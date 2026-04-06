import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-large-update.test.ts
/// Tests large updates (>100KB) that trigger R2 storage and sync.
final class LargeUpdateTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-large-update")
    }

    override func tearDown() async throws {
        for client in clients {
            await client.destroy()
        }
        clients.removeAll()
        await ctx.cleanup()
    }

    func testHandleLargeUpdateAndSyncToOtherClient() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Large Update Test")

        // Second user
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        // Two clients
        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(contentsOf: [client1, client2])

        try await client1.connect()
        try await client2.connect()
        try await waitForConnection(client: client1)
        try await waitForConnection(client: client2)

        let doc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))

        try await waitForSync(client: client1, documentId: docId)
        try await waitForSync(client: client2, documentId: docId)

        // Write a large payload (>100KB) to trigger R2 storage
        let largeString = String(repeating: "A", count: 150_000)
        let map1: YMap<String> = doc1.getOrCreateMap(named: "document")
        client1.transactAndSync(docId) { txn in
            map1.updateValue(largeString, forKey: "largeField", transaction: txn)
        }

        // Wait for large update to propagate
        try await delay(5)

        // Verify client 2 received the large update
        let map2: YMap<String> = doc2.getOrCreateMap(named: "document")
        try await eventually(timeout: 10, description: "client2 receives large update") {
            guard map2.containsKey("largeField") else { return false }
            let value: String? = map2["largeField"]
            return value != nil && value!.count >= 100_000
        }
    }

    // MARK: - Multiple large updates in sequence

    func testMultipleLargeUpdatesInSequence() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Sequential Large Updates")

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
        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))

        try await waitForSync(client: client1, documentId: docId)
        try await waitForSync(client: client2, documentId: docId)

        // Write 3 sequential large updates (each >100KB)
        let map1: YMap<String> = doc1.getOrCreateMap(named: "seqData")
        for i in 0..<3 {
            let largeValue = String(repeating: String(Character(UnicodeScalar(65 + i)!)), count: 120_000) // "AAA...", "BBB...", "CCC..."
            client1.transactAndSync(docId) { txn in
                map1.updateValue(largeValue, forKey: "large_\(i)", transaction: txn)
            }
            // Allow each update to propagate before the next
            try await delay(3)
        }

        // Verify client2 received all 3 large updates
        let map2: YMap<String> = doc2.getOrCreateMap(named: "seqData")
        try await eventually(timeout: 15, description: "client2 receives all sequential large updates") {
            for i in 0..<3 {
                guard map2.containsKey("large_\(i)") else { return false }
                let val: String? = map2["large_\(i)"]
                guard let v = val, v.count >= 100_000 else { return false }
            }
            return true
        }

        // Verify content integrity
        for i in 0..<3 {
            let expected = String(repeating: String(Character(UnicodeScalar(65 + i)!)), count: 120_000)
            let actual: String? = map2["large_\(i)"]
            XCTAssertEqual(actual, expected, "Large update \(i) content mismatch")
        }
    }

    // MARK: - Large update with concurrent small updates

    func testLargeUpdateWithConcurrentSmallUpdates() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Large + Small Updates")

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
        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))

        try await waitForSync(client: client1, documentId: docId)
        try await waitForSync(client: client2, documentId: docId)

        // Client 1 writes a large update
        let largeMap: YMap<String> = doc1.getOrCreateMap(named: "largeContent")
        let bigData = String(repeating: "X", count: 150_000)
        client1.transactAndSync(docId) { txn in
            largeMap.updateValue(bigData, forKey: "bigData", transaction: txn)
        }

        // Client 2 writes small updates concurrently
        let smallMap: YMap<String> = doc2.getOrCreateMap(named: "smallUpdates")
        for i in 0..<10 {
            client2.transactAndSync(docId) { txn in
                smallMap.updateValue("value_\(i)", forKey: "small_\(i)", transaction: txn)
            }
            try await delay(0.2)
        }

        // Wait for everything to propagate
        try await delay(8)

        // Verify client2 received the large update
        let largeMap2: YMap<String> = doc2.getOrCreateMap(named: "largeContent")
        try await eventually(timeout: 10, description: "client2 receives large update") {
            guard largeMap2.containsKey("bigData") else { return false }
            let val: String? = largeMap2["bigData"]
            return val != nil && val!.count == 150_000
        }

        // Verify client1 received all small updates
        let smallMap1: YMap<String> = doc1.getOrCreateMap(named: "smallUpdates")
        try await eventually(timeout: 10, description: "client1 receives small updates") {
            for i in 0..<10 {
                guard smallMap1.containsKey("small_\(i)") else { return false }
            }
            return true
        }

        for i in 0..<10 {
            XCTAssertEqual(smallMap1["small_\(i)"], "value_\(i)")
        }
    }

    // MARK: - Large updates sync correctly between clients

    func testLargeUpdatesSyncCorrectlyBetweenClients() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Large Sync Correctness")

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
        let doc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))

        try await waitForSync(client: client1, documentId: docId)
        try await waitForSync(client: client2, documentId: docId)

        // Client 1 writes a large, structured payload
        let map1: YMap<String> = doc1.getOrCreateMap(named: "document")
        let largeContent = String(repeating: "Z", count: 130_000)
        client1.transactAndSync(docId) { txn in
            map1.updateValue(largeContent, forKey: "content", transaction: txn)
        }
        try await delay(5)

        // Client 2 should see exact same content
        let map2: YMap<String> = doc2.getOrCreateMap(named: "document")
        try await eventually(timeout: 15, description: "client2 receives and matches large content") {
            guard map2.containsKey("content") else { return false }
            let val: String? = map2["content"]
            return val == largeContent
        }

        // Now client 2 writes back another large update
        let largeContent2 = String(repeating: "W", count: 125_000)
        client2.transactAndSync(docId) { txn in
            map2.updateValue(largeContent2, forKey: "content2", transaction: txn)
        }
        try await delay(5)

        // Client 1 should see it
        try await eventually(timeout: 15, description: "client1 receives client2's large update") {
            guard map1.containsKey("content2") else { return false }
            let val: String? = map1["content2"]
            return val == largeContent2
        }
    }
}
