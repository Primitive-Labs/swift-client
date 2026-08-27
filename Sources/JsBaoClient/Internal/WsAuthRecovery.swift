import Foundation

/// The side of the client the recovery policy needs to act on, kept behind a
/// protocol so the policy can be exercised without a socket or a server.
/// `JsBaoClient` is the only production conformer.
protocol WsAuthRecoveryHost: AnyObject, Sendable {
    /// Is there an access token to refresh at all? A signed-out client has
    /// nothing to recover.
    func wsAuthRecoveryHasToken() -> Bool

    /// Does the caller still want a connection? An explicit `disconnect()`
    /// means "stay down", and recovering from it would reopen the socket.
    /// Offline network mode reads as `false` here too, which is the JS guard
    /// pair (`!shouldConnect`, `networkMode === "offline"`) as one signal.
    func wsAuthRecoveryShouldConnect() async -> Bool

    /// Is a socket already up, or an attempt already in flight? Forcing a
    /// second connect on top of one would tear down a working connection.
    func wsAuthRecoveryIsConnectedOrConnecting() async -> Bool

    /// Refresh the access token. Returns the refresh outcome unchanged so the
    /// policy can tell a credential failure from a transient outage.
    func wsAuthRecoveryRefresh(cause: String) async -> RefreshOutcome

    /// Reconnect now, rather than waiting out the reconnect backoff.
    func wsAuthRecoveryReconnect() async

    /// Stop reconnecting — the token cannot be recovered.
    func wsAuthRecoveryStopConnecting() async

    /// Report the failure to the app layer (`auth-failed`).
    func wsAuthRecoveryEmitAuthFailed(reason: String, code: Int?, statusText: String?)
}

/// Refreshes the access token when the WebSocket fails to authenticate, and
/// reconnects with the new one.
///
/// The Swift port of the JS client's handshake recovery
/// (`maybeStartHandshakeRecovery` / `recoverFromHandshakeFailure` in
/// `src/client/JsBaoClient.ts`). Without it the reconnect loop reused the
/// expired token indefinitely: the server rejected every upgrade and the client
/// stayed offline until the app was relaunched (#2637).
///
/// Two differences from the JS policy, both because the Swift transport sees a
/// signal the browser one does not:
///
///  - **The 4401 close counts even after a completed handshake.** The server
///    accepts the upgrade and then closes with 4401 when the token expires
///    mid-connection (`src/connection-worker.ts`). JS only recovers when the
///    handshake itself failed; in Swift that close is the first and clearest
///    notice that the token is dead, so it triggers recovery too.
///  - **A successful connect does not reset the attempt counter**, only the
///    recovery window does. Since a 4401 can arrive *after* a connect, resetting
///    on connect would let a server that rejects every fresh token drive an
///    unbounded refresh loop — the bound would never be reachable.
///
/// Thread safety: all mutable state is behind `lock`, and the decision that
/// claims the in-flight slot is taken in a single hold, so two closes arriving
/// together cannot both start a refresh.
final class WsAuthRecovery: @unchecked Sendable {

    /// The close code the server uses for an expired/invalid token
    /// (`src/connection-worker.ts`). 4001/4003 are not refresh candidates —
    /// see `terminalAuthCloseCodes`.
    static let authCloseCode = 4401

    /// Auth closes a token refresh cannot help, so recovery leaves them alone
    /// and lets the transport's normal reconnect handle them. The server sends
    /// 4001 only with "Session expired. Please reconnect." — which asks for
    /// exactly that reconnect, not a new token — and never sends 4003 from any
    /// path (#2660 kept it here for safety only). Since #2660 the transport
    /// reconnects on every close code, so a skip here no longer means the
    /// connection stays down.
    static let terminalAuthCloseCodes: Set<Int> = [4001, 4003]

    /// Refreshes allowed inside one recovery window. Matches the JS client's
    /// `wsHandshakeMaxRefreshAttempts`.
    static let maxRefreshAttempts = 2

    /// Matches the JS client's `wsHandshakeRecoveryWindowMs` (60s).
    static let recoveryWindowSeconds: TimeInterval = 60

    private let logger: Logger
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var handshakeCompleted = false
    private var recoveryInFlight = false
    private var refreshAttempts = 0
    private var lastFailureAt: Date?
    /// A refresh failed for connectivity reasons, so the connection is waiting
    /// on the transport's backoff. The next refresh that succeeds through any
    /// path fires it early. Port of the JS `wsHandshakeReconnectPending`.
    private var reconnectPending = false

    init(logger: Logger, now: @escaping @Sendable () -> Date = { Date() }) {
        self.logger = logger
        self.now = now
    }

    // MARK: - Transport lifecycle

    /// A connect attempt has started: until the socket opens, any failure is a
    /// handshake failure.
    func noteConnecting() {
        lock.withLock {
            handshakeCompleted = false
            // This attempt supersedes the pending one (JS parity:
            // `handleWebSocketConnecting`).
            reconnectPending = false
        }
    }

    /// The socket opened, so the token was accepted for this connection.
    func noteConnected() {
        lock.withLock {
            handshakeCompleted = true
            reconnectPending = false
        }
    }

    /// Full reset — for teardown and for a deliberate sign-out.
    func reset() {
        lock.withLock {
            handshakeCompleted = false
            recoveryInFlight = false
            refreshAttempts = 0
            lastFailureAt = nil
            reconnectPending = false
        }
    }

    // MARK: - Entry points

    /// A refresh succeeded — through this policy or, more usefully, through
    /// any other path such as an HTTP request's reactive refresh. If a
    /// connectivity-failed refresh left a reconnect pending, the token is good
    /// again, so the connection is retried now rather than after the rest of a
    /// backoff delay capped around five minutes. Port of the JS
    /// `handleAuthRefreshRecovered`.
    func handleAuthRefreshRecovered(host: any WsAuthRecoveryHost) async {
        guard lock.withLock({ () -> Bool in
            guard reconnectPending else { return false }
            // One-shot: whatever happens below, this pending reconnect is spent.
            reconnectPending = false
            return true
        }) else { return }

        guard await host.wsAuthRecoveryShouldConnect() else {
            logger.debug("[WS Auth] pending reconnect dropped: the client does not want a connection")
            return
        }
        guard await host.wsAuthRecoveryIsConnectedOrConnecting() == false else {
            logger.debug("[WS Auth] pending reconnect dropped: the transport is already up")
            return
        }

        logger.log("[WS Auth] Token refreshed elsewhere; reconnecting without waiting out the backoff")
        await host.wsAuthRecoveryReconnect()
    }

    /// Synchronously capture whether the connection that is closing had
    /// completed its handshake. The caller must read this inside the
    /// transport's close delivery, BEFORE anything can start the next connect
    /// attempt: a `forceReconnect()` close is followed immediately by a new
    /// `connect()`, whose `noteConnecting()` clears the flag, and the recovery
    /// task racing it would then misread a deliberate close on an
    /// authenticated connection as a handshake failure — and tear the
    /// connection down when the refresh is rejected (fixed-token clients).
    func handshakeCompletedAtClose() -> Bool {
        lock.withLock { handshakeCompleted }
    }

    /// The only entry point for transport failures, and deliberately so. A
    /// rejected upgrade reaches
    /// the client as a transport error, but `WebSocketManager` always follows
    /// that error with a close carrying the same failure — driving recovery
    /// from both would let one failure spend two refresh attempts.
    ///
    /// `handshakeCompletedAtClose` is the flag as sampled at close delivery
    /// (see `handshakeCompletedAtClose()`); when nil, the live flag is used —
    /// acceptable only for callers that cannot race a new connect attempt.
    func handleClose(
        code: Int?,
        reason: String?,
        handshakeCompletedAtClose: Bool? = nil,
        host: any WsAuthRecoveryHost
    ) async {
        await recover(
            code: code,
            statusText: reason,
            handshakeCompletedAtClose: handshakeCompletedAtClose,
            host: host
        )
    }

    // MARK: - Decision

    private enum Decision: Equatable {
        case skip(String)
        case attempt(Int)
        case exhausted
    }

    private func decide(
        code: Int?,
        hasToken: Bool,
        shouldConnect: Bool,
        handshakeCompletedAtClose: Bool?
    ) -> Decision {
        lock.withLock {
            if recoveryInFlight { return .skip("recovery already in flight") }
            if let code, Self.terminalAuthCloseCodes.contains(code) {
                // A refresh cannot help these closes (see the constant's doc);
                // the transport's normal reconnect — which since #2660 runs on
                // every close code — is the right response, unassisted.
                return .skip("terminal auth close \(code)")
            }
            if !shouldConnect { return .skip("client does not want a connection") }
            if !hasToken { return .skip("no access token to refresh") }
            // Judge the close against the connection it belongs to: the flag
            // as sampled at close delivery, not the live one, which a new
            // connect attempt may already have cleared.
            if (handshakeCompletedAtClose ?? handshakeCompleted) && code != Self.authCloseCode {
                return .skip("ordinary close on an authenticated connection")
            }

            let at = now()
            if let last = lastFailureAt, at.timeIntervalSince(last) > Self.recoveryWindowSeconds {
                refreshAttempts = 0
            }
            lastFailureAt = at

            guard refreshAttempts < Self.maxRefreshAttempts else {
                // Giving up takes the connection down, so a later refresh must
                // not revive it (JS parity: `setShouldConnect(false)` clears
                // the pending reconnect).
                reconnectPending = false
                return .exhausted
            }

            refreshAttempts += 1
            recoveryInFlight = true
            // This attempt supersedes any pending reconnect an earlier one
            // armed. It matters because the refresh below emits the client's
            // auth-success event from inside `applyToken`, which drives
            // `handleAuthRefreshRecovered` — leaving the flag set would force a
            // second reconnect for the same recovery.
            reconnectPending = false
            return .attempt(refreshAttempts)
        }
    }

    private func recover(
        code: Int?,
        statusText: String?,
        handshakeCompletedAtClose: Bool?,
        host: any WsAuthRecoveryHost
    ) async {
        let hasToken = host.wsAuthRecoveryHasToken()
        let shouldConnect = await host.wsAuthRecoveryShouldConnect()

        switch decide(
            code: code,
            hasToken: hasToken,
            shouldConnect: shouldConnect,
            handshakeCompletedAtClose: handshakeCompletedAtClose
        ) {
        case .skip(let why):
            logger.debug("[WS Auth] skipping recovery:", why)

        case .exhausted:
            logger.warn("[WS Auth] Handshake failed; refresh attempts exhausted", code ?? 0)
            host.wsAuthRecoveryEmitAuthFailed(
                reason: "ws_handshake_refresh_exhausted", code: code, statusText: statusText
            )
            await host.wsAuthRecoveryStopConnecting()

        case .attempt(let attempt):
            logger.warn("[WS Auth] Authentication failed; refreshing token, attempt", attempt)
            let outcome = await host.wsAuthRecoveryRefresh(cause: "ws-handshake")
            lock.withLock { recoveryInFlight = false }

            switch outcome {
            case .success:
                // Recheck the intent: a `disconnect()` can land while the
                // refresh is in flight, and the reconnect is forced — it sets
                // `shouldConnect = true` — so reconnecting here would reopen a
                // socket the caller deliberately took down.
                guard await host.wsAuthRecoveryShouldConnect() else {
                    logger.debug("[WS Auth] token refreshed, but the client no longer wants a connection")
                    return
                }
                // The transport's own backoff can fire while the refresh is in
                // flight and have the socket back up by now. The reconnect is
                // forced — it closes whatever task exists and opens a new one —
                // so going ahead would disconnect a connection that already
                // recovered.
                guard await host.wsAuthRecoveryIsConnectedOrConnecting() == false else {
                    logger.debug("[WS Auth] token refreshed, but the transport already came back on its own")
                    return
                }
                logger.log("[WS Auth] Token refreshed after auth failure; reconnecting")
                await host.wsAuthRecoveryReconnect()

            case .invalid:
                host.wsAuthRecoveryEmitAuthFailed(
                    reason: "ws_handshake_refresh_failed", code: code, statusText: statusText
                )
                await host.wsAuthRecoveryStopConnecting()

            case .network(let error):
                // A transient outage, not a credential problem. Leave the
                // transport's own reconnect backoff to keep retrying; the next
                // failure gets another attempt from the same window budget.
                // Arm the fast path so a refresh that succeeds once
                // connectivity returns reconnects immediately.
                lock.withLock { reconnectPending = true }
                logger.warn(
                    "[WS Auth] Token refresh deferred after auth failure:",
                    error?.localizedDescription ?? "network"
                )
            }
        }
    }
}
