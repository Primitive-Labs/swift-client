import Foundation

// MARK: - DoDb direct-record types
//
// Mirror the js-bao `connectDoDb` / `DOClientEngine` request & response
// shapes (`packages/js-bao/src/initialize-do.ts` +
// `engines/cloudflare/DOClientEngine.ts` + `createDocumentDO.ts`). The
// Swift `DoDb` handle (`API/DoDb.swift`) routes every method through the
// same `makeRequest` closure `DatabasesAPI` uses, hitting the per-database
// `/databases/{id}/records` endpoint with a `?docId={id}` query param —
// the exact route the JS engine builds from its `endpoint` + `docId`.
//
// Records are schemaless on this path (`Record<string, any>` in JS), so
// filters, query/find results, and record data are typed as `JSONValue`.

// MARK: Filter

/// A direct-record filter. Mirrors js-bao's `DocumentFilter` — an
/// arbitrary object mixing plain field equality with `$`-prefixed operator
/// objects (`$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`, `$in`, `$nin`,
/// `$exists`, `$contains`, `$all`, `$size`, `$startsWith`, `$endsWith`,
/// `$containsText`) and the logical operators `$and` / `$or`.
///
/// Because the operator grammar is open-ended and nests arbitrarily, the
/// filter is carried as a `JSONValue` object rather than a closed struct —
/// the same decision the JS side makes (`DocumentFilter = Record<string, any>`).
public typealias DoDbFilter = JSONValue

// MARK: Query options

/// Sort specification for a query: ordered field → direction pairs.
/// Mirrors JS `SortSpec` (`{ [field]: 1 | -1 }`). Encoded as a JSON object;
/// `[String: SortDirection]` would lose ordering, so callers pass an ordered
/// array which is serialized into the object preserving insertion order.
public struct DoDbSort: Encodable, Sendable {
    public var fields: [(field: String, direction: SortDirection)]

    public init(_ fields: [(field: String, direction: SortDirection)]) {
        self.fields = fields
    }

    /// Single-field convenience.
    public init(_ field: String, _ direction: SortDirection) {
        self.fields = [(field, direction)]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: JSONCodingKey.self)
        for (field, direction) in fields {
            try container.encode(direction.rawValue, forKey: JSONCodingKey(stringValue: field))
        }
    }
}

/// Projection spec: field → `1` (include) or `0` (exclude). Mirrors JS
/// `ProjectionSpec`.
public struct DoDbProjection: Encodable, Sendable {
    public enum Mode: Int, Encodable, Sendable {
        case include = 1
        case exclude = 0
    }

    public var fields: [(field: String, mode: Mode)]

    public init(_ fields: [(field: String, mode: Mode)]) {
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: JSONCodingKey.self)
        for (field, mode) in fields {
            try container.encode(mode.rawValue, forKey: JSONCodingKey(stringValue: field))
        }
    }
}

/// Relationship type for an `include` clause. Mirrors JS
/// `IncludeSpec.type`.
public enum DoDbIncludeType: String, Encodable, Sendable {
    case refersTo
    case hasMany
    case refersToMany
}

/// Include spec for loading related records alongside a query. Mirrors
/// js-bao's `IncludeSpec` field-for-field (max nesting depth 3, enforced
/// server-side). The loaded records land under `_related` on each parent.
public struct DoDbInclude: Encodable, Sendable {
    /// Target model type name.
    public var model: String
    /// Relationship kind.
    public var type: DoDbIncludeType
    /// `refersTo`: field on the parent holding the target ID.
    public var sourceField: String?
    /// `hasMany`: field on the target holding the parent ID.
    public var foreignKey: String?
    /// `hasMany`: field on the parent to match (default: `"id"`).
    public var localField: String?
    /// Key name in `_related` (default: the model name).
    public var alias: String?
    /// Field projection on the related records.
    public var projection: DoDbProjection?
    /// Per-parent limit (`hasMany` only).
    public var limit: Int?
    /// Sort order (`hasMany` only).
    public var sort: DoDbSort?
    /// Additional filter on the related records.
    public var filter: DoDbFilter?
    /// Nested includes (max depth 3).
    public var include: [DoDbInclude]?

    public init(
        model: String,
        type: DoDbIncludeType,
        sourceField: String? = nil,
        foreignKey: String? = nil,
        localField: String? = nil,
        alias: String? = nil,
        projection: DoDbProjection? = nil,
        limit: Int? = nil,
        sort: DoDbSort? = nil,
        filter: DoDbFilter? = nil,
        include: [DoDbInclude]? = nil
    ) {
        self.model = model
        self.type = type
        self.sourceField = sourceField
        self.foreignKey = foreignKey
        self.localField = localField
        self.alias = alias
        self.projection = projection
        self.limit = limit
        self.sort = sort
        self.filter = filter
        self.include = include
    }

    private enum CodingKeys: String, CodingKey {
        case model, type, sourceField, foreignKey, localField
        case alias = "as"
        case projection, limit, sort, filter, include
    }
}

/// Options for a direct-record `query`. Mirrors js-bao's `QueryOptions`.
public struct DoDbQueryOptions: Encodable, Sendable {
    /// Sort order.
    public var sort: DoDbSort?
    /// Field projection — return only the named fields.
    public var projection: DoDbProjection?
    /// Restrict results to specific document IDs (string or array).
    public var documents: [String]?
    /// Page size.
    public var limit: Int?
    /// Base64-encoded cursor (`nextCursor` / `prevCursor` from a prior page).
    public var uniqueStartKey: String?
    /// Pagination direction (`.ascending` forward, `.descending` backward).
    public var direction: SortDirection?
    /// Related-data loading.
    public var include: [DoDbInclude]?

    public init(
        sort: DoDbSort? = nil,
        projection: DoDbProjection? = nil,
        documents: [String]? = nil,
        limit: Int? = nil,
        uniqueStartKey: String? = nil,
        direction: SortDirection? = nil,
        include: [DoDbInclude]? = nil
    ) {
        self.sort = sort
        self.projection = projection
        self.documents = documents
        self.limit = limit
        self.uniqueStartKey = uniqueStartKey
        self.direction = direction
        self.include = include
    }
}

/// Paginated direct-record query result. Mirrors js-bao's `PaginatedResult<T>`
/// for the DoDb path (`data` / `hasMore` / `nextCursor` / `prevCursor`) —
/// distinct from the app-layer `PaginatedResult` (items/cursor), so it gets
/// its own type. Records are schemaless `JSONValue` objects.
public struct DoDbQueryResult: Decodable, Sendable, Equatable {
    public let data: [JSONValue]
    public let hasMore: Bool
    public let nextCursor: String?
    public let prevCursor: String?

    public init(data: [JSONValue], hasMore: Bool = false, nextCursor: String? = nil, prevCursor: String? = nil) {
        self.data = data
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.prevCursor = prevCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent([JSONValue].self, forKey: .data) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        prevCursor = try c.decodeIfPresent(String.self, forKey: .prevCursor)
    }

    private enum CodingKeys: String, CodingKey {
        case data, hasMore, nextCursor, prevCursor
    }
}

// MARK: Write options

/// Options for `DoDb.save`. Mirrors js-bao's `SaveOptions`.
public struct DoDbSaveOptions: Sendable {
    /// Atomic StringSet seeds applied on this write.
    public var stringSets: [String: [String]]?
    /// Fail if a record with this ID already exists (insert-only).
    public var ifNotExists: Bool?
    /// Conditional write — only proceed if the existing record matches.
    public var condition: DoDbFilter?
    /// Upsert key: match/replace on this field instead of `id`.
    public var upsertOn: String?

    public init(
        stringSets: [String: [String]]? = nil,
        ifNotExists: Bool? = nil,
        condition: DoDbFilter? = nil,
        upsertOn: String? = nil
    ) {
        self.stringSets = stringSets
        self.ifNotExists = ifNotExists
        self.condition = condition
        self.upsertOn = upsertOn
    }
}

/// Options for `DoDb.patch`. Mirrors js-bao's `PatchOptions`.
public struct DoDbPatchOptions: Sendable {
    /// Atomic StringSet updates applied alongside the patch.
    public var stringSets: [String: [String]]?
    /// Conditional patch — only proceed if the existing record matches.
    public var condition: DoDbFilter?

    public init(stringSets: [String: [String]]? = nil, condition: DoDbFilter? = nil) {
        self.stringSets = stringSets
        self.condition = condition
    }
}

/// Conditional-write guard shared by `delete`, `increment`, `addToSet`,
/// `removeFromSet`. Mirrors js-bao's `WriteCondition`.
public struct DoDbWriteCondition: Sendable {
    public var condition: DoDbFilter?

    public init(condition: DoDbFilter? = nil) {
        self.condition = condition
    }
}

// MARK: Aggregation

/// A groupBy clause: a plain field name, or a StringSet-membership check.
/// Mirrors js-bao's `GroupByField` (`string | StringSetMembership`).
public enum DoDbGroupBy: Encodable, Sendable {
    case field(String)
    case stringSetMembership(field: String, contains: String)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .field(name):
            var c = encoder.singleValueContainer()
            try c.encode(name)
        case let .stringSetMembership(field, contains):
            var c = encoder.container(keyedBy: MembershipKeys.self)
            try c.encode(field, forKey: .field)
            try c.encode(contains, forKey: .contains)
        }
    }

    private enum MembershipKeys: String, CodingKey {
        case field, contains
    }
}

/// One aggregation operation. Mirrors js-bao's `AggregationOperation`.
/// `field` is required for `sum`/`avg`/`min`/`max`, ignored for `count`.
public struct DoDbAggregationOperation: Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        case count, sum, avg, min, max
    }

    public var type: Kind
    public var field: String?

    public init(type: Kind, field: String? = nil) {
        self.type = type
        self.field = field
    }
}

/// Sort applied to aggregation output. Mirrors js-bao's
/// `AggregationOptions.sort` — `field` may be an operation result name like
/// `"count"` or `"sum_amount"`.
public struct DoDbAggregationSort: Encodable, Sendable {
    public var field: String
    public var direction: SortDirection

    public init(field: String, direction: SortDirection) {
        self.field = field
        self.direction = direction
    }
}

/// Options for `DoDb.aggregate`. Mirrors js-bao's `AggregationOptions`.
public struct DoDbAggregationOptions: Encodable, Sendable {
    public var groupBy: [DoDbGroupBy]
    public var operations: [DoDbAggregationOperation]
    public var filter: DoDbFilter?
    public var limit: Int?
    public var sort: DoDbAggregationSort?

    public init(
        groupBy: [DoDbGroupBy],
        operations: [DoDbAggregationOperation],
        filter: DoDbFilter? = nil,
        limit: Int? = nil,
        sort: DoDbAggregationSort? = nil
    ) {
        self.groupBy = groupBy
        self.operations = operations
        self.filter = filter
        self.limit = limit
        self.sort = sort
    }
}

// MARK: Batch

/// A single operation in a `DoDb.batch` request. Mirrors js-bao's
/// `BatchOperation`. All operations run in one server-side transaction.
public struct DoDbBatchOperation: Encodable, Sendable {
    public enum Op: String, Encodable, Sendable {
        case save, patch, delete, increment, addToSet, removeFromSet
    }

    public var op: Op
    public var modelName: String
    public var id: String?
    /// Record data for `save` / `patch`.
    public var data: [String: JSONValue]?
    /// StringSet payload for `addToSet` / `removeFromSet` (or seeds on `save`).
    public var stringSets: [String: [String]]?
    /// Numeric deltas for `increment`.
    public var fields: [String: Double]?
    /// Insert-only guard for `save`.
    public var ifNotExists: Bool?
    /// Conditional-write guard.
    public var condition: DoDbFilter?
    /// Upsert key for `save`.
    public var upsertOn: String?

    public init(
        op: Op,
        modelName: String,
        id: String? = nil,
        data: [String: JSONValue]? = nil,
        stringSets: [String: [String]]? = nil,
        fields: [String: Double]? = nil,
        ifNotExists: Bool? = nil,
        condition: DoDbFilter? = nil,
        upsertOn: String? = nil
    ) {
        self.op = op
        self.modelName = modelName
        self.id = id
        self.data = data
        self.stringSets = stringSets
        self.fields = fields
        self.ifNotExists = ifNotExists
        self.condition = condition
        self.upsertOn = upsertOn
    }
}

/// Result of one operation in a `DoDb.batch`. Mirrors js-bao's
/// `BatchOperationResult`. `values` is present for `increment` ops; `error`
/// is set when that single op failed.
public struct DoDbBatchOperationResult: Decodable, Sendable, Equatable {
    public let success: Bool
    public let id: String
    public let error: String?
    public let values: [String: Double]?
}

// MARK: Index management

/// An index entry returned by `DoDb.listIndexes`. Mirrors js-bao's
/// `IndexEntry` (row shape from the DO `_indexes` table).
public struct DoDbIndexEntry: Decodable, Sendable, Equatable {
    public let modelName: String
    public let fieldName: String
    public let fieldType: String
    /// `1` when the index enforces uniqueness, `0` otherwise (SQLite int).
    public let isUnique: Int
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case fieldName = "field_name"
        case fieldType = "field_type"
        case isUnique = "is_unique"
        case createdAt = "created_at"
    }
}

/// A composite unique-constraint entry returned by
/// `DoDb.listUniqueConstraints`. Mirrors js-bao's `UniqueConstraintEntry`.
public struct DoDbUniqueConstraintEntry: Decodable, Sendable, Equatable {
    public let modelName: String
    public let constraintName: String
    public let fields: [String]
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case constraintName = "constraint_name"
        case fields
        case createdAt = "created_at"
    }
}

/// Desired index state for one model in a `syncIndexes` batch. Mirrors one
/// element of js-bao's `SyncIndexesRequest.models`.
public struct DoDbModelSyncState: Encodable, Sendable {
    public struct Index: Encodable, Sendable {
        public var fieldName: String
        public var fieldType: String
        public var unique: Bool

        public init(fieldName: String, fieldType: String = "string", unique: Bool = false) {
            self.fieldName = fieldName
            self.fieldType = fieldType
            self.unique = unique
        }
    }

    public struct UniqueConstraint: Encodable, Sendable {
        public var name: String
        public var fields: [String]

        public init(name: String, fields: [String]) {
            self.name = name
            self.fields = fields
        }
    }

    public var modelName: String
    public var indexes: [Index]
    public var uniqueConstraints: [UniqueConstraint]

    public init(modelName: String, indexes: [Index] = [], uniqueConstraints: [UniqueConstraint] = []) {
        self.modelName = modelName
        self.indexes = indexes
        self.uniqueConstraints = uniqueConstraints
    }
}

// MARK: - Coding helpers

/// Dynamic string coding key, used to encode field-keyed objects (sort /
/// projection) whose keys aren't known at compile time.
struct JSONCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
