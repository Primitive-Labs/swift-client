import XCTest
@testable import JsBaoClient

/// Unit tests for `EventEmitter`'s thread safety after the
/// `NSLock.lock()/unlock()` → scoped `withLock` conversion (issue #1910).
///
/// `EventEmitter`'s public ops (`on`/`onAny`/`emit`/`removeAll`) are
/// synchronous, so these use the synchronous `assertCompletes` watchdog
/// (fail-not-hang on a lock-ordering deadlock) directly.
final class EventEmitterTests: XCTestCase {

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
        let subsLock = NSLock()
        var subscriptions: [EventSubscription] = []

        assertCompletes(within: 5, "concurrent EventEmitter subscribe") {
            DispatchQueue.concurrentPerform(iterations: subscriberCount) { _ in
                let sub = emitter.onAny(.cacheUpdated) { _ in counter.increment() }
                subsLock.withLock { subscriptions.append(sub) }
            }
        }

        XCTAssertEqual(subscriptions.count, subscriberCount)

        emitter.emit(.cacheUpdated, () as Any)
        XCTAssertEqual(counter.value, subscriberCount, "every concurrently-registered handler must fire exactly once")

        // Keep the subscriptions alive until here.
        subsLock.withLock { subscriptions.removeAll() }
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
                    let sub = emitter.onAny(.cacheUpdated) { _ in counter.increment() }
                    sub.cancel()
                case 1:
                    emitter.emit(.cacheUpdated, () as Any)
                case 2:
                    emitter.removeAll(for: .cacheUpdated)
                default:
                    emitter.removeAll()
                }
            }
        }
    }
}
