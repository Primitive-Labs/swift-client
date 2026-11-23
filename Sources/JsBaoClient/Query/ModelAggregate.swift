import Foundation

// MARK: - Typed aggregate keys and rows

/// A `groupBy` level of an aggregate on `Model`, from a field token:
/// `f.category.group`, `f.tags.has("red")`, `f.dueDate.period(.month)`. A
/// row answers the level's value through ``AggregateRow/subscript(_:)-group``
/// as `Value?`.
///
/// A plain level on a `stringset` field is a facet: a row per member, whose
/// value is that member, a `String`.
public protocol AggregateGroupLevel<Model>: Sendable {
    /// The model the level groups.
    associatedtype Model
    /// The level as `AggregateOptions.groupBy` takes it.
    var level: AggregateGroupBy { get }
}

/// An operation of an aggregate on `Model`: `f.hours.sum()`,
/// `f.priority.max()`, `TaskRecord.aggregateCount()`. A row answers its
/// result through ``AggregateRow/subscript(_:)-result`` as `Value?`.
public protocol AggregateOperationKey<Model>: Sendable {
    /// The model the operation reads.
    associatedtype Model
    /// The operation as `AggregateOptions.operations` takes it.
    var operation: AggregateOperation { get }
}

/// A `groupBy` level whose rows hold a `Value` under ``key`` in `group`.
public struct AggregateGroupKey<Model, Value: Sendable>: AggregateGroupLevel {
    public let level: AggregateGroupBy
    let decode: @Sendable (JSONValue) -> Value?

    init(_ level: AggregateGroupBy, decode: @escaping @Sendable (JSONValue) -> Value?) {
        self.level = level
        self.decode = decode
    }

    /// The key the level's value takes in a row's `group`: the field name,
    /// `has_<field>_<member>` or `<field>_<period>`.
    public var key: String { QueryTranslator.aggregationGroupKey(level) }
}

/// An operation whose rows hold a `Value` under ``key``.
public struct AggregateResultKey<Model, Value: Sendable>: AggregateOperationKey {
    public let operation: AggregateOperation
    let decode: @Sendable (JSONValue) -> Value?

    init(_ operation: AggregateOperation, decode: @escaping @Sendable (JSONValue) -> Value?) {
        self.operation = operation
        self.decode = decode
    }

    /// The key the result takes in a row: `outputField` when given, else
    /// `count` or `<op>_<field>`.
    public var key: String { operation.resultKey }

    /// The number of records in each group, under `outputField` or `count`.
    public static func count(as outputField: String? = nil) -> AggregateResultKey<Model, Int> {
        AggregateResultKey<Model, Int>(AggregateOperation(type: .count, outputField: outputField), decode: AggregateValue.int)
    }
}

/// One row of a typed aggregate: each requested level's value and each
/// operation's result, read through the key the request named.
///
/// ```swift
/// let category = f.category.group, hours = f.estimatedHours.sum()
/// for row in try TaskRecord.aggregate(groupBy: [category], operations: [hours]) {
///     print(row[category] ?? "none", row[hours] ?? 0)
/// }
/// ```
///
/// A key the request did not name answers `nil`. ``raw`` is the row as
/// `aggregate(_:)` answers it.
public struct AggregateRow<Model>: Sendable, Equatable {
    /// The row as `aggregate(_:)` answers it.
    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    /// The value of the group level `key` in this row, `nil` for a null
    /// group or a level the request did not name.
    public subscript<Value>(_ key: AggregateGroupKey<Model, Value>) -> Value? {
        guard case .object(let group)? = raw[QueryTranslator.groupRowKey], let value = group[key.key] else { return nil }
        return key.decode(value)
    }

    /// The result of the operation `key` in this row, `nil` when the
    /// operation had none (`sum` of no values) or was not requested.
    public subscript<Value>(_ key: AggregateResultKey<Model, Value>) -> Value? {
        guard let value = raw[key.key] else { return nil }
        return key.decode(value)
    }
}

/// How a typed key reads a row's JSON value.
enum AggregateValue {
    @Sendable static func string(_ value: JSONValue) -> String? { value.stringValue }
    @Sendable static func double(_ value: JSONValue) -> Double? { value.numberValue }
    @Sendable static func int(_ value: JSONValue) -> Int? {
        guard let number = value.numberValue, number.isFinite, number == number.rounded() else { return nil }
        return Int(exactly: number)
    }
    /// A boolean level's value: SQLite answers `0` or `1`.
    @Sendable static func bool(_ value: JSONValue) -> Bool? { value.rowBoolValue }
    /// A membership level's value: `"true"` or `"false"`.
    @Sendable static func membership(_ value: JSONValue) -> Bool? {
        switch value {
        case .string("true"): return true
        case .string("false"): return false
        default: return value.rowBoolValue
        }
    }
}

// MARK: - Levels and operations from field tokens

public extension ModelStringField {
    /// Group by the field's value.
    var group: AggregateGroupKey<Model, String> { AggregateGroupKey(.field(name), decode: AggregateValue.string) }
    /// Group by the calendar `period` of the field's text (`YYYY-MM`, `YYYY-Qn`, `YYYY`).
    func period(_ period: DatePeriod) -> AggregateGroupKey<Model, String> {
        AggregateGroupKey(.datePeriod(field: name, period: period), decode: AggregateValue.string)
    }
    /// The smallest value in each group.
    func min(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .min, field: name, outputField: outputField), decode: AggregateValue.string)
    }
    /// The largest value in each group.
    func max(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .max, field: name, outputField: outputField), decode: AggregateValue.string)
    }
}

public extension ModelEnumField {
    /// Group by the field's stored string.
    var group: AggregateGroupKey<Model, String> { AggregateGroupKey(.field(name), decode: AggregateValue.string) }
    /// The smallest stored string in each group.
    func min(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .min, field: name, outputField: outputField), decode: AggregateValue.string)
    }
    /// The largest stored string in each group.
    func max(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .max, field: name, outputField: outputField), decode: AggregateValue.string)
    }
}

public extension ModelIdField {
    /// Group by the field's value.
    var group: AggregateGroupKey<Model, String> { AggregateGroupKey(.field(name), decode: AggregateValue.string) }
    /// The smallest value in each group.
    func min(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .min, field: name, outputField: outputField), decode: AggregateValue.string)
    }
    /// The largest value in each group.
    func max(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .max, field: name, outputField: outputField), decode: AggregateValue.string)
    }
}

public extension ModelDateField {
    /// Group by the field's stored text.
    var group: AggregateGroupKey<Model, String> { AggregateGroupKey(.field(name), decode: AggregateValue.string) }
    /// Group by the calendar `period` of the field (`YYYY-MM`, `YYYY-Qn`, `YYYY`).
    func period(_ period: DatePeriod) -> AggregateGroupKey<Model, String> {
        AggregateGroupKey(.datePeriod(field: name, period: period), decode: AggregateValue.string)
    }
    /// The earliest value in each group.
    func min(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .min, field: name, outputField: outputField), decode: AggregateValue.string)
    }
    /// The latest value in each group.
    func max(as outputField: String? = nil) -> AggregateResultKey<Model, String> {
        AggregateResultKey(AggregateOperation(type: .max, field: name, outputField: outputField), decode: AggregateValue.string)
    }
}

public extension ModelNumberField {
    /// Group by the field's value.
    var group: AggregateGroupKey<Model, Double> { AggregateGroupKey(.field(name), decode: AggregateValue.double) }
    /// The sum of the field in each group.
    func sum(as outputField: String? = nil) -> AggregateResultKey<Model, Double> {
        AggregateResultKey(AggregateOperation(type: .sum, field: name, outputField: outputField), decode: AggregateValue.double)
    }
    /// The mean of the field in each group.
    func avg(as outputField: String? = nil) -> AggregateResultKey<Model, Double> {
        AggregateResultKey(AggregateOperation(type: .avg, field: name, outputField: outputField), decode: AggregateValue.double)
    }
    /// The smallest value in each group.
    func min(as outputField: String? = nil) -> AggregateResultKey<Model, Double> {
        AggregateResultKey(AggregateOperation(type: .min, field: name, outputField: outputField), decode: AggregateValue.double)
    }
    /// The largest value in each group.
    func max(as outputField: String? = nil) -> AggregateResultKey<Model, Double> {
        AggregateResultKey(AggregateOperation(type: .max, field: name, outputField: outputField), decode: AggregateValue.double)
    }
}

public extension ModelBooleanField {
    /// Group by the field's value.
    var group: AggregateGroupKey<Model, Bool> { AggregateGroupKey(.field(name), decode: AggregateValue.bool) }
}

public extension ModelStringSetField {
    /// Group by member: a row per member the sets hold, whose value is that
    /// member (a facet), not the stored set.
    var group: AggregateGroupKey<Model, String> { AggregateGroupKey(.field(name), decode: AggregateValue.string) }
    /// Group by whether the set holds `member`.
    func has(_ member: String) -> AggregateGroupKey<Model, Bool> {
        AggregateGroupKey(.stringSetMembership(field: name, contains: member), decode: AggregateValue.membership)
    }
}
