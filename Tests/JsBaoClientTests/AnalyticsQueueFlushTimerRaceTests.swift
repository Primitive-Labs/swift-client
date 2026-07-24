import XCTest
@testable import JsBaoClient

/// Regression test for issue #1985.
///
/// `AnalyticsQueue.flushTimer` was checked under the lock but assigned and
/// cleared outside it. Two concurrent `logEvent()` calls could both pass the
/// "no timer scheduled" guard and each schedule their own flush timer — a
/// data race on `flushTimer` under the class's `@unchecked Sendable` contract,
/// double-scheduling the flush. The fix brings the check-and-schedule under a
/// single lock hold so it is atomic; only one racer creates the timer.
///
/// Server-free: constructs `AnalyticsQueue` directly with no connection, so
/// the scheduled flush harmlessly re-buffers. It observes how many timers were
/// scheduled via the internal `onFlushScheduled` hook.
final class AnalyticsQueueFlushTimerRaceTests: XCTestCase {

    /// Thread-safe counter for tallying flush-timer creations across the
    /// concurrent racers without adding a second data race in the test.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// Many independent rounds, each firing a burst of concurrent
    /// `logEvent()` calls at a fresh queue that has no flush timer scheduled.
    /// Each round must schedule EXACTLY ONE flush timer, however many events
    /// raced in. Pre-fix, the check-then-assign window let multiple racers
    /// each schedule their own timer, so the aggregate count exceeded the
    /// round count. Post-fix the atomic critical section guarantees exactly
    /// one timer per round.
    ///
    /// A fresh queue per round keeps every burst well under the rate limiter's
    /// burst cap (60 events / 10s), so no event is dropped before it reaches
    /// `scheduleFlush()`.
    func testConcurrentLogEventsScheduleFlushTimerExactlyOnce() async {
        let rounds = 300
        let concurrency = 48
        let scheduled = AtomicCounter()

        for _ in 0..<rounds {
            let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "flush-race-test"))
            queue.onFlushScheduled = { scheduled.increment() }

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<concurrency {
                    group.addTask {
                        queue.logEvent(["action": "race", "feature": "flush_timer_\(i)"])
                    }
                }
                await group.waitForAll()
            }
        }

        XCTAssertEqual(
            scheduled.value, rounds,
            "each round's concurrent logEvent() calls must schedule exactly one flush timer; "
                + "\(scheduled.value) schedules across \(rounds) rounds means the check-and-schedule "
                + "raced and double-scheduled (issue #1985)"
        )
    }
}
