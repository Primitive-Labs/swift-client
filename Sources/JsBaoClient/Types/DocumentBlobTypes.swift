import Foundation

// MARK: - Per-document blob context: typed results
//
// These mirror the per-document blob interfaces published by the JS client
// (`internal/blobManager.d.ts` — `DocumentBlobContext`) so the two surfaces
// line up field-for-field. The blob *metadata* shape (`BlobInfo`) and the
// upload result (`BlobUploadResult`) are already defined in
// `Internal/BlobManager.swift` and are reused as-is; this file only adds the
// typed wrapper results that JS exposes but Swift had been returning as
// untyped dictionaries.

/// Result of `DocumentBlobContext.list` — a page of blobs plus an opaque
/// pagination cursor. Mirrors JS `BlobListResult<T>` (`{ items, hasMore,
/// nextCursor? }`). `nextCursor` is `nil` when there are no further pages.
public struct DocumentBlobListResult: Decodable, Sendable {
    public let items: [BlobInfo]
    /// Continuation token for the next page (#1316).
    public let nextCursor: String?
    /// True when a next page exists (#1316).
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case items, nextCursor, hasMore
    }

    public init(
        items: [BlobInfo],
        nextCursor: String? = nil,
        hasMore: Bool? = nil
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore ?? (nextCursor != nil)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([BlobInfo].self, forKey: .items) ?? []
        let next = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        nextCursor = next
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? (next != nil)
    }
}

/// Result of `DocumentBlobContext.delete`. Mirrors JS `{ deleted: boolean }`.
public struct BlobDeleteResult: Decodable, Sendable, Equatable {
    public let deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }
}

/// Result of `DocumentBlobContext.uploadFile` — the narrowed queue shape JS
/// returns from `uploadFile` (`{ blobId, numBytes, bytesTransferred? }`),
/// distinct from the fuller `BlobUploadResult` returned by `upload`.
public struct BlobUploadFileResult: Sendable, Equatable {
    public let blobId: String
    public let numBytes: Int
    public let bytesTransferred: Int?

    public init(blobId: String, numBytes: Int, bytesTransferred: Int? = nil) {
        self.blobId = blobId
        self.numBytes = numBytes
        self.bytesTransferred = bytesTransferred
    }
}
