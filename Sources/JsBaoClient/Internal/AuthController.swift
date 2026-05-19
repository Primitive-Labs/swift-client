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

    // Request function (set externally to break circular dependency)
    var makeRequest: ((String, String, Any?) async throws -> Any)?

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
        lock.lock()
        defer { lock.unlock() }
        return currentToken
    }

    public func getUserId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentUserId
    }

    public func isAuthenticated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentToken != nil && currentUserId != nil
    }

    public func getAuthState() -> AuthState {
        lock.lock()
        defer { lock.unlock() }
        return AuthState(
            authenticated: currentToken != nil,
            mode: networkMode,
            userId: currentUserId
        )
    }

    public func getJwtPayload() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return jwtPayload
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

    /// Apply a new token, updating internal state and emitting events
    func applyToken(_ token: String?, previous: String?, cause: String?) {
        lock.lock()
        let oldUserId = currentUserId
        currentToken = token

        if let token = token {
            let payload = Self.parseJwtPayload(token: token)
            jwtPayload = payload
            currentUserId = payload?["userId"] as? String ?? payload?["sub"] as? String
        } else {
            jwtPayload = nil
            currentUserId = nil
        }
        let newUserId = currentUserId
        let newToken = currentToken
        lock.unlock()

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
            lock.lock()
            pendingPersistTask = task
            lock.unlock()
        }
    }

    /// Wait for any in-flight JWT persistence to drain. Called from
    /// `JsBaoClient.destroy()` so the storage layer doesn't close the
    /// SQLite connection out from under a queued write. Safe to call
    /// when no Task is in flight (no-op).
    public func awaitPendingPersistence() async {
        lock.lock()
        let task = pendingPersistTask
        lock.unlock()
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
        // await its outcome instead of starting a new round trip.
        lock.lock()
        if let inFlight = pendingRefresh {
            lock.unlock()
            return await inFlight.value
        }
        let task = Task<RefreshOutcome, Never> { [weak self] in
            guard let self = self else { return .network }
            return await self._refreshAccessTokenImpl(cause: cause)
        }
        pendingRefresh = task
        lock.unlock()

        let outcome = await task.value
        lock.lock()
        pendingRefresh = nil
        lock.unlock()
        return outcome
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

            lock.lock()
            refreshBackoffMs = refreshBackoffBase
            lock.unlock()

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

            lock.lock()
            refreshBackoffMs = min(refreshBackoffMs * 2, refreshBackoffMax)
            lock.unlock()

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

    public func startOAuthFlow(redirectUri: String, continueUrl: String? = nil) async throws -> URL {
        let state: [String: Any] = [
            "nonce": UUID().uuidString,
            "redirectUri": redirectUri,
            "continueUrl": continueUrl as Any,
        ]
        let stateData = try JSONSerialization.data(withJSONObject: state)
        let stateBase64 = stateData.base64EncodedString()

        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let response = try await makeRequest("POST", "/oauth-config", nil)
        guard let dict = response as? [String: Any],
              let authUrl = dict["authorizationUrl"] as? String else {
            throw JsBaoError(code: .unavailable, message: "Invalid OAuth config response")
        }

        guard var components = URLComponents(string: authUrl) else {
            throw JsBaoError(code: .unavailable, message: "Invalid OAuth URL")
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "state", value: stateBase64))
        queryItems.append(URLQueryItem(name: "redirect_uri", value: redirectUri))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw JsBaoError(code: .unavailable, message: "Could not build OAuth URL")
        }
        return url
    }

    public func handleOAuthCallback(code: String, state: String) async throws {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let body: [String: Any] = [
            "code": code,
            "state": state,
        ]

        let response = try await makeRequest("POST", "/auth/oauth/callback", body)
        guard let dict = response as? [String: Any],
              let token = dict["token"] as? String else {
            throw JsBaoError(code: .unavailable, message: "Invalid OAuth callback response")
        }

        let previous = getToken()
        applyToken(token, previous: previous, cause: "oauth")
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

    public func magicLinkVerify(token: String) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let endpoint: String
        let body: [String: Any]

        if let proxy = refreshProxy, proxy.enabled {
            endpoint = "\(proxy.baseUrl)/auth/magic-link/verify"
            body = ["token": token, "appId": appId]
        } else {
            endpoint = "/auth/magic-link/verify"
            body = ["token": token]
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

    public func otpVerify(email: String, code: String) async throws -> [String: Any] {
        guard let makeRequest = makeRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let body: [String: Any] = ["email": email, "code": code]

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

    // MARK: - Logout

    public func logout(wipeLocal: Bool = false) async throws {
        let previous = getToken()
        applyToken(nil, previous: previous, cause: "logout")

        if wipeLocal {
            try? await clearPersistedJwt()
        }
    }

    // MARK: - Network Mode

    public func setNetworkMode(_ mode: NetworkMode) {
        lock.lock()
        networkMode = mode
        lock.unlock()
        // Note: event emission is handled by JsBaoClient.setNetworkMode()
        // to avoid duplicate events.
    }

    public func getNetworkMode() -> NetworkMode {
        lock.lock()
        defer { lock.unlock() }
        return networkMode
    }

    // MARK: - Auth Ready

    public func waitForAuthReady() async {
        lock.lock()
        if authReady {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock()
            if authReady {
                lock.unlock()
                continuation.resume()
                return
            }
            authReadyContinuations.append(continuation)
            lock.unlock()
        }
    }

    private func markAuthReady() {
        lock.lock()
        authReady = true
        let continuations = authReadyContinuations
        authReadyContinuations.removeAll()
        lock.unlock()

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
            method: options.requireBiometric ? "biometric" : "signed"
        )

        // Store in Keychain
        let grantData = try JSONEncoder().encode(grant)
        try keychainHelper.save(key: "grant", data: grantData, requireBiometric: options.requireBiometric)

        // Also store in OfflineStore for metadata access
        try await offlineStore.putGrant(appId: appId, userId: userId, key: "grant", record: grant)

        lock.lock()
        offlineIdentity = OfflineIdentity(
            userId: grant.userId,
            appId: grant.appId,
            rootDocId: grant.rootDocId,
            email: grant.email,
            name: grant.name,
            expiresAt: grant.expiresAt,
            method: grant.method ?? "signed"
        )
        lock.unlock()

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

            lock.lock()
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
            lock.unlock()

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
        lock.lock()
        let identity = offlineIdentity
        lock.unlock()

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

        lock.lock()
        offlineIdentity = nil
        lock.unlock()

        emitter?.emit(.offlineAuthRevoked, ["wipeLocal": options.wipeLocal] as [String: Any])
    }

    /// Get the stored offline identity (available after unlockOffline succeeds).
    public func getOfflineIdentity() -> OfflineIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return offlineIdentity
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
