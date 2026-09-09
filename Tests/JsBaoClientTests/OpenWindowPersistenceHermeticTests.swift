import XCTest
@testable import JsBaoClient
import YSwift

/// Persistence is held for the length of an open (issue #3200).
///
/// The update observer is installed before the document is published, so a
/// write made during the open — from a `DocumentOpenedEvent` handler, or by a
/// caller the already-open fast path handed the document to — is observed, and
/// schedules a debounced persist. At that moment the document holds nothing but
/// that write: the stored snapshot has not been loaded and the stored metadata
/// row has not been read. A persist running there saves the early edit *over*
/// the snapshot the open is about to restore, and writes a metadata row rebuilt
/// from an index that has never seen the stored one — which is how an open can
/// replace a document's offline records with a single edit, and erase the
/// `localOnly` flag that keeps its content off the wire.
///
/// Server-free: `DocumentManager` is constructed directly over a SQLite
/// provider seeded by hand, and the open is parked mid-window by a test seam.
final class OpenWindowPersistenceHermeticTests: XCTestCase {

    private let appId = "open-window-persistence"
    private let userId = "open-window-user"
    private let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)

    /// Longer than the 250ms persist debounce, so an early write's persist has
    /// really had its chance while the open is parked.
    private static let outlastDebounceNanos: UInt64 = 700_000_000

    private func makeProvider(_ label: String) async throws -> SQLiteStorageProvider {
        let path = NSTemporaryDirectory()
            + "open-window-\(label)-\(UUID().uuidString.prefix(6)).sqlite"
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "\(appId):\(userId)")
        return provider
    }

    private func makeManager(store: OfflineStore) -> DocumentManager {
        let manager = DocumentManager(logger: Logger(level: .none, scope: "test"))
        manager.offlineStore = store
        manager.appId = appId
        manager.userId = userId
        return manager
    }

    /// A snapshot of a document that already holds a record, as an earlier
    /// session would have left on disk.
    private func seedSnapshot(
        provider: SQLiteStorageProvider,
        documentId: String
    ) async throws {
        let earlier = YDocument()
        let notes: YMap<String> = earlier.getOrCreateMap(named: "notes")
        earlier.transactSync { txn in
            notes.updateValue("from an earlier session", forKey: "seeded", transaction: txn)
        }
        let state: Data = earlier.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        let persistence = YjsSQLitePersistence(
            storageProvider: provider, documentId: documentId
        )
        try await persistence.saveDocument(data: state)
    }

    /// Writes to the document mid-open and then parks the open past the persist
    /// debounce, so the persist that write scheduled runs while the open is
    /// still inside its window.
    private func writeDuringOpen(
        _ manager: DocumentManager,
        _ documentId: String
    ) -> @Sendable (String) async -> Void {
        { [weak manager] id in
            guard id == documentId, let doc = manager?.getDocument(documentId) else { return }
            let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
            doc.transactSync { txn in
                notes.updateValue("written during the open", forKey: "early", transaction: txn)
            }
            try? await Task.sleep(nanoseconds: Self.outlastDebounceNanos)
        }
    }

    // MARK: - The stored snapshot survives a write made during the open

    func testAWriteDuringTheOpenDoesNotOverwriteTheSnapshotTheOpenRestores() async throws {
        let documentId = "open-window-snapshot-doc"
        let provider = try await makeProvider("snapshot")
        defer { Task { await provider.close() } }
        try await seedSnapshot(provider: provider, documentId: documentId)

        let store = OfflineStore()
        await store.setStorageProvider(provider)
        let manager = makeManager(store: store)
        manager.onOpenPublishedForTest = writeDuringOpen(manager, documentId)

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        let (seeded, early): (String?, String?) = doc.transactSync { txn in
            (notes.get(key: "seeded", transaction: txn), notes.get(key: "early", transaction: txn))
        }

        XCTAssertEqual(
            seeded, "from an earlier session",
            "the open must restore what storage held: a persist of the early write cannot run before the load"
        )
        XCTAssertEqual(
            early, "written during the open",
            "and the write made during the open is not lost either — both are in the document"
        )

        await manager.closeDocument(documentId: documentId)
    }

    // MARK: - And so does the stored metadata row

    func testAWriteDuringTheOpenDoesNotReplaceTheStoredMetadataRow() async throws {
        // The row is the only thing that says this document is local-only. A
        // persist mid-open rewrites it from an index that has not read it, so
        // the flag would be gone by the time the open looks — and the document
        // would classify as ordinary and put its content on the wire (#2691).
        let documentId = "open-window-metadata-doc"
        let provider = try await makeProvider("metadata")
        defer { Task { await provider.close() } }
        try await seedSnapshot(provider: provider, documentId: documentId)

        let store = OfflineStore()
        await store.setStorageProvider(provider)
        try await store.putMetadata(
            appId: appId,
            userId: userId,
            record: LocalMetadataEntry(
                documentId: documentId,
                title: "private notes",
                tags: ["personal"],
                pendingCreate: false,
                localOnly: true
            )
        )

        let manager = makeManager(store: store)
        manager.onOpenPublishedForTest = writeDuringOpen(manager, documentId)

        _ = try await manager.openDocument(documentId: documentId, options: localOpen)

        XCTAssertTrue(
            manager.isLocalOnly(documentId),
            "the open reads the row it seeded — a persist must not have replaced it in the meantime"
        )
        XCTAssertFalse(
            manager.isLocalOnlyClassificationPending(documentId),
            "and the classification is settled by that read, not left unknown"
        )

        // A fresh store over the same provider: nothing in-memory answers this.
        let fresh = OfflineStore()
        await fresh.setStorageProvider(provider)
        let storedRow = try await fresh.getMetadata(
            appId: appId, userId: userId, documentId: documentId
        )
        let row = try XCTUnwrap(storedRow, "the row must still be there")
        XCTAssertEqual(row.localOnly, true, "local-only survives the open")
        XCTAssertEqual(row.title, "private notes", "and so does the rest of the row")
        XCTAssertEqual(row.tags, ["personal"])

        await manager.closeDocument(documentId: documentId)
    }

    // MARK: - The held persist is replayed, not dropped

    func testThePersistHeldDuringTheOpenIsReplayedAfterIt() async throws {
        // Holding is only half of it: the write that asked for the persist is
        // owed one. It must not have to wait for the next edit, sync or close.
        let documentId = "open-window-replay-doc"
        let provider = try await makeProvider("replay")
        defer { Task { await provider.close() } }
        try await seedSnapshot(provider: provider, documentId: documentId)

        let store = OfflineStore()
        await store.setStorageProvider(provider)
        let manager = makeManager(store: store)
        manager.onOpenPublishedForTest = writeDuringOpen(manager, documentId)

        _ = try await manager.openDocument(documentId: documentId, options: localOpen)
        // The replay goes back through the debounce.
        try? await Task.sleep(nanoseconds: Self.outlastDebounceNanos)

        let probe = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        let loaded = try await probe.loadDocument()
        let saved = try XCTUnwrap(loaded, "a snapshot must be on disk")

        let replica = YDocument()
        replica.transactSync { txn in
            try? txn.transactionApplyUpdate(update: Array(saved))
        }
        let notes: YMap<String> = replica.getOrCreateMap(named: "notes")
        let (seeded, early): (String?, String?) = replica.transactSync { txn in
            (notes.get(key: "seeded", transaction: txn), notes.get(key: "early", transaction: txn))
        }
        XCTAssertEqual(
            seeded, "from an earlier session",
            "the replayed snapshot carries the restored state"
        )
        XCTAssertEqual(
            early, "written during the open",
            "and the write the held persist was owed — with no further write, sync or close"
        )

        await manager.closeDocument(documentId: documentId)
    }
}
