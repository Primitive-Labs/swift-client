// AUTO-GENERATED FROM prompts/display.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 8d2d14e406e0de62

import Foundation
import JsBaoClient

public typealias DisplayAgentVariables = JSONValue

public struct DisplayPresentationShow: Codable, Equatable, Sendable {
    public var status: Status
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        status: Status,
        extra: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try container.decode(Status.self, forKey: .status)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["status"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// A presentation the `display` agent hands the client with its answer,
/// typed by name: decode one of `view.presentations(of:names:)` with `init?(_:)`.
public enum DisplayAgentPresentation: Equatable, Sendable {
    case show(DisplayPresentationShow)

    /// The presentation's typed input; `nil` for a name this agent does not
    /// declare, or an input its type does not decode.
    public init?(_ presentation: AgentPresentation) {
        switch presentation.name {
        case "show":
            do { self = .show(try presentation.decode(DisplayPresentationShow.self)) } catch { return nil }
        default:
            return nil
        }
    }
}

/// The `display` agent: the key a session is created with, and the
/// client tools, presentations and event kinds it declares.
public enum DisplayAgent {
    public static let key = "display"
    public static let clientToolNames: [String] = []
    public static let presentationNames: [String] = ["show"]
    public static let eventNames: [String] = []
}
