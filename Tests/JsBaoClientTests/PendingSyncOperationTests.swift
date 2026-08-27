import XCTest
@testable import JsBaoClient
import YSwift

/// Server-free tests for the in-flight syncStep1 claim added for #2587
/// (`beginPendingSyncOperation` / `completePendingSyncOperation`), and for the
/// one case where holding the claim would do harm: a `pendingCreate` document.
///
/// A just-created doc doesn't exist server-side until its background commit
/// lands, so the syncStep1 sent at open time gets no `syncComplete` back. The
/// 350ms availability-retry loop (#852) exists to re-send until the commit
/// lands — if the claim survived the commit, every tick would be refused until
/// the 10s staleness window expired and a `.network` open of a fresh doc would
/// stall for the full 10s again. js-bao releases the claim on the same
/// post-commit path (`applyPostCommitPolicy`), which is what this covers.
final class PendingSyncOperationTests: XCTestCase {

    private func makeManager() -> DocumentManager {
        let mgr = DocumentManager(logger: Logger(level: .none, scope: "pso-test"))
        mgr.appId = "pending-sync-test-app"
        mgr.userId = "test-user"
        return mgr
    }

    private func newDocId() -> String { "doc-\(UUID().uuidString.prefix(8))" }

    func testClaimIsExclusiveUntilReleased() {
        let mgr = makeManager()
        let docId = newDocId()

        XCTAssertTrue(mgr.beginPendingSyncOperation(docId), "first claim wins")
        XCTAssertFalse(mgr.beginPendingSyncOperation(docId), "second claim is refused")

        mgr.completePendingSyncOperation(docId)
        XCTAssertTrue(mgr.beginPendingSyncOperation(docId), "claim is reusable after release")
    }

    func testSyncCompleteReleasesTheClaim() {
        let mgr = makeManager()
        let docId = newDocId()
        XCTAssertTrue(mgr.beginPendingSyncOperation(docId))
        mgr.handleSyncComplete(documentId: docId)
        XCTAssertTrue(mgr.beginPendingSyncOperation(docId), "syncComplete must release the claim")
    }

    func testStaleClaimAgesOut() {
        let mgr = makeManager()
        let docId = newDocId()
        XCTAssertTrue(mgr.beginPendingSyncOperation(docId))
        // A lost syncComplete must not wedge the document forever.
        XCTAssertTrue(
            mgr.beginPendingSyncOperation(docId, staleAfter: 0),
            "a claim older than staleAfter is replaced, not refused"
        )
    }

    func testTransportCloseReleasesEveryClaim() {
        let mgr = makeManager()
        let a = newDocId(), b = newDocId()
        XCTAssertTrue(mgr.beginPendingSyncOperation(a))
        XCTAssertTrue(mgr.beginPendingSyncOperation(b))
        mgr.clearPendingSyncOperations()
        XCTAssertTrue(mgr.beginPendingSyncOperation(a))
        XCTAssertTrue(mgr.beginPendingSyncOperation(b))
    }

    /// The regression the review caught: committing a pending create has to
    /// free the claim, or the availability-retry loop is refused for the whole
    /// staleness window.
    func testPendingCreateCommitReleasesTheClaimAndSignals() async throws {
        let mgr = makeManager()
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in ["documentId": docId] }

        let committed = Committed()
        mgr.onPendingCreateCommitted = { committed.record($0) }

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        XCTAssertTrue(mgr.isPendingCreate(docId), "precondition: doc is a pending create")

        // The open-time syncStep1 claims the slot; no syncComplete comes back
        // because the server has no such document yet.
        XCTAssertTrue(mgr.beginPendingSyncOperation(docId))
        XCTAssertFalse(mgr.beginPendingSyncOperation(docId), "precondition: claim held")

        _ = try await mgr.commitOfflineCreate(documentId: docId)

        XCTAssertTrue(
            mgr.beginPendingSyncOperation(docId),
            "the commit must release the claim so the 350ms retry can re-send"
        )
        XCTAssertEqual(committed.all, [docId], "commit must signal the re-sync hook")
    }

    /// The other half of the same policy: a document the caller opened with
    /// `deferNetworkSync` / `enableNetworkSync: false` owns its own sync
    /// timing, so the commit must NOT re-trigger sync for it. Otherwise a
    /// background commit pulls server state into a ydoc at a moment the caller
    /// did not choose — the ordering hazard of #2475, and worst on the
    /// `onExists: "link"` branch, where the doc links to an existing server
    /// document with real state.
    func testDeferredSyncDocumentIsNotResyncedOnCommit() async throws {
        let mgr = makeManager()
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in ["documentId": docId] }

        let committed = Committed()
        mgr.onPendingCreateCommitted = { committed.record($0) }

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        _ = try await mgr.openDocument(
            documentId: docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertEqual(mgr.startNetworkMode(docId), .manual)

        _ = try await mgr.commitOfflineCreate(documentId: docId)

        XCTAssertEqual(
            committed.all, [],
            "committing a deferred-sync document must not fire the re-sync hook"
        )
    }

    /// An explicit `startNetworkSync` hands sync back to the client, so a
    /// document that started deferred behaves like any other from then on.
    func testExplicitStartNetworkSyncPromotesADeferredDocument() async throws {
        let mgr = makeManager()
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in ["documentId": docId] }

        let committed = Committed()
        mgr.onPendingCreateCommitted = { committed.record($0) }

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        _ = try await mgr.openDocument(
            documentId: docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        mgr.setStartNetworkMode(docId, .immediate)

        _ = try await mgr.commitOfflineCreate(documentId: docId)

        XCTAssertEqual(committed.all, [docId])
    }

    /// A normal open records `immediate`; an unrecorded document keeps the
    /// pre-existing behavior; and the latest open's intent wins, which is what
    /// makes the deferred case above work at all — a locally-created document
    /// is already open by the time the caller opens it.
    func testOpenRecordsTheModeAndDefaultsToImmediate() async throws {
        let mgr = makeManager()
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in ["documentId": docId] }

        XCTAssertEqual(mgr.startNetworkMode(newDocId()), .immediate,
                       "an unrecorded document keeps the pre-existing behavior")

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        _ = try await mgr.openDocument(
            documentId: docId,
            options: OpenDocumentOptions(enableNetworkSync: true, deferNetworkSync: false)
        )
        XCTAssertEqual(mgr.startNetworkMode(docId), .immediate)

        _ = try await mgr.openDocument(
            documentId: docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertEqual(mgr.startNetworkMode(docId), .manual,
                       "re-opening with deferred sync hands the timing to the caller")
    }

    /// A mode entry lives exactly as long as its document is in `openDocs`:
    /// written under the `pendingOpens` claim in `openDocument`, removed in
    /// `closeDocument`. `evictAllLocalData()` clears `openDocs` wholesale, so
    /// it has to clear the mode map too — otherwise a stale `.manual` from a
    /// deferred open survives the wipe, and because `createLocalDocument` never
    /// writes the map, re-creating the same document id locally would have
    /// `applyPostCommitPolicy` read the dead entry and skip the post-commit
    /// re-sync, leaving the document to wait out the pending-sync timeout.
    func testEvictAllLocalDataClearsRecordedStartModes() async throws {
        let mgr = makeManager()
        let docId = newDocId()

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: true)
        _ = try await mgr.openDocument(
            documentId: docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertEqual(mgr.startNetworkMode(docId), .manual)

        await mgr.evictAllLocalData()
        XCTAssertFalse(mgr.listOpenDocuments().contains(docId),
                       "the wipe closes every open document")
        XCTAssertEqual(mgr.startNetworkMode(docId), .immediate,
                       "the wipe must not leave a mode entry for a document it just closed")

        // The path the stale entry would have broken: a fresh local create of
        // the same id, whose post-commit policy consults the map.
        _ = try await mgr.createLocalDocument(documentId: docId, title: "t2", localOnly: false)
        XCTAssertEqual(mgr.startNetworkMode(docId), .immediate,
                       "a re-created document syncs on its own schedule, not a dead open's")
    }

    /// The mode has to be readable from the moment the document is readable.
    /// `_openDocumentImpl` puts the document into `openDocs` as its first
    /// action and then awaits the storage provider, `loadDocument()`,
    /// `getMetadata` and `putMetadata`; recording the mode after that whole
    /// stretch left the document in `listOpenDocuments()` with no entry, and
    /// `startNetworkMode(_:)` defaults an absent entry to `.immediate`. A
    /// `connect()` overlapping the open of a `deferNetworkSync` document would
    /// then sweep it and put an unrequested syncStep1 on the wire against a
    /// half-restored ydoc (#2475).
    ///
    /// The gated provider parks the open inside `loadDocument()`, so the
    /// mid-open observation below is deterministic rather than a race the test
    /// has to win.
    func testStartModeIsRecordedBeforeTheDocumentBecomesVisible() async throws {
        let mgr = makeManager()
        let gate = GatedStorageProvider()
        try await gate.initialize(namespace: "start-mode-window")
        let store = OfflineStore()
        await store.setStorageProvider(gate)
        mgr.offlineStore = store

        let docId = newDocId()
        let openTask = Task { [mgr] in
            ConfinedYDocument(try await mgr.openDocument(
                documentId: docId,
                options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
            ))
        }

        let deadline = Date().addingTimeInterval(5)
        while !gate.didEnterGet && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gate.didEnterGet, "the open should have reached the storage read")
        XCTAssertTrue(
            mgr.listOpenDocuments().contains(docId),
            "the document is already visible while the open is still in flight"
        )
        XCTAssertEqual(
            mgr.startNetworkMode(docId), .manual,
            "a deferred open must be tagged .manual from the moment the document " +
            "is visible — an overlapping connect sweep reads this map"
        )

        gate.release()
        _ = try await openTask.value
        XCTAssertEqual(mgr.startNetworkMode(docId), .manual)
    }

    private final class Committed: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    /// A `StorageProvider` that parks the first `get` until it is released,
    /// so a test can observe the state of an open that is mid-flight.
    /// Everything else delegates to an in-memory provider.
    private final class GatedStorageProvider: StorageProvider, @unchecked Sendable {
        private let inner = MemoryStorageProvider()
        private let lock = NSLock()
        private var entered = false
        private var released = false

        var didEnterGet: Bool { lock.withLock { entered } }
        func release() { lock.withLock { released = true } }

        func initialize(namespace: String) async throws { try await inner.initialize(namespace: namespace) }
        func close() async { await inner.close() }
        func isReady() -> Bool { inner.isReady() }

        func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
            lock.withLock { entered = true }
            while !lock.withLock({ released }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return try await inner.get(store: store, key: key)
        }

        func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
            try await inner.put(store: store, key: key, value: value, metadata: metadata)
        }
        func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
            try await inner.putBatch(store: store, records: records)
        }
        func delete(store: String, key: String) async throws { try await inner.delete(store: store, key: key) }
        func clear(store: String) async throws { try await inner.clear(store: store) }
        func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
            try await inner.iterate(store: store, callback: callback)
        }
        func keys(store: String) async throws -> [String] { try await inner.keys(store: store) }
        func has(store: String, key: String) async throws -> Bool { try await inner.has(store: store, key: key) }
    }
}
