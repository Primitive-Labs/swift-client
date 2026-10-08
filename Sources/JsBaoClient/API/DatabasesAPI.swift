import Foundation

// MARK: - DatabasesAPI

public final class DatabasesAPI: @unchecked Sendable {
    private let transport: any Transport

    // MARK: - Realtime subscription plumbing
    //
    // Wired by `JsBaoClient.setupSubApis()`. When constructed without
    // these (tests / standalone usage), `subscribe(...)` still registers
    // the callback locally but cannot send frames — calls degrade to a
    // no-op send (the returned handle still deregisters cleanly).

    /// Shared registry that routes inbound `db.change` frames. Exposed so
    /// `JsBaoClient`'s WS message router can `dispatch(...)` and its
    /// reconnect path can `list()` for re-subscribe. `nil` only in the
    /// bare `init(transport:)` path.
    let subscriptionRegistry: DatabaseSubscriptionRegistry?

    /// Send a JSON-encoded control frame over the WebSocket. Fire-and-
    /// forget (the WS send is async under the hood); callers gate on
    /// `isWebSocketOpen()` first.
    private let sendWSMessage: ((String) -> Void)?

    /// `true` when the WebSocket is open and frames will be delivered.
    private let isWebSocketOpen: () -> Bool

    /// Nudge the WS manager to (re)connect. The reconnect pass re-issues
    /// `db.subscribe` for every live registration once the socket opens.
    private let connectWebSocket: () -> Void

    private let logger: Logger?

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
        self.subscriptionRegistry = nil
        self.sendWSMessage = nil
        self.isWebSocketOpen = { false }
        self.connectWebSocket = {}
        self.logger = nil
    }

    /// Full init used by `JsBaoClient` — wires the realtime subscription
    /// machinery (`databases.subscribe`).
    init(
        transport: any Transport,
        subscriptionRegistry: DatabaseSubscriptionRegistry,
        sendWSMessage: @escaping (String) -> Void,
        isWebSocketOpen: @escaping () -> Bool,
        connectWebSocket: @escaping () -> Void,
        logger: Logger? = nil
    ) {
        self.transport = transport
        self.subscriptionRegistry = subscriptionRegistry
        self.sendWSMessage = sendWSMessage
        self.isWebSocketOpen = isWebSocketOpen
        self.connectWebSocket = connectWebSocket
        self.logger = logger
    }

    // MARK: - Realtime subscriptions

    /// Subscribe to real-time database changes for a server-registered
    /// subscription (created via the `/databases/:id/subscriptions` admin
    /// endpoint). The server filters events by the subscription's CEL
    /// `filter` and access rule, so `onChange` only fires for rows the
    /// subscriber is allowed to see. Mirrors js-bao's
    /// `client.databases.subscribe(databaseId, subscriptionKey, { params, onChange })`.
    ///
    /// Sends `db.subscribe` over the active WebSocket; inbound `db.change`
    /// frames are routed back to `onChange`. If the socket isn't open yet, the
    /// registration is held and the reconnect pass re-issues `db.subscribe`
    /// once it opens (matches the JS reconnect behavior).
    ///
    /// `onChange` is `@Sendable` because it runs on whichever thread delivered
    /// the frame — the WebSocket delivery thread, not the caller's.
    ///
    /// - Returns: the subscription handle. **Hold it for as long as you want
    ///   changes**: the handle cancels itself when it is released, so dropping
    ///   it unsubscribes rather than leaking a server-side subscription.
    ///   `cancel()` is idempotent.
    /// - Throws: `JsBaoError(.invalidArgument, …)` if `databaseId` or
    ///   `subscriptionKey` is empty, matching the JS client's
    ///   `_subscribeDatabase` guards.
    public func subscribe(
        databaseId: String,
        subscriptionKey: String,
        options: DatabaseSubscribeOptions = DatabaseSubscribeOptions(),
        onChange: @escaping @Sendable (DatabaseChangePayload) -> Void
    ) throws -> EventSubscription {
        guard !databaseId.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "subscribeDatabase: databaseId is required"
            )
        }
        guard !subscriptionKey.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "subscribeDatabase: subscriptionKey is required"
            )
        }
        guard let registry = subscriptionRegistry else {
            logger?.warn("[db-sub] subscribe: realtime subscriptions are not wired (constructed without a WebSocket)")
            return EventSubscription(cancel: {})
        }

        let params = options.params ?? [:]
        let registrationID = registry.register(
            databaseId: databaseId,
            subscriptionKey: subscriptionKey,
            params: params,
            onChange: onChange
        )

        // Send immediately if open; otherwise nudge a connect — the
        // reconnect pass re-issues `db.subscribe` on open.
        if isWebSocketOpen() {
            sendSubscribeFrame(databaseId: databaseId, subscriptionKey: subscriptionKey, params: params)
        } else {
            connectWebSocket()
        }

        return EventSubscription { [weak registry, weak self] in
            // Only the handle that owns the live registration may tear it
            // down. A superseded handle removes nothing and sends nothing.
            guard registry?.unregister(
                databaseId: databaseId,
                subscriptionKey: subscriptionKey,
                id: registrationID
            ) == true else { return }
            guard let self = self, self.isWebSocketOpen() else { return }
            self.encodeAndSend([
                "type": "db.unsubscribe",
                "databaseId": databaseId,
                "subscriptionKey": subscriptionKey,
            ])
        }
    }

    /// Subscribe with the change payload decoded into a typed `Row` (#2805).
    ///
    /// The published SDK surface for the CLI-generated typed subscriptions
    /// factory (`primitive databases codegen --lang swift`): the generated
    /// `<Type>.Subscriptions` struct binds each registered subscription's row
    /// type over THIS overload. It is a thin wrapper over the
    /// untyped `subscribe` above — same registration, same frames, same
    /// reconnect behavior — that maps each delivered payload through
    /// ``TypedDatabaseChangePayload/init(decoding:as:)``.
    ///
    /// `Row` must declare every field optional: a change frame carries only the
    /// fields the write touched, narrowed further by the subscription's
    /// `select`, so a blob that is missing a required field would decode to
    /// `nil` and hand the caller nothing. The generated row types are emitted
    /// that way for exactly this reason (#1772).
    ///
    /// - Parameter rowType: the type each change's `data` / `previousData`
    ///   decodes into. Passed explicitly so this never competes with the
    ///   untyped overload during overload resolution.
    /// - Returns: the subscription handle. **Hold it for as long as you want
    ///   changes** — releasing it unsubscribes.
    public func subscribe<Row: Decodable & Sendable>(
        databaseId: String,
        subscriptionKey: String,
        rowType: Row.Type,
        options: DatabaseSubscribeOptions = DatabaseSubscribeOptions(),
        onChange: @escaping @Sendable (TypedDatabaseChangePayload<Row>) -> Void
    ) throws -> EventSubscription {
        try subscribe(
            databaseId: databaseId,
            subscriptionKey: subscriptionKey,
            options: options
        ) { payload in
            onChange(TypedDatabaseChangePayload(decoding: payload, as: Row.self))
        }
    }

    /// Send a single `db.subscribe` control frame. Shared by `subscribe`
    /// and the reconnect re-subscribe pass (`resubscribeAll`).
    ///
    /// Lowers the typed `params` to the `Any` graph `JSONSerialization` needs
    /// at the wire boundary — the same boundary pattern as
    /// `AnalyticsQueue.prepared(_:)`.
    ///
    /// Encoding can only fail on a value `JSONEncoder` rejects (a non-finite
    /// `.number`). This frame is fire-and-forget, so it cannot throw — but an
    /// empty `params` binds nothing in the server-side filter, which is a
    /// silent behavior change rather than a no-op, so it is logged.
    func sendSubscribeFrame(databaseId: String, subscriptionKey: String, params: [String: JSONValue]) {
        var paramsAny: [String: Any] = [:]
        do {
            paramsAny = try JSONCoding.jsonObject(from: params) as? [String: Any] ?? [:]
        } catch {
            logger?.warn(
                "[db-sub] subscribe: params for \(subscriptionKey) could not be encoded "
                    + "(\(error)); sending an empty params bag, so the subscription filter "
                    + "will bind nothing"
            )
        }
        encodeAndSend([
            "type": "db.subscribe",
            "databaseId": databaseId,
            "subscriptionKey": subscriptionKey,
            "params": paramsAny,
        ])
    }

    /// Re-issue `db.subscribe` for every live registration. Called by
    /// `JsBaoClient` after the WebSocket (re)connects — the server-side
    /// connection mapping is dropped on disconnect, so the client must
    /// re-register before the next change will be delivered. Mirrors the
    /// JS client's reconnect re-subscribe pass.
    func resubscribeAll() {
        guard let registry = subscriptionRegistry, isWebSocketOpen() else { return }
        for sub in registry.list() {
            sendSubscribeFrame(
                databaseId: sub.databaseId,
                subscriptionKey: sub.subscriptionKey,
                params: sub.params
            )
        }
    }

    /// JSON-encode a control frame and hand it to the WS send closure.
    /// Debug-logs and drops the frame on an encode failure.
    private func encodeAndSend(_ frame: [String: Any]) {
        guard let send = sendWSMessage else { return }
        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            logger?.debug("[db-sub] failed to encode control frame", frame["type"] as? String ?? "?")
            return
        }
        send(text)
    }

    // MARK: - Direct record access (DoDb)

    /// Connect to a database and get a `DoDb` handle for direct record
    /// reads/writes, atomic ops, batch writes, aggregation, and index
    /// management. Mirrors js-bao's `client.databases.connect(databaseId)`.
    ///
    /// The returned handle is scoped to `databaseId` and routes through the
    /// same transport this API uses, so it inherits the bearer token and
    /// `X-JB-Connection-Id` header automatically — matching the connection
    /// attribution the JS `connect()` arranges by hand. The handle is
    /// stateless beyond the bound ID, so it's cheap to create and safe to
    /// hold or discard.
    public func connect(databaseId: String) -> DoDb {
        DoDb(databaseId: databaseId, transport: transport)
    }

    // MARK: - CRUD

    /// Create a new database.
    public func create(params: CreateDatabaseParams) async throws -> DatabaseInfo {
        try await transport.request(method: .post, path: "/databases", body: params)
    }

    /// List the databases the current user can access.
    ///
    /// Pass `databaseType` to filter to a single type server-side (mirrors
    /// js-bao's `databases.list({ databaseType })`, #962).
    ///
    /// Pass `owner` to narrow the listing to the databases that user created
    /// (mirrors js-bao's `databases.list({ owner })` and the CLI's
    /// `primitive databases list --owner <user-id>`, #1965). Like
    /// `databaseType` it only narrows, never widens: an app admin gets that
    /// user's databases, an ordinary member gets the subset of their own
    /// grants that user created. An owner with no databases is an empty list,
    /// not an error.
    ///
    /// Results are paged at 100 per call (#1958). This returns the first
    /// page's items; use ``listPage(databaseType:owner:limit:cursor:)`` when
    /// you need the continuation token.
    ///
    /// An app admin or app owner (promoted in-app or holding console access)
    /// lists every database in the app, and each row comes back with
    /// `permission == "owner"` — the field reports capability, not ownership.
    /// To pick out the databases the caller created, compare `createdBy`
    /// against `client.userId`.
    public func list(
        databaseType: String? = nil,
        owner: String? = nil
    ) async throws -> [DatabaseInfo] {
        try await listPage(databaseType: databaseType, owner: owner).items
    }

    /// One page of the databases the current user can access, with the
    /// continuation token.
    ///
    /// Mirrors js-bao's `databases.list({ limit, cursor, returnPage: true })`.
    /// `limit` defaults to and is capped at 100; follow `nextCursor` until it
    /// is `nil` to enumerate every database.
    ///
    /// A cursor belongs to the listing that produced it: replaying one after
    /// changing `owner` (or dropping it) fails with a 400 rather than
    /// returning a page from the wrong partition — start a new listing when
    /// the filter changes.
    public func listPage(
        databaseType: String? = nil,
        owner: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> PaginatedResult<DatabaseInfo> {
        var query = URLQuery()
        // Parameter order matches the JS client's (`type`, `owner`, `limit`,
        // `cursor`) so both clients produce the same URL.
        query.appendIfPresent("type", databaseType)
        query.appendIfPresent("owner", owner)
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        // `PaginatedResult` already conforms to `Decodable` (see the
        // constrained extension in `Types/GroupsTypes.swift`) and decodes
        // `items`/`nextCursor`/`hasMore`, so the envelope decodes straight into
        // the shared type —
        // no per-surface page struct and re-map to drift. It is wrapped in
        // `PaginatedPageEnvelope` only to also accept the bare array a server
        // older than #1958 still returns (#2245).
        let envelope: PaginatedPageEnvelope<DatabaseInfo> = try await transport.request(
            method: .get,
            path: "/databases\(query.queryString)"
        )
        // An empty `owner` is "no filter", matching the JS client's
        // `if (options?.owner)` and the CLI's truthiness guard — and the
        // server, which treats `?owner=` as absent. Without the `isEmpty`
        // check `list(owner: "")` would filter the legacy page to
        // `createdBy == ""` and come back empty against a server that returns
        // the full list.
        guard let owner, !owner.isEmpty, envelope.isLegacyArray else {
            return envelope.page
        }
        // A server old enough to answer with a bare array (pre-#1958) also
        // predates the `owner` filter (#1965) and ignores the unknown query
        // parameter, so it just returned its full list. Without this guard the
        // tolerant decode would hand those rows back as if they were filtered.
        // The legacy rows carry `createdBy`, so filtering here reproduces the
        // server's own post-join filter, and it can only narrow the page the
        // caller was already allowed to see. The JS client and the CLI apply
        // the same guard on their legacy path (#2245).
        return PaginatedResult(
            items: envelope.page.items.filter { $0.createdBy == owner },
            hasMore: false
        )
    }

    /// Get database info by ID.
    public func get(databaseId: String) async throws -> DatabaseInfo {
        try await transport.request(method: .get, path: "/databases/\(databaseId)")
    }

    /// Update a database's title or type.
    public func update(databaseId: String, params: UpdateDatabaseParams) async throws -> DatabaseInfo {
        try await transport.request(method: .patch, path: "/databases/\(databaseId)", body: params)
    }

    /// Delete a database.
    @discardableResult
    public func delete(databaseId: String) async throws -> DatabaseSuccessResult {
        try await transport.request(method: .delete, path: "/databases/\(databaseId)")
    }

    // MARK: - Permissions

    /// List all permission entries for a database.
    public func listPermissions(databaseId: String) async throws -> [DatabasePermissionEntry] {
        try await transport.request(method: .get, path: "/databases/\(databaseId)/permissions")
    }

    /// Transfer database ownership to another user.
    public func transferOwnership(databaseId: String, newOwnerId: String) async throws -> DatabaseOwnershipTransferResult {
        try await transport.request(
            method: .post,
            path: "/databases/\(databaseId)/permissions/transfer",
            body: ["newOwnerId": newOwnerId]
        )
    }

    // MARK: - Operations

    /// Create a new operation (query or mutation) on a database.
    public func createOperation(databaseId: String, params: CreateOperationParams) async throws -> DatabaseOperationInfo {
        try await transport.request(
            method: .post,
            path: "/databases/\(databaseId)/operations",
            body: params
        )
    }

    /// Get a single operation by name.
    public func getOperation(databaseId: String, name: String) async throws -> DatabaseOperationInfo {
        let encodedName = URLEncoding.encodeComponent(name)
        return try await transport.request(
            method: .get,
            path: "/databases/\(databaseId)/operations/\(encodedName)"
        )
    }

    /// Update an existing operation's definition or access level.
    public func updateOperation(databaseId: String, name: String, params: UpdateOperationParams) async throws -> DatabaseOperationInfo {
        let encodedName = URLEncoding.encodeComponent(name)
        return try await transport.request(
            method: .patch,
            path: "/databases/\(databaseId)/operations/\(encodedName)",
            body: params
        )
    }

    /// Delete an operation from a database.
    @discardableResult
    public func deleteOperation(databaseId: String, name: String) async throws -> DatabaseSuccessResult {
        let encodedName = URLEncoding.encodeComponent(name)
        return try await transport.request(
            method: .delete,
            path: "/databases/\(databaseId)/operations/\(encodedName)"
        )
    }

    // MARK: - Schema

    /// Get the field schema for a model in a database.
    public func describe(databaseId: String, modelName: String) async throws -> [ModelFieldInfo] {
        var query = URLQuery()
        query.append("modelName", modelName)
        // The server may wrap the field list in a `{ fields }` envelope.
        let response: ModelFieldsEnvelope = try await transport.request(
            method: .get,
            path: "/databases/\(databaseId)/records/describe\(query.queryString)"
        )
        return response.fields
    }

    // MARK: - Managers

    /// List a database's managers (permission entries with manager grants).
    /// Convenience wrapper over `listPermissions` that filters to the
    /// `manager` rows. js-bao counterpart: `listManagers(databaseId)`.
    public func listManagers(databaseId: String) async throws -> [DatabasePermissionEntry] {
        let perms = try await listPermissions(databaseId: databaseId)
        return perms.filter { $0.permission == "manager" }
    }

    /// Add a user as a manager of a database.
    public func addManager(
        databaseId: String,
        params: AddManagerParams
    ) async throws -> DatabasePermissionEntry {
        try await transport.request(
            method: .put,
            path: "/databases/\(databaseId)/permissions",
            body: ["userId": params.userId, "permission": "manager"]
        )
    }

    /// Remove a manager from a database.
    @discardableResult
    public func removeManager(
        databaseId: String,
        userId: String
    ) async throws -> DatabaseSuccessResult {
        let escapedId = URLEncoding.encodeComponent(userId)
        return try await transport.request(
            method: .delete,
            path: "/databases/\(databaseId)/permissions/\(escapedId)"
        )
    }

    // MARK: - Group Permissions

    /// List the group permissions configured on a database.
    /// Platform-managed groups (whose `groupType` starts with `_`) are
    /// excluded unless `includeSystem: true`.
    public func listGroupPermissions(
        databaseId: String,
        includeSystem: Bool = false
    ) async throws -> [DatabaseGroupPermissionEntry] {
        let qs = includeSystem ? "?includeSystem=true" : ""
        return try await transport.request(
            method: .get,
            path: "/databases/\(databaseId)/group-permissions\(qs)"
        )
    }

    /// Grant a group permission on a database. Members of the specified
    /// group gain the permission level on the database.
    public func grantGroupPermission(
        databaseId: String,
        params: GrantDatabaseGroupPermissionParams
    ) async throws -> DatabaseGroupPermissionEntry {
        try await transport.request(
            method: .post,
            path: "/databases/\(databaseId)/group-permissions",
            body: params
        )
    }

    /// Revoke a group's permission on a database.
    @discardableResult
    public func revokeGroupPermission(
        databaseId: String,
        groupType: String,
        groupId: String
    ) async throws -> DatabaseSuccessResult {
        let gType = URLEncoding.encodeComponent(groupType)
        let gId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .delete,
            path: "/databases/\(databaseId)/group-permissions/\(gType)/\(gId)"
        )
    }
}
