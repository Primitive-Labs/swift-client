import Foundation
@testable import JsBaoClient

/// Test double for the internal `ConnectivityMonitor` (#1987). Lets a test
/// drive reachability transitions synchronously via `push(_:)` and observe the
/// `start`/`cancel` lifecycle. Thread-safe.
final class FakeConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable (Bool) -> Void)?
    private var _startCount = 0
    private var _cancelCount = 0
    private var _startedAt: Date?

    /// When set, `start` immediately delivers this value — the way
    /// `NWPathMonitor` emits the current path right after `start(queue:)`.
    private let initialValue: Bool?

    init(initialValue: Bool? = nil) {
        self.initialValue = initialValue
    }

    var startCount: Int { lock.withLock { _startCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var isStarted: Bool { lock.withLock { _startCount > 0 && onChange != nil } }
    /// When `start` was called, for timing assertions.
    var startedAt: Date? { lock.withLock { _startedAt } }

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            self.onChange = onChange
            self._startCount += 1
            self._startedAt = Date()
        }
        if let initialValue {
            onChange(initialValue)
        }
    }

    func cancel() {
        lock.withLock { self._cancelCount += 1 }
    }

    /// Deliver a reachability change to the client. No-op if `start` was never
    /// called (e.g. `autoNetwork: false`).
    func push(_ reachable: Bool) {
        let handler = lock.withLock { onChange }
        handler?(reachable)
    }
}
