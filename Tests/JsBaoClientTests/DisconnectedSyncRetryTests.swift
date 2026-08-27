import XCTest
@testable import JsBaoClient

/// #2621 — the syncStep1 send path must not be attempted while the WebSocket
/// transport is down.
///
/// Before the fix, every 350ms availability-retry tick took the in-flight sync
/// claim, built a syncStep1 message (stamping the `syncStep1SentAt` timing
/// anchor as if a frame had gone out), then failed inside `wsManager.send` with
/// `WebSocket is not connected` and logged a warning. With a session whose auth
/// is permanently dead the transport never comes back, so that ran unbounded —
/// ~3 log lines/sec for as long as the document stayed open.
///
/// The observable used here is the timing anchor rather than the wire: on a
/// disconnected transport the send throws client-side, so *no* frame reaches a
/// server either way. `DocumentManager.buildSyncStep1Message` stamps
/// `syncStep1SentAt` "immediately before the frame goes on the wire", so a
/// stamped anchor with nothing sent is exactly the wasted attempt this issue is
/// about.
///
/// Server-free: an in-process loopback WebSocket server stands in for the real
/// server, and the disconnected cases simply never connect to it.
final class DisconnectedSyncRetryTests: XCTestCase {

    private func newDocId() -> String { "disc-sync-\(UUID().uuidString.prefix(8))" }

    private func makeClient(wsUrl: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "disconnected-sync-retry-test-app",
            token: "test-token",
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// A local document with a live sync protocol, so `buildSyncStep1Message`
    /// can actually produce a message — otherwise the builder returns nil and
    /// every assertion below would pass for the wrong reason.
    private func makeOpenLocalDocument(_ client: JsBaoClient, _ docId: String) async throws {
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "disconnected-sync", localOnly: false
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        // The local open path may stamp timings of its own; start from clean so
        // the assertions below only see what the calls under test did.
        client.documentManager.clearSyncTimings(docId)
    }

    // MARK: - Behavior: no send attempt while disconnected

    /// Every caller of the send funnel — the retry loop's `explicit: false` and
    /// the public `startNetworkSync` — must skip while the transport is down.
    func testDisconnectedTransportMakesNoSyncStep1Attempt() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        // Never connected: the client has a valid ws URL but no socket.
        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        XCTAssertFalse(client.isConnected, "precondition: transport is down")

        let docId = newDocId()
        try await makeOpenLocalDocument(client, docId)

        for _ in 0..<4 {
            await client.startNetworkSync(documentId: docId, explicit: false)
        }
        await client.startNetworkSync(documentId: docId)

        XCTAssertNil(
            client.documentManager.getSyncTimings(docId)?["syncStep1SentAt"],
            "a disconnected transport must not build/stamp a syncStep1 — the send "
            + "can only fail client-side"
        )
        XCTAssertTrue(
            client.documentManager.beginPendingSyncOperation(docId),
            "the skipped attempts must not have taken (and released) the in-flight "
            + "sync claim"
        )
        XCTAssertEqual(
            server.receivedFrames.filter { $0.contains("syncStep1") }.count, 0,
            "nothing may reach the wire while disconnected"
        )
    }

    /// The reported path end to end: a `.network` open runs the 350ms
    /// availability-retry loop, which must make no send attempt per tick while
    /// the transport is down.
    ///
    /// The transport is held down by an unreachable ws URL rather than by
    /// simply never connecting: since #2667 the open brings the socket up
    /// itself before waiting (JS `connect()` ahead of `waitForAvailability`),
    /// so a reachable server would be connected here and the syncStep1 the
    /// retry loop sends would be entirely legitimate. A closed port is the
    /// down-transport this invariant is actually about — an unreachable
    /// server, or a session whose auth is dead.
    func testAvailabilityRetryLoopMakesNoSendAttemptsWhileDisconnected() async throws {
        // Port 1 is not listening: every connect attempt the open makes fails,
        // so the transport stays down for the whole wait.
        let client = makeClient(wsUrl: "ws://127.0.0.1:1")
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "retry-loop", localOnly: false
        )
        client.documentManager.clearSyncTimings(docId)

        // ~1.2s of wait is 3 retry ticks. The open ends on the availability
        // timeout because the transport is down and no syncComplete can
        // arrive — since #2667 that timeout throws `NETWORK_TIMEOUT` instead
        // of resolving with the empty document. What this test is about is
        // what the retry loop did while it waited.
        do {
            _ = try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1.2
            ))
            XCTFail("expected the open to fail on the availability timeout")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .networkTimeout)
        }

        // The timing anchor is the whole observable here: nothing can reach a
        // wire that has no listener on the other end, so a frame count would
        // pass for the wrong reason. `buildSyncStep1Message` stamps
        // `syncStep1SentAt` immediately before a frame would go out, so an
        // unstamped anchor is proof no tick took the claim and built one.
        XCTAssertNil(
            client.documentManager.getSyncTimings(docId)?["syncStep1SentAt"],
            "the 350ms retry loop attempted a syncStep1 send on a disconnected transport"
        )
        XCTAssertTrue(
            client.documentManager.beginPendingSyncOperation(docId),
            "the skipped ticks must not have taken (and released) the in-flight sync claim"
        )
    }

    // MARK: - Behavior: one report per connectivity transition

    /// The log has to survive a permanently dead transport: one line per
    /// document per disconnected→connected transition, not one per tick.
    func testSkipIsReportedOncePerConnectivityTransition() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }

        let docA = newDocId()
        let docB = newDocId()

        XCTAssertTrue(client.noteDisconnectedSyncSkip(docA), "first skip reports")
        XCTAssertFalse(client.noteDisconnectedSyncSkip(docA), "second skip is silent")
        XCTAssertFalse(client.noteDisconnectedSyncSkip(docA), "and stays silent")
        XCTAssertTrue(
            client.noteDisconnectedSyncSkip(docB),
            "the suppression is per document — a second document still reports once"
        )

        // A connect is the transition that re-arms the report.
        client.clearDisconnectedSyncSkipReports()
        XCTAssertTrue(
            client.noteDisconnectedSyncSkip(docA),
            "a later disconnection must report again — the suppression is not sticky"
        )
    }

    /// The suppression set is keyed by document, so a closed document must not
    /// leave an entry behind for the client's lifetime.
    func testClosingADocumentDropsItsSkipReportEntry() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        try await makeOpenLocalDocument(client, docId)

        XCTAssertTrue(client.noteDisconnectedSyncSkip(docId))
        await client.closeDocument(docId)
        XCTAssertTrue(
            client.noteDisconnectedSyncSkip(docId),
            "closing the document must drop its skip-report entry"
        )
    }

    // MARK: - Regression guard: a connected transport still syncs

    /// The gate must not swallow the normal path — a connected transport still
    /// puts syncStep1 on the wire.
    func testConnectedTransportStillSendsSyncStep1() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()
        XCTAssertTrue(client.isConnected, "precondition: transport is up")

        let docId = newDocId()
        try await makeOpenLocalDocument(client, docId)

        await client.startNetworkSync(documentId: docId)

        let deadline = Date().addingTimeInterval(5)
        var sent = false
        while Date() < deadline {
            if server.receivedFrames.contains(where: { $0.contains("syncStep1") && $0.contains(docId) }) {
                sent = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sent, "a connected transport must still send syncStep1")
        XCTAssertNotNil(
            client.documentManager.getSyncTimings(docId)?["syncStep1SentAt"],
            "the timing anchor is stamped when a frame really goes out"
        )
    }

    /// The other half of the transition: a document skipped while the socket was
    /// down is synced once the socket comes up (the connect sweep runs after the
    /// transport snapshot flips to connected, so it passes the gate).
    func testReconnectResumesSyncForADocumentSkippedWhileDisconnected() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }

        // The connect sweep deliberately skips `manual` and `pendingCreate`
        // documents, so this one is committed first and opened with network sync
        // on — otherwise the sweep would have nothing to do and the test would
        // pass for the wrong reason. `.local` keeps the open from parking on the
        // availability wait while the transport is down.
        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "reconnect-resume", localOnly: false
        )
        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: true)
        )
        XCTAssertFalse(client.documentManager.isPendingCreate(docId))
        XCTAssertNotEqual(client.documentManager.startNetworkMode(docId), .manual)
        client.documentManager.clearSyncTimings(docId)

        // Disconnected: skipped, nothing stamped.
        await client.startNetworkSync(documentId: docId, explicit: false)
        XCTAssertNil(client.documentManager.getSyncTimings(docId)?["syncStep1SentAt"])

        try await client.connect()

        let deadline = Date().addingTimeInterval(5)
        var sent = false
        while Date() < deadline {
            if server.receivedFrames.contains(where: { $0.contains("syncStep1") && $0.contains(docId) }) {
                sent = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(
            sent,
            "the connect sweep must sync a document whose earlier attempt the gate skipped"
        )
    }
}
