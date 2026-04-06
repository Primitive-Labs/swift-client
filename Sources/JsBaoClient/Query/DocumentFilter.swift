import Foundation

/// MongoDB-style filter operators for querying Collection records.
///
/// Usage:
/// ```swift
/// // Simple equality
/// let filter: DocumentFilter = ["completed": true]
///
/// // Operators
/// let filter: DocumentFilter = ["priority": ["$lte": 3]]
///
/// // Text search
/// let filter: DocumentFilter = ["title": ["$containsText": "urgent"]]
///
/// // Logical
/// let filter: DocumentFilter = ["$or": [["status": "done"], ["priority": ["$gte": 5]]]]
/// ```
public typealias DocumentFilter = [String: Any]

/// Options for query operations.
public struct QueryOptions: Sendable {
    /// Sort order: field name -> 1 (ascending) or -1 (descending)
    public var sort: [String: Int]?
    /// Maximum number of results
    public var limit: Int?
    /// Number of results to skip
    public var offset: Int?

    public init(sort: [String: Int]? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }
}

/// Options for aggregate operations.
public struct AggregateOptions {
    /// Fields to group by
    public var groupBy: [String]
    /// Aggregation operations to perform
    public var operations: [AggregateOperation]
    /// Optional filter to apply before aggregating
    public var filter: DocumentFilter?

    public init(groupBy: [String] = [], operations: [AggregateOperation], filter: DocumentFilter? = nil) {
        self.groupBy = groupBy
        self.operations = operations
        self.filter = filter
    }
}

/// A single aggregation operation.
public struct AggregateOperation: Sendable {
    public enum OperationType: String, Sendable {
        case count
        case sum
        case avg
        case min
        case max
    }

    public var type: OperationType
    /// Field to aggregate (not required for count)
    public var field: String?
    /// Output field name (defaults to type name or "type_field")
    public var outputField: String?

    public init(type: OperationType, field: String? = nil, outputField: String? = nil) {
        self.type = type
        self.field = field
        self.outputField = outputField
    }

    /// The name used in results
    public var resultKey: String {
        if let outputField { return outputField }
        if let field { return "\(type.rawValue)_\(field)" }
        return type.rawValue
    }
}
