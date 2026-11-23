import XCTest
@testable import JsBaoClient

/// The hold after a refusal (#6036): every automatic connect, whatever starts
/// it, opens no socket until a fetch releases the refusal; a connect the app
/// asks for itself is not held. The evidence is the loopback socket server's
/// connection count, not a client flag.
final class AppVersionConnectHoldHermeticTests: XCTestCase {

    private var world: AppVersionWorld!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        world = try AppVersionWorld(policy: AppVersionWorld.requiredPolicy)
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        world.stop()
    }

    private func track(_ client: JsBaoClient) -> JsBaoClient {
        clients.append(client)
        return client
    }

    /// A connected client whose socket the server then refused: held, with the
    /// app still wanting a connection.
    private func refusedClient(autoNetwork: Bool = false) async throws -> JsBaoClient {
        let client = track(world.client(autoNetwork: autoNetwork))
        await client.waitForStorageReady(timeout: 5)
        try await client.connect()
        try await eventually(description: "connected") { client.isConnected }
        world.closeWithRefusal(connection: world.ws.acceptedCount - 1)
        try await eventually(description: "refused") { client.appVersionController.isRefused && !client.isConnected }
        try await eventually(description: "the refusal fetch") { self.world.policyFetches >= 1 }
        return client
    }

    private func release(_ client: JsBaoClient) async {
        world.setPolicy(AppVersionWorld.currentPolicy)
        _ = await client.appVersion.refresh()
        XCTAssertFalse(client.appVersionController.isRefused)
    }

    // MARK: - Behavior 39: the manager's connect decision

    private final class HoldingDelegate: WebSocketManagerDelegate, @unchecked Sendable {
        let url: URL
        init(url: URL) { self.url = url }
        func webSocketManagerHasAccessToken() -> Bool { true }
        func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String]) { (url, [:]) }
        func webSocketManagerOnStatusChange(_ status: ConnectionStatus) {}
        func webSocketManagerOnConnecting() {}
        func webSocketManagerOnConnected() {}
        func webSocketManagerOnMessage(_ data: Data) async {}
        func webSocketManagerOnMessage(_ text: String) async {}
        func webSocketManagerOnClose(code: Int?, reason: String?) {}
        func webSocketManagerOnError(_ error: Error) {}
        func webSocketManagerOnReconnectScheduled(delayMs: Int) {}
        func webSocketManagerOnDisconnectInitiated() {}
        func webSocketManagerOnDisconnectResolved() {}
        func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool { false }
        func webSocketManagerAutomaticConnectHeld() -> Bool { true }
    }

    func testTheManagerHoldsAutomaticConnectsAndNotCallerOnes() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = HoldingDelegate(url: url)
        let manager = WebSocketManager(logger: Logger(level: .none, scope: "hold"), maxReconnectDelayMs: 1000)
        manager.delegate = delegate

        try await manager.connect()
        await manager.setDesiredConnection(shouldConnect: false)
        await manager.setDesiredConnection(shouldConnect: true)
        let desired = await manager.desiredConnection
        XCTAssertTrue(desired, "the wish is still recorded")
        await manager.forceReconnect()
        try await delay(0.5)
        XCTAssertEqual(server.acceptedCount, 0, "no automatic connect opens a socket")

        try await manager.connect(origin: .caller)
        try await eventually(description: "connect(origin: .caller)") { server.acceptedCount == 1 }
        await manager.disconnect()
        await manager.setDesiredConnection(shouldConnect: true, origin: .caller)
        try await eventually(description: "setDesiredConnection(origin: .caller)") { server.acceptedCount == 2 }
        await manager.disconnect()
        await manager.forceReconnect(origin: .caller)
        try await eventually(description: "forceReconnect(origin: .caller)") { server.acceptedCount == 3 }
        await manager.disconnect()
    }

    // MARK: - Behavior 40: an armed reconnect timer

    func testA426WhileAReconnectTimerIsArmedOpensNoSocket() async throws {
        let client = track(world.client())
        try await client.connect()
        world.ws.close(connection: 0)
        try await eventually(description: "the ordinary close lands") { !client.isConnected }
        await world.refuse(client)
        XCTAssertTrue(client.appVersionController.isRefused)
        try await delay(2.5)
        XCTAssertEqual(world.ws.acceptedCount, 1, "the timer fired into the hold")
    }

    // MARK: - Behavior 41: a token applied

    func testATokenAppliedWhileRefusedOpensNoSocketUntilTheRelease() async throws {
        let client = track(world.client(token: nil, autoNetwork: true))
        await client.waitForStorageReady(timeout: 5)
        try await delay(0.3)
        await world.refuse(client)
        XCTAssertTrue(client.appVersionController.isRefused)

        client.updateToken(makeTestJwt(userId: "first"))
        try await delay(0.8)
        XCTAssertEqual(world.ws.acceptedCount, 0, "a token where there was none")
        client.updateToken(makeTestJwt(userId: "first", exp: 9_999_999_000))
        try await delay(0.8)
        XCTAssertEqual(world.ws.acceptedCount, 0, "a token replacing another")

        await release(client)
        try await eventually(timeout: 5, description: "the release connects") {
            self.world.ws.acceptedCount == 1 && client.isConnected
        }
    }

    // MARK: - Behavior 42: reachability and online mode

    func testAReachabilityRestoreAndGoingOnlineOpenNoSocketUntilTheRelease() async throws {
        let client = try await refusedClient(autoNetwork: true)
        let accepted = world.ws.acceptedCount

        client.applyReachability(false, reason: "test")
        try await delay(0.3)
        client.applyReachability(true, reason: "test")
        try await delay(0.8)
        XCTAssertEqual(world.ws.acceptedCount, accepted, "a reachability restore")

        client.setNetworkMode(.offline)
        try await delay(0.2)
        client.setNetworkMode(.online)
        try await delay(0.8)
        XCTAssertEqual(world.ws.acceptedCount, accepted, "going back online")

        await release(client)
        try await eventually(timeout: 5, description: "the release connects") {
            self.world.ws.acceptedCount == accepted + 1 && client.isConnected
        }
    }

    // MARK: - Behavior 43: a channel join and a document open

    /// Marked deprecated because it calls the deprecated `openDocument`: the
    /// hold must cover that open while the member still answers.
    @available(*, deprecated)
    func testAChannelJoinAndADocumentOpenOnAClosedSocketOpenNoSocket() async throws {
        let client = try await refusedClient()
        let accepted = world.ws.acceptedCount
        client.channelSubscribeAckTimeoutForTest = 0.5
        _ = try? await client.subscribeToChannel("room-1", grant: "grant")
        _ = try? await client.openDocument("doc-hold", options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true, availabilityWait: 1
        ))
        try await delay(0.5)
        XCTAssertEqual(world.ws.acceptedCount, accepted)
    }

    // MARK: - Behavior 44: only the app's own entry points pass the caller origin

    func testTheCallerOriginIsPassedOnlyFromThePublicEntryPoints() throws {
        var total = 0
        for source in try ClientSourceText.allClientSources() {
            total += ClientSourceText.stripComments(source).components(separatedBy: "origin: .caller").count - 1
        }
        let client = try ClientSourceText.code("JsBaoClient.swift")
        var inEntryPoints = 0
        for (from, to) in [
            ("public func connect() async throws {", "\n    }\n"),
            ("public func setShouldConnect(_ shouldConnect: Bool) async {", "\n    }\n"),
            ("public func forceReconnectAsync() async {", "\n    }\n"),
        ] {
            let body = try ClientSourceText.slice(client, from: from, to: to)
            let count = body.components(separatedBy: "origin: .caller").count - 1
            XCTAssertEqual(count, 1, "\(from) passes the caller origin")
            inEntryPoints += count
        }
        XCTAssertEqual(total, inEntryPoints, "no other site passes the caller origin")
    }

    // MARK: - Edge: the stalled-sync rebuild is skipped while refused

    func testTheStalledSyncRebuildKeepsAnOpenSocketWhileRefused() async throws {
        let client = track(world.client())
        try await client.connect()
        await world.refuse(client)
        await client.rebuildConnectionForStalledSync("doc-stalled")
        try await delay(0.6)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(world.ws.acceptedCount, 1)
    }

    // MARK: - Edge: a changed user closes the socket and waits for the release

    func testAChangedUserWhileRefusedClosesTheSocketAndWaitsForTheRelease() async throws {
        let client = track(world.client())
        try await client.connect()
        await world.refuse(client)
        client.updateToken(makeTestJwt(userId: "someone-else"))
        try await eventually(description: "the old user's socket closes") { !client.isConnected }
        try await delay(1.0)
        XCTAssertEqual(world.ws.acceptedCount, 1, "no new socket while refused")

        await release(client)
        try await eventually(timeout: 5, description: "the release connects") {
            self.world.ws.acceptedCount == 2 && client.isConnected
        }
    }
}
