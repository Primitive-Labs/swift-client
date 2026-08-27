import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-events.test.ts
/// Tests document lifecycle events: documentLoaded, sync, documentClosed.
final class EventTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-events")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testEmitDocumentLoadedOnFirstSync() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Event Test Doc")

        var loadedEvents: [DocumentLoadedEvent] = []
        let sub = client.eventEmitter.subscribe(DocumentLoadedEvent.self) { e in
            loadedEvents.append(e)
        }

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Brief tick for event emission
        try await delay(0.2)

        let forDoc = loadedEvents.filter { $0.documentId == docId }
        XCTAssertGreaterThanOrEqual(forDoc.count, 1, "Expected at least one documentLoaded event")

        // Exactly one server-source event per open cycle, matching JS
        // (`tests/client/js-bao-client-events.test.ts`). This assertion used to
        // be a tolerant `>= 1`, which is what let the every-resync re-emission
        // go unnoticed (#2666).
        let serverEvents = forDoc.filter { $0.source == "server" }
        XCTAssertEqual(serverEvents.count, 1, "Expected exactly one server-source documentLoaded event")
        let serverEvent = serverEvents.first
        XCTAssertNotNil(serverEvent, "Expected a server-source documentLoaded event")
        XCTAssertEqual(serverEvent?.documentId, docId)
        XCTAssertGreaterThanOrEqual(serverEvent?.elapsedMs ?? -1, 0)

        sub.cancel()
    }

    func testEmitDocumentClosedOnClose() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        var closedEvents: [DocumentClosedEvent] = []
        let sub = client.eventEmitter.subscribe(DocumentClosedEvent.self) { e in
            closedEvents.append(e)
        }

        await client.closeDocument(docId)

        try await delay(0.2)

        let forDoc = closedEvents.filter { $0.documentId == docId }
        XCTAssertEqual(forDoc.count, 1, "Expected exactly one documentClosed event")

        sub.cancel()
    }

    func testEmitSyncEventOnDocumentSync() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        var syncEvents: [SyncEvent] = []
        let sub = client.eventEmitter.subscribe(SyncEvent.self) { e in
            syncEvents.append(e)
        }

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        try await delay(0.2)

        let forDoc = syncEvents.filter { $0.documentId == docId && $0.synced }
        XCTAssertGreaterThanOrEqual(forDoc.count, 1, "Expected at least one sync event with synced=true")

        sub.cancel()
    }

    /// `syncPerf` payload parity (#996): opening a doc with
    /// `requestSyncPerf: true` makes syncStep1 carry `requestPerf: true`,
    /// and the server replies with a `syncPerf` frame whose `timings` map
    /// (totalMs, reconstructMs, docHashMs, ...) is delivered verbatim —
    /// the same `{ documentId, timings, clientTimings? }` shape as JS.
    func testEmitSyncPerfWithServerTimingsWhenRequested() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "SyncPerf Test Doc")

        var perfEvents: [SyncPerfEvent] = []
        let sub = client.eventEmitter.subscribe(SyncPerfEvent.self) { e in
            perfEvents.append(e)
        }
        defer { sub.cancel() }

        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(waitForLoad: .network, requestSyncPerf: true)
        )
        try await waitForSync(client: client, documentId: docId)

        try await eventually(timeout: 5, description: "syncPerf event with server timings") {
            perfEvents.contains { $0.documentId == docId && !$0.timings.isEmpty }
        }

        let event = perfEvents.first { $0.documentId == docId && !$0.timings.isEmpty }
        XCTAssertNotNil(event)
        // `totalMs` is present on every server syncPerf payload variant
        // (both the already-in-sync and full-sync paths in yjs-room-v2).
        XCTAssertNotNil(event?.timings["totalMs"], "Expected server-provided totalMs in timings")
    }

    /// `syncPerf.clientTimings` parity (#1121): JS derives `clientTimings`
    /// from per-phase `getSyncTimings` instrumentation; Swift now mirrors
    /// that. With `requestSyncPerf: true`, the emitted event must carry a
    /// non-nil `clientTimings` map keyed with the JS field names
    /// (`clientTotalMs` is always present; the per-update phases
    /// `clientRoundTripMs` / `clientUpdateBytes` / `clientApplyMs` appear
    /// only when the server sends data). The internal `syncStep1SentAt`
    /// anchor must be stripped, exactly as JS does.
    func testSyncPerfClientTimingsPopulated() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "SyncPerf ClientTimings Doc")

        var perfEvents: [SyncPerfEvent] = []
        let sub = client.eventEmitter.subscribe(SyncPerfEvent.self) { e in
            perfEvents.append(e)
        }
        defer { sub.cancel() }

        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(waitForLoad: .network, requestSyncPerf: true)
        )
        try await waitForSync(client: client, documentId: docId)

        try await eventually(timeout: 5, description: "syncPerf event with client timings") {
            perfEvents.contains { $0.documentId == docId && $0.clientTimings != nil }
        }

        let event = perfEvents.first { $0.documentId == docId && $0.clientTimings != nil }
        XCTAssertNotNil(event, "Expected a syncPerf event with non-nil clientTimings")
        let clientTimings = try XCTUnwrap(event?.clientTimings)

        // Internal anchor must never leak into the emitted map (JS strips
        // `syncStep1SentAt` before assigning `data.clientTimings`).
        XCTAssertNil(clientTimings["syncStep1SentAt"], "syncStep1SentAt must be stripped before emit")

        // `clientTotalMs` is the one field set on every sync path
        // (syncComplete, or computed in the syncPerf handler when it
        // arrives first).
        XCTAssertNotNil(clientTimings["clientTotalMs"], "Expected clientTotalMs in clientTimings")

        // Every key must be one of the JS field names — no stray keys.
        let allowedKeys: Set<String> = [
            "clientRoundTripMs",
            "clientUpdateBytes",
            "clientApplyMs",
            "clientTotalMs",
        ]
        for key in clientTimings.keys {
            XCTAssertTrue(allowedKeys.contains(key), "Unexpected clientTimings key: \(key)")
        }
    }

    func testEmitStatusEvents() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        var statusEvents: [StatusChangedEvent] = []
        let sub = client.eventEmitter.subscribe(StatusChangedEvent.self) { e in
            statusEvents.append(e)
        }

        try await client.connect()
        try await waitForConnection(client: client)

        try await delay(0.5)

        // Should have received connecting and/or connected events
        let statuses = statusEvents.map { $0.status }
        XCTAssertTrue(statuses.contains(.connected), "Expected at least a 'connected' status event")

        sub.cancel()
    }

    func testEmitNetworkModeEvents() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        var networkEvents: [NetworkModeEvent] = []
        let sub = client.eventEmitter.subscribe(NetworkModeEvent.self) { e in
            networkEvents.append(e)
        }

        client.setNetworkMode(.offline)
        client.setNetworkMode(.online)

        try await delay(0.1)

        XCTAssertGreaterThanOrEqual(networkEvents.count, 2)
        XCTAssertEqual(networkEvents[0].mode, .offline)
        XCTAssertFalse(networkEvents[0].isOnline)
        XCTAssertEqual(networkEvents[1].mode, .online)
        XCTAssertTrue(networkEvents[1].isOnline)

        sub.cancel()
    }

    /// #854: `EventSubscription.init(cancel:)` must be public so app
    /// code (e.g. a `BaoDataLoader.custom` trigger wrapping
    /// `DynamicModel.subscribe()`) can construct one directly. Verifies
    /// the cancel closure runs exactly once across explicit
    /// `cancel()` + a redundant follow-up call.
    func testEventSubscriptionInitIsPublicAndCallsOnce() {
        var cancelCount = 0
        let sub = EventSubscription { cancelCount += 1 }
        XCTAssertEqual(cancelCount, 0)
        sub.cancel()
        XCTAssertEqual(cancelCount, 1)
        // Idempotent: a second cancel() is a no-op.
        sub.cancel()
        XCTAssertEqual(cancelCount, 1, "cancel() must be idempotent")
    }

    /// #1120: `.documentSyncStateChanged` (state "synced") is the supported,
    /// non-deprecated replacement for the deprecated Swift-only `.remoteUpdate`
    /// event. It must fire on the *reader* client when a *writer* client lands
    /// a remote update on the same document, so reload-on-remote-write loaders
    /// can migrate off `.remoteUpdate`. Mirrors the `.remoteUpdate` emit site:
    /// both fire from the same `"update"` WS frame.
    func testEmitDocumentSyncStateChangedOnRemoteUpdate() async throws {
        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await reader.destroy() } }
        let writer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await writer.destroy() } }

        try await reader.connect()
        try await waitForConnection(client: reader)
        try await writer.connect()
        try await waitForConnection(client: writer)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "SyncState Test Doc")

        // Reader opens and subscribes to the replacement event.
        _ = try await reader.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: reader, documentId: docId)

        let syncedStates = ThreadSafeBox<[String]>([])
        let sub = reader.eventEmitter.subscribe(DocumentSyncStateChangedEvent.self) { e in
            if e.documentId == docId {
                syncedStates.mutate { $0.append(e.state) }
            }
        }
        defer { sub.cancel() }

        // Writer opens the same doc and makes a change → the server fans an
        // `update` frame to the reader, which should emit a "synced" change.
        let writerDoc = try await writer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: writer, documentId: docId)

        let writerMap: YMap<String> = writerDoc.getOrCreateMap(named: "data")
        try writer.transactAndSync(docId) { txn in
            writerMap.updateValue("from-writer", forKey: "key", transaction: txn)
        }

        try await eventually(timeout: 5, description: ".documentSyncStateChanged (synced) on remote update") {
            syncedStates.value.contains("synced")
        }
        XCTAssertTrue(
            syncedStates.value.contains("synced"),
            "Expected a documentSyncStateChanged event with state == \"synced\" after a remote write"
        )
    }
}

/// Minimal thread-safe box for collecting event payloads from concurrent
/// event-emitter callbacks in tests.
final class ThreadSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&_value)
    }
}
