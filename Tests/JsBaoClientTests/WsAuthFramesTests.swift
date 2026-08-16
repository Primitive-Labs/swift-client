import XCTest
import Network
@testable import JsBaoClient

/// Mid-connection WebSocket auth protocol (#2660) — the Swift port of the JS
/// client's behavior, pinned in
/// `tests/client/js-bao-client-ws-auth-frames.test.ts`.
///
/// The server re-authenticates a live socket rather than closing it: as the
/// access token nears expiry it sends `auth_required`, waits out a grace
/// period, and only then closes with 4401 (`src/connection-worker.ts`). The
/// client is expected to refresh and push the new token back in band as
/// `{type:"auth", token}`, which the server answers with `auth_success` — or
/// `auth_failed` when the token does not check out. None of that was
/// implemented here: the frames hit the `default` branch of
/// `handleWebSocketMessage` and no token was ever pushed, so a connection that
/// outlived its token was closed and then reconnect-looped on the same dead
/// credential.
///
/// Server-free. The frame cases are driven straight through
/// `handleWebSocketMessage`, the way the transport delivers them. The in-band
/// push is asserted on the wire against the in-process
/// `LoopbackWebSocketServer`, so what the test sees is the frame the client
/// really sent.
///
/// The refresh itself is a real call to a dead port: it fails at the transport,
/// which the controller reports as `AuthRefreshDeferredEvent` carrying the
/// `cause` it was asked to refresh for. That event is the observable "a refresh
/// was attempted, and for this reason" — no injected refresh seam needed.
/// Hand one server frame to the client the way the transport does.
private func deliverFrame(_ frame: [String: Any], to client: JsBaoClient) async {
    let data = try! JSONSerialization.data(withJSONObject: frame)
    await client.handleWebSocketMessage(String(data: data, encoding: .utf8)!)
}

final class WsAuthFramesTests: XCTestCase {

    /// The client's per-connection budget for challenge-driven refreshes,
    /// restated here so the test fails if the production value changes rather
    /// than following it.
    private let maxChallengeRefreshes = 3

    /// A bare client: bootstrapped token, no auto-connect, memory storage. The
    /// API/WS hosts point at a closed port, so nothing reaches a server.
    private func makeClient(wsUrl: String = "ws://127.0.0.1:1") -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: "test-app",
            token: makeTestJwt(userId: "user-initial"),
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    /// Deliver one server frame the way the transport does. A free function, so
    /// the concurrent-delivery test can start two without sending the test case
    /// itself across an isolation boundary.
    private func deliver(_ frame: [String: Any], to client: JsBaoClient) async {
        await deliverFrame(frame, to: client)
    }

    /// A loopback server plus a client connected to it. Returns both so the
    /// caller can assert on the frames that reached the wire.
    private func connectedClient() async throws -> (LoopbackWebSocketServer, JsBaoClient) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        // Strip the trailing slash: the client appends "/app/<appId>/ws".
        let client = makeClient(wsUrl: String(url.absoluteString.dropLast()))
        try await client.connect()
        XCTAssertTrue(client.isConnected)
        return (server, client)
    }

    /// The `auth` frames the client put on the wire, decoded.
    private func authFrames(_ server: LoopbackWebSocketServer) -> [[String: Any]] {
        server.receivedFrames.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "auth"
            else { return nil }
            return json
        }
    }

    // MARK: - Behavior 8/9 — the challenge frames drive a refresh

    func testAuthRequiredFrameRefreshesTheAccessToken() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let deferred = try await collectEvents(
            from: client.eventEmitter, event: AuthRefreshDeferredEvent.self
        ) {
            await deliver(["type": "auth_required", "reason": "token_expired"], to: client)
        }

        // `"ws-challenge"` is the cause the JS client refreshes a challenge
        // under, so an app reading `authRefreshDeferred` sees the same string on
        // both platforms.
        XCTAssertEqual(deferred.compactMap(\.cause), ["ws-challenge"])
    }

    func testAuthFailedFrameRefreshesTheAccessToken() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let deferred = try await collectEvents(
            from: client.eventEmitter, event: AuthRefreshDeferredEvent.self
        ) {
            await deliver(["type": "auth_failed", "message": "Invalid token"], to: client)
        }

        XCTAssertEqual(deferred.compactMap(\.cause), ["ws-challenge"])
    }

    /// Two challenges that overlap spend one refresh, matching the JS client's
    /// `wsAuthRefreshInFlight` guard. The delivery is not awaited, because the
    /// window the guard exists for is the one where the first refresh is still
    /// running.
    func testOverlappingChallengesSpendOneRefresh() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let deferred = try await collectEvents(
            from: client.eventEmitter, event: AuthRefreshDeferredEvent.self
        ) {
            async let first: Void = deliverFrame(
                ["type": "auth_required", "reason": "token_expired"], to: client
            )
            async let second: Void = deliverFrame(
                ["type": "auth_required", "reason": "token_expired"], to: client
            )
            _ = await (first, second)
        }

        XCTAssertEqual(deferred.count, 1)
    }

    /// A server that keeps rejecting the token must not be able to drive an
    /// unbounded refresh loop. `auth_failed` is the case that matters: the
    /// server does not close the socket when it refuses a pushed token
    /// (`ConnectionWorker.handleTokenRefresh`), so a refresh that yields the
    /// same rejected identity — signing in as a different user on a socket
    /// authenticated as the previous one — would otherwise cycle
    /// push → auth_failed → refresh → push at HTTP speed with no backoff,
    /// since a successful refresh resets it.
    func testChallengeRefreshesAreBoundedPerConnection() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let deferred = try await collectEvents(
            from: client.eventEmitter, event: AuthRefreshDeferredEvent.self
        ) {
            for _ in 0..<6 {
                await deliver(["type": "auth_failed", "message": "Invalid token"], to: client)
            }
        }

        XCTAssertEqual(deferred.count, maxChallengeRefreshes)
    }

    /// The bound is per connection, so a socket that comes back up gets a fresh
    /// budget rather than inheriting a spent one for the rest of the session.
    func testChallengeRefreshBudgetResetsOnConnect() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        for _ in 0..<maxChallengeRefreshes {
            await deliver(["type": "auth_failed", "message": "Invalid token"], to: client)
        }

        let afterReconnect = try await collectEvents(
            from: client.eventEmitter, event: AuthRefreshDeferredEvent.self
        ) {
            client.webSocketManagerOnConnected()
            await deliver(["type": "auth_failed", "message": "Invalid token"], to: client)
        }

        XCTAssertEqual(afterReconnect.count, 1)
    }

    // MARK: - Behavior 10 — auth_success is surfaced

    func testAuthSuccessFrameIsSurfacedAsAnAuthSuccessEvent() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        let events = try await collectEvents(
            from: client.eventEmitter, event: AuthSuccessEvent.self
        ) {
            await deliver(["type": "auth_success"], to: client)
        }

        // Counted rather than compared whole: the client's own bootstrap token
        // application emits an `AuthSuccessEvent` of its own (cause
        // `"bootstrap"`) and can land inside this window.
        XCTAssertEqual(events.filter { $0.cause == "websocket" }.count, 1)
    }

    // MARK: - Behavior 11 — token_refresh applies the pushed token

    func testTokenRefreshFrameAppliesThePushedToken() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        let pushed = makeTestJwt(userId: "user-pushed")

        await deliver(["type": "token_refresh", "token": pushed], to: client)

        XCTAssertEqual(client.authController.getToken(), pushed)
    }

    /// A frame with no usable token must not clear the session — the client
    /// would sign the user out over a malformed server frame.
    func testTokenRefreshFrameWithoutATokenIsIgnored() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        let before = client.authController.getToken()

        await deliver(["type": "token_refresh"], to: client)
        await deliver(["type": "token_refresh", "token": ""], to: client)

        XCTAssertEqual(client.authController.getToken(), before)
    }

    // MARK: - Behavior 12 — the in-band push

    func testAnAppliedTokenIsPushedToTheOpenSocket() async throws {
        let (server, client) = try await connectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }
        // Same user, new token — the rotation case the in-band frame exists for.
        let rotated = makeTestJwt(userId: "user-initial")

        client.updateToken(rotated, cause: "refresh")
        try await delay(0.5)

        XCTAssertEqual(authFrames(server).count, 1)
        XCTAssertEqual(authFrames(server).first?["token"] as? String, rotated)
    }

    /// A token for a *different* user cannot be adopted in band: the server
    /// compares the pushed token's user against the one the socket was opened
    /// as and answers `auth_failed`
    /// (`ConnectionWorker.handleTokenRefresh`), leaving the connection
    /// authenticated as the previous user. Signing in as someone else while
    /// connected therefore has to rebuild the connection, or every subsequent
    /// document operation runs under the wrong session.
    func testATokenForADifferentUserRebuildsTheConnection() async throws {
        let (server, client) = try await connectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }

        client.updateToken(makeTestJwt(userId: "someone-else"), cause: "google")
        try await delay(1.0)

        XCTAssertEqual(authFrames(server).count, 0, "an in-band push would be rejected")
        XCTAssertEqual(server.acceptedCount, 2, "the connection must be rebuilt")
    }

    /// Rotating the token with no socket open is a no-op rather than an error
    /// or a frame queued for a connection that may never come.
    func testAnAppliedTokenSendsNothingWhenNoSocketIsOpen() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let client = makeClient(wsUrl: String(url.absoluteString.dropLast()))
        defer {
            Task { await client.destroy() }
            server.stop()
        }
        // Deliberately never connected.
        client.updateToken(makeTestJwt(userId: "user-rotated"), cause: "refresh")
        try await delay(0.5)

        XCTAssertEqual(server.acceptedCount, 0)
        XCTAssertEqual(authFrames(server).count, 0)
    }

    /// End to end on one socket: the challenge arrives, the client refreshes
    /// (here the refresh is stood in for by the token application every refresh
    /// ends in), and the new token goes back out on the same connection. What
    /// matters is that the socket is still the one the challenge arrived on.
    func testChallengeToReAuthKeepsTheSameSocket() async throws {
        let (server, client) = try await connectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }

        await deliver(["type": "auth_required", "reason": "token_expired"], to: client)
        client.updateToken(makeTestJwt(userId: "user-initial"), cause: "refresh")
        try await delay(0.5)

        XCTAssertEqual(authFrames(server).count, 1)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(server.acceptedCount, 1, "the connection must not have been rebuilt")
    }

    // MARK: - Behavior 13 — sign-in no longer hard-reconnects

    /// The OAuth and Apple callbacks used to call `forceReconnect()` on any
    /// already-open socket, explicitly because there was no in-band refresh.
    /// That cost a re-sync of every open document on a sign-in that happened
    /// while connected, including signing in again as the same user. The
    /// decision now belongs to `reauthenticateSocket(with:previous:)`, which
    /// reconnects only for an actual change of user (see the test above), so
    /// neither callback should reach for the transport itself. A source-level
    /// check because the alternative is standing up an OAuth token exchange;
    /// the region anchors fail loudly if either callback moves.
    func testSignInCallbacksDoNotForceReconnectAnOpenSocket() throws {
        let source = try ClientSourceText.code("JsBaoClient.swift")

        // `code(_:)` strips comments, so the anchors are declarations rather
        // than `// MARK:` headings.
        let oauth = try ClientSourceText.slice(
            source,
            from: "public func handleOAuthCallback(",
            to: "func handleAppleCallback("
        )
        XCTAssertFalse(
            oauth.contains("forceReconnect"),
            "handleOAuthCallback still hard-reconnects instead of pushing the token in band"
        )

        let apple = try ClientSourceText.slice(
            source,
            from: "func handleAppleCallback(",
            to: "public func magicLinkRequest("
        )
        XCTAssertFalse(
            apple.contains("forceReconnect"),
            "handleAppleCallback still hard-reconnects instead of pushing the token in band"
        )
    }

    // MARK: - Behavior 14 — no close-code allowlist

    /// JS `shouldReconnect` ignores the close code entirely. The Swift gate
    /// suppressed reconnect on 4001 and 4003, neither of which is what the
    /// server sends for an expired token: it sends 4401 (twice — the auth grace
    /// timeout and a disabled user), sends 4001 only alongside "Session
    /// expired. Please reconnect.", and never sends 4003 at all
    /// (`src/connection-worker.ts`). So the allowlist suppressed reconnects
    /// that should happen while doing nothing about the 4401 loop.
    func testReconnectIsNotSuppressedByAnyCloseCode() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        for code in [1006, 4001, 4003, 4401] {
            XCTAssertTrue(
                client.webSocketManagerShouldReconnect(code: code, reason: "auth"),
                "close code \(code) must not suppress reconnect"
            )
        }
    }
}
