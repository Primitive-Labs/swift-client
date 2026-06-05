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
    public let createdAt: String
    public let modifiedAt: String
    public let createdBy: String

    public init(
        appId: String,
        collectionType: String,
        ruleSetId: String?,
        createdAt: String,
        modifiedAt: String,
        createdBy: String
    ) {
        self.appId = appId
        self.collectionType = collectionType
        self.ruleSetId = ruleSetId
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

    public init(collectionType: String, ruleSetId: String? = nil) {
        self.collectionType = collectionType
        self.ruleSetId = ruleSetId
    }
}

/// Parameters for `update`. Mirrors JS `UpdateCollectionTypeConfigParams`,
/// whose `ruleSetId?: string | null` is a tri-state: omit to leave unchanged,
/// `.value(id)` to set, `.clear` to remove the current rule set.
public struct UpdateCollectionTypeConfigParams: Encodable, Sendable {
    /// `.value("rs_123")` to set, `.clear` to remove, `nil` to leave as-is.
    public var ruleSetId: Updatable<String>?

    public init(ruleSetId: Updatable<String>? = nil) {
        self.ruleSetId = ruleSetId
    }
}
