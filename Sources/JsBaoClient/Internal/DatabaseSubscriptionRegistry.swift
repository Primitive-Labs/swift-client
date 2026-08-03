import Foundation

/// Tracks active `databases.subscribe(...)` registrations on a single
/// WebSocket connection. Swift port of the JS client's
/// `DatabaseSubscriptionRegistry`
/// (`src/client/internal/databaseSubscriptions.ts`).
///
/// Responsibilities:
///  - Dispatch inbound `db.change` frames to the matching callback, keyed
///    by `(databaseId, subscriptionKey)`.
///  - Synthesize the per-recipient `isOrigin` / `isOriginUser` booleans
///    (#737) at dispatch time, so reconnects (connection-id rotation) and
///    sign-out/sign-in (user-id change) are reflected without re-wiring.
///  - Provide `unregister` so later frames are dropped.
///  - Expose `list()` so the client can re-issue `db.subscribe` frames
///    after a WS reconnect.
///
/// Intentionally self-contained and synchronous — the owning
/// `DatabasesAPI` / `JsBaoClient` send the `db.subscribe` frame; this
/// registry never touches the network layer.
///
/// ## A sync-adjacent boundary type (#1993 Phase D)
///
/// The concurrency epic actorized the async service managers (`OfflineStore`,
/// `KvCache`, `AnalyticsQueue`). This registry was deliberately **dropped**
/// from that list by the sponsor and stays class-plus-lock permanently: it
/// does no I/O and has no `await` anywhere, so an actor would buy nothing and
/// would cost `DatabasesAPI.subscribe` its synchronous shape (it is
/// sync-throwing and returns a synchronous unsubscribe closure). Do not
/// convert it — see the "Decisions of record" on #1993.
///
/// ## `@unchecked Sendable` safety argument
///
/// The conformance is unchecked because the registry stores two values the
/// compiler cannot prove are safe to share: `Registration.onChange`, a plain
/// (non-`@Sendable`) escaping closure supplied by app code, and
/// `Registration.params` / `OriginContext`'s two lookup closures, which are
/// likewise untyped and non-`@Sendable`. The argument that it is nonetheless
/// safe has three parts:
///
///  1. **Every mutable field is `lock`-confined.** `registrations` and
///     `originContext` are the only mutable state, both `private`, and every
///     read and write of either goes through the one `NSLock` held in `lock`.
///     There is no second lock, so there is no acquisition order to get wrong,
///     and no lock is ever held across an `await` because the type has no
///     `async` member at all.
///  2. **The stored closures never run under the lock.** `dispatch` copies the
///     matching `Registration` and the `originContext` out of the critical
///     section, releases `lock`, and only then calls `ctx.getConnectionId()` /
///     `ctx.getCurrentUserId()` and `reg.onChange(event)`. So an app callback
///     that re-enters the registry (`unregister` from inside `onChange` is the
///     realistic case) cannot deadlock against a non-recursive `NSLock`, and a
///     slow callback never blocks a concurrent `register`.
///  3. **No registry-owned state escapes by reference.** `list()` returns
///     value copies of `(databaseId, subscriptionKey, params)`; the `onChange`
///     closures stay inside the registry. The copy is one level deep — a
///     reference type an app stored *inside* `params` is shared with that app,
///     as it was before the copy — so the claim is about the registry's own
///     tables, not about everything reachable from them. Each closure is therefore invoked from exactly one
///     place, on whichever thread delivered the frame — the same contract the
///     JS client's registry has.
///
/// `logger` is a `let`, so it is not part of the mutable state the lock
/// confines; `Logger` does its own internal locking.
final class DatabaseSubscriptionRegistry: @unchecked Sendable {
    /// Lookups used to synthesize `isOrigin` / `isOriginUser` on inbound
    /// frames. Resolved lazily at dispatch time (not at register time)
    /// because either value can change while a subscription is live.
    struct OriginContext {
        let getConnectionId: () -> String?
        let getCurrentUserId: () -> String?
    }

    private struct Registration {
        let databaseId: String
        let subscriptionKey: String
        let params: [String: Any]
        let onChange: (DatabaseChangePayload) -> Void
    }

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]
    private var originContext: OriginContext?
    private let logger: Logger?

    init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Wire up the connection-id / user-id lookups. Called once by the
    /// client during construction.
    func setOriginContext(_ ctx: OriginContext?) {
        lock.lock()
        defer { lock.unlock() }
        originContext = ctx
    }

    private func makeKey(_ databaseId: String, _ subscriptionKey: String) -> String {
        "\(databaseId)::\(subscriptionKey)"
    }

    /// Register a callback for `(databaseId, subscriptionKey)`. A prior
    /// registration for the same pair is replaced (matches JS behavior).
    func register(
        databaseId: String,
        subscriptionKey: String,
        params: [String: Any],
        onChange: @escaping (DatabaseChangePayload) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        registrations[makeKey(databaseId, subscriptionKey)] = Registration(
            databaseId: databaseId,
            subscriptionKey: subscriptionKey,
            params: params,
            onChange: onChange
        )
    }

    /// Remove the registration for `(databaseId, subscriptionKey)`. Later
    /// frames for this pair are dropped (debug-logged, not an error).
    func unregister(databaseId: String, subscriptionKey: String) {
        lock.lock()
        defer { lock.unlock() }
        registrations.removeValue(forKey: makeKey(databaseId, subscriptionKey))
    }

    /// Snapshot of all live registrations, for reconnect re-subscribe.
    func list() -> [(databaseId: String, subscriptionKey: String, params: [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return registrations.values.map {
            ($0.databaseId, $0.subscriptionKey, $0.params)
        }
    }

    /// Route an inbound `db.change` frame (already parsed to `[String: Any]`)
    /// to the registered callback. No-op + debug-log if nothing is
    /// registered for `(databaseId, subscriptionKey)`, so frames that
    /// arrive before register or after unsubscribe never crash the client.
    ///
    /// Synthesizes `isOrigin` / `isOriginUser` per recipient (#737) and
    /// normalizes `originConnectionId` / `originUserId` to `nil` when
    /// absent on the wire.
    func dispatch(_ payload: [String: Any]) {
        guard let databaseId = payload["databaseId"] as? String,
              let subscriptionKey = payload["subscriptionKey"] as? String else {
            logger?.debug("[db-sub] dropping db.change frame with missing ids")
            return
        }

        lock.lock()
        let reg = registrations[makeKey(databaseId, subscriptionKey)]
        let ctx = originContext
        lock.unlock()

        guard let reg = reg else {
            logger?.debug(
                "[db-sub] dropping db.change frame with no registration",
                databaseId, subscriptionKey
            )
            return
        }

        // Decode the changes array; drop malformed elements.
        let rawChanges = payload["changes"] as? [[String: Any]] ?? []
        let changes = rawChanges.compactMap(DatabaseChangeEvent.from)

        // Normalize wire fields; treat absent/non-string as nil so
        // consumers see a stable discriminant.
        let originConnectionId = payload["originConnectionId"] as? String
        let originUserId = payload["originUserId"] as? String

        let localConnectionId = ctx?.getConnectionId()
        let localUserId = ctx?.getCurrentUserId()

        // `isOrigin`: per-connection attribution. Both ids must exist and
        // match — a nil wire id or a missing local id ⇒ false.
        let isOrigin = originConnectionId != nil
            && localConnectionId != nil
            && originConnectionId == localConnectionId

        // `isOriginUser`: per-user attribution. Same rule; a nil
        // originUserId (system write) ⇒ false for everyone.
        let isOriginUser = originUserId != nil
            && localUserId != nil
            && originUserId == localUserId

        let event = DatabaseChangePayload(
            databaseId: databaseId,
            subscriptionKey: subscriptionKey,
            changes: changes,
            timestamp: payload["timestamp"] as? String ?? "",
            originConnectionId: originConnectionId,
            originUserId: originUserId,
            isOrigin: isOrigin,
            isOriginUser: isOriginUser
        )

        reg.onChange(event)
    }
}
