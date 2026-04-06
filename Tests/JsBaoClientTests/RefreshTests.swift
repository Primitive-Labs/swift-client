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
}
