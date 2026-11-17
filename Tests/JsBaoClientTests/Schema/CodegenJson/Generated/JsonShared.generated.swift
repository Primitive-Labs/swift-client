// AUTO-GENERATED FROM schemas/ — DO NOT EDIT.
// The schemas/ defs, prompt output types and db3 projections the per-key
// files reference by name, each declared once.
// Run `primitive functions codegen --lang swift` to regenerate.

import Foundation
import JsBaoClient

/// The binding of a db3 JSON field that refs `schemas/billing-v2.toml#ShipInvoice`: its id and compiled
/// schema, which a generated model validates a value against before saving it.
public enum Db3JSONDef_billing_v2_ShipInvoice: Db3JSONDef {
    public typealias Value = Db3JSON_billing_v2_ShipInvoice
    public static let id = "schemas.billing-v2.ShipInvoice"
    public static let schema = #"{"type":"object","properties":{"number":{"type":"integer"},"priority":{"enum":[1,2,3]}}}"#
}

/// The binding of a db3 JSON field that refs `schemas/common.toml#ShipAddress`: its id and compiled
/// schema, which a generated model validates a value against before saving it.
public enum Db3JSONDef_common_ShipAddress: Db3JSONDef {
    public typealias Value = Db3JSON_common_ShipAddress
    public static let id = "schemas.common.ShipAddress"
    public static let schema = #"{"type":"object","required":["city"],"additionalProperties":false,"properties":{"city":{"type":"string","minLength":1,"maxLength":40},"zip":{"type":"string","pattern":"^[0-9]{4}(-[0-9]{3})?$"},"floor":{"type":"integer","minimum":-5,"maximum":200},"size":{"type":"string","enum":["s","m","l"]}}}"#
}

/// The binding of a db3 JSON field that refs `schemas/common.toml#ShipMeta`: its id and compiled
/// schema, which a generated model validates a value against before saving it.
public enum Db3JSONDef_common_ShipMeta: Db3JSONDef {
    public typealias Value = Db3JSON_common_ShipMeta
    public static let id = "schemas.common.ShipMeta"
    public static let schema = #"{"type":"object"}"#
}

/// The binding of a db3 JSON field that refs `schemas/common.toml#ShipNeedsKind`: its id and compiled
/// schema, which a generated model validates a value against before saving it.
public enum Db3JSONDef_common_ShipNeedsKind: Db3JSONDef {
    public typealias Value = Db3JSON_common_ShipNeedsKind
    public static let id = "schemas.common.ShipNeedsKind"
    public static let schema = #"{"type":"object","required":["kind"]}"#
}

/// The binding of a db3 JSON field that refs `schemas/common.toml#ShipParcel`: its id and compiled
/// schema, which a generated model validates a value against before saving it.
public enum Db3JSONDef_common_ShipParcel: Db3JSONDef {
    public typealias Value = Db3JSON_common_ShipParcel
    public static let id = "schemas.common.ShipParcel"
    public static let schema = #"{"type":"object","properties":{"label":{"type":"string"},"box":{"type":"object","properties":{"width":{"type":"number"},"count":{"type":"integer"}},"required":["width"],"additionalProperties":false},"codes":{"type":"array","items":{"type":"integer"}}},"required":["label"],"additionalProperties":false}"#
}

/// The type of a db3 JSON field that refs `schemas/billing-v2.toml#ShipInvoice`.
public typealias Db3JSON_billing_v2_ShipInvoice = ShipInvoice

/// The type of a db3 JSON field that refs `schemas/common.toml#ShipAddress`.
public typealias Db3JSON_common_ShipAddress = ShipAddress

/// The type of a db3 JSON field that refs `schemas/common.toml#ShipMeta`.
public typealias Db3JSON_common_ShipMeta = ShipMeta

/// The type of a db3 JSON field that refs `schemas/common.toml#ShipNeedsKind`.
public typealias Db3JSON_common_ShipNeedsKind = ShipNeedsKind

/// The type of a db3 JSON field that refs `schemas/common.toml#ShipParcel`.
public typealias Db3JSON_common_ShipParcel = ShipParcel

public struct ShipAddress: Codable, Equatable, Sendable {
    public enum SizeValue: String, Codable, CaseIterable, Sendable {
        case s = "s"
        case m = "m"
        case l = "l"
    }

    /// - minLength: 1
    /// - maxLength: 40
    public var city: String
    /// - pattern: "^[0-9]{4}(-[0-9]{3})?$"
    public var zip: String?
    /// - minimum: -5
    /// - maximum: 200
    public var floor: Int?
    public var size: SizeValue?

    public init(
        city: String,
        zip: String? = nil,
        floor: Int? = nil,
        size: SizeValue? = nil
    ) {
        self.city = city
        self.zip = zip
        self.floor = floor
        self.size = size
    }
}

public struct ShipInvoice: Codable, Equatable, Sendable {
    public var number: Int?
    public var priority: JSONValue?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        number: Int? = nil,
        priority: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.number = number
        self.priority = priority
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case number
        case priority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try container.decodeIfPresent(Int.self, forKey: .number)
        self.priority = try container.decodeIfPresent(JSONValue.self, forKey: .priority)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(priority, forKey: .priority)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["number", "priority"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public typealias ShipMeta = [String: JSONValue]

public typealias ShipNeedsKind = [String: JSONValue]

public struct ShipParcel: Codable, Equatable, Sendable {
    public struct Box: Codable, Equatable, Sendable {
        public var width: Double
        public var count: Int?

        public init(
            width: Double,
            count: Int? = nil
        ) {
            self.width = width
            self.count = count
        }
    }

    public var label: String
    public var box: Box?
    public var codes: [Int]?

    public init(
        label: String,
        box: Box? = nil,
        codes: [Int]? = nil
    ) {
        self.label = label
        self.box = box
        self.codes = codes
    }
}

public struct ShipUnused: Codable, Equatable, Sendable {
    public var note: String?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        note: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.note = note
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(note, forKey: .note)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["note"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
