import Foundation
@testable import JsBaoClient

/// #5223 — the "equals a rebuild from the view" oracle for a device store's
/// text indexes and member tables, the Swift port of
/// `tests/helpers/db3-device-index-oracle-5222.ts`, over any provider a
/// store runs on (the test's own, or a copy of a live client's file).
///
/// A text index is compared with a scratch FTS5 table of the same
/// definition, filled from the view's rows of its db3 and model: for every
/// term either table's vocabulary holds, the rowids `MATCH` finds agree, each
/// with the same `-bm25` score to 1e-9 (#5309, as the JS oracle has since
/// #5224), and every rowid the index finds is a view row of that db3 and
/// model. A member
/// table is compared with the members of the view's arrays.
enum Db3DeviceIndexOracle {

    /// A cached text entry of the store.
    struct TextIndex {
        var documentId: String
        var model: String
        var fields: [String]
        var table: String
        var options: JSONValue
    }

    /// A cached member entry of the store.
    struct MemberTable {
        var documentId: String
        var model: String
        var field: String
        var table: String
    }

    private static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func parse(_ text: String?) -> JSONValue? {
        text.flatMap(RecordLogJSON.parse)
    }

    /// Every text entry the store's cache names a table for.
    static func textIndexes(_ connection: any Format2SqlConnection) throws -> [TextIndex] {
        try connection.query(
            "SELECT doc_id, model, fields, text, options FROM record_log_indexes WHERE kind = 'text' AND text IS NOT NULL ORDER BY doc_id, model", []
        ).map { row in
            TextIndex(
                documentId: row["doc_id"].stringValue ?? "", model: row["model"].stringValue ?? "",
                fields: parse(row["fields"].stringValue)?.arrayValue?.compactMap(\.stringValue) ?? [],
                table: row["text"].stringValue ?? "", options: parse(row["options"].stringValue) ?? .null
            )
        }
    }

    private static func rowids(_ connection: any Format2SqlConnection, _ table: String, _ term: String) throws -> [Int] {
        try connection.query(
            "SELECT rowid FROM \(quote(table)) WHERE \(quote(table)) MATCH ? ORDER BY rowid",
            [.text("\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"")]
        ).compactMap { $0["rowid"].intValue }
    }

    /// Each rowid `MATCH` finds for `term`, with its `-bm25` score, by rowid.
    private static func scored(_ connection: any Format2SqlConnection, _ table: String, _ term: String) throws -> [(rowid: Int, score: Double)] {
        try connection.query(
            "SELECT rowid, -bm25(\(quote(table))) AS score FROM \(quote(table)) WHERE \(quote(table)) MATCH ? ORDER BY rowid",
            [.text("\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"")]
        ).map { row in
            let score: Double
            switch row["score"] {
            case .real(let value): score = value
            case .integer(let value): score = Double(value)
            default: score = .nan
            }
            return (row["rowid"].intValue ?? 0, score)
        }
    }

    /// Whether two scored answers name the same rowids with scores equal to 1e-9.
    private static func sameScores(_ a: [(rowid: Int, score: Double)], _ b: [(rowid: Int, score: Double)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.rowid == $1.rowid && abs($0.score - $1.score) <= 1e-9 }
    }

    /// `index` compared with a rebuild: the terms whose rowids differ, those
    /// whose rowids agree but whose scores do not, the rowids found outside
    /// the view, and the number of terms read. The scratch tables are dropped
    /// before it answers.
    static func textIndexDrift(
        _ connection: any Format2SqlConnection, _ index: TextIndex
    ) throws -> (
        terms: Int, differing: [(term: String, index: [Int], rebuilt: [Int])],
        misranked: [(term: String, index: [(rowid: Int, score: Double)], rebuilt: [(rowid: Int, score: Double)])], outside: [Int]
    ) {
        guard let master = try connection.query(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(index.table)]
        ).first?["sql"].stringValue else {
            throw JsBaoError(code: .invalidArgument, message: "no table \(index.table)")
        }
        let scratch = "oracle_5223_\(UUID().uuidString.prefix(8).lowercased())"
        let definition = master.replacingOccurrences(
            of: #"^CREATE VIRTUAL TABLE\s+("(?:[^"]|"")*"|\S+)"#, with: "CREATE VIRTUAL TABLE \(quote(scratch))",
            options: [.regularExpression, .caseInsensitive]
        )
        try connection.executeScript(definition)
        defer {
            for table in ["\(scratch)_iv", "\(scratch)_v", scratch] { try? connection.executeScript("DROP TABLE IF EXISTS \(quote(table))") }
        }
        let columns = index.fields.indices.map { "f\($0)" }
        let values = index.fields.map { field in
            "CASE WHEN json_type(_data, '$.\(field)') = 'text' THEN json_extract(_data, '$.\(field)') END"
        }
        try connection.execute(
            "INSERT INTO \(quote(scratch)) (rowid, \(columns.joined(separator: ", "))) SELECT rowid, \(values.joined(separator: ", ")) "
                + "FROM record_log_view WHERE doc_id = ? AND _type = ?",
            [.text(index.documentId), .text(index.model)]
        )
        try connection.executeScript("CREATE VIRTUAL TABLE \(quote("\(scratch)_v")) USING fts5vocab(\(quote(scratch)), 'row')")
        try connection.executeScript("CREATE VIRTUAL TABLE \(quote("\(scratch)_iv")) USING fts5vocab(\(quote(index.table)), 'row')")
        var terms = Set<String>()
        for table in ["\(scratch)_v", "\(scratch)_iv"] {
            for row in try connection.query("SELECT term FROM \(quote(table))", []) {
                if let term = row["term"].stringValue { terms.insert(term) }
            }
        }
        let view = Set(try connection.query(
            "SELECT rowid FROM record_log_view WHERE doc_id = ? AND _type = ?", [.text(index.documentId), .text(index.model)]
        ).compactMap { $0["rowid"].intValue })
        var differing: [(term: String, index: [Int], rebuilt: [Int])] = []
        var misranked: [(term: String, index: [(rowid: Int, score: Double)], rebuilt: [(rowid: Int, score: Double)])] = []
        var outside = Set<Int>()
        for term in terms.sorted() {
            let found = try rowids(connection, index.table, term)
            let rebuilt = try rowids(connection, scratch, term)
            if found != rebuilt {
                differing.append((term, found, rebuilt))
            } else {
                let (held, fresh) = (try scored(connection, index.table, term), try scored(connection, scratch, term))
                if !sameScores(held, fresh) { misranked.append((term, held, fresh)) }
            }
            for rowid in found where !view.contains(rowid) { outside.insert(rowid) }
        }
        return (terms.count, differing, misranked, outside.sorted())
    }

    /// Every member entry the store's cache names.
    static func memberTables(_ connection: any Format2SqlConnection) throws -> [MemberTable] {
        try connection.query(
            "SELECT doc_id, model, fields, members FROM record_log_indexes WHERE members IS NOT NULL ORDER BY doc_id, model, fields", []
        ).map { row in
            MemberTable(
                documentId: row["doc_id"].stringValue ?? "", model: row["model"].stringValue ?? "",
                field: parse(row["fields"].stringValue)?.arrayValue?.first?.stringValue ?? "",
                table: row["members"].stringValue ?? ""
            )
        }
    }

    /// A member table's rows and the members of the view's arrays it must equal, both `value\0rid` sorted.
    static func memberTableDrift(_ connection: any Format2SqlConnection, _ entry: MemberTable) throws -> (held: [String], truth: [String]) {
        let key = { (rows: [Format2SqlRow]) in rows.map { "\($0["value"].stringValue ?? "")\u{0}\($0["rid"].intValue ?? 0)" }.sorted() }
        let held = key(try connection.query("SELECT value, rid FROM \(quote(entry.table))", []))
        let path = Format2SqlValue.text("$.\(entry.field)")
        let truth = key(try connection.query(
            """
            SELECT DISTINCT m.value AS value, v.rowid AS rid FROM record_log_view v, json_each(v._data, ?) m
             WHERE v.doc_id = ? AND v._type = ? AND json_type(v._data, ?) = 'array' AND m.type = 'text'
            """,
            [path, .text(entry.documentId), .text(entry.model), path]
        ))
        return (held, truth)
    }

    /// A cached vector entry of the store with its flat table, and its ANN
    /// table when one is installed and filled (#5230).
    struct VectorIndex {
        var documentId: String
        var model: String
        var field: String
        var element: String
        var dims: Int
        var table: String
        var ann: String?
    }

    /// Every vector entry the store's cache names a flat table for.
    static func vectorIndexes(_ connection: any Format2SqlConnection) throws -> [VectorIndex] {
        // A store from before version 9 holds no vector table.
        guard try !connection.query("SELECT 1 AS present FROM pragma_table_info('record_log_indexes') WHERE name = 'vector'", []).isEmpty else { return [] }
        let tables = Set(try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'", []).compactMap { $0["name"].stringValue })
        return try connection.query(
            "SELECT doc_id, model, fields, vector, options FROM record_log_indexes WHERE kind = 'vector' AND vector IS NOT NULL ORDER BY doc_id, model, fields", []
        ).compactMap { row in
            let options = parse(row["options"].stringValue)
            guard let table = row["vector"].stringValue, let vector = options?["vector"],
                  let element = vector["element"]?.stringValue, let dims = vector["dims"]?.numberValue
            else { return nil }
            let ann = "\(table)_ann"
            // A fill under way holds part of the flat table's rows by design: only a finished ANN table is compared.
            let filled = options?["ann"] != nil && options?["fill"] == nil && tables.contains(ann)
            return VectorIndex(
                documentId: row["doc_id"].stringValue ?? "", model: row["model"].stringValue ?? "",
                field: parse(row["fields"].stringValue)?.arrayValue?.first?.stringValue ?? "", element: element, dims: Int(dims),
                table: table, ann: filled ? ann : nil
            )
        }
    }

    private static func vectorsOf(_ connection: any Format2SqlConnection, _ table: String) throws -> [Int: Data] {
        var out: [Int: Data] = [:]
        for row in try connection.query("SELECT rowid, vector FROM \(quote(table))", []) {
            if let rowid = row["rowid"].intValue, case .blob(let bytes) = row["vector"] { out[rowid] = bytes }
        }
        return out
    }

    /// `index` compared with a rebuild (F-5230-003): the flat table's rowids
    /// and vector bytes against the view's values through
    /// `record_log_vec_f32`, and an installed ANN table's rowids and vector
    /// bytes against the flat table's, so a stale ANN vector under a kept
    /// rowid is named. Empty when both equal.
    static func vectorTableDrift(_ connection: any Format2SqlConnection, _ index: VectorIndex) throws -> [String] {
        var truth: [Int: Data] = [:]
        for row in try connection.query(
            """
            SELECT rowid, record_log_vec_f32(json_extract(_data, ?), ?, ?) AS v FROM record_log_view WHERE doc_id = ? AND _type = ?
            """,
            [.text("$.\(index.field)"), .text(index.element), .integer(Int64(index.dims)), .text(index.documentId), .text(index.model)]
        ) {
            if let rowid = row["rowid"].intValue, case .blob(let bytes) = row["v"] { truth[rowid] = bytes }
        }
        var problems: [String] = []
        let compare = { (label: String, held: [Int: Data], expected: [Int: Data]) in
            let missing = expected.keys.filter { held[$0] == nil }.sorted()
            let stray = held.keys.filter { expected[$0] == nil }.sorted()
            let differing = expected.keys.filter { held[$0] != nil && held[$0] != expected[$0] }.sorted()
            if !missing.isEmpty { problems.append("\(label): rowids missing \(missing.prefix(10))") }
            if !stray.isEmpty { problems.append("\(label): stray rowids \(stray.prefix(10))") }
            if !differing.isEmpty { problems.append("\(label): vectors differ under rowids \(differing.prefix(10))") }
        }
        let flat = try vectorsOf(connection, index.table)
        compare(index.table, flat, truth)
        if let ann = index.ann { compare(ann, try vectorsOf(connection, ann), flat) }
        return problems
    }

    /// Every device index the store's cache names, compared with a rebuild:
    /// empty when each text index, member table and vector table equals the view.
    static func drift(_ connection: any Format2SqlConnection) throws -> [String] {
        var problems: [String] = []
        for index in try vectorIndexes(connection) { problems += try vectorTableDrift(connection, index) }
        for index in try textIndexes(connection) {
            let drift = try textIndexDrift(connection, index)
            if !drift.differing.isEmpty {
                problems.append("\(index.table): \(drift.differing.prefix(5).map { "\($0.term) \($0.index) != \($0.rebuilt)" })")
            }
            if !drift.misranked.isEmpty {
                problems.append("\(index.table): scores differ from a rebuild \(drift.misranked.prefix(5).map { "\($0.term) \($0.index) != \($0.rebuilt)" })")
            }
            if !drift.outside.isEmpty { problems.append("\(index.table): rowids outside the view \(drift.outside.prefix(10))") }
        }
        for entry in try memberTables(connection) {
            let (held, truth) = try memberTableDrift(connection, entry)
            if held != truth { problems.append("\(entry.table): \(held.count) member rows, \(truth.count) in the view") }
        }
        return problems
    }

    /// ``drift(_:)`` on `provider`'s connection.
    static func drift(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection { try drift($0) }
    }
}

/// db3 stores on one file-backed provider, for the device-index suites
/// (#5223): a synced db3's rows seeded as the room's results for another
/// writer's entries, a local-only db3's committed by the store itself.
final class Db3DeviceIndexWorld {

    let provider: SQLiteStorageProvider
    let directory: String
    let logger: Logger?
    private(set) var stores: [String: (store: RecordLogStore, writer: String)] = [:]

    private init(provider: SQLiteStorageProvider, directory: String, logger: Logger?) {
        self.provider = provider
        self.directory = directory
        self.logger = logger
    }

    /// A fresh provider on its own file. Remove it with ``remove()``.
    static func make(_ label: String, logger: Logger? = nil) async throws -> Db3DeviceIndexWorld {
        let directory = NSTemporaryDirectory() + "/db3-device-index-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return Db3DeviceIndexWorld(provider: provider, directory: directory, logger: logger)
    }

    func remove() { try? FileManager.default.removeItem(atPath: directory) }

    /// A world over a provider another fixture opened, sharing its file (#5230); its owner removes the file.
    static func over(_ provider: SQLiteStorageProvider, directory: String, logger: Logger? = nil) async throws -> Db3DeviceIndexWorld {
        Db3DeviceIndexWorld(provider: provider, directory: directory, logger: logger)
    }

    /// `documentId`'s store, opened and its writer minted on first use;
    /// marked local-only when `localOnly`, with `constraints` declared.
    @discardableResult
    func store(_ documentId: String, localOnly: Bool = false, constraints: [RecordLogConstraint]? = nil) throws -> RecordLogStore {
        if let held = stores[documentId] { return held.store }
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1", logger: logger)
        try store.initialize()
        let writer = try store.mintWriter()
        _ = try store.setState(writer: writer, constraints: constraints, localOnly: localOnly ? true : nil)
        stores[documentId] = (store, writer)
        return store
    }

    func writer(_ documentId: String) -> String { stores[documentId]?.writer ?? "" }

    /// A new store object over `documentId`'s rows on the same file, as a restarted client opens it.
    func reopen(_ documentId: String) throws -> RecordLogStore {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1", logger: logger)
        try store.initialize()
        if let writer = try store.writer() { stores[documentId] = (store, writer) }
        return store
    }

    /// Write `rows` of `model` into synced `documentId` as the room's results
    /// for another writer's entries, one entry per row.
    @discardableResult
    func seed(_ documentId: String, _ model: String, _ rows: [JSONValue]) throws -> RecordLogChangeReply {
        let store = try store(documentId)
        var next = try store.marks().cursor
        var items: [RecordLogResultItem] = []
        for row in rows {
            next += 1
            let id = row["id"]?.stringValue ?? ""
            items.append(.result(RecordLogResult(l: next, e: 1, changes: [RecordLogChange(model: model, id: id, row: row.objectValue)])))
        }
        return try store.receive(writer: writer(documentId), items: items)
    }

    /// Delete `ids` of `model` in synced `documentId` as the room's results.
    @discardableResult
    func seedDeletes(_ documentId: String, _ model: String, _ ids: [String]) throws -> RecordLogChangeReply {
        let store = try store(documentId)
        var next = try store.marks().cursor
        var items: [RecordLogResultItem] = []
        for id in ids {
            next += 1
            items.append(.result(RecordLogResult(l: next, e: 1, changes: [RecordLogChange(model: model, id: id, gone: true)])))
        }
        return try store.receive(writer: writer(documentId), items: items)
    }

    /// Commit `mutations` through `documentId`'s store, one write each, and flush.
    @discardableResult
    func commit(_ documentId: String, _ mutations: [RecordLogMutation], upsertOn: String? = nil) throws -> RecordLogCommitReply {
        let reply = try store(documentId).commitEntries(
            writer: writer(documentId), writes: mutations.map { RecordLogWrite(mutations: [$0], upsertOn: upsertOn) }
        )
        try store(documentId).flush()
        return reply
    }

    func rows(_ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try provider.withConnection { try $0.query(sql, bindings) }
    }

    func exec(_ sql: String, _ bindings: [Format2SqlValue] = []) throws {
        try provider.withConnection { try $0.execute(sql, bindings) }
    }

    /// The drift the oracle finds over every device index of the file.
    func drift() throws -> [String] { try Db3DeviceIndexOracle.drift(provider) }

    /// `sqlite_master`'s objects but the index cache and its key, as `type name sql`.
    func objects() throws -> [String] {
        try rows(
            """
            SELECT type, name, sql FROM sqlite_master WHERE name <> 'record_log_indexes'
               AND name NOT LIKE 'sqlite_autoindex_record_log_indexes%' AND name NOT LIKE 'sqlite_stat%' ORDER BY type, name
            """
        ).map { "\($0["type"].stringValue ?? "") \($0["name"].stringValue ?? "") \($0["sql"].stringValue ?? "")" }
    }

    /// The store's version, as `record_log_meta` holds it.
    func version() throws -> String? {
        try rows("SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue
    }

    /// The index cache as storage version 5 created it (#5156); version 4's lacks `members`.
    static func indexCache(version: Int) -> String {
        """
        CREATE TABLE record_log_indexes (
          doc_id TEXT NOT NULL,
          model TEXT NOT NULL,
          fields TEXT NOT NULL,
          is_unique INTEGER NOT NULL DEFAULT 0,
          room_name TEXT,\(version >= 5 ? "\n  members TEXT," : "")
          PRIMARY KEY (doc_id, model, fields)
        )
        """
    }

    /// Plant the file's index cache back at storage `version` (4 or 5): the
    /// cache rebuilt in that version's shape with its rows, and the version
    /// written. Every other object is left as it is.
    func plantIndexCache(version: Int) throws {
        try provider.withConnection { connection in
            let cached = try connection.query("SELECT * FROM record_log_indexes", [])
            try connection.executeScript("DROP TABLE record_log_indexes")
            try connection.executeScript(Self.indexCache(version: version))
            for row in cached {
                if version >= 5 {
                    try connection.execute(
                        "INSERT INTO record_log_indexes (doc_id, model, fields, is_unique, room_name, members) VALUES (?, ?, ?, ?, ?, ?)",
                        [row["doc_id"], row["model"], row["fields"], row["is_unique"], row["room_name"], row["members"]]
                    )
                } else {
                    try connection.execute(
                        "INSERT INTO record_log_indexes (doc_id, model, fields, is_unique, room_name) VALUES (?, ?, ?, ?, ?)",
                        [row["doc_id"], row["model"], row["fields"], row["is_unique"], row["room_name"]]
                    )
                }
            }
            try connection.execute("UPDATE record_log_meta SET value = ? WHERE key = 'storage_version'", [.text(String(version))])
        }
    }
}

extension Db3DeviceIndexOracle {
    /// The drift the oracle finds on a copy of `store`'s file (`VACUUM INTO`,
    /// its WAL folded in), so its scratch tables never touch a live client's
    /// store. The copy is removed before it answers.
    static func driftOnACopy(_ store: RecordLogStore) async throws -> [String] {
        let directory = NSTemporaryDirectory() + "/db3-oracle-copy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let copy = directory + "/store.sqlite"
        try store.flush()
        // On the store's connection itself: `VACUUM` refuses to run inside a
        // transaction, and `readView` is one read transaction (#5221).
        let vacuum = { (connection: any Format2SqlConnection) in
            try connection.executeScript("VACUUM INTO \(RecordLogSchema.quoteLiteral(copy))")
        }
        if let host = store.host as? any RecordLogGroupCommitHost {
            try host.withRecordLogConnection(vacuum)
        } else {
            try store.host.withConnection(vacuum)
        }
        let provider = SQLiteStorageProvider(path: copy)
        try await provider.initialize(namespace: "oracle")
        defer { Task { await provider.close() } }
        return try drift(provider)
    }
}
