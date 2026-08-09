import XCTest
@testable import JsBaoClient

/// Unit tests for `EventEmitter`'s thread safety after the
/// `NSLock.lock()/unlock()` → scoped `withLock` conversion (issue #1910).
///
/// `EventEmitter`'s public ops (`on`/`onAny`/`emit`/`removeAll`) are
/// synchronous, so these use the synchronous `assertCompletes` watchdog
/// (fail-not-hang on a lock-ordering deadlock) directly.
final class EventEmitterTests: XCTestCase {

    /// Payload for the emits below. `.cacheUpdated` is an arbitrary choice —
    /// these tests are about the registry's thread safety, not the event.
    private static let sampleEvent = CacheUpdatedEvent(key: "k", updatedAt: "2026-01-01", value: 1)

    /// A minimal thread-safe counter for asserting handler-invocation
    /// conservation across concurrent subscribers.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// Fan-out concurrent subscriptions across many threads, then emit once.
    /// The invariant is handler conservation: every subscription registered
    /// must receive exactly one payload (count == number of subscribers).
    /// Wrapped in `assertCompletes` so a lock-ordering regression fails the
    /// test rather than hanging the suite.
    func testConcurrentSubscribeThenEmitDeliversToAll() {
        let emitter = EventEmitter()
        let counter = AtomicCounter()
        let subscriberCount = 300

        // Subscriptions cancel on deinit, so retain them for the lifetime of
        // the test — otherwise the handler is removed the instant the returned
        // `EventSubscription` is discarded.
        let subscriptions = LockedBox([EventSubscription]())

        assertCompletes(within: 5, "concurrent EventEmitter subscribe") {
            DispatchQueue.concurrentPerform(iterations: subscriberCount) { _ in
                let sub = emitter.subscribe(CacheUpdatedEvent.self) { _ in counter.increment() }
                subscriptions.withValue { $0.append(sub) }
            }
        }

        XCTAssertEqual(subscriptions.value.count, subscriberCount)

        emitter.emit(Self.sampleEvent)
        XCTAssertEqual(counter.value, subscriberCount, "every concurrently-registered handler must fire exactly once")

        // Keep the subscriptions alive until here.
        subscriptions.withValue { $0.removeAll() }
    }

    /// Race subscribe / emit / removeAll from many threads at once. The
    /// invariant here is liveness (no deadlock) and no crash — the emitter's
    /// internal dictionary must stay consistent under concurrent mutation.
    func testConcurrentSubscribeEmitRemoveIsDeadlockFree() {
        let emitter = EventEmitter()
        let counter = AtomicCounter()

        assertCompletes(within: 5, "concurrent EventEmitter subscribe/emit/removeAll") {
            DispatchQueue.concurrentPerform(iterations: 400) { i in
                switch i % 4 {
                case 0:
                    let sub = emitter.subscribe(CacheUpdatedEvent.self) { _ in counter.increment() }
                    sub.cancel()
                case 1:
                    emitter.emit(Self.sampleEvent)
                case 2:
                    emitter.removeAll(for: .cacheUpdated)
                default:
                    emitter.removeAll()
                }
            }
        }
    }

    // MARK: - Re-entrant release from a handler's deinit (issue #2574)

    /// A consumer kept alive only by its own handler closure, which cancels the
    /// subscriptions it owns from `deinit` — an ordinary Swift shape (a view
    /// model that subscribes with a strong `self` and tears its subscriptions
    /// down when it goes away).
    ///
    /// Releasing that handler therefore runs `deinit` on the releasing thread,
    /// and `deinit` re-enters the emitter. Everything that drops a handler
    /// entry must do so with the emitter's lock released, or the thread parks
    /// on a non-recursive `NSLock` it already holds.
    private final class DeinitCancellingConsumer {
        /// Subscriptions this consumer owns and cancels on the way out.
        private var owned: [EventSubscription] = []
        private let deinitCount: AtomicCounter

        /// - Parameter retainingSubscription: when non-nil, the strongly
        ///   capturing subscription is handed to the caller instead of being
        ///   owned here — so the caller can cancel it and release this object
        ///   from inside `removeClosure`.
        init(
            emitter: EventEmitter,
            deinitCount: AtomicCounter,
            retainingSubscription: inout EventSubscription?,
            handOffRetainingSubscription: Bool
        ) {
            self.deinitCount = deinitCount

            // Strong `self`: from here on the emitter's handler is the only
            // outside reference keeping this object alive.
            let strongSub = emitter.subscribe(CacheUpdatedEvent.self) { _ in self.noop() }
            if handOffRetainingSubscription {
                retainingSubscription = strongSub
            } else {
                owned.append(strongSub)
            }

            // A second subscription this consumer owns and cancels in `deinit`.
            // Weak capture, so it is not what keeps the object alive.
            owned.append(emitter.subscribe(CacheUpdatedEvent.self) { [weak self] _ in self?.noop() })
        }

        private func noop() {}

        deinit {
            owned.forEach { $0.cancel() }
            deinitCount.increment()
        }
    }

    /// Read `activeHandlerCount` under the watchdog rather than directly.
    /// On a regression the deadlocked thread still holds the emitter's lock, so
    /// a plain read from the test thread would hang the suite instead of
    /// failing this test — the exact symptom issue #2574 describes.
    private func handlerCount(
        of emitter: EventEmitter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int? {
        let box = LockedBox<Int?>(nil)
        assertCompletes(within: 3, "read EventEmitter.activeHandlerCount", file: file, line: line) {
            let count = emitter.activeHandlerCount
            box.value = count
        }
        return box.value
    }

    /// `removeAll()` releases every handler. When one of them was the last
    /// reference to a consumer that cancels in `deinit`, the cancel re-enters
    /// the emitter — which must not happen under the lock.
    func testRemoveAllCompletesWhenHandlerReleaseCancelsInDeinit() {
        let emitter = EventEmitter()
        let deinits = AtomicCounter()
        var unused: EventSubscription?
        _ = DeinitCancellingConsumer(
            emitter: emitter,
            deinitCount: deinits,
            retainingSubscription: &unused,
            handOffRetainingSubscription: false
        )
        XCTAssertEqual(deinits.value, 0, "the emitter's handler should still be holding the consumer")

        assertCompletes(within: 3, "EventEmitter.removeAll() releasing a deinit-cancelling consumer") {
            emitter.removeAll()
        }

        XCTAssertEqual(deinits.value, 1, "the consumer should have been released by removeAll()")
        XCTAssertEqual(handlerCount(of: emitter), 0)
    }

    /// Same hazard through the per-event overload.
    func testRemoveAllForEventCompletesWhenHandlerReleaseCancelsInDeinit() {
        let emitter = EventEmitter()
        let deinits = AtomicCounter()
        var unused: EventSubscription?
        _ = DeinitCancellingConsumer(
            emitter: emitter,
            deinitCount: deinits,
            retainingSubscription: &unused,
            handOffRetainingSubscription: false
        )

        assertCompletes(within: 3, "EventEmitter.removeAll(for:) releasing a deinit-cancelling consumer") {
            emitter.removeAll(for: .cacheUpdated)
        }

        XCTAssertEqual(deinits.value, 1, "the consumer should have been released by removeAll(for:)")
        XCTAssertEqual(handlerCount(of: emitter), 0)
    }

    /// And through a single `cancel()`: cancelling the subscription whose
    /// handler holds the last reference releases the consumer inside
    /// `removeClosure`, whose `deinit` then cancels a second subscription on
    /// the same emitter.
    func testCancelCompletesWhenHandlerReleaseCancelsAnotherSubscriptionInDeinit() {
        let emitter = EventEmitter()
        let deinits = AtomicCounter()
        var retaining: EventSubscription?
        _ = DeinitCancellingConsumer(
            emitter: emitter,
            deinitCount: deinits,
            retainingSubscription: &retaining,
            handOffRetainingSubscription: true
        )
        XCTAssertNotNil(retaining)

        assertCompletes(within: 3, "EventSubscription.cancel() releasing a deinit-cancelling consumer") {
            retaining?.cancel()
        }

        XCTAssertEqual(deinits.value, 1, "the consumer should have been released by cancel()")
        XCTAssertEqual(handlerCount(of: emitter), 0, "the deinit's own cancel should have removed the second handler")
    }

    /// The reported entry point: `JsBaoClient.destroy()` calls
    /// `eventEmitter.removeAll()`, so an app whose view model subscribes with a
    /// strong `self` and cancels in `deinit` used to hang on teardown.
    func testClientDestroyCompletesWithDeinitCancellingSubscriber() async {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "event-emitter-deinit-test-app",
            token: nil,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        let deinits = AtomicCounter()
        var unused: EventSubscription?
        _ = DeinitCancellingConsumer(
            emitter: client.eventEmitter,
            deinitCount: deinits,
            retainingSubscription: &unused,
            handOffRetainingSubscription: false
        )

        await assertCompletesAsync(within: 10, "JsBaoClient.destroy() with a deinit-cancelling subscriber") {
            await client.destroy()
        }

        XCTAssertEqual(deinits.value, 1, "destroy() should have released the subscriber")
    }
}
