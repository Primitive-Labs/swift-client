import XCTest
@testable import JsBaoClient

/// The `JsBaoClient` half of the post-commit re-sync added for #2587: the
/// `onPendingCreateCommitted` hook is wired to `startNetworkSync`, so what a
/// committed pending create actually puts on the wire is only observable from
/// the client. `PendingSyncOperationTests` covers the `DocumentManager` half
/// (which documents fire the hook at all).
///
/// Server-free: an in-process loopback WebSocket server accepts the socket and
/// records the frames the client sends, so the assertions are on the real wire
/// rather than on an internal flag.
final class PostCommitResyncWiringTests: XCTestCase {

    private func newDocId() -> String { "post-commit-\(UUID().uuidString.prefix(8))" }

    private func makeClient(wsUrl: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "post-commit-resync-test-app",
            token: "test-token",
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    /// A document opened with `deferNetworkSync` / `enableNetworkSync: false`
    /// has taken its sync timing away from the client. Committing its
    /// background create must not put a syncStep1 on the wire — on the
    /// `onExists: "link"` branch that syncStep1 would pull an existing server
    /// document's whole state into a ydoc the caller had not yet asked to sync
    /// (the ordering hazard of #2475).
    func testDeferredOpenSendsNoSyncStep1AfterItsPendingCreateCommits() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }

        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "deferred", localOnly: false
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)
        // The hook dispatches onto a Task, so give it room to land.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count,
            0,
            "a deferred-sync document must not be synced by its own commit"
        )
    }

    /// Asking for sync explicitly hands the timing back to the client, so a
    /// document that started deferred is re-synced by its commit from then on.
    /// The client's own re-subscribe paths pass `explicit: false` and must not
    /// promote a document this way.
    func testExplicitStartNetworkSyncPromotesADeferredOpen() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }

        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "promoted", localOnly: false
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        await client.startNetworkSync(documentId: docId)
        XCTAssertEqual(client.documentManager.startNetworkMode(docId), .immediate)

        // No hand-release of the claim explicit start took: the commit's own
        // `applyPostCommitPolicy` has to release it, so this also covers the
        // `immediate` release path rather than assuming it.
        let before = server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count

        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)

        let deadline = Date().addingTimeInterval(5)
        var resent = false
        while Date() < deadline {
            let now = server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count
            if now > before { resent = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(resent, "a promoted document must be re-synced by its commit")
    }

    /// The positive half: a normally-opened document does get re-synced on
    /// commit — the hook is wired, and the fix above didn't disable it.
    func testImmediateOpenIsResyncedAfterItsPendingCreateCommits() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }

        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "immediate", localOnly: false
        )
        // Open without network sync so the open itself contributes no frame,
        // then hand sync back to the client the way a caller would.
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        client.documentManager.setStartNetworkMode(docId, .immediate)

        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)

        let deadline = Date().addingTimeInterval(5)
        var sawSyncStep1 = false
        while Date() < deadline {
            if server.receivedFrames.contains(where: { $0.contains("syncStep1") && $0.contains(docId) }) {
                sawSyncStep1 = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sawSyncStep1, "the commit must re-send syncStep1 for a client-driven document")
    }

    // MARK: - Connect sweep

    /// Open first, connect second — the path every other test here skips, and
    /// the one that made the mode map ineffective: `webSocketManagerOnConnected`
    /// re-subscribes every open document, so a `deferNetworkSync` document
    /// opened before the socket came up (or carried across any reconnect) got
    /// an unrequested syncStep1 anyway. JS guards this loop explicitly
    /// (`JsBaoClient.ts` `[CONNECT] Manual start for … - not triggering sync`).
    func testConnectSweepDoesNotSyncManualDocuments() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }

        // A local-only document, so `pendingCreate` isn't what's doing the
        // skipping — the mode is.
        let docId = newDocId()
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "manual", localOnly: true
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertEqual(client.documentManager.startNetworkMode(docId), .manual)

        // A second, client-driven document opened alongside it. Waiting for
        // *its* frame is what makes the absence assertion below meaningful: the
        // sweep has demonstrably run and reached the wire, so "no frame for
        // docId" is a skip rather than a frame that simply hadn't arrived yet.
        let controlId = try await openSweepControlDocument(client)

        try await client.connect()
        try await waitForSweep(of: controlId, on: server)

        XCTAssertEqual(
            server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count,
            0,
            "the connect sweep must not sync a document whose timing the caller owns"
        )
    }

    /// Opens a local-only, client-driven document: the sweep syncs it, so its
    /// frame is the signal that the sweep has run.
    private func openSweepControlDocument(_ client: JsBaoClient) async throws -> String {
        let controlId = newDocId()
        _ = try await client.documentManager.createLocalDocument(
            documentId: controlId, title: "sweep-control", localOnly: true
        )
        _ = try await client.openDocument(
            controlId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        client.documentManager.setStartNetworkMode(controlId, .immediate)
        return controlId
    }

    /// Polls until the control document's syncStep1 reaches the server, so the
    /// skip assertions are ordered behind an observed sweep rather than behind
    /// a fixed sleep that a loaded machine can outrun.
    private func waitForSweep(
        of controlId: String,
        on server: LoopbackWebSocketServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if server.receivedFrames.contains(where: { $0.contains("syncStep1") && $0.contains(controlId) }) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the connect sweep never reached the wire", file: file, line: line)
    }

    /// The same sweep must skip `pendingCreate` documents (JS skips them too):
    /// the server does not have the document yet, so the syncStep1 can never be
    /// answered and only holds the pending-sync claim until it ages out.
    func testConnectSweepDoesNotSyncPendingCreateDocuments() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "pending", localOnly: false
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        // Client-driven, so only the pendingCreate state can skip it.
        client.documentManager.setStartNetworkMode(docId, .immediate)
        XCTAssertTrue(client.documentManager.isPendingCreate(docId))

        let controlId = try await openSweepControlDocument(client)

        try await client.connect()
        try await waitForSweep(of: controlId, on: server)

        XCTAssertEqual(
            server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count,
            0,
            "the connect sweep must not sync a document the server does not have yet"
        )
    }

    /// Positive control for both skips: an ordinary client-driven document that
    /// exists server-side is still re-subscribed by the sweep, so the two tests
    /// above aren't passing because the sweep stopped working altogether.
    func testConnectSweepSyncsImmediateDocuments() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "swept", localOnly: true
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        client.documentManager.setStartNetworkMode(docId, .immediate)

        try await client.connect()

        let deadline = Date().addingTimeInterval(5)
        var swept = false
        while Date() < deadline {
            if server.receivedFrames.contains(where: { $0.contains("syncStep1") && $0.contains(docId) }) {
                swept = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(swept, "the connect sweep must still re-subscribe client-driven documents")
    }

    // MARK: - Explicit start outranks an in-flight claim

    /// An explicit `startNetworkSync` is the caller taking over the timing, so
    /// it must not be refused by a claim the *client* took. JS releases the
    /// claim on this path (`requestManualSync`'s `triggerSync` deletes the
    /// `pendingSyncOperations` entry before sending); Swift previously fell
    /// straight into `beginPendingSyncOperation` and no-op'd for up to the 10s
    /// staleness window.
    func testExplicitStartNetworkSyncSendsWhileAClaimIsOutstanding() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let wsBase = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString

        let client = makeClient(wsUrl: wsBase)
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "claimed", localOnly: true
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // A claim the client took and that nothing will answer.
        XCTAssertTrue(client.documentManager.beginPendingSyncOperation(docId))
        let before = server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count

        await client.startNetworkSync(documentId: docId)

        let deadline = Date().addingTimeInterval(5)
        var sent = false
        while Date() < deadline {
            let now = server.receivedFrames.filter { $0.contains("syncStep1") && $0.contains(docId) }.count
            if now > before { sent = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sent, "an explicit start must not be swallowed by an in-flight claim")
    }
}
