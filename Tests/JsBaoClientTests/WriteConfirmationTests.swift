import XCTest
@testable import JsBaoClient

/// Server-free tests for the honest sync-confirmation contract (#1979).
///
/// Before the fix, `waitForWriteConfirmation` / `waitForInSync` polled
/// `documentManager.isSynced` — a boolean set `true` once at initial
/// sync-complete and never reset on a later local edit or a disconnect. So
/// after initial sync both waiters returned success unconditionally, even with
/// the socket down or an edit still in the outbound debounce, and the evict
/// guard (`hasUnsyncedLocalChanges`) trusted the same sticky flag.
///
/// The fix rewires the waiters onto the live `checkStateVector` round trip
/// (JS parity) and makes `hasUnsyncedLocalChanges` track real outbound state.
/// These tests run without a server: `checkStateVector` short-circuits to
/// `(false, false)` while the socket is closed, which is exactly the
/// "connection down after initial sync" case the bug got wrong, and the
/// outbound-state tracking is exercised directly on `DocumentManager`.
final class WriteConfirmationTests: XCTestCase {

    /// A client that never opens a socket (`autoNetwork: false`, no `connect`),
    /// so `checkStateVector` always reports `(false, false)`. In-memory storage
    /// avoids touching SQLite on disk.
    private func makeOfflineClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: "write-confirmation-test-app",
            token: nil,
            offline: true,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    private func makeManager() -> DocumentManager {
        let mgr = DocumentManager(logger: Logger(level: .none, scope: "wc-test"))
        mgr.appId = "write-confirmation-test-app"
        mgr.userId = "test-user"
        return mgr
    }

    private func newDocId() -> String { "doc-\(UUID().uuidString.prefix(8))" }

    // MARK: - Waiters depend on a real round trip, not the sticky flag

    /// After initial sync, `waitForWriteConfirmation` must NOT report confirmed
    /// while the socket is down — it must time out (throw). The old code read
    /// the sticky `isSynced` flag and returned success immediately.
    func testWaitForWriteConfirmationDoesNotConfirmWhenSocketDown() async {
        let client = makeOfflineClient()
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        // Simulate initial sync completing — the sticky isSynced flag flips true.
        client.documentManager.handleSyncComplete(documentId: docId)
        XCTAssertTrue(client.documentManager.isSynced(docId),
                      "precondition: initial sync marks the doc synced")

        do {
            try await client.waitForWriteConfirmation(documentId: docId, timeout: 0.3, pollInterval: 0.05)
            XCTFail("waitForWriteConfirmation confirmed with the socket down — it trusted the sticky isSynced flag")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable, "expected a timeout, not \(error.code)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// Same guarantee for `waitForInSync`.
    func testWaitForInSyncDoesNotConfirmWhenSocketDown() async {
        let client = makeOfflineClient()
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        client.documentManager.handleSyncComplete(documentId: docId)
        XCTAssertTrue(client.documentManager.isSynced(docId))

        do {
            try await client.waitForInSync(documentId: docId, timeout: 0.3, pollInterval: 0.05)
            XCTFail("waitForInSync confirmed with the socket down — it trusted the sticky isSynced flag")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable, "expected a timeout, not \(error.code)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The sub-API forwarder (`documents.waitForInSync`) inherits the same
    /// honest behavior.
    func testDocumentsWaitForInSyncDoesNotConfirmWhenSocketDown() async {
        let client = makeOfflineClient()
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        client.documentManager.handleSyncComplete(documentId: docId)

        do {
            try await client.documents.waitForInSync(documentId: docId, timeout: 0.3, pollInterval: 0.05)
            XCTFail("documents.waitForInSync confirmed with the socket down")
        } catch {
            // expected timeout
        }
    }

    // MARK: - hasUnsyncedLocalChanges tracks real outbound state

    /// `hasUnsyncedLocalChanges` must reflect whether a local edit has actually
    /// reached the server, not the sticky initial-sync flag.
    func testHasUnsyncedLocalChangesTracksOutboundStateNotStickyFlag() {
        let mgr = makeManager()
        let docId = newDocId()

        // A doc that finished initial sync with no queued edit is clean.
        mgr.handleSyncComplete(documentId: docId)
        XCTAssertTrue(mgr.isSynced(docId))
        XCTAssertFalse(mgr.hasUnsyncedLocalChanges(docId),
                       "a synced doc with no queued edit has no unsynced changes")

        // A local edit queued for send (still in debounce, or unsendable because
        // the socket is down) is unsynced even though isSynced sticks at true.
        mgr.markUnsyncedLocalChanges(docId, true)
        XCTAssertTrue(mgr.isSynced(docId), "isSynced stays sticky-true")
        XCTAssertTrue(mgr.hasUnsyncedLocalChanges(docId),
                      "a queued-but-unsent edit must read as unsynced despite the sticky flag")

        // Once the edit reaches the socket the doc is clean again.
        mgr.markUnsyncedLocalChanges(docId, false)
        XCTAssertFalse(mgr.hasUnsyncedLocalChanges(docId))
    }

    // MARK: - Evict guard respects real sync state

    /// `documents.evict` must refuse to drop a doc that has real unsynced local
    /// changes, and proceed only with `force`.
    func testEvictGuardRespectsRealOutboundState() async throws {
        let client = makeOfflineClient()
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        // Synced per the sticky flag, but with an edit that hasn't drained.
        client.documentManager.handleSyncComplete(documentId: docId)
        client.documentManager.markUnsyncedLocalChanges(docId, true)

        // Guard blocks eviction of a doc with unsynced local edits.
        do {
            try await client.documents.evict(documentId: docId)
            XCTFail("evict dropped a doc with unsynced local changes")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }

        // force overrides the guard.
        try await client.documents.evict(documentId: docId, options: EvictDocumentOptions(force: true))

        // Once the edit drains, eviction proceeds without force.
        client.documentManager.markUnsyncedLocalChanges(docId, false)
        try await client.documents.evict(documentId: docId)
    }

    // MARK: - Sticky-unsynced flag clears after a resync (codex review #1979)

    /// A send that fails because the socket dropped leaves the outbound flag
    /// set (the flush already removed `pendingUpdates` but never cleared the
    /// flag). A later reconnect re-syncs the doc through `syncStep1`/`syncStep2`
    /// and completes — at which point the flag must clear so `documents.evict`
    /// stops rejecting a doc the server has already caught up on. But the flag
    /// must NOT clear while a fresh local edit is still queued for send.
    func testUnsyncedFlagClearsAfterResyncButNotWhileEditQueued() async throws {
        // Large debounce so a queued edit does not flush (and clear itself)
        // during the assertions below — we control the timing explicitly.
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: "write-confirmation-test-app",
            token: nil,
            offline: true,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 60),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        let docId = newDocId()

        // Reproduce the stuck-flag state: initial sync done, then a send failed
        // (socket down) — `pendingUpdates` is empty but the flag stays set.
        client.documentManager.handleSyncComplete(documentId: docId)
        client.documentManager.markUnsyncedLocalChanges(docId, true)
        XCTAssertTrue(client.documentManager.hasUnsyncedLocalChanges(docId),
                      "precondition: doc is stuck flagged unsynced after a failed send")

        // A completed reconnect resync must clear the stale flag.
        client.documentManager.handleSyncComplete(documentId: docId)
        client.reconcileUnsyncedAfterSync(documentId: docId)
        XCTAssertFalse(client.documentManager.hasUnsyncedLocalChanges(docId),
                       "resync completed with nothing queued — the stale flag must clear")

        // Now queue a genuinely-pending outbound edit. A resync completing for
        // an unrelated reason must NOT clear it — that edit hasn't drained.
        client.queueOutboundUpdate(documentId: docId, update: [1, 2, 3])
        XCTAssertTrue(client.documentManager.hasUnsyncedLocalChanges(docId),
                      "a queued edit reads unsynced")
        client.reconcileUnsyncedAfterSync(documentId: docId)
        XCTAssertTrue(client.documentManager.hasUnsyncedLocalChanges(docId),
                      "reconcile must not clear the flag while a real edit is still queued")
    }

    // MARK: - Waiter honors the caller's short timeout (codex review #1979)

    /// When the socket is open but the server never answers a
    /// `stateVectorCheck`, `waitForInSync(timeout:)` must return within
    /// roughly its requested window — not block for `checkStateVector`'s full
    /// 5s default. Uses an in-process loopback server that accepts the socket
    /// and stays silent, plus a locally-opened doc so `checkStateVector`
    /// actually sends a request and parks on the (never-arriving) response.
    func testWaitForInSyncHonorsShortTimeoutWhenServerSilent() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        // Strip the trailing slash: buildConnectionRequest appends "/app/...".
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsBase,
            appId: "write-confirmation-test-app",
            token: "test-token",
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        try await client.connect()
        XCTAssertTrue(client.isConnected, "socket should be open against the loopback server")

        // A locally-opened doc (no network sync) gives checkStateVector a real
        // state vector to send, so it parks on the server's silent response
        // rather than short-circuiting to (true, true) for a missing doc.
        let docId = newDocId()
        _ = try await client.documentManager.openDocument(
            documentId: docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let start = Date()
        do {
            try await client.waitForInSync(documentId: docId, timeout: 0.3, pollInterval: 0.05)
            XCTFail("waitForInSync confirmed although the server never answered")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        }
        let elapsed = Date().timeIntervalSince(start)
        // Requested 300ms. The bug blocked ~5s (checkStateVector's default).
        // Allow generous slack for CI scheduling but stay well under 5s.
        XCTAssertLessThan(elapsed, 2.0,
                          "waitForInSync blocked \(elapsed)s for a 300ms timeout — inner checkStateVector not bounded by the caller's remaining time")
    }
}
