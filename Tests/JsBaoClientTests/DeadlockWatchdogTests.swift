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
}
