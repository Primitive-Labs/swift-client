import XCTest
@testable import JsBaoClient

/// Server-free test for the `.connectionError` wire (issue #1986). The
/// `webSocketManagerOnError` delegate method existed and was implemented by
/// `JsBaoClient` (it emits `.connectionError`), but `WebSocketManager` never
/// called it — so `.connectionError` could never fire. The JS client emits
/// `connection-error` on a transport-level WebSocket error
/// (`handleWebSocketError`), so the parity-correct fix is to invoke the
/// delegate from the transport-error callback.
///
/// This drives the manager's real `connect()` at a refused loopback port so
/// URLSession delivers `didCompleteWithError`, and asserts the delegate's
/// `webSocketManagerOnError` fires. Before the wire this test hangs on its
/// expectation (the delegate is never called) and fails; after, it passes.
final class WebSocketManagerErrorTests: XCTestCase {

    /// Delegate that supplies a token + a fixed URL and fulfills an expectation
    /// when `webSocketManagerOnError` is invoked. `shouldReconnect` is false so
    /// the failed connect does not schedule a reconnect.
    private final class ErrorRecordingDelegate: WebSocketManagerDelegate, @unchecked Sendable {
        let url: URL
        let onErrorExpectation: XCTestExpectation
        init(url: URL, onError: XCTestExpectation) {
            self.url = url
            self.onErrorExpectation = onError
        }

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
        func webSocketManagerOnError(_ error: Error) { onErrorExpectation.fulfill() }
        func webSocketManagerOnReconnectScheduled(delayMs: Int) {}
        func webSocketManagerOnDisconnectInitiated() {}
        func webSocketManagerOnDisconnectResolved() {}
        func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool { false }
    }

    /// A transport-level connect failure must invoke `webSocketManagerOnError`
    /// so `.connectionError` can fire.
    func testTransportErrorInvokesOnErrorDelegate() async throws {
        // Bind a loopback port, then stop the server so the port is refused —
        // a `connect()` there fails via `didCompleteWithError` deterministically.
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        server.stop()
        // Give the OS a moment to release the listener.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let onError = expectation(description: "webSocketManagerOnError invoked on transport failure")
        let delegate = ErrorRecordingDelegate(url: url, onError: onError)
        let manager = WebSocketManager(
            logger: Logger(level: .error, scope: "test"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )

        do {
            try await manager.connect()
            XCTFail("connect() to a refused port should throw")
        } catch {
            // Expected — the connection was refused.
        }

        await fulfillment(of: [onError], timeout: 5)
        XCTAssertFalse(manager.isConnected, "manager must not be connected after a refused connect()")
    }

    /// Delegate for the established-connection failure case: signals when the
    /// socket opens, and counts `webSocketManagerOnError` invocations so the
    /// test can assert the error fires exactly once (no double-fire between the
    /// receive-loop catch and `didCompleteWithError`).
    private final class CountingDelegate: WebSocketManagerDelegate, @unchecked Sendable {
        let url: URL
        let onConnected: XCTestExpectation
        let onErrorFired: XCTestExpectation
        private let lock = NSLock()
        private var _errorCount = 0
        var errorCount: Int { lock.withLock { _errorCount } }

        init(url: URL, onConnected: XCTestExpectation, onErrorFired: XCTestExpectation) {
            self.url = url
            self.onConnected = onConnected
            self.onErrorFired = onErrorFired
        }

        func webSocketManagerHasAccessToken() -> Bool { true }
        func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String]) {
            (url, [:])
        }
        func webSocketManagerOnStatusChange(_ status: ConnectionStatus) {}
        func webSocketManagerOnConnecting() {}
        func webSocketManagerOnConnected() { onConnected.fulfill() }
        func webSocketManagerOnMessage(_ data: Data) async {}
        func webSocketManagerOnMessage(_ text: String) async {}
        func webSocketManagerOnClose(code: Int?, reason: String?) {}
        func webSocketManagerOnError(_ error: Error) {
            lock.withLock { _errorCount += 1 }
            onErrorFired.fulfill()
        }
        func webSocketManagerOnReconnectScheduled(delayMs: Int) {}
        func webSocketManagerOnDisconnectInitiated() {}
        func webSocketManagerOnDisconnectResolved() {}
        func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool { false }
    }

    /// A failure on an ALREADY-ESTABLISHED connection must invoke
    /// `webSocketManagerOnError` exactly once. This is the case Codex flagged:
    /// the receive-loop catch clears `self.task` before `didCompleteWithError`
    /// runs, so the completion callback's identity guard rejects it — leaving
    /// `.connectionError` unfired unless the receive-error path itself notifies.
    /// The fix routes both paths through `handleConnectionClosed`, whose atomic
    /// `wasTask` claim is a once-only guard: exactly one emission per failure.
    func testEstablishedConnectionFailureInvokesOnErrorExactlyOnce() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()

        let onConnected = expectation(description: "socket established")
        let onErrorFired = expectation(description: "webSocketManagerOnError on established-connection failure")
        let delegate = CountingDelegate(url: url, onConnected: onConnected, onErrorFired: onErrorFired)
        let manager = WebSocketManager(
            logger: Logger(level: .error, scope: "test"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )

        // Establish the connection for real.
        try await manager.connect()
        await fulfillment(of: [onConnected], timeout: 5)
        XCTAssertTrue(manager.isConnected, "manager should be connected before the drop")

        // Drop the established connection from the server side — the client's
        // pending receive() throws a transport error.
        server.stop()

        await fulfillment(of: [onErrorFired], timeout: 5)
        // Allow any (buggy) second emission to arrive before asserting once-only.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(
            delegate.errorCount, 1,
            "established-connection failure must fire .connectionError exactly once"
        )
        XCTAssertFalse(manager.isConnected, "manager must not be connected after the drop")
    }
}
