import XCTest
@testable import JsBaoClient

/// #2172 — the Phase D follow-up that converts `BlobManager` from
/// `final class` + `NSLock` + `@unchecked Sendable` to a `public actor`, and
/// opens the one-release deprecation window on the synchronous blob surface.
///
/// Same two kinds of check as the D2 (`ActorizedAsyncManagersTests`) and D3
/// (`ActorizedAnalyticsQueueTests`) suites:
///
/// * **Structural** (comment-stripped source) — that the type really is an
///   actor with no lock left, that the three lock-held decision regions each
///   became one `await`-free isolated region, that every emit helper is
///   `nonisolated` and no isolated member calls one, that the queue-timer task
///   is built by a `nonisolated` factory, that every deprecated member has a
///   twin and every removed one has an `unavailable, renamed:` stub, and that
///   `deinit`'s safety argument was rewritten rather than carried over.
/// * **Behavioral** — the two properties the conversion could silently destroy:
///   concurrent uploads must stay concurrent, and a blocking event subscriber
///   must not occupy the actor. Plus the generation guard, which has had no
///   direct test until now.
///
/// The coalesced-single-timer invariant (#2056) is *not* re-asserted here —
/// `BlobBackoffTests.testQueueTimerCoalesces` already pins it, and the point of
/// this conversion is that those assertions stay green unweakened.
///
/// All server-free.
final class ActorizedBlobManagerTests: XCTestCase {

    // MARK: - Fixtures

    private struct StubTransportError: Error {}

    /// Drives the manager's uploads through the typed `Transport` seam.
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
            return TransportResponse(status: status, headers: [:], body: data)
        }
    }

    /// Thread-safe counter.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        @discardableResult func increment() -> Int { lock.withLock { _value += 1; return _value } }
        func decrement() { lock.withLock { _value -= 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// Tracks how many transfers were in flight at once, and the peak.
    private final class ConcurrencyGauge: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var _peak = 0
        func enter() {
            lock.withLock {
                active += 1
                if active > _peak { _peak = active }
            }
        }
        func leave() { lock.withLock { active -= 1 } }
        var peak: Int { lock.withLock { _peak } }
        /// Drop the high-water mark back to what is in flight right now, so a
        /// later assertion measures only the phase it cares about rather than
        /// inheriting the peak of an earlier setup phase.
        func resetPeak() { lock.withLock { _peak = active } }
    }

    // MARK: - Behavior 1 — the actor, and no surviving lock

    /// The headline. An actor and a lock-guarded class behave identically from
    /// the outside, so this cannot be observed any other way.
    func testBlobManagerIsDeclaredAsAnActor() throws {
        XCTAssertTrue(
            try Self.clientSource("Internal/BlobManager.swift").contains("public actor BlobManager"),
            "BlobManager must be an actor"
        )
    }

    /// The conversion has to *replace* the lock, not sit beside it. The sponsor
    /// resolved Fork 3 to async-only reads (2026-08-02), so no snapshot holder
    /// exists and the budget is zero — for the lock and for the `Sendable`
    /// opt-out the lock justified.
    func testBlobManagerDeclaresNoLock() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        XCTAssertFalse(source.contains("NSLock("), "BlobManager must not declare a lock")
        XCTAssertFalse(source.contains("lock.withLock"), "BlobManager must not hold a lock")
        XCTAssertFalse(source.contains("@unchecked Sendable"),
                       "the @unchecked Sendable opt-out the lock justified must be gone")
        XCTAssertFalse(source.contains("class BlobManager"),
                       "BlobManager must not still be a class")
    }

    // MARK: - Behavior 2 — the v6 gate holds the new boundary at zero

    /// Actorizing a type *creates* `Sendable` requirements at every new
    /// boundary, so "the budget was already 0" is not the same claim as "this
    /// file is held at 0" — naming it is what stops a later change from
    /// re-introducing an `Any` here unnoticed. The runner's list and
    /// `SendableModelLayerTests`' assertion move in lockstep, so a half-update
    /// fails the suite.
    func testV6GateHoldsBlobManagerAtZero() throws {
        let runner = try ClientSourceText.packageFile("run-tests.sh")
        XCTAssertTrue(runner.contains("\"Internal/BlobManager.swift\""),
                      "run-tests.sh must hold Internal/BlobManager.swift at zero .v6 Sendable sites")
        XCTAssertTrue(runner.contains("V6_MAX_SITES=0"),
                      "the budget stays at zero")
    }

    // MARK: - Behavior 10 — the TSan gate exercises the queue timer

    /// `BlobBackoffTests` is the suite that hammers `scheduleQueueProcessing`,
    /// the generation counter and the retry rotation — the state this
    /// conversion moved into actor isolation — and the gate has never run it.
    /// Nothing is removed from the baseline here (no entry ever named
    /// `BlobManager`), and nothing may be added to it.
    func testTsanGateRunsTheBlobQueueSuitesAndAddsNoBaseline() throws {
        let script = try ClientSourceText.repoFile("swift-client/scripts/tsan-gate.sh")
        XCTAssertTrue(script.contains("BlobBackoffTests"),
                      "the gate must run the suite that exercises the queue timer")
        XCTAssertTrue(script.contains("ActorizedBlobManagerTests"),
                      "the gate must run this suite's concurrency exercises too")
        let signatures = try Self.slice(script, from: "BASELINE_RACE_SIGNATURES=(", to: "\n)")
        XCTAssertFalse(
            signatures.contains("BlobManager"),
            "no baseline entry may exempt BlobManager — a race here is a finding, not a baseline"
        )
    }

    // MARK: - Behavior 18 — the dead dependency is gone

    /// `getCurrentUserId` was assigned by `setupDependencies()` and read
    /// nowhere. It goes with the conversion rather than being ported.
    func testTheDeadGetCurrentUserIdDependencyIsGone() throws {
        XCTAssertFalse(
            try Self.clientSource("Internal/BlobManager.swift").contains("getCurrentUserId"),
            "BlobManager must not carry the dead getCurrentUserId dependency"
        )
        XCTAssertFalse(
            try Self.clientSource("JsBaoClient.swift").contains("blobManager.getCurrentUserId"),
            "the client must not wire a dependency the manager does not have"
        )
    }

    /// The construction-ordering fix: the client builds its `BlobManager` with
    /// every collaborator attached, instead of building it bare and assigning
    /// them from the synchronous `setupDependencies()` afterwards.
    func testJsBaoClientConstructsBlobManagerWithItsCollaborators() throws {
        let source = try Self.code("JsBaoClient.swift")
        XCTAssertTrue(source.contains("BlobManager(\n"),
                      "the client must construct BlobManager with its collaborators")
        for setter in ["blobManager.transport =", "blobManager.emitter =", "blobManager.getApiUrl ="] {
            XCTAssertFalse(source.contains(setter),
                           "no post-construction wiring may remain: \(setter)")
        }
    }

    // MARK: - Behavior 9 — the three decision regions are `await`-free

    /// Coalescing in `scheduleQueueProcessing`. Under the lock this took two or
    /// three separate holds; it is one isolated region now, and an `await` in
    /// it would reopen the #2056 double-arming class.
    func testScheduleQueueProcessingDecisionRegionContainsNoSuspensionPoint() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        let region = try Self.slice(
            source,
            from: "func scheduleQueueProcessing(delayMs: Int = 0) {",
            to: "private nonisolated func makeQueueTimer("
        )
        XCTAssertTrue(region.contains("queueTimerStartCountValue += 1"),
                      "the slice must cover the region that arms the timer")
        XCTAssertFalse(
            region.contains("await"),
            "the coalesce-and-arm region must not suspend:\n\(region)"
        )
    }

    /// The #2056 guard itself: selection plus the in-flight marking must stay
    /// one uninterrupted isolated step, or two passes select the same task.
    func testSelectionRegionContainsNoSuspensionPoint() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        let region = try Self.slice(
            source,
            from: "private func selectDueTasks()",
            to: "private nonisolated func runUploadTask("
        )
        XCTAssertTrue(region.contains("activeUploads += 1"),
                      "the slice must cover the region that claims a task")
        XCTAssertFalse(
            region.contains("await"),
            "the selection region must not suspend:\n\(region)"
        )
    }

    /// Failure bookkeeping: decrementing `activeUploads`, bumping `attempts`
    /// and computing the next deadline are one decision from one view of the
    /// queue.
    func testFailureBookkeepingRegionContainsNoSuspensionPoint() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        let region = try Self.slice(
            source,
            from: "private func recordUploadFailure(",
            to: "private nonisolated func emitUploadProgress("
        )
        XCTAssertTrue(region.contains("updatedTask.attempts += 1"),
                      "the slice must cover the region that records the failure")
        XCTAssertFalse(
            region.contains("await"),
            "the failure-bookkeeping region must not suspend:\n\(region)"
        )
    }

    /// The re-read the region above depends on. A task cancelled or drained
    /// mid-flight is simply gone; trusting the copy taken before the upload
    /// `await` would resurrect it.
    func testFailureBookkeepingRereadsTheQueueRatherThanTrustingThePreAwaitCopy() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        let region = try Self.slice(
            source,
            from: "private func recordUploadFailure(",
            to: "private nonisolated func emitUploadProgress("
        )
        XCTAssertTrue(
            region.contains("guard var updatedTask = uploadQueue[task.blobId] else {"),
            "the failure path must re-read the live queue record, not reuse the pre-await copy"
        )
    }

    /// A `Task {}` created inside an isolated context inherits the actor's
    /// isolation, so the queue timer must be built by a `nonisolated` factory —
    /// the same lesson D2 recorded for `KvCache.makeFetchTask`.
    func testTheQueueTimerIsBuiltByANonisolatedFactory() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        XCTAssertTrue(
            source.contains("private nonisolated func makeQueueTimer("),
            "the timer task must be built from nonisolated context, or its body inherits actor isolation"
        )
        let body = try Self.slice(
            source,
            from: "private nonisolated func makeQueueTimer(",
            to: "func claimQueueTimer(generation: UInt64) -> Bool {"
        )
        XCTAssertTrue(body.contains("[weak self]"),
                      "the timer must hold the manager weakly — deinit's safety argument depends on it")
        XCTAssertTrue(
            body.contains("guard await self.claimQueueTimer(generation: generation) else { return }"),
            "the timer body's only route to processQueue must be through the generation claim"
        )
    }

    // MARK: - Behavior 6 — a superseded generation never runs the queue

    /// The generation counter survives the conversion, and it has to: the timer
    /// body sleeps *outside* isolation and re-enters afterwards, so another
    /// `scheduleQueueProcessing` can supersede it in that window.
    ///
    /// Exercised through `claimQueueTimer` directly rather than by racing a real
    /// timer. The window between a timer waking and re-entering the actor is
    /// microseconds wide, so a timing-based test would be flaky by construction;
    /// the structural test above pins that the timer body has no other route to
    /// `processQueue`, and this pins what the claim decides.
    func testASupersededGenerationDeclinesToRunTheQueue() async throws {
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            backoffBaseMs: 100_000,
            backoffMaxMs: 100_000,
            transport: StubTransport { _, _, _, _ in throw StubTransportError() }
        )
        // One failing upload leaves a queued task with a timer armed for it.
        _ = try? await manager.uploadFromSource(documentId: "doc", source: Data("payload".utf8))
        // Settle first. The freshly queued task is due immediately (its
        // `nextAttemptAt` is 0), so the manager arms a zero-delay timer, runs
        // one retry, and only then parks a timer 100s out. Sampling before that
        // settles would race the manager's own timer against the assertions.
        try await Self.waitForAParkedQueueTimer(manager)

        let armed = await manager.hasPendingQueueTimer
        XCTAssertTrue(armed, "a queued retry must arm a timer")

        let current = await manager.currentQueueTimerGeneration
        let olderClaimed = await manager.claimQueueTimer(generation: current &- 1)
        XCTAssertFalse(
            olderClaimed,
            "a superseded (older) generation must decline to run the queue")
        let unarmedClaimed = await manager.claimQueueTimer(generation: current &+ 1)
        XCTAssertFalse(
            unarmedClaimed,
            "a generation that was never armed must decline too")
        // A declined claim must leave the live timer's bookkeeping alone —
        // clearing it would let the next schedule arm a second timer.
        let stillArmed = await manager.hasPendingQueueTimer
        XCTAssertTrue(
            stillArmed,
            "a declined claim must not clear the pending timer")

        // The current generation claims successfully, and the claim consumes
        // the timer. (`claimQueueTimer` does not bump the generation, so this
        // does not by itself prove a *second* same-generation call would be
        // refused — in production there is exactly one Task per generation and
        // a claimed generation can never be re-armed, because
        // `scheduleQueueProcessing` bumps through `clearQueueTimer`.)
        let currentClaimed = await manager.claimQueueTimer(generation: current)
        XCTAssertTrue(currentClaimed)
        let armedAfterClaim = await manager.hasPendingQueueTimer
        XCTAssertFalse(
            armedAfterClaim,
            "a successful claim consumes the timer")
    }

    // MARK: - Behavior 7 — concurrent uploads still overlap

    /// The actor serializes the same critical sections the lock did, and no
    /// more: the transfers themselves run off it. With `uploadConcurrency = 2`
    /// and a transport that holds each attempt open, two queued uploads must be
    /// in flight at the same instant.
    func testQueuedUploadsStillRunConcurrently() async throws {
        let gauge = ConcurrencyGauge()
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            uploadConcurrency: 2,
            backoffBaseMs: 20,
            backoffMaxMs: 20,
            transport: StubTransport { _, _, _, _ in
                gauge.enter()
                defer { gauge.leave() }
                try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                throw StubTransportError()
            }
        )

        // Seed two queued tasks (the immediate attempt fails, so each is queued
        // with a 20ms retry deadline).
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<2 {
                group.addTask {
                    _ = try? await manager.uploadFromSource(
                        documentId: "doc", source: Data("payload-\(i)".utf8))
                }
            }
            await group.waitForAll()
        }
        let queued = await manager.listUploads().count
        XCTAssertEqual(queued, 2, "both uploads must be queued")

        // The gauge is wired into the transport, so it also counted the two
        // *immediate* attempts the seeding group above issued in parallel —
        // `peak` is already 2 before a single queued upload runs, and it is
        // monotonic. Reset it here so the assertion below measures the queue
        // driver (`processQueue` / `runUploadTask`), which is the regression
        // this test exists to catch. Both seeding attempts have already
        // returned, and the reset drops the mark to what is in flight *now*
        // rather than to zero, so a retry that has already started is not
        // miscounted either way.
        gauge.resetPeak()

        // Let the retry rotation run. Both tasks are due within 20ms of each
        // other and each attempt is held open for 200ms, so a pass that honors
        // `uploadConcurrency = 2` has both in flight together.
        try await Task.sleep(nanoseconds: 900 * 1_000_000)

        XCTAssertEqual(
            gauge.peak, 2,
            "two queued uploads must overlap — the actor must not serialize the transfers")
    }

    // MARK: - Behavior 8 — a blocking subscriber does not occupy the actor

    /// `EventEmitter` delivers callback subscribers **synchronously**, so the
    /// emit closure runs arbitrary app code. Running it from an isolated step
    /// would put that code on the manager's executor: a slow
    /// `blobs:upload-failed` handler would serialize every queue operation.
    ///
    /// Exercised rather than read: the handler blocks until a *concurrent*
    /// isolated call has completed. If the emit held the actor, that call could
    /// not finish and the wait would time out.
    func testBlobEmitDoesNotOccupyTheBlobActor() async throws {
        let reentrantCallFinished = DispatchSemaphore(value: 0)
        let emitEntered = DispatchSemaphore(value: 0)
        let sawReentrantCall = AtomicCounter()
        let emitNeverFired = AtomicCounter()

        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            backoffBaseMs: 100_000,
            backoffMaxMs: 100_000,
            transport: StubTransport { _, _, _, _ in throw StubTransportError() },
            emit: { payload in
                guard payload is BlobUploadFailedEvent else { return }
                emitEntered.signal()
                // Deliberately blocking: this is the app handler whose cost
                // must not land on the blob actor.
                if reentrantCallFinished.wait(timeout: .now() + 5) == .success {
                    sawReentrantCall.increment()
                }
            }
        )

        let reader = Task { () -> [BlobUploadStatus]? in
            // Only start once the handler is actually blocking. Bounded: if the
            // emit stops firing — the regression this test guards — an untimed
            // wait would hang the suite instead of failing with a message.
            guard await emitEntered.waitAsync(timeout: .now() + 5) == .success else {
                emitNeverFired.increment()
                return nil
            }
            let uploads = await manager.listUploads()
            reentrantCallFinished.signal()
            return uploads
        }

        _ = try? await manager.uploadFromSource(documentId: "doc", source: Data("payload".utf8))

        let readWhileHandlerBlocked = await reader.value
        XCTAssertEqual(emitNeverFired.value, 0,
                       "the blobs:upload-failed emit never fired — the handler was never entered")
        XCTAssertEqual(readWhileHandlerBlocked?.count, 1,
                       "an isolated blob call must complete while an event handler is running")
        XCTAssertEqual(sawReentrantCall.value, 1,
                       "the emit must run with the actor free — it occupied the manager instead")
    }

    /// The structural half. A behavioral test can only observe the stall once
    /// the ordering is wrong in a way that reproduces; this pins where an emit
    /// may live: every member that reaches the `emit` closure — directly, or
    /// through a helper that does — is declared `nonisolated`.
    ///
    /// The helper names are **derived from the source**, not hardcoded, so a
    /// newly written emit helper is in scope the moment it exists rather than
    /// only after someone remembers to add it here. The site floor is the real
    /// site count for the same reason: a scan that quietly stops matching the
    /// source reports "no isolated emitters" for a file it never read, so it
    /// has to fail on the floor before it can return a vacuous pass.
    func testEveryEmitSiteSitsInNonisolatedContext() throws {
        let source = try Self.code("Internal/BlobManager.swift")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Member declarations sit at exactly one level of indentation; anything
        // deeper is a nested closure inside the member's body.
        func isMemberDeclaration(_ line: String) -> Bool {
            line.hasPrefix("    ") && !line.hasPrefix("        ") && line.contains("func ")
        }
        func declaredName(_ declaration: String) -> String? {
            guard let keyword = declaration.range(of: "func ") else { return nil }
            let name = declaration[keyword.upperBound...]
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        // `contains` rather than `hasPrefix`: `self.emit?(…)` and a trailing
        // `emit?(…)` on a continued expression reach the closure just as much
        // as a statement that starts with it.
        func touchesTheEmitClosure(_ line: String) -> Bool { line.contains("emit?(") }

        // Pass 1 — derive the helpers. Any member whose body touches the `emit`
        // closure hands app code whatever context it is called from, so calling
        // one from an isolated member is the same defect as emitting there.
        var currentDeclaration: String?
        var emitHelpers: Set<String> = []
        for line in lines {
            if isMemberDeclaration(line) {
                currentDeclaration = line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard touchesTheEmitClosure(line), let declaration = currentDeclaration,
                  let name = declaredName(declaration) else { continue }
            emitHelpers.insert(name)
        }
        XCTAssertFalse(emitHelpers.isEmpty,
                       "the scan found no member that reaches the emit closure — it is not reading the source")

        // Pass 2 — every site: a direct `emit?(`, or a call to a derived helper.
        currentDeclaration = nil
        var emittingDeclarations: [String] = []
        var isolatedEmitters: [String] = []
        for line in lines {
            if isMemberDeclaration(line) {
                currentDeclaration = line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let declaration = currentDeclaration else { continue }
            let reachesTheEmitClosure = touchesTheEmitClosure(line)
                || emitHelpers.contains { line.contains("\($0)(") }
            guard reachesTheEmitClosure else { continue }
            emittingDeclarations.append(declaration)
            if !declaration.contains("nonisolated") {
                isolatedEmitters.append(declaration)
            }
        }

        XCTAssertGreaterThanOrEqual(
            emittingDeclarations.count, Self.knownEmitReachingSiteCount,
            """
            the scan found \(emittingDeclarations.count) emit-reaching sites, \
            fewer than the \(Self.knownEmitReachingSiteCount) the source is known \
            to have — the scan has gone blind, so its "no isolated emitter" \
            verdict means nothing. Fix the scan (or lower this floor deliberately \
            if emit sites were genuinely removed).
            """
        )
        XCTAssertTrue(
            isolatedEmitters.isEmpty,
            """
            these isolated members reach the emit closure, which runs app code \
            on the blob actor: \(isolatedEmitters)
            """
        )
    }

    /// The emit-reaching site count in `BlobManager.swift` when this scan was
    /// last calibrated. It is an anti-vacuity floor, not an exact contract:
    /// adding an emit is fine, losing sight of the ones already there is not.
    private static let knownEmitReachingSiteCount = 26

    // MARK: - Behavior 12 — the void mutators keep a deprecated original + a twin

    /// The policy of record for a void-returning mutator is "additive `Async`
    /// twin + one-release deprecation" (Fork 1 Option C, as D3 shipped it).
    /// Both halves, for all six members, so a later edit cannot quietly drop a
    /// twin or un-deprecate an original.
    func testEveryDeprecatedBlobMutatorHasAnAsyncTwin() throws {
        let pairs: [(file: String, sync: String, twin: String)] = [
            ("JsBaoClient.swift", "func setBlobUploadConcurrency(", "func setBlobUploadConcurrencyAsync("),
            ("API/DocumentsAPI.swift", "func pauseAllUploads(", "func pauseAllUploadsAsync("),
            ("API/DocumentsAPI.swift", "func resumeAllUploads(", "func resumeAllUploadsAsync("),
            ("API/DocumentsAPI.swift", "func setUploadConcurrency(", "func setUploadConcurrencyAsync("),
            ("API/DocumentsAPI.swift", "func pauseAll(", "func pauseAllAsync("),
            ("API/DocumentsAPI.swift", "func resumeAll(", "func resumeAllAsync("),
        ]
        for pair in pairs {
            let source = try Self.clientSource(pair.file)
            XCTAssertTrue(
                source.contains(pair.twin),
                "\(pair.file): missing the async twin `\(pair.twin)`"
            )
            XCTAssertNotNil(
                source.range(of: "public \(pair.sync)"),
                "\(pair.file): the synchronous `\(pair.sync)` must survive the deprecation window"
            )
            let attributes = Self.attributes(before: "public \(pair.sync)", in: source)
            XCTAssertTrue(
                attributes.contains { $0.hasPrefix("@available(*, deprecated") },
                "\(pair.file): `\(pair.sync)` must be marked deprecated — attributes: \(attributes)"
            )
        }
    }

    /// `downloadUrl` stays synchronous **permanently** — it reads only the two
    /// immutable URL closures, and it is the member most likely to be called
    /// from a SwiftUI `body`. It carries no deprecation and no twin.
    func testDownloadUrlStaysSynchronousAndUndeprecated() throws {
        let manager = try Self.clientSource("Internal/BlobManager.swift")
        XCTAssertTrue(manager.contains("public nonisolated func downloadUrl("),
                      "BlobManager.downloadUrl must be nonisolated and synchronous")
        XCTAssertFalse(manager.contains("downloadUrlAsync"),
                       "downloadUrl gets no twin — it is not going away")

        let documents = try Self.clientSource("API/DocumentsAPI.swift")
        for declaration in ["public nonisolated func downloadUrl(", "public func downloadUrl("] where documents.contains(declaration) {
            XCTAssertFalse(
                Self.attributes(before: declaration, in: documents)
                    .contains { $0.hasPrefix("@available") },
                "DocumentBlobContext.downloadUrl must carry no availability attribute"
            )
        }
        XCTAssertFalse(
            Self.attributes(before: "public nonisolated func downloadUrl(", in: manager)
                .contains { $0.hasPrefix("@available") },
            "BlobManager.downloadUrl must carry no availability attribute"
        )
    }

    // MARK: - Behavior 13 — the removed members survive as guided stubs

    /// A read and a result-returning mutator have no honest synchronous form
    /// once the queue lives behind an actor (sponsor, 2026-08-02, Fork 3 →
    /// Option B and Fork 1 → Option A). They stay in the source as
    /// `unavailable, renamed:` stubs so the compiler offers a one-click
    /// migration instead of "no such member", with no executable body.
    func testTheRemovedSynchronousMembersAreGuidedStubs() throws {
        let stubs: [(file: String, declaration: String, renamed: String)] = [
            ("JsBaoClient.swift",
             "public func getBlobUploadConcurrency()", "getBlobUploadConcurrencyAsync()"),
            ("API/DocumentsAPI.swift",
             "public func uploads(documentId: String? = nil)", "uploadsAsync(documentId:)"),
            ("API/DocumentsAPI.swift",
             "public func pauseUpload(blobId: String, documentId: String? = nil)",
             "pauseUploadAsync(blobId:documentId:)"),
            ("API/DocumentsAPI.swift",
             "public func resumeUpload(blobId: String, documentId: String? = nil)",
             "resumeUploadAsync(blobId:documentId:)"),
            ("API/DocumentsAPI.swift",
             "public func getUploadConcurrency()", "getUploadConcurrencyAsync()"),
            ("API/DocumentsAPI.swift", "public func uploads()", "uploadsAsync()"),
            ("API/DocumentsAPI.swift", "public func pauseUpload(blobId: String)",
             "pauseUploadAsync(blobId:)"),
            ("API/DocumentsAPI.swift", "public func resumeUpload(blobId: String)",
             "resumeUploadAsync(blobId:)"),
        ]
        for stub in stubs {
            let source = try Self.clientSource(stub.file)
            let attributes = Self.attributes(before: stub.declaration, in: source)
            XCTAssertTrue(
                attributes.contains("@available(*, unavailable, renamed: \"\(stub.renamed)\")"),
                """
                \(stub.file): `\(stub.declaration)` must be an unavailable stub renamed to \
                `\(stub.renamed)` — attributes: \(attributes)
                """
            )
            let twinName = String(stub.renamed.prefix { $0 != "(" })
            XCTAssertTrue(
                source.contains("func \(twinName)("),
                "\(stub.file): the twin `\(stub.renamed)` the stub points at must exist"
            )
            XCTAssertTrue(
                Self.body(of: stub.declaration, in: source).contains("fatalError("),
                "\(stub.file): `\(stub.declaration)` must have no executable body"
            )
        }
    }

    /// The twins are deliberately *not* same-name `async` overloads: Swift
    /// prefers the `async` overload in an asynchronous context, so a same-name
    /// twin makes every existing un-`await`ed call a compile error — the source
    /// break the window exists to avoid. Pin the reasoning next to the code.
    func testTheTwinNamingRationaleIsRecorded() throws {
        XCTAssertTrue(
            try Self.clientSource("API/DocumentsAPI.swift")
                .contains("Swift prefers an `async` overload"),
            "the reason the twins carry a distinct name must stay written down"
        )
    }

    // MARK: - Behavior 14 — clearCache is async-only

    /// No twin and no synchronous form: a direct holder of the manager is
    /// taking the all-members-async break anyway, and the facade path
    /// (`evictAllLocal`) was already `async`.
    func testClearCacheIsAsyncOnlyWithNoTwin() throws {
        let manager = try Self.clientSource("Internal/BlobManager.swift")
        XCTAssertTrue(manager.contains("public func clearCache()"),
                      "clearCache stays, isolated and therefore async to callers")
        XCTAssertFalse(manager.contains("clearCacheAsync"),
                       "clearCache is async-only — it gets no twin")
        XCTAssertFalse(
            Self.attributes(before: "public func clearCache()", in: manager)
                .contains { $0.hasPrefix("@available") },
            "clearCache is not deprecated — there is nothing to migrate to"
        )
        XCTAssertTrue(
            try Self.code("JsBaoClient.swift").contains("await blobManager.clearCache()"),
            "evictAllLocal must await the isolated clearCache"
        )
    }

    /// And it still does its job: cached bytes are gone afterwards.
    func testClearCacheDropsTheRetainedBytes() async throws {
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: StubTransport { _, _, _, _ in (Data("{}".utf8), 200) }
        )
        let result = try await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))
        let cachedBeforeClear = await manager.hasCachedBytes(documentId: "doc", blobId: result.blobId)
        XCTAssertTrue(cachedBeforeClear)

        await manager.clearCache()
        let cachedAfterClear = await manager.hasCachedBytes(documentId: "doc", blobId: result.blobId)
        XCTAssertFalse(cachedAfterClear)
    }

    // MARK: - Behavior 15 — deinit's safety argument was rewritten

    /// The pre-conversion argument was "the lock makes this read safe", which
    /// says nothing once there is no lock. The rewritten one has to name why an
    /// actor `deinit` may touch isolated state, and has to state the limitation
    /// it cannot work around.
    func testDeinitCarriesTheRewrittenSafetyArgument() throws {
        let source = try Self.clientSource("Internal/BlobManager.swift")
        let argument = try Self.slice(source, from: "/// Cancel the pending queue timer.", to: "deinit {")
        XCTAssertTrue(
            argument.contains("no reference to the actor remains"),
            "the argument must say why no isolated work can race the deinit"
        )
        XCTAssertTrue(
            argument.contains("weakly"),
            "the argument must name the weak capture that keeps a pending timer from holding the actor"
        )
        XCTAssertTrue(
            argument.contains("cannot") && argument.contains("drain the queue"),
            "the argument must state the limitation: deinit cannot drain the queue"
        )
        XCTAssertTrue(
            try Self.code("Internal/BlobManager.swift")
                .contains("deinit {\n        queueTimerTask?.cancel()\n    }"),
            "deinit must still cancel the pending queue timer"
        )
    }

    // MARK: - Helpers

    /// Wait until the manager has parked a queue timer and stopped starting new
    /// ones — the same quiescence `BlobBackoffTests.waitForQuiescentQueue`
    /// waits for, and for the same reason: a timer count or a pending-timer read
    /// taken mid-retry measures the manager's own rotation, not the test's.
    private static func waitForAParkedQueueTimer(
        _ manager: BlobManager,
        timeoutMs: Int = 3000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var last = await manager.queueTimerStartCount
        var stableSamples = 0
        var waited = 0
        while waited < timeoutMs {
            try await Task.sleep(nanoseconds: 25 * 1_000_000)
            waited += 25
            let current = await manager.queueTimerStartCount
            let pending = await manager.hasPendingQueueTimer
            if current == last, pending {
                stableSamples += 1
                if stableSamples >= 3 { return }
            } else {
                stableSamples = 0
                last = current
            }
        }
        XCTFail("the queue never parked a timer within \(timeoutMs)ms", file: file, line: line)
    }

    private static func code(_ relativePath: String) throws -> String {
        try ClientSourceText.code(relativePath)
    }

    private static func clientSource(_ relativePath: String) throws -> String {
        try ClientSourceText.clientSource(relativePath)
    }

    private static func slice(_ source: String, from: String, to: String) throws -> String {
        try ClientSourceText.slice(source, from: from, to: to)
    }

    /// The attribute lines (`@available(...)`, `@discardableResult`, …) attached
    /// to a declaration, skipping the doc comment between them. Doc-comment
    /// prose can therefore never satisfy an attribute check.
    private static func attributes(before declaration: String, in source: String) -> [String] {
        // Consolidated into Helpers/ClientSourceText.swift by #2171, which needs
        // the same scan for the WebSocketManager deprecation window.
        ClientSourceText.attributes(before: declaration, in: source)
    }

    /// The lines of a declaration's body, up to the first line that closes it at
    /// the declaration's own indentation.
    private static func body(of declaration: String, in source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(declaration)
        }) else { return "" }
        let indent = String(lines[index].prefix { $0 == " " })
        var collected: [String] = []
        for line in lines.dropFirst(index + 1) {
            if line == indent + "}" { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }
}
