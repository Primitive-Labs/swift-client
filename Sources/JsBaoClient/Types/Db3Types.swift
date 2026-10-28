import Foundation

// The answers of `client.db3`'s lifecycle calls: a db3 as the `db3/*` routes
// answer it, and the sync, type, app-access and custody routes' own shapes.

/// A db3, as `client.db3.create`, `get`, `transfer` and `listMine` answer it.
///
/// One type for every route that answers a db3: a field a route does not send
/// decodes to its default (`tags` to `[]`; `metadata`, `permission`,
/// `accessSource` and `grantedAt` to `nil`), and a null `title` to `""`.
///
/// ```swift
/// let info = try await client.db3.create(title: "Orders", type: "orders")
/// print(info.id, info.type ?? "untyped", info.sync, info.custodian ?? "")
/// ```
public struct Db3Info: Decodable, Sendable, Equatable {
    public let id: String
    /// The title, `""` when it has none.
    public let title: String
    /// Who created it: a user id, or `sys:<appId>` for one the app created.
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String
    /// Who holds it: `user:<userId>`, `app`, or the platform resource that
    /// holds it, such as `agentSession:<sessionId>`.
    public let custodian: String?
    /// Whether clients sync it over a socket (`true`, the default); a sync-off
    /// db3 is reached only through its records routes.
    public let sync: Bool
    /// The db3 type it was created with or attached to, or `nil` for an untyped db3.
    public let type: String?
    public let tags: [String]
    /// The opaque metadata blob, when the route answers it.
    public let metadata: JSONValue?
    /// The caller's level, when the route answers it (`get` for a grant
    /// holder, each `listMine` row); `nil` otherwise.
    public let permission: DocumentPermission?
    /// How the caller holds it, when `get` answers it (`.app` for an app
    /// grant, `.resource` for a member of the resource that holds it); `nil`
    /// when absent or a value this client does not know.
    public let accessSource: DocumentAccessSource?
    public let grantedAt: String?

    public init(
        id: String, title: String, createdBy: String, createdAt: String, modifiedAt: String, custodian: String?,
        sync: Bool, type: String?, tags: [String], metadata: JSONValue?, permission: DocumentPermission?,
        accessSource: DocumentAccessSource?, grantedAt: String?
    ) {
        self.id = id
        self.title = title
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.custodian = custodian
        self.sync = sync
        self.type = type
        self.tags = tags
        self.metadata = metadata
        self.permission = permission
        self.accessSource = accessSource
        self.grantedAt = grantedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdBy, createdAt, modifiedAt, custodian, sync, type, tags, metadata, permission, accessSource, grantedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt) ?? ""
        custodian = try c.decodeIfPresent(String.self, forKey: .custodian)
        sync = try c.decodeIfPresent(Bool.self, forKey: .sync) ?? true
        type = try c.decodeIfPresent(String.self, forKey: .type)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        permission = try c.decodeIfPresent(DocumentPermission.self, forKey: .permission)
        accessSource = DocumentAccessSource.lenient(c, forKey: .accessSource)
        grantedAt = try c.decodeIfPresent(String.self, forKey: .grantedAt)
    }
}

/// What `client.db3.getOrCreateWithAlias(_:)` sends: the alias, and what a db3
/// created for it starts with. A db3 the alias already names is answered, not
/// changed; a stated `type` it is not of throws 409 `DB3_TYPE_MISMATCH`.
///
/// ```swift
/// let result = try await client.db3.getOrCreateWithAlias(
///     Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "home"), title: "Home", type: "notes")
/// )
/// let db3Id = result.id
/// ```
public struct Db3GetOrCreateWithAliasOptions: Sendable {
    public var alias: AliasRef
    public var title: String?
    public var tags: [String]?
    public var metadata: JSONValue?
    public var type: String?

    public init(alias: AliasRef, title: String? = nil, tags: [String]? = nil, metadata: JSONValue? = nil, type: String? = nil) {
        self.alias = alias
        self.title = title
        self.tags = tags
        self.metadata = metadata
        self.type = type
    }
}

/// What `client.db3.getOrCreateWithAlias(_:)` answers: the db3's `id`, whether
/// this call `created` it, the alias, and the db3 itself when it was created
/// (an existing one is a reference: read it with `get(_:)`).
public struct Db3GetOrCreateWithAliasResult: Decodable, Sendable, Equatable {
    public let id: String
    public let created: Bool
    public let alias: DocumentAliasInfo?
    /// The db3 this call created; `nil` when the alias already named one.
    public let db3: Db3Info?

    private enum CodingKeys: String, CodingKey {
        case id, created, alias
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created = try c.decode(Bool.self, forKey: .created)
        alias = try c.decodeIfPresent(DocumentAliasInfo.self, forKey: .alias)
        db3 = created ? try Db3Info(from: decoder) : nil
    }
}

/// A db3's sync state, as `client.db3.getSync(_:)` answers it.
public struct Db3SyncState: Decodable, Sendable, Equatable {
    public let id: String
    public let sync: Bool

    public init(id: String, sync: Bool) {
        self.id = id
        self.sync = sync
    }
}

/// What `client.db3.setSync(_:sync:)` answers: the state now, and whether this call changed it.
public struct Db3SyncChange: Decodable, Sendable, Equatable {
    public let id: String
    public let sync: Bool
    public let changed: Bool

    public init(id: String, sync: Bool, changed: Bool) {
        self.id = id
        self.sync = sync
        self.changed = changed
    }
}

/// One revision of a db3 type: a later push is a greater `generation`.
public struct Db3TypeRevision: Decodable, Sendable, Equatable {
    /// The push's time, in epoch milliseconds.
    public let generation: Int64
    /// The hash of the type's declarations and hook rules.
    public let hash: String

    public init(generation: Int64, hash: String) {
        self.generation = generation
        self.hash = hash
    }
}

/// The revision of a type a db3's room holds, and when it was installed.
public struct Db3InstalledType: Decodable, Sendable, Equatable {
    public let name: String
    public let revision: Db3TypeRevision
    /// When it was installed, in epoch milliseconds.
    public let installedAt: Double?

    public init(name: String, revision: Db3TypeRevision, installedAt: Double?) {
        self.name = name
        self.revision = revision
        self.installedAt = installedAt
    }
}

/// A db3's type, as `client.db3.getType(_:)` answers it: the type its row
/// names with that type's current `revision`, and what its room holds
/// (`installed`). The two differ while a push is reaching the db3, or after the
/// db3 refused one.
public struct Db3TypeState: Decodable, Sendable, Equatable {
    public let id: String
    /// The type's name, or `nil` for an untyped db3.
    public let type: String?
    public let revision: Db3TypeRevision?
    public let installed: Db3InstalledType?

    public init(id: String, type: String?, revision: Db3TypeRevision?, installed: Db3InstalledType?) {
        self.id = id
        self.type = type
        self.revision = revision
        self.installed = installed
    }
}

/// What `client.db3.setType(_:type:)` answers: the revision installed, and
/// `outcome` `committed`, or `unchanged` when the room already held it.
public struct Db3TypeChange: Decodable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let revision: Db3TypeRevision
    public let outcome: String

    public init(id: String, type: String, revision: Db3TypeRevision, outcome: String) {
        self.id = id
        self.type = type
        self.revision = revision
        self.outcome = outcome
    }
}

/// The level a db3's app access grants every member of the app. Its own type,
/// not `DocumentLinkAccessLevel`: the words are the same, the grants are not.
public enum Db3AppAccessLevel: String, Codable, Sendable {
    case reader
    case readWrite = "read-write"
}

/// A db3's app access, as `client.db3.getAppAccess(_:)` answers it: `level` is
/// `nil` while no app grant exists.
public struct Db3AppAccess: Decodable, Sendable, Equatable {
    public let id: String
    public let level: Db3AppAccessLevel?

    public init(id: String, level: Db3AppAccessLevel?) {
        self.id = id
        self.level = level
    }
}

/// What `client.db3.setAppAccess(_:level:)` answers: the level now, and whether this call changed it.
public struct Db3AppAccessChange: Decodable, Sendable, Equatable {
    public let id: String
    public let level: Db3AppAccessLevel?
    public let changed: Bool

    public init(id: String, level: Db3AppAccessLevel?, changed: Bool) {
        self.id = id
        self.level = level
        self.changed = changed
    }
}

/// What `client.db3.setOwnerRow(_:present:)` answers: the custodian, whether
/// its owner row now exists, and whether this call changed that.
public struct Db3OwnerRowChange: Decodable, Sendable, Equatable {
    public let id: String
    public let custodian: String?
    public let ownerRow: Bool
    public let changed: Bool

    public init(id: String, custodian: String?, ownerRow: Bool, changed: Bool) {
        self.id = id
        self.custodian = custodian
        self.ownerRow = ownerRow
        self.changed = changed
    }
}
