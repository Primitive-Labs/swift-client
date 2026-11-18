import XCTest
@testable import JsBaoClient

/// A server refusal of an outdated client (#6036): an HTTP 426 with code
/// `CLIENT_UPDATE_REQUIRED`, or a socket close with code 4426, sets
/// `updateRequired` at once, starts a fetch, and holds automatic reconnects
/// until a later fetch moves the status off `updateRequired`.
final class AppVersionRefusalHermeticTests: XCTestCase {

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

    private func client(appVersion: String? = "2.0", bundleVersion: (@Sendable () -> Any?)? = nil) -> JsBaoClient {
        let client = world.client(appVersion: appVersion, bundleVersion: bundleVersion)
        clients.append(client)
        return client
    }

    private func connectedClient() async throws -> JsBaoClient {
        let client = client()
        try await client.connect()
        XCTAssertTrue(client.isConnected)
        return client
    }

    // MARK: - Behavior 21

    func testA426OnAClientThatNeverAskedSetsUpdateRequiredAndStartsOneFetch() async throws {
        world.setPolicy(AppVersionWorld.requiredPolicy)
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        XCTAssertEqual(client.appVersionController.reportedStatus, .unknown)

        await world.refuse(client)
        XCTAssertTrue(client.appVersionController.isRefused)
        XCTAssertEqual(client.appVersionController.reportedStatus, .updateRequired, "at once, without an ask")
        try await eventually(description: "the refusal fetches") { self.world.policyFetches == 1 }
        try await delay(0.4)
        XCTAssertEqual(world.policyFetches, 1, "exactly one fetch")
        let awaited1 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited1, .updateRequired)
    }

    func testA426CallsSubscribers() async throws {
        world.setPolicy(AppVersionWorld.currentPolicy)
        let client = client()
        let awaited2 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited2, .current)
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }
        world.setPolicy(AppVersionWorld.requiredPolicy)
        await world.refuse(client)
        try await eventually(description: "the subscriber hears the refusal") {
            recorder.statuses.first == .updateRequired
        }
    }

    // MARK: - Behaviors 22 and 23

    func testA4426CloseSetsUpdateRequiredStartsOneFetchAndHoldsTheReconnect() async throws {
        let client = try await connectedClient()
        let closes = LockedBox<[Int?]>([])
        let sub = client.eventEmitter.subscribe(ConnectionCloseEvent.self) { event in closes.withValue { $0.append(event.code) } }
        defer { sub.cancel() }

        world.closeWithRefusal(connection: 0)
        try await eventually(description: "the close lands") { !closes.value.isEmpty }
        XCTAssertEqual(closes.value.first ?? nil, 4426, "the client sees the refusal code")
        XCTAssertTrue(client.appVersionController.isRefused)
        XCTAssertEqual(client.appVersionController.reportedStatus, .updateRequired)
        try await eventually(description: "the refusal fetches") { self.world.policyFetches == 1 }

        try await delay(2.0)
        XCTAssertEqual(world.policyFetches, 1, "exactly one fetch")
        XCTAssertEqual(world.ws.acceptedCount, 1, "no reconnect while the policy still requires an update")
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Behavior 24

    func testALaterFetchThatMovesTheStatusClearsTheRefusalAndReconnects() async throws {
        let client = try await connectedClient()
        world.closeWithRefusal(connection: 0)
        try await eventually(description: "refused") { client.appVersionController.isRefused }
        try await eventually(description: "the refusal fetches") { self.world.policyFetches == 1 }
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }
        try await delay(0.3)
        XCTAssertEqual(world.ws.acceptedCount, 1)

        world.setPolicy(AppVersionWorld.availablePolicy)
        let awaited3 = await client.appVersion.refresh()
        XCTAssertEqual(awaited3, .updateAvailable)
        XCTAssertFalse(client.appVersionController.isRefused)
        try await eventually(description: "the subscriber hears the release") { recorder.statuses.contains(.updateAvailable) }
        try await eventually(timeout: 5, description: "the socket reconnects") {
            self.world.ws.acceptedCount == 2 && client.isConnected
        }
    }

    func testTheReleaseReconnectsWhenTheWishWasSetWhileRefused() async throws {
        let client = try await connectedClient()
        world.closeWithRefusal(connection: 0)
        try await eventually(description: "refused") { client.appVersionController.isRefused }
        await client.wsManager.setDesiredConnection(shouldConnect: false)
        await client.wsManager.setDesiredConnection(shouldConnect: true)
        let desired = await client.wsManager.desiredConnection
        XCTAssertTrue(desired, "the wish is recorded while held")
        try await delay(0.5)
        XCTAssertEqual(world.ws.acceptedCount, 1, "held")

        world.setPolicy(AppVersionWorld.currentPolicy)
        _ = await client.appVersion.refresh()
        try await eventually(timeout: 5, description: "the socket reconnects") {
            self.world.ws.acceptedCount == 2 && client.isConnected
        }
    }

    // MARK: - Behavior 25

    private final class RecoveryHost: WsAuthRecoveryHost, @unchecked Sendable {
        private let lock = NSLock()
        private var refreshes = 0
        private var stops = 0
        private var failures = 0
        var counts: (refreshes: Int, stops: Int, failures: Int) { lock.withLock { (refreshes, stops, failures) } }
        func wsAuthRecoveryHasToken() -> Bool { true }
        func wsAuthRecoveryShouldConnect() async -> Bool { true }
        func wsAuthRecoveryIsConnectedOrConnecting() async -> Bool { false }
        func wsAuthRecoveryRefresh(cause: String) async -> RefreshOutcome {
            lock.withLock { refreshes += 1 }
            return .invalid
        }
        func wsAuthRecoveryReconnect() async {}
        func wsAuthRecoveryStopConnecting() async { lock.withLock { stops += 1 } }
        func wsAuthRecoveryEmitAuthFailed(reason: String, code: Int?, statusText: String?) { lock.withLock { failures += 1 } }
    }

    func testWsAuthRecoverySkipsA4426CloseBeforeAndAfterTheHandshake() async {
        XCTAssertEqual(WsAuthRecovery.updateRequiredCloseCode, 4426)
        for handshakeCompleted in [false, true] {
            let host = RecoveryHost()
            let policy = WsAuthRecovery(logger: Logger(level: .none, scope: "ws-auth-4426"))
            policy.noteConnecting()
            if handshakeCompleted { policy.noteConnected() }
            for _ in 0..<3 {
                await policy.handleClose(
                    code: 4426, reason: "update required",
                    handshakeCompletedAtClose: handshakeCompleted, deliberateClose: false, host: host
                )
            }
            XCTAssertEqual(host.counts.refreshes, 0, "no refresh (handshake \(handshakeCompleted))")
            XCTAssertEqual(host.counts.failures, 0, "no authFailed (handshake \(handshakeCompleted))")
            XCTAssertEqual(host.counts.stops, 0, "no stop (handshake \(handshakeCompleted))")
        }

        // Positive control: the same early close with another code is judged a handshake failure.
        let control = RecoveryHost()
        let policy = WsAuthRecovery(logger: Logger(level: .none, scope: "ws-auth-4426-control"))
        policy.noteConnecting()
        await policy.handleClose(code: 1006, reason: nil, handshakeCompletedAtClose: false, deliberateClose: false, host: control)
        XCTAssertEqual(control.counts.refreshes, 1)
    }

    // MARK: - Behavior 26

    func testAPolicyRequiringAnUpdateWithoutARefusalLeavesTheSocketAlone() async throws {
        let client = try await connectedClient()
        let awaited4 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited4, .updateRequired)
        XCTAssertFalse(client.appVersionController.isRefused)
        try await delay(0.3)
        XCTAssertTrue(client.isConnected, "the status alone does not close the socket")

        world.ws.close(connection: 0)
        try await eventually(timeout: 6, description: "an ordinary close reconnects") {
            self.world.ws.acceptedCount == 2 && client.isConnected
        }
    }

    // MARK: - Behavior 27

    func testRefusalFetchBackoff() {
        var backoff = RefusalFetchBackoff()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(backoff.delay(forRefusalAt: t0), 0, "the first refusal fetches at once")
        backoff.noteRelease(at: t0.addingTimeInterval(1))
        XCTAssertEqual(backoff.delay(forRefusalAt: t0.addingTimeInterval(11)), 5, "within 60 s of a release: 5 s")
        backoff.noteRelease(at: t0.addingTimeInterval(20))
        XCTAssertEqual(backoff.delay(forRefusalAt: t0.addingTimeInterval(21)), 10)
        var at = t0.addingTimeInterval(21)
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            at = at.addingTimeInterval(1)
            backoff.noteRelease(at: at)
            at = at.addingTimeInterval(1)
            delays.append(backoff.delay(forRefusalAt: at))
        }
        XCTAssertEqual(delays, [20, 40, 60, 60], "doubling, at most 60")
        backoff.noteRelease(at: at)
        XCTAssertEqual(backoff.delay(forRefusalAt: at.addingTimeInterval(61)), 0, "after a longer gap, at once")
        backoff.noteRelease(at: at.addingTimeInterval(62))
        XCTAssertEqual(backoff.delay(forRefusalAt: at.addingTimeInterval(63)), 5, "and the doubling starts over")
    }

    func testARefusalSoonAfterAReleaseDelaysItsFetch() async throws {
        world.setPolicy(AppVersionWorld.currentPolicy)
        let client = client()
        let clock = LockedBox(Date(timeIntervalSince1970: 2_000_000))
        client.appVersionController.setClockForTest { clock.value }
        await client.waitForStorageReady(timeout: 5)

        await world.refuse(client)
        XCTAssertEqual(client.appVersionController.lastRefusalFetchDelay, 0)
        try await eventually(description: "the first refusal's fetch releases it") {
            !client.appVersionController.isRefused
        }
        let fetches = world.policyFetches

        clock.value = clock.value.addingTimeInterval(10)
        await world.refuse(client)
        XCTAssertTrue(client.appVersionController.isRefused)
        XCTAssertEqual(client.appVersionController.lastRefusalFetchDelay, 5)
        try await delay(0.6)
        XCTAssertEqual(world.policyFetches, fetches, "the second refusal's fetch waits")
    }

    // MARK: - Behavior 29

    func testARefusalIsNotKeptAcrossLaunches() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        world.setPolicy(AppVersionWorld.currentPolicy)
        let first = world.client(storage: storage)
        let awaited5 = await first.appVersion.getStatus()
        XCTAssertEqual(awaited5, .current)
        world.setPolicy(AppVersionWorld.requiredPolicy)
        world.policyDelay.value = 1
        await world.refuse(first)
        XCTAssertTrue(first.appVersionController.isRefused)
        await first.destroy()
        world.policyDelay.value = 0
        world.setPolicy(AppVersionWorld.currentPolicy)

        let rebuilt = world.client(storage: storage)
        clients.append(rebuilt)
        XCTAssertFalse(rebuilt.appVersionController.isRefused)
        let awaited6 = await rebuilt.appVersion.getStatus()
        XCTAssertEqual(awaited6, .current)
        try await rebuilt.connect()
        XCTAssertTrue(rebuilt.isConnected)
        world.ws.close(connection: world.ws.acceptedCount - 1)
        try await eventually(timeout: 6, description: "it reconnects normally") {
            self.world.ws.acceptedCount >= 2 && rebuilt.isConnected
        }
    }

    // MARK: - Edge: only a 426 with the code is a refusal

    func testOnlyA426WithTheUpdateRequiredCodeIsARefusal() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        world.probe.value = .init(status: 426, body: #"{"error":"Upgrade","code":"SOMETHING_ELSE"}"#)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        world.probe.value = .init(status: 400, body: #"{"error":"x","code":"CLIENT_UPDATE_REQUIRED"}"#)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        try await delay(0.3)
        XCTAssertFalse(client.appVersionController.isRefused)
        XCTAssertEqual(world.policyFetches, 0)
    }

    // MARK: - Edge: a BlobManager direct request refuses as HttpClient does

    func testA426OnABlobDownloadSetsTheRefusal() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        world.probe.value = AppVersionWorld.refusal
        _ = try? await client.blobManager.read(documentId: "doc-1", blobId: "blob-1")
        XCTAssertTrue(client.appVersionController.isRefused)
    }

    func testA426OnASessionAttachmentSetsTheRefusal() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        world.probe.value = AppVersionWorld.refusal
        _ = try? await client.blobManager.readSessionAttachment(
            sessionId: "s", documentId: "doc-1", blobId: "blob-1", force: true, disposition: nil
        )
        XCTAssertTrue(client.appVersionController.isRefused)
    }

    // MARK: - Edge: a client with no version is still refused, and released

    func testARefusalOnAClientWithNoVersionIsReleasedByTheNextFetch() async throws {
        let client = client(appVersion: nil, bundleVersion: { nil })
        await client.waitForStorageReady(timeout: 5)
        world.policyDelay.value = 0.5
        await world.refuse(client)
        XCTAssertEqual(client.appVersionController.reportedStatus, .updateRequired)
        try await eventually(description: "the next fetch clears it") { !client.appVersionController.isRefused }
        XCTAssertEqual(client.appVersionController.reportedStatus, .unknown)
    }

    // MARK: - Edge: repeated refusals start no extra fetch

    func testRepeated426sWhileRefusedStartNoExtraFetch() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        for _ in 0..<4 { await world.refuse(client) }
        try await delay(0.5)
        XCTAssertEqual(world.policyFetches, 1)
        XCTAssertTrue(client.appVersionController.isRefused)
    }

    // MARK: - Edge: an explicit connect while refused is attempted

    func testAnExplicitConnectWhileRefusedIsAttempted() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        await world.refuse(client)
        try await eventually(description: "the refusal fetch") { self.world.policyFetches == 1 }

        try await client.connect()
        XCTAssertEqual(world.ws.acceptedCount, 1, "connect() is the app's own and is not held")
        world.closeWithRefusal(connection: 0)
        try await eventually(description: "the close lands") { !client.isConnected }
        await client.setShouldConnect(true)
        try await eventually(description: "setShouldConnect(true) is attempted") { self.world.ws.acceptedCount == 2 }
        world.closeWithRefusal(connection: 1)
        try await eventually(description: "the close lands") { !client.isConnected }
        await client.forceReconnectAsync()
        try await eventually(description: "forceReconnectAsync() is attempted") { self.world.ws.acceptedCount == 3 }
        try await eventually(description: "connected") { client.isConnected }
        // Each connect refetches, as any reconnect does once the client tracks
        // the policy; the refusal that follows adds none.
        try await delay(0.5)
        let beforeSecondRefusal = world.policyFetches
        world.closeWithRefusal(connection: 2)
        try await delay(0.5)
        XCTAssertTrue(client.appVersionController.isRefused, "still refused")
        XCTAssertEqual(world.policyFetches, beforeSecondRefusal, "an already refused client starts no new fetch")
    }

    // MARK: - Edge: a 426 while the socket is open

    func testA426WhileTheSocketIsOpenLeavesItOpenThenHoldsTheReconnect() async throws {
        let client = try await connectedClient()
        await world.refuse(client)
        try await delay(0.3)
        XCTAssertTrue(client.isConnected, "the refusal does not close an open socket")
        world.ws.close(connection: 0)
        try await delay(2.0)
        XCTAssertEqual(world.ws.acceptedCount, 1, "no reconnect after that socket closes")
    }

    // MARK: - Edge: a 4426 during a disconnect

    func testA4426CloseDuringADisconnectResolvesTheDisconnect() async throws {
        let client = try await connectedClient()
        let done = LockedBox(false)
        let disconnect = Task {
            await client.disconnect()
            done.value = true
        }
        world.closeWithRefusal(connection: 0)
        try await eventually(timeout: 3, description: "the disconnect resolves") { done.value }
        await disconnect.value
        XCTAssertFalse(client.isConnected)
    }
}
