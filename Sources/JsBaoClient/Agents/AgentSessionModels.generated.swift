// GENERATED FILE — do not edit by hand.
// Rendered from src/agents/session-document-schema.ts by
// scripts/gen-agent-session-models.ts: run `pnpm gen:agent-session-models`
// after changing the schema (`pnpm check:agent-session-models` verifies).

import Foundation

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitiveSessionStatus: Sendable, Equatable, Hashable {
    case idle
    case thinking
    case runningTool
    case awaitingAnswer
    case failed
    case expired
    case cancelled
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitiveSessionStatus] = [.idle, .thinking, .runningTool, .awaitingAnswer, .failed, .expired, .cancelled]

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

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitivePartKind: Sendable, Equatable, Hashable {
    case text
    case reasoning
    case toolCall
    case file
    case event
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitivePartKind] = [.text, .reasoning, .toolCall, .file, .event]

    public init(rawValue: String) {
        switch rawValue {
        case "text": self = .text
        case "reasoning": self = .reasoning
        case "tool_call": self = .toolCall
        case "file": self = .file
        case "event": self = .event
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .text: return "text"
        case .reasoning: return "reasoning"
        case .toolCall: return "tool_call"
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

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitiveTextState: Sendable, Equatable, Hashable {
    case streaming
    case done
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitiveTextState] = [.streaming, .done]

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

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitiveToolCallState: Sendable, Equatable, Hashable {
    case inputStreaming
    case inputAvailable
    case approvalRequested
    case approvalResponded
    case outputAvailable
    case outputError
    case outputDenied
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitiveToolCallState] = [.inputStreaming, .inputAvailable, .approvalRequested, .approvalResponded, .outputAvailable, .outputError, .outputDenied]

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

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitiveAuthorKind: Sendable, Equatable, Hashable {
    case user
    case agent
    case app
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitiveAuthorKind] = [.user, .agent, .app]

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

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitiveStepKind: Sendable, Equatable, Hashable {
    case modelCall
    case toolCall
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitiveStepKind] = [.modelCall, .toolCall]

    public init(rawValue: String) {
        switch rawValue {
        case "model_call": self = .modelCall
        case "tool_call": self = .toolCall
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .modelCall: return "model_call"
        case .toolCall: return "tool_call"
        case let .unknown(raw): return raw
        }
    }

    init?(json: JSONValue?) {
        guard let raw = json?.stringValue else { return nil }
        self.init(rawValue: raw)
    }
}

/// Open: a value this client does not know reads as `.unknown(raw)`, so a
/// newer server never breaks decoding. `rawValue` round-trips either way.
public enum PrimitiveStepStatus: Sendable, Equatable, Hashable {
    case running
    case completed
    case failed
    case unknown(String)

    /// The values this client knows, in the schema's order.
    public static let known: [PrimitiveStepStatus] = [.running, .completed, .failed]

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

/// A `PrimitiveSession` row of a session's conversation document (#3802).
///
/// Properties are the row's columns: scalars as stored, stringsets as sets
/// of ids, enums open, and JSON columns decoded. An optional column that is
/// absent or does not read is `nil`; `JSONValue.null` is a value.
public struct PrimitiveSession: PrimitiveModel, PrimitiveRowDecodable, Equatable, Sendable {
    public static let modelName = "PrimitiveSession"
    public static let primitiveSchema = PrimitiveSchema(
        name: "PrimitiveSession",
        fields: [
            "id": FieldDescriptor(type: .id, autoAssign: true),
            "schemaVersion": FieldDescriptor(type: .number, required: true),
            "agentKey": FieldDescriptor(type: .string, required: true),
            "configId": FieldDescriptor(type: .string),
            "status": FieldDescriptor(type: .string, required: true),
            "activeTurnId": FieldDescriptor(type: .string),
            "activeTurnInitiatorUserId": FieldDescriptor(type: .string),
            "activeTurnStartedAt": FieldDescriptor(type: .date),
            "activeTurnMessageIds": FieldDescriptor(type: .stringset),
            "queue": FieldDescriptor(type: .string),
            "title": FieldDescriptor(type: .string),
            "scope": FieldDescriptor(type: .string),
            "variables": FieldDescriptor(type: .string),
            "viewerUserIds": FieldDescriptor(type: .stringset),
            "participantUserIds": FieldDescriptor(type: .stringset),
            "ownerUserId": FieldDescriptor(type: .string),
            "lastErrorCode": FieldDescriptor(type: .string),
            "lastErrorMessage": FieldDescriptor(type: .string),
            "createdAt": FieldDescriptor(type: .date, required: true),
            "modifiedAt": FieldDescriptor(type: .date),
        ]
    )

    public let id: String
    public var schemaVersion: Double
    public var agentKey: String
    public var configId: String?
    public var status: PrimitiveSessionStatus
    public var activeTurnId: String?
    public var activeTurnInitiatorUserId: String?
    public var activeTurnStartedAt: String?
    public var activeTurnMessageIds: Set<String>?
    public var queue: [PrimitiveQueueEntry]?
    public var title: String?
    public var scope: String?
    public var variables: [String: JSONValue]?
    public var viewerUserIds: Set<String>?
    public var participantUserIds: Set<String>?
    public var ownerUserId: String?
    public var lastErrorCode: String?
    public var lastErrorMessage: String?
    public var createdAt: String
    public var modifiedAt: String?

    /// Decode a row. `nil` when a required scalar column is missing or does
    /// not read; an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let schemaVersion = AgentSessionJSON.number(row["schemaVersion"]),
              let agentKey = row["agentKey"]?.stringValue,
              let status = PrimitiveSessionStatus(json: row["status"]),
              let createdAt = row["createdAt"]?.stringValue
        else { return nil }
        self.id = id
        self.schemaVersion = schemaVersion
        self.agentKey = agentKey
        self.configId = row["configId"]?.stringValue
        self.status = status
        self.activeTurnId = row["activeTurnId"]?.stringValue
        self.activeTurnInitiatorUserId = row["activeTurnInitiatorUserId"]?.stringValue
        self.activeTurnStartedAt = row["activeTurnStartedAt"]?.stringValue
        self.activeTurnMessageIds = AgentSessionJSON.members(row["activeTurnMessageIds"])
        self.queue = AgentSessionJSON.queue(row["queue"], emptyOnWrongType: true)
        self.title = row["title"]?.stringValue
        self.scope = row["scope"]?.stringValue
        self.variables = AgentSessionJSON.object(row["variables"], emptyOnWrongType: true)
        self.viewerUserIds = AgentSessionJSON.members(row["viewerUserIds"])
        self.participantUserIds = AgentSessionJSON.members(row["participantUserIds"])
        self.ownerUserId = row["ownerUserId"]?.stringValue
        self.lastErrorCode = row["lastErrorCode"]?.stringValue
        self.lastErrorMessage = row["lastErrorMessage"]?.stringValue
        self.createdAt = createdAt
        self.modifiedAt = row["modifiedAt"]?.stringValue
    }

    public init?(record: PrimitiveRecord) {
        self.init(row: AgentSessionJSON.row(from: record))
    }

    /// The columns to store, JSON columns as canonical text. Omits `id`.
    public func primitiveValues() -> [String: PrimitiveValue] {
        var values: [String: PrimitiveValue] = [:]
        values["schemaVersion"] = .number(schemaVersion)
        values["agentKey"] = .string(agentKey)
        if let configId { values["configId"] = .string(configId) }
        values["status"] = .string(status.rawValue)
        if let activeTurnId { values["activeTurnId"] = .string(activeTurnId) }
        if let activeTurnInitiatorUserId { values["activeTurnInitiatorUserId"] = .string(activeTurnInitiatorUserId) }
        if let activeTurnStartedAt { values["activeTurnStartedAt"] = .date(activeTurnStartedAt) }
        if let activeTurnMessageIds { values["activeTurnMessageIds"] = .stringset(activeTurnMessageIds) }
        if let queue { values["queue"] = .string(AgentSessionJSON.text(.array(queue.map(\.jsonValue)))) }
        if let title { values["title"] = .string(title) }
        if let scope { values["scope"] = .string(scope) }
        if let variables { values["variables"] = .string(AgentSessionJSON.text(.object(variables))) }
        if let viewerUserIds { values["viewerUserIds"] = .stringset(viewerUserIds) }
        if let participantUserIds { values["participantUserIds"] = .stringset(participantUserIds) }
        if let ownerUserId { values["ownerUserId"] = .string(ownerUserId) }
        if let lastErrorCode { values["lastErrorCode"] = .string(lastErrorCode) }
        if let lastErrorMessage { values["lastErrorMessage"] = .string(lastErrorMessage) }
        values["createdAt"] = .date(createdAt)
        if let modifiedAt { values["modifiedAt"] = .date(modifiedAt) }
        return values
    }
}

/// Reads of `PrimitiveSession` across every open document, through the configured
/// default `JsBaoClient`. Rows that fail to decode are reported through
/// `PrimitiveRowDecoder.onDecodeFailure`, never dropped silently.
public extension PrimitiveSession {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> [PrimitiveSession] {
        let rows = try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeAll(rows, as: PrimitiveSession.self)
    }

    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PagedQueryResult<PrimitiveSession> {
        let page = try JsBaoClient.requireDefault()
            .codegen.queryPaged(primitiveSchema, filter: filter, options: options)
        return PagedQueryResult(
            data: PrimitiveRowDecoder.decodeAll(page.data, as: PrimitiveSession.self),
            nextCursor: page.nextCursor,
            prevCursor: page.prevCursor,
            hasMore: page.hasMore
        )
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PrimitiveSession? {
        let row = try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeOne(row, as: PrimitiveSession.self)
    }

    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    /// Throws `PrimitiveDecodeError` when a stored row no longer decodes.
    static func findAll() throws -> [PrimitiveSession] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: nil, options: nil)
            .map { row in
                guard let decoded = PrimitiveSession(row: row) else {
                    throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
                }
                return decoded
            }
    }

    /// `nil` only when no open document has `id`; throws when the row does not decode.
    static func find(_ id: String) throws -> PrimitiveSession? {
        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {
            return nil
        }
        guard let decoded = PrimitiveSession(row: row) else {
            throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
        }
        return decoded
    }

    @discardableResult
    static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        JsBaoClient.requireDefault().codegen.subscribe(primitiveSchema, callback)
    }
}

/// A `PrimitiveMessage` row of a session's conversation document (#3802).
///
/// Properties are the row's columns: scalars as stored, stringsets as sets
/// of ids, enums open, and JSON columns decoded. An optional column that is
/// absent or does not read is `nil`; `JSONValue.null` is a value.
public struct PrimitiveMessage: PrimitiveModel, PrimitiveRowDecodable, Equatable, Sendable {
    public static let modelName = "PrimitiveMessage"
    public static let primitiveSchema = PrimitiveSchema(
        name: "PrimitiveMessage",
        fields: [
            "id": FieldDescriptor(type: .id, autoAssign: true),
            "seq": FieldDescriptor(type: .number, indexed: true, required: true),
            "turnId": FieldDescriptor(type: .string, indexed: true),
            "authorKind": FieldDescriptor(type: .string, required: true),
            "authorUserId": FieldDescriptor(type: .string),
            "clientMessageId": FieldDescriptor(type: .string),
            "createdAt": FieldDescriptor(type: .date, required: true),
        ]
    )

    public let id: String
    public var seq: Double
    public var turnId: String?
    public var authorKind: PrimitiveAuthorKind
    public var authorUserId: String?
    public var clientMessageId: String?
    public var createdAt: String

    /// Decode a row. `nil` when a required scalar column is missing or does
    /// not read; an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let authorKind = PrimitiveAuthorKind(json: row["authorKind"]),
              let createdAt = row["createdAt"]?.stringValue
        else { return nil }
        self.id = id
        self.seq = seq
        self.turnId = row["turnId"]?.stringValue
        self.authorKind = authorKind
        self.authorUserId = row["authorUserId"]?.stringValue
        self.clientMessageId = row["clientMessageId"]?.stringValue
        self.createdAt = createdAt
    }

    public init?(record: PrimitiveRecord) {
        self.init(row: AgentSessionJSON.row(from: record))
    }

    /// The columns to store, JSON columns as canonical text. Omits `id`.
    public func primitiveValues() -> [String: PrimitiveValue] {
        var values: [String: PrimitiveValue] = [:]
        values["seq"] = .number(seq)
        if let turnId { values["turnId"] = .string(turnId) }
        values["authorKind"] = .string(authorKind.rawValue)
        if let authorUserId { values["authorUserId"] = .string(authorUserId) }
        if let clientMessageId { values["clientMessageId"] = .string(clientMessageId) }
        values["createdAt"] = .date(createdAt)
        return values
    }
}

/// Reads of `PrimitiveMessage` across every open document, through the configured
/// default `JsBaoClient`. Rows that fail to decode are reported through
/// `PrimitiveRowDecoder.onDecodeFailure`, never dropped silently.
public extension PrimitiveMessage {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> [PrimitiveMessage] {
        let rows = try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeAll(rows, as: PrimitiveMessage.self)
    }

    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PagedQueryResult<PrimitiveMessage> {
        let page = try JsBaoClient.requireDefault()
            .codegen.queryPaged(primitiveSchema, filter: filter, options: options)
        return PagedQueryResult(
            data: PrimitiveRowDecoder.decodeAll(page.data, as: PrimitiveMessage.self),
            nextCursor: page.nextCursor,
            prevCursor: page.prevCursor,
            hasMore: page.hasMore
        )
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PrimitiveMessage? {
        let row = try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeOne(row, as: PrimitiveMessage.self)
    }

    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    /// Throws `PrimitiveDecodeError` when a stored row no longer decodes.
    static func findAll() throws -> [PrimitiveMessage] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: nil, options: nil)
            .map { row in
                guard let decoded = PrimitiveMessage(row: row) else {
                    throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
                }
                return decoded
            }
    }

    /// `nil` only when no open document has `id`; throws when the row does not decode.
    static func find(_ id: String) throws -> PrimitiveMessage? {
        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {
            return nil
        }
        guard let decoded = PrimitiveMessage(row: row) else {
            throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
        }
        return decoded
    }

    @discardableResult
    static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        JsBaoClient.requireDefault().codegen.subscribe(primitiveSchema, callback)
    }
}

/// A `PrimitivePart` row of a session's conversation document (#3802).
///
/// Properties are the row's columns: scalars as stored, stringsets as sets
/// of ids, enums open, and JSON columns decoded. An optional column that is
/// absent or does not read is `nil`; `JSONValue.null` is a value.
public struct PrimitivePart: PrimitiveModel, PrimitiveRowDecodable, Equatable, Sendable {
    public static let modelName = "PrimitivePart"
    public static let primitiveSchema = PrimitiveSchema(
        name: "PrimitivePart",
        fields: [
            "id": FieldDescriptor(type: .id, autoAssign: true),
            "messageId": FieldDescriptor(type: .string, indexed: true, required: true),
            "seq": FieldDescriptor(type: .number, indexed: true, required: true),
            "kind": FieldDescriptor(type: .string, required: true),
            "state": FieldDescriptor(type: .string),
            "text": FieldDescriptor(type: .string),
            "toolCallId": FieldDescriptor(type: .string, indexed: true),
            "toolName": FieldDescriptor(type: .string),
            "input": FieldDescriptor(type: .string),
            "output": FieldDescriptor(type: .string),
            "errorText": FieldDescriptor(type: .string),
            "errorCode": FieldDescriptor(type: .string),
            "statusText": FieldDescriptor(type: .string),
            "approvalApproved": FieldDescriptor(type: .boolean),
            "approvalReason": FieldDescriptor(type: .string),
            "approvalUserId": FieldDescriptor(type: .string),
            "approvalRespondedAt": FieldDescriptor(type: .date),
            "resolvedByUserId": FieldDescriptor(type: .string),
            "artifact": FieldDescriptor(type: .string),
            "artifactBlobId": FieldDescriptor(type: .string),
            "providerMetadata": FieldDescriptor(type: .string),
            "mediaType": FieldDescriptor(type: .string),
            "filename": FieldDescriptor(type: .string),
            "blobId": FieldDescriptor(type: .string),
            "sizeBytes": FieldDescriptor(type: .number),
            "eventKind": FieldDescriptor(type: .string),
            "eventId": FieldDescriptor(type: .string),
            "refersTo": FieldDescriptor(type: .string),
            "data": FieldDescriptor(type: .string),
            "createdAt": FieldDescriptor(type: .date, required: true),
            "modifiedAt": FieldDescriptor(type: .date),
        ]
    )

    public let id: String
    public var messageId: String
    public var seq: Double
    public var kind: PrimitivePartKind
    public var state: String?
    public var text: String?
    public var toolCallId: String?
    public var toolName: String?
    public var input: JSONValue?
    public var output: JSONValue?
    public var errorText: String?
    public var errorCode: String?
    public var statusText: String?
    public var approvalApproved: Bool?
    public var approvalReason: String?
    public var approvalUserId: String?
    public var approvalRespondedAt: String?
    public var resolvedByUserId: String?
    public var artifact: JSONValue?
    public var artifactBlobId: String?
    public var providerMetadata: [String: JSONValue]?
    public var mediaType: String?
    public var filename: String?
    public var blobId: String?
    public var sizeBytes: Double?
    public var eventKind: String?
    public var eventId: String?
    public var refersTo: String?
    public var data: JSONValue?
    public var createdAt: String
    public var modifiedAt: String?

    /// Decode a row. `nil` when a required scalar column is missing or does
    /// not read; an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let messageId = row["messageId"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let kind = PrimitivePartKind(json: row["kind"]),
              let createdAt = row["createdAt"]?.stringValue
        else { return nil }
        self.id = id
        self.messageId = messageId
        self.seq = seq
        self.kind = kind
        self.state = row["state"]?.stringValue
        self.text = row["text"]?.stringValue
        self.toolCallId = row["toolCallId"]?.stringValue
        self.toolName = row["toolName"]?.stringValue
        self.input = AgentSessionJSON.parse(row["input"])
        self.output = AgentSessionJSON.parse(row["output"])
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
        self.mediaType = row["mediaType"]?.stringValue
        self.filename = row["filename"]?.stringValue
        self.blobId = row["blobId"]?.stringValue
        self.sizeBytes = AgentSessionJSON.number(row["sizeBytes"])
        self.eventKind = row["eventKind"]?.stringValue
        self.eventId = row["eventId"]?.stringValue
        self.refersTo = row["refersTo"]?.stringValue
        self.data = AgentSessionJSON.parse(row["data"])
        self.createdAt = createdAt
        self.modifiedAt = row["modifiedAt"]?.stringValue
    }

    public init?(record: PrimitiveRecord) {
        self.init(row: AgentSessionJSON.row(from: record))
    }

    /// The columns to store, JSON columns as canonical text. Omits `id`.
    public func primitiveValues() -> [String: PrimitiveValue] {
        var values: [String: PrimitiveValue] = [:]
        values["messageId"] = .string(messageId)
        values["seq"] = .number(seq)
        values["kind"] = .string(kind.rawValue)
        if let state { values["state"] = .string(state) }
        if let text { values["text"] = .string(text) }
        if let toolCallId { values["toolCallId"] = .string(toolCallId) }
        if let toolName { values["toolName"] = .string(toolName) }
        if let input { values["input"] = .string(AgentSessionJSON.text(input)) }
        if let output { values["output"] = .string(AgentSessionJSON.text(output)) }
        if let errorText { values["errorText"] = .string(errorText) }
        if let errorCode { values["errorCode"] = .string(errorCode) }
        if let statusText { values["statusText"] = .string(statusText) }
        if let approvalApproved { values["approvalApproved"] = .boolean(approvalApproved) }
        if let approvalReason { values["approvalReason"] = .string(approvalReason) }
        if let approvalUserId { values["approvalUserId"] = .string(approvalUserId) }
        if let approvalRespondedAt { values["approvalRespondedAt"] = .date(approvalRespondedAt) }
        if let resolvedByUserId { values["resolvedByUserId"] = .string(resolvedByUserId) }
        if let artifact { values["artifact"] = .string(AgentSessionJSON.text(artifact)) }
        if let artifactBlobId { values["artifactBlobId"] = .string(artifactBlobId) }
        if let providerMetadata { values["providerMetadata"] = .string(AgentSessionJSON.text(.object(providerMetadata))) }
        if let mediaType { values["mediaType"] = .string(mediaType) }
        if let filename { values["filename"] = .string(filename) }
        if let blobId { values["blobId"] = .string(blobId) }
        if let sizeBytes { values["sizeBytes"] = .number(sizeBytes) }
        if let eventKind { values["eventKind"] = .string(eventKind) }
        if let eventId { values["eventId"] = .string(eventId) }
        if let refersTo { values["refersTo"] = .string(refersTo) }
        if let data { values["data"] = .string(AgentSessionJSON.text(data)) }
        values["createdAt"] = .date(createdAt)
        if let modifiedAt { values["modifiedAt"] = .date(modifiedAt) }
        return values
    }

    /// The part by kind, with each kind's columns typed; `.unknown(kind:)` for
    /// a kind this client does not know (every column stays readable here).
    public var content: PrimitivePartContent {
        switch kind {
        case .text:
            return .text(PrimitiveTextPartContent(
                state: state.map(PrimitiveTextState.init(rawValue:)),
                text: text,
                providerMetadata: providerMetadata
            ))
        case .reasoning:
            return .reasoning(PrimitiveTextPartContent(
                state: state.map(PrimitiveTextState.init(rawValue:)),
                text: text,
                providerMetadata: providerMetadata
            ))
        case .toolCall:
            return .toolCall(PrimitiveToolCallPartContent(
                state: state.map(PrimitiveToolCallState.init(rawValue:)),
                toolCallId: toolCallId,
                toolName: toolName,
                input: input,
                output: output,
                errorText: errorText,
                errorCode: errorCode,
                statusText: statusText,
                approvalApproved: approvalApproved,
                approvalReason: approvalReason,
                approvalUserId: approvalUserId,
                approvalRespondedAt: approvalRespondedAt,
                resolvedByUserId: resolvedByUserId,
                artifact: artifact,
                artifactBlobId: artifactBlobId,
                providerMetadata: providerMetadata
            ))
        case .file:
            return .file(PrimitiveFilePartContent(
                mediaType: mediaType,
                filename: filename,
                blobId: blobId,
                sizeBytes: sizeBytes
            ))
        case .event:
            return .event(PrimitiveEventPartContent(
                eventKind: eventKind,
                eventId: eventId,
                refersTo: refersTo,
                data: data
            ))
        case let .unknown(raw):
            return .unknown(kind: raw)
        }
    }
}

/// Reads of `PrimitivePart` across every open document, through the configured
/// default `JsBaoClient`. Rows that fail to decode are reported through
/// `PrimitiveRowDecoder.onDecodeFailure`, never dropped silently.
public extension PrimitivePart {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> [PrimitivePart] {
        let rows = try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeAll(rows, as: PrimitivePart.self)
    }

    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PagedQueryResult<PrimitivePart> {
        let page = try JsBaoClient.requireDefault()
            .codegen.queryPaged(primitiveSchema, filter: filter, options: options)
        return PagedQueryResult(
            data: PrimitiveRowDecoder.decodeAll(page.data, as: PrimitivePart.self),
            nextCursor: page.nextCursor,
            prevCursor: page.prevCursor,
            hasMore: page.hasMore
        )
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PrimitivePart? {
        let row = try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeOne(row, as: PrimitivePart.self)
    }

    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    /// Throws `PrimitiveDecodeError` when a stored row no longer decodes.
    static func findAll() throws -> [PrimitivePart] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: nil, options: nil)
            .map { row in
                guard let decoded = PrimitivePart(row: row) else {
                    throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
                }
                return decoded
            }
    }

    /// `nil` only when no open document has `id`; throws when the row does not decode.
    static func find(_ id: String) throws -> PrimitivePart? {
        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {
            return nil
        }
        guard let decoded = PrimitivePart(row: row) else {
            throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
        }
        return decoded
    }

    @discardableResult
    static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        JsBaoClient.requireDefault().codegen.subscribe(primitiveSchema, callback)
    }
}

/// A `PrimitiveStep` row of a session's conversation document (#3802).
///
/// Properties are the row's columns: scalars as stored, stringsets as sets
/// of ids, enums open, and JSON columns decoded. An optional column that is
/// absent or does not read is `nil`; `JSONValue.null` is a value.
public struct PrimitiveStep: PrimitiveModel, PrimitiveRowDecodable, Equatable, Sendable {
    public static let modelName = "PrimitiveStep"
    public static let primitiveSchema = PrimitiveSchema(
        name: "PrimitiveStep",
        fields: [
            "id": FieldDescriptor(type: .id, autoAssign: true),
            "turnId": FieldDescriptor(type: .string, indexed: true, required: true),
            "seq": FieldDescriptor(type: .number, required: true),
            "kind": FieldDescriptor(type: .string, required: true),
            "status": FieldDescriptor(type: .string, required: true),
            "startedAt": FieldDescriptor(type: .date, required: true),
            "endedAt": FieldDescriptor(type: .date),
            "durationMs": FieldDescriptor(type: .number),
            "provider": FieldDescriptor(type: .string),
            "model": FieldDescriptor(type: .string),
            "configId": FieldDescriptor(type: .string),
            "callId": FieldDescriptor(type: .string),
            "toolName": FieldDescriptor(type: .string),
            "functionName": FieldDescriptor(type: .string),
            "functionVersion": FieldDescriptor(type: .string),
            "inputTokens": FieldDescriptor(type: .number),
            "outputTokens": FieldDescriptor(type: .number),
            "totalTokens": FieldDescriptor(type: .number),
            "reasoningTokens": FieldDescriptor(type: .number),
            "cachedInputTokens": FieldDescriptor(type: .number),
            "cost": FieldDescriptor(type: .number),
            "historyMessageIds": FieldDescriptor(type: .stringset),
            "errorCode": FieldDescriptor(type: .string),
            "errorMessage": FieldDescriptor(type: .string),
        ]
    )

    public let id: String
    public var turnId: String
    public var seq: Double
    public var kind: PrimitiveStepKind
    public var status: PrimitiveStepStatus
    public var startedAt: String
    public var endedAt: String?
    public var durationMs: Double?
    public var provider: String?
    public var model: String?
    public var configId: String?
    public var callId: String?
    public var toolName: String?
    public var functionName: String?
    public var functionVersion: String?
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var totalTokens: Double?
    public var reasoningTokens: Double?
    public var cachedInputTokens: Double?
    public var cost: Double?
    public var historyMessageIds: Set<String>?
    public var errorCode: String?
    public var errorMessage: String?

    /// Decode a row. `nil` when a required scalar column is missing or does
    /// not read; an optional column, JSON and stringsets included, never fails a row.
    public init?(row: [String: JSONValue]) {
        guard let id = row["id"]?.stringValue,
              let turnId = row["turnId"]?.stringValue,
              let seq = AgentSessionJSON.number(row["seq"]),
              let kind = PrimitiveStepKind(json: row["kind"]),
              let status = PrimitiveStepStatus(json: row["status"]),
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
        self.historyMessageIds = AgentSessionJSON.members(row["historyMessageIds"])
        self.errorCode = row["errorCode"]?.stringValue
        self.errorMessage = row["errorMessage"]?.stringValue
    }

    public init?(record: PrimitiveRecord) {
        self.init(row: AgentSessionJSON.row(from: record))
    }

    /// The columns to store, JSON columns as canonical text. Omits `id`.
    public func primitiveValues() -> [String: PrimitiveValue] {
        var values: [String: PrimitiveValue] = [:]
        values["turnId"] = .string(turnId)
        values["seq"] = .number(seq)
        values["kind"] = .string(kind.rawValue)
        values["status"] = .string(status.rawValue)
        values["startedAt"] = .date(startedAt)
        if let endedAt { values["endedAt"] = .date(endedAt) }
        if let durationMs { values["durationMs"] = .number(durationMs) }
        if let provider { values["provider"] = .string(provider) }
        if let model { values["model"] = .string(model) }
        if let configId { values["configId"] = .string(configId) }
        if let callId { values["callId"] = .string(callId) }
        if let toolName { values["toolName"] = .string(toolName) }
        if let functionName { values["functionName"] = .string(functionName) }
        if let functionVersion { values["functionVersion"] = .string(functionVersion) }
        if let inputTokens { values["inputTokens"] = .number(inputTokens) }
        if let outputTokens { values["outputTokens"] = .number(outputTokens) }
        if let totalTokens { values["totalTokens"] = .number(totalTokens) }
        if let reasoningTokens { values["reasoningTokens"] = .number(reasoningTokens) }
        if let cachedInputTokens { values["cachedInputTokens"] = .number(cachedInputTokens) }
        if let cost { values["cost"] = .number(cost) }
        if let historyMessageIds { values["historyMessageIds"] = .stringset(historyMessageIds) }
        if let errorCode { values["errorCode"] = .string(errorCode) }
        if let errorMessage { values["errorMessage"] = .string(errorMessage) }
        return values
    }
}

/// Reads of `PrimitiveStep` across every open document, through the configured
/// default `JsBaoClient`. Rows that fail to decode are reported through
/// `PrimitiveRowDecoder.onDecodeFailure`, never dropped silently.
public extension PrimitiveStep {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> [PrimitiveStep] {
        let rows = try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeAll(rows, as: PrimitiveStep.self)
    }

    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PagedQueryResult<PrimitiveStep> {
        let page = try JsBaoClient.requireDefault()
            .codegen.queryPaged(primitiveSchema, filter: filter, options: options)
        return PagedQueryResult(
            data: PrimitiveRowDecoder.decodeAll(page.data, as: PrimitiveStep.self),
            nextCursor: page.nextCursor,
            prevCursor: page.prevCursor,
            hasMore: page.hasMore
        )
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PrimitiveStep? {
        let row = try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter, options: options)
        return PrimitiveRowDecoder.decodeOne(row, as: PrimitiveStep.self)
    }

    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    /// Throws `PrimitiveDecodeError` when a stored row no longer decodes.
    static func findAll() throws -> [PrimitiveStep] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: nil, options: nil)
            .map { row in
                guard let decoded = PrimitiveStep(row: row) else {
                    throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
                }
                return decoded
            }
    }

    /// `nil` only when no open document has `id`; throws when the row does not decode.
    static func find(_ id: String) throws -> PrimitiveStep? {
        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {
            return nil
        }
        guard let decoded = PrimitiveStep(row: row) else {
            throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)
        }
        return decoded
    }

    @discardableResult
    static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        JsBaoClient.requireDefault().codegen.subscribe(primitiveSchema, callback)
    }
}

/// A `PrimitivePart` by kind (`PrimitivePart.content`).
public enum PrimitivePartContent: Sendable, Equatable {
    case text(PrimitiveTextPartContent)
    case reasoning(PrimitiveTextPartContent)
    case toolCall(PrimitiveToolCallPartContent)
    case file(PrimitiveFilePartContent)
    case event(PrimitiveEventPartContent)
    case unknown(kind: String)
}

public struct PrimitiveTextPartContent: Sendable, Equatable {
    public var state: PrimitiveTextState?
    public var text: String?
    public var providerMetadata: [String: JSONValue]?
}

public struct PrimitiveToolCallPartContent: Sendable, Equatable {
    public var state: PrimitiveToolCallState?
    public var toolCallId: String?
    public var toolName: String?
    public var input: JSONValue?
    public var output: JSONValue?
    public var errorText: String?
    public var errorCode: String?
    public var statusText: String?
    public var approvalApproved: Bool?
    public var approvalReason: String?
    public var approvalUserId: String?
    public var approvalRespondedAt: String?
    public var resolvedByUserId: String?
    public var artifact: JSONValue?
    public var artifactBlobId: String?
    public var providerMetadata: [String: JSONValue]?
}

public struct PrimitiveFilePartContent: Sendable, Equatable {
    public var mediaType: String?
    public var filename: String?
    public var blobId: String?
    public var sizeBytes: Double?
}

public struct PrimitiveEventPartContent: Sendable, Equatable {
    public var eventKind: String?
    public var eventId: String?
    public var refersTo: String?
    public var data: JSONValue?
}

/// The platform session models, for a client to attach at open (#3810).
public enum AgentSessionModels {
    /// The schema version a session row carries in `schemaVersion`.
    public static let schemaVersion: Double = 1
    public static let schemas: [PrimitiveSchema] = [PrimitiveSession.primitiveSchema, PrimitiveMessage.primitiveSchema, PrimitivePart.primitiveSchema, PrimitiveStep.primitiveSchema]
}
