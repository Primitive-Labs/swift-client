import Foundation

// A presentation an agent handed the client with its answer — the Swift half
// of the JS client's `view.presentations()`, rule for rule.

/// A presentation an agent handed the client with its final answer: a call to
/// a tool the agent declares with `runs = "presentation"`, from the agent
/// message's call. Read them with `view.presentations(of:names:)`, and decode
/// one with the generated `<Key>AgentPresentation(_:)`.
///
/// A presentation's input can name earlier calls of its turn by number (the
/// tool's `references`); `call(_:)` resolves such a number to that call.
public struct AgentPresentation: Sendable, Equatable {
    /// The presentation tool's name.
    public let name: String
    /// The call's input, checked by the platform against the tool's
    /// `inputSchema`.
    public let input: JSONValue
    /// The call.
    public let part: AgentSessionToolCallRecord
    /// The turn's calls in the view's window, by call number.
    let turnCalls: [Int: AgentSessionToolCallRecord]

    /// The call numbered `number` in this presentation's turn; `nil` for a
    /// number no call of the turn in the view's window carries.
    public func call(_ number: Int) -> AgentSessionToolCallRecord? {
        turnCalls[number]
    }

    /// The input decoded as `type`, the way the generated
    /// `<Key>AgentPresentation(_:)` decodes it.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(input))
    }

    /// The presentations of an agent message: each of its calls in
    /// `output-available` state whose tool is one of `names`, in part order.
    /// `turnParts` are the parts of the message's turn the caller holds, whose
    /// numbered calls `call(_:)` resolves numbers against.
    static func collect(
        message: AgentSessionMessageRecord,
        parts: [AgentSessionViewPart],
        turnParts: [AgentSessionViewPart],
        names: [String]
    ) -> [AgentPresentation] {
        guard message.authorKind == .agent else { return [] }
        let wanted = Set(names)
        var calls: [Int: AgentSessionToolCallRecord] = [:]
        for case let .toolCall(call) in turnParts {
            guard let number = call.callNumber, number.rounded() == number else { continue }
            calls[Int(number)] = call
        }
        return parts.compactMap { part in
            guard case let .toolCall(call) = part, call.state == .outputAvailable, wanted.contains(call.toolName) else {
                return nil
            }
            return AgentPresentation(name: call.toolName, input: call.input ?? .null, part: call, turnCalls: calls)
        }
    }
}
