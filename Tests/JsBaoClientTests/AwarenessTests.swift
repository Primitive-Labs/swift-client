import XCTest
@testable import JsBaoClient
import YSwift

/// Tests awareness state sharing between clients.
/// Port of awareness tests from tests/client/js-bao-client.test.ts
final class AwarenessTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-awareness")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testSetAwarenessAndReceiveOnOtherClient() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Awareness Test")

        // Create second user with permission
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        // Client 1
        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client1.destroy() } }

        try await client1.connect()
        try await waitForConnection(client: client1)
        _ = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        // Client 2
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        defer { Task { await client2.destroy() } }

        try await client2.connect()
        try await waitForConnection(client: client2)
        _ = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        // Subscribe to awareness events on client 2
        var receivedAwareness = false
        var receivedStates: [[String: Any]] = []
        let sub = client2.events.onAny(.awareness) { payload in
            if let event = payload as? AwarenessEvent, event.documentId == docId {
                receivedAwareness = true
                receivedStates = event.states
            }
        }
        defer { sub.cancel() }

        // Client 1 sets awareness state
        client1.setAwareness(docId, state: [
            "user": ["name": "Client 1 User"],
            "cursor": ["x": 50, "y": 100],
        ])

        // Wait for awareness to propagate
        try await eventually(timeout: 5, description: "awareness received on client 2") {
            return receivedAwareness
        }

        XCTAssertTrue(receivedAwareness)
        // Note: states may or may not be populated depending on server awareness
        // broadcast format. The key test is that the event was received.
    }

    func testAwarenessDoesNotCrashWithNoListeners() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Awareness No Crash")
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Setting awareness with no listeners should not crash
        client.setAwareness(docId, state: ["cursor": ["x": 10, "y": 20]])
        try await delay(1)
    }
}
