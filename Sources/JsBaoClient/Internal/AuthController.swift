import Foundation

/// Manages authentication state, token lifecycle, OAuth flows, and offline access.
///
/// ## A sync-adjacent boundary type (#1993 Phase D)
///
/// The concurrency epic actorized the async service managers (`OfflineStore`,
/// `KvCache`, `AnalyticsQueue`). This controller was deliberately left out of
/// that set by the sponsor (Fork 2, Option A): it has 13 synchronous public
/// members that callers reach from synchronous contexts, and `HttpClient`'s
/// 401 path calls into it, so converting it belongs in its own change. That
/// conversion is tracked as #2173. Until then the class-plus-lock model here is
/// the contract, and this argument is what stands in for compiler checking.
///
/// ## `@unchecked Sendable` safety argument
///
/// One `NSLock`, held in `lock`, guards **all** mutable state: `currentToken`,
/// `jwtPayload`, `currentUserId`, `networkMode`, `authReady`,
/// `authReadyContinuations`, `blockNonInteractiveAuth`, the refresh-backoff
/// bookkeeping (`refreshBackoffDelayMs`, `refreshBackoffAccumMs`,
/// `refreshRetryTask`, `refreshRetryScheduled`, `refreshRetryEpoch`) and its
/// tuning fields (`refreshBackoffBaseMs`, `refreshBackoffCapMs`,
/// `refreshBackoffMultiplier` — `var`s so tests can shorten a backoff, read in
/// production only from inside `handleRefreshDeferred`'s locked region),
/// `destroyed`, `pendingPersistTask`, `pendingRefresh`, `offlineIdentity`,
/// `pendingCodeVerifier` and `_transport`. Reads that only need one field go
/// through the small locked accessors (`getToken`, `getUserId`,
/// `getNetworkMode`, `getJwtPayload`, `getAuthState`) rather than touching the
/// storage directly, so a field is never read off-lock for convenience.
///
/// Four properties of the design make that single lock sufficient:
///
///  1. **No lock is held across an `await`.** Every suspension-crossing path
///     copies what it needs out of the critical section first — `refreshAccessToken`
///     registers or joins the single-flight `Task` inside one `withLock` and
///     awaits it outside; `requireTransport` copies the `any Transport`
///     existential out under the lock; `handleRefreshDeferred` computes a
///     `Decision` value inside the lock and emits/schedules outside it.
///  2. **Every decision that must be atomic is one critical section.** The
///     refresh single-flight (check-and-register), the backoff
///     check-and-schedule, the logout guard (`blockNonInteractiveAuth` +
///     `offlineIdentity`) and the retry-epoch validation are each a single
///     `withLock`, not a read followed by a separate write. This is the same
///     invariant the actorized managers restate as "no `await` inside a
///     decision region"; here the lock provides it directly.
///  3. **`NSLock` is not recursive, so no locked region calls back out.** The
///     event emissions, the logger calls and the `onLogoutDisconnect` /
///     `setClientNetworkMode` hooks all run after the lock is released.
///  4. **The write-once fields are confined to construction.** `_transport` is
///     installed by `setTransport`, which `precondition`s on a second call, and
///     writes under `lock`. The one other writer is the `DEBUG`-only
///     `replaceTransportForTesting`, which also writes under `lock` — so the
///     field is lock-confined either way; only the "written exactly once"
///     characterization is relaxed in test builds. `emitter` is a `weak var`
///     assigned only in `init` and never rebound. `setClientNetworkMode` and
///     `onLogoutDisconnect` are wired once by `JsBaoClient` while it is still
///     constructing itself, before the client is handed to any other thread,
///     and are never reassigned; their reads are therefore unsynchronized by
///     design, not by omission.
///
/// The one documented exception to (1) is `deinit`, which cancels
/// `refreshRetryTask` without taking `lock`. By then the last strong reference
/// is gone — the retry `Task` captures `[weak self]`, so it cannot be the
/// concurrent reader — and taking a lock in `deinit` would risk blocking a
/// deallocation. Same exception, same reasoning, as the sync domain's
/// `DynamicModel`.
///
/// Known gap, closed: the design pass for #1993 recorded an unsynchronized read
/// of the backoff delay while building the `authRefreshDeferred` payload
/// (#2174). #2022's rewrite replaced that read with the `Decision` enum above,
/// which carries the delay out of the locked region as a value, so the race no
/// longer exists on this tree.
public final class AuthController: @unchecked Sendable {
    private let lock = NSLock()

    // Dependencies
    private let appId: String
    private let apiUrl: String
    private let logger: Logger
    private let offlineStore: OfflineStore
    private weak var emitter: EventEmitter?
    private let refreshProxy: RefreshProxyConfig?
    private let persistConfig: AuthConfig

    // State
    private var currentToken: String?
    private var jwtPayload: [String: Any]?
    private var currentUserId: String?
    private var networkMode: NetworkMode = .auto
    private var authReady = false
    private var authReadyContinuations: [CheckedContinuation<Void, Never>] = []

    /// Set true on `logout()`; blocks NON-interactive token applications
    /// (a `bootstrap`/`http_refresh`/`refresh`/`startup` that resolves
    /// after the user logged out) from silently re-authenticating or
    /// re-persisting the JWT. Cleared by the next explicit sign-in
    /// (`oauthCallback`/`apple`/`magicLinkVerify`/`otpVerify`/`passkeyAuth`,
    /// and `manual` — the app setting a token itself; see
    /// `isInteractiveLogin`). Guarded by `lock`.
    private var blockNonInteractiveAuth = false

    // Refresh-retry backoff (#2022) — the port of the JS client's
    // `handleRefreshDeferred` / `scheduleRefreshRetry`
    // (src/client/internal/authController.ts). A network-failed refresh
    // schedules a background retry after `refreshBackoffDelayMs`, doubling the
    // delay each time and accumulating the total in `refreshBackoffAccumMs`;
    // once the projected total reaches the cap the controller stops retrying
    // and takes the client offline instead. `nextAttemptMs` in the public
    // `authRefreshDeferred` event reports the delay of the attempt actually
    // scheduled.
    //
    // `refreshBackoffDelayMs` starts at 0 (not at the base) so the FIRST
    // deferral reports the base delay and only then doubles — matching JS.
    private var refreshBackoffDelayMs: Int = 0
    private var refreshBackoffAccumMs: Int = 0

    // Backoff policy. Same values as the JS client. `internal` rather than
    // `private` only so tests can shrink the delays to milliseconds; nothing
    // in production mutates them.
    var refreshBackoffBaseMs: Int = 2000
    var refreshBackoffCapMs: Int = 300_000
    var refreshBackoffMultiplier: Int = 2

    // The pending retry. `refreshRetryScheduled` is the logical "a retry is
    // pending" flag the already-scheduled fast path reads; the Task is kept
    // only so cancellation can reach it. They're separate because a very short
    // delay lets the Task run to completion before `scheduleRefreshRetry`
    // stores it, and the flag must clear in that case too. `refreshRetryEpoch`
    // invalidates a Task whose reset/cancel raced its wakeup.
    private var refreshRetryTask: Task<Void, Never>?
    private var refreshRetryScheduled = false
    private var refreshRetryEpoch: Int = 0

    // Set by `destroy()`. Cancelling the pending retry Task is not enough on
    // its own: a `refreshAccessToken` that was already in flight when teardown
    // began can fail with a network error afterwards, reach
    // `handleRefreshDeferred`, and schedule a fresh retry against a
    // client/storage layer that is already gone. Once this is set, deferrals
    // are ignored and no new retry is scheduled. Guarded by `lock`.
    private var destroyed = false

    /// Set the client-level network mode. Wired by `JsBaoClient` to
    /// `client.setNetworkMode(_:)` so the backoff-cap transition emits the
    /// `networkMode` event exactly like a caller-initiated switch — the
    /// Swift equivalent of the JS `deps.setNetworkMode`. When the controller
    /// runs standalone (unit tests) it falls back to setting its own mode.
    var setClientNetworkMode: (@Sendable (NetworkMode) -> Void)?

    // In-flight JWT persistence task. Tracked so destroy() can await
    // outstanding writes before the storage layer closes the SQLite
    // connection — without this, a fresh client opening the same DB file
    // races against the prior session's write and hits SQLITE_BUSY
    // ("database is locked").
    private var pendingPersistTask: Task<Void, Never>?

    // Offline access grant
    private let keychainHelper: KeychainHelper
    private var offlineIdentity: OfflineIdentity?

    // PKCE: code_verifier from the most recent startOAuthFlow call, held
    // until handleOAuthCallback consumes it. Native (iOS) Google OAuth
    // clients have no client_secret and prove possession of the auth code
    // via PKCE (RFC 7636) instead. Guarded by `lock`.
    private var pendingCodeVerifier: String?

    // The typed HTTP transport, injected externally to break the circular
    // dependency with `JsBaoClient`. Written exactly once through
    // `setTransport` and only ever read under `lock` — the existential is
    // copied out of the critical section so no lock is ever held across an
    // `await`.
    private var _transport: (any Transport)?

    // Internal: takes the module-internal `Logger` (#2363).
    init(
        appId: String,
        apiUrl: String,
        logger: Logger,
        offlineStore: OfflineStore,
        emitter: EventEmitter,
        refreshProxy: RefreshProxyConfig?,
        persistConfig: AuthConfig
    ) {
        self.appId = appId
        self.apiUrl = apiUrl
        self.logger = logger.forScope(scope: "auth")
        self.offlineStore = offlineStore
        self.emitter = emitter
        self.refreshProxy = refreshProxy
        self.persistConfig = persistConfig
        self.keychainHelper = KeychainHelper(service: "com.primitive.\(appId).offline")
    }

    // MARK: - Transport injection

    /// Install the typed HTTP transport. **One-shot**: calling it a second
    /// time is a programming error and traps, because every request path
    /// reads the stored existential and a mid-flight swap would silently
    /// route some calls through the old client.
    ///
    /// The write happens under `lock`; every read copies the existential out
    /// under the same lock and releases it before awaiting.
    public func setTransport(_ transport: any Transport) {
        lock.withLock {
            precondition(
                _transport == nil,
                "AuthController.setTransport may only be called once"
            )
            _transport = transport
        }
    }

    // MARK: - Applied-token notification

    /// Called with every token the controller applies, from any path —
    /// bootstrap, an interactive login, a background refresh, a token the
    /// server pushed — together with the token it replaced. `JsBaoClient`
    /// installs a handler that re-authenticates an open WebSocket (#2660); the
    /// previous token is what lets it tell a rotation of the same identity,
    /// which the socket can adopt in band, from a switch to a different user,
    /// which it cannot.
    ///
    /// The controller has no transport reference and should not grow one, so
    /// the socket side stays behind this closure. Stored under `lock` like
    /// every other mutable field; the copy is taken under the lock and called
    /// outside it, so a handler that reaches back into the controller cannot
    /// deadlock.
    private var tokenAppliedHandler: (@Sendable (String, String?) -> Void)?

    func setTokenAppliedHandler(_ handler: @escaping @Sendable (String, String?) -> Void) {
        lock.withLock { tokenAppliedHandler = handler }
    }

    /// Drop the handler at client teardown, so a token applied afterwards
    /// cannot reach a socket that is being (or has been) closed.
    func clearTokenAppliedHandler() {
        lock.withLock { tokenAppliedHandler = nil }
    }

    #if DEBUG
    /// Test-only escape hatch from the one-shot rule: point an
    /// already-wired controller at a fake transport. `internal` and
    /// `DEBUG`-only, so no shipping code can swap the transport mid-flight.
    func replaceTransportForTesting(_ transport: any Transport) {
        lock.withLock { _transport = transport }
    }
    #endif

    /// The installed transport, copied out under `lock`. Throws the same
    /// "HTTP client not configured" error the unwired legacy closure did.
    private func requireTransport() throws -> any Transport {
        guard let transport = lock.withLock({ _transport }) else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        return transport
    }

    // MARK: - Token Management

    public func getToken() -> String? {
        return lock.withLock { currentToken }
    }

    public func getUserId() -> String? {
        return lock.withLock { currentUserId }
    }

    public func isAuthenticated() -> Bool {
        return lock.withLock { currentToken != nil && currentUserId != nil }
    }

    public func getAuthState() -> AuthState {
        return lock.withLock {
            AuthState(
                authenticated: currentToken != nil,
                mode: networkMode,
                userId: currentUserId
            )
        }
    }

    public func getJwtPayload() -> [String: Any]? {
        return lock.withLock { jwtPayload }
    }

    /// Bootstrap with an initial token (on startup).
    ///
    /// Sets state ONLY — no `.authSuccess`, no `.authState`, no applied-token
    /// notification. The constructor token is not a sign-in: the app supplied
    /// it, so nothing changed from the app's point of view, and the client
    /// opens its own socket during init. This mirrors JS
    /// `authController.bootstrapToken`, which deliberately skips
    /// `applyTokenEffects` (#2657, audit item A10).
    ///
    /// Silent on events, NOT on storage: the constructor token still has to
    /// reach the JWT store, or the next session has nothing to restore
    /// (`PersistenceTests.testJwtTokenPersistenceAcrossSessions`).
    ///
    /// Silent, but not blind: writing state directly skips `applyToken`'s
    /// logout guard, so the write is refused when a `logout()` has since
    /// blocked non-interactive auth, or when a different token is already
    /// installed. Without that, a bootstrap that runs late (the client
    /// re-bootstrapped after storage bound) could reinstate — and re-persist —
    /// a token the user had just logged out of, with no event and no hook to
    /// tell anyone.
    public func bootstrapToken(_ token: String?) {
        guard let token = token, !token.isEmpty else {
            markAuthReady()
            return
        }
        let installed = lock.withLock { () -> Bool in
            if blockNonInteractiveAuth { return false }
            if let current = currentToken, current != token { return false }
            currentToken = token
            let payload = Self.parseJwtPayload(token: token)
            jwtPayload = payload
            currentUserId = Self.extractUserId(from: payload)
            return true
        }
        guard installed else {
            logger.debug("Ignoring bootstrap token — a newer session state won")
            markAuthReady()
            return
        }
        resetRefreshBackoff("bootstrap")
        schedulePersist(token)
        markAuthReady()
    }

    /// Persist the token the controller holds *now*.
    ///
    /// `JsBaoClient` calls this once its storage provider is bound: the
    /// constructor token is applied synchronously during init, before there is
    /// anywhere to write it. Deliberately not a second `bootstrapToken(...)` —
    /// by the time storage binds the app may have logged out or signed in
    /// again, and re-applying the constructor token would quietly undo that.
    /// A no-op when no token is held.
    ///
    /// Reads the token and registers the write in ONE critical section, and
    /// refuses once a `logout()` has blocked non-interactive auth. Reading
    /// through `getToken()` and then queueing under a second lock acquisition
    /// left a window in between: a `logout()` landing there clears the token,
    /// drains the queue and deletes the record, and the write queued after it
    /// resurrects the session the user just ended on the next launch. Inside
    /// one critical section the two orders are both safe — queue first and
    /// `awaitPendingPersistence()` drains it before the delete; lose the race
    /// and there is no token left to write.
    public func persistCurrentToken() {
        lock.withLock {
            guard !blockNonInteractiveAuth, let token = currentToken else { return }
            schedulePersistLocked(token)
        }
    }

    /// Update the current token.
    ///
    /// An unnamed cause is `"manual"` — the JS client's default for a direct
    /// `setToken` (`JsBaoClient.setToken`), which is what this entry point is
    /// (#2657, audit item A10).
    ///
    /// This is the app handing the client a token it obtained itself, so it is
    /// an explicit sign-in whatever the caller names it: the cause travels on
    /// the event, but the sign-in classification does not depend on it. Reading
    /// the classification off the string alone meant the documented
    /// `updateToken(jwt, cause: "external")` was dropped by the logout guard —
    /// no token, no events, no socket — while the same call with the default
    /// cause signed in. Internal, non-interactive applications (refresh,
    /// restore, the server's `token_refresh` push) go through `applyToken` /
    /// `applyServerPushedToken` and stay blocked.
    public func updateToken(_ token: String?, cause: String? = nil) {
        let previous = getToken()
        applyToken(token, previous: previous, cause: cause ?? "manual", explicitSignIn: true)
    }

    /// Apply a token the server pushed over the live socket (`token_refresh`).
    ///
    /// Internal and NOT an explicit sign-in: it is the server rotating the
    /// session, the very thing the logout guard exists to catch, so it stays
    /// subject to it.
    func applyServerPushedToken(_ token: String) {
        applyToken(token, previous: getToken(), cause: "token_refresh")
    }

    /// Causes that represent an explicit, caller-initiated sign-in (as
    /// opposed to a background token refresh or persisted-session restore).
    /// The logout guard reads it: only a real sign-in lifts the block a
    /// `logout()` left behind. (The client's connection re-arm used to read it
    /// too; since #2657 the re-arm keys off "a token where there was none",
    /// which is JS's own test, so it no longer needs the classification.)
    ///
    /// The vocabulary is the JS client's since #2657 (audit item A10):
    /// `oauthCallback` / `magicLinkVerify` / `otpVerify` / `passkeyAuth`.
    /// `apple` has no JS counterpart — native Sign in with Apple is a
    /// Swift-only flow — so it keeps its own name.
    ///
    /// `manual` belongs here for the same reason the four flows do: it is the
    /// unnamed public `updateToken`/`setToken`, an app handing the client a
    /// token it obtained itself, which is a sign-in and not the in-flight
    /// refresh the guard exists to catch. Leaving it out meant an app doing
    /// its own auth could never sign back in after a `logout()` — JS, which
    /// has no guard at all, just signs in (#2657, audit item A3). Internal
    /// applications keep their own causes (`httpRefresh`,
    /// `persisted-hydrate`, `token_refresh` for the server push), so they stay
    /// blocked.
    ///
    /// A caller-named cause does NOT have to appear here to sign in: the public
    /// `updateToken` passes `explicitSignIn` and is classified by the entry
    /// point it came through, not by the string it chose (the documented
    /// `cause: "external"` is a sign-in too). This list is what still resolves
    /// the question for applications that carry only a cause.
    static func isInteractiveLogin(_ cause: String?) -> Bool {
        switch cause {
        case "oauthCallback", "apple", "magicLinkVerify", "otpVerify", "passkeyAuth", "manual":
            return true
        default:
            return false
        }
    }

    /// Derive the user id from a decoded JWT payload: the canonical nested
    /// `user.userId` claim first, then the legacy top-level `userId`, then
    /// `sub`. The first two steps and their order are the JS client's
    /// (`authController.getUserId`); `sub` is the last resort JS keeps in
    /// `extractUserIdFromPayload` and swift-client has always had. Reading only
    /// the top level meant a token carrying just the canonical claim — what the
    /// server issues — looked signed out (#2657, audit item A11).
    static func extractUserId(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let nested = (payload["user"] as? [String: Any])?["userId"] as? String
        for candidate in [nested, payload["userId"] as? String, payload["sub"] as? String] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// A precondition on the token held right now, evaluated inside
    /// `applyToken`'s critical section so the check and the mutation it guards
    /// cannot interleave.
    enum HeldTokenPrecondition: Sendable {
        /// Apply whatever is held.
        case none
        /// Apply only while the held token is still this one. The rejected
        /// refresh passes it: the rejection belongs to the session that owned
        /// the refresh, so a session established while it was in flight must
        /// survive it (#2655 — the rejection-side mirror of `onlyWhenSignedOut`).
        case unchangedFrom(String?)
    }

    /// Apply a new token, updating internal state and emitting events.
    ///
    /// - Parameter onlyWhenSignedOut: drop the application if a token is
    ///   already held. The startup refresh passes this: it exists to fill an
    ///   empty session, and an app that shows a login screen at launch can
    ///   complete `otpVerify` while that refresh is still in flight. Without
    ///   the guard an older `rt-{appId}` cookie — possibly a different user's —
    ///   would replace the session the user just signed into (#2656).
    /// - Parameter explicitSignIn: the application came through the public
    ///   token API, so it is a sign-in whatever its cause string says. Only
    ///   `updateToken` passes it.
    /// - Parameter requiring: drop the application unless the token held now
    ///   still matches. Unlike `onlyWhenSignedOut` this also guards *clearing*
    ///   the token, which is what a rejected refresh does.
    /// - Returns: `true` when the token was applied, `false` when a guard
    ///   dropped it — callers with follow-up work (deleting the persisted JWT)
    ///   must skip it in the latter case.
    @discardableResult
    func applyToken(
        _ token: String?,
        previous: String?,
        cause: String?,
        onlyWhenSignedOut: Bool = false,
        explicitSignIn: Bool = false,
        requiring precondition: HeldTokenPrecondition = .none
    ) -> Bool {
        let isSignIn = explicitSignIn || Self.isInteractiveLogin(cause)
        // Logout race guard: a refresh/restore that resolves AFTER the
        // user logged out must not silently sign them back in (or
        // re-persist the JWT). Drop non-interactive token applications
        // until an explicit interactive login clears the flag.
        // The check-and-mutate stays atomic in one critical section; a
        // `nil` result signals the guard dropped the application so we
        // log and return outside the lock exactly as before. The
        // signed-out-only check rides in the same section for the same
        // reason: read-then-apply outside the lock would reopen the race
        // it is closing.
        enum DropReason { case loggedOut, signedIn, superseded }
        var dropReason: DropReason = .loggedOut
        let applied: (newUserId: String?, newToken: String?)? = lock.withLock {
            if token != nil, blockNonInteractiveAuth, !isSignIn {
                return nil
            }
            if token != nil, onlyWhenSignedOut, currentToken != nil {
                dropReason = .signedIn
                return nil
            }
            if case .unchangedFrom(let expected) = precondition, currentToken != expected {
                dropReason = .superseded
                return nil
            }
            if token != nil, isSignIn {
                blockNonInteractiveAuth = false
            }
            currentToken = token

            if let token = token {
                let payload = Self.parseJwtPayload(token: token)
                jwtPayload = payload
                currentUserId = Self.extractUserId(from: payload)
            } else {
                jwtPayload = nil
                currentUserId = nil
            }
            return (currentUserId, currentToken)
        }

        guard let (newUserId, newToken) = applied else {
            switch dropReason {
            case .signedIn:
                logger.debug("Ignoring token application (cause:", cause ?? "unknown", ") — a session was established while it was in flight")
            case .superseded:
                logger.debug("Ignoring token application (cause:", cause ?? "unknown", ") — it refers to a session that is no longer the current one")
            case .loggedOut:
                logger.debug("Ignoring token application (cause:", cause ?? "unknown", ") — logged out, awaiting explicit login")
            }
            return false
        }

        // A token landing from ANY path (bootstrap, interactive login, a
        // successful refresh, logout clearing it) makes a deferred refresh
        // moot: cancel the pending retry and clear the accumulated backoff.
        // Mirrors the JS `resetRefreshBackoff("bootstrap" / "token-updated")`
        // calls in `bootstrapToken` / `updateToken`.
        resetRefreshBackoff("token-updated")

        // The mode is read through the locked accessor at each construction
        // site below rather than hoisted into a local here. Hoisting would be
        // one fewer lock acquisition, but an `.authSuccess` listener that
        // switches the client online — a realistic reaction to signing in —
        // would then see a stale mode in the `AuthStateEvent` that follows,
        // where the pre-#1993 code read the stored property inline at each
        // event. Reading through the accessor keeps the `@unchecked Sendable`
        // argument's "every mutable field is lock-confined" claim true without
        // changing when the value is sampled.

        if let newToken = newToken {
            logger.debug("Token applied", "userId:", newUserId ?? "nil", "cause:", cause ?? "unknown")
            // A sign-in needs a user. JS gates both emissions on a derivable
            // userId (`applyTokenEffects`), so a token the client cannot read a
            // user out of is not reported as a successful sign-in (#2657, audit
            // item A10) — the session is still installed, it is just not
            // announced as somebody arriving.
            if let newUserId {
                emitter?.emit(AuthSuccessEvent(
                    token: newToken,
                    previousToken: previous,
                    cause: cause
                ))
                emitter?.emit(AuthStateEvent(
                    authenticated: true,
                    mode: getNetworkMode(),
                    userId: newUserId
                ))
            }
            // Re-authenticate an open WebSocket with the token that just
            // landed, rather than leaving the connection running on the
            // previous identity until it is closed and rebuilt (#2660). JS does
            // this from the same point in `applyTokenEffects`, after the auth
            // events.
            let notify = lock.withLock { tokenAppliedHandler }
            notify?(newToken, previous)
        } else if previous != nil {
            emitter?.emit(AuthStateEvent(
                authenticated: false,
                mode: getNetworkMode(),
                userId: nil
            ))
        }

        schedulePersist(newToken)

        return true
    }

    /// Queue the configured JWT persistence for a token that has just been
    /// installed. Every path that installs one calls this, `bootstrapToken`
    /// included — that path emits nothing, but a constructor token never
    /// written to storage leaves the next session with nothing to restore
    /// (#2657).
    private func schedulePersist(_ token: String?) {
        guard let token else { return }
        lock.withLock { schedulePersistLocked(token) }
    }

    /// The queueing half of `schedulePersist`, for callers that already hold
    /// `lock` because the token they are writing has to be read in the same
    /// critical section (`persistCurrentToken`).
    ///
    /// Each write is chained onto the one before it rather than replacing the
    /// handle. `awaitPendingPersistence()` is the barrier the sign-out paths
    /// take before deleting the record (#2655), and a bare "latest task wins"
    /// handle would let an earlier, slower write finish AFTER that delete and
    /// resurrect the session the user just ended. Chaining also keeps two
    /// writes from reaching the store out of order. The read-modify-write of
    /// the chain tail happens in one critical section; `Task {}` only
    /// schedules, so nothing awaits under the lock.
    ///
    /// - Precondition: `lock` is held.
    private func schedulePersistLocked(_ token: String) {
        guard persistConfig.persistJwtInStorage else { return }
        let previousWrite = pendingPersistTask
        pendingPersistTask = Task { [logger] in
            await previousWrite?.value
            do {
                try await persistJwt(token: token)
            } catch {
                // Don't swallow persistence errors silently — without this
                // log, a disk-full or SQLite-corruption issue would leave
                // the user appearing logged in until restart, with no clue
                // why they were unexpectedly logged out the next session.
                logger.warn("Failed to persist JWT:", error.localizedDescription)
            }
        }
    }

    /// Wait for every queued JWT persistence write to drain. Called from
    /// `JsBaoClient.destroy()` so the storage layer doesn't close the
    /// SQLite connection out from under a queued write, and by the sign-out
    /// paths so a write cannot land after the record is deleted. Awaiting the
    /// tail of the chain awaits all of it. Safe to call when no Task is in
    /// flight (no-op).
    public func awaitPendingPersistence() async {
        let task = lock.withLock { pendingPersistTask }
        await task?.value
    }

    // MARK: - Token Refresh

    /// In-flight refresh Task. When non-nil, concurrent refresh callers
    /// await *this* Task instead of starting a duplicate refresh — so a
    /// burst of N concurrent 401s on the wire produces exactly **one**
    /// `POST /auth/refresh` round trip, not N. Mirrors the JS client's
    /// refresh-coalescing behavior, and on servers that rotate refresh
    /// cookies (revoking the prior refresh JWT after each successful
    /// refresh) prevents the "first call wins, others see 401, cascade
    /// of auth-failed events" failure mode.
    private var pendingRefresh: Task<RefreshOutcome, Never>?

    public func refreshAccessToken(cause: String? = nil) async -> RefreshOutcome {
        // Coalesce: if another caller is already running a refresh,
        // await its outcome instead of starting a new round trip. The
        // check-and-register must be atomic so a burst of concurrent
        // callers registers exactly one refresh Task — hence a single
        // `withLock`. The refresh itself runs in the escaping `Task{}`
        // and is awaited OUTSIDE the lock (never hold the lock across an
        // `await`); single-flight is preserved.
        enum RefreshStart {
            case existing(Task<RefreshOutcome, Never>)
            case started(Task<RefreshOutcome, Never>)
        }
        let start: RefreshStart = lock.withLock {
            if let inFlight = pendingRefresh {
                return .existing(inFlight)
            }
            let task = Task<RefreshOutcome, Never> { [weak self] in
                guard let self = self else { return .network(nil) }
                return await self._refreshAccessTokenImpl(cause: cause)
            }
            pendingRefresh = task
            return .started(task)
        }

        switch start {
        case .existing(let inFlight):
            return await inFlight.value
        case .started(let task):
            let outcome = await task.value
            lock.withLock { pendingRefresh = nil }
            return outcome
        }
    }

    /// Causes that identify the launch-time refresh — the one that runs before
    /// the app has a session, rather than refreshing an existing one (#2656).
    ///
    /// Two consequences hang off it: its rejection is a silent signed-out start
    /// (no `authFailed`, the port of JS's `shouldEmitAuthFailed` check in
    /// `handleRefreshOutcome`), and its success only applies while the client
    /// is still signed out (see `applyToken(onlyWhenSignedOut:)`).
    ///
    /// Not needed on the sign-out side: `handleRefreshFailure` guards every
    /// cause the same way, by the session the refresh started from, which
    /// subsumes the bootstrap case (that one starts from no session at all).
    private static func isBootstrapCause(_ cause: String?) -> Bool {
        switch cause {
        case "startup", "bootstrap", "bootstrap:refresh": return true
        default: return false
        }
    }

    /// The cause the 401-retry (and pre-expiry) refresh on the request path
    /// carries — `JsBaoClient` passes it when it wires `HttpClient`'s refresh
    /// to this controller. Named because `authFailedEvent(cause:)` has to
    /// recognise it.
    static let httpRequestCause = "http"

    /// The `authFailed` event a rejected refresh delivers to the app, or `nil`
    /// when this cause delivers none. Port of the JS client's TWO emit sites,
    /// which between them decide the whole table (#2723):
    ///
    ///   * `handleRefreshOutcome` (src/client/internal/authController.ts) emits
    ///     for every cause EXCEPT `"http-request"` and `"bootstrap:refresh"`,
    ///     reporting the cause itself as the `reason`.
    ///   * `JsBaoClient`'s `onRefreshOutcome` wiring emits the bare
    ///     `{ reason: "refresh_failed" }` for exactly the 401-retry cause the
    ///     first site suppresses.
    ///
    /// So the launch refresh is silent, the request path's refresh reports
    /// `refresh_failed`, and every other cause reports itself. This client has a
    /// single emit site, so it makes the whole choice here rather than splitting
    /// it. Before #2723 it reported `invalid_token` for all three, which is a
    /// vocabulary no JS app ever sees.
    ///
    /// Pinned on both sides — `tests/client/js-bao-client-auth-failed-parity.test.ts`
    /// and `AuthFailedRefreshParityHermeticTests`.
    private static func authFailedEvent(cause: String?) -> AuthFailedEvent? {
        // A signed-out start is not an auth failure (#2656).
        if isBootstrapCause(cause) { return nil }
        if cause == httpRequestCause {
            // JS's payload at this site carries a reason and nothing else.
            return AuthFailedEvent(message: nil, reason: "refresh_failed")
        }
        return AuthFailedEvent(
            // JS derives the message from the rejection's error and falls back
            // to this. A refresh the server *answered* — 401, or 2xx with no
            // token — reaches its emit site with no error attached, so the
            // fallback is the only message that path can produce there.
            message: "Authentication refresh failed",
            reason: cause ?? "refresh_invalid"
        )
    }

    private func _refreshAccessTokenImpl(cause: String? = nil) async -> RefreshOutcome {
        logger.debug("Refreshing access token", "cause:", cause ?? "unknown")

        // The session this refresh belongs to. A rejection only ends *this*
        // session: whatever else may be signed in by the time the answer comes
        // back was not what the server rejected (see `handleRefreshFailure`).
        let sessionAtStart = getToken()

        do {
            let newToken: String

            if let proxy = refreshProxy, proxy.enabled {
                newToken = try await refreshViaProxy(proxy: proxy)
            } else {
                newToken = try await refreshDirect()
            }

            resetRefreshBackoff("refresh-success")

            let previous = getToken()
            // A startup refresh only ever fills an empty session: if anything
            // signed the client in while it was in flight, that session wins
            // (#2656). Every other cause is a refresh OF the current session,
            // so it applies unconditionally.
            applyToken(
                newToken,
                previous: previous,
                cause: "httpRefresh",
                onlyWhenSignedOut: Self.isBootstrapCause(cause)
            )
            return .success
        } catch let error as HttpError where error.status == 401 {
            // Only 401 means "this session is over" — 403 and 5xx are
            // connectivity-class failures and fall through to the retryable
            // path below, matching the JS `tryRefreshAccessToken`
            // classification (src/client/internal/httpClient.ts). Issue #2655.
            logger.warn("Token refresh returned invalid:", error.status)
            resetRefreshBackoff("refresh-invalid")
            await handleRefreshFailure(sessionAtStart: sessionAtStart)
            if let event = Self.authFailedEvent(cause: cause) {
                emitter?.emit(event)
            }
            return .invalid
        } catch is RefreshTokenMissingError {
            // A 2xx whose body carries no `token`: the server answered, so
            // retrying on backoff would never recover. JS returns "invalid"
            // here (`if (!newToken) return "invalid"`). Issue #2655.
            logger.warn("Token refresh succeeded without a token; treating as invalid")
            resetRefreshBackoff("refresh-invalid")
            // Same sign-out and same `authFailed` table as the 401 path above —
            // JS classifies both as `"invalid"` and hands them to one place.
            await handleRefreshFailure(sessionAtStart: sessionAtStart)
            if let event = Self.authFailedEvent(cause: cause) {
                emitter?.emit(event)
            }
            return .invalid
        } catch {
            logger.warn("Token refresh network error:", error.localizedDescription)
            handleRefreshDeferred(cause: cause ?? "network_error", error: error)
            // Carry the underlying failure so the 401 retry path can rethrow
            // it as `JsBaoNetworkError` instead of inventing a 401.
            return .network(JsBaoNetworkError(refreshFailure: error))
        }
    }

    /// End the session after a refresh the server rejected. Port of the JS
    /// `handleRefreshFailure()` → `updateToken(null)` path
    /// (src/client/internal/authController.ts): the dead access token is
    /// dropped — which emits `authState{authenticated:false}` through
    /// `applyToken` — and the persisted JWT record is deleted so the next
    /// launch does not restore a session the server has already ended.
    /// Issue #2655.
    ///
    /// `sessionAtStart` is the token the refresh set out to renew, and the
    /// sign-out is a compare-and-clear against it. A refresh round trip is not
    /// instantaneous, and anything can land while it is open: the startup
    /// refresh runs with no session at all and an app that shows a login screen
    /// at launch can complete `otpVerify` before the stale cookie is rejected;
    /// a refresh of session A can be answered after B signed in. In both cases
    /// the rejection refers to a session that is no longer current, and clearing
    /// the token — or deleting the persisted record, which belongs to the new
    /// session — would sign out a user the server never rejected. This is the
    /// rejection-side mirror of the `applyToken(onlyWhenSignedOut:)` guard #2656
    /// added on the success side; JS, single-threaded, cannot interleave here.
    private func handleRefreshFailure(sessionAtStart: String?) async {
        // Checked inside `applyToken`'s critical section: reading the current
        // token here and clearing it afterwards would leave exactly the gap
        // this guard exists to close.
        let cleared = applyToken(
            nil,
            previous: sessionAtStart,
            cause: "refreshFailed",
            requiring: .unchangedFrom(sessionAtStart)
        )
        guard cleared else {
            logger.debug("Rejected refresh did not end the session — a newer one was established while it was in flight")
            return
        }
        // Deleted without consulting `persistJwtInStorage`, as in JS: a record
        // written while persistence was enabled must not survive a later run
        // with it off. Any queued persistence drains first so a write cannot
        // land after the delete.
        await awaitPendingPersistence()
        // The drain is an `await`, so re-check: a sign-in during it owns
        // whatever record is on disk now, and deleting that one would sign the
        // new user out at the next launch.
        guard getToken() == nil else {
            logger.debug("Keeping the persisted JWT — a session was established while the sign-out drained")
            return
        }
        try? await clearPersistedJwt()
    }

    // MARK: - Refresh Retry Backoff (#2022)

    /// Handle a refresh that failed for connectivity reasons: schedule the
    /// next attempt, re-report an already-scheduled one, or give up and go
    /// offline once the accumulated backoff reaches the cap. Port of the JS
    /// `handleRefreshDeferred`.
    private func handleRefreshDeferred(cause: String?, error: Error?) {
        enum Decision {
            case destroyed
            case alreadyOffline
            case alreadyScheduled(delayMs: Int)
            case capReached
            case schedule(delayMs: Int)
        }

        // One critical section so two concurrent deferrals can't both decide
        // to schedule (which would stack timers and double the retry rate).
        let decision: Decision = lock.withLock {
            // A refresh that was in flight when `destroy()` ran can land here
            // afterwards; scheduling a retry now would run background work
            // against a torn-down client.
            if destroyed {
                return .destroyed
            }
            if networkMode == .offline {
                return .alreadyOffline
            }
            if refreshRetryScheduled {
                return .alreadyScheduled(delayMs: refreshBackoffDelayMs)
            }

            let nextDelay = refreshBackoffDelayMs == 0
                ? refreshBackoffBaseMs
                : min(refreshBackoffDelayMs, refreshBackoffCapMs)

            let projectedAccum = refreshBackoffAccumMs + nextDelay
            if projectedAccum >= refreshBackoffCapMs {
                return .capReached
            }

            refreshBackoffAccumMs = projectedAccum
            refreshBackoffDelayMs = min(nextDelay * refreshBackoffMultiplier, refreshBackoffCapMs)
            refreshRetryScheduled = true
            refreshRetryEpoch += 1
            return .schedule(delayMs: nextDelay)
        }

        switch decision {
        case .destroyed:
            logger.debug("Ignoring deferred refresh after destroy", "cause:", cause ?? "unknown")

        case .alreadyOffline:
            emitAuthRefreshDeferred(status: "offline", cause: cause)

        case .alreadyScheduled(let delayMs):
            emitAuthRefreshDeferred(status: "scheduled", cause: cause, nextAttemptMs: delayMs)

        case .capReached:
            resetRefreshBackoff("backoff-cap-reached")
            applyOfflineNetworkMode()
            emitAuthRefreshDeferred(
                status: "offline",
                cause: cause,
                error: error?.localizedDescription
            )

        case .schedule(let delayMs):
            emitAuthRefreshDeferred(status: "scheduled", cause: cause, nextAttemptMs: delayMs)
            scheduleRefreshRetry(afterMs: delayMs, cause: cause)
        }
    }

    /// Start the background retry. The caller has already marked
    /// `refreshRetryScheduled` and bumped `refreshRetryEpoch` inside the
    /// decision lock, so the fast path is correct even if this Task finishes
    /// before the `refreshRetryTask` assignment below.
    private func scheduleRefreshRetry(afterMs: Int, cause: String?) {
        let epoch = lock.withLock { refreshRetryEpoch }
        let task = Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, afterMs)) * 1_000_000)
            guard let self = self, !Task.isCancelled else { return }

            // A reset (success / invalid / new token / destroy) that landed
            // while this Task slept bumped the epoch — that retry is stale.
            let stillCurrent = self.lock.withLock { () -> Bool in
                guard !self.destroyed,
                      self.refreshRetryEpoch == epoch,
                      self.refreshRetryScheduled else {
                    return false
                }
                self.refreshRetryScheduled = false
                self.refreshRetryTask = nil
                return true
            }
            guard stillCurrent else { return }

            self.logger.debug(
                "Retrying refresh after backoff",
                "delayMs:", String(afterMs),
                "cause:", cause ?? "unknown"
            )
            _ = await self.refreshAccessToken(cause: "backoff-retry")
        }

        // Only hold on to the Task while it's still the current one; if it
        // already ran (or was reset) there's nothing left to cancel.
        lock.withLock {
            if refreshRetryEpoch == epoch, refreshRetryScheduled {
                refreshRetryTask = task
            }
        }
    }

    /// Cancel any pending retry and clear the accumulated backoff. Port of the
    /// JS `resetRefreshBackoff`. Safe to call from inside the retry Task (it
    /// clears its own bookkeeping first, so this finds nothing to cancel).
    private func resetRefreshBackoff(_ reason: String) {
        let pending: Task<Void, Never>? = lock.withLock {
            let task = refreshRetryTask
            refreshRetryTask = nil
            refreshRetryScheduled = false
            refreshRetryEpoch += 1
            refreshBackoffDelayMs = 0
            refreshBackoffAccumMs = 0
            return task
        }
        pending?.cancel()
        logger.debug("Refresh backoff reset", "reason:", reason)
    }

    /// Take the client offline after the backoff cap. Goes through the
    /// client-level hook when wired so the `networkMode` event fires once;
    /// falls back to the controller's own mode when standalone.
    private func applyOfflineNetworkMode() {
        if let setClientNetworkMode = setClientNetworkMode {
            setClientNetworkMode(.offline)
        } else {
            setNetworkMode(.offline)
        }
    }

    private func emitAuthRefreshDeferred(
        status: String,
        cause: String?,
        nextAttemptMs: Int? = nil,
        error: String? = nil
    ) {
        logger.debug("Emitting auth-refresh-deferred", "status:", status)
        emitter?.emit(AuthRefreshDeferredEvent(
            status: status,
            cause: cause,
            nextAttemptMs: nextAttemptMs,
            error: error
        ))
    }

    /// Cancel background work owned by the controller. Called from
    /// `JsBaoClient.destroy()`; also runs on `deinit` as a safety net so a
    /// dropped controller can't fire a refresh afterwards.
    ///
    /// Marks the controller destroyed *before* cancelling the current retry, so
    /// a refresh that is still in flight can't slip its network failure past
    /// the cancellation and schedule a replacement retry. Idempotent.
    public func destroy() {
        lock.withLock { destroyed = true }
        resetRefreshBackoff("destroy")
    }

    deinit {
        refreshRetryTask?.cancel()
    }

    /// Refresh the access token in answer to a server auth challenge — an HTTP
    /// 401, or an `auth_required` / `auth_failed` WebSocket frame (#2660).
    ///
    /// The cause is the fixed string `"ws-challenge"`, matching the JS client,
    /// so an app watching `authRefreshDeferred` reads the same value on both
    /// platforms. The frame's own reason is logged rather than folded into the
    /// cause, which would make the string unpredictable.
    public func handleAuthChallenge(reason: String? = nil) async -> Bool {
        logger.debug("Handling auth challenge", "reason:", reason ?? "unspecified")
        let outcome = await refreshAccessToken(cause: "ws-challenge")
        return outcome == .success
    }

    // MARK: - JWT Parsing

    public static func parseJwtPayload(token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        // Pad base64 to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Check if a token is expiring within the given threshold (seconds)
    public static func isTokenExpiring(token: String, thresholdSeconds: TimeInterval = 120) -> Bool {
        guard let payload = parseJwtPayload(token: token),
              let exp = payload["exp"] as? TimeInterval else {
            return false
        }
        return exp - Date().timeIntervalSince1970 < thresholdSeconds
    }

    // MARK: - OAuth

    /// Start the OAuth flow. Mirrors JS `authController.startOAuthFlow`
    /// (src/client/internal/authController.ts): fetch the app's auth config
    /// (`GET /oauth-config`), require a usable `ios` client entry, and build
    /// the Google authorize URL client-side with the base64-JSON state bag
    /// `{nonce, redirectUri, continueUrl?}`. Where the JS client redirects the
    /// browser, this returns the URL for the caller to open (e.g. via
    /// `ASWebAuthenticationSession` — see `JsBaoClient.signInWithGoogle`).
    public func startOAuthFlow(
        redirectUri: String,
        continueUrl: String? = nil,
        waitlist: OAuthWaitlist? = nil,
        inviteToken: String? = nil
    ) async throws -> URL {
        let transport = try requireTransport()

        let config: AuthConfigInfo = try await transport.request(
            method: .get,
            path: "/oauth-config"
        )
        // The same predicate the button gates on, re-checked here so a caller
        // that skipped `checkOAuthAvailable()` cannot start a flow that can
        // only fail — including on an app whose provider is switched off, which
        // the server now rejects at the callback too (#2891).
        guard config.googleSignInAvailable,
              let googleClientId = config.nativeGoogleClient?.clientId
        else {
            throw JsBaoError(code: .unavailable, message: "OAuth not configured")
        }

        // PKCE (RFC 7636): generate a fresh verifier+challenge pair for this
        // flow. The challenge (base64url SHA-256 of the verifier) goes to
        // Google on the authorize URL; the verifier is held on `self` until
        // `handleOAuthCallback` sends it to our server with the code
        // exchange. Together they prove the client exchanging the code is
        // the one that started the flow — replacing the client_secret that
        // confidential (web) OAuth clients use. Native iOS clients have no
        // secret, so PKCE is what makes the native flow work. Servers that
        // don't support PKCE yet simply ignore the extra parameters.
        let verifier = Self.generatePkceVerifier()
        let challenge = Self.pkceChallenge(forVerifier: verifier)
        lock.withLock { pendingCodeVerifier = verifier }

        let state = try Self.encodeOAuthState(
            redirectUri: redirectUri,
            continueUrl: continueUrl,
            waitlist: waitlist,
            inviteToken: inviteToken
        )
        return try Self.buildGoogleAuthorizationUrl(
            googleClientId: googleClientId,
            redirectUri: redirectUri,
            state: state,
            codeChallenge: challenge
        )
    }

    /// Exchange the authorization code for a session token. Mirrors JS
    /// `exchangeOAuthCode` (src/client/internal/authController.ts):
    /// `GET /oauth/callback?code=&state=` returns `{token, isNewUser}` plus
    /// the `rt-{appId}` HttpOnly refresh cookie (handled transparently by
    /// `URLSession`'s shared cookie storage). Applies the token with cause
    /// `"oauthCallback"`, which emits `.authSuccess` / `.authState` like every other
    /// interactive sign-in path. Returns the typed server response so callers
    /// can read `isNewUser`.
    @discardableResult
    public func handleOAuthCallback(code: String, state: String) async throws -> OAuthCallbackResult {
        let transport = try requireTransport()

        // PKCE: consume the verifier from the most recent startOAuthFlow.
        // Cleared whether the exchange succeeds or fails so a stale verifier
        // can't leak into a later attempt. Callers that never went through
        // startOAuthFlow (e.g. resuming a web-started flow) have no verifier
        // and the legacy GET path is used — same wire shape as before.
        let codeVerifier = lock.withLock { () -> String? in
            let verifier = pendingCodeVerifier
            pendingCodeVerifier = nil
            return verifier
        }

        // The server only reads the verifier from the native JSON endpoint
        // (`POST /auth/oauth/callback`, body `{code, state, codeVerifier}` —
        // OAuthController.callbackJson); the web `GET /oauth/callback` never
        // looks at a code_verifier param. So: verifier → POST, none → GET.
        let result: OAuthCallbackResult
        if let codeVerifier {
            let body: [String: JSONValue] = [
                "code": .string(code),
                "state": .string(state),
                "codeVerifier": .string(codeVerifier),
            ]
            result = try await transport.request(
                method: .post,
                path: "/auth/oauth/callback",
                body: body
            )
        } else {
            let path = try Self.oauthCallbackPath(code: code, state: state)
            result = try await transport.request(method: .get, path: path)
        }

        let previous = getToken()
        applyToken(result.token, previous: previous, cause: "oauthCallback")
        return result
    }

    // MARK: - Sign in with Apple

    /// Exchange a native Sign in with Apple credential for a session token.
    /// `POST /auth/apple/callback` with the JSON body
    /// `{identityToken, nonce, user, email?, firstName?, lastName?, inviteToken?}` —
    /// the contract of the server's `AppleAuthController` (#409):
    ///  * `identityToken` — Apple's JWT (`credential.identityToken`, UTF-8).
    ///  * `nonce` — the **raw** nonce; the client put its SHA-256 (lowercase
    ///    hex) on `ASAuthorizationAppleIDRequest.nonce`, and the server
    ///    re-hashes this raw value to check the token's `nonce` claim.
    ///  * `user` — Apple's stable user identifier (`credential.user`).
    ///  * `email` / `firstName` / `lastName` — first-authorization hints
    ///    (Apple only provides them once per user+app).
    ///  * `inviteToken` — optional invitation token (#1467); the server
    ///    accepts the invitation and resolves its deferred grants during a
    ///    first sign-in. Omitted from the body when nil or empty.
    /// The response is `{token, isNewUser}` plus the `rt-{appId}` HttpOnly
    /// refresh cookie (handled by `URLSession`'s cookie storage). Applies
    /// the token with cause `"apple"`, emitting `.authSuccess` /
    /// `.authState` like the other interactive sign-in paths. Returns the
    /// typed server response so callers can read `isNewUser`.
    @discardableResult
    public func handleAppleCallback(
        identityToken: String,
        rawNonce: String,
        user: String,
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        inviteToken: String? = nil
    ) async throws -> OAuthCallbackResult {
        let transport = try requireTransport()

        let body = AppleSignInHelpers.callbackBody(
            identityToken: identityToken,
            rawNonce: rawNonce,
            user: user,
            email: email,
            firstName: firstName,
            lastName: lastName,
            inviteToken: inviteToken
        )
        let result: OAuthCallbackResult = try await transport.request(
            method: .post,
            path: "/auth/apple/callback",
            body: body
        )

        let previous = getToken()
        applyToken(result.token, previous: previous, cause: "apple")
        return result
    }

    // MARK: - OAuth URL helpers (pure, unit-testable)

    /// Encode the OAuth state bag the server round-trips through Google.
    /// Mirrors the JS shape: `btoa(JSON.stringify({redirectUri, nonce,
    /// continueUrl?}))` — `continueUrl` omitted when absent.
    static func encodeOAuthState(
        redirectUri: String,
        continueUrl: String? = nil,
        waitlist: OAuthWaitlist? = nil,
        inviteToken: String? = nil,
        nonce: String = UUID().uuidString
    ) throws -> String {
        var state: [String: JSONValue] = [
            "nonce": .string(nonce),
            "redirectUri": .string(redirectUri),
        ]
        if let continueUrl, !continueUrl.isEmpty {
            state["continueUrl"] = .string(continueUrl)
        }
        // #466 parity: enroll the user in the waitlist via the OAuth state bag.
        // JS trims both fields and clamps each to 255 chars, and only attaches
        // the `waitlist` key when at least one field survives trimming.
        if let waitlist {
            var entry: [String: JSONValue] = [:]
            if let source = waitlist.source?.trimmingCharacters(in: .whitespacesAndNewlines),
               !source.isEmpty {
                entry["source"] = .string(String(source.prefix(255)))
            }
            if let note = waitlist.note?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                entry["note"] = .string(String(note.prefix(255)))
            }
            if !entry.isEmpty {
                state["waitlist"] = .object(entry)
            }
        }
        // #466 parity: thread the (trimmed) invite token through the state bag.
        // The callback handler reads `stateData.inviteToken` and accepts the
        // named invitation server-side, resolving deferred grants to the new
        // user even when the OAuth email differs from the invited email.
        if let inviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inviteToken.isEmpty {
            state["inviteToken"] = .string(inviteToken)
        }
        let data = try JSONCoding.encodeData(state)
        return data.base64EncodedString()
    }

    /// Build the Google authorize URL exactly like the JS client:
    /// `https://accounts.google.com/o/oauth2/v2/auth` with
    /// `client_id`, `redirect_uri`, `response_type=code`,
    /// `scope="openid email profile"`, and `state` — plus, when
    /// `codeChallenge` is given, the PKCE pair `code_challenge` /
    /// `code_challenge_method=S256` (RFC 7636 §4.3).
    ///
    /// Query values are strictly percent-encoded (RFC 3986 unreserved set)
    /// rather than via `URLComponents.queryItems`, which leaves `+` literal —
    /// Google would decode a literal `+` in the base64 state as a space and
    /// corrupt it.
    static func buildGoogleAuthorizationUrl(
        googleClientId: String,
        redirectUri: String,
        state: String,
        codeChallenge: String? = nil
    ) throws -> URL {
        var params: [(String, String)] = [
            ("client_id", googleClientId),
            ("redirect_uri", redirectUri),
            ("response_type", "code"),
            ("scope", "openid email profile"),
            ("state", state),
        ]
        if let codeChallenge, !codeChallenge.isEmpty {
            params.append(("code_challenge", codeChallenge))
            params.append(("code_challenge_method", "S256"))
        }
        let query = try params.map { name, value in
            "\(name)=\(try Self.strictPercentEncode(value))"
        }.joined(separator: "&")

        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            throw JsBaoError(code: .unavailable, message: "Could not build OAuth URL")
        }
        components.percentEncodedQuery = query
        guard let url = components.url else {
            throw JsBaoError(code: .unavailable, message: "Could not build OAuth URL")
        }
        return url
    }

    /// Request path for the legacy (non-PKCE) code exchange:
    /// `/oauth/callback?code=&state=` with both values strictly
    /// percent-encoded (the base64 state contains `+` / `/` / `=`, all
    /// reserved in queries). PKCE flows don't use this path — the verifier
    /// goes in the JSON body of `POST /auth/oauth/callback` instead, which
    /// is the only place the server reads it.
    static func oauthCallbackPath(
        code: String,
        state: String
    ) throws -> String {
        let encodedCode = try strictPercentEncode(code)
        let encodedState = try strictPercentEncode(state)
        return "/oauth/callback?code=\(encodedCode)&state=\(encodedState)"
    }

    // MARK: - PKCE helpers (pure, unit-testable)

    /// Generate a high-entropy PKCE `code_verifier` per RFC 7636 §4.1:
    /// 32 random bytes, base64url-encoded without padding — 43 characters,
    /// all from the spec's unreserved set, comfortably inside the required
    /// 43–128 range.
    static func generatePkceVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return PasskeyWire.base64UrlEncode(Data(bytes))
    }

    /// Derive the S256 PKCE `code_challenge` for a verifier (RFC 7636 §4.2):
    /// `base64url(sha256(ascii(verifier)))`, no padding.
    static func pkceChallenge(forVerifier verifier: String) -> String {
        PasskeyWire.base64UrlEncode(hashSHA256(Data(verifier.utf8)))
    }

    /// Percent-encode everything outside the RFC 3986 unreserved set
    /// (alphanumerics plus `-._~`), matching JS `encodeURIComponent` for
    /// the characters that matter in OAuth payloads (`+`, `/`, `=`, `:`).
    static func strictPercentEncode(_ value: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw JsBaoError(code: .invalidArgument, message: "Could not percent-encode OAuth parameter")
        }
        return encoded
    }

    /// Apply a verify endpoint's access token, then decode the rest of its
    /// envelope.
    ///
    /// Two rules live here, shared by magic-link / OTP / passkey-finish:
    ///
    /// * **The token is required.** A 2xx without one used to return a
    ///   fully-populated "success" result while the client stayed signed
    ///   out — and since the typed surface no longer exposes the token, the
    ///   caller had no way to notice. The server always sends it on 2xx, so
    ///   its absence is a broken contract and is reported as one.
    /// * **The token is applied first.** Magic-link and OTP tokens are
    ///   single-use: decoding the whole envelope before applying the token
    ///   means a mismatch on a sibling field (say a future `user` shape
    ///   change) burns the credential server-side and leaves the user with
    ///   no session and no retry.
    private func applyVerifiedToken<Envelope: Decodable & Sendable>(
        _ type: Envelope.Type,
        from raw: JSONValue,
        path: String,
        cause: String
    ) throws -> Envelope {
        guard let accessToken = raw["token"]?.stringValue, !accessToken.isEmpty else {
            throw JsBaoError(
                code: .unavailable,
                message: "Verify response carried no access token"
            )
        }
        let previous = getToken()
        applyToken(accessToken, previous: previous, cause: cause)

        do {
            return try JSONCoding.decodeData(Envelope.self, from: JSONCoding.encodeData(raw))
        } catch {
            // `path` is credential-bearing, so the factory redacts the body.
            throw HttpError.decodingFailure(
                path: path,
                expected: Envelope.self,
                body: nil,
                underlying: error
            )
        }
    }

    // MARK: - Email sign-in (#2884)

    /// Request one sign-in email carrying a 6-digit code — and, when a
    /// redirect target is supplied and allow-listed, a magic link too. The
    /// user finishes with whichever one suits them; nothing here selects a
    /// method.
    ///
    /// `redirectUri` is optional, and that is how a code-only email is asked
    /// for: OMIT it and the server issues one from the same template, with no
    /// allow-list involved. A target that IS supplied must match the app's
    /// non-empty `emailRedirectUris` allow-list, or the request is rejected
    /// 400 `Invalid redirect URI` — the server does not fall back to a
    /// code-only email for an un-allow-listed target (#2967).
    public func emailSignInRequest(
        email: String,
        redirectUri: String? = nil
    ) async throws -> Bool {
        let transport = try requireTransport()

        var body: [String: JSONValue] = ["email": .string(email)]
        if let redirectUri = redirectUri, !redirectUri.isEmpty {
            body["redirectUri"] = .string(redirectUri)
        }
        let response: SuccessResponse? = try await transport.requestOptional(
            method: .post,
            path: "/auth/email/request",
            body: body
        )
        return response?.success ?? false
    }

    // MARK: - Magic Link

    /// - Warning: Deprecated by #2884. `/auth/magic-link/request` is now an
    ///   alias of the unified issuance path and sends the same email
    ///   `emailSignInRequest` does. Call `emailSignInRequest` instead.
    public func magicLinkRequest(email: String, redirectUri: String) async throws -> Bool {
        let transport = try requireTransport()

        let body: [String: JSONValue] = [
            "email": .string(email),
            "redirectUri": .string(redirectUri),
        ]
        let response: SuccessResponse? = try await transport.requestOptional(
            method: .post,
            path: "/auth/magic-link/request",
            body: body
        )
        return response?.success ?? false
    }

    public func magicLinkVerify(token: String, inviteToken: String? = nil) async throws -> MagicLinkVerifyResult {
        let transport = try requireTransport()

        // #466: thread the (trimmed) invite token through verify so deferred
        // grants resolve to the signing-in user. Mirrors JS magicLinkVerify.
        let trimmedInviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInviteToken = (trimmedInviteToken?.isEmpty == false) ? trimmedInviteToken : nil

        // The body is the same either way — JS sends no `appId` on the proxy
        // request, and the proxy identifies the app from the `X-App-Id` header
        // the same way the proxy refresh does.
        var body: [String: JSONValue] = ["token": .string(token)]
        if let resolvedInviteToken = resolvedInviteToken {
            body["inviteToken"] = .string(resolvedInviteToken)
        }

        let endpoint: String
        let raw: JSONValue
        if let proxy = refreshProxy, proxy.enabled {
            endpoint = Self.proxyUrl(proxy: proxy, suffix: "auth/magic-link/verify")
            raw = try await postToProxy(url: endpoint, proxy: proxy, body: body)
        } else {
            endpoint = "/auth/magic-link/verify"
            raw = try await transport.request(
                method: .post,
                path: endpoint,
                body: body
            )
        }
        let envelope: MagicLinkVerifyEnvelope = try applyVerifiedToken(
            MagicLinkVerifyEnvelope.self, from: raw, path: endpoint, cause: "magicLinkVerify"
        )

        return MagicLinkVerifyResult(
            user: envelope.user,
            promptAddPasskey: envelope.promptAddPasskey,
            isNewUser: envelope.isNewUser
        )
    }

    // MARK: - OTP

    /// - Warning: Deprecated by #2884. `/auth/otp/request` is now an alias of
    ///   the unified issuance path. Call `emailSignInRequest` instead.
    public func otpRequest(email: String) async throws -> Bool {
        let transport = try requireTransport()

        let body: [String: JSONValue] = ["email": .string(email)]
        let response: SuccessResponse? = try await transport.requestOptional(
            method: .post,
            path: "/auth/otp/request",
            body: body
        )
        return response?.success ?? false
    }

    public func otpVerify(email: String, code: String, inviteToken: String? = nil) async throws -> OtpVerifyResult {
        let transport = try requireTransport()

        // #466: thread the (trimmed) invite token through verify so deferred
        // grants resolve to the signing-in user. Mirrors JS otpVerify.
        let trimmedInviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInviteToken = (trimmedInviteToken?.isEmpty == false) ? trimmedInviteToken : nil

        var body: [String: JSONValue] = ["email": .string(email), "code": .string(code)]
        if let resolvedInviteToken = resolvedInviteToken {
            body["inviteToken"] = .string(resolvedInviteToken)
        }

        let endpoint: String
        let raw: JSONValue
        if let proxy = refreshProxy, proxy.enabled {
            endpoint = Self.proxyUrl(proxy: proxy, suffix: "auth/otp/verify")
            raw = try await postToProxy(url: endpoint, proxy: proxy, body: body)
        } else {
            endpoint = "/auth/otp/verify"
            raw = try await transport.request(
                method: .post,
                path: endpoint,
                body: body
            )
        }
        let envelope: OtpVerifyEnvelope = try applyVerifiedToken(
            OtpVerifyEnvelope.self, from: raw, path: endpoint, cause: "otpVerify"
        )

        return OtpVerifyResult(user: envelope.user, isNewUser: envelope.isNewUser)
    }

    // MARK: - Passkeys (#929)
    //
    // Wire-level passkey endpoints, mirroring JS `authController.passkey*`.
    // The native AuthenticationServices orchestration lives in
    // `AuthAPI+NativePasskeys.swift`; these methods only speak HTTP.

    /// `POST /passkey/auth/start` (no auth). The server spreads the WebAuthn
    /// request options at the top level alongside `challengeToken`; the
    /// options travel as an opaque `JSONValue` because the SDK hands them
    /// straight to `PasskeyWire` / AuthenticationServices.
    public func passkeyAuthStart() async throws -> PasskeyAuthStartResult {
        let transport = try requireTransport()
        let response: JSONValue = try await transport.request(
            method: .post,
            path: "/passkey/auth/start",
            body: [String: JSONValue]()
        )
        let split = try Self.splitChallengeToken(
            response,
            message: "Invalid passkey auth start response"
        )
        return PasskeyAuthStartResult(options: split.options, challengeToken: split.challengeToken)
    }

    /// `POST /passkey/auth/finish` (no auth). On success applies the
    /// returned access token (cause `"passkeyAuth"`) — the session lands exactly
    /// like the magic-link / OTP paths — and returns the typed result.
    public func passkeyAuthFinish(
        credential: JSONValue,
        challengeToken: String
    ) async throws -> PasskeySignInResult {
        let transport = try requireTransport()
        let body: [String: JSONValue] = [
            "credential": credential,
            "challengeToken": .string(challengeToken),
        ]
        let raw: JSONValue = try await transport.request(
            method: .post,
            path: "/passkey/auth/finish",
            body: body
        )
        let envelope: PasskeyAuthFinishEnvelope = try applyVerifiedToken(
            PasskeyAuthFinishEnvelope.self,
            from: raw,
            path: "/passkey/auth/finish",
            cause: "passkeyAuth"
        )
        return PasskeySignInResult(user: envelope.user, isNewUser: envelope.isNewUser)
    }

    /// `POST /passkey/register/start` (requires auth). WebAuthn creation
    /// options plus `challengeToken`, same split as `passkeyAuthStart`.
    public func passkeyRegisterStart() async throws -> PasskeyRegisterStartResult {
        let transport = try requireTransport()
        let response: JSONValue = try await transport.request(
            method: .post,
            path: "/passkey/register/start",
            body: [String: JSONValue]()
        )
        let split = try Self.splitChallengeToken(
            response,
            message: "Invalid passkey register start response"
        )
        return PasskeyRegisterStartResult(options: split.options, challengeToken: split.challengeToken)
    }

    /// Split a passkey `start` response into `{options, challengeToken}`:
    /// the server spreads the WebAuthn options at the top level, so the
    /// options are everything except `challengeToken`.
    private static func splitChallengeToken(
        _ response: JSONValue,
        message: String
    ) throws -> (options: JSONValue, challengeToken: String) {
        guard var object = response.objectValue,
              let challengeToken = object["challengeToken"]?.stringValue else {
            throw JsBaoError(code: .unavailable, message: message)
        }
        object.removeValue(forKey: "challengeToken")
        return (.object(object), challengeToken)
    }

    /// `POST /passkey/register/finish` (requires auth). Returns
    /// `{ success, credentialBackedUp?, invitation? }`. `inviteToken` (#466)
    /// folds invitation acceptance into the registration call.
    public func passkeyRegisterFinish(
        credential: JSONValue,
        challengeToken: String,
        deviceName: String? = nil,
        inviteToken: String? = nil
    ) async throws -> PasskeyRegistrationResult {
        let transport = try requireTransport()
        var body: [String: JSONValue] = [
            "credential": credential,
            "challengeToken": .string(challengeToken),
        ]
        if let deviceName = deviceName, !deviceName.isEmpty {
            body["deviceName"] = .string(deviceName)
        }
        let trimmedInviteToken = inviteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedInviteToken = trimmedInviteToken, !trimmedInviteToken.isEmpty {
            body["inviteToken"] = .string(trimmedInviteToken)
        }
        return try await transport.request(method: .post, path: "/passkey/register/finish", body: body)
    }

    /// `GET /passkey/list` (requires auth). Returns `{ passkeys: [...] }`.
    public func passkeyList() async throws -> PasskeyListResult {
        let transport = try requireTransport()
        return try await transport.request(method: .get, path: "/passkey/list")
    }

    /// `DELETE /passkey/{passkeyId}` (requires auth). Returns `{ success }`.
    public func passkeyDelete(passkeyId: String) async throws -> PasskeyDeleteResult {
        let transport = try requireTransport()
        return try await transport.request(method: .delete, path: "/passkey/\(passkeyId)")
    }

    /// `PATCH /passkey/{passkeyId}` (requires auth). Renames a passkey;
    /// returns `{ passkey: {...} }`.
    public func passkeyUpdate(passkeyId: String, deviceName: String) async throws -> PasskeyUpdateResult {
        let transport = try requireTransport()
        let body: [String: JSONValue] = ["deviceName": .string(deviceName)]
        return try await transport.request(method: .patch, path: "/passkey/\(passkeyId)", body: body)
    }

    // MARK: - Logout

    /// Sign out the current user. Mirrors JS `authController.logout(options)`:
    /// honors `clearOfflineIdentity` (default `true`), `revokeOffline`,
    /// `wipeLocal`, and the Swift-specific `waitForDisconnect`. (`redirectTo`
    /// is web-only `window.location` and is intentionally not modeled here.)
    public func logout(options: LogoutOptions = LogoutOptions()) async throws {
        // JS parity (#1059): JS emits `auth:logout` (payload `{}`) as the very
        // first statement of `JsBaoClient.logout()`, before any teardown.
        // Every Swift logout path funnels through this method, so emitting
        // here covers `client.logout(...)` and `client.auth.logout(...)`.
        emitter?.emit(AuthLogoutEvent())

        // Block any in-flight refresh/restore from re-authenticating after
        // this logout (see `blockNonInteractiveAuth`). Set before clearing
        // the token so a refresh resolving mid-logout is caught — and before
        // the server logout below, whose own 401 path can drive a refresh.
        lock.withLock { blockNonInteractiveAuth = true }

        // JS parity (#2655): step 1 of the JS `logout()` is a best-effort
        // `POST /auth/logout` that clears the server's refresh cookie. It runs
        // before the token is dropped so the request still carries the bearer
        // the server needs to identify the session.
        await postServerLogout()

        let previous = getToken()
        applyToken(nil, previous: previous, cause: "logout")

        // Default-true in JS: drop the in-memory offline identity unless the
        // caller explicitly opts out.
        if options.clearOfflineIdentity {
            lock.withLock { offlineIdentity = nil }
        }

        if options.revokeOffline {
            // revokeOfflineGrant clears the stored grant (and the in-memory
            // identity) and, when wipeLocal is set, evicts local data.
            try? await revokeOfflineGrant(options: RevokeOfflineGrantOptions(wipeLocal: options.wipeLocal))
        }

        // JS parity (#2655): the persisted JWT goes on EVERY logout, not only
        // under `wipeLocal`. In JS this falls out of `updateToken(null)`
        // clearing the stored record; leaving it behind here meant a relaunch
        // restored the session the user had just ended. Draining any queued
        // persistence first keeps a write from landing after the delete.
        await awaitPendingPersistence()
        try? await clearPersistedJwt()

        // JS parity (#2874): the web client's `authController.logout` awaits
        // `deps.onLogoutCleanup({ wipeLocal })` on EVERY logout before it
        // signals completion. Placed here, ahead of the `waitForDisconnect`
        // teardown, the sweep's per-document `unsubscribe` frames still reach
        // a live socket — a Swift improvement over JS, which disconnects
        // before calling `auth.logout` — and no completion subscriber can
        // observe the signed-out user's documents or rows.
        await onLogoutCleanup?(options)

        if options.waitForDisconnect {
            await onLogoutDisconnect?()
        }

        // JS parity (#1059): JS emits `auth:logout:complete` (payload `{}`)
        // after the best-effort server logout, networking shutdown, and
        // `auth.logout(...)` teardown have all finished.
        emitter?.emit(AuthLogoutCompleteEvent())
    }

    /// Backward-compatible overload retained for the `JsBaoClient` wiring
    /// (`logout(wipeLocal:)`). Forwards to the options-based `logout`.
    public func logout(wipeLocal: Bool) async throws {
        try await logout(options: LogoutOptions(wipeLocal: wipeLocal))
    }

    /// Optional hook invoked when `logout(waitForDisconnect: true)` is
    /// requested, awaited so callers can block until the socket is torn down.
    /// Wired by `JsBaoClient` (which owns the WebSocket lifecycle); `nil` when
    /// the controller is used standalone.
    var onLogoutDisconnect: (@Sendable () async -> Void)?

    /// Client-owned logout cleanup, awaited on EVERY logout before
    /// `onLogoutDisconnect` and before `AuthLogoutCompleteEvent` (#2874).
    /// Mirrors the JS `onLogoutCleanup` dependency: close every open
    /// document, reset user-scoped document state, and — under `wipeLocal` —
    /// purge the local stores. Wired by `JsBaoClient` the same way
    /// `onLogoutDisconnect` is; `nil` when the controller is used standalone.
    var onLogoutCleanup: (@Sendable (LogoutOptions) async -> Void)?

    // MARK: - Network Mode

    public func setNetworkMode(_ mode: NetworkMode) {
        lock.withLock { networkMode = mode }
        // Note: event emission is handled by JsBaoClient.setNetworkMode()
        // to avoid duplicate events.
    }

    public func getNetworkMode() -> NetworkMode {
        return lock.withLock { networkMode }
    }

    // MARK: - Auth Ready

    public func waitForAuthReady() async {
        if lock.withLock({ authReady }) {
            return
        }

        await withCheckedContinuation { continuation in
            // Register the waiter atomically with the ready check so a
            // `markAuthReady()` racing this closure can't slip between the
            // check and the append (which would strand the continuation).
            // The resume happens outside the lock.
            let alreadyReady = lock.withLock { () -> Bool in
                if authReady {
                    return true
                }
                authReadyContinuations.append(continuation)
                return false
            }
            if alreadyReady {
                continuation.resume()
            }
        }
    }

    private func markAuthReady() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            authReady = true
            let pending = authReadyContinuations
            authReadyContinuations.removeAll()
            return pending
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    // MARK: - JWT Persistence (private)

    /// A persisted access token is refused this close to its expiry, on both
    /// the read and the write side. Port of the JS client's
    /// `jwtPersistenceLeewayMs = 120_000` (#2656): a token about to expire is
    /// worth less than the refresh it would suppress, and one already in
    /// storage would only be handed to the network a moment before it lapses.
    private static let jwtPersistenceLeewaySeconds: TimeInterval = 120

    /// The expiry to judge a persisted record by: the recorded `expiresAt`
    /// when it parses, otherwise the token's own `exp` claim. `nil` means
    /// there is no usable expiry — which makes the token unusable rather than
    /// eternal, matching JS's `isPersistedTokenUsable` (a token with no `exp`
    /// returns false there).
    private static func persistedExpiry(recordedExpiry: String?, token: String) -> Date? {
        if let recordedExpiry = recordedExpiry,
           let date = ISO8601DateFormatter().date(from: recordedExpiry) {
            return date
        }
        if let exp = Self.parseJwtPayload(token: token)?["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        return nil
    }

    /// Whether a persisted record still has enough life left to be used.
    private static func isPersistedTokenUsable(recordedExpiry: String?, token: String) -> Bool {
        guard let expiry = persistedExpiry(recordedExpiry: recordedExpiry, token: token) else {
            return false
        }
        return expiry.timeIntervalSinceNow > jwtPersistenceLeewaySeconds
    }

    private func persistJwt(token: String) async throws {
        let namespace = persistConfig.storageKeyPrefix ?? "default"
        let payload = Self.parseJwtPayload(token: token)

        // Same leeway on the way in. A token that would be refused on the next
        // read is not written at all, and whatever is already on disk is
        // cleared rather than left as a stale record (JS `persistJwtInternal`).
        guard Self.isPersistedTokenUsable(recordedExpiry: nil, token: token) else {
            logger.debug("Not persisting JWT: no usable expiry, or inside the refresh leeway")
            try await offlineStore.clearPersistedJwt(appId: appId, namespace: namespace)
            return
        }

        let record = PersistedJwtRecord(
            key: "session",
            token: token,
            expiresAt: (payload?["exp"] as? TimeInterval).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) },
            storedAt: ISO8601DateFormatter().string(from: Date()),
            userId: payload?["userId"] as? String ?? payload?["sub"] as? String,
            version: 1
        )
        try await offlineStore.persistJwt(appId: appId, namespace: namespace, record: record)
    }

    private func clearPersistedJwt() async throws {
        let namespace = persistConfig.storageKeyPrefix ?? "default"
        try await offlineStore.clearPersistedJwt(appId: appId, namespace: namespace)
    }

    /// Try to load a persisted JWT on startup
    public func tryLoadPersistedJwt() async -> String? {
        guard persistConfig.persistJwtInStorage else { return nil }
        let namespace = persistConfig.storageKeyPrefix ?? "default"
        guard let record = try? await offlineStore.loadPersistedJwt(appId: appId, namespace: namespace) else {
            return nil
        }
        guard Self.isPersistedTokenUsable(
            recordedExpiry: record.expiresAt,
            token: record.token
        ) else {
            logger.debug("Persisted JWT expired, inside the refresh leeway, or missing an expiry")
            return nil
        }
        return record.token
    }

    /// Restore an authenticated session on startup:
    ///   1. Prefer a persisted access token that's still usable (only possible
    ///      when `persistJwtInStorage` is on).
    ///   2. Otherwise attempt a cookie-based refresh — the `rt-{appId}` refresh
    ///      cookie persists in `HTTPCookieStorage.shared` across app launches
    ///      and lives up to 7d, so a user reopening the app after the 1h
    ///      access-token TTL shouldn't be forced back through login.
    ///   3. Otherwise bootstrap as unauthenticated.
    ///
    /// Step 2 runs whenever there is no usable token — it is **not** gated on
    /// `persistJwtInStorage` (off by default) and not on a persisted record
    /// existing. That gate was #2656: with the default options every launch
    /// started signed out even though the refresh cookie was sitting right
    /// there, while the same app on the JS client resumed. JS's
    /// `runAuthBootstrap` refreshes whenever `this.token` is empty, and this is
    /// the port of that.
    ///
    /// Marks auth ready once the attempt completes, regardless of outcome.
    public func tryRestoreSession() async {
        defer { markAuthReady() }

        let namespace = persistConfig.storageKeyPrefix ?? "default"

        if persistConfig.persistJwtInStorage,
           let record = try? await offlineStore.loadPersistedJwt(appId: appId, namespace: namespace) {
            if Self.isPersistedTokenUsable(recordedExpiry: record.expiresAt, token: record.token) {
                applyToken(record.token, previous: nil, cause: "persisted-hydrate")
                return
            }
            // Aged out, inside the leeway, or carrying no usable expiry: drop
            // it so a later launch doesn't reconsider the same dead record,
            // then fall through to the refresh.
            logger.debug("Persisted JWT unusable; attempting cookie-based refresh")
            try? await clearPersistedJwt()
        }

        let outcome = await refreshAccessToken(cause: "startup")
        switch outcome {
        case .success:
            break // applyToken has already set the new token
        case .invalid:
            // Refresh cookie is gone or the session was revoked. Nothing to
            // keep — and nothing to report: a signed-out start is not an auth
            // failure (see `isBootstrapCause`). Since #2655 the refresh path
            // already clears the record; the idempotent delete stays as a
            // local guarantee for the startup path regardless of how the
            // refresh was routed. Skipped when a sign-in landed while the
            // refresh was in flight — any record on disk is then the NEW
            // session's, not the stale one this rejection refers to.
            if getToken() == nil {
                try? await clearPersistedJwt()
            }
        case .network:
            // Transient. Leave any record in place so the next launch (or an
            // online-again trigger) can try again.
            break
        }
    }

    // MARK: - Offline Access Grants

    /// Enable offline access by requesting a grant from the server and storing it in the Keychain.
    public func enableOfflineAccess(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> EnableOfflineAccessResult {
        let transport = try requireTransport()

        guard getNetworkMode() != .offline else {
            throw JsBaoError(code: .invalidArgument, message: "Cannot enable offline access while in offline mode")
        }

        let body: [String: JSONValue] = ["ttlDays": .number(Double(options.ttlDays))]
        let response: OfflineGrantResponse = try await transport.request(
            method: .post,
            path: "/auth/offline-grant",
            body: body
        )

        // Grant-method selection (mirrors JS authController.enableOfflineAccess):
        // the default grant is the non-biometric "signed" method. Biometric is
        // strictly opt-in via `preferBiometric` — when set, the grant is stored
        // behind a Keychain biometric ACL and labeled "largeBlob" to match the
        // JS unlock-method taxonomy ("largeBlob" | "pin" | "signed"). PIN
        // fallback (`allowPinFallback` + `pinProvider`) labels the grant "pin".
        let method: String
        if options.preferBiometric {
            method = "largeBlob"
        } else if options.allowPinFallback {
            method = "pin"
        } else {
            method = "signed"
        }

        // Build grant record
        let userId = getUserId() ?? ""
        let grant = OfflineGrant(
            key: "grant",
            userId: userId,
            appId: appId,
            rootDocId: response.rootDocId,
            email: response.email,
            name: response.name,
            expiresAt: response.expiresAt,
            method: method
        )

        // Store in Keychain. Biometric protection is gated on the opt-in
        // `preferBiometric` flag (JS default is the non-biometric grant).
        let grantData = try JSONEncoder().encode(grant)
        try keychainHelper.save(key: "grant", data: grantData, requireBiometric: options.preferBiometric)

        // Also store in OfflineStore for metadata access
        try await offlineStore.putGrant(appId: appId, userId: userId, key: "grant", record: grant)

        lock.withLock {
            offlineIdentity = OfflineIdentity(
                userId: grant.userId,
                appId: grant.appId,
                rootDocId: grant.rootDocId,
                email: grant.email,
                name: grant.name,
                expiresAt: grant.expiresAt,
                method: grant.method ?? "signed"
            )
        }

        emitter?.emit(OfflineAuthEnabledEvent(method: grant.method ?? "signed"))

        // Same projection `AuthAPI` used to perform on the raw grant dict:
        // a decodable response counts as enabled unless the server says
        // otherwise, and `method`/`reason` pass through when present.
        return EnableOfflineAccessResult(
            enabled: response.enabled ?? true,
            method: response.method,
            reason: response.reason
        )
    }

    /// Unlock offline access by reading the grant from the Keychain.
    /// If biometric-protected, this triggers Face ID / Touch ID automatically.
    public func unlockOffline() async throws -> Bool {
        do {
            guard let grantData = try keychainHelper.load(key: "grant") else {
                logger.debug("No offline grant found in Keychain")
                return false
            }

            let grant = try JSONDecoder().decode(OfflineGrant.self, from: grantData)

            // Check expiry
            if let expiresAt = grant.expiresAt,
               let date = ISO8601DateFormatter().date(from: expiresAt),
               date < Date() {
                logger.warn("Offline grant expired")
                emitter?.emit(OfflineAuthFailedEvent(reason: "expired"))
                return false
            }

            lock.withLock {
                offlineIdentity = OfflineIdentity(
                    userId: grant.userId,
                    appId: grant.appId,
                    rootDocId: grant.rootDocId,
                    email: grant.email,
                    name: grant.name,
                    expiresAt: grant.expiresAt,
                    method: grant.method ?? "signed"
                )
                // Set user context from grant
                currentUserId = grant.userId
            }

            emitter?.emit(OfflineAuthUnlockedEvent(userId: grant.userId))
            return true
        } catch KeychainError.biometricCancelled {
            emitter?.emit(OfflineAuthFailedEvent(reason: "biometric_cancelled"))
            return false
        } catch {
            logger.warn("Failed to unlock offline:", error.localizedDescription)
            emitter?.emit(OfflineAuthFailedEvent(reason: error.localizedDescription))
            return false
        }
    }

    /// Check if an offline grant exists in the Keychain.
    public func isOfflineGrantAvailable() -> Bool {
        keychainHelper.exists(key: "grant")
    }

    /// Get the status of the offline grant (availability, expiry, method).
    public func getOfflineGrantStatus() -> OfflineGrantStatus {
        let identity = lock.withLock { offlineIdentity }

        guard let identity = identity else {
            return OfflineGrantStatus(
                available: keychainHelper.exists(key: "grant"),
                expiresAt: nil,
                daysLeft: nil,
                method: nil
            )
        }

        var daysLeft: Int?
        if let expiresAt = identity.expiresAt,
           let date = ISO8601DateFormatter().date(from: expiresAt) {
            daysLeft = max(0, Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0)
        }

        return OfflineGrantStatus(
            available: true,
            expiresAt: identity.expiresAt,
            daysLeft: daysLeft,
            method: identity.method
        )
    }

    /// Renew the offline grant while online by requesting a new grant from the server.
    public func renewOfflineGrantOnline(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> Bool {
        guard getNetworkMode() != .offline else {
            throw JsBaoError(code: .invalidArgument, message: "Must be online to renew offline grant")
        }

        let _ = try await enableOfflineAccess(options: options)
        emitter?.emit(OfflineAuthRenewedEvent())
        return true
    }

    /// Revoke the offline grant, removing it from the Keychain.
    public func revokeOfflineGrant(options: RevokeOfflineGrantOptions = RevokeOfflineGrantOptions()) async throws {
        try keychainHelper.delete(key: "grant")

        let userId = getUserId() ?? ""
        try? await offlineStore.deleteGrant(appId: appId, userId: userId, key: "grant")

        lock.withLock { offlineIdentity = nil }

        emitter?.emit(OfflineAuthRevokedEvent(wipeLocal: options.wipeLocal))
    }

    /// Get the stored offline identity (available after unlockOffline succeeds).
    public func getOfflineIdentity() -> OfflineIdentity? {
        return lock.withLock { offlineIdentity }
    }

    // MARK: - Private Helpers

    private func refreshDirect() async throws -> String {
        let transport = try requireTransport()
        // `requestOptional` + an optional `token` put both "the server
        // answered 2xx with nothing usable" shapes — an empty body (a proxy
        // answering 204, say) and a body that simply omits `token` — on the
        // `RefreshTokenMissingError` path (→ `.invalid`) rather than on a
        // decode error (→ `.network`, retried forever). JS reads
        // `text ? JSON.parse(text) : null` and treats both the same way. A
        // body that is present but not decodable still throws from the
        // transport and stays retryable, also matching JS. Issue #2655.
        let response: RefreshResponse? = try await transport.requestOptional(
            method: .post,
            path: "/auth/refresh"
        )
        guard let token = response?.token, !token.isEmpty else {
            throw RefreshTokenMissingError()
        }
        return token
    }

    /// Join a refresh-proxy base and an endpoint suffix into one absolute URL.
    ///
    /// Strips a single trailing slash off the base so a trailing-slash config
    /// (`.../proxy/`) yields `.../proxy/auth/refresh` rather than a
    /// double-slash `.../proxy//auth/refresh` that strict proxy routes 404
    /// (#1983). Matches the JS client's `new URL(suffix, proxyBase)`.
    static func proxyUrl(proxy: RefreshProxyConfig, suffix: String) -> String {
        let base = proxy.baseUrl.hasSuffix("/") ? String(proxy.baseUrl.dropLast()) : proxy.baseUrl
        return "\(base)/\(suffix)"
    }

    /// POST a JSON body straight to the refresh proxy, bypassing the transport.
    ///
    /// The proxy endpoints are absolute URLs, and the transport's `path` is
    /// always resolved against `apiUrl + /app/{appId}/api` — passing one as a
    /// path produced `https://api…/app/{id}/api/https://proxy…` and no verify
    /// could ever succeed in proxy mode (#2658). These requests also carry no
    /// bearer token, so they intentionally never run the refresh interceptor.
    ///
    /// Non-2xx surfaces as `HttpError` with the server's `{error, code}`
    /// extracted, the same mapping `Transport.executeValidated` applies.
    private func postToProxy(
        url: String,
        proxy: RefreshProxyConfig,
        body: [String: JSONValue]
    ) async throws -> JSONValue {
        guard let parsed = URL(string: url) else {
            throw HttpError(status: 0, message: "Failed to build URL for path: \(url)")
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(appId, forHTTPHeaderField: "X-App-Id")
        if let maxAge = proxy.cookieMaxAgeSeconds {
            request.setValue(String(maxAge), forHTTPHeaderField: "X-Refresh-Cookie-Max-Age")
        }
        request.httpBody = try JSONCoding.encodeData(body)

        let (data, response) = try await NetworkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JsBaoError(code: .unavailable, message: "Invalid response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            let parsedBody = HttpError.parseBody(text)
            throw HttpError(
                status: httpResponse.statusCode,
                message: "HTTP \(httpResponse.statusCode)",
                body: text,
                serverCode: parsedBody.code,
                serverMessage: parsedBody.message
            )
        }
        return try JSONCoding.decodeData(JSONValue.self, from: data)
    }

    private func refreshViaProxy(proxy: RefreshProxyConfig) async throws -> String {
        let url = Self.proxyUrl(proxy: proxy, suffix: "auth/refresh")
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appId, forHTTPHeaderField: "X-App-Id")
        if let maxAge = proxy.cookieMaxAgeSeconds {
            request.setValue(String(maxAge), forHTTPHeaderField: "X-Refresh-Cookie-Max-Age")
        }
        if let token = getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await NetworkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JsBaoError(code: .unavailable, message: "Invalid response")
        }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw HttpError(status: httpResponse.statusCode, message: "Refresh failed")
        }

        return try Self.tokenFromRefreshBody(data)
    }

    /// Read the access token out of a 2xx refresh body, classifying the ways it
    /// can carry none the way JS does. `tryRefreshAccessToken` reads
    /// `const data = text ? JSON.parse(text) : null; const newToken =
    /// data?.token; if (!newToken) return "invalid"`
    /// (src/client/internal/httpClient.ts), so:
    ///
    /// - nothing to parse (a proxy answering 204, or 200 with no content),
    ///   JSON `null`, or a document without a usable `token` all mean the
    ///   session is over → `RefreshTokenMissingError` → `.invalid`. Retrying
    ///   these on backoff would never recover, and would leave a dead bearer on
    ///   every request in the meantime.
    /// - a body that does not parse at all is a garbled response, not an answer
    ///   about the session → `.network`, matching `JSON.parse` throwing into the
    ///   outer `catch`.
    ///
    /// The direct (non-proxy) path gets the same classification from
    /// `Transport.decodeOptional`, which also decodes into an Optional so a
    /// bare `null` reads as "no document" rather than a decode failure.
    /// Issue #2655.
    static func tokenFromRefreshBody(_ data: Data) throws -> String {
        // Zero bytes or nothing but JSON whitespace: no document at all, the
        // `text ? … : null` arm. (`Transport.isEffectivelyEmpty` applies the
        // same rule on the direct path; it is file-private to that extension.)
        let isEmpty = data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        guard !isEmpty else {
            throw RefreshTokenMissingError()
        }
        let decoded: RefreshResponse?
        do {
            decoded = try JSONCoding.decodeData(RefreshResponse?.self, from: data)
        } catch {
            throw JsBaoError(code: .unavailable, message: "Invalid refresh response")
        }
        guard let token = decoded?.token, !token.isEmpty else {
            throw RefreshTokenMissingError()
        }
        return token
    }

    /// Best-effort `POST /auth/logout`, so the server drops the refresh
    /// cookie and a later launch cannot mint a new access token from it.
    /// Mirrors step 1 of the JS `JsBaoClient.logout()`; every failure is
    /// swallowed, because a server that cannot be reached must not stop the
    /// local sign-out. Issue #2655.
    private func postServerLogout() async {
        if let proxy = refreshProxy, proxy.enabled {
            let base = proxy.baseUrl.hasSuffix("/") ? String(proxy.baseUrl.dropLast()) : proxy.baseUrl
            guard let url = URL(string: "\(base)/auth/logout") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(appId, forHTTPHeaderField: "X-App-Id")
            if let maxAge = proxy.cookieMaxAgeSeconds {
                request.setValue(String(maxAge), forHTTPHeaderField: "X-Refresh-Cookie-Max-Age")
            }
            if let token = getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                _ = try await NetworkSession.data(for: request)
            } catch {
                logger.debug("Best-effort server logout failed:", error.localizedDescription)
            }
            return
        }

        guard let transport = try? requireTransport() else { return }
        do {
            let _: SuccessResponse = try await transport.request(
                method: .post,
                path: "/auth/logout"
            )
        } catch {
            logger.debug("Best-effort server logout failed:", error.localizedDescription)
        }
    }
}

// MARK: - Wire envelopes (internal)
//
// The response shapes `AuthController` decodes. Each one is the typed
// replacement for a `[String: Any]` cast chain: the public DTOs the auth
// surface returns carry no access token, so the envelopes below add the
// `token` field the controller applies before handing the public result back.

/// `{ success }` — magic-link / OTP request endpoints.
struct SuccessResponse: Decodable, Sendable {
    let success: Bool?
}

/// `{ token }` — `POST /auth/refresh` (direct and via the refresh proxy).
/// `token` is optional so that a 2xx answer without one is classified as an
/// ended session rather than a decode failure — see `refreshDirect`.
struct RefreshResponse: Decodable, Sendable {
    let token: String?
}

/// A refresh that succeeded at the HTTP level but carried no usable token.
/// Distinguishes the JS `"invalid"` case from the decode failures that stay
/// retryable. Issue #2655.
struct RefreshTokenMissingError: Error {}

// The three verify envelopes below carry no `token` field: the token is read
// off the raw response and applied by `applyVerifiedToken` *before* these
// decode, so a decode failure here can never burn a single-use credential.

/// `POST /auth/magic-link/verify` — the `MagicLinkVerifyResult` fields.
struct MagicLinkVerifyEnvelope: Decodable, Sendable {
    let user: AuthUser
    let promptAddPasskey: Bool?
    let isNewUser: Bool?
}

/// `POST /auth/otp/verify` — the `OtpVerifyResult` fields.
struct OtpVerifyEnvelope: Decodable, Sendable {
    let user: AuthUser
    let isNewUser: Bool?
}

/// `POST /passkey/auth/finish` — the `PasskeySignInResult` fields.
struct PasskeyAuthFinishEnvelope: Decodable, Sendable {
    let user: AuthUser
    let isNewUser: Bool?
}

/// `POST /auth/offline-grant` — the grant fields the controller stores in the
/// Keychain, plus the `enabled`/`method`/`reason` projection the public
/// `EnableOfflineAccessResult` exposes.
struct OfflineGrantResponse: Decodable, Sendable {
    let rootDocId: String?
    let email: String?
    let name: String?
    let expiresAt: String?
    let enabled: Bool?
    let method: String?
    let reason: String?
}
