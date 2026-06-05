import Foundation

// MARK: - DatabasesAPI

public final class DatabasesAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    // MARK: - Realtime subscription plumbing
    //
    // Wired by `JsBaoClient.setupSubApis()`. When constructed without
    // these (tests / standalone usage), `subscribe(...)` still registers
    // the callback locally but cannot send frames — calls degrade to a
    // no-op send (the returned handle still deregisters cleanly).

    /// Shared registry that routes inbound `db.change` frames. Exposed so
    /// `JsBaoClient`'s WS message router can `dispatch(...)` and its
    /// reconnect path can `list()` for re-subscribe. `nil` only in the
    /// bare `init(makeRequest:)` path.
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

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
        self.subscriptionRegistry = nil
        self.sendWSMessage = nil
        self.isWebSocketOpen = { false }
        self.connectWebSocket = {}
        self.logger = nil
    }

    /// Full init used by `JsBaoClient` — wires the realtime subscription
    /// machinery (`databases.subscribe`).
    init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        subscriptionRegistry: DatabaseSubscriptionRegistry,
        sendWSMessage: @escaping (String) -> Void,
        isWebSocketOpen: @escaping () -> Bool,
        connectWebSocket: @escaping () -> Void,
        logger: Logger? = nil
    ) {
        self.makeRequest = makeRequest
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
    /// frames are routed back to `options.onChange`. If the socket isn't
    /// open yet, the registration is held and the reconnect pass re-issues
    /// `db.subscribe` once it opens (matches the JS reconnect behavior).
    ///
    /// - Returns: an unsubscribe handle — calling it removes the callback
    ///   and sends `db.unsubscribe`. Safe to call multiple times.
    /// - Throws: `JsBaoError(.invalidArgument, …)` if `databaseId` or
    ///   `subscriptionKey` is empty, matching the JS client's
    ///   `_subscribeDatabase` guards.
    @discardableResult
    public func subscribe(
        databaseId: String,
        subscriptionKey: String,
        options: DatabaseSubscribeOptions
    ) throws -> () -> Void {
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
            return {}
        }

        let params = options.params ?? [:]
        registry.register(
            databaseId: databaseId,
            subscriptionKey: subscriptionKey,
            params: params,
            onChange: options.onChange
        )

        // Send immediately if open; otherwise nudge a connect — the
        // reconnect pass re-issues `db.subscribe` on open.
        if isWebSocketOpen() {
            sendSubscribeFrame(databaseId: databaseId, subscriptionKey: subscriptionKey, params: params)
        } else {
            connectWebSocket()
        }

        return { [weak registry, weak self] in
            registry?.unregister(databaseId: databaseId, subscriptionKey: subscriptionKey)
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
    func sendSubscribeFrame(databaseId: String, subscriptionKey: String, params: [String: Any]) {
        encodeAndSend([
            "type": "db.subscribe",
            "databaseId": databaseId,
            "subscriptionKey": subscriptionKey,
            "params": params,
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
    /// same `makeRequest` closure this API uses, so it inherits the bearer
    /// token and `X-JB-Connection-Id` header automatically — matching the
    /// connection attribution the JS `connect()` arranges by hand. The handle
    /// is stateless beyond the bound ID, so it's cheap to create and safe to
    /// hold or discard.
    public func connect(databaseId: String) -> DoDb {
        DoDb(databaseId: databaseId, makeRequest: makeRequest)
    }

    // MARK: - CRUD

    /// Create a new database.
    public func create(params: CreateDatabaseParams) async throws -> DatabaseInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/databases", body)
        return try JSONCoding.decode(DatabaseInfo.self, from: result)
    }

    /// List all databases the current user can access.
    ///
    /// Pass `databaseType` to filter to a single type server-side (mirrors
    /// js-bao's `databases.list({ databaseType })`, #962).
    public func list(databaseType: String? = nil) async throws -> [DatabaseInfo] {
        var path = "/databases"
        if let databaseType,
           let escaped = databaseType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?type=\(escaped)"
        }
        let result = try await makeRequest("GET", path, nil)
        return try JSONCoding.decode([DatabaseInfo].self, from: result)
    }

    /// Get database info by ID.
    public func get(databaseId: String) async throws -> DatabaseInfo {
        let result = try await makeRequest("GET", "/databases/\(databaseId)", nil)
        return try JSONCoding.decode(DatabaseInfo.self, from: result)
    }

    /// Update a database's title or type.
    public func update(databaseId: String, params: UpdateDatabaseParams) async throws -> DatabaseInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)", body)
        return try JSONCoding.decode(DatabaseInfo.self, from: result)
    }

    /// Update a database's CEL context dict.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.updateMetadata`.
    @available(*, deprecated, message: "Use databases.updateCelContext(databaseId:celContext:) instead.")
    public func updateMetadata(databaseId: String, metadata: [String: JSONValue]) async throws -> DatabaseInfo {
        let body = try JSONCoding.jsonObject(from: metadata)
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)/metadata", body)
        return try JSONCoding.decode(DatabaseInfo.self, from: result)
    }

    /// Read a database's CEL context dict.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.getMetadata`.
    @available(*, deprecated, message: "Use databases.getCelContext(databaseId:) instead.")
    public func getMetadata(databaseId: String) async throws -> CelContextResult {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/metadata", nil)
        return try JSONCoding.decode(CelContextResult.self, from: result)
    }

    /// Delete a database.
    @discardableResult
    public func delete(databaseId: String) async throws -> DatabaseSuccessResult {
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)", nil)
        return try JSONCoding.decode(DatabaseSuccessResult.self, from: result)
    }

    // MARK: - Permissions

    /// List all permission entries for a database.
    public func listPermissions(databaseId: String) async throws -> [DatabasePermissionEntry] {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/permissions", nil)
        return try JSONCoding.decode([DatabasePermissionEntry].self, from: result)
    }

    /// Grant a user permission to access a database.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.grantPermission`.
    @available(*, deprecated, message: "Use databases.addManager(databaseId:params:) instead.")
    public func grantPermission(databaseId: String, params: GrantPermissionParams) async throws -> DatabasePermissionEntry {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PUT", "/databases/\(databaseId)/permissions", body)
        return try JSONCoding.decode(DatabasePermissionEntry.self, from: result)
    }

    /// Revoke a user's permission to a database.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.revokePermission`.
    @available(*, deprecated, message: "Use databases.removeManager(databaseId:userId:) instead.")
    @discardableResult
    public func revokePermission(databaseId: String, userId: String) async throws -> DatabaseSuccessResult {
        let escapedId = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)/permissions/\(escapedId)", nil)
        return try JSONCoding.decode(DatabaseSuccessResult.self, from: result)
    }

    /// Transfer database ownership to another user.
    public func transferOwnership(databaseId: String, newOwnerId: String) async throws -> DatabaseOwnershipTransferResult {
        let body: [String: Any] = ["newOwnerId": newOwnerId]
        let result = try await makeRequest("POST", "/databases/\(databaseId)/permissions/transfer", body)
        return try JSONCoding.decode(DatabaseOwnershipTransferResult.self, from: result)
    }

    // MARK: - Operations

    /// Create a new operation (query or mutation) on a database.
    public func createOperation(databaseId: String, params: CreateOperationParams) async throws -> DatabaseOperationInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/databases/\(databaseId)/operations", body)
        return try JSONCoding.decode(DatabaseOperationInfo.self, from: result)
    }

    /// List all operations registered on a database.
    public func listOperations(databaseId: String) async throws -> [DatabaseOperationInfo] {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/operations", nil)
        return try JSONCoding.decode([DatabaseOperationInfo].self, from: result)
    }

    /// Get a single operation by name.
    public func getOperation(databaseId: String, name: String) async throws -> DatabaseOperationInfo {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let result = try await makeRequest("GET", "/databases/\(databaseId)/operations/\(encodedName)", nil)
        return try JSONCoding.decode(DatabaseOperationInfo.self, from: result)
    }

    /// Update an existing operation's definition or access level.
    public func updateOperation(databaseId: String, name: String, params: UpdateOperationParams) async throws -> DatabaseOperationInfo {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)/operations/\(encodedName)", body)
        return try JSONCoding.decode(DatabaseOperationInfo.self, from: result)
    }

    /// Delete an operation from a database.
    @discardableResult
    public func deleteOperation(databaseId: String, name: String) async throws -> DatabaseSuccessResult {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)/operations/\(encodedName)", nil)
        return try JSONCoding.decode(DatabaseSuccessResult.self, from: result)
    }

    /// Execute a registered operation by name, with optional parameters and
    /// pagination. The result shape depends on the operation (query rows,
    /// mutation acknowledgement, count, aggregate), so it is returned as an
    /// opaque `JSONValue` — JS returns `any` here.
    public func executeOperation(databaseId: String, name: String, options: ExecuteOperationOptions? = nil) async throws -> JSONValue {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let body: Any = try options.map { try JSONCoding.jsonObject(from: $0) } ?? [String: Any]()
        let result = try await makeRequest("POST", "/databases/\(databaseId)/operations/\(encodedName)/execute", body)
        return try JSONCoding.decode(JSONValue.self, from: result)
    }

    // MARK: - Bulk Import

    /// Import a batch of records using a named mutation operation.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.importBulk`.
    @available(*, deprecated, message: "Use databases.executeBatch(databaseId:operationName:batch:) instead.")
    public func importBulk(databaseId: String, operationName: String, batch: [DatabaseBatchOperation]) async throws -> DatabaseBatchResult {
        let encodedName = operationName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? operationName
        let body: Any = ["batch": try JSONCoding.jsonObject(from: batch)]
        let result = try await makeRequest("POST", "/databases/\(databaseId)/operations/\(encodedName)/import-bulk", body)
        return try JSONCoding.decode(DatabaseBatchResult.self, from: result)
    }

    // MARK: - Schema

    /// Get the field schema for a model in a database.
    public func describe(databaseId: String, modelName: String) async throws -> [ModelFieldInfo] {
        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelName
        let result = try await makeRequest("GET", "/databases/\(databaseId)/records/describe?modelName=\(encodedModel)", nil)
        // The server may wrap the field list in a `{ fields }` envelope.
        if let dict = result as? [String: Any], let fields = dict["fields"] {
            return try JSONCoding.decode([ModelFieldInfo].self, from: fields)
        }
        return try JSONCoding.decode([ModelFieldInfo].self, from: result)
    }

    // MARK: - CEL Context

    /// Read a database's CEL context dict. Values are referenced from
    /// CEL access rules as `database.celContext.<key>` and from filter
    /// JSON as `$database.celContext.<key>`.
    ///
    /// Response payload includes the same dict under both `metadata`
    /// (legacy wire name) and `celContext` (current name).
    public func getCelContext(databaseId: String) async throws -> CelContextResult {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/metadata", nil)
        return try JSONCoding.decode(CelContextResult.self, from: result)
    }

    /// Merge new key-value pairs into a database's CEL context dict.
    public func updateCelContext(
        databaseId: String,
        celContext: [String: JSONValue]
    ) async throws -> DatabaseInfo {
        let body = try JSONCoding.jsonObject(from: celContext)
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)/metadata", body)
        return try JSONCoding.decode(DatabaseInfo.self, from: result)
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
        let body: [String: Any] = ["userId": params.userId, "permission": "manager"]
        let result = try await makeRequest("PUT", "/databases/\(databaseId)/permissions", body)
        return try JSONCoding.decode(DatabasePermissionEntry.self, from: result)
    }

    /// Remove a manager from a database.
    @discardableResult
    public func removeManager(
        databaseId: String,
        userId: String
    ) async throws -> DatabaseSuccessResult {
        let escapedId = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)/permissions/\(escapedId)", nil)
        return try JSONCoding.decode(DatabaseSuccessResult.self, from: result)
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
        let result = try await makeRequest("GET", "/databases/\(databaseId)/group-permissions\(qs)", nil)
        return try JSONCoding.decode([DatabaseGroupPermissionEntry].self, from: result)
    }

    /// Grant a group permission on a database. Members of the specified
    /// group gain the permission level on the database.
    public func grantGroupPermission(
        databaseId: String,
        params: GrantDatabaseGroupPermissionParams
    ) async throws -> DatabaseGroupPermissionEntry {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/databases/\(databaseId)/group-permissions", body)
        return try JSONCoding.decode(DatabaseGroupPermissionEntry.self, from: result)
    }

    /// Revoke a group's permission on a database.
    @discardableResult
    public func revokeGroupPermission(
        databaseId: String,
        groupType: String,
        groupId: String
    ) async throws -> DatabaseSuccessResult {
        let gType = groupType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupType
        let gId = groupId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupId
        let result = try await makeRequest(
            "DELETE",
            "/databases/\(databaseId)/group-permissions/\(gType)/\(gId)",
            nil
        )
        return try JSONCoding.decode(DatabaseSuccessResult.self, from: result)
    }

    // MARK: - Batch operations

    /// Execute a batch of records via a named mutation operation.
    /// Each element is one invocation passed to the operation.
    public func executeBatch(
        databaseId: String,
        operationName: String,
        batch: [DatabaseBatchOperation]
    ) async throws -> DatabaseBatchResult {
        let encodedName = operationName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? operationName
        let body: Any = ["batch": try JSONCoding.jsonObject(from: batch)]
        let result = try await makeRequest(
            "POST",
            "/databases/\(databaseId)/operations/\(encodedName)/batch",
            body
        )
        return try JSONCoding.decode(DatabaseBatchResult.self, from: result)
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
    /// Pipeline (matches JS): resolve `modelName` → parse `csv` (quoted-field
    /// aware) or copy `data` → apply `columnMap` → coerce values per `types` →
    /// assign `id` (`idColumn` → `idGenerator` → ULID) → run `transform`
    /// (skip on `nil`) → write in batches of `batchSize` (default 5000) via the
    /// named save operation as `{ modelName, id, data }`.
    ///
    /// - Note: the JS `model:` BaseModel-class path (schema-driven field
    ///   filtering + post-import `syncIndexes`) is not ported; `modelName` is
    ///   required and `indexesCreated` is always `0`.
    public func importCsv(databaseId: String, options: CsvImportOptions) async throws -> CsvImportResult {
        let start = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // 1. Resolve model name.
        guard let modelName = options.modelName, !modelName.isEmpty else {
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

        // 4 & 6. Coerce values, assign IDs, apply transform.
        //   (Step 4/5 in JS — schema-based field filtering and the schema type
        //   map — require a BaseModel class, which the Swift surface doesn't
        //   take; only the explicit `types` overrides are applied here.)
        let typeMap = options.types ?? [:]
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
               let raw = rawRow[idColumn], !raw.isEmpty {
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

        // 9. Index sync is JS BaseModel-class only; always 0 here.
        return CsvImportResult(
            imported: imported,
            failed: failed,
            errors: errors,
            indexesCreated: 0,
            durationMs: elapsedMs()
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
