import Foundation

/// `$near` (#5230): a filter asking for the `k` records nearest a query
/// vector, which a device answers from a vector index it built. The Swift
/// port of js-bao's `query/nearSearch.ts`, messages and statements and all.
///
/// Grammar: `["$near": ["field": …, "vector": […], "k": …, "filter": […]]`
/// as the only key of a query's filter. `field` names a vector field;
/// `vector` is an array of numbers; `k` is an integer from 1 to 10,000, 10
/// when omitted; `filter` is an ordinary filter over the model's other
/// fields, holding neither `$near` nor `$search`. Anything else (a `$near`
/// beside other keys, under `$and`, `$or` or `$not`, or beside `$search`) is
/// refused `JsBaoError(.invalidArgument)` naming the rule, before any
/// statement.
enum RecordLogNearSearch {

    /// The filter key.
    static let key = "$near"

    /// The key a `$near` answer's distance is selected, sorted and paged by.
    static let distanceKey = "_distance"

    /// A `$near` as a query states it, checked.
    struct Query: Sendable {
        var field: String
        /// The query vector's numbers, as given.
        var vector: [JSONValue]
        var k: Int
        /// The conditions on the model's other fields, empty when none.
        var filter: DocumentFilter
    }

    private static let nearKeys: Set<String> = ["field", "vector", "k", "filter"]

    /// Whether `filter` asks for `$near` at its top level.
    static func has(_ filter: DocumentFilter?) -> Bool { filter?[key] != nil }

    private static func invalid(_ message: String) -> JsBaoError { JsBaoError(code: .invalidArgument, message: message) }

    static func nested() -> JsBaoError {
        invalid("$near is allowed only at the top level of a query's filter: it is the filter's only key, its other conditions under $near.filter")
    }

    /// Whether `value` uses `key` anywhere.
    private static func uses(_ key: String, in value: JSONValue) -> Bool {
        switch value {
        case .array(let members): return members.contains { uses(key, in: $0) }
        case .object(let object): return object.contains { $0.key == key || uses(key, in: $0.value) }
        default: return false
        }
    }

    /// The `$near` a read's filter asks for, checked, or `nil` when it asks for none.
    ///
    /// - Throws: `JsBaoError(.invalidArgument)` for a `$near` the grammar does not admit.
    static func parse(_ filter: DocumentFilter?) throws -> Query? {
        guard let filter else { return nil }
        guard let near = filter[key] else {
            if uses(key, in: .object(filter)) { throw nested() }
            return nil
        }
        if filter.count != 1 { throw invalid("$near is the only key of its filter: put the other conditions under $near.filter") }
        guard let object = near.objectValue else { throw invalid("$near is { field, vector, k?, filter? }") }
        if let extra = object.keys.sorted().first(where: { !nearKeys.contains($0) }) {
            throw invalid("$near takes field, vector, k and filter, not \(RecordLogJSON.text(.string(extra)))")
        }
        guard let field = object["field"]?.stringValue, RecordLogSchema.isValidIdentifier(field) else {
            throw invalid("$near.field must name the vector field")
        }
        guard let vector = object["vector"]?.arrayValue else {
            throw invalid("$near.vector must be the query vector: an array of numbers or a Float32Array")
        }
        let k: Int
        if let raw = object["k"] {
            guard let value = raw.numberValue, value.rounded() == value, value >= 1, value <= Double(RecordLogVectorIndex.nearMaxK) else {
                throw invalid("$near.k must be an integer from 1 to \(RecordLogVectorIndex.nearMaxK)")
            }
            k = Int(value)
        } else {
            k = RecordLogVectorIndex.nearDefaultK
        }
        let inner: DocumentFilter
        if let raw = object["filter"] {
            guard let filter = raw.objectValue else { throw invalid("$near.filter must be a filter object") }
            inner = filter
        } else {
            inner = [:]
        }
        if uses(key, in: .object(inner)) || uses(RecordLogTextSearch.key, in: .object(inner)) {
            throw invalid("$near's filter takes neither $near nor $search")
        }
        return Query(field: field, vector: vector, k: k, filter: inner)
    }

    /// A `$near` whose vector does not fit the field: the wrong length, a
    /// member that is not a finite number, or a field that is not a vector
    /// field. `JsBaoError(.db3VectorInvalid)` with `details {model, field}`,
    /// as a write of a bad vector is refused.
    static func vectorInvalid(model: String, field: String, _ message: String) -> JsBaoError {
        JsBaoError(code: .db3VectorInvalid, message: message, details: ["model": .string(model), "field": .string(field)])
    }

    /// `near.vector` as binary32 bytes for a field of `dims` numbers, or the
    /// refusal: a vector of another length, or a member that is not a finite
    /// number. `dims` `nil` checks the members alone (a field whose encoding
    /// this device does not know).
    static func vectorBytes(_ near: Query, model: String, dims: Int?) throws -> Data {
        if let dims, near.vector.count != dims {
            throw vectorInvalid(model: model, field: near.field, "$near.vector holds \(near.vector.count) numbers; \(model).\(near.field) holds \(dims)")
        }
        var numbers: [Float] = []
        numbers.reserveCapacity(near.vector.count)
        for (index, value) in near.vector.enumerated() {
            guard let number = value.numberValue, number.isFinite else {
                throw vectorInvalid(model: model, field: near.field, "$near.vector[\(index)] is not a finite number")
            }
            numbers.append(Float(number))
        }
        return numbers.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
    }

    /// No vector entry cached for `model.field` on this device: `JsBaoError(.queryIndexNotOnDevice)`.
    static func notOnDevice(model: String, field: String) -> JsBaoError {
        JsBaoError(
            code: .queryIndexNotOnDevice,
            message: "$near on \(model).\(field) needs a vector index on this device, and this device holds none over the field",
            details: ["operator": .string(key), "model": .string(model), "field": .string(field)]
        )
    }

    /// A `$near` on a vector index this device declined (#5322): `JsBaoError(.db3IndexDeclinedOnDevice)`, naming `accept`.
    static func declined(model: String, index: String, reason: String) -> JsBaoError {
        JsBaoError(
            code: .db3IndexDeclinedOnDevice,
            message: "\(model)'s vector index \(index) is not built on this device (\(reason)): accept it with "
                + "client.db3.indexes.accept(db3Id, name: \"\(index)\") to build it here",
            details: ["model": .string(model), "index": .string(index), "kind": "vector"]
        )
    }

    /// A `$near` on a vector index this device holds the entry of but no
    /// table for: `JsBaoError(.db3IndexPlacementUnsupported)` naming the
    /// engine and why.
    static func notBuilt(model: String, reason: String) -> JsBaoError {
        JsBaoError(
            code: .db3IndexPlacementUnsupported,
            message: "\(model)'s vector index is not built on this device (\(RecordLogTextSearch.engine)): \(reason)",
            details: ["kind": "vector", "on": "device", "engine": .string(RecordLogTextSearch.engine), "reason": .string(reason)]
        )
    }

    /// A `$near` as a reader answers it from a device vector index.
    struct Read: Sendable {
        /// The flat table, which answers exactly.
        var table: String
        /// The ANN table, which answers from a shared model's buckets, reranked; `nil` in exact mode.
        var annTable: String?
        /// `cos` or `l2`.
        var distance: String
        /// The query vector as binary32 bytes.
        var vector: Data
        var k: Int
        /// The conditions on the model's other fields, empty when none.
        var filter: DocumentFilter
    }

    /// How many of vec1's nearest a `$near` of `k` reads before it orders
    /// them by distance then `_id` and keeps `k`: rows at the `k`th distance
    /// beyond the `k`th are read too, so a tie across the boundary is broken
    /// by the record's id and not by its rowid, which differs between devices.
    static func tieWindow(_ k: Int) -> Int { k + max(k, 64) }

    private static func quoted(_ name: String) -> String { RecordLogVectorIndex.quoted(name) }

    /// The statement a `$near` reads its `k` nearest rowids and their
    /// distances from, `(rowid, _distance)`, and every bind it takes, the
    /// filter's included. js-bao's `nearSubquery`, text for text (the shared
    /// fixture pins it).
    ///
    /// Exact mode reads the flat table's ``tieWindow(_:)`` nearest; with a
    /// filter, vec1's streaming mode produces rows in distance order until
    /// that many pass it. When the window filled and its last row is at the
    /// `k`th distance, ties may lie past it: the statement then reads every
    /// (passing) row up to that distance by streaming instead. `ann` mode
    /// reads `max(20·k, 200)` candidates from the ANN table at nprobe 0.1
    /// (streaming likewise under a filter) and reranks them on their full
    /// vectors with the exact distance, so `_distance` is always exact.
    /// Either way the rows are ordered by `_distance` then the record's `_id`
    /// before the `k` nearest are kept.
    ///
    /// - Parameters:
    ///   - filterSQL: The filter's condition over the view, or `""`.
    ///   - filterParams: What `filterSQL` binds.
    static func subquery(_ read: Read, viewTable: String, filterSQL: String, filterParams: [Format2SqlValue]) -> (sql: String, params: [Format2SqlValue]) {
        let filtered = !filterSQL.isEmpty
        let join = { (alias: String) in
            " CROSS JOIN \(viewTable) ON \(viewTable).rowid = \(alias).rowid\(filtered ? " WHERE \(filterSQL)" : "")"
        }
        let nearest = { (inner: String) in "SELECT rowid, \(distanceKey) FROM (\(inner)) ORDER BY \(distanceKey), _near_id LIMIT \(read.k)" }
        let vector = Format2SqlValue.blob(read.vector)
        guard let annTable = read.annTable else {
            let window = tieWindow(read.k)
            let options = filtered ? "{K:\(window), streaming:1}" : "{K:\(window)}"
            let rows = { (alias: String) in
                "SELECT \(alias).rowid AS rowid, \(alias).distance AS \(distanceKey), \(viewTable)._id AS _near_id"
            }
            let kth = "(SELECT \(distanceKey) FROM _near_window ORDER BY \(distanceKey) LIMIT 1 OFFSET \(read.k - 1))"
            let overflow = "((SELECT COUNT(*) FROM _near_window) = \(window) AND (SELECT MAX(\(distanceKey)) FROM _near_window) <= \(kth))"
            let tied = "\(rows("t")) FROM (SELECT 1 WHERE \(overflow)) AS _near_tied CROSS JOIN \(quoted(read.table))(?, ?) AS t\(join("t"))"
                + "\(filtered ? " AND" : " WHERE") t.distance <= \(kth)"
            return (
                "WITH _near_window AS MATERIALIZED (\(rows("n")) FROM \(quoted(read.table))(?, ?) AS n\(join("n")) LIMIT \(window)) "
                    + nearest("SELECT * FROM _near_window WHERE NOT \(overflow) UNION ALL \(tied)"),
                [vector, .text(options)] + filterParams + [vector, .text("{K:\(window), streaming:1}")] + filterParams
            )
        }
        let candidates = max(RecordLogVectorIndex.nearCandidates(read.k), tieWindow(read.k))
        let measure = read.distance == "cos" ? "vec1_cos_distance" : "vec1_l2_distance"
        let options = "{K:\(candidates), nprobe:\(RecordLogVectorIndex.nearDefaultNprobe)\(filtered ? ", streaming:1" : "")}"
        return (
            nearest(
                "SELECT a.rowid AS rowid, \(measure)(a.vector, ?) AS \(distanceKey), \(viewTable)._id AS _near_id "
                    + "FROM \(quoted(annTable))(?, ?) AS a\(join("a")) LIMIT \(candidates)"
            ),
            [vector, vector, .text(options)] + filterParams
        )
    }

    /// How a typed db3's type declares `model.field`: its kind and, for a
    /// vector field, its dims; `nil` when the store holds no declaration of
    /// the model (an untyped db3, or a type whose declarations are not held).
    static func declaredField(_ sql: RecordLogSql, documentId: String, model: String, field: String) throws -> (kind: String?, dims: Int?)? {
        let text = try sql.first("SELECT value FROM record_log_meta WHERE key = ?", [.text("db3_type:\(documentId)")])?["value"].stringValue
        guard let held = text.flatMap({ JSONValue(jsonText: $0) })?.objectValue, held["typed"]?.stringValue == "yes",
              let fields = held["models"]?[model]?.objectValue
        else { return nil }
        let dims = RecordLogVectorIndex.integer(held["vectors"]?[model]?[field]?["dims"])
        return (fields[field]?.stringValue, dims)
    }
}
