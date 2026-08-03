import Foundation
import Network

/// Internal seam for automatic connectivity monitoring (#1987, Phase 2).
///
/// Not public: injection is internal-only (tests supply a fake), so publishing
/// the protocol would freeze a concurrency/lifecycle contract with no consumer
/// benefit.
///
/// Contract:
/// - `start(onChange:)` is called at most once. The implementation SHOULD emit
///   the current reachability soon after starting, then once per change.
/// - `onChange` may be invoked on any queue.
/// - `cancel()` is idempotent and safe to call after `start`. After `cancel()`
///   returns, the client must still TOLERATE one already-enqueued `onChange`
///   (it no-ops via the client's `isDestroyed`/reachability-dedup guards).
internal protocol ConnectivityMonitor: Sendable {
    /// `reachable == true` when a satisfied network path is available.
    func start(onChange: @escaping @Sendable (_ reachable: Bool) -> Void)
    func cancel()
}

/// Production `ConnectivityMonitor` backed by `NWPathMonitor`. `reachable` is
/// `path.status == .satisfied`. The update handler runs on a dedicated
/// `DispatchQueue`; `NWPathMonitor` emits the current path state right after
/// `start`, which seeds the client's initial reachability snapshot.
///
/// Platform floors (macOS 13 / iOS 16) clear `NWPathMonitor`'s availability
/// (10.14 / 12), so no `@available` guards are needed.
internal final class NWPathConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jsbao.connectivity-monitor")
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start(onChange: @escaping @Sendable (_ reachable: Bool) -> Void) {
        let shouldStart: Bool = lock.withLock {
            if started || cancelled { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        let shouldCancel: Bool = lock.withLock {
            if cancelled { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
