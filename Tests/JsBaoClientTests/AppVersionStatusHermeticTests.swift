import XCTest
@testable import JsBaoClient

/// `client.appVersion`: what a client reports, when it fetches the policy, how
/// the status follows a change, and what it keeps (#6036). Every request goes
/// to the in-process `AppVersionWorld`.
final class AppVersionStatusHermeticTests: XCTestCase {

    private var world: AppVersionWorld!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        world = try AppVersionWorld()
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        world.stop()
    }

    private func client(
        appVersion: String? = "2.0",
        storage: StorageConfig = .memory,
        storageSetupHold: (@Sendable () async -> Void)? = nil
    ) -> JsBaoClient {
        let client = world.client(appVersion: appVersion, storage: storage, storageSetupHold: storageSetupHold)
        clients.append(client)
        return client
    }

    // MARK: - Behavior 8

    func testVersionAndPlatformReportTheResolvedValues() {
        let client = client(appVersion: "3.1.4")
        XCTAssertEqual(client.appVersion.version, "3.1.4")
        XCTAssertEqual(client.appVersion.platform, "ios")
    }

    // MARK: - Behavior 9

    func testNoPolicyRequestBeforeTheFirstAskAndExactlyOneOnIt() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/me", body: nil, options: nil)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/documents", body: nil, options: nil)
        try await delay(0.5)
        XCTAssertEqual(world.policyFetches, 0, "no fetch before the first ask")
        XCTAssertGreaterThanOrEqual(world.api.requests.count, 2, "the other calls did reach the server")

        _ = await client.appVersion.getStatus()
        try await delay(0.3)
        XCTAssertEqual(world.policyFetches, 1, "the first ask fetches exactly once")
    }

    // MARK: - Behavior 10

    func testGetStatusAndGetPolicyReportFromTheFetchedPolicy() async {
        world.setPolicy(AppVersionWorld.requiredPolicy)
        let client = client()
        let status = await client.appVersion.getStatus()
        XCTAssertEqual(status, .updateRequired)
        let policy = await client.appVersion.getPolicy()
        XCTAssertEqual(policy, ClientPlatformVersions(
            latest: "4.0", minRecommended: "3.5", minRequired: "3.0", updateUrl: "itms-apps://example"
        ))
    }

    func testGetPolicyIsAlsoAnAsk() async throws {
        world.setPolicy(AppVersionWorld.availablePolicy)
        let client = client()
        let policy = await client.appVersion.getPolicy()
        XCTAssertEqual(policy?.latest, "2.5")
        XCTAssertEqual(world.policyFetches, 1)
    }

    // MARK: - Behavior 15

    func testThePolicyReadDoesNotRunTheRefreshInterceptor() async throws {
        let expiring = makeTestJwt(userId: "user-av", exp: Int(Date().timeIntervalSince1970) + 30)
        let client = world.client(token: expiring)
        clients.append(client)
        await client.waitForStorageReady(timeout: 5)
        let before = world.api.requests.filter { $0.apiPathOnly == "/auth/refresh" }.count
        _ = await client.appVersion.refresh()
        XCTAssertEqual(world.policyFetches, 1)
        let after = world.api.requests.filter { $0.apiPathOnly == "/auth/refresh" }.count
        XCTAssertEqual(after, before, "an expiring token must not make the policy read refresh it")
    }

    // MARK: - Behavior 16

    func testAfterTheFirstAskASocketReconnectStartsOneFetch() async throws {
        let client = client()
        _ = await client.appVersion.getStatus()
        XCTAssertEqual(world.policyFetches, 1)

        try await client.connect()
        try await eventually(description: "the connect refetches") { self.world.policyFetches == 2 }

        world.ws.close(connection: 0)
        try await eventually(timeout: 8, description: "the socket comes back") {
            self.world.ws.acceptedCount == 2 && client.isConnected
        }
        try await eventually(description: "the reconnect refetches") { self.world.policyFetches == 3 }
        try await delay(0.3)
        XCTAssertEqual(world.policyFetches, 3, "one fetch per reconnect")
    }

    func testAReconnectFetchWaitsTheDrawnShareOfTheJitter() async throws {
        XCTAssertEqual(AppVersionController.defaultReconnectJitter, 30)
        let client = client()
        client.appVersionController.reconnectJitter = 1.5
        client.appVersionController.setReconnectDrawForTest { 0.5 }
        _ = await client.appVersion.getStatus()
        XCTAssertEqual(world.policyFetches, 1)

        try await client.connect()
        try await delay(0.3)
        XCTAssertEqual(world.policyFetches, 1, "the fetch waits; it does not run at the connect")
        try await eventually(description: "the waiting fetch runs") { self.world.policyFetches == 2 }
    }

    func testAFetchThatStartsSoonerReplacesAReconnectsWaitingFetch() async throws {
        let client = client()
        client.appVersionController.reconnectJitter = 1.0
        client.appVersionController.setReconnectDrawForTest { 0.5 }
        _ = await client.appVersion.getStatus()
        try await client.connect()
        _ = await client.appVersion.refresh()
        XCTAssertEqual(world.policyFetches, 2)
        try await delay(1.0)
        XCTAssertEqual(world.policyFetches, 2, "the reconnect's own fetch was dropped")
    }

    func testDestroyDropsAReconnectsWaitingFetch() async throws {
        let client = client()
        client.appVersionController.reconnectJitter = 0.6
        client.appVersionController.setReconnectDrawForTest { 0.5 }
        _ = await client.appVersion.getStatus()
        try await client.connect()
        await client.destroy()
        try await delay(0.8)
        XCTAssertEqual(world.policyFetches, 1)
    }

    func testAReconnectBeforeAnyAskFetchesNothing() async throws {
        let client = client()
        try await client.connect()
        try await delay(0.5)
        XCTAssertEqual(world.policyFetches, 0)
    }

    // MARK: - Behavior 17

    func testAfterTheFirstAskAForegroundNotificationStartsOneFetch() async throws {
        let client = client()
        _ = await client.appVersion.getStatus()
        XCTAssertEqual(world.policyFetches, 1)

        NotificationCenter.default.post(name: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil)
        try await eventually(description: "the UIKit foreground refetches") { self.world.policyFetches == 2 }
        try await delay(0.2)

        NotificationCenter.default.post(name: Notification.Name("NSApplicationDidBecomeActiveNotification"), object: nil)
        try await eventually(description: "the macOS foreground refetches") { self.world.policyFetches == 3 }
        try await delay(0.2)
        XCTAssertEqual(world.policyFetches, 3)
    }

    func testAForegroundBeforeAnyAskFetchesNothing() async throws {
        let client = client()
        await client.waitForStorageReady(timeout: 5)
        NotificationCenter.default.post(name: Notification.Name("NSApplicationDidBecomeActiveNotification"), object: nil)
        try await delay(0.4)
        XCTAssertEqual(world.policyFetches, 0)
    }

    // MARK: - Behavior 18

    func testThePeriodicTimerFetchesEachInterval() async throws {
        XCTAssertEqual(AppVersionController.defaultPeriodicInterval, 3600)
        let client = client()
        client.appVersionController.periodicInterval = 0.3
        _ = await client.appVersion.getStatus()
        try await eventually(timeout: 5, description: "three periodic fetches") { self.world.policyFetches >= 4 }
    }

    // MARK: - Behavior 19

    func testRefreshFetchesAndReturnsTheNewStatus() async {
        let client = client()
        let first = await client.appVersion.getStatus()
        XCTAssertEqual(first, .current)
        world.setPolicy(AppVersionWorld.availablePolicy)
        let refreshed = await client.appVersion.refresh()
        XCTAssertEqual(refreshed, .updateAvailable)
        XCTAssertEqual(world.policyFetches, 2)
    }

    func testConcurrentFetchCausesShareOneRequest() async throws {
        let client = client()
        _ = await client.appVersion.getStatus()
        XCTAssertEqual(world.policyFetches, 1)

        world.setPolicy(AppVersionWorld.availablePolicy)
        world.policyDelay.value = 0.4
        async let a = client.appVersion.refresh()
        async let b = client.appVersion.refresh()
        async let c = client.appVersion.refresh()
        let statuses = await [a, b, c]
        XCTAssertEqual(statuses, [.updateAvailable, .updateAvailable, .updateAvailable])
        XCTAssertEqual(world.policyFetches, 2, "three causes in flight together share one request")
    }

    // MARK: - Behavior 20

    func testAHandlerIsCalledOncePerStatusChangeAndNotAfterCancel() async throws {
        let client = client()
        _ = await client.appVersion.getStatus()
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }

        _ = await client.appVersion.refresh()
        try await delay(0.1)
        XCTAssertEqual(recorder.statuses, [], "a fetch that leaves the status the same calls nobody")

        world.setPolicy(AppVersionWorld.availablePolicy)
        _ = await client.appVersion.refresh()
        try await eventually(description: "the change is reported") { recorder.statuses == [.updateAvailable] }
        _ = await client.appVersion.refresh()
        try await delay(0.1)
        XCTAssertEqual(recorder.statuses, [.updateAvailable], "once per change")

        subscription.cancel()
        world.setPolicy(AppVersionWorld.requiredPolicy)
        let after = await client.appVersion.refresh()
        XCTAssertEqual(after, .updateRequired)
        try await delay(0.1)
        XCTAssertEqual(recorder.statuses, [.updateAvailable], "nothing after the subscription is cancelled")
    }

    func testSubscribingIsAnAsk() async throws {
        world.setPolicy(AppVersionWorld.availablePolicy)
        let client = client()
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }
        try await eventually(description: "the subscriber hears the first status") {
            recorder.statuses == [.updateAvailable]
        }
        XCTAssertEqual(world.policyFetches, 1)
    }

    // MARK: - Behavior 28

    func testTheStoredPolicyIsReportedByAClientRebuiltWithTheServerStopped() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        world.setPolicy(AppVersionWorld.requiredPolicy)

        let first = world.client(storage: storage)
        let status = await first.appVersion.getStatus()
        let policy = await first.appVersion.getPolicy()
        XCTAssertEqual(status, .updateRequired)
        await first.destroy()

        world.stop()
        let rebuilt = world.client(storage: storage)
        clients.append(rebuilt)
        let rebuiltStatus = await rebuilt.appVersion.getStatus()
        let rebuiltPolicy = await rebuilt.appVersion.getPolicy()
        XCTAssertEqual(rebuiltStatus, .updateRequired)
        XCTAssertEqual(rebuiltPolicy, policy)
    }

    // MARK: - Behavior 30

    func testAFailedFetchChangesNothingAndNeverThrows() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        world.setPolicy(AppVersionWorld.availablePolicy)
        let client = world.client(storage: storage)
        clients.append(client)
        let awaited12 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited12, .updateAvailable)
        let stored = await client.offlineStore.loadClientVersions(appId: "app-version-hermetic")
        XCTAssertNotNil(stored)
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        world.policy.value = .status(500, "boom")
        let awaited13 = await client.appVersion.refresh()
        XCTAssertEqual(awaited13, .updateAvailable, "a 500")
        world.policy.value = .json("not json")
        let awaited14 = await client.appVersion.refresh()
        XCTAssertEqual(awaited14, .updateAvailable, "an undecodable body")
        world.policy.value = .json(AppVersionWorld.requiredPolicy)
        client.setNetworkMode(.offline)
        let awaited15 = await client.appVersion.refresh()
        XCTAssertEqual(awaited15, .updateAvailable, "offline")
        client.setNetworkMode(.online)
        world.stop()
        let awaited16 = await client.appVersion.refresh()
        XCTAssertEqual(awaited16, .updateAvailable, "the server stopped")
        let awaited17 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited17, .updateAvailable)

        try await delay(0.2)
        XCTAssertEqual(recorder.statuses, [], "no subscriber is called")
        let after = await client.offlineStore.loadClientVersions(appId: "app-version-hermetic")
        XCTAssertEqual(after, stored, "the stored policy is unchanged")
    }

    func testAFirstAskWhoseFetchFailsReportsUnknown() async {
        world.policy.value = .status(500, "boom")
        let client = client()
        let awaited18 = await client.appVersion.getStatus()
        XCTAssertEqual(awaited18, .unknown)
        let awaited19 = await client.appVersion.getPolicy()
        XCTAssertNil(awaited19)
    }

    // MARK: - Edge: the first ask waits for storage

    func testAFirstAskBeforeStorageIsReadyWaitsAndReadsTheStoredPolicy() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        world.setPolicy(AppVersionWorld.availablePolicy)
        let first = world.client(storage: storage)
        let awaited20 = await first.appVersion.getStatus()
        XCTAssertEqual(awaited20, .updateAvailable)
        await first.destroy()

        world.policy.value = .status(500, "down")
        let gate = AppVersionGate()
        let held = client(storage: storage, storageSetupHold: { await gate.wait() })
        let answer = LockedBox<AppVersionStatus?>(nil)
        let ask = Task { answer.value = await held.appVersion.getStatus() }
        try await delay(0.4)
        XCTAssertNil(answer.value, "the ask waits for storage")
        await gate.open()
        await ask.value
        XCTAssertEqual(answer.value, .updateAvailable, "and then reports from the stored policy")
    }

    // MARK: - Edge: memory storage keeps nothing for the next client

    func testWithMemoryStorageNothingIsKeptForTheNextClient() async {
        world.setPolicy(AppVersionWorld.availablePolicy)
        let first = client()
        let awaited21 = await first.appVersion.getStatus()
        XCTAssertEqual(awaited21, .updateAvailable)
        world.policy.value = .status(500, "down")
        let second = client()
        let awaited22 = await second.appVersion.getStatus()
        XCTAssertEqual(awaited22, .unknown)
    }

    // MARK: - Edge: destroy cancels the periodic task and an in-flight fetch

    func testDestroyStopsThePeriodicTask() async throws {
        let client = world.client()
        client.appVersionController.periodicInterval = 0.2
        _ = await client.appVersion.getStatus()
        await client.destroy()
        let atDestroy = world.policyFetches
        try await delay(0.8)
        XCTAssertEqual(world.policyFetches, atDestroy, "no request after destroy")
    }

    func testDestroyDuringAFetchCallsNoHandler() async throws {
        let client = world.client()
        let recorder = StatusRecorder()
        world.setPolicy(AppVersionWorld.availablePolicy)
        world.policyDelay.value = 0.5
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }
        try await eventually(description: "the fetch is in flight") { self.world.policyFetches == 1 }
        await client.destroy()
        try await delay(0.9)
        XCTAssertEqual(recorder.statuses, [], "no handler after destroy")
        XCTAssertEqual(world.policyFetches, 1)
    }

    func testAFetchWhoseClientIsDestroyedDuringDeliveryDoesNotOverwriteTheNextClientsPolicy() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The first client's fetch applies the required policy, then stops in
        // its subscriber's callback, before it writes the policy.
        world.setPolicy(AppVersionWorld.requiredPolicy)
        let first = world.client(storage: storage)
        let entered = LockedBox(false)
        let resume = DispatchSemaphore(value: 0)
        let subscription = first.appVersion.onStatusChange { _ in
            entered.value = true
            _ = resume.wait(timeout: .now() + 10)
        }
        defer { subscription.cancel() }
        try await eventually(description: "the first client's fetch is delivering") { entered.value }
        await first.destroy()

        // A replacement client on the same store saves a newer policy.
        world.setPolicy(AppVersionWorld.availablePolicy)
        let second = world.client(storage: storage)
        let secondStatus = await second.appVersion.getStatus()
        XCTAssertEqual(secondStatus, .updateAvailable)
        let saved = await second.offlineStore.loadClientVersions(appId: "app-version-hermetic")
        XCTAssertNotNil(saved)

        // The old fetch resumes after its client is gone.
        resume.signal()
        try await delay(0.5)
        await second.destroy()

        world.stop()
        let rebuilt = world.client(storage: storage)
        clients.append(rebuilt)
        let rebuiltStatus = await rebuilt.appVersion.getStatus()
        XCTAssertEqual(rebuiltStatus, .updateAvailable, "the destroyed client's fetch wrote nothing")
        let stored = await rebuilt.offlineStore.loadClientVersions(appId: "app-version-hermetic")
        XCTAssertEqual(stored, saved)
    }

    // MARK: - Edge: the stored policy survives a wiping logout

    func testTheStoredPolicySurvivesAWipingLogout() async throws {
        let (storage, dir) = appVersionTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        world.setPolicy(AppVersionWorld.requiredPolicy)
        let client = world.client(storage: storage)
        clients.append(client)
        _ = await client.appVersion.getStatus()
        let stored = await client.offlineStore.loadClientVersions(appId: "app-version-hermetic")
        XCTAssertNotNil(stored)
        try? await client.logout(wipeLocal: true)
        let after = await client.offlineStore.loadClientVersions(appId: "app-version-hermetic")
        XCTAssertEqual(after, stored)
    }

    // MARK: - Edge: a subscriber released by cancellation or destroy

    /// Subscribes a handler that holds the only reference to an owner of a
    /// second subscription, so releasing the handler cancels that second one.
    private func subscribeHoldingAnother(_ api: AppVersionAPI, ownerGone: LockedBox<Bool>) -> EventSubscription {
        let owner = SubscriptionOwner(api.onStatusChange { _ in }, gone: ownerGone)
        return api.onStatusChange { _ in _ = owner }
    }

    /// Runs `work` on another thread and reports whether it finished within
    /// `timeout`, so a deadlock fails the test instead of hanging it.
    private func finishesInTime(_ timeout: TimeInterval = 3, _ work: @escaping @Sendable () -> Void) async throws -> Bool {
        let done = LockedBox(false)
        DispatchQueue.global().async {
            work()
            done.value = true
        }
        try await eventually(timeout: timeout, description: "the call returns") { done.value }
        return done.value
    }

    func testCancellingASubscriptionWhoseHandlerOwnsAnotherDoesNotDeadlock() async throws {
        let client = world.client()
        let ownerGone = LockedBox(false)
        let subscription = subscribeHoldingAnother(client.appVersion, ownerGone: ownerGone)
        let returned = try await finishesInTime { subscription.cancel() }
        guard returned else { return XCTFail("cancel() deadlocked") }
        clients.append(client)
        XCTAssertTrue(ownerGone.value, "the handler, and the subscription its owner held, were released")
    }

    func testDestroyReleasingAHandlerThatOwnsASubscriptionDoesNotDeadlock() async throws {
        let client = world.client()
        let ownerGone = LockedBox(false)
        let subscription = subscribeHoldingAnother(client.appVersion, ownerGone: ownerGone)
        let controller = client.appVersionController
        let returned = try await finishesInTime { controller.destroy() }
        guard returned else { return XCTFail("destroy() deadlocked") }
        clients.append(client)
        XCTAssertTrue(ownerGone.value, "destroy released the handler")
        subscription.cancel()
    }

    // MARK: - Edge: changes reach subscribers in the order they were committed

    func testARefusalAndAReleasingFetchThatOverlapAreDeliveredInCommitOrder() async throws {
        let client = client()
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }
        try await eventually(description: "the first status") { recorder.statuses == [.current] }

        // Hold the refusal's thread after it has committed updateRequired and
        // before it delivers, while a fetch commits and delivers the release.
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let first = LockedBox(true)
        client.appVersionController.setBeforeDrainForTest {
            let isFirst = first.withValue { value -> Bool in defer { value = false }; return value }
            guard isFirst else { return }
            entered.signal()
            resume.wait()
        }
        let controller = client.appVersionController
        let refused = LockedBox(false)
        DispatchQueue.global().async {
            controller.noteRefusal()
            refused.value = true
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success, "the refusal committed")
        XCTAssertEqual(controller.reportedStatus, .updateRequired)

        let released = await client.appVersion.refresh()
        XCTAssertEqual(released, .current)
        resume.signal()
        try await eventually(description: "the refusal returns") { refused.value }
        controller.setBeforeDrainForTest(nil)
        try await delay(0.3)

        XCTAssertEqual(recorder.statuses, [.current, .updateRequired, .current], "delivered in commit order")
        XCTAssertEqual(controller.reportedStatus, .current)
        XCTAssertFalse(controller.isRefused)
    }
}

/// Holds an `EventSubscription`, which cancels itself when released, and
/// records its own release.
private final class SubscriptionOwner: @unchecked Sendable {
    private let subscription: EventSubscription
    private let gone: LockedBox<Bool>

    init(_ subscription: EventSubscription, gone: LockedBox<Bool>) {
        self.subscription = subscription
        self.gone = gone
    }

    deinit { gone.value = true }
}

/// A one-shot gate a test opens when it chooses.
actor AppVersionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
