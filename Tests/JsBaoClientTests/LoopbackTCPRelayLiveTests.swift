import XCTest
@testable import JsBaoClient

/// The observed local URL the backend resolver's live suite puts in front of
/// the dev server (#6185, plan step 0.1): a client pointed at the relay signs
/// in, makes a request and connects its socket through it, and the relay's
/// record shows the request and the upgrade.
/// Deprecated only because it writes and reads back with the documents family.
@available(*, deprecated)
final class LoopbackTCPRelayLiveTests: XCTestCase {
    var ctx: TestContext!
    var relay: LoopbackTCPRelay!
    var client: JsBaoClient?

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        relay = try LoopbackTCPRelay(target: TestConfig.httpUrl)
        try relay.start()
    }

    override func tearDown() async throws {
        if let client { await client.destroy() }
        relay?.stop()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    func testAClientThroughTheRelayWorksAndTheRelayRecordsItsRequestAndUpgrade() async throws {
        let app = try await ctx.createTestApp(name: "swift-relay-6185")
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: relay.baseUrl,
            wsUrl: relay.wsUrl,
            appId: app.appId,
            token: app.ownerJWT,
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false
        ))
        self.client = client
        let created = try await client.documents.createWithAlias(options: CreateWithAliasOptions(
            title: "Through the relay", alias: AliasRef(scope: .user, aliasKey: "relay-\(UUID().uuidString.prefix(8))")
        ))
        let info = try await client.documents.get(documentId: created.documentId)
        XCTAssertEqual(info.title, "Through the relay")
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)

        let paths = relay.requests.map(\.pathOnly)
        XCTAssertTrue(paths.contains("/app/\(app.appId)/api/documents/create-with-alias"), "\(paths)")
        XCTAssertTrue(paths.contains("/app/\(app.appId)/api/documents/\(created.documentId)"), "\(paths)")
        XCTAssertEqual(relay.upgrades.count, 1, "\(relay.requests.map { "\($0.method) \($0.path)" })")
    }
}
