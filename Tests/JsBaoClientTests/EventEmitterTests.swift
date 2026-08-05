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
}
