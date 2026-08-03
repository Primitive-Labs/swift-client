import Foundation
import XCTest
@testable import JsBaoClient

/// Self-tests for the shared deadlock watchdog (`assertCompletes`) introduced in
/// Phase 0 of issue #1910. Proves the helper does what the later per-class stress
/// tests rely on: it passes when the work finishes in time, and it *fails the
/// test* (rather than hanging the suite) when the work blocks past the timeout.
final class DeadlockWatchdogTests: XCTestCase {

    /// Happy path: work that completes well within the timeout does not fail.
    func testCompletesWithinTimeoutPasses() {
        var ran = false
        assertCompletes(within: 2, "fast work") {
            ran = true
        }
        XCTAssertTrue(ran, "the watched closure should have run")
    }

    /// A closure that blocks forever must make the watchdog *fail*, not hang the
    /// suite. `XCTExpectFailure` swallows that expected XCTFail so this test
    /// itself passes — and would fail loudly if the watchdog hung or did not
    /// report a failure at all. The blocked worker thread is intentionally leaked
    /// (it never returns), matching YDocumentDeadlockTests.
    func testBlockedWorkFailsRatherThanHangs() {
        let neverSignals = DispatchSemaphore(value: 0)
        XCTExpectFailure("watchdog is expected to report a timeout for blocked work") {
            assertCompletes(within: 1, "intentionally blocked work") {
                // Block past the timeout. Not signalled anywhere — the worker
                // thread is leaked, exactly as a real lock-held-forever hang.
                _ = neverSignals.wait(timeout: .now() + 30)
            }
        }
    }

    // MARK: - assertCompletesAsync (#1993 Phase D, #2172)

    /// Happy path for the `async` counterpart. Same contract, same two halves,
    /// so the helper the actor suites depend on is proven rather than assumed.
    func testAsyncCompletesWithinTimeoutPasses() async {
        let ran = RanFlag()
        await assertCompletesAsync(within: 2, "fast async work") {
            ran.set()
        }
        XCTAssertTrue(ran.value, "the watched closure should have run")
    }

    /// An `async` closure that never returns must be *reported*, not hang the
    /// suite. Asserted on `completesAsync`'s verdict rather than through
    /// `XCTExpectFailure`: `assertCompletesAsync` records its failure after an
    /// `await` hop, on a cooperative-pool thread, and the expected-failure
    /// scope does not reach across that. The stuck task is intentionally
    /// leaked — an actor call that never returns cannot be cancelled, which is
    /// why the helper polls a flag rather than awaiting the work.
    func testAsyncBlockedWorkIsReportedRatherThanHanging() async {
        let started = Date()
        let finished = await completesAsync(within: 1) {
            // Sleeps well past the timeout, standing in for an isolated call
            // that never returns.
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
        XCTAssertFalse(finished, "blocked work must be reported as not completing")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 10,
            "the watchdog must return at its own deadline, not wait out the blocked work")
    }

    /// The other half of the same seam: work that does finish is reported as
    /// finished, so the verdict above is not simply always `false`.
    func testAsyncCompletesReportsFinishedWork() async {
        let finished = await completesAsync(within: 2) {}
        XCTAssertTrue(finished, "work that returns must be reported as completing")
    }
}

/// Thread-safe flag — the watched closure is `@Sendable`, so it cannot capture
/// a plain `var`.
private final class RanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() { lock.withLock { _value = true } }
    var value: Bool { lock.withLock { _value } }
}
