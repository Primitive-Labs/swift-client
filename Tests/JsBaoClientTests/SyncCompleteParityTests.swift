import XCTest
@testable import JsBaoClient
import YSwift

/// Server-free mirror of `tests/client/js-bao-client-events.test.ts` for the
/// three `syncComplete` / open-lifecycle parity gaps in #2666 (audit items
/// C13 and C20). JS is the reference in every case:
///
///   * `syncComplete` carrying `synced:false` records the document as UNSYNCED
///     (`JsBaoClient.ts:7440` resolves `data.synced === false ? false : true`
///     and hands that to `_updateSynced`). Swift used to hard-code `true`.
///   * `documentLoaded(source:"server")` fires once per OPEN cycle, guarded by
///     `docLoadedEmitted` (`documentManager.ts:475,660,1340`). Swift used to
///     emit it on every `syncComplete`, so a document held open across several
///     reconnects announced itself as freshly loaded each time.
///   * `openDocument` emits `documentOpened` (`documentManager.ts:696`).
///     `DocumentOpenedEvent` existed in Swift with no emitter at all.
final class SyncCompleteParityTests: XCTestCase {

    private func makeManager(_ emitter: EventEmitter) -> DocumentManager {
        let mgr = DocumentManager(logger: Logger(level: .none, scope: "sync-parity-test"))
        mgr.appId = "sync-parity-test-app"
        mgr.userId = "test-user"
        mgr.emitter = emitter
        return mgr
    }

    private func newDocId() -> String { "doc-\(UUID().uuidString.prefix(8))" }

    /// A client that never touches the network — enough to exercise the
    /// post-sync reconciliation, which lives on `JsBaoClient` rather than on
    /// `DocumentManager`.
    private func makeOfflineClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "sync-parity-test-app",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    /// Collected `documentLoaded` / `sync` / `documentOpened` payloads for one
    /// manager, kept alive alongside the emitter for the test's duration.
    private struct Capture {
        let emitter: EventEmitter
        let loaded: ThreadSafeBox<[DocumentLoadedEvent]>
        let sync: ThreadSafeBox<[SyncEvent]>
        let opened: ThreadSafeBox<[DocumentOpenedEvent]>
        let subscriptions: [EventSubscription]

        func cancel() { subscriptions.forEach { $0.cancel() } }
        func serverLoaded(_ documentId: String) -> [DocumentLoadedEvent] {
            loaded.value.filter { $0.documentId == documentId && $0.source == "server" }
        }
    }

    private func capture(_ emitter: EventEmitter) -> Capture {
        let loaded = ThreadSafeBox<[DocumentLoadedEvent]>([])
        let sync = ThreadSafeBox<[SyncEvent]>([])
        let opened = ThreadSafeBox<[DocumentOpenedEvent]>([])
        let subs = [
            emitter.subscribe(DocumentLoadedEvent.self) { e in loaded.mutate { $0.append(e) } },
            emitter.subscribe(SyncEvent.self) { e in sync.mutate { $0.append(e) } },
            emitter.subscribe(DocumentOpenedEvent.self) { e in opened.mutate { $0.append(e) } },
        ]
        return Capture(
            emitter: emitter,
            loaded: loaded,
            sync: sync,
            opened: opened,
            subscriptions: subs
        )
    }

    // MARK: - Behavior 1 — synced:false records the document as unsynced

    func testSyncCompleteWithSyncedFalseRecordsDocumentUnsynced() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        mgr.handleSyncComplete(documentId: docId, synced: false)

        XCTAssertFalse(
            mgr.isSynced(docId),
            "a syncComplete the server reports as unsuccessful must not record the doc as synced"
        )
        let syncEvents = cap.sync.value.filter { $0.documentId == docId }
        XCTAssertEqual(syncEvents.count, 1, "one sync event per syncComplete")
        XCTAssertEqual(syncEvents.first?.synced, false, "the event carries the server's verdict")
        XCTAssertTrue(
            cap.serverLoaded(docId).isEmpty,
            "an unsuccessful sync never announces the document as loaded from the server"
        )
    }

    /// A failed completion still releases the in-flight syncStep1 claim — JS
    /// calls `completePendingSyncOperation` before it resolves `synced`, so a
    /// `synced:false` frame must not wedge the document's sync forever.
    func testSyncCompleteWithSyncedFalseStillReleasesTheClaim() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        XCTAssertTrue(mgr.beginPendingSyncOperation(docId))
        mgr.handleSyncComplete(documentId: docId, synced: false)
        XCTAssertTrue(
            mgr.beginPendingSyncOperation(docId),
            "an unsuccessful syncComplete must still release the in-flight claim"
        )
    }

    /// The unsynced-local-writes flag is what `documents.evict` consults before
    /// it drops a document's local copy. Clearing it after a completion the
    /// server reported as UNSUCCESSFUL would mark locally sent but
    /// server-unconfirmed edits as safe to discard, so the clear is gated on
    /// the verdict. Queued updates are still retried either way.
    func testUnsuccessfulSyncDoesNotClearTheUnsyncedWritesFlag() async throws {
        let client = makeOfflineClient()
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        client.documentManager.markUnsyncedLocalChanges(docId, true)
        client.documentManager.handleSyncComplete(documentId: docId, synced: false)
        client.reconcileUnsyncedAfterSync(documentId: docId, synced: false)

        XCTAssertTrue(
            client.documentManager.hasUnsyncedLocalChanges(docId),
            "an unsuccessful sync leaves the document holding unconfirmed local writes"
        )
    }

    func testSuccessfulSyncStillClearsTheUnsyncedWritesFlag() async throws {
        let client = makeOfflineClient()
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        client.documentManager.markUnsyncedLocalChanges(docId, true)
        client.documentManager.handleSyncComplete(documentId: docId)
        client.reconcileUnsyncedAfterSync(documentId: docId, synced: true)

        XCTAssertFalse(
            client.documentManager.hasUnsyncedLocalChanges(docId),
            "a successful sync with a drained outbound queue clears the flag as before"
        )
    }

    // MARK: - Behavior 2 — documentLoaded(server) once per open cycle

    func testDocumentLoadedEmittedOnceAcrossRepeatedSyncCompletes() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())

        mgr.handleSyncComplete(documentId: docId)
        XCTAssertEqual(cap.serverLoaded(docId).count, 1, "first sync of an open cycle announces the load")

        // A plain resync of the same open cycle.
        mgr.handleSyncComplete(documentId: docId)
        // A reconnect: the doc goes back to unsynced and then syncs again.
        // This is the case the `!wasSynced` check alone does NOT cover — only
        // the per-open-cycle flag does.
        mgr.handleSyncComplete(documentId: docId, synced: false)
        mgr.handleSyncComplete(documentId: docId)

        XCTAssertEqual(
            cap.serverLoaded(docId).count,
            1,
            "documentLoaded(source:\"server\") is emitted once per open, not once per syncComplete"
        )
        XCTAssertEqual(
            cap.sync.value.filter { $0.documentId == docId }.count,
            4,
            "every syncComplete still reports its sync state"
        )
        XCTAssertTrue(mgr.isSynced(docId))
    }

    // MARK: - Behavior 3 — a reopen starts a fresh cycle

    func testReopenEmitsDocumentLoadedAgain() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        mgr.handleSyncComplete(documentId: docId)
        XCTAssertEqual(cap.serverLoaded(docId).count, 1)

        await mgr.closeDocument(documentId: docId)

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        mgr.handleSyncComplete(documentId: docId)

        XCTAssertEqual(
            cap.serverLoaded(docId).count,
            2,
            "the once-per-open flag is scoped to the open cycle, so a reopen announces the load again"
        )
    }

    /// `evictAllLocalData` empties `openDocs` without going through
    /// `closeDocument`, so it has to end the open cycle too. A flag left
    /// behind there would silence the next open's `documentLoaded`.
    func testEvictAllLocalDataEndsTheOpenCycle() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        mgr.handleSyncComplete(documentId: docId)
        XCTAssertEqual(cap.serverLoaded(docId).count, 1)

        await mgr.evictAllLocalData()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        mgr.handleSyncComplete(documentId: docId)

        XCTAssertEqual(
            cap.serverLoaded(docId).count,
            2,
            "an evict-all ends the open cycle, so the next open announces its load"
        )
    }

    // MARK: - Behavior 4 — openDocument emits documentOpened

    func testOpenDocumentEmitsDocumentOpened() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())

        XCTAssertEqual(
            cap.opened.value.filter { $0.documentId == docId }.count,
            1,
            "openDocument emits documentOpened (JS documentManager.ts:696)"
        )
    }

    /// The already-open fast path returns the same document without running a
    /// new open cycle, so it must not fire a second `documentOpened` — JS
    /// emits only from the real open path.
    func testAlreadyOpenFastPathDoesNotReEmitDocumentOpened() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter)
        let cap = capture(emitter)
        defer { cap.cancel() }
        let docId = newDocId()

        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())
        _ = try await mgr.openDocument(documentId: docId, options: OpenDocumentOptions())

        XCTAssertEqual(
            cap.opened.value.filter { $0.documentId == docId }.count,
            1,
            "reopening an already-open document is not a new open cycle"
        )
    }
}
