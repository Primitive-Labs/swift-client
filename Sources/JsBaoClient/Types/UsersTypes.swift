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
    /// The user's properties a client may read: on another user, the fields
    /// whose `client` is `members` or `self-write-members`; on the caller's
    /// own row, also `self` and `self-write`. Defaults applied; `[:]` when
    /// the app declares none, and for an answer cached before the field
    /// existed.
    public let properties: [String: JSONValue]

    public init(
        userId: String,
        email: String,
        name: String? = nil,
        avatarUrl: String? = nil,
        appRole: String,
        appId: String,
        addedAt: String? = nil,
        properties: [String: JSONValue] = [:]
    ) {
        self.userId = userId
        self.email = email
        self.name = name
        self.avatarUrl = avatarUrl
        self.appRole = appRole
        self.appId = appId
        self.addedAt = addedAt
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey {
        case userId, email, name, avatarUrl, appRole, appId, addedAt, properties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        email = try c.decode(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        appRole = try c.decode(String.self, forKey: .appRole)
        appId = try c.decode(String.self, forKey: .appId)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
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
    /// The user's properties a client may read, as on
    /// `BasicUserInfo.properties`.
    public let properties: [String: JSONValue]

    public init(
        userId: String,
        email: String,
        name: String? = nil,
        avatarUrl: String? = nil,
        properties: [String: JSONValue] = [:]
    ) {
        self.userId = userId
        self.email = email
        self.name = name
        self.avatarUrl = avatarUrl
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey {
        case userId, email, name, avatarUrl, properties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        email = try c.decode(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
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
    /// The user's properties a client may read, as on
    /// `BasicUserInfo.properties`.
    public let properties: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case userId, name, email, properties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
    }
}

/// Result of `users.lookup(email:)`. Mirrors JS `UserLookupResult`
/// (`{ exists: boolean; user?: { userId; name; email; properties } }`).
public struct UserLookupResult: Decodable, Sendable, Equatable {
    public let exists: Bool
    public let user: UserLookupSummary?
}

// MARK: Options

/// Options controlling caching and loading behavior for `users.getBasic`.
/// Mirrors JS `GetUserOptions` field-for-field; this named type replaces
/// the generic `FetchCachedOptions` on the users surface (parity row D1).
public struct GetUserOptions: Sendable {
    /// Refreshes from the server in the background if the cached entry is
    /// older than this many seconds (default 5 minutes). The cached value is
    /// still returned immediately.
    public var refreshIfOlderThan: TimeInterval?
    /// Where to read from: local cache, network, or local-first with
    /// network fallback. Use `.network` when the call must wait for fresh
    /// server data.
    public var waitForLoad: WaitForLoadMode?
    /// When true, refreshes from the server even if the cached entry is
    /// fresh. The refresh runs behind the returned cached value, so it makes
    /// the *next* read current, not this one.
    public var refreshNetwork: Bool?
    /// Maximum time to wait for a server response before falling back.
    public var serverTimeout: TimeInterval?

    public init(
        refreshIfOlderThan: TimeInterval? = nil,
        waitForLoad: WaitForLoadMode? = nil,
        refreshNetwork: Bool? = nil,
        serverTimeout: TimeInterval? = nil
    ) {
        self.refreshIfOlderThan = refreshIfOlderThan
        self.waitForLoad = waitForLoad
        self.refreshNetwork = refreshNetwork
        self.serverTimeout = serverTimeout
    }
}
