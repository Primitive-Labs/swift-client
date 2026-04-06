import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-oauth.test.ts
/// Tests OAuth-related client behavior.
///
/// Note: The JS OAuth tests rely heavily on mocking window.location and fetch,
/// which don't apply to Swift. These tests cover the auth state management
/// aspects that are relevant in a native client context.
final class OAuthTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-oauth")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testAuthStateWithValidToken() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Wait for auth bootstrap
        try await delay(1)

        let state = client.getAuthState()
        XCTAssertTrue(state.authenticated)
    }

    func testAuthStateWithoutToken() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: testApp.appId,
            token: nil,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        try await delay(1)

        let state = client.getAuthState()
        XCTAssertFalse(state.authenticated)
    }

    func testAuthPersistenceInfoMemoryMode() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let info = client.getAuthPersistenceInfo()
        XCTAssertEqual(info["mode"] as? String, "memory")
    }

    func testAuthPersistenceInfoPersistedMode() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: testApp.appId,
            token: testApp.ownerJWT,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .warn,
            storageConfig: .memory,
            auth: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "test-prefix"),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let info = client.getAuthPersistenceInfo()
        XCTAssertEqual(info["mode"] as? String, "persisted")
        XCTAssertEqual(info["prefix"] as? String, "test-prefix")
    }
}
