import Foundation

// MARK: - MeAPI

public final class MeAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))?
    private let cache: CacheFacade?

    private static let defaultRefreshIfOlderThanMs = 5 * 60 * 1000 // 5 minutes

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        cache: CacheFacade? = nil,
        makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))? = nil
    ) {
        self.makeRequest = makeRequest
        self.cache = cache
        self.makeRawRequest = makeRawRequest
    }

    /// Retrieves the current user's profile, using the cache when available.
    public func get(options: FetchCachedOptions? = nil) async throws -> [String: Any]? {
        guard let cache = cache else {
            let result = try await makeRequest("GET", "/me", nil)
            return result as? [String: Any]
        }

        let mergedOptions = FetchCachedOptions(
            waitForLoad: options?.waitForLoad,
            refreshNetwork: options?.refreshNetwork,
            refreshIfOlderThanMs: options?.refreshIfOlderThanMs ?? Self.defaultRefreshIfOlderThanMs,
            serverTimeoutMs: options?.serverTimeoutMs
        )

        let value = try await cache.fetchCached(
            key: "me",
            fetcher: { [makeRequest] in
                try await makeRequest("GET", "/me", nil)
            },
            options: mergedOptions
        )
        return value as? [String: Any]
    }

    /// Returns cache metadata for the current user's profile entry.
    public func cacheInfo() async -> (updatedAt: String?, ageMs: Double?) {
        guard let cache = cache else { return (nil, nil) }
        return await cache.info(key: "me")
    }

    /// Clears the cached profile so the next get() fetches fresh data.
    public func clearCache() async {
        guard let cache = cache else { return }
        await cache.clear(key: "me")
    }

    /// List documents the current user has access to but doesn't own
    /// (the "shared with me" filter). Mirrors js-bao's
    /// `client.me.sharedDocuments(options)`. Response shape:
    /// `{ "items": [...], "cursor"?: String }`.
    ///
    /// - Parameters:
    ///   - cursor: opaque pagination cursor returned by the previous call
    ///   - limit: page size
    ///   - tag: filter to documents bearing this tag
    public func sharedDocuments(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil
    ) async throws -> [String: Any] {
        var qs: [String] = []
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        if let limit { qs.append("limit=\(limit)") }
        if let tag,
           let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("tag=\(escaped)")
        }
        let path = qs.isEmpty
            ? "/me/shared-documents"
            : "/me/shared-documents?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return result as? [String: Any] ?? [:]
    }

    /// List documents the current user owns (live owner, not creator —
    /// ownership transfer is reflected here). Mirrors js-bao's
    /// `client.me.ownedDocuments(options)`. Same response shape as
    /// `sharedDocuments`.
    public func ownedDocuments(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil
    ) async throws -> [String: Any] {
        var qs: [String] = []
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        if let limit { qs.append("limit=\(limit)") }
        if let tag,
           let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("tag=\(escaped)")
        }
        let path = qs.isEmpty
            ? "/me/owned-documents"
            : "/me/owned-documents?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return result as? [String: Any] ?? [:]
    }

    /// Lists pending document invitations for the current user.
    public func pendingDocumentInvitations() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/me/document-invitations", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Update the current user's profile (name and/or avatar URL).
    public func update(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/me", params)
        await clearCache()
        return result as? [String: Any] ?? [:]
    }

    /// Upload an avatar image for the current user. Sends the bytes as
    /// the raw HTTP body with the supplied `Content-Type` header (matches
    /// js-bao's `me.uploadAvatar(blob, contentType)` shape). Returns
    /// `{ "avatarUrl": String }`.
    ///
    /// - Parameter contentType: One of `image/png`, `image/jpeg`,
    ///   `image/gif`, `image/webp`. Routed via the `Content-Type` header
    ///   when the raw HTTP closure is wired (always in production); the
    ///   previous build silently dropped this argument, so any server
    ///   that strictly validated `Content-Type` would reject the upload.
    public func uploadAvatar(imageData: Data, contentType: String) async throws -> [String: Any] {
        if let makeRawRequest {
            let headers = ["Content-Type": contentType]
            let (body, status) = try await makeRawRequest("POST", "/me/avatar", imageData, headers)
            guard (200..<300).contains(status) else {
                throw HttpError(
                    status: status, message: "Avatar upload failed",
                    body: String(data: body, encoding: .utf8)
                )
            }
            await clearCache()
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return [:]
            }
            return json
        }
        // Fallback when no raw closure is wired (tests that construct
        // MeAPI directly): use the JSON path. The server typically
        // accepts the bytes either way for the avatar endpoint.
        let result = try await makeRequest("POST", "/me/avatar", imageData)
        await clearCache()
        return result as? [String: Any] ?? [:]
    }
}
