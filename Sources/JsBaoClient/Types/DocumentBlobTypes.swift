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
/// pagination cursor. Mirrors JS `BlobListResult<T>` (`{ items, cursor? }`).
/// `cursor` is `nil` when there are no further pages.
public struct DocumentBlobListResult: Decodable, Sendable {
    public let items: [BlobInfo]
    public let cursor: String?

    public init(items: [BlobInfo], cursor: String? = nil) {
        self.items = items
        self.cursor = cursor
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
