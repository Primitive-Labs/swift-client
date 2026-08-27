import Foundation

// MARK: - Auth: typed request & response models
//
// Typed models for the auth surface exposed by `client.auth` (issue #964):
// magic-link, OTP, auth-config, logout, and the offline-grant suite.
// Passkey models (#929) live in `PasskeyTypes.swift`. Native Google sign-in
// (#928) lives in GoogleSignIn.swift (`JsBaoClient.signInWithGoogle`), not
// under `client.auth`.
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
/// Parameters for `auth.emailSignInRequest(...)` (#2884). Mirrors JS
/// `emailSignInRequest({ email, redirectUri })`.
///
/// `redirectUri` is optional, and omitting it is how a code-only email is
/// requested — the server issues one from the same unified template. A target
/// that IS supplied must match the app's non-empty `emailRedirectUris`
/// allow-list, or the request is rejected 400 `Invalid redirect URI` (#2967).
public struct EmailSignInRequestParams: Sendable {
    public var email: String
    public var redirectUri: String?

    public init(email: String, redirectUri: String? = nil) {
        self.email = email
        self.redirectUri = redirectUri
    }
}

/// Result of `auth.emailSignInRequest(...)`. Mirrors JS `{ success: boolean }`.
public struct EmailSignInRequestResult: Decodable, Sendable, Equatable {
    public let success: Bool
}

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

/// One Google client, as `/oauth-config` publishes it (#2891).
///
/// A projection of the stored entry, not the entry itself: no `clientSecret`
/// is ever published, and `usable` is the server's SHAPE verdict — a client id,
/// at least one redirect URI, and a client secret exactly when that client type
/// takes one. A consumer's availability predicate is that AND
/// `googleOAuthEnabled`, which is what `googleSignInAvailable` computes.
public struct GoogleClientConfig: Decodable, Sendable, Equatable {
    public let clientId: String
    public let redirectUris: [String]
    public let usable: Bool

    public init(clientId: String, redirectUris: [String], usable: Bool) {
        self.clientId = clientId
        self.redirectUris = redirectUris
        self.usable = usable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? ""
        redirectUris = try c.decodeIfPresent([String].self, forKey: .redirectUris) ?? []
        usable = try c.decodeIfPresent(Bool.self, forKey: .usable) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case clientId, redirectUris, usable
    }
}

/// The Google client map, keyed by client type (#2891).
///
/// Google registers a client PER PLATFORM — `web`, `ios`, `android`,
/// `desktop`, `chrome-extension` — so there is no single "is Google available"
/// flag to read: a native app reads its own `ios` entry, and a browser reads
/// `web`. Kept as a dictionary rather than an enum-keyed struct so a client
/// type added server-side decodes rather than throwing.
public struct GoogleClientsConfig: Decodable, Sendable, Equatable {
    public let clients: [String: GoogleClientConfig]

    public init(clients: [String: GoogleClientConfig]) {
        self.clients = clients
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clients =
            try c.decodeIfPresent([String: GoogleClientConfig].self, forKey: .clients) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case clients
    }
}

/// The client type a Swift app signs in through.
let nativeGoogleClientType = "ios"

/// The app's auth configuration, returned by `auth.getAuthConfig()`. Mirrors
/// the object JS `AuthController.getAuthConfig()` resolves to (the
/// `GET /oauth-config` envelope). The passkey fields pair with the native
/// passkey flows (#929 — see `AuthAPI+NativePasskeys.swift`); the OAuth
/// fields pair with native Google sign-in (#928); the Apple fields pair
/// with `signInWithApple` (#409 port).
public struct AuthConfigInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let name: String
    public let mode: String
    public let waitlistEnabled: Bool
    public let googleOAuthEnabled: Bool
    /// The typed client map (#2891). `nil` only against a server that predates
    /// it — which reports unavailable, the documented client-version floor.
    public let googleClients: GoogleClientsConfig?
    public let passkeyEnabled: Bool
    /// Opaque per-RP config map (`{ [rpId]: { name } }`) — kept as `JSONValue`
    /// because the shape is configuration data the SDK never introspects.
    public let passkeyRpConfig: JSONValue?
    public let hasPasskey: Bool
    /// Sign in with Apple (#409): enabled flag + the fully-configured
    /// gate (`appleAudiences` present AND not explicitly disabled).
    /// `false` against servers that predate the Apple port.
    public let appleSignInEnabled: Bool
    public let hasApple: Bool
    /// Is email sign-in available at all (#2884)? ONE flag: one request sends
    /// one email carrying a code and, when a link can be issued, a link, so
    /// there is no per-method availability to report.
    public let emailSignInEnabled: Bool
    /// - Warning: Deprecated by #2884. A server that has the unified flow
    ///   reports both of these equal to `emailSignInEnabled`; they exist so
    ///   already-published clients keep reading a value that matches
    ///   behavior. New code reads `emailSignInEnabled`.
    public let magicLinkEnabled: Bool
    public let otpEnabled: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decodeIfPresent(String.self, forKey: .appId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        waitlistEnabled = try c.decodeIfPresent(Bool.self, forKey: .waitlistEnabled) ?? false
        googleOAuthEnabled = try c.decodeIfPresent(Bool.self, forKey: .googleOAuthEnabled) ?? false
        googleClients = try c.decodeIfPresent(GoogleClientsConfig.self, forKey: .googleClients)
        passkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .passkeyEnabled) ?? false
        passkeyRpConfig = try c.decodeIfPresent(JSONValue.self, forKey: .passkeyRpConfig)
        hasPasskey = try c.decodeIfPresent(Bool.self, forKey: .hasPasskey) ?? false
        appleSignInEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleSignInEnabled) ?? false
        hasApple = try c.decodeIfPresent(Bool.self, forKey: .hasApple) ?? false
        magicLinkEnabled = try c.decodeIfPresent(Bool.self, forKey: .magicLinkEnabled) ?? false
        otpEnabled = try c.decodeIfPresent(Bool.self, forKey: .otpEnabled) ?? false
        // A server that predates #2884 sends no `emailSignInEnabled` at all,
        // so derive it from the pair it replaced: email sign-in is off only
        // when BOTH legacy flags are explicitly false. Reading the absent key
        // as `false` would black out the email button against every older
        // server.
        emailSignInEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .emailSignInEnabled)
            ?? (magicLinkEnabled || otpEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case appId, name, mode, waitlistEnabled, googleOAuthEnabled, googleClients
        case passkeyEnabled
        case passkeyRpConfig, hasPasskey, appleSignInEnabled, hasApple
        case emailSignInEnabled, magicLinkEnabled, otpEnabled
    }
}

extension AuthConfigInfo {
    /// The `ios` entry, or `nil` when this app has no native Google client.
    public var nativeGoogleClient: GoogleClientConfig? {
        googleClients?.clients[nativeGoogleClientType]
    }

    /// Can THIS (native) client start Google sign-in right now?
    ///
    /// The enable flag AND the `ios` entry's shape, together (DSO-2891-001).
    /// One property so a login view's button and its action cannot disagree —
    /// which is exactly what the removed `hasOAuth` let them do: it was
    /// clientId-only, so a web-only app rendered a button whose PKCE exchange
    /// failed at Google.
    public var googleSignInAvailable: Bool {
        guard googleOAuthEnabled, let entry = nativeGoogleClient else { return false }
        return entry.usable && !entry.clientId.isEmpty
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
    /// Whether THIS (native) client can start Google sign-in — the provider
    /// enabled and the `ios` entry usable (#2891). It replaced the server's
    /// `hasOAuth`, which could not tell a web-configured app from a
    /// native-configured one and so was wrong in one direction or the other.
    public let googleAvailable: Bool
    public let hasPasskey: Bool
    public let magicLinkEnabled: Bool

    public init(
        appId: String,
        name: String,
        mode: String,
        waitlistEnabled: Bool,
        googleAvailable: Bool,
        hasPasskey: Bool,
        magicLinkEnabled: Bool
    ) {
        self.appId = appId
        self.name = name
        self.mode = mode
        self.waitlistEnabled = waitlistEnabled
        self.googleAvailable = googleAvailable
        self.hasPasskey = hasPasskey
        self.magicLinkEnabled = magicLinkEnabled
    }

    /// Project the launch-UI subset out of the full envelope.
    ///
    /// Derived rather than decoded, so the two views of the same response
    /// cannot disagree about whether to offer the Google button.
    public init(from config: AuthConfigInfo) {
        self.init(
            appId: config.appId,
            name: config.name,
            mode: config.mode.isEmpty ? "public" : config.mode,
            waitlistEnabled: config.waitlistEnabled,
            googleAvailable: config.googleSignInAvailable,
            hasPasskey: config.hasPasskey,
            magicLinkEnabled: config.magicLinkEnabled
        )
    }

    public init(from decoder: Decoder) throws {
        // The `/oauth-config` envelope carries no `googleAvailable` key — it is
        // a client-side predicate over the map — so decoding goes through the
        // full type and projects, rather than restating the rule here.
        self.init(from: try AuthConfigInfo(from: decoder))
    }
}

// MARK: OAuth / Apple callback

/// Result of a native OAuth code exchange — `handleOAuthCallback` (Google)
/// and `handleAppleCallback` (Sign in with Apple). Mirrors the server's
/// `{ token, isNewUser }` response. The SDK has already applied `token`
/// (cause `"oauthCallback"` / `"apple"`) by the time this is returned; callers read
/// it for `isNewUser` to branch on first-time signup.
public struct OAuthCallbackResult: Decodable, Sendable, Equatable {
    /// The access token the SDK applied.
    public let token: String
    /// `true` when the exchange created a brand-new account.
    public let isNewUser: Bool?

    public init(token: String, isNewUser: Bool? = nil) {
        self.token = token
        self.isNewUser = isNewUser
    }
}

// MARK: OAuth flow options

/// Waitlist enrollment carried through the OAuth state bag. Mirrors the JS
/// `startOAuthFlow(continueUrl, { waitlist })` shape
/// (`{ source?: string | null; note?: string | null }`). When present, the
/// OAuth callback enrolls the user in the app's waitlist. Both fields are
/// trimmed and clamped to 255 characters before being embedded in the state,
/// matching the JS client (src/client/internal/authController.ts).
public struct OAuthWaitlist: Sendable {
    /// Optional acquisition source (e.g. a campaign tag).
    public var source: String?
    /// Optional free-form note recorded with the waitlist entry.
    public var note: String?

    public init(source: String? = nil, note: String? = nil) {
        self.source = source
        self.note = note
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
