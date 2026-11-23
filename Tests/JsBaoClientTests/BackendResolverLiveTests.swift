import XCTest
@testable import JsBaoClient

/// Backend overrides end to end on the local dev server (#6185, project
/// `client-backend-overrides`, phase 2; intent criteria 6 and 9): two apps,
/// policies written with `PUT settings`, a copy that resolves its backend and
/// then constructs a client from the answer. The home app and the target are
/// each reached through a `LoopbackTCPRelay`, so where every request and
/// socket went is read from what each URL received.
/// Deprecated only because it writes and reads back with the documents family.
@available(*, deprecated)
final class BackendResolverLiveTests: XCTestCase {
    var ctx: TestContext!
    var home: LoopbackTCPRelay!
    var second: LoopbackTCPRelay!
    var clients: [JsBaoClient] = []
    var stores: [ResolverStore] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        home = try LoopbackTCPRelay(target: TestConfig.httpUrl)
        try home.start()
        second = try LoopbackTCPRelay(target: TestConfig.httpUrl)
        try second.start()
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        home?.stop()
        second?.stop()
        stores.forEach { $0.remove() }
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private func pushPolicy(_ app: TestApp, _ policy: [String: Any]) async throws {
        try await ctx.updateAppSettings(appId: app.appId, updates: ["clientVersions": policy], jwt: app.ownerJWT)
    }

    private func overrideTo(_ appId: String, from: String = "2.0", apiUrl: String? = nil) -> [String: Any] {
        var override: [String: Any] = ["from": from, "appId": appId]
        if let apiUrl { override["apiUrl"] = apiUrl }
        return ["ios": ["latest": "9.0", "backendOverrides": [override]]]
    }

    private func newStore() -> ResolverStore {
        let store = ResolverStore()
        stores.append(store)
        return store
    }

    /// The build's own options for a copy of `app` at `version`, against the home URL.
    private func options(_ app: TestApp, version: String, store: ResolverStore) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: home.baseUrl,
            wsUrl: home.wsUrl,
            appId: app.appId,
            token: app.ownerJWT,
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: store.storage,
            autoNetwork: false,
            appVersion: version,
            platform: "ios"
        )
    }

    private func resolve(_ options: JsBaoClientOptions) async -> ResolvedBackend {
        await JsBaoClient.resolveBackend(options: options, timeout: 20)
    }

    private func client(_ options: JsBaoClientOptions) -> JsBaoClient {
        let client = JsBaoClient(options: options)
        clients.append(client)
        return client
    }

    private func policyPath(_ appId: String) -> String { "/app/\(appId)/api/settings/client-versions" }

    private func aliasKey() -> String { "br-6185-\(UUID().uuidString.prefix(8))" }

    // MARK: - Behaviors 26 and 32

    func testACopyAtVWorksInBAfterBsSessionAndACopyBelowVWorksInA() async throws {
        let appA = try await ctx.createTestApp(name: "swift-br-6185-home")
        let appB = try await ctx.createTestApp(name: "swift-br-6185-target")
        try await pushPolicy(appA, overrideTo(appB.appId))

        let atVOptions = options(appA, version: "2.0", store: newStore())
        let atV = await resolve(atVOptions)
        XCTAssertEqual(atV, ResolvedBackend(appId: appB.appId, apiUrl: home.baseUrl, wsUrl: home.wsUrl, overridden: true, source: .fresh))
        let markHome = home.requests.count, markSecond = second.requests.count

        let inB = client(atV.applied(to: atVOptions))
        await inB.waitForStorageReady(timeout: 5)
        try await delay(0.5)
        XCTAssertNil(inB.auth.token, "the home token does not follow the override")
        let beforeSession = Array(home.requests.dropFirst(markHome)) + Array(second.requests.dropFirst(markSecond))
        XCTAssertFalse(beforeSession.contains { $0.header("Authorization")?.contains(appA.ownerJWT) == true },
                       "behavior 32: no request carries A's token")

        inB.updateToken(appB.ownerJWT)
        let created = try await inB.documents.createWithAlias(options: CreateWithAliasOptions(
            title: "Written in B", alias: AliasRef(scope: .user, aliasKey: aliasKey())
        ))
        let readBack = try await inB.documents.get(documentId: created.documentId)
        XCTAssertEqual(readBack.title, "Written in B")
        let afterSession = Array(home.requests.dropFirst(markHome)) + Array(second.requests.dropFirst(markSecond))
        XCTAssertFalse(afterSession.contains { $0.header("Authorization")?.contains(appA.ownerJWT) == true })
        do {
            _ = try await ctx.appRequest(method: "GET", appId: appA.appId, path: "/documents/\(created.documentId)", body: nil, jwt: appA.ownerJWT)
            XCTFail("the document written in B is readable in A")
        } catch {}

        let belowOptions = options(appA, version: "1.9", store: newStore())
        let belowV = await resolve(belowOptions)
        XCTAssertEqual(belowV, ResolvedBackend(appId: appA.appId, apiUrl: home.baseUrl, wsUrl: home.wsUrl, overridden: false, source: .fresh))
        let inA = client(belowV.applied(to: belowOptions))
        XCTAssertEqual(inA.auth.token, appA.ownerJWT, "the token is kept when not overridden")
        let mark = home.requests.count
        let mine = try await inA.documents.createWithAlias(options: CreateWithAliasOptions(
            title: "Written in A", alias: AliasRef(scope: .user, aliasKey: aliasKey())
        ))
        let mineBack = try await inA.documents.get(documentId: mine.documentId)
        XCTAssertEqual(mineBack.documentId, mine.documentId)
        let since = home.requests.dropFirst(mark).map(\.pathOnly)
        XCTAssertTrue(since.contains { $0.hasPrefix("/app/\(appA.appId)/") })
        XCTAssertFalse(since.contains { $0.hasPrefix("/app/\(appB.appId)/") })
    }

    // MARK: - Behavior 27

    func testAClientBuiltFromTheAnswerStaysOnATargetWithOverridesOfItsOwn() async throws {
        let appA = try await ctx.createTestApp(name: "swift-br-6185-hop-home")
        let appB = try await ctx.createTestApp(name: "swift-br-6185-hop-target")
        let appC = "target-c-6185"
        try await pushPolicy(appB, ["ios": ["latest": "3.0", "minRequired": "2.5", "backendOverrides": [["from": "1.0", "appId": appC]]]])
        try await pushPolicy(appA, overrideTo(appB.appId))

        let given = options(appA, version: "2.0", store: newStore())
        let answer = await resolve(given)
        XCTAssertEqual(answer.appId, appB.appId)
        let mark = home.requests.count
        let client = client(answer.applied(to: given))
        let status = await client.appVersion.getStatus()
        XCTAssertEqual(status, .updateRequired)
        let policy = await client.appVersion.getPolicy()
        XCTAssertEqual(policy, ClientPlatformVersions(latest: "3.0", minRequired: "2.5"))
        try await delay(0.3)

        let since = home.requests.dropFirst(mark).map(\.pathOnly)
        XCTAssertTrue(since.contains(policyPath(appB.appId)), "\(since)")
        XCTAssertFalse(since.contains { $0.contains(appC) }, "\(since)")
        XCTAssertFalse(since.contains { $0.hasPrefix("/app/\(appA.appId)/") }, "\(since)")
        XCTAssertFalse(second.requests.contains { $0.path.contains(appC) })
    }

    // MARK: - Behavior 28

    func testARemovedOverrideAnswersHomeOnTheNextRun() async throws {
        let appA = try await ctx.createTestApp(name: "swift-br-6185-remove-home")
        let appB = try await ctx.createTestApp(name: "swift-br-6185-remove-target")
        try await pushPolicy(appA, overrideTo(appB.appId))
        let store = newStore()
        let given = options(appA, version: "2.0", store: store)
        let first = await resolve(given)
        XCTAssertEqual(first.appId, appB.appId)

        try await pushPolicy(appA, ["ios": ["latest": "9.0"]])
        let next = await resolve(given)
        XCTAssertEqual(next, ResolvedBackend(appId: appA.appId, apiUrl: home.baseUrl, wsUrl: home.wsUrl, overridden: false, source: .fresh))
    }

    // MARK: - Behavior 29

    func testAnOverrideAddedLaterReachesACopyOnTheRunAfterItsBackgroundRefresh() async throws {
        let appA = try await ctx.createTestApp(name: "swift-br-6185-later-home")
        let appB = try await ctx.createTestApp(name: "swift-br-6185-later-target")
        try await pushPolicy(appA, ["ios": ["latest": "9.0"]])
        let store = newStore()
        let given = options(appA, version: "2.0", store: store)
        let first = await resolve(given)
        XCTAssertEqual(first.source, .fresh)
        XCTAssertFalse(first.overridden)

        try await pushPolicy(appA, overrideTo(appB.appId))
        let second = await resolve(given)
        XCTAssertEqual(second, ResolvedBackend(appId: appA.appId, apiUrl: home.baseUrl, wsUrl: home.wsUrl, overridden: false, source: .stored))
        try await eventually(timeout: 20, description: "the background refresh writes the override") {
            store.record(appA.appId)?["clients"].map { "\($0)".contains(appB.appId) } == true
        }
        let third = await resolve(given)
        XCTAssertEqual(third, ResolvedBackend(appId: appB.appId, apiUrl: home.baseUrl, wsUrl: home.wsUrl, overridden: true, source: .fresh))
    }

    // MARK: - Behavior 30

    func testWithBBehindASecondURLTheCopySendsItsRequestsAndSocketThere() async throws {
        let appA = try await ctx.createTestApp(name: "swift-br-6185-url-home")
        let appB = try await ctx.createTestApp(name: "swift-br-6185-url-target")
        do {
            try await pushPolicy(appA, overrideTo(appB.appId, apiUrl: second.baseUrl))
            XCTFail("an apiUrl without its root slash is refused")
        } catch {
            XCTAssertTrue("\(error)".contains("HTTP 400"), "\(error)")
        }
        try await pushPolicy(appA, overrideTo(appB.appId, apiUrl: second.baseUrl + "/"))
        let homeMark = home.requests.count, secondMark = second.requests.count

        let given = options(appA, version: "2.0", store: newStore())
        let answer = await resolve(given)
        XCTAssertEqual(answer, ResolvedBackend(appId: appB.appId, apiUrl: second.baseUrl, wsUrl: second.wsUrl, overridden: true, source: .fresh))
        let client = client(answer.applied(to: given))
        await client.waitForStorageReady(timeout: 5)
        client.updateToken(appB.ownerJWT)
        let created = try await client.documents.createWithAlias(options: CreateWithAliasOptions(
            title: "Behind the second URL", alias: AliasRef(scope: .user, aliasKey: aliasKey())
        ))
        let readBack = try await client.documents.get(documentId: created.documentId)
        XCTAssertEqual(readBack.documentId, created.documentId)
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
        try await delay(0.3)

        let atSecond = second.requests.dropFirst(secondMark)
        XCTAssertTrue(atSecond.contains { $0.pathOnly == "/app/\(appB.appId)/api/documents/create-with-alias" }, "\(atSecond.map(\.path))")
        XCTAssertTrue(atSecond.contains { $0.pathOnly == "/app/\(appB.appId)/api/documents/\(created.documentId)" })
        XCTAssertEqual(atSecond.filter(\.isUpgrade).count, 1, "the socket upgrade reached the second URL")
        XCTAssertEqual(home.requests.dropFirst(homeMark).map(\.pathOnly), [policyPath(appA.appId)], "only the policy read at home")
    }
}
