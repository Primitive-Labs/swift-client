import Foundation

// The two locks that survive `WebSocketManager`'s actor conversion (#2171).
//
// They live in their own file on purpose. `WebSocketManager.swift` is held at
// zero `NSLock` / `withLock` / `@unchecked Sendable` by
// `ActorizedWebSocketManagerTests` — that is the headline claim of the
// conversion, and a lock declared beside the actor would blur it. Each box
// here is an *explicitly enumerated* exception with a written safety argument,
// which is the bar `swift-client/docs/architecture.md` sets for every
// `@unchecked Sendable` in the package.

// MARK: - Transport snapshot

/// The transport state a **synchronous** caller may read while
/// `WebSocketManager` is an actor.
///
/// Safety argument for the `@unchecked Sendable`:
///
/// - Every field is confined to `lock`. There is no other storage and no
///   unlocked accessor, so there is no unsynchronized path to any of them.
/// - It is written **only from inside the actor**, on each transport
///   transition, and read from anywhere. Writers are therefore already
///   serialized by actor isolation; the lock exists for the readers.
/// - It holds no continuation, no queue and no ordering state — nothing whose
///   correctness depends on *when* a reader observes it. A reader that races an
///   in-flight transition sees the pre-transition value for the duration of one
///   actor step, exactly as it did when the manager was a class that released
///   its lock before calling the delegate.
/// - `connected` and `connecting` are written together through
///   `set(connected:connecting:)`, so `status` can never report the two
///   inconsistently. That is the property the class's single-lock-hold
///   `connectionStatus` provided, preserved rather than dropped.
/// - It stores the `URLSessionWebSocketTask` **reference**, not a cached
///   `Bool`, so `socketIsOpen` keeps reading the socket's live `state`.
///   `URLSessionWebSocketTask.state` is documented as readable from any thread.
/// - `opened` belongs to the task it was set for: replacing the task clears it
///   in the same hold, so it can never describe a socket that is gone.
final class WebSocketTransportSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var _connected = false
    private var _connecting = false
    private var _opened = false
    private var _task: URLSessionWebSocketTask?
    private var _sentForTest: (@Sendable (String) -> Void)?

    var connected: Bool { lock.withLock { _connected } }

    /// Test seam: hears every frame `send(_:)` hands the socket (a binary one
    /// decoded as UTF-8). Internal; never set in production code.
    var sentForTest: (@Sendable (String) -> Void)? {
        get { lock.withLock { _sentForTest } }
        set { lock.withLock { _sentForTest = newValue } }
    }
    var connecting: Bool { lock.withLock { _connecting } }

    var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set {
            lock.withLock {
                if _task !== newValue { _opened = false }
                _task = newValue
            }
        }
    }

    /// The current task's socket has opened (`didOpenWithProtocol`). Before
    /// the server's `ready` (#5578) it is open without being connected.
    var opened: Bool { lock.withLock { _opened } }

    /// Record the current task's open.
    func markOpened() {
        lock.withLock { _opened = _task != nil }
    }

    /// The transport state as one value, read under a single lock hold so
    /// `connected` and `connecting` cannot be observed inconsistently.
    /// `.connected` wins over `.connecting`.
    var status: ConnectionStatus {
        lock.withLock {
            if _connected { return .connected }
            if _connecting { return .connecting }
            return .disconnected
        }
    }

    /// The socket's **live** open state — `task?.state == .running`, not a
    /// cached boolean. A task cancelled out from under the manager reads
    /// `false` here before any delegate callback lands.
    var socketIsOpen: Bool {
        lock.withLock { _task != nil && _task?.state == .running && _connected }
    }

    /// The task to send on: the current one, but only while connected. Reading
    /// it here rather than hopping onto the actor is what keeps `send(_:)` off
    /// the actor's executor, so concurrent sends stay concurrent.
    var sendableTask: URLSessionWebSocketTask? {
        lock.withLock { _connected ? _task : nil }
    }

    /// Whether the socket is open, connected or still waiting for the server's
    /// `ready` (#5578): the live `state`, like `socketIsOpen`, but not gated on
    /// `connected`. What decides that an applied token goes to the socket
    /// rather than to the next handshake.
    var transportIsOpen: Bool {
        lock.withLock { _task != nil && _task?.state == .running && _opened }
    }

    /// The task to send on once its socket has opened, before `ready` too.
    var openTask: URLSessionWebSocketTask? {
        lock.withLock { _opened ? _task : nil }
    }

    /// Writes both flags in one hold — see the safety argument above.
    func set(connected: Bool, connecting: Bool) {
        lock.withLock {
            _connected = connected
            _connecting = connecting
        }
    }
}

// MARK: - Weak delegate

/// The manager's delegate, held weakly and settable **synchronously**.
///
/// Safety argument for the `@unchecked Sendable`: the single `weak` reference
/// is confined to `lock` and there is no unlocked accessor. `AnyObject` weak
/// references are not atomic on their own, so the lock is what makes a
/// concurrent set/read safe; the value it hands back is a strong reference the
/// caller owns for the duration of its call.
///
/// It exists because `JsBaoClient.setupDependencies()` is a synchronous private
/// method called from `init`: `wsManager.delegate = self` has to land before
/// `init` returns or a window opens in which the manager is live with no
/// delegate. Construction-time injection — the shape `KvCache` and
/// `AnalyticsQueue` use — does not apply here, because the delegate *is* the
/// client and cannot be captured before its own `init` completes.
final class WeakWebSocketManagerDelegateBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: (any WebSocketManagerDelegate)?

    var value: (any WebSocketManagerDelegate)? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
