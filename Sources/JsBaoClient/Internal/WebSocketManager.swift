import Foundation

// MARK: - Delegate Protocol

public protocol WebSocketManagerDelegate: AnyObject {
    func webSocketManagerHasAccessToken() -> Bool
    func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String])
    func webSocketManagerOnStatusChange(_ status: ConnectionStatus)
    func webSocketManagerOnConnecting()
    func webSocketManagerOnConnected()
    func webSocketManagerOnMessage(_ data: Data) async
    func webSocketManagerOnMessage(_ text: String) async
    func webSocketManagerOnClose(code: Int?, reason: String?)
    func webSocketManagerOnError(_ error: Error)
    func webSocketManagerOnReconnectScheduled(delayMs: Int)
    func webSocketManagerOnDisconnectInitiated()
    func webSocketManagerOnDisconnectResolved()
    func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool
}

// MARK: - WebSocketManager

public final class WebSocketManager: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {

    // MARK: - Properties

    private let logger: Logger
    private var maxReconnectDelayMs: Int
    internal weak var delegate: WebSocketManagerDelegate?

    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var _connected = false
    private var _connecting = false
    private var shouldConnect = true
    private var manualReconnectPending = false
    private var reconnectAttempts = 0
    private var lastCloseInitiator: String?
    private var reconnectWorkItem: DispatchWorkItem?

    /// Stable per-client connection id, minted once at construction. Must be
    /// a ULID, not a UUID: the JS client mints a ULID, and the server's auth
    /// middleware validates the `X-JB-Connection-Id` header against a ULID
    /// regex (`permission-middleware.ts`) — a UUID is silently dropped, which
    /// breaks the #737 `isOrigin` round-trip on `db.change` frames.
    public let connectionId: String = ULID.generate()

    // Connect continuation (the in-flight connect() call's own continuation)
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // Additional callers that hit connect() while one is already in flight.
    // They are all resumed atomically when the in-flight attempt finishes —
    // success resumes them with `()`, failure with the same error. Using an
    // explicit list (instead of polling state) eliminates the race where the
    // in-flight attempt completes in the gap between releasing the lock and
    // a secondary caller starting to wait.
    private var pendingConnectWaiters: [CheckedContinuation<Void, Error>] = []

    // Disconnect continuation (the in-flight disconnect() call's own continuation)
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var isDisconnecting = false
    private var disconnectTimeoutWorkItem: DispatchWorkItem?

    // Additional callers that hit disconnect() / setDesiredConnection() while a
    // disconnect is already in flight. Same pattern as `pendingConnectWaiters`:
    // they register atomically under the lock and are drained when the
    // disconnect resolves (success path in handleConnectionClosed, fallback
    // path in the disconnect() timeout work item, or the synchronous no-task
    // path in disconnect()). Polling `isDisconnecting` from outside the lock
    // is a data race even though Apple's memory model usually papers over it.
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

    // Receive loop task
    private var receiveLoopTask: Task<Void, Never>?

    // MARK: - Lock-decision helpers

    /// Outcome of the connect() prologue, decided in a single `withLock` so the
    /// checks and state mutations that must be atomic stay atomic. Everything
    /// with side effects (delegate calls, awaiting a continuation) runs after
    /// the lock is released.
    private enum ConnectDecision {
        case alreadyConnected
        case waitOnExisting
        case abort
        case proceed(WebSocketManagerDelegate)
    }

    /// How a secondary connect() caller — one that arrived while a connect was
    /// already in flight — is resolved when it re-checks under the lock inside
    /// its continuation prologue.
    private enum ConnectWaiterResolution {
        case registered
        case succeeded
        case failed
    }

    /// Outcome of the disconnect() prologue, decided in a single `withLock`.
    private enum DisconnectDecision {
        case waitOnExisting
        case proceed(hadTask: Bool, currentTask: URLSessionWebSocketTask?)
    }

    // MARK: - Init

    public init(logger: Logger, maxReconnectDelayMs: Int, delegate: WebSocketManagerDelegate? = nil) {
        self.logger = logger
        self.maxReconnectDelayMs = maxReconnectDelayMs
        self.delegate = delegate
        super.init()
    }

    deinit {
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Public Accessors

    public var isConnected: Bool {
        return lock.withLock { _connected }
    }

    public var isConnecting: Bool {
        return lock.withLock { _connecting }
    }

    /// The transport state as a single `ConnectionStatus`, read under one lock
    /// hold so `connected` and `connecting` can't be observed inconsistently
    /// (reading `isConnected` then `isConnecting` separately is two lock hops
    /// and can race). `.connected` wins over `.connecting`.
    public var connectionStatus: ConnectionStatus {
        return lock.withLock {
            if _connected { return .connected }
            if _connecting { return .connecting }
            return .disconnected
        }
    }

    public func setMaxReconnectDelay(_ ms: Int) {
        guard ms > 0 else { return }
        lock.withLock { maxReconnectDelayMs = ms }
    }

    // MARK: - Connect

    public func connect() async throws {
        let decision: ConnectDecision = lock.withLock {
            // Already connected
            if task != nil && _connected {
                logger.debug("[WSM][debug] connect aborted: already connected")
                return .alreadyConnected
            }

            // Already connecting — resolve as a secondary waiter below.
            if _connecting {
                logger.debug("[WSM][debug] connect: waiting on existing connect attempt")
                return .waitOnExisting
            }

            // Explicit connect() call implies the caller wants to connect,
            // so reset shouldConnect (which disconnect() sets to false).
            shouldConnect = true

            guard let delegate = delegate else {
                return .abort
            }

            if !delegate.webSocketManagerHasAccessToken() {
                logger.debug("[CONNECT] Skipping connect: no access token present")
                return .abort
            }

            // Clean up existing socket
            if task != nil {
                closeSocketLocked(initiator: "connect:cleanup")
                task = nil
            }

            // Mark as connecting early to prevent concurrent connect() calls
            // from racing past the _connecting check above.
            _connecting = true

            logger.debug("[WSM][debug] initiating connect", connectionId)
            return .proceed(delegate)
        }

        let connectDelegate: WebSocketManagerDelegate
        switch decision {
        case .alreadyConnected, .abort:
            return
        case .waitOnExisting:
            // Register atomically as a waiter. Because the decision above and
            // this registration are two separate lock holds, the in-flight
            // attempt may have finished in the gap — re-check under the lock
            // and resolve directly if so, otherwise append to be drained when
            // it finishes. (Matches the waitForAuthReady idiom.)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resolution: ConnectWaiterResolution = self.lock.withLock {
                    if self._connecting {
                        self.pendingConnectWaiters.append(continuation)
                        return .registered
                    }
                    return self._connected ? .succeeded : .failed
                }
                switch resolution {
                case .registered:
                    break
                case .succeeded:
                    continuation.resume()
                case .failed:
                    continuation.resume(
                        throwing: WebSocketError.connectionFailed("Connection attempt ended without success")
                    )
                }
            }
            return
        case .proceed(let d):
            connectDelegate = d
        }

        connectDelegate.webSocketManagerOnConnecting()

        let (url, headers) = connectDelegate.webSocketManagerBuildConnectionRequest(connectionId: connectionId)

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Create URLSession with self as delegate to get didOpenWithProtocol callback.
        // This is the equivalent of JavaScript's WebSocket 'onopen' event.
        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        let (oldSession, newTask): (URLSession?, URLSessionWebSocketTask) = lock.withLock {
            let oldSession = session
            session = newSession
            let newTask = newSession.webSocketTask(with: request)
            task = newTask
            _connecting = true
            return (oldSession, newTask)
        }

        // Invalidate old session AFTER setting the new task, so any stale
        // callbacks that sneak through are filtered by the task identity guards.
        oldSession?.invalidateAndCancel()

        connectDelegate.webSocketManagerOnStatusChange(.connecting)

        // Wait for the didOpenWithProtocol delegate callback to fire.
        // IMPORTANT: Store the continuation BEFORE calling resume() to avoid
        // a race where didOpenWithProtocol fires before the continuation is set.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.withLock {
                self.connectContinuation = continuation
            }

            // Now start the connection
            newTask.resume()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    /// Called when the WebSocket handshake completes — equivalent to JS's 'onopen'.
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let resumeSet: (connect: CheckedContinuation<Void, Error>?, waiters: [CheckedContinuation<Void, Error>])? =
            lock.withLock {
                // Ignore callbacks from stale sessions (e.g. after invalidateAndCancel)
                guard webSocketTask === self.task else {
                    logger.debug("[WSM][debug] ignoring didOpenWithProtocol from stale task")
                    return nil
                }
                _connecting = false
                _connected = true
                reconnectAttempts = 0
                logger.debug("[WSM][debug] socket open (didOpenWithProtocol)", connectionId)

                let continuation = connectContinuation
                connectContinuation = nil
                let waiters = pendingConnectWaiters
                pendingConnectWaiters.removeAll()
                return (continuation, waiters)
            }
        guard let resumeSet = resumeSet else { return }

        delegate?.webSocketManagerOnStatusChange(.connected)
        delegate?.webSocketManagerOnConnected()
        resumeSet.connect?.resume()
        for waiter in resumeSet.waiters {
            waiter.resume()
        }

        // Start the receive loop
        startReceiveLoop(webSocketTask)
    }

    /// Called when the WebSocket closes.
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard lock.withLock({ webSocketTask === self.task }) else {
            logger.debug("[WSM][debug] ignoring didCloseWith from stale task")
            return
        }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        logger.debug("[WSM][debug] didCloseWith", closeCode.rawValue, reasonStr ?? "")
        handleConnectionClosed(code: closeCode.rawValue, reason: reasonStr)
    }

    /// Called on task completion with error (connection failure).
    public func urlSession(
        _ session: URLSession,
        task urlSessionTask: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }

        let drained: (connect: CheckedContinuation<Void, Error>?, waiters: [CheckedContinuation<Void, Error>])? =
            lock.withLock {
                // Ignore callbacks from stale sessions (e.g. after invalidateAndCancel
                // during reconnect). Without this guard, the stale session's error callback
                // steals the new connection's continuation, causing a leak.
                guard urlSessionTask === self.task else {
                    logger.debug("[WSM][debug] ignoring didCompleteWithError from stale task:", error.localizedDescription)
                    return nil
                }
                let continuation = connectContinuation
                connectContinuation = nil
                let waiters = pendingConnectWaiters
                pendingConnectWaiters.removeAll()
                _connecting = false
                _connected = false
                return (continuation, waiters)
            }
        guard let drained = drained else { return }

        drained.connect?.resume(throwing: error)
        for waiter in drained.waiters {
            waiter.resume(throwing: error)
        }
        // Transport-level failure. Route the error through handleConnectionClosed
        // so its once-only `wasTask` guard emits `.connectionError` exactly once,
        // whether the failure surfaces here (connect-time) or via the receive-loop
        // catch (an already-established connection). handleConnectionClosed also
        // emits the paired close, mirroring the JS client's 'error' + 'close' pair
        // (`handleWebSocketError`).
        handleConnectionClosed(code: nil, reason: error.localizedDescription, error: error)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop(_ wsTask: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()

        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }

                let currentTask = self.lock.withLock { self.task }

                guard currentTask === wsTask else { return }

                do {
                    let message = try await wsTask.receive()

                    switch message {
                    case .string(let text):
                        await self.delegate?.webSocketManagerOnMessage(text)
                    case .data(let data):
                        await self.delegate?.webSocketManagerOnMessage(data)
                    @unknown default:
                        self.logger.warn("[WSM] Unknown message type received")
                    }
                } catch {
                    guard !Task.isCancelled else { return }

                    let stillCurrentTask = self.lock.withLock { self.task === wsTask }

                    if stillCurrentTask {
                        self.logger.log("Disconnected from WebSocket server. Error:", error.localizedDescription)
                        // Established-connection transport failure: pass the error
                        // so `.connectionError` fires (once, via the guard in
                        // handleConnectionClosed). Deliberate closes cancel this
                        // receive loop first, so `Task.isCancelled` short-circuits
                        // above and never reaches here — no spurious error.
                        self.handleConnectionClosed(
                            code: (error as? URLError)?.errorCode,
                            reason: error.localizedDescription,
                            error: error
                        )
                    }
                    return
                }
            }
        }
    }

    // MARK: - Connection Closed Handler

    private func handleConnectionClosed(code: Int?, reason: String?, error: Error? = nil) {
        let snapshot: (
            wasTask: URLSessionWebSocketTask?,
            pendingConnect: CheckedContinuation<Void, Error>?,
            drainedWaiters: [CheckedContinuation<Void, Error>],
            pendingDisconnect: CheckedContinuation<Void, Never>?,
            wasDisconnecting: Bool,
            shouldReconnectNow: Bool,
            manualPending: Bool,
            drainedDisconnectWaiters: [CheckedContinuation<Void, Never>]
        ) = lock.withLock {
            if let initiator = lastCloseInitiator {
                logger.warn("[WS-CLOSE] observed", initiator)
            }

            let wasTask = task
            task = nil
            _connected = false
            _connecting = false

            // Cancel receive loop
            receiveLoopTask?.cancel()
            receiveLoopTask = nil

            // Reject pending connect continuation and any extra waiters
            let pendingConnect = connectContinuation
            connectContinuation = nil
            let drainedWaiters = pendingConnectWaiters
            pendingConnectWaiters.removeAll()

            // Check for disconnect continuation + drain any extra disconnect waiters.
            let pendingDisconnect = disconnectContinuation
            let wasDisconnecting = isDisconnecting
            let shouldReconnectNow = shouldConnect
            let manualPending = manualReconnectPending
            let drainedDisconnectWaiters = disconnectWaiters
            disconnectWaiters.removeAll()

            if pendingDisconnect != nil {
                disconnectContinuation = nil
                isDisconnecting = false
                disconnectTimeoutWorkItem?.cancel()
                disconnectTimeoutWorkItem = nil
            }

            if manualPending {
                manualReconnectPending = false
            }

            lastCloseInitiator = nil

            return (
                wasTask, pendingConnect, drainedWaiters, pendingDisconnect,
                wasDisconnecting, shouldReconnectNow, manualPending, drainedDisconnectWaiters
            )
        }

        // `.connectionError` fires here exactly once per transport failure. The
        // atomic `wasTask` claim in the snapshot above is the once-only guard:
        // whichever path (didCompleteWithError or the receive-loop catch) first
        // enters with a live task nils it, so a second entry for the same failure
        // sees `wasTask == nil` and does not re-emit. A graceful close
        // (didCloseWith) passes `error: nil` and emits no error — mirroring the JS
        // client emitting 'error' only on a transport error and 'close' on every
        // close. Emitted before the close so subscribers see error-then-close.
        if let error, snapshot.wasTask != nil {
            delegate?.webSocketManagerOnError(error)
        }

        delegate?.webSocketManagerOnStatusChange(.disconnected)
        delegate?.webSocketManagerOnClose(code: code, reason: reason)

        let closeError = WebSocketError.connectionFailed(
            "WebSocket closed before connected: code=\(code.map(String.init) ?? "nil")"
        )
        snapshot.pendingConnect?.resume(throwing: closeError)
        for waiter in snapshot.drainedWaiters {
            waiter.resume(throwing: closeError)
        }

        // Clean up session. Capture-and-nil `session` atomically under the lock
        // (it is written under the lock elsewhere, so reading it unlocked is a
        // data race), then invalidate the captured reference outside the lock.
        if snapshot.wasTask != nil {
            let staleSession: URLSession? = lock.withLock {
                let s = session
                session = nil
                return s
            }
            staleSession?.invalidateAndCancel()
        }

        if snapshot.wasDisconnecting {
            delegate?.webSocketManagerOnDisconnectResolved()
            snapshot.pendingDisconnect?.resume()
            // Drain any callers parked in disconnect()/setDesiredConnection()
            // waiting for this disconnect to finish.
            for waiter in snapshot.drainedDisconnectWaiters {
                waiter.resume()
            }
            return
        }

        if snapshot.manualPending {
            logger.debug("[WSM][debug] manual reconnect trigger fired")
            Task {
                try? await self.connect()
            }
            return
        }

        if snapshot.shouldReconnectNow, delegate?.webSocketManagerShouldReconnect(code: code, reason: reason) == true {
            let delay = calculateReconnectDelay()
            logger.debug("[WSM][debug] scheduling reconnect", delay)
            delegate?.webSocketManagerOnReconnectScheduled(delayMs: delay)
            scheduleReconnect(delayMs: delay)
        } else {
            logger.debug("[WSM][debug] not scheduling reconnect, shouldConnect:", snapshot.shouldReconnectNow)
            lock.withLock { reconnectAttempts = 0 }
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(delayMs: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let shouldGo = self.lock.withLock { self.shouldConnect }

            if shouldGo {
                self.logger.debug("[WSM][debug] reconnect timer fired")
                Task {
                    try? await self.connect()
                }
            } else {
                self.logger.debug("[WSM][debug] reconnect cancelled")
            }
        }

        lock.withLock {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = workItem
        }

        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(delayMs),
            execute: workItem
        )
    }

    private func calculateReconnectDelay() -> Int {
        return lock.withLock {
            let delay = Self.reconnectDelayMs(
                attempts: reconnectAttempts,
                maxReconnectDelayMs: maxReconnectDelayMs
            )
            reconnectAttempts += 1
            return delay
        }
    }

    /// Pure exponential-backoff delay computation, split out so it can be unit
    /// tested independently of the manager's locking and socket state.
    ///
    /// The cap is applied in the `Double` domain *before* converting to `Int`.
    /// Doing the `min` in `Int` (via `Int(pow(2.0, …))` first) traps once
    /// `attempts` reaches ~63, where `pow(2, attempts)` exceeds `Int.max` and
    /// the `Double → Int` conversion crashes before the cap can clamp it. In
    /// `Double`, an overflowing `pow` simply yields `.infinity`, and
    /// `min(.infinity, Double(maxSeconds))` picks the finite cap, so the final
    /// `Int(...)` is always in range regardless of how high `attempts` climbs.
    static func reconnectDelayMs(attempts: Int, maxReconnectDelayMs: Int) -> Int {
        let baseDelayMs = 200
        let maxSeconds = max(1, maxReconnectDelayMs / 1000)
        let cappedSeconds = Int(min(pow(2.0, Double(attempts)), Double(maxSeconds)))
        return baseDelayMs + cappedSeconds * 1000
    }

    // MARK: - Disconnect

    public func disconnect() async {
        // Take a snapshot of any state we might pass to the delegate, then
        // finish all internal mutations under the lock BEFORE releasing it and
        // calling the delegate. This avoids any window where the delegate
        // observes inconsistent state via the manager.
        let decision: DisconnectDecision = lock.withLock {
            // Already disconnecting — resolve as a waiter below.
            if isDisconnecting {
                return .waitOnExisting
            }

            shouldConnect = false
            reconnectAttempts = 0
            _connecting = false
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil

            let hadTask = task != nil
            let currentTask = task
            if currentTask != nil {
                isDisconnecting = true
            } else {
                _connected = false
                isDisconnecting = false
            }
            return .proceed(hadTask: hadTask, currentTask: currentTask)
        }

        let hadTask: Bool
        let currentTask: URLSessionWebSocketTask?
        switch decision {
        case .waitOnExisting:
            // Register atomically as a waiter. The decision above and this
            // registration are two separate lock holds, so the in-flight
            // disconnect may have resolved in the gap — re-check under the
            // lock and resume directly if so, otherwise append to be drained
            // when it finishes. (Matches the waitForAuthReady idiom; the
            // resume always happens outside the lock.)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resolvedInGap = self.lock.withLock { () -> Bool in
                    if self.isDisconnecting {
                        self.disconnectWaiters.append(continuation)
                        return false
                    }
                    return true
                }
                if resolvedInGap {
                    continuation.resume()
                }
            }
            return
        case .proceed(let h, let t):
            hadTask = h
            currentTask = t
        }

        if hadTask {
            delegate?.webSocketManagerOnDisconnectInitiated()
        }

        guard let currentTask = currentTask else {
            delegate?.webSocketManagerOnDisconnectResolved()
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Safety timeout: 500ms. Captures the pending disconnect
            // continuation + any parked waiters OUT of the lock, then resumes
            // them outside it. The `disconnectContinuation` nil-guard makes
            // this mutually exclusive with handleConnectionClosed — whichever
            // fires first nils it, and the other returns without resuming, so
            // the continuation is resumed exactly once.
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let drained: (
                    continuation: CheckedContinuation<Void, Never>,
                    waiters: [CheckedContinuation<Void, Never>]
                )? = self.lock.withLock {
                    guard let pendingContinuation = self.disconnectContinuation else {
                        return nil
                    }
                    self.disconnectContinuation = nil
                    self.isDisconnecting = false
                    self.task = nil
                    self._connected = false
                    let drainedWaiters = self.disconnectWaiters
                    self.disconnectWaiters.removeAll()
                    return (pendingContinuation, drainedWaiters)
                }
                guard let drained = drained else { return }

                self.delegate?.webSocketManagerOnDisconnectResolved()
                drained.continuation.resume()
                for waiter in drained.waiters {
                    waiter.resume()
                }
            }

            self.lock.withLock {
                self.disconnectContinuation = continuation
                self.disconnectTimeoutWorkItem = timeoutWork
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(500),
                execute: timeoutWork
            )

            // Cancel the receive loop first
            self.receiveLoopTask?.cancel()

            // Close the socket gracefully
            currentTask.cancel(with: .normalClosure, reason: nil)
        }
    }

    // MARK: - setDesiredConnection

    public func setDesiredConnection(shouldConnect: Bool) async {
        logger.debug("[WSM][debug] setDesiredConnection", shouldConnect, "connected:", _connected, "connecting:", _connecting)

        if shouldConnect {
            // Wait for any pending disconnect to finish, registering as a
            // waiter atomically under the lock instead of polling
            // `isDisconnecting` from outside the lock (which is a data race).
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = self.lock.withLock { () -> Bool in
                    if self.isDisconnecting {
                        self.disconnectWaiters.append(continuation)
                        return false
                    }
                    return true
                }
                if resumeNow {
                    continuation.resume()
                }
            }

            lock.withLock { self.shouldConnect = true }

            // `connect()` is idempotent: it returns immediately if already
            // connected, registers on the `pendingConnectWaiters` list if a
            // connect is already in flight, or starts a fresh connect. Calling
            // it unconditionally replaces the old branch that hand-rolled a
            // 50ms polling wait (`waitForConnection`) for the in-flight case.
            do {
                try await connect()
            } catch {
                logger.debug("[WSM][debug] connect failed in setDesiredConnection:", error.localizedDescription)
            }
        } else {
            lock.withLock { self.shouldConnect = false }
            await disconnect()
        }
    }

    // MARK: - Force Reconnect

    public func forceReconnect() {
        let needsConnect = lock.withLock { () -> Bool in
            manualReconnectPending = true
            shouldConnect = true
            reconnectAttempts = 0

            if task != nil {
                closeSocketLocked(initiator: "forceReconnect")
                // handleConnectionClosed will be triggered by the receive loop error
                return false
            }
            return true
        }

        if needsConnect {
            Task {
                try? await self.connect()
            }
        }
    }

    // MARK: - Send

    public func send(_ text: String) async throws {
        let currentTask: URLSessionWebSocketTask? = lock.withLock {
            guard let currentTask = task, _connected else { return nil }
            return currentTask
        }
        guard let currentTask = currentTask else {
            throw WebSocketError.notConnected
        }

        try await currentTask.send(.string(text))
    }

    public func send(_ data: Data) async throws {
        let currentTask: URLSessionWebSocketTask? = lock.withLock {
            guard let currentTask = task, _connected else { return nil }
            return currentTask
        }
        guard let currentTask = currentTask else {
            throw WebSocketError.notConnected
        }

        try await currentTask.send(.data(data))
    }

    // MARK: - Close Socket

    public func closeSocket(initiator: String) {
        lock.withLock {
            closeSocketLocked(initiator: initiator)
        }
    }

    /// Must be called with lock held.
    private func closeSocketLocked(initiator: String) {
        lastCloseInitiator = initiator
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: initiator.data(using: .utf8))

        // Resume any pending connect continuation and drained waiters to
        // avoid leaked continuations (waiters would otherwise hang forever).
        let waiters = pendingConnectWaiters
        pendingConnectWaiters.removeAll()
        if let continuation = connectContinuation {
            connectContinuation = nil
            _connecting = false
            let err = WebSocketError.connectionFailed("Connection closed: \(initiator)")
            continuation.resume(throwing: err)
            for waiter in waiters {
                waiter.resume(throwing: err)
            }
        } else if !waiters.isEmpty {
            let err = WebSocketError.connectionFailed("Connection closed: \(initiator)")
            for waiter in waiters {
                waiter.resume(throwing: err)
            }
        }
    }

    // MARK: - Socket State

    public var isSocketOpen: Bool {
        return lock.withLock { task != nil && task?.state == .running && _connected }
    }
}

// MARK: - WebSocketError

public enum WebSocketError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
}

extension WebSocketError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "WebSocket is not connected"
        case .connectionFailed(let reason):
            return "WebSocket connection failed: \(reason)"
        }
    }
}
