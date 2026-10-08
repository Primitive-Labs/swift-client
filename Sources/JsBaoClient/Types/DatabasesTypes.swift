import Foundation

// MARK: - Databases: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/databasesApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. Opaque,
// platform-untouched blobs (operation definitions, query results) are typed as
// `JSONValue` (see JSONValue.swift).

// MARK: Database metadata

/// A single database's details. Mirrors JS `DatabaseInfo`. Per-database values
/// live in resource metadata categories, read from CEL as
/// `md.self.<category>.<key>`.
public struct DatabaseInfo: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let title: String
    public let databaseType: String?
    public let permission: String?
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String

    private enum CodingKeys: String, CodingKey {
        case databaseId, title, databaseType
        case permission, createdBy, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        databaseId = try c.decode(String.self, forKey: .databaseId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        databaseType = try c.decodeIfPresent(String.self, forKey: .databaseType)
        permission = try c.decodeIfPresent(String.self, forKey: .permission)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt) ?? ""
    }
}

// MARK: Create / update inputs

/// Parameters for `create`.
public struct CreateDatabaseParams: Encodable, Sendable {
    public var title: String
    public var databaseType: String
    /// Create-time resource metadata to stamp on the new database, keyed by
    /// category name → that category's values, e.g.
    /// `["settings": ["teamId": .string("t-1")]]`. Each entry is
    /// schema-validated with the category `writeRule` waived — creation
    /// authority covers the initial stamp. At most 10 categories; any invalid
    /// entry fails the whole create.
    ///
    /// The stamped values are read from CEL as `md.self.<category>.<key>`.
    /// Mirrors js-bao's `CreateDatabaseParams.initialMetadata`.
    public var initialMetadata: [String: [String: JSONValue]]? = nil

    public init(
        title: String,
        databaseType: String,
        initialMetadata: [String: [String: JSONValue]]? = nil
    ) {
        self.title = title
        self.databaseType = databaseType
        self.initialMetadata = initialMetadata
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
/// `changeType`; CRDT-aware subscribers can keep reading `op`.
///
/// `data` and `previousData` are opaque record blobs, still typed `Any?` —
/// which is why this type and its `DatabaseChangePayload` envelope are
/// `@unchecked Sendable` rather than checked, even though
/// `DatabasesAPI.subscribe`'s callback is now `@Sendable` (#2367). #2546
/// retyped the *document* query row currency and left these alone — they are
/// the DoDb subscription payload, a separate surface — so retyping them is
/// tracked in **#2579**. Until then, convert one with
/// `JSONValue.typedRow(from:)` before handing it across an actor boundary —
/// the compiler will not do it for you.
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
/// The change callback is a parameter of
/// ``DatabasesAPI/subscribe(databaseId:subscriptionKey:options:onChange:)``
/// rather than a field here, so a subscription always has exactly one handler
/// and the options stay a plain value type.
public struct DatabaseSubscribeOptions: Sendable {
    /// Bound params forwarded to the server; available in the
    /// subscription's filter CEL as `params.*`.
    public let params: [String: JSONValue]?

    public init(params: [String: JSONValue]? = nil) {
        self.params = params
    }
}

// MARK: - Typed realtime subscriptions (#2805)
//
// The typed half of the surface above: the same wire frame, with the opaque
// `data` / `previousData` blobs decoded into a caller-supplied `Row`. These
// live in the SDK (not in each `<type>.generated.swift`) for the same reason
// the `DBQueryResult<T>` family does — a Swift package compiles every generated
// file into one module, so a per-file copy would redeclare.

/// One change inside a typed `db.change` frame — the `Row`-decoded counterpart
/// of ``DatabaseChangeEvent``.
///
/// `data` and `previousData` are **partial by construction**, which is why a
/// generated `Row` declares every field optional. A change frame carries only
/// what the write touched: `patch` / `increment` / `addToSet` / `removeFromSet`
/// send just the delta, `save` merges onto the stored row, and a subscription's
/// `select` narrows the payload further still. Typing them as the model's full
/// record would claim fields the frame need not carry — the soundness bug
/// tracked for the JS factory in #1772, which this surface deliberately does
/// not reproduce.
///
/// A blob that does not decode into `Row` (a field whose wire type disagrees,
/// say) yields `nil` rather than dropping the change: the frame is still
/// delivered and ``raw`` carries the untouched event.
public struct TypedDatabaseChangeEvent<Row: Decodable & Sendable>: Sendable {
    /// `"enter" | "update" | "leave"` — absent on older server frames.
    public let changeType: String?
    /// `"save" | "patch" | "delete" | "increment" | "addToSet" | "removeFromSet"`.
    public let op: String
    public let modelName: String
    public let id: String
    /// The frame's `data`, decoded into `Row`. `nil` when the frame carried no
    /// `data` (a `delete`) or when the blob is not a `Row`.
    public let data: Row?
    /// The frame's `previousData`, decoded into `Row`. `nil` when the server
    /// sent none (no pre-read) or when the blob is not a `Row`.
    public let previousData: Row?
    /// The untyped event this was decoded from — the escape hatch for anything
    /// `Row` cannot express, and the only place an undecodable blob survives.
    public let raw: DatabaseChangeEvent

    /// Decode one untyped event. Never throws: a blob that is not a `Row`
    /// becomes `nil`, so one odd change cannot take the frame down.
    public init(decoding event: DatabaseChangeEvent, as rowType: Row.Type = Row.self) {
        self.changeType = event.changeType
        self.op = event.op
        self.modelName = event.modelName
        self.id = event.id
        self.data = Self.decodeRow(event.data)
        self.previousData = Self.decodeRow(event.previousData)
        self.raw = event
    }

    private static func decodeRow(_ blob: Any?) -> Row? {
        guard let blob, !(blob is NSNull) else { return nil }
        return try? JSONCoding.decode(Row.self, from: blob)
    }
}

/// Envelope for a typed `db.change` frame — the `Row`-decoded counterpart of
/// ``DatabaseChangePayload``. Every envelope field is threaded through
/// unchanged, including the #737 origin attribution.
public struct TypedDatabaseChangePayload<Row: Decodable & Sendable>: Sendable {
    public let databaseId: String
    public let subscriptionKey: String
    public let changes: [TypedDatabaseChangeEvent<Row>]
    public let timestamp: String
    /// Connection id of the writer, or `nil` for server-side / unattributed writes.
    public let originConnectionId: String?
    /// User id of the writer, or `nil` for unattributed server-side writes.
    public let originUserId: String?
    /// `true` iff this exact WS connection produced the write.
    public let isOrigin: Bool
    /// `true` iff any tab/process signed in as this client's current user
    /// produced the write.
    public let isOriginUser: Bool

    /// Decode an untyped payload. Never throws — see
    /// ``TypedDatabaseChangeEvent/init(decoding:as:)``. Public so an app that
    /// already holds an untyped payload (from `databases.subscribe`) can type it
    /// after the fact.
    public init(decoding payload: DatabaseChangePayload, as rowType: Row.Type = Row.self) {
        self.databaseId = payload.databaseId
        self.subscriptionKey = payload.subscriptionKey
        self.changes = payload.changes.map { TypedDatabaseChangeEvent(decoding: $0, as: Row.self) }
        self.timestamp = payload.timestamp
        self.originConnectionId = payload.originConnectionId
        self.originUserId = payload.originUserId
        self.isOrigin = payload.isOrigin
        self.isOriginUser = payload.isOriginUser
    }
}

// MARK: Paginated decode envelope
//
// `GET /databases` returns `{ items, hasMore, nextCursor? }` (#1958 —
// it used to return a bare array). No per-surface page type is needed:
// `PaginatedResult<DatabaseInfo>` decodes that envelope directly through the
// constrained `Decodable` extension in `Types/GroupsTypes.swift`, the same way
// `groups.list` does.
//
// `listPage` reads it through the shared `PaginatedPageEnvelope` in
// `Types/ResponseEnvelopes.swift`, which adds one thing on top: a server older
// than #1958 still answers with the bare array, and that decodes as a single
// page instead of throwing (#2245).
