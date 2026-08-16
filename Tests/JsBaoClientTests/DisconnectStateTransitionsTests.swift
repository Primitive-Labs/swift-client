import XCTest
@testable import JsBaoClient
import YSwift

/// Mirror of `tests/client/js-bao-client-disconnect-state-transitions.test.ts`
/// — the JS reference for #2663 (Swift↔JS parity items B1, B2, C6).
///
/// JS is the reference. Each test here asserts the same transition the JS test
/// of the same name asserts:
///
///   - every open document goes unsynced on a disconnect, with a
///     `SyncEvent(synced: false)`, and the reconnect produces the false→true
///     cycle;
///   - remote awareness is cleared when the transport closes, with an
///     `AwarenessEvent` naming the removed client IDs;
///   - the `.disconnected` status is emitted once at the initiation of a
///     deliberate `disconnect()`, and exactly once per close — the transport
///     manager owns the close-side emission, the client's close handler must
///     not emit a second one;
///   - `connect()` while `shouldConnect == false` is a no-op.
///
/// The two status tests drive the delegate callbacks directly rather than
/// through a socket: which callback emits the status is exactly what the bug
/// is about, and a live close fires them both within a millisecond of each
/// other, so only the split can distinguish the fix from the defect.
final class DisconnectStateTransitionsTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-disconnect-state-transitions")
    }

    override func tearDown() async throws {
        for client in clients {
            await client.destroy()
        }
        clients.removeAll()
        await ctx.cleanup()
    }

    // MARK: - Behaviors 1 & 2 — sync state false→true across a reconnect

    func testOpenDocumentsGoUnsyncedOnDisconnectAndResyncOnReconnect() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Unsync On Disconnect"
        )

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)
        XCTAssertTrue(client.isSynced(docId))

        let syncEvents = LockedBox<[(String, Bool)]>([])
        let sub = client.eventEmitter.subscribe(SyncEvent.self) { event in
            syncEvents.withValue { $0.append((event.documentId, event.synced)) }
        }
        defer { sub.cancel() }

        await client.disconnect()

        try await eventually(timeout: 5, description: "a sync event with synced:false") {
            syncEvents.value.contains { $0.0 == docId && $0.1 == false }
        }
        XCTAssertFalse(
            client.isSynced(docId),
            "an open document must not report itself synced while the transport is down"
        )

        // Reconnect completes the false→true cycle.
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 10)
        try await waitForSync(client: client, documentId: docId, timeout: 15)

        XCTAssertTrue(client.isSynced(docId))
        XCTAssertTrue(
            syncEvents.value.contains { $0.0 == docId && $0.1 == true },
            "the reconnect must emit synced:true, completing the cycle"
        )
    }

    // MARK: - Behavior 3 — remote awareness cleared on close

    func testRemoteAwarenessClearedOnClose() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Awareness Cleared On Close"
        )
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let observer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(observer)
        let peer = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(peer)

        try await observer.connect()
        try await waitForConnection(client: observer)
        try await peer.connect()
        try await waitForConnection(client: peer)

        _ = try await observer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        _ = try await peer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: observer, documentId: docId)
        try await waitForSync(client: peer, documentId: docId)

        peer.setAwareness(docId, state: ["user": ["name": "Peer"]])

        try await eventually(timeout: 10, description: "observer sees the peer's awareness") {
            !observer.getAwarenessStates(documentId: docId).isEmpty
        }
        let peerClientIds = Array(observer.getAwarenessStates(documentId: docId).keys)
        XCTAssertFalse(peerClientIds.isEmpty)

        let removals = LockedBox<[String]>([])
        let sub = observer.eventEmitter.subscribe(AwarenessEvent.self) { event in
            guard event.documentId == docId else { return }
            let removed = event.removed
            removals.withValue { $0.append(contentsOf: removed) }
        }
        defer { sub.cancel() }

        await observer.disconnect()

        try await eventually(timeout: 10, description: "an awareness removal for the peer") {
            peerClientIds.allSatisfy { removals.value.contains($0) }
        }
        XCTAssertTrue(
            observer.getAwarenessStates(documentId: docId).isEmpty,
            "remote presence must not survive the close — the peers are no longer there"
        )
    }

    /// The disconnect-timeout path: when no close callback arrives within the
    /// manager's 500ms window, the disconnect resolves on the timeout and the
    /// late close is dropped as stale, so the close handler never runs. That
    /// terminal point has to clear presence too, or peer cursors stay on
    /// screen for good.
    func testRemoteAwarenessClearedWhenTheDisconnectResolvesOnTimeout() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Awareness Cleared On Timeout"
        )
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let observer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(observer)
        let peer = createTestClient(appId: testApp.appId, token: user2.jwt)
        clients.append(peer)

        try await observer.connect()
        try await waitForConnection(client: observer)
        try await peer.connect()
        try await waitForConnection(client: peer)

        _ = try await observer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        _ = try await peer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: observer, documentId: docId)
        try await waitForSync(client: peer, documentId: docId)

        peer.setAwareness(docId, state: ["user": ["name": "Peer"]])
        try await eventually(timeout: 10, description: "observer sees the peer's awareness") {
            !observer.getAwarenessStates(documentId: docId).isEmpty
        }
        let peerClientIds = Array(observer.getAwarenessStates(documentId: docId).keys)

        let removals = LockedBox<[String]>([])
        let sub = observer.eventEmitter.subscribe(AwarenessEvent.self) { event in
            guard event.documentId == docId else { return }
            let removed = event.removed
            removals.withValue { $0.append(contentsOf: removed) }
        }
        defer { sub.cancel() }

        // The timeout path's terminal callback, driven directly — a socket
        // whose close never arrives cannot be arranged against a live server.
        observer.webSocketManagerOnDisconnectResolved()

        XCTAssertTrue(
            peerClientIds.allSatisfy { removals.value.contains($0) },
            "the disconnect-timeout path must clear presence too: \(removals.value)"
        )
        XCTAssertTrue(observer.getAwarenessStates(documentId: docId).isEmpty)
    }

    /// The re-arm in `testSignInAfterLogoutReconnects` runs on a detached
    /// task, so another token change can land between the sign-in event and
    /// the re-arm. An event carrying a token that is no longer the current one
    /// must not override the explicit disconnect that happened in between.
    func testStaleAuthEventDoesNotRearmTheConnection() async throws {
        let client = createTestClient(
            appId: testApp.appId, token: testApp.ownerJWT, autoNetwork: true
        )
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        await client.disconnect()
        try await delay(0.5)
        XCTAssertFalse(client.isConnected)

        // A sign-in event whose token is not the one the client now holds —
        // the shape a token change landing during the re-arm leaves behind.
        // The client still has a usable token, so an unguarded re-arm would
        // connect.
        client.eventEmitter.emit(AuthSuccessEvent(
            token: "stale-token-that-is-not-current", previousToken: nil, cause: "google"
        ))
        try await delay(3)

        XCTAssertFalse(
            client.isConnected,
            "a sign-in event for a token that is no longer current must not undo an explicit disconnect"
        )
    }

    // MARK: - Behavior 5 — the status is emitted at disconnect initiation

    func testDisconnectInitiationEmitsTheDisconnectedStatus() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)
        try await client.connect()
        try await waitForConnection(client: client)

        let statuses = LockedBox<[ConnectionStatus]>([])
        let sub = client.eventEmitter.subscribe(StatusChangedEvent.self) { event in
            statuses.withValue { $0.append(event.status) }
        }
        defer { sub.cancel() }

        client.webSocketManagerOnDisconnectInitiated()

        XCTAssertEqual(
            statuses.value.filter { $0 == .disconnected }.count, 1,
            "a deliberate disconnect must report .disconnected as it starts, not only once the socket closes"
        )
    }

    // MARK: - Behavior 4 — exactly one disconnected status per close

    func testCloseHandlerDoesNotEmitASecondDisconnectedStatus() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)
        try await client.connect()
        try await waitForConnection(client: client)

        let statuses = LockedBox<[ConnectionStatus]>([])
        let sub = client.eventEmitter.subscribe(StatusChangedEvent.self) { event in
            statuses.withValue { $0.append(event.status) }
        }
        defer { sub.cancel() }

        // The transport manager already emits one `.disconnected` per close
        // before it calls this. A second one here is the duplicate.
        client.webSocketManagerOnClose(code: 1006, reason: nil)

        XCTAssertEqual(
            statuses.value.filter { $0 == .disconnected }.count, 0,
            "the close handler must not emit its own status — the manager emits exactly one per close"
        )
    }

    // MARK: - Behavior 6 — connect() is a no-op while shouldConnect is false

    func testConnectIsANoOpWhileShouldConnectIsFalse() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)
        XCTAssertTrue(client.isConnected)

        await client.disconnect()
        try await delay(0.5)
        XCTAssertFalse(client.isConnected)

        // connect() must not re-arm the connection an explicit disconnect took
        // down — JS returns immediately while shouldConnect is false.
        try await client.connect()
        try await delay(2)
        XCTAssertFalse(
            client.isConnected,
            "connect() must not override an explicit disconnect; setShouldConnect(true) is the way back"
        )

        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 10)
        XCTAssertTrue(client.isConnected)
    }

    /// The other half of behavior 6: with `connect()` no longer overriding
    /// `shouldConnect`, a sign-in after a `logout()` (which disconnects) has to
    /// re-arm the connection itself, or the user is signed in and permanently
    /// offline. JS re-enables it on the same no-token → token transition.
    func testSignInAfterLogoutReconnects() async throws {
        // `autoNetwork: true` — the connect from here is gated the same way the
        // init auto-connect is, so this is the client shape it applies to.
        let client = createTestClient(
            appId: testApp.appId, token: testApp.ownerJWT, autoNetwork: true
        )
        clients.append(client)

        try await client.connect()
        try await waitForConnection(client: client)

        // logout() clears the token and disconnects, so shouldConnect is false.
        try await client.logout()
        try await delay(0.5)
        XCTAssertFalse(client.isConnected)

        // A fresh interactive sign-in applies a token where there was none.
        client.authController.applyToken(testApp.ownerJWT, previous: nil, cause: "google")

        try await waitForConnection(client: client, timeout: 15)
        XCTAssertTrue(
            client.isConnected,
            "signing in after a logout must reconnect, not leave the client offline"
        )
    }
}
