import XCTest
@testable import JsBaoClient

/// Tests for the auth lifecycle events wired in #1059:
/// - `.authLogout` (JS `auth:logout`) — fires immediately when logout starts
/// - `.authLogoutComplete` (JS `auth:logout:complete`) — fires when logout
///   teardown finishes
/// - `.authOnlineRequired` (JS `auth:onlineAuthRequired`) — fires when the
///   client tries to go online without a valid token and re-auth fails
final class AuthLifecycleEventTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-auth-lifecycle")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    /// `auth.logout()` must emit `.authLogout` first, then
    /// `.authLogoutComplete` once teardown finishes — same ordering as the
    /// JS client's `logout()`.
    func testLogoutEmitsLogoutThenComplete() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let order = OrderRecorder()
        let logoutSub = client.events.on(.authLogout) { (_: AuthLogoutEvent) in
            order.append("logout")
        }
        let completeSub = client.events.on(.authLogoutComplete) { (_: AuthLogoutCompleteEvent) in
            order.append("complete")
        }

        try await client.auth.logout()
        try await delay(0.2)

        XCTAssertEqual(
            order.snapshot(), ["logout", "complete"],
            "Expected auth:logout to fire immediately and auth:logout:complete after teardown"
        )
        XCTAssertNil(client.auth.getToken(), "Token should be cleared after logout")
        XCTAssertFalse(client.isAuthenticated(), "Client should be signed out after logout")

        logoutSub.cancel()
        completeSub.cancel()
    }

    /// The legacy `client.logout(wipeLocal:)` entry point funnels through the
    /// same controller method and must emit the same pair, in order.
    func testTopLevelLogoutEmitsBothEvents() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let order = OrderRecorder()
        let logoutSub = client.events.on(.authLogout) { (_: AuthLogoutEvent) in
            order.append("logout")
        }
        let completeSub = client.events.on(.authLogoutComplete) { (_: AuthLogoutCompleteEvent) in
            order.append("complete")
        }

        try await client.logout()
        try await delay(0.2)

        XCTAssertEqual(order.snapshot(), ["logout", "complete"])

        logoutSub.cancel()
        completeSub.cancel()
    }

    /// Going online with no token (post-logout, no refresh session) must emit
    /// `.authOnlineRequired` and revert the client to offline mode — mirrors
    /// the JS `setNetworkMode("online")` handoff. Test sessions are created
    /// from raw JWTs (no refresh cookie), so the refresh attempt fails the
    /// same way a signed-out browser session would.
    func testGoOnlineWithoutTokenEmitsOnlineAuthRequired() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Sign out so there is no token, then try to come back online.
        try await client.auth.logout()
        XCTAssertNil(client.auth.getToken())

        let order = OrderRecorder()
        let sub = client.events.on(.authOnlineRequired) { (_: AuthOnlineRequiredEvent) in
            order.append("onlineAuthRequired")
        }

        await client.goOnline()
        try await delay(0.2)

        XCTAssertEqual(
            order.snapshot(), ["onlineAuthRequired"],
            "Expected auth:onlineAuthRequired when going online without a valid token"
        )
        XCTAssertEqual(
            client.getNetworkMode(), .offline,
            "Client should revert to offline mode when online auth is required"
        )
        XCTAssertFalse(client.isConnected, "Client must not connect without a token")

        sub.cancel()
    }

    /// #1113: the synchronous `setNetworkMode(.online)` entry point must run
    /// the same auth handoff as `goOnline()` (in JS, goOnline IS
    /// setNetworkMode("online")). With no usable token the full JS event
    /// sequence must fire: `networkMode` online -> `auth:onlineAuthRequired`
    /// -> `networkMode` offline (the revert), ending offline and disconnected.
    func testSetNetworkModeOnlineWithoutTokenRunsAuthHandoff() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Sign out so there is no token, then force online via the sync API.
        try await client.auth.logout()
        XCTAssertNil(client.auth.getToken())

        let order = OrderRecorder()
        let modeSub = client.events.on(.networkMode) { (e: NetworkModeEvent) in
            order.append("networkMode:\(e.mode.rawValue)")
        }
        let authSub = client.events.on(.authOnlineRequired) { (_: AuthOnlineRequiredEvent) in
            order.append("onlineAuthRequired")
        }

        client.setNetworkMode(.online)
        try await eventually(timeout: 5, description: "handoff reverts to offline") {
            client.getNetworkMode() == .offline
        }
        try await delay(0.2)

        XCTAssertEqual(
            order.snapshot(),
            ["networkMode:online", "onlineAuthRequired", "networkMode:offline"],
            "setNetworkMode(.online) must produce the JS event sequence: online -> onlineAuthRequired -> offline revert"
        )
        XCTAssertEqual(client.getNetworkMode(), .offline)
        XCTAssertFalse(client.isConnected, "Client must not connect without a token")

        modeSub.cancel()
        authSub.cancel()
    }

    /// #1113: with a valid token, `setNetworkMode(.online)` must run the
    /// handoff's connect half — no `.authOnlineRequired`, no offline revert.
    func testSetNetworkModeOnlineWithTokenStaysOnline() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let order = OrderRecorder()
        let sub = client.events.on(.authOnlineRequired) { (_: AuthOnlineRequiredEvent) in
            order.append("onlineAuthRequired")
        }

        await client.goOffline()
        client.setNetworkMode(.online)
        try await delay(1.0)

        XCTAssertTrue(order.snapshot().isEmpty,
                      "auth:onlineAuthRequired must not fire when a token is present")
        XCTAssertEqual(client.getNetworkMode(), .online,
                       "mode must not revert when the token is usable")

        sub.cancel()
    }

    /// With a valid token, `goOnline()` must NOT emit `.authOnlineRequired`.
    func testGoOnlineWithTokenDoesNotEmitOnlineAuthRequired() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let order = OrderRecorder()
        let sub = client.events.on(.authOnlineRequired) { (_: AuthOnlineRequiredEvent) in
            order.append("onlineAuthRequired")
        }

        await client.goOffline()
        await client.goOnline()
        try await delay(0.2)

        XCTAssertTrue(order.snapshot().isEmpty,
                      "auth:onlineAuthRequired must not fire when a token is present")
        XCTAssertTrue(client.isOnline())

        sub.cancel()
    }
}

/// Thread-safe ordered event recorder for assertions on emit ordering.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
