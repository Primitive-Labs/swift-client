import Foundation
@testable import JsBaoClient

/// Decoded session rows as the shared fixtures spell them (#3802), and as the
/// JS client's decode is projected by `CrossPlatform/harness/agent-session-decode.mjs`
/// (#3810): one definition the fixture suite and the live parity suite both
/// hold the two clients to. Since #4884 the rows are the seven models of a
/// session's db3, each projected as every column its record represents.
///
/// - An open enum is its known value, or `"unknown"`.
/// - `{"$absent": true}` is "no value" — distinct from JSON `null`, which an
///   `any` column can hold.
/// - A stringset is its members, sorted; an absent one is `[]`.
/// - JSON columns are their values.
/// - A `Part` carries its kind's columns; one of a kind this client does not
///   know is `kind: "unknown"` with its `rawKind`.
enum AgentSessionProjection {
    static let absent: JSONValue = ["$absent": true]

    static func open(_ raw: String?, known: Bool) -> JSONValue {
        guard let raw else { return absent }
        return .string(known ? raw : "unknown")
    }
    static func value(_ v: String?) -> JSONValue { v.map { .string($0) } ?? absent }
    static func value(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? absent }
    static func value(_ v: Bool?) -> JSONValue { v.map { .bool($0) } ?? absent }
    static func value(_ v: JSONValue?) -> JSONValue { v ?? absent }
    static func value(_ v: [String: JSONValue]?) -> JSONValue { v.map { .object($0) } ?? absent }
    static func members(_ v: Set<String>?) -> JSONValue { .array((v ?? []).sorted().map { .string($0) }) }

    // MARK: - The db3's records (#4884)

    static func project(_ s: AgentSessionRecord) -> [String: JSONValue] {
        [
            "id": .string(s.id),
            "agentKey": .string(s.agentKey),
            "configId": value(s.configId),
            "title": value(s.title),
            "scope": value(s.scope),
            "status": open(s.status.rawValue, known: s.status.isKnown),
            "activeTurnId": value(s.activeTurnId),
            "variables": value(s.variables),
            "lastErrorCode": value(s.lastErrorCode),
            "lastErrorMessage": value(s.lastErrorMessage),
            "createdAt": value(s.createdAt),
            "modifiedAt": value(s.modifiedAt),
        ]
    }

    /// A member's role is known when it is one of the IR's member roles.
    static func project(_ m: AgentSessionMemberRecord) -> [String: JSONValue] {
        [
            "id": .string(m.id),
            "role": open(m.role.rawValue, known: [AgentSessionRole.owner, .participant, .viewer].contains(m.role)),
            "addedAt": .string(m.addedAt),
        ]
    }

    static func project(_ t: AgentSessionTurnRecord) -> [String: JSONValue] {
        [
            "id": .string(t.id),
            "seq": .number(t.seq),
            "status": open(t.status.rawValue, known: t.status.isKnown),
            "initiatorUserId": value(t.initiatorUserId),
            "startedAt": value(t.startedAt),
            "endedAt": value(t.endedAt),
            "errorCode": value(t.errorCode),
            "errorMessage": value(t.errorMessage),
            "inputTokens": value(t.inputTokens),
            "outputTokens": value(t.outputTokens),
            "totalTokens": value(t.totalTokens),
            "reasoningTokens": value(t.reasoningTokens),
            "cachedInputTokens": value(t.cachedInputTokens),
            "cost": value(t.cost),
        ]
    }

    static func project(_ m: AgentSessionMessageRecord) -> [String: JSONValue] {
        [
            "id": .string(m.id),
            "seq": .number(m.seq),
            "authorKind": open(m.authorKind.rawValue, known: m.authorKind.isKnown),
            "authorUserId": value(m.authorUserId),
            "clientMessageId": value(m.clientMessageId),
            "turnId": value(m.turnId),
            "queueSeq": value(m.queueSeq),
            "createdAt": .string(m.createdAt),
        ]
    }

    static func project(_ p: AgentSessionPartRecord) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "id": .string(p.id),
            "messageId": .string(p.messageId),
            "seq": .number(p.seq),
            "createdAt": value(p.createdAt),
            "modifiedAt": value(p.modifiedAt),
        ]
        switch p.content {
        case let .text(c), let .reasoning(c):
            out["kind"] = .string(p.kind.rawValue)
            out["text"] = value(c.text)
            out["textState"] = c.textState.map { open($0.rawValue, known: $0.isKnown) } ?? absent
            out["providerMetadata"] = value(c.providerMetadata)
        case let .file(c):
            out["kind"] = "file"
            out["mediaType"] = value(c.mediaType)
            out["filename"] = value(c.filename)
            out["blobId"] = value(c.blobId)
            out["sizeBytes"] = value(c.sizeBytes)
        case let .event(c):
            out["kind"] = "event"
            out["eventKind"] = value(c.eventKind)
            out["eventId"] = value(c.eventId)
            out["refersTo"] = value(c.refersTo)
            out["data"] = value(c.data)
        case let .unknown(kind):
            out["kind"] = "unknown"
            out["rawKind"] = .string(kind)
        }
        return out
    }

    static func project(_ c: AgentSessionToolCallRecord) -> [String: JSONValue] {
        [
            "id": .string(c.id),
            "messageId": .string(c.messageId),
            "seq": .number(c.seq),
            "turnId": .string(c.turnId),
            "callNumber": value(c.callNumber),
            "toolName": .string(c.toolName),
            "state": open(c.state.rawValue, known: c.state.isKnown),
            "input": value(c.input),
            "output": value(c.output),
            "outputBlobId": value(c.outputBlobId),
            "errorText": value(c.errorText),
            "errorCode": value(c.errorCode),
            "statusText": value(c.statusText),
            "approvalApproved": value(c.approvalApproved),
            "approvalReason": value(c.approvalReason),
            "approvalUserId": value(c.approvalUserId),
            "approvalRespondedAt": value(c.approvalRespondedAt),
            "resolvedByUserId": value(c.resolvedByUserId),
            "artifact": value(c.artifact),
            "artifactBlobId": value(c.artifactBlobId),
            "providerMetadata": value(c.providerMetadata),
            "createdAt": value(c.createdAt),
            "modifiedAt": value(c.modifiedAt),
        ]
    }

    static func project(_ s: AgentSessionStepRecord) -> [String: JSONValue] {
        [
            "id": .string(s.id),
            "turnId": .string(s.turnId),
            "seq": .number(s.seq),
            "kind": open(s.kind.rawValue, known: s.kind.isKnown),
            "status": open(s.status.rawValue, known: s.status.isKnown),
            "startedAt": .string(s.startedAt),
            "endedAt": value(s.endedAt),
            "durationMs": value(s.durationMs),
            "provider": value(s.provider),
            "model": value(s.model),
            "configId": value(s.configId),
            "callId": value(s.callId),
            "toolName": value(s.toolName),
            "functionName": value(s.functionName),
            "functionVersion": value(s.functionVersion),
            "inputTokens": value(s.inputTokens),
            "outputTokens": value(s.outputTokens),
            "totalTokens": value(s.totalTokens),
            "reasoningTokens": value(s.reasoningTokens),
            "cachedInputTokens": value(s.cachedInputTokens),
            "cost": value(s.cost),
            "historyMessageIds": members(s.historyMessageIds),
            "historyMode": value(s.historyMode),
            "historySelection": value(s.historySelection),
            "providerDurationMs": value(s.providerDurationMs),
            "errorCode": value(s.errorCode),
            "errorMessage": value(s.errorMessage),
            "resolvedByUserId": value(s.resolvedByUserId),
        ]
    }

    /// Decode `row` as `model` and project it; `nil` when the row does not
    /// decode (or the model is not one of the db3's seven).
    static func decode(model: String, row: [String: JSONValue]) -> [String: JSONValue]? {
        switch model {
        case "Session": return AgentSessionRecord(row: row).map(project)
        case "Member": return AgentSessionMemberRecord(row: row).map(project)
        case "Turn": return AgentSessionTurnRecord(row: row).map(project)
        case "Message": return AgentSessionMessageRecord(row: row).map(project)
        case "Part": return AgentSessionPartRecord(row: row).map(project)
        case "ToolCall": return AgentSessionToolCallRecord(row: row).map(project)
        case "Step": return AgentSessionStepRecord(row: row).map(project)
        default: return nil
        }
    }
}

// Whether an open value is one of the vocabulary's known values.
extension AgentSessionStatus { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionTurnStatus { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionToolCallState { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionTextState { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionPartKind { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionAuthorKind { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionStepKind { var isKnown: Bool { Self.known.contains(self) } }
extension AgentSessionStepStatus { var isKnown: Bool { Self.known.contains(self) } }
