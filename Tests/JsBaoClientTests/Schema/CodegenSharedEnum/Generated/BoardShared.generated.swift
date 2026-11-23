// AUTO-GENERATED FROM schemas/ — DO NOT EDIT.
// The schemas/ defs, prompt output types and db3 projections the per-key
// files reference by name, each declared once.
// Run `primitive functions codegen --lang swift` to regenerate.

import Foundation
import JsBaoClient

public enum Phase: String, Codable, CaseIterable, Sendable {
    case `open` = "open"
    case closed = "closed"
}

/// - projection: declared — db3 board.posts as declared (closed, storage keys stripped)
public struct PostsDeclared: Codable, Equatable, Sendable {
    public var title: String?
    public var status: Phase?

    public init(
        title: String? = nil,
        status: Phase? = nil
    ) {
        self.title = title
        self.status = status
    }
}

/// - projection: row — db3 board.posts as a stored row (id, the declared fields, the type's stamps; open)
public struct PostsRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var status: Phase?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        id: String,
        title: String? = nil,
        status: Phase? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.status = try container.decodeIfPresent(Phase.self, forKey: .status)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(status, forKey: .status)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["id", "title", "status"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public enum StatusValue: String, Codable, CaseIterable, Sendable {
    case draft = "draft"
    case on_hold = "on hold"
    case done = "done"
}

public enum stateRaw: String, Codable, CaseIterable, Sendable {
    case on = "on"
    case off = "off"
}

public enum status: String, Codable, CaseIterable, Sendable {
    case `open` = "open"
    case closed = "closed"
}
