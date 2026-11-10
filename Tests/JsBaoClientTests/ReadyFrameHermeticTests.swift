import XCTest
@testable import JsBaoClient

/// #5578 — the Swift client reports `.connected` when the server's `ready`
/// frame arrives, not when the socket opens: the server registers the socket on
/// its user's channel behind the 101 and says `ready` once it has, so an app
/// that lists on `.connected` and applies events misses none. Port of the JS
/// cases in `tests/client/js-bao-client-ready-5578.test.ts`.
///
/// Server-free: the in-process `LoopbackWebSocketServer` with `sendsReady`
/// off holds each connection between its upgrade and the `ready` the test
/// pushes.
final class ReadyFrameHermeticTests: XCTestCase {

    private typealias RecordingDelegate = ActorizedWebSocketManagerTests.RecordingDelegate

    private static let ready = LoopbackWebSocketServer.readyFrame

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private func makeClient(
        wsUrl: String,
        userId: String = "user-ready",
        sync: SyncConfig = SyncConfig()
    ) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: "ready-hermetic",
            token: makeTestJwt(userId: userId),
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            sync: sync,
            autoNetwork: false
        ))
    }

    /// A `connect()` started in its own task, with its outcome readable.
    private final class Attempt: @unchecked Sendable {
        private let outcome = LockedBox<Result<Void, Error>?>(nil)
        let task: Task<Void, Never>

        init(_ connect: @escaping @Sendable () async throws -> Void) {
            let box = outcome
            task = Task {
                do {
                    try await connect()
                    box.value = .success(())
                } catch {
                    box.value = .failure(error)
                }
            }
        }

        var isSettled: Bool { outcome.value != nil }
        var succeeded: Bool { if case .success? = outcome.value { return true } else { return false } }
        var failure: Error? { if case .failure(let error)? = outcome.value { return error } else { return nil } }
    }

    /// The statuses a client emits, in order.
    private final class Statuses: @unchecked Sendable {
        private let box = LockedBox<[ConnectionStatus]>([])
        private var subscription: EventSubscription?

        init(_ client: JsBaoClient) {
            let box = self.box
            subscription = client.eventEmitter.subscribe(StatusChangedEvent.self) { event in
                box.withValue { $0.append(event.status) }
            }
        }

        var all: [ConnectionStatus] { box.value }
        func count(_ status: ConnectionStatus) -> Int { box.value.filter { $0 == status }.count }
        deinit { subscription?.cancel() }
    }

    /// Wait until the manager has handled the open of its `n`th socket: the
    /// pump reports each event on the way in, and the actor hop afterwards
    /// lands behind the step that applied it.
    private func waitForOpen(_ manager: WebSocketManager, _ log: HandledEventLog, count: Int = 1) async {
        let opened = await eventuallyTrue(timeout: 10) {
            log.events.filter { if case .opened = $0 { return true } else { return false } }.count >= count
        }
        XCTAssertTrue(opened, "socket \(count) opened")
        _ = await manager.isConnectedAsync
    }

    private func handledLog(_ manager: WebSocketManager) async -> HandledEventLog {
        let log = HandledEventLog()
        await manager.setEventHandledHookForTest { log.record($0) }
        return log
    }

    // MARK: - Behavior 11 — the manager connects on ready, not on open

    func testTheManagerStaysConnectingAtTheUpgradeAndConnectsOnceOnReady() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = WebSocketManager(
            logger: Logger(level: .none, scope: "ready-5578"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
        let log = await handledLog(manager)
        let attempt = Attempt { try await manager.connect() }

        await waitForOpen(manager, log)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.isConnected, "open is not connected")
        XCTAssertTrue(manager.isConnecting)
        XCTAssertEqual(manager.snapshot.task?.state, .running, "the socket is open")
        XCTAssertFalse(attempt.isSettled, "connect() waits for ready")
        XCTAssertEqual(delegate.countOf("status:connected"), 0)
        XCTAssertEqual(delegate.countOf("connected"), 0)

        XCTAssertTrue(server.push(Self.ready))
        let connected = await eventuallyTrue(timeout: 10) { attempt.isSettled }
        XCTAssertTrue(connected && attempt.succeeded, "connect() returns on ready")
        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(delegate.countOf("status:connected"), 1)
        XCTAssertEqual(delegate.countOf("connected"), 1)

        XCTAssertTrue(server.push(Self.ready))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(delegate.countOf("status:connected"), 1, "a second ready changes nothing")
        XCTAssertEqual(delegate.countOf("connected"), 1)
        XCTAssertEqual(delegate.countOf("message:text"), 0, "the manager consumes ready")

        await manager.disconnect()
    }

    // MARK: - Behavior 12 — the client reports connected on ready

    func testTheClientReportsConnectedOnceOnReady() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        let statuses = Statuses(client)
        let log = await handledLog(client.wsManager)
        let attempt = Attempt { try await client.connect() }

        await waitForOpen(client.wsManager, log)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(client.wsManager.connectionStatus, .connecting)
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(attempt.isSettled)
        XCTAssertEqual(statuses.count(.connected), 0)

        XCTAssertTrue(server.push(Self.ready))
        let settled = await eventuallyTrue(timeout: 10) { attempt.isSettled }
        XCTAssertTrue(settled && attempt.succeeded)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(client.wsManager.connectionStatus, .connected)
        let emitted = await eventuallyTrue(timeout: 5) { statuses.count(.connected) == 1 }
        XCTAssertTrue(emitted, "one StatusChangedEvent(.connected)")

        XCTAssertTrue(server.push(Self.ready))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(statuses.count(.connected), 1, "a second ready emits nothing")
    }

    // MARK: - Behavior 13 — a close before ready is a plain disconnect

    func testACloseBetweenOpenAndReadyIsAPlainDisconnectAndReconnects() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        let statuses = Statuses(client)
        let log = await handledLog(client.wsManager)
        let attempt = Attempt { try await client.connect() }

        await waitForOpen(client.wsManager, log)
        XCTAssertFalse(attempt.isSettled)
        server.close(connection: 0)

        let settled = await eventuallyTrue(timeout: 10) { attempt.isSettled }
        XCTAssertTrue(settled)
        XCTAssertNotNil(attempt.failure, "connect() throws the close")
        let disconnected = await eventuallyTrue(timeout: 5) { statuses.count(.disconnected) >= 1 }
        XCTAssertTrue(disconnected)
        XCTAssertEqual(statuses.count(.connected), 0)
        let recovery = try XCTUnwrap(Mirror(reflecting: client).descendant("wsAuthRecovery") as? WsAuthRecovery)
        XCTAssertTrue(recovery.handshakeCompletedAtClose(), "the handshake was accepted: no token refresh")

        // The reconnect loop owns the retry.
        let redialed = await eventuallyTrue(timeout: 10) { server.acceptedCount >= 2 }
        XCTAssertTrue(redialed, "a reconnect is scheduled")
    }

    // MARK: - Behavior 14 — the readiness deadline

    func testASocketWithNoReadyWithinTheHandshakeBudgetIsClosedAndRetried() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let client = makeClient(wsUrl: wsBase(url), sync: SyncConfig(handshakeTimeout: 1))
        defer { Task { await client.destroy() } }
        let statuses = Statuses(client)
        let log = await handledLog(client.wsManager)
        let started = Date()
        let attempt = Attempt { try await client.connect() }

        await waitForOpen(client.wsManager, log)
        let settled = await eventuallyTrue(timeout: 5) { attempt.isSettled }
        XCTAssertTrue(settled, "connect() settles within the budget")
        XCTAssertNotNil(attempt.failure, "connect() throws")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        let closed = await eventuallyTrue(timeout: 5) { server.isClosed(connection: 0) }
        XCTAssertTrue(closed, "the client closed the socket")
        let disconnected = await eventuallyTrue(timeout: 5) { statuses.count(.disconnected) >= 1 }
        XCTAssertTrue(disconnected)
        XCTAssertFalse(client.isConnected)

        // The reconnect is answered in time: its ready cancels the deadline.
        server.sendsReady = true
        let reconnected = await eventuallyTrue(timeout: 10) { client.isConnected }
        XCTAssertTrue(reconnected, "the reconnect loop retried")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(client.isConnected, "a ready in time cancels the deadline")
        XCTAssertFalse(server.isClosed(connection: 1))
    }

    func testDisconnectDuringTheWaitCancelsTheReadinessDeadline() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let client = makeClient(wsUrl: wsBase(url), sync: SyncConfig(handshakeTimeout: 1))
        defer { Task { await client.destroy() } }
        let statuses = Statuses(client)
        let log = await handledLog(client.wsManager)
        let attempt = Attempt { try await client.connect() }

        await waitForOpen(client.wsManager, log)
        XCTAssertFalse(attempt.isSettled)
        await client.disconnect()
        let settled = await eventuallyTrue(timeout: 5) { attempt.isSettled }
        XCTAssertTrue(settled)
        let seen = statuses.all.count

        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(statuses.all.count, seen, "nothing fires after the disconnect")
        XCTAssertEqual(server.acceptedCount, 1, "and nothing reconnects")
    }

    // MARK: - Behavior 15 — the open-time work waits for ready

    func testTheChannelResubscribeWaitsForReady() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let client = makeClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let join = Task { try await client.subscribeToChannel("orders:5578", grant: "grant-5578") }
        let sent = await eventuallyTrue(timeout: 10) {
            server.receivedFrames(onConnection: 0).contains { $0.contains("channel.subscribe") }
        }
        XCTAssertTrue(sent)
        XCTAssertTrue(server.push(#"{"type":"channel.subscribed","channel":"orders:5578","expiresAt":9999999999999}"#))
        _ = try await join.value

        // The next connection is held between its upgrade and its ready.
        server.sendsReady = false
        let log = await handledLog(client.wsManager)
        await client.forceReconnectAsync()
        await waitForOpen(client.wsManager, log)
        XCTAssertEqual(server.acceptedCount, 2)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.receivedFrames(onConnection: 1), [], "nothing is sent before ready")

        XCTAssertTrue(server.push(Self.ready, toConnection: 1))
        let resubscribed = await eventuallyTrue(timeout: 10) {
            server.receivedFrames(onConnection: 1).contains { $0.contains("channel.subscribe") && $0.contains("orders:5578") }
        }
        XCTAssertTrue(resubscribed, "the held grant is presented once ready arrives")
    }

    // MARK: - Behavior 16 — a ready from a socket the manager moved past

    func testAReadyOnTheSocketAForcedReconnectReplacedMarksNothing() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = WebSocketManager(
            logger: Logger(level: .none, scope: "ready-5578"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
        let log = await handledLog(manager)
        let attempt = Attempt { try await manager.connect() }
        await waitForOpen(manager, log)
        XCTAssertFalse(manager.isConnected)

        await manager.forceReconnect()
        await waitForOpen(manager, log, count: 2)
        XCTAssertEqual(server.acceptedCount, 2)
        server.push(Self.ready, toConnection: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.isConnected, "the replaced socket's ready marks nothing")
        XCTAssertEqual(delegate.countOf("connected"), 0)

        let retry = Attempt { try await manager.connect() }
        XCTAssertTrue(server.push(Self.ready, toConnection: 1))
        let connected = await eventuallyTrue(timeout: 10) { retry.isSettled }
        XCTAssertTrue(connected && retry.succeeded, "the current socket's ready connects")
        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(delegate.countOf("connected"), 1)
        _ = attempt
        await manager.disconnect()
    }

    /// The same filter, driven through the channel: a `ready` tagged with the
    /// replaced task, delivered while the replacement waits for its own, marks
    /// nothing; the sentinel behind it proves the pump handled it.
    func testAReadyTaggedWithAReplacedTaskChangesNothing() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = WebSocketManager(
            logger: Logger(level: .none, scope: "ready-5578"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
        let log = await handledLog(manager)
        let first = Attempt { try await manager.connect() }
        await waitForOpen(manager, log)
        let replaced = try XCTUnwrap(manager.snapshot.task)

        await manager.forceReconnect()
        await waitForOpen(manager, log, count: 2)
        let retry = Attempt { try await manager.connect() }
        let sentinelCode = 4578
        let stranger = NSObject()
        manager.emit(.ready(task: ObjectIdentifier(replaced)))
        manager.emit(.closed(task: ObjectIdentifier(stranger), code: sentinelCode, reason: nil))
        let observed = await eventuallyTrue(timeout: 10) { log.sawSentinel(code: sentinelCode) }
        XCTAssertTrue(observed)
        _ = await manager.isConnectedAsync
        XCTAssertFalse(manager.isConnected, "a ready from the replaced task")
        XCTAssertFalse(retry.isSettled, "connect() still waits for the current task's ready")
        XCTAssertEqual(delegate.countOf("connected"), 0)

        let current = try XCTUnwrap(manager.snapshot.task)
        manager.emit(.ready(task: ObjectIdentifier(current)))
        let connected = await eventuallyTrue(timeout: 10) { retry.isSettled }
        XCTAssertTrue(connected && retry.succeeded)
        XCTAssertEqual(delegate.countOf("connected"), 1)
        _ = first
        await manager.disconnect()
    }

    /// A `ready` already queued when the manager starts closing its socket —
    /// the readiness deadline's close, a forced reconnect — is handled while
    /// that task is still current, ahead of its close callback, and marks
    /// nothing.
    func testAReadyQueuedBehindALocalCloseMarksNothing() async throws {
        for closing in ["readyTimeout", "forceReconnect"] {
            let server = try LoopbackWebSocketServer(sendsReady: false)
            let url = try server.start()
            defer { server.stop() }
            let delegate = RecordingDelegate(url: url)
            let manager = WebSocketManager(
                logger: Logger(level: .none, scope: "ready-5578"),
                maxReconnectDelayMs: 1000,
                delegate: delegate
            )
            let log = await handledLog(manager)
            let attempt = Attempt { try await manager.connect() }
            await waitForOpen(manager, log)
            let closed = try XCTUnwrap(manager.snapshot.task)

            if closing == "forceReconnect" {
                await manager.forceReconnect()
            } else {
                await manager.closeSocket(initiator: closing)
            }
            let sentinelCode = 4579
            manager.emit(.ready(task: ObjectIdentifier(closed)))
            manager.emit(.closed(task: ObjectIdentifier(NSObject()), code: sentinelCode, reason: nil))
            let observed = await eventuallyTrue(timeout: 10) { log.sawSentinel(code: sentinelCode) }
            XCTAssertTrue(observed, closing)
            _ = await manager.isConnectedAsync
            XCTAssertEqual(delegate.countOf("status:connected"), 0, "\(closing): the closing socket's ready marks nothing")
            XCTAssertEqual(delegate.countOf("connected"), 0, closing)
            let settled = await eventuallyTrue(timeout: 5) { attempt.isSettled }
            XCTAssertTrue(settled && !attempt.succeeded, "\(closing): connect() fails with the close")
            await manager.disconnect()
        }
    }

    /// The same for `disconnect()`: a `ready` queued in its decision region,
    /// before the socket's close lands, neither connects the manager nor
    /// returns the pending `connect()`.
    func testAReadyQueuedBehindDisconnectMarksNothing() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let managerBox = LockedBox<WebSocketManager?>(nil)
        let delegate = RecordingDelegate(url: url, onDisconnectInitiated: {
            guard let manager = managerBox.value, let task = manager.snapshot.task else { return }
            manager.emit(.ready(task: ObjectIdentifier(task)))
        })
        let manager = WebSocketManager(
            logger: Logger(level: .none, scope: "ready-5578"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
        managerBox.value = manager
        let log = await handledLog(manager)
        let attempt = Attempt { try await manager.connect() }
        await waitForOpen(manager, log)

        await manager.disconnect()
        let readyHandled = log.events.contains { if case .ready = $0 { return true } else { return false } }
        XCTAssertTrue(readyHandled, "the queued ready reached the pump")
        let settled = await eventuallyTrue(timeout: 5) { attempt.isSettled }
        XCTAssertTrue(settled)
        XCTAssertFalse(attempt.succeeded, "connect() does not return after disconnect() began")
        XCTAssertEqual(delegate.countOf("status:connected"), 0)
        XCTAssertEqual(delegate.countOf("connected"), 0)
        XCTAssertFalse(manager.isConnected)
        managerBox.value = nil
    }

    /// A replaced socket's readiness deadline never closes its replacement.
    func testTheDeadlineOfAReplacedSocketDoesNothing() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = WebSocketManager(
            logger: Logger(level: .none, scope: "ready-5578"),
            maxReconnectDelayMs: 1000,
            readyTimeoutMs: 800,
            delegate: delegate
        )
        let log = await handledLog(manager)
        let first = Attempt { try await manager.connect() }
        await waitForOpen(manager, log)
        try await Task.sleep(nanoseconds: 400_000_000)

        await manager.forceReconnect()
        await waitForOpen(manager, log, count: 2)
        let retry = Attempt { try await manager.connect() }
        XCTAssertTrue(server.push(Self.ready, toConnection: 1))
        let connected = await eventuallyTrue(timeout: 10) { retry.isSettled }
        XCTAssertTrue(connected && retry.succeeded)

        // Past the first socket's deadline, and the second's.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(manager.isConnected)
        XCTAssertFalse(server.isClosed(connection: 1), "the replacement stays open")
        XCTAssertEqual(server.acceptedCount, 2)
        _ = first
        await manager.disconnect()
    }

    // MARK: - Behavior 18 — an account switch during the wait rebuilds

    func testATokenForAnotherUserAppliedBeforeReadyRebuildsTheSocket() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let client = makeClient(wsUrl: wsBase(url), userId: "user-first")
        defer { Task { await client.destroy() } }
        let log = await handledLog(client.wsManager)
        let first = Attempt { try await client.connect() }

        await waitForOpen(client.wsManager, log)
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.wsManager.snapshot.task?.state, .running, "open, awaiting ready")
        XCTAssertFalse(first.isSettled)

        let switched = makeTestJwt(userId: "user-second")
        client.updateToken(switched, cause: "test")
        let rebuilt = await eventuallyTrue(timeout: 10) { server.acceptedCount >= 2 }
        XCTAssertTrue(rebuilt, "a second upgrade")
        let firstClosed = await eventuallyTrue(timeout: 5) { server.isClosed(connection: 0) }
        XCTAssertTrue(firstClosed, "the first connection is closed")
        await waitForOpen(client.wsManager, log, count: 2)
        let request = try XCTUnwrap(client.wsManager.snapshot.task?.originalRequest?.url)
        let token = URLComponents(url: request, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        XCTAssertEqual(token, switched, "the second upgrade carries the new token")

        let second = Attempt { try await client.connect() }
        XCTAssertTrue(server.push(Self.ready, toConnection: 1))
        let connected = await eventuallyTrue(timeout: 10) { second.isSettled }
        XCTAssertTrue(connected && second.succeeded, "connect() returns on the second connection's ready")
        XCTAssertTrue(client.isConnected)
    }
}
