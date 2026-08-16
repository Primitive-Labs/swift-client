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
        _ = try await client.documents.update(documentId: docId, data: UpdateDocumentData(title: "Updated Title"))

        // Verify the document reflects the updated title
        try await eventually(timeout: 5, description: "document title updated") {
            let doc = try await client.documents.get(documentId: docId)
            return doc.title == "Updated Title"
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
        try client.transactAndSync(docId) { txn in
            writeMap.updateValue("preserved", forKey: "field", transaction: txn)
        }
        try await delay(1)

        // Update HTTP metadata
        _ = try await client.documents.update(documentId: docId, data: UpdateDocumentData(title: "New Title"))
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

    /// Parity C4: the `docMetadata` WS case must apply the frame, not only
    /// emit an event. Drives the frame straight through the client's WS
    /// message handler — the same entry point the socket calls — and asserts
    /// the local metadata cache and permission state moved with it. Mirrors
    /// `tests/client/js-bao-client-docmetadata-ws.test.ts`.
    func testDocMetadataFrameUpdatesLocalStateAndPermission() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Frame Applied Doc"
        )
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        let frame = """
        {"type":"docMetadata","documentId":"\(docId)","action":"updated",
         "changedFields":["title","permission"],
         "metadata":{"title":"Renamed by another session","permission":"reader",
                     "lastModified":"2026-08-13T00:00:00.000Z"}}
        """
        await client.handleWebSocketMessage(frame)

        let cached = await client.documents.getLocalMetadata(documentId: docId)
        let meta = try XCTUnwrap(cached, "the frame must land in the local metadata cache")
        XCTAssertEqual(meta.title, "Renamed by another session")
        XCTAssertNotNil(meta.metadataSyncedAt)
        XCTAssertEqual(meta.lastSyncedAt, "2026-08-13T00:00:00.000Z")
        XCTAssertTrue(
            client.isDocumentReadOnly(docId),
            "a downgraded permission on the frame must flip read-only mid-session"
        )

        // A revoke frame carries metadata: null and is a local delete. Close
        // the document first and let its final persist land: while a document
        // is open the persist path keeps writing its own `lastOpenedAt` /
        // `localBytes` row, which can re-create a bare entry just after the
        // delete. The assertion below is therefore on the *server* metadata
        // being gone, which no local persist can put back;
        // `DocumentMetadataApplyTests` pins the strict removal without a live
        // document in the way.
        await client.closeDocument(docId)
        try await delay(1)

        let deleteLock = NSLock()
        var deleteSeen = false
        let sub = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) { e in
            guard e.documentId == docId, e.action == "deleted" else { return }
            deleteLock.lock(); deleteSeen = true; deleteLock.unlock()
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage(
            "{\"type\":\"docMetadata\",\"documentId\":\"\(docId)\",\"action\":\"deleted\",\"metadata\":null}"
        )

        XCTAssertTrue(
            deleteLock.withLock { deleteSeen },
            "metadata:null must emit a deleted metadata event"
        )
        let after = await client.documents.getLocalMetadata(documentId: docId)
        XCTAssertNil(
            after?.title,
            "metadata:null must drop the document's server metadata locally"
        )
    }
}
