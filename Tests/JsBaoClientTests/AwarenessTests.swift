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

        // Subscribe to awareness events on client 2. JS-parity shape (#996):
        // the payload is a delta of client IDs (added/updated/removed), not
        // a snapshot of states.
        var receivedAwareness = false
        var addedIds: [String] = []
        let sub = client2.events.on(.awareness) { (event: AwarenessEvent) in
            if event.documentId == docId {
                receivedAwareness = true
                addedIds.append(contentsOf: event.added)
                addedIds.append(contentsOf: event.updated)
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
        // The delta carries client1's wire key (its connectionId), and the
        // actual state is readable via getAwarenessStates — same pattern
        // as JS.
        XCTAssertFalse(addedIds.isEmpty, "Expected added/updated client IDs in the awareness delta")
        let states = client2.getAwarenessStates(documentId: docId)
        let remoteState = addedIds.compactMap { states[$0] }.first
        XCTAssertNotNil(remoteState, "Expected client 1's awareness state to be retrievable on client 2")
        if let user = remoteState?["user"] as? [String: Any] {
            XCTAssertEqual(user["name"] as? String, "Client 1 User")
        }
    }

    func testLocalSetAwarenessEmitsAddedThenUpdatedDelta() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Awareness Local Delta")
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        var deltas: [AwarenessEvent] = []
        let sub = client.events.on(.awareness) { (event: AwarenessEvent) in
            if event.documentId == docId {
                deltas.append(event)
            }
        }
        defer { sub.cancel() }

        // First set → `added` containing the local wire key (connectionId).
        client.setAwareness(docId, state: ["cursor": ["x": 1, "y": 2]])
        try await eventually(timeout: 2, description: "first local awareness delta") {
            !deltas.isEmpty
        }
        XCTAssertEqual(deltas[0].added, [client.connectionId])
        XCTAssertTrue(deltas[0].updated.isEmpty)
        XCTAssertTrue(deltas[0].removed.isEmpty)

        // Second set → `updated`.
        client.setAwareness(docId, state: ["cursor": ["x": 3, "y": 4]])
        try await eventually(timeout: 2, description: "second local awareness delta") {
            deltas.count >= 2
        }
        XCTAssertTrue(deltas[1].added.isEmpty)
        XCTAssertEqual(deltas[1].updated, [client.connectionId])

        // Removal → `removed` echoes the requested IDs (JS parity).
        client.removeAwareness(documentId: docId, clientIds: [client.connectionId])
        try await eventually(timeout: 2, description: "removal awareness delta") {
            deltas.count >= 3
        }
        XCTAssertEqual(deltas[2].removed, [client.connectionId])
        XCTAssertNil(client.getAwarenessStates(documentId: docId)[client.connectionId])
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
