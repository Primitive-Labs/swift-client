import Foundation

// MARK: - BlobBucketsAPI

/// Mirrors the JS `BlobBucketsAPI` — app-level blob storage namespaces
/// with configurable TTL tiers and access policies. Distinct from
/// per-document blobs on `client.document(id).blobs()`, which are tied
/// to a single Y-CRDT document.
///
/// Bucket-level methods (CRUD + list) go through the standard JSON
/// request path. Upload and download bypass JSON and use the raw HTTP
/// closure so binary bodies/responses round-trip without base64
/// detours.
public final class BlobBucketsAPI: @unchecked Sendable {
    /// JSON request closure — `(method, path, body) -> Any`. Matches the
    /// pattern every other sub-API uses.
    private let makeRequest: (String, String, Any?) async throws -> Any

    /// Raw HTTP closure for upload/download. Returns `(body, status)`.
    /// Mirrors `BlobManager.makeRawRequest`'s shape, so BlobBuckets can
    /// PUT binary bodies and GET binary responses without forcing the
    /// JSON pipeline to base64-encode them.
    private let makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))?

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))? = nil
    ) {
        self.makeRequest = makeRequest
        self.makeRawRequest = makeRawRequest
    }

    // MARK: - Bucket CRUD

    /// Create a new blob bucket (admin/owner only).
    public func createBucket(params: CreateBlobBucketParams) async throws -> BlobBucketInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/blob-buckets", body)
        return try JSONCoding.decode(BlobBucketInfo.self, from: result)
    }

    /// List all blob buckets for the current app (admin/owner only).
    /// The server returns `{ items: [...] }`; this method unwraps to the
    /// items array to match the JS surface (which also returns the
    /// list directly).
    public func listBuckets() async throws -> [BlobBucketInfo] {
        let result = try await makeRequest("GET", "/blob-buckets", nil)
        if let dict = result as? [String: Any], let items = dict["items"] {
            return try JSONCoding.decode([BlobBucketInfo].self, from: items)
        }
        return try JSONCoding.decode([BlobBucketInfo].self, from: result)
    }

    /// Get a single bucket by its `bucketId` or `bucketKey`.
    public func getBucket(bucketIdOrKey: String) async throws -> BlobBucketInfo {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let result = try await makeRequest("GET", "/blob-buckets/\(escaped)", nil)
        return try JSONCoding.decode(BlobBucketInfo.self, from: result)
    }

    /// Delete a bucket and every blob inside it.
    public func deleteBucket(bucketIdOrKey: String) async throws -> BlobDeletedResult {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let result = try await makeRequest("DELETE", "/blob-buckets/\(escaped)", nil)
        return try JSONCoding.decode(BlobDeletedResult.self, from: result)
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
        guard let makeRawRequest else {
            throw JsBaoError(code: .unavailable, message: "Raw HTTP client not wired for BlobBucketsAPI")
        }
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let path = "/blob-buckets/\(escaped)/blobs"

        let encodedFilename = filename.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? filename
        var headers: [String: String] = [
            "Content-Type": contentType,
            "X-Blob-Filename": encodedFilename,
        ]
        if let tags, !tags.isEmpty,
           let tagsData = try? JSONSerialization.data(withJSONObject: tags),
           let tagsJSON = String(data: tagsData, encoding: .utf8) {
            headers["X-Blob-Tags"] = tagsJSON
        }
        let (body, status) = try await makeRawRequest("POST", path, data, headers)
        guard (200..<300).contains(status) else {
            throw HttpError(
                status: status, message: "Blob upload failed",
                body: String(data: body, encoding: .utf8)
            )
        }
        let json = try JSONSerialization.jsonObject(with: body)
        return try JSONCoding.decode(BucketBlobInfo.self, from: json)
    }

    /// List blobs in a bucket. Cursor-paginated per R2; response shape:
    /// `{ "items": [...], "cursor"?: String }`.
    public func list(
        bucketIdOrKey: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> BucketBlobListResult {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        var qs: [String] = []
        if let cursor,
           let escapedCursor = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escapedCursor)")
        }
        if let limit { qs.append("limit=\(limit)") }
        let suffix = qs.isEmpty ? "" : "?\(qs.joined(separator: "&"))"
        let result = try await makeRequest(
            "GET", "/blob-buckets/\(escaped)/blobs\(suffix)", nil
        )
        return try JSONCoding.decode(BucketBlobListResult.self, from: result)
    }

    /// Fetch a blob's metadata without downloading its bytes.
    public func getMetadata(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> BucketBlobInfo {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let escapedBlob = blobId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? blobId
        let result = try await makeRequest(
            "GET", "/blob-buckets/\(escaped)/blobs/\(escapedBlob)/metadata", nil
        )
        return try JSONCoding.decode(BucketBlobInfo.self, from: result)
    }

    /// Download a blob's raw bytes.
    public func download(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> Data {
        guard let makeRawRequest else {
            throw JsBaoError(code: .unavailable, message: "Raw HTTP client not wired for BlobBucketsAPI")
        }
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let escapedBlob = blobId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? blobId
        let path = "/blob-buckets/\(escaped)/blobs/\(escapedBlob)"
        let (body, status) = try await makeRawRequest("GET", path, nil, [:])
        guard (200..<300).contains(status) else {
            throw HttpError(
                status: status, message: "Blob download failed",
                body: String(data: body, encoding: .utf8)
            )
        }
        return body
    }

    /// Delete a blob from a bucket.
    public func delete(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> BlobDeletedResult {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let escapedBlob = blobId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? blobId
        let result = try await makeRequest(
            "DELETE", "/blob-buckets/\(escaped)/blobs/\(escapedBlob)", nil
        )
        return try JSONCoding.decode(BlobDeletedResult.self, from: result)
    }

    /// Get a time-limited signed URL for unauthenticated download.
    /// Response carries `url`, `token`, `expiresAt`, `expiresInSeconds`.
    public func getSignedUrl(
        bucketIdOrKey: String,
        blobId: String,
        expiresInSeconds: Int? = nil
    ) async throws -> BlobSignedUrlResult {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let escapedBlob = blobId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? blobId
        var params: [String: Any] = [:]
        if let expiresInSeconds {
            params["expiresInSeconds"] = expiresInSeconds
        }
        let result = try await makeRequest(
            "POST",
            "/blob-buckets/\(escaped)/blobs/\(escapedBlob)/signed-url",
            params
        )
        return try JSONCoding.decode(BlobSignedUrlResult.self, from: result)
    }
}
