import Foundation
import YSwift
import Yniffi

private enum BaoModelDebug {
    static var hasLogged = false
}

// MARK: - Protocol

/// A type that can be stored as a record in a Y.Map-backed model.
/// Each record is a nested Y.Map within a top-level Y.Map named after the model.
public protocol BaoModelRecord: Identifiable where ID == String {
    /// The model name (e.g., "pages", "blocks"). Maps to yDoc.getMap(name).
    static var modelName: String { get }

    /// Field definitions for reading/writing to Y.Maps.
    static var fields: [FieldDefinition] { get }

    /// Create an instance from a dictionary of field values.
    init(fields: [String: Any])

    /// Convert this instance to a dictionary of field values.
    func toFields() -> [String: Any]
}

// MARK: - Field Definition

public struct FieldDefinition {
    public let name: String
    public let type: FieldType
    public let optional: Bool

    public init(_ name: String, _ type: FieldType, optional: Bool = false) {
        self.init(name: name, type: type, optional: optional)
    }

    public init(name: String, type: FieldType, optional: Bool = false) {
        self.name = name
        self.type = type
        self.optional = optional
    }
}

public enum FieldType {
    case string
    case number
    case boolean
    case json  // stored as JSON string, parsed as Any
}

// MARK: - BaoModel

/// Typed access to a Y.Map-backed model within a YDocument.
///
/// Mirrors the JS client's `BaseModel` from `js-bao` — a typed record store
/// layered on top of a single Y.Doc. Named `BaoModel` to avoid clashing with
/// Swift's standard library `Collection` protocol and with `CollectionsAPI`
/// (the Primitive platform feature for grouping documents, a different concept).
///
/// Structure: `yDoc.getMap("modelName")` contains nested Y.Maps keyed by record ID.
/// Each nested Y.Map holds the record's fields as JSON-encoded values.
///
/// Supports rich queries via a SQLite mirror:
/// ```swift
/// let tasks = model.query(["status": "done"], options: QueryOptions(sort: ["priority": -1]))
/// let count = model.count(["completed": true])
/// let stats = model.aggregate(AggregateOptions(
///     groupBy: ["status"],
///     operations: [.init(type: .count), .init(type: .avg, field: "priority")]
/// ))
/// ```
public final class BaoModel<T: BaoModelRecord> {
    private let doc: YDocument
    private let client: JsBaoClient?
    private let documentId: String?
    private lazy var queryEngine: BaoModelQueryEngine = {
        let engine = BaoModelQueryEngine()
        let fieldTuples = T.fields.map { (name: $0.name, type: $0.type) }
        engine.ensureTable(modelName: T.modelName, fields: fieldTuples)
        return engine
    }()

    /// Internal accessor for the underlying SQLite mirror — used by tests
    /// and by the schema layer's observer plumbing.
    internal var queryEngineInternal: BaoModelQueryEngine { queryEngine }

    /// True when the SQLite mirror may be out of sync with the Y.Doc.
    /// Initially true so the first query triggers a full sync.
    /// Set to true by an `observeUpdate` subscription on the doc whenever
    /// any transaction commits (local or remote). Cleared inside
    /// `syncToQueryEngine()` once the rebuild has been claimed.
    private var queryIndexDirty: Bool = true
    private let dirtyLock = NSLock()
    // Disambiguate from `Yniffi.YSubscription` — `doc.observeUpdate` returns
    // the YSwift wrapper, which auto-cancels on deinit.
    private var docUpdateSubscription: YSwift.YSubscription?

    /// Test-only counter incremented every time the SQLite mirror is rebuilt.
    /// Allows tests to verify that the dirty-flag short-circuit avoids
    /// unnecessary rebuilds.
    internal private(set) var syncCallCount: Int = 0

    /// The root Y.Map for this model. Created once on init via get-or-create.
    private let rootMap: YrsMap

    /// Create a model bound to a YDocument.
    /// Pass `client` and `documentId` to enable network sync on writes.
    public init(doc: YDocument, client: JsBaoClient? = nil, documentId: String? = nil) {
        self.doc = doc
        self.client = client
        self.documentId = documentId
        // Cache the root YrsMap once at init time. We use the doc-level
        // get-or-create here, which is safe BECAUSE we're not inside a
        // transaction. (Historically this was a strict requirement: yrs's
        // RwLock isn't reentrant and the doc-level getter re-acquires it,
        // so calling getMap() inside an open transact() would deadlock the
        // calling thread. The deadlock-safe alternative is now exposed as
        // `YDocument.getOrInsertMap(named:transaction:)`, which routes
        // through the held TransactionMut. We still cache here purely as a
        // perf win: a stored MapRef avoids redoing the named lookup on
        // every find/query/create/update/delete.)
        self.rootMap = doc.document.getMap(name: T.modelName)

        // Subscribe to all doc updates (local + remote) and mark the SQLite
        // mirror dirty whenever anything commits. The callback fires
        // synchronously inside the transaction commit, so we only do a tiny
        // bool write under a lock — no doc reads or new transactions.
        self.docUpdateSubscription = doc.observeUpdate { [weak self] _ in
            self?.markQueryIndexDirty()
        }
    }

    deinit {
        docUpdateSubscription?.cancel()
    }

    // MARK: - Dirty flag

    private func markQueryIndexDirty() {
        dirtyLock.lock()
        queryIndexDirty = true
        dirtyLock.unlock()
    }

    /// Returns true (and clears the flag) if the index needs rebuilding.
    /// Returns false if the index is already in sync.
    private func claimDirtyForRebuild() -> Bool {
        dirtyLock.lock()
        defer { dirtyLock.unlock() }
        guard queryIndexDirty else { return false }
        queryIndexDirty = false
        return true
    }

    // MARK: - Read

    /// Find a record by ID. Returns nil if not found.
    public func find(_ id: String) -> T? {
        return doc.transactSync { txn in
            let outerMap = self.rootMap
            guard let recordMap = outerMap.getMap(tx: txn, key: id) else { return nil }
            var fields = self.readFields(from: recordMap, txn: txn)
            fields["id"] = id
            return T(fields: fields)
        }
    }

    /// Return all records in the model.
    public func findAll() -> [T] {
        return doc.transactSync { txn in
            let outerMap = self.rootMap
            let len = outerMap.length(tx: txn)
            if len == 0 { return [] }

            let kc = KeyCollectorInternal()
            outerMap.keys(tx: txn, delegate: kc)

            var results: [T] = []
            for key in kc.keys {
                guard let recordMap = outerMap.getMap(tx: txn, key: key) else { continue }
                var fields = self.readFields(from: recordMap, txn: txn)
                fields["id"] = key
                let record = T(fields: fields)
                results.append(record)
            }
            return results
        }
    }

    /// Return all records matching a predicate.
    public func filter(_ predicate: (T) -> Bool) -> [T] {
        return findAll().filter(predicate)
    }

    // MARK: - Query (SQLite-backed)

    /// Query records with MongoDB-style filters, sorting, and pagination.
    ///
    /// ```swift
    /// // All done tasks sorted by priority descending
    /// let tasks = model.query(["status": "done"], options: QueryOptions(sort: ["priority": -1]))
    ///
    /// // High priority tasks
    /// let urgent = model.query(["priority": ["$gte": 4]])
    ///
    /// // Text search
    /// let results = model.query(["title": ["$containsText": "review"]])
    ///
    /// // Logical operators
    /// let filtered = model.query(["$or": [["status": "done"], ["priority": ["$gte": 5]]]])
    /// ```
    public func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> [T] {
        syncToQueryEngine()
        let rows = queryEngine.query(modelName: T.modelName, filter: filter, options: options)
        return rows.map { T(fields: $0) }
    }

    /// Count records matching a filter.
    ///
    /// ```swift
    /// let doneCount = model.count(["status": "done"])
    /// let total = model.count()
    /// ```
    public func count(_ filter: DocumentFilter? = nil) -> Int {
        syncToQueryEngine()
        return queryEngine.count(modelName: T.modelName, filter: filter)
    }

    /// Run aggregations on the model.
    ///
    /// ```swift
    /// let stats = model.aggregate(AggregateOptions(
    ///     groupBy: ["status"],
    ///     operations: [
    ///         .init(type: .count),
    ///         .init(type: .avg, field: "priority", outputField: "avgPriority")
    ///     ]
    /// ))
    /// // Returns: [["status": "done", "count": 3, "avgPriority": 2.5], ...]
    /// ```
    public func aggregate(_ options: AggregateOptions) -> [[String: Any]] {
        syncToQueryEngine()
        return queryEngine.aggregate(modelName: T.modelName, options: options)
    }

    /// Force re-sync the SQLite query index from the Y.Map data.
    /// Call this if you've made external changes to the Y.Doc that bypassed
    /// the doc's update notifications (rare — `observeUpdate` already covers
    /// every committed transaction).
    public func refreshQueryIndex() {
        markQueryIndexDirty()
        syncToQueryEngine()
    }

    /// Sync all Y.Map records into the SQLite query engine, but only if the
    /// dirty flag is set. The flag is marked by an `observeUpdate`
    /// subscription on the doc, so we skip work entirely when nothing has
    /// changed since the last rebuild.
    private func syncToQueryEngine() {
        guard claimDirtyForRebuild() else { return }
        let records = findAll().map { $0.toFields() }
        queryEngine.syncRecords(modelName: T.modelName, records: records)
        syncCallCount += 1
    }

    // MARK: - Write

    /// Update specific fields on a record. Only writes the given fields.
    public func update(_ id: String, _ updates: [String: Any]) {
        let fieldDefs = Dictionary(uniqueKeysWithValues: T.fields.map { ($0.name, $0) })

        if let client, let documentId {
            client.transactAndSync(documentId) { txn in
                let outerMap = self.rootMap
                guard let recordMap = outerMap.getMap(tx: txn, key: id) else { return }
                for (key, value) in updates {
                    guard let fieldDef = fieldDefs[key] else { continue }
                    let jsonValue = self.encodeFieldValue(value, type: fieldDef.type)
                    recordMap.insert(tx: txn, key: key, value: jsonValue)
                }
            }
        } else {
            doc.transactSync { txn in
                let outerMap = self.rootMap
                guard let recordMap = outerMap.getMap(tx: txn, key: id) else { return }
                for (key, value) in updates {
                    guard let fieldDef = fieldDefs[key] else { continue }
                    let jsonValue = self.encodeFieldValue(value, type: fieldDef.type)
                    recordMap.insert(tx: txn, key: key, value: jsonValue)
                }
            }
        }
    }

    /// Create a new record from a T instance.
    public func create(_ record: T) {
        let fields = record.toFields()

        if let client, let documentId {
            client.transactAndSync(documentId) { txn in
                // Use doc.document.getMap to ensure the root map exists (creates if needed)
                let outerMap = self.rootMap
                let recordMap = outerMap.getOrInsertMap(tx: txn, key: record.id)
                self.writeIdField(record.id, to: recordMap, txn: txn)
                self.writeFields(fields, to: recordMap, txn: txn)
            }
        } else {
            doc.transactSync { txn in
                let outerMap = self.rootMap
                let recordMap = outerMap.getOrInsertMap(tx: txn, key: record.id)
                self.writeIdField(record.id, to: recordMap, txn: txn)
                self.writeFields(fields, to: recordMap, txn: txn)
            }
        }
        // No incremental SQLite update needed: the transaction commit fires
        // `observeUpdate` which marks the index dirty for the next query.
    }

    /// Delete a record by ID.
    public func delete(_ id: String) {
        if let client, let documentId {
            client.transactAndSync(documentId) { txn in
                let outerMap = self.rootMap
                _ = try? outerMap.remove(tx: txn, key: id)
            }
        } else {
            doc.transactSync { txn in
                let outerMap = self.rootMap
                _ = try? outerMap.remove(tx: txn, key: id)
            }
        }
        // No incremental SQLite update needed: the transaction commit fires
        // `observeUpdate` which marks the index dirty for the next query.
    }

    // MARK: - Internal

    private func readFields(from recordMap: YrsMap, txn: YrsTransaction) -> [String: Any] {
        var result: [String: Any] = [:]
        for field in T.fields {
            guard let jsonVal = try? recordMap.get(tx: txn, key: field.name) else { continue }
            #if DEBUG
            // Log first record's raw values for debugging — gated to debug
            // builds so it stays out of Console.app on shipped apps.
            if !BaoModelDebug.hasLogged && (field.name == "content" || field.name == "title") {
                print("[BaoModel-DEBUG] \(T.modelName).\(field.name) raw from Yrs (\(field.type)): \(jsonVal.prefix(150))")
            }
            #endif
            result[field.name] = decodeFieldValue(jsonVal, type: field.type)
            #if DEBUG
            if !BaoModelDebug.hasLogged && (field.name == "content" || field.name == "title") {
                print("[BaoModel-DEBUG] \(T.modelName).\(field.name) after decode: \(String(describing: result[field.name]).prefix(150))")
            }
            #endif
        }
        if !BaoModelDebug.hasLogged && !result.isEmpty {
            BaoModelDebug.hasLogged = true
        }
        return result
    }

    private func writeFields(_ fields: [String: Any], to recordMap: YrsMap, txn: YrsTransaction) {
        let fieldDefs = Dictionary(uniqueKeysWithValues: T.fields.map { ($0.name, $0) })
        for (key, value) in fields {
            guard let fieldDef = fieldDefs[key] else { continue }
            let jsonValue = encodeFieldValue(value, type: fieldDef.type)
            recordMap.insert(tx: txn, key: key, value: jsonValue)
        }
    }

    /// Write the record's `id` as a field inside the nested Y.Map.
    ///
    /// The outer map is already keyed by the id, but js-bao (the TypeScript
    /// reader) also requires the id to appear as a field *inside* the nested
    /// map — its `extractItemData` returns `null` without one, which drops
    /// the whole record from the reader's SQLite mirror and makes it
    /// invisible to `Model.query`. The TS writer does the same thing at
    /// `js-bao/src/models/BaseModel.ts` (search for
    /// "required for database sync"). Called from `create()` so every
    /// record produced by swift-client satisfies the cross-client contract
    /// without requiring every BaoModelRecord definition to declare `id` as
    /// an explicit FieldDefinition.
    private func writeIdField(_ id: String, to recordMap: YrsMap, txn: YrsTransaction) {
        let encoded = encodeFieldValue(id, type: .string)
        recordMap.insert(tx: txn, key: "id", value: encoded)
    }

    private func decodeFieldValue(_ jsonVal: String, type: FieldType) -> Any {
        switch type {
        case .string:
            // JSON strings come as "\"hello\"" — strip outer quotes and unescape
            if jsonVal.hasPrefix("\"") && jsonVal.hasSuffix("\"") && jsonVal.count >= 2 {
                let stripped = String(jsonVal.dropFirst().dropLast())
                return stripped.replacingOccurrences(of: "\\\"", with: "\"")
            }
            return jsonVal
        case .number:
            return Double(jsonVal) ?? 0.0
        case .boolean:
            return jsonVal == "true"
        case .json:
            // Yrs stores JSON values as JSON-encoded strings.
            // A JSON array like [{"text":"hello"}] comes back as:
            //   "[{\"text\":\"hello\"}]"
            // We need to strip the outer quotes AND unescape inner quotes.
            if jsonVal.hasPrefix("\"") && jsonVal.hasSuffix("\"") && jsonVal.count >= 2 {
                let stripped = String(jsonVal.dropFirst().dropLast())
                return stripped.replacingOccurrences(of: "\\\"", with: "\"")
            }
            return jsonVal
        }
    }

    private func encodeFieldValue(_ value: Any, type: FieldType) -> String {
        switch type {
        case .string:
            if let s = value as? String {
                return jsonEncodeString(s)
            }
            return jsonEncodeString("\(value)")
        case .number:
            if let n = value as? Double { return "\(n)" }
            if let n = value as? Int { return "\(n)" }
            return "\(value)"
        case .boolean:
            if let b = value as? Bool { return b ? "true" : "false" }
            return "\(value)"
        case .json:
            if let s = value as? String {
                return jsonEncodeString(s)
            }
            return jsonEncodeString("\(value)")
        }
    }

    /// Properly JSON-encode a string value with escaped quotes, backslashes, newlines, etc.
    private func jsonEncodeString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

// MARK: - Internal Key Collector

private final class KeyCollectorInternal: YrsMapIteratorDelegate {
    var keys: [String] = []
    func call(value: String) {
        keys.append(value)
    }
}
