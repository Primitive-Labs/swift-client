import Foundation

// MARK: - JSONValue

/// A type-erased, fully `Codable` JSON value.
///
/// Used for fields the platform does not introspect and round-trips
/// verbatim — most notably a document's opaque `metadata` blob. This
/// mirrors the `unknown` typing on the JS side: the *shape* is the
/// caller's to define, but unlike a raw `[String: Any]` the value
/// encodes and decodes losslessly and participates in `Codable`.
///
/// Construct values with literals thanks to the `ExpressibleBy*`
/// conformances below:
/// ```swift
/// let meta: JSONValue = ["color": "blue", "pinned": true, "order": 3]
/// ```
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(s): try container.encode(s)
        case let .number(n): try container.encode(n)
        case let .bool(b): try container.encode(b)
        case let .object(o): try container.encode(o)
        case let .array(a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    // MARK: - Convenience accessors

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var numberValue: Double? { if case let .number(n) = self { return n }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Subscript into an object value; returns `nil` for non-objects or
    /// missing keys.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Literal conformances

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Updatable

/// Tri-state for a nullable field with replace semantics on update.
///
/// Distinguishes the three cases the wire protocol cares about:
///  * omit the property entirely (leave the field unchanged) — represented
///    by the enclosing property being `nil`;
///  * `.value(x)` — set the field to `x`;
///  * `.clear` — explicitly null the field out.
///
/// JS callers lean on `undefined` vs `null` for this distinction; in Swift
/// a plain `String?` can't express "set to null", so clearable fields use
/// `Updatable<T>?` instead.
public enum Updatable<Wrapped: Encodable & Sendable>: Encodable, Sendable {
    case value(Wrapped)
    case clear

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .value(v): try container.encode(v)
        case .clear: try container.encodeNil()
        }
    }
}

// MARK: - JSON bridging helpers

/// Bridges between the JSON `Any` graph that `makeRequest` speaks (the
/// output of `JSONSerialization`) and the typed `Codable` request/response
/// models. This is the seam that lets the API layer hand back real Swift
/// types instead of `[String: Any]`.
enum JSONCoding {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    /// Decode a typed value from the loosely-typed JSON object a
    /// `makeRequest` call returns.
    static func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: data)
    }

    /// Encode a typed request body back into the JSON `Any` graph
    /// `makeRequest` expects as its body argument.
    static func jsonObject<T: Encodable>(from value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
