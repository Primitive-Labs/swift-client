import XCTest
@testable import JsBaoClient

/// #5578 — between the socket's open and the server's `ready`, the Swift
/// client sends nothing of its own (its sends wait for `ready`), but a token
/// rotated for the same user still goes out in band on the open socket as
/// `{type:"auth", token}`, which the server answers once the handshake's
/// session is stored. Server-free: the `LoopbackWebSocketServer` holds the
/// connection between its upgrade and the `ready` the test pushes.
final class ReadyFrameAuthPushHermeticTests: XCTestCase {

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    func testARotatedTokenGoesOutOnTheOpenSocketBeforeReady() async throws {
        let server = try LoopbackWebSocketServer(sendsReady: false)
        let url = try server.start()
        defer { server.stop() }
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsBase(url),
            appId: "ready-auth-push",
            token: makeTestJwt(userId: "user-rotating"),
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        let log = HandledEventLog()
        await client.wsManager.setEventHandledHookForTest { log.record($0) }
        let connect = Task { try await client.connect() }

        let opened = await eventuallyTrue(timeout: 10) {
            log.events.contains { if case .opened = $0 { return true } else { return false } }
        }
        XCTAssertTrue(opened, "the socket opened")
        _ = await client.wsManager.isConnectedAsync
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(client.isConnected, "open, awaiting ready")
        XCTAssertEqual(server.receivedFrames(onConnection: 0), [], "nothing of the client's own goes out before ready")

        let rotated = makeTestJwt(userId: "user-rotating", exp: 9_999_999_998)
        client.updateToken(rotated, cause: "refresh")
        let pushed = await eventuallyTrue(timeout: 10) {
            server.receivedFrames(onConnection: 0).contains { $0.contains("\"auth\"") && $0.contains(rotated) }
        }
        XCTAssertTrue(pushed, "the rotated token goes out on the open socket")
        XCTAssertEqual(server.acceptedCount, 1, "the same user's token rebuilds nothing")
        XCTAssertFalse(client.isConnected)

        XCTAssertTrue(server.push(LoopbackWebSocketServer.readyFrame, toConnection: 0))
        let connected = await eventuallyTrue(timeout: 10) { client.isConnected }
        XCTAssertTrue(connected)
        _ = try? await connect.value
    }
}
