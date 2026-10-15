// AUTO-GENERATED FROM prompts/concierge.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 87a144318aba7138

import Foundation
import JsBaoClient

public typealias ConciergeAgentVariables = JSONValue

/// A presentation the `concierge` agent hands the client with its answer,
/// typed by name: decode one of `view.presentations(of:names:)` with `init?(_:)`.
public enum ConciergeAgentPresentation: Equatable, Sendable {
    /// The presentation's typed input; `nil` for a name this agent does not
    /// declare, or an input its type does not decode.
    public init?(_ presentation: AgentPresentation) {
        return nil
    }
}

/// The `concierge` agent: the key a session is created with, and the
/// client tools, presentations and event kinds it declares.
public enum ConciergeAgent {
    public static let key = "concierge"
    public static let clientToolNames: [String] = []
    public static let presentationNames: [String] = []
    public static let eventNames: [String] = []
}
