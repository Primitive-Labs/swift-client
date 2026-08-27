import Foundation
@testable import JsBaoClient

/// Shared support for the `WebSocketManager` suites (#2171).
///
/// `eventuallyTrue` is the non-throwing boolean poll those suites need — the
/// package-level `eventually(timeout:interval:description:check:)` in
/// `TestHelper.swift` fails the test itself on timeout and takes a `throws`
/// closure, so it cannot express "poll, then assert on the result". Each of
/// the WebSocketManager suites had grown its own byte-identical private copy;
/// this is the one copy they share.
@discardableResult
func eventuallyTrue(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Records what the pump reports through `setEventHandledHookForTest`, and
/// turns "this injected event must change nothing" from a sleep into an
/// ordered wait.
///
/// A sleep cannot tell an undrained pump from a correctly dropping one — both
/// look like "nothing happened" — so a stale-event test that sleeps passes on
/// a loaded machine even if the stale filter is broken. The fix is a
/// **sentinel**: emit one more event behind the injected ones and wait for the
/// pump to report it. The channel is FIFO and `handle(_:)` is non-`async`, so
/// a report for the sentinel proves every earlier event was already handled to
/// completion, whatever the machine's load.
///
/// The sentinel carries a task identity that is not the manager's, so it is
/// itself dropped by the same stale filter and changes nothing.
final class HandledEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WebSocketManager.DelegateEvent] = []

    func record(_ event: WebSocketManager.DelegateEvent) {
        lock.withLock { _events.append(event) }
    }

    var events: [WebSocketManager.DelegateEvent] { lock.withLock { _events } }

    /// True once the pump has reported a `.closed` carrying `code` — the
    /// sentinel marker.
    func sawSentinel(code: Int) -> Bool {
        events.contains { event in
            if case .closed(_, let seen, _) = event { return seen == code }
            return false
        }
    }
}
