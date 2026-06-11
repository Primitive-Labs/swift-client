import Foundation

// MARK: - AuthAPI
//
// Typed `client.auth` namespace for the NON-NATIVE auth surface (issue #964):
// magic-link, OTP, auth-config, logout, identity accessors, and the
// offline-grant suite. Native passkeys (#929) and OAuth/Google sign-in (#928)
// are DEFERRED and intentionally NOT surfaced here.
//
// Like `MeAPI` / `SessionAPI`, this is a thin facade that delegates to the
// internal `AuthController` via injected closures — it holds no auth state of
// its own. Closures keep `AuthController` out of the public API surface while
// letting `JsBaoClient` wire the real implementations.

public final class AuthAPI: @unchecked Sendable {
    // Identity / token accessors
    private let _getUserId: () -> String?
    private let _getToken: () -> String?
    private let _isAuthenticated: () -> Bool

    // Non-native sign-in flows
    private let _magicLinkRequest: (_ email: String, _ redirectUri: String) async throws -> Bool
    private let _magicLinkVerify: (_ token: String) async throws -> Any
    // Carries the optional #466 invite token through verify. When unwired,
    // `magicLinkVerify(token:inviteToken:)` falls back to the token-only path.
    private let _magicLinkVerifyWithInvite: ((_ token: String, _ inviteToken: String?) async throws -> Any)?
    private let _otpRequest: (_ email: String) async throws -> Bool
    private let _otpVerify: (_ email: String, _ code: String) async throws -> Any
    // Carries the optional #466 invite token through verify. When unwired,
    // `otpVerify` falls back to the email+code-only path.
    private let _otpVerifyWithInvite: ((_ email: String, _ code: String, _ inviteToken: String?) async throws -> Any)?

    // App auth config (`GET /oauth-config`)
    private let _getAuthConfig: () async throws -> Any
    // App-launch config subset. When unwired, derived from `_getAuthConfig`.
    private let _getAppConfig: (() async throws -> Any)?

    // Logout. `_logout` is the legacy wipeLocal-only closure retained for the
    // existing `JsBaoClient` wiring; `_logoutWithOptions`, when wired, carries
    // the full `LogoutOptions` bag (revokeOffline / clearOfflineIdentity /
    // waitForDisconnect) through to the controller.
    private let _logout: (_ wipeLocal: Bool) async throws -> Void
    private let _logoutWithOptions: ((_ options: LogoutOptions) async throws -> Void)?

    // Offline-grant suite
    private let _enableOfflineAccess: (_ options: EnableOfflineAccessOptions) async throws -> Any
    private let _unlockOffline: () async throws -> Bool
    private let _getOfflineGrantStatus: () -> OfflineGrantStatus
    private let _renewOfflineGrant: (_ options: EnableOfflineAccessOptions) async throws -> Bool
    private let _revokeOfflineGrant: (_ options: RevokeOfflineGrantOptions) async throws -> Void
    private let _hasOfflineGrantStored: () -> Bool

    public init(
        getUserId: @escaping () -> String?,
        getToken: @escaping () -> String?,
        isAuthenticated: @escaping () -> Bool,
        magicLinkRequest: @escaping (_ email: String, _ redirectUri: String) async throws -> Bool,
        magicLinkVerify: @escaping (_ token: String) async throws -> Any,
        magicLinkVerifyWithInvite: ((_ token: String, _ inviteToken: String?) async throws -> Any)? = nil,
        otpRequest: @escaping (_ email: String) async throws -> Bool,
        otpVerify: @escaping (_ email: String, _ code: String) async throws -> Any,
        otpVerifyWithInvite: ((_ email: String, _ code: String, _ inviteToken: String?) async throws -> Any)? = nil,
        getAuthConfig: @escaping () async throws -> Any,
        getAppConfig: (() async throws -> Any)? = nil,
        logout: @escaping (_ wipeLocal: Bool) async throws -> Void,
        logoutWithOptions: ((_ options: LogoutOptions) async throws -> Void)? = nil,
        enableOfflineAccess: @escaping (_ options: EnableOfflineAccessOptions) async throws -> Any,
        unlockOffline: @escaping () async throws -> Bool,
        getOfflineGrantStatus: @escaping () -> OfflineGrantStatus,
        renewOfflineGrant: @escaping (_ options: EnableOfflineAccessOptions) async throws -> Bool,
        revokeOfflineGrant: @escaping (_ options: RevokeOfflineGrantOptions) async throws -> Void,
        hasOfflineGrantStored: @escaping () -> Bool
    ) {
        self._getUserId = getUserId
        self._getToken = getToken
        self._isAuthenticated = isAuthenticated
        self._magicLinkRequest = magicLinkRequest
        self._magicLinkVerify = magicLinkVerify
        self._magicLinkVerifyWithInvite = magicLinkVerifyWithInvite
        self._otpRequest = otpRequest
        self._otpVerify = otpVerify
        self._otpVerifyWithInvite = otpVerifyWithInvite
        self._getAuthConfig = getAuthConfig
        self._getAppConfig = getAppConfig
        self._logout = logout
        self._logoutWithOptions = logoutWithOptions
        self._enableOfflineAccess = enableOfflineAccess
        self._unlockOffline = unlockOffline
        self._getOfflineGrantStatus = getOfflineGrantStatus
        self._renewOfflineGrant = renewOfflineGrant
        self._revokeOfflineGrant = revokeOfflineGrant
        self._hasOfflineGrantStored = hasOfflineGrantStored
    }

    // MARK: - Identity / token accessors

    /// The current user's id, or `nil` when unauthenticated.
    public func getUserId() -> String? { _getUserId() }

    /// The current access token, or `nil` when unauthenticated.
    public func getToken() -> String? { _getToken() }

    /// Whether the client currently holds an authenticated session.
    /// Mirrors JS `client.isAuthenticated()`.
    public func isAuthenticated() -> Bool { _isAuthenticated() }

    /// Block until a user id is available (e.g. while a persisted session
    /// rehydrates or a refresh completes), or throw on timeout. Mirrors JS
    /// `client.waitForUserId({ timeoutMs })` (default 5s). Returns immediately
    /// if a user id is already present.
    ///
    /// Implemented here by polling the injected `getUserId` accessor — the
    /// Swift `AuthController` exposes no event-driven waiter, so this matches
    /// the JS contract (resolve-with-id / throw-on-timeout) without one.
    @discardableResult
    public func waitForUserId(timeoutMs: Int = 5000) async throws -> String {
        if let uid = _getUserId() { return uid }

        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000.0)
        let pollIntervalNs: UInt64 = 50_000_000 // 50ms
        while Date() < deadline {
            if let uid = _getUserId() { return uid }
            try await Task.sleep(nanoseconds: pollIntervalNs)
        }
        if let uid = _getUserId() { return uid }
        throw AuthError(code: .unauthorized, message: "waitForUserId timeout")
    }

    // MARK: - Magic link

    /// Request a magic-link email. Mirrors JS
    /// `auth.magicLinkRequest({ email, redirectUri })`. Returns the typed
    /// `{ success }` result.
    public func magicLinkRequest(_ params: MagicLinkRequestParams) async throws -> MagicLinkRequestResult {
        let success = try await _magicLinkRequest(params.email, params.redirectUri)
        return MagicLinkRequestResult(success: success)
    }

    /// Convenience overload taking the fields directly.
    public func magicLinkRequest(email: String, redirectUri: String) async throws -> MagicLinkRequestResult {
        try await magicLinkRequest(MagicLinkRequestParams(email: email, redirectUri: redirectUri))
    }

    /// Verify a magic-link token, completing sign-in. On success the SDK has
    /// already applied the returned access token. Mirrors JS
    /// `auth.magicLinkVerify(token, { inviteToken })`.
    ///
    /// `inviteToken` (#466): when present, accepts the named invitation
    /// server-side during verify and resolves deferred grants to the
    /// signing-in user — even when the magic-link email differs from the
    /// invited email. Threaded through only when the invite-aware closure is
    /// wired; otherwise the token-only path is used.
    public func magicLinkVerify(token: String, inviteToken: String? = nil) async throws -> MagicLinkVerifyResult {
        let raw: Any
        if let verifyWithInvite = _magicLinkVerifyWithInvite {
            raw = try await verifyWithInvite(token, inviteToken)
        } else {
            raw = try await _magicLinkVerify(token)
        }
        return try JSONCoding.decode(MagicLinkVerifyResult.self, from: raw)
    }

    // MARK: - OTP

    /// Request a one-time-passcode email. Mirrors JS
    /// `auth.otpRequest({ email })`. Returns the typed `{ success }` result.
    public func otpRequest(email: String) async throws -> OtpRequestResult {
        let success = try await _otpRequest(email)
        return OtpRequestResult(success: success)
    }

    /// Verify an OTP code, completing sign-in. On success the SDK has already
    /// applied the returned access token. Mirrors JS
    /// `auth.otpVerify(email, code, { inviteToken })`.
    ///
    /// `inviteToken` (#466): when present, accepts the named invitation
    /// server-side during verify and resolves deferred grants to the
    /// signing-in user — even when the signup email differs from the invited
    /// email. Threaded through only when the invite-aware closure is wired;
    /// otherwise the email+code-only path is used.
    public func otpVerify(_ params: OtpVerifyParams) async throws -> OtpVerifyResult {
        let raw: Any
        if let verifyWithInvite = _otpVerifyWithInvite {
            raw = try await verifyWithInvite(params.email, params.code, params.inviteToken)
        } else {
            raw = try await _otpVerify(params.email, params.code)
        }
        return try JSONCoding.decode(OtpVerifyResult.self, from: raw)
    }

    /// Convenience overload taking the fields directly.
    public func otpVerify(email: String, code: String, inviteToken: String? = nil) async throws -> OtpVerifyResult {
        try await otpVerify(OtpVerifyParams(email: email, code: code, inviteToken: inviteToken))
    }

    // MARK: - Auth config

    /// Fetch the app's auth configuration (`GET /oauth-config`). Mirrors JS
    /// `auth.getAuthConfig()`, returning the typed `AuthConfigInfo`.
    public func getAuthConfig() async throws -> AuthConfigInfo {
        let raw = try await _getAuthConfig()
        return try JSONCoding.decode(AuthConfigInfo.self, from: raw)
    }

    /// Fetch the app-launch config subset (`appId`, `name`, `mode`,
    /// `waitlistEnabled`, `hasOAuth`, `hasPasskey`, `magicLinkEnabled`).
    /// Mirrors JS `client.getAppConfig()` — the 7-field projection of the
    /// `/oauth-config` envelope used to decide what login UI to show before a
    /// session exists. Decodes the same `/oauth-config` payload as
    /// `getAuthConfig()`; the extra fields are simply ignored.
    public func getAppConfig() async throws -> AppConfigInfo {
        let raw: Any
        if let getAppConfig = _getAppConfig {
            raw = try await getAppConfig()
        } else {
            raw = try await _getAuthConfig()
        }
        return try JSONCoding.decode(AppConfigInfo.self, from: raw)
    }

    // MARK: - Logout

    /// Sign out the current user. Mirrors JS `auth.logout(options)`. When the
    /// full-options closure is wired, the Swift `AuthController` honors
    /// `revokeOffline`, `wipeLocal`, `clearOfflineIdentity`, and
    /// `waitForDisconnect`; otherwise it falls back to the legacy
    /// `wipeLocal`-only path.
    public func logout(options: LogoutOptions = LogoutOptions()) async throws {
        if let logoutWithOptions = _logoutWithOptions {
            try await logoutWithOptions(options)
        } else {
            try await _logout(options.wipeLocal)
        }
    }

    // MARK: - Offline-grant suite

    /// Enable offline access by requesting a grant and storing it. Mirrors JS
    /// `auth.enableOfflineAccess(options)`, returning the typed
    /// `EnableOfflineAccessResult`.
    public func enableOfflineAccess(
        options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()
    ) async throws -> EnableOfflineAccessResult {
        let raw = try await _enableOfflineAccess(options)
        return try JSONCoding.decode(EnableOfflineAccessResult.self, from: raw)
    }

    /// Unlock a stored offline grant (triggers Face ID / Touch ID when the
    /// grant is biometric-protected). Mirrors JS `auth.unlockOffline()`.
    /// Returns whether the unlock succeeded.
    @discardableResult
    public func unlockOffline() async throws -> Bool {
        try await _unlockOffline()
    }

    /// Status of the stored offline grant (availability, expiry, method).
    /// Mirrors JS `auth.getOfflineGrantStatus()`.
    public func getOfflineGrantStatus() -> OfflineGrantStatus {
        _getOfflineGrantStatus()
    }

    /// Renew the offline grant while online. Mirrors JS
    /// `auth.renewOfflineGrantOnline(...)`. Returns whether renewal succeeded.
    @discardableResult
    public func renewOfflineGrant(
        options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()
    ) async throws -> Bool {
        try await _renewOfflineGrant(options)
    }

    /// Revoke the stored offline grant. Mirrors JS
    /// `auth.revokeOfflineGrant(options)`.
    public func revokeOfflineGrant(
        options: RevokeOfflineGrantOptions = RevokeOfflineGrantOptions()
    ) async throws {
        try await _revokeOfflineGrant(options)
    }

    /// Whether an offline grant is currently stored on this device. Mirrors
    /// JS `auth.hasOfflineGrantStored()` — backed by the Swift controller's
    /// `isOfflineGrantAvailable()` (Keychain presence check).
    public func hasOfflineGrantStored() -> Bool {
        _hasOfflineGrantStored()
    }
}
