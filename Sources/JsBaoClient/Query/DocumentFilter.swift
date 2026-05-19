import Foundation

/// MongoDB-style filter operators for querying BaoModel records.
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

/// Options for query operations. Cursor-based pagination is opaque
/// and works alongside arbitrary sort orders — mirrors js-bao's
/// `QueryOptions.uniqueStartKey` + `direction` pair.
public struct QueryOptions: Sendable {
    /// Sort order (single-field, or multi-field whose primary field
    /// name comes first alphabetically). For guaranteed multi-field
    /// ordering, prefer `sortOrder` — Swift dict literals don't
    /// preserve insertion order, so `[rank: 1, id: 1]` and
    /// `[id: 1, rank: 1]` compile to the same value.
    public var sort: [String: Int]?

    /// Ordered multi-field sort: `[("rank", -1), ("id", 1)]` means
    /// "rank DESC, id ASC" (primary-first). Use this whenever sort
    /// order matters for cursor pagination. Takes precedence over
    /// `sort` when both are set.
    public var sortOrder: [(String, Int)]?
    /// Maximum number of results per page.
    public var limit: Int?
    /// Offset-based pagination — DEPRECATED.
    ///
    /// Offset is unstable in CRDT-backed datasets: concurrent inserts
    /// from another client can shift the rows that come "before
    /// offset N" between two queries, causing the same row to appear
    /// twice (insert) or be skipped (delete) across page boundaries.
    /// Use `cursor` + `direction` instead — the cursor anchors to a
    /// unique key value and survives concurrent mutations to other
    /// rows. js-bao deliberately doesn't expose offset for the same
    /// reason; this field is the only cross-language outlier.
    @available(*, deprecated, message: "Offset is unstable under concurrent inserts in CRDT-backed docs. Use `cursor` + `direction` for stable pagination.")
    public var offset: Int?

    /// Opaque cursor from a previous `queryPaged` call. Pass
    /// `result.nextCursor` or `result.prevCursor` back here to advance
    /// / rewind. `nil` means start from the first page.
    public var cursor: String?

    /// Direction to walk through the sorted results from the cursor
    /// position. Default `.forward`.
    public var direction: CursorDirection

    /// Scope a cross-doc query to records from specific docs in a
    /// shared SQLite store. Equivalent to merging
    /// `["_meta_doc_id": ["$in": docs]]` into the filter but more
    /// ergonomic — matches js-bao browser's `options.documents`
    /// (browser.js:1146). `nil` applies no scope. An explicit empty
    /// list matches nothing (mirrors js-bao's `WHERE 1 = 0`).
    public var documents: [String]?

    /// Field-level projection. Keys are field names; values are `1`
    /// (include) or `0` (exclude). Cannot mix modes — either every
    /// value is 1 or every value is 0. `id` is always returned
    /// regardless. Matches js-bao browser's `options.projection`.
    /// `nil` returns every field.
    public var projection: [String: Int]?

    public init(
        sort: [String: Int]? = nil,
        sortOrder: [(String, Int)]? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        cursor: String? = nil,
        direction: CursorDirection = .forward,
        documents: [String]? = nil,
        projection: [String: Int]? = nil
    ) {
        self.sort = sort
        self.sortOrder = sortOrder
        self.limit = limit
        self.offset = offset
        self.cursor = cursor
        self.direction = direction
        self.documents = documents
        self.projection = projection
    }
}

/// Ordering spec for aggregation results. `field` can name either a
/// group-by column or one of the operations' `resultKey` (e.g. "n" if
/// a COUNT operation was declared with `outputField: "n"`).
/// `direction` is 1 for ASC, -1 for DESC. Mirrors js-bao browser
/// aggregation's `sort` object.
public struct AggregateSort: Sendable {
    public var field: String
    public var direction: Int

    public init(field: String, direction: Int = 1) {
        self.field = field
        self.direction = direction
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
    /// Optional ordering applied to the grouped results. Enables top-N
    /// aggregates when paired with `limit`.
    public var sort: AggregateSort?
    /// Optional cap on returned groups.
    public var limit: Int?

    public init(
        groupBy: [String] = [],
        operations: [AggregateOperation],
        filter: DocumentFilter? = nil,
        sort: AggregateSort? = nil,
        limit: Int? = nil
    ) {
        self.groupBy = groupBy
        self.operations = operations
        self.filter = filter
        self.sort = sort
        self.limit = limit
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
