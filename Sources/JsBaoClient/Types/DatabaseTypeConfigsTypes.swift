import Foundation

// MARK: - DatabaseTypeConfigs: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/databaseTypeConfigsApi.d.ts`) so the two surfaces line up
// field-for-field. Timestamps stay as ISO-8601 `String`s — exactly what JS
// exposes. The `triggers` map is an opaque, server-validated blob keyed by
// model name, so it's typed as `[String: JSONValue]` (the round-trip-safe
// equivalent of JS's `Record<string, any>`; see JSONValue.swift).

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
    public let createdAt: String
    public let modifiedAt: String
    public let createdBy: String

    public init(
        appId: String,
        databaseType: String,
        ruleSetId: String? = nil,
        triggers: [String: JSONValue]? = nil,
        metadataAccess: String? = nil,
        createdAt: String,
        modifiedAt: String,
        createdBy: String
    ) {
        self.appId = appId
        self.databaseType = databaseType
        self.ruleSetId = ruleSetId
        self.triggers = triggers
        self.metadataAccess = metadataAccess
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

    public init(
        databaseType: String,
        ruleSetId: String? = nil,
        triggers: [String: JSONValue]? = nil,
        metadataAccess: String? = nil
    ) {
        self.databaseType = databaseType
        self.ruleSetId = ruleSetId
        self.triggers = triggers
        self.metadataAccess = metadataAccess
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

    public init(
        ruleSetId: Updatable<String>? = nil,
        triggers: Updatable<[String: JSONValue]>? = nil,
        metadataAccess: Updatable<String>? = nil
    ) {
        self.ruleSetId = ruleSetId
        self.triggers = triggers
        self.metadataAccess = metadataAccess
    }
}
