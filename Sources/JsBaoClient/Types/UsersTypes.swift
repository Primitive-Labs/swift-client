import Foundation

// MARK: - Users: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/usersApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes.

// MARK: Profiles

/// Basic profile information for a single user, as returned by
/// `users.getBasic`. Mirrors JS `BasicUserInfo`.
public struct BasicUserInfo: Decodable, Sendable, Equatable {
    public let userId: String
    public let email: String
    /// Optional: `users-controller.ts` (`getBasic`) omits `name` when unset
    /// (JS types it `string` but the server never guarantees it).
    public let name: String?
    public let avatarUrl: String?
    public let appRole: String
    public let appId: String
    public let addedAt: String?

    public init(
        userId: String,
        email: String,
        name: String? = nil,
        avatarUrl: String? = nil,
        appRole: String,
        appId: String,
        addedAt: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.name = name
        self.avatarUrl = avatarUrl
        self.appRole = appRole
        self.appId = appId
        self.addedAt = addedAt
    }
}

/// A profile returned by the batch `users.getProfiles` lookup. Mirrors JS
/// `BatchUserProfile` — note `name` and `avatarUrl` are nullable here
/// (unlike `BasicUserInfo.name`).
public struct BatchUserProfile: Decodable, Sendable, Equatable {
    public let userId: String
    public let email: String
    public let name: String?
    public let avatarUrl: String?

    public init(
        userId: String,
        email: String,
        name: String? = nil,
        avatarUrl: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

// MARK: Lookup

/// The `user` summary embedded in a `UserLookupResult` when the email
/// resolves to an app member.
public struct UserLookupSummary: Decodable, Sendable, Equatable {
    public let userId: String
    /// Optional: `users-controller.ts` (`lookup`) omits `name` when unset.
    public let name: String?
    public let email: String
}

/// Result of `users.lookup(email:)`. Mirrors JS
/// `{ exists: boolean; user?: { userId; name; email } }`.
public struct UserLookupResult: Decodable, Sendable, Equatable {
    public let exists: Bool
    public let user: UserLookupSummary?
}

// MARK: Options

/// Options controlling caching and loading behavior for `users.getBasic`.
/// Mirrors JS `GetUserOptions` field-for-field; this named type replaces
/// the generic `FetchCachedOptions` on the users surface (parity row D1).
public struct GetUserOptions: Sendable {
    /// Re-fetches from the server if the cached entry is older than this
    /// many milliseconds (default 5 minutes).
    public var refreshIfOlderThanMs: Int?
    /// Where to read from: local cache, network, or local-first with
    /// network fallback.
    public var waitForLoad: WaitForLoadMode?
    /// When true, forces a network fetch even if cached data exists.
    public var refreshNetwork: Bool?
    /// Maximum time in milliseconds to wait for a server response before
    /// falling back.
    public var serverTimeoutMs: Int?

    public init(
        refreshIfOlderThanMs: Int? = nil,
        waitForLoad: WaitForLoadMode? = nil,
        refreshNetwork: Bool? = nil,
        serverTimeoutMs: Int? = nil
    ) {
        self.refreshIfOlderThanMs = refreshIfOlderThanMs
        self.waitForLoad = waitForLoad
        self.refreshNetwork = refreshNetwork
        self.serverTimeoutMs = serverTimeoutMs
    }
}
