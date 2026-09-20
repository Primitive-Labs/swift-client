import XCTest
@testable import JsBaoClient

/// A close this client made itself is not the server refusing its token
/// (#3437, found by the live rows).
///
/// The shape, reproduced under `PersistenceTests`: a second session hydrates a
/// persisted JWT, the hydrated token starts a connect, and the storage that
/// binds a moment later raises the receive limit — which, since #3436, rebuilds
/// the socket, because `URLSessionWebSocketTask.maximumMessageSize` is only
/// honoured before a task is resumed. That rebuild's close lands on a
/// connection whose handshake had not completed, so `WsAuthRecovery` read it as
/// a handshake auth failure, refreshed a token nobody had rejected, and — for
/// the fixed-token clients that have no refresh token — took the connection
/// down for good on the 401. The client never came back, and the app was left
/// signed in to a socket that would not open.
///
/// The rule these two tests pin is the narrow, true one: recovery judges what
/// the SERVER did, so a close this client initiated is skipped whatever the
/// handshake state, and the transport says so at close delivery rather than
/// leaving the policy to guess.
final class WsAuthDeliberateCloseHermeticTests: XCTestCase {

    // MARK: - Fake host

    /// Records what the policy asked for. Deliberately its own double rather
    /// than `WsAuthRecoveryTests`' richer one: what is under test here is a
    /// single decision, and the two suites' hosts must be free to diverge.
    private final class FakeHost: WsAuthRecoveryHost, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var refreshCauses: [String] = []
        private(set) var stopCount = 0
        private(set) var reconnectCount = 0

        var refreshCount: Int { lock.withLock { refreshCauses.count } }
        var stops: Int { lock.withLock { stopCount } }

        func wsAuthRecoveryHasToken() -> Bool { true }
        func wsAuthRecoveryShouldConnect() async -> Bool { true }
        func wsAuthRecoveryIsConnectedOrConnecting() async -> Bool { false }
        func wsAuthRecoveryRefresh(cause: String) async -> RefreshOutcome {
            lock.withLock { refreshCauses.append(cause) }
            // What a fixed-token client gets: there is no refresh token, so the
            // server answers 401 and the policy's next move is to give up.
            return .invalid
        }
        func wsAuthRecoveryReconnect() async { lock.withLock { reconnectCount += 1 } }
        func wsAuthRecoveryStopConnecting() async { lock.withLock { stopCount += 1 } }
        func wsAuthRecoveryEmitAuthFailed(reason: String, code: Int?, statusText: String?) {}
    }

    // MARK: - Recording delegate

    private final class RecordingDelegate: WebSocketManagerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private let url: URL

        init(url: URL) { self.url = url }

        var calls: [String] { lock.withLock { _calls } }
        private func record(_ call: String) { lock.withLock { _calls.append(call) } }

        func webSocketManagerHasAccessToken() -> Bool { true }
        func webSocketManagerBuildConnectionRequest(
            connectionId: String
        ) -> (url: URL, headers: [String: String]) { (url, [:]) }
        func webSocketManagerOnStatusChange(_ status: ConnectionStatus) {}
        func webSocketManagerOnConnecting() { record("connecting") }
        func webSocketManagerOnConnected() { record("connected") }
        func webSocketManagerOnMessage(_ data: Data) async {}
        func webSocketManagerOnMessage(_ text: String) async {}
        func webSocketManagerOnClose(code: Int?, reason: String?) { record("close") }
        func webSocketManagerOnError(_ error: Error) { record("error") }
        func webSocketManagerOnReconnectScheduled(delayMs: Int) {}
        func webSocketManagerOnDisconnectInitiated() {}
        func webSocketManagerOnDisconnectResolved() {}
        func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool { false }
        func webSocketManagerWillDeliverDeliberateClose() { record("deliberate") }
    }

    // MARK: - The policy

    /// The decision itself, with its own positive control beside it: the same
    /// close, on the same not-yet-authenticated connection, refreshes when the
    /// server closed it and is left alone when this client did.
    func testADeliberateCloseIsNotJudgedAnAuthenticationFailure() async throws {
        let deliberate = FakeHost()
        let policy = WsAuthRecovery(logger: Logger(level: .none, scope: "ws-auth-deliberate"))
        policy.noteConnecting()
        await policy.handleClose(
            code: nil,
            reason: nil,
            handshakeCompletedAtClose: false,
            deliberateClose: true,
            host: deliberate
        )
        XCTAssertEqual(
            deliberate.refreshCount, 0,
            "a close this client made itself says nothing about the token"
        )
        XCTAssertEqual(
            deliberate.stops, 0,
            "and it must never take the connection down: the rebuild is already reconnecting"
        )

        // Positive control — without the flag the very same close is a
        // handshake failure and still recovers, so the skip above is about the
        // initiator and not about the shape of the close.
        let server = FakeHost()
        let control = WsAuthRecovery(logger: Logger(level: .none, scope: "ws-auth-control"))
        control.noteConnecting()
        await control.handleClose(
            code: nil,
            reason: nil,
            handshakeCompletedAtClose: false,
            deliberateClose: false,
            host: server
        )
        XCTAssertEqual(
            server.refreshCount, 1,
            "a close before the handshake completed is still an auth failure"
        )
        XCTAssertEqual(server.stops, 1, "and an invalid refresh still stops the retries")
    }

    // MARK: - The transport's notice

    /// The half no policy test can make: the rebuild a raised receive limit
    /// forces really does announce itself before the close it produces, so the
    /// client has something to sample. Driven over a real socket against the
    /// in-process loopback server, because what is under test is the order in
    /// which the manager's close delivery calls the delegate.
    func testTheReceiveLimitRebuildAnnouncesItsCloseAsDeliberate() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let delegate = RecordingDelegate(url: url)
        let manager = WebSocketManager(
            logger: Logger(level: .none, scope: "ws-auth-deliberate-wsm"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
        try await manager.connect()

        // The raise #3436 makes on a live task: it cannot take effect on a
        // resumed task, so the manager rebuilds the socket.
        await manager.setMaximumMessageSize(16 * 1024 * 1024)

        let announced = await eventually { delegate.calls.contains("close") }
        XCTAssertTrue(announced, "the rebuild must close the socket it could not raise")

        let calls = delegate.calls
        guard let closeIndex = calls.firstIndex(of: "close") else {
            return XCTFail("no close was delivered: \(calls)")
        }
        XCTAssertTrue(
            calls[..<closeIndex].contains("deliberate"),
            "the close must be announced as this client's own before it is delivered: \(calls)"
        )

        await manager.disconnect()
    }

    // MARK: - Helpers

    private func eventually(
        timeout: TimeInterval = 5,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
