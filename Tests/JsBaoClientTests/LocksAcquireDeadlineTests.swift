import Foundation
import XCTest
@testable import JsBaoClient

/// The blocking `acquire` poll loop converts its remaining time to `Int`
/// milliseconds on every iteration. `Int(_:)` traps on a `Double` that is
/// non-finite or out of range, so the deadline it measures against has to be
/// finite by construction — which it only is when it is derived from the
/// clamped `timeoutMs` rather than the raw `TimeInterval` the caller passed.
///
/// #2367 renamed `timeoutMs: Int` to `timeout: TimeInterval`, so `.infinity`
/// became expressible for the first time. These are pure arithmetic tests: the
/// live contention path is covered by `LocksTests`.
final class LocksAcquireDeadlineTests: XCTestCase {

    /// Every remaining-time value the loop can compute, for the given timeout.
    private func remainingMs(forTimeout timeout: TimeInterval) -> Int {
        let now = Date()
        let deadline = LocksAPI.deadline(timeoutMs: timeout.wholeMilliseconds, from: now)
        // The exact expression `acquire` evaluates at each poll.
        return Int((deadline.timeIntervalSince(now) * 1000).rounded())
    }

    func testOrdinaryTimeoutsProduceTheExpectedDeadline() {
        let now = Date()
        XCTAssertEqual(
            LocksAPI.deadline(timeoutMs: (0.9 as TimeInterval).wholeMilliseconds, from: now)
                .timeIntervalSince(now),
            0.9,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LocksAPI.deadline(timeoutMs: (15 as TimeInterval).wholeMilliseconds, from: now)
                .timeIntervalSince(now),
            15,
            accuracy: 0.001
        )
    }

    /// The finding this file exists for: `acquire(timeout: .infinity)` on a
    /// contended key used to reach `Int(.infinity)` and terminate the process.
    func testInfiniteTimeoutYieldsAFiniteDeadlineAtTheCeiling() {
        let now = Date()
        let deadline = LocksAPI.deadline(
            timeoutMs: TimeInterval.infinity.wholeMilliseconds, from: now
        )
        let remaining = deadline.timeIntervalSince(now)

        XCTAssertTrue(remaining.isFinite, "an infinite timeout must not produce an infinite deadline")
        XCTAssertEqual(
            remaining, Double(TimeInterval.maxWholeMilliseconds) / 1000,
            accuracy: 1,
            "it saturates at the same ~292-year ceiling wholeMilliseconds does"
        )
        XCTAssertGreaterThan(deadline, now, "the loop must keep polling, not time out immediately")
    }

    /// The conversion the loop performs must stay in `Int` range for every
    /// timeout a caller can legally pass — this is the expression that trapped.
    func testTheRemainingTimeConversionSurvivesEveryExtreme() {
        let extremes: [TimeInterval] = [
            .infinity, -.infinity, .nan, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude, 1e30, -1e30, 0, 0.9, 15,
        ]
        for timeout in extremes {
            let ms = remainingMs(forTimeout: timeout)
            XCTAssertGreaterThanOrEqual(ms, -1, "timeout \(timeout) produced \(ms)")
            XCTAssertLessThanOrEqual(
                ms, TimeInterval.maxWholeMilliseconds,
                "timeout \(timeout) produced \(ms)"
            )
        }
    }

    /// A timeout at or below zero must expire immediately rather than wrapping
    /// into a long wait — `now >= deadline` on the first pass.
    func testNonPositiveTimeoutsExpireImmediately() {
        let now = Date()
        for timeout in [0, -1, -TimeInterval.infinity, TimeInterval.nan] as [TimeInterval] {
            let deadline = LocksAPI.deadline(timeoutMs: timeout.wholeMilliseconds, from: now)
            XCTAssertLessThanOrEqual(
                deadline, now, "timeout \(timeout) must not extend the deadline"
            )
        }
    }
}
