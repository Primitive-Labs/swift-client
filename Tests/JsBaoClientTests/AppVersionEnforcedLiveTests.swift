import XCTest
@testable import JsBaoClient

/// The Swift client against the real enforcing dev server, no loopback
/// stand-in (project `client-version-policy` phase 5; intent criteria 5 and
/// 10). The app's `[clients.ios]` says `minRequired = "2.0"`, `enforce = true`.
///
/// Refusal state is read from `appVersionController.isRefused` and
/// `reportedStatus` before anything asks for the status: `getStatus()`,
/// `getPolicy()`, `refresh()` and `onStatusChange` all start tracking and
/// fetch, and against this policy a fetch alone would compute
/// `updateRequired` whether or not the refusal was handled.
final class AppVersionEnforcedLiveTests: XCTestCase {
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

    private func client(_ app: TestApp, version: String) -> JsBaoClient {
        let client = makeEnforcedLiveClient(app, version: version)
        clients.append(client)
        return client
    }

    // MARK: - HTTP first

    func testAnHttpRefusalIsHeldUnaskedThenLiftedByALoweredMinimum() async throws {
        let app = try await ctx.createTestApp(name: "swift-cv-enforced-http")
        try await ctx.pushEnforcingPolicy(app, minRequired: "2.0")
        let client = client(app, version: "1.9")
        _ = await client.waitForStorageReady(timeout: 5)
        XCTAssertEqual(client.appVersionController.reportedStatus, .unknown, "nothing asked, nothing refused yet")

        var refusal: HttpError?
        do {
            _ = try await client.requestJSON(method: .get, path: "/me")
        } catch let error as HttpError {
            refusal = error
        }
        XCTAssertEqual(refusal?.status, 426, String(describing: refusal))
        XCTAssertEqual(refusal?.serverCode, "CLIENT_UPDATE_REQUIRED")

        // Still no ask: the refusal alone set this.
        XCTAssertTrue(client.appVersionController.isRefused)
        XCTAssertEqual(client.appVersionController.reportedStatus, .updateRequired)
        let asked = await client.appVersion.getStatus()
        XCTAssertEqual(asked, .updateRequired)
        try await delay(4)
        XCTAssertFalse(client.isConnected)

        try await ctx.pushEnforcingPolicy(app, minRequired: "1.9")
        let lifted = await client.appVersion.refresh()
        XCTAssertNotEqual(lifted, .updateRequired)
        XCTAssertFalse(client.appVersionController.isRefused)
        try await client.connect()
        try await waitForConnection(client: client, timeout: 15)
        let me = try await client.requestJSON(method: .get, path: "/me")
        XCTAssertNotNil(me)
    }

    // MARK: - Socket first

    func testASocketRefusalByUrlParametersIsHeldUnaskedAndAClientAtTheMinimumConnects() async throws {
        let app = try await ctx.createTestApp(name: "swift-cv-enforced-socket")
        try await ctx.pushEnforcingPolicy(app, minRequired: "2.0")
        let client = client(app, version: "1.9")
        _ = await client.waitForStorageReady(timeout: 5)
        XCTAssertEqual(client.appVersionController.reportedStatus, .unknown)

        let closes = LockedBox<[Int?]>([])
        let sub = client.eventEmitter.subscribe(ConnectionCloseEvent.self) { event in closes.withValue { $0.append(event.code) } }
        defer { sub.cancel() }

        // The socket is this client's first contact. Whether connect() throws
        // or returns on an accept-then-close is not part of the contract.
        let connectError: Error?
        do {
            try await client.connect()
            connectError = nil
        } catch {
            connectError = error
        }
        try await eventually(timeout: 15, description: "the 4426 close") { !closes.value.isEmpty }
        FileHandle.standardError.write(Data("[6041-swift] connect() on a refused socket \(connectError.map { "threw \($0)" } ?? "returned")\n".utf8))
        XCTAssertEqual(closes.value.first ?? nil, 4426, "connect() \(connectError.map { "threw \($0)" } ?? "returned")")

        // Still no ask.
        XCTAssertTrue(client.appVersionController.isRefused)
        XCTAssertEqual(client.appVersionController.reportedStatus, .updateRequired)
        XCTAssertFalse(client.isConnected)
        let seen = closes.value.count
        try await delay(4)
        XCTAssertEqual(closes.value.count, seen, "no automatic redial while refused")
        XCTAssertFalse(client.isConnected)

        let current = self.client(app, version: "2.0")
        _ = await current.waitForStorageReady(timeout: 5)
        try await current.connect()
        try await waitForConnection(client: current, timeout: 15)
        try await delay(0.5)
        XCTAssertTrue(current.isConnected)
        XCTAssertFalse(current.appVersionController.isRefused)
    }
}
