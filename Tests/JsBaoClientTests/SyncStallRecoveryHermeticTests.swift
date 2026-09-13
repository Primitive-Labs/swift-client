import XCTest
@testable import JsBaoClient

/// Issue #3390 — a document whose `syncComplete` never arrives stopped
/// converging and told the app nothing.
///
/// The #2664 watchdog re-sends `syncStep1` once per timeout, but that single
/// retry ends the chain: `startNetworkSync` returns without arming anything
/// when the transport is down, when a claim from an earlier cycle is still
/// held, or when the send itself fails. With no watchdog armed and no retry
/// pending, the document stays unsynced with nothing left to re-drive it —
/// which is what the field report saw, a client rendering stale state until
/// the process was restarted. On top of that, nothing reached the app: no
/// sync-state event was emitted, so the session simply looked like a hung
/// peer.
///
/// Server-free: an in-process loopback WebSocket server accepts the socket and
/// records frames but never answers, which is the lost-`syncComplete`
/// condition itself. `syncComplete` frames are handed to the client's own
/// message router when a test needs one.
final class SyncStallRecoveryHermeticTests: XCTestCase {
    private var apiServers: [LoopbackAPIServer] = []

    override func tearDown() async throws {
        for server in apiServers { server.stop() }
        apiServers = []
    }

    private func newDocId() -> String { "stall-\(UUID().uuidString.prefix(8))" }

    /// The path the API server refuses with a 403.
    private static let expiredUpdatePath = "/r2/expired-3390"

    /// An API server that answers everything the client asks during these
    /// tests. It exists so the client keeps the token it started with: a real
    /// dev server rejects this suite's fake token, and a client that has lost
    /// its access token refuses to build a socket — which would make the
    /// reconnect assertions below measure the test's auth setup rather than
    /// the behavior.
    ///
    /// It also refuses `expiredUpdatePath` with a 403 — the expired R2 URL an
    /// `updateUrl` download can run into.
    private func makeApiServer() throws -> String {
        let server = try LoopbackAPIServer { request in
            if request.apiPathOnly == "/auth/refresh" {
                return .json(#"{"token":"test-token"}"#)
            }
            if request.path == Self.expiredUpdatePath {
                return .status(403, "expired")
            }
            return .json("{}")
        }
        let baseUrl = try server.start()
        apiServers.append(server)
        return baseUrl
    }

    private func makeClient(
        wsUrl: String,
        handshakeTimeout: TimeInterval,
        apiUrl: String? = nil
    ) throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: try apiUrl ?? makeApiServer(),
            wsUrl: wsUrl,
            appId: "sync-stall-test-app",
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
        client.syncRetryInitial = 0.1
        client.syncRetryMax = 0.4
        return client
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// A committed (not pending-create) document, open with network sync on.
    private func makeCommittedOpenDocument(
        _ client: JsBaoClient,
        _ docId: String
    ) async throws {
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "stall", localOnly: false
        )
        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local,
            enableNetworkSync: true,
            deferNetworkSync: true
        ))
    }

    private func syncStep1Count(_ server: LoopbackWebSocketServer, _ docId: String) -> Int {
        server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count
    }

    /// Let the frames the setup itself produces (the post-commit re-sync, the
    /// open) land, so a later count is measured against a settled baseline.
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

    /// Drive one timed-out sync cycle and take the document's pending-sync
    /// claim the moment the watchdog releases it, so the retry that follows
    /// finds the document claimed and cannot start a cycle — the shape a claim
    /// left behind by an earlier cycle produces in the field. The caller
    /// releases the claim with `completePendingSyncOperation`.
    private func stallWithHeldClaim(
        _ client: JsBaoClient,
        _ server: LoopbackWebSocketServer,
        _ docId: String
    ) async -> Int {
        let baseline = syncStep1Count(server, docId)
        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }
        await waitUntil(5, "the watchdog to release the claim") {
            !client.isSynced(docId) && client.documentManager.beginPendingSyncOperation(docId)
        }
        return baseline
    }

    // MARK: - The retry chain keeps going until a cycle actually starts

    /// A retry attempt that cannot start a sync cycle must re-arm itself. Once
    /// the blocker clears, the client re-sends `syncStep1` on its own — no
    /// reconnect, no reopen, no process restart.
    func testRetryChainSurvivesAnAttemptThatCannotStartACycle() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()
        XCTAssertTrue(client.isConnected, "precondition: transport is up")

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        try await quiesce()

        let baseline = await stallWithHeldClaim(client, server, docId)

        // While the claim is held, no syncStep1 can go out — the retries are
        // being refused.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(
            syncStep1Count(server, docId), baseline + 1,
            "precondition: a held claim refuses every retry attempt"
        )

        // The blocker clears. Nothing else happens: no reconnect, no reopen,
        // no explicit startNetworkSync.
        client.documentManager.completePendingSyncOperation(docId)

        await waitUntil(5, "the retry chain to re-send syncStep1 on its own") {
            self.syncStep1Count(server, docId) >= baseline + 2
        }
    }

    /// The re-armed retries keep backing off to the ceiling rather than
    /// spinning: a document that cannot sync is retried slowly, not hammered.
    func testReArmedRetriesStayOnTheCappedBackoff() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        try await quiesce()

        _ = await stallWithHeldClaim(client, server, docId)
        defer { client.documentManager.completePendingSyncOperation(docId) }

        await waitUntil(5, "the re-armed retries to reach the backoff ceiling") {
            client.syncRetryBackoffForTest(docId) == client.syncRetryMax
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(
            client.syncRetryBackoffForTest(docId), client.syncRetryMax,
            "the re-armed chain must stay capped, not grow unbounded or reset"
        )
    }

    /// Closing the document ends the chain. Nothing may keep re-syncing a
    /// document the caller closed, however many times the retry re-armed.
    func testClosingTheDocumentEndsTheReArmedChain() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        try await quiesce()

        _ = await stallWithHeldClaim(client, server, docId)
        // Let the chain re-arm at least once before the close.
        try await Task.sleep(nanoseconds: 800_000_000)

        await client.closeDocument(docId)
        client.documentManager.completePendingSyncOperation(docId)
        let afterClose = syncStep1Count(server, docId)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(
            syncStep1Count(server, docId), afterClose,
            "a closed document must not be re-synced by the retry chain"
        )
    }

    // MARK: - The app hears about a document that cannot sync

    /// A document that misses the handshake budget has to reach the app as a
    /// sync-state error. Without one the app has nothing to surface and keeps
    /// rendering stale state as if it were current.
    func testHandshakeBudgetTimeoutSurfacesASyncErrorToTheApp() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        try await quiesce()

        let states = LockedBox<[String]>([])
        let sub = client.eventEmitter.subscribe(DocumentSyncStateChangedEvent.self) { event in
            guard event.documentId == docId else { return }
            states.withValue { $0.append(event.state) }
        }
        defer { sub.cancel() }

        let baseline = syncStep1Count(server, docId)
        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the syncStep1 under test") {
            self.syncStep1Count(server, docId) >= baseline + 1
        }

        await waitUntil(5, "a sync-state error for the stalled document") {
            states.value.contains("error")
        }
        XCTAssertFalse(
            client.isSynced(docId),
            "precondition: the document is not synced when the error is reported"
        )
    }

    /// Once the document does sync, the app hears that too — an error it was
    /// told about has to be clearable without guessing.
    func testASyncedDocumentClearsTheReportedError() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        // No local metadata claim on this document, so the #2664 C14
        // stale-state recovery does not apply and the bare syncComplete below
        // is simply the cycle ending normally.
        let docId = newDocId()
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        try await quiesce()

        let states = LockedBox<[String]>([])
        let sub = client.eventEmitter.subscribe(DocumentSyncStateChangedEvent.self) { event in
            guard event.documentId == docId else { return }
            states.withValue { $0.append(event.state) }
        }
        defer { sub.cancel() }

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "a sync-state error for the stalled document") {
            states.value.contains("error")
        }

        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        XCTAssertTrue(client.isSynced(docId), "precondition: the document synced")

        await waitUntil(5, "the recovery to be reported as synced") {
            states.value.last == "synced"
        }
    }

    /// A `syncComplete` that triggers the #2664 C14 stale-state reset has not
    /// delivered any server state: the document is about to be wiped and
    /// re-synced. It must not be reported as the recovery — that comes with the
    /// re-sync that actually completes, once.
    func testAStaleStateResetDoesNotClearTheReportedError() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        // Reopened with local metadata and an empty ydoc — the shape the
        // stale-state recovery fires on when the server answers with a bare
        // syncComplete.
        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        await client.closeDocument(docId)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        XCTAssertTrue(client.documentManager.claimedLocalCopyAtOpen(docId),
                      "precondition: the document claimed a local copy at open")
        XCTAssertFalse(client.documentManager.ydocHasData(docId),
                       "precondition: the ydoc is empty")
        try await quiesce()

        let states = LockedBox<[String]>([])
        let sub = client.eventEmitter.subscribe(DocumentSyncStateChangedEvent.self) { event in
            guard event.documentId == docId else { return }
            states.withValue { $0.append(event.state) }
        }
        defer { sub.cancel() }

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "a sync-state error for the stalled document") {
            states.value.contains("error")
        }

        // The cycle ends with no server state for a document claiming local
        // data: the client resets its persistence and re-sends syncStep1.
        let beforeReset = syncStep1Count(server, docId)
        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        await waitUntil(5, "the stale-state reset to re-send syncStep1") {
            self.syncStep1Count(server, docId) > beforeReset
        }
        XCTAssertFalse(
            states.value.contains("synced"),
            "a completion that only scheduled a reset must not be reported as the recovery"
        )

        // The re-sync carries server state and completes. This is the
        // recovery, and the app hears it exactly once.
        await client.handleWebSocketMessage(
            "{\"type\":\"syncStep2\",\"documentId\":\"\(docId)\",\"update\":\"AAA=\"}"
        )
        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        await waitUntil(5, "the re-sync to be reported as synced") {
            states.value.contains("synced")
        }
        XCTAssertEqual(
            states.value.filter { $0 == "synced" }.count, 1,
            "the recovery is reported once, by the sync that delivered server state"
        )
    }

    /// A `syncStep2` whose `updateUrl` download fails has delivered nothing
    /// either: the frame counts as received (so the stale-state check does not
    /// fire), but no server state reached the document. The `syncComplete`
    /// that closes that cycle must not be reported as the recovery — the app
    /// would clear its warning over a document still stale. The next cycle
    /// that applies is.
    func testAFailedSyncStep2PayloadDoesNotClearTheReportedError() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let apiUrl = try makeApiServer()
        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3, apiUrl: apiUrl)
        defer { Task { await client.destroy() } }
        try await client.connect()

        // No local metadata claim, so the stale-state recovery does not apply.
        let docId = newDocId()
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        try await quiesce()

        let states = LockedBox<[String]>([])
        let sub = client.eventEmitter.subscribe(DocumentSyncStateChangedEvent.self) { event in
            guard event.documentId == docId else { return }
            states.withValue { $0.append(event.state) }
        }
        defer { sub.cancel() }

        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "a sync-state error for the stalled document") {
            states.value.contains("error")
        }

        // The retry's cycle answers with an R2 URL the download is refused
        // for, then completes.
        await client.handleWebSocketMessage(
            "{\"type\":\"syncStep2\",\"documentId\":\"\(docId)\",\"updateUrl\":\"\(apiUrl)\(Self.expiredUpdatePath)\"}"
        )
        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        XCTAssertTrue(client.isSynced(docId), "precondition: the cycle completed")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(
            states.value.contains("synced"),
            "a cycle whose payload did not apply must not be reported as the recovery: \(states.value)"
        )

        // The server closes a cycle with more than one syncComplete (another
        // follows the client's answer to the server's own syncStep1). Those
        // belong to the failed cycle too.
        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        XCTAssertFalse(
            states.value.contains("synced"),
            "a second syncComplete for the failed cycle is not the recovery either: \(states.value)"
        )

        // The next cycle applies: that is the recovery, reported once.
        let beforeNext = syncStep1Count(server, docId)
        await client.startNetworkSync(documentId: docId)
        await waitUntil(5, "the next cycle's syncStep1") {
            self.syncStep1Count(server, docId) > beforeNext
        }
        await client.handleWebSocketMessage(
            "{\"type\":\"syncStep2\",\"documentId\":\"\(docId)\",\"update\":\"AAA=\"}"
        )
        await client.handleWebSocketMessage(
            "{\"type\":\"syncComplete\",\"documentId\":\"\(docId)\"}"
        )
        await waitUntil(5, "the applying cycle to be reported as synced") {
            states.value.contains("synced")
        }
        XCTAssertEqual(
            states.value.filter { $0 == "synced" }.count, 1,
            "the recovery is reported once, by the sync that delivered server state"
        )
    }

    // MARK: - A connection that answers nothing is rebuilt once

    /// Retrying on a connection the server has stopped answering on converges
    /// on nothing — in the field the only recovery was killing the process,
    /// which is a new socket. After repeated handshake-budget timeouts on a
    /// socket the client still considers open, the client rebuilds the socket
    /// itself so the next cycle runs on a fresh connection.
    func testRepeatedTimeoutsRebuildTheConnection() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()
        XCTAssertEqual(server.acceptedCount, 1, "precondition: one socket so far")

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        try await quiesce()

        await client.startNetworkSync(documentId: docId)
        await waitUntil(10, "the client to rebuild the socket after repeated timeouts") {
            server.acceptedCount >= 2
        }
    }

    /// The rebuild happens once per stalled document, not on a loop: a
    /// document that still cannot sync on the fresh socket must not reconnect
    /// the client every few seconds.
    func testTheConnectionRebuildIsNotRepeated() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = try makeClient(wsUrl: wsBase(url), handshakeTimeout: 0.3)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeCommittedOpenDocument(client, docId)
        try await quiesce()

        await client.startNetworkSync(documentId: docId)
        await waitUntil(10, "the client to rebuild the socket after repeated timeouts") {
            server.acceptedCount >= 2
        }
        let afterRebuild = server.acceptedCount

        // The server still answers nothing, so the document stays stalled and
        // the retry chain keeps running. That must not keep rebuilding.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(
            server.acceptedCount, afterRebuild,
            "a document that stays stalled must be retried, not reconnected in a loop"
        )
    }
}
