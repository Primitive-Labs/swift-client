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

    public let connectionId: String = UUID().uuidString

    // Connect continuation
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var hasActiveConnectContinuation = false

    // Disconnect continuation
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var isDisconnecting = false
    private var disconnectTimeoutWorkItem: DispatchWorkItem?

    // Receive loop task
    private var receiveLoopTask: Task<Void, Never>?

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
        lock.lock()
        defer { lock.unlock() }
        return _connected
    }

    public var isConnecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connecting
    }

    public func setMaxReconnectDelay(_ ms: Int) {
        guard ms > 0 else { return }
        lock.lock()
        maxReconnectDelayMs = ms
        lock.unlock()
    }

    // MARK: - Connect

    public func connect() async throws {
        lock.lock()

        // Already connected
        if task != nil && _connected {
            logger.debug("[WSM][debug] connect aborted: already connected")
            lock.unlock()
            return
        }

        // Already connecting - wait on the existing continuation
        if _connecting && hasActiveConnectContinuation {
            logger.debug("[WSM][debug] connect: waiting on existing connect attempt")
            lock.unlock()
            // We cannot share the same continuation, so just poll until done
            try await waitForConnection()
            return
        }

        // Explicit connect() call implies the caller wants to connect,
        // so reset shouldConnect (which disconnect() sets to false).
        shouldConnect = true

        guard let delegate = delegate else {
            lock.unlock()
            return
        }

        if !delegate.webSocketManagerHasAccessToken() {
            logger.debug("[CONNECT] Skipping connect: no access token present")
            lock.unlock()
            return
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
        lock.unlock()

        delegate.webSocketManagerOnConnecting()

        let (url, headers) = delegate.webSocketManagerBuildConnectionRequest(connectionId: connectionId)

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Create URLSession with self as delegate to get didOpenWithProtocol callback.
        // This is the equivalent of JavaScript's WebSocket 'onopen' event.
        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        lock.lock()
        let oldSession = session
        session = newSession
        let newTask = newSession.webSocketTask(with: request)
        task = newTask
        _connecting = true
        lock.unlock()

        // Invalidate old session AFTER setting the new task, so any stale
        // callbacks that sneak through are filtered by the task identity guards.
        oldSession?.invalidateAndCancel()

        delegate.webSocketManagerOnStatusChange(.connecting)

        // Wait for the didOpenWithProtocol delegate callback to fire.
        // IMPORTANT: Store the continuation BEFORE calling resume() to avoid
        // a race where didOpenWithProtocol fires before the continuation is set.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            self.connectContinuation = continuation
            self.hasActiveConnectContinuation = true
            self.lock.unlock()

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
        lock.lock()
        // Ignore callbacks from stale sessions (e.g. after invalidateAndCancel)
        guard webSocketTask === self.task else {
            logger.debug("[WSM][debug] ignoring didOpenWithProtocol from stale task")
            lock.unlock()
            return
        }
        _connecting = false
        _connected = true
        reconnectAttempts = 0
        logger.debug("[WSM][debug] socket open (didOpenWithProtocol)", connectionId)

        let continuation = connectContinuation
        connectContinuation = nil
        hasActiveConnectContinuation = false
        lock.unlock()

        delegate?.webSocketManagerOnStatusChange(.connected)
        delegate?.webSocketManagerOnConnected()
        continuation?.resume()

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
        lock.lock()
        guard webSocketTask === self.task else {
            logger.debug("[WSM][debug] ignoring didCloseWith from stale task")
            lock.unlock()
            return
        }
        lock.unlock()
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

        lock.lock()
        // Ignore callbacks from stale sessions (e.g. after invalidateAndCancel
        // during reconnect). Without this guard, the stale session's error callback
        // steals the new connection's continuation, causing a leak.
        guard urlSessionTask === self.task else {
            logger.debug("[WSM][debug] ignoring didCompleteWithError from stale task:", error.localizedDescription)
            lock.unlock()
            return
        }
        let continuation = connectContinuation
        connectContinuation = nil
        hasActiveConnectContinuation = false
        _connecting = false
        _connected = false
        lock.unlock()

        if let continuation = continuation {
            continuation.resume(throwing: error)
        }
        handleConnectionClosed(code: nil, reason: error.localizedDescription)
    }

    /// Polls until connection completes (for secondary callers waiting on an in-flight connect).
    private func waitForConnection() async throws {
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            lock.lock()
            let connected = _connected
            let connecting = _connecting
            lock.unlock()
            if connected { return }
            if !connecting {
                throw WebSocketError.connectionFailed("Connection attempt ended without success")
            }
        }
        throw WebSocketError.connectionFailed("Timed out waiting for existing connection")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop(_ wsTask: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()

        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }

                self.lock.lock()
                let currentTask = self.task
                self.lock.unlock()

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

                    self.lock.lock()
                    let stillCurrentTask = self.task === wsTask
                    self.lock.unlock()

                    if stillCurrentTask {
                        self.logger.log("Disconnected from WebSocket server. Error:", error.localizedDescription)
                        self.handleConnectionClosed(
                            code: (error as? URLError)?.errorCode,
                            reason: error.localizedDescription
                        )
                    }
                    return
                }
            }
        }
    }

    // MARK: - Connection Closed Handler

    private func handleConnectionClosed(code: Int?, reason: String?) {
        lock.lock()

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

        // Reject pending connect continuation
        let pendingConnect = connectContinuation
        connectContinuation = nil
        hasActiveConnectContinuation = false

        // Check for disconnect continuation
        let pendingDisconnect = disconnectContinuation
        let wasDisconnecting = isDisconnecting
        let shouldReconnectNow = shouldConnect
        let manualPending = manualReconnectPending

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

        lock.unlock()

        delegate?.webSocketManagerOnStatusChange(.disconnected)
        delegate?.webSocketManagerOnClose(code: code, reason: reason)

        pendingConnect?.resume(throwing: WebSocketError.connectionFailed(
            "WebSocket closed before connected: code=\(code.map(String.init) ?? "nil")"
        ))

        // Clean up session
        if wasTask != nil {
            session?.invalidateAndCancel()
            lock.lock()
            session = nil
            lock.unlock()
        }

        if wasDisconnecting {
            delegate?.webSocketManagerOnDisconnectResolved()
            pendingDisconnect?.resume()
            return
        }

        if manualPending {
            logger.debug("[WSM][debug] manual reconnect trigger fired")
            Task {
                try? await self.connect()
            }
            return
        }

        if shouldReconnectNow, delegate?.webSocketManagerShouldReconnect(code: code, reason: reason) == true {
            let delay = calculateReconnectDelay()
            logger.debug("[WSM][debug] scheduling reconnect", delay)
            delegate?.webSocketManagerOnReconnectScheduled(delayMs: delay)
            scheduleReconnect(delayMs: delay)
        } else {
            logger.debug("[WSM][debug] not scheduling reconnect, shouldConnect:", shouldReconnectNow)
            lock.lock()
            reconnectAttempts = 0
            lock.unlock()
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(delayMs: Int) {
        lock.lock()
        reconnectWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let shouldGo = self.shouldConnect
            self.lock.unlock()

            if shouldGo {
                self.logger.debug("[WSM][debug] reconnect timer fired")
                Task {
                    try? await self.connect()
                }
            } else {
                self.logger.debug("[WSM][debug] reconnect cancelled")
            }
        }
        reconnectWorkItem = workItem
        lock.unlock()

        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(delayMs),
            execute: workItem
        )
    }

    private func calculateReconnectDelay() -> Int {
        lock.lock()
        let baseDelayMs = 200
        let maxSeconds = max(1, maxReconnectDelayMs / 1000)
        let cappedSeconds = min(
            Int(pow(2.0, Double(reconnectAttempts))),
            maxSeconds
        )
        reconnectAttempts += 1
        lock.unlock()
        return baseDelayMs + cappedSeconds * 1000
    }

    // MARK: - Disconnect

    public func disconnect() async {
        lock.lock()

        // Already disconnecting
        if isDisconnecting, disconnectContinuation != nil {
            lock.unlock()
            // Wait for existing disconnect
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Poll until disconnect resolves
                Task {
                    while self.isDisconnecting {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continuation.resume()
                }
            }
            return
        }

        shouldConnect = false
        reconnectAttempts = 0
        _connecting = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        let hadTask = task != nil

        if hadTask {
            lock.unlock()
            delegate?.webSocketManagerOnDisconnectInitiated()
            lock.lock()
        }

        guard let currentTask = task else {
            _connected = false
            isDisconnecting = false
            lock.unlock()
            delegate?.webSocketManagerOnDisconnectResolved()
            return
        }

        isDisconnecting = true
        lock.unlock()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            self.disconnectContinuation = continuation

            // Safety timeout: 500ms
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                guard let pendingContinuation = self.disconnectContinuation else {
                    self.lock.unlock()
                    return
                }
                self.disconnectContinuation = nil
                self.isDisconnecting = false
                self.task = nil
                self._connected = false
                self.lock.unlock()

                self.delegate?.webSocketManagerOnDisconnectResolved()
                pendingContinuation.resume()
            }
            self.disconnectTimeoutWorkItem = timeoutWork
            self.lock.unlock()

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
            // Wait for any pending disconnect
            lock.lock()
            let wasDisconnecting = isDisconnecting
            lock.unlock()

            if wasDisconnecting {
                // Poll until disconnect finishes
                while isDisconnecting {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            lock.lock()
            self.shouldConnect = true
            let connected = _connected
            let connecting = _connecting
            lock.unlock()

            if !connected && !connecting {
                do {
                    try await connect()
                } catch {
                    logger.debug("[WSM][debug] connect failed in setDesiredConnection:", error.localizedDescription)
                }
            } else if connecting {
                // Wait for existing connection attempt
                try? await waitForConnection()
            }
        } else {
            lock.lock()
            self.shouldConnect = false
            lock.unlock()
            await disconnect()
        }
    }

    // MARK: - Force Reconnect

    public func forceReconnect() {
        lock.lock()
        manualReconnectPending = true
        shouldConnect = true
        reconnectAttempts = 0

        if task != nil {
            closeSocketLocked(initiator: "forceReconnect")
            // handleConnectionClosed will be triggered by the receive loop error
            lock.unlock()
        } else {
            lock.unlock()
            Task {
                try? await self.connect()
            }
        }
    }

    // MARK: - Send

    public func send(_ text: String) async throws {
        lock.lock()
        guard let currentTask = task, _connected else {
            lock.unlock()
            throw WebSocketError.notConnected
        }
        lock.unlock()

        try await currentTask.send(.string(text))
    }

    public func send(_ data: Data) async throws {
        lock.lock()
        guard let currentTask = task, _connected else {
            lock.unlock()
            throw WebSocketError.notConnected
        }
        lock.unlock()

        try await currentTask.send(.data(data))
    }

    // MARK: - Close Socket

    public func closeSocket(initiator: String) {
        lock.lock()
        closeSocketLocked(initiator: initiator)
        lock.unlock()
    }

    /// Must be called with lock held.
    private func closeSocketLocked(initiator: String) {
        lastCloseInitiator = initiator
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: initiator.data(using: .utf8))

        // Resume any pending connect continuation to avoid leaked continuations
        if let continuation = connectContinuation {
            connectContinuation = nil
            hasActiveConnectContinuation = false
            _connecting = false
            continuation.resume(throwing: WebSocketError.connectionFailed("Connection closed: \(initiator)"))
        }
    }

    // MARK: - Socket State

    public var isSocketOpen: Bool {
        lock.lock()
        let open = task != nil && task?.state == .running && _connected
        lock.unlock()
        return open
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
