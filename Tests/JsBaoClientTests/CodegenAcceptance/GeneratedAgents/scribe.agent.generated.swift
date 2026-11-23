// AUTO-GENERATED FROM prompts/scribe.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: db747a956bf90f30

import Foundation
import JsBaoClient

public typealias ScribeAgentVariables = JSONValue

public struct ScribePresentation_: Codable, Equatable, Sendable {
    public var show: [Int]
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        show: [Int],
        extra: [String: JSONValue] = [:]
    ) {
        self.show = show
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case show
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.show = try container.decode([Int].self, forKey: .show)
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
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["show"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public typealias ScribePresentationNote = String?

/// A presentation the `scribe` agent hands the client with its answer,
/// typed by name: decode one of `view.presentations(of:names:)` with `init?(_:)`.
public enum ScribeAgentPresentation: Equatable, Sendable {
    case `_`(ScribePresentation_)
    case note(ScribePresentationNote)

    /// The presentation's typed input; `nil` for a name this agent does not
    /// declare, or an input its type does not decode.
    public init?(_ presentation: AgentPresentation) {
        switch presentation.name {
        case "_":
            do { self = .`_`(try presentation.decode(ScribePresentation_.self)) } catch { return nil }
        case "note":
            do { self = .note(try presentation.decode(ScribePresentationNote.self)) } catch { return nil }
        default:
            return nil
        }
    }
}

/// The `scribe` agent: the key a session is created with, and the
/// client tools, presentations and event kinds it declares.
public enum ScribeAgent {
    public static let key = "scribe"
    public static let clientToolNames: [String] = []
    public static let presentationNames: [String] = ["_", "note"]
    public static let eventNames: [String] = []
}
