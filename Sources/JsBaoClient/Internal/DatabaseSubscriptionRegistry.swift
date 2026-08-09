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
/// Since #2367 the values this registry *stores* are all `Sendable` on their
/// own: `Registration.onChange` is a `@Sendable` closure,
/// `Registration.params` is `[String: JSONValue]`, and `OriginContext`'s two
/// lookup closures are `@Sendable`. The conformance stays unchecked because
/// the registry has mutable stored state (`registrations`, `originContext`)
/// guarded by a lock rather than by the type system.
///
/// Note the boundary: this says nothing about the `DatabaseChangePayload` the
/// stored callback is *handed*. That type and its `DatabaseChangeEvent`
/// elements are still `@unchecked Sendable` because `data` / `previousData`
/// are `Any?` — row currency deferred to #2546. Annotating `onChange`
/// `@Sendable` did not make its argument checked.
///
/// The argument that the registry itself is safe has three parts:
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
///     closures stay inside the registry. `params` is `[String: JSONValue]`, a
///     recursive value type, so the copy is complete rather than one level
///     deep. Each closure is therefore invoked from exactly one place, on
///     whichever thread delivered the frame — the same contract the JS
///     client's registry has, and why the closure must be `@Sendable`.
///
/// `logger` is a `let`, so it is not part of the mutable state the lock
/// confines; `Logger` does its own internal locking.
final class DatabaseSubscriptionRegistry: @unchecked Sendable {
    /// Lookups used to synthesize `isOrigin` / `isOriginUser` on inbound
    /// frames. Resolved lazily at dispatch time (not at register time)
    /// because either value can change while a subscription is live.
    struct OriginContext {
        let getConnectionId: @Sendable () -> String?
        let getCurrentUserId: @Sendable () -> String?
    }

    /// Opaque identity for one `register` call, so a handle that was already
    /// superseded cannot remove the registration that replaced it.
    ///
    /// Registering the same `(databaseId, subscriptionKey)` twice replaces the
    /// first callback (matching the JS client). Without an identity check the
    /// first subscription's handle — still held by the caller, and cancelled by
    /// `EventSubscription.deinit` when that caller goes away — would remove the
    /// *second*, live registration. Follows `EventEmitter`'s
    /// monotonic-id-with-identity-checked-removal pattern.
    struct RegistrationID: Equatable {
        fileprivate let value: UInt64
    }

    private struct Registration {
        let id: RegistrationID
        let databaseId: String
        let subscriptionKey: String
        let params: [String: JSONValue]
        let onChange: @Sendable (DatabaseChangePayload) -> Void
    }

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]
    private var nextRegistrationID: UInt64 = 0
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
    ///
    /// - Returns: the identity of this registration. Pass it back to
    ///   ``unregister(databaseId:subscriptionKey:id:)`` so a stale handle
    ///   cannot remove a registration that has since replaced this one.
    func register(
        databaseId: String,
        subscriptionKey: String,
        params: [String: JSONValue],
        onChange: @escaping @Sendable (DatabaseChangePayload) -> Void
    ) -> RegistrationID {
        lock.lock()
        defer { lock.unlock() }
        nextRegistrationID &+= 1
        let id = RegistrationID(value: nextRegistrationID)
        registrations[makeKey(databaseId, subscriptionKey)] = Registration(
            id: id,
            databaseId: databaseId,
            subscriptionKey: subscriptionKey,
            params: params,
            onChange: onChange
        )
        return id
    }

    /// Remove the registration for `(databaseId, subscriptionKey)`, but only if
    /// it is still the one `id` identifies. Later frames for this pair are
    /// dropped (debug-logged, not an error).
    ///
    /// - Returns: `true` when this call removed the registration, `false` when
    ///   `id` was stale (already replaced or already removed). The caller uses
    ///   that to decide whether to send `db.unsubscribe` — a stale handle must
    ///   not tear down the live server-side subscription.
    @discardableResult
    func unregister(databaseId: String, subscriptionKey: String, id: RegistrationID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = makeKey(databaseId, subscriptionKey)
        guard registrations[key]?.id == id else { return false }
        registrations.removeValue(forKey: key)
        return true
    }

    /// Snapshot of all live registrations, for reconnect re-subscribe.
    func list() -> [(databaseId: String, subscriptionKey: String, params: [String: JSONValue])] {
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
