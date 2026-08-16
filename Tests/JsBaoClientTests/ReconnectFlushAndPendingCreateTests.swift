import XCTest
@testable import JsBaoClient

/// Issue #2664 (parity items C21 and C27) — what the socket opening has to do
/// before anything else:
///
///   C21 flush every queued outbound update, including for documents in
///       `manual` start-network mode. Those documents are skipped by the connect
///       sweep on purpose (the caller owns their sync timing), and their queued
///       updates used to drain only after a `syncComplete` — which for a manual
///       document may never come. JS flushes all queued updates the moment the
///       socket opens (`flushAllLocalUpdates("ws-open")`).
///   C27 re-drive pending offline creates. The Swift client only re-drove them
///       from the online-auth handoff, so a create whose retry chain was
///       exhausted stayed pending across every later reconnect. JS calls
///       `autoCommitPendingCreates("reconnect")` on every socket open.
///
/// The JS reference for both is pinned in
/// `tests/client/js-bao-client-sync-self-heal.test.ts`.
///
/// Server-free: an in-process loopback WebSocket server accepts the socket, and
/// the pending create's server call is the injected
/// `DocumentManager.createRemoteDocument`.
final class ReconnectFlushAndPendingCreateTests: XCTestCase {

    private func newDocId() -> String { "reconnect-\(UUID().uuidString.prefix(8))" }

    private func makeClient(wsUrl: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "reconnect-flush-test-app",
            token: "test-token",
            offline: true,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
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

    // MARK: - C21: the socket opening flushes queued outbound updates

    /// A manual-start-mode document's queued update must go out when the socket
    /// opens. The connect sweep deliberately never syncs this document, so
    /// nothing else will ever drain its queue.
    func testSocketOpenFlushesQueuedUpdatesForAManualDocument() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "manual-flush", localOnly: false
        )
        _ = try await client.documentManager.commitOfflineCreate(documentId: docId)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: true, deferNetworkSync: true
        ))
        XCTAssertEqual(client.documentManager.startNetworkMode(docId), .manual,
                       "precondition: the caller owns this document's sync timing")

        // Queued while the transport is down: the send fails and the batch is
        // retained.
        client.queueOutboundUpdate(documentId: docId, update: [1, 2, 3])
        await waitUntil(5, "the update to queue while disconnected") {
            client.pendingOutboundUpdateCountForTest(docId) > 0
        }

        try await client.connect()
        XCTAssertTrue(client.isConnected, "precondition: transport is up")

        await waitUntil(5, "the socket opening to flush the queued update") {
            client.pendingOutboundUpdateCountForTest(docId) == 0
        }
        XCTAssertTrue(
            server.receivedFrames.contains { $0.contains("update") && $0.contains(docId) },
            "the queued update must reach the wire on socket open"
        )
    }

    // MARK: - C27: the socket opening re-drives pending creates

    /// A document created offline commits on the next socket open, with no
    /// reachability change and no explicit `commitOfflineCreate` from the
    /// caller.
    func testSocketOpenReDrivesAPendingCreate() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "offline-create", localOnly: false
        )
        XCTAssertTrue(client.documentManager.isPendingCreate(docId),
                      "precondition: the create is still pending")

        try await client.connect()

        await waitUntil(10, "the socket opening to commit the pending create") {
            !client.documentManager.isPendingCreate(docId)
        }
    }

    /// A create whose retry chain has already been exhausted is re-driven too —
    /// the reconnect restarts the attempt count rather than resuming a chain
    /// that has given up.
    func testSocketOpenReDrivesACreateWhoseRetriesWereExhausted() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        let failing = FailingCreate()
        client.documentManager.createRemoteDocument = { _ in
            if failing.shouldFail { throw JsBaoError(code: .unavailable) }
            return ["documentId": docId]
        }
        // One attempt, then the chain is done — the state the filing describes.
        client.documentManager.commitRetryBackoff = CommitRetryBackoff(
            base: 0.01, factor: 1, max: 0.01, jitter: false, maxAttempts: 1
        )
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "exhausted-create", localOnly: false
        )
        client.documentManager.scheduleCommitRetry(documentId: docId)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(client.documentManager.isPendingCreate(docId),
                      "precondition: the retry chain gave up with the create still pending")

        failing.shouldFail = false
        try await client.connect()

        await waitUntil(10, "the reconnect to re-drive the exhausted create") {
            !client.documentManager.isPendingCreate(docId)
        }
    }

    /// Mutable flag shared with the injected create closure.
    private final class FailingCreate: @unchecked Sendable {
        private let lock = NSLock()
        private var _shouldFail = true
        var shouldFail: Bool {
            get { lock.withLock { _shouldFail } }
            set { lock.withLock { _shouldFail = newValue } }
        }
    }
}
