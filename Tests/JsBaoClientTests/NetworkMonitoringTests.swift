import XCTest
import Network
@testable import JsBaoClient

/// Phase 2 (issue #1987): `NWPathMonitor`-driven automatic monitoring via the
/// internal `ConnectivityMonitor` seam. Driven by a `FakeConnectivityMonitor`
/// so no live network is needed; the one "restore actually connects" case uses
/// the in-process `LoopbackWebSocketServer`.
///
/// Invariant checked throughout: the monitor NEVER mutates `networkMode` — it
/// drives the internal `reachable` bit, which feeds `networkingAllowed()`.
final class NetworkMonitoringTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _n = 0
        func bump() { lock.withLock { _n += 1 } }
        var value: Int { lock.withLock { _n } }
    }

    /// Client with an injected fake monitor. `wsUrl` defaults to an unreachable
    /// address so a startup auto-connect can't accidentally succeed.
    private func makeClient(
        autoNetwork: Bool,
        monitor: FakeConnectivityMonitor,
        token: String? = "test-token",
        wsUrl: String = "ws://127.0.0.1:1",
        apiUrl: String = "http://127.0.0.1:1"
    ) -> JsBaoClient {
        JsBaoClient(
            options: JsBaoClientOptions(
                apiUrl: apiUrl,
                wsUrl: wsUrl,
                appId: "test-app",
                token: token,
                offline: false,
                logLevel: .error,
                storageConfig: .memory,
                autoNetwork: autoNetwork
            ),
            connectivityMonitor: monitor
        )
    }

    // MARK: - Behavior 6 — autoNetwork gates monitoring

    func testAutoNetworkTrueStartsMonitor() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3, description: "monitor started") {
            monitor.isStarted
        }
        XCTAssertEqual(monitor.startCount, 1)
    }

    func testAutoNetworkFalseStartsNoMonitor() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: false, monitor: monitor)
        defer { Task { await client.destroy() } }

        // Give setupStorage time to run; the monitor must never be started.
        try await delay(0.3)
        XCTAssertFalse(monitor.isStarted)
        XCTAssertEqual(monitor.startCount, 0)

        // A push has no effect (not wired): the gate stays open.
        monitor.push(false)
        try await delay(0.3)
        XCTAssertTrue(client.networkingAllowed())
    }

    // MARK: - Behavior 7 — loss pauses + suppresses reconnect, mode unchanged

    func testPathLostPausesAndSuppressesReconnect() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }
        monitor.push(false)

        try await eventually(timeout: 3, description: "gate closed after loss") {
            client.networkingAllowed() == false
        }
        // mode stays .auto; reconnect suppressed; reason recorded.
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertFalse(client.webSocketManagerShouldReconnect(code: 1006, reason: "abnormal"))
        XCTAssertEqual(client.networkStatus.reason, "connectivityLost")
    }

    // MARK: - Behavior 8 — restore runs the handoff and connects (with token)

    func testPathRestoreConnectsWithToken() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }
        // Seed a lost path first so startup does not auto-connect and so the
        // subsequent restore is a real transition (not deduped).
        monitor.push(false)
        try await eventually(timeout: 3) { client.networkingAllowed() == false }
        XCTAssertFalse(client.isConnected)

        // Restore → handoff (token present) → connect to the loopback socket.
        monitor.push(true)
        try await eventually(timeout: 5, description: "restore reconnects") {
            client.isConnected
        }
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertEqual(client.networkStatus.reason, "connectivityRestored")
    }

    // MARK: - Behavior 9 — restore without a token: authOnlineRequired, no revert

    func testPathRestoreWithoutTokenEmitsAuthRequiredAndKeepsAutoMode() async throws {
        let monitor = FakeConnectivityMonitor()
        // No token → the restore handoff's refresh fails.
        let client = makeClient(autoNetwork: true, monitor: monitor, token: nil)
        defer { Task { await client.destroy() } }

        let authRequired = Counter()
        let sub = client.eventEmitter.subscribe(AuthOnlineRequiredEvent.self) { _ in
            authRequired.bump()
        }
        defer { sub.cancel() }

        try await eventually(timeout: 3) { monitor.isStarted }
        monitor.push(false)
        try await eventually(timeout: 3) { client.networkingAllowed() == false }

        monitor.push(true)
        try await eventually(timeout: 5, description: "auth required emitted") {
            authRequired.value >= 1
        }
        // Mode stays .auto (NOT reverted to .offline); socket not connected.
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Behavior 10 — flapping within the window coalesces

    func testFlappingCoalescesToOneReaction() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor)
        defer { Task { await client.destroy() } }

        let connectivityEvents = Counter()
        let sub = client.eventEmitter.subscribe(NetworkModeEvent.self) { e in
            if e.reason == "connectivityLost" || e.reason == "connectivityRestored" {
                connectivityEvents.bump()
            }
        }
        defer { sub.cancel() }

        try await eventually(timeout: 3) { monitor.isStarted }

        // Rapid flap ending on `false` (different from the default `true`),
        // all within the debounce window — only the last survives.
        monitor.push(false)
        monitor.push(true)
        monitor.push(false)

        try await eventually(timeout: 3, description: "single coalesced reaction") {
            client.networkingAllowed() == false
        }
        // Let any stray debounced work settle, then assert exactly one reaction.
        try await delay(0.5)
        XCTAssertEqual(connectivityEvents.value, 1)
        XCTAssertEqual(client.networkMode, .auto)
    }

    // MARK: - Behavior 11 — explicit modes are user-pinned

    func testExplicitModeNotDrivenByMonitorButBitRecorded() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }

        // Pin the mode explicitly.
        await client.goOffline()
        XCTAssertEqual(client.networkMode, .offline)

        // A path loss records the reachability bit but must not drive the
        // socket or change the pinned mode.
        monitor.push(false)
        try await delay(0.4)
        XCTAssertEqual(client.networkMode, .offline)

        // Returning to .auto then honors the current (lost) reachability.
        client.setNetworkMode(.auto)
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertFalse(client.networkingAllowed())
    }

    // MARK: - Behavior 12 — lifecycle

    func testDestroyCancelsMonitorAndNoReactionAfterCancel() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor)

        let connectivityEvents = Counter()
        let sub = client.eventEmitter.subscribe(NetworkModeEvent.self) { e in
            if e.reason == "connectivityLost" || e.reason == "connectivityRestored" {
                connectivityEvents.bump()
            }
        }
        defer { sub.cancel() }

        try await eventually(timeout: 3) { monitor.isStarted }

        await client.destroy()
        XCTAssertEqual(monitor.cancelCount, 1)

        // A push after destroy triggers no reaction.
        monitor.push(false)
        try await delay(0.4)
        XCTAssertEqual(connectivityEvents.value, 0)

        // Double-destroy is safe and does not re-cancel.
        await client.destroy()
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    // MARK: - Behavior 13 — entering .auto reconciles the socket (PR #2069, [P2])

    /// A client pinned away from `.auto` records reachability but never drives
    /// the socket. When it returns to `.auto` while `reachable == true`, the
    /// mode switch itself must reconnect — no fresh monitor event follows it.
    func testEnterAutoWhileReachableReconnects() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }

        // Pin offline and make sure the socket is closed.
        await client.goOffline()
        try await eventually(timeout: 3, description: "offline disconnects") {
            client.isConnected == false
        }
        XCTAssertEqual(client.networkMode, .offline)

        // A restore is recorded while pinned but drives no socket action.
        monitor.push(true)
        try await delay(0.4)
        XCTAssertFalse(client.isConnected)

        // Returning to .auto must reconcile to the recorded reachable==true bit
        // and reconnect, even though no fresh monitor event follows the switch.
        client.setNetworkMode(.auto)
        try await eventually(timeout: 5, description: "enter .auto reconnects") {
            client.isConnected
        }
        XCTAssertEqual(client.networkMode, .auto)
    }

    /// The mirror case: a client connected while pinned `.online` that became
    /// unreachable in the meantime must disconnect the moment it enters `.auto`.
    func testEnterAutoWhileUnreachableDisconnects() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }

        // Pin online and connect to the loopback socket.
        await client.goOnline()
        try await eventually(timeout: 5, description: "connected while pinned online") {
            client.isConnected
        }

        // A loss is recorded while pinned but drives no socket action — the
        // connection stays up.
        monitor.push(false)
        try await delay(0.4)
        XCTAssertTrue(client.isConnected)

        // Returning to .auto must reconcile to the recorded reachable==false bit
        // and disconnect.
        client.setNetworkMode(.auto)
        try await eventually(timeout: 5, description: "enter .auto disconnects") {
            client.isConnected == false
        }
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertFalse(client.networkingAllowed())
    }

    // MARK: - Behavior 14 — rapid loss/restore churn ends connected (PR #2069, [P2])

    /// Churn coverage for the serialized restore path. The fix routes the
    /// reachability-restore handoff through the desired-connection path
    /// (`setShouldConnect(true)`) instead of a bare `connect()`, so a restore
    /// that overlaps a still-in-flight loss disconnect waits for that disconnect
    /// and re-arms `shouldConnect` before connecting — the restore's intent
    /// always wins and the client can't be stranded offline in `.auto`+reachable.
    ///
    /// This fires many concurrent loss/restore pairs from a freshly reconnected
    /// baseline and asserts the client always settles connected in `.auto` with
    /// reconnect enabled. It exercises the concurrent restore/disconnect
    /// serialization repeatedly without deadlock or a stranded connection.
    ///
    /// Note: this is coverage of the restore path, not a tight isolation of the
    /// exact in-flight race — that window over the loopback socket is only a few
    /// milliseconds (a client-initiated close completes locally almost
    /// immediately), so a single overlap cannot be forced deterministically with
    /// the available server-free seams. The race itself is closed by
    /// construction: `setShouldConnect(true)` registers as a disconnect waiter
    /// under the manager's lock (see `WebSocketManager.setDesiredConnection`).
    func testRapidLossRestoreChurnEndsConnected() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }

        // Reach a connected .auto state.
        monitor.push(true)
        try await eventually(timeout: 5, description: "initially connected") {
            client.isConnected
        }
        XCTAssertEqual(client.networkMode, .auto)

        for trial in 0..<40 {
            // Reset to a known connected baseline (bypasses the reachability
            // dedup, and recovers a trial that stranded the client offline).
            await client.forceReconnectAsync()
            try await eventually(timeout: 5, description: "trial \(trial): baseline connected") {
                client.isConnected
            }

            // Fire the loss disconnect and the restore handoff concurrently so
            // they contend on the connect/disconnect serialization.
            async let loss: Void = client.setShouldConnect(false)
            async let restore: Void = client.runOnlineAuthHandoff()
            _ = await (loss, restore)

            // The restore must win — after both settle the client is connected
            // in .auto with reconnect enabled, never stranded offline.
            try await eventually(timeout: 5, description: "trial \(trial): ends connected") {
                client.isConnected && client.networkingAllowed()
            }
        }
        XCTAssertEqual(client.networkMode, .auto)
    }

    // MARK: - Behavior 15 — the first snapshot is not debounced (PR #2069 review)

    /// Timing property, not just outcome: `NWPathMonitor` emits the current
    /// path right after `start(queue:)`, and the startup gate blocks the first
    /// connect until that snapshot is applied. If the first snapshot went
    /// through the 300 ms restore debounce, every cold start on a working
    /// network would pay that delay for nothing. The fake pushes `true`
    /// synchronously inside `start`, so the latch must be set well inside one
    /// debounce interval.
    func testInitialReachabilitySnapshotIsNotDebounced() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor(initialValue: true)
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        // Wait for the monitor to start, then measure how long the startup
        // gate's latch takes from that moment.
        try await eventually(timeout: 3) { monitor.startedAt != nil }
        let startedAt = try XCTUnwrap(monitor.startedAt)

        var latchedAfter: TimeInterval?
        while Date().timeIntervalSince(startedAt) < 3 {
            if client.initialReachabilityLatched {
                latchedAfter = Date().timeIntervalSince(startedAt)
                break
            }
            try await delay(0.005)
        }
        let elapsed = try XCTUnwrap(latchedAfter, "initial reachability never latched")
        // Fails (~0.3 s) if the first snapshot is put through the restore
        // debounce; the undebounced path latches inside the poll granularity.
        XCTAssertLessThan(
            elapsed, 0.15,
            "first reachability snapshot waited out the debounce (\(elapsed)s)"
        )

        // And the outcome still holds: the gate opens and startup connects.
        try await eventually(timeout: 5, description: "startup connects") {
            client.isConnected
        }
        XCTAssertEqual(client.networkMode, .auto)
    }

    /// The correctness property the immediate-apply half protects: the first
    /// snapshot runs through `applyReachability` BEFORE latching, so a down
    /// path at startup closes the gate instead of the gate reading the stale
    /// `reachable = true` default and auto-connecting.
    func testStartupWithDownPathDoesNotAutoConnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor(initialValue: false)
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        // Point-in-time ordering check, not a time window: at the FIRST tick
        // where the latch is set, the gate must already be closed. A window
        // assertion would also pass under a "latch inline, apply via the
        // debounced item" hybrid — there the gate opens at t≈0 on the stale
        // `reachable = true` default, startup connects, and the deferred apply
        // closes the socket again ~100 ms later, leaving every outcome
        // assertion satisfied after a spurious cold-start connect.
        var allowedAtLatch: Bool?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if client.initialReachabilityLatched {
                allowedAtLatch = client.networkingAllowed()
                break
            }
            try await delay(0.005)
        }
        let gateAtLatch = try XCTUnwrap(allowedAtLatch, "initial reachability never latched")
        XCTAssertFalse(
            gateAtLatch,
            "startup gate was open at the moment the first-snapshot latch was set — "
                + "the snapshot latched before it was applied"
        )

        // No auto-connect happened, and the mode was not touched by the monitor.
        try await delay(0.5)
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertEqual(client.networkStatus.reason, "connectivityLost")
    }

    // MARK: - Behavior 16 — a stale deferred pause revalidates (#2078)

    /// `applyReachability`/`reconcileAutoSocket` decide under the lock and act
    /// outside it, so the pause runs in an unstructured `Task`. If the client
    /// transitions again before that task is scheduled — the app pins `.online`,
    /// or reachability comes back — the stale task used to close the socket and
    /// leave `shouldConnect == false`, stranding the client offline after the
    /// NEWER transition had already restored it.
    ///
    /// Both tests invoke `pauseSocketForReachabilityLoss()` directly, which is
    /// exactly the body of that deferred task. That is deterministic where
    /// racing the scheduler is not: the failure only shows up when the stale
    /// task lands *after* the newer transition finished, and calling it here
    /// reproduces that ordering exactly.
    func testStalePauseAfterPinToOnlineDoesNotDisconnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }

        // A path loss lands in `.auto` — the gate closes and the pause is
        // queued.
        monitor.push(false)
        try await eventually(timeout: 3, description: "gate closed after loss") {
            client.networkingAllowed() == false
        }

        // The app immediately pins `.online`, which connects.
        client.setNetworkMode(.online)
        try await eventually(timeout: 5, description: "pinned online connects") {
            client.isConnected
        }

        // The stale pause now runs. It must revalidate and no-op.
        await client.pauseSocketForReachabilityLoss()
        try await delay(0.4)
        XCTAssertTrue(
            client.isConnected,
            "stale reachability pause closed the socket after the client was pinned .online"
        )
        XCTAssertTrue(client.networkingAllowed())
        XCTAssertTrue(client.webSocketManagerShouldReconnect(code: 1006, reason: "abnormal"))
        XCTAssertEqual(client.networkMode, .online)
    }

    /// Same race, `.auto` variant: reachability is restored (and the restore
    /// handoff has reconnected) before the loss's deferred pause runs.
    func testStalePauseAfterReachabilityRestoredDoesNotDisconnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }

        monitor.push(false)
        try await eventually(timeout: 3, description: "gate closed after loss") {
            client.networkingAllowed() == false
        }

        monitor.push(true)
        try await eventually(timeout: 5, description: "restore reconnects") {
            client.isConnected
        }

        await client.pauseSocketForReachabilityLoss()
        try await delay(0.4)
        XCTAssertTrue(
            client.isConnected,
            "stale reachability pause closed the socket after reachability was restored"
        )
        XCTAssertTrue(client.networkingAllowed())
        XCTAssertTrue(client.webSocketManagerShouldReconnect(code: 1006, reason: "abnormal"))
        XCTAssertEqual(client.networkMode, .auto)
    }

    /// The guard must not defang the real pause: when the state the pause was
    /// queued for still holds (`.auto` + unreachable), it still closes the
    /// socket and suppresses reconnect.
    func testPauseStillActsWhenStillAutoAndUnreachable() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = String(url.absoluteString.dropLast())
        defer { server.stop() }

        let monitor = FakeConnectivityMonitor()
        let client = makeClient(autoNetwork: true, monitor: monitor, wsUrl: base)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3) { monitor.isStarted }
        monitor.push(true)
        try await eventually(timeout: 5, description: "connected in .auto") {
            client.isConnected
        }

        monitor.push(false)
        try await eventually(timeout: 5, description: "loss disconnects") {
            client.isConnected == false
        }
        XCTAssertFalse(client.networkingAllowed())
        XCTAssertFalse(client.webSocketManagerShouldReconnect(code: 1006, reason: "abnormal"))
        XCTAssertEqual(client.networkMode, .auto)
    }
}
