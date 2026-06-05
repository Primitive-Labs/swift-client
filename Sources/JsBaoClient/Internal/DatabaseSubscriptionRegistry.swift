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
/// registry never touches the network layer. Thread-safe via `lock`
/// because `register` / `dispatch` / `list` can be called from any thread
/// (subscribe call site, WS receive task, reconnect task).
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

    func has(databaseId: String, subscriptionKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registrations[makeKey(databaseId, subscriptionKey)] != nil
    }

    /// Snapshot of all live registrations, for reconnect re-subscribe.
    func list() -> [(databaseId: String, subscriptionKey: String, params: [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return registrations.values.map {
            ($0.databaseId, $0.subscriptionKey, $0.params)
        }
    }

    /// Clear all registrations (client destroy).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        registrations.removeAll()
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
