import XCTest
import Network
@testable import JsBaoClient

/// Phase 1 (issue #1987): separation of the internal networking GATE
/// (`networkingAllowed()`, mode-based) from the public connectivity REPORT
/// (`isOnline()` / `getNetworkStatus()`, blended with transport), plus the new
/// `transport`/`reason` fields on `NetworkStatus`.
///
/// Server-free: the connected-transport case drives a real socket via the
/// in-process `LoopbackWebSocketServer`; everything else is pure logic against
/// a client constructed with memory storage and no auto-connect.
final class NetworkReportingTests: XCTestCase {

    /// Thread-safe capture box for values recorded inside `@Sendable` event
    /// handlers.
    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { self._value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    /// A bare client: bootstrapped token, no auto-connect, memory storage —
    /// constructs without any dev server.
    private func makeClient(wsUrl: String = "ws://127.0.0.1:1") -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    // MARK: - Behavior 1 — reconnect not suppressed by the reporting change

    /// The exact v1 regression: after an unexpected socket close in `.auto`
    /// (reachable still `true`), the reconnect delegate must still return
    /// `true` even though the transport reports disconnected. A transport-
    /// blended gate would return `false` here and kill the reconnect loop.
    func testReconnectNotSuppressedInAutoWhileTransportDisconnected() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        XCTAssertEqual(client.getNetworkMode(), .auto)
        XCTAssertEqual(client.getNetworkStatus().transport, .disconnected)

        // Reporting says offline (transport disconnected)…
        XCTAssertFalse(client.getNetworkStatus().isOnline)
        XCTAssertFalse(client.isOnline())

        // …but the gate (the reconnect delegate) still says YES, so the
        // reconnect loop survives an unexpected close.
        XCTAssertTrue(client.webSocketManagerShouldReconnect(code: 1006, reason: "abnormal"))
        XCTAssertTrue(client.networkingAllowed())

        // Auth-failure closes still suppress reconnect (unchanged).
        XCTAssertFalse(client.webSocketManagerShouldReconnect(code: 4001, reason: "auth"))
        XCTAssertFalse(client.webSocketManagerShouldReconnect(code: 4003, reason: "auth"))
    }

    // MARK: - Behaviors 2/3/4 — the reporting formula matrix

    /// `isOnline = (mode == .online) || (mode == .auto && transport == .connected)`
    /// across the full mode × transport matrix.
    func testReportedOnlineMatrix() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        // Explicit `.online` → online regardless of transport.
        for t in [ConnectionStatus.connected, .connecting, .disconnected] {
            XCTAssertTrue(client.reportedOnline(mode: .online, transport: t))
        }
        // Explicit `.offline` → offline regardless of transport.
        for t in [ConnectionStatus.connected, .connecting, .disconnected] {
            XCTAssertFalse(client.reportedOnline(mode: .offline, transport: t))
        }
        // `.auto` → online only when the transport is connected.
        XCTAssertTrue(client.reportedOnline(mode: .auto, transport: .connected))
        XCTAssertFalse(client.reportedOnline(mode: .auto, transport: .connecting))
        XCTAssertFalse(client.reportedOnline(mode: .auto, transport: .disconnected))
    }

    // MARK: - Behavior 5 — gating unchanged with monitoring off

    /// With monitoring off, `reachable` stays `true`, so `networkingAllowed()`
    /// equals the old `mode != .offline` — the reporting change to `isOnline()`
    /// does not alter what gates sync/requests/reconnect.
    func testGatingUnchangedWithMonitoringOff() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        // `.auto` + reachable(default true): the gate is OPEN even though the
        // report says offline (socket disconnected).
        XCTAssertTrue(client.networkingAllowed())
        XCTAssertFalse(client.isOnline())

        // `.offline`: both the gate and the report close.
        await client.goOffline()
        XCTAssertFalse(client.networkingAllowed())
        XCTAssertFalse(client.isOnline())
    }

    // MARK: - Behavior 4 — event isOnline agrees with getNetworkStatus()

    /// The emitted `NetworkModeEvent.isOnline` and `getNetworkStatus().isOnline`
    /// are routed through the same helper, so they always agree. `reason` is
    /// stored and surfaced.
    func testNetworkModeEventIsOnlineAgreesWithStatus() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let captured = LockedBox<Bool?>(nil)
        let sub = client.eventEmitter.subscribe(NetworkModeEvent.self) { e in
            captured.value = e.isOnline
        }
        defer { sub.cancel() }

        client.setNetworkMode(.offline, options: SetNetworkModeOptions(reason: "user_set"))
        try await eventually(timeout: 2, description: "networkMode event fired") {
            captured.value != nil
        }

        XCTAssertEqual(captured.value, client.getNetworkStatus().isOnline)
        XCTAssertEqual(captured.value, false)
        XCTAssertEqual(client.getNetworkStatus().reason, "user_set")
    }

    // MARK: - Behavior 2/4 — transport reflects a real connected socket

    /// Against a real (loopback) socket, `getNetworkStatus().transport` becomes
    /// `.connected` and, in `.auto`, `isOnline()` reports `true`.
    func testTransportReflectsConnectedSocket() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start() // ws://127.0.0.1:<port>/
        // Strip the trailing slash: the client appends "/app/<appId>/ws".
        let base = String(url.absoluteString.dropLast())
        let client = makeClient(wsUrl: base)
        defer { Task { await client.destroy() } }

        try await client.connect()
        XCTAssertTrue(client.isConnected)

        let status = client.getNetworkStatus()
        XCTAssertEqual(status.transport, .connected)
        XCTAssertTrue(status.isOnline)   // .auto + connected → online
        XCTAssertTrue(client.isOnline())
    }
}
