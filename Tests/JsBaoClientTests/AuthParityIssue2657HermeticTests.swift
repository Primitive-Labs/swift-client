import XCTest
@testable import JsBaoClient

/// Issue #2657 — Swift↔JS auth parity (2026-08-11 audit items A3, A10, A11,
/// A12). The JS client is the reference; every behavior here mirrors a passing
/// pin in `tests/client/js-bao-client-auth-parity-reference.test.ts`
/// (A10/A11/A12) or `tests/client/js-bao-client-node-otp-bootstrap.test.ts`
/// (A3 — otpVerify leaves the client connected).
///
///   A3  — every no-token→token transition connects the socket, for EVERY flow
///         (magic link, OTP, passkey, manual `updateToken`, OAuth), and a
///         successful HTTP refresh connects a disconnected client. JS does this
///         in `applyTokenEffects` / the HTTP client's `onRefreshOutcome`.
///   A10 — `bootstrapToken` sets state only (no sign-in events); the cause
///         vocabulary matches JS; `.authSuccess` needs a derivable userId.
///   A11 — userId derivation reads `payload.user.userId`, then
///         `payload.userId`, then `sub`.
///   A12 — `waitForAuthReady` resolves with a userId and throws when none
///         arrives; `waitForUserId` waits for a sign-in that lands after the
///         call.
///
/// Hermetic (`*HermeticTests`, the server-free lane): the controller cases
/// script HTTP through `RecordingTransport`, and the socket cases run against
/// the in-process `LoopbackWebSocketServer` with the API host pointed at a
/// closed port. No dev server, no `TestContext`.
final class AuthParityIssue2657HermeticTests: XCTestCase {

    // MARK: - Helpers

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _successes: [AuthSuccessEvent] = []
        private var _states: [AuthStateEvent] = []
        func record(_ event: AuthSuccessEvent) { lock.withLock { _successes.append(event) } }
        func record(_ event: AuthStateEvent) { lock.withLock { _states.append(event) } }
        var successes: [AuthSuccessEvent] { lock.withLock { _successes } }
        var states: [AuthStateEvent] { lock.withLock { _states } }
    }

    /// A JWT carrying exactly the claims given — the claim-shape cases need
    /// tokens `makeTestJwt` cannot express (nested `user.userId`, `sub` only,
    /// no user at all).
    private func mintJwt(claims: [String: Any]) -> String {
        var payload = claims
        payload["exp"] = payload["exp"] ?? 9_999_999_999
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(b64).s"
    }

    private func makeController(
        emitter: EventEmitter = EventEmitter(),
        json: String = ""
    ) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://127.0.0.1:1",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: emitter,
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        if !json.isEmpty {
            controller.setTransport(RecordingTransport(json: json))
        }
        return controller
    }

    // MARK: - A11: userId claim derivation

    /// The canonical nested claim is what the server actually issues; Swift
    /// read only the top level, so those sessions looked signed out.
    func testNestedUserIdClaimIsRead() {
        let controller = makeController()

        controller.updateToken(mintJwt(claims: ["user": ["userId": "nested-uid"]]))

        XCTAssertEqual(controller.getUserId(), "nested-uid")
        XCTAssertTrue(controller.isAuthenticated())
    }

    /// The derivation order: nested `user.userId`, then the legacy top-level
    /// `userId`, then `sub`.
    func testUserIdDerivationOrder() {
        let controller = makeController()

        controller.updateToken(mintJwt(claims: [
            "user": ["userId": "nested-uid"],
            "userId": "legacy-uid",
            "sub": "sub-uid",
        ]))
        XCTAssertEqual(controller.getUserId(), "nested-uid", "the nested claim wins")

        controller.updateToken(mintJwt(claims: ["userId": "legacy-uid", "sub": "sub-uid"]))
        XCTAssertEqual(controller.getUserId(), "legacy-uid", "the legacy claim beats sub")

        controller.updateToken(mintJwt(claims: ["sub": "sub-uid"]))
        XCTAssertEqual(controller.getUserId(), "sub-uid", "sub is the last resort")
    }

    // MARK: - A10: a sign-in needs a user

    /// JS gates both emissions on a derivable userId (`applyTokenEffects`), so
    /// a token the client cannot read a user out of is not reported as a
    /// successful sign-in. Swift emitted `.authSuccess` for any non-nil token,
    /// so an app listening for sign-ins saw one for a session it had no
    /// identity for.
    func testAuthSuccessRequiresADerivableUserId() {
        let emitter = EventEmitter()
        let controller = makeController(emitter: emitter)
        let recorder = EventRecorder()
        let successSub = emitter.subscribe(AuthSuccessEvent.self) { recorder.record($0) }
        let stateSub = emitter.subscribe(AuthStateEvent.self) { recorder.record($0) }
        defer { successSub.cancel(); stateSub.cancel() }

        controller.updateToken(mintJwt(claims: ["email": "nobody@example.com"]))

        XCTAssertTrue(
            recorder.successes.isEmpty,
            "a token with no derivable userId must not emit .authSuccess"
        )
        XCTAssertTrue(
            recorder.states.isEmpty,
            "nor the authenticated .authState that goes with it"
        )
        XCTAssertNil(controller.getUserId())
    }

    /// The other half of the gate: a token that DOES carry a user still emits
    /// both, so the guard cannot be satisfied by emitting nothing.
    func testAuthSuccessStillEmittedForATokenCarryingAUser() {
        let emitter = EventEmitter()
        let controller = makeController(emitter: emitter)
        let recorder = EventRecorder()
        let successSub = emitter.subscribe(AuthSuccessEvent.self) { recorder.record($0) }
        let stateSub = emitter.subscribe(AuthStateEvent.self) { recorder.record($0) }
        defer { successSub.cancel(); stateSub.cancel() }

        controller.updateToken(mintJwt(claims: ["user": ["userId": "signed-in-uid"]]))

        XCTAssertEqual(recorder.successes.count, 1)
        XCTAssertEqual(recorder.states.map(\.userId), ["signed-in-uid"])
        XCTAssertEqual(recorder.states.map(\.authenticated), [true])
    }

    // MARK: - A10: the constructor token is not a sign-in

    /// JS's `bootstrapToken` sets state and deliberately skips
    /// `applyTokenEffects`, so a client constructed with a token emits nothing:
    /// the app supplied that token, so nobody signed in from its point of view.
    /// Swift routed bootstrap through `applyToken`, so every such client
    /// announced a spurious sign-in on startup.
    func testBootstrapTokenEmitsNoSignInEvents() {
        let emitter = EventEmitter()
        let controller = makeController(emitter: emitter)
        let recorder = EventRecorder()
        let successSub = emitter.subscribe(AuthSuccessEvent.self) { recorder.record($0) }
        let stateSub = emitter.subscribe(AuthStateEvent.self) { recorder.record($0) }
        defer { successSub.cancel(); stateSub.cancel() }

        let token = mintJwt(claims: ["user": ["userId": "boot-uid"]])
        controller.bootstrapToken(token)

        XCTAssertTrue(recorder.successes.isEmpty, "bootstrapToken must not emit .authSuccess")
        XCTAssertTrue(recorder.states.isEmpty, "bootstrapToken must not emit .authState")
        XCTAssertEqual(controller.getToken(), token, "the state is still set")
        XCTAssertEqual(controller.getUserId(), "boot-uid")
        XCTAssertTrue(controller.isAuthenticated())
    }

    // MARK: - A10: the cause vocabulary is the JS one

    /// The `cause` on `.authSuccess` is an event payload apps read (the
    /// `PrimitiveApp` passkey-enrollment nudge switches on it), and Swift's
    /// vocabulary was its own: `google` / `magic_link` / `otp` / `passkey` /
    /// `refresh`. JS names the flow that produced the token — `oauthCallback`,
    /// `magicLinkVerify`, `otpVerify`, `passkeyAuth`, `httpRefresh` — and a
    /// direct `setToken` defaults to `manual`.
    func testSignInFlowsEmitTheJsCauseVocabulary() async throws {
        try await assertCause("oauthCallback", userId: "oauth-uid") { controller, token in
            controller.setTransport(
                RecordingTransport(json: #"{"token": "\#(token)", "isNewUser": false}"#)
            )
            let state = try AuthController.encodeOAuthState(
                redirectUri: "https://app.example.com/cb"
            )
            _ = try await controller.handleOAuthCallback(code: "code", state: state)
        }
        try await assertCause("magicLinkVerify", userId: "ml-uid") { controller, token in
            controller.setTransport(
                RecordingTransport(json: self.verifyEnvelope(userId: "ml-uid", token: token))
            )
            _ = try await controller.magicLinkVerify(token: "magic-token")
        }
        try await assertCause("otpVerify", userId: "otp-uid") { controller, token in
            controller.setTransport(
                RecordingTransport(json: self.verifyEnvelope(userId: "otp-uid", token: token))
            )
            _ = try await controller.otpVerify(email: "u@example.com", code: "000000")
        }
        try await assertCause("passkeyAuth", userId: "pk-uid") { controller, token in
            controller.setTransport(
                RecordingTransport(json: self.verifyEnvelope(userId: "pk-uid", token: token))
            )
            _ = try await controller.passkeyAuthFinish(
                credential: .object([:]), challengeToken: "challenge"
            )
        }
    }

    /// A successful HTTP refresh reports `httpRefresh` — the cause the JS
    /// client's `onTokenRefresh` applies — carrying the token it replaced.
    func testSuccessfulRefreshEmitsTheHttpRefreshCause() async throws {
        let first = makeTestJwt(userId: "u1")
        let refreshed = mintJwt(claims: ["user": ["userId": "u1"], "exp": 9_999_999_998])
        let emitter = EventEmitter()
        let controller = makeController(
            emitter: emitter, json: #"{"token": "\#(refreshed)"}"#
        )
        controller.updateToken(first)

        let events = try await collectEvents(from: emitter, event: AuthSuccessEvent.self) {
            let outcome = await controller.refreshAccessToken(cause: "test")
            XCTAssertEqual(outcome, .success)
        }

        XCTAssertEqual(events.map(\.cause), ["httpRefresh"])
        XCTAssertEqual(events.first?.previousToken, first, "a refresh replaces a token")
    }

    /// An unnamed `updateToken` — the app driving its own auth — is JS's
    /// `manual`, the default `JsBaoClient.setToken` applies.
    func testManualTokenApplicationEmitsTheManualCause() async throws {
        let emitter = EventEmitter()
        let controller = makeController(emitter: emitter)

        let events = try await collectEvents(from: emitter, event: AuthSuccessEvent.self) {
            controller.updateToken(makeTestJwt(userId: "manual-uid"))
        }

        XCTAssertEqual(events.map(\.cause), ["manual"])
    }

    /// Run one sign-in flow against a scripted transport and assert the single
    /// `.authSuccess` it emits carries `expectedCause`.
    private func assertCause(
        _ expectedCause: String,
        userId: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        run: (AuthController, String) async throws -> Void
    ) async throws {
        let token = makeTestJwt(userId: userId)
        let emitter = EventEmitter()
        let controller = makeController(emitter: emitter)

        let events = try await collectEvents(from: emitter, event: AuthSuccessEvent.self) {
            try await run(controller, token)
        }

        XCTAssertEqual(events.map(\.cause), [expectedCause], file: file, line: line)
    }

    // MARK: - A3: a token where there was none connects the socket

    /// A manual `updateToken` — an app running its own auth — is a
    /// no-token→token transition like any other, and JS connects on every one
    /// of them (`applyTokenEffects`). Swift only reconnected for the causes it
    /// classified as interactive sign-ins, so an app that set the token itself
    /// stayed offline until it called `connect()`.
    func testAManualTokenApplicationConnectsTheSocket() async throws {
        let (server, client) = try await disconnectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }

        client.updateToken(makeTestJwt(userId: "manual-uid"))

        try await eventually(timeout: 5, description: "the socket opens") {
            client.isConnected
        }
    }

    /// ...including the manual sign-in that FOLLOWS a `logout()`.
    ///
    /// The logout race guard drops non-interactive token applications until an
    /// explicit sign-in clears it, so an in-flight refresh cannot sign the user
    /// back in behind their back. An app handing the client a token itself is
    /// not that in-flight refresh — it is the sign-in — but `manual` was not on
    /// the guard's list, so the second session was dropped on the floor: no
    /// user, no events, no socket. JS has no such guard and simply signs in
    /// (pinned in `js-bao-client-auth-parity-reference.test.ts`).
    func testAManualSignInAfterLogoutConnectsTheSocket() async throws {
        let (server, client) = try await disconnectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }

        client.updateToken(makeTestJwt(userId: "first-uid"))
        try await eventually(timeout: 5, description: "the first socket opens") {
            client.isConnected
        }

        try await client.logout()
        XCTAssertNil(client.auth.userId, "logout clears the session")

        client.updateToken(makeTestJwt(userId: "second-uid"))

        XCTAssertEqual(client.auth.userId, "second-uid", "the app signed a user in")
        try await eventually(timeout: 5, description: "the socket opens again") {
            client.isConnected
        }
    }

    /// ...and however the app NAMES that sign-in. `updateToken(jwt, cause:)` is
    /// the documented custom-auth entry point (the reference example passes
    /// `cause: "external"`), and it is a sign-in because of the door it came
    /// through, not because of the string it chose. Classifying on the string
    /// alone signed the user back in for the default `manual` and silently
    /// dropped every named cause.
    func testANamedManualSignInAfterLogoutAlsoConnectsTheSocket() async throws {
        let (server, client) = try await disconnectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }

        client.updateToken(makeTestJwt(userId: "first-uid"), cause: "external")
        try await eventually(timeout: 5, description: "the first socket opens") {
            client.isConnected
        }

        try await client.logout()

        client.updateToken(makeTestJwt(userId: "second-uid"), cause: "external")

        XCTAssertEqual(client.auth.userId, "second-uid", "the app signed a user in")
        try await eventually(timeout: 5, description: "the socket opens again") {
            client.isConnected
        }
    }

    /// ...and an app that drives its own networking gets its socket back too.
    ///
    /// With `autoNetwork: false` the client never connects on its own, so the
    /// only thing the applied token owes it is the re-arm of `shouldConnect`
    /// that `logout()` cleared — the app's own `connect()` aborts on that flag
    /// (#2663). Gating the re-arm on `autoNetwork` left such a client signed in
    /// and permanently unable to connect; JS re-arms first and only then
    /// decides whether to connect itself (`applyTokenEffects`).
    func testAManualNetworkClientCanConnectAfterASignInFollowingLogout() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: String(url.absoluteString.dropLast()),
            appId: "test-app",
            token: nil,
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer {
            Task { await client.destroy() }
            server.stop()
        }
        await client.waitForStorageReady(timeout: 5)

        client.updateToken(makeTestJwt(userId: "first-uid"))
        try await client.connect()
        try await eventually(timeout: 5, description: "the first socket opens") {
            client.isConnected
        }

        try await client.logout()
        try await eventually(timeout: 5, description: "the logout takes the socket down") {
            !client.isConnected
        }

        client.updateToken(makeTestJwt(userId: "second-uid"))
        XCTAssertEqual(client.auth.userId, "second-uid", "the app signed a user in")

        // The applied-token hook re-arms the flag from a Task, so it can land
        // just after `updateToken` returns; the connect is retried rather than
        // pinned to that instant. Without the re-arm every attempt aborts on
        // `shouldConnect == false`, however long this waits.
        try await eventually(timeout: 5, description: "the app's own connect works again") {
            try await client.connect()
            return client.isConnected
        }
    }

    /// The other side of that widening: a token the SERVER pushes over the live
    /// socket is not the app signing in, so the logout guard still drops it. It
    /// travels through `applyServerPushedToken`, not the public `updateToken`.
    func testAServerPushedTokenIsStillBlockedAfterLogout() async throws {
        let controller = makeController()
        controller.updateToken(makeTestJwt(userId: "u1"))
        try await controller.logout()

        controller.applyServerPushedToken(makeTestJwt(userId: "u1"))

        XCTAssertNil(controller.getToken(), "a pushed token must not undo a logout")
        XCTAssertNil(controller.getUserId())
    }

    /// A token applied after `destroy()` must not reopen the socket. The
    /// applied-token hook runs on a detached task, so without unhooking it at
    /// teardown a late refresh — or an app that kept the reference — could
    /// reconnect a client whose storage is already closed.
    func testATokenAppliedAfterDestroyDoesNotConnect() async throws {
        let (server, client) = try await disconnectedClient()
        defer { server.stop() }

        await client.destroy()
        client.updateToken(makeTestJwt(userId: "late-uid"))

        try await delay(0.5)
        XCTAssertFalse(client.isConnected, "a destroyed client must not reconnect")
        XCTAssertEqual(server.acceptedCount, 0, "and must not have reached the server")
    }

    /// The OAuth callbacks await the socket work their token started, so they
    /// return with the connection attempt FINISHED — code that sends the
    /// moment sign-in resolves must not race the handshake. A connect already
    /// in flight is therefore joined (`wsManager.connect()` resolves as a
    /// secondary waiter on it), not skipped: skipping it handed the callback
    /// back while the socket was still mid-handshake.
    func testTheOAuthCallbackJoinsAConnectAlreadyInFlight() async throws {
        // A server that accepts TCP and never answers the upgrade: the client's
        // connect stays in flight for the whole test.
        let server = try LoopbackWebSocketServer(completesHandshake: false)
        let url = try server.start()
        let client = JsBaoClient(
            options: JsBaoClientOptions(
                apiUrl: "http://127.0.0.1:1",
                wsUrl: String(url.absoluteString.dropLast()),
                appId: "test-app",
                token: makeTestJwt(userId: "u1"),
                offline: false,
                logLevel: .error,
                storageConfig: .memory,
                autoNetwork: true
            ),
            connectivityMonitor: FakeConnectivityMonitor(initialValue: true)
        )
        defer {
            Task { await client.destroy() }
            server.stop()
        }
        await client.waitForStorageReady(timeout: 5)
        try await eventually(timeout: 5, description: "the init connect is in flight") {
            server.acceptedCount >= 1
        }
        XCTAssertFalse(client.isConnected, "the handshake never completes")

        client.authController.replaceTransportForTesting(
            RecordingTransport(json: #"{"token": "\#(makeTestJwt(userId: "u1"))", "isNewUser": false}"#)
        )
        let returned = BoolBox()
        let callback = Task {
            _ = try? await client.handleOAuthCallback(
                code: "code",
                state: try AuthController.encodeOAuthState(redirectUri: "https://app.example.com/cb")
            )
            returned.set()
        }
        defer { callback.cancel() }

        try await delay(0.5)
        XCTAssertFalse(
            returned.value,
            "the callback must not return while its connect is still in flight"
        )
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.withLock { _value = true } }
        var value: Bool { lock.withLock { _value } }
    }

    // MARK: - A10: the constructor token cannot outrank a later session

    /// `bootstrapToken` writes state directly — it is not a sign-in, so it does
    /// not go through `applyToken` — which means it must decline rather than
    /// bulldoze. A `logout()` between the client's synchronous constructor
    /// bootstrap and the one that used to run once storage bound would
    /// otherwise be undone silently: token back, re-persisted, no event.
    func testBootstrapTokenDoesNotUndoALogout() async throws {
        let controller = makeController()
        let token = makeTestJwt(userId: "boot-uid")
        controller.bootstrapToken(token)

        try await controller.logout()
        controller.bootstrapToken(token)

        XCTAssertNil(controller.getToken(), "the logout stands")
        XCTAssertNil(controller.getUserId())
    }

    /// Nor may it replace a session established since — the app signing in
    /// while storage was still binding wins over the constructor token.
    func testBootstrapTokenDoesNotReplaceANewerToken() {
        let controller = makeController()
        let newer = makeTestJwt(userId: "newer-uid")
        controller.updateToken(newer)

        controller.bootstrapToken(makeTestJwt(userId: "boot-uid"))

        XCTAssertEqual(controller.getToken(), newer)
        XCTAssertEqual(controller.getUserId(), "newer-uid")
    }

    /// The same for an interactive sign-in, driven end to end through
    /// `magicLinkVerify` — the flow the issue reports as never connecting.
    func testMagicLinkSignInConnectsTheSocket() async throws {
        let (server, client) = try await disconnectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }
        let token = makeTestJwt(userId: "ml-uid")
        client.authController.replaceTransportForTesting(
            RecordingTransport(json: verifyEnvelope(userId: "ml-uid", token: token))
        )

        _ = try await client.magicLinkVerify(token: "magic-token")

        try await eventually(timeout: 5, description: "the socket opens") {
            client.isConnected
        }
    }

    /// A successful HTTP refresh connects a disconnected client — JS does it
    /// from `onRefreshOutcome` ("refresh success (http) -> connect"), gated on
    /// not being connected or connecting. This is the startup shape: the app
    /// launches signed out, the cookie-based refresh lands a session, and the
    /// socket has to follow it up.
    func testASuccessfulRefreshConnectsTheSocket() async throws {
        let (server, client) = try await disconnectedClient()
        defer {
            Task { await client.destroy() }
            server.stop()
        }
        let token = makeTestJwt(userId: "refreshed-uid")
        client.authController.replaceTransportForTesting(
            RecordingTransport(json: #"{"token": "\#(token)"}"#)
        )

        let outcome = await client.authController.refreshAccessToken(cause: "test")
        XCTAssertEqual(outcome, .success)

        try await eventually(timeout: 5, description: "the socket opens") {
            client.isConnected
        }
    }

    /// A client that wants a connection but has no token, so it has none: the
    /// WebSocket manager refuses to connect without one
    /// (`webSocketManagerHasAccessToken`), which is exactly the state a
    /// signed-out app sits in while the user works through a sign-in screen.
    /// Returns it paired with the loopback server its socket would reach.
    private func disconnectedClient() async throws -> (LoopbackWebSocketServer, JsBaoClient) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let monitor = FakeConnectivityMonitor(initialValue: true)
        let client = JsBaoClient(
            options: JsBaoClientOptions(
                // The API host is a closed port: the startup refresh fails at
                // the transport, leaving the client signed out, and every HTTP
                // call a test needs is scripted through the transport seam.
                apiUrl: "http://127.0.0.1:1",
                // Strip the trailing slash: the client appends "/app/<appId>/ws".
                wsUrl: String(url.absoluteString.dropLast()),
                appId: "test-app",
                token: nil,
                offline: false,
                logLevel: .error,
                storageConfig: .memory,
                autoNetwork: true
            ),
            connectivityMonitor: monitor
        )

        // Let init settle: storage bound, startup refresh resolved, and the
        // init auto-connect attempted — it aborts for want of a token.
        await client.waitForStorageReady(timeout: 5)
        try await delay(0.3)
        XCTAssertFalse(client.isConnected, "a client with no token must not be connected")
        XCTAssertEqual(server.acceptedCount, 0, "and must not have reached the server")

        return (server, client)
    }

    // MARK: - A12: waitForAuthReady waits for a USER

    /// With somebody signed in it resolves with their id.
    func testWaitForAuthReadyResolvesWithTheUserId() async throws {
        let client = makeQuietClient(token: makeTestJwt(userId: "ready-uid"))
        defer { Task { await client.destroy() } }

        let result = try await client.waitForAuthReady(timeout: 5)

        XCTAssertEqual(result.userId, "ready-uid")
    }

    /// The waiter's whole point: a sign-in that starts AFTER the call resolves
    /// it. Swift resolved at `markAuthReady()` — which lands during init,
    /// before any interactive sign-in could — so awaiting it across a login
    /// screen answered "ready, nobody signed in".
    func testWaitForAuthReadyResolvesOnASignInThatLandsAfterTheCall() async throws {
        let client = makeQuietClient()
        defer { Task { await client.destroy() } }

        Task {
            try? await delay(0.2)
            client.updateToken(makeTestJwt(userId: "late-uid"))
        }

        let result = try await client.waitForAuthReady(timeout: 5)

        XCTAssertEqual(result.userId, "late-uid")
    }

    /// Signed out is not success. JS rejects; Swift resolved with a nil userId,
    /// so callers that did not re-check the state carried on as an anonymous
    /// client.
    func testWaitForAuthReadyThrowsWhenNobodySignsIn() async throws {
        let client = makeQuietClient()
        defer { Task { await client.destroy() } }

        do {
            let result = try await client.waitForAuthReady(timeout: 0.5)
            XCTFail("expected a throw, got userId=\(String(describing: result.userId))")
        } catch {
            // expected
        }
    }

    /// An `authFailed` while waiting rejects promptly instead of waiting out
    /// the timeout, matching the JS race against the `auth-failed` event.
    func testWaitForAuthReadyThrowsPromptlyOnAuthFailed() async throws {
        let client = makeQuietClient()
        defer { Task { await client.destroy() } }

        Task {
            try? await delay(0.15)
            client.eventEmitter.emit(
                AuthFailedEvent(message: "bad token", reason: "refresh_failed")
            )
        }

        let start = Date()
        do {
            _ = try await client.waitForAuthReady(timeout: 10)
            XCTFail("expected a throw on authFailed")
        } catch {
            XCTAssertLessThan(
                Date().timeIntervalSince(start), 5,
                "authFailed must reject promptly, not wait out the timeout"
            )
        }
    }

    /// And a sign-in landing within one poll interval of the failure does not
    /// overturn it. JS races the two as promises, so the FIRST one settles the
    /// wait permanently; a poll that read the userId first would report success
    /// through a failure that had already happened.
    func testAnAuthFailedIsNotOverturnedByASignInInTheSamePollWindow() async throws {
        let client = makeQuietClient()
        defer { Task { await client.destroy() } }

        Task {
            try? await delay(0.15)
            client.eventEmitter.emit(
                AuthFailedEvent(message: "bad token", reason: "refresh_failed")
            )
            client.updateToken(makeTestJwt(userId: "too-late-uid"))
        }

        do {
            let result = try await client.waitForAuthReady(timeout: 5)
            XCTFail("expected the earlier authFailed to win, got userId=\(result.userId)")
        } catch {
            // expected
        }
    }

    /// `waitForUserId` shares the same waiter, so it too waits for a FUTURE
    /// sign-in — the whole point of the call. It used to run
    /// `waitForAuthReady` and then throw "Not authenticated" the moment
    /// readiness landed, which is before any interactive sign-in can finish.
    func testWaitForUserIdWaitsForASignInThatLandsAfterTheCall() async throws {
        let client = makeQuietClient()
        defer { Task { await client.destroy() } }

        Task {
            try? await delay(0.3)
            client.updateToken(makeTestJwt(userId: "later-uid"))
        }

        let userId = try await client.waitForUserId(timeout: 5)

        XCTAssertEqual(userId, "later-uid")
    }

    /// And it still gives up at its timeout.
    func testWaitForUserIdTimesOut() async throws {
        let client = makeQuietClient()
        defer { Task { await client.destroy() } }

        do {
            let userId = try await client.waitForUserId(timeout: 0.5)
            XCTFail("expected a timeout, got \(userId)")
        } catch {
            // expected
        }
    }

    /// A client that never touches the network: no auto-networking, and both
    /// hosts are closed ports. Everything A12 needs is local state.
    private func makeQuietClient(token: String? = nil) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: token,
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    private func verifyEnvelope(userId: String, token: String) -> String {
        """
        {"token": "\(token)", "user": {"userId": "\(userId)", "email": "u@example.com"}, \
        "isNewUser": false}
        """
    }
}
