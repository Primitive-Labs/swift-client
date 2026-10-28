import Foundation

/// One index of a db3's list, as the room answers `GET db3/:id/indexes`.
struct RecordLogIndexEntry: Equatable, Sendable {
    /// The room's name for it; the store names its own index its own way.
    var name: String
    var model: String
    var fields: [String]
    var unique: Bool

    init(name: String, model: String, fields: [String], unique: Bool) {
        self.name = name
        self.model = model
        self.fields = fields
        self.unique = unique
    }

    /// One entry of the room's `indexes` array, or `nil` when it names no model or fields.
    init?(json: JSONValue) {
        guard let model = json["model"]?.stringValue, let fields = json["fields"]?.arrayValue else { return nil }
        self.init(
            name: json["name"]?.stringValue ?? "", model: model, fields: fields.compactMap(\.stringValue),
            unique: json["unique"]?.boolValue ?? false
        )
    }
}

/// One view index of a store, as the room lists one: `(model, fields, unique)`.
struct RecordLogIndexTuple: Equatable, Sendable {
    var model: String
    var fields: [String]
    var unique: Bool
}

/// What a reconcile did.
struct RecordLogIndexSync: Equatable, Sendable {
    var created: Int
    var dropped: Int
}

/// The order a db3's index-list reads are applied in. Reads may answer out of
/// order (the open's read and the read on the room's `record.declared` run side
/// by side) and the store replaces its cached list with each one it is handed,
/// so a read answered after a later one was applied is dropped. js-bao's
/// `Db3IndexReadOrder`.
///
/// `@unchecked Sendable`: its one mutable property, `reads`, is read and
/// written only under `lock`, a leaf lock held for the lookup alone.
/// `applying` serializes the applications themselves (the check, the store's
/// sync and the mark), so two answers in flight never apply out of order.
final class RecordLogIndexReadOrder: @unchecked Sendable {
    private let lock = NSLock()
    private let applying = NSLock()
    private var reads: [String: (issued: Int, applied: Int)] = [:]

    /// Number a new read of `documentId`'s list.
    func issue(_ documentId: String) -> Int {
        lock.withLock {
            var current = reads[documentId] ?? (0, 0)
            current.issued += 1
            reads[documentId] = current
            return current.issued
        }
    }

    /// Apply read `read` of `documentId`'s list with `body`, unless a later
    /// read's list was applied already. The check, `body` and the mark run as
    /// one step, one application at a time, so of two answers in flight the
    /// later-issued one is applied last or the older one not at all. The read
    /// counts as applied once `body` returns; a `body` that throws marks
    /// nothing. Answers whether `body` ran.
    @discardableResult
    func apply(_ documentId: String, _ read: Int, _ body: () throws -> Void) throws -> Bool {
        applying.lock()
        defer { applying.unlock() }
        guard lock.withLock({ read >= (reads[documentId]?.applied ?? 0) }) else { return false }
        try body()
        lock.withLock {
            var current = reads[documentId] ?? (read, 0)
            current.applied = max(current.applied, read)
            reads[documentId] = current
        }
        return true
    }
}

/// A store's lookup indexes on its db3s' views, built from the room's index
/// lists rather than from model declarations. The Swift port of js-bao's
/// `record-log-client/indexes.ts`, names and all.
///
/// The list is cached per document in `record_log_indexes`; the indexes are
/// reconciled per store, over every cached document, by definition:
///
/// - one partial index on `record_log_view` per distinct `(model, fields)`,
///   with the columns `doc_id, json_extract(_data, '$.<field>')…, _id` and
///   `WHERE _type = '<model>'`, never SQL `UNIQUE` (uniqueness is the room's);
/// - one on `record_log_rows` for each unique single-field entry, where an
///   upsert's guess looks for the record holding its value;
/// - an existing index is matched by its definition, not its name; a new one
///   takes the canonical name, or `<canonical>_<n>` when another index holds
///   that name, so `(Note, [title])` and `(note, [title])` are two indexes;
/// - an index of the store's family (`idx_record_log_view_…`,
///   `idx_record_log_rows_…`) whose definition no cached entry wants is dropped.
enum RecordLogIndexes {

    /// The tables a store's lookup indexes are on, with the prefix of their names.
    private static let family: [(table: String, prefix: String)] = [
        ("record_log_view", "idx_record_log_view_"),
        ("record_log_rows", "idx_record_log_rows_"),
    ]

    /// The definition of an index on `table` over `model`'s `fields`, as the store writes it.
    static func definition(_ table: String, _ model: String, _ fields: [String]) -> String {
        let columns = (["doc_id"] + fields.map { "json_extract(_data, '$.\($0)')" } + ["_id"]).joined(separator: ", ")
        return "\(table)(\(columns)) WHERE _type = \(RecordLogSchema.quoteLiteral(model))"
    }

    /// The canonical name of the store's index on `table` (`view` or `rows`)
    /// over `model`'s `fields`: `idx_record_log_<table>_<len>_<model>` then
    /// `_<len>_<field>` per field, names lowercased.
    static func name(_ table: String, _ model: String, _ fields: [String]) -> String {
        let part = { (name: String) in "\(name.utf16.count)_\(name.lowercased())" }
        return (["idx_record_log_\(table)", part(model)] + fields.map(part)).joined(separator: "_")
    }

    /// A `CREATE INDEX` statement's definition: the text after `ON`, whitespace collapsed.
    static func definition(inSql sql: String) -> String? {
        guard let on = sql.range(of: #"\bON\s+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(sql[on.upperBound...])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\)"#, with: ")", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Why the store cannot index `entry`, or `nil`.
    private static func unusable(_ entry: RecordLogIndexEntry) -> String? {
        if !RecordLogSchema.isValidIdentifier(entry.model) { return "model '\(entry.model)' is not an identifier" }
        if let bad = entry.fields.first(where: { !RecordLogSchema.isValidIdentifier($0) }) {
            return "field '\(bad)' is not an identifier"
        }
        if entry.fields.isEmpty { return "it names no field" }
        return nil
    }

    /// Replace `documentId`'s cached list with `entries`, then reconcile the
    /// store's indexes; with no list, reconcile from what is cached (a db3
    /// opened offline keeps its indexes). An entry whose model or field is not
    /// an identifier is skipped with a warning; one on `id` alone needs no index
    /// of its own. The caller runs it as one transaction.
    static func sync(
        _ sql: RecordLogSql, documentId: String, _ entries: [RecordLogIndexEntry]?, logger: Logger?
    ) throws -> RecordLogIndexSync {
        if let entries {
            try sql.exec("DELETE FROM record_log_indexes WHERE doc_id = ?", [.text(documentId)])
            for entry in entries {
                if let refusal = unusable(entry) {
                    logger?.warn("[record-log] \(documentId): index '\(entry.name)' skipped: \(refusal); queries on it scan.")
                    continue
                }
                if entry.fields == ["id"] { continue }
                try sql.exec(
                    """
                    INSERT INTO record_log_indexes (doc_id, model, fields, is_unique, room_name) VALUES (?, ?, ?, ?, ?)
                      ON CONFLICT (doc_id, model, fields) DO UPDATE SET \
                    is_unique = MAX(is_unique, excluded.is_unique), room_name = excluded.room_name
                    """,
                    [
                        .text(documentId), .text(entry.model), .text(RecordLogJSON.text(.array(entry.fields.map { .string($0) }))),
                        .integer(entry.unique ? 1 : 0), .text(entry.name),
                    ]
                )
            }
        }
        return try reconcile(sql)
    }

    /// Every cached `(model, fields)` with whether any list marks it unique.
    private static func cached(_ sql: RecordLogSql) throws -> [(model: String, fields: [String], unique: Bool)] {
        try sql.rows("SELECT model, fields, MAX(is_unique) AS is_unique FROM record_log_indexes GROUP BY model, fields").map { row in
            let fields = (row["fields"].stringValue.flatMap(RecordLogJSON.parse)?.arrayValue ?? []).compactMap(\.stringValue)
            return (row["model"].stringValue ?? "", fields, row["is_unique"].intValue == 1)
        }
    }

    /// Make the store's family of indexes the set the cached lists want.
    private static func reconcile(_ sql: RecordLogSql) throws -> RecordLogIndexSync {
        var wanted: [(table: String, definition: String, canonical: String)] = []
        var wantedDefinitions = Set<String>()
        for (model, fields, unique) in try cached(sql) {
            let view = definition("record_log_view", model, fields)
            if wantedDefinitions.insert(view).inserted {
                wanted.append(("record_log_view", view, name("view", model, fields)))
            }
            if unique && fields.count == 1 {
                let rows = definition("record_log_rows", model, fields)
                if wantedDefinitions.insert(rows).inserted {
                    wanted.append(("record_log_rows", rows, name("rows", model, fields)))
                }
            }
        }
        var held = Set<String>()
        var taken = Set<String>()
        var dropped = 0
        for row in try sql.rows("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL") {
            let indexName = row["name"].stringValue ?? ""
            let table = row["tbl_name"].stringValue ?? ""
            taken.insert(indexName)
            guard family.contains(where: { $0.table == table && indexName.hasPrefix($0.prefix) }) else { continue }
            if let found = row["sql"].stringValue.flatMap(definition(inSql:)), wantedDefinitions.contains(found),
               held.insert(found).inserted {
                continue
            }
            try sql.connection.executeScript("DROP INDEX IF EXISTS \(quoted(indexName))")
            taken.remove(indexName)
            dropped += 1
        }
        var created = 0
        for index in wanted where !held.contains(index.definition) {
            var indexName = index.canonical
            var n = 2
            while taken.contains(indexName) {
                indexName = "\(index.canonical)_\(n)"
                n += 1
            }
            try sql.connection.executeScript("CREATE INDEX \(quoted(indexName)) ON \(index.definition)")
            taken.insert(indexName)
            created += 1
        }
        return RecordLogIndexSync(created: created, dropped: dropped)
    }

    /// The store's view indexes as the room lists its own: `(model, fields,
    /// unique)`, read from `sqlite_master` with `unique` from the cached lists,
    /// sorted by model, then fields.
    static func tuples(_ sql: RecordLogSql) throws -> [RecordLogIndexTuple] {
        var unique: [String: Bool] = [:]
        for (model, fields, isUnique) in try cached(sql) {
            unique[definition("record_log_view", model, fields)] = isUnique
        }
        var tuples: [RecordLogIndexTuple] = []
        let rows = try sql.rows(
            #"SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'record_log_view' AND name LIKE 'idx\_record\_log\_view\_%' ESCAPE '\'"#
        )
        for row in rows {
            guard let found = row["sql"].stringValue.flatMap(definition(inSql:)),
                  let model = firstMatch(#"WHERE _type = '((?:[^']|'')*)'$"#, in: found)?.replacingOccurrences(of: "''", with: "'")
            else { continue }
            let fields = allMatches(#"json_extract\(_data, '\$\.([A-Za-z_][A-Za-z0-9_]*)'\)"#, in: found)
            tuples.append(RecordLogIndexTuple(model: model, fields: fields, unique: unique[found] ?? false))
        }
        let key = { (tuple: RecordLogIndexTuple) in
            Array(RecordLogJSON.text(.array([.string(tuple.model), .array(tuple.fields.map { .string($0) })])).utf8)
        }
        return tuples.sorted { key($0).lexicographicallyPrecedes(key($1)) }
    }

    private static func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    /// The first capture group of every match of `pattern` in `text`.
    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }
}
