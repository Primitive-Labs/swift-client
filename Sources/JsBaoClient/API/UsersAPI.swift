import Foundation

// MARK: - UsersAPI

public final class UsersAPI: @unchecked Sendable {
    private let transport: any Transport
    private let cache: CacheFacade?

    private static let defaultRefreshIfOlderThanMs = 5 * 60 * 1000 // 5 minutes

    /// Designated initializer — the typed transport spine.
    public init(
        transport: any Transport,
        cache: CacheFacade? = nil
    ) {
        self.transport = transport
        self.cache = cache
    }

    /// Deprecated: construct with a `Transport` instead. The legacy closure is
    /// wrapped in an adapter so existing call sites keep working for one major
    /// cycle.
    @available(*, deprecated, message: "Use init(transport:) — the untyped makeRequest closure is removed in the next major release.")
    public convenience init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        cache: CacheFacade? = nil
    ) {
        self.init(transport: ClosureTransport(makeRequest: makeRequest), cache: cache)
    }

    /// Retrieves basic profile information for a user by their ID.
    /// Results are cached with a default staleness threshold of 5 minutes.
    public func getBasic(userId: String, options: GetUserOptions? = nil) async throws -> BasicUserInfo {
        guard !userId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "userId is required")
        }

        let encodedUserId = URLEncoding.encodeComponent(userId)

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
                return try await transport.request(
                    method: .get,
                    path: "/users/\(encodedUserId)/basic"
                )
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
            fetcher: { [transport] () async throws -> Any in
                // The response is decoded as a `JSONValue` and handed to the
                // cache as the JSON graph it persists (it round-trips through
                // `KvCache`'s storage); the typed decode happens below.
                let json: JSONValue = try await transport.request(
                    method: .get,
                    path: "/users/\(encodedUserId)/basic"
                )
                return try JSONCoding.jsonObject(from: json)
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
        // The server wraps the array in a `{ profiles }` envelope; accept a
        // bare array too for resilience. Users that don't exist or don't
        // belong to the current app are silently omitted.
        let response: BatchUserProfilesResponse = try await transport.request(
            method: .post,
            path: "/users/profiles",
            body: ["userIds": userIds]
        )
        return response.profiles
    }

    /// Look up a user by email in the current app. Returns a
    /// `UserLookupResult` with an `exists` flag and an optional `user`
    /// summary (`userId`, `name`, `email`).
    public func lookup(email: String) async throws -> UserLookupResult {
        var query = URLQuery()
        query.append("email", email)
        return try await transport.request(method: .get, path: "/users/lookup\(query.queryString)")
    }
}

// MARK: - Response shims

/// The batch-profiles endpoint returns a `{ profiles }` envelope; a bare
/// array is also accepted for resilience, and any other shape yields no
/// profiles (matching the previous `try?`-based leniency). Expressing that in
/// a `Decodable` keeps the shape probe out of the call site now that
/// responses are decoded straight from the wire bytes.
private struct BatchUserProfilesResponse: Decodable, Sendable {
    let profiles: [BatchUserProfile]

    private enum CodingKeys: String, CodingKey { case profiles }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.profiles) {
            // The envelope is present — decode it strictly, as before.
            profiles = try container.decode([BatchUserProfile].self, forKey: .profiles)
            return
        }
        if let container = try? decoder.singleValueContainer(),
           let list = try? container.decode([BatchUserProfile].self) {
            profiles = list
            return
        }
        profiles = []
    }
}
