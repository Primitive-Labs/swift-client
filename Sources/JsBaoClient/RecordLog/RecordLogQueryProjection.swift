import Foundation

/// What one model's query tables look like: the table `query()`, `count()`
/// and `aggregate()` read, its scalar columns and its string-set junctions.
/// Keyed by `_meta_doc_id`, so one read answers over every record-log
/// document stored in them.
struct RecordLogProjectionSpec: Sendable, Equatable {
    let model: String
    /// The model's query table.
    let table: String
    /// The scalar fields, by name, with their types; `id` is not among them.
    let columns: [Column]
    /// The string-set fields, each with its junction table.
    let stringSets: [(field: String, junction: String)]

    struct Column: Sendable, Equatable {
        let name: String
        let type: PrimitiveFieldType
    }

    init(schema: PrimitiveSchema) {
        model = schema.name
        table = BaoModelQueryEngine.sanitizeTableName(schema.name)
        let sorted = schema.fields.sorted { $0.key < $1.key }
        columns = sorted.compactMap { name, descriptor in
            name == "id" || descriptor.type == .stringset ? nil : Column(name: name, type: descriptor.type)
        }
        let table = self.table
        stringSets = sorted.compactMap { name, descriptor in
            descriptor.type == .stringset ? (name, "\(table)__\(name)") : nil
        }
    }

    static func == (a: RecordLogProjectionSpec, b: RecordLogProjectionSpec) -> Bool {
        a.model == b.model && a.table == b.table && a.columns == b.columns
            && a.stringSets.map(\.field) == b.stringSets.map(\.field)
    }
}

/// The projection of a format-3 document's view into the model query tables.
///
/// The rows are written on the provider's connection inside the store's own
/// transaction (a save's group, or a command's), so a projected row commits
/// with the view row it came from: `query` and `find` cannot disagree.
/// Preparing a table goes through the query engine (`ensureTable`), which
/// takes the engine's lock and then the provider's queue, so it is never
/// called from inside a store call.
enum RecordLogQueryProjection {

    /// Create (or widen) a model's query tables for format-3 rows, through the
    /// engine that reads them. Called off the provider's queue.
    static func prepare(schema: PrimitiveSchema, engine: BaoModelQueryEngine, host: any Format2SqlHost) throws {
        try widen(schema: schema, host: host)
        engine.ensureTable(
            modelName: schema.name,
            fields: schema.fields.map { (name: $0.key, type: $0.value.type.toLegacyFieldType()) },
            indexedFields: Set(schema.fields.compactMap { name, descriptor in
                descriptor.indexed || descriptor.unique ? name : nil
            }),
            withDocIdColumn: true,
            stringsetFields: Set(schema.fields.compactMap { name, descriptor in
                descriptor.type == .stringset ? name : nil
            })
        )
    }

    /// Give a stored table the columns this build's schema has. A model that
    /// gained a field has every document's projection mark withdrawn, so each
    /// re-projects from its view when it is next bound.
    private static func widen(schema: PrimitiveSchema, host: any Format2SqlHost) throws {
        let table = BaoModelQueryEngine.sanitizeTableName(schema.name)
        try host.withConnection { connection in
            let existing = Set(
                try connection.query("PRAGMA table_info(\"\(table)\")").compactMap { $0["name"].stringValue }
            )
            guard !existing.isEmpty else { return }
            var added = false
            for (name, descriptor) in schema.fields.sorted(by: { $0.key < $1.key })
            where name != "id" && descriptor.type != .stringset && !existing.contains(name) {
                try connection.execute("ALTER TABLE \"\(table)\" ADD COLUMN \"\(name)\" \(columnType(descriptor.type))")
                added = true
            }
            guard added else { return }
            let marks = try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'record_log_projection'"
            )
            if !marks.isEmpty {
                try connection.execute("DELETE FROM record_log_projection WHERE model = ?", [.text(schema.name)])
            }
        }
    }

    private static func columnType(_ type: PrimitiveFieldType) -> String {
        switch type.toLegacyFieldType() {
        case .number: return "REAL"
        case .boolean: return "INTEGER"
        default: return "TEXT"
        }
    }

    /// Write one record's projected row from its view row — or remove it when
    /// the view holds none. Its string-set junctions are set to exactly the
    /// row's members.
    static func projectRow(
        _ sql: RecordLogSql, spec: RecordLogProjectionSpec, documentId: String, id: String, row: RecordLogRow?
    ) throws {
        let doc: Format2SqlValue = .text(documentId)
        guard let row else {
            try sql.exec("DELETE FROM \"\(spec.table)\" WHERE \"_meta_doc_id\" = ? AND \"id\" = ?", [doc, .text(id)])
            for set in spec.stringSets {
                try sql.exec(
                    "DELETE FROM \"\(set.junction)\" WHERE \"_meta_doc_id\" = ? AND \"parent_id\" = ?", [doc, .text(id)]
                )
            }
            return
        }
        var names = ["_meta_doc_id", "id"]
        var values: [Format2SqlValue] = [doc, .text(id)]
        for column in spec.columns {
            names.append(column.name)
            values.append(value(row[column.name]))
        }
        try sql.exec(
            "INSERT OR REPLACE INTO \"\(spec.table)\" (\(names.map { "\"\($0)\"" }.joined(separator: ", "))) "
                + "VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
            values
        )
        for set in spec.stringSets {
            let members = row[set.field]?.arrayValue?.compactMap(\.stringValue) ?? []
            let current = try sql.rows(
                "SELECT value FROM \"\(set.junction)\" WHERE \"_meta_doc_id\" = ? AND \"parent_id\" = ?", [doc, .text(id)]
            ).compactMap { $0["value"].stringValue }
            for member in current where !members.contains(where: { recordLogSameText($0, member) }) {
                try sql.exec(
                    "DELETE FROM \"\(set.junction)\" WHERE \"_meta_doc_id\" = ? AND \"parent_id\" = ? AND \"value\" = ?",
                    [doc, .text(id), .text(member)]
                )
            }
            for member in members where !current.contains(where: { recordLogSameText($0, member) }) {
                try sql.exec(
                    "INSERT OR IGNORE INTO \"\(set.junction)\" (\"_meta_doc_id\", \"parent_id\", \"value\") VALUES (?, ?, ?)",
                    [doc, .text(id), .text(member)]
                )
            }
        }
    }

    /// Remove every projected row of one document from one model's tables.
    static func removeDocument(_ sql: RecordLogSql, spec: RecordLogProjectionSpec, documentId: String) throws {
        guard try tableExists(sql, spec.table) else { return }
        try sql.exec("DELETE FROM \"\(spec.table)\" WHERE \"_meta_doc_id\" = ?", [.text(documentId)])
        for set in spec.stringSets where try tableExists(sql, set.junction) {
            try sql.exec("DELETE FROM \"\(set.junction)\" WHERE \"_meta_doc_id\" = ?", [.text(documentId)])
        }
    }

    private static func tableExists(_ sql: RecordLogSql, _ name: String) throws -> Bool {
        try sql.first("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) != nil
    }

    /// What a view value binds as: a scalar as itself (a boolean as 1/0), a
    /// nested object or array as its JSON text, which the view keeps as a value.
    static func value(_ value: JSONValue?) -> Format2SqlValue {
        guard let value else { return .null }
        switch value {
        case .object, .array: return .text(RecordLogJSON.text(value))
        default: return Format2SqlValue(json: value)
        }
    }
}
