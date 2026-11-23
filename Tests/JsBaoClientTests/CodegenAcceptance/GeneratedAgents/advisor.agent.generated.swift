// AUTO-GENERATED FROM prompts/advisor.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 557d4b528c6e0529

import Foundation
import JsBaoClient

public struct AdvisorAgentVariables: Codable, Equatable, Sendable {
    public var householdId: String
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        householdId: String,
        extra: [String: JSONValue] = [:]
    ) {
        self.householdId = householdId
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case householdId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.householdId = try container.decode(String.self, forKey: .householdId)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdId, forKey: .householdId)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["householdId"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct AdvisorToolProposeBudgetChangeInput: Codable, Equatable, Sendable {
    public var category: String
    public var delta: Double
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        category: String,
        delta: Double,
        extra: [String: JSONValue] = [:]
    ) {
        self.category = category
        self.delta = delta
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case category
        case delta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.category = try container.decode(String.self, forKey: .category)
        self.delta = try container.decode(Double.self, forKey: .delta)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(delta, forKey: .delta)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["category", "delta"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct AdvisorToolProposeBudgetChangeOutput: Codable, Equatable, Sendable {
    public var accepted: Bool
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        accepted: Bool,
        extra: [String: JSONValue] = [:]
    ) {
        self.accepted = accepted
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case accepted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accepted = try container.decode(Bool.self, forKey: .accepted)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accepted, forKey: .accepted)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["accepted"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct AdvisorPresentationPresent: Codable, Equatable, Sendable {
    public var show: [Int]
    public var suggestions: [String]?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        show: [Int],
        suggestions: [String]? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.show = show
        self.suggestions = suggestions
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case show
        case suggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.show = try container.decode([Int].self, forKey: .show)
        self.suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(show, forKey: .show)
        try container.encodeIfPresent(suggestions, forKey: .suggestions)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["show", "suggestions"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct AdvisorEventApplied: Codable, Equatable, Sendable {
    public var callId: String
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        callId: String,
        extra: [String: JSONValue] = [:]
    ) {
        self.callId = callId
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case callId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.callId = try container.decode(String.self, forKey: .callId)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["callId"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// A presentation the `advisor` agent hands the client with its answer,
/// typed by name: decode one of `view.presentations(of:names:)` with `init?(_:)`.
public enum AdvisorAgentPresentation: Equatable, Sendable {
    case present(AdvisorPresentationPresent)

    /// The presentation's typed input; `nil` for a name this agent does not
    /// declare, or an input its type does not decode.
    public init?(_ presentation: AgentPresentation) {
        switch presentation.name {
        case "present":
            do { self = .present(try presentation.decode(AdvisorPresentationPresent.self)) } catch { return nil }
        default:
            return nil
        }
    }
}

/// The `advisor` agent: the key a session is created with, and the
/// client tools, presentations and event kinds it declares.
public enum AdvisorAgent {
    public static let key = "advisor"
    public static let clientToolNames: [String] = ["propose_budget_change"]
    public static let presentationNames: [String] = ["present"]
    public static let eventNames: [String] = ["applied"]
}
