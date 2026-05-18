import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-refresh.test.ts
/// Tests token lifecycle and auth-failed behavior.
final class RefreshTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-refresh")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testTokenInMemoryWorksForRequests() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Token in memory should work for a simple request
        let result = try await client.makeRequest("GET", "/me", nil)
        guard let dict = result as? [String: Any] else {
            XCTFail("Expected dictionary response")
            return
        }
        XCTAssertNotNil(dict["userId"])
    }

    func testInvalidTokenFailsGracefully() async throws {
        let client = createTestClient(appId: testApp.appId, token: "invalid.jwt.token")
        defer { Task { await client.destroy() } }

        // Request with invalid token should throw
        do {
            _ = try await client.makeRequest("GET", "/me", nil)
            XCTFail("Should have thrown with invalid token")
        } catch {
            // Expected: auth failure
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("401") || msg.contains("403") || msg.contains("auth") || msg.contains("Unauthorized"),
                "Expected auth error, got: \(msg)"
            )
        }
    }

    func testAuthStateReflectsToken() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Wait for auth to initialize
        try await delay(1)

        let state = client.getAuthState()
        XCTAssertTrue(state.authenticated)
        XCTAssertNotNil(client.getUserId())
    }

    func testIsAuthenticated() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Wait for auth bootstrap
        try await delay(1)

        XCTAssertTrue(client.isAuthenticated())
    }

    func testLogout() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        try await client.logout()

        XCTAssertFalse(client.isConnected)
    }

    func testLogoutWithWipeLocal() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        try await client.logout(wipeLocal: true)

        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Cold-start refresh via persisted cookie
    //
    // Regression for the bug where iOS users got logged out roughly every
    // ~24h despite the backend advertising a 7-day refresh window. The real
    // threshold was 1h — cold starts that found an expired access token in
    // SQLite short-circuited to "logged out" without ever trying the refresh
    // cookie sitting in `HTTPCookieStorage.shared`.
    //
    // This reproduces the exact cold-start state: SQLite holds an
    // already-expired access-token record, and an `rt-{appId}` cookie is
    // installed in the shared jar (what URLSession would have persisted after
    // a prior login). A new `JsBaoClient` pointed at the same SQLite path
    // with no `options.token` must end up authenticated via cookie-based
    // refresh, not pushed back to login.
    func testColdStartRestoresViaRefreshCookie() async throws {
        let tempDir = NSTemporaryDirectory() + "jsbao-coldstart-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let dbPath = tempDir + "auth.sqlite"
        let namespace = testApp.appId

        // 1. Forge a refresh JWT for the app owner. The existing owner access
        // token already has the right payload; we only need to flip its
        // `type` to "refresh" and re-sign with the dev-server test secret.
        // This avoids any server-side test helper — see feedback doc
        // 2026-04-21 for the upstream ask to return a refresh token from
        // `mint-test-jwt`.
        let refreshToken = try ctx.forgeRefreshJwt(fromAccessToken: testApp.ownerJWT)

        // 2. Install the refresh token as an `rt-{appId}` cookie — the state
        // URLSession would have been in after a prior successful login.
        // `Secure` is intentionally unset so the cookie flows over plain-HTTP
        // test traffic; the production cookie sets Secure and is HTTPS-only.
        // Build via Set-Cookie parsing: constructing via the properties-dict
        // initializer silently drops the cookie on some setups, so we
        // reuse the path URLSession actually uses when it sees a real
        // server response.
        let cookiePath = "/app/\(testApp.appId)/api/"
        let cookieName = "rt-\(testApp.appId)"
        let refreshUrl = URL(string: "\(TestConfig.httpUrl)\(cookiePath)auth/refresh")!
        let maxAge = 7 * 24 * 60 * 60
        let setCookieHeader = "\(cookieName)=\(refreshToken); Path=\(cookiePath); Max-Age=\(maxAge); HttpOnly; SameSite=None"
        let cookiesToInstall = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookieHeader],
            for: refreshUrl
        )
        XCTAssertEqual(cookiesToInstall.count, 1, "Failed to parse Set-Cookie for refresh token")
        for c in cookiesToInstall { HTTPCookieStorage.shared.setCookie(c) }
        defer {
            for c in cookiesToInstall { HTTPCookieStorage.shared.deleteCookie(c) }
        }

        // Sanity: URLSession should attach the cookie to requests against the
        // refresh path. If this fails, the rest of the assertions are noise.
        let attached = HTTPCookieStorage.shared.cookies(for: refreshUrl) ?? []
        XCTAssertTrue(
            attached.contains(where: { $0.name == cookieName }),
            "Installed refresh cookie not attached for \(refreshUrl). Stored cookies: \(attached.map { "\($0.name)=<…>" })"
        )

        // 3. Pre-seed SQLite with an expired JWT record — same shape the
        // client writes after any normal login, but `expiresAt` dialed back
        // 2h so the bootstrap path sees it as stale.
        let bootstrapStore = OfflineStore()
        let bootstrapProvider = SQLiteStorageProvider(path: dbPath)
        bootstrapStore.setStorageProvider(bootstrapProvider)

        let iso = ISO8601DateFormatter()
        let expiredRecord = PersistedJwtRecord(
            key: "session",
            token: "expired.placeholder.token",
            expiresAt: iso.string(from: Date().addingTimeInterval(-7200)),
            storedAt: iso.string(from: Date().addingTimeInterval(-7200 - 3600)),
            userId: testApp.ownerUserId,
            version: 1
        )
        try await bootstrapStore.persistJwt(appId: testApp.appId, namespace: namespace, record: expiredRecord)
        await bootstrapProvider.close()

        // 4. Cold-start a client with the same SQLite path, no token.
        // With the bug present: isAuthenticated() stays false.
        // With the fix: tryRestoreSession sees the expired record, POSTs
        // /auth/refresh (cookie attached by URLSession), applies the new
        // access token.
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: testApp.appId,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .sqlite(directory: dbPath),
            auth: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: namespace),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        try await client.waitForAuthReady(timeout: 10)

        XCTAssertTrue(
            client.isAuthenticated(),
            "Cold start with expired persisted JWT + live refresh cookie should refresh, not log the user out"
        )
        XCTAssertEqual(client.getUserId(), testApp.ownerUserId)

        // Token we end up with must be freshly issued, not the placeholder
        // we seeded. A nil payload or a stale exp would both indicate the
        // fix path didn't run.
        guard let payload = client.getJwtPayload(),
              let exp = payload["exp"] as? TimeInterval else {
            XCTFail("Expected a parseable JWT payload after cold-start refresh")
            return
        }
        XCTAssertGreaterThan(exp, Date().timeIntervalSince1970, "Refreshed token must not be expired")
    }
}
