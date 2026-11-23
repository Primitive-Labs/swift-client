import Foundation

// A db3 JSON field (#5899): a field whose `ref` names a `schemas/` object or
// list def (#6307), stored as canonical JSON text in a `string` field and read
// and written as the def's type. The value's root is an array when the def's
// compiled schema has `type` `array`, and an object otherwise. The canonical text is RFC 8785's (keys sorted by UTF-16
// code unit, no whitespace, strings and numbers as ECMAScript writes them),
// byte for byte what js-bao and the functions SDK write for the same value.
//
// A value is encoded through an internal tree that keeps an integer source
// as an integer, so an `Int` above 2^53 in magnitude is refused instead of
// rounded; nothing on this path goes through `JSONValue`, whose numbers are
// `Double`s. The validator gives each keyword a def a db3 field may use the
// meaning the server's validator gives it; string lengths count Unicode code
// points. Reads do not validate.

/// The def a db3 JSON field is bound to: its id (`schemas.<file>.<Name>`), its
/// compiled schema, and the Swift type its values decode as.
///
/// `primitive functions codegen --lang swift` declares one caseless
/// `Db3JSONDef_<file>_<Name>` enum per def a db3 field refs, in
/// `Primitive.generated.swift`; the models `swift-bao-codegen` writes name it
/// when they encode, validate and decode the field. The schema belongs to the
/// binding and not to the value type, so two defs whose Swift types are one
/// type each keep their own.
///
/// - Stability: beta
public protocol Db3JSONDef {
    /// The Swift type the field's value is read and written as.
    associatedtype Value: Codable & Equatable & Sendable
    /// The def's id, `schemas.<file>.<Name>`.
    static var id: String { get }
    /// The def's compiled JSON Schema as JSON text, every ref inlined: what a
    /// value is validated against before it is stored.
    static var schema: String { get }
}

/// Why a db3 JSON field's value was refused: JSON cannot hold a number above
/// 2^53 in magnitude or a non-finite one (`number`), a lone surrogate
/// (`surrogate`), a root that is not the def's kind, an object or an array
/// (`root`), a value of another kind (`type`), or the value does not match
/// the def (`schema`).
///
/// - Stability: beta
public enum Db3JSONRefusalKind: String, Sendable, Equatable {
    case number, surrogate, root, type, schema
}

/// A db3 JSON field's value was refused before anything was stored: it does
/// not match the def, or JSON cannot hold it exactly. `path` is where inside
/// the value (`value.lines[1].qty`), `reason` the sentence; the facts are
/// js-bao's `Db3JsonValueError`'s.
///
/// - Stability: beta
public struct Db3JSONValueError: Error, Sendable, Equatable, LocalizedError {
    /// `DB3_JSON_INVALID`, as js-bao's error carries it.
    public let code = "DB3_JSON_INVALID"
    /// The model's name.
    public let model: String
    /// The field's name.
    public let field: String
    /// The def's id, `schemas.<file>.<Name>`.
    public let def: String
    /// Where inside the value: `value`, `value.city`, `value.lines[1]`.
    public let path: String
    /// Why, as a sentence.
    public let reason: String
    /// The kind of refusal.
    public let kind: Db3JSONRefusalKind

    /// A refusal of `model`'s `field`, typed by `def`.
    public init(model: String, field: String, def: String, path: String, reason: String, kind: Db3JSONRefusalKind) {
        (self.model, self.field, self.def, self.path, self.reason, self.kind) = (model, field, def, path, reason, kind)
    }

    /// `<model>.<field> is typed by <def>: <reason>`.
    public var errorDescription: String? { "\(model).\(field) is typed by \(def): \(reason)" }
}

public extension Db3JSONDef {
    /// `value`'s stored text: its canonical JSON, validated against the def.
    ///
    /// - Throws: `Db3JSONValueError` when JSON cannot hold the value exactly
    ///   (a number above 2^53 in magnitude, a non-finite number, a root that
    ///   is not the def's kind: an array for a list def, an object otherwise)
    ///   or it does not match the def.
    /// - Stability: beta
    static func storedText(for value: Value, model: String, field: String) throws -> String {
        let compiled = Db3JSONSchemas.parsed(id: id, text: schema)
        let text: String
        do {
            text = try Db3JSONCanonical.text(Db3JSONTreeEncoder.encode(value, root: Db3JSONRoot(schema: compiled)))
        } catch let refusal as Db3JSONRefusal {
            throw Db3JSONValueError(model: model, field: field, def: id, path: refusal.path, reason: refusal.reason, kind: refusal.kind)
        }
        // A compiled schema that is not JSON text cannot check anything, so the value is refused, never passed unchecked.
        guard let compiled else {
            throw Db3JSONValueError(model: model, field: field, def: id, path: "value", reason: Db3JSONSchemas.unreadable, kind: .schema)
        }
        // Validated as stored: the value the text carries, as js-bao validates it.
        let issues = Db3JSONValidator.validate(schema: compiled, value: try Db3JSONParser.parse(text))
        if let first = issues.first {
            throw Db3JSONValueError(model: model, field: field, def: id, path: first.path, reason: issues.map(\.message).joined(separator: "; "), kind: .schema)
        }
        return text
    }

    /// `value`'s canonical JSON without validating it, or `nil` when JSON
    /// cannot hold it exactly. A generated model's `primitiveValues()` uses
    /// it; every save goes through `storedText(for:model:field:)`.
    ///
    /// - Stability: beta
    static func canonicalText(_ value: Value) -> String? {
        try? Db3JSONCanonical.text(Db3JSONTreeEncoder.encode(value, root: Db3JSONRoot(schema: Db3JSONSchemas.parsed(id: id, text: schema))))
    }

    /// A stored text as the field reads it: the decoded value, or `nil` when
    /// there is no text, its root is not the def's kind (an array for a list
    /// def, an object otherwise), or it does not decode as `Value` (logged
    /// once per model and field; the text stays in the model's `<field>Raw`).
    /// Reads check the root kind only and do not validate against the def.
    ///
    /// - Stability: beta
    static func value(fromStored text: String?, model: String, field: String) -> Value? {
        guard let text else { return nil }
        let root = Db3JSONRoot(schema: Db3JSONSchemas.parsed(id: id, text: schema))
        let opener: UInt8 = root == .array ? UInt8(ascii: "[") : UInt8(ascii: "{")
        let first = text.utf8.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        if first == opener, let value = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)) { return value }
        Db3JSONMisreads.report(model: model, field: field, def: id)
        return nil
    }
}

// MARK: - The tree

/// An object member's name, equal to another only when their code units are.
/// Swift's `String` equality and hashing treat canonically equivalent text
/// (`"\u{E9}"` and `"e\u{301}"`) as one; JSON, js-bao and the server do not.
struct Db3JSONKey: Hashable {
    let text: String
    init(_ text: String) { self.text = text }
    static func == (a: Db3JSONKey, b: Db3JSONKey) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) }
    func hash(into hasher: inout Hasher) {
        for byte in text.utf8 { hasher.combine(byte) }
    }
}

/// A JSON value as the encoder and parser hold it: an integer source stays an
/// integer, apart from a `Double`. An object keeps its keys in order. Strings
/// and member names compare by code unit, as JSON's do (`==` included).
indirect enum Db3JSONNode: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([Db3JSONNode])
    case object(keys: [String], values: [Db3JSONKey: Db3JSONNode])

    static func == (a: Db3JSONNode, b: Db3JSONNode) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.string(x), .string(y)): return x.utf8.elementsEqual(y.utf8)
        case let (.array(x), .array(y)): return x == y
        case let (.object(xKeys, x), .object(yKeys, y)): return xKeys.map(Db3JSONKey.init) == yKeys.map(Db3JSONKey.init) && x == y
        default: return false
        }
    }

    var members: (keys: [String], values: [Db3JSONKey: Db3JSONNode])? {
        if case let .object(keys, values) = self { return (keys, values) }
        return nil
    }

    subscript(key: String) -> Db3JSONNode? { members?.values[Db3JSONKey(key)] }

    var isObject: Bool { members != nil }

    var number: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var array: [Db3JSONNode]? {
        if case let .array(items) = self { return items }
        return nil
    }
}

/// A tree encodes as the value it holds, so a parsed value passes through the
/// encoder's number rule as a model's value does.
extension Db3JSONNode: Encodable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .int(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .double(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case let .object(keys, values):
            var container = encoder.container(keyedBy: Key.self)
            for key in keys { try container.encode(values[Db3JSONKey(key)]!, forKey: Key(stringValue: key)) }
        }
    }
}

/// Why JSON cannot hold a value exactly, with where.
struct Db3JSONRefusal: Error, Equatable {
    let kind: Db3JSONRefusalKind
    let path: String
    let reason: String
}

/// 2^53: the largest magnitude a db3 JSON value's number may have.
private let maxExact: Int64 = 1 << 53

/// A path as js-bao writes it: `value`, `.key` per member, `[i]` per item.
private func pathText(_ codingPath: [CodingKey]) -> String {
    codingPath.reduce("value") { path, key in
        key is Db3JSONIndexKey ? "\(path)[\(key.intValue ?? 0)]" : "\(path).\(key.stringValue)"
    }
}

/// The key of an array item, so a path writes it `[i]`.
struct Db3JSONIndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { String(intValue ?? 0) }
    init(_ index: Int) { intValue = index }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { self.intValue = intValue }
}

/// A slot the encoder fills: a value, or an object or array still being filled.
private final class Db3JSONSlot {
    enum Content {
        case value(Db3JSONNode)
        case object(Db3JSONObjectSlot)
        case array(Db3JSONArraySlot)
    }
    var content: Content?

    var node: Db3JSONNode {
        switch content {
        case let .value(node): return node
        case let .object(object):
            return .object(keys: object.keys, values: object.entries.mapValues(\.node))
        case let .array(array): return .array(array.items.map(\.node))
        case nil: return .object(keys: [], values: [:])
        }
    }
}

private final class Db3JSONObjectSlot {
    var keys: [String] = []
    var entries: [Db3JSONKey: Db3JSONSlot] = [:]

    func slot(_ key: String) -> Db3JSONSlot {
        if let slot = entries[Db3JSONKey(key)] { return slot }
        let slot = Db3JSONSlot()
        keys.append(key)
        entries[Db3JSONKey(key)] = slot
        return slot
    }
}

private final class Db3JSONArraySlot {
    var items: [Db3JSONSlot] = []
}

/// Number checks, shared by every container: the rule is applied to the value
/// the caller supplied, before any conversion to `Double`.
private enum Db3JSONNumbers {
    static func integer<T: BinaryInteger>(_ value: T, _ codingPath: [CodingKey]) throws -> Db3JSONNode {
        guard let wide = Int64(exactly: value), wide >= -maxExact, wide <= maxExact else {
            let path = pathText(codingPath)
            throw Db3JSONRefusal(kind: .number, path: path, reason: "\(path) is \(value); a db3 JSON value holds numbers up to 2^53 in magnitude (store a larger one as a string)")
        }
        return .int(wide)
    }

    static func double(_ value: Double, _ codingPath: [CodingKey]) throws -> Db3JSONNode {
        let path = pathText(codingPath)
        guard value.isFinite else {
            let text = value.isNaN ? "NaN" : value < 0 ? "-Infinity" : "Infinity"
            throw Db3JSONRefusal(kind: .number, path: path, reason: "\(path) is \(text); JSON holds finite numbers only")
        }
        guard abs(value) <= Double(maxExact) else {
            throw Db3JSONRefusal(kind: .number, path: path, reason: "\(path) is \(PrimitiveValue.jsNumberString(value)); a db3 JSON value holds numbers up to 2^53 in magnitude (store a larger one as a string)")
        }
        return .double(value)
    }

    /// A `Float` as `JSONEncoder` writes it: its own shortest digits.
    static func float(_ value: Float, _ codingPath: [CodingKey]) throws -> Db3JSONNode {
        try double(value.isFinite ? Double("\(value)") ?? Double(value) : Double(value), codingPath)
    }
}

/// The root kind a db3 JSON field's value takes: an array for a list def
/// (#6307), whose compiled schema has `type` `array`, and an object for any
/// other def.
enum Db3JSONRoot: Equatable {
    case object, array

    /// The root kind `schema`, a def's compiled schema, gives its field.
    init(schema: Db3JSONNode?) {
        self = schema?["type"] == .string("array") ? .array : .object
    }
}

/// Walks an `Encodable` value into a `Db3JSONNode`, applying the number rule.
enum Db3JSONTreeEncoder {
    /// The value's tree; its root must be `root`'s kind, an object unless asked for an array.
    static func encode<T: Encodable>(_ value: T, root: Db3JSONRoot = .object) throws -> Db3JSONNode {
        let slot = Db3JSONSlot()
        try value.encode(to: Db3JSONEncoder(slot: slot, codingPath: []))
        let node = slot.node
        let fits: Bool
        switch (root, node) {
        case (.array, .array): fits = true
        case (.object, .object): fits = true
        default: fits = false
        }
        guard fits else {
            let what: String
            switch node {
            case .array: what = "an array"
            case .object: what = "an object"
            case .null: what = "null"
            case .string: what = "string"
            case .bool: what = "boolean"
            default: what = "number"
            }
            let holds = root == .array ? "this db3 JSON field holds an array" : "a db3 JSON field holds an object"
            throw Db3JSONRefusal(kind: .root, path: "value", reason: "the value is \(what); \(holds)")
        }
        return node
    }
}

private struct Db3JSONEncoder: Encoder {
    let slot: Db3JSONSlot
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let object: Db3JSONObjectSlot
        if case let .object(existing) = slot.content {
            object = existing
        } else {
            object = Db3JSONObjectSlot()
            slot.content = .object(object)
        }
        return KeyedEncodingContainer(Db3JSONKeyedContainer<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let array: Db3JSONArraySlot
        if case let .array(existing) = slot.content {
            array = existing
        } else {
            array = Db3JSONArraySlot()
            slot.content = .array(array)
        }
        return Db3JSONUnkeyedContainer(array: array, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        Db3JSONSingleContainer(slot: slot, codingPath: codingPath)
    }
}

private struct Db3JSONKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let object: Db3JSONObjectSlot
    let codingPath: [CodingKey]

    private func put(_ node: Db3JSONNode, _ key: Key) { object.slot(key.stringValue).content = .value(node) }

    mutating func encodeNil(forKey key: Key) throws { put(.null, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { put(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { put(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { put(try Db3JSONNumbers.double(value, codingPath + [key]), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { put(try Db3JSONNumbers.float(value, codingPath + [key]), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { put(try Db3JSONNumbers.integer(value, codingPath + [key]), key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try value.encode(to: Db3JSONEncoder(slot: object.slot(key.stringValue), codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        Db3JSONEncoder(slot: object.slot(key.stringValue), codingPath: codingPath + [key]).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        Db3JSONEncoder(slot: object.slot(key.stringValue), codingPath: codingPath + [key]).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        Db3JSONEncoder(slot: object.slot("super"), codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        Db3JSONEncoder(slot: object.slot(key.stringValue), codingPath: codingPath + [key])
    }
}

private struct Db3JSONUnkeyedContainer: UnkeyedEncodingContainer {
    let array: Db3JSONArraySlot
    let codingPath: [CodingKey]
    var count: Int { array.items.count }

    private func next() -> (Db3JSONSlot, [CodingKey]) {
        let slot = Db3JSONSlot()
        let path = codingPath + [Db3JSONIndexKey(array.items.count)]
        array.items.append(slot)
        return (slot, path)
    }

    private func put(_ make: ([CodingKey]) throws -> Db3JSONNode) throws {
        let path = codingPath + [Db3JSONIndexKey(array.items.count)]
        let node = try make(path)
        let slot = Db3JSONSlot()
        slot.content = .value(node)
        array.items.append(slot)
    }

    mutating func encodeNil() throws { try put { _ in .null } }
    mutating func encode(_ value: Bool) throws { try put { _ in .bool(value) } }
    mutating func encode(_ value: String) throws { try put { _ in .string(value) } }
    mutating func encode(_ value: Double) throws { try put { try Db3JSONNumbers.double(value, $0) } }
    mutating func encode(_ value: Float) throws { try put { try Db3JSONNumbers.float(value, $0) } }
    mutating func encode(_ value: Int) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: Int8) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: Int16) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: Int32) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: Int64) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: UInt) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: UInt8) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: UInt16) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: UInt32) throws { try put { try Db3JSONNumbers.integer(value, $0) } }
    mutating func encode(_ value: UInt64) throws { try put { try Db3JSONNumbers.integer(value, $0) } }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let (slot, path) = next()
        try value.encode(to: Db3JSONEncoder(slot: slot, codingPath: path))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let (slot, path) = next()
        return Db3JSONEncoder(slot: slot, codingPath: path).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let (slot, path) = next()
        return Db3JSONEncoder(slot: slot, codingPath: path).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let (slot, path) = next()
        return Db3JSONEncoder(slot: slot, codingPath: path)
    }
}

private struct Db3JSONSingleContainer: SingleValueEncodingContainer {
    let slot: Db3JSONSlot
    let codingPath: [CodingKey]

    private func put(_ node: Db3JSONNode) { slot.content = .value(node) }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { put(try Db3JSONNumbers.double(value, codingPath)) }
    mutating func encode(_ value: Float) throws { put(try Db3JSONNumbers.float(value, codingPath)) }
    mutating func encode(_ value: Int) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: Int8) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: Int16) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: Int32) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: Int64) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: UInt) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: UInt8) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: UInt16) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: UInt32) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }
    mutating func encode(_ value: UInt64) throws { put(try Db3JSONNumbers.integer(value, codingPath)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: Db3JSONEncoder(slot: slot, codingPath: codingPath))
    }
}

// MARK: - The canonical writer

/// RFC 8785 text for a tree.
enum Db3JSONCanonical {
    static func text(_ node: Db3JSONNode) -> String {
        var out = ""
        write(node, into: &out)
        return out
    }

    private static func write(_ node: Db3JSONNode, into out: inout String) {
        switch node {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .int(value): out += String(value)
        case let .double(value): out += PrimitiveValue.jsNumberString(value)
        case let .string(value): quote(value, into: &out)
        case let .array(items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case let .object(keys, values):
            out += "{"
            for (i, key) in keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }).enumerated() {
                if i > 0 { out += "," }
                quote(key, into: &out)
                out += ":"
                write(values[Db3JSONKey(key)]!, into: &out)
            }
            out += "}"
        }
    }

    /// A string as ECMAScript's `JSON.stringify` writes it.
    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    static func quoted(_ text: String) -> String {
        var out = ""
        quote(text, into: &out)
        return out
    }
}

// MARK: - The parser

/// Reads JSON text into a tree, an integer literal kept as an integer when
/// it fits. A `\u` escape of a lone surrogate is refused (`surrogate`): a
/// Swift `String` cannot hold one.
enum Db3JSONParser {
    struct Malformed: Error {}

    static func parse(_ text: String) throws -> Db3JSONNode {
        try parse(text, substitutingLoneSurrogates: false).node
    }

    /// `text`'s tree; with `substitutingLoneSurrogates`, a lone surrogate
    /// reads as U+FFFD and its path is answered instead of refused.
    static func parse(_ text: String, substitutingLoneSurrogates: Bool) throws -> (node: Db3JSONNode, loneSurrogates: [String]) {
        var reader = Reader(units: Array(text.utf8), substitute: substitutingLoneSurrogates)
        reader.skipSpace()
        let node = try reader.value("value")
        reader.skipSpace()
        guard reader.at == reader.units.count else { throw Malformed() }
        return (node, reader.loneSurrogates)
    }

    private struct Reader {
        let units: [UInt8]
        let substitute: Bool
        var at = 0
        var loneSurrogates: [String] = []

        init(units: [UInt8], substitute: Bool) {
            (self.units, self.substitute) = (units, substitute)
        }

        mutating func skipSpace() {
            while at < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[at]) { at += 1 }
        }

        mutating func literal(_ word: String) throws {
            let bytes = Array(word.utf8)
            guard at + bytes.count <= units.count, Array(units[at..<at + bytes.count]) == bytes else { throw Malformed() }
            at += bytes.count
        }

        mutating func value(_ path: String) throws -> Db3JSONNode {
            guard at < units.count else { throw Malformed() }
            switch units[at] {
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "\""): return .string(try string(path))
            case UInt8(ascii: "["):
                at += 1
                var items: [Db3JSONNode] = []
                skipSpace()
                if at < units.count, units[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value("\(path)[\(items.count)]"))
                    skipSpace()
                    guard at < units.count else { throw Malformed() }
                    if units[at] == UInt8(ascii: ",") { at += 1; continue }
                    guard units[at] == UInt8(ascii: "]") else { throw Malformed() }
                    at += 1
                    return .array(items)
                }
            case UInt8(ascii: "{"):
                at += 1
                var keys: [String] = []
                var values: [Db3JSONKey: Db3JSONNode] = [:]
                skipSpace()
                if at < units.count, units[at] == UInt8(ascii: "}") { at += 1; return .object(keys: keys, values: values) }
                while true {
                    skipSpace()
                    guard at < units.count, units[at] == UInt8(ascii: "\"") else { throw Malformed() }
                    let key = try string(path)
                    skipSpace()
                    guard at < units.count, units[at] == UInt8(ascii: ":") else { throw Malformed() }
                    at += 1
                    skipSpace()
                    let member = try value("\(path).\(key)")
                    if values[Db3JSONKey(key)] == nil { keys.append(key) }
                    values[Db3JSONKey(key)] = member
                    skipSpace()
                    guard at < units.count else { throw Malformed() }
                    if units[at] == UInt8(ascii: ",") { at += 1; continue }
                    guard units[at] == UInt8(ascii: "}") else { throw Malformed() }
                    at += 1
                    return .object(keys: keys, values: values)
                }
            default:
                return try number()
            }
        }

        mutating func number() throws -> Db3JSONNode {
            let start = at
            var integral = true
            while at < units.count, let c = Optional(units[at]),
                  (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                    || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { integral = false }
                at += 1
            }
            guard at > start, let text = String(bytes: units[start..<at], encoding: .utf8) else { throw Malformed() }
            if integral, let value = Int64(text) { return .int(value) }
            guard let value = Double(text) else { throw Malformed() }
            return .double(value)
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= units.count, let text = String(bytes: units[at..<at + 4], encoding: .utf8), let value = UInt32(text, radix: 16) else {
                throw Malformed()
            }
            at += 4
            return value
        }

        mutating func string(_ path: String) throws -> String {
            at += 1
            var bytes: [UInt8] = []
            while at < units.count {
                let c = units[at]
                at += 1
                if c == UInt8(ascii: "\"") {
                    // Checked with Foundation, read with the standard library: `String(bytes:encoding:)` drops a
                    // leading U+FEFF, which is a character of the value (ECMAScript's `\s` matches it).
                    guard String(bytes: bytes, encoding: .utf8) != nil else { throw Malformed() }
                    return String(decoding: bytes, as: UTF8.self)
                }
                guard c == UInt8(ascii: "\\") else { bytes.append(c); continue }
                guard at < units.count else { throw Malformed() }
                let escape = units[at]
                at += 1
                switch escape {
                case UInt8(ascii: "\""): bytes.append(0x22)
                case UInt8(ascii: "\\"): bytes.append(0x5C)
                case UInt8(ascii: "/"): bytes.append(0x2F)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        let mark = at
                        if at + 2 <= units.count, units[at] == UInt8(ascii: "\\"), units[at + 1] == UInt8(ascii: "u") {
                            at += 2
                            let low = try hex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                at = mark
                                code = 0xD800
                            }
                        }
                    }
                    guard let scalar = Unicode.Scalar(code) else {
                        if substitute {
                            loneSurrogates.append(path)
                            bytes.append(contentsOf: [0xEF, 0xBF, 0xBD])
                            continue
                        }
                        throw Db3JSONRefusal(kind: .surrogate, path: path, reason: "\(path) holds a lone surrogate, which JSON text cannot carry")
                    }
                    bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw Malformed()
                }
            }
            throw Malformed()
        }
    }
}

// MARK: - Patterns

/// A def's `pattern`, which js-bao and the server compile as an ECMAScript
/// regular expression with the `u` flag, rewritten so `NSRegularExpression`
/// (ICU) gives it the same meaning. ICU reads the same syntax differently:
/// `\d`, `\w` and `\b` are Unicode-wide there and ASCII in ECMAScript, `\s`
/// and `.` see other line and space characters, `$` also matches before a
/// final line break, and `[` and `&&` inside a class are set operations. Each
/// is written out as ECMAScript means it; everything else passes unchanged.
enum Db3JSONPattern {
    private static let word = "A-Za-z0-9_"
    /// ECMAScript's WhiteSpace and LineTerminator.
    private static let space = #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#
    private static let boundary = "(?:(?<=[\(word)])(?![\(word)])|(?<![\(word)])(?=[\(word)]))"
    private static let notBoundary = "(?:(?<=[\(word)])(?=[\(word)])|(?<![\(word)])(?![\(word)]))"

    /// `pattern` as an ICU pattern with ECMAScript's meaning.
    static func icu(_ pattern: String) -> String {
        let s = Array(pattern.unicodeScalars)
        var out = ""
        var i = 0
        var inClass = false
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                let next = s[i + 1]
                i += 2
                switch next {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "D": out += "[^0-9]"
                case "w": out += inClass ? word : "[\(word)]"
                case "W": out += "[^\(word)]"
                case "s": out += inClass ? space : "[\(space)]"
                case "S": out += "[^\(space)]"
                case "b": out += inClass ? #"\x{08}"# : boundary
                case "B" where !inClass: out += notBoundary
                // ECMAScript's `\v` is U+000B alone; ICU's is every vertical space, line breaks included.
                case "v": out += #"\x{0B}"#
                case "u" where i < s.count && s[i] == "{":
                    out += #"\x"# // `\u{1F600}` is ICU's `\x{1F600}`; the braces follow as written.
                default:
                    out += "\\"
                    out.unicodeScalars.append(next)
                }
                continue
            }
            i += 1
            if inClass {
                switch c {
                case "]": inClass = false; out += "]"
                case "[": out += #"\["#
                case "&": out += #"\&"#
                default: out.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "[":
                // ECMAScript's `[]` matches nothing and `[^]` anything; ICU reads neither.
                if i < s.count, s[i] == "]" { out += "(?!)"; i += 1; continue }
                if i + 1 < s.count, s[i] == "^", s[i + 1] == "]" { out += "(?s:.)"; i += 2; continue }
                inClass = true
                out += "["
                if i < s.count, s[i] == "^" { out += "^"; i += 1 }
            case ".": out += #"[^\n\r\x{2028}\x{2029}]"#
            case "$": out += #"\z"#
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}

// MARK: - The validator

/// One way a value does not match a schema: where and the sentence.
struct Db3JSONIssue: Equatable {
    let path: String
    let message: String
}

/// Each compiled schema, parsed once per def id.
enum Db3JSONSchemas {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (text: String, node: Db3JSONNode)] = [:]

    /// The reason a value is refused when its def's compiled schema is not JSON text of an object.
    static let unreadable = "the def's compiled schema is not JSON text of an object, so no value can be checked against it; regenerate the shared file with primitive functions codegen --lang swift"

    /// The compiled schema `text` as a tree, or nil when it is not JSON text of an object: a binding that does not
    /// parse is never read as the empty schema, which would accept every value.
    static func parsed(id: String, text: String) -> Db3JSONNode? {
        if let hit = lock.withLock({ cache[id] }), hit.text.utf8.elementsEqual(text.utf8) { return hit.node }
        guard let node = try? Db3JSONParser.parse(text), node.isObject else { return nil }
        lock.withLock { cache[id] = (text, node) }
        return node
    }
}

/// The fields whose stored text did not decode, each logged once.
enum Db3JSONMisreads {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reported: Set<String> = []
    private static let logger = createLogger(level: .warn, scope: "Db3JSON")

    static func report(model: String, field: String, def: String) {
        let first = lock.withLock { reported.insert("\(model)\u{0}\(field)").inserted }
        guard first else { return }
        logger.warn("\(model).\(field): a stored value does not decode as \(def); it reads as nil (its text stays readable through the model's raw accessor)")
    }

    /// Whether `model`'s `field` has been logged.
    static func wasReported(model: String, field: String) -> Bool {
        lock.withLock { reported.contains("\(model)\u{0}\(field)") }
    }
}

/// The server's `validateJsonSchema`, at its full level, over the keywords a
/// def a db3 field refs may use; js-bao's `validateDb3Json` sentence for sentence.
enum Db3JSONValidator {
    private static let oneOfSiblings = ["type", "properties", "required", "additionalProperties", "items", "enum"]

    /// Every way `value` does not match `schema`, in the server's order; empty when it matches.
    static func validate(schema: Db3JSONNode, value: Db3JSONNode) -> [Db3JSONIssue] {
        var issues: [Db3JSONIssue] = []
        walk(value, schema, "value", &issues)
        return issues
    }

    /// A value as `String(value)` and `Array.prototype.join` write it.
    private static func joinText(_ node: Db3JSONNode) -> String {
        switch node {
        case .null: return ""
        case let .bool(value): return value ? "true" : "false"
        case let .int(value): return String(value)
        case let .double(value): return PrimitiveValue.jsNumberString(value)
        case let .string(value): return value
        case let .array(items): return items.map(joinText).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// A value as `JSON.stringify` writes it; `undefined` for none.
    private static func stringify(_ node: Db3JSONNode?) -> String {
        guard let node else { return "undefined" }
        return Db3JSONCanonical.text(node)
    }

    private static func isScalarTag(_ node: Db3JSONNode) -> Bool {
        switch node {
        case .string, .int, .double, .bool: return true
        default: return false
        }
    }

    /// `===` over JSON values: scalars by value, numbers numerically.
    private static func same(_ a: Db3JSONNode?, _ b: Db3JSONNode?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if let x = a.number, let y = b.number { return x == y }
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.string(x), .string(y)): return x.utf8.elementsEqual(y.utf8)
        default: return false
        }
    }

    private static func isType(_ value: Db3JSONNode, _ type: Db3JSONNode) -> Bool {
        switch type.string {
        case "array": return value.array != nil
        case "object": return value.isObject
        case "string": return value.string != nil
        case "number": return value.number != nil
        case "integer":
            guard let number = value.number else { return false }
            return number.isFinite && number.rounded(.towardZero) == number
        case "boolean": if case .bool = value { return true }; return false
        case "null": return value == .null
        default: return true
        }
    }

    /// An object's own keys in the order JavaScript enumerates them: array
    /// indices ascending, then the rest in order.
    private static func ownKeys(_ keys: [String]) -> [String] {
        let isIndex = { (key: String) -> Bool in
            guard let value = UInt64(key), value < 4_294_967_295 else { return false }
            return String(value) == key
        }
        return keys.filter(isIndex).sorted { UInt64($0)! < UInt64($1)! } + keys.filter { !isIndex($0) }
    }

    private struct Union {
        let discriminant: String
        let members: [(tag: Db3JSONNode?, schema: Db3JSONNode)]
    }

    /// The literal tags of each member's properties, in property order.
    private static func tags(_ member: Db3JSONNode, consts: Bool) -> [(String, Db3JSONNode)] {
        guard let properties = member["properties"]?.members else { return [] }
        return properties.keys.compactMap { name in
            guard let sub = properties.values[Db3JSONKey(name)], sub.isObject else { return nil }
            if let values = sub["enum"]?.array, values.count == 1, isScalarTag(values[0]) { return (name, values[0]) }
            if consts, let constant = sub["const"], isScalarTag(constant) { return (name, constant) }
            return nil
        }
    }

    private static func union(_ objects: [Db3JSONNode], consts: Bool, requireRequired: Bool) -> Union? {
        let literals = objects.map { tags($0, consts: consts) }
        let lookup = literals.map { Dictionary($0.map { (Db3JSONKey($0.0), $0.1) }, uniquingKeysWith: { first, _ in first }) }
        let candidates = literals[0].map(\.0).filter { name in
            guard lookup.allSatisfy({ $0[Db3JSONKey(name)] != nil }) else { return false }
            if requireRequired {
                guard objects.allSatisfy({ ($0["required"]?.array ?? []).contains(.string(name)) }) else { return false }
            }
            // Distinct by code unit, as JavaScript's `Set` of the tags' texts is.
            return Set(lookup.map { Db3JSONKey(stringify($0[Db3JSONKey(name)])) }).count == lookup.count
        }
        guard candidates.count == 1 else { return nil }
        return Union(discriminant: candidates[0], members: objects.enumerated().map { (lookup[$0.offset][Db3JSONKey(candidates[0])], $0.element) })
    }

    /// The discriminant of a clean enum-tagged `oneOf`, or nil.
    private static func enumTaggedOneOf(_ schema: Db3JSONNode) -> Union? {
        guard let members = schema["oneOf"]?.array, members.count >= 2,
              members.allSatisfy({ $0.isObject && $0["type"] == .string("object") }),
              !oneOfSiblings.contains(where: { schema[$0] != nil })
        else { return nil }
        return union(members, consts: false, requireRequired: false)
    }

    /// Any other `oneOf` whose object members each require a distinct scalar tag, or nil.
    private static func requiredTagOneOf(_ members: [Db3JSONNode]) -> Union? {
        let objects = members.filter { $0.isObject && $0["type"] == .string("object") }
        guard objects.count >= 2, objects.count == members.count else { return nil }
        return union(objects, consts: true, requireRequired: true)
    }

    /// The bounds of one node; true when an array is past `maxItems`, so nothing under it is walked.
    private static func bounds(_ value: Db3JSONNode, _ schema: Db3JSONNode, _ path: String, _ issues: inout [Db3JSONIssue]) -> Bool {
        let number = { (key: String) -> Double? in schema[key]?.number }
        let text = { (key: String) -> String in schema[key].map(joinText) ?? "" }
        if let value = value.number {
            if let minimum = number("minimum"), value < minimum { issues.append(.init(path: path, message: "\(path) must be >= \(text("minimum"))")) }
            if let maximum = number("maximum"), value > maximum { issues.append(.init(path: path, message: "\(path) must be <= \(text("maximum"))")) }
        }
        if let string = value.string {
            // Unicode code points, not UTF-16 code units and not grapheme clusters.
            let length = Double(string.unicodeScalars.count)
            let tooShort = number("minLength").map { length < $0 } ?? false
            let tooLong = number("maxLength").map { length > $0 } ?? false
            if tooShort { issues.append(.init(path: path, message: "\(path) must be at least \(text("minLength")) characters")) }
            if tooLong { issues.append(.init(path: path, message: "\(path) must be at most \(text("maxLength")) characters")) }
            if let pattern = schema["pattern"]?.string, !tooShort, !tooLong {
                if let regex = try? NSRegularExpression(pattern: Db3JSONPattern.icu(pattern)) {
                    let range = NSRange(string.startIndex..., in: string)
                    if regex.firstMatch(in: string, range: range) == nil {
                        issues.append(.init(path: path, message: "\(path) must match the pattern \(pattern)"))
                    }
                } else {
                    issues.append(.init(path: path, message: "\(path) cannot be checked: the schema's pattern \(Db3JSONCanonical.quoted(pattern)) is not a valid regular expression"))
                }
            }
        }
        if let items = value.array {
            let count = Double(items.count)
            if let minItems = number("minItems"), count < minItems { issues.append(.init(path: path, message: "\(path) must have at least \(text("minItems")) items")) }
            if let maxItems = number("maxItems"), count > maxItems {
                issues.append(.init(path: path, message: "\(path) must have at most \(text("maxItems")) items"))
                return true
            }
        }
        return false
    }

    private static func walk(_ value: Db3JSONNode, _ schema: Db3JSONNode, _ path: String, _ issues: inout [Db3JSONIssue]) {
        guard schema.isObject else { return }
        let fail = { (at: String, message: String, issues: inout [Db3JSONIssue]) in issues.append(.init(path: at, message: message)) }

        if let union = enumTaggedOneOf(schema) {
            guard value.isObject else { return fail(path, "\(path) must be object", &issues) }
            _ = bounds(value, schema, path, &issues)
            let tag = value[union.discriminant]
            guard let matched = union.members.first(where: { same($0.tag, tag) }) else {
                let expected = union.members.map { stringify($0.tag) }.joined(separator: ", ")
                return fail("\(path).\(union.discriminant)", "\(path).\(union.discriminant) \(stringify(tag)) matches no case (expected one of \(expected))", &issues)
            }
            return walk(value, matched.schema, path, &issues)
        }

        let types: [Db3JSONNode]
        switch schema["type"] {
        case let .array(list)?: types = list
        case let .string(type)? where !type.isEmpty: types = [.string(type)]
        default: types = []
        }
        if !types.isEmpty, !types.contains(where: { isType(value, $0) }) {
            return fail(path, "\(path) must be \(types.map(joinText).joined(separator: " or "))", &issues)
        }
        if let members = schema["enum"]?.array, !members.contains(where: { same($0, value) }) {
            return fail(path, "\(path) must be one of \(members.map(joinText).joined(separator: ", "))", &issues)
        }
        if bounds(value, schema, path, &issues) { return }

        if let object = value.members {
            let properties = schema["properties"]?.members ?? (keys: [], values: [:])
            for key in schema["required"]?.array ?? [] {
                let name = joinText(key)
                if object.values[Db3JSONKey(name)] == nil { fail("\(path).\(name)", "\(path).\(name) is required", &issues) }
            }
            for key in properties.keys {
                if let member = object.values[Db3JSONKey(key)] { walk(member, properties.values[Db3JSONKey(key)]!, "\(path).\(key)", &issues) }
            }
            if schema["additionalProperties"] == .bool(false) {
                for key in ownKeys(object.keys) where properties.values[Db3JSONKey(key)] == nil {
                    fail("\(path).\(key)", "\(path).\(key) is not allowed", &issues)
                }
            }
            // A map's value schema: each key `properties` does not declare, in own-key order.
            if let valueSchema = schema["additionalProperties"], valueSchema.isObject {
                for key in ownKeys(object.keys) where properties.values[Db3JSONKey(key)] == nil {
                    walk(object.values[Db3JSONKey(key)]!, valueSchema, "\(path).\(key)", &issues)
                }
            }
        }
        if let items = value.array, let itemSchema = schema["items"], itemSchema.isObject {
            for (i, item) in items.enumerated() { walk(item, itemSchema, "\(path)[\(i)]", &issues) }
        }

        if let oneOf = schema["oneOf"]?.array, !oneOf.isEmpty {
            if let tagged = requiredTagOneOf(oneOf) {
                guard value.isObject else { return fail(path, "\(path) must be object", &issues) }
                let tag = value[tagged.discriminant]
                guard let matched = tagged.members.first(where: { same($0.tag, tag) }) else {
                    let expected = tagged.members.map { stringify($0.tag) }.joined(separator: ", ")
                    return fail("\(path).\(tagged.discriminant)", "\(path).\(tagged.discriminant) \(stringify(tag)) matches no case (expected one of \(expected))", &issues)
                }
                return walk(value, matched.schema, path, &issues)
            }
            let matching = oneOf.filter { member in
                var trial: [Db3JSONIssue] = []
                walk(value, member, path, &trial)
                return trial.isEmpty
            }.count
            if matching == 0 { fail(path, "\(path) matches no member of oneOf", &issues) }
            if matching > 1 { fail(path, "\(path) matches more than one member of oneOf", &issues) }
        }
    }
}
