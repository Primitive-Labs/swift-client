import XCTest
@testable import JsBaoClient
import YSwift

/// Core client tests ported from tests/client/js-bao-client.test.ts
final class JsBaoClientTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-core")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Initialization and Connection

    func testInitializeAndConnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)
        XCTAssertTrue(client.isConnected)
    }

    func testHandleConnectionErrorsGracefully() async throws {
        let client = createTestClient(appId: testApp.appId, token: "invalid-token")
        defer { Task { await client.destroy() } }

        // Should not crash with an invalid token
        try? await client.connect()
        // Connection may fail but client should handle it gracefully
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: - Document Operations

    func testOpenAndSyncDocument() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Test Doc")

        let doc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        XCTAssertNotNil(doc)
        XCTAssertTrue(client.isSynced(docId))
    }

    func testCloseDocumentsProperly() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)
        let _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        XCTAssertNotNil(client.getDoc(docId))
        XCTAssertTrue(client.isDocumentOpen(docId))

        await client.closeDocument(docId)

        XCTAssertNil(client.getDoc(docId))
        XCTAssertFalse(client.isDocumentOpen(docId))
    }

    // MARK: - Two-Client Synchronization

    func testSyncUpdatesBetweenTwoClients() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Sync Test")

        // Create second user with read-write permission
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(appId: testApp.appId, documentId: docId, userId: user2.userId, permission: "read-write", jwt: testApp.ownerJWT)

        // Client 1
        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client1.destroy() } }

        try await client1.connect()
        try await waitForConnection(client: client1)
        let doc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        // Client 2
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        defer { Task { await client2.destroy() } }

        try await client2.connect()
        try await waitForConnection(client: client2)
        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        // Client 1 writes data using plain doc.transactSync — the update observer
        // automatically captures and sends changes (no transactAndSync needed).
        // Note: getOrCreateMap must be called OUTSIDE transactSync because it
        // internally calls document.getMap() which creates a nested transaction.
        let map1: YMap<String> = doc1.getOrCreateMap(named: "document")
        doc1.transactSync { txn in
            map1.updateValue("Hello from client 1", forKey: "testKey", transaction: txn)
        }

        // Wait for propagation and verify client 2 sees the data
        let map2: YMap<String> = doc2.getOrCreateMap(named: "document")
        try await eventually(timeout: 5, description: "client 2 sees synced data") {
            return map2.containsKey("testKey")
        }
        let value = map2["testKey"]
        XCTAssertEqual(value, "Hello from client 1")
    }

    // MARK: - HTTP API Integration

    func testMakeAuthenticatedHttpRequests() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let result = try await client.makeRequest("GET", "/me", nil)
        guard let dict = result as? [String: Any] else {
            XCTFail("Expected dictionary response from /me")
            return
        }
        XCTAssertNotNil(dict["userId"])
    }

    func testHandleHttpErrors() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            let _ = try await client.makeRequest("GET", "/nonexistent-endpoint", nil)
            XCTFail("Should have thrown an error")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }

    // MARK: - Document Listing

    func testListDocuments() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Create a document
        let _ = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "List Test")

        let result = try await client.documents.list()
        XCTAssertNotNil(result)
    }

    // MARK: - Network Mode

    func testGoOnlineAndOffline() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        XCTAssertTrue(client.isOnline())

        await client.goOffline()
        XCTAssertFalse(client.isOnline())
        XCTAssertEqual(client.getNetworkMode(), .offline)

        await client.goOnline()
        XCTAssertTrue(client.isOnline())
    }

    // MARK: - Open Documents Tracking

    func testListOpenDocuments() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        XCTAssertEqual(client.listOpenDocuments().count, 0)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)
        let _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        XCTAssertEqual(client.listOpenDocuments().count, 1)
        XCTAssertTrue(client.listOpenDocuments().contains(docId))

        await client.closeDocument(docId)
        XCTAssertEqual(client.listOpenDocuments().count, 0)
    }
}
