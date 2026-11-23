import Foundation

// MARK: - BlobBuckets: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/blobBucketsApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. The
// bucket-scoped blob metadata type is named `BucketBlobInfo` (not `BlobInfo`)
// because the per-document `BlobInfo` already exists in `BlobManager.swift`
// with a *different* field set; the bucket surface's `BlobInfo` carries
// `bucketId`/`tags`/`createdAt`/`etag`, so it gets its own name to avoid a
// collision.

// MARK: Enums

/// Retention tier for a bucket — controls automatic blob expiration.
/// Mirrors JS `BlobBucketTtlTier`.
public enum BlobBucketTtlTier: String, Codable, Sendable {
    case oneDay = "1d"
    case threeDays = "3d"
    case fourteenDays = "14d"
    case twentyEightDays = "28d"
    case oneHundredEightyDays = "180d"
    case threeHundredSixtyFiveDays = "365d"
    case permanent
}

/// A bucket's access, one of four named presets. Mirrors JS
/// `BlobBucketPreset`. For access a preset cannot express, make the bucket
/// `.adminOnly` and hand out read URLs from a server function.
public enum BlobBucketPreset: String, Codable, Sendable {
    case publicAccess = "public"
    case authenticated
    case adminOnly = "admin-only"
    case personalUploads = "personal-uploads"
}

// MARK: Bucket metadata

/// Metadata for a single blob bucket. Mirrors JS `BlobBucketInfo`.
public struct BlobBucketInfo: Decodable, Sendable, Equatable {
    public let bucketId: String
    public let appId: String
    public let bucketKey: String
    public let name: String
    public let description: String?
    public let ttlTier: BlobBucketTtlTier
    public let preset: BlobBucketPreset
    /// True for a bucket stored with a rule set. Such a bucket is served as
    /// `.adminOnly` until `updateBucket` names a preset, which clears the
    /// mark. Decodes as `false` when the server omits it.
    public let convertedFromRuleSet: Bool
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String

    private enum CodingKeys: String, CodingKey {
        case bucketId, appId, bucketKey, name, description, ttlTier, preset
        case convertedFromRuleSet, createdBy, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bucketId = try c.decode(String.self, forKey: .bucketId)
        appId = try c.decode(String.self, forKey: .appId)
        bucketKey = try c.decode(String.self, forKey: .bucketKey)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        ttlTier = try c.decode(BlobBucketTtlTier.self, forKey: .ttlTier)
        preset = try c.decode(BlobBucketPreset.self, forKey: .preset)
        convertedFromRuleSet =
            try c.decodeIfPresent(Bool.self, forKey: .convertedFromRuleSet) ?? false
        createdBy = try c.decode(String.self, forKey: .createdBy)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        modifiedAt = try c.decode(String.self, forKey: .modifiedAt)
    }
}

// MARK: Bucket create input

/// Parameters for `createBucket`. Mirrors JS `CreateBlobBucketParams`.
public struct CreateBlobBucketParams: Encodable, Sendable {
    /// Human-friendly identifier for the bucket (max 64 chars,
    /// alphanumeric + dash/underscore).
    public var bucketKey: String
    /// Display name for the bucket.
    public var name: String
    /// Optional description.
    public var description: String?
    /// Retention tier — controls automatic expiration.
    public var ttlTier: BlobBucketTtlTier
    /// Named access preset; the server requires one.
    public var preset: BlobBucketPreset?

    public init(
        bucketKey: String,
        name: String,
        ttlTier: BlobBucketTtlTier,
        preset: BlobBucketPreset? = nil,
        description: String? = nil
    ) {
        self.bucketKey = bucketKey
        self.name = name
        self.ttlTier = ttlTier
        self.preset = preset
        self.description = description
    }
}

// MARK: Bucket update input

/// Parameters for `updateBucket`. Mirrors JS `UpdateBlobBucketParams`.
public struct UpdateBlobBucketParams: Encodable, Sendable {
    /// New access preset. On a bucket with `convertedFromRuleSet`, naming a
    /// preset clears the mark.
    public var preset: BlobBucketPreset?
    public var name: String?
    public var description: Updatable<String>?

    public init(
        preset: BlobBucketPreset? = nil,
        name: String? = nil,
        description: Updatable<String>? = nil
    ) {
        self.preset = preset
        self.name = name
        self.description = description
    }
}

// MARK: Blob metadata

/// Metadata for a single blob inside a bucket. Mirrors JS `BlobInfo`
/// (named `BucketBlobInfo` here to avoid colliding with the per-document
/// `BlobInfo` in `BlobManager.swift`). JS `BucketBlobUploadResult` extends
/// `BlobInfo` with an optional `bytesTransferred`, so `upload` also returns
/// this type.
public struct BucketBlobInfo: Decodable, Sendable, Equatable {
    public let blobId: String
    public let bucketId: String
    public let filename: String?
    public let contentType: String?
    public let numBytes: Int
    public let sha256: String?
    public let tags: [String]
    public let createdBy: String?
    /// When the blob was stored, ISO 8601.
    public let createdAt: String?
    public let etag: String?
    /// On an upload's answer: the bytes sent, 0 when the same bytes were
    /// already stored under the id. `nil` on metadata and list items.
    public let bytesTransferred: Int?
}

/// A page of blobs in a bucket with an optional R2 pagination cursor.
/// Mirrors JS `BucketBlobListResult`.
public struct BucketBlobListResult: Decodable, Sendable, Equatable {
    public let items: [BucketBlobInfo]
    /// Continuation token for the next page.
    public let nextCursor: String?
    /// True when a next page exists.
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case items, nextCursor, hasMore
    }

    public init(
        items: [BucketBlobInfo],
        nextCursor: String? = nil,
        hasMore: Bool? = nil
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore ?? (nextCursor != nil)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([BucketBlobInfo].self, forKey: .items) ?? []
        let next = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        nextCursor = next
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? (next != nil)
    }
}

// MARK: Blob list options

/// Options for `list`. Mirrors JS `BlobListOptions`.
public struct BlobListOptions: Sendable {
    public var cursor: String?
    public var limit: Int?

    public init(cursor: String? = nil, limit: Int? = nil) {
        self.cursor = cursor
        self.limit = limit
    }
}

// MARK: Signed URL result

/// Result of `getSignedUrl`. Mirrors JS `BlobSignedUrlResult`.
public struct BlobSignedUrlResult: Decodable, Sendable, Equatable {
    public let url: String
    public let token: String
    public let expiresAt: Int
    public let expiresInSeconds: Int
}

// MARK: Small result wrappers

/// `{ deleted }` — returned by `deleteBucket` and blob `delete`. Mirrors
/// JS's `Promise<{ deleted: boolean }>`.
public struct BlobDeletedResult: Decodable, Sendable, Equatable {
    public let deleted: Bool
}

/// Result of a batch blob delete via `delete(bucketIdOrKey:blobIds:)`.
/// Mirrors JS's `BatchBlobDeleteResult` — `{ deleted, blobIds, bucketId }`,
/// returned by `POST /blob-buckets/:bucketId/blobs/delete`.
public struct BatchBlobDeleteResult: Decodable, Sendable, Equatable {
    /// Count of ids processed (input length, duplicates included).
    public let deleted: Int
    /// The ids processed, echoed back.
    public let blobIds: [String]
    /// The resolved bucket id.
    public let bucketId: String

    public init(deleted: Int, blobIds: [String], bucketId: String) {
        self.deleted = deleted
        self.blobIds = blobIds
        self.bucketId = bucketId
    }
}
