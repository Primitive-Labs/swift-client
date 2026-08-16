import XCTest
@testable import JsBaoClient

/// Mirrors `tests/client/js-bao-client-authoritative-listing.test.ts` (parity
/// item C5). An authoritative server document listing replaces the local
/// index rather than merely upserting into it: local entries the server did
/// not list are evicted and a `deleted` event is emitted for each. Pending
/// creates and local-only documents are exempt — the server has never heard of
/// them, so their absence proves nothing.
///
/// Runs in-process against a `DocumentManager` backed by a temp SQLite store —
/// no live dev server.
final class AuthoritativeListingTests: XCTestCase {
    var tempDir: String!
    /// `DocumentManager.emitter` is `weak`; the test holds the strong ref.
    var emitter: EventEmitter!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-authlist-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        emitter = EventEmitter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
        emitter = nil
    }

    private func makeManager() async throws -> (DocumentManager, OfflineStore) {
        let dbPath = tempDir + "authlist-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "authlist")
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

    private func serverDoc(_ id: String, _ title: String) -> [String: Any] {
        ["documentId": id, "title": title, "permission": "read-write"]
    }

    // MARK: - Behavior 4: eviction

    func test_authoritativeListing_evictsAbsentDocsAndEmitsDeleted() async throws {
        let (mgr, offline) = try await makeManager()
        let keptId = "doc-keep"
        let revokedId = "doc-revoked"

        await mgr.handleServerDocuments([
            serverDoc(keptId, "Still mine"),
            serverDoc(revokedId, "Access revoked while offline"),
        ])
        XCTAssertNotNil(mgr.getLocalMetadata(keptId))
        XCTAssertNotNil(mgr.getLocalMetadata(revokedId))

        let sink = EventSink()
        let sub = emitter.subscribe(DocumentMetadataChangedEvent.self) { sink.record($0) }
        defer { sub.cancel() }

        // Reconnect: the authoritative listing no longer carries the revoked doc.
        await mgr.handleServerDocuments(
            [serverDoc(keptId, "Still mine")],
            authoritative: true
        )

        XCTAssertNotNil(mgr.getLocalMetadata(keptId))
        XCTAssertNil(mgr.getLocalMetadata(revokedId), "absent doc must be evicted")

        let persisted = try await offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: revokedId
        )
        XCTAssertNil(persisted, "eviction must reach local persistence")

        let deleted = try XCTUnwrap(
            sink.all.first(where: { $0.documentId == revokedId && $0.action == "deleted" }),
            "an evicted doc must emit a deleted event"
        )
        XCTAssertNil(deleted.metadata)
    }

    // MARK: - Behavior 5: exemptions

    func test_authoritativeListing_skipsPendingCreatesAndLocalOnlyDocs() async throws {
        let (mgr, _) = try await makeManager()

        _ = try await mgr.createLocalDocument(
            documentId: "doc-local-only", title: "Local only", localOnly: true
        )
        _ = try await mgr.createLocalDocument(
            documentId: "doc-pending", title: "Pending create", localOnly: false
        )

        await mgr.handleServerDocuments([], authoritative: true)

        XCTAssertNotNil(
            mgr.getLocalMetadata("doc-local-only"),
            "local-only docs are never in a server listing and must survive"
        )
        XCTAssertNotNil(
            mgr.getLocalMetadata("doc-pending"),
            "a pending create has not reached the server yet and must survive"
        )
    }

    // MARK: - Which syncMetadata responses may evict

    /// Mirrors js-bao's rule: a full listing is authoritative by default; a
    /// single-document sync and an ids-only payload never are.
    func test_listingIsAuthoritative_matchesTheJsRule() {
        XCTAssertTrue(JsBaoClient.listingIsAuthoritative(SyncMetadataOptions()))
        XCTAssertTrue(
            JsBaoClient.listingIsAuthoritative(SyncMetadataOptions(payloadType: "full"))
        )
        XCTAssertFalse(
            JsBaoClient.listingIsAuthoritative(SyncMetadataOptions(authoritative: false))
        )
        XCTAssertFalse(
            JsBaoClient.listingIsAuthoritative(SyncMetadataOptions(documentId: "doc-1")),
            "a single-document sync says nothing about the other documents"
        )
        XCTAssertFalse(
            JsBaoClient.listingIsAuthoritative(SyncMetadataOptions(payloadType: "ids")),
            "an ids-only payload is verified before anything is deleted"
        )
    }

    /// `authoritative: false` stays upsert-only.
    func test_nonAuthoritativeListing_doesNotEvict() async throws {
        let (mgr, _) = try await makeManager()
        await mgr.handleServerDocuments([serverDoc("doc-a", "Retained")])

        await mgr.handleServerDocuments([])

        XCTAssertNotNil(mgr.getLocalMetadata("doc-a"))
    }
}
