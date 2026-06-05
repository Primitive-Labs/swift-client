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
    public func getBasic(userId: String, options: GetUserOptions? = nil) async throws -> BasicUserInfo {
        guard !userId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "userId is required")
        }

        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId

        guard let cache = cache else {
            // No cache facade injected (only the standalone-test construction
            // path; the real client at `JsBaoClient` always wires one). True
            // caching and the `refreshIfOlderThanMs` staleness window can't
            // apply without a `KvCache` to persist into, but we still honor the
            // `waitForLoad` read-location semantics so `GetUserOptions` isn't
            // silently dropped (the parity gap this fixes). `refreshNetwork`
            // and `serverTimeoutMs` only modulate a cache-backed fetch, so they
            // are no-ops here.
            switch options?.waitForLoad ?? .localIfAvailableElseNetwork {
            case .local:
                // Cache-only read, mirroring `CacheFacade.fetchCached`'s
                // `.local` branch — with no cache there is nothing local to
                // return.
                throw JsBaoError(code: .notFound, message: "User \(userId) not found")
            case .network, .localIfAvailableElseNetwork:
                let result = try await makeRequest("GET", "/users/\(encodedUserId)/basic", nil)
                return try JSONCoding.decode(BasicUserInfo.self, from: result)
            }
        }

        // Map the named `GetUserOptions` onto the cache facade's generic
        // options bag, preserving the 5-minute default staleness threshold.
        let mergedOptions = FetchCachedOptions(
            waitForLoad: options?.waitForLoad,
            refreshNetwork: options?.refreshNetwork,
            refreshIfOlderThanMs: options?.refreshIfOlderThanMs ?? Self.defaultRefreshIfOlderThanMs,
            serverTimeoutMs: options?.serverTimeoutMs
        )

        let cacheKey = "user:\(userId)"

        // The cache stores the raw JSON `Any` graph (round-trips losslessly
        // through KvCache); decode it into the typed model on the way out so
        // the cache path stays untyped end-to-end and only the public return
        // is typed.
        let value = try await cache.fetchCached(
            key: cacheKey,
            fetcher: { [makeRequest] in
                try await makeRequest("GET", "/users/\(encodedUserId)/basic", nil)
            },
            options: mergedOptions
        )
        guard let value = value else {
            throw JsBaoError(code: .notFound, message: "User \(userId) not found")
        }
        return try JSONCoding.decode(BasicUserInfo.self, from: value)
    }

    /// Retrieve profiles for multiple users in a single batch request.
    /// Server caps at 100 ids per call.
    ///
    /// - Returns: The contents of the response's `profiles` array.
    ///   Users that don't exist or don't belong to the current app are
    ///   silently omitted (no per-id error).
    public func getProfiles(userIds: [String]) async throws -> [BatchUserProfile] {
        guard !userIds.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "userIds must be a non-empty array"
            )
        }
        let body: [String: Any] = ["userIds": userIds]
        let result = try await makeRequest("POST", "/users/profiles", body)
        // The server wraps the array in a `{ profiles }` envelope; accept a
        // bare array too for resilience. Users that don't exist or don't
        // belong to the current app are silently omitted.
        if let dict = result as? [String: Any], let profiles = dict["profiles"] {
            return try JSONCoding.decode([BatchUserProfile].self, from: profiles)
        }
        return (try? JSONCoding.decode([BatchUserProfile].self, from: result)) ?? []
    }

    /// Look up a user by email in the current app. Returns a
    /// `UserLookupResult` with an `exists` flag and an optional `user`
    /// summary (`userId`, `name`, `email`).
    public func lookup(email: String) async throws -> UserLookupResult {
        let escaped = email.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? email
        let result = try await makeRequest("GET", "/users/lookup?email=\(escaped)", nil)
        return try JSONCoding.decode(UserLookupResult.self, from: result)
    }
}
