import XCTest
@testable import JsBaoClient

/// The client reports its version and platform on every app-API request and
/// socket connect (#6036): `X-Primitive-App-Version` and
/// `X-Primitive-App-Platform` headers on HTTP, the same names as URL
/// parameters on the socket, both only when both are known.
final class AppVersionHeadersHermeticTests: XCTestCase {

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

    private func client(
        appVersion: String? = "2.0",
        bundleVersion: (@Sendable () -> Any?)? = nil
    ) -> JsBaoClient {
        let client = world.client(appVersion: appVersion, bundleVersion: bundleVersion)
        clients.append(client)
        return client
    }

    private func lastRequest(to path: String) throws -> LoopbackAPIServer.Request {
        try XCTUnwrap(world.api.requests.last { $0.apiPathOnly == path }, "no request to \(path)")
    }

    // MARK: - Behavior 11

    func testEveryHttpClientRequestCarriesTheTwoHeaders() async throws {
        let client = client()
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        _ = try? await client.gatedTransport.execute(method: .post, path: "/probe/write", body: Data("{}".utf8), options: nil)
        _ = await client.appVersion.getStatus()
        for path in ["/probe", "/probe/write", "/settings/client-versions"] {
            let request = try lastRequest(to: path)
            XCTAssertEqual(request.header("X-Primitive-App-Version"), "2.0", path)
            XCTAssertEqual(request.header("X-Primitive-App-Platform"), "ios", path)
        }
    }

    func testTheBundleVersionIsReportedWhenNoOptionIsGiven() async throws {
        let client = client(appVersion: nil, bundleVersion: { "7.1" })
        XCTAssertEqual(client.appVersion.version, "7.1")
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        XCTAssertEqual(try lastRequest(to: "/probe").header("X-Primitive-App-Version"), "7.1")
    }

    // MARK: - Behavior 12

    func testBothBlobManagerRequestSitesCarryTheTwoHeaders() async throws {
        let client = client()
        let download = try XCTUnwrap(
            client.blobManager.downloadRequest(family: .documents, documentId: "doc-1", blobId: "blob-1")
        )
        XCTAssertEqual(download.value(forHTTPHeaderField: "X-Primitive-App-Version"), "2.0")
        XCTAssertEqual(download.value(forHTTPHeaderField: "X-Primitive-App-Platform"), "ios")

        _ = try? await client.blobManager.read(documentId: "doc-1", blobId: "blob-1")
        let read = try XCTUnwrap(world.api.requests.last { $0.apiPathOnly.hasSuffix("blob-1/download") })
        XCTAssertEqual(read.header("X-Primitive-App-Version"), "2.0")

        _ = try? await client.blobManager.readSessionAttachment(
            sessionId: "session-1", documentId: "doc-1", blobId: "blob-2", force: true, disposition: nil
        )
        let attachment = try XCTUnwrap(world.api.requests.last { $0.apiPathOnly.hasSuffix("blob-2/download") })
        XCTAssertEqual(attachment.header("X-Primitive-App-Version"), "2.0")
        XCTAssertEqual(attachment.header("X-Primitive-App-Platform"), "ios")
    }

    // MARK: - Behavior 13

    func testTheSocketUrlCarriesTheTwoNamesAsParameters() throws {
        let client = client()
        let (url, _) = client.webSocketManagerBuildConnectionRequest(connectionId: "conn-1")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "X-Primitive-App-Version" }?.value, "2.0")
        XCTAssertEqual(items.first { $0.name == "X-Primitive-App-Platform" }?.value, "ios")
        XCTAssertEqual(items.first { $0.name == "connectionId" }?.value, "conn-1")
    }

    // MARK: - Behavior 14

    func testEverySiteThatSetsTheTenantHeaderAppliesTheHelper() throws {
        var sites = 0
        for source in try ClientSourceText.allClientSources() {
            let lines = ClientSourceText.stripComments(source).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("\"X-Global-Admin-App-Id\"") {
                sites += 1
                let window = lines[max(0, index - 4)...min(lines.count - 1, index + 4)].joined(separator: "\n")
                XCTAssertTrue(
                    window.contains("versionHeaders.apply(to:") || window.contains("versionHeaders.queryItems"),
                    "no ClientVersionHeaders call beside: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(sites, 4, "the four known sites")
    }

    // MARK: - Behavior 5

    func testTheDesignatedInitStopsOnTheRulesRefusal() throws {
        let source = try ClientSourceText.code("JsBaoClient.swift")
        let initBody = try ClientSourceText.slice(
            source, from: "connectivityMonitor injectedMonitor: ConnectivityMonitor?,", to: "deinit {"
        )
        XCTAssertEqual(initBody.components(separatedBy: "ClientVersionRules.resolveClientIdentity(").count - 1, 1,
                       "the identity is resolved exactly once")
        let preconditionLine = try XCTUnwrap(
            initBody.components(separatedBy: "\n").first { $0.contains("precondition(") },
            "the init stops through precondition"
        )
        XCTAssertTrue(preconditionLine.contains(".refusal"), "and passes it the rules' refusal: \(preconditionLine)")
        let resolve = try XCTUnwrap(initBody.range(of: "ClientVersionRules.resolveClientIdentity("))
        let stop = try XCTUnwrap(initBody.range(of: "precondition("))
        let firstComponent = try XCTUnwrap(initBody.range(of: "OfflineStore()"))
        XCTAssertLessThan(resolve.lowerBound, stop.lowerBound)
        XCTAssertLessThan(stop.lowerBound, firstComponent.lowerBound, "before anything is built")
    }

    // MARK: - Behavior 37 (pin): no version, no report

    func testAClientWithNoVersionSendsNoHeadersStampsNothingAndReportsUnknown() async throws {
        let client = client(appVersion: nil, bundleVersion: { nil })
        XCTAssertNil(client.appVersion.version)
        XCTAssertEqual(client.appVersion.platform, "ios")
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        let request = try lastRequest(to: "/probe")
        XCTAssertNil(request.header("X-Primitive-App-Version"))
        XCTAssertNil(request.header("X-Primitive-App-Platform"))

        let (url, _) = client.webSocketManagerBuildConnectionRequest(connectionId: "c")
        XCTAssertFalse(url.absoluteString.contains("X-Primitive-App"), url.absoluteString)

        let logged = LockedBox<[[String: JSONValue]]>([])
        await client.analyticsQueue.setOnEventLogged { event in logged.withValue { $0.append(event) } }
        await client.analytics.logEventAsync(AnalyticsEventInput(action: "probe"))
        try await eventually(description: "the event is logged") { !logged.value.isEmpty }
        XCTAssertNil(logged.value.first?["app_version"], "no app_version stamp")

        let awaited7 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited7, .unknown)
    }

    // MARK: - Edge: a custom header overrides the helper's value

    func testACustomHeaderOverridesTheHelpersValue() async throws {
        let client = client()
        _ = try? await client.gatedTransport.execute(
            method: .get, path: "/probe", body: nil,
            options: RequestOptions(customHeaders: ["X-Primitive-App-Version": "9.9"])
        )
        let request = try lastRequest(to: "/probe")
        XCTAssertEqual(request.header("X-Primitive-App-Version"), "9.9")
        XCTAssertEqual(request.header("X-Primitive-App-Platform"), "ios")
    }
}
