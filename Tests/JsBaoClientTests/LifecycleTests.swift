import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-lifecycle-edge-cases.test.ts
/// Tests lifecycle edge cases: destroy, double-open, close-while-syncing, etc.
final class LifecycleTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-lifecycle")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testDestroyDisconnectsAndCleansUp() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        await client.destroy()

        // After destroy, client should not be connected
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.listOpenDocuments().count, 0)
    }

    func testDoubleDestroyDoesNotCrash() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        await client.destroy()
        await client.destroy() // Should not crash
    }

    func testDestroyWithoutConnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        await client.destroy() // Should not crash
    }

    func testCloseDocumentThatIsNotOpen() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Closing a non-existent document should not crash
        await client.closeDocument("nonexistent-doc-id")
    }

    func testCloseAllDocumentsOnDisconnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let doc1Id = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Doc 1")
        let doc2Id = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Doc 2")

        _ = try await client.openDocument(doc1Id, options: OpenDocumentOptions(waitForLoad: .network))
        _ = try await client.openDocument(doc2Id, options: OpenDocumentOptions(waitForLoad: .network))

        try await waitForSync(client: client, documentId: doc1Id)
        try await waitForSync(client: client, documentId: doc2Id)

        XCTAssertEqual(client.listOpenDocuments().count, 2)

        // Close all
        await client.closeDocument(doc1Id)
        await client.closeDocument(doc2Id)

        XCTAssertEqual(client.listOpenDocuments().count, 0)
    }

    func testConnectAfterDestroy() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        await client.destroy()

        // Connecting after destroy should be a no-op, not crash
        try? await client.connect()
    }

    func testGetDocReturnsNilForUnopenedDocument() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        XCTAssertNil(client.getDoc("nonexistent"))
        XCTAssertFalse(client.isSynced("nonexistent"))
        XCTAssertFalse(client.isDocumentOpen("nonexistent"))
    }
}
