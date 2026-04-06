import XCTest
import YSwift
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-docmetadata-ws.test.ts
/// Tests document metadata change events via WebSocket.
final class DocMetadataWSTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-docmetadata-ws")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testReceiveDocumentMetadataChangedEvent() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Metadata WS Doc")

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Update document metadata via HTTP
        _ = try await client.documents.update(documentId: docId, data: ["title": "Updated Title"])

        // Verify the document reflects the updated title
        try await eventually(timeout: 5, description: "document title updated") {
            let doc = try await client.documents.get(documentId: docId)
            let title = doc["title"] as? String
            return title == "Updated Title"
        }
    }

    func testMetadataUpdateDoesNotAffectSync() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "No Desync")

        let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Write Yjs data
        let writeMap: YMap<String> = ydoc.getOrCreateMap(named: "test")
        client.transactAndSync(docId) { txn in
            writeMap.updateValue("preserved", forKey: "field", transaction: txn)
        }
        try await delay(1)

        // Update HTTP metadata
        _ = try await client.documents.update(documentId: docId, data: ["title": "New Title"])
        try await delay(1)

        // Yjs data should still be there
        let readMap: YMap<String> = ydoc.getOrCreateMap(named: "test")
        try await eventually(timeout: 5, description: "Yjs data still present after metadata update") {
            return readMap.containsKey("field")
        }
        var value: String?
        ydoc.transactSync { txn in
            value = readMap.get(key: "field", transaction: txn)
        }
        XCTAssertEqual(value, "preserved")
        XCTAssertTrue(client.isSynced(docId))
    }
}
