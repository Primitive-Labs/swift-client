import Foundation

// MARK: - DatabaseTypeConfigs: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/databaseTypeConfigsApi.d.ts`) so the two surfaces line up
// field-for-field. Timestamps stay as ISO-8601 `String`s — exactly what JS
// exposes. The `triggers` map is an opaque, server-validated blob keyed by
// model name, so it's typed as `[String: JSONValue]` (the round-trip-safe
// equivalent of JS's `Record<string, any>`; see JSONValue.swift).
//
// The declared-access manifest lives here too, mirroring its JS home
// (`databaseTypeConfigsApi.ts`, which the collection surface re-exports): the
// same shape is carried by both type-config surfaces.

// MARK: - Declared-access manifest

/// A single declared traversal edge in a ``DeclaredMetadataManifest``
/// (bound under `md.<name>.<category>.<key>`). Mirrors JS
/// `DeclaredManifestPath`.
///
/// Exactly one of the two cases roots the edge — a `from` + `via` hop off an
/// already-declared node, or a `rootFrom` static-context root. JS models this
/// as an exclusive union (the unused keys are typed `never`) so that a shape
/// the server's `validatePathGraph` rejects with HTTP 400 is a compile error;
/// an enum is the Swift spelling of the same guarantee, and it keeps the two
/// rootings' required fields non-optional.
///
/// Note this is a *stricter* sibling of ``PathDeclaration``, the loose
/// all-optional shape used for a rule-set entry's per-rule `loads` — the same
/// split the JS client has between `databaseTypeConfigsApi` and `ruleSetsApi`.
public enum DeclaredManifestPath: Codable, Sendable, Equatable {
    /// Hop from an already-declared source node (`self` or another declared
    /// path) to the target whose id is stored at `via` (`<category>.<key>`)
    /// on that source.
    case from(from: String, via: String, type: String, categories: [String])
    /// The target id comes straight from a static dotted context path
    /// (`input.*` / `record.*` / `params.*`, or the server-authenticated
    /// `user.userId`). Roots the graph, so it takes no `from` / `via`.
    case rootFrom(rootFrom: String, type: String, categories: [String])

    /// The target resource's `resourceType`, whichever way the edge is rooted.
    public var type: String {
        switch self {
        case let .from(_, _, type, _), let .rootFrom(_, type, _): return type
        }
    }

    /// Target categories to load and bind under `md.<name>`.
    public var categories: [String] {
        switch self {
        case let .from(_, _, _, categories), let .rootFrom(_, _, categories):
            return categories
        }
    }

    private enum CodingKeys: String, CodingKey {
        case from, rootFrom, via, type, categories
    }

    /// Decodes the rooting the wire data actually carries, and rejects any
    /// shape that isn't exactly one of them — both rootings at once, or a
    /// `rootFrom` alongside a `via`, are what the server's `validatePathGraph`
    /// 400s, so they're decoded as corrupt data rather than silently resolved
    /// (which would drop the other rooting's keys on the next re-encode).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let categories = try container.decode([String].self, forKey: .categories)
        let from = try container.decodeIfPresent(String.self, forKey: .from)
        let via = try container.decodeIfPresent(String.self, forKey: .via)
        let rootFrom = try container.decodeIfPresent(String.self, forKey: .rootFrom)

        func corrupt(_ reason: String) -> DecodingError {
            DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath, debugDescription: reason
                )
            )
        }

        if let rootFrom {
            guard from == nil, via == nil else {
                throw corrupt("""
                A declared manifest path rooted at `rootFrom` must not also \
                carry `from` or `via`.
                """)
            }
            self = .rootFrom(rootFrom: rootFrom, type: type, categories: categories)
            return
        }
        guard let from, let via else {
            throw corrupt("""
            A declared manifest path must carry either `rootFrom` or both \
            `from` and `via`.
            """)
        }
        self = .from(from: from, via: via, type: type, categories: categories)
    }

    /// Encodes only the keys the rooting in play uses — the other variant's
    /// keys stay off the wire entirely rather than going out as `null`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .from(from, via, type, categories):
            try container.encode(from, forKey: .from)
            try container.encode(via, forKey: .via)
            try container.encode(type, forKey: .type)
            try container.encode(categories, forKey: .categories)
        case let .rootFrom(rootFrom, type, categories):
            try container.encode(rootFrom, forKey: .rootFrom)
            try container.encode(type, forKey: .type)
            try container.encode(categories, forKey: .categories)
        }
    }
}

/// A declared-access manifest. Mirrors JS `DeclaredMetadataManifest`.
///
/// Declares exactly which resource metadata categories and scalar roots a type
/// config's CEL rules may load: `self` categories on the subject, declared
/// traversal ``paths``, and the ``secrets`` / ``vars`` keys the rules
/// reference. A category is reachable from a rule as `md.self.<category>.<key>`
/// only when it is declared here — this is the manifest prerequisite for
/// migrating off `metadataAccess` / `contextId` to metadata categories.
/// Persisted JSON-stringified; the API returns it parsed.
public struct DeclaredMetadataManifest: Codable, Sendable, Equatable {
    /// The `self` declaration: categories on the subject resource to load
    /// under `md.self`.
    public struct SelfDeclaration: Codable, Sendable, Equatable {
        public var categories: [String]

        public init(categories: [String]) {
            self.categories = categories
        }
    }

    /// Categories on the subject resource to load under `md.self`.
    ///
    /// Spelled `selfCategories` in Swift because a property named `self` would
    /// collide with the `x.self` identity expression; it encodes and decodes
    /// as the JS field name, `self`.
    public var selfCategories: SelfDeclaration?
    /// Declared traversal edges, keyed by the `md.<name>` they bind under.
    public var paths: [String: DeclaredManifestPath]?
    /// Secret keys the rules may reference as `secrets.<KEY>`.
    public var secrets: [String]?
    /// Non-secret config-var keys the rules may reference as `vars.<KEY>`.
    public var vars: [String]?

    private enum CodingKeys: String, CodingKey {
        case selfCategories = "self"
        case paths, secrets, vars
    }

    public init(
        selfCategories: SelfDeclaration? = nil,
        paths: [String: DeclaredManifestPath]? = nil,
        secrets: [String]? = nil,
        vars: [String]? = nil
    ) {
        self.selfCategories = selfCategories
        self.paths = paths
        self.secrets = secrets
        self.vars = vars
    }
}

/// A serialized database-type-configuration row, as returned by the
/// `databases/types` endpoints. Mirrors JS `DatabaseTypeConfigInfo`.
///
/// Database type configs control schema-less database behavior for documents
/// tagged with a particular `databaseType`: which rule set governs access,
/// which CEL-driven `triggers` run on writes, and how `metadataAccess` is
/// gated.
public struct DatabaseTypeConfigInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let databaseType: String
    /// `nil` when no rule set is bound.
    public let ruleSetId: String?
    /// Trigger rules keyed by model name (e.g.
    /// `["Task": ["triggers": [["on": "create", "set": [...]]]]]`). `nil`
    /// when no triggers are configured.
    public let triggers: [String: JSONValue]?
    /// CEL expression evaluated to decide whether the caller can read
    /// database metadata. `nil` when not configured.
    public let metadataAccess: String?
    /// The declared-access manifest for this type's CEL rules, returned
    /// parsed. `nil` when none is set. Declaring a category here is the
    /// prerequisite for reading `md.self.<category>.<key>` from this type's
    /// rules — i.e. for migrating a ``metadataAccess`` gate to a metadata
    /// category.
    public let metadataManifest: DeclaredMetadataManifest?
    public let createdAt: String
    public let modifiedAt: String
    public let createdBy: String

    public init(
        appId: String,
        databaseType: String,
        ruleSetId: String? = nil,
        triggers: [String: JSONValue]? = nil,
        metadataAccess: String? = nil,
        metadataManifest: DeclaredMetadataManifest? = nil,
        createdAt: String,
        modifiedAt: String,
        createdBy: String
    ) {
        self.appId = appId
        self.databaseType = databaseType
        self.ruleSetId = ruleSetId
        self.triggers = triggers
        self.metadataAccess = metadataAccess
        self.metadataManifest = metadataManifest
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.createdBy = createdBy
    }
}

/// Parameters for `create`. `databaseType` is required; the rest are optional
/// and omitted from the request body when `nil`. Mirrors JS
/// `CreateDatabaseTypeConfigParams`.
public struct CreateDatabaseTypeConfigParams: Encodable, Sendable {
    /// The database type identifier to configure (e.g. `"userDB"`).
    public var databaseType: String
    /// Rule set to enforce for databases of this type. Must have
    /// `resourceType: "database_type"`.
    public var ruleSetId: String?
    /// Optional trigger rules keyed by model name. Validated server-side.
    public var triggers: [String: JSONValue]?
    /// Optional CEL expression gating metadata access.
    public var metadataAccess: String?
    /// Optional declared-access manifest that lets this type's CEL rules load
    /// metadata categories as `md.self.<category>.<key>` (and traversed
    /// `md.<node>.*`). Declaring a category here is the prerequisite for
    /// migrating a `metadataAccess` gate to a metadata category. Omitted from
    /// the body when `nil`.
    public var metadataManifest: DeclaredMetadataManifest?

    public init(
        databaseType: String,
        ruleSetId: String? = nil,
        triggers: [String: JSONValue]? = nil,
        metadataAccess: String? = nil,
        metadataManifest: DeclaredMetadataManifest? = nil
    ) {
        self.databaseType = databaseType
        self.ruleSetId = ruleSetId
        self.triggers = triggers
        self.metadataAccess = metadataAccess
        self.metadataManifest = metadataManifest
    }
}

/// Parameters for `update`. Every field is clearable: pass `.value(x)` to set,
/// `.clear` to null the field server-side, or omit (leave `nil`) to leave it
/// unchanged. Mirrors JS `UpdateDatabaseTypeConfigParams`, where each field is
/// `T | null | undefined`.
public struct UpdateDatabaseTypeConfigParams: Encodable, Sendable {
    /// New rule set ID to associate (`.value`), or `.clear` to remove the
    /// current rule set.
    public var ruleSetId: Updatable<String>?
    /// Replacement trigger rules object (`.value`), or `.clear` to remove all
    /// triggers.
    public var triggers: Updatable<[String: JSONValue]>?
    /// Replacement metadata-access CEL expression (`.value`), or `.clear` to
    /// remove it.
    public var metadataAccess: Updatable<String>?
    /// Replacement declared-access manifest (`.value`), or `.clear` to remove
    /// it. Set this to make metadata categories reachable from this type's CEL
    /// rules as `md.self.<category>.<key>` when migrating off
    /// `metadataAccess`.
    public var metadataManifest: Updatable<DeclaredMetadataManifest>?

    public init(
        ruleSetId: Updatable<String>? = nil,
        triggers: Updatable<[String: JSONValue]>? = nil,
        metadataAccess: Updatable<String>? = nil,
        metadataManifest: Updatable<DeclaredMetadataManifest>? = nil
    ) {
        self.ruleSetId = ruleSetId
        self.triggers = triggers
        self.metadataAccess = metadataAccess
        self.metadataManifest = metadataManifest
    }
}
