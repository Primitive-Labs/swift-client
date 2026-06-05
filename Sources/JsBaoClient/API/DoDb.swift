import Foundation

// MARK: - DoDb

/// Direct-record handle to a single database, returned by
/// `client.databases.connect(databaseId:)`. Mirrors js-bao's `DoDb`
/// (`connectDoDb` in `packages/js-bao/src/initialize-do.ts`, backed by the
/// `DOClientEngine` HTTP routes).
///
/// This is the owner/manager direct record-access path: schemaless
/// save/patch/find/query/delete/count, atomic increment & StringSet ops,
/// transactional batch writes, aggregation, and index management — all
/// scoped to one database.
///
/// Every method routes through the same `makeRequest` closure `DatabasesAPI`
/// uses, hitting `/databases/{databaseId}/records{enginePath}?docId={databaseId}`
/// — the exact route the JS engine constructs (`endpoint` =
/// `.../databases/{id}/records`, plus the per-method path and the `docId`
/// query param). `makeRequest` already injects the `Authorization` bearer
/// token and the `X-JB-Connection-Id` header, so writes are attributed to
/// this client's connection just as the JS `connect()` arranges by hand.
///
/// Mutating/read endpoints are `POST` with a JSON body (the engine's
/// `doFetch`); the three list/introspection endpoints (`listIndexes`,
/// `listUniqueConstraints`, `describe`) are `GET` with query params.
///
/// Unlike the JS handle, the Swift surface takes an explicit `modelName`
/// string for every call (the JS `ModelIdentifier` accepts a `BaseModel`
/// class or a string; only the string form has a wire representation). The
/// pre-bound `db.User.*` accessors and the `models`-array-driven
/// `syncAllIndexes()` / `describe`-via-class conveniences likewise depend on
/// registered model classes, which the Swift client does not model — see the
/// per-method notes below.
public final class DoDb: @unchecked Sendable {
    /// The connected database ID. Mirrors js-bao's `DoDb.docId`.
    public let databaseId: String

    private let makeRequest: (String, String, Any?) async throws -> Any

    /// - Parameters:
    ///   - databaseId: the database this handle is bound to.
    ///   - makeRequest: the same request closure `DatabasesAPI` holds.
    init(databaseId: String, makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.databaseId = databaseId
        self.makeRequest = makeRequest
    }

    // MARK: - Path building

    /// Build the per-method path: `/databases/{id}/records{enginePath}?docId={id}`.
    /// `enginePath` is the engine sub-route (`/query`, `/save`, …). Extra
    /// query params (e.g. `modelName` for the GET routes) are appended.
    private func path(_ enginePath: String, extraQuery: [String: String] = [:]) -> String {
        let encodedDocId = databaseId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? databaseId
        var query = "docId=\(encodedDocId)"
        for (key, value) in extraQuery {
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            query += "&\(k)=\(v)"
        }
        return "/databases/\(encodedDocId)/records\(enginePath)?\(query)"
    }

    // MARK: - Read

    /// Query records matching `filter`. Mirrors js-bao's `db.query(model, filter, options)`
    /// → `POST /query` with `{ modelName, filter, options }`.
    ///
    /// Supports the full filter operator grammar (`$eq`/`$ne`/`$gt`/…/`$in`/
    /// `$contains`/`$startsWith`/`$and`/`$or`/…) plus sort, limit, cursor
    /// pagination (`uniqueStartKey` + `direction`), projection, document
    /// scoping, and `include` relationship loading.
    public func query(
        modelName: String,
        filter: DoDbFilter? = nil,
        options: DoDbQueryOptions? = nil
    ) async throws -> DoDbQueryResult {
        var body: [String: Any] = [
            "modelName": modelName,
            "filter": try filter.map { try JSONCoding.jsonObject(from: $0) } ?? [String: Any](),
        ]
        if let options {
            body["options"] = try JSONCoding.jsonObject(from: options)
        }
        let result = try await makeRequest("POST", path("/query"), body)
        return try JSONCoding.decode(DoDbQueryResult.self, from: result)
    }

    /// Find a single record by ID. Mirrors js-bao's `db.find(model, id)` —
    /// implemented as a `query` for `{ id }` returning the first match (or
    /// `nil`). Returns the raw record as a `JSONValue` object.
    public func find(modelName: String, id: String) async throws -> JSONValue? {
        let result = try await query(modelName: modelName, filter: .object(["id": .string(id)]))
        return result.data.first
    }

    /// Count records matching `filter`. Mirrors js-bao's `db.count(model, filter)`
    /// → `POST /count` with `{ modelName, filter }`.
    public func count(modelName: String, filter: DoDbFilter? = nil) async throws -> Int {
        let body: [String: Any] = [
            "modelName": modelName,
            "filter": try filter.map { try JSONCoding.jsonObject(from: $0) } ?? [String: Any](),
        ]
        let result = try await makeRequest("POST", path("/count"), body)
        return try Self.intField(result, "count")
    }

    /// Aggregate records (groupBy + count/sum/avg/min/max). Mirrors js-bao's
    /// `db.aggregate(model, options)` → `POST /aggregate` with
    /// `{ modelName, options }`. The result is an opaque nested object (or
    /// array of objects) keyed by group values, returned as `JSONValue`.
    public func aggregate(modelName: String, options: DoDbAggregationOptions) async throws -> JSONValue {
        let body: [String: Any] = [
            "modelName": modelName,
            "options": try JSONCoding.jsonObject(from: options),
        ]
        let result = try await makeRequest("POST", path("/aggregate"), body)
        if let dict = result as? [String: Any], let inner = dict["result"] {
            return try JSONCoding.decode(JSONValue.self, from: inner)
        }
        return try JSONCoding.decode(JSONValue.self, from: result)
    }

    // MARK: - Write

    /// Save (insert or replace) a record. Mirrors js-bao's
    /// `db.save(model, data, options)` → `POST /save` with
    /// `{ modelName, id, data, stringSets, ifNotExists, condition, upsertOn }`.
    /// Returns the saved record's ID.
    ///
    /// `data` must carry an `"id"` field unless `options.upsertOn` is set —
    /// this matches the JS guard (`Record must have an 'id' field (or use
    /// upsertOn)`), enforced here as a thrown `DoDbError.missingId`.
    @discardableResult
    public func save(
        modelName: String,
        data: [String: JSONValue],
        options: DoDbSaveOptions? = nil
    ) async throws -> String {
        let id = data["id"]?.stringValue
        if id == nil, options?.upsertOn == nil {
            throw DoDbError.missingId
        }
        var body: [String: Any] = [
            "modelName": modelName,
            "data": try JSONCoding.jsonObject(from: data),
        ]
        if let id { body["id"] = id }
        if let stringSets = options?.stringSets { body["stringSets"] = stringSets }
        if let ifNotExists = options?.ifNotExists { body["ifNotExists"] = ifNotExists }
        if let condition = options?.condition { body["condition"] = try JSONCoding.jsonObject(from: condition) }
        if let upsertOn = options?.upsertOn { body["upsertOn"] = upsertOn }
        let result = try await makeRequest("POST", path("/save"), body)
        return try Self.stringField(result, "id")
    }

    /// Patch (partial update) a record — only the provided fields change.
    /// Mirrors js-bao's `db.patch(model, id, data, options)` → `POST /patch`
    /// with `{ modelName, id, data, stringSets, condition }`. Returns the ID.
    @discardableResult
    public func patch(
        modelName: String,
        id: String,
        data: [String: JSONValue],
        options: DoDbPatchOptions? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "modelName": modelName,
            "id": id,
            "data": try JSONCoding.jsonObject(from: data),
        ]
        if let stringSets = options?.stringSets { body["stringSets"] = stringSets }
        if let condition = options?.condition { body["condition"] = try JSONCoding.jsonObject(from: condition) }
        let result = try await makeRequest("POST", path("/patch"), body)
        return try Self.stringField(result, "id")
    }

    /// Delete a record by ID. Mirrors js-bao's `db.delete(model, id, options)`
    /// → `POST /delete` with `{ modelName, id, condition }`. Returns whether a
    /// record was deleted.
    @discardableResult
    public func delete(
        modelName: String,
        id: String,
        options: DoDbWriteCondition? = nil
    ) async throws -> Bool {
        var body: [String: Any] = [
            "modelName": modelName,
            "id": id,
        ]
        if let condition = options?.condition { body["condition"] = try JSONCoding.jsonObject(from: condition) }
        let result = try await makeRequest("POST", path("/delete"), body)
        return try Self.boolField(result, "success")
    }

    // MARK: - Atomic ops

    /// Atomically increment/decrement numeric fields on a record. Mirrors
    /// js-bao's `db.increment(model, id, fields, options)` → `POST /increment`
    /// with `{ modelName, id, fields, condition }`. Returns the post-increment
    /// values.
    @discardableResult
    public func increment(
        modelName: String,
        id: String,
        fields: [String: Double],
        options: DoDbWriteCondition? = nil
    ) async throws -> [String: Double] {
        var body: [String: Any] = [
            "modelName": modelName,
            "id": id,
            "fields": fields,
        ]
        if let condition = options?.condition { body["condition"] = try JSONCoding.jsonObject(from: condition) }
        let result = try await makeRequest("POST", path("/increment"), body)
        // Decode-or-throw, matching the sibling write methods
        // (`stringField`/`boolField`/`intField`): a missing `values` envelope
        // is a server-contract violation, not an empty success.
        guard let dict = result as? [String: Any], let values = dict["values"] else {
            throw DoDbError.unexpectedResponse(field: "values")
        }
        return try JSONCoding.decode([String: Double].self, from: values)
    }

    /// Atomically add values to StringSet fields on a record. Mirrors js-bao's
    /// `db.addToSet(model, id, sets, options)` → `POST /stringset/add` with
    /// `{ modelName, id, sets, condition }`. StringSet membership is a set
    /// (duplicates collapse).
    public func addToSet(
        modelName: String,
        id: String,
        sets: [String: [String]],
        options: DoDbWriteCondition? = nil
    ) async throws {
        try await stringSetUpdate("/stringset/add", modelName: modelName, id: id, sets: sets, options: options)
    }

    /// Atomically remove values from StringSet fields on a record. Mirrors
    /// js-bao's `db.removeFromSet(model, id, sets, options)` →
    /// `POST /stringset/remove` with `{ modelName, id, sets, condition }`.
    public func removeFromSet(
        modelName: String,
        id: String,
        sets: [String: [String]],
        options: DoDbWriteCondition? = nil
    ) async throws {
        try await stringSetUpdate("/stringset/remove", modelName: modelName, id: id, sets: sets, options: options)
    }

    private func stringSetUpdate(
        _ enginePath: String,
        modelName: String,
        id: String,
        sets: [String: [String]],
        options: DoDbWriteCondition?
    ) async throws {
        var body: [String: Any] = [
            "modelName": modelName,
            "id": id,
            "sets": sets,
        ]
        if let condition = options?.condition { body["condition"] = try JSONCoding.jsonObject(from: condition) }
        _ = try await makeRequest("POST", path(enginePath), body)
    }

    // MARK: - Batch

    /// Execute multiple save/patch/delete/increment/addToSet/removeFromSet
    /// operations in a single server-side transaction. Mirrors js-bao's
    /// `db.batch(operations)` → `POST /batch` with `{ operations }`. Returns
    /// one result per operation in order.
    @discardableResult
    public func batch(_ operations: [DoDbBatchOperation]) async throws -> [DoDbBatchOperationResult] {
        let body: [String: Any] = [
            "operations": try JSONCoding.jsonObject(from: operations),
        ]
        let result = try await makeRequest("POST", path("/batch"), body)
        if let dict = result as? [String: Any], let results = dict["results"] {
            return try JSONCoding.decode([DoDbBatchOperationResult].self, from: results)
        }
        return try JSONCoding.decode([DoDbBatchOperationResult].self, from: result)
    }

    // MARK: - Schema introspection

    /// Describe the tracked fields for a model. Mirrors js-bao's
    /// `db.describe(modelName)` → `GET /describe?modelName=…`, unwrapping the
    /// `{ fields }` envelope.
    public func describe(modelName: String) async throws -> [ModelFieldInfo] {
        let result = try await makeRequest("GET", path("/describe", extraQuery: ["modelName": modelName]), nil)
        if let dict = result as? [String: Any], let fields = dict["fields"] {
            return try JSONCoding.decode([ModelFieldInfo].self, from: fields)
        }
        return try JSONCoding.decode([ModelFieldInfo].self, from: result)
    }

    // MARK: - Index management

    /// Register a single-field index. Mirrors js-bao's
    /// `db.registerIndex(modelName, fieldName, fieldType?, unique?)` →
    /// `POST /index/register` with `{ modelName, fieldName, fieldType, unique }`.
    /// `fieldType` defaults to `"string"`, `unique` to `false` (matches JS).
    public func registerIndex(
        modelName: String,
        fieldName: String,
        fieldType: String = "string",
        unique: Bool = false
    ) async throws {
        let body: [String: Any] = [
            "modelName": modelName,
            "fieldName": fieldName,
            "fieldType": fieldType,
            "unique": unique,
        ]
        _ = try await makeRequest("POST", path("/index/register"), body)
    }

    /// Drop a single-field index. Mirrors js-bao's
    /// `db.dropIndex(modelName, fieldName)` → `POST /index/drop` with
    /// `{ modelName, fieldName }`.
    public func dropIndex(modelName: String, fieldName: String) async throws {
        let body: [String: Any] = ["modelName": modelName, "fieldName": fieldName]
        _ = try await makeRequest("POST", path("/index/drop"), body)
    }

    /// List indexes, optionally filtered to one model. Mirrors js-bao's
    /// `db.listIndexes(modelName?)` → `GET /indexes[?modelName=…]`, unwrapping
    /// the `{ indexes }` envelope.
    public func listIndexes(modelName: String? = nil) async throws -> [DoDbIndexEntry] {
        let extra = modelName.map { ["modelName": $0] } ?? [:]
        let result = try await makeRequest("GET", path("/indexes", extraQuery: extra), nil)
        if let dict = result as? [String: Any], let indexes = dict["indexes"] {
            return try JSONCoding.decode([DoDbIndexEntry].self, from: indexes)
        }
        return try JSONCoding.decode([DoDbIndexEntry].self, from: result)
    }

    /// Register a composite unique constraint across multiple fields. Mirrors
    /// js-bao's `db.registerUniqueConstraint(modelName, constraintName, fields)`
    /// → `POST /unique-constraint/register` with
    /// `{ modelName, constraintName, fields }`.
    public func registerUniqueConstraint(
        modelName: String,
        constraintName: String,
        fields: [String]
    ) async throws {
        let body: [String: Any] = [
            "modelName": modelName,
            "constraintName": constraintName,
            "fields": fields,
        ]
        _ = try await makeRequest("POST", path("/unique-constraint/register"), body)
    }

    /// Drop a composite unique constraint. Mirrors js-bao's
    /// `db.dropUniqueConstraint(modelName, constraintName)` →
    /// `POST /unique-constraint/drop` with `{ modelName, constraintName }`.
    public func dropUniqueConstraint(modelName: String, constraintName: String) async throws {
        let body: [String: Any] = ["modelName": modelName, "constraintName": constraintName]
        _ = try await makeRequest("POST", path("/unique-constraint/drop"), body)
    }

    /// List composite unique constraints, optionally filtered to one model.
    /// Mirrors js-bao's `db.listUniqueConstraints(modelName?)` →
    /// `GET /unique-constraints[?modelName=…]`, unwrapping the
    /// `{ constraints }` envelope.
    public func listUniqueConstraints(modelName: String? = nil) async throws -> [DoDbUniqueConstraintEntry] {
        let extra = modelName.map { ["modelName": $0] } ?? [:]
        let result = try await makeRequest("GET", path("/unique-constraints", extraQuery: extra), nil)
        if let dict = result as? [String: Any], let constraints = dict["constraints"] {
            return try JSONCoding.decode([DoDbUniqueConstraintEntry].self, from: constraints)
        }
        return try JSONCoding.decode([DoDbUniqueConstraintEntry].self, from: result)
    }

    /// Batch-sync the desired index state for one or more models. The server
    /// diffs against the existing `_indexes` table and registers only what's
    /// missing; returns the number of indexes/constraints newly registered.
    /// Mirrors js-bao's `syncIndexesBatch` → `POST /indexes/sync` with
    /// `{ models }`.
    ///
    /// This is the wire-level counterpart of both JS `db.syncIndexes(model)`
    /// (one model) and `db.syncAllIndexes()` (every registered model). Those
    /// JS variants derive the desired `DoDbModelSyncState` from a `BaseModel`
    /// schema; the Swift client has no model-class registry, so callers pass
    /// the desired state explicitly here.
    @discardableResult
    public func syncIndexes(models: [DoDbModelSyncState]) async throws -> Int {
        let body: [String: Any] = ["models": try JSONCoding.jsonObject(from: models)]
        let result = try await makeRequest("POST", path("/indexes/sync"), body)
        return try Self.intField(result, "registered")
    }

    // MARK: - Response field helpers

    private static func stringField(_ result: Any, _ key: String) throws -> String {
        guard let dict = result as? [String: Any], let value = dict[key] as? String else {
            throw DoDbError.unexpectedResponse(field: key)
        }
        return value
    }

    private static func boolField(_ result: Any, _ key: String) throws -> Bool {
        guard let dict = result as? [String: Any], let value = dict[key] as? Bool else {
            throw DoDbError.unexpectedResponse(field: key)
        }
        return value
    }

    private static func intField(_ result: Any, _ key: String) throws -> Int {
        guard let dict = result as? [String: Any] else {
            throw DoDbError.unexpectedResponse(field: key)
        }
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? Double { return Int(n) }
        if let n = dict[key] as? NSNumber { return n.intValue }
        throw DoDbError.unexpectedResponse(field: key)
    }
}

// MARK: - DoDbError

/// Errors raised by the `DoDb` handle before / around a request.
public enum DoDbError: Error, LocalizedError, Equatable {
    /// `save` was called without an `"id"` field in `data` and without
    /// `upsertOn`. Mirrors js-bao's `Record must have an 'id' field` guard.
    case missingId
    /// The server response was missing an expected field.
    case unexpectedResponse(field: String)

    public var errorDescription: String? {
        switch self {
        case .missingId:
            return "Record must have an 'id' field (or use upsertOn)"
        case let .unexpectedResponse(field):
            return "DoDb response missing expected field '\(field)'"
        }
    }
}
