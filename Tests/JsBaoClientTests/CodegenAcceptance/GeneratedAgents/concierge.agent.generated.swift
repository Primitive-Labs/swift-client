// AUTO-GENERATED FROM prompts/concierge.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 87a144318aba7138

import Foundation
import JsBaoClient

public typealias ConciergeAgentVariables = JSONValue

/// The `concierge` agent: the key a session is created with, and the
/// client tools and event kinds it declares.
public enum ConciergeAgent {
    public static let key = "concierge"
    public static let clientToolNames: [String] = []
    public static let eventNames: [String] = []
}
