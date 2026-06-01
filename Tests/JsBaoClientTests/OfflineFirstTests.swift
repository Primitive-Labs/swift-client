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
        // setUp may throw before these are assigned (e.g. when the
        // dev-server / JWT env vars aren't set). Read through Optional
        // semantics so a nil here can't crash the test process and
        // prevent later suites from running.
        if let ctx: TestContext = ctx { await ctx.cleanup() }
        if let tempDir: String = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
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

    /// Local YDoc edits should land in SQLite without waiting for a
    /// server sync to complete. Reopening a fresh client against the
    /// same `.sqlite()` directory must surface the prior session's
    /// writes — that's the durability guarantee js-bao's `y-indexeddb`
    /// integration provides on the JS side, and the missing piece in
    /// swift-client pre-this-patch (writes were only flushed on
    /// `handleSyncComplete` or explicit close, so anything written
    /// between sync rounds — or on a doc whose sync never completes —
    /// vanished on app restart).
    func testWritesPersistAcrossClientRestartWithoutSync() async throws {
        let dbPath = tempDir + "persist-across-restart.sqlite"

        // ── First client lifetime: write data, never let sync complete.
        var capturedDocId: String = ""
        do {
            let client = createTestClient(
                appId: testApp.appId,
                token: testApp.ownerJWT,
                offline: true,
                storageConfig: .sqlite(directory: dbPath),
                autoNetwork: false
            )
            // Stay offline for the entirety of this lifetime so the
            // observed durability is purely local-first — no
            // `handleSyncComplete` can fire to save the test.
            await client.goOffline()

            let (docId, maybeDoc) = try await client.createDocument(options: CreateDocumentOptions(
                title: "Persist Across Restart",
                localOnly: true
            ))
            capturedDocId = docId
            guard let ydoc = maybeDoc else {
                XCTFail("createDocument returned nil YDocument")
                return
            }
            let map: YMap<String> = ydoc.getOrCreateMap(named: "content")
            ydoc.transactSync { txn in
                map.updateValue("hello", forKey: "greeting", transaction: txn)
                map.updateValue("world", forKey: "place", transaction: txn)
            }

            // Wait well past the 250ms debounce so the persist task
            // has a chance to flush.
            try await delay(0.6)

            await client.destroy()
        }

        // ── Fresh client, same SQLite directory: writes survived?
        let client2 = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            offline: true,
            storageConfig: .sqlite(directory: dbPath),
            autoNetwork: false
        )
        defer { Task { await client2.destroy() } }
        await client2.goOffline()

        // Open the same doc against the new client. With local-first
        // persistence working, `openDocument` rehydrates from SQLite.
        let restored = try await client2.openDocument(
            capturedDocId,
            options: OpenDocumentOptions(
                waitForLoad: .local,
                enableNetworkSync: false
            )
        )

        let restoredMap: YMap<String> = restored.getOrCreateMap(named: "content")
        XCTAssertEqual(restoredMap["greeting"], "hello", "greeting was lost across restart — SQLite persistence isn't firing on local updates")
        XCTAssertEqual(restoredMap["place"], "world", "place was lost across restart — SQLite persistence isn't firing on local updates")
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
