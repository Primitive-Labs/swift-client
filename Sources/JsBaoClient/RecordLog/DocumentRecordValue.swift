import Foundation

/// A value a model-free write (`client.documents.records(_:)`) carries in a
/// field of a format-3 document: a string, a number, a boolean, `null`, a
/// string set, or a change that edits a string set in place.
///
/// Literals build the first five, so a write reads as data:
///
/// ```swift
/// try records.put("Note", ["title": "Groceries", "n": 1, "done": false, "tags": ["home", "weekly"], "due": nil])
/// try records.patch("Note", id: id, ["tags": .setChange(add: ["urgent"])])
/// ```
///
/// A string set's members are distinct by their UTF-8 bytes, as the room and
/// the JS client keep them: `stringSet(["a", "a"])` is one member, and the two
/// spellings of "é" (U+00E9, and U+0065 U+0301) are two. Equality compares
/// strings the same way, so two values are equal only when they write the same
/// bytes.
public enum DocumentRecordValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    /// The record's members become exactly these (a member another writer adds
    /// concurrently is kept). On a create, the members added.
    case stringSet([String])
    /// Edit the record's set in place: `clear` removes every member it holds,
    /// then `remove` the ones named, then `add` adds. A create takes `add` only.
    /// A change of nothing still makes the field a string set.
    case setChange(add: [String] = [], remove: [String] = [], clear: Bool = false)

    /// A string set's members, each once, in byte order; `[]` for any other value.
    var members: [String] {
        if case .stringSet(let members) = self { return recordLogCanonicalStringSet(members) }
        return []
    }

    /// The value as a field holds it: a string set as its members, a set
    /// change as `{ $add, $remove, $clear }`.
    var json: JSONValue {
        switch self {
        case .string(let text): return .string(text)
        case .number(let number): return .number(number)
        case .bool(let flag): return .bool(flag)
        case .null: return .null
        case .stringSet: return .array(members.map { .string($0) })
        case .setChange(let add, let remove, let clear):
            return .object([
                "$add": .array(add.map { .string($0) }), "$remove": .array(remove.map { .string($0) }), "$clear": .bool(clear),
            ])
        }
    }
}

extension DocumentRecordValue: Equatable {
    /// Equal when the two write the same bytes: strings and members are
    /// compared by their UTF-8 bytes, never by canonical equivalence, and a
    /// string set by its distinct members.
    public static func == (a: DocumentRecordValue, b: DocumentRecordValue) -> Bool {
        let same = { (x: [String], y: [String]) in x.count == y.count && zip(x, y).allSatisfy { recordLogSameText($0, $1) } }
        switch (a, b) {
        case (.string(let x), .string(let y)): return recordLogSameText(x, y)
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        case (.stringSet, .stringSet): return same(a.members, b.members)
        case (.setChange(let addA, let removeA, let clearA), .setChange(let addB, let removeB, let clearB)):
            return clearA == clearB && same(recordLogCanonicalStringSet(addA), recordLogCanonicalStringSet(addB))
                && same(recordLogCanonicalStringSet(removeA), recordLogCanonicalStringSet(removeB))
        default: return false
        }
    }
}

extension DocumentRecordValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension DocumentRecordValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension DocumentRecordValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension DocumentRecordValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension DocumentRecordValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension DocumentRecordValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: String...) { self = .stringSet(elements) }
}
