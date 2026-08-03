import Foundation

// MARK: - Resource metadata: typed request & response models
//
// These mirror the interfaces the JS client publishes
// (`src/client/api/resourceMetadataApi.ts`, issues #1352 and #1402)
// field-for-field, including optionality.
//
// A stored metadata object is caller-defined and the platform validates it
// against the category's schema without the client introspecting it, so every
// `data` payload is a `[String: JSONValue]` — the same choice
// `databases.create(initialMetadata:)` already makes for metadata values.
//
// TypeScript models the read and the batch results as discriminated unions
// (`{exists: true, schemaVersion: number}` | `{exists: false, schemaVersion:
// null}`, `{ok: true, …}` | `{ok: false, …}`). Swift decodes them the same way
// the rest of this client decodes server unions (see `LockAcquireResponse`): a
// struct carrying the discriminator flag plus optional payload fields, with
// convenience accessors for the arms. A newly added field can then never fail
// the decode.

// MARK: - Single read

/// Result of a single-category metadata read (`resourceMetadata.get`).
///
/// A read of a resource that has nothing stored for the category is still a
/// success: `exists` is `false`, `data` is empty, and `schemaVersion` is `nil`.
/// Check `exists` before treating `data` as meaningful.
public struct ResourceMetadataReadResult: Decodable, Sendable, Equatable {
    public let resourceType: String
    public let resourceId: String
    public let category: String
    /// The stored metadata object — empty when `exists` is `false`.
    public let data: [String: JSONValue]
    /// Schema version the stored data was validated against. `nil` when no row
    /// exists.
    public let schemaVersion: Int?
    /// `true` when a stored row exists for this resource and category.
    public let exists: Bool

    public init(
        resourceType: String,
        resourceId: String,
        category: String,
        data: [String: JSONValue],
        schemaVersion: Int?,
        exists: Bool
    ) {
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.category = category
        self.data = data
        self.schemaVersion = schemaVersion
        self.exists = exists
    }
}

// MARK: - Write

/// Result of a metadata write (`resourceMetadata.set` — a full replace, not a
/// merge).
public struct ResourceMetadataWriteResult: Decodable, Sendable, Equatable {
    public let resourceType: String
    public let resourceId: String
    public let category: String
    /// The stored metadata object as validated and persisted.
    public let data: [String: JSONValue]
    /// Schema version the write was validated against.
    public let schemaVersion: Int
    /// Stored size of the serialized data, in bytes.
    public let size: Int

    public init(
        resourceType: String,
        resourceId: String,
        category: String,
        data: [String: JSONValue],
        schemaVersion: Int,
        size: Int
    ) {
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.category = category
        self.data = data
        self.schemaVersion = schemaVersion
        self.size = size
    }
}

// MARK: - Batch read

/// One item of a batch read request.
///
/// `categories` is required and must be non-empty — there is no expand-to-all.
/// An item that omits it comes back as a per-resource error with `status` 400.
public struct ResourceMetadataBatchRequestItem: Codable, Sendable, Equatable {
    public let resourceType: String
    public let resourceId: String
    /// Explicit categories to read for this resource.
    public let categories: [String]

    public init(resourceType: String, resourceId: String, categories: [String]) {
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.categories = categories
    }
}

/// The failure detail carried by a batch entry whose `ok` is `false` — the same
/// triple at the per-resource and the per-category level.
public struct ResourceMetadataBatchError: Sendable, Equatable {
    /// HTTP-style status this entry would have produced on its own (403, 404, …).
    public let status: Int
    /// Machine-readable error code.
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
}

/// Per-category result inside a batch read.
///
/// `ok == true` carries the same payload as a single read (`data`,
/// `schemaVersion`, `exists`); `ok == false` carries `error` and never `data`.
public struct ResourceMetadataBatchCategoryResult: Decodable, Sendable, Equatable {
    public let ok: Bool
    /// Present when `ok == true`.
    public let data: [String: JSONValue]?
    /// Present when `ok == true`; nullable there as well.
    public let schemaVersion: Int?
    /// Present when `ok == true`.
    public let exists: Bool?
    /// Present when `ok == false`.
    public let status: Int?
    /// Present when `ok == false`.
    public let code: String?
    /// Present when `ok == false`.
    public let message: String?

    /// The failure detail when this category could not be read, `nil` when it
    /// was read successfully.
    public var error: ResourceMetadataBatchError? {
        guard !ok, let status, let code, let message else { return nil }
        return ResourceMetadataBatchError(status: status, code: code, message: message)
    }

    public init(
        ok: Bool,
        data: [String: JSONValue]? = nil,
        schemaVersion: Int? = nil,
        exists: Bool? = nil,
        status: Int? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.ok = ok
        self.data = data
        self.schemaVersion = schemaVersion
        self.exists = exists
        self.status = status
        self.code = code
        self.message = message
    }
}

/// Per-resource result inside a batch read.
///
/// `ok == true` carries the per-category map; `ok == false` is an item-level
/// fault (a malformed segment, or a missing `categories` list) that applies to
/// the whole item and carries no `categories`.
public struct ResourceMetadataBatchResourceResult: Decodable, Sendable, Equatable {
    public let resourceType: String
    public let resourceId: String
    public let ok: Bool
    /// Present when `ok == true`: category name → that category's result.
    public let categories: [String: ResourceMetadataBatchCategoryResult]?
    /// Present when `ok == false`.
    public let status: Int?
    /// Present when `ok == false`.
    public let code: String?
    /// Present when `ok == false`.
    public let message: String?

    /// The failure detail when the whole item failed, `nil` otherwise.
    public var error: ResourceMetadataBatchError? {
        guard !ok, let status, let code, let message else { return nil }
        return ResourceMetadataBatchError(status: status, code: code, message: message)
    }

    public init(
        resourceType: String,
        resourceId: String,
        ok: Bool,
        categories: [String: ResourceMetadataBatchCategoryResult]? = nil,
        status: Int? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.ok = ok
        self.categories = categories
        self.status = status
        self.code = code
        self.message = message
    }
}

/// Result of `resourceMetadata.getBatch`.
///
/// The call itself succeeds (HTTP 200) even when individual entries fail —
/// check each entry's `ok` flag.
public struct ResourceMetadataBatchResult: Decodable, Sendable, Equatable {
    /// One entry per request item, in request order.
    public let results: [ResourceMetadataBatchResourceResult]

    public init(results: [ResourceMetadataBatchResourceResult]) {
        self.results = results
    }
}

// MARK: - List

/// One stored category in a resource metadata listing (`resourceMetadata.list`).
public struct ResourceMetadataListEntry: Decodable, Sendable, Equatable {
    public let category: String
    /// The stored metadata object for this category.
    public let data: [String: JSONValue]
    /// Schema version the stored data was validated against (`nil` if unknown).
    public let schemaVersion: Int?

    public init(category: String, data: [String: JSONValue], schemaVersion: Int?) {
        self.category = category
        self.data = data
        self.schemaVersion = schemaVersion
    }
}

/// Result of `resourceMetadata.list`.
///
/// Only categories the caller may read are returned: each is gated by its
/// `readRule` with the app-level owner/admin bypass, so an admin sees every
/// category while a plain member sees only the ones their rule permits. A
/// resource with no metadata returns an empty list.
public struct ResourceMetadataListResult: Decodable, Sendable, Equatable {
    public let resourceType: String
    public let resourceId: String
    public let categories: [ResourceMetadataListEntry]

    public init(
        resourceType: String,
        resourceId: String,
        categories: [ResourceMetadataListEntry]
    ) {
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.categories = categories
    }
}

// MARK: - Delete

/// Result of `resourceMetadata.delete` — idempotent, so an absent item is a
/// success with `deleted == false`, not an error.
public struct ResourceMetadataDeleteResult: Decodable, Sendable, Equatable {
    public let resourceType: String
    public let resourceId: String
    public let category: String
    /// `false` when no stored item existed (still a success, not a 404).
    public let deleted: Bool

    public init(
        resourceType: String,
        resourceId: String,
        category: String,
        deleted: Bool
    ) {
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.category = category
        self.deleted = deleted
    }
}

// MARK: - Resolve

/// The owning resource carried by a `resourceMetadata.resolve` hit.
public struct ResourceMetadataResolvedResource: Sendable, Equatable {
    /// ID of the resource that owns the value.
    public let resourceId: String
    /// Type of the resource that owns the value.
    public let resourceType: String

    public init(resourceId: String, resourceType: String) {
        self.resourceId = resourceId
        self.resourceType = resourceType
    }
}

/// Result of `resourceMetadata.resolve` — the reverse of a metadata read.
///
/// A hit carries the owning resource (`resourceId` and `resourceType` both
/// set); a miss carries `resourceId == nil` and no `resourceType`. Read the
/// `resolved` accessor to get the hit arm as one value.
///
/// A value the caller may not resolve (the category's `readRule` denies reading
/// the resource it points at) comes back as the **same** miss shape, so a
/// denial and a genuine miss cannot be told apart from the response body. Only
/// the body is indistinguishable: a denied resolve does the rule evaluation a
/// miss skips, so it is not constant-time.
public struct ResourceMetadataResolveResult: Decodable, Sendable, Equatable {
    /// ID of the resource that owns the value; `nil` on a miss (or a denial).
    public let resourceId: String?
    /// Type of the resource that owns the value; `nil` on a miss (or a denial).
    public let resourceType: String?

    /// The owning resource when the value resolved, `nil` on a miss — the arm
    /// to branch on rather than unwrapping the two optionals separately.
    public var resolved: ResourceMetadataResolvedResource? {
        guard let resourceId, let resourceType else { return nil }
        return ResourceMetadataResolvedResource(
            resourceId: resourceId,
            resourceType: resourceType
        )
    }

    public init(resourceId: String?, resourceType: String?) {
        self.resourceId = resourceId
        self.resourceType = resourceType
    }
}

// MARK: - Request bodies

/// Body of `PUT /resources/{type}/{id}/metadata/{category}`. The server also
/// accepts a bare metadata object, but the JS client sends the wrapped form and
/// this mirrors it.
struct ResourceMetadataWriteRequest: Encodable, Sendable {
    let data: [String: JSONValue]
}

/// Body of `POST /resources/metadata/batch`.
struct ResourceMetadataBatchRequest: Encodable, Sendable {
    let requests: [ResourceMetadataBatchRequestItem]
}

/// Body of `POST /metadata/resolve`. The lookup parameters travel in the body
/// rather than the path, so nothing here needs percent-encoding.
struct ResourceMetadataResolveRequest: Encodable, Sendable {
    let resourceType: String
    let category: String
    let key: String
    let value: String
}
