import Foundation

// MARK: - BlobBucketsAPI

/// Mirrors the JS `BlobBucketsAPI` — app-level blob storage namespaces
/// with configurable TTL tiers and access policies. Distinct from
/// per-document blobs on `client.document(id).blobs()`, which are tied
/// to a single Y-CRDT document.
///
/// Bucket-level methods (CRUD + list) go through the typed JSON request
/// path. Upload and download bypass JSON and use `Transport.requestData`
/// so binary bodies/responses round-trip byte-for-byte without base64
/// detours.
public final class BlobBucketsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Bucket CRUD

    /// Create a new blob bucket (admin/owner only).
    public func createBucket(params: CreateBlobBucketParams) async throws -> BlobBucketInfo {
        try await transport.request(method: .post, path: "/blob-buckets", body: params)
    }

    /// List all blob buckets for the current app (admin/owner only).
    /// The server returns `{ items: [...] }`; this method unwraps to the
    /// items array to match the JS surface (which also returns the
    /// list directly).
    public func listBuckets() async throws -> [BlobBucketInfo] {
        let response: ItemsEnvelope<BlobBucketInfo> = try await transport.request(
            method: .get,
            path: "/blob-buckets"
        )
        return response.items
    }

    /// Get a single bucket by its `bucketId` or `bucketKey`.
    public func getBucket(bucketIdOrKey: String) async throws -> BlobBucketInfo {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        return try await transport.request(method: .get, path: "/blob-buckets/\(escaped)")
    }

    /// Update a bucket's preset/rule set or display metadata.
    public func updateBucket(
        bucketIdOrKey: String,
        params: UpdateBlobBucketParams
    ) async throws -> BlobBucketInfo {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        return try await transport.request(
            method: .patch,
            path: "/blob-buckets/\(escaped)",
            body: params
        )
    }

    /// Delete a bucket and every blob inside it.
    public func deleteBucket(bucketIdOrKey: String) async throws -> BlobDeletedResult {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        return try await transport.request(method: .delete, path: "/blob-buckets/\(escaped)")
    }

    // MARK: - Blob upload / list / metadata / download / delete

    /// Upload a blob into a bucket. Returns the generated metadata
    /// (including a server-minted `blobId`).
    ///
    /// - Parameters:
    ///   - bucketIdOrKey: target bucket.
    ///   - data: blob bytes.
    ///   - filename: original filename for `Content-Disposition`.
    ///   - contentType: MIME type; defaults to `application/octet-stream`.
    ///   - tags: optional array of tag strings.
    public func upload(
        bucketIdOrKey: String,
        data: Data,
        filename: String,
        contentType: String = "application/octet-stream",
        tags: [String]? = nil
    ) async throws -> BucketBlobInfo {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        let path = "/blob-buckets/\(escaped)/blobs"

        let encodedFilename = URLEncoding.encodeComponent(filename)
        var headers: [String: String] = [
            "Content-Type": contentType,
            "X-Blob-Filename": encodedFilename,
        ]
        if let tags, !tags.isEmpty,
           let tagsData = try? JSONCoding.encodeData(tags),
           let tagsJSON = String(data: tagsData, encoding: .utf8) {
            headers["X-Blob-Tags"] = tagsJSON
        }
        let (body, status) = try await transport.requestData(
            method: .post,
            path: path,
            body: data,
            options: RequestOptions(customHeaders: headers)
        )
        guard (200..<300).contains(status) else {
            throw HttpError(
                status: status, message: "Blob upload failed",
                body: String(data: body, encoding: .utf8)
            )
        }
        return try JSONCoding.decodeData(BucketBlobInfo.self, from: body)
    }

    /// List blobs in a bucket. Cursor-paginated per R2; response shape:
    /// `{ "items": [...], "cursor"?: String }`.
    public func list(
        bucketIdOrKey: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> BucketBlobListResult {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        var query = URLQuery()
        query.appendIfPresent("cursor", cursor)
        if let limit { query.append("limit", limit) }
        return try await transport.request(
            method: .get,
            path: "/blob-buckets/\(escaped)/blobs\(query.queryString)"
        )
    }

    /// Fetch a blob's metadata without downloading its bytes.
    public func getMetadata(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> BucketBlobInfo {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        let escapedBlob = URLEncoding.encodeComponent(blobId)
        return try await transport.request(
            method: .get,
            path: "/blob-buckets/\(escaped)/blobs/\(escapedBlob)/metadata"
        )
    }

    /// Download a blob's raw bytes.
    public func download(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> Data {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        let escapedBlob = URLEncoding.encodeComponent(blobId)
        let path = "/blob-buckets/\(escaped)/blobs/\(escapedBlob)"
        let (body, status) = try await transport.requestData(method: .get, path: path)
        guard (200..<300).contains(status) else {
            throw HttpError(
                status: status, message: "Blob download failed",
                body: String(data: body, encoding: .utf8)
            )
        }
        return body
    }

    /// Delete a single blob from a bucket (`DELETE .../blobs/:blobId`).
    /// Returns `{ deleted: Bool }`. Unchanged, back-compatible.
    public func delete(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> BlobDeletedResult {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        let escapedBlob = URLEncoding.encodeComponent(blobId)
        return try await transport.request(
            method: .delete,
            path: "/blob-buckets/\(escaped)/blobs/\(escapedBlob)"
        )
    }

    /// Batch-delete blobs from a bucket (#1455). Routes to
    /// `POST .../blobs/delete` with body `{ blobIds }` and returns
    /// `{ deleted, blobIds, bucketId }`. Mirrors the JS array overload of
    /// `blobBuckets.delete(bucket, blobIds)`.
    ///
    /// All-or-nothing access screening: if the bucket's `delete` rule denies
    /// any id the whole batch fails (403, nothing deleted). `deleted` counts
    /// ids processed (input length, duplicates included), not ids that existed.
    /// The server caps a batch at 500 ids; an empty array is a 200 no-op
    /// (`{ deleted: 0, blobIds: [] }`, no R2 operation).
    ///
    /// A missing id is screened against the `delete` rule with
    /// `blobCreatedBy == null`, exactly like the single-blob path — so a
    /// missing id and an existing-but-unauthorized id are indistinguishable
    /// (no existence oracle).
    public func delete(
        bucketIdOrKey: String,
        blobIds: [String]
    ) async throws -> BatchBlobDeleteResult {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        return try await transport.request(
            method: .post,
            path: "/blob-buckets/\(escaped)/blobs/delete",
            body: ["blobIds": blobIds]
        )
    }

    /// Get a time-limited signed URL for unauthenticated download.
    /// Response carries `url`, `token`, `expiresAt`, `expiresInSeconds`.
    public func getSignedUrl(
        bucketIdOrKey: String,
        blobId: String,
        expiresInSeconds: Int? = nil
    ) async throws -> BlobSignedUrlResult {
        let escaped = URLEncoding.encodeComponent(bucketIdOrKey)
        let escapedBlob = URLEncoding.encodeComponent(blobId)
        return try await transport.request(
            method: .post,
            path: "/blob-buckets/\(escaped)/blobs/\(escapedBlob)/signed-url",
            body: SignedUrlBody(expiresInSeconds: expiresInSeconds)
        )
    }
}

// MARK: - Wire shims

/// `{ expiresInSeconds? }` — the key is omitted when the caller did not
/// supply it, matching the previous conditionally-populated dictionary.
private struct SignedUrlBody: Encodable, Sendable {
    let expiresInSeconds: Int?
}

