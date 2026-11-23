// GENERATED FILE — do not edit by hand.
// Rendered from src/agents/session-document-schema.ts by
// scripts/gen-agent-session-models.ts: run `pnpm gen:agent-session-models`
// after changing the IR (`pnpm check:agent-session-models` verifies).

import Foundation

/// The agent session models (design-docs/agent-sessions-db3.md §The proposed
/// models): the records of a session's db3, read by model name from its local
/// copy, and their open vocabularies. No model is registered with a client, so
/// an app's own models never collide with these names.
public enum AgentSessionModels {
    /// The generation of the `primitive:agentSession` type a session's db3 holds.
    public static let schemaVersion: Double = 3
    /// The models of a session's db3.
    public static let modelNames: [String] = ["Session", "Member", "Turn", "Message", "Part", "ToolCall", "Step"]
}

/// Values of the IR's `sessionStatus`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionStatus: Sendable, Equatable, Hashable {
    case idle
    case thinking
    case runningTool
    case awaitingAnswer
    case failed
    case expired
    case cancelled
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionStatus] = [.idle, .thinking, .runningTool, .awaitingAnswer, .failed, .expired, .cancelled]

    public init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "thinking": self = .thinking
        case "running_tool": self = .runningTool
        case "awaiting_answer": self = .awaitingAnswer
        case "failed": self = .failed
        case "expired": self = .expired
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .runningTool: return "running_tool"
        case .awaitingAnswer: return "awaiting_answer"
        case .failed: return "failed"
        case .expired: return "expired"
        case .cancelled: return "cancelled"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

extension AgentSessionRole {
    /// A value of the IR's `memberRole`: one of `owner`, `participant`, `viewer`; any other
    /// reads as `.unknown(raw)`. `nil` when the column holds no string.
    init?(memberRole json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        switch raw {
        case "owner": self = .owner
        case "participant": self = .participant
        case "viewer": self = .viewer
        default: self = .unknown(raw)
        }
    }
}

/// Values of the IR's `turnStatus`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionTurnStatus: Sendable, Equatable, Hashable {
    case running
    case completed
    case failed
    case cancelled
    case expired
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionTurnStatus] = [.running, .completed, .failed, .cancelled, .expired]

    public init(rawValue: String) {
        switch rawValue {
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "expired": self = .expired
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Values of the IR's `partKind`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionPartKind: Sendable, Equatable, Hashable {
    case text
    case reasoning
    case file
    case event
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionPartKind] = [.text, .reasoning, .file, .event]

    public init(rawValue: String) {
        switch rawValue {
        case "text": self = .text
        case "reasoning": self = .reasoning
        case "file": self = .file
        case "event": self = .event
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .text: return "text"
        case .reasoning: return "reasoning"
        case .file: return "file"
        case .event: return "event"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Values of the IR's `textState`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionTextState: Sendable, Equatable, Hashable {
    case streaming
    case done
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionTextState] = [.streaming, .done]

    public init(rawValue: String) {
        switch rawValue {
        case "streaming": self = .streaming
        case "done": self = .done
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .streaming: return "streaming"
        case .done: return "done"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Values of the IR's `toolCallState`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionToolCallState: Sendable, Equatable, Hashable {
    case inputStreaming
    case inputAvailable
    case approvalRequested
    case approvalResponded
    case outputAvailable
    case outputError
    case outputDenied
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionToolCallState] = [.inputStreaming, .inputAvailable, .approvalRequested, .approvalResponded, .outputAvailable, .outputError, .outputDenied]

    public init(rawValue: String) {
        switch rawValue {
        case "input-streaming": self = .inputStreaming
        case "input-available": self = .inputAvailable
        case "approval-requested": self = .approvalRequested
        case "approval-responded": self = .approvalResponded
        case "output-available": self = .outputAvailable
        case "output-error": self = .outputError
        case "output-denied": self = .outputDenied
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inputStreaming: return "input-streaming"
        case .inputAvailable: return "input-available"
        case .approvalRequested: return "approval-requested"
        case .approvalResponded: return "approval-responded"
        case .outputAvailable: return "output-available"
        case .outputError: return "output-error"
        case .outputDenied: return "output-denied"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Values of the IR's `authorKind`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionAuthorKind: Sendable, Equatable, Hashable {
    case user
    case agent
    case app
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionAuthorKind] = [.user, .agent, .app]

    public init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "agent": self = .agent
        case "app": self = .app
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .user: return "user"
        case .agent: return "agent"
        case .app: return "app"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Values of the IR's `stepKind`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionStepKind: Sendable, Equatable, Hashable {
    case modelCall
    case toolCall
    case contextCall
    case historyCall
    case clientCall
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionStepKind] = [.modelCall, .toolCall, .contextCall, .historyCall, .clientCall]

    public init(rawValue: String) {
        switch rawValue {
        case "model_call": self = .modelCall
        case "tool_call": self = .toolCall
        case "context_call": self = .contextCall
        case "history_call": self = .historyCall
        case "client_call": self = .clientCall
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .modelCall: return "model_call"
        case .toolCall: return "tool_call"
        case .contextCall: return "context_call"
        case .historyCall: return "history_call"
        case .clientCall: return "client_call"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Values of the IR's `stepStatus`. Open: a value this client does not know reads
/// as `.unknown(raw)`, so a newer server never breaks decoding. `rawValue`
/// round-trips either way.
public enum AgentSessionStepStatus: Sendable, Equatable, Hashable {
    case running
    case completed
    case failed
    case unknown(String)

    /// The values this client knows, in the IR's order.
    public static let known: [AgentSessionStepStatus] = [.running, .completed, .failed]

    public init(rawValue: String) {
        switch rawValue {
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// A `Session` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionRecord: Sendable, Equatable {
    public let id: String
    public let agentKey: String
    public let configId: String?
    public let title: String?
    public let scope: String?
    public let status: AgentSessionStatus
    public let activeTurnId: String?
    public let variables: [String: JSONValue]?
    public let lastErrorCode: String?
    public let lastErrorMessage: String?
    public let createdAt: String?
    public let modifiedAt: String?
    public let deletingAt: String?
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let agentKey = row["agentKey"]?.stringValue,
              let status = AgentSessionStatus(json: row["status"])
        else { return nil }
        self.id = id
        self.agentKey = agentKey
        self.configId = row["configId"]?.stringValue
        self.title = row["title"]?.stringValue
        self.scope = row["scope"]?.stringValue
        self.status = status
        self.activeTurnId = row["activeTurnId"]?.stringValue
        self.variables = AgentSessionJSON.object(row["variables"], emptyOnWrongType: true)
        self.lastErrorCode = row["lastErrorCode"]?.stringValue
        self.lastErrorMessage = row["lastErrorMessage"]?.stringValue
        self.createdAt = row["createdAt"]?.stringValue
        self.modifiedAt = row["modifiedAt"]?.stringValue
        self.deletingAt = row["deletingAt"]?.stringValue
        self.row = row
    }
}

/// A `Member` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionMemberRecord: Sendable, Equatable {
    public let id: String
    public let role: AgentSessionRole
    public let addedAt: String
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let role = AgentSessionRole(memberRole: row["role"]),
              let addedAt = row["addedAt"]?.stringValue
        else { return nil }
        self.id = id
        self.role = role
        self.addedAt = addedAt
        self.row = row
    }
}

/// A `Turn` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionTurnRecord: Sendable, Equatable {
    public let id: String
    public let seq: Double
    public let status: AgentSessionTurnStatus
    public let initiatorUserId: String?
    public let configId: String?
    public let startedAt: String?
    public let endedAt: String?
    public let errorCode: String?
    public let errorMessage: String?
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let totalTokens: Double?
    public let reasoningTokens: Double?
    public let cachedInputTokens: Double?
    public let cost: Double?
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let status = AgentSessionTurnStatus(json: row["status"])
        else { return nil }
        self.id = id
        self.seq = seq
        self.status = status
        self.initiatorUserId = row["initiatorUserId"]?.stringValue
        self.configId = row["configId"]?.stringValue
        self.startedAt = row["startedAt"]?.stringValue
        self.endedAt = row["endedAt"]?.stringValue
        self.errorCode = row["errorCode"]?.stringValue
        self.errorMessage = row["errorMessage"]?.stringValue
        self.inputTokens = AgentSessionJSON.number(row["inputTokens"])
        self.outputTokens = AgentSessionJSON.number(row["outputTokens"])
        self.totalTokens = AgentSessionJSON.number(row["totalTokens"])
        self.reasoningTokens = AgentSessionJSON.number(row["reasoningTokens"])
        self.cachedInputTokens = AgentSessionJSON.number(row["cachedInputTokens"])
        self.cost = AgentSessionJSON.number(row["cost"])
        self.row = row
    }
}

/// A `Message` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionMessageRecord: Sendable, Equatable {
    public let id: String
    public let seq: Double
    public let authorKind: AgentSessionAuthorKind
    public let authorUserId: String?
    public let clientMessageId: String?
    public let turnId: String?
    public let queueSeq: Double?
    public let createdAt: String
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let authorKind = AgentSessionAuthorKind(json: row["authorKind"]),
              let createdAt = row["createdAt"]?.stringValue
        else { return nil }
        self.id = id
        self.seq = seq
        self.authorKind = authorKind
        self.authorUserId = row["authorUserId"]?.stringValue
        self.clientMessageId = row["clientMessageId"]?.stringValue
        self.turnId = row["turnId"]?.stringValue
        self.queueSeq = AgentSessionJSON.number(row["queueSeq"])
        self.createdAt = createdAt
        self.row = row
    }
}

/// A `Part` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionPartRecord: Sendable, Equatable {
    public let id: String
    public let messageId: String
    public let seq: Double
    public let createdAt: String?
    public let modifiedAt: String?
    public let kind: AgentSessionPartKind
    /// The columns of its `kind`; `.unknown(kind:)` for one this client does not know.
    public let content: AgentSessionPartContent
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let messageId = row["messageId"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let kindRaw = row["kind"]?.stringValue
        else { return nil }
        self.id = id
        self.messageId = messageId
        self.seq = seq
        self.createdAt = row["createdAt"]?.stringValue
        self.modifiedAt = row["modifiedAt"]?.stringValue
        self.kind = AgentSessionPartKind(rawValue: kindRaw)
        switch kindRaw {
        case "text": self.content = .text(AgentSessionTextPart(row: row))
        case "reasoning": self.content = .reasoning(AgentSessionTextPart(row: row))
        case "file": self.content = .file(AgentSessionFilePart(row: row))
        case "event": self.content = .event(AgentSessionEventPart(row: row))
        default: self.content = .unknown(kind: kindRaw)
        }
        self.row = row
    }
}

/// A `Part`'s columns by its `kind`.
public enum AgentSessionPartContent: Sendable, Equatable {
    case text(AgentSessionTextPart)
    case reasoning(AgentSessionTextPart)
    case file(AgentSessionFilePart)
    case event(AgentSessionEventPart)
    /// A `kind` this client does not know: every column is on the record's `row`.
    case unknown(kind: String)
}

/// The columns of a `Part` of kind `text` or `reasoning`.
public struct AgentSessionTextPart: Sendable, Equatable {
    public let text: String?
    public let textState: AgentSessionTextState?
    public let providerMetadata: [String: JSONValue]?

    init(row: [String: JSONValue]) {
        self.text = row["text"]?.stringValue
        self.textState = AgentSessionTextState(json: row["textState"])
        self.providerMetadata = AgentSessionJSON.object(row["providerMetadata"], emptyOnWrongType: false)
    }
}

/// The columns of a `Part` of kind `file`.
public struct AgentSessionFilePart: Sendable, Equatable {
    public let mediaType: String?
    public let filename: String?
    public let blobId: String?
    public let sizeBytes: Double?

    init(row: [String: JSONValue]) {
        self.mediaType = row["mediaType"]?.stringValue
        self.filename = row["filename"]?.stringValue
        self.blobId = row["blobId"]?.stringValue
        self.sizeBytes = AgentSessionJSON.number(row["sizeBytes"])
    }
}

/// The columns of a `Part` of kind `event`.
public struct AgentSessionEventPart: Sendable, Equatable {
    public let eventKind: String?
    public let eventId: String?
    public let refersTo: String?
    public let data: JSONValue?

    init(row: [String: JSONValue]) {
        self.eventKind = row["eventKind"]?.stringValue
        self.eventId = row["eventId"]?.stringValue
        self.refersTo = row["refersTo"]?.stringValue
        self.data = AgentSessionJSON.parse(row["data"])
    }
}

/// A `ToolCall` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionToolCallRecord: Sendable, Equatable {
    public let id: String
    public let messageId: String
    public let seq: Double
    public let turnId: String
    public let callNumber: Double?
    public let toolName: String
    public let state: AgentSessionToolCallState
    public let input: JSONValue?
    public let output: JSONValue?
    public let outputBlobId: String?
    public let errorText: String?
    public let errorCode: String?
    public let statusText: String?
    public let approvalApproved: Bool?
    public let approvalReason: String?
    public let approvalUserId: String?
    public let approvalRespondedAt: String?
    public let resolvedByUserId: String?
    public let artifact: JSONValue?
    public let artifactBlobId: String?
    public let providerMetadata: [String: JSONValue]?
    public let createdAt: String?
    public let modifiedAt: String?
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let messageId = row["messageId"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let turnId = row["turnId"]?.stringValue,
              let toolName = row["toolName"]?.stringValue,
              let state = AgentSessionToolCallState(json: row["state"])
        else { return nil }
        self.id = id
        self.messageId = messageId
        self.seq = seq
        self.turnId = turnId
        self.callNumber = AgentSessionJSON.number(row["callNumber"])
        self.toolName = toolName
        self.state = state
        self.input = AgentSessionJSON.parse(row["input"])
        self.output = AgentSessionJSON.parse(row["output"])
        self.outputBlobId = row["outputBlobId"]?.stringValue
        self.errorText = row["errorText"]?.stringValue
        self.errorCode = row["errorCode"]?.stringValue
        self.statusText = row["statusText"]?.stringValue
        self.approvalApproved = row["approvalApproved"]?.rowBoolValue
        self.approvalReason = row["approvalReason"]?.stringValue
        self.approvalUserId = row["approvalUserId"]?.stringValue
        self.approvalRespondedAt = row["approvalRespondedAt"]?.stringValue
        self.resolvedByUserId = row["resolvedByUserId"]?.stringValue
        self.artifact = AgentSessionJSON.parse(row["artifact"])
        self.artifactBlobId = row["artifactBlobId"]?.stringValue
        self.providerMetadata = AgentSessionJSON.object(row["providerMetadata"], emptyOnWrongType: false)
        self.createdAt = row["createdAt"]?.stringValue
        self.modifiedAt = row["modifiedAt"]?.stringValue
        self.row = row
    }
}

/// A `Step` row of a session's db3: its columns, enums open and JSON
/// columns decoded. An optional column that is absent or does not read is
/// `nil`; `JSONValue.null` is a value. `row` is the row as read.
public struct AgentSessionStepRecord: Sendable, Equatable {
    public let id: String
    public let turnId: String
    public let seq: Double
    public let kind: AgentSessionStepKind
    public let status: AgentSessionStepStatus
    public let startedAt: String
    public let endedAt: String?
    public let durationMs: Double?
    public let provider: String?
    public let model: String?
    public let configId: String?
    public let callId: String?
    public let toolName: String?
    public let functionName: String?
    public let functionVersion: String?
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let totalTokens: Double?
    public let reasoningTokens: Double?
    public let cachedInputTokens: Double?
    public let cost: Double?
    public let historyMessageIds: Set<String>
    public let historyMode: String?
    public let historySelection: JSONValue?
    public let providerDurationMs: Double?
    public let errorCode: String?
    public let errorMessage: String?
    public let resolvedByUserId: String?
    public let row: [String: JSONValue]

    /// Decode a row. `nil` when a required column is missing or does not read;
    /// an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let turnId = row["turnId"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let kind = AgentSessionStepKind(json: row["kind"]),
              let status = AgentSessionStepStatus(json: row["status"]),
              let startedAt = row["startedAt"]?.stringValue
        else { return nil }
        self.id = id
        self.turnId = turnId
        self.seq = seq
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.endedAt = row["endedAt"]?.stringValue
        self.durationMs = AgentSessionJSON.number(row["durationMs"])
        self.provider = row["provider"]?.stringValue
        self.model = row["model"]?.stringValue
        self.configId = row["configId"]?.stringValue
        self.callId = row["callId"]?.stringValue
        self.toolName = row["toolName"]?.stringValue
        self.functionName = row["functionName"]?.stringValue
        self.functionVersion = row["functionVersion"]?.stringValue
        self.inputTokens = AgentSessionJSON.number(row["inputTokens"])
        self.outputTokens = AgentSessionJSON.number(row["outputTokens"])
        self.totalTokens = AgentSessionJSON.number(row["totalTokens"])
        self.reasoningTokens = AgentSessionJSON.number(row["reasoningTokens"])
        self.cachedInputTokens = AgentSessionJSON.number(row["cachedInputTokens"])
        self.cost = AgentSessionJSON.number(row["cost"])
        self.historyMessageIds = AgentSessionJSON.stringset(row["historyMessageIds"])
        self.historyMode = row["historyMode"]?.stringValue
        self.historySelection = AgentSessionJSON.parse(row["historySelection"])
        self.providerDurationMs = AgentSessionJSON.number(row["providerDurationMs"])
        self.errorCode = row["errorCode"]?.stringValue
        self.errorMessage = row["errorMessage"]?.stringValue
        self.resolvedByUserId = row["resolvedByUserId"]?.stringValue
        self.row = row
    }
}
