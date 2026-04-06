import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-concurrent-writes.test.ts
/// Tests concurrent multi-client writes for data consistency.
final class ConcurrentWritesTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-concurrent-writes")
    }

    override func tearDown() async throws {
        for client in clients {
            await client.destroy()
        }
        clients.removeAll()
        await ctx.cleanup()
    }

    func testConcurrentWritesFromMultipleClients() async throws {
        let numClients = 3
        let writesPerClient = 5

        // Create document
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Concurrent Writes Test")

        // Create users and grant permissions
        var users: [TestUser] = []
        for i in 0..<numClients {
            if i == 0 {
                // Owner is first user
                users.append(TestUser(userId: testApp.ownerUserId, email: "", name: "Owner", role: "owner", jwt: testApp.ownerJWT))
            } else {
                let user = try await ctx.createTestUser(appId: testApp.appId, role: "member")
                try await ctx.grantPermission(
                    appId: testApp.appId,
                    documentId: docId,
                    userId: user.userId,
                    permission: "read-write",
                    jwt: testApp.ownerJWT
                )
                users.append(user)
            }
        }

        // Initialize all clients
        for i in 0..<numClients {
            let client = createTestClient(appId: testApp.appId, token: users[i].jwt)
            clients.append(client)
        }

        // Connect all clients
        for client in clients {
            try await client.connect()
        }
        for client in clients {
            try await waitForConnection(client: client)
        }

        // Open documents on all clients
        var ydocs: [YDocument] = []
        for client in clients {
            let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
            ydocs.append(ydoc)
        }

        // Wait for all to sync
        for client in clients {
            try await waitForSync(client: client, documentId: docId)
        }

        // Each client writes to its own key in a shared map
        for i in 0..<numClients {
            let client = clients[i]
            let ydoc = ydocs[i]
            let map: YMap<String> = ydoc.getOrCreateMap(named: "concurrent")
            for j in 0..<writesPerClient {
                client.transactAndSync(docId) { txn in
                    map.updateValue("client\(i)-write\(j)", forKey: "client\(i)-\(j)", transaction: txn)
                }
            }
        }

        // Wait for updates to propagate
        try await delay(3)

        // Verify all writes are visible on the last client
        let lastDoc = ydocs[numClients - 1]
        let lastMap: YMap<String> = lastDoc.getOrCreateMap(named: "concurrent")
        let expectedKeys: [String] = (0..<numClients).flatMap { i in
            (0..<writesPerClient).map { j in "client\(i)-\(j)" }
        }

        try await eventually(timeout: 10, description: "all concurrent writes visible on last client") {
            return expectedKeys.allSatisfy { lastMap.containsKey($0) }
        }

        // Verify values are correct
        var missingKeys: [String] = []
        lastDoc.transactSync { txn in
            for i in 0..<numClients {
                for j in 0..<writesPerClient {
                    let key = "client\(i)-\(j)"
                    if lastMap.get(key: key, transaction: txn) != "client\(i)-write\(j)" {
                        missingKeys.append(key)
                    }
                }
            }
        }

        XCTAssertTrue(missingKeys.isEmpty, "Missing or incorrect keys after concurrent writes: \(missingKeys)")
    }

    /// Ported from JS: "should handle conflicting concurrent updates to the same keys"
    func testConflictingConcurrentUpdatesToSameKeys() async throws {
        let numClients = 3

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Conflicting Updates")

        var users: [TestUser] = []
        users.append(TestUser(userId: testApp.ownerUserId, email: "", name: "Owner", role: "owner", jwt: testApp.ownerJWT))
        for _ in 1..<numClients {
            let user = try await ctx.createTestUser(appId: testApp.appId, role: "member")
            try await ctx.grantPermission(
                appId: testApp.appId,
                documentId: docId,
                userId: user.userId,
                permission: "read-write",
                jwt: testApp.ownerJWT
            )
            users.append(user)
        }

        // Initialize and connect all clients
        for i in 0..<numClients {
            let client = createTestClient(appId: testApp.appId, token: users[i].jwt)
            clients.append(client)
        }

        for client in clients {
            try await client.connect()
        }
        for client in clients {
            try await waitForConnection(client: client)
        }

        // Open documents on all clients
        var ydocs: [YDocument] = []
        for client in clients {
            let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
            ydocs.append(ydoc)
        }
        for client in clients {
            try await waitForSync(client: client, documentId: docId)
        }

        // All clients write to the same key concurrently
        for i in 0..<numClients {
            let ydoc = ydocs[i]
            let map: YMap<String> = ydoc.getOrCreateMap(named: "conflictTest")
            for j in 0..<5 {
                clients[i].transactAndSync(docId) { txn in
                    map.updateValue("Client \(i) iteration \(j)", forKey: "sharedKey", transaction: txn)
                }
                try await delay(0.1)
            }
        }

        // Wait for CRDT convergence
        try await delay(3)

        // All clients should converge to the same value (last-writer-wins)
        let maps: [YMap<String>] = ydocs.map { $0.getOrCreateMap(named: "conflictTest") }

        try await eventually(timeout: 5, description: "all clients converge on sharedKey") {
            guard maps.allSatisfy({ $0.containsKey("sharedKey") }) else { return false }
            let values: [String?] = maps.map { $0["sharedKey"] }
            return values.allSatisfy { $0 != nil } && Set(values).count == 1
        }

        // Verify all clients have the same value
        let val0: String? = maps[0]["sharedKey"]
        for i in 1..<numClients {
            let valI: String? = maps[i]["sharedKey"]
            XCTAssertEqual(valI, val0, "Client \(i) should converge to same value as client 0")
        }
    }
}
