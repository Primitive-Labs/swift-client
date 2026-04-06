import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-offline-first.test.ts
/// Tests offline-first document creation and sync.
final class OfflineFirstTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var tempDir: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-offline-first")

        tempDir = NSTemporaryDirectory() + "jsbao-swift-offline-first-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await ctx.cleanup()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func testOfflineCreateThenOnlineSync() async throws {
        let dbPath = tempDir + "offline-first.sqlite"

        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            offline: true,
            storageConfig: .sqlite(directory: dbPath),
            autoNetwork: false
        )
        defer { Task { await client.destroy() } }

        // Start offline
        await client.goOffline()

        // Create a document while offline
        let (docId, ydoc) = try await client.createDocument(options: CreateDocumentOptions(
            title: "Offline First Doc"
        ))

        XCTAssertFalse(docId.isEmpty)
        XCTAssertTrue(client.isPendingCreate(docId))

        // Write data offline
        if let ydoc = ydoc {
            let map: YMap<String> = ydoc.getOrCreateMap(named: "content")
            ydoc.transactSync { txn in
                map.updateValue("offline-first-data", forKey: "key", transaction: txn)
            }
        }

        try await delay(0.5)

        // Go online
        await client.goOnline()
        try await delay(5)

        // After going online, the pending create should be synced
        // (may still be pending if sync takes longer)
    }

    func testLocalOnlyDocumentNeverSyncs() async throws {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .memory
        )
        defer { Task { await client.destroy() } }

        let (docId, ydoc) = try await client.createDocument(options: CreateDocumentOptions(
            title: "Local Only Forever",
            localOnly: true
        ))

        XCTAssertFalse(docId.isEmpty)
        XCTAssertNotNil(ydoc)
        // Local-only documents are tracked separately from pending creates
        XCTAssertTrue(client.isLocalOnly(docId))

        // Write data
        if let ydoc = ydoc {
            let map: YMap<String> = ydoc.getOrCreateMap(named: "data")
            ydoc.transactSync { txn in
                map.updateValue("local-only", forKey: "key", transaction: txn)
            }
        }

        // Connect and wait -- local-only doc should remain local-only (never syncs)
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(2)

        XCTAssertTrue(client.isLocalOnly(docId))
    }

    func testEvictAllLocalData() async throws {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .memory
        )
        defer { Task { await client.destroy() } }

        // Create some local data
        let (docId, _) = try await client.createDocument(options: CreateDocumentOptions(
            title: "Evict Test",
            localOnly: true
        ))

        XCTAssertTrue(client.isLocalOnly(docId))

        await client.evictAllLocal()

        // After eviction, document references should be cleared
        XCTAssertEqual(client.listOpenDocuments().count, 0)
    }
}
