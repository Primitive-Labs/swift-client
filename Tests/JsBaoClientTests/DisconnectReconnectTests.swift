import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-disconnect-reconnect.test.ts
/// Tests disconnect/reconnect stress scenarios.
final class DisconnectReconnectTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-disconnect-reconnect")
    }

    override func tearDown() async throws {
        for client in clients {
            await client.destroy()
        }
        clients.removeAll()
        await ctx.cleanup()
    }

    func testDisconnectAndReconnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)
        XCTAssertTrue(client.isConnected)

        // Disconnect
        await client.disconnect()
        try await delay(0.5)
        XCTAssertFalse(client.isConnected)

        // Reconnect. `connect()` is a no-op while shouldConnect is false
        // (#2663); setShouldConnect(true) is how an explicit disconnect is undone.
        await client.setShouldConnect(true)
        try await waitForConnection(client: client)
        XCTAssertTrue(client.isConnected)
    }

    func testReconnectResyncsDocuments() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Reconnect Sync Test")

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Write data
        let writeMap: YMap<String> = ydoc.getOrCreateMap(named: "document")
        try client.transactAndSync(docId) { txn in
            writeMap.updateValue("before disconnect", forKey: "state", transaction: txn)
        }
        try await delay(1)

        // Disconnect
        await client.disconnect()
        try await delay(1)

        // Reconnect (see #2663: connect() no longer overrides shouldConnect)
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 10)

        // Wait for re-sync
        try await waitForSync(client: client, documentId: docId, timeout: 10)

        // Data should still be there
        let readMap: YMap<String> = ydoc.getOrCreateMap(named: "document")
        try await eventually(timeout: 5, description: "data visible after reconnect") {
            return readMap.containsKey("state")
        }
        let value = ydoc.transactSync { txn -> String? in
            return readMap.get(key: "state", transaction: txn)
        }
        XCTAssertEqual(value, "before disconnect")
    }

    func testMultipleRapidDisconnectReconnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        // Rapid disconnect/reconnect cycles
        for _ in 0..<3 {
            await client.disconnect()
            try await delay(0.3)
            await client.setShouldConnect(true)
            try await delay(0.5)
        }

        // Wait for final connection
        try await waitForConnection(client: client, timeout: 10)
        XCTAssertTrue(client.isConnected)
    }

    func testShouldConnectToggle() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        // Disable reconnection
        await client.setShouldConnect(false)
        try await delay(1)

        // Re-enable reconnection
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 10)
    }

    func testForceReconnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        // Force reconnect
        await client.forceReconnectAsync()
        try await delay(2)

        // Should be reconnected
        try await waitForConnection(client: client, timeout: 10)
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - Documents remain open after disconnect

    // Skipped: Reading Y.Doc after disconnect triggers a native crash in YSwift/yrs.
    // The underlying issue is that transactSync on a doc whose provider was torn down
    // causes a use-after-free in the Rust FFI layer (signal 5 / SIGTRAP).
    //
    // The previous incarnation of this test used a `SKIP_test*` name prefix so
    // XCTest never discovered it — meaning when the YSwift FFI fix lands,
    // nobody would notice that the regression coverage was still off. Renamed
    // to the real `test*` name and gated with `XCTSkip` so the suite reports
    // a documented skip the operator can grep for.
    func testDocumentsRemainOpenAfterDisconnect() async throws {
        throw XCTSkip(
            "Disabled until YSwift FFI use-after-free on post-disconnect " +
            "transactSync is fixed. Re-enable when the Rust FFI layer no " +
            "longer signal-traps on a torn-down provider read."
        )
        // The body below is intentionally unreachable but preserved so the
        // assertions don't bit-rot — when the FFI fix lands, delete the
        // XCTSkip and the test runs as-is.
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Remain Open Test")

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Write data before disconnect
        let map: YMap<String> = ydoc.getOrCreateMap(named: "data")
        try client.transactAndSync(docId) { txn in
            map.updateValue("hello", forKey: "key1", transaction: txn)
        }
        try await delay(1)

        // Disconnect
        await client.disconnect()
        try await delay(0.5)
        XCTAssertFalse(client.isConnected)

        // Document should still be accessible (locally) -- the YDoc reference is still valid
        let readMap: YMap<String> = ydoc.getOrCreateMap(named: "data")
        let value = ydoc.transactSync { txn -> String? in
            guard readMap.containsKey("key1") else { return nil }
            return readMap.get(key: "key1", transaction: txn)
        }
        XCTAssertEqual(value, "hello", "Document data should persist locally after disconnect")
    }

    // MARK: - Sync state resets on disconnect

    func testSyncStateResetsOnDisconnect() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Sync Reset Test")

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Confirm synced
        XCTAssertTrue(client.isSynced(docId))

        // Disconnect -- sync state should reset
        await client.disconnect()
        try await delay(1)

        // Re-enabled by #2663: the disconnect now resets every open document's
        // sync state, matching JS. The assertion was commented out while
        // `docSyncStates` stuck at true through a disconnect.
        XCTAssertFalse(client.isSynced(docId), "Sync state should reset after disconnect")
    }

    // MARK: - Queued updates sent after reconnect

    func testQueuedUpdatesSentAfterReconnect() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Queued Updates Test")

        // Create a second user to observe
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let writer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(writer)

        let observer = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(observer)

        // Connect both sequentially
        try await writer.connect()
        try await waitForConnection(client: writer)

        try await observer.connect()
        try await waitForConnection(client: observer)

        let writerDoc = try await writer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: writer, documentId: docId)

        let observerDoc = try await observer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: observer, documentId: docId)

        // Write initial data
        let wMap: YMap<String> = writerDoc.getOrCreateMap(named: "data")
        try writer.transactAndSync(docId) { txn in
            wMap.updateValue("before", forKey: "connected_update", transaction: txn)
        }
        try await delay(1)

        // Disconnect writer
        await writer.disconnect()
        try await delay(0.5)

        // Make updates while disconnected
        try writer.transactAndSync(docId) { txn in
            wMap.updateValue("offline_1", forKey: "offline_update_1", transaction: txn)
        }
        try writer.transactAndSync(docId) { txn in
            wMap.updateValue("offline_2", forKey: "offline_update_2", transaction: txn)
        }

        // Reconnect (see #2663: connect() no longer overrides shouldConnect)
        await writer.setShouldConnect(true)
        try await waitForConnection(client: writer, timeout: 10)
        try await waitForSync(client: writer, documentId: docId, timeout: 10)

        // Wait for updates to propagate to observer
        let oMap: YMap<String> = observerDoc.getOrCreateMap(named: "data")
        try await eventually(timeout: 10, description: "observer sees offline updates") {
            return oMap.containsKey("offline_update_1") && oMap.containsKey("offline_update_2")
        }

        XCTAssertEqual(oMap["offline_update_1"], "offline_1")
        XCTAssertEqual(oMap["offline_update_2"], "offline_2")
    }

    // MARK: - Brand new client sees existing data

    /// Ported from JS: "should handle brand new client connecting to document with existing data"
    func testBrandNewClientSeesExistingData() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Existing Data Test")

        // Client 1 writes data
        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client1)

        try await client1.connect()
        try await waitForConnection(client: client1)

        let ydoc1 = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        let map1: YMap<String> = ydoc1.getOrCreateMap(named: "existingData")
        for i in 0..<5 {
            try client1.transactAndSync(docId) { txn in
                map1.updateValue("value_\(i)", forKey: "key_\(i)", transaction: txn)
            }
        }
        try await delay(2)

        // Brand new client connects and should see all data
        let client2 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client2)

        try await client2.connect()
        try await waitForConnection(client: client2)

        let ydoc2 = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        let map2: YMap<String> = ydoc2.getOrCreateMap(named: "existingData")
        try await eventually(timeout: 10, description: "new client sees all existing data") {
            return (0..<5).allSatisfy { map2.containsKey("key_\($0)") }
        }

        for i in 0..<5 {
            XCTAssertEqual(map2["key_\(i)"], "value_\(i)", "New client should see key_\(i)")
        }
    }

    // MARK: - Connection status events during disconnect/reconnect cycle

    func testConnectionStatusEventsDuringCycle() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        var statusHistory: [ConnectionStatus] = []
        let sub = client.eventEmitter.subscribe(StatusChangedEvent.self) { e in
            statusHistory.append(e.status)
        }
        defer { sub.cancel() }

        // Connect
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(0.3)

        // Disconnect
        await client.disconnect()
        try await delay(1)

        // Reconnect. `connect()` is a no-op while shouldConnect is false
        // (#2663), so an explicit disconnect is undone with setShouldConnect.
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 10)
        try await delay(0.3)

        // Exact counts, tightened by #2663 from the tolerant >= form the
        // duplicate-status bug forced. One connected per successful connect,
        // and for the deliberate disconnect one status at initiation plus the
        // one the transport manager emits for the close.
        let connectedCount = statusHistory.filter { $0 == .connected }.count
        let disconnectedCount = statusHistory.filter { $0 == .disconnected }.count
        XCTAssertEqual(connectedCount, 2, "Expected exactly 2 connected events. History: \(statusHistory)")
        XCTAssertEqual(disconnectedCount, 2, "Expected exactly 2 disconnected events (initiation + close). History: \(statusHistory)")
    }

    // MARK: - Awareness re-established after reconnect

    func testAwarenessReestablishedAfterReconnect() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Awareness Reconnect Test")

        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let client1 = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client1)

        let client2 = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(client2)

        // Connect sequentially
        try await client1.connect()
        try await waitForConnection(client: client1)

        try await client2.connect()
        try await waitForConnection(client: client2)

        _ = try await client1.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client1, documentId: docId)

        _ = try await client2.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client2, documentId: docId)

        // Set awareness on client1
        client1.setAwareness(docId, state: ["user": ["name": "Client1"], "cursor": ["x": 10, "y": 20]])

        // Verify client2 receives awareness
        var receivedAwareness = false
        let sub = client2.eventEmitter.subscribe(AwarenessEvent.self) { event in
            if event.documentId == docId {
                receivedAwareness = true
            }
        }
        defer { sub.cancel() }

        try await eventually(timeout: 5, description: "initial awareness received") {
            return receivedAwareness
        }

        // Disconnect client1
        await client1.disconnect()
        try await delay(1)
        receivedAwareness = false

        // Reconnect client1 (see #2663: connect() no longer overrides shouldConnect)
        await client1.setShouldConnect(true)
        try await waitForConnection(client: client1, timeout: 10)
        try await waitForSync(client: client1, documentId: docId, timeout: 10)

        // Re-set awareness after reconnect.
        //
        // This stays a manual re-set even though the client now handles
        // `refreshAwareness` (#2661). The server only asks a document's
        // existing peers to republish when a connection *subscribes*
        // (`connection-worker.ts` `requestExistingAwarenessStates`), and
        // neither client sends a `subscribe` frame — the subscription is
        // implied by `syncStep1`. A reconnected client therefore has no
        // connection mapping for the document either, so nothing can be
        // routed to it: no `refreshAwareness` reaches this client here,
        // whatever it does with one. The handler itself is covered
        // server-free in `ServerPushFramesTests`.
        client1.setAwareness(docId, state: ["user": ["name": "Client1-Reconnected"], "cursor": ["x": 30, "y": 40]])

        // Verify client2 receives updated awareness
        try await eventually(timeout: 5, description: "awareness re-established after reconnect") {
            return receivedAwareness
        }
    }
}
