import Foundation

// MARK: - Agent sessions (`client.agents.sessions`)
//
// The Swift half of the JS client's `src/client/api/agentSessionsApi.ts`
// (#3810). Every value the server may grow — a status, a role, a turn phase,
// a call state — decodes open: a value this client does not know reads
// `.unknown(raw)` instead of failing the whole answer.

/// A member's role in an agent session. A `viewer` reads the session and
/// holds a `reader` grant on its document; a `participant` also sends
/// messages and holds a `read-write` grant.
public enum AgentSessionMemberRole: String, Codable, Sendable, Equatable {
    case viewer
    case participant
}

/// A session's members, each list in the order they were added.
public struct AgentSessionMembers: Codable, Sendable, Equatable {
    public let viewers: [String]
    public let participants: [String]

    public init(viewers: [String], participants: [String]) {
        self.viewers = viewers
        self.participants = participants
    }
}

/// The caller's standing in a session: their role in it, or `admin` when they
/// reached it as an app owner or admin without being in it. Open: a role this
/// client does not know reads `.unknown(raw)`.
public enum AgentSessionRole: Sendable, Equatable, Hashable, Codable {
    case owner
    case participant
    case viewer
    case admin
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "participant": self = .participant
        case "viewer": self = .viewer
        case "admin": self = .admin
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .owner: return "owner"
        case .participant: return "participant"
        case .viewer: return "viewer"
        case .admin: return "admin"
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What the active turn is doing: `model` while a model call runs, `tools`
/// while server tools run, `paused` while a call waits on a person,
/// `draining` while a turn that ended waits for a server tool to finish,
/// `starting` before its first round. Open: an unknown phase reads
/// `.unknown(raw)`.
public enum AgentTurnPhase: Sendable, Equatable, Hashable, Codable {
    case model
    case tools
    case paused
    case draining
    case starting
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "model": self = .model
        case "tools": self = .tools
        case "paused": self = .paused
        case "draining": self = .draining
        case "starting": self = .starting
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .model: return "model"
        case .tools: return "tools"
        case .paused: return "paused"
        case .draining: return "draining"
        case .starting: return "starting"
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The calls a paused turn waits on a person for, and until when.
public struct AgentTurnPause: Codable, Sendable, Equatable {
    /// The calls still unanswered.
    public let callIds: [String]
    /// ISO-8601.
    public let since: String
    /// ISO-8601; the calls expire then.
    public let expiresAt: String
}

/// A transition the active turn is making: `answer` or `end`. `kind` stays a
/// string so a kind added later still decodes.
public struct AgentTurnPending: Codable, Sendable, Equatable {
    public let kind: String
}

/// The active turn of a session, as `get` answers it.
public struct AgentSessionTurnSummary: Codable, Sendable, Equatable {
    public let turnId: String
    /// The member whose messages started the turn.
    public let initiatorUserId: String
    /// ISO-8601; `nil` until the turn has started.
    public let startedAt: String?
    public let phase: AgentTurnPhase
    /// Model rounds begun.
    public let rounds: Int
    /// ISO-8601; until when the turn's runner holds it.
    public let leaseUntil: String?
    /// Who may answer the turn's calls, as pinned at the turn's start.
    public let answeredBy: String?
    public let pause: AgentTurnPause?
    public let pending: AgentTurnPending?
}

/// One agent session, as `client.agents.sessions.get` answers it: who it
/// belongs to, which agent it runs, its members, its status, and the document
/// that holds its conversation. The conversation itself is read by opening
/// `documentId` (or with `open`), never through this call.
public struct AgentSessionInfo: Decodable, Sendable, Equatable {
    public let sessionId: String
    /// The agent prompt the session is bound to.
    public let agentKey: String
    /// The session's conversation document.
    public let documentId: String
    public let ownerUserId: String
    /// ISO-8601.
    public let createdAt: String
    /// An open view keeps it current as the session is renamed.
    public internal(set) var title: String?
    public internal(set) var scope: String?
    /// ISO-8601; `nil` when the session's listing entry is missing. An open
    /// view keeps it current as activity arrives.
    public internal(set) var lastActivityAt: String?
    /// Whether you have activity in this session you have not marked read
    /// (`markRead`): an agent's answer or pause, a turn's end, or another
    /// member's message or event. Always `false` for an app owner or admin
    /// who is not in the session; `false` when the server does not send it.
    public internal(set) var hasUnread: Bool
    /// When you last marked the session read (ISO-8601), or `nil`.
    public internal(set) var lastReadAt: String?
    /// An open view keeps it current as members change.
    public internal(set) var members: AgentSessionMembers
    public let role: AgentSessionRole
    /// Decided from the session object, never the session row. Open: a status
    /// outside the vocabulary reads `.unknown(raw)`. An open view keeps it
    /// current.
    public internal(set) var status: PrimitiveSessionStatus
    /// The active turn, or `nil` when none runs.
    public let turn: AgentSessionTurnSummary?
    /// For app owners and admins only: what only the session object knows
    /// (the active and last turn, the queue, the lease, the server calls).
    /// Carried whole: new keys may appear, so read the ones you know.
    public let object: JSONValue?
    /// For app owners and admins only: the turn contexts the session kept.
    public let turnContexts: JSONValue?
    /// For app owners and admins only: the last turn's summary and timing.
    public let lastTurn: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case sessionId, agentKey, documentId, ownerUserId, createdAt, title, scope
        case lastActivityAt, hasUnread, lastReadAt, members, role, status, turn, object, turnContexts, lastTurn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        agentKey = try c.decode(String.self, forKey: .agentKey)
        documentId = try c.decode(String.self, forKey: .documentId)
        ownerUserId = try c.decode(String.self, forKey: .ownerUserId)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        lastActivityAt = try c.decodeIfPresent(String.self, forKey: .lastActivityAt)
        hasUnread = try c.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false
        lastReadAt = try c.decodeIfPresent(String.self, forKey: .lastReadAt)
        members = try c.decode(AgentSessionMembers.self, forKey: .members)
        role = try c.decode(AgentSessionRole.self, forKey: .role)
        status = PrimitiveSessionStatus(rawValue: try c.decode(String.self, forKey: .status))
        turn = try c.decodeIfPresent(AgentSessionTurnSummary.self, forKey: .turn)
        object = try Self.present(c, .object)
        turnContexts = try Self.present(c, .turnContexts)
        lastTurn = try Self.present(c, .lastTurn)
    }

    /// A key carried whole: `nil` when absent, the value (`.null` included)
    /// when present.
    private static func present(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> JSONValue? {
        guard c.contains(key) else { return nil }
        return try c.decode(JSONValue.self, forKey: key)
    }
}

/// One entry of `client.agents.sessions.list`: what an app shows in a session
/// list without opening any document.
public struct AgentSessionListItem: Codable, Sendable, Equatable {
    public let sessionId: String
    public let agentKey: String
    public let scope: String?
    public let documentId: String
    public let ownerUserId: String
    /// The listed user's role in the session.
    public let role: AgentSessionRole
    public let title: String?
    /// ISO-8601.
    public let lastActivityAt: String
    public let createdAt: String?
    /// Whether the listed user has activity in this session they have not
    /// marked read: an agent's answer or pause, a turn's end, or another
    /// member's message or event. Their own never count. `false` when the
    /// server does not send it.
    public let hasUnread: Bool
    /// When the listed user last marked the session read (ISO-8601), or `nil`.
    public let lastReadAt: String?
    /// The session's status as of its last listed activity, or `nil` for an
    /// entry written before the status was listed. A watched list (`watch`)
    /// and its change events carry every status change as it happens. Open: a
    /// status outside the vocabulary reads `.unknown(raw)`.
    public let status: PrimitiveSessionStatus?

    private enum CodingKeys: String, CodingKey {
        case sessionId, agentKey, scope, documentId, ownerUserId, role, title
        case lastActivityAt, createdAt, hasUnread, lastReadAt, status
    }

    init(
        sessionId: String, agentKey: String, scope: String?, documentId: String, ownerUserId: String,
        role: AgentSessionRole, title: String?, lastActivityAt: String, createdAt: String?,
        hasUnread: Bool, lastReadAt: String?, status: PrimitiveSessionStatus?
    ) {
        self.sessionId = sessionId
        self.agentKey = agentKey
        self.scope = scope
        self.documentId = documentId
        self.ownerUserId = ownerUserId
        self.role = role
        self.title = title
        self.lastActivityAt = lastActivityAt
        self.createdAt = createdAt
        self.hasUnread = hasUnread
        self.lastReadAt = lastReadAt
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        agentKey = try c.decode(String.self, forKey: .agentKey)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        documentId = try c.decode(String.self, forKey: .documentId)
        ownerUserId = try c.decode(String.self, forKey: .ownerUserId)
        role = try c.decode(AgentSessionRole.self, forKey: .role)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lastActivityAt = try c.decode(String.self, forKey: .lastActivityAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        hasUnread = try c.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false
        lastReadAt = try c.decodeIfPresent(String.self, forKey: .lastReadAt)
        status = try c.decodeIfPresent(String.self, forKey: .status).map(PrimitiveSessionStatus.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(agentKey, forKey: .agentKey)
        try c.encode(scope, forKey: .scope)
        try c.encode(documentId, forKey: .documentId)
        try c.encode(ownerUserId, forKey: .ownerUserId)
        try c.encode(role, forKey: .role)
        try c.encode(title, forKey: .title)
        try c.encode(lastActivityAt, forKey: .lastActivityAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(hasUnread, forKey: .hasUnread)
        try c.encode(lastReadAt, forKey: .lastReadAt)
        try c.encode(status?.rawValue, forKey: .status)
    }

    /// This item with some fields replaced.
    func with(
        lastActivityAt: String? = nil, lastReadAt: String?? = nil, hasUnread: Bool? = nil,
        status: PrimitiveSessionStatus?? = nil
    ) -> AgentSessionListItem {
        AgentSessionListItem(
            sessionId: sessionId, agentKey: agentKey, scope: scope, documentId: documentId,
            ownerUserId: ownerUserId, role: role, title: title,
            lastActivityAt: lastActivityAt ?? self.lastActivityAt, createdAt: createdAt,
            hasUnread: hasUnread ?? self.hasUnread, lastReadAt: lastReadAt ?? self.lastReadAt,
            status: status ?? self.status
        )
    }
}

/// What changed a session's listing entry, in an `AgentSessionChangedEvent`.
/// Open: a change this client does not know reads `.unknown(raw)`.
public enum AgentSessionChange: Sendable, Equatable, Hashable {
    case created
    case activity
    case status
    case read
    case title
    case members
    case removed
    case deleted
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "created": self = .created
        case "activity": self = .activity
        case "status": self = .status
        case "read": self = .read
        case "title": self = .title
        case "members": self = .members
        case "removed": self = .removed
        case "deleted": self = .deleted
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .created: return "created"
        case .activity: return "activity"
        case .status: return "status"
        case .read: return "read"
        case .title: return "title"
        case .members: return "members"
        case .removed: return "removed"
        case .deleted: return "deleted"
        case .unknown(let raw): return raw
        }
    }
}

/// Payload of `.agentSessionChanged`
/// (`for await e in client.stream(for: AgentSessionChangedEvent.self)`): a
/// session you own or belong to changed for you. `.upsert` carries your list
/// item, as `list` would answer it, and the members; `.removed` (you were
/// removed, or the session was deleted) carries neither. `watch` and an open
/// view apply these for you.
public struct AgentSessionChangedEvent: Sendable, Equatable, Decodable {
    /// Whether your entry changed or left your list. Open: an action this
    /// client does not know reads `.unknown(raw)`.
    public enum Action: Sendable, Equatable, Hashable {
        case upsert
        case removed
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "upsert": self = .upsert
            case "removed": self = .removed
            default: self = .unknown(rawValue)
            }
        }
    }

    public let action: Action
    public let change: AgentSessionChange
    /// ISO-8601: when the change happened on the server.
    public let at: String
    public let sessionId: String
    /// Your list item; `nil` on `.removed`.
    public let item: AgentSessionListItem?
    /// The members; `nil` on `.removed`.
    public let members: AgentSessionMembers?

    public init(
        action: Action, change: AgentSessionChange, at: String, sessionId: String,
        item: AgentSessionListItem?, members: AgentSessionMembers?
    ) {
        self.action = action
        self.change = change
        self.at = at
        self.sessionId = sessionId
        self.item = item
        self.members = members
    }

    private enum CodingKeys: String, CodingKey { case action, change, at, sessionId, item, members }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = Action(rawValue: try c.decode(String.self, forKey: .action))
        change = AgentSessionChange(rawValue: try c.decode(String.self, forKey: .change))
        at = try c.decode(String.self, forKey: .at)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        item = try c.decodeIfPresent(AgentSessionListItem.self, forKey: .item)
        members = try c.decodeIfPresent(AgentSessionMembers.self, forKey: .members)
        if action == .upsert && item == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .item, in: c, debugDescription: "an upsert carries the recipient's item"
            )
        }
    }
}

/// Filters and paging for `client.agents.sessions.list`.
public struct ListAgentSessionsOptions: Sendable, Equatable {
    /// Whose sessions to list. `nil` for your own; naming another user
    /// requires being an app owner or admin.
    public var userId: String?
    /// Only this agent's sessions.
    public var agent: String?
    /// Only sessions created with exactly this scope.
    public var scope: String?
    /// Page size, at most 100 (the server's default is 50).
    public var limit: Int?
    /// The `nextCursor` of the previous page.
    public var cursor: String?

    public init(
        userId: String? = nil,
        agent: String? = nil,
        scope: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.userId = userId
        self.agent = agent
        self.scope = scope
        self.limit = limit
        self.cursor = cursor
    }
}

/// What `rename` answers.
public struct AgentSessionRenameResult: Codable, Sendable, Equatable {
    public let sessionId: String
    public let title: String
}

/// What `delete` answers.
public struct AgentSessionDeleteResult: Codable, Sendable, Equatable {
    public let deleted: Bool
    public let sessionId: String
    public let documentId: String
}

/// What the member calls answer: the members after the change.
public struct AgentSessionMembersResult: Codable, Sendable, Equatable {
    public let members: AgentSessionMembers
}

/// A blob already uploaded to the session's document (an image or a PDF),
/// named on a send.
public struct AgentSessionFileRef: Codable, Sendable, Equatable, Hashable {
    public let blobId: String

    public init(blobId: String) {
        self.blobId = blobId
    }
}

/// A message to send with `client.agents.sessions.send`. Every key is sent
/// only when given.
public struct AgentSessionSendBody: Encodable, Sendable, Equatable {
    public var text: String?
    /// Blobs already uploaded to the session's document: images or PDF.
    public var files: [AgentSessionFileRef]?
    /// Your id for the message. A repeat with the same id and content answers
    /// the first send (`duplicate: true`); with other content it is refused
    /// with `AGENT_CLIENT_ID_CONFLICT`.
    public var clientMessageId: String?
    /// The turn context for an agent that declares one: a JSON object, sent
    /// as given. The server checks it against the agent's declaration
    /// (`AGENT_SESSION_CONTEXT_INVALID`, `AGENT_SESSION_CONTEXT_NOT_ALLOWED`).
    public var context: JSONValue?
    /// An IANA time zone name, for the turn's `now` and `today`.
    public var timezone: String?
    /// A BCP 47 language tag.
    public var locale: String?

    public init(
        text: String? = nil,
        files: [AgentSessionFileRef]? = nil,
        clientMessageId: String? = nil,
        context: JSONValue? = nil,
        timezone: String? = nil,
        locale: String? = nil
    ) {
        self.text = text
        self.files = files
        self.clientMessageId = clientMessageId
        self.context = context
        self.timezone = timezone
        self.locale = locale
    }
}

/// What `send` answers.
public struct AgentSessionSendResult: Codable, Sendable, Equatable {
    public let messageId: String
    public let seq: Double
    /// The turn that answers the message; `nil` when it was queued behind
    /// another author's.
    public let turnId: String?
    /// Whether the message waits behind the active turn.
    public let queued: Bool
    /// A repeat of a `clientMessageId` already sent with this content: the
    /// first send's ids.
    public let duplicate: Bool?
    /// The paused turn this message set aside.
    public let superseded: String?
}

/// An answer to a call a person must answer: exactly one of an approval, a
/// client tool's output (and an optional artifact), or a client tool's error.
public enum AgentCallAnswer: Encodable, Sendable, Equatable {
    /// Approve or deny the call: `{ approval: { approved, reason? } }`.
    case approval(approved: Bool, reason: String? = nil)
    /// A client tool's output: `{ output, artifact? }`. `.null` is sent as
    /// `null`.
    case output(JSONValue, artifact: JSONValue? = nil)
    /// A client tool's failure: `{ error: { message } }`.
    case error(message: String)

    /// A client tool's output from any `Encodable` value — the generated
    /// `<Key>Tool<Name>Output` types among them.
    public static func output<T: Encodable>(
        encoding value: T, artifact: JSONValue? = nil
    ) throws -> AgentCallAnswer {
        let data = try JSONCoding.encodeData(value)
        return .output(try JSONCoding.decodeData(JSONValue.self, from: data), artifact: artifact)
    }

    private enum CodingKeys: String, CodingKey {
        case approval, output, artifact, error
    }

    private enum ApprovalKeys: String, CodingKey { case approved, reason }
    private enum ErrorKeys: String, CodingKey { case message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approval(approved, reason):
            var nested = c.nestedContainer(keyedBy: ApprovalKeys.self, forKey: .approval)
            try nested.encode(approved, forKey: .approved)
            try nested.encodeIfPresent(reason, forKey: .reason)
        case let .output(value, artifact):
            try c.encode(value, forKey: .output)
            try c.encodeIfPresent(artifact, forKey: .artifact)
        case let .error(message):
            var nested = c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try nested.encode(message, forKey: .message)
        }
    }
}

/// What `answer` answers: the call's new state (open).
public struct AgentCallAnswerResult: Decodable, Sendable, Equatable {
    public let callId: String
    public let state: PrimitiveToolCallState

    private enum CodingKeys: String, CodingKey { case callId, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callId = try c.decode(String.self, forKey: .callId)
        state = PrimitiveToolCallState(rawValue: try c.decode(String.self, forKey: .state))
    }
}

/// What `markRead` answers.
public struct AgentSessionReadResult: Codable, Sendable, Equatable {
    public let sessionId: String
    /// Your read marker now (ISO-8601).
    public let lastReadAt: String
}

/// What `cancel` answers.
public struct AgentSessionCancelResult: Codable, Sendable, Equatable {
    public let turnId: String
    public let cancelled: Bool
    /// The queued turn that starts next, or `nil`.
    public let nextTurnId: String?
}

/// An event to record with `client.agents.sessions.recordEvent`.
public struct AgentSessionEvent: Encodable, Sendable, Equatable {
    /// An event kind the session's agent declares.
    public var kind: String
    /// The payload, sent as given (`.null` included) and validated against
    /// the kind's schema.
    public var data: JSONValue
    /// Your id for the event; a repeat with the same content answers the
    /// first.
    public var eventId: String?
    /// A tool call this event refers to.
    public var refersTo: String?

    public init(kind: String, data: JSONValue, eventId: String? = nil, refersTo: String? = nil) {
        self.kind = kind
        self.data = data
        self.eventId = eventId
        self.refersTo = refersTo
    }

    private enum CodingKeys: String, CodingKey { case kind, data, eventId, refersTo }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(data, forKey: .data)
        try c.encodeIfPresent(eventId, forKey: .eventId)
        try c.encodeIfPresent(refersTo, forKey: .refersTo)
    }
}

/// What `recordEvent` answers.
public struct AgentSessionEventResult: Codable, Sendable, Equatable {
    public let messageId: String
    public let seq: Double
    public let duplicate: Bool?
}

// MARK: - Client-tool handlers

/// A call a client-tool handler runs: the call's ids and its input.
public struct AgentClientToolCall<Input: Sendable>: Sendable {
    public let sessionId: String
    public let turnId: String
    /// The call, the tool call part's `toolCallId`.
    public let callId: String
    public let messageId: String
    public let partId: String
    public let toolName: String
    public let input: Input

    public init(
        sessionId: String, turnId: String, callId: String, messageId: String, partId: String,
        toolName: String, input: Input
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.callId = callId
        self.messageId = messageId
        self.partId = partId
        self.toolName = toolName
        self.input = input
    }
}

/// What a client-tool handler returns: the call's output, and an optional
/// artifact.
public struct AgentClientToolResult<Output: Sendable>: Sendable {
    public var output: Output
    public var artifact: JSONValue?

    public init(output: Output, artifact: JSONValue? = nil) {
        self.output = output
        self.artifact = artifact
    }
}

/// Runs a client tool's call for `AgentSessionView.handleClientTools`.
/// Return the output; throw to answer the call with the error's message.
///
/// Build it untyped over `JSONValue`, or with `typed` over the generated
/// `<Key>Tool<Name>Input` and `<Key>Tool<Name>Output` types (or any
/// `Decodable` input and `Encodable` output).
public struct AgentClientToolHandler: Sendable {
    private let run: @Sendable (AgentClientToolCall<JSONValue>) async throws -> AgentCallAnswer

    /// A handler over the part's `input` as `JSONValue`, answering with a
    /// `JSONValue` output.
    public init(
        _ run: @escaping @Sendable (AgentClientToolCall<JSONValue>) async throws -> AgentClientToolResult<JSONValue>
    ) {
        self.run = { call in
            let result = try await run(call)
            return .output(result.output, artifact: result.artifact)
        }
    }

    private init(answering run: @escaping @Sendable (AgentClientToolCall<JSONValue>) async throws -> AgentCallAnswer) {
        self.run = run
    }

    /// A handler whose input is decoded into `Input` and whose output is
    /// encoded from `Output`. An input that does not decode, or an output
    /// that does not encode, answers the call with the error.
    public static func typed<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ run: @escaping @Sendable (AgentClientToolCall<Input>) async throws -> AgentClientToolResult<Output>
    ) -> AgentClientToolHandler {
        AgentClientToolHandler(answering: { call in
            let input = try JSONCoding.decodeData(Input.self, from: JSONCoding.encodeData(call.input))
            let result = try await run(AgentClientToolCall(
                sessionId: call.sessionId, turnId: call.turnId, callId: call.callId,
                messageId: call.messageId, partId: call.partId, toolName: call.toolName, input: input
            ))
            return try AgentCallAnswer.output(encoding: result.output, artifact: result.artifact)
        })
    }

    /// The answer the handler gives `call`: its result, encoded. The whole
    /// answer, artifact included, is encoded here, so a value the wire cannot
    /// carry (a non-finite number, a failing `Encodable`) is a handler error,
    /// never a failed request.
    func answer(_ call: AgentClientToolCall<JSONValue>) async throws -> AgentCallAnswer {
        let answer = try await run(call)
        _ = try JSONCoding.encodeData(answer)
        return answer
    }
}

/// A client-tool answer that did not land, other than one lost to another
/// answer.
public struct AgentClientToolError: Sendable {
    public let callId: String
    public let toolName: String
    public let turnId: String
    /// The server's refusal code; `nil` for a network, offline or other
    /// local failure.
    public let code: String?
    public let message: String
    /// The error the answer failed with.
    public let error: any Error

    public init(callId: String, toolName: String, turnId: String, code: String?, message: String, error: any Error) {
        self.callId = callId
        self.toolName = toolName
        self.turnId = turnId
        self.code = code
        self.message = message
        self.error = error
    }
}

/// Options for `AgentSessionView.handleClientTools`.
public struct HandleClientToolsOptions: Sendable {
    /// Hears every answer that failed, except one lost to another answer.
    /// With a `code` the server refused it and the call is not run again
    /// while its part is unchanged; without one the call runs again on the
    /// next refresh or sync.
    public var onError: (@Sendable (AgentClientToolError) -> Void)?

    public init(onError: (@Sendable (AgentClientToolError) -> Void)? = nil) {
        self.onError = onError
    }
}
