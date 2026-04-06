import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-document-freshness.test.ts
/// Tests that documents are fresh after open/sync.
final class FreshnessTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-freshness")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testDocumentIsFreshAfterNetworkSync() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Freshness Test")

        // Write some data via a second client
        let client2 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client2.destroy() } }

        try await client2.connect()
        try await waitForConnection(client: client2)

        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        let mapWrite: YMap<String> = doc2.getOrCreateMap(named: "data")
        client2.transactAndSync(docId) { txn in
            mapWrite.updateValue("fresh-data", forKey: "field", transaction: txn)
        }
        try await delay(2)

        // Now open on client 1 -- should see the fresh data
        let doc1 = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        let mapRead: YMap<String> = doc1.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "synced data visible on client1") {
            return mapRead.containsKey("field")
        }
        let value = mapRead["field"]

        XCTAssertEqual(value, "fresh-data")
    }

    /// Ported from JS: "should not persist data between test runs on the same document"
    /// Writes data via one client, destroys it, reconnects with another, verifies data persists.
    func testDataPersistsBetweenClientSessions() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Persist Between Sessions")

        // Client 1: add data
        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        try await client1.connect()
        try await waitForConnection(client: client1)

        let ydoc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        let map1: YMap<String> = ydoc1.getOrCreateMap(named: "data")
        client1.transactAndSync(docId) { txn in
            map1.updateValue("value1", forKey: "test1", transaction: txn)
            map1.updateValue("value2", forKey: "test2", transaction: txn)
        }
        try await delay(2)

        await client1.closeDocument(docId)
        await client1.destroy()

        // Client 2: verify data persists on server
        let client2 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client2.destroy() } }

        try await client2.connect()
        try await waitForConnection(client: client2)

        let ydoc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        let map2: YMap<String> = ydoc2.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "data visible on client2") {
            return map2.containsKey("test1") && map2.containsKey("test2")
        }

        XCTAssertEqual(map2["test1"], "value1")
        XCTAssertEqual(map2["test2"], "value2")
    }

    func testMultipleDocumentsIndependent() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId1 = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Doc 1")
        let docId2 = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Doc 2")

        let ydoc1 = try await client.openDocument(docId1, options: OpenDocumentOptions(waitForLoad: .network))
        let ydoc2 = try await client.openDocument(docId2, options: OpenDocumentOptions(waitForLoad: .network))

        try await waitForSync(client: client, documentId: docId1)
        try await waitForSync(client: client, documentId: docId2)

        // Write different data to each
        let mapDoc1: YMap<String> = ydoc1.getOrCreateMap(named: "data")
        client.transactAndSync(docId1) { txn in
            mapDoc1.updateValue("doc1-value", forKey: "field", transaction: txn)
        }

        let mapDoc2: YMap<String> = ydoc2.getOrCreateMap(named: "data")
        client.transactAndSync(docId2) { txn in
            mapDoc2.updateValue("doc2-value", forKey: "field", transaction: txn)
        }

        try await delay(1)

        // Verify they are independent (same client wrote both, data is local)
        var val1: String?
        var val2: String?
        let mapDoc1Read: YMap<String> = ydoc1.getOrCreateMap(named: "data")
        ydoc1.transactSync { txn in
            val1 = mapDoc1Read.get(key: "field", transaction: txn)
        }
        let mapDoc2Read: YMap<String> = ydoc2.getOrCreateMap(named: "data")
        ydoc2.transactSync { txn in
            val2 = mapDoc2Read.get(key: "field", transaction: txn)
        }

        XCTAssertEqual(val1, "doc1-value")
        XCTAssertEqual(val2, "doc2-value")
    }
}
