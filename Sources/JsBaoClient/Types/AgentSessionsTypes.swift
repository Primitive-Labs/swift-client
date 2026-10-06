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
    public let title: String?
    public let scope: String?
    /// ISO-8601; `nil` when the session's listing entry is missing.
    public let lastActivityAt: String?
    public let members: AgentSessionMembers
    public let role: AgentSessionRole
    /// Decided from the session object, never the session row. Open: a status
    /// outside the vocabulary reads `.unknown(raw)`.
    public let status: PrimitiveSessionStatus
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
        case lastActivityAt, members, role, status, turn, object, turnContexts, lastTurn
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
