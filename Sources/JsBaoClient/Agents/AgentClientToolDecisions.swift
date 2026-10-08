import Foundation

// The small rules of `view.handleClientTools` (#4263) — the Swift half of the
// JS client's `src/client/agents/clientToolDecisions.ts`: which tool-call
// part a handler may run, how a failed answer is read, and an error's
// message as an answer. Internal; the view applies them.

enum AgentClientToolDecisions {
    /// The longest error message an answer carries, in characters.
    static let errorMax = 4096
    /// The error message an answer carries when the handler's error has none.
    static let defaultError = "Client tool failed"
    /// Refusals that mean another answer, or the turn's end, came first.
    static let lostCodes: Set<String> = [
        "AGENT_CALL_ANSWERED", "AGENT_TURN_STALE", "AGENT_CALL_NOT_FOUND", "AGENT_TURN_NOT_ALLOWED",
    ]
    /// `HttpError` codes the client sets itself, which no server sent.
    static let clientSentinels: Set<String> = [HttpError.emptyBodyCode, HttpError.decodingFailedCode]
    /// The tool-call states after which a call takes no answer.
    static let terminalStates: Set<String> = ["output-available", "output-error", "output-denied"]

    /// A call a registered handler may run.
    struct EligibleCall: Sendable, Equatable {
        let callId: String
        let toolName: String
        let input: JSONValue?
        let messageId: String
        let partId: String
        /// The state it was found in: `input-available` or `approval-responded`.
        let state: String
    }

    /// The call a part holds when a handler may run it: a tool call of a
    /// registered name with a call id, waiting for its result
    /// (`input-available`, or `approval-responded` once approved).
    static func eligibleCall(part: PrimitivePart, registered: Set<String>) -> EligibleCall? {
        guard part.kind == .toolCall,
              let callId = part.toolCallId, !callId.isEmpty,
              let toolName = part.toolName, registered.contains(toolName),
              let state = part.state
        else { return nil }
        let waiting = state == "input-available" || (state == "approval-responded" && part.approvalApproved == true)
        guard waiting else { return nil }
        return EligibleCall(
            callId: callId, toolName: toolName, input: part.input, messageId: part.messageId,
            partId: part.id, state: state
        )
    }

    /// How a failed answer is read.
    enum AnswerFailure: Sendable, Equatable {
        case lost(code: String)
        case refused(code: String, message: String)
        case transport(message: String)
    }

    /// A failed answer, by error class: only a server refusal (an
    /// `HttpError` carrying a server code) is read by its code. Everything
    /// else — the client's own `.offline`, a `URLError`, a cancellation, an
    /// `HttpError` with no server code or with one the client set itself —
    /// is a transport failure.
    static func classifyAnswerFailure(_ error: Error) -> AnswerFailure {
        if let http = error as? HttpError, let code = http.serverCode, !clientSentinels.contains(code) {
            if lostCodes.contains(code) { return .lost(code: code) }
            return .refused(code: code, message: http.serverMessage ?? http.message)
        }
        return .transport(message: message(of: error))
    }

    /// An error's message as an answer carries it: at most 4096 UTF-16 code
    /// units (the server's measure), never empty.
    static func errorMessage(of error: Error) -> String {
        let text = message(of: error)
        guard !text.isEmpty else { return defaultError }
        let units = text.utf16
        guard units.count > errorMax else { return text }
        return String(decoding: Array(units.prefix(errorMax)), as: UTF16.self)
    }

    private static func message(of error: Error) -> String {
        if let jsBao = error as? JsBaoError { return jsBao.message }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
