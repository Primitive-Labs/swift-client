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
/// Every method routes through the same `Transport` `DatabasesAPI` uses,
/// hitting `/databases/{databaseId}/records{enginePath}?docId={databaseId}`
/// — the exact route the JS engine constructs (`endpoint` =
/// `.../databases/{id}/records`, plus the per-method path and the `docId`
/// query param). The transport already injects the `Authorization` bearer
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

    private let transport: any Transport

    /// - Parameters:
    ///   - databaseId: the database this handle is bound to.
    ///   - transport: the same transport `DatabasesAPI` holds.
    init(databaseId: String, transport: any Transport) {
        self.databaseId = databaseId
        self.transport = transport
    }

    // MARK: - Path building

    /// Build the per-method path: `/databases/{id}/records{enginePath}?docId={id}`.
    /// `enginePath` is the engine sub-route (`/query`, `/save`, …). Extra
    /// query params (e.g. `modelName` for the GET routes) are appended.
    private func path(_ enginePath: String, extraQuery: [String: String] = [:]) -> String {
        let encodedDocId = URLEncoding.encodeComponent(databaseId)
        var query = URLQuery()
        query.append("docId", databaseId)
        for (key, value) in extraQuery {
            query.append(key, value)
        }
        return "/databases/\(encodedDocId)/records\(enginePath)\(query.queryString)"
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
        var body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "filter": try filter.map { try JSONValue(encoding: $0) } ?? .object([:]),
        ]
        if let options {
            body["options"] = try JSONValue(encoding: options)
        }
        return try await transport.request(method: .post, path: path("/query"), body: body)
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
        let body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "filter": try filter.map { try JSONValue(encoding: $0) } ?? .object([:]),
        ]
        let response: CountResponse = try await transport.request(
            method: .post, path: path("/count"), body: body
        )
        return try Self.intValue(response.count, field: "count")
    }

    /// Aggregate records (groupBy + count/sum/avg/min/max). Mirrors js-bao's
    /// `db.aggregate(model, options)` → `POST /aggregate` with
    /// `{ modelName, options }`. The result is an opaque nested object (or
    /// array of objects) keyed by group values, returned as `JSONValue`.
    public func aggregate(modelName: String, options: DoDbAggregationOptions) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "options": try JSONValue(encoding: options),
        ]
        let response: JSONValue = try await transport.request(
            method: .post, path: path("/aggregate"), body: body
        )
        // The engine wraps the aggregation in `{ result }`; plain shapes
        // return it bare.
        return response["result"] ?? response
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
        var body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "data": .object(data),
        ]
        if let id { body["id"] = .string(id) }
        if let stringSets = options?.stringSets { body["stringSets"] = try JSONValue(encoding: stringSets) }
        if let ifNotExists = options?.ifNotExists { body["ifNotExists"] = .bool(ifNotExists) }
        if let condition = options?.condition { body["condition"] = try JSONValue(encoding: condition) }
        if let upsertOn = options?.upsertOn { body["upsertOn"] = try JSONValue(encoding: upsertOn) }
        let response: IdResponse = try await transport.request(
            method: .post, path: path("/save"), body: body
        )
        return try Self.required(response.id, field: "id")
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
        var body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "id": .string(id),
            "data": .object(data),
        ]
        if let stringSets = options?.stringSets { body["stringSets"] = try JSONValue(encoding: stringSets) }
        if let condition = options?.condition { body["condition"] = try JSONValue(encoding: condition) }
        let response: IdResponse = try await transport.request(
            method: .post, path: path("/patch"), body: body
        )
        return try Self.required(response.id, field: "id")
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
        var body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "id": .string(id),
        ]
        if let condition = options?.condition { body["condition"] = try JSONValue(encoding: condition) }
        let response: SuccessFlagResponse = try await transport.request(
            method: .post, path: path("/delete"), body: body
        )
        return try Self.required(response.success, field: "success")
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
        var body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "id": .string(id),
            "fields": try JSONValue(encoding: fields),
        ]
        if let condition = options?.condition { body["condition"] = try JSONValue(encoding: condition) }
        // Decode-or-throw, matching the sibling write methods: a missing
        // `values` envelope is a server-contract violation, not an empty
        // success.
        let response: IncrementResponse = try await transport.request(
            method: .post, path: path("/increment"), body: body
        )
        return try Self.required(response.values, field: "values")
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
        var body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "id": .string(id),
            "sets": try JSONValue(encoding: sets),
        ]
        if let condition = options?.condition { body["condition"] = try JSONValue(encoding: condition) }
        try await transport.send(method: .post, path: path(enginePath), body: body)
    }

    // MARK: - Batch

    /// Execute multiple save/patch/delete/increment/addToSet/removeFromSet
    /// operations in a single server-side transaction. Mirrors js-bao's
    /// `db.batch(operations)` → `POST /batch` with `{ operations }`. Returns
    /// one result per operation in order.
    @discardableResult
    public func batch(_ operations: [DoDbBatchOperation]) async throws -> [DoDbBatchOperationResult] {
        let body: [String: JSONValue] = [
            "operations": try JSONValue(encoding: operations),
        ]
        let response: BatchResponse = try await transport.request(
            method: .post, path: path("/batch"), body: body
        )
        return response.results
    }

    // MARK: - Schema introspection

    /// Describe the tracked fields for a model. Mirrors js-bao's
    /// `db.describe(modelName)` → `GET /describe?modelName=…`, unwrapping the
    /// `{ fields }` envelope.
    public func describe(modelName: String) async throws -> [ModelFieldInfo] {
        let response: ModelFieldsEnvelope = try await transport.request(
            method: .get,
            path: path("/describe", extraQuery: ["modelName": modelName])
        )
        return response.fields
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
        let body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "fieldName": .string(fieldName),
            "fieldType": .string(fieldType),
            "unique": .bool(unique),
        ]
        try await transport.send(method: .post, path: path("/index/register"), body: body)
    }

    /// Drop a single-field index. Mirrors js-bao's
    /// `db.dropIndex(modelName, fieldName)` → `POST /index/drop` with
    /// `{ modelName, fieldName }`.
    public func dropIndex(modelName: String, fieldName: String) async throws {
        let body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "fieldName": .string(fieldName),
        ]
        try await transport.send(method: .post, path: path("/index/drop"), body: body)
    }

    /// List indexes, optionally filtered to one model. Mirrors js-bao's
    /// `db.listIndexes(modelName?)` → `GET /indexes[?modelName=…]`, unwrapping
    /// the `{ indexes }` envelope.
    public func listIndexes(modelName: String? = nil) async throws -> [DoDbIndexEntry] {
        let extra = modelName.map { ["modelName": $0] } ?? [:]
        let response: IndexListResponse = try await transport.request(
            method: .get, path: path("/indexes", extraQuery: extra)
        )
        return response.indexes
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
        let body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "constraintName": .string(constraintName),
            "fields": .array(fields.map { .string($0) }),
        ]
        try await transport.send(method: .post, path: path("/unique-constraint/register"), body: body)
    }

    /// Drop a composite unique constraint. Mirrors js-bao's
    /// `db.dropUniqueConstraint(modelName, constraintName)` →
    /// `POST /unique-constraint/drop` with `{ modelName, constraintName }`.
    public func dropUniqueConstraint(modelName: String, constraintName: String) async throws {
        let body: [String: JSONValue] = [
            "modelName": .string(modelName),
            "constraintName": .string(constraintName),
        ]
        try await transport.send(method: .post, path: path("/unique-constraint/drop"), body: body)
    }

    /// List composite unique constraints, optionally filtered to one model.
    /// Mirrors js-bao's `db.listUniqueConstraints(modelName?)` →
    /// `GET /unique-constraints[?modelName=…]`, unwrapping the
    /// `{ constraints }` envelope.
    public func listUniqueConstraints(modelName: String? = nil) async throws -> [DoDbUniqueConstraintEntry] {
        let extra = modelName.map { ["modelName": $0] } ?? [:]
        let response: UniqueConstraintListResponse = try await transport.request(
            method: .get, path: path("/unique-constraints", extraQuery: extra)
        )
        return response.constraints
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
        let body: [String: JSONValue] = ["models": try JSONValue(encoding: models)]
        let response: RegisteredCountResponse = try await transport.request(
            method: .post, path: path("/indexes/sync"), body: body
        )
        return try Self.intValue(response.registered, field: "registered")
    }

    // MARK: - Response field helpers

    /// A field the engine's response contract requires. Absent means the
    /// server broke the contract, which stays a `DoDbError` rather than a
    /// decode failure so callers keep the error they always handled.
    private static func required<T>(_ value: T?, field: String) throws -> T {
        guard let value = value else { throw DoDbError.unexpectedResponse(field: field) }
        return value
    }

    /// Counts arrive as JSON numbers; accept any numeric spelling (including
    /// `3.0`) exactly as the previous `NSNumber`-tolerant reader did.
    ///
    /// `Int(_: Double)` is a **trapping** conversion — it aborts the process
    /// on NaN, ±infinity, or any magnitude past `Int.max`. A response parser
    /// must never crash on hostile or broken server input (#2056), so the
    /// conversion is range-checked and a value that cannot be represented is
    /// reported as the contract violation it is.
    ///
    /// Internal rather than private so the out-of-range handling is unit
    /// testable (#2056).
    static func intValue(_ value: Double?, field: String) throws -> Int {
        let raw = try required(value, field: field)
        guard raw.isFinite, let converted = Int(exactly: raw.rounded(.towardZero)) else {
            throw DoDbError.unexpectedResponse(field: field)
        }
        return converted
    }
}

// MARK: - Engine response envelopes
//
// The DO engine's responses. Fields the callers require are optional here so
// a missing one surfaces as `DoDbError.unexpectedResponse(field:)` — the
// error these methods have always thrown — rather than a decode failure.

private struct IdResponse: Decodable, Sendable {
    let id: String?
}

private struct SuccessFlagResponse: Decodable, Sendable {
    let success: Bool?
}

private struct CountResponse: Decodable, Sendable {
    let count: Double?
}

private struct RegisteredCountResponse: Decodable, Sendable {
    let registered: Double?
}

private struct IncrementResponse: Decodable, Sendable {
    let values: [String: Double]?
}

/// `{ results }` or a bare array — both documented engine shapes.
private struct BatchResponse: Decodable, Sendable {
    let results: [DoDbBatchOperationResult]

    init(from decoder: Decoder) throws {
        if let array = try? [DoDbBatchOperationResult](from: decoder) {
            results = array
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        results = try c.decode([DoDbBatchOperationResult].self, forKey: .results)
    }

    private enum Key: String, CodingKey { case results }
}


/// `{ indexes }` or a bare array.
private struct IndexListResponse: Decodable, Sendable {
    let indexes: [DoDbIndexEntry]

    init(from decoder: Decoder) throws {
        if let array = try? [DoDbIndexEntry](from: decoder) {
            indexes = array
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        indexes = try c.decode([DoDbIndexEntry].self, forKey: .indexes)
    }

    private enum Key: String, CodingKey { case indexes }
}

/// `{ constraints }` or a bare array.
private struct UniqueConstraintListResponse: Decodable, Sendable {
    let constraints: [DoDbUniqueConstraintEntry]

    init(from decoder: Decoder) throws {
        if let array = try? [DoDbUniqueConstraintEntry](from: decoder) {
            constraints = array
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        constraints = try c.decode([DoDbUniqueConstraintEntry].self, forKey: .constraints)
    }

    private enum Key: String, CodingKey { case constraints }
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
