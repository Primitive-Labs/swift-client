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
        // `items`/`cursor`/`nextCursor`/`hasMore` with the `nextCursor ?? cursor`
        // precedence, so the envelope decodes straight into the shared type —
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

    /// Update a database's CEL context dict.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.updateMetadata`.
    @available(*, deprecated, message: "Prefer resource metadata categories (issue #1420). A category has separate readRule/writeRule, so a writer no longer inherits update from read access. Define the category via the CLI `primitive sync` (config/metadata-category-configs) or the REST metadata-categories API, write its values, and read them from CEL as md.self.<category>.<key>. Legacy wire-name alias of the also-deprecated updateCelContext.")
    public func updateMetadata(databaseId: String, metadata: [String: JSONValue]) async throws -> DatabaseInfo {
        try await transport.request(
            method: .patch,
            path: "/databases/\(databaseId)/metadata",
            body: metadata
        )
    }

    /// Read a database's CEL context dict.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.getMetadata`.
    @available(*, deprecated, message: "Prefer resource metadata categories (issue #1420). A category has separate readRule/writeRule (read no longer implies update). Define the category via the CLI `primitive sync` (config/metadata-category-configs) or the REST metadata-categories API and read its values from CEL as md.self.<category>.<key>. Legacy wire-name alias of the also-deprecated getCelContext.")
    public func getMetadata(databaseId: String) async throws -> CelContextResult {
        try await transport.request(method: .get, path: "/databases/\(databaseId)/metadata")
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

    /// List all operations registered on a database.
    public func listOperations(databaseId: String) async throws -> [DatabaseOperationInfo] {
        try await transport.request(method: .get, path: "/databases/\(databaseId)/operations")
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

    /// Execute a registered operation by name, with optional parameters and
    /// pagination. The result shape depends on the operation (query rows,
    /// mutation acknowledgement, count, aggregate), so it is returned as an
    /// opaque `JSONValue` — JS returns `any` here.
    ///
    /// `options.timing` does not travel in the body: the server reads it from
    /// the `X-Timing` request header, so it is sent as a header here and left
    /// out of the encoded options (#2359). Same split the JS client makes.
    public func executeOperation(databaseId: String, name: String, options: ExecuteOperationOptions? = nil) async throws -> JSONValue {
        let encodedName = URLEncoding.encodeComponent(name)
        // Only a `true` sends the header at all — a `false`/omitted flag sends
        // nothing, matching the JS client's truthiness check.
        let requestOptions = options?.timing == true
            ? RequestOptions(customHeaders: ["X-Timing": "true"])
            : nil
        // A `nil` options object sends `{}`, as the untyped body did — every
        // field on `ExecuteOperationOptions` is optional, so the default value
        // encodes to an empty JSON object.
        return try await transport.request(
            method: .post,
            path: "/databases/\(databaseId)/operations/\(encodedName)/execute",
            body: options ?? ExecuteOperationOptions(),
            options: requestOptions
        )
    }

    // MARK: - Typed generic overload (#1547)
    //
    // The published SDK surface for the CLI-generated typed database-ops factory
    // (`primitive databases codegen --lang swift`). The generated `<Type>Ops`
    // struct binds each op's `<Op>Params` in and `<Op>Result` out over THIS
    // overload; only it is library surface (the generated factory is app-target
    // code). It delegates to the untyped `executeOperation` above — encoding the
    // typed `Codable` params into the opaque `params` object and decoding the
    // opaque result blob into `Output` — so no request/response behavior
    // diverges from the untyped path.

    /// Execute a registered operation with typed `Codable` params and a typed
    /// `Output` result. `Params` is encoded into the request `params` object and
    /// the opaque result is decoded into `Output`. Pagination + diagnostics
    /// (`limit`/`cursor`/`direction`/`timing`) pass straight through.
    public func executeOperation<Params: Encodable, Output: Decodable & Sendable>(
        databaseId: String,
        name: String,
        params: Params,
        limit: Int? = nil,
        cursor: String? = nil,
        direction: SortDirection? = nil,
        timing: Bool? = nil
    ) async throws -> Output {
        // Encode the typed params into the loosely-typed `JSONValue` the untyped
        // `ExecuteOperationOptions.params` carries.
        let paramsValue = try JSONCoding.decode(
            JSONValue.self,
            from: JSONCoding.jsonObject(from: params)
        )
        let options = ExecuteOperationOptions(
            params: paramsValue,
            limit: limit,
            cursor: cursor,
            direction: direction,
            timing: timing
        )
        let raw = try await executeOperation(databaseId: databaseId, name: name, options: options)
        // Decode the opaque result blob into the typed `Output`.
        return try JSONCoding.decode(Output.self, from: JSONCoding.jsonObject(from: raw))
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

    // MARK: - CEL Context

    /// Read a database's CEL context dict. Values are referenced from
    /// CEL access rules as `database.celContext.<key>` and from filter
    /// JSON as `$database.celContext.<key>`.
    ///
    /// Response payload includes the same dict under both `metadata`
    /// (legacy wire name) and `celContext` (current name).
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.getCelContext`.
    @available(*, deprecated, message: "Prefer resource metadata categories (issue #1420). The metadataAccess gate that controls this read uses one CEL expression for read AND update, so read implies update. A metadata category has separate readRule/writeRule; read its values from CEL as md.self.<category>.<key>.")
    public func getCelContext(databaseId: String) async throws -> CelContextResult {
        try await transport.request(method: .get, path: "/databases/\(databaseId)/metadata")
    }

    /// Merge new key-value pairs into a database's CEL context dict.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.updateCelContext`.
    @available(*, deprecated, message: "Prefer resource metadata categories (issue #1420). Writing here is gated by the same single metadataAccess expression that gates reads, so anyone who can read can also update. A metadata category has separate readRule/writeRule; read its values from CEL as md.self.<category>.<key>.")
    public func updateCelContext(
        databaseId: String,
        celContext: [String: JSONValue]
    ) async throws -> DatabaseInfo {
        try await transport.request(
            method: .patch,
            path: "/databases/\(databaseId)/metadata",
            body: celContext
        )
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

    // MARK: - Batch operations

    /// Execute a batch of records via a named mutation operation.
    /// Each element is one invocation passed to the operation.
    public func executeBatch(
        databaseId: String,
        operationName: String,
        batch: [DatabaseBatchOperation]
    ) async throws -> DatabaseBatchResult {
        let encodedName = URLEncoding.encodeComponent(operationName)
        return try await transport.request(
            method: .post,
            path: "/databases/\(databaseId)/operations/\(encodedName)/batch",
            body: DatabaseBatchBody(batch: batch)
        )
    }

    /// Import a parsed list of rows into a database via a named mutation
    /// operation. Thin wrapper over `executeBatch` that wraps each row as
    /// `{ params: row }` and batches in groups of `batchSize` records
    /// (defaults to 5000 — matches js-bao).
    ///
    /// - Note: js-bao's `importCsv` (#962a) additionally handles raw CSV
    ///   parsing, schema-aware type coercion, column mapping, and progress
    ///   callbacks. Those higher-level conveniences are deferred; the Swift
    ///   surface starts with pre-parsed rows. To import a CSV string, parse
    ///   it with a third-party parser (e.g. `CodableCSV`) before calling.
    public func importRows(
        databaseId: String,
        operationName: String = "save",
        rows: [[String: JSONValue]],
        batchSize: Int = 5000
    ) async throws -> DatabaseBatchResult {
        guard !rows.isEmpty else {
            return DatabaseBatchResult(imported: 0, failed: 0)
        }
        var imported = 0
        var failed = 0
        var i = 0
        while i < rows.count {
            let end = min(i + batchSize, rows.count)
            let slice = rows[i..<end].map { DatabaseBatchOperation(params: .object($0)) }
            let result = try await executeBatch(
                databaseId: databaseId,
                operationName: operationName,
                batch: Array(slice)
            )
            imported += result.imported
            failed += result.failed
            i = end
        }
        return DatabaseBatchResult(imported: imported, failed: failed)
    }

    /// Import data into a database from a raw CSV string (or pre-parsed rows),
    /// with column mapping, value coercion, per-row transforms, ID assignment,
    /// batched writes, and progress / error callbacks. Mirrors js-bao's
    /// `databases.importCsv` (#962a).
    ///
    /// Pipeline (matches JS): resolve `model`/`modelName` → parse `csv`
    /// (quoted-field aware) or copy `data` → apply `columnMap` → (model only)
    /// filter columns to the schema's fields → coerce values per the schema +
    /// `types` → assign `id` (`idColumn` → `idGenerator` → ULID) → run
    /// `transform` (skip on `nil`) → write in batches of `batchSize`
    /// (default 5000) via the named save operation as `{ modelName, id, data }`
    /// → (model only, unless `syncIndexes == false`) sync the model's indexes
    /// and report the count as `indexesCreated`.
    ///
    /// - Note: schema-driven column filtering, schema type coercion, and
    ///   post-import index sync only run when `options.model` is set (a
    ///   `PrimitiveModel` type, mirroring the JS BaseModel-class path). The
    ///   `modelName`-only path skips all three and leaves `indexesCreated` at
    ///   `0`.
    public func importCsv(databaseId: String, options: CsvImportOptions) async throws -> CsvImportResult {
        let start = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // 1. Resolve model name + (when a model class is given) its schema.
        //    Mirrors JS: `model` resolves the name AND drives field filtering
        //    + index sync; a bare `modelName` does neither.
        let modelName: String
        let schema: PrimitiveSchema?
        if let model = options.model {
            modelName = model.modelName
            schema = model.primitiveSchema
        } else if let name = options.modelName, !name.isEmpty {
            modelName = name
            schema = nil
        } else {
            throw DatabaseImportError.modelNameRequired
        }

        // 2. Parse CSV or copy pre-parsed data into `[header: value]` rows.
        var rows: [[String: String]]
        if let csv = options.csv {
            rows = Self.parseCsv(csv, delimiter: options.delimiter ?? ",")
        } else if let data = options.data {
            rows = data
        } else {
            throw DatabaseImportError.csvOrDataRequired
        }

        if rows.isEmpty {
            return CsvImportResult(imported: 0, failed: 0, errors: [], indexesCreated: 0, durationMs: elapsedMs())
        }

        // 3. Apply columnMap (rename headers).
        if let map = options.columnMap {
            rows = rows.map { row in
                var mapped: [String: String] = [:]
                for (key, value) in row {
                    mapped[map[key] ?? key] = value
                }
                return mapped
            }
        }

        // 4. If a model class was given, filter columns to its schema fields
        //    (mirrors JS: drop any header not in the model's field set). The
        //    `id` column survives because the schema always carries `id`.
        if let schema {
            let allowed = Set(schema.fields.keys)
            rows = rows.map { row in row.filter { allowed.contains($0.key) } }
        }

        // 5 & 6. Build the type-coercion map (schema number/boolean fields,
        //   then explicit `types` overrides — `types` wins, matching JS), then
        //   coerce values, assign IDs, and apply the per-row transform.
        var typeMap = Self.coercionMap(from: schema)
        if let explicit = options.types {
            for (field, type) in explicit { typeMap[field] = type }
        }
        var processedRows: [[String: JSONValue]] = []
        processedRows.reserveCapacity(rows.count)

        for (i, rawRow) in rows.enumerated() {
            // Start from string cells, then coerce known fields.
            var row: [String: JSONValue] = [:]
            for (field, value) in rawRow {
                if let target = typeMap[field] {
                    row[field] = Self.coerceValue(value, to: target)
                } else {
                    row[field] = .string(value)
                }
            }

            // Assign ID: idColumn → idGenerator → existing id → ULID.
            if let idColumn = options.idColumn,
               let raw = rawRow[idColumn] {
                row["id"] = .string(raw)
            } else if let idGenerator = options.idGenerator {
                row["id"] = .string(idGenerator(row, i))
            } else if row["id"] == nil || row["id"]?.isNull == true {
                row["id"] = .string(PrimitiveSchemaRegistry.generateULID())
            }

            // Per-row transform; nil skips the row.
            if let transform = options.transform {
                guard let result = transform(row, i) else { continue }
                row = result
            }
            processedRows.append(row)
        }

        // 7. Build batch items as `{ params: { modelName, id, data: row } }`.
        let operationName = options.operationName ?? "save"
        let batch: [DatabaseBatchOperation] = processedRows.map { row in
            let id = row["id"] ?? .null
            return DatabaseBatchOperation(params: .object([
                "modelName": .string(modelName),
                "id": id,
                "data": .object(row),
            ]))
        }

        // 8. Import in batches of `batchSize`.
        let importBatchSize = max(1, options.batchSize ?? 5000)
        var imported = 0
        var failed = 0
        var errors: [CsvImportError] = []
        let totalBatches = (batch.count + importBatchSize - 1) / importBatchSize

        for b in 0..<totalBatches {
            let lower = b * importBatchSize
            let upper = min(lower + importBatchSize, batch.count)
            let chunk = Array(batch[lower..<upper])
            do {
                let res = try await executeBatch(
                    databaseId: databaseId,
                    operationName: operationName,
                    batch: chunk
                )
                imported += res.imported
                failed += res.failed
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                errors.append(CsvImportError(batchIndex: b, error: message))
                failed += chunk.count
                if let onBatchError = options.onBatchError {
                    let shouldContinue = onBatchError(error, b)
                    if shouldContinue == false { break }
                }
            }
            if let onProgress = options.onProgress {
                onProgress(CsvImportProgress(
                    processed: min((b + 1) * importBatchSize, processedRows.count),
                    total: processedRows.count,
                    imported: imported,
                    failed: failed,
                    batchIndex: b
                ))
            }
        }

        // 9. Sync indexes from the model schema (model-class path only, unless
        //    explicitly disabled). Mirrors JS:
        //    `syncIndexes !== false && model && typeof model !== "string"`.
        var indexesCreated = 0
        if let schema, options.syncIndexes != false {
            let syncState = Self.modelSyncState(from: schema)
            indexesCreated = try await connect(databaseId: databaseId)
                .syncIndexes(models: [syncState])
        }

        return CsvImportResult(
            imported: imported,
            failed: failed,
            errors: errors,
            indexesCreated: indexesCreated,
            durationMs: elapsedMs()
        )
    }

    // MARK: - Model-class import helpers

    /// Build the CSV type-coercion map from a model schema: number-like
    /// fields → `.number`, boolean fields → `.boolean`. Mirrors JS
    /// `importCsv` step 5 (`number`/`float`/`integer` → number, `boolean` →
    /// boolean). Returns an empty map when no schema is given.
    static func coercionMap(from schema: PrimitiveSchema?) -> [String: CsvCoercionType] {
        guard let schema else { return [:] }
        var map: [String: CsvCoercionType] = [:]
        for (fieldName, desc) in schema.fields {
            switch desc.type {
            case .number:
                map[fieldName] = .number
            case .boolean:
                map[fieldName] = .boolean
            default:
                break
            }
        }
        return map
    }

    /// Extract the desired index state for the `/indexes/sync` batch from a
    /// model schema. Mirrors js-bao's `extractModelSyncState`: skip `id`,
    /// include every field flagged `indexed` or `unique` (single-field uniques
    /// carry `unique: true`), and pass the compound unique constraints.
    static func modelSyncState(from schema: PrimitiveSchema) -> DoDbModelSyncState {
        var indexes: [DoDbModelSyncState.Index] = []
        for (fieldName, desc) in schema.fields.sorted(by: { $0.key < $1.key }) {
            if fieldName == "id" { continue }
            guard desc.indexed || desc.unique else { continue }
            indexes.append(.init(
                fieldName: fieldName,
                fieldType: desc.type.rawValue,
                unique: desc.unique
            ))
        }
        // Only compound (multi-field) constraints go on the wire as named
        // constraints; single-field uniques ride the `unique` index flag
        // above. Matches js-bao's `schema.options.uniqueConstraints`.
        let uniqueConstraints = schema.constraints.values
            .filter { $0.fields.count > 1 }
            .sorted(by: { $0.name < $1.name })
            .map { DoDbModelSyncState.UniqueConstraint(name: $0.name, fields: $0.fields) }
        return DoDbModelSyncState(
            modelName: schema.name,
            indexes: indexes,
            uniqueConstraints: uniqueConstraints
        )
    }

    // MARK: - CSV parsing helpers

    /// Quoted-field-aware CSV parser. Ports js-bao's `parseCsv`: splits lines
    /// while respecting quotes (which may span newlines), unescapes doubled
    /// quotes, trims unquoted cells, and drops empty cells/rows. Returns one
    /// `[header: value]` dictionary per data row.
    static func parseCsv(_ csv: String, delimiter: String = ",") -> [[String: String]] {
        let delim = delimiter.first ?? ","
        let chars = Array(csv)

        // Split into raw lines, respecting quoted newlines.
        var lines: [String] = []
        var current = ""
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 1
                } else {
                    inQuotes.toggle()
                }
                current.append(ch)
            } else if (ch == "\n" || ch == "\r") && !inQuotes {
                lines.append(current)
                current = ""
                if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else {
                current.append(ch)
            }
            i += 1
        }
        if !current.isEmpty { lines.append(current) }
        guard !lines.isEmpty else { return [] }

        func parseRow(_ line: String) -> [String] {
            var fields: [String] = []
            var field = ""
            var q = false
            var wasQuoted = false
            let lineChars = Array(line)
            var j = 0
            while j < lineChars.count {
                let ch = lineChars[j]
                if ch == "\"" {
                    if q, j + 1 < lineChars.count, lineChars[j + 1] == "\"" {
                        field.append("\"")
                        j += 1
                    } else {
                        q.toggle()
                        if q { wasQuoted = true }
                    }
                } else if ch == delim && !q {
                    fields.append(wasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
                    field = ""
                    wasQuoted = false
                } else {
                    field.append(ch)
                }
                j += 1
            }
            fields.append(wasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
            return fields
        }

        let headers = parseRow(lines[0])
        var result: [[String: String]] = []
        for k in 1..<lines.count {
            let trimmed = lines[k].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let values = parseRow(trimmed)
            var row: [String: String] = [:]
            for (idx, h) in headers.enumerated() {
                if idx < values.count, !values[idx].isEmpty {
                    row[h] = values[idx]
                }
            }
            if !row.isEmpty { result.append(row) }
        }
        return result
    }

    /// Coerce a string cell to a typed `JSONValue`. Ports js-bao's
    /// `coerceValue`: `number` parses to a double (falling back to the raw
    /// string when not numeric), `boolean` is true for `"true"`/`"1"`/`"yes"`,
    /// and `string` passes through.
    static func coerceValue(_ value: String, to type: CsvCoercionType) -> JSONValue {
        switch type {
        case .number:
            if let n = Double(value) { return .number(n) }
            return .string(value)
        case .boolean:
            return .bool(value == "true" || value == "1" || value == "yes")
        case .string:
            return .string(value)
        }
    }
}

// MARK: - Request / response shims

/// Body of the batch / bulk-import endpoints: `{ batch: [...] }`.
private struct DatabaseBatchBody: Encodable, Sendable {
    let batch: [DatabaseBatchOperation]
}


/// Errors thrown by `databases.importCsv` before any network call. Mirror the
/// guard clauses in js-bao's `importCsv`.
public enum DatabaseImportError: Error, LocalizedError, Equatable {
    /// Neither `model` nor `modelName` was provided.
    case modelNameRequired
    /// Neither `csv` nor `data` was provided.
    case csvOrDataRequired

    public var errorDescription: String? {
        switch self {
        case .modelNameRequired: return "Either model or modelName is required"
        case .csvOrDataRequired: return "Either csv or data is required"
        }
    }
}
