import XCTest
import YSwift
@testable import JsBaoClient

/// #2661 — server-pushed frames the Swift message switch used to drop:
/// `error`, `availability`, `pendingCreateCommitted`, `pendingCreateFailed` and
/// `refreshAwareness`. The JS client is the reference; each behavior here has a
/// matching pin in `tests/client/js-bao-client-server-push-frames.test.ts`.
///
/// Server-free: frames are fed straight into `handleWebSocketMessage` (the same
/// way `NotificationsAPITests` drives its `notification` frame), and the one
/// behavior that is only observable on the wire — the awareness re-broadcast —
/// runs against the in-process `LoopbackWebSocketServer`.
final class ServerPushFramesTests: XCTestCase {

    private func newDocId() -> String { "push-frames-\(UUID().uuidString.prefix(8))" }

    private func makeClient(wsUrl: String = TestConfig.wsUrl) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "server-push-frames-test-app",
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

    /// A local document that is a pending create, with its sync protocol and
    /// awareness entry built (the same setup `createLocalDocument` gives a
    /// freshly created document).
    @discardableResult
    private func makeLocalDocument(
        _ client: JsBaoClient,
        _ docId: String,
        localOnly: Bool = false
    ) async throws -> YDocument {
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        let doc = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "push-frames", localOnly: localOnly
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        return doc
    }

    // MARK: - B7: error frames

    func testErrorFrameEmitsConnectionErrorWithServerDetail() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let received = LockedBox<[ConnectionErrorEvent]>([])
        let sub = client.eventEmitter.subscribe(ConnectionErrorEvent.self) { event in
            received.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage("""
        {"type":"error","message":"Permission denied","documentId":"doc-b7",\
        "messageType":"syncStep1","detail":{"code":"FORBIDDEN"}}
        """)

        let events = received.value
        XCTAssertEqual(events.count, 1, "an error frame must surface as one connection-error")
        XCTAssertEqual(events.first?.message, "Permission denied")
        XCTAssertEqual(events.first?.documentId, "doc-b7")
        XCTAssertEqual(events.first?.messageType, "syncStep1")
        XCTAssertEqual(events.first?.detail?["code"]?.stringValue, "FORBIDDEN")
    }

    // MARK: - C1: availability frames

    func testAvailabilityFrameAppliesSyncState() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        try await makeLocalDocument(client, docId)
        // The shared setup opens deferred, which records `manual`. A normal
        // open records `immediate`, and that is the case this behavior is
        // about — a caller waiting on the network.
        client.documentManager.setStartNetworkMode(docId, .immediate)
        XCTAssertFalse(client.isSynced(docId), "precondition: not synced yet")

        let synced = LockedBox<[SyncEvent]>([])
        let sub = client.eventEmitter.subscribe(SyncEvent.self) { event in
            synced.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage("""
        {"type":"availability","documentId":"\(docId)","status":"available","synced":true}
        """)

        XCTAssertTrue(client.isSynced(docId), "availability must apply the sync state it carries")
        XCTAssertTrue(
            synced.value.contains { $0.documentId == docId && $0.synced },
            "a waiting open resolves on the sync event, so it has to fire"
        )
    }

    /// JS parity (`applySyncState`): a document whose caller owns the sync
    /// timing is not flipped to synced by a server push.
    func testAvailabilityFrameLeavesAManualDocumentAlone() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        try await makeLocalDocument(client, docId)  // deferred open → manual
        XCTAssertEqual(client.documentManager.startNetworkMode(docId), .manual)

        await client.handleWebSocketMessage("""
        {"type":"availability","documentId":"\(docId)","status":"available","synced":true}
        """)

        XCTAssertFalse(client.isSynced(docId), "a manual document keeps its own sync timing")
    }

    func testAvailabilityFrameAppliesMetadata() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        try await makeLocalDocument(client, docId)

        let changes = LockedBox<[DocumentMetadataChangedEvent]>([])
        let sub = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) { event in
            changes.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage("""
        {"type":"availability","documentId":"\(docId)","status":"available",\
        "metadata":{"title":"From availability","permission":"read-write"}}
        """)

        let event = changes.value.first { $0.documentId == docId }
        XCTAssertNotNil(event, "attached metadata must reach documentMetadataChanged subscribers")
        XCTAssertEqual(event?.metadata?["title"]?.stringValue, "From availability")
        XCTAssertEqual(event?.source, "server")
        XCTAssertEqual(
            client.documentManager.getLocalMetadata(docId)?.title,
            "From availability",
            "the local metadata index must carry the applied title"
        )
    }

    func testAvailabilityFrameWithoutDocumentIdIsIgnored() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let changes = LockedBox<[DocumentMetadataChangedEvent]>([])
        let sub = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) { event in
            changes.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage(#"{"type":"availability","synced":true}"#)

        XCTAssertTrue(changes.value.isEmpty, "a frame with no documentId has nothing to apply")
    }

    // MARK: - C2: pendingCreate lifecycle frames

    func testPendingCreateCommittedFrameClearsThePendingCreate() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        try await makeLocalDocument(client, docId)
        XCTAssertTrue(client.documentManager.isPendingCreate(docId), "precondition: pending create")

        let committed = LockedBox<[PendingCreateCommittedEvent]>([])
        let sub = client.eventEmitter.subscribe(PendingCreateCommittedEvent.self) { event in
            committed.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage("""
        {"type":"pendingCreateCommitted","documentId":"\(docId)"}
        """)

        XCTAssertFalse(
            client.documentManager.isPendingCreate(docId),
            "the server confirmed the create — the retry loop must stop here"
        )
        XCTAssertTrue(committed.value.contains { $0.documentId == docId })
        let meta = client.documentManager.getLocalMetadata(docId)
        XCTAssertEqual(meta?.pendingCreate, false)
        XCTAssertNotNil(meta?.createCommittedAt, "commit time must be stamped, as in JS")
    }

    func testPendingCreateFailedFrameRecordsTheFailure() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        try await makeLocalDocument(client, docId)

        let failed = LockedBox<[PendingCreateFailedEvent]>([])
        let sub = client.eventEmitter.subscribe(PendingCreateFailedEvent.self) { event in
            failed.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        await client.handleWebSocketMessage("""
        {"type":"pendingCreateFailed","documentId":"\(docId)","reason":"quota exceeded"}
        """)

        XCTAssertTrue(client.documentManager.isPendingCreate(docId))
        XCTAssertEqual(failed.value.first { $0.documentId == docId }?.error, "quota exceeded")
        let meta = client.documentManager.getLocalMetadata(docId)
        XCTAssertEqual(meta?.pendingCreate, true)
        XCTAssertEqual(meta?.commitError?.message, "quota exceeded")
    }

    // MARK: - C3: refreshAwareness

    func testRefreshAwarenessFrameRebroadcastsLocalState() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeLocalDocument(client, docId)
        client.setAwareness(docId, state: ["user": .object(["name": .string("swift")])])

        // Wait for the state-setting broadcast so the refresh response is a
        // second, distinct frame rather than the one setAwareness already sent.
        try await eventually(timeout: 5, description: "initial awareness frame") {
            server.receivedFrames.contains { $0.contains("\"awareness\"") && $0.contains(docId) }
        }
        let before = server.receivedFrames.filter {
            $0.contains("\"awareness\"") && $0.contains(docId)
        }.count

        await client.handleWebSocketMessage("""
        {"type":"refreshAwareness","documentId":"\(docId)","reason":"new_connection"}
        """)

        try await eventually(timeout: 5, description: "awareness re-broadcast") {
            server.receivedFrames.filter {
                $0.contains("\"awareness\"") && $0.contains(docId)
            }.count > before
        }
        let last = server.receivedFrames.last { $0.contains("\"awareness\"") && $0.contains(docId) }
        XCTAssertEqual(last?.contains(client.connectionId), true,
                       "the re-broadcast is keyed by connectionId, as in JS")
        XCTAssertEqual(last?.contains("swift"), true)
    }

    func testRefreshAwarenessWithoutLocalStateSendsNothing() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let docId = newDocId()
        try await makeLocalDocument(client, docId)

        await client.handleWebSocketMessage("""
        {"type":"refreshAwareness","documentId":"\(docId)","reason":"new_connection"}
        """)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(
            server.receivedFrames.contains { $0.contains("\"awareness\"") && $0.contains(docId) },
            "nothing to publish means no frame — JS logs and returns"
        )
    }
}
