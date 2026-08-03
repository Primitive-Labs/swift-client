import XCTest
@testable import JsBaoClient

/// #1994 Phase E2 — the `AsyncStream` event surface.
///
/// Server-free: every behavior here is in-process event delivery, so these run
/// against a bare `EventEmitter` or a client constructed with `autoNetwork:
/// false` and an unreachable URL.
final class EventStreamTests: XCTestCase {

    /// A bare client: bootstrapped token, no auto-connect, memory storage —
    /// constructs without any dev server.
    private func makeClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    // MARK: - Behavior 3: every emit reaches the stream, in emit order

    /// A `for await` loop over `stream(for:)` receives every `.status` emit in
    /// the order it was emitted.
    func testStreamDeliversEveryEmitInOrder() async throws {
        let client = makeClient()
        let statuses: [ConnectionStatus] = [.connecting, .connected, .disconnected, .connecting, .connected]
        let before = client.eventEmitter.activeObserverCount

        let stream = client.stream(for: StatusChangedEvent.self)
        let collector = Task { () -> [ConnectionStatus] in
            var seen: [ConnectionStatus] = []
            for await event in stream {
                seen.append(event.status)
                if seen.count == statuses.count { break }
            }
            return seen
        }

        // Emit only once the stream is registered — a stream does not replay
        // events that fired before it opened (unless it asked for replay).
        try await waitForObserverCount(client, atLeast: before + 1)
        for status in statuses {
            client.eventEmitter.emit(StatusChangedEvent(status: status))
        }

        let seen = try await withTimeout(seconds: 5) { await collector.value }
        XCTAssertEqual(seen, statuses, "the stream must deliver every emit in emit order")
    }

    // MARK: - Behavior 4: independent consumers each see every occurrence

    /// Two streams of the same event are independent — neither steals the
    /// other's elements.
    func testTwoConsumersEachReceiveEveryOccurrence() async throws {
        let client = makeClient()
        let emitCount = 20
        let before = client.eventEmitter.activeObserverCount

        let first = client.stream(for: DocumentClosedEvent.self)
        let second = client.stream(for: DocumentClosedEvent.self)

        func drain(_ stream: AsyncStream<DocumentClosedEvent>) -> Task<[String], Never> {
            Task {
                var ids: [String] = []
                for await event in stream {
                    ids.append(event.documentId)
                    if ids.count == emitCount { break }
                }
                return ids
            }
        }
        let firstTask = drain(first)
        let secondTask = drain(second)

        try await waitForObserverCount(client, atLeast: before + 2)
        let expected = (0..<emitCount).map { "doc-\($0)" }
        for id in expected {
            client.eventEmitter.emit(DocumentClosedEvent(documentId: id))
        }

        let firstIds = try await withTimeout(seconds: 5) { await firstTask.value }
        let secondIds = try await withTimeout(seconds: 5) { await secondTask.value }
        XCTAssertEqual(firstIds, expected, "consumer 1 must see every occurrence")
        XCTAssertEqual(secondIds, expected, "consumer 2 must see every occurrence — no element stealing")
    }

    // MARK: - Behavior 5: observeOnMainActor runs the handler on the main actor

    /// The handler runs on the main actor with no `Task { @MainActor in }` at the
    /// call site, even though the emit happens off the main actor.
    func testObserveOnMainActorRunsHandlerOnMainActor() async throws {
        let client = makeClient()
        let sawMainActor = ThreadSafeBox<[Bool]>([])
        let received = expectation(description: "main-actor handler ran")

        let subscription = client.observeOnMainActor(SyncEvent.self) { event in
            // `MainActor.assertIsolated` would trap on failure and take the
            // whole suite down; record the fact instead so the assertion is a
            // normal test failure.
            sawMainActor.mutate { $0.append(Thread.isMainThread) }
            XCTAssertEqual(event.documentId, "doc-main")
            received.fulfill()
        }
        defer { subscription.cancel() }

        // Emit from a background queue so a handler that did NOT hop would run
        // off the main thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                client.eventEmitter.emit(SyncEvent(documentId: "doc-main", synced: true))
                continuation.resume()
            }
        }

        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(sawMainActor.value, [true],
                       "observeOnMainActor must deliver on the main actor even for an off-main emit")
    }

    /// Cancelling on the main actor stops a hop the emit has already enqueued.
    ///
    /// Cancelling only removes the emitter-side callback, so without the
    /// delivery gate a handler could still run — and mutate its owner's UI —
    /// after that owner cancelled or re-keyed the subscription.
    func testObserveOnMainActorCancelStopsAnAlreadyEnqueuedHop() async throws {
        let client = makeClient()
        let delivered = AtomicInt()

        let subscription = client.observeOnMainActor(SyncEvent.self) { _ in
            delivered.increment()
        }

        // Emit and cancel inside one main-actor block: the emit enqueues the hop
        // onto the main queue behind this block, and `cancel()` runs before the
        // queue reaches it.
        await MainActor.run {
            client.eventEmitter.emit(SyncEvent(documentId: "doc-cancel", synced: true))
            subscription.cancel()
        }

        // Two more main-queue turns, so anything the emit enqueued has run (or
        // been gated) before the assertion.
        await MainActor.run {}
        try await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {}

        XCTAssertEqual(delivered.value, 0,
                       "cancelling on the main actor must stop a hop the emit already enqueued")
    }

    /// Handlers for *different* event types run in emit order. The debug
    /// inspector's timeline depends on this: it stamps its own timestamp when
    /// the handler runs, so a reordered delivery reads as reordered client work.
    func testObserveOnMainActorPreservesCrossEventOrder() async throws {
        let client = makeClient()
        let emits = 40
        let seen = ThreadSafeBox<[String]>([])
        let done = expectation(description: "every hop ran")
        done.expectedFulfillmentCount = emits

        let statusSubscription = client.observeOnMainActor(StatusChangedEvent.self) { _ in
            seen.mutate { $0.append("status") }
            done.fulfill()
        }
        let syncSubscription = client.observeOnMainActor(SyncEvent.self) { _ in
            seen.mutate { $0.append("sync") }
            done.fulfill()
        }
        defer {
            statusSubscription.cancel()
            syncSubscription.cancel()
        }

        let expected = (0..<emits).map { $0.isMultiple(of: 2) ? "status" : "sync" }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for index in 0..<emits {
                    if index.isMultiple(of: 2) {
                        client.eventEmitter.emit(StatusChangedEvent(status: .connected))
                    } else {
                        client.eventEmitter.emit(SyncEvent(documentId: "doc-order", synced: true))
                    }
                }
                continuation.resume()
            }
        }

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(seen.value, expected,
                       "observeOnMainActor handlers must run in emit order across event types")
    }

    // MARK: - Behavior 6: ending, cancelling, or dropping frees the registry entry

    /// Breaking out of a `for await` loop removes the registry entry.
    func testEndingLoopRemovesObserver() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeObserverCount

        let done = expectation(description: "loop ended")
        let task = Task { () -> Int in
            // Counted, so the assertion below proves the loop exited via `break`
            // after receiving an element — a stream that finished with nothing
            // delivered would also reach `done.fulfill()`.
            var received = 0
            for await _ in client.stream(for: DocumentOpenedEvent.self) {
                received += 1
                break
            }
            done.fulfill()
            return received
        }

        try await waitForObserverCount(client, atLeast: before + 1)
        client.eventEmitter.emit(DocumentOpenedEvent(documentId: "doc-1"))
        await fulfillment(of: [done], timeout: 5)
        let received = await task.value
        XCTAssertEqual(received, 1, "the loop must have broken out after an element, not on a finished stream")

        try await waitForObserverCount(client, equalTo: before)
        XCTAssertEqual(client.eventEmitter.activeObserverCount, before,
                       "ending the loop must remove the registry entry")
    }

    /// Cancelling the enclosing task removes the registry entry.
    func testCancellingTaskRemovesObserver() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeObserverCount

        let task = Task {
            for await _ in client.stream(for: DocumentOpenedEvent.self) {
                // Never breaks on its own — only cancellation ends this.
            }
        }
        try await waitForObserverCount(client, atLeast: before + 1)

        task.cancel()
        _ = await task.value

        try await waitForObserverCount(client, equalTo: before)
        XCTAssertEqual(client.eventEmitter.activeObserverCount, before,
                       "cancelling the task must remove the registry entry")
    }

    /// Dropping the stream without ever iterating it removes the registry entry.
    func testDroppingStreamRemovesObserver() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeObserverCount

        do {
            let stream = client.stream(for: DocumentOpenedEvent.self)
            XCTAssertEqual(client.eventEmitter.activeObserverCount, before + 1)
            _ = stream
        }

        try await waitForObserverCount(client, equalTo: before)
        XCTAssertEqual(client.eventEmitter.activeObserverCount, before,
                       "dropping the stream must remove the registry entry")
    }

    /// Ending the loop over a stream value the caller *retained* does NOT
    /// unsubscribe — the value still holds the stream. Releasing it does.
    ///
    /// This is `AsyncStream`'s own lifetime model, not something the
    /// consumption-counting wrapper adds: `testBareAsyncStreamHasTheSameRetainedLifetime`
    /// below pins the identical behavior on a plain `AsyncStream`. The doc
    /// comment on `stream(for:buffering:replayingLatest:)` states it.
    func testRetainedStreamStaysSubscribedUntilTheValueIsReleased() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeObserverCount

        do {
            let retained = client.stream(for: DocumentOpenedEvent.self)
            XCTAssertEqual(client.eventEmitter.activeObserverCount, before + 1)

            client.eventEmitter.emit(DocumentOpenedEvent(documentId: "doc-1"))
            var received = 0
            for await _ in retained {
                received += 1
                break
            }
            XCTAssertEqual(received, 1, "the buffered element must be delivered before the break")

            // Long enough for a termination that was going to happen to have
            // happened — the non-retained cases above settle well inside this.
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(client.eventEmitter.activeObserverCount, before + 1,
                           "a retained stream value keeps the subscription alive after the loop ends")
        }

        try await waitForObserverCount(client, equalTo: before)
        XCTAssertEqual(client.eventEmitter.activeObserverCount, before,
                       "releasing the retained stream value must remove the registry entry")
    }

    /// The reference behavior the test above is measured against: a plain
    /// `AsyncStream` also keeps its termination handler unrun while the stream
    /// value is retained, however the loop over it ended.
    func testBareAsyncStreamHasTheSameRetainedLifetime() async throws {
        let terminations = AtomicInt()

        do {
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            continuation.onTermination = { _ in terminations.increment() }
            continuation.yield(1)

            var received = 0
            for await _ in stream {
                received += 1
                break
            }
            XCTAssertEqual(received, 1)

            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(terminations.value, 0,
                           "AsyncStream does not terminate while the stream value is retained")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminations.value, 1,
                       "releasing the retained AsyncStream terminates it")
    }

    /// A `for await` loop over a stream from a client that goes away must exit
    /// rather than hang — every continuation is finished on teardown.
    func testDestroyFinishesOpenStreams() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeObserverCount
        let stream = client.stream(for: DocumentOpenedEvent.self)

        let exited = Task { () -> Bool in
            for await _ in stream {}
            return true
        }
        try await waitForObserverCount(client, atLeast: before + 1)

        await client.destroy()

        let didExit = try await withTimeout(seconds: 5) { await exited.value }
        XCTAssertTrue(didExit, "destroy() must finish open streams so awaiting loops exit")
    }

    // MARK: - Behavior 7: nextEvent returns the first match, throws on timeout

    /// `nextEvent` returns the first event the predicate accepts, ignoring the
    /// ones it rejects.
    func testNextEventReturnsFirstMatch() async throws {
        let client = makeClient()
        // A fresh client can already hold internal listeners, so the baseline
        // has to be captured: waiting for "at least 1" would pass before
        // `nextEvent` registered and let the emit race ahead of the wait.
        let before = client.eventEmitter.activeHandlerCount

        let waiter = Task { () -> DocumentLoadedEvent in
            try await client.nextEvent(DocumentLoadedEvent.self, timeout: 5) { $0.documentId == "wanted" }
        }
        // The wait registers a callback, not a stream.
        try await waitForHandlerCount(client, atLeast: before + 1)

        client.eventEmitter.emit(loadedEvent(documentId: "other"))
        client.eventEmitter.emit(loadedEvent(documentId: "wanted"))

        let event = try await withTimeout(seconds: 5) { try await waiter.value }
        XCTAssertEqual(event.documentId, "wanted",
                       "nextEvent must skip non-matching events and return the first match")
    }

    /// `nextEvent` throws `JsBaoError(code: .unavailable)` on timeout — parity
    /// with the deprecated `waitForEvent`.
    func testNextEventThrowsUnavailableOnTimeout() async throws {
        let client = makeClient()
        do {
            _ = try await client.nextEvent(DocumentOpenedEvent.self, timeout: 0.2)
            XCTFail("expected a timeout")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable, "timeout must surface as .unavailable")
        }
    }

    /// Cancelling the calling task ends the wait: the caller throws
    /// `CancellationError` and the handler is unregistered, rather than both
    /// staying live for the rest of the timeout.
    func testNextEventHonoursTaskCancellation() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeHandlerCount

        let waiter = Task { () -> DocumentOpenedEvent in
            // A long timeout, so anything that ends this wait promptly can only
            // be the cancellation.
            try await client.nextEvent(DocumentOpenedEvent.self, timeout: 60)
        }
        try await waitForHandlerCount(client, atLeast: before + 1)
        waiter.cancel()

        do {
            _ = try await withTimeout(seconds: 5) { try await waiter.value }
            XCTFail("expected the cancelled wait to throw")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForHandlerCount(client, equalTo: before)
    }

    /// The wait unsubscribes on both paths — a resolved wait and a timed-out one
    /// must both leave the handler count where they found it.
    func testNextEventCleansUpItsSubscription() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeHandlerCount

        let waiter = Task { try await client.nextEvent(DocumentOpenedEvent.self, timeout: 5) }
        try await waitForHandlerCount(client, atLeast: before + 1)
        client.eventEmitter.emit(DocumentOpenedEvent(documentId: "doc-1"))
        _ = try await withTimeout(seconds: 5) { try await waiter.value }
        try await waitForHandlerCount(client, equalTo: before)

        _ = try? await client.nextEvent(DocumentOpenedEvent.self, timeout: 0.2)
        try await waitForHandlerCount(client, equalTo: before)
        XCTAssertEqual(client.eventEmitter.activeHandlerCount, before,
                       "a timed-out wait must also remove its handler")
    }

    // MARK: - Behavior 8: buffering policy and the high-water warning

    /// `.bufferingNewest(1)` keeps at most one element: a stalled consumer that
    /// resumes sees only the most recent event, never a backlog.
    func testBufferingNewestOneKeepsOnlyTheLatest() async throws {
        let client = makeClient()
        let stream = client.stream(for: DocumentOpenedEvent.self, buffering: .bufferingNewest(1))
        var iterator = stream.makeAsyncIterator()

        // Nothing is draining yet, so all 50 land in the (1-element) buffer.
        for i in 0..<50 {
            client.eventEmitter.emit(DocumentOpenedEvent(documentId: "doc-\(i)"))
        }

        let first = await iterator.next()
        XCTAssertEqual(first?.documentId, "doc-49",
                       ".bufferingNewest(1) must retain only the most recent element")

        // And the buffer is now empty rather than holding the other 49.
        client.eventEmitter.emit(DocumentOpenedEvent(documentId: "doc-next"))
        let second = await iterator.next()
        XCTAssertEqual(second?.documentId, "doc-next",
                       "the buffer must never have exceeded one element")
    }

    /// `.unbounded` (the default) drops nothing: a stalled consumer that resumes
    /// still sees every event, in order.
    func testUnboundedBufferingDropsNothing() async throws {
        let client = makeClient()
        let stream = client.stream(for: DocumentOpenedEvent.self)
        var iterator = stream.makeAsyncIterator()

        let expected = (0..<200).map { "doc-\($0)" }
        for id in expected {
            client.eventEmitter.emit(DocumentOpenedEvent(documentId: id))
        }

        var seen: [String] = []
        for _ in expected {
            guard let event = await iterator.next() else { break }
            seen.append(event.documentId)
        }
        XCTAssertEqual(seen, expected, ".unbounded must drop nothing")
    }

    /// The high-water warning fires once, at 1,000 undrained elements, and the
    /// meter's pending count tracks the drain.
    func testHighWaterWarningFiresOncePerStream() {
        let meter = StreamMeter(eventKey: "awareness", logger: nil)
        XCTAssertFalse(meter.didWarn)

        for _ in 0..<(StreamMeter.highWaterMark - 1) { meter.noteYield() }
        XCTAssertFalse(meter.didWarn, "the warning must not fire below the high-water mark")
        XCTAssertEqual(meter.pendingCount, StreamMeter.highWaterMark - 1)

        meter.noteYield()
        XCTAssertTrue(meter.didWarn, "the warning must fire at the high-water mark")

        // Further yields do not re-warn, and consumption decrements.
        for _ in 0..<500 { meter.noteYield() }
        meter.noteConsumed()
        XCTAssertEqual(meter.pendingCount, StreamMeter.highWaterMark + 500 - 1)
        XCTAssertTrue(meter.didWarn)
    }

    /// The meter is wired to the live stream: yields raise the pending count and
    /// draining lowers it, so a stalled consumer is what actually trips the
    /// warning.
    ///
    /// Asserted through the emitter's `lastStreamMeter` hook, because the meter
    /// has no other observable output — its only effect is a debug-level log.
    /// Without these assertions both `noteYield()` and `noteConsumed()` could be
    /// deleted and the suite would stay green.
    func testStreamMeterTracksLiveYieldAndDrain() async throws {
        let emitter = EventEmitter(logger: nil)
        let stream = emitter.makeStream(
            for: DocumentOpenedEvent.self,
            buffering: .unbounded,
            replayingLatest: false
        )
        let meter = try XCTUnwrap(emitter.lastStreamMeter, "makeStream must expose its meter to tests")
        var iterator = stream.makeAsyncIterator()

        for i in 0..<10 {
            emitter.emit(DocumentOpenedEvent(documentId: "doc-\(i)"))
        }
        XCTAssertEqual(meter.pendingCount, 10,
                       "ten undrained elements must be counted as outstanding")

        for _ in 0..<10 {
            _ = await iterator.next()
        }
        // All ten drained, so nothing is outstanding — the accounting the
        // high-water warning depends on.
        XCTAssertEqual(meter.pendingCount, 0, "draining must bring the pending count back to zero")
        XCTAssertFalse(meter.didWarn, "ten elements is far below the high-water mark")
        XCTAssertEqual(emitter.activeObserverCount, 1)
    }

    /// A bounded policy drops rather than buffers, so a stalled consumer on
    /// `.bufferingNewest(1)` must never look like it is falling behind.
    ///
    /// Counting yields instead of buffered elements made `pending` grow without
    /// limit here, and the warning then told a consumer already on
    /// `.bufferingNewest(1)` to switch to `.bufferingNewest(1)`.
    func testBoundedBufferingDoesNotAccumulatePending() async throws {
        let emitter = EventEmitter(logger: nil)
        let stream = emitter.makeStream(
            for: DocumentOpenedEvent.self,
            buffering: .bufferingNewest(1),
            replayingLatest: false
        )
        let meter = try XCTUnwrap(emitter.lastStreamMeter)
        var iterator = stream.makeAsyncIterator()

        for i in 0..<(StreamMeter.highWaterMark * 2) {
            emitter.emit(DocumentOpenedEvent(documentId: "doc-\(i)"))
        }
        XCTAssertEqual(meter.pendingCount, 1,
                       ".bufferingNewest(1) holds one element however many were yielded")
        XCTAssertFalse(meter.didWarn,
                       "a dropping policy cannot fall behind, so the warning must not fire")

        let latest = await iterator.next()
        XCTAssertEqual(latest?.documentId, "doc-\(StreamMeter.highWaterMark * 2 - 1)",
                       ".bufferingNewest(1) must keep the newest element")
        XCTAssertEqual(meter.pendingCount, 0)
    }

    // MARK: - Behavior 11: replayingLatest

    /// A consumer that opens a `.status` stream after the connection was already
    /// established gets the last-known status immediately when it asks for
    /// replay.
    func testReplayingLatestDeliversLastKnownStatus() async throws {
        let client = makeClient()
        client.eventEmitter.emit(StatusChangedEvent(status: .connected))

        let stream = client.stream(for: StatusChangedEvent.self, replayingLatest: true)
        var iterator = stream.makeAsyncIterator()
        let replayed = await iterator.next()
        XCTAssertEqual(replayed?.status, .connected,
                       "replayingLatest must deliver the status that fired before the stream opened")
    }

    /// The default does not replay: a stream opened after the event waits for the
    /// next one.
    func testWithoutReplayNothingIsRedelivered() async throws {
        let client = makeClient()
        client.eventEmitter.emit(StatusChangedEvent(status: .connected))

        let before = client.eventEmitter.activeObserverCount
        let stream = client.stream(for: StatusChangedEvent.self)
        var iterator = stream.makeAsyncIterator()

        let next = Task { await iterator.next() }
        try await waitForObserverCount(client, atLeast: before + 1)
        client.eventEmitter.emit(StatusChangedEvent(status: .disconnected))

        let event = try await withTimeout(seconds: 5) { await next.value }
        XCTAssertEqual(event?.status, .disconnected,
                       "without replay the stream must start at the next emit, not the previous one")
    }

    /// Replay is only offered for the state-like events. A one-shot event is not
    /// retained, so asking for replay is harmless but delivers nothing — the
    /// stream simply waits for the next occurrence.
    func testReplayIsNotOfferedForOneShotEvents() async throws {
        XCTAssertFalse(DocumentLoadedEvent.isReplayable)
        XCTAssertFalse(BlobUploadFailedEvent.isReplayable)
        XCTAssertTrue(StatusChangedEvent.isReplayable)
        XCTAssertTrue(NetworkModeEvent.isReplayable)
        XCTAssertTrue(AuthStateEvent.isReplayable)

        let client = makeClient()
        client.eventEmitter.emit(loadedEvent(documentId: "already-loaded"))

        let before = client.eventEmitter.activeObserverCount
        let stream = client.stream(for: DocumentLoadedEvent.self, replayingLatest: true)
        var iterator = stream.makeAsyncIterator()
        let next = Task { await iterator.next() }
        try await waitForObserverCount(client, atLeast: before + 1)
        client.eventEmitter.emit(loadedEvent(documentId: "next-one"))

        let event = try await withTimeout(seconds: 5) { await next.value }
        XCTAssertEqual(event?.documentId, "next-one",
                       "a one-shot event's latest value is not retained, so nothing is replayed")
    }

    /// The retained set is exactly the three client-global state events, and
    /// nothing joins it without a deliberate change here.
    ///
    /// Retention is one slot per event *key*, which constrains what may opt in
    /// two ways: a high-frequency event (`AwarenessEvent`) would start holding a
    /// payload for the client's lifetime, and an event scoped to a subject
    /// (`DocumentSyncStateChangedEvent`, per-document) would replay whichever
    /// subject changed last rather than the one the consumer asked about.
    func testReplayableSetIsExactlyTheClientGlobalStateEvents() {
        XCTAssertEqual(
            EventEmitter.replayableEventKeys,
            Set([
                JsBaoEvent.status.rawValue,
                JsBaoEvent.networkMode.rawValue,
                JsBaoEvent.authState.rawValue,
            ]),
            "adding a replayable event needs a deliberate change here: retention is one slot per key, so per-subject and high-frequency events must stay out"
        )
        XCTAssertFalse(DocumentSyncStateChangedEvent.isReplayable,
                       "per-document sync state must not share one global retention slot")
        XCTAssertFalse(AwarenessEvent.isReplayable)
    }

    /// The replayed value is never overtaken by an emit that lands while the
    /// stream is being opened.
    ///
    /// The replay used to be yielded after the registry lock was released, so an
    /// emit in that window reached the newly registered entry first and the
    /// consumer ended on the *older* value — a `replayingLatest: true` status
    /// consumer would then sit on a stale status until the next transition.
    func testReplayIsNotOvertakenByAConcurrentEmit() async throws {
        for _ in 0..<100 {
            var seen: [ConnectionStatus] = []
            for await event in Self.raceReplayAgainstConcurrentEmit() {
                seen.append(event.status)
            }
            XCTAssertNotEqual(
                seen, [.disconnected, .connected],
                "the replayed value must not be delivered after a newer concurrent emit"
            )
        }
    }

    /// Open a `replayingLatest: true` stream while a second thread emits a newer
    /// value, then finish the stream so the caller can drain exactly what was
    /// buffered — no timing budget, no flake.
    ///
    /// Synchronous on purpose: `DispatchSemaphore.wait()` is unavailable from an
    /// async context.
    private static func raceReplayAgainstConcurrentEmit() -> AsyncStream<StatusChangedEvent> {
        let emitter = EventEmitter(logger: nil)
        emitter.emit(StatusChangedEvent(status: .connected))

        let racerStarted = DispatchSemaphore(value: 0)
        let racerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            racerStarted.signal()
            emitter.emit(StatusChangedEvent(status: .disconnected))
            racerFinished.signal()
        }

        racerStarted.wait()
        let stream = emitter.makeStream(
            for: StatusChangedEvent.self,
            buffering: .unbounded,
            replayingLatest: true
        )
        racerFinished.wait()
        emitter.finishAllStreams()
        return stream
    }

    /// A stream opened after the client tore down finishes immediately rather
    /// than registering and waiting forever, and does not replay a value from
    /// before the teardown.
    func testStreamOpenedAfterTeardownFinishesAndDoesNotReplay() async throws {
        let emitter = EventEmitter(logger: nil)
        emitter.emit(StatusChangedEvent(status: .connected))
        emitter.finishAllStreams()

        let stream = emitter.makeStream(
            for: StatusChangedEvent.self,
            buffering: .unbounded,
            replayingLatest: true
        )
        var seen: [ConnectionStatus] = []
        for await event in stream { seen.append(event.status) }

        XCTAssertEqual(seen, [], "a retained value must not outlive teardown")
        XCTAssertEqual(emitter.activeObserverCount, 0,
                       "a stream opened after teardown must not register an entry")
    }

    // MARK: - Edge case: re-entrant emit under the shim must not deadlock

    /// The registry lock is released before fan-out, so a legacy `on()` callback
    /// that itself emits does not deadlock — and its nested emit still reaches a
    /// stream consumer.
    @available(*, deprecated, message: "Deprecated context: exercises the `on` shim on purpose (#1994).")
    func testReentrantEmitFromCallbackDoesNotDeadlock() async throws {
        let emitter = EventEmitter()
        let nested = emitter.makeStream(
            for: DocumentClosedEvent.self,
            buffering: .unbounded,
            replayingLatest: false
        )
        var iterator = nested.makeAsyncIterator()

        let sub = emitter.on(.documentOpened) { (event: DocumentOpenedEvent) in
            emitter.emit(DocumentClosedEvent(documentId: "nested-\(event.documentId)"))
        }
        defer { sub.cancel() }

        assertCompletes(within: 5, "re-entrant emit from an on() callback") {
            emitter.emit(DocumentOpenedEvent(documentId: "doc-1"))
        }

        let event = await iterator.next()
        XCTAssertEqual(event?.documentId, "nested-doc-1",
                       "the nested emit must reach the stream consumer")
    }

    /// Opening and dropping streams while emits are in flight must not deadlock
    /// or crash, and must leave no registry entry behind.
    ///
    /// The completion (no deadlock) and the absence of a crash are what
    /// `assertCompletes` covers; the count assertion is what proves the dropped
    /// streams actually deregistered rather than accumulating.
    func testEmitRacingCancellationIsSafe() {
        let emitter = EventEmitter()
        assertCompletes(within: 10, "emit racing stream cancellation") {
            DispatchQueue.concurrentPerform(iterations: 200) { index in
                if index.isMultiple(of: 2) {
                    let stream = emitter.makeStream(
                        for: DocumentOpenedEvent.self,
                        buffering: .unbounded,
                        replayingLatest: false
                    )
                    _ = stream
                } else {
                    emitter.emit(DocumentOpenedEvent(documentId: "doc-\(index)"))
                }
            }
        }

        // `onTermination` runs asynchronously, so poll rather than read once.
        let deadline = Date().addingTimeInterval(5)
        while emitter.activeObserverCount != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(emitter.activeObserverCount, 0,
                       "every dropped stream must have removed its registry entry")
    }

    // MARK: - Edge case: cross-event ordering is per-stream, not total

    /// Two streams give per-stream FIFO but no order relative to each other.
    /// This is a deliberate behavior change from `on()`'s synchronous fan-out;
    /// the assertion pins the guarantee that IS offered.
    func testPerStreamOrderingIsFifo() async throws {
        let client = makeClient()
        let before = client.eventEmitter.activeObserverCount
        let opened = client.stream(for: DocumentOpenedEvent.self)
        let closed = client.stream(for: DocumentClosedEvent.self)
        try await waitForObserverCount(client, atLeast: before + 2)

        // Interleave the two events; each stream must see ITS OWN in emit order.
        for i in 0..<10 {
            client.eventEmitter.emit(DocumentOpenedEvent(documentId: "open-\(i)"))
            client.eventEmitter.emit(DocumentClosedEvent(documentId: "close-\(i)"))
        }

        var openedIds: [String] = []
        var openedIterator = opened.makeAsyncIterator()
        for _ in 0..<10 {
            guard let event = await openedIterator.next() else { break }
            openedIds.append(event.documentId)
        }
        var closedIds: [String] = []
        var closedIterator = closed.makeAsyncIterator()
        for _ in 0..<10 {
            guard let event = await closedIterator.next() else { break }
            closedIds.append(event.documentId)
        }

        XCTAssertEqual(openedIds, (0..<10).map { "open-\($0)" })
        XCTAssertEqual(closedIds, (0..<10).map { "close-\($0)" })
    }

    // MARK: - Behavior 10: EventSubscription cancels exactly once, race-free

    /// `cancel()` racing `deinit` (and racing itself) runs the cancel closure
    /// exactly once. Run under `swift-client/scripts/tsan-gate.sh` this is also
    /// the ThreadSanitizer regression for the `EventSubscription.cancellation`
    /// baseline entry.
    func testEventSubscriptionCancelsExactlyOnceUnderConcurrency() {
        let counts = ThreadSafeBox<[Int]>([])

        assertCompletes(within: 30, "concurrent EventSubscription cancel/deinit") {
            DispatchQueue.concurrentPerform(iterations: 500) { _ in
                let calls = AtomicInt()
                // The subscription lives in a box rather than a local, so the
                // racing thread can drop the last reference — and run `deinit`
                // — while this thread is inside `cancel()`. A block that
                // captured a local `subscription` strongly could not do that:
                // it would pin the object alive until the block finished, which
                // makes the race cancel-vs-cancel, not cancel-vs-deinit.
                let box = ThreadSafeBox<EventSubscription?>(EventSubscription { calls.increment() })
                let dropped = DispatchSemaphore(value: 0)
                // A real thread rather than `DispatchQueue.global().async`: this
                // iteration blocks on `dropped` below, and blocking a
                // `concurrentPerform` worker while waiting on the same
                // non-overcommit pool can starve the block that would signal it.
                let dropper = Thread {
                    box.mutate { $0 = nil }
                    dropped.signal()
                }
                dropper.start()
                box.value?.cancel()
                // Wait for the racing thread instead of sleeping: the read below
                // then cannot miss a second run, and there is no timing budget
                // to blow under 500-way contention.
                dropped.wait()
                counts.mutate { $0.append(calls.value) }
            }
        }

        let observed = Set(counts.value)
        XCTAssertEqual(observed, [1],
                       "the cancel closure must run exactly once however cancel() and deinit interleave; saw \(observed.sorted())")
    }

    /// A `SubscriptionHolder` cancelled before its subscription is stored still
    /// cancels it — the leak the `openDocument` `.sync` listener would otherwise
    /// have when its handler fires before `subscribe` returns.
    func testSubscriptionHolderCancelBeforeSetStillCancels() {
        let calls = AtomicInt()
        let holder = SubscriptionHolder()
        holder.cancel()
        holder.set(EventSubscription { calls.increment() })
        XCTAssertEqual(calls.value, 1,
                       "a cancel that arrives before set() must still cancel the subscription")
    }

    // MARK: - Helpers

    private func loadedEvent(documentId: String) -> DocumentLoadedEvent {
        DocumentLoadedEvent(
            documentId: documentId,
            source: "server",
            hadData: true,
            bytes: 1,
            elapsedMs: 1
        )
    }

    private func waitForObserverCount(
        _ client: JsBaoClient,
        atLeast target: Int? = nil,
        equalTo exact: Int? = nil
    ) async throws {
        try await poll(
            description: "observer count \(target.map { "≥ \($0)" } ?? "== \(exact ?? 0)")",
            current: { client.eventEmitter.activeObserverCount },
            atLeast: target,
            equalTo: exact
        )
    }

    private func waitForHandlerCount(
        _ client: JsBaoClient,
        atLeast target: Int? = nil,
        equalTo exact: Int? = nil
    ) async throws {
        try await poll(
            description: "handler count \(target.map { "≥ \($0)" } ?? "== \(exact ?? 0)")",
            current: { client.eventEmitter.activeHandlerCount },
            atLeast: target,
            equalTo: exact
        )
    }

    private func poll(
        description: String,
        current: @escaping @Sendable () -> Int,
        atLeast: Int?,
        equalTo: Int?
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let value = current()
            if let atLeast, value >= atLeast { return }
            if let equalTo, value == equalTo { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(description); saw \(current())")
    }

    /// Bound an await so a regression fails the test instead of hanging the
    /// suite (the async counterpart of `assertCompletes`).
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw JsBaoError(code: .unavailable, message: "timed out after \(seconds)s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Minimal thread-safe counter shared by the concurrency assertions above.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}
