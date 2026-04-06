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
        let sub = client.events.on(.documentLoaded) { (e: DocumentLoadedEvent) in
            loadedEvents.append(e)
        }

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Brief tick for event emission
        try await delay(0.2)

        let forDoc = loadedEvents.filter { $0.documentId == docId }
        XCTAssertGreaterThanOrEqual(forDoc.count, 1, "Expected at least one documentLoaded event")

        let serverEvent = forDoc.first { $0.source == "server" }
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
        let sub = client.events.on(.documentClosed) { (e: DocumentClosedEvent) in
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
        let sub = client.events.on(.sync) { (e: SyncEvent) in
            syncEvents.append(e)
        }

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        try await delay(0.2)

        let forDoc = syncEvents.filter { $0.documentId == docId && $0.synced }
        XCTAssertGreaterThanOrEqual(forDoc.count, 1, "Expected at least one sync event with synced=true")

        sub.cancel()
    }

    func testEmitStatusEvents() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        var statusEvents: [StatusChangedEvent] = []
        let sub = client.events.on(.status) { (e: StatusChangedEvent) in
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
        let sub = client.events.on(.networkMode) { (e: NetworkModeEvent) in
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
}
