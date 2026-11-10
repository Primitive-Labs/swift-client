import XCTest
@testable import JsBaoClient

/// #5578 — against the live dev server, with the handshake's user-channel
/// write held through the local test route (`handshake-mapping` on the
/// client's own connection id): a token for another user applied while the
/// socket waits for `ready` rebuilds it, and the client ends connected as the
/// new user, registered on the new user's channel and not the old one's. At
/// `.connected` the row exists on one read, and an access request made then
/// reaches the client. Port of the JS cases in
/// `tests/client/js-bao-client-ready-5578.test.ts`.
final class ReadyFrameLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-ready-frame-5578")
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        await ctx?.cleanup()
    }

    private var testAuth: String {
        ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret"
    }

    /// `POST /__test__/connection/<id>/hold` for `handshake-mapping`.
    @discardableResult
    private func hold(_ connectionId: String, _ action: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(TestConfig.httpUrl)/__test__/connection/\(connectionId)/hold")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(testAuth, forHTTPHeaderField: "X-Test-Auth")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["point": "handshake-mapping", "action": action])
        let (data, response) = try await NetworkSession.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Whether the connection's row on `userId`'s channel exists: one read.
    private func mappingRow(_ connectionId: String, userId: String) async throws -> Bool {
        let channel = "userMetadata:\(testApp.appId):\(userId)"
        var components = URLComponents(string: "\(TestConfig.httpUrl)/__test__/connection/\(connectionId)/state")!
        components.queryItems = [URLQueryItem(name: "documentId", value: channel)]
        var request = URLRequest(url: components.url!)
        request.setValue(testAuth, forHTTPHeaderField: "X-Test-Auth")
        let (data, _) = try await NetworkSession.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return json["mappingRow"] as? Bool == true
    }

    func testATokenForAnotherUserAppliedBeforeReadyConnectsAsTheNewUser() async throws {
        let second = try await ctx.createTestUser(appId: testApp.appId)
        let created = try await ctx.appRequest(
            method: "POST", appId: testApp.appId, path: "/documents",
            body: ["title": "Swift ready switch", "documentFormat": 3], jwt: second.jwt
        )
        let db3Id = try XCTUnwrap(created["documentId"] as? String)

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)
        let heard = LockedBox<[Db3AccessRequestCreatedEvent]>([])
        let sub = client.eventEmitter.subscribe(Db3AccessRequestCreatedEvent.self) { event in
            heard.withValue { $0.append(event) }
        }
        defer { sub.cancel() }
        let id = client.connectionId
        try await hold(id, "arm")

        let returned = LockedBox(false)
        let attempt = Task {
            try? await client.connect()
            returned.value = true
        }
        try await eventually(timeout: 15, interval: 0.1, description: "the handshake reaching handshake-mapping") {
            try await self.hold(id, "status")["held"] as? Bool == true
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(client.isConnected, "open is not connected while the write is held")
        XCTAssertFalse(returned.value, "connect() waits for ready")

        client.updateToken(second.jwt, cause: "test")
        let released = try await hold(id, "release")
        XCTAssertEqual(released["released"] as? Bool, true)
        try await waitForConnection(client: client, timeout: 30)

        // At connected, with nothing in between: one read, one request.
        let registered = try await mappingRow(id, userId: second.userId)
        let asked = try await ctx.appRequest(
            method: "POST", appId: testApp.appId, path: "/documents/\(db3Id)/access-requests",
            body: ["permission": "reader"], jwt: testApp.ownerJWT
        )
        XCTAssertTrue(registered, "the new user's channel row at connected")
        let request = try XCTUnwrap(asked["request"] as? [String: Any])
        let requestId = try XCTUnwrap(request["requestId"] as? String)
        try await eventually(timeout: 15, description: "the new user hears the request") {
            heard.value.contains { $0.requestId == requestId }
        }
        try await eventually(timeout: 15, description: "no row on the previous user's channel") {
            !(try await self.mappingRow(id, userId: self.testApp.ownerUserId))
        }
        _ = await attempt.value
    }
}
