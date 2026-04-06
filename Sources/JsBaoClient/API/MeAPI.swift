import Foundation

// MARK: - MeAPI

public final class MeAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let cache: CacheFacade?

    private static let defaultRefreshIfOlderThanMs = 5 * 60 * 1000 // 5 minutes

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        cache: CacheFacade? = nil
    ) {
        self.makeRequest = makeRequest
        self.cache = cache
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

    /// Upload an avatar image for the current user.
    /// Note: The caller is responsible for setting appropriate Content-Type headers
    /// via custom request options on the underlying HTTP client.
    public func uploadAvatar(imageData: Data, contentType: String) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/me/avatar", imageData)
        await clearCache()
        return result as? [String: Any] ?? [:]
    }
}
