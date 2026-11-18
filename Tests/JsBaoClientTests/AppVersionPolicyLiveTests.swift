import XCTest
@testable import JsBaoClient

/// `client.appVersion` against the local dev server (#6036): the policy an app
/// pushed with `PUT settings` reaches each client's status, a second app's
/// client reads only its own app's policy, and a change on the server moves
/// the status on `refresh()` and on a reconnect.
final class AppVersionPolicyLiveTests: XCTestCase {
    var ctx: TestContext!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private func pushPolicy(_ app: TestApp, _ policy: [String: Any]) async throws {
        try await ctx.updateAppSettings(appId: app.appId, updates: ["clientVersions": policy], jwt: app.ownerJWT)
    }

    private func client(_ app: TestApp, version: String, platform: String = "ios") -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: app.appId,
            token: app.ownerJWT,
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false,
            appVersion: version,
            platform: platform
        ))
        // The reconnect's fetch is asserted below, so it does not wait.
        client.appVersionController.reconnectJitter = 0
        clients.append(client)
        return client
    }

    // MARK: - Behavior 34

    func testClientsSpanningOnePolicyReportEachStatusAndASecondAppReadsItsOwn() async throws {
        let appA = try await ctx.createTestApp(name: "swift-app-version-6036-a")
        let appB = try await ctx.createTestApp(name: "swift-app-version-6036-b")
        try await pushPolicy(appA, ["ios": ["latest": "4.0", "minRecommended": "3.0", "minRequired": "2.0"]])
        try await pushPolicy(appB, ["ios": ["latest": "1.0"]])

        let rows: [(String, String, AppVersionStatus)] = [
            ("1.5", "ios", .updateRequired),
            ("2.5", "ios", .updateRecommended),
            ("3.5", "ios", .updateAvailable),
            ("4.0", "ios", .current),
            ("5.1", "ios", .current),
            ("1.5", "android", .unknown),
        ]
        for (version, platform, expected) in rows {
            let status = await client(appA, version: version, platform: platform).appVersion.getStatus()
            XCTAssertEqual(status, expected, "\(version) on \(platform)")
        }
        let policyA = await client(appA, version: "1.0").appVersion.getPolicy()
        XCTAssertEqual(policyA, ClientPlatformVersions(latest: "4.0", minRecommended: "3.0", minRequired: "2.0"))

        let clientB = client(appB, version: "1.5")
        let awaited8 = await clientB.appVersion.getStatus()
        XCTAssertEqual(awaited8, .current, "app B's own policy, not app A's")
        let awaited9 = await clientB.appVersion.getPolicy()
        XCTAssertEqual(awaited9, ClientPlatformVersions(latest: "1.0"))
    }

    // MARK: - Behavior 35

    func testAPolicyChangeMovesTheStatusOnRefreshAndOnReconnect() async throws {
        let app = try await ctx.createTestApp(name: "swift-app-version-6036-change")
        try await pushPolicy(app, ["ios": ["latest": "2.0"]])
        let client = client(app, version: "2.0")
        let awaited10 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited10, .current)
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(0.5)

        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        try await pushPolicy(app, ["ios": ["latest": "3.0"]])
        let awaited11 = await client.appVersion.refresh()
        XCTAssertEqual(awaited11, .updateAvailable)
        try await eventually(description: "one call for the refresh") { recorder.statuses == [.updateAvailable] }

        try await pushPolicy(app, ["ios": ["latest": "3.0", "minRequired": "2.5"]])
        await client.forceReconnectAsync()
        try await eventually(timeout: 10, description: "the reconnect moves the status") {
            recorder.statuses == [.updateAvailable, .updateRequired]
        }
        XCTAssertTrue(client.isConnected, "a status from the policy alone does not hold the socket")
        try await delay(0.5)
        XCTAssertEqual(recorder.statuses, [.updateAvailable, .updateRequired], "one call per change")
    }
}
