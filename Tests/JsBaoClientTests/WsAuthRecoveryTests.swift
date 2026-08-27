import XCTest
@testable import JsBaoClient

/// Server-free tests for the WebSocket auth-recovery policy (issue #2637).
///
/// Before this policy existed the Swift client reconnected after a 4401 close
/// with the same expired access token forever: nothing referenced close code
/// 4401 and `AuthController.handleAuthChallenge()` had no callers, so the
/// client stayed offline until the app was relaunched (or until an unrelated
/// HTTP 401 happened to refresh the token as a side effect).
///
/// The policy is the Swift port of the JS client's handshake recovery
/// (`maybeStartHandshakeRecovery` / `recoverFromHandshakeFailure` in
/// `src/client/JsBaoClient.ts`). It is driven entirely through
/// `WsAuthRecoveryHost`, so every behavior is observable without a server.
final class WsAuthRecoveryTests: XCTestCase {

    // MARK: - Fake host

    /// Records what the policy asked for and replays scripted refresh outcomes.
    private final class FakeHost: WsAuthRecoveryHost, @unchecked Sendable {
        private let lock = NSLock()

        var hasToken = true
        var shouldConnect = true
        var connectedOrConnecting = false

        /// Outcomes handed back in order; the last one repeats once exhausted.
        var outcomes: [RefreshOutcome] = [.success]

        /// Set to have `refresh()` park until `releaseRefresh()` is called.
        var blockRefresh = false
        private var refreshGate: CheckedContinuation<Void, Never>?
        private var refreshEntered: XCTestExpectation?

        private(set) var refreshCauses: [String] = []
        private(set) var reconnectCount = 0
        private(set) var stopCount = 0
        private(set) var authFailures: [(reason: String, code: Int?)] = []

        var refreshCount: Int { lock.withLock { refreshCauses.count } }

        func expectRefreshEntered(_ expectation: XCTestExpectation) {
            lock.withLock { refreshEntered = expectation }
        }

        func releaseRefresh() {
            let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let g = refreshGate
                refreshGate = nil
                return g
            }
            gate?.resume()
        }

        func wsAuthRecoveryHasToken() -> Bool { lock.withLock { hasToken } }

        func wsAuthRecoveryShouldConnect() async -> Bool { lock.withLock { shouldConnect } }

        func wsAuthRecoveryIsConnectedOrConnecting() async -> Bool {
            lock.withLock { connectedOrConnecting }
        }

        func wsAuthRecoveryRefresh(cause: String) async -> RefreshOutcome {
            let (outcome, shouldBlock, entered) = lock.withLock { () -> (RefreshOutcome, Bool, XCTestExpectation?) in
                refreshCauses.append(cause)
                let index = min(refreshCauses.count - 1, outcomes.count - 1)
                return (outcomes[index], blockRefresh, refreshEntered)
            }
            entered?.fulfill()
            if shouldBlock {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { refreshGate = continuation }
                }
            }
            return outcome
        }

        func wsAuthRecoveryReconnect() async { lock.withLock { reconnectCount += 1 } }

        func wsAuthRecoveryStopConnecting() async { lock.withLock { stopCount += 1 } }

        func wsAuthRecoveryEmitAuthFailed(reason: String, code: Int?, statusText: String?) {
            lock.withLock { authFailures.append((reason, code)) }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_000_000)
        var date: Date { lock.withLock { now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { now = now.addingTimeInterval(seconds) } }
    }

    private func makeRecovery(_ clock: Clock) -> WsAuthRecovery {
        WsAuthRecovery(logger: Logger(level: .error, scope: "test"), now: { clock.date })
    }

    // MARK: - Behavior 1 — a 4401 close refreshes the token

    func testAuthCloseTriggersRefreshWithWsHandshakeCause() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()

        // A completed handshake, then the server's auth-expiry close — the
        // exact sequence in the repro (connection-worker closes with 4401).
        recovery.noteConnecting()
        recovery.noteConnected()
        await recovery.handleClose(code: 4401, reason: "Authentication expired", host: host)

        XCTAssertEqual(host.refreshCauses, ["ws-handshake"])
    }

    // MARK: - Behavior 2 — handshake-level failures refresh too

    func testCloseBeforeSocketOpenTriggersRefresh() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()

        // Connecting, never opened: the upgrade was rejected.
        recovery.noteConnecting()
        await recovery.handleClose(code: nil, reason: "bad response from the server", host: host)

        XCTAssertEqual(host.refreshCauses, ["ws-handshake"])
    }

    /// The rejected-upgrade case from the repro. `WebSocketManager` reports it
    /// as a transport error and then closes with the same failure text and no
    /// close code, so the close carries it.
    func testRejectedUpgradeTriggersRefresh() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()

        recovery.noteConnecting()
        await recovery.handleClose(
            code: nil, reason: "There was a bad response from the server.", host: host
        )

        XCTAssertEqual(host.refreshCauses, ["ws-handshake"])
    }

    // MARK: - Behavior 3 — a successful refresh reconnects immediately

    func testSuccessfulRefreshReconnects() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.success]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertEqual(host.reconnectCount, 1, "a refreshed token must not wait out the capped backoff")
        XCTAssertEqual(host.stopCount, 0)
        XCTAssertTrue(host.authFailures.isEmpty)
    }

    /// A `disconnect()` that lands while the refresh is in flight wins: the
    /// reconnect is forced (it sets `shouldConnect = true`), so reviving the
    /// socket here would override a connection the caller deliberately took
    /// down. The intent is rechecked after the refresh, not only before it.
    func testDisconnectDuringRefreshCancelsTheReconnect() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.success]
        host.blockRefresh = true
        let entered = expectation(description: "refresh entered")
        host.expectRefreshEntered(entered)

        recovery.noteConnecting()
        let recovering = Task { await recovery.handleClose(code: 4401, reason: nil, host: host) }
        await fulfillment(of: [entered], timeout: 5)

        host.shouldConnect = false
        host.releaseRefresh()
        await recovering.value

        XCTAssertEqual(host.reconnectCount, 0, "must not revive an explicitly closed connection")
    }

    /// The transport's own backoff can fire while the refresh is in flight and
    /// have the socket back up by the time it returns. `forceReconnect()`
    /// closes whatever task exists and opens a new one, so forcing it here
    /// would disconnect a connection that already recovered.
    func testSuccessfulRefreshDoesNotForceReconnectOverALiveTransport() async {
        for transport in [true, false] {
            let clock = Clock()
            let recovery = makeRecovery(clock)
            let host = FakeHost()
            host.outcomes = [.success]
            host.blockRefresh = true
            let entered = expectation(description: "refresh entered")
            host.expectRefreshEntered(entered)

            recovery.noteConnecting()
            let recovering = Task { await recovery.handleClose(code: 4401, reason: nil, host: host) }
            await fulfillment(of: [entered], timeout: 5)

            host.connectedOrConnecting = transport
            host.releaseRefresh()
            await recovering.value

            XCTAssertEqual(host.reconnectCount, transport ? 0 : 1,
                           "connectedOrConnecting=\(transport)")
        }
    }

    // MARK: - Behavior 4 — attempts are bounded within the recovery window

    func testAttemptsBoundedWithinWindow() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        // Refresh keeps succeeding but the server keeps rejecting the upgrade.
        host.outcomes = [.success]

        for _ in 0..<4 {
            recovery.noteConnecting()
            await recovery.handleClose(code: 4401, reason: nil, host: host)
            clock.advance(5)
        }

        XCTAssertEqual(host.refreshCount, WsAuthRecovery.maxRefreshAttempts,
                       "refreshes inside one recovery window must be bounded")
    }

    func testWindowExpiryResetsAttempts() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.success]

        for _ in 0..<WsAuthRecovery.maxRefreshAttempts {
            recovery.noteConnecting()
            await recovery.handleClose(code: 4401, reason: nil, host: host)
        }
        XCTAssertEqual(host.refreshCount, WsAuthRecovery.maxRefreshAttempts)

        // An hour-later expiry is a new incident, not a continuation of this one.
        clock.advance(WsAuthRecovery.recoveryWindowSeconds + 1)
        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertEqual(host.refreshCount, WsAuthRecovery.maxRefreshAttempts + 1)
        XCTAssertTrue(host.authFailures.isEmpty, "a fresh window must not report exhaustion")
    }

    // MARK: - Behavior 5 — exhaustion emits auth-failed and stops reconnecting

    func testExhaustionEmitsAuthFailedAndStops() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.success]

        for _ in 0...WsAuthRecovery.maxRefreshAttempts {
            recovery.noteConnecting()
            await recovery.handleClose(code: 4401, reason: "Authentication expired", host: host)
        }

        XCTAssertEqual(host.authFailures.count, 1)
        XCTAssertEqual(host.authFailures.first?.reason, "ws_handshake_refresh_exhausted")
        XCTAssertEqual(host.authFailures.first?.code, 4401)
        XCTAssertEqual(host.stopCount, 1, "an exhausted client must stop retrying with a dead token")
    }

    // MARK: - Behavior 6 — invalid stops, network defers to the backoff loop

    func testInvalidRefreshEmitsAuthFailedAndStops() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.invalid]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertEqual(host.authFailures.map(\.reason), ["ws_handshake_refresh_failed"])
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(host.reconnectCount, 0)
    }

    func testNetworkRefreshLeavesBackoffLoopAlone() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil)]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertTrue(host.authFailures.isEmpty, "a transient outage is not an auth failure")
        XCTAssertEqual(host.stopCount, 0, "the reconnect backoff loop must keep running")
        XCTAssertEqual(host.reconnectCount, 0)
    }

    // MARK: - Behavior 8 — a network-failed refresh reconnects as soon as any refresh succeeds

    /// The outage case. The refresh could not reach the server, so the policy
    /// leaves the transport's backoff running — but that backoff is capped
    /// around 5 minutes, and by the time connectivity returns the client would
    /// sit out the rest of it. A refresh that succeeds through any other path
    /// (typically an HTTP request's reactive refresh) means the token is good
    /// again, so the connection is retried now. Port of the JS client's
    /// `wsHandshakeReconnectPending` / `handleAuthRefreshRecovered`.
    func testNetworkOutcomeReconnectsWhenALaterRefreshSucceeds() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil)]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)
        XCTAssertEqual(host.reconnectCount, 0, "precondition: the outage leaves the backoff running")

        // Connectivity returns and some other caller's refresh succeeds.
        await recovery.handleAuthRefreshRecovered(host: host)

        XCTAssertEqual(host.reconnectCount, 1, "must not wait out the remaining backoff")
    }

    func testAuthRefreshRecoveredDoesNothingWithoutAPendingReconnect() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()

        // No handshake failure has happened at all — an ordinary sign-in
        // refresh must not force the transport open.
        await recovery.handleAuthRefreshRecovered(host: host)

        XCTAssertEqual(host.reconnectCount, 0)
    }

    func testPendingReconnectIsOneShot() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil)]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)
        await recovery.handleAuthRefreshRecovered(host: host)
        await recovery.handleAuthRefreshRecovered(host: host)

        XCTAssertEqual(host.reconnectCount, 1, "one pending reconnect must fire exactly once")
    }

    /// Both an explicit `disconnect()` and offline network mode reach the
    /// policy as "the client does not want a connection"
    /// (`wsAuthRecoveryShouldConnect` is `desiredConnection && networkingAllowed`),
    /// which is the JS guard pair — `!shouldConnect` and `networkMode ===
    /// "offline"` — collapsed into one signal.
    func testPendingReconnectClearedWhenTheClientDoesNotWantAConnection() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil)]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        host.shouldConnect = false
        await recovery.handleAuthRefreshRecovered(host: host)
        XCTAssertEqual(host.reconnectCount, 0, "a client that was taken down stays down")

        // And the pending reconnect is spent, not merely deferred: a later
        // connect() is the caller's business, not this policy's.
        host.shouldConnect = true
        await recovery.handleAuthRefreshRecovered(host: host)
        XCTAssertEqual(host.reconnectCount, 0)
    }

    func testPendingReconnectSkippedWhenTheSocketIsAlreadyUp() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil)]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        // The backoff attempt already landed before the refresh recovered.
        host.connectedOrConnecting = true
        await recovery.handleAuthRefreshRecovered(host: host)

        XCTAssertEqual(host.reconnectCount, 0, "no second connect on top of a live one")
    }

    /// The policy's own refresh emits the client's auth-success event from
    /// inside `applyToken`, which is what drives `handleAuthRefreshRecovered`.
    /// A pending reconnect armed by an earlier attempt must not fire off that
    /// event while this attempt is still deciding — the attempt supersedes it,
    /// and firing both would force two reconnects for one recovery.
    func testAnInFlightAttemptSupersedesAnEarlierPendingReconnect() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil), .success]

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        // A second close: this refresh will succeed, and parks so the
        // auth-success it would emit lands while it is still in flight.
        host.blockRefresh = true
        let entered = expectation(description: "second refresh entered")
        host.expectRefreshEntered(entered)
        let recovering = Task { await recovery.handleClose(code: 4401, reason: nil, host: host) }
        await fulfillment(of: [entered], timeout: 5)

        await recovery.handleAuthRefreshRecovered(host: host)
        XCTAssertEqual(host.reconnectCount, 0, "the in-flight attempt owns this recovery")

        host.releaseRefresh()
        await recovering.value
        XCTAssertEqual(host.reconnectCount, 1, "exactly one reconnect for one recovery")
    }

    /// An exhausted budget stops the client; the pending reconnect goes with
    /// it, or a later refresh would revive a connection the policy just gave up
    /// on (JS parity: `setShouldConnect(false)` clears it).
    func testExhaustionClearsThePendingReconnect() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.network(nil)]

        for _ in 0...WsAuthRecovery.maxRefreshAttempts {
            recovery.noteConnecting()
            await recovery.handleClose(code: 4401, reason: nil, host: host)
        }
        XCTAssertEqual(host.authFailures.map(\.reason), ["ws_handshake_refresh_exhausted"])

        await recovery.handleAuthRefreshRecovered(host: host)
        XCTAssertEqual(host.reconnectCount, 0, "a client that gave up stays down")
    }

    /// JS parity: `handleWebSocketConnecting` and `handleWebSocketOpen` both
    /// clear the pending reconnect, so it never outlives the attempt it was
    /// armed for.
    func testTransportLifecycleClearsThePendingReconnect() async {
        for clearOnConnect in [false, true] {
            let clock = Clock()
            let recovery = makeRecovery(clock)
            let host = FakeHost()
            host.outcomes = [.network(nil)]

            recovery.noteConnecting()
            await recovery.handleClose(code: 4401, reason: nil, host: host)

            recovery.noteConnecting()
            if clearOnConnect { recovery.noteConnected() }
            await recovery.handleAuthRefreshRecovered(host: host)

            XCTAssertEqual(host.reconnectCount, 0,
                           "a new connect attempt supersedes the pending reconnect")
        }
    }

    // MARK: - Behavior 7 — no concurrent recovery, no recovery for ordinary closes

    func testRecoveryDoesNotRunConcurrentlyWithItself() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.blockRefresh = true
        let entered = expectation(description: "first refresh entered")
        host.expectRefreshEntered(entered)

        recovery.noteConnecting()
        let first = Task { await recovery.handleClose(code: 4401, reason: nil, host: host) }
        await fulfillment(of: [entered], timeout: 5)

        // A second close while the first refresh is still in flight.
        await recovery.handleClose(code: 4401, reason: nil, host: host)
        XCTAssertEqual(host.refreshCount, 1, "a second close must not start a second refresh")

        host.releaseRefresh()
        await first.value
    }

    func testPostHandshakeNonAuthCloseIsIgnored() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()

        recovery.noteConnecting()
        recovery.noteConnected()
        // An ordinary network drop on an established connection.
        await recovery.handleClose(code: 1006, reason: "abnormal closure", host: host)

        XCTAssertEqual(host.refreshCount, 0, "an ordinary drop stays on the plain backoff path")
        XCTAssertEqual(host.stopCount, 0)
    }

    /// The `forceReconnect()` race: the deliberate close's recovery task can
    /// run AFTER the immediate follow-up connect has called `noteConnecting()`
    /// and cleared the live handshake flag. The close must be judged against
    /// the connection it belongs to — the flag as sampled at close delivery —
    /// or a fixed-token client's forced reconnect refreshes, gets `invalid`,
    /// and tears the connection down (`DisconnectReconnectTests
    /// .testForceReconnect` was the field failure).
    func testCloseJudgedAgainstHandshakeStateSampledAtCloseDelivery() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.invalid]

        recovery.noteConnecting()
        recovery.noteConnected()
        // Close delivery samples the flag synchronously...
        let sampled = recovery.handshakeCompletedAtClose()
        // ...then the forced reconnect's connect() clears the live flag before
        // the recovery task runs.
        recovery.noteConnecting()
        await recovery.handleClose(
            code: 1001, reason: "forceReconnect", handshakeCompletedAtClose: sampled, host: host
        )

        XCTAssertEqual(host.refreshCount, 0, "a deliberate close on an authenticated connection must not refresh")
        XCTAssertEqual(host.stopCount, 0, "and must never stop the reconnect the caller just asked for")
        XCTAssertTrue(host.authFailures.isEmpty)
    }

    // MARK: - Edge cases

    func testNoTokenNoRefresh() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.hasToken = false

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertEqual(host.refreshCount, 0)
    }

    /// 4001/4003 are the transport's terminal auth closes — it deliberately
    /// does not reconnect on them (`webSocketManagerShouldReconnect`). Recovery
    /// must not override that by refreshing and forcing a reconnect.
    func testTerminalAuthCloseCodesAreNotRecovered() async {
        for code in [4001, 4003] {
            let clock = Clock()
            let recovery = makeRecovery(clock)
            let host = FakeHost()

            recovery.noteConnecting()
            await recovery.handleClose(code: code, reason: "unauthorized", host: host)

            XCTAssertEqual(host.refreshCount, 0, "close code \(code) is terminal")
            XCTAssertEqual(host.reconnectCount, 0, "close code \(code) must stay down")
        }
    }

    func testExplicitDisconnectNoRefresh() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.shouldConnect = false

        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertEqual(host.refreshCount, 0)
    }

    /// After exhaustion the app layer typically signs in again and calls
    /// `connect()`. That is a fresh incident: it must not inherit the spent
    /// attempt budget, or the first 4401 on the new session reports exhaustion
    /// immediately and the client goes straight back offline.
    func testResetRestoresTheAttemptBudget() async {
        let clock = Clock()
        let recovery = makeRecovery(clock)
        let host = FakeHost()
        host.outcomes = [.success]

        for _ in 0...WsAuthRecovery.maxRefreshAttempts {
            recovery.noteConnecting()
            await recovery.handleClose(code: 4401, reason: nil, host: host)
        }
        XCTAssertEqual(host.authFailures.count, 1, "precondition: budget spent")

        recovery.reset()
        recovery.noteConnecting()
        await recovery.handleClose(code: 4401, reason: nil, host: host)

        XCTAssertEqual(host.refreshCount, WsAuthRecovery.maxRefreshAttempts + 1)
        XCTAssertEqual(host.authFailures.count, 1, "no new exhaustion after a reset")
    }

    // MARK: - Wiring

    /// The policy is only useful if the client's transport delegate drives it.
    /// The delegate methods need a live socket to reach, so this is a
    /// source-level check that the call sites exist — and that the close is the
    /// single driver, since `webSocketManagerOnError` always precedes a close
    /// carrying the same failure and a second trigger would spend a second
    /// refresh attempt on one failure.
    func testClientDelegateDrivesTheRecoveryPolicy() throws {
        let source = try ClientSourceText.code("JsBaoClient.swift")

        for call in [
            "wsAuthRecovery.noteConnecting()",
            "wsAuthRecovery.noteConnected()",
            "wsAuthRecovery.handleClose(",
            // An explicit connect() is a fresh incident — see
            // `testResetRestoresTheAttemptBudget`.
            "wsAuthRecovery.reset()",
            // A refresh that succeeds through any path fires the pending
            // reconnect armed by a network-failed one (behavior 8), so the
            // client must drive the policy from the auth-success event.
            "wsAuthRecovery.handleAuthRefreshRecovered(",
            "AuthSuccessEvent.self",
        ] {
            XCTAssertTrue(source.contains(call), "JsBaoClient must call \(call)")
        }

        let onError = try ClientSourceText.slice(
            source, from: "func webSocketManagerOnError(", to: "func webSocketManagerOnReconnectScheduled("
        )
        XCTAssertFalse(onError.contains("wsAuthRecovery"),
                       "the close is the single recovery driver; the error path must not trigger it too")
    }
}
