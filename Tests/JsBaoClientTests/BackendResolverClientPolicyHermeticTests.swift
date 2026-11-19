import XCTest
@testable import JsBaoClient

/// A constructed client and backend overrides (#6185, project
/// `client-backend-overrides`, phase 2; intent criterion 6): `client.appVersion`
/// never reports overrides, a platform whose table holds only overrides reads
/// as no table, an override change calls no status listener, the public policy
/// type is unchanged, and a client that never calls the resolver sends nothing
/// new.
final class BackendResolverClientPolicyHermeticTests: XCTestCase {
    private var world: AppVersionWorld!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        world = try AppVersionWorld()
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        world.stop()
    }

    private func track(_ client: JsBaoClient) -> JsBaoClient {
        clients.append(client)
        return client
    }

    private static let overridesOnly =
        #"{"clients":{"ios":{"backendOverrides":[{"from":"1.0","appId":"target-b"}]}}}"#

    // MARK: - Behavior 22

    func testAPlatformHoldingOnlyOverridesReadsAsNoTable() async {
        world.setPolicy(Self.overridesOnly)
        let client = track(world.client())
        let status = await client.appVersion.getStatus()
        XCTAssertEqual(status, .unknown)
        let policy = await client.appVersion.getPolicy()
        XCTAssertNil(policy)
    }

    func testPolicyKeysBesideOverridesAreReportedWithoutThem() async {
        world.setPolicy(#"{"clients":{"ios":{"latest":"3.0","enforce":false,"backendOverrides":[{"from":"1.0","appId":"target-b"}]}}}"#)
        let client = track(world.client())
        let status = await client.appVersion.getStatus()
        XCTAssertEqual(status, .updateAvailable)
        let policy = await client.appVersion.getPolicy()
        XCTAssertEqual(policy, ClientPlatformVersions(latest: "3.0", enforce: false))
    }

    // MARK: - Behavior 23

    func testAddingChangingAndRemovingAnOverrideCallsNoStatusListener() async throws {
        world.setPolicy(#"{"clients":{}}"#)
        let client = track(world.client())
        let initial = await client.appVersion.getStatus()
        XCTAssertEqual(initial, .unknown)
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        for body in [
            Self.overridesOnly,
            #"{"clients":{"ios":{"backendOverrides":[{"from":"1.5","appId":"target-c","apiUrl":"https://c.example.com"}]}}}"#,
            #"{"clients":{}}"#,
        ] {
            world.setPolicy(body)
            let status = await client.appVersion.refresh()
            XCTAssertEqual(status, .unknown, body)
        }

        world.setPolicy(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let current = await client.appVersion.refresh()
        XCTAssertEqual(current, .current)
        for body in [
            #"{"clients":{"ios":{"latest":"2.0","backendOverrides":[{"from":"1.0","appId":"target-b"}]}}}"#,
            #"{"clients":{"ios":{"latest":"2.0","backendOverrides":[{"from":"2.0","appId":"target-c"}]}}}"#,
            #"{"clients":{"ios":{"latest":"2.0"}}}"#,
        ] {
            world.setPolicy(body)
            let status = await client.appVersion.refresh()
            XCTAssertEqual(status, .current, body)
        }
        try await delay(0.2)
        XCTAssertEqual(recorder.statuses, [.current], "only the change a policy key made")
    }

    // MARK: - Edge case: a stored entry with every key unset

    func testAStoredEntryWithEveryKeyUnsetReadsAsNoTable() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .sqlite(let path?) = storage else { return XCTFail("a SQLite path") }
        let store = OfflineStore()
        await store.setAuthStorageProvider(SQLiteStorageProvider(path: path))
        await store.persistClientVersions(
            appId: "app-version-hermetic",
            record: ClientVersionPolicyRecord(clients: ["ios": ClientPlatformVersions()])
        )
        await store.closeStorage()

        world.policy.value = .status(500)
        let client = track(world.client(storage: storage))
        let status = await client.appVersion.getStatus()
        XCTAssertEqual(status, .unknown)
        let policy = await client.appVersion.getPolicy()
        XCTAssertNil(policy)
    }

    // MARK: - Behavior 24 (pin)

    func testClientPlatformVersionsKeepsItsFiveStoredPropertiesAndInitialiser() throws {
        let code = try ClientSourceText.code("API/AppVersionAPI.swift")
        guard let start = code.range(of: "public struct ClientPlatformVersions: Codable, Sendable, Equatable {"),
              let end = code.range(of: "// MARK", range: start.upperBound..<code.endIndex) ??
                code.range(of: "public final class AppVersionAPI", range: start.upperBound..<code.endIndex)
        else { return XCTFail("ClientPlatformVersions not found") }
        let body = String(code[start.upperBound..<end.lowerBound])
        let stored = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public let ") || $0.hasPrefix("public var ") || $0.hasPrefix("let ") || $0.hasPrefix("var ") }
        XCTAssertEqual(stored, [
            "public let latest: String?",
            "public let minRecommended: String?",
            "public let minRequired: String?",
            "public let updateUrl: String?",
            "public let enforce: Bool?",
        ])
        let signature = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(signature.contains(
            "public init( latest: String? = nil, minRecommended: String? = nil, minRequired: String? = nil, updateUrl: String? = nil, enforce: Bool? = nil )"
        ), signature)
        XCTAssertEqual(body.components(separatedBy: "init(").count - 1, 1, "one initialiser")
    }

    // MARK: - Behavior 25 (pin)

    func testAClientThatNeverCallsTheResolverSendsNoPolicyReadAndWritesNoRecord() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = world.client(storage: storage)
        await client.waitForStorageReady(timeout: 5)
        try await client.connect()
        try await eventually(description: "connected") { client.isConnected }
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        try await delay(0.3)
        await client.destroy()

        XCTAssertGreaterThan(world.api.requests.count, 0, "the client did talk to the server")
        XCTAssertEqual(world.policyFetches, 0, "no policy read")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".backend-resolver.json") }, "\(files)")
        XCTAssertTrue(files.contains("store.sqlite"), "\(files)")
    }
}
