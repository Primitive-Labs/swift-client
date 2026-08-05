import XCTest
@testable import JsBaoClient

/// Server-free thread-safety tests for `WebSocketManager` after the
/// `NSLock.lock()/unlock()` → scoped `withLock` conversion (issue #1910,
/// Phase 4). The tricky site is `disconnect()`: when a disconnect is already
/// in flight, extra callers register atomically as waiters under the lock and
/// are drained when it resolves. Splitting the old single continuous lock hold
/// into scoped `withLock` blocks must not strand a waiter (which would hang
/// that `disconnect()` forever). Behavior 8: N concurrent disconnect callers
/// all resolve, no dropped waiter.
///
/// These drive the manager through its real public `connect()`/`disconnect()`
/// API against an in-process loopback WebSocket server (no external dev server,
/// no production injection seam), so `connect()`'s rewritten decision prologue,
/// session swap, continuation prologue, and `didOpenWithProtocol` drain are all
/// exercised on a real socket too.
///
/// Both tests survive the #2171 actor conversion unchanged in substance: the
/// waiter lists are actor state now rather than lock-guarded fields, and the
/// registration is atomic with the decision that chose it because the
/// continuation body runs synchronously inside isolation.
final class WebSocketManagerDisconnectTests: XCTestCase {

    /// No-op delegate that supplies a token and the loopback URL. `weak` on the
    /// manager, so tests retain it. `shouldReconnect` returns false so a
    /// disconnect does not schedule a reconnect.
    private final class StubDelegate: WebSocketManagerDelegate, @unchecked Sendable {
        let url: URL
        init(url: URL) { self.url = url }

        func webSocketManagerHasAccessToken() -> Bool { true }
        func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String]) {
            (url, [:])
        }
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
    }

    private func makeConnectedManager() async throws -> (WebSocketManager, StubDelegate, LoopbackWebSocketServer) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let delegate = StubDelegate(url: url)
        let manager = WebSocketManager(
            logger: Logger(level: .error, scope: "test"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
        try await manager.connect()
        // connect() returns once didOpenWithProtocol has fired.
        XCTAssertTrue(manager.isConnected, "manager should be connected after connect() resolves")
        return (manager, delegate, server)
    }

    // The local `assertAsyncCompletes` this suite used to carry was folded into
    // the shared `assertCompletesAsync(within:)` (`Helpers/DeadlockWatchdog.swift`,
    // added by #2340 for exactly this case) when `WebSocketManager` became an
    // actor (#2171 behavior 8): the synchronous `assertCompletes(within:)`
    // takes a non-`async` closure and cannot wrap actor-isolated
    // `connect()`/`disconnect()`.

    /// Behavior 8: fire many concurrent `disconnect()` calls at a connected
    /// manager. Exactly one becomes the in-flight leader; the rest hit the
    /// `isDisconnecting` branch and register as waiters. Every caller must
    /// resolve — a dropped/stranded waiter would hang its `disconnect()`
    /// forever, which the watchdog turns into a failure.
    func testConcurrentDisconnectCallersAllResolve() async throws {
        let (manager, delegate, server) = try await makeConnectedManager()
        defer { server.stop() }
        _ = delegate // retain the weak delegate for the test's lifetime

        let callers = 50
        await assertCompletesAsync(within: 8, "50 concurrent disconnect() callers") {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<callers {
                    group.addTask { await manager.disconnect() }
                }
                await group.waitForAll()
            }
        }

        XCTAssertFalse(manager.isConnected, "manager should be disconnected after all callers resolve")
    }

    /// Liveness for the rewritten `connect()` + `disconnect()` paths: a few
    /// sequential connect/disconnect cycles over the loopback server all
    /// complete without deadlock, and the manager ends disconnected.
    func testConnectDisconnectCyclesAreDeadlockFree() async throws {
        let (manager, delegate, server) = try await makeConnectedManager()
        defer { server.stop() }
        _ = delegate

        await assertCompletesAsync(within: 15, "connect/disconnect cycles") {
            for _ in 0..<3 {
                await manager.disconnect()
                try? await manager.connect()
            }
            await manager.disconnect()
        }

        XCTAssertFalse(manager.isConnected, "manager should be disconnected after the final disconnect()")
    }
}
