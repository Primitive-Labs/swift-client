import Foundation

// MARK: - Typed filters and sorts

/// A filter on `Model`'s fields, built from the typed field tokens a
/// generated model carries on `fields`:
///
/// ```swift
/// let f = TaskRecord.fields
/// let open = try TaskRecord.query(where: .and([f.done.eq(false), f.priority.gte(3)]))
/// ```
///
/// Each token takes only the operators its field's kind has, with an operand
/// of the field's Swift type, so a misspelt field, a wrong operand or an
/// operator the kind lacks fails to compile. `documentFilter` is the
/// `DocumentFilter` the filter stands for, the same one the hand-written form
/// builds. For what the tokens cannot say (`$search`, a stored field the model
/// does not declare), wrap a `DocumentFilter` with ``init(unchecked:)``.
public struct ModelFilter<Model>: Sendable, Equatable {
    /// The filter as the `DocumentFilter` the query engine reads.
    public let documentFilter: DocumentFilter

    /// A filter the field tokens cannot say, written as a `DocumentFilter`.
    /// Nothing about it is checked against the model.
    public init(unchecked filter: DocumentFilter) {
        self.documentFilter = filter
    }

    /// Every one of `filters` matches: `["$and": [...]]`.
    public static func and(_ filters: [ModelFilter]) -> ModelFilter {
        ModelFilter(unchecked: ["$and": .array(filters.map { .object($0.documentFilter) })])
    }

    /// At least one of `filters` matches: `["$or": [...]]`.
    public static func or(_ filters: [ModelFilter]) -> ModelFilter {
        ModelFilter(unchecked: ["$or": .array(filters.map { .object($0.documentFilter) })])
    }

    /// One condition on one field.
    static func on(_ field: String, _ condition: JSONValue) -> ModelFilter {
        ModelFilter(unchecked: [field: condition])
    }

    /// One operator on one field: `[field: [op: operand]]`.
    static func on(_ field: String, _ op: String, _ operand: JSONValue) -> ModelFilter {
        ModelFilter(unchecked: [field: .object([op: operand])])
    }
}

/// One field of a sort on `Model`: ``asc(_:)`` or ``desc(_:)`` of a field
/// token. A typed query sends its sorts as `QueryOptions.sortOrder`, in the
/// order given.
public struct ModelSort<Model>: Sendable, Equatable {
    /// The field's name.
    public let field: String
    /// `1` ascending, `-1` descending.
    public let direction: Int

    /// Ascending by `field`.
    public static func asc<Field: SortableModelField>(_ field: Field) -> ModelSort where Field.Model == Model {
        ModelSort(field: field.name, direction: 1)
    }

    /// Descending by `field`.
    public static func desc<Field: SortableModelField>(_ field: Field) -> ModelSort where Field.Model == Model {
        ModelSort(field: field.name, direction: -1)
    }
}

// MARK: - Field tokens

/// A typed token for one field of `Model`, as a generated model's `fields`
/// carries it. The token's type fixes the operators the field takes and the
/// type of their operand.
public protocol ModelFieldToken: Sendable {
    /// The model the field belongs to.
    associatedtype Model
    /// The field's name (its current name, for a renamed field).
    var name: String { get }
}

/// A token whose field a typed query can sort by.
public protocol SortableModelField: ModelFieldToken {}

/// A token whose field compares with a value: equality, `$ne`, `$in`,
/// `$nin`, `$exists` and the null match.
public protocol EquatableModelField: ModelFieldToken {
    /// The Swift type of the field's value in a filter.
    associatedtype Operand
    /// `operand` as the filter's JSON value.
    static func json(_ operand: Operand) -> JSONValue
}

/// A token whose field takes the range operators.
public protocol RangeModelField: EquatableModelField {}

/// A token whose field takes the case-insensitive substring operators.
public protocol SubstringModelField: ModelFieldToken {}

public extension EquatableModelField {
    /// The field equals `value`: `[field: value]`.
    func eq(_ value: Operand) -> ModelFilter<Model> { .on(name, Self.json(value)) }
    /// The field is absent or null: `[field: null]`.
    func isNull() -> ModelFilter<Model> { .on(name, .null) }
    /// The field does not equal `value`: `["$ne": value]`.
    func ne(_ value: Operand) -> ModelFilter<Model> { .on(name, "$ne", Self.json(value)) }
    /// The field is one of `values`: `["$in": [...]]`.
    func `in`(_ values: [Operand]) -> ModelFilter<Model> { .on(name, "$in", .array(values.map(Self.json))) }
    /// The field is none of `values`: `["$nin": [...]]`.
    func notIn(_ values: [Operand]) -> ModelFilter<Model> { .on(name, "$nin", .array(values.map(Self.json))) }
    /// The field is present (`true`) or absent (`false`): `["$exists": ...]`.
    func exists(_ present: Bool = true) -> ModelFilter<Model> { .on(name, "$exists", .bool(present)) }
}

public extension RangeModelField {
    /// The field is greater than `value`: `["$gt": value]`.
    func gt(_ value: Operand) -> ModelFilter<Model> { .on(name, "$gt", Self.json(value)) }
    /// The field is at least `value`: `["$gte": value]`.
    func gte(_ value: Operand) -> ModelFilter<Model> { .on(name, "$gte", Self.json(value)) }
    /// The field is less than `value`: `["$lt": value]`.
    func lt(_ value: Operand) -> ModelFilter<Model> { .on(name, "$lt", Self.json(value)) }
    /// The field is at most `value`: `["$lte": value]`.
    func lte(_ value: Operand) -> ModelFilter<Model> { .on(name, "$lte", Self.json(value)) }
}

public extension SubstringModelField {
    /// The field (a member, for a string set) starts with `prefix`, ignoring case.
    func startsWith(_ prefix: String) -> ModelFilter<Model> { .on(name, "$startsWith", .string(prefix)) }
    /// The field (a member, for a string set) ends with `suffix`, ignoring case.
    func endsWith(_ suffix: String) -> ModelFilter<Model> { .on(name, "$endsWith", .string(suffix)) }
    /// The field (a member, for a string set) contains `text`, ignoring case.
    func containsText(_ text: String) -> ModelFilter<Model> { .on(name, "$containsText", .string(text)) }
}

/// A `string` field: a `String` operand, the range and substring operators.
public struct ModelStringField<Model>: RangeModelField, SubstringModelField, SortableModelField {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func json(_ operand: String) -> JSONValue { .string(operand) }
}

/// A `string` field whose values are the shared enum `Value`: it takes a
/// `String` or a `Value` operand, and the range and substring operators.
public struct ModelEnumField<Model, Value: RawRepresentable & Sendable>: RangeModelField, SubstringModelField,
    SortableModelField where Value.RawValue == String
{
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func json(_ operand: String) -> JSONValue { .string(operand) }

    /// The field equals `value`'s raw value.
    public func eq(_ value: Value) -> ModelFilter<Model> { eq(value.rawValue) }
    /// The field does not equal `value`'s raw value.
    public func ne(_ value: Value) -> ModelFilter<Model> { ne(value.rawValue) }
    /// The field is one of `values`' raw values.
    public func `in`(_ values: [Value]) -> ModelFilter<Model> { self.in(values.map(\.rawValue)) }
    /// The field is none of `values`' raw values.
    public func notIn(_ values: [Value]) -> ModelFilter<Model> { notIn(values.map(\.rawValue)) }
}

/// An `id` field: a `String` operand and the range operators.
public struct ModelIdField<Model>: RangeModelField, SortableModelField {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func json(_ operand: String) -> JSONValue { .string(operand) }
}

/// A `date` field: an ISO-8601 `String` operand, as the model stores it, and
/// the range operators.
public struct ModelDateField<Model>: RangeModelField, SortableModelField {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func json(_ operand: String) -> JSONValue { .string(operand) }
}

/// A `number` field: a `Double` operand and the range operators.
public struct ModelNumberField<Model>: RangeModelField, SortableModelField {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func json(_ operand: Double) -> JSONValue { .number(operand) }
}

/// A `boolean` field: a `Bool` operand, with no range or substring operators.
public struct ModelBooleanField<Model>: EquatableModelField, SortableModelField {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static func json(_ operand: Bool) -> JSONValue { .bool(operand) }
}

/// A comparison of a string set's member count, for
/// ``ModelStringSetField/size(_:_:)``: `f.tags.size(.gte(1), .lt(3))`.
public struct ModelSetSize: Sendable, Equatable {
    /// The comparison operator: `$eq`, `$ne`, `$gt`, `$gte`, `$lt` or `$lte`.
    public let op: String
    /// The count compared with.
    public let count: Int

    /// The set has exactly `count` members.
    public static func eq(_ count: Int) -> ModelSetSize { ModelSetSize(op: "$eq", count: count) }
    /// The set does not have `count` members.
    public static func ne(_ count: Int) -> ModelSetSize { ModelSetSize(op: "$ne", count: count) }
    /// The set has more than `count` members.
    public static func gt(_ count: Int) -> ModelSetSize { ModelSetSize(op: "$gt", count: count) }
    /// The set has at least `count` members.
    public static func gte(_ count: Int) -> ModelSetSize { ModelSetSize(op: "$gte", count: count) }
    /// The set has fewer than `count` members.
    public static func lt(_ count: Int) -> ModelSetSize { ModelSetSize(op: "$lt", count: count) }
    /// The set has at most `count` members.
    public static func lte(_ count: Int) -> ModelSetSize { ModelSetSize(op: "$lte", count: count) }
}

/// A `stringset` field: member operators (`contains`, `all`, `size`), the
/// substring operators on its members, `exists` and the null match. A set is
/// matched by its members, so it has no `eq`, `ne`, `in` or `notIn`.
public struct ModelStringSetField<Model>: SubstringModelField, SortableModelField {
    public let name: String
    public init(_ name: String) { self.name = name }

    /// The set holds `member` exactly: `["$contains": member]`.
    public func contains(_ member: String) -> ModelFilter<Model> { .on(name, "$contains", .string(member)) }
    /// The set holds every one of `members`: `["$all": [...]]`. An empty
    /// list matches nothing.
    public func all(_ members: [String]) -> ModelFilter<Model> {
        .on(name, "$all", .array(members.map { .string($0) }))
    }
    /// The set has `count` members: `["$size": count]`.
    public func size(_ count: Int) -> ModelFilter<Model> { .on(name, "$size", .number(Double(count))) }
    /// The set's member count meets every comparison given:
    /// `["$size": ["$gte": 1, "$lt": 3]]`. A second comparison with the same
    /// operator replaces the first.
    public func size(_ comparison: ModelSetSize, _ more: ModelSetSize...) -> ModelFilter<Model> {
        var comparisons: [String: JSONValue] = [:]
        for each in [comparison] + more { comparisons[each.op] = .number(Double(each.count)) }
        return .on(name, "$size", .object(comparisons))
    }
    /// The set is present (`true`) or absent (`false`): `["$exists": ...]`.
    public func exists(_ present: Bool = true) -> ModelFilter<Model> { .on(name, "$exists", .bool(present)) }
    /// The set is absent or null: `[field: null]`.
    public func isNull() -> ModelFilter<Model> { .on(name, .null) }
}

/// A JSON field (one that refs an object def): only whether it is present.
public struct ModelJSONField<Model>: ModelFieldToken {
    public let name: String
    public init(_ name: String) { self.name = name }

    /// The field is present (`true`) or absent (`false`): `["$exists": ...]`.
    public func exists(_ present: Bool = true) -> ModelFilter<Model> { .on(name, "$exists", .bool(present)) }
}
