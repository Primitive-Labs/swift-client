import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-interleaved-operations.test.ts
/// Tests interleaved open/close/write operations.
final class InterleavedTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-interleaved")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testOpenCloseOpenSameDocument() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Interleaved Test")

        // Open
        let doc1 = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Write
        let map1: YMap<String> = doc1.getOrCreateMap(named: "data")
        client.transactAndSync(docId) { txn in
            map1.updateValue("initial", forKey: "key", transaction: txn)
        }
        try await delay(1)

        // Close
        await client.closeDocument(docId)
        XCTAssertFalse(client.isDocumentOpen(docId))

        // Re-open
        let doc2 = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Data should persist from server
        let map2: YMap<String> = doc2.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "data visible after re-open") {
            return map2.containsKey("key")
        }
        let reOpenedValue = doc2.transactSync { txn -> String? in
            return map2.get(key: "key", transaction: txn)
        }
        XCTAssertEqual(reOpenedValue, "initial")
    }

    func testOpenMultipleDocumentsSequentially() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docIds = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<3 {
                group.addTask {
                    try await self.ctx.createDocument(appId: self.testApp.appId, jwt: self.testApp.ownerJWT, title: "Sequential \(i)")
                }
            }
            var ids: [String] = []
            for try await id in group { ids.append(id) }
            return ids
        }

        // Open all sequentially
        for docId in docIds {
            _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
            try await waitForSync(client: client, documentId: docId)
        }

        XCTAssertEqual(client.listOpenDocuments().count, docIds.count)

        // Close all
        for docId in docIds {
            await client.closeDocument(docId)
        }

        XCTAssertEqual(client.listOpenDocuments().count, 0)
    }

    func testWriteAfterCloseDoesNotCrash() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        await client.closeDocument(docId)

        // Writing to a closed document's YDoc should not crash
        // (the YDoc still exists in memory, just not tracked by the client)
        let closedMap: YMap<String> = ydoc.getOrCreateMap(named: "data")
        ydoc.transactSync { txn in
            closedMap.updateValue("after-close", forKey: "key", transaction: txn)
        }
    }
}
