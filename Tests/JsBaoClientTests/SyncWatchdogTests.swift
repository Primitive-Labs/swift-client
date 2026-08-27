import XCTest
@testable import JsBaoClient

/// Issue #2664 (parity items C7 and C14) — the two self-heal mechanisms the
/// Swift client was missing on the sync path:
///
///   C7  a `syncStep1` whose `syncComplete` never arrives has to be retried.
///       Before this, the only recovery was the passive 10s staleness escape on
///       the pending-sync claim, which nothing ever re-drove — so a single lost
///       frame left the document unsynced until a reconnect, a remote update or
///       an explicit `startNetworkSync`.
///   C14 a `syncComplete` with no `syncStep2`, for a document whose local
///       metadata claims a local copy while its ydoc is empty, means the server
///       decided the client was already in sync off stale local clocks. The
///       client has to drop that local state and re-sync from an empty state
///       vector, or the document stays empty forever.
///
/// The JS reference for both is pinned in
/// `tests/client/js-bao-client-sync-self-heal.test.ts`.
///
/// Server-free: an in-process loopback WebSocket server accepts the socket and
/// records frames, but never answers — which is exactly the lost-`syncComplete`
/// condition C7 is about. `syncComplete` frames are handed to the client's own
/// message router when a test needs one.
final class SyncWatchdogTests: XCTestCase {

    private func newDocId() -> String { "watchdog-\(UUID().uuidString.prefix(8))" }

    private func makeClient(wsUrl: String, handshakeTimeout: TimeInterval) -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "sync-watchdog-test-app",
            token: "test-token",
            offline: true,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(handshakeTimeout: handshakeTimeout),
            autoNetwork: false
        ))
        // Keep the retry cadence far below the test's own budget; the mechanism
        // is the same one that runs at the 2s → 15s production values.
        client.syncRetryInitial = 0.2
        client.syncRetryMax = 1.0
        return client
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// A committed (not pending-create) document, open with network sync on —
    /// the ordinary case the connect sweep and the watchdog both act on.
    private func makeCommittedOpenDocument(
        _ client: JsBaoClient,
        _ docId: String,
        deferNetworkSync: Bool = false
    ) async throws {
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "watchdog", localOnly: false
        )
        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local,
            enableNetworkSync: true,
            deferNetworkSync: deferNetworkSync
        ))
    }

    private func syncStep1Count(_ server: LoopbackWebSocketServer, _ docId: String) -> Int {
        server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count
    }

    /// Let the frames the setup itself produces (the post-commit re-sync, the
    /// open) land, so a later count is measured against a settled baseline.
    /// Without this the assertions could be satisfied by setup traffic rather
    /// than by the mechanism under test.
    private func quiesce() async throws {
        try await Task.sleep(nanoseconds: 700_000_000)
    }

    private func waitUntil(
        _ timeout: TimeInterval,
        _ what: String,
        _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - C7: sync watchdog

    /// A syncStep1 that gets no syncComplete must be re-sent on its own.
    func testLostSyncCompleteIsRetried() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()
        XCTAssertTrue(client.isConnected, "precondition: transport is up")

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId, deferNetworkSync: true)
        try await quiesce()
        let baseline = syncStep1Count(server, docId)

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }
        await waitUntil(5, "the watchdog to re-send syncStep1") {
            self.syncStep1Count(server, docId) >= baseline + 2
        }
        XCTAssertFalse(
            client.isSynced(docId),
            "a document whose syncComplete never arrived must not read as synced"
        )
    }

    /// The watchdog releases the in-flight claim, so the retry — and any caller
    /// asking for a sync meanwhile — is not refused by the claim the lost cycle
    /// left behind.
    func testWatchdogReleasesTheInFlightClaim() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        // A long first retry keeps the retry itself out of the way, so the free
        // claim observed below is the watchdog's doing and not the retry's.
        client.syncRetryInitial = 30
        client.syncRetryMax = 30
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId, deferNetworkSync: true)
        try await quiesce()
        let baseline = syncStep1Count(server, docId)

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }
        await waitUntil(5, "the watchdog to release the claim and mark the document unsynced") {
            !client.isSynced(docId) && client.documentManager.beginPendingSyncOperation(docId)
        }
    }

    /// Repeated timeouts back off, doubling up to the ceiling, so a server that
    /// stays silent is not hammered.
    func testRetryBackoffDoublesAndIsCapped() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId, deferNetworkSync: true)
        await client.startNetworkSync(documentId: docId)

        await waitUntil(5, "the first timeout to arm a backoff") {
            (client.syncRetryBackoffForTest(docId) ?? 0) >= 0.4
        }
        await waitUntil(10, "the backoff to reach its ceiling") {
            (client.syncRetryBackoffForTest(docId) ?? 0) >= client.syncRetryMax
        }
        XCTAssertEqual(
            client.syncRetryBackoffForTest(docId), client.syncRetryMax,
            "the backoff must be capped, not unbounded"
        )
    }

    /// A syncComplete cancels the watchdog: no retry is scheduled for a cycle
    /// that finished normally.
    func testSyncCompleteCancelsTheWatchdog() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        // No local metadata claim on this document, so the C14 stale-state
        // recovery below does not apply and the bare syncComplete is simply the
        // normal end of the cycle.
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        try await quiesce()
        let baseline = syncStep1Count(server, docId)

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }

        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        XCTAssertTrue(client.isSynced(docId))

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(
            syncStep1Count(server, docId), baseline + 1,
            "a completed cycle must not leave a watchdog behind to re-send"
        )
    }

    /// Closing a document cancels its watchdog — nothing may keep re-syncing a
    /// document the caller closed.
    func testClosingADocumentCancelsItsWatchdog() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId, deferNetworkSync: true)
        try await quiesce()
        let baseline = syncStep1Count(server, docId)

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }

        await client.closeDocument(docId)
        let afterClose = syncStep1Count(server, docId)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(
            syncStep1Count(server, docId), afterClose,
            "a closed document must not be re-synced by its watchdog"
        )
    }

    // MARK: - C14: stale local state recovery

    /// The document claims a local copy (it has local metadata) but its ydoc is
    /// empty, and the server answered with a bare syncComplete — the stale-clock
    /// case. The client must drop the local state and re-sync.
    func testSyncCompleteWithoutSyncStep2ResyncsAStaleDocument() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 30)
        defer { Task { await client.destroy() } }
        try await client.connect()

        // Reopening a document whose local metadata survives from an earlier
        // session is the shape the recovery is for: the metadata claims a local
        // copy, and nothing loads content back into the ydoc.
        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId, deferNetworkSync: true)
        await client.closeDocument(docId)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        XCTAssertTrue(client.documentManager.claimedLocalCopyAtOpen(docId),
                      "precondition: the document claimed a local copy at open")
        XCTAssertFalse(client.documentManager.ydocHasData(docId),
                       "precondition: the ydoc is empty")
        try await quiesce()
        let baseline = syncStep1Count(server, docId)

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }

        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )

        await waitUntil(5, "the stale-state reset to re-send syncStep1") {
            self.syncStep1Count(server, docId) >= baseline + 2
        }
    }

    /// The recovery must not fire for a document that never claimed local data —
    /// a bare syncComplete there just means the server had nothing to send.
    func testSyncCompleteWithoutSyncStep2DoesNotResyncAFreshDocument() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url), handshakeTimeout: 30)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        // The claim is sampled before the open attaches persistence, so a
        // document with no local metadata does not claim one — even though the
        // open then wires a (empty) persistence provider for it.
        XCTAssertFalse(client.documentManager.claimedLocalCopyAtOpen(docId),
                       "precondition: no local copy is claimed")
        try await quiesce()
        let baseline = syncStep1Count(server, docId)

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }

        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(
            syncStep1Count(server, docId), baseline + 1,
            "a document with no local claim must not be reset and re-synced"
        )
    }
}
