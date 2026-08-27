import Foundation

// MARK: - CollectionTypeConfigs: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/collectionTypeConfigsApi.d.ts`) field-for-field. Timestamps stay as
// ISO-8601 `String`s — exactly what JS exposes. `ruleSetId` is nullable on the
// wire; on update it's clearable, so the input uses `Updatable<String>?` (see
// JSONValue.swift) to distinguish omit / set / clear, matching JS's
// `string | null | undefined`.

/// A collection type configuration. Mirrors JS `CollectionTypeConfigInfo`.
public struct CollectionTypeConfigInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let collectionType: String
    /// The bound rule set, or `nil` when no rule set is configured.
    public let ruleSetId: String?
    /// The declared-access manifest for this type's CEL rule set, returned
    /// parsed. `nil` when none is set. A collection rule set can read a
    /// metadata category as `md.self.<category>.<key>` only when the category
    /// is declared here — the manifest prerequisite for migrating a
    /// `collection.contextId` binding to a metadata category.
    public let metadataManifest: DeclaredMetadataManifest?
    public let createdAt: String
    public let modifiedAt: String
    public let createdBy: String

    public init(
        appId: String,
        collectionType: String,
        ruleSetId: String?,
        metadataManifest: DeclaredMetadataManifest? = nil,
        createdAt: String,
        modifiedAt: String,
        createdBy: String
    ) {
        self.appId = appId
        self.collectionType = collectionType
        self.ruleSetId = ruleSetId
        self.metadataManifest = metadataManifest
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.createdBy = createdBy
    }
}

/// Parameters for `create`. Mirrors JS `CreateCollectionTypeConfigParams`.
public struct CreateCollectionTypeConfigParams: Encodable, Sendable {
    /// The collection type identifier to configure (e.g. `"class-students"`).
    public var collectionType: String
    /// Rule set to enforce for collections of this type. Must have
    /// `resourceType: "collection"`. Omit to create an unbound config.
    public var ruleSetId: String?
    /// Optional declared-access manifest that lets this type's rule set load
    /// metadata categories as `md.self.<category>.<key>`. Declaring a category
    /// here is the prerequisite for migrating a `collection.contextId` binding
    /// to a metadata category. Omitted from the body when `nil`.
    public var metadataManifest: DeclaredMetadataManifest?

    public init(
        collectionType: String,
        ruleSetId: String? = nil,
        metadataManifest: DeclaredMetadataManifest? = nil
    ) {
        self.collectionType = collectionType
        self.ruleSetId = ruleSetId
        self.metadataManifest = metadataManifest
    }
}

/// Parameters for `update`. Mirrors JS `UpdateCollectionTypeConfigParams`,
/// whose `ruleSetId?: string | null` is a tri-state: omit to leave unchanged,
/// `.value(id)` to set, `.clear` to remove the current rule set. The manifest
/// is clearable the same way.
public struct UpdateCollectionTypeConfigParams: Encodable, Sendable {
    /// `.value("rs_123")` to set, `.clear` to remove, `nil` to leave as-is.
    public var ruleSetId: Updatable<String>?
    /// Replacement declared-access manifest (`.value`), `.clear` to remove it,
    /// or `nil` to leave as-is. Set this to make metadata categories reachable
    /// from this type's rule set as `md.self.<category>.<key>` when migrating
    /// off `collection.contextId`.
    public var metadataManifest: Updatable<DeclaredMetadataManifest>?

    public init(
        ruleSetId: Updatable<String>? = nil,
        metadataManifest: Updatable<DeclaredMetadataManifest>? = nil
    ) {
        self.ruleSetId = ruleSetId
        self.metadataManifest = metadataManifest
    }
}
