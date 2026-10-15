import Foundation

// A live view of one agent session over its synced document (#3810) — the
// Swift half of the JS client's `src/client/agents/sessionView.ts`, rule for
// rule.
//
// `client.agents.sessions.open` reads the session (`get`), registers the
// platform models, opens the session's document and keeps a window of the
// latest messages by `seq` with their parts and steps; `loadOlder()` pages
// back. Every query names the session's document, so a client with several
// sessions open never mixes them. Your own messages appear at once as pending
// entries, keyed by a client message id, and leave once the row the server
// accepted is in the window; a refused send stays as `.failed`.
//
// Swift carries no `uiMessages()`: the AI SDK adapter is the JS client's.
// Read a part's typed `content` instead.
//
// `info` follows the server's `AgentSessionChangedEvent`s for the session, and
// is read again after a reconnect; `markRead: .whileOpen` keeps the session
// read while the view is open.

/// When an open view marks its session read by itself.
public enum AgentSessionMarkRead: Sendable, Equatable {
    /// Once the view is open, and again whenever new activity arrives while
    /// it is open (or a reconnect finds it unread), so activity you watched
    /// arrive does not stay unread on your other devices. Nothing is sent for
    /// an app owner or admin who is not in the session, or after `close()`;
    /// a failed mark is retried on the next activity or reconnect.
    case whileOpen
}

/// Options for `client.agents.sessions.open`.
public struct OpenAgentSessionOptions: Sendable {
    /// Messages per page, 1 to 500: the first window and each `loadOlder()`.
    public var pageSize: Int
    /// How to open the document. `nil` opens it with
    /// `waitForLoad: .network, enableNetworkSync: true`.
    public var open: OpenDocumentOptions?
    /// `.whileOpen` keeps the session read while the view is open; `nil`
    /// marks it read only when you call `markRead()`.
    public var markRead: AgentSessionMarkRead?

    public init(pageSize: Int = 50, open: OpenDocumentOptions? = nil, markRead: AgentSessionMarkRead? = nil) {
        self.pageSize = pageSize
        self.open = open
        self.markRead = markRead
    }
}

/// Why a send failed: the server's code and message, and when to retry a
/// rate-limited one.
public struct AgentSessionSendError: Sendable, Equatable {
    public let code: String
    public let message: String
    /// Seconds, for `AGENT_SESSION_RATE_LIMITED`.
    public let retryAfter: Double?

    public init(code: String, message: String, retryAfter: Double? = nil) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }
}

/// A message in the view's window, synced from the document.
public struct AgentSessionSyncedMessage: Sendable, Equatable {
    /// `.queued` while the session's queue names the message, waiting for its
    /// turn.
    public enum State: Sendable, Equatable {
        case synced
        case queued
    }

    public let messageId: String
    public let seq: Double
    public let clientMessageId: String?
    public let message: PrimitiveMessage
    /// The message's parts, by `seq` then id.
    public let parts: [PrimitivePart]
    /// The steps of the message's turn, by `seq`; `[]` when it has none.
    public let steps: [PrimitiveStep]
    public let state: State
}

/// One of your messages the view shows before its row is synced, or that the
/// server refused. It exists only in the view that sent it.
public struct AgentSessionPendingMessage: Sendable, Equatable {
    /// `.sending` until its row is in the window (the entry then leaves);
    /// `.failed` when refused.
    public enum State: Sendable, Equatable {
        case sending
        case failed
    }

    public let clientMessageId: String
    public let text: String
    public let files: [AgentSessionFileRef]
    public let context: JSONValue?
    public let timezone: String?
    public let locale: String?
    public let state: State
    /// The id the server accepted the message under, once it answered.
    public let messageId: String?
    public let error: AgentSessionSendError?
    /// ISO-8601; when `send` was called.
    public let createdAt: String

    /// Which delivery this entry belongs to, so a late answer to an attempt
    /// that was replaced never rewrites the entry that replaced it.
    let attempt: UUID

    func with(
        state: State, messageId: String? = nil, error: AgentSessionSendError? = nil, attempt: UUID? = nil
    ) -> AgentSessionPendingMessage {
        AgentSessionPendingMessage(
            clientMessageId: clientMessageId, text: text, files: files, context: context,
            timezone: timezone, locale: locale, state: state, messageId: messageId,
            error: error, createdAt: createdAt, attempt: attempt ?? self.attempt
        )
    }

    var body: AgentSessionSendBody {
        AgentSessionSendBody(
            text: text, files: files.isEmpty ? nil : files, clientMessageId: clientMessageId,
            context: context, timezone: timezone, locale: locale
        )
    }
}

/// A message in the view: synced from the document, or pending.
public enum AgentSessionViewMessage: Sendable, Equatable {
    case synced(AgentSessionSyncedMessage)
    case pending(AgentSessionPendingMessage)
}

/// What `loadOlder()` answers.
public struct AgentSessionLoadOlderResult: Sendable, Equatable {
    /// How many messages the page added.
    public let loaded: Int
    /// Whether still older messages remain.
    public let hasOlder: Bool

    public init(loaded: Int, hasOlder: Bool) {
        self.loaded = loaded
        self.hasOlder = hasOlder
    }
}

/// A live view of one agent session, from `client.agents.sessions.open`.
///
/// Read its state through the properties (they change as the document
/// syncs), and call `onChange` to hear about every change. `close()` when
/// done.
///
/// Opening the same session twice on one client gives two views over one
/// open document; closing either closes the document for both.
public final class AgentSessionView: @unchecked Sendable {
    static let defaultPageSize = 50
    static let maxPageSize = 500
    /// Ids per `$in` query.
    static let inChunk = 100
    /// How long a change waits for others before the view reads them.
    static let refreshCoalesceWindow: DispatchTimeInterval = .milliseconds(15)

    private let api: AgentSessionsAPI
    private let client: JsBaoClient
    private let pageSize: Int
    /// Every refresh and page load runs here, one at a time.
    private let work = DispatchQueue(label: "agent-session-view")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var _info: AgentSessionInfo
    private var window: [String: PrimitiveMessage] = [:]
    private var partsByMessage: [String: [PrimitivePart]] = [:]
    private var steps: [PrimitiveStep] = []
    private var olderRemain = false
    private var sessionRecord: PrimitiveSession?
    private var sessionRow: [String: JSONValue]?
    private var pendingEntries: [AgentSessionPendingMessage] = []
    private var view: [AgentSessionViewMessage] = []
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    private var unsubscribes: [@Sendable () -> Void] = []
    private var refreshQueued = false
    private var olderInFlight: Task<AgentSessionLoadOlderResult, Error>?
    private var closed = false
    /// Client-tool handlers by tool name.
    private var toolHandlers: [String: ClientToolRegistration] = [:]
    /// The calls a handler runs now, by call id.
    private var runningCalls: [String: RunningClientTool] = [:]
    private var runningOrder: [String] = []
    /// Calls this view answered (or lost to another answer), by call id: their turn.
    private var answeredCalls: [String: String] = [:]
    /// Calls the server refused an answer for, by call id: their turn and the
    /// state they were in.
    private var failedCalls: [String: (turnId: String, state: String)] = [:]
    private var evaluateQueued = false
    private var syncTask: Task<Void, Never>?
    /// The change events and connection states, heard since before `get`.
    private let signals: AgentSessionViewSignals
    /// For each `get` in flight, the changes made to `info` since it was
    /// sent, made again over its answer so it never undoes them (CSO-4380-002).
    private var infoReads: [UUID: [@Sendable (AgentSessionInfo) -> AgentSessionInfo]] = [:]
    /// The `at` of the latest change event applied to `info`, in milliseconds.
    private var infoAt: Double?
    /// When the session was removed for you: an older upsert is ignored.
    private var removedAt: Double?
    /// Whether the connection now up has been heard since `info` was read.
    private var live = false
    private let markWhileOpen: Bool
    private var reading = false
    private var readAgain = false
    /// Set once a mark is refused not found: the session is no longer yours.
    private var readStopped = false
    private var reconciling = false
    private var reconcileAgain = false
    /// The reconnect's reads of `info`, cancelled by `close()` (CSO-4380-015).
    private var reconcileTask: Task<Void, Never>?

    private struct ClientToolRegistration: Sendable {
        let id: UUID
        let handler: AgentClientToolHandler
        let onError: (@Sendable (AgentClientToolError) -> Void)?
    }

    private struct RunningClientTool {
        let id: UUID
        var task: Task<Void, Never>?
    }

    init(
        api: AgentSessionsAPI, client: JsBaoClient, info: AgentSessionInfo, pageSize: Int,
        markWhileOpen: Bool = false, connectedAtOpen: Bool = false, signals: AgentSessionViewSignals? = nil
    ) {
        self.api = api
        self.client = client
        self._info = info
        self.pageSize = pageSize
        self.markWhileOpen = markWhileOpen
        self.live = connectedAtOpen
        self.signals = signals ?? AgentSessionViewSignals(client: client)
    }

    // MARK: - State

    /// The session's info as `get` answered it, kept current by the server's
    /// change events (title, last activity, the dot, members, status) and read
    /// again after a reconnect; `refreshInfo()` reads it again on demand.
    public var info: AgentSessionInfo { lock.withLock { _info } }

    /// The session's id.
    public var sessionId: String { info.sessionId }

    /// The session's document.
    public var documentId: String { info.documentId }

    /// The session row, decoded; `nil` until it has synced or when it does not
    /// decode.
    public var session: PrimitiveSession? { lock.withLock { sessionRecord } }

    /// The session row's status; `nil` until it has synced. A status outside
    /// the vocabulary reads `.unknown(raw)`.
    public var status: PrimitiveSessionStatus? { session?.status }

    /// The active turn the session row names, or `nil`.
    public var activeTurnId: String? { session?.activeTurnId }

    /// The authors waiting behind the active turn, with their messages, from
    /// the session row.
    public var queue: [PrimitiveQueueEntry] { session?.queue ?? [] }

    /// The window's synced messages, oldest first, then your pending ones.
    public var messages: [AgentSessionViewMessage] { lock.withLock { view } }

    /// Whether older messages than the window's oldest remain (`loadOlder()`).
    public var hasOlder: Bool { lock.withLock { olderRemain } }

    /// Listen for changes: to the window, the session row or your pending
    /// messages. Called once per change, never while the view holds its lock.
    ///
    /// - Returns: A function that removes the listener.
    @discardableResult
    public func onChange(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.withLock {
            guard !closed else { return }
            listeners[id] = listener
        }
        return { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.listeners.removeValue(forKey: id) }
        }
    }

    // MARK: - Sending

    /// Send a message. A pending entry appears at once (`.sending`) and leaves
    /// once the row the server accepted is in the window; on a refusal it
    /// becomes `.failed` with the server's code and the call throws the same
    /// error. A `clientMessageId` is generated when none is given, so a
    /// `retry` is deduplicated.
    @discardableResult
    public func send(
        text: String,
        files: [AgentSessionFileRef] = [],
        clientMessageId: String? = nil,
        context: JSONValue? = nil,
        timezone: String? = nil,
        locale: String? = nil
    ) async throws -> AgentSessionSendResult {
        if let context, context.objectValue == nil {
            throw JsBaoError(
                code: .invalidArgument, message: "context must be a JSON object",
                details: ["field": .string("context")]
            )
        }
        let entry = AgentSessionPendingMessage(
            clientMessageId: clientMessageId ?? PrimitiveSchemaRegistry.generateULID(),
            text: text, files: files, context: context, timezone: timezone, locale: locale,
            state: .sending, messageId: nil, error: nil,
            createdAt: Self.isoNow(), attempt: UUID()
        )
        return try await deliver(entry)
    }

    /// Send a failed message again, with the same text, files, context,
    /// timezone, locale and client message id, so a first attempt that did
    /// land answers as a duplicate. Throws `.invalidArgument` when no failed
    /// message has that id.
    @discardableResult
    public func retry(clientMessageId: String) async throws -> AgentSessionSendResult {
        let failed = lock.withLock {
            pendingEntries.first { $0.clientMessageId == clientMessageId && $0.state == .failed }
        }
        guard let failed else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "No failed message with clientMessageId \"\(clientMessageId)\" to retry"
            )
        }
        return try await deliver(failed.with(state: .sending, attempt: UUID()))
    }

    /// Remove a failed message from the view.
    ///
    /// - Returns: Whether a failed message was removed.
    @discardableResult
    public func dismiss(clientMessageId: String) -> Bool {
        let removed: Bool = lock.withLock {
            let before = pendingEntries.count
            pendingEntries.removeAll { $0.clientMessageId == clientMessageId && $0.state == .failed }
            guard pendingEntries.count != before else { return false }
            _ = rebuildLocked()
            return true
        }
        if removed { notify() }
        return removed
    }

    // MARK: - Paging

    /// Load the page of messages before the window's oldest, with their parts
    /// and steps. Calls made while one is loading share its page; at the start
    /// of the session, or after `close()`, it answers `{ 0, false }`.
    public func loadOlder() async throws -> AgentSessionLoadOlderResult {
        let task: Task<AgentSessionLoadOlderResult, Error> = lock.withLock {
            if let olderInFlight { return olderInFlight }
            let task = Task { try await self.onWorkQueue { try self.loadOlderNow() } }
            olderInFlight = task
            return task
        }
        defer {
            lock.withLock { if olderInFlight == task { olderInFlight = nil } }
        }
        return try await task.value
    }

    // MARK: - Turns

    /// Answer a call the active turn waits on.
    @discardableResult
    public func answer(callId: String, _ answer: AgentCallAnswer) async throws -> AgentCallAnswerResult {
        try await api.answer(sessionId: sessionId, callId: callId, answer)
    }

    /// A tool call's artifact: the same value whether the server stored it
    /// inline or, being large, as a blob on the session's document, which is
    /// read only now. `nil` when the call has none or `part` is not a tool
    /// call; `.null` for a stored JSON null.
    ///
    /// Throws `.invalidArgument` on a closed view, the blob read's error for
    /// a download that fails, and a `DecodingError` for a blob that is not
    /// JSON.
    public func artifact(of part: PrimitivePart) async throws -> JSONValue? {
        if lock.withLock({ closed }) {
            throw JsBaoError(code: .invalidArgument, message: "The session view is closed")
        }
        guard case .toolCall(let call) = part.content else { return nil }
        guard let blobId = call.artifactBlobId, !blobId.isEmpty else { return call.artifact }
        return try await client.documents.blobs(documentId: documentId).read(blobId: blobId, as: JSONValue.self)
    }

    /// The presentations an agent message carries: each `tool_call` part in
    /// `output-available` state whose tool is one of `names`, in part order.
    /// A part alone does not say whether its tool is a presentation, so pass
    /// the generated `<Key>Agent.presentationNames`. A refused presentation
    /// (`output-error`) and a message that is not the agent's yield none.
    /// `call(_:)` on each resolves numbers against the turn's parts in the
    /// window.
    public func presentations(of message: PrimitiveMessage, names: [String]) -> [AgentPresentation] {
        lock.withLock {
            let turnParts: [PrimitivePart] = message.turnId.map { turnId in
                window.values
                    .filter { $0.turnId == turnId }
                    .flatMap { partsByMessage[$0.id] ?? [] }
            } ?? []
            return AgentPresentation.collect(
                message: message, parts: partsByMessage[message.id] ?? [], turnParts: turnParts, names: names
            )
        }
    }

    /// Record an event on the session.
    @discardableResult
    public func recordEvent(_ event: AgentSessionEvent) async throws -> AgentSessionEventResult {
        try await api.recordEvent(sessionId: sessionId, event: event)
    }

    /// Cancel the active turn: the one named, else the one the session row
    /// names, else the one `get` answers. With no turn at all, throws
    /// `.agentSessionNoActiveTurn` and sends no cancel.
    @discardableResult
    public func cancel(turnId: String? = nil) async throws -> AgentSessionCancelResult {
        var target = turnId ?? activeTurnId
        if target == nil {
            target = try await api.get(sessionId: sessionId).turn?.turnId
        }
        guard let target else {
            throw JsBaoError(
                code: .agentSessionNoActiveTurn,
                message: "There is no active turn to cancel: the session is idle."
            )
        }
        return try await api.cancel(sessionId: sessionId, turnId: target)
    }

    /// Mark the session read for the signed-in user (`sessions.markRead`):
    /// `info.hasUnread` becomes `false` and `info.lastReadAt` the marker, and
    /// `onChange` fires. Activity that arrived after the marker, while the
    /// call was answering, keeps the dot. Call it when the user opens or
    /// returns to the session.
    @discardableResult
    public func markRead() async throws -> AgentSessionReadResult {
        let result = try await api.markRead(sessionId: sessionId)
        let read: @Sendable (AgentSessionInfo) -> AgentSessionInfo = { info in
            var info = info
            info.lastReadAt = AgentSessionList.laterOf(info.lastReadAt, result.lastReadAt)
            // Activity after this marker keeps its dot (CSO-4380-007).
            info.hasUnread = info.hasUnread && AgentSessionList.unread(info.lastActivityAt, info.lastReadAt)
            return info
        }
        lock.withLock {
            _info = read(_info)
            amendInfoReadsLocked(read)
        }
        notify()
        return result
    }

    // MARK: - Client tools

    /// Call ids a handler of this view is running now, in start order.
    public var runningClientToolCalls: [String] { lock.withLock { runningOrder } }

    /// Run client tools for this member: when the active turn is yours, each
    /// call of a named tool that waits for its result (`input-available`, or
    /// approved) runs its handler and is answered with the result. Calls
    /// waiting when you register, or found again when the document re-syncs,
    /// run too. Every one of your open views runs a call and the first answer
    /// wins, so keep handlers free of side effects. Approvals stay with your
    /// UI.
    ///
    /// Throws `.invalidArgument` when a name already has a handler on this
    /// view (nothing is registered) or the view is closed.
    ///
    /// - Returns: A function that removes these handlers; runs in flight
    ///   still answer.
    @discardableResult
    public func handleClientTools(
        _ handlers: [String: AgentClientToolHandler],
        options: HandleClientToolsOptions = HandleClientToolsOptions()
    ) throws -> @Sendable () -> Void {
        let id = UUID()
        let refusal: JsBaoError? = lock.withLock {
            if closed { return JsBaoError(code: .invalidArgument, message: "The session view is closed") }
            if let taken = handlers.keys.sorted().first(where: { toolHandlers[$0] != nil }) {
                return JsBaoError(
                    code: .invalidArgument, message: "Client tool \"\(taken)\" already has a handler on this view",
                    details: ["toolName": .string(taken)]
                )
            }
            for (name, handler) in handlers {
                toolHandlers[name] = ClientToolRegistration(id: id, handler: handler, onError: options.onError)
            }
            return nil
        }
        if let refusal { throw refusal }
        guard !handlers.isEmpty else { return {} }
        work.async { [weak self] in self?.evaluateClientTools() }
        let names = Array(handlers.keys)
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                for name in names where self.toolHandlers[name]?.id == id { self.toolHandlers[name] = nil }
            }
        }
    }

    /// Read the session's info again (`get`), and notify when it is read.
    @discardableResult
    public func refreshInfo() async throws -> AgentSessionInfo {
        guard let next = try await readInfo(whileOpen: false) else { return info }
        return next
    }

    /// `get`, applied to `info` over the changes made while it was in flight.
    /// `whileOpen` (a reconnect's read): nothing is sent once the view is
    /// closed, and an answer that arrives after `close()` is dropped — nil.
    private func readInfo(whileOpen: Bool) async throws -> AgentSessionInfo? {
        let id = UUID()
        let start: Bool = lock.withLock {
            if whileOpen && closed { return false }
            infoReads[id] = []
            return true
        }
        guard start else { return nil }
        let answered: AgentSessionInfo
        do {
            answered = try await api.get(sessionId: sessionId)
        } catch {
            _ = lock.withLock { infoReads.removeValue(forKey: id) }
            throw error
        }
        let next: AgentSessionInfo? = lock.withLock {
            let since = infoReads.removeValue(forKey: id) ?? []
            if whileOpen && closed { return nil }
            _info = since.reduce(answered) { info, change in change(info) }
            return _info
        }
        guard let next else { return nil }
        notify()
        return next
    }

    /// Stop listening and close the session's document. Running client-tool
    /// handlers are cancelled and their answers never sent. Idempotent.
    public func close() async {
        let closing: (unsubscribes: [@Sendable () -> Void], tasks: [Task<Void, Never>])? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            listeners.removeAll()
            var tasks = runningCalls.values.compactMap(\.task)
            if let syncTask { tasks.append(syncTask) }
            syncTask = nil
            if let reconcileTask { tasks.append(reconcileTask) }
            reconcileTask = nil
            runningCalls.removeAll()
            runningOrder.removeAll()
            toolHandlers.removeAll()
            answeredCalls.removeAll()
            failedCalls.removeAll()
            defer { unsubscribes.removeAll() }
            return (unsubscribes, tasks)
        }
        guard let closing else { return }
        signals.release()
        for unsubscribe in closing.unsubscribes { unsubscribe() }
        for task in closing.tasks { task.cancel() }
        await client.documents.close(documentId)
    }

    // MARK: - Internals

    /// Subscribe to the four models and the document's syncs, and load the
    /// first window.
    func start() async throws {
        var unsubs: [@Sendable () -> Void] = []
        for schema in AgentSessionModels.schemas {
            unsubs.append(client.codegen.subscribe(schema) { [weak self] in self?.scheduleRefresh() })
        }
        let documentId = self.documentId
        let syncs = Self.syncEvents(of: client)
        let sync = Task { [weak self] in
            for await event in syncs where event.documentId == documentId && event.synced {
                self?.scheduleEvaluate()
            }
        }
        let alreadyClosed: Bool = lock.withLock {
            if !closed {
                unsubscribes.append(contentsOf: unsubs)
                syncTask = sync
            }
            return closed
        }
        if alreadyClosed {
            unsubs.forEach { $0() }
            sync.cancel()
            signals.release()
        }
        // What arrived while the session was read and its document opened, then the rest.
        signals.attach { [weak self] signal in
            switch signal {
            case .change(let event): self?.onSessionChanged(event)
            case .status(let status): self?.onConnectionStatus(status)
            }
        }
        try await onWorkQueue { try self.refreshNow(notify: false) }
        if markWhileOpen { readWhileOpen() }
    }

    /// A change event: this session's upsert merged into `info`; a removal
    /// changes nothing.
    private func onSessionChanged(_ event: AgentSessionChangedEvent) {
        let (changed, unread): (Bool, Bool) = lock.withLock {
            guard !closed, event.sessionId == _info.sessionId else { return (false, false) }
            let at = AgentSessionList.ms(event.at) ?? 0
            switch event.action {
            case .removed:
                removedAt = max(at, removedAt ?? 0)
                return (false, false)
            case .unknown:
                return (false, false)
            case .upsert:
                break
            }
            guard let item = event.item else { return (false, false) }
            if let removedAt, at <= removedAt { return (false, false) }
            // An event older than the last one applied adds only its instants.
            let newer = infoAt == nil || at >= infoAt!
            if newer { infoAt = at }
            _info = Self.merged(_info, event, item, newer: newer)
            amendInfoReadsLocked { Self.merged($0, event, item, newer: newer) }
            return (true, _info.hasUnread)
        }
        guard changed else { return }
        notify()
        if markWhileOpen && unread { readWhileOpen() }
    }

    /// A change event merged into a session's info: a newer event's title,
    /// scope, members and status; the later of each instant; the dot from them.
    private static func merged(
        _ info: AgentSessionInfo, _ event: AgentSessionChangedEvent, _ item: AgentSessionListItem, newer: Bool
    ) -> AgentSessionInfo {
        var info = info
        if newer {
            info.title = item.title
            info.scope = item.scope
            if let members = event.members { info.members = members }
            if let status = item.status { info.status = status }
        }
        info.lastActivityAt = AgentSessionList.laterOf(info.lastActivityAt, item.lastActivityAt)
        info.lastReadAt = AgentSessionList.laterOf(info.lastReadAt, item.lastReadAt)
        // The dot is a member's; an app owner or admin who is not in the session has none.
        info.hasUnread = info.role != .admin && AgentSessionList.unread(info.lastActivityAt, info.lastReadAt)
        return info
    }

    /// A change to `info`, kept for each `get` in flight to make again over its answer.
    private func amendInfoReadsLocked(_ change: @escaping @Sendable (AgentSessionInfo) -> AgentSessionInfo) {
        for id in infoReads.keys { infoReads[id]?.append(change) }
    }

    /// A reconnect: `info` read again, one read at a time, then the while-open read.
    private func onConnectionStatus(_ status: ConnectionStatus) {
        let reconcile: Bool = lock.withLock {
            guard !closed else { return false }
            switch status {
            case .disconnected:
                live = false
                return false
            case .connected:
                if live { return false }
                live = true
                return true
            case .connecting:
                return false
            }
        }
        if reconcile { reconcileInfo() }
    }

    private func reconcileInfo() {
        let start: Bool = lock.withLock {
            guard !closed else { return false }
            if reconciling {
                reconcileAgain = true
                return false
            }
            reconciling = true
            return true
        }
        guard start else { return }
        let task = Task { [weak self] in
            while let self {
                let proceed: Bool = self.lock.withLock {
                    self.reconcileAgain = false
                    return !self.closed
                }
                if proceed, !Task.isCancelled,
                   let info = try? await self.readInfo(whileOpen: true), self.markWhileOpen, info.hasUnread {
                    self.readWhileOpen()
                }
                let again: Bool = self.lock.withLock {
                    if proceed && self.reconcileAgain && !self.closed { return true }
                    self.reconciling = false
                    return false
                }
                if !again { break }
            }
        }
        // A close that ran meanwhile has already taken the tasks it cancels.
        let cancel: Bool = lock.withLock {
            if closed { return true }
            reconcileTask = task
            return false
        }
        if cancel { task.cancel() }
    }

    /// One `markRead()` at a time: a request while one runs makes one more
    /// after it. A failure waits for the next activity or reconnect; a
    /// refusal as not found stops the loop.
    private func readWhileOpen() {
        let start: Bool = lock.withLock {
            guard !closed, !readStopped, _info.role != .admin else { return false }
            if reading {
                readAgain = true
                return false
            }
            reading = true
            return true
        }
        guard start else { return }
        Task { [weak self] in
            while let self {
                let proceed: Bool = self.lock.withLock {
                    self.readAgain = false
                    return !self.closed && !self.readStopped
                }
                if proceed {
                    do {
                        try await self.markRead()
                    } catch {
                        if (error as? HttpError)?.serverCode == "AGENT_SESSION_NOT_FOUND" {
                            self.lock.withLock { self.readStopped = true }
                        }
                    }
                }
                let again: Bool = self.lock.withLock {
                    if proceed && self.readAgain && !self.closed && !self.readStopped { return true }
                    self.reading = false
                    return false
                }
                if !again { break }
            }
        }
    }

    /// Every document's `SyncEvent`, unbounded: the stream is filtered to the
    /// session's document only after buffering, so a bounded buffer would let
    /// a reconnect burst of other documents' syncs evict this one's.
    static func syncEvents(of client: JsBaoClient) -> AsyncStream<SyncEvent> {
        client.stream(for: SyncEvent.self, buffering: .unbounded)
    }

    private func onWorkQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            work.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// At most one refresh waits behind the one running; writes that land
    /// meanwhile are read by it. The wait is a short window so a burst of
    /// writes (one sync applying many rows) is read once — JS's per-macrotask
    /// coalescing.
    private func scheduleRefresh() {
        let schedule: Bool = lock.withLock {
            guard !closed, !refreshQueued else { return false }
            refreshQueued = true
            return true
        }
        guard schedule else { return }
        work.asyncAfter(deadline: .now() + Self.refreshCoalesceWindow) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.refreshQueued = false }
            try? self.refreshNow(notify: true)
        }
    }

    private func notify() {
        let current: [@Sendable () -> Void] = lock.withLock { closed ? [] : Array(listeners.values) }
        for listener in current { listener() }
    }

    private func options(sort: [String: Int]? = nil, limit: Int? = nil) -> QueryOptions {
        QueryOptions(sort: sort, limit: limit, documents: [documentId])
    }

    /// The session row, the window's messages from its oldest on, and their
    /// parts and steps; listeners hear of it only when something changed.
    private func refreshNow(notify shouldNotify: Bool) throws {
        let (isClosed, oldest) = lock.withLock { (closed, Self.oldestSeq(window)) }
        guard !isClosed else { return }
        let codegen = client.codegen
        let sessionRow = try codegen.query(
            PrimitiveSession.primitiveSchema, filter: nil, options: options(limit: 1)
        ).first
        var nextWindow: [String: PrimitiveMessage] = [:]
        var nextOlder: Bool?
        if let oldest {
            let rows = try codegen.query(
                PrimitiveMessage.primitiveSchema, filter: ["seq": ["$gte": .number(oldest)]],
                options: options(sort: ["seq": 1])
            )
            for row in rows { if let message = PrimitiveMessage(row: row) { nextWindow[message.id] = message } }
        } else {
            let page = try codegen.queryPaged(
                PrimitiveMessage.primitiveSchema, filter: nil,
                options: options(sort: ["seq": -1], limit: pageSize)
            )
            for row in page.data { if let message = PrimitiveMessage(row: row.raw) { nextWindow[message.id] = message } }
            nextOlder = page.hasMore
        }
        let (parts, nextSteps) = try loadRows(for: nextWindow)
        let changed: Bool = lock.withLock {
            guard !closed else { return false }
            var changed = false
            if sessionRow != self.sessionRow {
                self.sessionRow = sessionRow
                sessionRecord = sessionRow.flatMap(PrimitiveSession.init(row:))
                changed = true
            }
            let olderBefore = olderRemain
            if let nextOlder { olderRemain = nextOlder }
            window = nextWindow
            partsByMessage = parts
            steps = nextSteps
            return rebuildLocked() || changed || olderBefore != olderRemain
        }
        if changed && shouldNotify { notify() }
        evaluateClientTools(session: sessionRow.flatMap(PrimitiveSession.init(row:)))
    }

    /// At most one evaluation waits behind the running work, so a burst of
    /// sync events is read once.
    private func scheduleEvaluate() {
        let schedule: Bool = lock.withLock {
            guard !closed, !toolHandlers.isEmpty, !evaluateQueued else { return false }
            evaluateQueued = true
            return true
        }
        guard schedule else { return }
        work.asyncAfter(deadline: .now() + Self.refreshCoalesceWindow) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.evaluateQueued = false }
            self.evaluateClientTools()
        }
    }

    /// `evaluateClientTools(session:)` over the session row read now. Runs on
    /// `work`.
    private func evaluateClientTools() {
        guard lock.withLock({ !closed && !toolHandlers.isEmpty }) else { return }
        let row = try? client.codegen.query(
            PrimitiveSession.primitiveSchema, filter: nil, options: options(limit: 1)
        ).first
        evaluateClientTools(session: row.flatMap(PrimitiveSession.init(row:)))
    }

    /// Start a handler for each call of the active turn that waits on this
    /// member, read from the document rather than the window. Runs only when
    /// the session row names the current user as the turn's initiator. Runs
    /// on `work`.
    private func evaluateClientTools(session: PrimitiveSession?) {
        let turnId = session?.activeTurnId
        let proceed: Bool = lock.withLock {
            guard !closed, !toolHandlers.isEmpty else { return false }
            answeredCalls = answeredCalls.filter { $0.value == turnId }
            failedCalls = failedCalls.filter { $0.value.turnId == turnId }
            return true
        }
        guard proceed, let turnId, let userId = client.userId,
              session?.activeTurnInitiatorUserId == userId
        else { return }
        let codegen = client.codegen
        guard let messages = try? codegen.query(
            PrimitiveMessage.primitiveSchema, filter: ["turnId": .string(turnId)], options: options()
        ) else { return }
        let messageIds = messages.compactMap(PrimitiveMessage.init(row:)).map(\.id).sorted()
        var parts: [PrimitivePart] = []
        for chunk in Self.chunks(messageIds, Self.inChunk) {
            guard let rows = try? codegen.query(
                PrimitivePart.primitiveSchema,
                filter: ["messageId": ["$in": .array(chunk.map { .string($0) })], "kind": "tool_call"],
                options: options()
            ) else { return }
            parts.append(contentsOf: rows.compactMap(PrimitivePart.init(row:)))
        }
        let starts: [(AgentClientToolDecisions.EligibleCall, ClientToolRegistration, UUID)] = lock.withLock {
            guard !closed else { return [] }
            var starts: [(AgentClientToolDecisions.EligibleCall, ClientToolRegistration, UUID)] = []
            let registered = Set(toolHandlers.keys)
            for part in parts.sorted(by: { ($0.seq, $0.id) < ($1.seq, $1.id) }) {
                guard let callId = part.toolCallId else { continue }
                if let state = part.state, AgentClientToolDecisions.terminalStates.contains(state) {
                    answeredCalls[callId] = nil
                }
                if let failed = failedCalls[callId], failed.state != part.state { failedCalls[callId] = nil }
                guard let call = AgentClientToolDecisions.eligibleCall(part: part, registered: registered),
                      runningCalls[callId] == nil, answeredCalls[callId] == nil, failedCalls[callId] == nil,
                      let registration = toolHandlers[call.toolName]
                else { continue }
                let runId = UUID()
                runningCalls[callId] = RunningClientTool(id: runId, task: nil)
                runningOrder.append(callId)
                starts.append((call, registration, runId))
            }
            return starts
        }
        guard !starts.isEmpty else { return }
        for (call, registration, runId) in starts {
            let task = runClientTool(call, turnId: turnId, registration: registration, runId: runId)
            let stillRunning: Bool = lock.withLock {
                guard runningCalls[call.callId]?.id == runId else { return false }
                runningCalls[call.callId]?.task = task
                return true
            }
            if !stillRunning { task.cancel() }
        }
        notify()
    }

    /// Run one call's handler and answer it; refusals are read by
    /// `AgentClientToolDecisions.classifyAnswerFailure`.
    private func runClientTool(
        _ call: AgentClientToolDecisions.EligibleCall, turnId: String, registration: ClientToolRegistration,
        runId: UUID
    ) -> Task<Void, Never> {
        let request = AgentClientToolCall(
            sessionId: sessionId, turnId: turnId, callId: call.callId, messageId: call.messageId,
            partId: call.partId, toolName: call.toolName, input: call.input ?? .null
        )
        return Task { [weak self] in
            let answer: AgentCallAnswer
            do {
                answer = try await registration.handler.answer(request)
            } catch {
                answer = .error(message: AgentClientToolDecisions.errorMessage(of: error))
            }
            guard let self, !Task.isCancelled, !self.lock.withLock({ self.closed }) else { return }
            do {
                _ = try await self.api.answer(sessionId: self.sessionId, callId: call.callId, answer)
                self.lock.withLock { self.answeredCalls[call.callId] = turnId }
            } catch {
                guard !self.lock.withLock({ self.closed }) else { return }
                let failure = AgentClientToolDecisions.classifyAnswerFailure(error)
                switch failure {
                case let .lost(code):
                    if code == "AGENT_CALL_ANSWERED" {
                        self.lock.withLock { self.answeredCalls[call.callId] = turnId }
                    }
                case let .refused(code, message):
                    self.lock.withLock { self.failedCalls[call.callId] = (turnId, call.state) }
                    registration.onError?(AgentClientToolError(
                        callId: call.callId, toolName: call.toolName, turnId: turnId, code: code,
                        message: message, error: error
                    ))
                case let .transport(message):
                    registration.onError?(AgentClientToolError(
                        callId: call.callId, toolName: call.toolName, turnId: turnId, code: nil,
                        message: message, error: error
                    ))
                }
            }
            let settled: Bool = self.lock.withLock {
                guard self.runningCalls[call.callId]?.id == runId else { return false }
                self.runningCalls[call.callId] = nil
                self.runningOrder.removeAll { $0 == call.callId }
                return true
            }
            if settled { self.notify() }
        }
    }

    private func loadOlderNow() throws -> AgentSessionLoadOlderResult {
        let (isClosed, remain, oldest) = lock.withLock { (closed, olderRemain, Self.oldestSeq(window)) }
        guard !isClosed, remain else { return AgentSessionLoadOlderResult(loaded: 0, hasOlder: false) }
        let page = try client.codegen.queryPaged(
            PrimitiveMessage.primitiveSchema,
            filter: oldest.map { ["seq": ["$lt": .number($0)]] },
            options: options(sort: ["seq": -1], limit: pageSize)
        )
        var nextWindow = lock.withLock { window }
        var loaded = 0
        for row in page.data {
            guard let message = PrimitiveMessage(row: row.raw), nextWindow[message.id] == nil else { continue }
            nextWindow[message.id] = message
            loaded += 1
        }
        let (parts, nextSteps) = try loadRows(for: nextWindow)
        let (changed, hasOlder): (Bool, Bool) = lock.withLock {
            guard !closed else { return (false, false) }
            let olderBefore = olderRemain
            olderRemain = page.hasMore
            window = nextWindow
            partsByMessage = parts
            steps = nextSteps
            return (rebuildLocked() || olderBefore != olderRemain, olderRemain)
        }
        if changed { notify() }
        return AgentSessionLoadOlderResult(loaded: loaded, hasOlder: hasOlder)
    }

    /// The parts of the window's messages and the steps of its turns, each
    /// query scoped to the document.
    private func loadRows(
        for window: [String: PrimitiveMessage]
    ) throws -> ([String: [PrimitivePart]], [PrimitiveStep]) {
        let codegen = client.codegen
        var parts: [String: [PrimitivePart]] = [:]
        for chunk in Self.chunks(window.keys.sorted(), Self.inChunk) {
            let rows = try codegen.query(
                PrimitivePart.primitiveSchema,
                filter: ["messageId": ["$in": .array(chunk.map { .string($0) })]],
                options: options()
            )
            for row in rows {
                guard let part = PrimitivePart(row: row) else { continue }
                parts[part.messageId, default: []].append(part)
            }
        }
        for (id, list) in parts {
            parts[id] = list.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
        }
        let turnIds = Set(window.values.compactMap(\.turnId)).sorted()
        var steps: [PrimitiveStep] = []
        for chunk in Self.chunks(turnIds, Self.inChunk) {
            let rows = try codegen.query(
                PrimitiveStep.primitiveSchema,
                filter: ["turnId": ["$in": .array(chunk.map { .string($0) })]],
                options: options()
            )
            steps.append(contentsOf: rows.compactMap(PrimitiveStep.init(row:)))
        }
        return (parts, steps.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) })
    }

    /// The messages the properties answer. Whether any entry changed. Caller
    /// holds `lock`.
    private func rebuildLocked() -> Bool {
        let queued = Set((sessionRecord?.queue ?? []).flatMap(\.messageIds))
        var stepsByTurn: [String: [PrimitiveStep]] = [:]
        for step in steps { stepsByTurn[step.turnId, default: []].append(step) }
        let synced = window.values
            .sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
            .map { message in
                AgentSessionSyncedMessage(
                    messageId: message.id,
                    seq: message.seq,
                    clientMessageId: message.clientMessageId,
                    message: message,
                    parts: partsByMessage[message.id] ?? [],
                    steps: message.turnId.flatMap { stepsByTurn[$0] } ?? [],
                    state: queued.contains(message.id) ? .queued : .synced
                )
            }
        // A pending entry leaves once the row its accepted id names is in the
        // window.
        pendingEntries.removeAll { entry in
            entry.state == .sending && entry.messageId.map { window[$0] != nil } == true
        }
        let next = synced.map(AgentSessionViewMessage.synced) + pendingEntries.map(AgentSessionViewMessage.pending)
        let changed = next != view
        view = next
        return changed
    }

    private func deliver(_ entry: AgentSessionPendingMessage) async throws -> AgentSessionSendResult {
        lock.withLock {
            // An earlier entry under the same id gives way to this one.
            pendingEntries.removeAll { $0.clientMessageId == entry.clientMessageId }
            pendingEntries.append(entry)
            _ = rebuildLocked()
        }
        notify()
        let result: AgentSessionSendResult
        do {
            result = try await api.send(sessionId: sessionId, body: entry.body)
        } catch {
            replace(entry, with: entry.with(state: .failed, error: Self.sendError(of: error)))
            throw error
        }
        replace(entry, with: entry.with(state: .sending, messageId: result.messageId))
        return result
    }

    private func replace(_ entry: AgentSessionPendingMessage, with next: AgentSessionPendingMessage) {
        let replaced: Bool = lock.withLock {
            guard let at = pendingEntries.firstIndex(where: { $0.attempt == entry.attempt }) else { return false }
            pendingEntries[at] = next
            _ = rebuildLocked()
            return true
        }
        if replaced { notify() }
    }

    /// A refusal's code, message and `retryAfter`.
    static func sendError(of error: Error) -> AgentSessionSendError {
        if let http = error as? HttpError {
            var retryAfter: Double?
            if let text = http.body,
               let body = try? JSONCoding.decodeData(JSONValue.self, from: Data(text.utf8)) {
                retryAfter = body["retryAfter"]?.numberValue ?? body["details"]?["retryAfter"]?.numberValue
            }
            return AgentSessionSendError(
                code: http.serverCode ?? "AGENT_SESSION_SEND_FAILED",
                message: http.serverMessage ?? http.message,
                retryAfter: retryAfter
            )
        }
        if let jsBao = error as? JsBaoError {
            return AgentSessionSendError(code: jsBao.code.rawValue, message: jsBao.message)
        }
        return AgentSessionSendError(code: "AGENT_SESSION_SEND_FAILED", message: String(describing: error))
    }

    private static func oldestSeq(_ window: [String: PrimitiveMessage]) -> Double? {
        window.values.map(\.seq).min()
    }

    private static func chunks<T>(_ items: [T], _ size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - Signals

/// The client's change events and connection states, heard from before a
/// view's first `get` and held until the view takes them, so nothing that
/// arrives while the session is read or its document opens is lost
/// (CSO-4380-001).
final class AgentSessionViewSignals: @unchecked Sendable {
    enum Signal: Sendable {
        case change(AgentSessionChangedEvent)
        case status(ConnectionStatus)
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var held: [Signal] = []
    private var sink: (@Sendable (Signal) -> Void)?
    private var released = false
    private var tasks: [Task<Void, Never>] = []

    init(client: JsBaoClient) {
        let changes = client.stream(for: AgentSessionChangedEvent.self)
        let statuses = AgentSessionsAPI.connectionStatuses(of: client)
        let tasks = [
            Task { [weak self] in
                for await event in changes { self?.deliver(.change(event)) }
            },
            Task { [weak self] in
                for await status in statuses { self?.deliver(.status(status)) }
            },
        ]
        lock.withLock { self.tasks = tasks }
    }

    /// What was held, in arrival order, then everything after, to `sink`.
    func attach(_ sink: @escaping @Sendable (Signal) -> Void) {
        while true {
            let batch: [Signal]? = lock.withLock {
                if released { return nil }
                if held.isEmpty {
                    self.sink = sink
                    return nil
                }
                defer { held.removeAll() }
                return held
            }
            guard let batch else { return }
            batch.forEach(sink)
        }
    }

    /// Stop listening. Idempotent.
    func release() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            released = true
            held.removeAll()
            sink = nil
            defer { self.tasks.removeAll() }
            return self.tasks
        }
        tasks.forEach { $0.cancel() }
    }

    private func deliver(_ signal: Signal) {
        let target: (@Sendable (Signal) -> Void)? = lock.withLock {
            if released { return nil }
            if let sink { return sink }
            held.append(signal)
            return nil
        }
        target?(signal)
    }
}

// MARK: - open

extension AgentSessionsAPI {
    /// Open a session as a live view: its info, the latest page of messages
    /// with their parts and steps (older pages with `loadOlder()`), your own
    /// messages shown at once while they send, and `onChange` on every change.
    /// `info` stays current as the session changes; `markRead: .whileOpen`
    /// keeps the session read while the view is open.
    ///
    /// Runs `get` first (a refusal throws before anything is opened), then
    /// registers the four platform models — throwing
    /// `.agentSessionModelNameTaken` when a model under a platform name
    /// carries a different schema, with nothing registered or opened — then
    /// opens the session's document and loads the first window. Call
    /// `close()` when done. A `pageSize` outside 1…500 throws
    /// `.invalidArgument` before any request.
    public func open(
        sessionId: String, options: OpenAgentSessionOptions = OpenAgentSessionOptions()
    ) async throws -> AgentSessionView {
        guard (1...AgentSessionView.maxPageSize).contains(options.pageSize) else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "pageSize must be an integer from 1 to \(AgentSessionView.maxPageSize)",
                details: ["field": .string("pageSize")]
            )
        }
        try Self.require(sessionId, "sessionId")
        guard let client else {
            throw JsBaoError(code: .unavailable, message: "agents.sessions.open requires a wired JsBaoClient")
        }
        // Heard from before `get`: a change or the first connection while the
        // session is read or its document opens reaches the view (CSO-4380-001).
        let signals = AgentSessionViewSignals(client: client)
        // A connection already up when `get` is read hears every change since.
        let connectedAtOpen = client.isConnected
        let info: AgentSessionInfo
        do {
            info = try await get(sessionId: sessionId)
            for schema in AgentSessionModels.schemas {
                if let existing = client.sharedModel(schema.name), existing.schema != schema {
                    throw JsBaoError(
                        code: .agentSessionModelNameTaken,
                        message: "A model named \(schema.name) is already registered with a different schema; " +
                            "the platform's session models need the name.",
                        details: ["model": .string(schema.name)]
                    )
                }
            }
            client.registerModels(AgentSessionModels.schemas)
            _ = try await client.documents.open(
                info.documentId,
                options: options.open ?? OpenDocumentOptions(waitForLoad: .network, enableNetworkSync: true)
            )
        } catch {
            signals.release()
            throw error
        }
        let view = AgentSessionView(
            api: self, client: client, info: info, pageSize: options.pageSize,
            markWhileOpen: options.markRead == .whileOpen, connectedAtOpen: connectedAtOpen, signals: signals
        )
        do {
            try await view.start()
        } catch {
            await view.close()
            throw error
        }
        return view
    }
}
