import Foundation

// MARK: - Databases: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/databasesApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. Opaque,
// platform-untouched blobs (the CEL-context dict, operation definitions,
// query results) are typed as `JSONValue` (see JSONValue.swift).

// MARK: Database metadata

/// Metadata for a single database. Mirrors JS `DatabaseInfo`.
public struct DatabaseInfo: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let title: String
    public let databaseType: String?
    /// Legacy wire name for the CEL-context dict. Deprecated in favor of
    /// `celContext`; kept so stored CEL expressions referencing
    /// `database.metadata.<key>` keep resolving.
    public let metadata: JSONValue?
    /// User-facing name for the CEL context dict. Values are referenced
    /// from CEL access rules as `database.celContext.<key>` (or the legacy
    /// `database.metadata.<key>`) and from filter JSON as
    /// `$database.celContext.<key>`.
    public let celContext: JSONValue?
    public let permission: String?
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String

    private enum CodingKeys: String, CodingKey {
        case databaseId, title, databaseType, metadata, celContext
        case permission, createdBy, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        databaseId = try c.decode(String.self, forKey: .databaseId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        databaseType = try c.decodeIfPresent(String.self, forKey: .databaseType)
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        celContext = try c.decodeIfPresent(JSONValue.self, forKey: .celContext)
        permission = try c.decodeIfPresent(String.self, forKey: .permission)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt) ?? ""
    }
}

// MARK: Create / update inputs

/// Parameters for `create`. `metadata` is the legacy alias for `celContext` —
/// both encode to the same server field; set one or the other.
public struct CreateDatabaseParams: Encodable, Sendable {
    public var title: String
    public var databaseType: String
    /// Legacy alias for `celContext`.
    public var metadata: [String: JSONValue]?
    /// Key-value pairs attached as the database's CEL context.
    public var celContext: [String: JSONValue]?

    public init(
        title: String,
        databaseType: String,
        metadata: [String: JSONValue]? = nil,
        celContext: [String: JSONValue]? = nil
    ) {
        self.title = title
        self.databaseType = databaseType
        self.metadata = metadata
        self.celContext = celContext
    }
}

/// Fields to change on `update`. Omit a property to leave it unchanged.
/// `databaseType` is clearable — pass `.clear` to null it out.
public struct UpdateDatabaseParams: Encodable, Sendable {
    public var title: String?
    /// `.value("type")` to set, `.clear` to remove, omit to leave as-is.
    public var databaseType: Updatable<String>?

    public init(title: String? = nil, databaseType: Updatable<String>? = nil) {
        self.title = title
        self.databaseType = databaseType
    }
}

// MARK: Permissions

/// A user's permission entry on a database.
public struct DatabasePermissionEntry: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let userId: String
    public let permission: String
    public let grantedAt: String
    public let grantedBy: String
    public let userName: String?
    public let userEmail: String?
}

/// A group's permission entry on a database.
public struct DatabaseGroupPermissionEntry: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let groupType: String
    public let groupId: String
    public let permission: String
    public let grantedAt: String
    public let grantedBy: String
}

/// Parameters for `addManager`.
public struct AddManagerParams: Encodable, Sendable {
    public var userId: String

    public init(userId: String) {
        self.userId = userId
    }
}

/// Parameters for the deprecated `grantPermission`. Only `"manager"` is
/// accepted. Prefer `AddManagerParams` + `addManager`.
public struct GrantPermissionParams: Encodable, Sendable {
    public var userId: String
    /// Only `"manager"` is accepted server-side.
    public var permission: String

    public init(userId: String, permission: String = "manager") {
        self.userId = userId
        self.permission = permission
    }
}

/// Parameters for granting a group permission. Only `"manager"` is supported
/// for groups.
public struct GrantDatabaseGroupPermissionParams: Encodable, Sendable {
    public var groupType: String
    public var groupId: String
    /// Only `"manager"` is accepted server-side.
    public var permission: String

    public init(groupType: String, groupId: String, permission: String = "manager") {
        self.groupType = groupType
        self.groupId = groupId
        self.permission = permission
    }
}

/// Result of `transferOwnership`.
public struct DatabaseOwnershipTransferResult: Decodable, Sendable {
    public let success: Bool
    public let message: String
    public let previousOwnerId: String
    public let newOwnerId: String
}

// MARK: CEL context

/// Response from `getCelContext` (and the deprecated `getMetadata`). The same
/// dict is returned under both the legacy `metadata` key and the current
/// `celContext` key.
public struct CelContextResult: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let metadata: JSONValue?
    public let celContext: JSONValue?
}

// MARK: Operations

/// Kind of a database operation.
public enum DatabaseOperationType: String, Codable, Sendable {
    case query
    case mutation
    case count
    case aggregate
}

/// Metadata for a registered database operation. Mirrors JS
/// `DatabaseOperationInfo`. `definition` and `params` are opaque structured
/// blobs typed as `JSONValue`.
public struct DatabaseOperationInfo: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let name: String
    public let type: DatabaseOperationType
    public let modelName: String
    public let access: String
    public let definition: JSONValue
    public let params: JSONValue?
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String
}

/// Parameters for `createOperation`.
public struct CreateOperationParams: Encodable, Sendable {
    public var name: String
    public var type: DatabaseOperationType
    public var modelName: String
    public var access: String
    public var definition: JSONValue
    public var params: JSONValue?

    public init(
        name: String,
        type: DatabaseOperationType,
        modelName: String,
        access: String,
        definition: JSONValue,
        params: JSONValue? = nil
    ) {
        self.name = name
        self.type = type
        self.modelName = modelName
        self.access = access
        self.definition = definition
        self.params = params
    }
}

/// Parameters for `updateOperation`. Omit a property to leave it unchanged;
/// pass `params: .clear` to remove the runtime parameter schema.
public struct UpdateOperationParams: Encodable, Sendable {
    public var modelName: String?
    public var access: String?
    public var definition: JSONValue?
    /// `.value(...)` to replace, `.clear` to remove, omit to leave as-is.
    public var params: Updatable<JSONValue>?

    public init(
        modelName: String? = nil,
        access: String? = nil,
        definition: JSONValue? = nil,
        params: Updatable<JSONValue>? = nil
    ) {
        self.modelName = modelName
        self.access = access
        self.definition = definition
        self.params = params
    }
}

/// Sort direction for an operation execution: ascending or descending.
public enum SortDirection: Int, Codable, Sendable {
    case ascending = 1
    case descending = -1
}

/// Options for `executeOperation`.
public struct ExecuteOperationOptions: Encodable, Sendable {
    public var params: JSONValue?
    public var limit: Int?
    public var cursor: String?
    public var direction: SortDirection?
    public var timing: Bool?

    public init(
        params: JSONValue? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        direction: SortDirection? = nil,
        timing: Bool? = nil
    ) {
        self.params = params
        self.limit = limit
        self.cursor = cursor
        self.direction = direction
        self.timing = timing
    }
}

// MARK: Batch

/// A single invocation in an `executeBatch` call — one parameter object per
/// record passed to the mutation operation.
public struct DatabaseBatchOperation: Encodable, Sendable {
    public var params: JSONValue

    public init(params: JSONValue) {
        self.params = params
    }
}

/// Result of `executeBatch` / the deprecated `importBulk`, and of the
/// row-import convenience.
public struct DatabaseBatchResult: Decodable, Sendable, Equatable {
    public let imported: Int
    public let failed: Int

    public init(imported: Int, failed: Int) {
        self.imported = imported
        self.failed = failed
    }
}

// MARK: CSV import

/// Target type for explicit CSV value coercion. Mirrors the JS
/// `types` map values (`"number" | "boolean" | "string"`).
public enum CsvCoercionType: String, Sendable {
    case number
    case boolean
    case string
}

/// Progress snapshot passed to `CsvImportOptions.onProgress` after each
/// batch. Mirrors JS `CsvImportProgress`.
public struct CsvImportProgress: Sendable, Equatable {
    public let processed: Int
    public let total: Int
    public let imported: Int
    public let failed: Int
    public let batchIndex: Int

    public init(processed: Int, total: Int, imported: Int, failed: Int, batchIndex: Int) {
        self.processed = processed
        self.total = total
        self.imported = imported
        self.failed = failed
        self.batchIndex = batchIndex
    }
}

/// Options for `importCsv`. Mirrors JS `CsvImportOptions`.
///
/// Provide either `csv` (raw text, parsed with a quoted-field-aware parser)
/// or `data` (pre-parsed string rows). `modelName` is required — the Swift
/// surface resolves the model by name (the JS `model:` BaseModel-class path,
/// with its schema-driven field filtering and index sync, is not ported; see
/// `syncIndexes`). Callbacks are Swift closures rather than JS functions.
public struct CsvImportOptions: Sendable {
    /// Raw CSV string to parse. Provide either `csv` or `data`.
    public var csv: String?
    /// Pre-parsed rows (each a `header -> value` dictionary). Provide either
    /// `csv` or `data`.
    public var data: [[String: String]]?
    /// Model name the rows are written to (required).
    public var modelName: String?
    /// Map CSV column headers to field names (e.g. `["Product Name": "name"]`).
    public var columnMap: [String: String]?
    /// Per-row transform. Receives the coerced row and its index; return `nil`
    /// to skip the row, or a replacement row to import.
    public var transform: (@Sendable ([String: JSONValue], Int) -> [String: JSONValue]?)?
    /// Explicit type coercion map (field name -> target type).
    public var types: [String: CsvCoercionType]?
    /// CSV column whose value is used as the record ID.
    public var idColumn: String?
    /// Generate an ID per row (receives the row and its index).
    public var idGenerator: (@Sendable ([String: JSONValue], Int) -> String)?
    /// CSV delimiter (default `","`).
    public var delimiter: String?
    /// Records per bulk-import request (default `5000`).
    public var batchSize: Int?
    /// Fired after each batch with cumulative progress.
    public var onProgress: (@Sendable (CsvImportProgress) -> Void)?
    /// Called when a batch fails. Return `false` to abort remaining batches.
    public var onBatchError: (@Sendable (Error, Int) -> Bool)?
    /// Sync indexes from the model schema after import. Kept for parity with
    /// JS; in Swift it has no effect (no BaseModel-class introspection), so
    /// `CsvImportResult.indexesCreated` is always `0`.
    public var syncIndexes: Bool?
    /// Name of the registered save operation (default `"save"`). Must accept
    /// params `{ modelName, id, data }`.
    public var operationName: String?

    public init(
        csv: String? = nil,
        data: [[String: String]]? = nil,
        modelName: String? = nil,
        columnMap: [String: String]? = nil,
        transform: (@Sendable ([String: JSONValue], Int) -> [String: JSONValue]?)? = nil,
        types: [String: CsvCoercionType]? = nil,
        idColumn: String? = nil,
        idGenerator: (@Sendable ([String: JSONValue], Int) -> String)? = nil,
        delimiter: String? = nil,
        batchSize: Int? = nil,
        onProgress: (@Sendable (CsvImportProgress) -> Void)? = nil,
        onBatchError: (@Sendable (Error, Int) -> Bool)? = nil,
        syncIndexes: Bool? = nil,
        operationName: String? = nil
    ) {
        self.csv = csv
        self.data = data
        self.modelName = modelName
        self.columnMap = columnMap
        self.transform = transform
        self.types = types
        self.idColumn = idColumn
        self.idGenerator = idGenerator
        self.delimiter = delimiter
        self.batchSize = batchSize
        self.onProgress = onProgress
        self.onBatchError = onBatchError
        self.syncIndexes = syncIndexes
        self.operationName = operationName
    }
}

/// A single batch failure in a `CsvImportResult`. Mirrors JS
/// `CsvImportResult.errors[n]`.
public struct CsvImportError: Sendable, Equatable {
    public let batchIndex: Int
    public let error: String

    public init(batchIndex: Int, error: String) {
        self.batchIndex = batchIndex
        self.error = error
    }
}

/// Result of `importCsv`. Mirrors JS `CsvImportResult`.
public struct CsvImportResult: Sendable, Equatable {
    public let imported: Int
    public let failed: Int
    public let errors: [CsvImportError]
    /// Number of indexes created after import. Always `0` on the Swift
    /// surface (no model-class index sync); see `CsvImportOptions.syncIndexes`.
    public let indexesCreated: Int
    public let durationMs: Int

    public init(imported: Int, failed: Int, errors: [CsvImportError], indexesCreated: Int, durationMs: Int) {
        self.imported = imported
        self.failed = failed
        self.errors = errors
        self.indexesCreated = indexesCreated
        self.durationMs = durationMs
    }
}

// MARK: Schema

/// Field schema entry for a model, returned by `describe`. Mirrors JS
/// `ModelFieldInfo` from `js-bao/client`.
public struct ModelFieldInfo: Decodable, Sendable, Equatable {
    public let modelName: String
    public let fieldName: String
    public let inferredType: String
    public let firstSeenAt: String

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case fieldName = "field_name"
        case inferredType = "inferred_type"
        case firstSeenAt = "first_seen_at"
    }
}

// MARK: Small result wrappers

/// `{ success }` — returned by `delete`, `removeManager`,
/// `revokePermission`, and `revokeGroupPermission`.
public struct DatabaseSuccessResult: Decodable, Sendable, Equatable {
    public let success: Bool
}

// MARK: - Realtime subscriptions (`databases.subscribe`)
//
// Mirror the JS client's `db.change` wire frame
// (`src/client/internal/databaseSubscriptions.ts` +
// `api/databasesApi.ts`). The frame arrives parsed as a JSON dict on the
// WS message router, so these structs are built from `[String: Any]` (the
// same hand-decode style as `WorkflowStatusEvent`) rather than via
// `Decodable` — the router already has a `[String: Any]` in hand and
// `data`/`previousData` are opaque blobs the platform doesn't introspect.

/// A single change inside a `db.change` frame. Mirrors JS
/// `DatabaseChangeEvent`.
///
/// `changeType` is the server-derived filter transition (#740):
/// `"enter"` / `"update"` / `"leave"`. Projection-using subscribers read
/// `changeType`; CRDT-aware subscribers can keep reading `op`. `data` and
/// `previousData` are opaque record blobs (`JSONValue`).
public struct DatabaseChangeEvent: @unchecked Sendable {
    /// `"enter" | "update" | "leave"` — absent on older server frames.
    public let changeType: String?
    /// `"save" | "patch" | "delete" | "increment" | "addToSet" | "removeFromSet"`.
    public let op: String
    public let modelName: String
    public let id: String
    public let data: Any?
    public let previousData: Any?

    public init(
        changeType: String? = nil,
        op: String,
        modelName: String,
        id: String,
        data: Any? = nil,
        previousData: Any? = nil
    ) {
        self.changeType = changeType
        self.op = op
        self.modelName = modelName
        self.id = id
        self.data = data
        self.previousData = previousData
    }

    /// Build from one element of the wire `changes` array. Returns `nil`
    /// if the required discriminant fields are missing.
    static func from(_ json: [String: Any]) -> DatabaseChangeEvent? {
        guard let op = json["op"] as? String,
              let modelName = json["modelName"] as? String,
              let id = json["id"] as? String else { return nil }
        return DatabaseChangeEvent(
            changeType: json["changeType"] as? String,
            op: op,
            modelName: modelName,
            id: id,
            data: json["data"] is NSNull ? nil : json["data"],
            previousData: json["previousData"] is NSNull ? nil : json["previousData"]
        )
    }
}

/// Envelope for a `db.change` event (one frame, potentially N changes).
/// Mirrors JS `DatabaseChangePayload`.
///
/// `isOrigin` / `isOriginUser` are synthesized client-side at dispatch
/// time (#737) from the server-stamped `originConnectionId` /
/// `originUserId` compared against this client's live connection / user
/// id — so a frame for the receiver's own write is flagged without the
/// server knowing per-recipient context. On WS reconnect the local
/// connection id rotates, so a frame for the writer's own pre-reconnect
/// write may arrive with `isOrigin == false` — expected.
public struct DatabaseChangePayload: @unchecked Sendable {
    public let databaseId: String
    public let subscriptionKey: String
    public let changes: [DatabaseChangeEvent]
    public let timestamp: String
    /// Connection id of the writer, or `nil` for server-side / unattributed
    /// writes (cron, workflow steps, admin imports, or an HTTP write that
    /// omitted `X-JB-Connection-Id`).
    public let originConnectionId: String?
    /// User id of the writer, or `nil` for unattributed server-side writes.
    public let originUserId: String?
    /// `true` iff this exact WS connection produced the write.
    public let isOrigin: Bool
    /// `true` iff any tab/process signed in as this client's current user
    /// produced the write.
    public let isOriginUser: Bool

    public init(
        databaseId: String,
        subscriptionKey: String,
        changes: [DatabaseChangeEvent],
        timestamp: String,
        originConnectionId: String? = nil,
        originUserId: String? = nil,
        isOrigin: Bool = false,
        isOriginUser: Bool = false
    ) {
        self.databaseId = databaseId
        self.subscriptionKey = subscriptionKey
        self.changes = changes
        self.timestamp = timestamp
        self.originConnectionId = originConnectionId
        self.originUserId = originUserId
        self.isOrigin = isOrigin
        self.isOriginUser = isOriginUser
    }
}

/// Options for `databases.subscribe(...)`. Mirrors JS
/// `DatabaseSubscribeOptions`.
public struct DatabaseSubscribeOptions: @unchecked Sendable {
    /// Bound params forwarded to the server; available in the
    /// subscription's filter CEL as `params.*`.
    public let params: [String: Any]?
    /// Called for every matching `db.change` frame until the returned
    /// unsubscribe handle is invoked.
    public let onChange: (DatabaseChangePayload) -> Void

    public init(
        params: [String: Any]? = nil,
        onChange: @escaping (DatabaseChangePayload) -> Void
    ) {
        self.params = params
        self.onChange = onChange
    }
}
