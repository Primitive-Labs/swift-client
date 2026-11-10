import XCTest
@testable import JsBaoClient

/// The access-request events against the live dev server (#5519 behavior
/// 13). An owner's client hears `Db3AccessRequestCreatedEvent` when a second
/// user asks for its db3, and the requester's client hears
/// `Db3AccessRequestResolvedEvent` once the owner approves. Each client counts
/// as registered for user events once `connect()` returns, which it does on the
/// server's `ready` (#5578): its user-channel mapping row then exists on one
/// read through the local test route. Port of the live cases in
/// `tests/client/js-bao-client-access-request-events-5519.test.ts`.
final class AccessRequestEventsLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-access-request-events-5519")
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        await ctx?.cleanup()
    }

    /// Whether the connection's user-channel `ConnectionMapping` row exists.
    private func mappingRow(_ client: JsBaoClient, userId: String) async throws -> Bool {
        let channel = "userMetadata:\(testApp.appId):\(userId)"
        var components = URLComponents(string: "\(TestConfig.httpUrl)/__test__/connection/\(client.connectionId)/state")!
        components.queryItems = [URLQueryItem(name: "documentId", value: channel)]
        var request = URLRequest(url: components.url!)
        request.setValue(
            ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret",
            forHTTPHeaderField: "X-Test-Auth"
        )
        let (data, _) = try await NetworkSession.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return json["mappingRow"] as? Bool == true
    }

    /// A connected client for `token`: the server can address it as `userId`
    /// from the moment `connect()` returns.
    private func registeredClient(token: String, userId: String) async throws -> JsBaoClient {
        let client = createTestClient(appId: testApp.appId, token: token)
        clients.append(client)
        try await client.connect()
        XCTAssertTrue(client.isConnected)
        let registered = try await mappingRow(client, userId: userId)
        XCTAssertTrue(registered, "the user-channel mapping of \(client.connectionId) at connected")
        return client
    }

    func testAnOwnerHearsTheDb3CreatedEventAndTheRequesterHearsTheApproval() async throws {
        let created = try await ctx.appRequest(
            method: "POST", appId: testApp.appId, path: "/documents",
            body: ["title": "Swift access events", "documentFormat": 3], jwt: testApp.ownerJWT
        )
        let db3Id = try XCTUnwrap(created["documentId"] as? String)
        let requester = try await ctx.createTestUser(appId: testApp.appId)

        let owner = try await registeredClient(token: testApp.ownerJWT, userId: testApp.ownerUserId)
        let asker = try await registeredClient(token: requester.jwt, userId: requester.userId)
        let ownerHeard = LockedBox<[Db3AccessRequestCreatedEvent]>([])
        let askerHeard = LockedBox<[Db3AccessRequestResolvedEvent]>([])
        let ownerSub = owner.eventEmitter.subscribe(Db3AccessRequestCreatedEvent.self) { event in
            ownerHeard.withValue { $0.append(event) }
        }
        let askerSub = asker.eventEmitter.subscribe(Db3AccessRequestResolvedEvent.self) { event in
            askerHeard.withValue { $0.append(event) }
        }
        defer {
            ownerSub.cancel()
            askerSub.cancel()
        }

        let asked = try await asker.db3.permissions(db3Id).requestAccess(
            RequestAccessOptions(permission: .reader, sendEmail: false)
        )
        let requestId = asked.request.requestId
        try await eventually(timeout: 15, description: "the owner hears db3:access-request-created") {
            ownerHeard.value.contains { $0.requestId == requestId }
        }
        let createdEvent = try XCTUnwrap(ownerHeard.value.first { $0.requestId == requestId })
        XCTAssertEqual(createdEvent.documentId, db3Id)
        XCTAssertEqual(createdEvent.requesterId, requester.userId)
        XCTAssertEqual(createdEvent.status, "pending")
        XCTAssertEqual(createdEvent.requestedPermission, "reader")

        _ = try await owner.db3.permissions(db3Id).approveAccessRequest(requestId)
        try await eventually(timeout: 15, description: "the requester hears db3:access-request-resolved") {
            askerHeard.value.contains { $0.requestId == requestId }
        }
        let resolvedEvent = try XCTUnwrap(askerHeard.value.first { $0.requestId == requestId })
        XCTAssertEqual(resolvedEvent.status, "approved")
        XCTAssertEqual(resolvedEvent.grantedPermission, "reader")
        XCTAssertEqual(resolvedEvent.resolvedBy, testApp.ownerUserId)
        XCTAssertEqual(resolvedEvent.documentId, db3Id)
    }
}
