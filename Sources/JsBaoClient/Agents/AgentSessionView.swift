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

/// Options for `client.agents.sessions.open`.
public struct OpenAgentSessionOptions: Sendable {
    /// Messages per page, 1 to 500: the first window and each `loadOlder()`.
    public var pageSize: Int
    /// How to open the document. `nil` opens it with
    /// `waitForLoad: .network, enableNetworkSync: true`.
    public var open: OpenDocumentOptions?

    public init(pageSize: Int = 50, open: OpenDocumentOptions? = nil) {
        self.pageSize = pageSize
        self.open = open
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

    init(api: AgentSessionsAPI, client: JsBaoClient, info: AgentSessionInfo, pageSize: Int) {
        self.api = api
        self.client = client
        self._info = info
        self.pageSize = pageSize
    }

    // MARK: - State

    /// The session's info as `get` answered it; `refreshInfo()` reads it again.
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

    /// Read the session's info again (`get`), and notify when it is read.
    @discardableResult
    public func refreshInfo() async throws -> AgentSessionInfo {
        let next = try await api.get(sessionId: sessionId)
        lock.withLock { _info = next }
        notify()
        return next
    }

    /// Stop listening and close the session's document. Idempotent.
    public func close() async {
        let unsubscribing: [@Sendable () -> Void]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            listeners.removeAll()
            defer { unsubscribes.removeAll() }
            return unsubscribes
        }
        guard let unsubscribing else { return }
        for unsubscribe in unsubscribing { unsubscribe() }
        await client.documents.close(documentId)
    }

    // MARK: - Internals

    /// Subscribe to the four models and load the first window.
    func start() async throws {
        var unsubs: [@Sendable () -> Void] = []
        for schema in AgentSessionModels.schemas {
            unsubs.append(client.codegen.subscribe(schema) { [weak self] in self?.scheduleRefresh() })
        }
        let alreadyClosed: Bool = lock.withLock {
            if !closed { unsubscribes.append(contentsOf: unsubs) }
            return closed
        }
        if alreadyClosed { unsubs.forEach { $0() } }
        try await onWorkQueue { try self.refreshNow(notify: false) }
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

// MARK: - open

extension AgentSessionsAPI {
    /// Open a session as a live view: its info, the latest page of messages
    /// with their parts and steps (older pages with `loadOlder()`), your own
    /// messages shown at once while they send, and `onChange` on every change.
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
        let info = try await get(sessionId: sessionId)
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
        let view = AgentSessionView(api: self, client: client, info: info, pageSize: options.pageSize)
        do {
            try await view.start()
        } catch {
            await view.close()
            throw error
        }
        return view
    }
}
