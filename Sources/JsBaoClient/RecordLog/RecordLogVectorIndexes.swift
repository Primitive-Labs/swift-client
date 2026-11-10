import Foundation

/// A db3's vector index on `model.field` as a `$near` reads it (#5230): its
/// tables when built, and what its refusal names when not. js-bao's
/// `RecordLogVectorIndexOf`.
struct RecordLogVectorIndexOf: Equatable, Sendable {
    /// The flat table, or `nil` when the store holds none for it (unbuilt, declined).
    var table: String?
    /// The ANN table, when a model is installed and its fill finished: the table `$near` answers from.
    var annTable: String?
    /// The index's options and the field's encoding, when the room's list gave them.
    var vector: RecordLogVectorOptions?
    /// The room's name for the index, which a refusal names.
    var roomName: String
    /// Why this device does not build it (#5322): declined here, or left out by the `deviceIndexes` default with nothing built.
    var declined: String?
    /// Why it is not built, when it is not.
    var unbuilt: String?
}

// MARK: - Vector indexes (#5230)

/// The vector family's half of a reconcile, the Swift port of js-bao's
/// `dropUnwantedVectors` and `buildVectors` (#5229). A vector entry's cached
/// options are js-bao's `RecordLogVectorEntryOptions`, key for key: what the
/// room lists of it (`on`, `vector`, `generation`, `revision`, `annModel`) and
/// how it stands on this device (`flat`, the flat table's definition as
/// built; `ann`, the installed model; `fill`, its ANN table's fill under way;
/// `refused`, a model this device refused at its revision; `training`, a
/// training run under way here; `unbuilt`, why it is not built).
extension RecordLogIndexes {

    /// The device state a vector entry's cached options carry across a new list.
    static let vectorDeviceState = ["flat", "ann", "fill", "refused", "training", "unbuilt"]

    static let triggerSuffixesOfVectors = RecordLogVectorIndex.triggerSuffixes

    /// The key a vector entry's previous table is found under: one vector index per field.
    static func vectorKey(_ model: String, _ field: String) -> String { "vector\u{0}\(model)\u{0}\(field)" }

    /// The vec1 tables of the vector family, flat and ANN (vec1's own shadow tables are not listed).
    static func vectorTables(_ sql: RecordLogSql) throws -> Set<String> {
        Set(try sql.rows(
            #"SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'idx\_record\_log\_vec\_%' ESCAPE '\' AND sql LIKE 'CREATE VIRTUAL TABLE%'"#
        ).compactMap { $0["name"].stringValue })
    }

    /// The triggers of the vector family, with their text.
    static func vectorTriggers(_ sql: RecordLogSql) throws -> [String: String] {
        var out: [String: String] = [:]
        for row in try sql.rows(#"SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'idx\_record\_log\_vec\_%' ESCAPE '\'"#) {
            if let name = row["name"].stringValue { out[name] = row["sql"].stringValue ?? "" }
        }
        return out
    }

    /// What a vector entry's triggers keep: its db3, model, field and encoding.
    static func vectorTarget(_ row: Format2SqlRow, _ vector: RecordLogVectorOptions) -> RecordLogVectorIndex.Target {
        RecordLogVectorIndex.Target(
            documentId: row["doc_id"].stringValue ?? "", model: row["model"].stringValue ?? "", field: fieldsOf(row).first ?? "",
            element: vector.element.rawValue, dims: vector.dims
        )
    }

    /// Whether a vector entry's installed model is still its index's: the
    /// index is `ann`, and on a synced db3 the room lists a model of the same
    /// generation and revision (a local-only db3's model is its own).
    static func annCurrent(_ row: Format2SqlRow, _ options: [String: JSONValue]) -> Bool {
        guard let ann = options["ann"]?.objectValue, RecordLogVectorOptions(cached: options["vector"])?.isAnn == true else { return false }
        if row["local_only"].intValue == 1 { return ann["source"]?.stringValue == "local" }
        guard let listed = options["annModel"]?.objectValue else { return false }
        return listed["revision"] == ann["revision"] && options["generation"] == ann["generation"]
    }

    /// Whether the flat table was built as the entry's options now ask for.
    static func flatCurrent(_ options: [String: JSONValue]) -> Bool {
        guard let vector = RecordLogVectorOptions(cached: options["vector"]), let flat = options["flat"]?.objectValue else { return false }
        return flat["distance"]?.stringValue == vector.distance && RecordLogVectorIndex.integer(flat["dims"]) == vector.dims
            && flat["element"]?.stringValue == vector.element.rawValue
    }

    /// Write a vector entry's options and pointer back.
    static func writeVectorOptions(_ sql: RecordLogSql, _ row: Format2SqlRow, _ options: [String: JSONValue], _ vector: String?) throws {
        try sql.exec(
            "UPDATE record_log_indexes SET vector = ?, options = ? WHERE doc_id = ? AND model = ? AND fields = ? AND kind = 'vector'",
            [vector.map { .text($0) } ?? .null, .text(RecordLogJSON.text(.object(options))), row["doc_id"], row["model"], row["fields"]]
        )
    }

    /// `options` without `keys`.
    static func removing(_ options: [String: JSONValue], _ keys: String...) -> [String: JSONValue] {
        options.filter { !keys.contains($0.key) }
    }

    /// The vector family's drop half, in the cache's transaction: an entry's
    /// flat table stands while it is held as its options ask (the same
    /// distance, dims and element) and the entry is not declined; its ANN
    /// table while its model is still the index's (``annCurrent(_:_:)``);
    /// every table and trigger of the family no entry keeps is dropped, and a
    /// kept table's triggers are written again when they are not the ones its
    /// mode wants (flat only, or flat and ANN). Answers how many were dropped
    /// (a flat table dropped to be rebuilt is not counted).
    static func dropUnwantedVectors(_ sql: RecordLogSql, _ deviceIndexes: Db3DeviceIndexes) throws -> Int {
        let triggers = try vectorTriggers(sql)
        let rows = try cachedRows(sql, "WHERE i.kind = 'vector'")
        let tables = try vectorTables(sql)
        if tables.isEmpty && triggers.isEmpty && rows.allSatisfy({ $0["vector"].isNull }) { return 0 }
        var keptTables = Set<String>()
        var keptTriggers = Set<String>()
        var rebuilt = Set<String>()
        for row in rows {
            guard let flat = row["vector"].stringValue else { continue }
            var options = optionsOf(row)
            let declined = disposition(row, deviceIndexes) == .decline
            if declined || !tables.contains(flat) || !flatCurrent(options) || keptTables.contains(flat) {
                if !declined { rebuilt.insert(flat) }
                try writeVectorOptions(sql, row, removing(options, "flat", "ann", "fill", "training"), nil)
                continue
            }
            keptTables.insert(flat)
            let ann = RecordLogVectorIndex.annTable(flat)
            if options["ann"] != nil && annCurrent(row, options) && tables.contains(ann) {
                keptTables.insert(ann)
            } else if options["ann"] != nil || options["fill"] != nil {
                options = removing(options, "ann", "fill")
                try writeVectorOptions(sql, row, options, flat)
            }
            guard let vector = RecordLogVectorOptions(cached: options["vector"]) else { continue }
            let bodies = RecordLogVectorIndex.triggersDDL(keptTables.contains(ann) ? [flat, ann] : [flat], vectorTarget(row, vector))
            for (suffix, body) in zip(triggerSuffixesOfVectors, bodies) {
                let name = "\(flat)\(suffix)"
                keptTriggers.insert(name)
                if triggers[name] == body { continue }
                try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(RecordLogVectorIndex.quoted(name))")
                try sql.connection.executeScript(body)
            }
        }
        var dropped = 0
        for trigger in triggers.keys.sorted() where !keptTriggers.contains(trigger) {
            try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(RecordLogVectorIndex.quoted(trigger))")
        }
        for table in tables.sorted() where !keptTables.contains(table) {
            try sql.connection.executeScript("DROP TABLE IF EXISTS \(RecordLogVectorIndex.quoted(table))")
            let isAnn = table.hasSuffix("_ann") && tables.contains(String(table.dropLast(4)))
            if !isAnn && !rebuilt.contains(table) { dropped += 1 }
        }
        return dropped
    }

    /// The vector family's build half for one entry with no table: its flat
    /// table (vec1, `flat`, the index's distance), filled from the view
    /// through `record_log_vec_f32`, its three triggers and its pointer, in a
    /// transaction of its own. An entry the room's list gives no options for
    /// is kept unbuilt with why; a build that fails likewise, and is tried
    /// again at the next sync. Answers whether it built one.
    static func buildVector(
        _ row: Format2SqlRow, logger: Logger?, transaction: ((RecordLogSql) throws -> Void) throws -> Void
    ) throws -> Bool {
        let options = optionsOf(row)
        // Placed on the server only, a synced db3's entry has no table.
        if options["on"]?.stringValue == Db3IndexPlacement.server.rawValue && row["local_only"].intValue != 1 { return false }
        guard let vector = RecordLogVectorOptions(cached: options["vector"]) else {
            record(reason: RecordLogVectorOptions.unbuiltReason(cached: options["unbuilt"]?.stringValue), kind: "vector", logger: logger, transaction: transaction, rows: { _ in [row] })
            return false
        }
        let documentId = row["doc_id"].stringValue ?? ""
        let model = row["model"].stringValue ?? ""
        let target = vectorTarget(row, vector)
        let started = Date()
        var rows = 0
        do {
            try transaction { sql in
                let table = try deviceTable(
                    sql, key: vectorKey(model, target.field),
                    canonical: RecordLogVectorIndex.tableName(documentId: documentId, model: model, field: target.field), previous: [:]
                )
                try sql.connection.executeScript(RecordLogVectorIndex.tableDDL(table))
                try sql.exec(
                    "INSERT INTO \(RecordLogVectorIndex.quoted(table)) (cmd, arg) VALUES ('rebuild', ?)",
                    [.text(RecordLogVectorIndex.flatRebuildArg(vector.distance))]
                )
                try sql.exec(
                    "INSERT INTO \(RecordLogVectorIndex.quoted(table)) (rowid, vector) \(RecordLogVectorIndex.fillSQL(target))",
                    [.text(documentId), .text(model)]
                )
                for statement in RecordLogVectorIndex.triggersDDL([table], target) { try sql.connection.executeScript(statement) }
                rows = try sql.first("SELECT COUNT(*) AS n FROM \(RecordLogVectorIndex.quoted(table))")?["n"].intValue ?? 0
                var kept = removing(options, "unbuilt", "ann", "fill", "training")
                kept["flat"] = ["distance": .string(vector.distance), "dims": .number(Double(vector.dims)), "element": .string(vector.element.rawValue)]
                try writeVectorOptions(sql, row, kept, table)
                // The engine's vec1, which every model it installs is checked against, read once.
                _ = try RecordLogVectorIndex.engineVec1Version(sql)
            }
        } catch {
            record(
                reason: "the vector index could not be built: \(message(error))", kind: "vector", logger: logger, transaction: transaction,
                rows: { _ in [row] }
            )
            return false
        }
        let ms = Date().timeIntervalSince(started) * 1000
        logger?.log(
            "[record-log] \(documentId): vector index \(row["room_name"].stringValue ?? "") on \(model).\(target.field) built from \(rows) rows in \(String(format: "%.1f", ms)) ms."
        )
        return true
    }

    /// Drop a vector index's triggers, then its flat and ANN tables.
    static func dropVectorTables(_ sql: RecordLogSql, _ flat: String) throws {
        for suffix in triggerSuffixesOfVectors {
            try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(RecordLogVectorIndex.quoted("\(flat)\(suffix)"))")
        }
        try sql.connection.executeScript("DROP TABLE IF EXISTS \(RecordLogVectorIndex.quoted(RecordLogVectorIndex.annTable(flat)))")
        try sql.connection.executeScript("DROP TABLE IF EXISTS \(RecordLogVectorIndex.quoted(flat))")
    }

    /// Every cached vector entry of `documentId`, with its device's verdict and the db3's local-only mark.
    static func cachedVectorRows(_ sql: RecordLogSql, documentId: String) throws -> [Format2SqlRow] {
        try cachedRows(sql, "WHERE i.doc_id = ? AND i.kind = 'vector'", [.text(documentId)])
    }

    /// `documentId`'s vector index on `model.field`, as its cached row names
    /// it, with this device's verdict on it read in the same statement, or
    /// `nil` when the cache holds none. js-bao's `recordLogVectorIndexOf`.
    static func vectorIndex(
        _ sql: RecordLogSql, documentId: String, model: String, field: String, deviceIndexes: Db3DeviceIndexes = .all
    ) throws -> RecordLogVectorIndexOf? {
        guard let row = try cachedRows(
            sql, "WHERE i.doc_id = ? AND i.model = ? AND i.fields = ? AND i.kind = 'vector'",
            [.text(documentId), .text(model), .text(RecordLogJSON.text(.array([.string(field)])))]
        ).first else { return nil }
        let options = optionsOf(row)
        let pointer = row["vector"].stringValue
        var present = Set<String>()
        if let pointer {
            present = Set(try sql.rows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)", [.text(pointer), .text(RecordLogVectorIndex.annTable(pointer))]
            ).compactMap { $0["name"].stringValue })
        }
        let unbuilt = options["unbuilt"]?.stringValue
        let table = pointer.flatMap { unbuilt == nil && present.contains($0) ? $0 : nil }
        let declined: String?
        switch disposition(row, deviceIndexes) {
        case .decline: declined = declinedHere
        case .keep where table == nil: declined = excludedByOption(.vector)
        default: declined = nil
        }
        let ann = table.map(RecordLogVectorIndex.annTable)
        return RecordLogVectorIndexOf(
            table: table,
            annTable: ann.flatMap { options["ann"] != nil && options["fill"] == nil && present.contains($0) ? $0 : nil },
            vector: RecordLogVectorOptions(cached: options["vector"]), roomName: row["room_name"].stringValue ?? "", declined: declined,
            unbuilt: unbuilt
        )
    }
}
