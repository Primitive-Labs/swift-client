import XCTest
@testable import JsBaoClient
import YSwift

/// Swift mirrors of the JS close/evict lifecycle pins in
/// `tests/client/js-bao-client-close-evict-lifecycle.test.ts` (issue #2668).
///
/// JS is the reference: closing a document flushes its queued outbound updates
/// and sends an `unsubscribe` frame, `evictLocal` is refused until the server
/// confirms the writes, eviction deletes the persisted CRDT bytes, and
/// `retainLocal: false` evicts at close.
///
/// On-disk assertions read the `yjs_docs` store directly rather than going
/// through `hasLocalCopy()`, which reports on in-memory bookkeeping and is
/// blind to rows an eviction left behind.
///
/// Server-free: an in-process loopback WebSocket server records the frames the
/// client sends, and the storage-facing tests drive a bare `DocumentManager`
/// over a temp-file `SQLiteStorageProvider`.
final class CloseEvictLifecycleTests: XCTestCase {
    var tempDir: String!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-close-evict-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Fixtures

    /// A `DocumentManager` plus the storage provider behind it, so a test can
    /// read the `yjs_docs` rows the manager writes.
    private struct Fixture {
        let manager: DocumentManager
        let storage: SQLiteStorageProvider
    }

    private func makeFixture(seed: [LocalMetadataEntry] = []) async throws -> Fixture {
        let dbPath = tempDir + "close-evict-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "close-evict")
        let offline = OfflineStore()
        await offline.setStorageProvider(storage)

        let manager = DocumentManager(logger: Logger(level: .warn, scope: "test"))
        manager.offlineStore = offline
        manager.appId = "test-app"
        manager.userId = "test-user"

        try await offline.ensureMetadataDb(appId: "test-app", userId: "test-user")
        if !seed.isEmpty {
            try await offline.putMetadataBatch(
                appId: "test-app", userId: "test-user", records: seed
            )
        }
        await manager.loadLocalMetadata()
        return Fixture(manager: manager, storage: storage)
    }

    private func meta(_ id: String, bytes: Int = 100) -> LocalMetadataEntry {
        LocalMetadataEntry(
            documentId: id,
            lastOpenedAt: ISO8601DateFormatter().string(from: Date()),
            localBytes: bytes
        )
    }

    /// Write CRDT bytes for a document the way `persistDocumentToLocal` does.
    private func seedYjsRow(_ storage: SQLiteStorageProvider, documentId: String) async throws {
        let persistence = YjsSQLitePersistence(storageProvider: storage, documentId: documentId)
        try await persistence.saveDocument(data: Data([1, 2, 3, 4]))
    }

    /// Read the persisted CRDT bytes for a document, or nil when the row is gone.
    private func yjsRow(_ storage: SQLiteStorageProvider, documentId: String) async throws -> Data? {
        let record: StorageRecord<Data>? = try await storage.get(
            store: YjsSQLitePersistence.store, key: documentId
        )
        return record?.value
    }

    // MARK: - Behavior 1 + 2: flush and unsubscribe on close

    func test_closeFlushesQueuedUpdatesThenSendsUnsubscribe() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsBase,
            appId: "close-evict-test-app",
            token: "test-token",
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            // A debounce far longer than the test: only a flush at close can
            // put the queued update on the wire.
            sync: SyncConfig(outboundDebounce: 30),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = "close-flush-\(UUID().uuidString.prefix(8))"
        // An ordinary committed document: the only kind whose updates reach the
        // outbound queue at all. A local-only document's edits are dropped
        // before they can be queued (#2691) and a pending-create document's are
        // held, so the create is confirmed here to leave a plain writable
        // document with something to flush.
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "flush-on-close", localOnly: false
        )
        client.documentManager.handlePendingCreateCommitted(documentId)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(
            client.pendingOutboundUpdateCountForTest(documentId), 1,
            "the update must still be queued when close starts, or the test proves nothing"
        )

        await client.closeDocument(documentId)

        let updateIndex = server.receivedFrames.firstIndex {
            $0.contains("\"update\"") && $0.contains(documentId)
        }
        let unsubscribeIndex = server.receivedFrames.firstIndex {
            $0.contains("\"unsubscribe\"") && $0.contains(documentId)
        }

        XCTAssertNotNil(
            updateIndex,
            "closeDocument dropped a queued outbound update instead of flushing it (#2668 C16)"
        )
        XCTAssertNotNil(
            unsubscribeIndex,
            "closeDocument sent no unsubscribe frame, so the server keeps streaming the closed document (#2668 C16)"
        )
        if let updateIndex, let unsubscribeIndex {
            XCTAssertGreaterThan(
                unsubscribeIndex, updateIndex,
                "the unsubscribe must follow the flushed update, not precede it"
            )
        }
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 0)
    }

    // MARK: - Behavior 3: evictLocal refused until the server confirms

    func test_closeWithEvictLocalKeepsDataWhenTheServerHasNotConfirmed() async throws {
        // `.sqlite(directory:)` takes the database file path itself.
        let storageDir = tempDir + "unconfirmed-\(UUID().uuidString.prefix(6)).sqlite"
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "close-evict-test-app",
            offline: true,
            logLevel: .none,
            storageConfig: .sqlite(directory: storageDir),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let documentId = "unconfirmed-\(UUID().uuidString.prefix(8))"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "unconfirmed", localOnly: true
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // Wait for the storage provider to exist, then write the CRDT bytes the
        // eviction must not delete.
        var provider: (any StorageProvider)?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            provider = await client.documentManager.offlineStore?.getStorageProvider()
            if provider != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let storage = try XCTUnwrap(provider, "storage provider never became available")
        let persistence = YjsSQLitePersistence(storageProvider: storage, documentId: documentId)
        try await persistence.saveDocument(data: Data([9, 9, 9]))

        // The socket is down, so the server cannot have confirmed anything.
        await client.closeDocument(documentId, options: CloseDocumentOptions(evictLocal: true))

        let record: StorageRecord<Data>? = try await storage.get(
            store: YjsSQLitePersistence.store, key: documentId
        )
        XCTAssertNotNil(
            record,
            "close(evictLocal:) evicted local data the server had never confirmed (#2668 C16)"
        )
        XCTAssertNotNil(
            client.documentManager.getMetadataIndex()[documentId],
            "close(evictLocal:) dropped the metadata for a document the server had never confirmed (#2668 C16)"
        )
    }

    func test_closeKeepsDataForRetainLocalFalseWhenTheServerHasNotConfirmed() async throws {
        // `retainLocal: false` evicts at close just like `evictLocal`, so it
        // needs the same guard: an unconfirmed document keeps its local data
        // rather than losing the edit on both sides (Codex review of #2668).
        let storagePath = tempDir + "retain-unconfirmed-\(UUID().uuidString.prefix(6)).sqlite"
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "close-evict-test-app",
            offline: true,
            logLevel: .none,
            storageConfig: .sqlite(directory: storagePath),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let documentId = "retain-unconfirmed-\(UUID().uuidString.prefix(8))"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "unconfirmed", localOnly: true
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(
                waitForLoad: .local,
                enableNetworkSync: false,
                retainLocal: false,
                deferNetworkSync: true
            )
        )

        var provider: (any StorageProvider)?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            provider = await client.documentManager.offlineStore?.getStorageProvider()
            if provider != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let storage = try XCTUnwrap(provider, "storage provider never became available")
        let persistence = YjsSQLitePersistence(storageProvider: storage, documentId: documentId)
        try await persistence.saveDocument(data: Data([7, 7, 7]))

        await client.closeDocument(documentId)

        let record: StorageRecord<Data>? = try await storage.get(
            store: YjsSQLitePersistence.store, key: documentId
        )
        XCTAssertNotNil(
            record,
            "retainLocal:false evicted local data the server had never confirmed (#2668)"
        )
    }

    func test_documentsCloseReportsEvictedFalseWhenTheServerHasNotConfirmed() async throws {
        // `documents.close` forwards to `client.closeDocument`, which owns the
        // guard since #2668; this pins the reported verdict through that path.
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "close-evict-test-app",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let documentId = "api-close-\(UUID().uuidString.prefix(8))"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "api-close", localOnly: true
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let result = await client.documents.close(
            documentId, options: CloseDocumentOptions(evictLocal: true)
        )
        XCTAssertFalse(
            result.evicted,
            "documents.close must report evicted:false when the server has not confirmed the writes"
        )
        XCTAssertNotNil(client.documentManager.getMetadataIndex()[documentId])
    }

    // MARK: - Behavior 4: eviction deletes the persisted CRDT bytes

    func test_evictLocalDataDeletesTheYjsDocsRow() async throws {
        let fixture = try await makeFixture(seed: [meta("evict-me")])
        try await seedYjsRow(fixture.storage, documentId: "evict-me")
        let before = try await yjsRow(fixture.storage, documentId: "evict-me")
        XCTAssertNotNil(before, "seed failed — nothing on disk to evict")

        await fixture.manager.evictLocalData(documentId: "evict-me")

        let after = try await yjsRow(fixture.storage, documentId: "evict-me")
        XCTAssertNil(
            after,
            "eviction left the CRDT snapshot on disk, so a re-open rehydrates evicted content (#2668 C23)"
        )
        XCTAssertNil(fixture.manager.getMetadataIndex()["evict-me"])
    }

    func test_reopenAfterEvictionStartsEmptyLocally() async throws {
        let fixture = try await makeFixture(seed: [meta("reopen-empty")])

        let doc = try await fixture.manager.openDocument(
            documentId: "reopen-empty",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let writeMap: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in
            writeMap.updateValue("persisted", forKey: "k", transaction: txn)
        }

        // closeDocument flushes the doc state to SQLite before teardown.
        await fixture.manager.closeDocument(documentId: "reopen-empty")
        let persistedRow = try await yjsRow(fixture.storage, documentId: "reopen-empty")
        XCTAssertNotNil(persistedRow)

        await fixture.manager.evictLocalData(documentId: "reopen-empty")

        let reopened = try await fixture.manager.openDocument(
            documentId: "reopen-empty",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let readMap: YMap<String> = reopened.getOrCreateMap(named: "m")
        let value = reopened.transactSync { txn -> String? in
            readMap.get(key: "k", transaction: txn)
        }
        XCTAssertNil(
            value,
            "an evicted document rehydrated its old content on re-open (#2668 C23)"
        )
    }

    func test_evictingAnOpenDocumentStopsItFromRepersisting() async throws {
        // Retention evicts open documents (#2668 C24). The reclaim only holds if
        // the open document stops persisting: js-bao destroys the document's
        // persistence provider on evict, so later edits and the eventual close
        // do not write the CRDT bytes back (Codex review of #2668).
        let fixture = try await makeFixture(seed: [meta("open-evicted")])

        let doc = try await fixture.manager.openDocument(
            documentId: "open-evicted",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in
            map.updateValue("before", forKey: "k", transaction: txn)
        }

        await fixture.manager.evictLocalData(documentId: "open-evicted")
        let afterEvict = try await yjsRow(fixture.storage, documentId: "open-evicted")
        XCTAssertNil(afterEvict, "the evict itself must clear the row")

        // Keep writing to the still-open document, then close it normally.
        doc.transactSync { txn in
            map.updateValue("after", forKey: "k", transaction: txn)
        }
        await fixture.manager.closeDocument(documentId: "open-evicted")

        let afterClose = try await yjsRow(fixture.storage, documentId: "open-evicted")
        XCTAssertNil(
            afterClose,
            "an evicted open document wrote its CRDT bytes back on close, so retention reclaimed nothing (#2668)"
        )
        XCTAssertNil(fixture.manager.getMetadataIndex()["open-evicted"])
    }

    func test_reopeningAnAlreadyOpenEvictedDocumentKeepsPersistenceSuspended() async throws {
        // A second `openDocument` on a document that is still open takes the
        // fast path and must not lift the eviction's persistence suspension —
        // otherwise the next edit or close writes the evicted CRDT bytes back
        // and the retention reclaim is undone (Codex review of #2668).
        let fixture = try await makeFixture(seed: [meta("open-evicted-reopened")])

        let doc = try await fixture.manager.openDocument(
            documentId: "open-evicted-reopened",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in
            map.updateValue("before", forKey: "k", transaction: txn)
        }

        await fixture.manager.evictLocalData(documentId: "open-evicted-reopened")
        let afterEvict = try await yjsRow(fixture.storage, documentId: "open-evicted-reopened")
        XCTAssertNil(afterEvict, "the evict itself must clear the row")

        // The document never closed, so this open hits the already-open fast path.
        _ = try await fixture.manager.openDocument(
            documentId: "open-evicted-reopened",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        doc.transactSync { txn in
            map.updateValue("after", forKey: "k", transaction: txn)
        }
        await fixture.manager.closeDocument(documentId: "open-evicted-reopened")

        let afterClose = try await yjsRow(fixture.storage, documentId: "open-evicted-reopened")
        XCTAssertNil(
            afterClose,
            "re-opening an already-open evicted document lifted its persistence suspension, so the evicted bytes were written back (#2668)"
        )
    }

    // MARK: - Behavior 5: retainLocal:false evicts at close

    func test_retainLocalFalseEvictsPersistenceAtClose() async throws {
        let fixture = try await makeFixture(seed: [meta("no-retain")])

        _ = try await fixture.manager.openDocument(
            documentId: "no-retain",
            options: OpenDocumentOptions(
                waitForLoad: .local, enableNetworkSync: false, retainLocal: false
            )
        )
        try await seedYjsRow(fixture.storage, documentId: "no-retain")

        // No evictLocal here: retainLocal:false alone must evict at close.
        await fixture.manager.closeDocument(documentId: "no-retain")

        let after = try await yjsRow(fixture.storage, documentId: "no-retain")
        XCTAssertNil(
            after,
            "retainLocal:false was ignored — the document persisted through close (#2668 C17)"
        )
        XCTAssertNil(fixture.manager.getMetadataIndex()["no-retain"])
    }

    func test_retainLocalTrueKeepsPersistenceAtClose() async throws {
        let fixture = try await makeFixture(seed: [meta("retained")])

        _ = try await fixture.manager.openDocument(
            documentId: "retained",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        try await seedYjsRow(fixture.storage, documentId: "retained")

        await fixture.manager.closeDocument(documentId: "retained")

        let retainedRow = try await yjsRow(fixture.storage, documentId: "retained")
        XCTAssertNotNil(
            retainedRow,
            "the default retainLocal:true must keep local data across a close"
        )
        XCTAssertNotNil(fixture.manager.getMetadataIndex()["retained"])
    }

    // MARK: - Behavior 6: hasLocalCopy needs a real local data signal

    func test_hasLocalCopyIsFalseForMetadataOnlyDocument() async throws {
        // A document that only ever appeared in a server listing: metadata row,
        // zero bytes, never opened.
        let fixture = try await makeFixture(seed: [meta("metadata-only", bytes: 0)])

        XCTAssertNotNil(fixture.manager.getMetadataIndex()["metadata-only"])
        XCTAssertFalse(
            fixture.manager.hasLocalCopy("metadata-only"),
            "hasLocalCopy reported a local copy for a document with no local data (#2668 C22)"
        )
    }

    func test_hasLocalCopyIsTrueForRealLocalDataSignals() async throws {
        let fixture = try await makeFixture(seed: [meta("with-bytes", bytes: 512)])

        // localBytes > 0 is a real signal.
        XCTAssertTrue(fixture.manager.hasLocalCopy("with-bytes"))

        // So is a pending local-only create.
        _ = try await fixture.manager.createLocalDocument(
            documentId: "local-only-doc", title: "local", localOnly: true
        )
        XCTAssertTrue(fixture.manager.hasLocalCopy("local-only-doc"))

        // And so is an open document that holds data.
        let doc = try await fixture.manager.openDocument(
            documentId: "opened-with-data",
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in
            map.updateValue("v", forKey: "k", transaction: txn)
        }
        XCTAssertTrue(fixture.manager.hasLocalCopy("opened-with-data"))
    }
}
