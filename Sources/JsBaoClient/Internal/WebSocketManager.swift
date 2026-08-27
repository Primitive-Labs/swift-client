import Foundation

// MARK: - Delegate Protocol

/// How `WebSocketManager` calls back into `JsBaoClient`.
///
/// Module-internal on purpose (#2363). While this was `public`, `JsBaoClient`'s
/// conformance put all 13 `webSocketManagerOn*` / `webSocketManagerBuild*`
/// methods on the client's public API: app code could read the bearer token out
/// of `webSocketManagerBuildConnectionRequest(connectionId:)`'s `?token=` URL,
/// and could call the `On*` methods to inject connection-lifecycle events the
/// app's own observers would treat as real. Nothing outside the module
/// implements or calls this, and tests reach it through `@testable import`.
///
/// Refined to `Sendable` by #2171: the manager is an `actor` now and calls the
/// delegate from `nonisolated` context, so the reference genuinely crosses
/// isolation domains. `JsBaoClient` — the only conformer — is already
/// `@unchecked Sendable`, so it conforms for free. Every method keeps its
/// signature, including the eleven synchronous ones: an `await` inside
/// `connect()`'s decision region would reopen the double-connect race (#1993
/// decision 2).
protocol WebSocketManagerDelegate: AnyObject, Sendable {
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

/// The client's WebSocket transport and its reconnect state machine.
///
/// An `actor` since #2171. The `NSLock` it used to hold is gone; every piece of
/// connection state below is actor-isolated. Two things that could not follow
/// it into isolation are enumerated in `WebSocketTransportBoxes.swift`, each
/// with its own written safety argument: the transport snapshot the synchronous
/// reads serve from, and the weak delegate the client wires synchronously at
/// construction.
///
/// **The ordered delegate-event channel.** `URLSession` delivers its callbacks
/// on a serial delegate queue, so a class could rely on them arriving in order.
/// An actor cannot: a `nonisolated` callback that hops onto the actor gets no
/// ordering guarantee, and an `open` overtaking a `close` would leave the state
/// machine believing a dead socket is live. Every lifecycle signal that
/// originates outside isolation is therefore emitted into one unbounded
/// `AsyncStream` and consumed by a single pump task, which restores FIFO order
/// by construction rather than by convention.
///
/// Three consequences worth knowing:
///
/// - The callbacks emit **unconditionally**. They cannot read `task` (it is
///   isolated), so they carry the task's `ObjectIdentifier` and the pump drops
///   stale ones — in the same isolated step as the state it guards, which is
///   stronger than the old identity check under a separate lock hold.
/// - `handleConnectionClosed` has exactly **one** caller, `handle(_:)`. All
///   three terminal paths (`didCloseWith`, `didCompleteWithError`, and the
///   receive loop's catch) reach it only through the channel.
/// - The receive loop's *message* path deliberately stays **off** the channel.
///   Messages are not delegate callbacks, and `webSocketManagerOnMessage` is
///   `async`; routing them through the pump would put an `await` inside the
///   ordering region and serialize every inbound frame behind the actor.
actor WebSocketManager: NSObject, URLSessionWebSocketDelegate {

    // MARK: - Delegate events

    /// A lifecycle signal that originated **outside** actor isolation.
    ///
    /// `Sendable` by construction: it carries no `Error` and no
    /// `URLSessionWebSocketTask`, only the task's `ObjectIdentifier` and a
    /// failure already reduced to `WebSocketError`.
    ///
    /// Module-internal rather than private so the ordering suite can drive the
    /// channel directly (`ActorizedWebSocketManagerTests`).
    enum DelegateEvent: Sendable {
        case opened(task: ObjectIdentifier)
        case closed(task: ObjectIdentifier, code: Int, reason: String?)
        case completed(task: ObjectIdentifier, failure: WebSocketError)
        case receiveLoopFailed(task: ObjectIdentifier, code: Int?, failure: WebSocketError)
    }

    // MARK: - Nonisolated state

    private nonisolated let logger: Logger

    /// The transport state the synchronous reads serve from. See
    /// `WebSocketTransportBoxes.swift` for the safety argument. Not `private`
    /// so the ordering suite can observe the live task identity.
    nonisolated let snapshot = WebSocketTransportSnapshot()

    private nonisolated let delegateBox = WeakWebSocketManagerDelegateBox()

    /// Set synchronously, with no window, from `JsBaoClient.setupDependencies()`.
    nonisolated var delegate: (any WebSocketManagerDelegate)? {
        get { delegateBox.value }
        set { delegateBox.value = newValue }
    }

    /// The ordered delegate-event channel. `.unbounded`: a bounded policy that
    /// discarded an `open` or a `close` would desynchronize the state machine
    /// permanently, and the stream has exactly one producer pair (the delegate
    /// queue and the receive loop) emitting once per connection-lifecycle
    /// transition, never per message — so there is nothing here to meter, which
    /// is why it does not borrow `EventEmitter`'s high-water accounting.
    private nonisolated let events: AsyncStream<DelegateEvent>
    private nonisolated let eventContinuation: AsyncStream<DelegateEvent>.Continuation

    /// Stable per-client connection id, minted once at construction. Must be
    /// a ULID, not a UUID: the JS client mints a ULID, and the server's auth
    /// middleware validates the `X-JB-Connection-Id` header against a ULID
    /// regex (`permission-middleware.ts`) — a UUID is silently dropped, which
    /// breaks the #737 `isOrigin` round-trip on `db.change` frames.
    nonisolated let connectionId: String = ULID.generate()

    // MARK: - Isolated state

    private var maxReconnectDelayMs: Int
    private var session: URLSession?
    private var shouldConnect = true
    private var manualReconnectPending = false
    private var reconnectAttempts = 0
    private var lastCloseInitiator: String?
    private var reconnectTask: Task<Void, Never>?

    /// The single consumer of `events`. Captures `self` weakly — a strong
    /// capture would retain the actor for as long as the stream is live, so
    /// `deinit` would never run and the `URLSession` would never be
    /// invalidated: a connection leak on every client teardown.
    private var pump: Task<Void, Never>?

    // Connect continuation (the in-flight connect() call's own continuation)
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // Additional callers that hit connect() while one is already in flight.
    // They are all resumed atomically when the in-flight attempt finishes —
    // success resumes them with `()`, failure with the same error.
    private var pendingConnectWaiters: [CheckedContinuation<Void, Error>] = []

    // Disconnect continuation (the in-flight disconnect() call's own continuation)
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var isDisconnecting = false
    private var disconnectTimeoutTask: Task<Void, Never>?

    // Additional callers that hit disconnect() / setDesiredConnection() while a
    // disconnect is already in flight. Same pattern as `pendingConnectWaiters`.
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

    // Receive loop task
    private var receiveLoopTask: Task<Void, Never>?

    /// Test seam (#2171): the pump reports every event it handled, in handling
    /// order, so the ordering and no-drop behaviors can be observed. Mirrors
    /// `onOutboundFlushedForTest` (#2105).
    var onDelegateEventHandledForTest: (@Sendable (DelegateEvent) -> Void)?

    // MARK: - Transport state, stored in the snapshot box

    /// `connected` / `connecting` / `task` live in `snapshot` rather than in
    /// three more isolated fields. One storage means the synchronous readers
    /// and the actor can never drift apart, and every write below still happens
    /// from inside isolation.
    private var task: URLSessionWebSocketTask? {
        get { snapshot.task }
        set { snapshot.task = newValue }
    }

    private var _connected: Bool {
        get { snapshot.connected }
        set { snapshot.set(connected: newValue, connecting: snapshot.connecting) }
    }

    private var _connecting: Bool {
        get { snapshot.connecting }
        set { snapshot.set(connected: snapshot.connected, connecting: newValue) }
    }

    /// Writes both flags in one hold, for the transitions where a reader must
    /// never catch the pair half-updated (`connecting` off and `connected` on
    /// are the same instant).
    private func setTransportState(connected: Bool, connecting: Bool) {
        snapshot.set(connected: connected, connecting: connecting)
    }

    // MARK: - Decision types

    /// Outcome of the connect() prologue, decided in one isolated step with no
    /// suspension point in it, so the checks and the state mutations that must
    /// be atomic stay atomic. Everything with side effects runs after.
    private enum ConnectDecision {
        case alreadyConnected
        case waitOnExisting
        case abort
        case proceed(any WebSocketManagerDelegate)
    }

    /// Outcome of the disconnect() prologue, decided in one isolated step.
    private enum DisconnectDecision {
        case waitOnExisting
        case proceed(hadTask: Bool, currentTask: URLSessionWebSocketTask?)
    }

    // MARK: - Init

    init(logger: Logger, maxReconnectDelayMs: Int, delegate: (any WebSocketManagerDelegate)? = nil) {
        self.logger = logger
        self.maxReconnectDelayMs = maxReconnectDelayMs
        var continuation: AsyncStream<DelegateEvent>.Continuation!
        self.events = AsyncStream(DelegateEvent.self, bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
        super.init()
        self.delegateBox.value = delegate
        // The pump is started from an isolated step rather than here: `self`
        // has escaped by this point, so the initializer can no longer touch
        // isolated state. Nothing is lost by the hop — the stream is unbounded,
        // so any event emitted before the pump attaches is buffered, and the
        // manager cannot be connected before `init` returns.
        Task { await self.startPump() }
    }

    private func startPump() {
        guard pump == nil else { return }
        let stream = events
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    deinit {
        pump?.cancel()
        eventContinuation.finish()
        receiveLoopTask?.cancel()
        reconnectTask?.cancel()
        disconnectTimeoutTask?.cancel()
        // `snapshot.task`, not the isolated `task` accessor: `deinit` may touch
        // isolated *stored* state, but not a computed property.
        snapshot.task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Accessors

    /// Synchronous **permanently** (sponsor, 2026-08-02, Fork 2 → Option B).
    /// These four read the snapshot box, which is written from inside the actor
    /// on every transition, so they keep the values and the caller-side shape
    /// they had before the conversion.
    nonisolated var isConnected: Bool { snapshot.connected }

    nonisolated var isConnecting: Bool { snapshot.connecting }

    /// The transport state as a single `ConnectionStatus`, read under one lock
    /// hold so `connected` and `connecting` can't be observed inconsistently.
    nonisolated var connectionStatus: ConnectionStatus { snapshot.status }

    nonisolated var isSocketOpen: Bool { snapshot.socketIsOpen }

    /// The strictly-current values, for callers that would rather take an actor
    /// hop than a snapshot. Undeprecated — the synchronous forms above are not
    /// going away.
    var isConnectedAsync: Bool { _connected }

    var isConnectingAsync: Bool { _connecting }

    var connectionStatusAsync: ConnectionStatus { snapshot.status }

    var isSocketOpenAsync: Bool { snapshot.socketIsOpen }

    /// Whether the manager is currently trying to hold a connection open — the
    /// `shouldConnect` intent, not the live transport state. The WS auth
    /// recovery reads it so it never revives a connection the caller
    /// deliberately took down (#2637).
    var desiredConnection: Bool { shouldConnect }

    func setMaxReconnectDelay(_ ms: Int) {
        guard ms > 0 else { return }
        maxReconnectDelayMs = ms
    }

    var shouldConnectFlag: Bool { shouldConnect }

    /// Set the "should the manager hold a connection open" flag without
    /// touching the socket — `setDesiredConnection` is the form that also
    /// connects or disconnects. Mirrors JS `setShouldConnectFlag`. Its caller
    /// is the auth transition: a token arriving where there was none re-arms a
    /// connection an earlier logout took down (#2663).
    func setShouldConnectFlag(_ value: Bool) {
        logger.debug("[WSM][debug] setShouldConnectFlag", value)
        shouldConnect = value
    }

    func setEventHandledHookForTest(_ hook: (@Sendable (DelegateEvent) -> Void)?) {
        onDelegateEventHandledForTest = hook
    }

    // MARK: - Connect

    func connect() async throws {
        switch connectDecision() {
        case .alreadyConnected, .abort:
            return
        case .waitOnExisting:
            try await waitForInFlightConnect()
        case .proceed(let delegate):
            try await performConnect(with: delegate)
        }
    }

    /// The connect decision region. It contains **no `await`** — actor
    /// isolation is reentrant, so a suspension between the `_connecting` check
    /// and the `_connecting = true` commit would let a second caller take the
    /// same decision and open a second socket.
    private func connectDecision() -> ConnectDecision {
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

        // An explicit disconnect means "stay down". `connect()` does not
        // override it — JS returns immediately here
        // (`webSocketManager.ts` `connect aborted: shouldConnect=false`), and
        // before #2663 this line silently re-armed the reconnect loop after a
        // `disconnect()` or a logout. `setDesiredConnection(true)` and
        // `forceReconnect()` set the flag themselves and are the way back up.
        if !shouldConnect {
            logger.debug("[WSM][debug] connect aborted: shouldConnect=false")
            return .abort
        }

        guard let delegate = delegate else {
            return .abort
        }

        if !delegate.webSocketManagerHasAccessToken() {
            logger.debug("[CONNECT] Skipping connect: no access token present")
            return .abort
        }

        // Clean up existing socket
        if task != nil {
            closeSocketNow(initiator: "connect:cleanup")
            task = nil
        }

        // Mark as connecting early to prevent concurrent connect() calls
        // from racing past the _connecting check above.
        _connecting = true

        logger.debug("[WSM][debug] initiating connect", connectionId)
        return .proceed(delegate)
    }

    /// Park a secondary caller on the in-flight attempt.
    ///
    /// The class needed a `ConnectWaiterResolution` re-check here, because the
    /// decision and the registration were two separate lock holds and the
    /// attempt could finish in the gap. There is no gap now:
    /// `withCheckedThrowingContinuation`'s body runs synchronously inside actor
    /// isolation, so the registration lands in the same isolated step as the
    /// `_connecting` check that chose this path (#2171 Fork 3).
    private func waitForInFlightConnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.pendingConnectWaiters.append(continuation)
        }
    }

    private func performConnect(with delegate: any WebSocketManagerDelegate) async throws {
        delegate.webSocketManagerOnConnecting()

        let (url, headers) = delegate.webSocketManagerBuildConnectionRequest(connectionId: connectionId)

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Create URLSession with self as delegate to get didOpenWithProtocol callback.
        // This is the equivalent of JavaScript's WebSocket 'onopen' event.
        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let oldSession = session
        session = newSession
        let newTask = newSession.webSocketTask(with: request)
        task = newTask
        _connecting = true

        // Invalidate the old session AFTER setting the new task, so any stale
        // callbacks that sneak through are filtered by the task identity guard
        // in `handle(_:)`.
        oldSession?.invalidateAndCancel()

        delegate.webSocketManagerOnStatusChange(.connecting)

        // Wait for the didOpenWithProtocol delegate callback to fire.
        // IMPORTANT: store the continuation BEFORE resuming the task, or the
        // callback can land before there is anything to resume.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation
            newTask.resume()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    // These run outside actor isolation and cannot read `task`, so they filter
    // nothing: they emit unconditionally and the pump drops stale events.

    /// Called when the WebSocket handshake completes — equivalent to JS's 'onopen'.
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        emit(.opened(task: ObjectIdentifier(webSocketTask)))
    }

    /// Called when the WebSocket closes.
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        emit(.closed(task: ObjectIdentifier(webSocketTask), code: closeCode.rawValue, reason: reasonStr))
    }

    /// Called on task completion with error (connection failure).
    nonisolated func urlSession(
        _ session: URLSession,
        task urlSessionTask: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        emit(.completed(task: ObjectIdentifier(urlSessionTask), failure: Self.transportFailure(from: error)))
    }

    /// Reduce a non-`Sendable` `Error` to the `Sendable` value the channel
    /// carries. The message is the original `localizedDescription` verbatim, so
    /// `ConnectionErrorEvent.message` text is unchanged.
    ///
    /// Built from `JsBaoNetworkError(transport:)` — the client's one
    /// error-to-(message, code) mapping — so the WS and HTTP failure paths
    /// cannot report the same underlying failure differently (#2367).
    private nonisolated static func transportFailure(from error: Error) -> WebSocketError {
        let normalized = JsBaoNetworkError(transport: error)
        return .transportFailure(message: normalized.message, code: normalized.urlErrorCode)
    }

    /// Yield onto the ordered channel. `nonisolated`, so every producer —
    /// delegate queue or receive loop — reaches it without an actor hop.
    nonisolated func emit(_ event: DelegateEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - The pump

    /// The channel's only consumer and the **only** caller of
    /// `handleConnectionClosed`.
    ///
    /// Deliberately not `async`: it is the decision region for every lifecycle
    /// signal, and a suspension anywhere in it would let the next event
    /// interleave and destroy the ordering the channel exists to provide. The
    /// compiler enforces that here — a non-`async` function cannot `await`.
    private func handle(_ event: DelegateEvent) {
        // Reported on the way IN: a test that needs to stall the pump *before*
        // an event is applied hooks here (behavior 13). Ordering the other way
        // — "event N has been fully handled" — is available without a second
        // hook, because the channel is FIFO and this method cannot suspend: a
        // report for any later event proves every earlier one finished. The
        // stale-event tests use a sentinel event for exactly that.
        onDelegateEventHandledForTest?(event)

        switch event {
        case .opened(let taskId):
            guard let current = currentTask(matching: taskId, "didOpenWithProtocol") else { return }
            handleSocketOpened(current)

        case .closed(let taskId, let code, let reason):
            guard currentTask(matching: taskId, "didCloseWith") != nil else { return }
            logger.debug("[WSM][debug] didCloseWith", code, reason ?? "")
            handleConnectionClosed(code: code, reason: reason)

        case .completed(let taskId, let failure):
            guard currentTask(matching: taskId, "didCompleteWithError") != nil else { return }
            // Transport-level failure. The pending connect continuation and its
            // waiters take the transport error itself; the close that follows
            // mirrors the JS client's 'error' + 'close' pair.
            let pending = connectContinuation
            connectContinuation = nil
            let waiters = pendingConnectWaiters
            pendingConnectWaiters.removeAll()
            setTransportState(connected: false, connecting: false)
            pending?.resume(throwing: failure)
            for waiter in waiters { waiter.resume(throwing: failure) }
            handleConnectionClosed(code: nil, reason: failure.localizedDescription, error: failure)

        case .receiveLoopFailed(let taskId, let code, let failure):
            guard currentTask(matching: taskId, "receive loop") != nil else { return }
            handleConnectionClosed(code: code, reason: failure.localizedDescription, error: failure)
        }
    }

    /// The stale-event filter, run inside isolation — in the same step as the
    /// state it guards, which the old `lock.withLock { webSocketTask === task }`
    /// check could not be.
    private func currentTask(matching taskId: ObjectIdentifier, _ what: String) -> URLSessionWebSocketTask? {
        guard let current = task, ObjectIdentifier(current) == taskId else {
            logger.debug("[WSM][debug] ignoring \(what) from stale task")
            return nil
        }
        return current
    }

    private func handleSocketOpened(_ openedTask: URLSessionWebSocketTask) {
        setTransportState(connected: true, connecting: false)
        reconnectAttempts = 0
        logger.debug("[WSM][debug] socket open (didOpenWithProtocol)", connectionId)

        let continuation = connectContinuation
        connectContinuation = nil
        let waiters = pendingConnectWaiters
        pendingConnectWaiters.removeAll()

        delegate?.webSocketManagerOnStatusChange(.connected)
        delegate?.webSocketManagerOnConnected()
        continuation?.resume()
        for waiter in waiters { waiter.resume() }

        startReceiveLoop(openedTask)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop(_ wsTask: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()
        receiveLoopTask = makeReceiveLoop(wsTask)
    }

    /// Built from a `nonisolated` factory so the loop body does not inherit
    /// actor isolation: every inbound frame would otherwise be delivered from
    /// the actor's executor.
    private nonisolated func makeReceiveLoop(_ wsTask: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }

                // A snapshot read, not an actor hop: the box is written from
                // inside the actor on every task change, so this is the same
                // value an isolated read would give, at no per-message cost.
                guard self.snapshot.task === wsTask else { return }

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
                    self.logger.log("Disconnected from WebSocket server. Error:", error.localizedDescription)
                    // Established-connection transport failure. It joins the
                    // channel like every other terminal signal, so the pump's
                    // once-only `wasTask` claim still fires `.connectionError`
                    // exactly once whichever path surfaces the failure first.
                    // Deliberate closes cancel this loop, so `Task.isCancelled`
                    // short-circuits above and never reaches here.
                    self.emit(
                        .receiveLoopFailed(
                            task: ObjectIdentifier(wsTask),
                            code: (error as? URLError)?.errorCode,
                            failure: Self.transportFailure(from: error)
                        )
                    )
                    return
                }
            }
        }
    }

    // MARK: - Connection Closed Handler

    /// Reached **only** from `handle(_:)` — every terminal path funnels through
    /// the ordered channel first.
    private func handleConnectionClosed(code: Int?, reason: String?, error: Error? = nil) {
        if let initiator = lastCloseInitiator {
            logger.warn("[WS-CLOSE] observed", initiator)
        }

        let wasTask = task
        task = nil
        setTransportState(connected: false, connecting: false)

        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        let pendingConnect = connectContinuation
        connectContinuation = nil
        let drainedWaiters = pendingConnectWaiters
        pendingConnectWaiters.removeAll()

        let pendingDisconnect = disconnectContinuation
        let wasDisconnecting = isDisconnecting
        let shouldReconnectNow = shouldConnect
        let manualPending = manualReconnectPending
        let drainedDisconnectWaiters = disconnectWaiters
        disconnectWaiters.removeAll()

        if pendingDisconnect != nil {
            disconnectContinuation = nil
            isDisconnecting = false
            disconnectTimeoutTask?.cancel()
            disconnectTimeoutTask = nil
        }

        if manualPending {
            manualReconnectPending = false
        }

        lastCloseInitiator = nil

        // `.connectionError` fires here exactly once per transport failure. The
        // `wasTask` claim above is the once-only guard: whichever terminal
        // event the pump handles first nils the task, so a second event for the
        // same failure is already dropped by the stale filter. A graceful close
        // passes `error: nil` and emits no error — mirroring the JS client
        // emitting 'error' only on a transport error and 'close' on every
        // close. Emitted before the close so subscribers see error-then-close.
        if let error, wasTask != nil {
            delegate?.webSocketManagerOnError(error)
        }

        delegate?.webSocketManagerOnStatusChange(.disconnected)
        delegate?.webSocketManagerOnClose(code: code, reason: reason)

        let closeError = WebSocketError.connectionFailed(
            "WebSocket closed before connected: code=\(code.map(String.init) ?? "nil")"
        )
        pendingConnect?.resume(throwing: closeError)
        for waiter in drainedWaiters {
            waiter.resume(throwing: closeError)
        }

        if wasTask != nil {
            let staleSession = session
            session = nil
            staleSession?.invalidateAndCancel()
        }

        if wasDisconnecting {
            delegate?.webSocketManagerOnDisconnectResolved()
            pendingDisconnect?.resume()
            for waiter in drainedDisconnectWaiters {
                waiter.resume()
            }
            return
        }

        if manualPending {
            logger.debug("[WSM][debug] manual reconnect trigger fired")
            Task { try? await self.connect() }
            return
        }

        if shouldReconnectNow, delegate?.webSocketManagerShouldReconnect(code: code, reason: reason) == true {
            let delay = calculateReconnectDelay()
            logger.debug("[WSM][debug] scheduling reconnect", delay)
            delegate?.webSocketManagerOnReconnectScheduled(delayMs: delay)
            scheduleReconnect(delayMs: delay)
        } else {
            logger.debug("[WSM][debug] not scheduling reconnect, shouldConnect:", shouldReconnectNow)
            reconnectAttempts = 0
        }
    }

    // MARK: - Reconnect

    /// A cancellable `Task.sleep`, replacing the `DispatchWorkItem` the class
    /// used. Same pattern as `AnalyticsQueue.makeFlushTimer()`: the body is
    /// built by a `nonisolated` factory so arming it needs no suspension.
    private func scheduleReconnect(delayMs: Int) {
        reconnectTask?.cancel()
        reconnectTask = makeReconnectTimer(delayMs: delayMs)
    }

    private nonisolated func makeReconnectTimer(delayMs: Int) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await self.fireReconnect()
        }
    }

    private func fireReconnect() {
        reconnectTask = nil
        guard shouldConnect else {
            logger.debug("[WSM][debug] reconnect cancelled")
            return
        }
        logger.debug("[WSM][debug] reconnect timer fired")
        Task { try? await self.connect() }
    }

    private func calculateReconnectDelay() -> Int {
        let delay = Self.reconnectDelayMs(
            attempts: reconnectAttempts,
            maxReconnectDelayMs: maxReconnectDelayMs
        )
        reconnectAttempts += 1
        return delay
    }

    /// Pure exponential-backoff delay computation, split out so it can be unit
    /// tested independently of the manager's isolation and socket state.
    ///
    /// The cap is applied in the `Double` domain *before* converting to `Int`.
    /// Doing the `min` in `Int` (via `Int(pow(2.0, …))` first) traps once
    /// `attempts` reaches ~63, where `pow(2, attempts)` exceeds `Int.max` and
    /// the `Double → Int` conversion crashes before the cap can clamp it. In
    /// `Double`, an overflowing `pow` simply yields `.infinity`, and
    /// `min(.infinity, Double(maxSeconds))` picks the finite cap, so the final
    /// `Int(...)` is always in range regardless of how high `attempts` climbs.
    nonisolated static func reconnectDelayMs(attempts: Int, maxReconnectDelayMs: Int) -> Int {
        let baseDelayMs = 200
        let maxSeconds = max(1, maxReconnectDelayMs / 1000)
        let cappedSeconds = Int(min(pow(2.0, Double(attempts)), Double(maxSeconds)))
        return baseDelayMs + cappedSeconds * 1000
    }

    // MARK: - Disconnect

    func disconnect() async {
        let hadTask: Bool
        let currentTask: URLSessionWebSocketTask?
        switch disconnectDecision() {
        case .waitOnExisting:
            await waitForInFlightDisconnect()
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
            self.disconnectContinuation = continuation
            self.disconnectTimeoutTask = self.makeDisconnectTimeout()

            // Cancel the receive loop first, then close the socket gracefully.
            self.receiveLoopTask?.cancel()
            currentTask.cancel(with: .normalClosure, reason: nil)
        }
    }

    /// The disconnect decision region. No `await` — see `connectDecision()`.
    private func disconnectDecision() -> DisconnectDecision {
        // Already disconnecting — resolve as a waiter below.
        if isDisconnecting {
            return .waitOnExisting
        }

        shouldConnect = false
        reconnectAttempts = 0
        _connecting = false
        reconnectTask?.cancel()
        reconnectTask = nil

        let hadTask = task != nil
        let currentTask = task
        if currentTask != nil {
            isDisconnecting = true
        } else {
            setTransportState(connected: false, connecting: false)
            isDisconnecting = false
        }
        return .proceed(hadTask: hadTask, currentTask: currentTask)
    }

    /// Park on the in-flight disconnect. Registration is atomic with the
    /// `isDisconnecting` check for the same reason `waitForInFlightConnect()`
    /// is: the continuation body runs synchronously inside isolation.
    private func waitForInFlightDisconnect() async {
        guard isDisconnecting else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.disconnectWaiters.append(continuation)
        }
    }

    /// The 500 ms safety timeout for a disconnect whose close callback never
    /// arrives.
    private nonisolated func makeDisconnectTimeout() -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500 * 1_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await self.fireDisconnectTimeout()
        }
    }

    /// Mutually exclusive with `handleConnectionClosed` by an atomic
    /// check-and-nil of `disconnectContinuation`. Under the class this was
    /// atomic only because both paths took the same `NSLock`; it is genuinely
    /// atomic now — this method contains no suspension point.
    private func fireDisconnectTimeout() {
        guard let pendingContinuation = disconnectContinuation else { return }
        disconnectContinuation = nil
        isDisconnecting = false
        disconnectTimeoutTask = nil
        task = nil
        _connected = false
        let drainedWaiters = disconnectWaiters
        disconnectWaiters.removeAll()

        delegate?.webSocketManagerOnDisconnectResolved()
        pendingContinuation.resume()
        for waiter in drainedWaiters {
            waiter.resume()
        }
    }

    // MARK: - setDesiredConnection

    /// Set whether the manager should hold a connection open.
    ///
    /// `shouldConnect: true` parks on a disconnect that is already in flight
    /// and then connects, so a connect issued while the socket is closing does
    /// not race the close.
    ///
    /// **Last writer wins**, with one exception. That parking is the only
    /// ordering guarantee: it applies to a disconnect already in flight, not
    /// to one that arrives afterwards. Calls issued concurrently with no
    /// ordering between them settle on whichever reaches the manager last, so
    /// a `disconnect()` that lands after
    /// `setDesiredConnection(shouldConnect: true)` leaves the manager
    /// disconnected with auto-reconnect off — an explicit disconnect means
    /// "stay down" and is not overridden by an earlier connect.
    ///
    /// The exception is a **coalesced** disconnect. A `disconnect()` that
    /// arrives while another disconnect is still in flight takes
    /// `disconnectDecision()`'s `.waitOnExisting` branch: it waits the
    /// in-flight close out and returns, without re-running the decision region
    /// and without cancelling a `setDesiredConnection(shouldConnect: true)`
    /// already parked on that same close. So in the sequence `disconnect()` →
    /// `setDesiredConnection(shouldConnect: true)` → `disconnect()`, the
    /// parked connect resumes once the first close resolves and the manager
    /// ends up **connected**, even though a disconnect was issued last.
    ///
    /// Callers that need a particular outcome must order the calls themselves
    /// — await one before making the next. The JS client's `setShouldConnect`
    /// follows the same rule, coalescing exception included (#2568).
    func setDesiredConnection(shouldConnect: Bool) async {
        logger.debug(
            "[WSM][debug] setDesiredConnection", shouldConnect,
            "connected:", _connected, "connecting:", _connecting
        )

        if shouldConnect {
            // Wait for any pending disconnect to finish before reconnecting.
            await waitForInFlightDisconnect()

            self.shouldConnect = true

            // `connect()` is idempotent: it returns immediately if already
            // connected, registers on the `pendingConnectWaiters` list if a
            // connect is already in flight, or starts a fresh connect.
            do {
                try await connect()
            } catch {
                logger.debug("[WSM][debug] connect failed in setDesiredConnection:", error.localizedDescription)
            }
        } else {
            self.shouldConnect = false
            await disconnect()
        }
    }

    // MARK: - Force Reconnect

    func forceReconnect() {
        manualReconnectPending = true
        shouldConnect = true
        reconnectAttempts = 0

        if task != nil {
            closeSocketNow(initiator: "forceReconnect")
            // The close lands as a channel event (`didCloseWith` /
            // `didCompleteWithError`, or the receive loop's failure), and the
            // pump takes it from there — `manualReconnectPending` is what tells
            // `handleConnectionClosed` to reconnect immediately.
            return
        }

        Task { try? await self.connect() }
    }

    // MARK: - Send

    /// `nonisolated`: the task is read from the snapshot box and the frame goes
    /// out off the actor, so concurrent sends stay concurrent and the
    /// per-message path takes no actor hop.
    nonisolated func send(_ text: String) async throws {
        guard let currentTask = snapshot.sendableTask else {
            throw WebSocketError.notConnected
        }
        try await currentTask.send(.string(text))
    }

    nonisolated func send(_ data: Data) async throws {
        guard let currentTask = snapshot.sendableTask else {
            throw WebSocketError.notConnected
        }
        try await currentTask.send(.data(data))
    }

    // MARK: - Close Socket

    func closeSocket(initiator: String) {
        closeSocketNow(initiator: initiator)
    }

    /// Isolated: it mutates the continuation state directly. (Under the class
    /// this was `closeSocketLocked` and carried a "must be called with lock
    /// held" contract; actor isolation makes the contract structural.)
    private func closeSocketNow(initiator: String) {
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
}
