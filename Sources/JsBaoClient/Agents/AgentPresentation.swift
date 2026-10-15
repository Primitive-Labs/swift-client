import Foundation

// A presentation an agent handed the client with its answer — the Swift half
// of the JS client's `src/client/agents/presentations.ts`, rule for rule.

/// A presentation an agent handed the client with its final answer: a call to
/// a tool the agent declares with `runs = "presentation"`, from the agent
/// message's `tool_call` part. Read them with
/// `view.presentations(of:names:)`, and decode one with the generated
/// `<Key>AgentPresentation(_:)`.
///
/// A presentation's input can name earlier calls of its turn by number (the
/// tool's `references`); `call(_:)` resolves such a number to that call's part.
public struct AgentPresentation: Sendable, Equatable {
    /// The presentation tool's name.
    public let name: String
    /// The call's input, checked by the platform against the tool's
    /// `inputSchema`.
    public let input: JSONValue
    /// The call's `tool_call` part.
    public let part: PrimitivePart
    /// The turn's `tool_call` parts in the view's window, by call number.
    let turnCalls: [Int: PrimitivePart]

    /// The `tool_call` part of the call numbered `number` in this
    /// presentation's turn; `nil` for a number no call of the turn in the
    /// view's window carries.
    public func call(_ number: Int) -> PrimitivePart? {
        turnCalls[number]
    }

    /// The input decoded as `type`, the way the generated
    /// `<Key>AgentPresentation(_:)` decodes it.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(input))
    }

    /// The presentations of an agent message: each of its `tool_call` parts
    /// in `output-available` state whose tool is one of `names`, in part
    /// order. `turnParts` are the parts of the message's turn the caller
    /// holds, which `call(_:)` resolves numbers against.
    static func collect(
        message: PrimitiveMessage,
        parts: [PrimitivePart],
        turnParts: [PrimitivePart],
        names: [String]
    ) -> [AgentPresentation] {
        guard message.authorKind == .agent else { return [] }
        let wanted = Set(names)
        var calls: [Int: PrimitivePart] = [:]
        for part in turnParts where part.kind == .toolCall {
            guard let number = part.callNumber, number.rounded() == number else { continue }
            calls[Int(number)] = part
        }
        return parts.compactMap { part in
            guard part.kind == .toolCall, part.state == "output-available",
                  let name = part.toolName, wanted.contains(name)
            else { return nil }
            return AgentPresentation(name: name, input: part.input ?? .null, part: part, turnCalls: calls)
        }
    }
}
