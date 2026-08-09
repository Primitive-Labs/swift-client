import Foundation
import XCTest
@testable import JsBaoClient

/// `TimeInterval.wholeMilliseconds` is the one conversion every `TimeInterval`
/// parameter the #2367 migration introduced passes through — lock TTLs,
/// workflow timeouts, cache freshness windows. `Int(_:)` traps on a `Double`
/// that is non-finite or out of `Int`'s range, and the `Int` parameters this
/// migration replaced could not express those values, so the trap surface is
/// new: `client.locks.acquire(key:ttl: .infinity)` would have terminated the
/// process rather than throwing.
final class WholeMillisecondsTests: XCTestCase {

    // MARK: - The floor (pre-existing behavior, pinned)

    func testNegativeIntervalsClampToZero() {
        XCTAssertEqual((-1.0 as TimeInterval).wholeMilliseconds, 0)
        XCTAssertEqual((-TimeInterval.infinity).wholeMilliseconds, 0)
        XCTAssertEqual((-Double.greatestFiniteMagnitude as TimeInterval).wholeMilliseconds, 0)
    }

    func testOrdinaryIntervalsConvertAndRound() {
        XCTAssertEqual((0 as TimeInterval).wholeMilliseconds, 0)
        XCTAssertEqual((1.5 as TimeInterval).wholeMilliseconds, 1500)
        XCTAssertEqual((0.0004 as TimeInterval).wholeMilliseconds, 0)
        XCTAssertEqual((0.0006 as TimeInterval).wholeMilliseconds, 1)
    }

    // MARK: - The ceiling (the trap this closes)

    func testInfinitySaturatesInsteadOfTrapping() {
        XCTAssertEqual(
            TimeInterval.infinity.wholeMilliseconds,
            TimeInterval.maxWholeMilliseconds,
            "an infinite duration means 'never time out', not a crash"
        )
    }

    func testNaNFloorsToZero() {
        XCTAssertEqual(
            TimeInterval.nan.wholeMilliseconds, 0,
            "every comparison against NaN is false, so Swift.max(0, .nan) is 0"
        )
    }

    func testFiniteValuesAboveTheCeilingSaturate() {
        XCTAssertEqual(
            TimeInterval.greatestFiniteMagnitude.wholeMilliseconds,
            TimeInterval.maxWholeMilliseconds
        )
        // Just past the ceiling in seconds.
        let justOver = Double(TimeInterval.maxWholeMilliseconds) / 1000 * 2
        XCTAssertEqual(justOver.wholeMilliseconds, TimeInterval.maxWholeMilliseconds)
    }

    /// The ceiling exists to keep `withTimeout(ms:)`'s `UInt64(ms) *
    /// 1_000_000` in range — saturating at `Int.max` would only move the trap
    /// into that multiplication.
    func testTheCeilingSurvivesTheNanosecondConversion() {
        let ms = TimeInterval.maxWholeMilliseconds
        let (ns, overflow) = UInt64(ms).multipliedReportingOverflow(by: 1_000_000)
        XCTAssertFalse(overflow, "the ms ceiling must convert to nanoseconds without overflowing")
        XCTAssertGreaterThan(ns, 0)
    }

    /// Values that far exceed a realistic timeout are still legal `Double`s a
    /// caller can pass, so every public `TimeInterval` parameter has to
    /// survive them. Sample the extremes through the same helper each of those
    /// parameters uses.
    func testEveryExtremeConvertsWithoutTrapping() {
        let extremes: [TimeInterval] = [
            .infinity, -.infinity, .nan, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude, .leastNonzeroMagnitude, 1e30, -1e30, 0,
        ]
        for value in extremes {
            let ms = value.wholeMilliseconds
            XCTAssertGreaterThanOrEqual(ms, 0)
            XCTAssertLessThanOrEqual(ms, TimeInterval.maxWholeMilliseconds)
        }
    }
}
