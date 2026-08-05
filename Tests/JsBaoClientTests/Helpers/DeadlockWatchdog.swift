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
    // `work` is an ordinary (non-`Sendable`) closure — most callers capture a
    // `YDocument` or another lock-confined value in it — so under the Swift 6
    // language mode it cannot be captured directly by the `@Sendable` GCD
    // closure below (#2310). The handover is one-way: the caller builds it,
    // the worker runs it, and the caller only resumes once the semaphore is
    // signalled or the watchdog times out. `SendingBox` is that argument.
    let sending = SendingBox(work)
    // Intentionally leaked on a genuine hang: the worker may be holding a lock
    // with no safe way to free it. Matches YDocumentDeadlockTests.
    DispatchQueue.global(qos: .userInitiated).async {
        sending.value()
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

/// The `async` counterpart, for critical sections that became **actor
/// isolation** rather than a lock (#1993 Phase D, #2172). Same contract as the
/// synchronous form: the work runs detached and the *test* fails rather than
/// the suite hanging when it does not finish in time.
///
/// It polls a flag instead of blocking on a `DispatchSemaphore`, because
/// blocking inside an `async` test would occupy a cooperative-pool thread — the
/// very resource a hung actor call needs to make progress. A genuinely stuck
/// task is leaked when the timeout fires, exactly as the synchronous form leaks
/// its stuck thread: an actor call that never returns cannot be cancelled.
func assertCompletesAsync(
    within timeout: TimeInterval = 3,
    _ description: String = "operation",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: @escaping @Sendable () async -> Void
) async {
    if await completesAsync(within: timeout, work) { return }
    XCTFail(
        "Deadlock watchdog: \(description) did not complete within \(timeout)s — likely an isolated call that never returns.",
        file: file,
        line: line
    )
}

/// The detection half of `assertCompletesAsync`, without the `XCTFail`: runs
/// `work` detached and reports whether it finished inside `timeout`.
///
/// It is split out so the timeout decision can be self-tested directly.
/// `XCTExpectFailure` cannot be used for that: `assertCompletesAsync` records
/// its failure after an `await` hop, on a cooperative-pool thread rather than
/// the test's own, and the expected-failure scope does not reach across that.
/// With the seam, the self-test asserts on the returned verdict instead and
/// only the one-line `XCTFail` above is left uncovered.
@discardableResult
func completesAsync(
    within timeout: TimeInterval,
    _ work: @escaping @Sendable () async -> Void
) async -> Bool {
    let finished = WatchdogFlag()
    Task.detached {
        await work()
        finished.set()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !finished.value && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
    }
    return finished.value
}

/// Thread-safe completion flag for `assertCompletesAsync`.
private final class WatchdogFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() { lock.withLock { _value = true } }
    var value: Bool { lock.withLock { _value } }
}
