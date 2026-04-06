import Foundation
import YSwift
import Yniffi

private enum CollectionDebug {
    static var hasLogged = false
}

// MARK: - Protocol

/// A type that can be stored as a record in a Y.Map-backed collection.
/// Each record is a nested Y.Map within a top-level Y.Map named after the collection.
public protocol CollectionRecord: Identifiable where ID == String {
    /// The collection name (e.g., "pages", "blocks"). Maps to yDoc.getMap(name).
    static var collectionName: String { get }

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

// MARK: - Collection

/// Typed access to a Y.Map-backed collection within a YDocument.
///
/// Structure: `yDoc.getMap("collectionName")` contains nested Y.Maps keyed by record ID.
/// Each nested Y.Map holds the record's fields as JSON-encoded values.
///
/// Supports rich queries via a SQLite mirror:
/// ```swift
/// let tasks = collection.query(["status": "done"], options: QueryOptions(sort: ["priority": -1]))
/// let count = collection.count(["completed": true])
/// let stats = collection.aggregate(AggregateOptions(
///     groupBy: ["status"],
///     operations: [.init(type: .count), .init(type: .avg, field: "priority")]
/// ))
/// ```
public final class Collection<T: CollectionRecord> {
    private let doc: YDocument
    private let client: JsBaoClient?
    private let documentId: String?
    private lazy var queryEngine: CollectionQueryEngine = {
        let engine = CollectionQueryEngine()
        let fieldTuples = T.fields.map { (name: $0.name, type: $0.type) }
        engine.ensureTable(collectionName: T.collectionName, fields: fieldTuples)
        return engine
    }()
    private var queryIndexSynced = false

    /// The root Y.Map for this collection. Created once on init via get-or-create.
    private let rootMap: YrsMap

    /// Create a collection bound to a YDocument.
    /// Pass `client` and `documentId` to enable network sync on writes.
    public init(doc: YDocument, client: JsBaoClient? = nil, documentId: String? = nil) {
        self.doc = doc
        self.client = client
        self.documentId = documentId
        // Get or create the root map OUTSIDE any transaction to avoid deadlocks.
        // YrsDoc.getMap(name:) is a get-or-create operation that's safe to call freely.
        self.rootMap = doc.document.getMap(name: T.collectionName)
    }

    // MARK: - Read

    /// Find a record by ID. Returns nil if not found.
    public func find(_ id: String) -> T? {
        return doc.transactSync { txn in
            let outerMap = self.rootMap
            guard let recordMap = outerMap.getMap(tx: txn, key: id) else { return nil }
            let fields = self.readFields(from: recordMap, txn: txn)
            return T(fields: fields)
        }
    }

    /// Return all records in the collection.
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
                let fields = self.readFields(from: recordMap, txn: txn)
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
    /// let tasks = collection.query(["status": "done"], options: QueryOptions(sort: ["priority": -1]))
    ///
    /// // High priority tasks
    /// let urgent = collection.query(["priority": ["$gte": 4]])
    ///
    /// // Text search
    /// let results = collection.query(["title": ["$containsText": "review"]])
    ///
    /// // Logical operators
    /// let filtered = collection.query(["$or": [["status": "done"], ["priority": ["$gte": 5]]]])
    /// ```
    public func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> [T] {
        syncToQueryEngine()
        let rows = queryEngine.query(collectionName: T.collectionName, filter: filter, options: options)
        return rows.map { T(fields: $0) }
    }

    /// Count records matching a filter.
    ///
    /// ```swift
    /// let doneCount = collection.count(["status": "done"])
    /// let total = collection.count()
    /// ```
    public func count(_ filter: DocumentFilter? = nil) -> Int {
        syncToQueryEngine()
        return queryEngine.count(collectionName: T.collectionName, filter: filter)
    }

    /// Run aggregations on the collection.
    ///
    /// ```swift
    /// let stats = collection.aggregate(AggregateOptions(
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
        return queryEngine.aggregate(collectionName: T.collectionName, options: options)
    }

    /// Force re-sync the SQLite query index from the Y.Map data.
    /// Call this if you've made external changes to the Y.Doc.
    public func refreshQueryIndex() {
        queryIndexSynced = false
        syncToQueryEngine()
    }

    /// Sync all Y.Map records into the SQLite query engine.
    private func syncToQueryEngine() {
        let records = findAll().map { $0.toFields() }
        queryEngine.syncRecords(collectionName: T.collectionName, records: records)
        queryIndexSynced = true
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
                self.writeFields(fields, to: recordMap, txn: txn)
            }
        } else {
            doc.transactSync { txn in
                let outerMap = self.rootMap
                let recordMap = outerMap.getOrInsertMap(tx: txn, key: record.id)
                self.writeFields(fields, to: recordMap, txn: txn)
            }
        }

        // Keep SQLite index in sync
        if queryIndexSynced {
            queryEngine.upsertRecord(collectionName: T.collectionName, record: fields)
        }
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

        // Keep SQLite index in sync
        if queryIndexSynced {
            queryEngine.deleteRecord(collectionName: T.collectionName, id: id)
        }
    }

    // MARK: - Internal

    private func readFields(from recordMap: YrsMap, txn: YrsTransaction) -> [String: Any] {
        var result: [String: Any] = [:]
        for field in T.fields {
            guard let jsonVal = try? recordMap.get(tx: txn, key: field.name) else { continue }
            // Log first record's raw values for debugging
            if !CollectionDebug.hasLogged && (field.name == "content" || field.name == "title") {
                print("[Collection-DEBUG] \(T.collectionName).\(field.name) raw from Yrs (\(field.type)): \(jsonVal.prefix(150))")
            }
            result[field.name] = decodeFieldValue(jsonVal, type: field.type)
            if !CollectionDebug.hasLogged && (field.name == "content" || field.name == "title") {
                print("[Collection-DEBUG] \(T.collectionName).\(field.name) after decode: \(String(describing: result[field.name]).prefix(150))")
            }
        }
        if !CollectionDebug.hasLogged && !result.isEmpty {
            CollectionDebug.hasLogged = true
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
