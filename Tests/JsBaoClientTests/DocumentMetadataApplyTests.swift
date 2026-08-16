import XCTest
@testable import JsBaoClient

/// Mirrors `tests/client/js-bao-client-docmetadata-ws.test.ts` (parity item
/// C4). A `docMetadata` frame is not just an event: JS's
/// `applyDocumentMetadataUpdate` merges it into the metadata cache, persists
/// it, stamps `metadataSyncedAt` / `lastSyncedAt`, treats `metadata: null` as
/// a local delete, and derives a permission change so read-only state flips
/// mid-session.
///
/// Runs in-process against a `DocumentManager` backed by a temp SQLite store —
/// no live dev server, same shape as `RetentionPolicyTests`.
final class DocumentMetadataApplyTests: XCTestCase {
    var tempDir: String!
    /// `DocumentManager.emitter` is `weak`; the test holds the strong ref.
    var emitter: EventEmitter!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-metaapply-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        emitter = EventEmitter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
        emitter = nil
    }

    private func makeManager() async throws -> (DocumentManager, OfflineStore) {
        let dbPath = tempDir + "meta-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "metaapply")
        let offline = OfflineStore()
        await offline.setStorageProvider(storage)

        let mgr = DocumentManager(logger: Logger(level: .warn, scope: "test"))
        mgr.offlineStore = offline
        mgr.appId = "test-app"
        mgr.userId = "test-user"
        mgr.emitter = emitter
        try await offline.ensureMetadataDb(appId: "test-app", userId: "test-user")
        return (mgr, offline)
    }

    /// Collects every `DocumentMetadataChangedEvent` for the lifetime of the
    /// returned subscription.
    private final class EventSink {
        private let lock = NSLock()
        private var events: [DocumentMetadataChangedEvent] = []
        func record(_ e: DocumentMetadataChangedEvent) {
            lock.lock(); events.append(e); lock.unlock()
        }
        var all: [DocumentMetadataChangedEvent] {
            lock.lock(); defer { lock.unlock() }; return events
        }
    }

    // MARK: - Behavior 1: merge + persist + stamp

    func test_applyDocumentMetadataUpdate_mergesPersistsAndStampsTimestamps() async throws {
        let (mgr, offline) = try await makeManager()
        let docId = "doc-merge-1"
        let lastModified = "2026-08-13T00:00:00.000Z"

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: [
                "title": .string("Renamed by another session"),
                "lastModified": .string(lastModified),
            ],
            changedFields: ["title"],
            action: "updated",
            source: "server"
        )

        let cached = try XCTUnwrap(mgr.getLocalMetadata(docId), "frame must populate the metadata cache")
        XCTAssertEqual(cached.title, "Renamed by another session")
        XCTAssertNotNil(cached.metadataSyncedAt)
        XCTAssertEqual(cached.lastSyncedAt, lastModified)

        let persisted = try await offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: docId
        )
        let row = try XCTUnwrap(persisted, "frame must be persisted, not just cached")
        XCTAssertEqual(row.title, "Renamed by another session")
        XCTAssertEqual(row.lastSyncedAt, lastModified)
    }

    /// A server `created` for a document already in the cache is emitted as
    /// `updated`, so the creating client does not see two `created` events.
    func test_applyDocumentMetadataUpdate_createdOnExistingEntryEmitsUpdated() async throws {
        let (mgr, _) = try await makeManager()
        let docId = "doc-created-twice"
        mgr.setMetadata(docId, entry: LocalMetadataEntry(documentId: docId, title: "Existing"))

        let sink = EventSink()
        let sub = emitter.subscribe(DocumentMetadataChangedEvent.self) { sink.record($0) }
        defer { sub.cancel() }

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["title": .string("Existing")],
            changedFields: nil,
            action: "created",
            source: "server"
        )

        let event = try XCTUnwrap(sink.all.first(where: { $0.documentId == docId }))
        XCTAssertEqual(event.action, "updated")
    }

    // MARK: - Behavior 2: metadata:null is a local delete

    func test_applyDocumentMetadataUpdate_nullMetadataDeletesLocallyAndEmitsDeleted() async throws {
        let (mgr, offline) = try await makeManager()
        let docId = "doc-revoked-1"

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["title": .string("About to be revoked")],
            changedFields: nil,
            action: "updated",
            source: "server"
        )
        XCTAssertNotNil(mgr.getLocalMetadata(docId))

        let sink = EventSink()
        let sub = emitter.subscribe(DocumentMetadataChangedEvent.self) { sink.record($0) }
        defer { sub.cancel() }

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: nil,
            changedFields: nil,
            action: "deleted",
            source: "server"
        )

        XCTAssertNil(mgr.getLocalMetadata(docId), "revoked doc must leave the cache")
        let persisted = try await offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: docId
        )
        XCTAssertNil(persisted, "revoked doc must leave local persistence")

        let deleted = try XCTUnwrap(
            sink.all.first(where: { $0.documentId == docId && $0.action == "deleted" }),
            "a deleted event must be emitted"
        )
        XCTAssertNil(deleted.metadata)
    }

    /// A key the server sends as null clears the cached value — js-bao's merge
    /// is a spread, so an explicit null overwrites. Without this a thumbnail
    /// another client removed survives every later sync.
    func test_applyDocumentMetadataUpdate_explicitNullClearsTheCachedValue() async throws {
        let (mgr, _) = try await makeManager()
        let docId = "doc-thumb"

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["title": .string("Has a thumbnail"), "thumbnailBlobId": .string("blob-1")],
            action: "updated",
            source: "server"
        )
        XCTAssertEqual(mgr.getLocalMetadata(docId)?.thumbnailBlobId, "blob-1")

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["thumbnailBlobId": .null],
            changedFields: ["thumbnailBlobId"],
            action: "updated",
            source: "server"
        )

        let after = try XCTUnwrap(mgr.getLocalMetadata(docId))
        XCTAssertNil(after.thumbnailBlobId, "an explicit null must clear the cached thumbnail")
        XCTAssertEqual(after.title, "Has a thumbnail", "an absent key leaves its value alone")
    }

    /// Eviction has to take the CRDT snapshot with it. Otherwise a revoked
    /// document leaves every listing while its content stays on disk, ready to
    /// be rehydrated the next time that id is opened.
    func test_evictLocalData_deletesThePersistedYjsSnapshot() async throws {
        let (mgr, offline) = try await makeManager()
        let docId = "doc-with-snapshot"
        let storageProvider = await offline.getStorageProvider()
        let provider = try XCTUnwrap(storageProvider)

        let persistence = YjsSQLitePersistence(storageProvider: provider, documentId: docId)
        try await persistence.saveDocument(data: Data([1, 2, 3]))
        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["title": .string("Revoked soon")],
            action: "updated",
            source: "server"
        )

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: nil,
            action: "deleted",
            source: "server"
        )

        let remaining = try await persistence.loadDocument()
        XCTAssertNil(remaining, "the CRDT snapshot must be deleted along with the metadata")
    }

    // MARK: - Behavior 3: derived permission flips read-only

    func test_applyDocumentMetadataUpdate_permissionFlipsReadOnlyMidSession() async throws {
        let (mgr, _) = try await makeManager()
        let docId = "doc-perm-1"

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["permission": .string("read-write")],
            changedFields: ["permission"],
            action: "updated",
            source: "server"
        )
        XCTAssertEqual(mgr.getPermission(docId), .readWrite)
        XCTAssertFalse(mgr.isReadOnly(docId))

        await mgr.applyDocumentMetadataUpdate(
            documentId: docId,
            metadata: ["permission": .string("reader")],
            changedFields: ["permission"],
            action: "updated",
            source: "server"
        )

        XCTAssertEqual(mgr.getPermission(docId), .reader)
        XCTAssertTrue(mgr.isReadOnly(docId), "a downgrade must flip read-only mid-session")

        let cached = try XCTUnwrap(mgr.getLocalMetadata(docId))
        XCTAssertEqual(cached.lastKnownPermission, "reader")
        XCTAssertNotNil(cached.permissionCachedAt)
    }
}
