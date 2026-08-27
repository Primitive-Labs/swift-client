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
///
/// ## Numeric precision — every number is a `Double`
///
/// There is one numeric case, `.number(Double)`, so **every** JSON number
/// round-trips through a 64-bit float. This matches JavaScript's single
/// `number` type, which is what the platform's servers and the JS client
/// speak, so a value that survives the JS client survives this one.
///
/// The limit is the usual one: integers are exact only up to 2^53
/// (`9_007_199_254_740_992`). An `Int64` larger than that — a raw Snowflake
/// ID, a nanosecond timestamp, a big accounting amount in minor units —
/// loses its low bits when it passes through a `JSONValue`, and comes back
/// as a nearby value rather than the one that was sent. Nothing throws; the
/// digits just change.
///
/// This bites on the dynamic payloads specifically: `DoDb` record fields
/// (`[String: JSONValue]`), document `metadata`, and workflow inputs are all
/// caller-defined, so the client cannot know a field was meant to be an
/// exact large integer. Platform identifiers are unaffected — they are ULID
/// **strings**, not numbers.
///
/// If a value needs more than 53 bits of integer precision, store it as a
/// `String` (the same advice the JS client gives) or model that field with a
/// typed `Codable` struct using `Int64`, which decodes straight from the
/// wire bytes and never passes through `JSONValue`.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    /// All JSON numbers, integral or not — see the type's "Numeric
    /// precision" note: exact only to 2^53, like JavaScript's `number`.
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

    // MARK: - Query-row accessors
    //
    // A query row (`[String: JSONValue]`) comes out of SQLite, where two
    // column shapes don't line up with the strict accessors above. These two
    // read them; generated `init?(row:)` uses both.

    /// A row column read as a boolean. SQLite has no boolean type — a boolean
    /// field is stored as INTEGER, so the row carries `.number(0)` /
    /// `.number(1)`. A real `.bool` is accepted too; anything else is `nil`.
    public var rowBoolValue: Bool? {
        switch self {
        case let .bool(b):   return b
        case let .number(n): return n != 0
        default:             return nil
        }
    }

    /// A row column read as `[String]` — the shape a stringset field takes
    /// after the engine's junction-table population pass (an `.array` of
    /// `.string`). Non-string members are dropped; a non-array is `nil`.
    public var stringArrayValue: [String]? {
        guard case let .array(items) = self else { return nil }
        return items.compactMap { $0.stringValue }
    }
}

public extension JSONValue {
    /// Wrap any `Encodable` value as a `JSONValue`.
    ///
    /// This is how a typed model becomes one leaf of a dynamic request body
    /// (`[String: JSONValue]`) without ever materializing a
    /// `JSONSerialization` `Any` graph.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONCoding.decodeData(JSONValue.self, from: JSONCoding.encodeData(value))
    }

    /// Build a `JSONValue` from a loosely-typed JSON `Any` graph — the shape
    /// `JSONSerialization` produces, and the shape the client's remaining
    /// `[String: Any]` public surfaces hand in.
    ///
    /// Containers are converted element by element rather than round-tripped
    /// through `JSONSerialization`, which is what makes this cheap enough for a
    /// per-event path (#1993, behavior 13). The cast order is chosen for the
    /// same reason and is explained inline.
    ///
    /// - Parameter subject: names the values in the error message, so a caller
    ///   can say "KvCache values" or "Analytics event fields".
    init(jsonAny value: Any, subject: String = "Values") throws {
        if let string = value as? String { self = .string(string); return }

        // The native Swift number types next, matched on the value's **concrete
        // type** rather than by a bare `as?`. The type check is what keeps this
        // correct: `NSNumber` bridges, so a plain `value as? Bool` succeeds for
        // the `NSNumber(value: 1)` that `JSONSerialization` produces for `1`,
        // and the number would be read back as `true`. `type(of:)` reports
        // `__NSCFNumber` there, so a bridged number falls through to the
        // `NSNumber` branch below, which tells booleans apart properly.
        //
        // These come first because they are the overwhelming majority of leaves
        // and a matched cast is far cheaper than bridging to `NSNumber` or
        // reflecting — which is what makes the per-event path affordable.
        let concreteType = type(of: value)
        if concreteType == Bool.self, let bool = value as? Bool { self = .bool(bool); return }
        if concreteType == Int.self, let int = value as? Int { self = .number(Double(int)); return }
        if concreteType == Double.self, let double = value as? Double { self = .number(double); return }

        if let json = value as? JSONValue { self = json; return }
        if value is NSNull { self = .null; return }
        if let number = value as? NSNumber {
            // A value that came from Objective-C (or `JSONSerialization`) is an
            // `NSNumber`, and there the boolean has to be told apart by its
            // CoreFoundation type rather than by a cast
            // (`NSNumber(value: 1) as? Bool` succeeds).
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue); return }
            self = .number(number.doubleValue); return
        }

        if let dictionary = value as? [String: Any] {
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                object[key] = try JSONValue(jsonAny: element, subject: subject)
            }
            self = .object(object); return
        }
        if let array = value as? [Any] {
            self = .array(try array.map { try JSONValue(jsonAny: $0, subject: subject) }); return
        }

        // A `nil` optional boxed into `Any` is not `NSNull` and is not
        // JSON-serializable — reflect to spot it. Reflection is the most
        // expensive check here, so it comes after everything a real value can
        // match rather than before, as it did when this lived on `KvCache`.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, mirror.children.isEmpty { self = .null; return }

        // `Date`, `Data`, `URL` and `Decimal` reach this branch: they are
        // `Encodable`, so they lower to their encoded JSON form (a number, a
        // base64 string, a string) and read back as that rather than as the
        // original type. For a cached `[String: Any]` this now applies to the
        // memory tier too, where such a value used to survive untouched.
        if let encodable = value as? any Encodable, let json = try? JSONValue(encoding: encodable) {
            self = json; return
        }
        throw JsBaoError(
            code: .invalidArgument,
            message: "\(subject) must be JSON-representable; \(type(of: value)) is not"
        )
    }

    /// Lower a string-keyed `Any` graph straight to its typed row, skipping the
    /// scalar-cast chain `init(jsonAny:)` has to try before it reaches the
    /// dictionary branch. A caller that already knows it holds a dictionary —
    /// every untyped public surface that feeds a typed one — should use this:
    /// on a three-key event it saves seven failed dynamic casts, which is
    /// measurable on the analytics hot path (#1993, behavior 13).
    static func typedRow(from dictionary: [String: Any], subject: String = "Values") throws -> [String: JSONValue] {
        var row: [String: JSONValue] = [:]
        row.reserveCapacity(dictionary.count)
        for (key, element) in dictionary {
            row[key] = try JSONValue(jsonAny: element, subject: subject)
        }
        return row
    }
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

/// Bridges between the JSON `Any` graph `JSONSerialization` produces and the
/// typed `Codable` request/response models. This is the seam that lets the API layer hand back real Swift
/// types instead of `[String: Any]`.
enum JSONCoding {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    /// Decode a typed value from a loosely-typed JSON object.
    static func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: data)
    }

    /// Encode a typed request body back into a JSON `Any` graph.
    static func jsonObject<T: Encodable>(from value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - Byte-level coding (the typed `Transport` path)

    /// Encode a typed request body straight to the wire bytes — no
    /// intermediate `JSONSerialization` `Any` graph.
    static func encodeData<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    /// Decode a typed value straight from the raw response bytes — no
    /// intermediate `JSONSerialization` `Any` graph.
    ///
    /// Keeping this next to `encoder`/`decoder` means encoding policy (key
    /// strategy, fragment handling) lives in exactly one place rather than
    /// being split between `JSONCoding` and the `Transport` extension.
    static func decodeData<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }
}
