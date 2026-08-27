import XCTest
@testable import JsBaoClient

/// Issue #2656 — Swift mirrors of the JS auth-bootstrap reference pins in
/// `tests/client/js-bao-client-auth-bootstrap-parity.test.ts` (parity audit
/// items A4 / A5 / A9). Each test asserts the same observable outcome the JS
/// pin asserts:
///
///   A4 — a cold start with no token attempts the cookie refresh regardless of
///        `persistJwtInStorage` and regardless of whether a persisted record
///        exists.
///   A5 — persisted tokens with less than 120s of remaining life are refused on
///        read and never written; a token with no usable `exp` is unusable
///        (not "never expires").
///   A9 — an invalid refresh on the startup/bootstrap path emits no
///        `AuthFailedEvent`; other causes still emit.
///
/// The first test drives a real cold start against the dev server with a real
/// `rt-{appId}` cookie, the way `RefreshTests.testColdStartRestoresViaRefreshCookie`
/// does. The rest use the controller-level transport seam so the leeway
/// boundary and the event suppression can be asserted exactly.
final class AuthBootstrapParityTests: XCTestCase {

    // MARK: - Helpers

    private static let leewayMs = 120_000.0

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// A controller wired to a scripted transport, with an in-memory auth store.
    private func makeController(
        persistConfig: AuthConfig,
        emitter: EventEmitter = EventEmitter(),
        store: OfflineStore,
        responder: @escaping @Sendable (RecordedRequest) async throws -> TransportResponse
    ) -> (controller: AuthController, transport: RecordingTransport) {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: store,
            emitter: emitter,
            refreshProxy: nil,
            persistConfig: persistConfig
        )
        let transport = RecordingTransport(responder: responder)
        controller.setTransport(transport)
        return (controller, transport)
    }

    /// An `OfflineStore` backed by a throwaway SQLite file.
    ///
    /// `MemoryStorageProvider.initialize(namespace:)` wipes its stores on every
    /// call, and `OfflineStore` re-initializes on each read — so a seeded record
    /// would never survive to be read back. SQLite is what the client actually
    /// uses for auth persistence anyway.
    private func makeAuthStore() async -> OfflineStore {
        let dir = NSTemporaryDirectory() + "jsbao-2656-\(UUID().uuidString.prefix(8))/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let provider = SQLiteStorageProvider(path: dir + "auth.sqlite")
        providers.append(provider)
        let store = OfflineStore()
        await store.setAuthStorageProvider(provider)
        return store
    }

    private var tempDirs: [String] = []
    private var providers: [SQLiteStorageProvider] = []

    override func tearDown() async throws {
        for provider in providers { await provider.close() }
        providers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
        tempDirs.removeAll()
    }

    /// Answers `POST /auth/refresh` with a freshly minted token; 401s anything
    /// else so an accidental extra call is visible.
    private func refreshSucceeds(
        with token: String
    ) -> @Sendable (RecordedRequest) async throws -> TransportResponse {
        { call in
            guard call.path == "/auth/refresh" else {
                return TransportResponse(status: 401, headers: [:], body: Data())
            }
            let json = #"{"token":"\#(token)"}"#
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(json.utf8)
            )
        }
    }

    /// Answers every request with 401 — the "refresh cookie is gone" server.
    private let refreshRejects: @Sendable (RecordedRequest) async throws -> TransportResponse = { _ in
        TransportResponse(
            status: 401,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"invalid_refresh"}"#.utf8)
        )
    }

    // MARK: - A4 (behavior 1): live cold start with persistence OFF

    /// Mirrors the JS pin "cold start with no token and persistence OFF (the
    /// default) still refreshes off the rt cookie".
    ///
    /// `RefreshTests.testColdStartRestoresViaRefreshCookie` covers the
    /// persistence-ON path (an expired record on disk). This is the default
    /// configuration: `persistJwtInStorage` is false, so nothing was ever
    /// written to disk and there is no persisted record to consult — the JS
    /// client refreshes anyway, and so must this one.
    func testColdStartWithPersistenceOffRefreshesViaCookie() async throws {
        let ctx = TestContext()
        try await ctx.initialize()
        defer { Task { await ctx.cleanup() } }
        let testApp = try await ctx.createTestApp(name: "swift-2656-a4")

        let refreshToken = try await ctx.mintRefreshToken(
            appId: testApp.appId,
            userId: testApp.ownerUserId
        )

        let cookiePath = "/app/\(testApp.appId)/api/"
        let cookieName = "rt-\(testApp.appId)"
        let refreshUrl = URL(string: "\(TestConfig.httpUrl)\(cookiePath)auth/refresh")!
        let maxAge = 7 * 24 * 60 * 60
        let setCookieHeader =
            "\(cookieName)=\(refreshToken); Path=\(cookiePath); Max-Age=\(maxAge); HttpOnly; SameSite=None"
        let cookiesToInstall = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookieHeader],
            for: refreshUrl
        )
        XCTAssertEqual(cookiesToInstall.count, 1, "Failed to parse Set-Cookie for refresh token")
        for c in cookiesToInstall { HTTPCookieStorage.shared.setCookie(c) }
        defer {
            for c in cookiesToInstall { HTTPCookieStorage.shared.deleteCookie(c) }
        }

        // Default `auth` config: persistJwtInStorage == false. No token, no
        // persisted record, no storage of any kind.
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: testApp.appId,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        try await client.waitForAuthReady(timeout: 10)

        XCTAssertTrue(
            client.isAuthenticated(),
            "Cold start with a live refresh cookie must resume the session even with JWT persistence off"
        )
        XCTAssertEqual(client.userId, testApp.ownerUserId)
    }

    // MARK: - A4 (behavior 2): no persisted record still refreshes

    func testRestoreAttemptsRefreshWhenNoPersistedRecordExists() async throws {
        let store = await makeAuthStore()
        let fresh = makeTestJwt(userId: "u-2656", exp: Int(Date().timeIntervalSince1970) + 3600)
        // Persistence ON, but the store is empty — the "first install" state
        // the old code short-circuited on.
        let (controller, transport) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshSucceeds(with: fresh)
        )

        await controller.tryRestoreSession()

        XCTAssertEqual(
            transport.calls.filter { $0.path == "/auth/refresh" }.count,
            1,
            "A cold start with no persisted record must still try the refresh cookie"
        )
        XCTAssertEqual(controller.getToken(), fresh)
    }

    func testRestoreAttemptsRefreshWhenPersistenceIsDisabled() async throws {
        let store = await makeAuthStore()
        let fresh = makeTestJwt(userId: "u-2656", exp: Int(Date().timeIntervalSince1970) + 3600)
        // Default AuthConfig: persistJwtInStorage == false.
        let (controller, transport) = makeController(
            persistConfig: AuthConfig(),
            store: store,
            responder: refreshSucceeds(with: fresh)
        )

        await controller.tryRestoreSession()

        XCTAssertEqual(
            transport.calls.filter { $0.path == "/auth/refresh" }.count,
            1,
            "Startup refresh must not be gated on persistJwtInStorage"
        )
        XCTAssertEqual(controller.getToken(), fresh)
    }

    // MARK: - A5 (read side)

    /// Control for the two "refused on read" tests: a record comfortably
    /// outside the leeway IS applied, and no refresh is spent.
    func testPersistedRecordOutsideLeewayIsUsed() async throws {
        let store = await makeAuthStore()
        let expiry = Date().addingTimeInterval(3600)
        let token = makeTestJwt(userId: "u-2656", exp: Int(expiry.timeIntervalSince1970))
        try await store.persistJwt(
            appId: "test-app",
            namespace: "ns",
            record: PersistedJwtRecord(
                key: "session",
                token: token,
                expiresAt: isoString(expiry),
                storedAt: isoString(Date().addingTimeInterval(-60)),
                userId: "u-2656",
                version: 1
            )
        )

        let (controller, transport) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshRejects
        )

        await controller.tryRestoreSession()

        XCTAssertEqual(controller.getToken(), token)
        XCTAssertTrue(
            transport.calls.isEmpty,
            "A usable persisted token should be applied without a refresh round trip"
        )
    }

    /// Behavior 3 — 60s of remaining life is inside the 120s leeway.
    func testPersistedRecordInsideLeewayIsRefusedOnRead() async throws {
        let store = await makeAuthStore()
        let expiry = Date().addingTimeInterval(60)
        XCTAssertLessThan(60_000.0, Self.leewayMs)
        let token = makeTestJwt(userId: "u-2656", exp: Int(expiry.timeIntervalSince1970))
        try await store.persistJwt(
            appId: "test-app",
            namespace: "ns",
            record: PersistedJwtRecord(
                key: "session",
                token: token,
                expiresAt: isoString(expiry),
                storedAt: isoString(Date().addingTimeInterval(-3600)),
                userId: "u-2656",
                version: 1
            )
        )

        let (controller, transport) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshRejects
        )

        await controller.tryRestoreSession()

        XCTAssertNil(
            controller.getToken(),
            "A persisted token inside the 120s leeway must not become the session token"
        )
        XCTAssertEqual(
            transport.calls.filter { $0.path == "/auth/refresh" }.count,
            1,
            "A refused record should fall through to the cookie refresh"
        )
    }

    /// Behavior 4 — a record with no usable expiry is unusable, not eternal.
    func testPersistedRecordWithNoUsableExpiryIsRefusedOnRead() async throws {
        let store = await makeAuthStore()
        // No `expiresAt` on the record and no `exp` claim on the token: there
        // is no way to know it is still good, so it cannot be trusted.
        let payload: [String: Any] = ["userId": "u-2656", "sub": "u-2656"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let tokenWithoutExp = "h.\(b64).s"

        try await store.persistJwt(
            appId: "test-app",
            namespace: "ns",
            record: PersistedJwtRecord(
                key: "session",
                token: tokenWithoutExp,
                expiresAt: nil,
                storedAt: isoString(Date().addingTimeInterval(-3600)),
                userId: "u-2656",
                version: 1
            )
        )

        let (controller, _) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshRejects
        )

        await controller.tryRestoreSession()

        XCTAssertNil(
            controller.getToken(),
            "A persisted token with no usable expiry must be treated as unusable, not as never-expiring"
        )
    }

    /// `tryLoadPersistedJwt` is public surface with the same contract.
    func testTryLoadPersistedJwtAppliesTheSameLeeway() async throws {
        let store = await makeAuthStore()
        let expiry = Date().addingTimeInterval(60)
        let token = makeTestJwt(userId: "u-2656", exp: Int(expiry.timeIntervalSince1970))
        try await store.persistJwt(
            appId: "test-app",
            namespace: "ns",
            record: PersistedJwtRecord(
                key: "session",
                token: token,
                expiresAt: isoString(expiry),
                storedAt: isoString(Date()),
                userId: "u-2656",
                version: 1
            )
        )

        let (controller, _) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshRejects
        )

        let loaded = await controller.tryLoadPersistedJwt()
        XCTAssertNil(loaded, "tryLoadPersistedJwt must refuse a token inside the leeway")
    }

    // MARK: - A5 (write side, behavior 5)

    func testTokenInsideLeewayIsNeverPersisted() async throws {
        let store = await makeAuthStore()
        let (controller, _) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshRejects
        )

        // Control: a full-lifetime token IS written.
        let healthy = makeTestJwt(userId: "u-2656", exp: Int(Date().timeIntervalSince1970) + 3600)
        controller.applyToken(healthy, previous: nil, cause: "otpVerify")
        await controller.awaitPendingPersistence()
        let healthyRecord = try await store.loadPersistedJwt(appId: "test-app", namespace: "ns")
        XCTAssertEqual(healthyRecord?.token, healthy)

        // A token with 60s of life left is refused, and the stale record it
        // would have replaced is cleared rather than left behind.
        let shortLived = makeTestJwt(userId: "u-2656", exp: Int(Date().timeIntervalSince1970) + 60)
        controller.applyToken(shortLived, previous: healthy, cause: "otpVerify")
        await controller.awaitPendingPersistence()
        let shortRecord = try await store.loadPersistedJwt(appId: "test-app", namespace: "ns")
        XCTAssertNil(
            shortRecord,
            "A token inside the 120s leeway must not be written to persistent storage"
        )
    }

    func testTokenWithoutExpiryIsNeverPersisted() async throws {
        let store = await makeAuthStore()
        let (controller, _) = makeController(
            persistConfig: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            store: store,
            responder: refreshRejects
        )

        let payload: [String: Any] = ["userId": "u-2656", "sub": "u-2656"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        controller.applyToken("h.\(b64).s", previous: nil, cause: "otpVerify")
        await controller.awaitPendingPersistence()

        let record = try await store.loadPersistedJwt(appId: "test-app", namespace: "ns")
        XCTAssertNil(record, "A token with no usable expiry must not be written to storage")
    }

    // MARK: - A9 (behavior 6)

    func testStartupRefreshFailureEmitsNoAuthFailed() async throws {
        let store = await makeAuthStore()
        let emitter = EventEmitter()
        let (controller, _) = makeController(
            persistConfig: AuthConfig(),
            emitter: emitter,
            store: store,
            responder: refreshRejects
        )

        let events = await collectEvents(from: emitter, event: AuthFailedEvent.self) {
            await controller.tryRestoreSession()
        }

        XCTAssertTrue(
            events.isEmpty,
            "A lapsed refresh cookie at startup is a silent signed-out start, not an auth failure"
        )
        XCTAssertNil(controller.getToken())
    }

    // MARK: - Startup refresh must not outrank a login that lands first

    /// The startup refresh is now unconditional, so an app that presents a
    /// login screen immediately can finish `otpVerify` while it is still in
    /// flight. A refresh cookie from an earlier session — possibly a different
    /// user — must not then replace the session the user just created.
    func testStartupRefreshDoesNotOverwriteAnInteractiveLogin() async throws {
        let store = await makeAuthStore()
        let cookieUserToken = makeTestJwt(
            userId: "old-cookie-user",
            exp: Int(Date().timeIntervalSince1970) + 3600
        )
        let (controller, _) = makeController(
            persistConfig: AuthConfig(),
            store: store,
            responder: { call in
                guard call.path == "/auth/refresh" else {
                    return TransportResponse(status: 401, headers: [:], body: Data())
                }
                // Hold the refresh in flight long enough for the interactive
                // login below to win the race.
                try await Task.sleep(nanoseconds: 300_000_000)
                return TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"token":"\#(cookieUserToken)"}"#.utf8)
                )
            }
        )

        let restore = Task { await controller.tryRestoreSession() }

        // The user signs in while the startup refresh is still out.
        try await Task.sleep(nanoseconds: 50_000_000)
        let interactiveToken = makeTestJwt(
            userId: "signed-in-user",
            exp: Int(Date().timeIntervalSince1970) + 3600
        )
        controller.applyToken(interactiveToken, previous: nil, cause: "otpVerify")

        await restore.value

        XCTAssertEqual(
            controller.getToken(),
            interactiveToken,
            "A startup refresh that resolves late must not replace the session the user just signed into"
        )
        XCTAssertEqual(controller.getUserId(), "signed-in-user")
    }

    /// Control: a non-bootstrap cause still surfaces the failure to the app.
    func testNonBootstrapRefreshFailureStillEmitsAuthFailed() async throws {
        let store = await makeAuthStore()
        let emitter = EventEmitter()
        let (controller, _) = makeController(
            persistConfig: AuthConfig(),
            emitter: emitter,
            store: store,
            responder: refreshRejects
        )

        let events = await collectEvents(from: emitter, event: AuthFailedEvent.self) {
            _ = await controller.refreshAccessToken(cause: "auth_challenge")
        }

        XCTAssertEqual(
            events.count,
            1,
            "An interactive-path refresh rejection must still emit authFailed"
        )
    }
}
