import Foundation

// A live view of one agent session over its db3 (#3810; #4884) — the Swift
// half of the JS client's `src/client/agents/sessionView.ts`, rule for rule.
//
// `client.agents.sessions.open` reads the session (`get`), subscribes to the
// session's db3 (its id the session's) and keeps a window of the latest
// messages by `seq` with their parts, calls, steps and turns, read by model
// name from the db3's local copy; `loadOlder()` pages back. Your own messages
// appear at once as pending entries, keyed by a client message id, and leave
// once the row the server accepted is in the window; a refused send stays as
// `.failed`.
//
// Swift carries no `uiMessages()`: the AI SDK adapter is the JS client's.
// Read a part's typed `content` instead.
//
// `info` follows the server's `AgentSessionChangedEvent`s for the session, and
// is read again after a reconnect; `markRead: .whileOpen` keeps the session
// read while the view is open. When the room refuses you the session, or the
// session's `removed` event comes first (you were removed, or it was deleted),
// the view evicts its local copy and `gone` says so.

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
    /// `.whileOpen` keeps the session read while the view is open; `nil`
    /// marks it read only when you call `markRead()`.
    public var markRead: AgentSessionMarkRead?

    public init(pageSize: Int = 50, markRead: AgentSessionMarkRead? = nil) {
        self.pageSize = pageSize
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

/// One of a message's parts in the view: a `Part` record, or one of its calls
/// (a `ToolCall` record, its id the call's).
public enum AgentSessionViewPart: Sendable, Equatable {
    case part(AgentSessionPartRecord)
    case toolCall(AgentSessionToolCallRecord)

    public var id: String {
        switch self {
        case let .part(record): return record.id
        case let .toolCall(record): return record.id
        }
    }

    public var messageId: String {
        switch self {
        case let .part(record): return record.messageId
        case let .toolCall(record): return record.messageId
        }
    }

    /// Its position among the message's parts.
    public var seq: Double {
        switch self {
        case let .part(record): return record.seq
        case let .toolCall(record): return record.seq
        }
    }
}

/// A message in the view's window, synced from the session's db3.
public struct AgentSessionSyncedMessage: Sendable, Equatable {
    /// `.queued` while the message waits for a turn (its `queueSeq` is set).
    public enum State: Sendable, Equatable {
        case synced
        case queued
    }

    public let messageId: String
    public let seq: Double
    public let clientMessageId: String?
    public let message: AgentSessionMessageRecord
    /// The message's `Part` records and its calls, in one list by `seq`, then id.
    public let parts: [AgentSessionViewPart]
    /// The steps of the message's turn, by `seq`; `[]` when it has none.
    public let steps: [AgentSessionStepRecord]
    /// The message's turn, once its `Turn` row has synced.
    public let turn: AgentSessionTurnRecord?
    public let state: State
}

/// One of your messages the view shows before its row is synced, or that the
/// server refused. It exists only in the view that sent it.
public struct AgentSessionPendingMessage: Sendable, Equatable {
    /// `.waiting` while a session upload the message names is still in
    /// `attachments.uploads()`; `.sending` until its row is in the window
    /// (the entry then leaves); `.failed` when refused, or when an upload it
    /// waited on failed.
    public enum State: Sendable, Equatable {
        case sending
        case failed
        case waiting
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

/// A message in the view: synced from the session's db3, or pending.
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
/// Read its state through the properties (they change as the session's db3
/// syncs), and call `onChange` to hear about every change. `close()` when
/// done: it gives up the view's subscription, and the local copy stays.
///
/// Opening the same session twice on one client gives two views, each with
/// its own subscription; closing one leaves the other live.
public final class AgentSessionView: @unchecked Sendable {
    static let defaultPageSize = 50
    static let maxPageSize = 500
    /// Ids per `$in` query.
    static let inChunk = 100
    /// The most records one local records query answers.
    static let recordsPageMax = 10_000
    /// How long a change waits for others before the view reads them.
    static let refreshCoalesceWindow: DispatchTimeInterval = .milliseconds(15)

    private let host: AgentSessionViewHost
    private let subscription: Db3Subscription
    private let records: DocumentRecords
    private let pageSize: Int
    /// Every refresh and page load runs here, one at a time.
    private let work = DispatchQueue(label: "agent-session-view")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var _info: AgentSessionInfo
    private var window: [String: AgentSessionMessageRecord] = [:]
    private var partsByMessage: [String: [AgentSessionViewPart]] = [:]
    private var steps: [AgentSessionStepRecord] = []
    private var turns: [String: AgentSessionTurnRecord] = [:]
    private var memberRecords: [AgentSessionMemberRecord] = []
    private var queueEntries: [PrimitiveQueueEntry] = []
    private var olderRemain = false
    private var sessionRecord: AgentSessionRecord?
    private var goneEvent: Db3GoneEvent?
    /// Set once you lost the session (the room refused you, or its `removed`
    /// event came first): nothing more is read into the view.
    private var lost = false
    private var pendingEntries: [AgentSessionPendingMessage] = []
    private var view: [AgentSessionViewMessage] = []
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    private var unsubscribes: [@Sendable () -> Void] = []
    private var observations: [EventSubscription] = []
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
    private var failedCalls: [String: (turnId: String, state: AgentSessionToolCallState)] = [:]
    private var evaluateQueued = false
    /// Whether the subscription left `.live` since the calls were last
    /// evaluated for it: its return evaluates them again.
    private var leftLive = false
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
    /// `attachments`, built on first use.
    private var attachmentsOf: AgentSessionAttachments?
    /// The waits of waiting sends, by client message id: a newer send under
    /// the id ends its wait.
    private var waitingSends: [String: (attempt: UUID, task: Task<Void, Error>)] = [:]
    /// Artifact reads in flight, by blob id, shared by every `artifact(of:)`
    /// call that asks meanwhile and forgotten once settled.
    private var artifactReads: [String: (id: UUID, read: Task<Data, Error>)] = [:]

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
        host: AgentSessionViewHost, info: AgentSessionInfo, subscription: Db3Subscription, pageSize: Int,
        markWhileOpen: Bool = false, connectedAtOpen: Bool = false, signals: AgentSessionViewSignals? = nil
    ) {
        self.host = host
        self._info = info
        self.subscription = subscription
        self.records = host.db3.records(info.sessionId)
        self.pageSize = pageSize
        self.markWhileOpen = markWhileOpen
        self.live = connectedAtOpen
        self.signals = signals ?? host.signals()
    }

    // MARK: - State

    /// The session's info as `get` answered it, kept current by the server's
    /// change events (title, last activity, the dot, members, status) and read
    /// again after a reconnect; `refreshInfo()` reads it again on demand.
    public var info: AgentSessionInfo { lock.withLock { _info } }

    /// The session's id: also its db3's.
    public var sessionId: String { info.sessionId }

    /// The session's files: upload them, follow and control the upload
    /// queue, and read any file of the session, by `blobId`. Send an uploaded
    /// file with `send(text:files:)`. Queued uploads outlive the view; after
    /// `close()`, `upload` and `read` throw `.invalidArgument`.
    public var attachments: AgentSessionAttachments {
        lock.withLock {
            if let attachmentsOf { return attachmentsOf }
            let made = host.attachments(_info.sessionId) { [weak self] in self?.isClosed ?? true }
            attachmentsOf = made
            return made
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    /// The `Session` row, decoded; `nil` until it has synced or when it does
    /// not decode.
    public var session: AgentSessionRecord? { lock.withLock { sessionRecord } }

    /// The `Session` row's status; `nil` until it has synced. A status outside
    /// the vocabulary reads `.unknown(raw)`.
    public var status: AgentSessionStatus? { session?.status }

    /// The active turn the `Session` row names, or `nil`.
    public var activeTurnId: String? { session?.activeTurnId }

    /// The authors waiting behind the active turn, with their messages: the
    /// messages whose `queueSeq` is set, in its order, one entry per author.
    public var queue: [PrimitiveQueueEntry] { lock.withLock { queueEntries } }

    /// The session's members, the owner included: its `Member` rows, in the
    /// order they were added.
    public var members: [AgentSessionMemberRecord] { lock.withLock { memberRecords } }

    /// Why the room stopped syncing the session with this client, or `nil`.
    /// On `.permission` you are no longer a member: the view has evicted its
    /// local copy, shows nothing and runs no client tool. On `.syncOff` and
    /// `.clientOutdated` the copy is kept.
    public var gone: Db3GoneEvent? { lock.withLock { goneEvent } }

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
    ///
    /// A message whose `files` name uploads still in `attachments.uploads()`
    /// is `.waiting` until they land, and is sent then, even after `close()`;
    /// when one fails, the message fails with the upload's error, the call
    /// throws it, and nothing is sent. Other messages go out at once. A newer
    /// send under the same `clientMessageId` replaces a waiting one, whose
    /// call throws `.invalidArgument`.
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
    /// land answers as a duplicate. It waits again for any upload it names
    /// that is still queued (`attachments.resume` retries a failed one).
    /// Throws `.invalidArgument` when no failed message has that id.
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

    /// Load the page of messages before the window's oldest, with their parts,
    /// calls, steps and turns. Calls made while one is loading share its page;
    /// at the start of the session, or after `close()`, it answers `{ 0, false }`.
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
        try await host.sessions.answer(sessionId: sessionId, callId: callId, answer)
    }

    /// A tool call's artifact: the same value whether the server stored it
    /// inline or, being large, as a blob of the session's db3, which is read
    /// only now, through the session's attachment route. `nil` when the call
    /// has none; `.null` for a stored JSON null. Calls made while a read of
    /// the same blob is in flight share it, each decoding its own value.
    ///
    /// Throws `.invalidArgument` on a closed view, the blob read's error for
    /// a download that fails, and a `DecodingError` for a blob that is not
    /// JSON.
    public func artifact(of call: AgentSessionToolCallRecord) async throws -> JSONValue? {
        if lock.withLock({ closed }) {
            throw JsBaoError(code: .invalidArgument, message: "The session view is closed")
        }
        guard let blobId = call.artifactBlobId, !blobId.isEmpty else { return call.artifact }
        let read: Task<Data, Error> = lock.withLock {
            if let inFlight = artifactReads[blobId] { return inFlight.read }
            let id = UUID()
            let readBlob = host.readBlob
            let sessionId = _info.sessionId
            let read = Task { [weak self] in
                // Forgotten once settled: a later call reads again (the blob
                // cache answers it).
                defer { self?.forgetArtifactRead(blobId, id: id) }
                return try await readBlob(sessionId, blobId)
            }
            artifactReads[blobId] = (id, read)
            return read
        }
        return try JSONCoding.decoder.decode(JSONValue.self, from: try await read.value)
    }

    private func forgetArtifactRead(_ blobId: String, id: UUID) {
        lock.withLock {
            if artifactReads[blobId]?.id == id { artifactReads[blobId] = nil }
        }
    }

    /// The presentations an agent message carries: each of its calls in
    /// `output-available` state whose tool is one of `names`, in part order.
    /// A call alone does not say whether its tool is a presentation, so pass
    /// the generated `<Key>Agent.presentationNames`. A refused presentation
    /// (`output-error`) and a message that is not the agent's yield none.
    /// `call(_:)` on each resolves numbers against the turn's calls in the
    /// window.
    public func presentations(of message: AgentSessionSyncedMessage, names: [String]) -> [AgentPresentation] {
        lock.withLock {
            let parts = partsByMessage[message.messageId] ?? message.parts
            let turnParts: [AgentSessionViewPart] = message.message.turnId.map { turnId in
                window.values
                    .filter { $0.turnId == turnId }
                    .flatMap { partsByMessage[$0.id] ?? [] }
            } ?? []
            return AgentPresentation.collect(message: message.message, parts: parts, turnParts: turnParts, names: names)
        }
    }

    /// Record an event on the session.
    @discardableResult
    public func recordEvent(_ event: AgentSessionEvent) async throws -> AgentSessionEventResult {
        try await host.sessions.recordEvent(sessionId: sessionId, event: event)
    }

    /// Cancel the active turn: the one named, else the one the `Session` row
    /// names, else the one `get` answers. With no turn at all, throws
    /// `.agentSessionNoActiveTurn` and sends no cancel.
    @discardableResult
    public func cancel(turnId: String? = nil) async throws -> AgentSessionCancelResult {
        var target = turnId ?? activeTurnId
        if target == nil {
            target = try await host.sessions.get(sessionId: sessionId).turn?.turnId
        }
        guard let target else {
            throw JsBaoError(
                code: .agentSessionNoActiveTurn,
                message: "There is no active turn to cancel: the session is idle."
            )
        }
        return try await host.sessions.cancel(sessionId: sessionId, turnId: target)
    }

    /// Mark the session read for the signed-in user (`sessions.markRead`):
    /// `info.hasUnread` becomes `false` and `info.lastReadAt` the marker, and
    /// `onChange` fires. Activity that arrived after the marker, while the
    /// call was answering, keeps the dot. Call it when the user opens or
    /// returns to the session.
    @discardableResult
    public func markRead() async throws -> AgentSessionReadResult {
        let result = try await host.sessions.markRead(sessionId: sessionId)
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
    /// waiting when you register, or found again when the session's db3 is
    /// live again after a reconnect, run too. Every one of your open views runs a call and the first answer
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
            answered = try await host.sessions.get(sessionId: sessionId)
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

    /// Stop listening and give up the view's subscription to the session's
    /// db3; its local copy stays. Running client-tool handlers are cancelled
    /// and their answers never sent. Idempotent.
    public func close() async {
        let closing: (unsubscribes: [@Sendable () -> Void], observations: [EventSubscription], tasks: [Task<Void, Never>])? =
            lock.withLock {
                guard !closed else { return nil }
                closed = true
                listeners.removeAll()
                var tasks = runningCalls.values.compactMap(\.task)
                if let reconcileTask { tasks.append(reconcileTask) }
                reconcileTask = nil
                runningCalls.removeAll()
                runningOrder.removeAll()
                toolHandlers.removeAll()
                answeredCalls.removeAll()
                failedCalls.removeAll()
                defer {
                    unsubscribes.removeAll()
                    observations.removeAll()
                }
                return (unsubscribes, observations, tasks)
            }
        guard let closing else { return }
        signals.release()
        for unsubscribe in closing.unsubscribes { unsubscribe() }
        for observation in closing.observations { observation.cancel() }
        for task in closing.tasks { task.cancel() }
        subscription.dispose()
    }

    // MARK: - Internals

    /// Listen to the db3's models and its going, and load the first window.
    func start() async throws {
        var unsubs: [@Sendable () -> Void] = []
        for model in AgentSessionModels.modelNames {
            unsubs.append(try records.subscribe(model) { [weak self] in self?.scheduleRefresh() })
        }
        let alreadyClosed: Bool = lock.withLock {
            if !closed { unsubscribes.append(contentsOf: unsubs) }
            return closed
        }
        if alreadyClosed { unsubs.forEach { $0() } }
        let observation = subscription.observe { [weak self] event in
            switch event {
            case let .state(state): self?.onSubscriptionState(state)
            case let .gone(gone): self?.onGone(gone)
            default: break
            }
        }
        let observed: Bool = lock.withLock {
            if !closed { observations.append(observation) }
            return !closed
        }
        if !observed { observation.cancel() }
        // A loss the room delivered after `ready()` and before this observer
        // is not replayed: the subscription's state still says it.
        let state = subscription.state
        if observed && state.phase == .gone { onGone(Db3GoneEvent(id: sessionId, reason: Self.goneReason(state.error?.code))) }
        // What arrived while the session was read and its db3 subscribed, then the rest.
        signals.attach { [weak self] signal in
            switch signal {
            case .change(let event): self?.onSessionChanged(event)
            case .status(let status): self?.onConnectionStatus(status)
            }
        }
        try await onWorkQueue { try self.refreshNow(notify: false) }
        if markWhileOpen { readWhileOpen() }
    }

    /// The room stopped syncing the db3 with this client. On `.permission` the
    /// member was removed: running handlers stop, the local copy is evicted
    /// and the view empties; otherwise the copy is kept and `gone` says why.
    private func onGone(_ event: Db3GoneEvent) {
        if event.reason == .permission {
            loseSession()
            return
        }
        let changed: Bool = lock.withLock {
            guard !closed, !lost else { return false }
            goneEvent = event
            return true
        }
        if changed { notify() }
    }

    /// The reason a `gone` state's error code names; a refusal by default.
    private static func goneReason(_ code: String?) -> Db3GoneEvent.Reason {
        switch code {
        case JsBaoErrorCode.db3SyncOff.rawValue: return .syncOff
        case JsBaoErrorCode.db3ClientOutdated.rawValue: return .clientOutdated
        default: return .permission
        }
    }

    /// You no longer have the session: the room refused you, or its `removed`
    /// event came first. Running handlers stop, the subscription is given up,
    /// the local copy is evicted and the view empties; once only. Your own
    /// messages still waiting or sending stay: each fails on its own answer.
    private func loseSession() {
        let tasks: [Task<Void, Never>]? = lock.withLock {
            guard !closed, !lost else { return nil }
            lost = true
            goneEvent = Db3GoneEvent(id: _info.sessionId, reason: .permission)
            let tasks = runningCalls.values.compactMap(\.task)
            runningCalls.removeAll()
            runningOrder.removeAll()
            toolHandlers.removeAll()
            answeredCalls.removeAll()
            failedCalls.removeAll()
            window = [:]
            partsByMessage = [:]
            steps = []
            turns = [:]
            memberRecords = []
            queueEntries = []
            sessionRecord = nil
            olderRemain = false
            _ = rebuildLocked()
            return tasks
        }
        guard let tasks else { return }
        tasks.forEach { $0.cancel() }
        subscription.dispose()
        let evict = host.db3.evict
        let sessionId = self.sessionId
        let logger = host.logger
        Task {
            do {
                try await evict(sessionId)
            } catch {
                logger?.warn("[agents] evicting the lost session", sessionId, "failed:", error.localizedDescription)
            }
        }
        notify()
    }

    /// The subscription's state: live again after a reconnect, a call whose
    /// answer failed to go out runs again. The lifecycle may deliver two
    /// states out of order, so the phase now, not the event's order, says
    /// whether it is live again.
    private func onSubscriptionState(_ state: Db3State) {
        let live = subscription.state.phase == .live
        let again: Bool = lock.withLock {
            guard !closed else { return false }
            if state.phase != .live { leftLive = true }
            guard live, leftLive else { return false }
            leftLive = false
            return true
        }
        if again { scheduleEvaluate() }
    }

    /// A change event: this session's upsert merged into `info`; a removal
    /// changes nothing.
    private func onSessionChanged(_ event: AgentSessionChangedEvent) {
        var lose = false
        let (changed, unread): (Bool, Bool) = lock.withLock {
            guard !closed, event.sessionId == _info.sessionId else { return (false, false) }
            let at = AgentSessionList.ms(event.at) ?? 0
            switch event.action {
            case .removed:
                removedAt = max(at, removedAt ?? 0)
                lose = infoAt.map { at >= $0 } ?? true
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
        if lose { loseSession() }
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
            guard !closed, !lost, !refreshQueued else { return false }
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

    /// Decoded rows of `model` matching `filter`, from the db3's local copy:
    /// one page of `limit`, or with none every match (the records API answers
    /// 100 unless told otherwise), in pages of its most followed through their
    /// cursor. Runs on `work`.
    private func rowsOf<R>(
        _ model: String, _ decode: ([String: JSONValue]) -> R?, _ filter: DocumentFilter? = nil,
        sort: [(String, Int)]? = nil, limit: Int? = nil
    ) throws -> (records: [R], hasMore: Bool) {
        var out: [R] = []
        // The eviction of a lost session can unbind the store under a read:
        // its error is the loss.
        func query(_ options: QueryOptions) throws -> PagedQueryResult<PrimitiveRow> {
            do {
                return try records.query(model, filter, options: options)
            } catch {
                if lock.withLock({ lost }) { throw SessionLostDuringRead() }
                throw error
            }
        }
        func take(_ rows: [PrimitiveRow]) throws {
            if lock.withLock({ lost }) { throw SessionLostDuringRead() }
            for row in rows {
                if let record = decode(row.raw) { out.append(record) }
            }
        }
        if let limit {
            let page = try query(QueryOptions(sortOrder: sort, limit: limit))
            try take(page.data)
            return (out, page.hasMore)
        }
        var cursor: String?
        repeat {
            let page = try query(QueryOptions(sortOrder: sort, limit: Self.recordsPageMax, cursor: cursor))
            try take(page.data)
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        return (out, false)
    }

    /// The `Session` row, the members, the queue, the window's messages from
    /// its oldest on, and their parts, calls, steps and turns; listeners hear
    /// of it only when something changed. Runs on `work`.
    private func refreshNow(notify shouldNotify: Bool) throws {
        do {
            try refreshRows(notify: shouldNotify)
        } catch is SessionLostDuringRead {
            // Lost while the rows were read: the emptied view takes none of them.
        }
    }

    private func refreshRows(notify shouldNotify: Bool) throws {
        let (isClosed, oldest) = lock.withLock { (closed || lost, Self.oldestSeq(window)) }
        guard !isClosed else { return }
        let session = try rowsOf("Session", AgentSessionRecord.init(row:), ["id": .string(sessionId)], limit: 1).records.first
        let members = try rowsOf("Member", AgentSessionMemberRecord.init(row:)).records
            .sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
        let waiting = try rowsOf("Message", AgentSessionMessageRecord.init(row:), ["queueSeq": ["$exists": true]]).records
        let queue = Self.queueOf(waiting)
        var nextWindow: [String: AgentSessionMessageRecord] = [:]
        var nextOlder: Bool?
        if let oldest {
            let page = try rowsOf(
                "Message", AgentSessionMessageRecord.init(row:), ["seq": ["$gte": .number(oldest)]], sort: [("seq", 1)]
            )
            for message in page.records { nextWindow[message.id] = message }
        } else {
            let page = try rowsOf("Message", AgentSessionMessageRecord.init(row:), nil, sort: [("seq", -1)], limit: pageSize)
            for message in page.records { nextWindow[message.id] = message }
            nextOlder = page.hasMore
        }
        let loaded = try loadRows(for: nextWindow)
        let changed: Bool = lock.withLock {
            guard !closed, !lost else { return false }
            var changed = false
            if session != sessionRecord {
                sessionRecord = session
                changed = true
            }
            if members != memberRecords {
                memberRecords = members
                changed = true
            }
            if queue != queueEntries {
                queueEntries = queue
                changed = true
            }
            let olderBefore = olderRemain
            if let nextOlder { olderRemain = nextOlder }
            window = nextWindow
            partsByMessage = loaded.parts
            steps = loaded.steps
            turns = loaded.turns
            return rebuildLocked() || changed || olderBefore != olderRemain
        }
        if changed && shouldNotify { notify() }
        evaluateClientTools(session: session)
    }

    /// The waiting messages, in queue order, as one entry per author in the
    /// order of each author's first. A taken message's `queueSeq` is cleared
    /// to null, which the local query still matches: it is no longer waiting.
    static func queueOf(_ waiting: [AgentSessionMessageRecord]) -> [PrimitiveQueueEntry] {
        var entries: [PrimitiveQueueEntry] = []
        var index: [String: Int] = [:]
        let queued = waiting.compactMap { message in message.queueSeq.map { (seq: $0, message: message) } }
        for (_, message) in queued.sorted(by: { ($0.seq, $0.message.id) < ($1.seq, $1.message.id) }) {
            let userId = message.authorUserId ?? ""
            if let at = index[userId] {
                entries[at].messageIds.append(message.id)
            } else {
                index[userId] = entries.count
                entries.append(PrimitiveQueueEntry(userId: userId, messageIds: [message.id]))
            }
        }
        return entries
    }

    /// The parts and calls of the window's messages, and the steps and turns
    /// of its turns. Runs on `work`.
    private func loadRows(for window: [String: AgentSessionMessageRecord]) throws -> (
        parts: [String: [AgentSessionViewPart]], steps: [AgentSessionStepRecord], turns: [String: AgentSessionTurnRecord]
    ) {
        var parts: [String: [AgentSessionViewPart]] = [:]
        for chunk in Self.chunks(window.keys.sorted(), Self.inChunk) {
            let filter: DocumentFilter = ["messageId": ["$in": .array(chunk.map { .string($0) })]]
            for part in try rowsOf("Part", AgentSessionPartRecord.init(row:), filter).records {
                parts[part.messageId, default: []].append(.part(part))
            }
            for call in try rowsOf("ToolCall", AgentSessionToolCallRecord.init(row:), filter).records {
                parts[call.messageId, default: []].append(.toolCall(call))
            }
        }
        for (id, list) in parts {
            parts[id] = list.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
        }
        let turnIds = Set(window.values.compactMap(\.turnId)).sorted()
        var steps: [AgentSessionStepRecord] = []
        var turns: [String: AgentSessionTurnRecord] = [:]
        for chunk in Self.chunks(turnIds, Self.inChunk) {
            let ids: JSONValue = .array(chunk.map { .string($0) })
            steps.append(contentsOf: try rowsOf("Step", AgentSessionStepRecord.init(row:), ["turnId": ["$in": ids]]).records)
            for turn in try rowsOf("Turn", AgentSessionTurnRecord.init(row:), ["id": ["$in": ids]]).records {
                turns[turn.id] = turn
            }
        }
        return (parts, steps.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }, turns)
    }

    /// At most one evaluation waits behind the running work, so a burst of
    /// state changes is read once.
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

    /// `evaluateClientTools(session:)` over the `Session` row read now. Runs
    /// on `work`.
    private func evaluateClientTools() {
        guard lock.withLock({ !closed && !lost && !toolHandlers.isEmpty }) else { return }
        guard let page = try? rowsOf("Session", AgentSessionRecord.init(row:), ["id": .string(sessionId)], limit: 1) else {
            return
        }
        evaluateClientTools(session: page.records.first)
    }

    /// Start a handler for each call of the active turn that waits on this
    /// member, read from the db3 rather than the window. Runs only when the
    /// active turn's `Turn` row names the current user as its initiator. Runs
    /// on `work`.
    private func evaluateClientTools(session: AgentSessionRecord?) {
        let turnId = session?.activeTurnId
        let proceed: Bool = lock.withLock {
            guard !closed, !lost, !toolHandlers.isEmpty else { return false }
            answeredCalls = answeredCalls.filter { $0.value == turnId }
            failedCalls = failedCalls.filter { $0.value.turnId == turnId }
            return true
        }
        guard proceed, let turnId, let userId = host.currentUserId() else { return }
        guard let turn = try? rowsOf("Turn", AgentSessionTurnRecord.init(row:), ["id": .string(turnId)], limit: 1).records.first,
              turn.initiatorUserId == userId,
              let calls = try? rowsOf("ToolCall", AgentSessionToolCallRecord.init(row:), ["turnId": .string(turnId)]).records
        else { return }
        let starts: [(AgentClientToolDecisions.EligibleCall, ClientToolRegistration, UUID)] = lock.withLock {
            guard !closed, !lost else { return [] }
            var starts: [(AgentClientToolDecisions.EligibleCall, ClientToolRegistration, UUID)] = []
            let registered = Set(toolHandlers.keys)
            for call in calls.sorted(by: { ($0.seq, $0.id) < ($1.seq, $1.id) }) {
                if AgentClientToolDecisions.terminalStates.contains(call.state) { answeredCalls[call.id] = nil }
                if let failed = failedCalls[call.id], failed.state != call.state { failedCalls[call.id] = nil }
                guard let eligible = AgentClientToolDecisions.eligibleCall(call: call, registered: registered),
                      runningCalls[call.id] == nil, answeredCalls[call.id] == nil, failedCalls[call.id] == nil,
                      let registration = toolHandlers[eligible.toolName]
                else { continue }
                let runId = UUID()
                runningCalls[call.id] = RunningClientTool(id: runId, task: nil)
                runningOrder.append(call.id)
                starts.append((eligible, registration, runId))
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
                _ = try await self.host.sessions.answer(sessionId: self.sessionId, callId: call.callId, answer)
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

    /// The page of messages below the window's oldest `seq`, with their rows.
    /// Runs on `work`.
    private func loadOlderNow() throws -> AgentSessionLoadOlderResult {
        do {
            return try loadOlderRows()
        } catch is SessionLostDuringRead {
            return AgentSessionLoadOlderResult(loaded: 0, hasOlder: false)
        }
    }

    private func loadOlderRows() throws -> AgentSessionLoadOlderResult {
        let (isClosed, remain, oldest) = lock.withLock { (closed || lost, olderRemain, Self.oldestSeq(window)) }
        guard !isClosed, remain else { return AgentSessionLoadOlderResult(loaded: 0, hasOlder: false) }
        let page = try rowsOf(
            "Message", AgentSessionMessageRecord.init(row:), oldest.map { ["seq": ["$lt": .number($0)]] },
            sort: [("seq", -1)], limit: pageSize
        )
        var nextWindow = lock.withLock { window }
        var loaded = 0
        for message in page.records where nextWindow[message.id] == nil {
            nextWindow[message.id] = message
            loaded += 1
        }
        let rows = try loadRows(for: nextWindow)
        let (taken, changed, hasOlder): (Bool, Bool, Bool) = lock.withLock {
            guard !closed, !lost else { return (false, false, false) }
            let olderBefore = olderRemain
            olderRemain = page.hasMore
            window = nextWindow
            partsByMessage = rows.parts
            steps = rows.steps
            turns = rows.turns
            return (true, rebuildLocked() || olderBefore != olderRemain, olderRemain)
        }
        // Closed or lost before the page went in: nothing was loaded.
        guard taken else { return AgentSessionLoadOlderResult(loaded: 0, hasOlder: false) }
        if changed { notify() }
        return AgentSessionLoadOlderResult(loaded: loaded, hasOlder: hasOlder)
    }

    /// The messages the properties answer. Whether any entry changed. Caller
    /// holds `lock`.
    private func rebuildLocked() -> Bool {
        let queued = Set(queueEntries.flatMap(\.messageIds))
        var stepsByTurn: [String: [AgentSessionStepRecord]] = [:]
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
                    turn: message.turnId.flatMap { turns[$0] },
                    state: queued.contains(message.id) || message.queueSeq != nil ? .queued : .synced
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
        // Its own references to session uploads still in the queue.
        var waitFor: [String] = []
        if !entry.files.isEmpty {
            let queued = Set(await attachments.uploads().map(\.blobId))
            var seen = Set<String>()
            waitFor = entry.files.map(\.blobId).filter { queued.contains($0) && seen.insert($0).inserted }
        }
        var current = waitFor.isEmpty ? entry : entry.with(state: .waiting)
        let displaced: Task<Void, Error>? = lock.withLock {
            // An earlier entry under the same id gives way to this one; a
            // waiting one stops waiting.
            let displaced = waitingSends.removeValue(forKey: entry.clientMessageId)?.task
            pendingEntries.removeAll { $0.clientMessageId == entry.clientMessageId }
            pendingEntries.append(current)
            _ = rebuildLocked()
            return displaced
        }
        displaced?.cancel()
        notify()
        if !waitFor.isEmpty {
            let outcome = await wait(for: waitFor, of: entry)
            let next: AgentSessionPendingMessage
            switch outcome {
            case .failure(let error): next = current.with(state: .failed, error: Self.sendError(of: error))
            case .success: next = current.with(state: .sending)
            }
            // The check that it was not displaced and its move out of
            // `.waiting` are one step, so a send that displaces it at any
            // point leaves it unsent.
            guard replace(current, with: next) else {
                throw JsBaoError(
                    code: .invalidArgument,
                    message: "The message \"\(entry.clientMessageId)\" was replaced by a newer send with the same clientMessageId",
                    details: ["clientMessageId": .string(entry.clientMessageId)]
                )
            }
            if case .failure(let error) = outcome { throw error }
            current = next
        }
        let result: AgentSessionSendResult
        do {
            result = try await host.sessions.send(sessionId: sessionId, body: entry.body)
        } catch {
            replace(current, with: current.with(state: .failed, error: Self.sendError(of: error)))
            throw error
        }
        replace(current, with: current.with(state: .sending, messageId: result.messageId))
        return result
    }

    /// Wait until every upload `blobIds` names lands, or the first fails. The
    /// wait is kept by client message id, so a newer send under that id ends
    /// it at once; nothing else does, `close()` included.
    private func wait(for blobIds: [String], of entry: AgentSessionPendingMessage) async -> Result<Void, Error> {
        let attachments = self.attachments
        let waiting = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for blobId in blobIds {
                    group.addTask { _ = try await attachments.waitUntilUploaded(blobId: blobId) }
                }
                for try await _ in group {}
            }
        }
        let kept: Bool = lock.withLock {
            guard pendingEntries.contains(where: { $0.attempt == entry.attempt }) else { return false }
            waitingSends[entry.clientMessageId] = (entry.attempt, waiting)
            return true
        }
        if !kept { waiting.cancel() }
        let outcome = await waiting.result
        lock.withLock {
            if waitingSends[entry.clientMessageId]?.attempt == entry.attempt {
                waitingSends[entry.clientMessageId] = nil
            }
        }
        return outcome
    }

    /// Whether `entry` was still pending, and so replaced.
    @discardableResult
    private func replace(_ entry: AgentSessionPendingMessage, with next: AgentSessionPendingMessage) -> Bool {
        let replaced: Bool = lock.withLock {
            guard let at = pendingEntries.firstIndex(where: { $0.attempt == entry.attempt }) else { return false }
            pendingEntries[at] = next
            _ = rebuildLocked()
            return true
        }
        if replaced { notify() }
        return replaced
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

    private static func oldestSeq(_ window: [String: AgentSessionMessageRecord]) -> Double? {
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

/// A local read finished after you lost the session: its rows are not taken
/// into the emptied view.
private struct SessionLostDuringRead: Error {}

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
    /// with their parts, calls, steps and turns (older pages with
    /// `loadOlder()`), its members and queue, your own messages shown at once
    /// while they send, and `onChange` on every change. `info` stays current
    /// as the session changes; `markRead: .whileOpen` keeps the session read
    /// while the view is open.
    ///
    /// Runs `get` first (a refusal throws before anything is subscribed), then
    /// subscribes to the session's db3, whose id is the session's, waits until
    /// it is live, and reads the first window from its local copy; nothing
    /// opens a document or registers a model. When the subscription cannot go
    /// live (`DB3_ACCESS_REFUSED`, `DB3_READY_TIMEOUT`, `NOT_A_DB3`), `open`
    /// throws that error with nothing left subscribed; on `DB3_ACCESS_REFUSED`
    /// the session's copy on this device is evicted too. Call `close()` when
    /// done. A `pageSize` outside 1…500 throws `.invalidArgument` before any
    /// request.
    public func open(
        sessionId: String, options: OpenAgentSessionOptions = OpenAgentSessionOptions()
    ) async throws -> AgentSessionView {
        try Self.validateOpen(sessionId, options)
        guard let client else {
            throw JsBaoError(code: .unavailable, message: "agents.sessions.open requires a wired JsBaoClient")
        }
        return try await open(host: AgentSessionViewHost(client: client, sessions: self), sessionId: sessionId, options: options)
    }

    /// `open` over `host`: what the client's own `open` runs.
    func open(
        host: AgentSessionViewHost, sessionId: String, options: OpenAgentSessionOptions = OpenAgentSessionOptions()
    ) async throws -> AgentSessionView {
        try Self.validateOpen(sessionId, options)
        // Heard from before `get`: a change or the first connection while the
        // session is read or its db3 subscribed reaches the view (CSO-4380-001).
        let signals = host.signals()
        // A connection already up when `get` is read hears every change since.
        let connectedAtOpen = host.isConnected()
        let info: AgentSessionInfo
        let subscription: Db3Subscription
        do {
            info = try await get(sessionId: sessionId)
            subscription = try host.db3.subscribe(info.sessionId)
        } catch {
            signals.release()
            throw error
        }
        do {
            try await subscription.ready()
        } catch {
            subscription.dispose()
            signals.release()
            // The room refused you the session (you were removed after `get`
            // answered): a copy kept from an earlier view does not outlive it.
            if (error as? JsBaoError)?.code == .db3AccessRefused {
                do {
                    try await host.db3.evict(info.sessionId)
                } catch let evictError {
                    host.logger?.warn("[agents] evicting the refused session", info.sessionId, "failed:", evictError.localizedDescription)
                }
            }
            throw error
        }
        let view = AgentSessionView(
            host: host, info: info, subscription: subscription, pageSize: options.pageSize,
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

    private static func validateOpen(_ sessionId: String, _ options: OpenAgentSessionOptions) throws {
        guard (1...AgentSessionView.maxPageSize).contains(options.pageSize) else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "pageSize must be an integer from 1 to \(AgentSessionView.maxPageSize)",
                details: ["field": .string("pageSize")]
            )
        }
        try require(sessionId, "sessionId")
    }
}
