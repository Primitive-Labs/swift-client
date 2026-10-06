import Foundation
@testable import JsBaoClient

/// Decoded session rows as the shared fixtures spell them (#3802), and as the
/// JS client's decode is projected by `CrossPlatform/harness/agent-session-decode.mjs`
/// (#3810): one definition the fixture suite and the live parity suite both
/// hold the two clients to.
///
/// - An open enum is its known value, or `"unknown"`.
/// - `{"$absent": true}` is "no value" — distinct from JSON `null`, which an
///   `any` column can hold.
/// - A stringset is its members, sorted; an absent one is `[]`.
/// - JSON columns are their values.
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
    static func queue(_ v: [PrimitiveQueueEntry]?) -> JSONValue { v.map { .array($0.map(\.jsonValue)) } ?? absent }

    static func project(_ s: PrimitiveSession) -> [String: JSONValue] {
        [
            "id": .string(s.id),
            "schemaVersion": .number(s.schemaVersion),
            "agentKey": .string(s.agentKey),
            "configId": value(s.configId),
            "status": open(s.status.rawValue, known: s.status.isKnown),
            "activeTurnId": value(s.activeTurnId),
            "activeTurnInitiatorUserId": value(s.activeTurnInitiatorUserId),
            "activeTurnStartedAt": value(s.activeTurnStartedAt),
            "activeTurnMessageIds": members(s.activeTurnMessageIds),
            "queue": queue(s.queue),
            "title": value(s.title),
            "scope": value(s.scope),
            "variables": value(s.variables),
            "viewerUserIds": members(s.viewerUserIds),
            "participantUserIds": members(s.participantUserIds),
            "ownerUserId": value(s.ownerUserId),
            "lastErrorCode": value(s.lastErrorCode),
            "lastErrorMessage": value(s.lastErrorMessage),
            "createdAt": .string(s.createdAt),
            "modifiedAt": value(s.modifiedAt),
        ]
    }

    static func project(_ m: PrimitiveMessage) -> [String: JSONValue] {
        [
            "id": .string(m.id),
            "seq": .number(m.seq),
            "turnId": value(m.turnId),
            "authorKind": open(m.authorKind.rawValue, known: m.authorKind.isKnown),
            "authorUserId": value(m.authorUserId),
            "clientMessageId": value(m.clientMessageId),
            "createdAt": .string(m.createdAt),
        ]
    }

    static func project(_ p: PrimitivePart) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "id": .string(p.id),
            "messageId": .string(p.messageId),
            "seq": .number(p.seq),
            "createdAt": .string(p.createdAt),
            "modifiedAt": value(p.modifiedAt),
        ]
        switch p.content {
        case let .text(c), let .reasoning(c):
            out["kind"] = .string(p.kind.rawValue)
            out["state"] = c.state.map { open($0.rawValue, known: $0.isKnown) } ?? absent
            out["text"] = value(c.text)
            out["providerMetadata"] = value(c.providerMetadata)
        case let .toolCall(c):
            out["kind"] = "tool_call"
            out["state"] = c.state.map { open($0.rawValue, known: $0.isKnown) } ?? absent
            out["toolCallId"] = value(c.toolCallId)
            out["toolName"] = value(c.toolName)
            out["input"] = value(c.input)
            out["output"] = value(c.output)
            out["errorText"] = value(c.errorText)
            out["errorCode"] = value(c.errorCode)
            out["statusText"] = value(c.statusText)
            out["approvalApproved"] = value(c.approvalApproved)
            out["approvalReason"] = value(c.approvalReason)
            out["approvalUserId"] = value(c.approvalUserId)
            out["approvalRespondedAt"] = value(c.approvalRespondedAt)
            out["resolvedByUserId"] = value(c.resolvedByUserId)
            out["artifact"] = value(c.artifact)
            out["artifactBlobId"] = value(c.artifactBlobId)
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

    static func project(_ s: PrimitiveStep) -> [String: JSONValue] {
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
            "errorCode": value(s.errorCode),
            "errorMessage": value(s.errorMessage),
            "historyMode": value(s.historyMode),
            "historySelection": value(s.historySelection),
            "providerDurationMs": value(s.providerDurationMs),
        ]
    }

    /// Decode `row` as `model` and project it; `nil` when the row does not
    /// decode (or the model is not a platform model).
    static func decode(model: String, row: [String: JSONValue]) -> [String: JSONValue]? {
        switch model {
        case "PrimitiveSession": return PrimitiveSession(row: row).map(project)
        case "PrimitiveMessage": return PrimitiveMessage(row: row).map(project)
        case "PrimitivePart": return PrimitivePart(row: row).map(project)
        case "PrimitiveStep": return PrimitiveStep(row: row).map(project)
        default: return nil
        }
    }
}

// Whether an open value is one of the vocabulary's known values.
extension PrimitiveSessionStatus { var isKnown: Bool { Self.known.contains(self) } }
extension PrimitiveToolCallState { var isKnown: Bool { Self.known.contains(self) } }
extension PrimitiveTextState { var isKnown: Bool { Self.known.contains(self) } }
extension PrimitivePartKind { var isKnown: Bool { Self.known.contains(self) } }
extension PrimitiveAuthorKind { var isKnown: Bool { Self.known.contains(self) } }
extension PrimitiveStepKind { var isKnown: Bool { Self.known.contains(self) } }
extension PrimitiveStepStatus { var isKnown: Bool { Self.known.contains(self) } }
