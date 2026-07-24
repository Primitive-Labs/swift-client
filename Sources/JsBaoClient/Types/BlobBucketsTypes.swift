import Foundation

// MARK: - BlobBuckets: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/blobBucketsApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. The
// bucket-scoped blob metadata type is named `BucketBlobInfo` (not `BlobInfo`)
// because the per-document `BlobInfo` already exists in `BlobManager.swift`
// with a *different* field set; the bucket surface's `BlobInfo` carries
// `bucketId`/`tags`/`uploaded`/`etag`, so it gets its own name to avoid a
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

/// Access policy for blobs in a bucket. Mirrors JS `BlobBucketAccessPolicy`.
public enum BlobBucketAccessPolicy: String, Codable, Sendable {
    case publicRead = "public-read"
    case authenticated
    case ownerOnly = "owner-only"
}

/// Named access preset for a bucket. Mirrors JS `BlobBucketPreset`.
public enum BlobBucketPreset: String, Codable, Sendable {
    case publicAccess = "public"
    case authenticated
    case adminOnly = "admin-only"
    case personalUploads = "personal-uploads"
    case custom
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
    /// Deprecated JS read-alias of `preset`. Kept as `String` because the
    /// server may return preset names that are outside the legacy input enum.
    public let accessPolicy: String
    public let ruleSetId: String?
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String

    private enum CodingKeys: String, CodingKey {
        case bucketId, appId, bucketKey, name, description, ttlTier
        case preset, accessPolicy, ruleSetId, createdBy, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bucketId = try c.decode(String.self, forKey: .bucketId)
        appId = try c.decode(String.self, forKey: .appId)
        bucketKey = try c.decode(String.self, forKey: .bucketKey)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        ttlTier = try c.decode(BlobBucketTtlTier.self, forKey: .ttlTier)
        ruleSetId = try c.decodeIfPresent(String.self, forKey: .ruleSetId)
        createdBy = try c.decode(String.self, forKey: .createdBy)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        modifiedAt = try c.decode(String.self, forKey: .modifiedAt)

        if let decodedPreset = try c.decodeIfPresent(BlobBucketPreset.self, forKey: .preset) {
            preset = decodedPreset
        } else {
            let legacy = try c.decode(BlobBucketAccessPolicy.self, forKey: .accessPolicy)
            preset = Self.preset(from: legacy)
        }
        accessPolicy = try c.decodeIfPresent(String.self, forKey: .accessPolicy) ?? preset.rawValue
    }

    private static func preset(from legacy: BlobBucketAccessPolicy) -> BlobBucketPreset {
        switch legacy {
        case .publicRead: return .publicAccess
        case .authenticated: return .authenticated
        case .ownerOnly: return .adminOnly
        }
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
    /// Named access preset. Provide this or a `ruleSetId`; legacy
    /// `accessPolicy` remains accepted as an input alias. For custom access,
    /// pass `ruleSetId` and leave `preset` nil; `.custom` is returned by the
    /// server on bucket info but is not a meaningful create input.
    public var preset: BlobBucketPreset?
    /// Access policy for blobs in this bucket.
    public var accessPolicy: BlobBucketAccessPolicy?
    /// Optional rule set ID for CEL-based access control.
    public var ruleSetId: String?

    public init(
        bucketKey: String,
        name: String,
        ttlTier: BlobBucketTtlTier,
        accessPolicy: BlobBucketAccessPolicy? = nil,
        preset: BlobBucketPreset? = nil,
        description: String? = nil,
        ruleSetId: String? = nil
    ) {
        self.bucketKey = bucketKey
        self.name = name
        self.ttlTier = ttlTier
        self.accessPolicy = accessPolicy
        self.preset = preset
        self.description = description
        self.ruleSetId = ruleSetId
    }
}

// MARK: Bucket update input

/// Parameters for `updateBucket`. Mirrors JS `UpdateBlobBucketParams`.
public struct UpdateBlobBucketParams: Encodable, Sendable {
    /// New access preset. For custom access, set `ruleSetId` instead; `.custom`
    /// is returned by the server on bucket info but is not a meaningful update
    /// input.
    public var preset: BlobBucketPreset?
    public var accessPolicy: BlobBucketAccessPolicy?
    public var ruleSetId: Updatable<String>?
    public var name: String?
    public var description: Updatable<String>?

    public init(
        preset: BlobBucketPreset? = nil,
        accessPolicy: BlobBucketAccessPolicy? = nil,
        ruleSetId: Updatable<String>? = nil,
        name: String? = nil,
        description: Updatable<String>? = nil
    ) {
        self.preset = preset
        self.accessPolicy = accessPolicy
        self.ruleSetId = ruleSetId
        self.name = name
        self.description = description
    }
}

// MARK: Blob metadata

/// Metadata for a single blob inside a bucket. Mirrors JS `BlobInfo`
/// (named `BucketBlobInfo` here to avoid colliding with the per-document
/// `BlobInfo` in `BlobManager.swift`). JS `BucketBlobUploadResult` extends
/// `BlobInfo` with no extra fields, so `upload` also returns this type.
public struct BucketBlobInfo: Decodable, Sendable, Equatable {
    public let blobId: String
    public let bucketId: String
    public let filename: String?
    public let contentType: String?
    public let numBytes: Int
    public let sha256: String?
    public let tags: [String]
    public let createdBy: String?
    public let uploaded: String?
    public let etag: String?
}

/// A page of blobs in a bucket with an optional R2 pagination cursor.
/// Mirrors JS `BucketBlobListResult`.
public struct BucketBlobListResult: Decodable, Sendable, Equatable {
    public let items: [BucketBlobInfo]
    /// Continuation token for the next page (#1316).
    public let nextCursor: String?
    /// True when a next page exists (#1316).
    public let hasMore: Bool
    /// Deprecated alias of `nextCursor` kept for one deprecation window (#1316).
    public let cursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, cursor, nextCursor, hasMore
    }

    public init(
        items: [BucketBlobInfo],
        cursor: String? = nil,
        nextCursor: String? = nil,
        hasMore: Bool? = nil
    ) {
        self.items = items
        let next = nextCursor ?? cursor
        self.nextCursor = next
        self.cursor = next
        self.hasMore = hasMore ?? (next != nil)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([BucketBlobInfo].self, forKey: .items) ?? []
        // #1316: prefer `nextCursor`; `cursor` is the deprecated alias.
        let next = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .cursor)
        nextCursor = next
        cursor = next
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

/// Result of a batch blob delete (#1455) via `delete(bucketIdOrKey:blobIds:)`.
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
