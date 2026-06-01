import Foundation

// MARK: - UsersAPI

public final class UsersAPI: @unchecked Sendable {
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

    /// Retrieves basic profile information for a user by their ID.
    /// Results are cached with a default staleness threshold of 5 minutes.
    public func getBasic(userId: String, options: FetchCachedOptions? = nil) async throws -> [String: Any] {
        guard !userId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "userId is required")
        }

        guard let cache = cache else {
            let result = try await makeRequest("GET", "/users/\(userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId)/basic", nil)
            return result as? [String: Any] ?? [:]
        }

        let mergedOptions = FetchCachedOptions(
            waitForLoad: options?.waitForLoad,
            refreshNetwork: options?.refreshNetwork,
            refreshIfOlderThanMs: options?.refreshIfOlderThanMs ?? Self.defaultRefreshIfOlderThanMs,
            serverTimeoutMs: options?.serverTimeoutMs
        )

        let cacheKey = "user:\(userId)"
        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId

        let value = try await cache.fetchCached(
            key: cacheKey,
            fetcher: { [makeRequest] in
                try await makeRequest("GET", "/users/\(encodedUserId)/basic", nil)
            },
            options: mergedOptions
        )
        return value as? [String: Any] ?? [:]
    }

    /// Retrieve profiles for multiple users in a single batch request.
    /// Server caps at 100 ids per call.
    ///
    /// - Returns: The contents of the response's `profiles` array.
    ///   Users that don't exist or don't belong to the current app are
    ///   silently omitted (no per-id error).
    public func getProfiles(userIds: [String]) async throws -> [[String: Any]] {
        guard !userIds.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "userIds must be a non-empty array"
            )
        }
        let body: [String: Any] = ["userIds": userIds]
        let result = try await makeRequest("POST", "/users/profiles", body)
        if let dict = result as? [String: Any],
           let profiles = dict["profiles"] as? [[String: Any]] {
            return profiles
        }
        return []
    }

    /// Look up a user by email in the current app. Response:
    /// `{ "exists": Bool, "user"?: { "userId", "name", "email" } }`.
    public func lookup(email: String) async throws -> [String: Any] {
        let escaped = email.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? email
        let result = try await makeRequest("GET", "/users/lookup?email=\(escaped)", nil)
        return result as? [String: Any] ?? [:]
    }
}
