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

// MARK: Bucket metadata

/// Metadata for a single blob bucket. Mirrors JS `BlobBucketInfo`.
public struct BlobBucketInfo: Decodable, Sendable, Equatable {
    public let bucketId: String
    public let appId: String
    public let bucketKey: String
    public let name: String
    public let description: String?
    public let ttlTier: BlobBucketTtlTier
    public let accessPolicy: BlobBucketAccessPolicy
    public let ruleSetId: String?
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String
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
    /// Access policy for blobs in this bucket.
    public var accessPolicy: BlobBucketAccessPolicy
    /// Optional rule set ID for CEL-based access control.
    public var ruleSetId: String?

    public init(
        bucketKey: String,
        name: String,
        ttlTier: BlobBucketTtlTier,
        accessPolicy: BlobBucketAccessPolicy,
        description: String? = nil,
        ruleSetId: String? = nil
    ) {
        self.bucketKey = bucketKey
        self.name = name
        self.ttlTier = ttlTier
        self.accessPolicy = accessPolicy
        self.description = description
        self.ruleSetId = ruleSetId
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
    public let cursor: String?

    private enum CodingKeys: String, CodingKey { case items, cursor }

    public init(items: [BucketBlobInfo], cursor: String? = nil) {
        self.items = items
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([BucketBlobInfo].self, forKey: .items) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
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
