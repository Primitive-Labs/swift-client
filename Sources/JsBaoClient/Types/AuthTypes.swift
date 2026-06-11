import Foundation

// MARK: - Auth: typed request & response models
//
// Typed models for the NON-NATIVE auth surface exposed by `client.auth`
// (issue #964): magic-link, OTP, auth-config, logout, and the offline-grant
// suite. Native passkeys (#929) and OAuth/Google sign-in (#928) are DEFERRED
// and intentionally NOT modeled here.
//
// Shapes mirror the JS client (`src/client/internal/authController.ts`):
// timestamps stay as ISO-8601 `String`s exactly as JS exposes them, and only
// genuinely-opaque blobs fall back to `JSONValue`.

// MARK: Authenticated user (magic-link / OTP verify result)

/// The signed-in user returned by `magicLinkVerify` / `otpVerify`.
/// Mirrors JS `{ userId: string; email: string; name?: string }`.
public struct AuthUser: Decodable, Sendable, Equatable {
    public let userId: String
    public let email: String
    public let name: String?
}

// MARK: Magic link

/// Parameters for `auth.magicLinkRequest(...)`. Mirrors JS
/// `magicLinkRequest({ email, redirectUri })`.
public struct MagicLinkRequestParams: Sendable {
    public var email: String
    public var redirectUri: String

    public init(email: String, redirectUri: String) {
        self.email = email
        self.redirectUri = redirectUri
    }
}

/// Result of `auth.magicLinkRequest(...)`. Mirrors JS `{ success: boolean }`.
public struct MagicLinkRequestResult: Decodable, Sendable, Equatable {
    public let success: Bool
}

/// Result of `auth.magicLinkVerify(...)`. Mirrors JS
/// `{ user, promptAddPasskey?, isNewUser? }`. On success the SDK has already
/// applied the returned access token internally.
public struct MagicLinkVerifyResult: Decodable, Sendable, Equatable {
    public let user: AuthUser
    /// Server hint that the UI may prompt the user to add a passkey.
    public let promptAddPasskey: Bool?
    /// `true` when this verification created a brand-new account.
    public let isNewUser: Bool?
}

// MARK: OTP

/// Result of `auth.otpRequest(...)`. Mirrors JS `{ success: boolean }`.
public struct OtpRequestResult: Decodable, Sendable, Equatable {
    public let success: Bool
}

/// Parameters for `auth.otpVerify(...)`. Mirrors JS
/// `otpVerify(email, code, { inviteToken })`.
public struct OtpVerifyParams: Sendable {
    public var email: String
    public var code: String
    /// Optional invitation token (#466): when present, the server accepts
    /// the named invitation during verify and resolves deferred grants to
    /// the signing-in user — even when the signup email differs from the
    /// invited email. Mirrors JS `otpVerify(email, code, { inviteToken })`.
    public var inviteToken: String?

    public init(email: String, code: String, inviteToken: String? = nil) {
        self.email = email
        self.code = code
        self.inviteToken = inviteToken
    }
}

/// Result of `auth.otpVerify(...)`. Mirrors JS `{ user, isNewUser? }`.
/// On success the SDK has already applied the returned access token.
public struct OtpVerifyResult: Decodable, Sendable, Equatable {
    public let user: AuthUser
    /// `true` when this verification created a brand-new account.
    public let isNewUser: Bool?
}

// MARK: Auth config

/// The app's auth configuration, returned by `auth.getAuthConfig()`. Mirrors
/// the object JS `AuthController.getAuthConfig()` resolves to (the
/// `GET /oauth-config` envelope). The passkey/OAuth fields are surfaced for
/// completeness (so a UI can decide what to show) even though the native
/// flows themselves are deferred (#928 / #929).
public struct AuthConfigInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let name: String
    public let mode: String
    public let waitlistEnabled: Bool
    public let googleOAuthEnabled: Bool
    public let googleClientId: String?
    public let hasOAuth: Bool
    public let redirectUris: [String]?
    public let passkeyEnabled: Bool
    public let passkeyRpId: String?
    public let passkeyRpName: String?
    /// Opaque per-RP config map (`{ [rpId]: { name } }`) — kept as `JSONValue`
    /// because the shape is configuration data the SDK never introspects.
    public let passkeyRpConfig: JSONValue?
    public let hasPasskey: Bool
    public let magicLinkEnabled: Bool
    public let otpEnabled: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decodeIfPresent(String.self, forKey: .appId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        waitlistEnabled = try c.decodeIfPresent(Bool.self, forKey: .waitlistEnabled) ?? false
        googleOAuthEnabled = try c.decodeIfPresent(Bool.self, forKey: .googleOAuthEnabled) ?? false
        googleClientId = try c.decodeIfPresent(String.self, forKey: .googleClientId)
        hasOAuth = try c.decodeIfPresent(Bool.self, forKey: .hasOAuth) ?? false
        redirectUris = try c.decodeIfPresent([String].self, forKey: .redirectUris)
        passkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .passkeyEnabled) ?? false
        passkeyRpId = try c.decodeIfPresent(String.self, forKey: .passkeyRpId)
        passkeyRpName = try c.decodeIfPresent(String.self, forKey: .passkeyRpName)
        passkeyRpConfig = try c.decodeIfPresent(JSONValue.self, forKey: .passkeyRpConfig)
        hasPasskey = try c.decodeIfPresent(Bool.self, forKey: .hasPasskey) ?? false
        magicLinkEnabled = try c.decodeIfPresent(Bool.self, forKey: .magicLinkEnabled) ?? false
        otpEnabled = try c.decodeIfPresent(Bool.self, forKey: .otpEnabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case appId, name, mode, waitlistEnabled, googleOAuthEnabled, googleClientId
        case hasOAuth, redirectUris, passkeyEnabled, passkeyRpId, passkeyRpName
        case passkeyRpConfig, hasPasskey, magicLinkEnabled, otpEnabled
    }
}

// MARK: App config (launch-UI subset)

/// The app-launch config subset returned by `auth.getAppConfig()` /
/// `client.getAppConfig()`. Mirrors the typed 7-field object JS
/// `getAppConfig()` resolves to — the projection of the `/oauth-config`
/// envelope used to decide which login affordances to show before a session
/// exists. (`getAuthConfig()` returns the typed superset `AuthConfigInfo`.)
public struct AppConfigInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let name: String
    /// One of `"public"`, `"invite-only"`, or `"domain"` (kept as `String` to
    /// stay forward-compatible with new server modes, matching how
    /// `AuthConfigInfo.mode` is modeled).
    public let mode: String
    public let waitlistEnabled: Bool
    public let hasOAuth: Bool
    public let hasPasskey: Bool
    public let magicLinkEnabled: Bool

    public init(
        appId: String,
        name: String,
        mode: String,
        waitlistEnabled: Bool,
        hasOAuth: Bool,
        hasPasskey: Bool,
        magicLinkEnabled: Bool
    ) {
        self.appId = appId
        self.name = name
        self.mode = mode
        self.waitlistEnabled = waitlistEnabled
        self.hasOAuth = hasOAuth
        self.hasPasskey = hasPasskey
        self.magicLinkEnabled = magicLinkEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decodeIfPresent(String.self, forKey: .appId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "public"
        waitlistEnabled = try c.decodeIfPresent(Bool.self, forKey: .waitlistEnabled) ?? false
        hasOAuth = try c.decodeIfPresent(Bool.self, forKey: .hasOAuth) ?? false
        hasPasskey = try c.decodeIfPresent(Bool.self, forKey: .hasPasskey) ?? false
        magicLinkEnabled = try c.decodeIfPresent(Bool.self, forKey: .magicLinkEnabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case appId, name, mode, waitlistEnabled, hasOAuth, hasPasskey, magicLinkEnabled
    }
}

// MARK: Logout

/// Options for `auth.logout(...)`. Mirrors the JS `logout(options)` bag
/// (`revokeOffline`, `wipeLocal`, `clearOfflineIdentity`) plus the
/// Swift-specific `waitForDisconnect`. (`redirectTo` is web-only
/// `window.location` and is intentionally not modeled.) The Swift
/// `AuthController.logout` honors all four fields.
public struct LogoutOptions: Sendable {
    /// Also revoke any stored offline grant.
    public var revokeOffline: Bool
    /// Wipe locally-cached data on the way out.
    public var wipeLocal: Bool
    /// Clear the in-memory offline identity (defaults to `true` in JS).
    public var clearOfflineIdentity: Bool
    /// Await WebSocket teardown before returning (no JS analog — JS logout is
    /// fire-and-forget on the socket). Defaults to `false`.
    public var waitForDisconnect: Bool

    public init(
        revokeOffline: Bool = false,
        wipeLocal: Bool = false,
        clearOfflineIdentity: Bool = true,
        waitForDisconnect: Bool = false
    ) {
        self.revokeOffline = revokeOffline
        self.wipeLocal = wipeLocal
        self.clearOfflineIdentity = clearOfflineIdentity
        self.waitForDisconnect = waitForDisconnect
    }
}

// MARK: Offline access result

/// Result of `auth.enableOfflineAccess(...)`. Mirrors JS
/// `{ enabled: boolean; method?; reason? }`. Decoded from the grant
/// response the controller returns.
public struct EnableOfflineAccessResult: Decodable, Sendable, Equatable {
    /// Whether offline access is now enabled. Defaults to `true` when the
    /// controller succeeds but the response omits the flag (the JS happy path
    /// returns `{ enabled: true }`).
    public let enabled: Bool
    /// The unlock method established (`"largeBlob"`, `"pin"`, or `"signed"`).
    public let method: String?
    /// Reason offline access could not be enabled, when `enabled` is false.
    public let reason: String?

    public init(enabled: Bool, method: String? = nil, reason: String? = nil) {
        self.enabled = enabled
        self.method = method
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The controller returns the raw grant dict on success (no `enabled`
        // key); treat a decodable response as enabled unless told otherwise.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        method = try c.decodeIfPresent(String.self, forKey: .method)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, method, reason
    }
}
