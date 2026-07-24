import Foundation
import XCTest

/// Shared deadlock watchdog for the NSLock → scoped `withLock` conversion
/// (issue #1910). Runs a synchronous closure on a detached GCD thread and
/// **fails the test** (rather than hanging the whole suite) if it does not
/// complete within a bounded timeout.
///
/// This generalizes the `DispatchQueue.global(...).async { ...; semaphore.signal() }`
/// + `semaphore.wait(timeout:)` pattern already used in `YDocumentDeadlockTests`
/// and `YTextSemanticsTests`.
///
/// IMPORTANT: it deliberately uses `DispatchSemaphore`, NOT `Task` /
/// `withTaskGroup` cancellation. A thread blocked on a lock (or inside Rust FFI)
/// cannot be cancelled, so a `Task`-based watchdog would hang `withTaskGroup`
/// forever instead of reporting a failure. With GCD the stuck worker thread is
/// leaked when the timeout fires — acceptable, because it only happens on a
/// genuine regression (a real deadlock), never in steady state.
///
/// - Parameters:
///   - timeout: how long to wait before declaring a deadlock (default 3s).
///   - description: shown in the failure message.
///   - work: the synchronous critical-section exercise to run and time.
func assertCompletes(
    within timeout: TimeInterval = 3,
    _ description: String = "operation",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: @escaping () -> Void
) {
    let semaphore = DispatchSemaphore(value: 0)
    // Intentionally leaked on a genuine hang: the worker may be holding a lock
    // with no safe way to free it. Matches YDocumentDeadlockTests.
    DispatchQueue.global(qos: .userInitiated).async {
        work()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        XCTFail(
            "Deadlock watchdog: \(description) did not complete within \(timeout)s — likely a lock held across a suspension or a lock-ordering deadlock.",
            file: file,
            line: line
        )
    }
}
