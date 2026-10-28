import Foundation

/// MongoDB-style filter operators for querying BaoModel records.
///
/// Values are `JSONValue`, so literals read the same as they do in JS:
///
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
///
/// A value held in a variable needs its `JSONValue` case spelled out, since
/// only literals convert implicitly:
///
/// ```swift
/// let filter: DocumentFilter = ["authorId": .string(authorId)]
/// let filter: DocumentFilter = ["id": ["$in": .array(ids.map { .string($0) })]]
/// ```
public typealias DocumentFilter = [String: JSONValue]

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

    /// Scope the read to these db3s: `documents` under its db3 name. A db3 it
    /// names that is not resident on this device (its rows not loaded here)
    /// is refused `DB3_NOT_RESIDENT`, where `documents` leaves it out. Both
    /// set with different values is refused `.invalidArgument`.
    public var db3: [String]?

    /// `offset` was removed in #2367: offset paging is unstable in
    /// CRDT-backed datasets, because a concurrent insert from another client
    /// shifts the rows before offset N and makes the same row appear twice or
    /// be skipped across a page boundary. Page with `cursor` + `direction`
    /// instead — the cursor anchors to a unique key value and survives
    /// concurrent mutations to other rows. js-bao never exposed offset for the
    /// same reason, so this also closes the last cross-language outlier.
    public init(
        sort: [String: Int]? = nil,
        sortOrder: [(String, Int)]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        direction: CursorDirection = .forward,
        documents: [String]? = nil,
        projection: [String: Int]? = nil,
        db3: [String]? = nil
    ) {
        self.sort = sort
        self.sortOrder = sortOrder
        self.limit = limit
        self.cursor = cursor
        self.direction = direction
        self.documents = documents
        self.projection = projection
        self.db3 = db3
    }

}

/// The documents a read is scoped to, from its `documents` and `db3` forms:
/// `nil` for none, refused `.invalidArgument` when both name different ids.
func resolvedDocumentScope(documents: [String]?, db3: [String]?) throws -> [String]? {
    guard let db3 else { return documents }
    guard let documents else { return db3 }
    guard Set(documents) == Set(db3) else {
        throw JsBaoError(
            code: .invalidArgument,
            message: "A read names both `documents` and `db3` with different ids; `db3` is `documents` under its db3 "
                + "name, so pass one of them.",
            details: ["documents": .array(documents.map { .string($0) }), "db3": .array(db3.map { .string($0) })]
        )
    }
    return documents
}

extension QueryOptions {
    /// The documents the read is scoped to: `documents` or its `db3` form.
    func documentScope() throws -> [String]? {
        try resolvedDocumentScope(documents: documents, db3: db3)
    }

    /// The sort a paged query runs: `sortOrder` when set, else `sort`'s
    /// fields in name order, with `id` ascending appended as the tiebreaker
    /// when the sort lacks it, as js-bao's `extractSortFields` does.
    var pagingSort: (fields: [String], directions: [Int]) {
        var fields: [String]
        var directions: [Int]
        if let ordered = sortOrder, !ordered.isEmpty {
            fields = ordered.map { $0.0 }
            directions = ordered.map { $0.1 == -1 ? -1 : 1 }
        } else if let sort, !sort.isEmpty {
            fields = sort.keys.sorted()
            directions = fields.map { sort[$0] == -1 ? -1 : 1 }
        } else {
            fields = []
            directions = []
        }
        if !fields.contains("id") {
            fields.append("id")
            directions.append(1)
        }
        return (fields, directions)
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

/// A calendar period a `.date` field can be grouped by.
public enum DatePeriod: String, Sendable, Equatable {
    case month, quarter, year
}

/// A group-by clause: a plain field, a StringSet-membership check
/// (`{ field, contains }`), or a calendar period of a date field
/// (`{ field, period }`). Mirrors js-bao's `GroupByField`
/// (`string | StringSetMembership | DatePeriodGroup`). A bare string literal
/// is a field, so existing `groupBy: ["category"]` call sites keep working; a
/// stringset *field* name groups by member value (facet), and
/// `.stringSetMembership` groups by whether the set contains a value.
///
/// `.datePeriod` groups a `.date` or `.string` field by the calendar month,
/// quarter or year of its stored text, with no time-zone conversion. Its key
/// in a row's `group` is `<field>_<period>` (`dueDate_month`), holding
/// `YYYY-MM`, `YYYY-Qn` or `YYYY`; a missing value, or text that does not
/// begin `YYYY-MM`, is `.null`. A field of any other type throws
/// `JsBaoError(.invalidArgument)` before anything is read.
public enum AggregateGroupBy: Sendable, Equatable, ExpressibleByStringLiteral {
    case field(String)
    case stringSetMembership(field: String, contains: String)
    case datePeriod(field: String, period: DatePeriod)
    public init(stringLiteral value: String) { self = .field(value) }
}

/// Options for aggregate operations.
///
/// `aggregate` answers one row per group, as js-bao does. Each row holds the
/// `groupBy` values under `group`, keyed by the field name (or
/// `has_<field>_<contains>` for a membership check, `<field>_<period>` for a
/// period level) with the value as stored,
/// and every operation's value beside it under its `resultKey`:
///
/// ```swift
/// ["group": ["category": "work"], "count": 8, "sum_estimatedHours": 40]
/// ```
///
/// An aggregate with no `groupBy` is one row with an empty `group`. Two
/// levels that would share a key in `group` (the same field twice, or a field
/// named like a membership key) throw `JsBaoError(.invalidArgument)`,
/// `Ambiguous aggregation group keys: '<key>' names more than one groupBy
/// level`, before anything is read.
/// An operation whose `resultKey` is `group` throws
/// `JsBaoError(.invalidArgument)` too: that key holds the group values.
public struct AggregateOptions {
    /// Fields to group by
    public var groupBy: [AggregateGroupBy]
    /// Aggregation operations to perform
    public var operations: [AggregateOperation]
    /// Optional filter to apply before aggregating
    public var filter: DocumentFilter?
    /// Optional ordering applied to the grouped results. Enables top-N
    /// aggregates when paired with `limit`.
    public var sort: AggregateSort?
    /// Optional cap on returned groups.
    public var limit: Int?
    /// Aggregate only these documents, with exactly the meaning `documents`
    /// has on `QueryOptions` (#3760). `nil` applies no scope of its own; an
    /// explicit EMPTY list matches nothing.
    ///
    /// On a model bound to ONE document the option NARROWS rather than
    /// replaces: it is ANDed with the bound document exactly as `query` and
    /// `count` AND theirs, so a member of A asked for `[B]` answers no
    /// groups. Appended last, and defaulted, so every existing call site
    /// compiles unchanged.
    public var documents: [String]?
    /// Aggregate only these db3s: `documents` under its db3 name, refusing a
    /// db3 not resident on this device `DB3_NOT_RESIDENT` (see
    /// ``QueryOptions/db3``).
    public var db3: [String]?

    public init(
        groupBy: [AggregateGroupBy] = [],
        operations: [AggregateOperation],
        filter: DocumentFilter? = nil,
        sort: AggregateSort? = nil,
        limit: Int? = nil,
        documents: [String]? = nil,
        db3: [String]? = nil
    ) {
        self.groupBy = groupBy
        self.operations = operations
        self.filter = filter
        self.sort = sort
        self.limit = limit
        self.documents = documents
        self.db3 = db3
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
