import Foundation

/// Manages authentication state, token lifecycle, OAuth flows, and offline access.
public final class AuthController: @unchecked Sendable {
    private let lock = NSLock()

    // Dependencies
    private let appId: String
    private let apiUrl: String
    private let logger: Logger
    private let offlineStore: OfflineStore
    private weak var emitter: EventEmitter?
    private let refreshProxy: RefreshProxyConfig?
    private let persistConfig: AuthConfig

    // State
    private var currentToken: String?
    private var jwtPayload: [String: Any]?
    private var currentUserId: String?
    private var networkMode: NetworkMode = .auto
    private var authReady = false
    private var authReadyContinuations: [CheckedContinuation<Void, Never>] = []

    /// Set true on `logout()`; blocks NON-interactive token applications
    /// (a `bootstrap`/`http_refresh`/`refresh`/`startup` that resolves
    /// after the user logged out) from silently re-authenticating or
    /// re-persisting the JWT. Cleared by the next interactive login
    /// (`google`/`oauth`/`apple`/`magic_link`/`otp`/`passkey`). Guarded by `lock`.
    private var blockNonInteractiveAuth = false

    // Refresh backoff
    private var refreshBackoffMs: Int = 2000
    private let refreshBackoffBase: Int = 2000
    private let refreshBackoffMax: Int = 300_000
    private var lastRefreshAttempt: Date?

    // In-flight JWT persistence task. Tracked so destroy() can await
    // outstanding writes before the storage layer closes the SQLite
    // connection — without this, a fresh client opening the same DB file
    // races against the prior session's write and hits SQLITE_BUSY
    // ("database is locked").
    private var pendingPersistTask: Task<Void, Never>?

    // Offline access grant
    private let keychainHelper: KeychainHelper
    private var offlineIdentity: OfflineIdentity?

    // PKCE: code_verifier from the most recent startOAuthFlow call, held
    // until handleOAuthCallback consumes it. Native (iOS) Google OAuth
    // clients have no client_secret and prove possession of the auth code
    // via PKCE (RFC 7636) instead. Guarded by `lock`.
    private var pendingCodeVerifier: String?

    // Request function (set externally to break circular dependency)
    var makeRequest: ((String, String, Any?) async throws -> Any?)?

    public init(
        appId: String,
        apiUrl: String,
        logger: Logger,
        offlineStore: OfflineStore,
        emitter: EventEmitter,
        refreshProxy: RefreshProxyConfig?,
        persistConfig: AuthConfig
    ) {
        self.appId = appId
        self.apiUrl = apiUrl
        self.logger = logger.forScope(scope: "auth")
        self.offlineStore = offlineStore
        self.emitter = emitter
        self.refreshProxy = refreshProxy
        self.persistConfig = persistConfig
        self.keychainHelper = KeychainHelper(service: "com.primitive.\(appId).offline")
    }

    // MARK: - Token Management

    public func getToken() -> String? {
        return lock.withLock { currentToken }
    }

    public func getUserId() -> String? {
        return lock.withLock { currentUserId }
    }

    public func isAuthenticated() -> Bool {
        return lock.withLock { currentToken != nil && currentUserId != nil }
    }

    public func getAuthState() -> AuthState {
        return lock.withLock {
            AuthState(
                authenticated: currentToken != nil,
                mode: networkMode,
                userId: currentUserId
            )
        }
    }

    public func getJwtPayload() -> [String: Any]? {
        return lock.withLock { jwtPayload }
    }

    /// Bootstrap with an initial token (on startup)
    public func bootstrapToken(_ token: String?) {
        guard let token = token, !token.isEmpty else {
            markAuthReady()
            return
        }
        applyToken(token, previous: nil, cause: "bootstrap")
        markAuthReady()
    }

    /// Update the current token
    public func updateToken(_ token: String?, cause: String? = nil) {
        let previous = getToken()
        applyToken(token, previous: previous, cause: cause)
    }

    /// Causes that represent an explicit, user-initiated sign-in (as
    /// opposed to a background token refresh or persisted-session restore).
    private static func isInteractiveLogin(_ cause: String?) -> Bool {
        switch cause {
        case "google", "oauth", "apple", "magic_link", "otp", "passkey": return true
        default: return false
        }
    }

    /// Apply a new token, updating internal state and emitting events
    func applyToken(_ token: String?, previous: String?, cause: String?) {
        // Logout race guard: a refresh/restore that resolves AFTER the
        // user logged out must not silently sign them back in (or
        // re-persist the JWT). Drop non-interactive token applications
        // until an explicit interactive login clears the flag.
        // The check-and-mutate stays atomic in one critical section; a
        // `nil` result signals the guard dropped the application so we
        // log and return outside the lock exactly as before.
        let applied: (newUserId: String?, newToken: String?)? = lock.withLock {
            if token != nil, blockNonInteractiveAuth, !Self.isInteractiveLogin(cause) {
                return nil
            }
            if token != nil, Self.isInteractiveLogin(cause) {
                blockNonInteractiveAuth = false
            }
            currentToken = token

            if let token = token {
                let payload = Self.parseJwtPayload(token: token)
                jwtPayload = payload
                currentUserId = payload?["userId"] as? String ?? payload?["sub"] as? String
            } else {
                jwtPayload = nil
                currentUserId = nil
            }
            return (currentUserId, currentToken)
        }

        guard let (newUserId, newToken) = applied else {
            logger.debug("Ignoring token application (cause:", cause ?? "unknown", ") — logged out, awaiting explicit login")
            return
        }

        if let newToken = newToken {
            logger.debug("Token applied", "userId:", newUserId ?? "nil", "cause:", cause ?? "unknown")
            emitter?.emit(.authSuccess, AuthSuccessEvent(
                token: newToken,
                previousToken: previous,
                cause: cause
            ))
            emitter?.emit(.authState, AuthStateEvent(
                authenticated: true,
                mode: networkMode,
                userId: newUserId
            ))
        } else if previous != nil {
            emitter?.emit(.authState, AuthStateEvent(
                authenticated: false,
                mode: networkMode,
                userId: nil
            ))
        }

        // Persist JWT if configured
        if persistConfig.persistJwtInStorage, let token = newToken {
            let task: Task<Void, Never> = Task { [logger] in
                do {
                    try await persistJwt(token: token)
                } catch {
                    // Don't swallow persistence errors silently — without this
                    // log, a disk-full or SQLite-corruption issue would leave
                    // the user appearing logged in until restart, with no clue
                    // why they were unexpectedly logged out the next session.
                    logger.warn("Failed to persist JWT:", error.localizedDescription)
                }
            }
            lock.withLock { pendingPersistTask = task }
        }
    }

    /// Wait for any in-flight JWT persistence to drain. Called from
    /// `JsBaoClient.destroy()` so the storage layer doesn't close the
    /// SQLite connection out from under a queued write. Safe to call
    /// when no Task is in flight (no-op).
    public func awaitPendingPersistence() async {
        let task = lock.withLock { pendingPersistTask }
        await task?.value
    }

    // MARK: - Token Refresh

    /// In-flight refresh Task. When non-nil, concurrent refresh callers
    /// await *this* Task instead of starting a duplicate refresh — so a
    /// burst of N concurrent 401s on the wire produces exactly **one**
    /// `POST /auth/refresh` round trip, not N. Mirrors the JS client's
    /// refresh-coalescing behavior, and on servers that rotate refresh
    /// cookies (revoking the prior refresh JWT after each successful
    /// refresh) prevents the "first call wins, others see 401, cascade
    /// of auth-failed events" failure mode.
    private var pendingRefresh: Task<RefreshOutcome, Never>?

    public func refreshAccessToken(cause: String? = nil) async -> RefreshOutcome {
        // Coalesce: if another caller is already running a refresh,
        // await its outcome instead of starting a new round trip. The
        // check-and-register must be atomic so a burst of concurrent
        // callers registers exactly one refresh Task — hence a single
        // `withLock`. The refresh itself runs in the escaping `Task{}`
        // and is awaited OUTSIDE the lock (never hold the lock across an
        // `await`); single-flight is preserved.
        enum RefreshStart {
            case existing(Task<RefreshOutcome, Never>)
            case started(Task<RefreshOutcome, Never>)
        }
        let start: RefreshStart = lock.withLock {
            if let inFlight = pendingRefresh {
                return .existing(inFlight)
            }
            let task = Task<RefreshOutcome, Never> { [weak self] in
                guard let self = self else { return .network }
                return await self._refreshAccessTokenImpl(cause: cause)
            }
            pendingRefresh = task
            return .started(task)
        }

        switch start {
        case .existing(let inFlight):
            return await inFlight.value
        case .started(let task):
            let outcome = await task.value
            lock.withLock { pendingRefresh = nil }
            return outcome
        }
    }

    private func _refreshAccessTokenImpl(cause: String? = nil) async -> RefreshOutcome {
        logger.debug("Refreshing access token", "cause:", cause ?? "unknown")

        do {
            let newToken: String

            if let proxy = refreshProxy, proxy.enabled {
                newToken = try await refreshViaProxy(proxy: proxy)
            } else {
                newToken = try await refreshDirect()
            }

            lock.withLock { refreshBackoffMs = refreshBackoffBase }

            let previous = getToken()
            applyToken(newToken, previous: previous, cause: "refresh")
            return .success
        } catch let error as HttpError where error.status == 401 || error.status == 403 {
            logger.warn("Token refresh returned invalid:", error.status)
            emitter?.emit(.authFailed, AuthFailedEvent(
                message: "Token refresh failed: \(error.message)",
                reason: "invalid_token"
            ))
            return .invalid
        } catch {
            logger.warn("Token refresh network error:", error.localizedDescription)

            lock.withLock { refreshBackoffMs = min(refreshBackoffMs * 2, refreshBackoffMax) }

            emitter?.emit(.authRefreshDeferred, [
                "status": "scheduled",
                "cause": cause ?? "network_error",
                "nextAttemptMs": refreshBackoffMs,
            ] as [String: Any])

            return .network
        }
    }

    /// Handle a 401 challenge from the server
    public func handleAuthChallenge(reason: String? = nil) async -> Bool {
        let outcome = await refreshAccessToken(cause: reason ?? "auth_challenge")
        return outcome == .success
    }

    // MARK: - JWT Parsing

    public static func parseJwtPayload(token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        // Pad base64 to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Check if a token is expiring within the given threshold (seconds)
    public static func isTokenExpiring(token: String, thresholdSeconds: TimeInterval = 120) -> Bool {
        guard let payload = parseJwtPayload(token: token),
              let exp = payload["exp"] as? TimeInterval else {
            return false
        }
        return exp - Date().timeIntervalSince1970 < thresholdSeconds
    }

    // MARK: - OAuth

    /// Start the OAuth flow. Mirrors JS `authController.startOAuthFlow`
    /// (src/client/internal/authController.ts): fetch the app's auth config
    /// (`GET /oauth-config`), require a `googleClientId`, and build the Google
    /// authorize URL client-side with the base64-JSON state bag
    /// `{nonce, redirectUri, continueUrl?}`. Where the JS client redirects the
    /// browser, this returns the URL for the caller to open (e.g. via
    /// `ASWebAuthenticationSession` — see `JsBaoClient.signInWithGoogle`).
    public func startOAuthFlow(
        redirectUri: String,
        continueUrl: String? = nil,
        waitlist: OAuthWaitlist? = nil,
        inviteToken: String? = nil
    ) async throws -> URL {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let response = try await makeRequest("GET", "/oauth-config", nil)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid OAuth config response")
        }
        guard let googleClientId = dict["googleClientId"] as? String,
              !googleClientId.isEmpty else {
            throw JsBaoError(code: .unavailable, message: "OAuth not configured")
        }

        // PKCE (RFC 7636): generate a fresh verifier+challenge pair for this
        // flow. The challenge (base64url SHA-256 of the verifier) goes to
        // Google on the authorize URL; the verifier is held on `self` until
        // `handleOAuthCallback` sends it to our server with the code
        // exchange. Together they prove the client exchanging the code is
        // the one that started the flow — replacing the client_secret that
        // confidential (web) OAuth clients use. Native iOS clients have no
        // secret, so PKCE is what makes the native flow work. Servers that
        // don't support PKCE yet simply ignore the extra parameters.
        let verifier = Self.generatePkceVerifier()
        let challenge = Self.pkceChallenge(forVerifier: verifier)
        lock.withLock { pendingCodeVerifier = verifier }

        let state = try Self.encodeOAuthState(
            redirectUri: redirectUri,
            continueUrl: continueUrl,
            waitlist: waitlist,
            inviteToken: inviteToken
        )
        return try Self.buildGoogleAuthorizationUrl(
            googleClientId: googleClientId,
            redirectUri: redirectUri,
            state: state,
            codeChallenge: challenge
        )
    }

    /// Exchange the authorization code for a session token. Mirrors JS
    /// `exchangeOAuthCode` (src/client/internal/authController.ts):
    /// `GET /oauth/callback?code=&state=` returns `{token, isNewUser}` plus
    /// the `rt-{appId}` HttpOnly refresh cookie (handled transparently by
    /// `URLSession`'s shared cookie storage). Applies the token with cause
    /// `"google"`, which emits `.authSuccess` / `.authState` like every other
    /// interactive sign-in path. Returns the raw server response so callers
    /// can read `isNewUser`.
    @discardableResult
    public func handleOAuthCallback(code: String, state: String) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        // PKCE: consume the verifier from the most recent startOAuthFlow.
        // Cleared whether the exchange succeeds or fails so a stale verifier
        // can't leak into a later attempt. Callers that never went through
        // startOAuthFlow (e.g. resuming a web-started flow) have no verifier
        // and the legacy GET path is used — same wire shape as before.
        let codeVerifier = lock.withLock { () -> String? in
            let verifier = pendingCodeVerifier
            pendingCodeVerifier = nil
            return verifier
        }

        // The server only reads the verifier from the native JSON endpoint
        // (`POST /auth/oauth/callback`, body `{code, state, codeVerifier}` —
        // OAuthController.callbackJson); the web `GET /oauth/callback` never
        // looks at a code_verifier param. So: verifier → POST, none → GET.
        let response: Any?
        if let codeVerifier {
            response = try await makeRequest(
                "POST",
                "/auth/oauth/callback",
                ["code": code, "state": state, "codeVerifier": codeVerifier]
            )
        } else {
            let path = try Self.oauthCallbackPath(code: code, state: state)
            response = try await makeRequest("GET", path, nil)
        }
        guard let dict = response as? [String: Any],
              let token = dict["token"] as? String else {
            throw JsBaoError(code: .unavailable, message: "Invalid OAuth callback response")
        }

        let previous = getToken()
        applyToken(token, previous: previous, cause: "google")
        return dict
    }

    // MARK: - Sign in with Apple

    /// Exchange a native Sign in with Apple credential for a session token.
    /// `POST /auth/apple/callback` with the JSON body
    /// `{identityToken, nonce, user, email?, firstName?, lastName?, inviteToken?}` —
    /// the contract of the server's `AppleAuthController` (#409):
    ///  * `identityToken` — Apple's JWT (`credential.identityToken`, UTF-8).
    ///  * `nonce` — the **raw** nonce; the client put its SHA-256 (lowercase
    ///    hex) on `ASAuthorizationAppleIDRequest.nonce`, and the server
    ///    re-hashes this raw value to check the token's `nonce` claim.
    ///  * `user` — Apple's stable user identifier (`credential.user`).
    ///  * `email` / `firstName` / `lastName` — first-authorization hints
    ///    (Apple only provides them once per user+app).
    ///  * `inviteToken` — optional invitation token (#1467); the server
    ///    accepts the invitation and resolves its deferred grants during a
    ///    first sign-in. Omitted from the body when nil or empty.
    /// The response is `{token, isNewUser}` plus the `rt-{appId}` HttpOnly
    /// refresh cookie (handled by `URLSession`'s cookie storage). Applies
    /// the token with cause `"apple"`, emitting `.authSuccess` /
    /// `.authState` like the other interactive sign-in paths. Returns the
    /// raw server response so callers can read `isNewUser`.
    @discardableResult
    public func handleAppleCallback(
        identityToken: String,
        rawNonce: String,
        user: String,
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        inviteToken: String? = nil
    ) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let body = AppleSignInHelpers.callbackBody(
            identityToken: identityToken,
            rawNonce: rawNonce,
            user: user,
            email: email,
            firstName: firstName,
            lastName: lastName,
            inviteToken: inviteToken
        )
        let response = try await makeRequest("POST", "/auth/apple/callback", body)
        guard let dict = response as? [String: Any],
              let token = dict["token"] as? String else {
            throw JsBaoError(code: .unavailable, message: "Invalid Apple sign-in response")
        }

        let previous = getToken()
        applyToken(token, previous: previous, cause: "apple")
        return dict
    }

    // MARK: - OAuth URL helpers (pure, unit-testable)

    /// Encode the OAuth state bag the server round-trips through Google.
    /// Mirrors the JS shape: `btoa(JSON.stringify({redirectUri, nonce,
    /// continueUrl?}))` — `continueUrl` omitted when absent.
    static func encodeOAuthState(
        redirectUri: String,
        continueUrl: String? = nil,
        waitlist: OAuthWaitlist? = nil,
        inviteToken: String? = nil,
        nonce: String = UUID().uuidString
    ) throws -> String {
        var state: [String: Any] = [
            "nonce": nonce,
            "redirectUri": redirectUri,
        ]
        if let continueUrl, !continueUrl.isEmpty {
            state["continueUrl"] = continueUrl
        }
        // #466 parity: enroll the user in the waitlist via the OAuth state bag.
        // JS trims both fields and clamps each to 255 chars, and only attaches
        // the `waitlist` key when at least one field survives trimming.
        if let waitlist {
            var entry: [String: Any] = [:]
            if let source = waitlist.source?.trimmingCharacters(in: .whitespacesAndNewlines),
               !source.isEmpty {
                entry["source"] = String(source.prefix(255))
            }
            if let note = waitlist.note?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                entry["note"] = String(note.prefix(255))
            }
            if !entry.isEmpty {
                state["waitlist"] = entry
            }
        }
        // #466 parity: thread the (trimmed) invite token through the state bag.
        // The callback handler reads `stateData.inviteToken` and accepts the
        // named invitation server-side, resolving deferred grants to the new
        // user even when the OAuth email differs from the invited email.
        if let inviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inviteToken.isEmpty {
            state["inviteToken"] = inviteToken
        }
        let data = try JSONSerialization.data(withJSONObject: state)
        return data.base64EncodedString()
    }

    /// Build the Google authorize URL exactly like the JS client:
    /// `https://accounts.google.com/o/oauth2/v2/auth` with
    /// `client_id`, `redirect_uri`, `response_type=code`,
    /// `scope="openid email profile"`, and `state` — plus, when
    /// `codeChallenge` is given, the PKCE pair `code_challenge` /
    /// `code_challenge_method=S256` (RFC 7636 §4.3).
    ///
    /// Query values are strictly percent-encoded (RFC 3986 unreserved set)
    /// rather than via `URLComponents.queryItems`, which leaves `+` literal —
    /// Google would decode a literal `+` in the base64 state as a space and
    /// corrupt it.
    static func buildGoogleAuthorizationUrl(
        googleClientId: String,
        redirectUri: String,
        state: String,
        codeChallenge: String? = nil
    ) throws -> URL {
        var params: [(String, String)] = [
            ("client_id", googleClientId),
            ("redirect_uri", redirectUri),
            ("response_type", "code"),
            ("scope", "openid email profile"),
            ("state", state),
        ]
        if let codeChallenge, !codeChallenge.isEmpty {
            params.append(("code_challenge", codeChallenge))
            params.append(("code_challenge_method", "S256"))
        }
        let query = try params.map { name, value in
            "\(name)=\(try Self.strictPercentEncode(value))"
        }.joined(separator: "&")

        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            throw JsBaoError(code: .unavailable, message: "Could not build OAuth URL")
        }
        components.percentEncodedQuery = query
        guard let url = components.url else {
            throw JsBaoError(code: .unavailable, message: "Could not build OAuth URL")
        }
        return url
    }

    /// Request path for the legacy (non-PKCE) code exchange:
    /// `/oauth/callback?code=&state=` with both values strictly
    /// percent-encoded (the base64 state contains `+` / `/` / `=`, all
    /// reserved in queries). PKCE flows don't use this path — the verifier
    /// goes in the JSON body of `POST /auth/oauth/callback` instead, which
    /// is the only place the server reads it.
    static func oauthCallbackPath(
        code: String,
        state: String
    ) throws -> String {
        let encodedCode = try strictPercentEncode(code)
        let encodedState = try strictPercentEncode(state)
        return "/oauth/callback?code=\(encodedCode)&state=\(encodedState)"
    }

    // MARK: - PKCE helpers (pure, unit-testable)

    /// Generate a high-entropy PKCE `code_verifier` per RFC 7636 §4.1:
    /// 32 random bytes, base64url-encoded without padding — 43 characters,
    /// all from the spec's unreserved set, comfortably inside the required
    /// 43–128 range.
    static func generatePkceVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return PasskeyWire.base64UrlEncode(Data(bytes))
    }

    /// Derive the S256 PKCE `code_challenge` for a verifier (RFC 7636 §4.2):
    /// `base64url(sha256(ascii(verifier)))`, no padding.
    static func pkceChallenge(forVerifier verifier: String) -> String {
        PasskeyWire.base64UrlEncode(hashSHA256(Data(verifier.utf8)))
    }

    /// Percent-encode everything outside the RFC 3986 unreserved set
    /// (alphanumerics plus `-._~`), matching JS `encodeURIComponent` for
    /// the characters that matter in OAuth payloads (`+`, `/`, `=`, `:`).
    static func strictPercentEncode(_ value: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw JsBaoError(code: .invalidArgument, message: "Could not percent-encode OAuth parameter")
        }
        return encoded
    }

    // MARK: - Magic Link

    public func magicLinkRequest(email: String, redirectUri: String) async throws -> Bool {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let body: [String: Any] = ["email": email, "redirectUri": redirectUri]
        let response = try await makeRequest("POST", "/auth/magic-link/request", body)
        guard let dict = response as? [String: Any],
              let success = dict["success"] as? Bool else {
            return false
        }
        return success
    }

    public func magicLinkVerify(token: String, inviteToken: String? = nil) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        // #466: thread the (trimmed) invite token through verify so deferred
        // grants resolve to the signing-in user. Mirrors JS magicLinkVerify.
        let trimmedInviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInviteToken = (trimmedInviteToken?.isEmpty == false) ? trimmedInviteToken : nil

        let endpoint: String
        var body: [String: Any]

        if let proxy = refreshProxy, proxy.enabled {
            endpoint = "\(proxy.baseUrl)/auth/magic-link/verify"
            body = ["token": token, "appId": appId]
        } else {
            endpoint = "/auth/magic-link/verify"
            body = ["token": token]
        }
        if let resolvedInviteToken = resolvedInviteToken {
            body["inviteToken"] = resolvedInviteToken
        }

        let response = try await makeRequest("POST", endpoint, body)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid magic link verify response")
        }

        if let accessToken = dict["token"] as? String {
            let previous = getToken()
            applyToken(accessToken, previous: previous, cause: "magic_link")
        }

        return dict
    }

    // MARK: - OTP

    public func otpRequest(email: String) async throws -> Bool {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let body: [String: Any] = ["email": email]
        let response = try await makeRequest("POST", "/auth/otp/request", body)
        guard let dict = response as? [String: Any],
              let success = dict["success"] as? Bool else {
            return false
        }
        return success
    }

    public func otpVerify(email: String, code: String, inviteToken: String? = nil) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        // #466: thread the (trimmed) invite token through verify so deferred
        // grants resolve to the signing-in user. Mirrors JS otpVerify.
        let trimmedInviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInviteToken = (trimmedInviteToken?.isEmpty == false) ? trimmedInviteToken : nil

        var body: [String: Any] = ["email": email, "code": code]
        if let resolvedInviteToken = resolvedInviteToken {
            body["inviteToken"] = resolvedInviteToken
        }

        let endpoint: String
        if let proxy = refreshProxy, proxy.enabled {
            endpoint = "\(proxy.baseUrl)/auth/otp/verify"
        } else {
            endpoint = "/auth/otp/verify"
        }

        let response = try await makeRequest("POST", endpoint, body)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid OTP verify response")
        }

        if let accessToken = dict["token"] as? String {
            let previous = getToken()
            applyToken(accessToken, previous: previous, cause: "otp")
        }

        return dict
    }

    // MARK: - Passkeys (#929)
    //
    // Wire-level passkey endpoints, mirroring JS `authController.passkey*`.
    // The native AuthenticationServices orchestration lives in
    // `AuthAPI+NativePasskeys.swift`; these methods only speak HTTP.

    /// `POST /passkey/auth/start` (no auth). Returns the raw response dict:
    /// WebAuthn request options spread at the top level plus `challengeToken`.
    public func passkeyAuthStart() async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let response = try await makeRequest("POST", "/passkey/auth/start", [String: Any]())
        guard let dict = response as? [String: Any],
              dict["challengeToken"] is String else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey auth start response")
        }
        return dict
    }

    /// `POST /passkey/auth/finish` (no auth). On success applies the
    /// returned access token (cause `"passkey"`) — the session lands exactly
    /// like the magic-link / OTP paths — and returns the response dict
    /// (`{ token, expiresAt, user, isNewUser }`).
    public func passkeyAuthFinish(credential: [String: Any], challengeToken: String) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let body: [String: Any] = [
            "credential": credential,
            "challengeToken": challengeToken,
        ]
        let response = try await makeRequest("POST", "/passkey/auth/finish", body)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey auth finish response")
        }
        if let accessToken = dict["token"] as? String {
            let previous = getToken()
            applyToken(accessToken, previous: previous, cause: "passkey")
        }
        return dict
    }

    /// `POST /passkey/register/start` (requires auth). Returns the raw
    /// response dict: WebAuthn creation options plus `challengeToken`.
    public func passkeyRegisterStart() async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let response = try await makeRequest("POST", "/passkey/register/start", [String: Any]())
        guard let dict = response as? [String: Any],
              dict["challengeToken"] is String else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey register start response")
        }
        return dict
    }

    /// `POST /passkey/register/finish` (requires auth). Returns
    /// `{ success, credentialBackedUp?, invitation? }`. `inviteToken` (#466)
    /// folds invitation acceptance into the registration call.
    public func passkeyRegisterFinish(
        credential: [String: Any],
        challengeToken: String,
        deviceName: String? = nil,
        inviteToken: String? = nil
    ) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        var body: [String: Any] = [
            "credential": credential,
            "challengeToken": challengeToken,
        ]
        if let deviceName = deviceName, !deviceName.isEmpty {
            body["deviceName"] = deviceName
        }
        let trimmedInviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedInviteToken = trimmedInviteToken, !trimmedInviteToken.isEmpty {
            body["inviteToken"] = trimmedInviteToken
        }
        let response = try await makeRequest("POST", "/passkey/register/finish", body)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey register finish response")
        }
        return dict
    }

    /// `GET /passkey/list` (requires auth). Returns `{ passkeys: [...] }`.
    public func passkeyList() async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let response = try await makeRequest("GET", "/passkey/list", nil)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey list response")
        }
        return dict
    }

    /// `DELETE /passkey/{passkeyId}` (requires auth). Returns `{ success }`.
    public func passkeyDelete(passkeyId: String) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let response = try await makeRequest("DELETE", "/passkey/\(passkeyId)", nil)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey delete response")
        }
        return dict
    }

    /// `PATCH /passkey/{passkeyId}` (requires auth). Renames a passkey;
    /// returns `{ passkey: {...} }`.
    public func passkeyUpdate(passkeyId: String, deviceName: String) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let body: [String: Any] = ["deviceName": deviceName]
        let response = try await makeRequest("PATCH", "/passkey/\(passkeyId)", body)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid passkey update response")
        }
        return dict
    }

    // MARK: - Logout

    /// Sign out the current user. Mirrors JS `authController.logout(options)`:
    /// honors `clearOfflineIdentity` (default `true`), `revokeOffline`,
    /// `wipeLocal`, and the Swift-specific `waitForDisconnect`. (`redirectTo`
    /// is web-only `window.location` and is intentionally not modeled here.)
    public func logout(options: LogoutOptions = LogoutOptions()) async throws {
        // JS parity (#1059): JS emits `auth:logout` (payload `{}`) as the very
        // first statement of `JsBaoClient.logout()`, before any teardown.
        // Every Swift logout path funnels through this method, so emitting
        // here covers `client.logout(...)` and `client.auth.logout(...)`.
        emitter?.emit(.authLogout, AuthLogoutEvent())

        // Block any in-flight refresh/restore from re-authenticating after
        // this logout (see `blockNonInteractiveAuth`). Set before clearing
        // the token so a refresh resolving mid-logout is caught.
        lock.withLock { blockNonInteractiveAuth = true }
        let previous = getToken()
        applyToken(nil, previous: previous, cause: "logout")

        // Default-true in JS: drop the in-memory offline identity unless the
        // caller explicitly opts out.
        if options.clearOfflineIdentity {
            lock.withLock { offlineIdentity = nil }
        }

        if options.revokeOffline {
            // revokeOfflineGrant clears the stored grant (and the in-memory
            // identity) and, when wipeLocal is set, evicts local data.
            try? await revokeOfflineGrant(options: RevokeOfflineGrantOptions(wipeLocal: options.wipeLocal))
        } else if options.wipeLocal {
            try? await clearPersistedJwt()
        }

        if options.waitForDisconnect {
            await onLogoutDisconnect?()
        }

        // JS parity (#1059): JS emits `auth:logout:complete` (payload `{}`)
        // after the best-effort server logout, networking shutdown, and
        // `auth.logout(...)` teardown have all finished.
        emitter?.emit(.authLogoutComplete, AuthLogoutCompleteEvent())
    }

    /// Backward-compatible overload retained for the `JsBaoClient` wiring
    /// (`logout(wipeLocal:)`). Forwards to the options-based `logout`.
    public func logout(wipeLocal: Bool) async throws {
        try await logout(options: LogoutOptions(wipeLocal: wipeLocal))
    }

    /// Optional hook invoked when `logout(waitForDisconnect: true)` is
    /// requested, awaited so callers can block until the socket is torn down.
    /// Wired by `JsBaoClient` (which owns the WebSocket lifecycle); `nil` when
    /// the controller is used standalone. Mirrors the JS `onLogoutCleanup`
    /// dependency the web client injects.
    var onLogoutDisconnect: (@Sendable () async -> Void)?

    // MARK: - Network Mode

    public func setNetworkMode(_ mode: NetworkMode) {
        lock.withLock { networkMode = mode }
        // Note: event emission is handled by JsBaoClient.setNetworkMode()
        // to avoid duplicate events.
    }

    public func getNetworkMode() -> NetworkMode {
        return lock.withLock { networkMode }
    }

    // MARK: - Auth Ready

    public func waitForAuthReady() async {
        if lock.withLock({ authReady }) {
            return
        }

        await withCheckedContinuation { continuation in
            // Register the waiter atomically with the ready check so a
            // `markAuthReady()` racing this closure can't slip between the
            // check and the append (which would strand the continuation).
            // The resume happens outside the lock.
            let alreadyReady = lock.withLock { () -> Bool in
                if authReady {
                    return true
                }
                authReadyContinuations.append(continuation)
                return false
            }
            if alreadyReady {
                continuation.resume()
            }
        }
    }

    private func markAuthReady() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            authReady = true
            let pending = authReadyContinuations
            authReadyContinuations.removeAll()
            return pending
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    // MARK: - JWT Persistence (private)

    private func persistJwt(token: String) async throws {
        let namespace = persistConfig.storageKeyPrefix ?? "default"
        let payload = Self.parseJwtPayload(token: token)
        let record = PersistedJwtRecord(
            key: "session",
            token: token,
            expiresAt: (payload?["exp"] as? TimeInterval).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) },
            storedAt: ISO8601DateFormatter().string(from: Date()),
            userId: payload?["userId"] as? String ?? payload?["sub"] as? String,
            version: 1
        )
        try await offlineStore.persistJwt(appId: appId, namespace: namespace, record: record)
    }

    private func clearPersistedJwt() async throws {
        let namespace = persistConfig.storageKeyPrefix ?? "default"
        try await offlineStore.clearPersistedJwt(appId: appId, namespace: namespace)
    }

    /// Try to load a persisted JWT on startup
    public func tryLoadPersistedJwt() async -> String? {
        guard persistConfig.persistJwtInStorage else { return nil }
        let namespace = persistConfig.storageKeyPrefix ?? "default"
        guard let record = try? await offlineStore.loadPersistedJwt(appId: appId, namespace: namespace) else {
            return nil
        }
        // Check expiry
        if let expiresAt = record.expiresAt,
           let date = ISO8601DateFormatter().date(from: expiresAt),
           date < Date() {
            logger.debug("Persisted JWT expired")
            return nil
        }
        return record.token
    }

    /// Restore an authenticated session on startup:
    ///   1. Prefer a persisted access token that's still valid.
    ///   2. If the persisted access token has aged out, attempt a cookie-based
    ///      refresh — the `rt-{appId}` refresh cookie persists in
    ///      `HTTPCookieStorage.shared` across app launches and lives up to 7d,
    ///      so a user reopening the app after the 1h access-token TTL
    ///      shouldn't be forced back through login.
    ///   3. Otherwise bootstrap as unauthenticated.
    ///
    /// Marks auth ready once the attempt completes, regardless of outcome.
    public func tryRestoreSession() async {
        defer { markAuthReady() }

        guard persistConfig.persistJwtInStorage else { return }

        let namespace = persistConfig.storageKeyPrefix ?? "default"
        guard let record = try? await offlineStore.loadPersistedJwt(appId: appId, namespace: namespace) else {
            // No prior session on disk; don't waste a refresh round-trip on
            // first install.
            return
        }

        let expiredAt: Date? = record.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let isExpired = expiredAt.map { $0 < Date() } ?? false

        if !isExpired {
            applyToken(record.token, previous: nil, cause: "bootstrap")
            return
        }

        logger.debug("Persisted JWT expired; attempting cookie-based refresh")
        let outcome = await refreshAccessToken(cause: "startup")
        switch outcome {
        case .success:
            break // applyToken has already set the new token
        case .invalid:
            // Refresh cookie is gone or the session was revoked. Clear the
            // stale persisted record so we don't keep retrying.
            try? await clearPersistedJwt()
        case .network:
            // Transient. Leave the stale record in place so the next launch
            // (or an online-again trigger) can try again.
            break
        }
    }

    // MARK: - Offline Access Grants

    /// Enable offline access by requesting a grant from the server and storing it in the Keychain.
    public func enableOfflineAccess(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        guard networkMode != .offline else {
            throw JsBaoError(code: .invalidArgument, message: "Cannot enable offline access while in offline mode")
        }

        let body: [String: Any] = ["ttlDays": options.ttlDays]
        let response = try await makeRequest("POST", "/auth/offline-grant", body)
        guard let dict = response as? [String: Any] else {
            throw JsBaoError(code: .unavailable, message: "Invalid offline grant response")
        }

        // Grant-method selection (mirrors JS authController.enableOfflineAccess):
        // the default grant is the non-biometric "signed" method. Biometric is
        // strictly opt-in via `preferBiometric` — when set, the grant is stored
        // behind a Keychain biometric ACL and labeled "largeBlob" to match the
        // JS unlock-method taxonomy ("largeBlob" | "pin" | "signed"). PIN
        // fallback (`allowPinFallback` + `pinProvider`) labels the grant "pin".
        let method: String
        if options.preferBiometric {
            method = "largeBlob"
        } else if options.allowPinFallback {
            method = "pin"
        } else {
            method = "signed"
        }

        // Build grant record
        let userId = getUserId() ?? ""
        let grant = OfflineGrant(
            key: "grant",
            userId: userId,
            appId: appId,
            rootDocId: dict["rootDocId"] as? String,
            email: dict["email"] as? String,
            name: dict["name"] as? String,
            expiresAt: dict["expiresAt"] as? String,
            method: method
        )

        // Store in Keychain. Biometric protection is gated on the opt-in
        // `preferBiometric` flag (JS default is the non-biometric grant).
        let grantData = try JSONEncoder().encode(grant)
        try keychainHelper.save(key: "grant", data: grantData, requireBiometric: options.preferBiometric)

        // Also store in OfflineStore for metadata access
        try await offlineStore.putGrant(appId: appId, userId: userId, key: "grant", record: grant)

        lock.withLock {
            offlineIdentity = OfflineIdentity(
                userId: grant.userId,
                appId: grant.appId,
                rootDocId: grant.rootDocId,
                email: grant.email,
                name: grant.name,
                expiresAt: grant.expiresAt,
                method: grant.method ?? "signed"
            )
        }

        emitter?.emit(.offlineAuthEnabled, ["method": grant.method ?? "signed"] as [String: Any])

        return dict
    }

    /// Unlock offline access by reading the grant from the Keychain.
    /// If biometric-protected, this triggers Face ID / Touch ID automatically.
    public func unlockOffline() async throws -> Bool {
        do {
            guard let grantData = try keychainHelper.load(key: "grant") else {
                logger.debug("No offline grant found in Keychain")
                return false
            }

            let grant = try JSONDecoder().decode(OfflineGrant.self, from: grantData)

            // Check expiry
            if let expiresAt = grant.expiresAt,
               let date = ISO8601DateFormatter().date(from: expiresAt),
               date < Date() {
                logger.warn("Offline grant expired")
                emitter?.emit(.offlineAuthFailed, ["reason": "expired"] as [String: Any])
                return false
            }

            lock.withLock {
                offlineIdentity = OfflineIdentity(
                    userId: grant.userId,
                    appId: grant.appId,
                    rootDocId: grant.rootDocId,
                    email: grant.email,
                    name: grant.name,
                    expiresAt: grant.expiresAt,
                    method: grant.method ?? "signed"
                )
                // Set user context from grant
                currentUserId = grant.userId
            }

            emitter?.emit(.offlineAuthUnlocked, ["userId": grant.userId] as [String: Any])
            return true
        } catch KeychainError.biometricCancelled {
            emitter?.emit(.offlineAuthFailed, ["reason": "biometric_cancelled"] as [String: Any])
            return false
        } catch {
            logger.warn("Failed to unlock offline:", error.localizedDescription)
            emitter?.emit(.offlineAuthFailed, ["reason": error.localizedDescription] as [String: Any])
            return false
        }
    }

    /// Check if an offline grant exists in the Keychain.
    public func isOfflineGrantAvailable() -> Bool {
        keychainHelper.exists(key: "grant")
    }

    /// Get the status of the offline grant (availability, expiry, method).
    public func getOfflineGrantStatus() -> OfflineGrantStatus {
        let identity = lock.withLock { offlineIdentity }

        guard let identity = identity else {
            return OfflineGrantStatus(
                available: keychainHelper.exists(key: "grant"),
                expiresAt: nil,
                daysLeft: nil,
                method: nil
            )
        }

        var daysLeft: Int?
        if let expiresAt = identity.expiresAt,
           let date = ISO8601DateFormatter().date(from: expiresAt) {
            daysLeft = max(0, Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0)
        }

        return OfflineGrantStatus(
            available: true,
            expiresAt: identity.expiresAt,
            daysLeft: daysLeft,
            method: identity.method
        )
    }

    /// Renew the offline grant while online by requesting a new grant from the server.
    public func renewOfflineGrantOnline(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> Bool {
        guard networkMode != .offline else {
            throw JsBaoError(code: .invalidArgument, message: "Must be online to renew offline grant")
        }

        let _ = try await enableOfflineAccess(options: options)
        emitter?.emit(.offlineAuthRenewed, [:] as [String: Any])
        return true
    }

    /// Revoke the offline grant, removing it from the Keychain.
    public func revokeOfflineGrant(options: RevokeOfflineGrantOptions = RevokeOfflineGrantOptions()) async throws {
        try keychainHelper.delete(key: "grant")

        let userId = getUserId() ?? ""
        try? await offlineStore.deleteGrant(appId: appId, userId: userId, key: "grant")

        lock.withLock { offlineIdentity = nil }

        emitter?.emit(.offlineAuthRevoked, ["wipeLocal": options.wipeLocal] as [String: Any])
    }

    /// Get the stored offline identity (available after unlockOffline succeeds).
    public func getOfflineIdentity() -> OfflineIdentity? {
        return lock.withLock { offlineIdentity }
    }

    // MARK: - Private Helpers

    private func refreshDirect() async throws -> String {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        let response = try await makeRequest("POST", "/auth/refresh", nil)
        guard let dict = response as? [String: Any],
              let token = dict["token"] as? String else {
            throw JsBaoError(code: .unavailable, message: "Invalid refresh response")
        }
        return token
    }

    private func refreshViaProxy(proxy: RefreshProxyConfig) async throws -> String {
        let url = "\(proxy.baseUrl)/auth/refresh"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appId, forHTTPHeaderField: "X-App-Id")
        if let maxAge = proxy.cookieMaxAgeSeconds {
            request.setValue(String(maxAge), forHTTPHeaderField: "X-Refresh-Cookie-Max-Age")
        }
        if let token = getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JsBaoError(code: .unavailable, message: "Invalid response")
        }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw HttpError(status: httpResponse.statusCode, message: "Refresh failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw JsBaoError(code: .unavailable, message: "Invalid refresh response")
        }
        return token
    }
}
