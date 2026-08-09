import XCTest
@testable import JsBaoClient

/// Regression tests for `BlobManager`'s upload-retry backoff and queue
/// scheduling (issue #2056).
///
/// The crash: `computeBackoff` applied its cap in the `Int` domain
/// (`min(Int(delay), backoffMax)`), so once `backoffBase * 2^(attempts-1)`
/// exceeded `Int.max` — from `attempts == 54` on with the production 2000ms
/// base — the `Double → Int` conversion trapped and aborted the whole test
/// process with "Double value cannot be converted to Int because the result
/// would be greater than Int.max" (signal 5), silently truncating the suite.
///
/// The driver: `processQueue()` had no per-task in-flight marker and spawned a
/// fresh detached retry `Task` per failure, so concurrent passes re-selected
/// the same failing task and each one bumped `attempts` — which is how a
/// nominally 60s-capped backoff reached 54 attempts inside an ~8-minute
/// process (ten threads were inside `processQueue()` in the crash report).
final class BlobBackoffTests: XCTestCase {

    private struct StubTransportError: Error {}

    /// Drives the manager's uploads through the typed `Transport` seam. The
    /// handler returns the `(body, status)` pair `Transport.requestData` hands
    /// back to `BlobManager`, or throws to simulate a transport-level failure.
    private struct StubTransport: Transport {
        let handler: @Sendable (HTTPMethod, String, Data?, RequestOptions?) async throws -> (Data, Int)

        init(
            _ handler: @escaping @Sendable (HTTPMethod, String, Data?, RequestOptions?) async throws -> (Data, Int)
        ) {
            self.handler = handler
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            let (data, status) = try await handler(method, path, body, options)
            return TransportResponse(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }

    /// The manager's collaborators arrive at construction (#2172) — it is an
    /// actor, so there is no post-construction setter to assign them with.
    private func makeManager(
        uploadConcurrency: Int = 2,
        backoffBaseMs: Int? = nil,
        backoffMaxMs: Int? = nil,
        transport: (any Transport)? = nil,
        emitter: EventEmitter? = nil
    ) -> BlobManager {
        BlobManager(
            logger: Logger(level: .error, scope: "test"),
            uploadConcurrency: uploadConcurrency,
            backoffBaseMs: backoffBaseMs,
            backoffMaxMs: backoffMaxMs,
            transport: transport,
            emit: emitter.map { emitter in { @Sendable payload in emitter.emitErased(payload) } }
        )
    }

    // MARK: - computeBackoff

    /// Attempt counts at and beyond the overflow threshold must clamp to the
    /// cap instead of trapping. 54 is the exact first trapping value with the
    /// production constants; `delay` stays finite (so `pow` has not yet reached
    /// `.infinity`) up to `attempts <= 1014`, and beyond that the non-finite
    /// path must clamp too.
    func testHighAttemptCountsClampWithoutTrapping() {
        let manager = makeManager()
        for attempts in [54, 64, 1014, 1015, 4096, Int.max] {
            XCTAssertEqual(
                manager.computeBackoff(attempts: attempts),
                BlobManager.defaultBackoffMaxMs,
                "attempts=\(attempts) must clamp to the cap, not trap"
            )
        }
    }

    /// The pure form, exercised directly across the finite → infinite boundary.
    func testPureBackoffClampsForFiniteAndNonFiniteDelays() {
        // Finite but past Int.max.
        XCTAssertEqual(
            BlobManager.uploadBackoffMs(attempts: 54, baseMs: 2000, maxMs: 60000), 60000)
        XCTAssertEqual(
            BlobManager.uploadBackoffMs(attempts: 1014, baseMs: 2000, maxMs: 60000), 60000)
        // `pow` overflows Double to +infinity from attempts == 1015 on.
        XCTAssertEqual(
            BlobManager.uploadBackoffMs(attempts: 1015, baseMs: 2000, maxMs: 60000), 60000)
        XCTAssertEqual(
            BlobManager.uploadBackoffMs(attempts: 100_000, baseMs: 2000, maxMs: 60000), 60000)
    }

    /// Small attempt counts keep the original progression, and the cap takes
    /// over from attempt 6 on (2000 * 2^5 = 64000 > 60000).
    func testLowAttemptCountsAreUnchanged() {
        let manager = makeManager()
        XCTAssertEqual(manager.computeBackoff(attempts: 1), 2000)
        XCTAssertEqual(manager.computeBackoff(attempts: 2), 4000)
        XCTAssertEqual(manager.computeBackoff(attempts: 3), 8000)
        XCTAssertEqual(manager.computeBackoff(attempts: 4), 16000)
        XCTAssertEqual(manager.computeBackoff(attempts: 5), 32000)
        XCTAssertEqual(manager.computeBackoff(attempts: 6), 60000)
    }

    /// Non-positive attempt counts clamp the exponent to zero (JS parity with
    /// `Math.max(0, attempts - 1)`) rather than producing a fractional or
    /// absurd delay — and `Int.min` must not overflow the `attempts - 1`
    /// subtraction itself.
    func testNonPositiveAttemptsClampExponent() {
        let manager = makeManager()
        XCTAssertEqual(manager.computeBackoff(attempts: 0), 2000)
        XCTAssertEqual(manager.computeBackoff(attempts: -5), 2000)
        XCTAssertEqual(manager.computeBackoff(attempts: Int.min), 2000)
    }

    // MARK: - Queue re-entrancy

    /// Wait until the single queued task has settled out of its in-flight
    /// state, and return it. Fails the test if it never does — which is exactly
    /// what a stranded in-flight marker looks like.
    @discardableResult
    private func waitForSettledTask(
        _ manager: BlobManager,
        timeoutMs: Int = 3000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> BlobUploadStatus? {
        var uploads = await manager.listUploads()
        var waited = 0
        while uploads.first?.status == "uploading" && waited < timeoutMs {
            try await Task.sleep(nanoseconds: 25 * 1_000_000)
            waited += 25
            uploads = await manager.listUploads()
        }
        XCTAssertNotEqual(
            uploads.first?.status, "uploading",
            "task never left the in-flight state — its marker was not cleared",
            file: file, line: line
        )
        return uploads.first
    }

    /// Wait until the manager is quiescent: the task has settled *and* the
    /// queue timer it re-arms on the way out is pending and has stopped
    /// changing.
    ///
    /// `waitForSettledTask` alone is not enough for a timer-count baseline —
    /// it returns as soon as the in-flight marker clears, which happens just
    /// before `runUploadTask`'s trailing `rearmQueueTimer()`. A baseline taken
    /// in that window counts the re-arm against whatever the test does next.
    private func waitForQuiescentQueue(
        _ manager: BlobManager,
        timeoutMs: Int = 3000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitForSettledTask(manager, timeoutMs: timeoutMs, file: file, line: line)

        var last = await manager.queueTimerStartCount
        var stableSamples = 0
        var waited = 0
        while waited < timeoutMs {
            try await Task.sleep(nanoseconds: 25 * 1_000_000)
            waited += 25
            let current = await manager.queueTimerStartCount
            if current == last, await manager.hasPendingQueueTimer {
                stableSamples += 1
                if stableSamples >= 3 { return }
            } else {
                stableSamples = 0
                last = current
            }
        }
        XCTFail(
            "the queue never quiesced — no stable pending timer within \(timeoutMs)ms",
            file: file, line: line)
    }

    /// Ten concurrent `processQueue()` passes over a single due task must
    /// perform exactly **one** physical upload attempt: the in-flight marker is
    /// set synchronously under the same lock that snapshots the queue, so the
    /// other nine passes skip the task. Before the fix every pass selected it,
    /// each fired a request and each incremented `attempts`.
    func testConcurrentPassesSelectATaskOnlyOnce() async throws {
        // A 100s backoff means the queue's own timer can fire at most the one
        // immediate retry — everything else in this test is the ten passes.
        let calls = Counter()
        let manager = makeManager(
            uploadConcurrency: 4, backoffBaseMs: 100_000, backoffMaxMs: 100_000,
            transport: StubTransport { _, _, _, _ in
                calls.increment()
                // Hold each attempt open long enough for the other passes to run.
                try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                throw StubTransportError()
            })

        // Queue one task: the immediate attempt fails and leaves it queued
        // (attempts = 1, due immediately).
        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))
        let observed1 = await manager.listUploads().count
        XCTAssertEqual(observed1, 1)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await manager.processQueue() }
            }
            await group.waitForAll()
        }

        // Let whichever pass claimed the task finish its attempt.
        var uploads = await manager.listUploads()
        for _ in 0..<40 where uploads.first?.status == "uploading" {
            try await Task.sleep(nanoseconds: 50 * 1_000_000)
            uploads = await manager.listUploads()
        }

        XCTAssertEqual(uploads.count, 1)
        // One immediate attempt + exactly one retry, however many passes ran.
        XCTAssertEqual(
            calls.value, 2,
            "ten concurrent passes must produce one physical retry, saw \(calls.value) requests")
        XCTAssertEqual(
            uploads[0].attempts, 2,
            "`attempts` must advance by exactly one per physical attempt")
    }

    /// Repeated scheduling requests must coalesce onto a single pending timer
    /// rather than starting one per call (the old code spawned a detached
    /// `Task` per failure).
    ///
    /// Both bursts request the same 30s delay while the queue's own timer is
    /// parked 100s out, so the first request replaces that timer and every
    /// later one must find the pending timer already good enough. The counts
    /// are exact, not bounded: the baseline is taken only once the manager is
    /// quiescent (see `waitForQuiescentQueue` — snapshotting it earlier caught
    /// the initial failure's own re-arm and was what made this test flaky), and
    /// the concurrent burst runs *after* the serial one so every child's
    /// deadline is later than the pending timer's however its `Date()` read is
    /// interleaved.
    func testQueueTimerCoalesces() async throws {
        // A 100s backoff parks the task far out, so the timer armed for it
        // stays pending for the duration of this test.
        let manager = makeManager(
            backoffBaseMs: 100_000, backoffMaxMs: 100_000,
            transport: StubTransport { _, _, _, _ in throw StubTransportError() })

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))
        try await waitForQuiescentQueue(manager)

        // Serial burst: the first request pulls the deadline in from 100s to
        // 30s, the other 19 coalesce onto it.
        let beforeSerial = await manager.queueTimerStartCount
        for _ in 0..<20 {
            await manager.scheduleQueueProcessing(delayMs: 30_000)
        }
        let serialStarts = await manager.queueTimerStartCount - beforeSerial
        XCTAssertEqual(
            serialStarts, 1,
            "20 requests for the same deadline must arm exactly one timer, armed \(serialStarts)")
        let observed2 = await manager.hasPendingQueueTimer
        XCTAssertTrue(observed2, "a single timer must remain pending")

        // Concurrent burst: the pending 30s timer already covers every one of
        // these, so none of them may arm another.
        let beforeConcurrent = await manager.queueTimerStartCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await manager.scheduleQueueProcessing(delayMs: 30_000) }
            }
            await group.waitForAll()
        }
        let concurrentStarts = await manager.queueTimerStartCount - beforeConcurrent
        XCTAssertEqual(
            concurrentStarts, 0,
            "20 concurrent requests covered by the pending timer must arm none, armed \(concurrentStarts)")
        let observed3 = await manager.hasPendingQueueTimer
        XCTAssertTrue(
            observed3,
            "exactly one timer must still be pending after the concurrent burst")
    }

    /// A *queueable* failure (here a bare transport error, which carries no
    /// HTTP status) keeps retrying — no max-attempt limit, no terminal
    /// `willRetry: false` event — but the retry rate stays bounded by the
    /// backoff: one attempt per interval, not a growing set of concurrent
    /// passes. With a 50ms flat backoff, ~1 second of retrying is tens of
    /// attempts, never the hundreds the runaway produced.
    ///
    /// Both halves are JS parity: `shouldQueueError` returns `true` for an
    /// error with no status, and `computeBackoff` paces the retries.
    /// Permanently-rejected uploads take the terminal path instead — see
    /// `testPermanent4xxTerminatesTheUpload`.
    func testFailingUploadRetriesForeverAtABoundedRate() async throws {
        let calls = Counter()
        let failures = Counter()
        let terminal = Counter()
        let emitter = EventEmitter()
        let manager = makeManager(
            uploadConcurrency: 2, backoffBaseMs: 50, backoffMaxMs: 50,
            transport: StubTransport { _, _, _, _ in
                calls.increment()
                throw StubTransportError()
            },
            emitter: emitter)
        let subscription = emitter.subscribe(BlobUploadFailedEvent.self) { event in
            failures.increment()
            if event.willRetry == false {
                terminal.increment()
            }
        }
        defer { subscription.cancel() }

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))

        try await Task.sleep(nanoseconds: 1_000 * 1_000_000)

        let uploads = await manager.listUploads()
        XCTAssertEqual(uploads.count, 1, "a permanently failing upload stays queued forever")
        let attempts = uploads[0].attempts
        XCTAssertGreaterThan(attempts, 3, "the task must still be being retried, attempts=\(attempts)")
        // ~1s / 50ms ≈ 20 attempts; allow generous slack for scheduler jitter
        // while still failing loudly on the exponential runaway.
        XCTAssertLessThan(
            attempts, 120,
            "retries must stay paced by the backoff, not multiply per failure (attempts=\(attempts))")
        XCTAssertEqual(
            terminal.value, 0,
            """
            no terminal willRetry:false event — a statusless transport error \
            is queueable under shouldQueueError, so it retries indefinitely
            """)
        XCTAssertGreaterThan(failures.value, 0, "each failed attempt emits blobs:upload-failed")

        // Attempts and physical requests advance together: one increment per
        // request, so the `attempts` carried on `blobs:upload-failed` is
        // meaningful rather than inflated by concurrent passes. The sample can
        // catch one request still in flight, hence the ±1.
        let drift = calls.value - attempts
        XCTAssertTrue(
            drift == 0 || drift == 1,
            "one physical request per attempt (requests=\(calls.value), attempts=\(attempts))")
    }

    /// The in-flight marker must be cleared on the failure path, or the task
    /// strands as permanently "uploading" and is never retried again.
    func testInFlightMarkerIsClearedAfterAFailedAttempt() async throws {
        let manager = makeManager(
            backoffBaseMs: 100_000, backoffMaxMs: 100_000,
            transport: StubTransport { _, _, _, _ in throw StubTransportError() })

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))

        let task = try await waitForSettledTask(manager)
        let observed4 = await manager.listUploads().count
        XCTAssertEqual(observed4, 1)
        XCTAssertEqual(
            task?.status, "pending",
            "a task left marked in-flight after a failure would never be retried")
    }

    /// Pausing a queued upload while a retry timer is pending must not leave
    /// the manager retrying it, and resuming must pick it back up.
    func testPauseAndResumeAroundAPendingRetryTimer() async throws {
        let calls = Counter()
        let manager = makeManager(
            backoffBaseMs: 100, backoffMaxMs: 100,
            transport: StubTransport { _, _, _, _ in
                calls.increment()
                throw StubTransportError()
            })

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))
        try await Task.sleep(nanoseconds: 150 * 1_000_000)

        let blobId = await manager.listUploads()[0].blobId
        let observed5 = await manager.pauseUpload(blobId)
        XCTAssertTrue(observed5)
        // `pauseUpload` stops future retries but does not cancel an attempt
        // that is already in flight, so let any such attempt land before
        // taking the baseline — sampling `calls` immediately raced it.
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        let pausedAt = calls.value
        try await Task.sleep(nanoseconds: 400 * 1_000_000)
        XCTAssertEqual(
            calls.value, pausedAt,
            "a paused upload must not be retried by a pending queue timer")
        let observed6 = await manager.listUploads()[0].status
        XCTAssertEqual(observed6, "paused")

        let observed7 = await manager.resumeUpload(blobId)
        XCTAssertTrue(observed7)
        try await Task.sleep(nanoseconds: 300 * 1_000_000)
        XCTAssertGreaterThan(
            calls.value, pausedAt, "resuming must put the task back in the retry rotation")
    }

    /// A successful retry drains the queue and emits `blobs:queue-drained`.
    func testSuccessfulRetryDrainsTheQueue() async throws {
        let calls = Counter()
        let drained = Counter()
        let emitter = EventEmitter()
        let manager = makeManager(
            backoffBaseMs: 20, backoffMaxMs: 20,
            transport: StubTransport { _, _, _, _ in
                let n = calls.increment()
                if n == 1 { throw StubTransportError() }
                return (Data("{}".utf8), 200)
            },
            emitter: emitter)
        let subscription = emitter.subscribe(BlobsQueueDrainedEvent.self) { _ in drained.increment() }
        defer { subscription.cancel() }

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))

        // Poll for the retry to succeed.
        var remaining = 0
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50 * 1_000_000)
            remaining = await manager.listUploads().count
            if remaining == 0 { break }
        }
        XCTAssertEqual(remaining, 0, "the retry must succeed and remove the task")
        XCTAssertGreaterThan(drained.value, 0, "queue-drained must fire once the queue empties")
        let observed8 = await manager.hasPendingQueueTimer
        XCTAssertFalse(
            observed8,
            "an empty queue must leave no timer armed")
    }

    // MARK: - Retry eligibility (`shouldQueueError` parity)

    /// Classification table, mirroring JS `shouldQueueError`
    /// (`src/client/internal/blobManager.ts:1305-1318`) status for status.
    func testShouldQueueErrorMatchesTheJsClassification() {
        // Retryable 4xx.
        for status in [408, 409, 429] {
            XCTAssertTrue(
                BlobManager.shouldQueueError(HttpError(status: status, message: "x")),
                "\(status) is retryable in JS")
        }
        // 5xx: always retryable.
        for status in [500, 502, 503, 504, 599] {
            XCTAssertTrue(
                BlobManager.shouldQueueError(HttpError(status: status, message: "x")),
                "\(status) is retryable in JS")
        }
        // Every other 4xx is permanent.
        for status in [400, 401, 403, 404, 413, 422, 499] {
            XCTAssertFalse(
                BlobManager.shouldQueueError(HttpError(status: status, message: "x")),
                "\(status) is terminal in JS")
        }
        // Non-HTTP errors (network/transport) and sub-400 statuses fall
        // through to JS's `return true`.
        XCTAssertTrue(BlobManager.shouldQueueError(StubTransportError()))
        XCTAssertTrue(BlobManager.shouldQueueError(
            URLError(.notConnectedToInternet)))
        XCTAssertTrue(BlobManager.shouldQueueError(HttpError(status: 0, message: "x")))
        // Whatever `HttpClient.fetchWithRefresh` throws for a refresh-time
        // transport failure must be retryable (#2366). Since #2367 / PR #2549
        // that failure is the public `JsBaoNetworkError` (rethrown from the
        // refresh path, or built at the throw site when no underlying error
        // was carried).
        XCTAssertTrue(BlobManager.shouldQueueError(
            JsBaoNetworkError(message: "Token refresh failed due to a network error")))
    }

    /// A permanent 4xx on the very first (immediate) attempt must never be
    /// queued: the error propagates, no task is tracked, the retained bytes
    /// are released, and exactly one terminal `willRetry: false` is emitted.
    func testPermanent4xxOnTheImmediateAttemptTerminatesTheUpload() async throws {
        let calls = Counter()
        let events = FailureRecorder()
        let emitter = EventEmitter()
        let manager = makeManager(
            backoffBaseMs: 20, backoffMaxMs: 20,
            transport: StubTransport { _, _, _, _ in
                calls.increment()
                return (Data(#"{"error":"forbidden"}"#.utf8), 403)
            },
            emitter: emitter)
        let subscription = emitter.subscribe(BlobUploadFailedEvent.self) { event in
            events.record(event)
        }
        defer { subscription.cancel() }

        do {
            _ = try await manager.uploadFromSource(
                documentId: "doc", source: Data("payload".utf8))
            XCTFail("a permanent 4xx must propagate to the caller")
        } catch {
            XCTAssertEqual((error as? HttpError)?.status, 403)
        }

        // Give any (incorrect) retry timer a chance to fire.
        try await Task.sleep(nanoseconds: 300 * 1_000_000)

        XCTAssertEqual(calls.value, 1, "a permanent 4xx must not be retried")
        let observed9 = await manager.listUploads().isEmpty
        XCTAssertTrue(observed9, "the queue record must be dropped")
        let observed10 = await manager.hasPendingQueueTimer
        XCTAssertFalse(
            observed10, "no retry timer may be armed for a terminal failure")

        let recorded = events.events
        XCTAssertEqual(recorded.count, 1, "exactly one terminal failure event")
        XCTAssertEqual(recorded.first?.willRetry, false)
        XCTAssertEqual(recorded.first?.attempts, 1)

        let blobId = recorded.first?.blobId ?? ""
        let observed11 = await manager.hasCachedBytes(documentId: "doc", blobId: blobId)
        XCTAssertFalse(
            observed11,
            "the locally-retained bytes must be released, not pinned for the process lifetime")
    }

    /// A queued task whose retry hits a permanent 4xx must terminate there:
    /// the record is removed, the bytes released, one `willRetry: false` is
    /// emitted, and `queue-drained` fires because the queue is now empty.
    func testPermanent4xxOnARetryTerminatesTheQueuedUpload() async throws {
        let calls = Counter()
        let events = FailureRecorder()
        let drained = Counter()
        let emitter = EventEmitter()
        let manager = makeManager(
            backoffBaseMs: 20, backoffMaxMs: 20,
            transport: StubTransport { _, _, _, _ in
                let n = calls.increment()
                // First attempt: a retryable 503. Every later attempt: a
                // permanent 404.
                if n == 1 { return (Data("{}".utf8), 503) }
                return (Data("{}".utf8), 404)
            },
            emitter: emitter)
        let failedSub = emitter.subscribe(BlobUploadFailedEvent.self) { event in
            events.record(event)
        }
        let drainSub = emitter.subscribe(BlobsQueueDrainedEvent.self) { _ in drained.increment() }
        defer {
            failedSub.cancel()
            drainSub.cancel()
        }

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))
        let observed12 = await manager.listUploads().count
        XCTAssertEqual(observed12, 1, "a 503 must queue for retry")

        var remaining = 1
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50 * 1_000_000)
            remaining = await manager.listUploads().count
            if remaining == 0 { break }
        }
        XCTAssertEqual(remaining, 0, "the permanent 404 retry must drop the task")

        let callsAtTermination = calls.value
        try await Task.sleep(nanoseconds: 300 * 1_000_000)
        XCTAssertEqual(
            calls.value, callsAtTermination,
            "no attempts may run after the terminal failure")

        let recorded = events.events
        XCTAssertEqual(recorded.count, 2, "one retryable failure, then one terminal one")
        XCTAssertEqual(recorded.first?.willRetry, true, "the 503 must report willRetry: true")
        XCTAssertEqual(recorded.last?.willRetry, false, "the 404 must report willRetry: false")
        XCTAssertEqual(recorded.last?.attempts, 2)
        XCTAssertGreaterThan(drained.value, 0, "queue-drained must fire once the queue empties")

        let blobId = recorded.last?.blobId ?? ""
        let observed13 = await manager.hasCachedBytes(documentId: "doc", blobId: blobId)
        XCTAssertFalse(
            observed13,
            "the terminal path must release the retained bytes")
    }

    /// The queueable 4xx statuses stay in the retry rotation — a 429 must not
    /// be swept up by the "other 4xx is terminal" rule.
    func testQueueable4xxKeepsRetrying() async throws {
        let calls = Counter()
        let terminal = Counter()
        let emitter = EventEmitter()
        let manager = makeManager(
            backoffBaseMs: 20, backoffMaxMs: 20,
            transport: StubTransport { _, _, _, _ in
                calls.increment()
                return (Data("{}".utf8), 429)
            },
            emitter: emitter)
        let subscription = emitter.subscribe(BlobUploadFailedEvent.self) { event in
            if event.willRetry == false {
                terminal.increment()
            }
        }
        defer { subscription.cancel() }

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))

        try await Task.sleep(nanoseconds: 400 * 1_000_000)

        let observed14 = await manager.listUploads().count
        XCTAssertEqual(observed14, 1, "a 429 must stay queued")
        XCTAssertGreaterThan(calls.value, 1, "a 429 must be retried")
        XCTAssertEqual(terminal.value, 0, "a 429 must never produce a terminal failure")
    }
}

/// Thread-safe recorder for `blobs:upload-failed` payloads.
private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BlobUploadFailedEvent] = []

    func record(_ event: BlobUploadFailedEvent) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(event)
    }

    var events: [BlobUploadFailedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Small thread-safe counter for the stubbed transport.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
