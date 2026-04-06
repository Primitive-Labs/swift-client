import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-merge-e2e.test.ts
/// Tests document merge scenarios between multiple clients.
final class MergeTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-merge")
    }

    override func tearDown() async throws {
        for client in clients {
            await client.destroy()
        }
        clients.removeAll()
        await ctx.cleanup()
    }

    func testMergeEditsFromTwoClients() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Merge Test")

        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(contentsOf: [client1, client2])

        try await client1.connect()
        try await waitForConnection(client: client1)

        try await client2.connect()
        try await waitForConnection(client: client2)

        let doc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        // Both clients write to different keys
        let map1a: YMap<String> = doc1.getOrCreateMap(named: "data")
        client1.transactAndSync(docId) { txn in
            map1a.updateValue("from-client1", forKey: "key1", transaction: txn)
        }

        let map2a: YMap<String> = doc2.getOrCreateMap(named: "data")
        client2.transactAndSync(docId) { txn in
            map2a.updateValue("from-client2", forKey: "key2", transaction: txn)
        }

        // Wait for merge to propagate
        try await delay(3)

        // Both clients should see both keys
        let map1b: YMap<String> = doc1.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "both keys visible on client1") {
            return map1b.containsKey("key1") && map1b.containsKey("key2")
        }
        XCTAssertEqual(map1b["key1"], "from-client1")
        XCTAssertEqual(map1b["key2"], "from-client2")

        let map2b: YMap<String> = doc2.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "both keys visible on client2") {
            return map2b.containsKey("key1") && map2b.containsKey("key2")
        }
        XCTAssertEqual(map2b["key1"], "from-client1")
        XCTAssertEqual(map2b["key2"], "from-client2")
    }

    func testConcurrentEditsToSameKey() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Same Key Merge")

        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(contentsOf: [client1, client2])

        try await client1.connect()
        try await waitForConnection(client: client1)

        try await client2.connect()
        try await waitForConnection(client: client2)

        let doc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        // Both clients write to the same key concurrently
        let map1c: YMap<String> = doc1.getOrCreateMap(named: "data")
        client1.transactAndSync(docId) { txn in
            map1c.updateValue("value-from-1", forKey: "sharedKey", transaction: txn)
        }

        let map2c: YMap<String> = doc2.getOrCreateMap(named: "data")
        client2.transactAndSync(docId) { txn in
            map2c.updateValue("value-from-2", forKey: "sharedKey", transaction: txn)
        }

        // Wait for CRDT merge
        try await delay(3)

        // After merge, both clients should converge to the same value (last-writer-wins for YMap)
        let map1d: YMap<String> = doc1.getOrCreateMap(named: "data")
        let map2d: YMap<String> = doc2.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "clients converge on shared key") {
            guard map1d.containsKey("sharedKey") && map2d.containsKey("sharedKey") else {
                return false
            }
            let val1: String? = map1d["sharedKey"]
            let val2: String? = map2d["sharedKey"]
            return val1 != nil && val2 != nil && val1 == val2
        }
    }

    // MARK: - 3-client merge scenario

    func testThreeClientMerge() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "3-Client Merge")

        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        let user3 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user3.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        let client3 = createTestClient(appId: testApp.appId, token: user3.jwt)
        clients.append(contentsOf: [client1, client2, client3])

        // Connect sequentially
        try await client1.connect()
        try await waitForConnection(client: client1)

        try await client2.connect()
        try await waitForConnection(client: client2)

        try await client3.connect()
        try await waitForConnection(client: client3)

        let doc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        let doc3 = try await client3.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client3, documentId: docId)

        // Each client writes to its own key
        let map1: YMap<String> = doc1.getOrCreateMap(named: "data")
        client1.transactAndSync(docId) { txn in
            map1.updateValue("from-client1", forKey: "key1", transaction: txn)
        }

        let map2: YMap<String> = doc2.getOrCreateMap(named: "data")
        client2.transactAndSync(docId) { txn in
            map2.updateValue("from-client2", forKey: "key2", transaction: txn)
        }

        let map3: YMap<String> = doc3.getOrCreateMap(named: "data")
        client3.transactAndSync(docId) { txn in
            map3.updateValue("from-client3", forKey: "key3", transaction: txn)
        }

        // Wait for merge to propagate
        try await delay(3)

        // All 3 clients should see all 3 keys
        let verify1: YMap<String> = doc1.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "all keys visible on client1") {
            return verify1.containsKey("key1") && verify1.containsKey("key2") && verify1.containsKey("key3")
        }
        XCTAssertEqual(verify1["key1"], "from-client1")
        XCTAssertEqual(verify1["key2"], "from-client2")
        XCTAssertEqual(verify1["key3"], "from-client3")

        let verify2: YMap<String> = doc2.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "all keys visible on client2") {
            return verify2.containsKey("key1") && verify2.containsKey("key2") && verify2.containsKey("key3")
        }
        XCTAssertEqual(verify2["key1"], "from-client1")
        XCTAssertEqual(verify2["key2"], "from-client2")
        XCTAssertEqual(verify2["key3"], "from-client3")

        let verify3: YMap<String> = doc3.getOrCreateMap(named: "data")
        try await eventually(timeout: 5, description: "all keys visible on client3") {
            return verify3.containsKey("key1") && verify3.containsKey("key2") && verify3.containsKey("key3")
        }
        XCTAssertEqual(verify3["key1"], "from-client1")
        XCTAssertEqual(verify3["key2"], "from-client2")
        XCTAssertEqual(verify3["key3"], "from-client3")
    }

    // MARK: - Rapid alternating edits from two clients

    func testRapidAlternatingEditsFromTwoClients() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Rapid Alternating Merge")

        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(contentsOf: [client1, client2])

        try await client1.connect()
        try await waitForConnection(client: client1)

        try await client2.connect()
        try await waitForConnection(client: client2)

        let doc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        let map1: YMap<String> = doc1.getOrCreateMap(named: "rapid")
        let map2: YMap<String> = doc2.getOrCreateMap(named: "rapid")

        let totalEdits = 10

        // Alternate edits rapidly: client1 writes even keys, client2 writes odd keys
        for i in 0..<totalEdits {
            if i % 2 == 0 {
                client1.transactAndSync(docId) { txn in
                    map1.updateValue("c1_val_\(i)", forKey: "edit_\(i)", transaction: txn)
                }
            } else {
                client2.transactAndSync(docId) { txn in
                    map2.updateValue("c2_val_\(i)", forKey: "edit_\(i)", transaction: txn)
                }
            }
            try await delay(0.1) // Brief pause between alternating edits
        }

        // Wait for all edits to propagate
        try await delay(5)

        // Both clients should see all edits
        let readMap1: YMap<String> = doc1.getOrCreateMap(named: "rapid")
        let readMap2: YMap<String> = doc2.getOrCreateMap(named: "rapid")

        try await eventually(timeout: 10, description: "all rapid edits visible on both clients") {
            for i in 0..<totalEdits {
                guard readMap1.containsKey("edit_\(i)") && readMap2.containsKey("edit_\(i)") else {
                    return false
                }
            }
            return true
        }

        // Verify values match
        for i in 0..<totalEdits {
            let expectedValue = i % 2 == 0 ? "c1_val_\(i)" : "c2_val_\(i)"
            XCTAssertEqual(readMap1["edit_\(i)"], expectedValue, "Client1 mismatch on edit_\(i)")
            XCTAssertEqual(readMap2["edit_\(i)"], expectedValue, "Client2 mismatch on edit_\(i)")
        }
    }
}
