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
    ///
    /// - Parameter params: Expected keys:
    ///   - `bucketKey` (String, required): app-unique slug.
    ///   - `name` (String, required): display name.
    ///   - `ttlTier` (String, required): one of `"1d"`, `"3d"`, `"14d"`,
    ///     `"28d"`, `"180d"`, `"365d"`, `"permanent"`.
    ///   - `accessPolicy` (String, required): `"public-read"`,
    ///     `"authenticated"`, or `"owner-only"`.
    ///   - `description` (String, optional)
    ///   - `ruleSetId` (String, optional): CEL-based access control.
    public func createBucket(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/blob-buckets", params)
        return result as? [String: Any] ?? [:]
    }

    /// List all blob buckets for the current app (admin/owner only).
    /// The server returns `{ items: [...] }`; this method unwraps to the
    /// items array to match the JS surface (which also returns the
    /// list directly).
    public func listBuckets() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/blob-buckets", nil)
        if let dict = result as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            return items
        }
        return result as? [[String: Any]] ?? []
    }

    /// Get a single bucket by its `bucketId` or `bucketKey`.
    public func getBucket(bucketIdOrKey: String) async throws -> [String: Any] {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let result = try await makeRequest("GET", "/blob-buckets/\(escaped)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Delete a bucket and every blob inside it.
    public func deleteBucket(bucketIdOrKey: String) async throws -> [String: Any] {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let result = try await makeRequest("DELETE", "/blob-buckets/\(escaped)", nil)
        return result as? [String: Any] ?? [:]
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
    ) async throws -> [String: Any] {
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
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// List blobs in a bucket. Cursor-paginated per R2; response shape:
    /// `{ "items": [...], "cursor"?: String }`.
    public func list(
        bucketIdOrKey: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> [String: Any] {
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
        return result as? [String: Any] ?? [:]
    }

    /// Fetch a blob's metadata without downloading its bytes.
    public func getMetadata(
        bucketIdOrKey: String,
        blobId: String
    ) async throws -> [String: Any] {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let escapedBlob = blobId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? blobId
        let result = try await makeRequest(
            "GET", "/blob-buckets/\(escaped)/blobs/\(escapedBlob)/metadata", nil
        )
        return result as? [String: Any] ?? [:]
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
    ) async throws -> [String: Any] {
        let escaped = bucketIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bucketIdOrKey
        let escapedBlob = blobId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? blobId
        let result = try await makeRequest(
            "DELETE", "/blob-buckets/\(escaped)/blobs/\(escapedBlob)", nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Get a time-limited signed URL for unauthenticated download.
    /// Response carries `url`, `token`, `expiresAt`, `expiresInSeconds`.
    public func getSignedUrl(
        bucketIdOrKey: String,
        blobId: String,
        expiresInSeconds: Int? = nil
    ) async throws -> [String: Any] {
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
        return result as? [String: Any] ?? [:]
    }
}
