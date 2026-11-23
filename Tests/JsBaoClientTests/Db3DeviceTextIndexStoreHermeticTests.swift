import XCTest
@testable import JsBaoClient

/// #5223 behavior 3 and edge cases E7, E12 — the Swift store's storage
/// version 6, js-bao's 6: `record_log_indexes` is rebuilt keyed `(doc_id,
/// model, fields, kind)`, `kind` backfilled `members` where `members` is set
/// and `scalar` otherwise, `text` and `options` NULL, in the open's first
/// transaction after the columns of versions 4 and 5 were added; the view
/// indexes, member tables and triggers are left as they were.
final class Db3StorageVersion6HermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world() async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("storage-6")
        worlds.append(world)
        return world
    }

    private static let slug = RecordLogIndexEntry(name: "idx_records_note_slug", model: "Note", fields: ["slug"], unique: true)
    private static let title = RecordLogIndexEntry(name: "idx_records_note_title", model: "Note", fields: ["title"], unique: false)
    private static let tags = RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true)

    private func columns(_ world: Db3DeviceIndexWorld) throws -> [String] {
        try world.rows("SELECT name, pk FROM pragma_table_info('record_log_indexes') ORDER BY cid")
            .map { "\($0["name"].stringValue ?? "") \($0["pk"].intValue ?? 0)" }
    }

    private func cache(_ world: Db3DeviceIndexWorld) throws -> [String] {
        try world.rows(
            "SELECT doc_id, model, fields, kind, is_unique, room_name, members, text, options FROM record_log_indexes ORDER BY doc_id, fields"
        ).map { row in
            ["doc_id", "model", "fields", "kind", "is_unique", "room_name", "members", "text", "options"].map { column in
                let value = row[column]
                if value.isNull { return "NULL" }
                return value.stringValue ?? value.intValue.map(String.init) ?? "?"
            }.joined(separator: " ")
        }
    }

    /// A synced db3 with a scalar and a unique view index, and a local-only
    /// db3 with a member table, on one file.
    private func populated(_ world: Db3DeviceIndexWorld) throws {
        try world.store("db3-synced")
        try world.seed("db3-synced", "Note", [["id": "r1", "slug": "a", "title": "one"], ["id": "r2", "slug": "b", "title": "two"]])
        try world.store("db3-synced").syncIndexes([Self.slug, Self.title])
        try world.store("db3-local", localOnly: true)
        try world.commit("db3-local", [
            RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["tags": ["a", "b"]]),
            RecordLogMutation(model: "Note", id: "r2", kind: .create, fields: ["tags": ["b"]]),
        ])
        try world.store("db3-local").syncIndexes([Self.tags])
    }

    /// Version 6's columns, and `vector` that version 9 adds (#5230).
    private static let version6Columns = [
        "doc_id 1", "model 2", "fields 3", "kind 4", "is_unique 0", "room_name 0", "members 0", "text 0", "options 0", "vector 0",
    ]

    func testTheVersionIs6() {
        // 6 or later: #5221 raised it to 7 for the room's head as last heard.
        XCTAssertGreaterThanOrEqual(RecordLogSchema.storageVersion, 6)
    }

    func testAStoreAt5OpensAt6KeyedByKindWithItsIndexesMemberTableAndTriggersUnchanged() async throws {
        let world = try await world()
        try populated(world)
        let synced = try world.store("db3-synced").storedState()
        let tuples = try world.store("db3-synced").indexTuples()
        try world.plantIndexCache(version: 5)
        XCTAssertEqual(try columns(world), ["doc_id 1", "model 2", "fields 3", "is_unique 0", "room_name 0", "members 0"])
        let objects = try world.objects()
        XCTAssertEqual(objects.filter { $0.hasPrefix("trigger ") }.count, 3)
        let member = Db3LocalOnlyMemberIndexStoreHermeticTests.table("db3-local")

        let reopened = try world.reopen("db3-synced")
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        XCTAssertEqual(try columns(world), Self.version6Columns)
        XCTAssertEqual(try cache(world), [
            "db3-local Note [\"tags\"] members 0 idx_members_note_tags \(member) NULL NULL",
            "db3-synced Note [\"slug\"] scalar 1 idx_records_note_slug NULL NULL NULL",
            "db3-synced Note [\"title\"] scalar 0 idx_records_note_title NULL NULL NULL",
        ])
        // The view indexes, the member table and its triggers are untouched.
        XCTAssertEqual(try world.objects(), objects)
        let after = try reopened.storedState()
        XCTAssertEqual(after.cursor, synced.cursor)
        XCTAssertEqual(after.rows, synced.rows)
        XCTAssertEqual(after.writers, synced.writers)
        XCTAssertEqual(try reopened.indexTuples(), tuples)
        let local = try world.reopen("db3-local")
        XCTAssertTrue(try local.marks().localOnly)
        XCTAssertEqual(try local.countView("Note", ["tags": ["$contains": "b"]]), 2)
        XCTAssertEqual(try local.countView("Note", ["tags": ["$contains": "a"]]), 1)
        XCTAssertEqual(try world.drift(), [])
        // A scalar and a text entry over the same fields have a row each now.
        try world.exec("INSERT INTO record_log_indexes (doc_id, model, fields, kind) VALUES ('db3-synced', 'Note', '[\"title\"]', 'text')")
        XCTAssertEqual(
            try world.rows("SELECT kind FROM record_log_indexes WHERE fields = '[\"title\"]' ORDER BY kind").compactMap { $0["kind"].stringValue },
            ["scalar", "text"]
        )
    }

    /// A store from version 1 to 4 has no `members` column: the open adds it
    /// before the copy reads it (E12), so each row reads `scalar`.
    func testAStoreAt4OpensAt6WithEveryRowScalarAndItsRowsKept() async throws {
        let world = try await world()
        try world.store("db3-synced")
        try world.seed("db3-synced", "Note", [["id": "r1", "slug": "a", "title": "one"]])
        try world.store("db3-synced").syncIndexes([Self.slug, Self.title])
        try world.store("db3-local", localOnly: true)
        try world.commit("db3-local", [RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["tags": ["a"]])])
        let synced = try world.store("db3-synced").storedState()
        let tuples = try world.store("db3-synced").indexTuples()
        try world.plantIndexCache(version: 4)
        XCTAssertEqual(try columns(world), ["doc_id 1", "model 2", "fields 3", "is_unique 0", "room_name 0"])
        let objects = try world.objects()

        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        let reopened = try world.reopen("db3-synced")
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        XCTAssertEqual(try columns(world), Self.version6Columns)
        XCTAssertEqual(try cache(world), [
            "db3-synced Note [\"slug\"] scalar 1 idx_records_note_slug NULL NULL NULL",
            "db3-synced Note [\"title\"] scalar 0 idx_records_note_title NULL NULL NULL",
        ])
        XCTAssertEqual(try world.objects(), objects)
        let after = try reopened.storedState()
        XCTAssertEqual(after.cursor, synced.cursor)
        XCTAssertEqual(after.rows, synced.rows)
        XCTAssertEqual(after.writers, synced.writers)
        XCTAssertEqual(try reopened.indexTuples(), tuples)
        XCTAssertTrue(try world.reopen("db3-local").marks().localOnly)

        // In the open's first transaction: the `members` column, then the
        // copy, then the rename, with no commit between; the version after.
        let statements = trace.statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let added = try XCTUnwrap(statements.firstIndex { $0.contains("ALTER TABLE record_log_indexes ADD COLUMN members") })
        let copied = try XCTUnwrap(statements.firstIndex { $0.hasPrefix("INSERT INTO record_log_indexes_v6") })
        let renamed = try XCTUnwrap(statements.firstIndex { $0.contains("RENAME TO record_log_indexes") })
        let versioned = try XCTUnwrap(statements.lastIndex { $0.contains("'storage_version'") && $0.hasPrefix("INSERT") })
        XCTAssertLessThan(added, copied)
        XCTAssertLessThan(copied, renamed)
        XCTAssertLessThan(renamed, versioned)
        XCTAssertFalse(statements[added...renamed].contains { $0.uppercased().hasPrefix("COMMIT") }, "\(statements[added...renamed])")
    }

    /// An open interrupted after the rename and before the version write
    /// converts nothing again (E12): the rebuild is a no-op once `kind` exists.
    func testAnOpenInterruptedBeforeTheVersionWriteConvertsNothingTwice() async throws {
        let world = try await world()
        try populated(world)
        try world.plantIndexCache(version: 5)
        _ = try world.reopen("db3-synced")
        let cached = try cache(world)
        try world.exec("UPDATE record_log_meta SET value = '5' WHERE key = 'storage_version'")
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        _ = try world.reopen("db3-synced")
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        XCTAssertEqual(try cache(world), cached)
        XCTAssertFalse(trace.statements.contains { $0.contains("record_log_indexes_v6") }, "\(trace.statements)")
    }

    /// A fresh store is created at 6 by its DDL, and a store at 6 runs no
    /// DDL at open: one version read and one probe.
    func testAFreshStoreIsCreatedAt6AndAStoreAt6RunsNoDDLAtOpen() async throws {
        let world = try await world()
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        try world.store("db3-fresh")
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        XCTAssertEqual(try columns(world), Self.version6Columns)
        XCTAssertFalse(trace.statements.contains {
            $0.contains("record_log_indexes_v6") || $0.contains("ALTER TABLE record_log_indexes") || $0.contains("DROP TABLE record_log_indexes")
        }, "\(trace.statements)")
        trace.clear()
        try RecordLogStore(host: world.provider, documentId: "db3-fresh", clientId: "client-1").initialize()
        let ran = trace.statements.filter { statement in
            !["BEGIN", "COMMIT", "ROLLBACK", "PRAGMA", "SAVEPOINT", "RELEASE"].contains {
                statement.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix($0)
            }
        }
        XCTAssertEqual(ran.count, 2, "one version read and one sqlite_master probe: \(ran)")
    }
}

/// #5223 behavior 4 — a text index's options, js-bao's
/// `parseTextIndexOptions`: filled in with the defaults (`unicode61`, no
/// prefix lengths, every field weighing 1), refused with js-bao's messages.
final class Db3TextIndexOptionsHermeticTests: XCTestCase {

    private func refusal(_ fields: [String], _ raw: JSONValue?, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try RecordLogTextIndexOptions.parse(fields: fields, raw: raw)
            XCTFail("\(String(describing: raw)) was not refused", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3IndexInvalid, file: file, line: line)
            return error.message
        } catch {
            XCTFail("threw \(error)", file: file, line: line)
        }
        return nil
    }

    func testAnEntryReadsItsTextOptionsWithTheDefaultsFilledIn() throws {
        let entry = try XCTUnwrap(RecordLogIndexEntry(json: [
            "name": "idx_text_note", "model": "Note", "fields": ["title", "body"], "unique": false, "kind": "text", "on": "device",
            "text": ["tokenizer": "porter", "weights": ["title": 3]],
        ]))
        XCTAssertEqual(entry.kind, .text)
        XCTAssertEqual(entry.on, .device)
        let options = try entry.textOptions()
        XCTAssertEqual(options.tokenizer, .porter)
        XCTAssertEqual(options.prefix, [])
        XCTAssertEqual(options.weights, ["title": 3, "body": 1])
        let bare = try XCTUnwrap(RecordLogIndexEntry(json: ["name": "t", "model": "Note", "fields": ["title"], "unique": false, "kind": "text"]))
        XCTAssertNil(bare.text)
        XCTAssertEqual(try bare.textOptions(), RecordLogTextIndexOptions(tokenizer: .unicode61, prefix: [], weights: ["title": 1]))
        XCTAssertEqual(try RecordLogTextIndexOptions.parse(fields: ["title"], raw: ["prefix": [2, 3]]).prefix, [2, 3])
    }

    func testRefusesEachInvalidOptionWithJsBaosMessage() {
        let fields = ["title", "body"]
        XCTAssertEqual(refusal(fields, "porter"), "text options must be an object: { tokenizer?, prefix?, weights? }")
        XCTAssertEqual(refusal(fields, ["stem": true]), "text.stem is not a text index option: give tokenizer, prefix or weights")
        XCTAssertEqual(refusal(fields, ["tokenizer": "trigram"]), "text.tokenizer must be one of unicode61, porter")
        XCTAssertEqual(refusal(fields, ["tokenizer": 1]), "text.tokenizer must be one of unicode61, porter")
        let prefix = "text.prefix must be at most 8 integers from 1 to 32"
        XCTAssertEqual(refusal(fields, ["prefix": [1, 2, 3, 4, 5, 6, 7, 8, 9]]), prefix)
        XCTAssertEqual(refusal(fields, ["prefix": [2.5]]), prefix)
        XCTAssertEqual(refusal(fields, ["prefix": [0]]), prefix)
        XCTAssertEqual(refusal(fields, ["prefix": [33]]), prefix)
        XCTAssertEqual(refusal(fields, ["prefix": ["2"]]), prefix)
        XCTAssertEqual(refusal(fields, ["prefix": 2]), prefix)
        XCTAssertEqual(refusal(fields, ["weights": [1]]), "text.weights must be an object of field: weight")
        XCTAssertEqual(refusal(fields, ["weights": ["summary": 2]]), "text.weights.summary names a field the index does not cover: title, body")
        for weight: JSONValue in [0, -1, "2", .null, .number(.infinity)] {
            XCTAssertEqual(refusal(fields, ["weights": ["title": weight]]), "text.weights.title must be a positive number")
        }
        XCTAssertNotNil(try? RecordLogTextIndexOptions.parse(fields: fields, raw: ["prefix": [1, 2, 3, 4, 5, 6, 7, 32]]))
        XCTAssertNotNil(try? RecordLogTextIndexOptions.parse(fields: fields, raw: ["weights": ["title": 0.5]]))
    }

    func testAFieldNamedLikeAnObjectMemberLeftOutWeighs1() throws {
        let fields = ["toString", "valueOf", "hasOwnProperty", "constructor"]
        XCTAssertEqual(try RecordLogTextIndexOptions.parse(fields: fields, raw: nil).weights,
                       ["toString": 1, "valueOf": 1, "hasOwnProperty": 1, "constructor": 1])
        XCTAssertEqual(try RecordLogTextIndexOptions.parse(fields: fields, raw: ["weights": ["valueOf": 3]]).weights,
                       ["toString": 1, "valueOf": 3, "hasOwnProperty": 1, "constructor": 1])
    }

    /// The options as the store caches them: `{tokenizer, prefix, weights, on}`, `unbuilt` when set.
    func testTheCachedOptionsRoundTripThroughTheirJSON() throws {
        var options = try RecordLogTextIndexOptions.parse(fields: ["title", "body"], raw: ["tokenizer": "porter", "prefix": [2, 3]])
        options.on = .both
        XCTAssertEqual(options.json, [
            "tokenizer": "porter", "prefix": [2, 3], "weights": ["title": 1, "body": 1], "on": "both",
        ])
        XCTAssertEqual(RecordLogTextIndexOptions(cached: options.json), options)
        options.unbuilt = "the text index could not be built: x"
        XCTAssertEqual(options.json["unbuilt"], "the text index could not be built: x")
        XCTAssertEqual(RecordLogTextIndexOptions(cached: options.json), options)
    }
}

/// Shared by the device text-index store suites (#5223).
enum Db3TextIndexFixture {
    static func textEntry(
        _ fields: [String], _ text: JSONValue? = nil, model: String = "Note", on: Db3IndexPlacement? = .device
    ) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: "idx_text_\(model.lowercased())", model: model, fields: fields, unique: false, kind: .text, on: on, text: text)
    }

    static func scalarEntry(_ field: String, model: String = "Note") -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: "idx_records_\(model.lowercased())_\(field)", model: model, fields: [field], unique: false)
    }

    /// The FTS5 table `documentId`'s text index on `model` is kept in.
    static func tableName(_ documentId: String, _ model: String = "Note") -> String {
        "idx_record_log_text_\(documentId.utf16.count)_\(documentId.lowercased())_\(model.utf16.count)_\(model.lowercased())"
    }

    /// The text family's tables and triggers, as `type:name`.
    static func textObjects(_ world: Db3DeviceIndexWorld) throws -> [String] {
        try world.rows(
            #"SELECT type, name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\' AND (type = 'trigger' OR sql LIKE 'CREATE VIRTUAL%') ORDER BY type, name"#
        ).map { "\($0["type"].stringValue ?? ""):\($0["name"].stringValue ?? "")" }
    }

    static func objectsOf(_ table: String) -> [String] {
        ["table:\(table)", "trigger:\(table)__d", "trigger:\(table)__i", "trigger:\(table)__u"]
    }

    /// The rowids `table` matches `match` with.
    static func matched(_ world: Db3DeviceIndexWorld, _ table: String, _ match: String) throws -> [Int] {
        try world.rows("SELECT rowid FROM \"\(table)\" WHERE \"\(table)\" MATCH ? ORDER BY rowid", [.text(match)]).compactMap { $0["rowid"].intValue }
    }

    /// The view rowids of `ids` of `model` in `documentId`, sorted.
    static func rowids(_ world: Db3DeviceIndexWorld, _ documentId: String, _ ids: [String], model: String = "Note") throws -> [Int] {
        try ids.compactMap { id in
            try world.rows("SELECT rowid FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id = ?", [.text(documentId), .text(model), .text(id)])
                .first?["rowid"].intValue
        }.sorted()
    }

    /// The three trigger statements of a text index over `fields`, as js-bao's
    /// `textTriggersDDL` writes them (#5224): an old row's values leave
    /// through FTS5's `'delete'` command. Sorted by name, as `sqlite_master` lists them.
    static func triggers(_ table: String, documentId: String, model: String, fields: [String]) -> [String] {
        let values = { (row: String) in
            fields.map { "CASE WHEN json_type(\(row)._data, '$.\($0)') = 'text' THEN json_extract(\(row)._data, '$.\($0)') END" }.joined(separator: ", ")
        }
        let columns = fields.indices.map { "f\($0)" }
        let insert = "INSERT INTO \"\(table)\" (\((["rowid"] + columns).joined(separator: ", "))) VALUES (NEW.rowid, \(values("NEW")))"
        let delete = "INSERT INTO \"\(table)\" (\((["\"\(table)\"", "rowid"] + columns).joined(separator: ", "))) VALUES ('delete', OLD.rowid, \(values("OLD")))"
        let scope = { (row: String) in "\(row).doc_id = '\(documentId)' AND \(row)._type = '\(model)'" }
        return [
            "CREATE TRIGGER \"\(table)__d\" AFTER DELETE ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n  \(delete);\nEND",
            "CREATE TRIGGER \"\(table)__i\" AFTER INSERT ON record_log_view WHEN \(scope("NEW"))\nBEGIN\n  \(insert);\nEND",
            "CREATE TRIGGER \"\(table)__u\" AFTER UPDATE OF _data ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n"
                + "  \(delete);\n  \(insert);\nEND",
        ]
    }

    /// #5223's table and trigger texts for a text index over `fields`
    /// (`contentless_delete=1`, rows removed by `DELETE FROM`), as that
    /// release wrote them; sorted by name, as `sqlite_master` lists them.
    static func triggers5223(_ table: String, documentId: String, model: String, fields: [String]) -> [String] {
        let values = fields.map { "CASE WHEN json_type(NEW._data, '$.\($0)') = 'text' THEN json_extract(NEW._data, '$.\($0)') END" }
        let columns = (["rowid"] + fields.indices.map { "f\($0)" }).joined(separator: ", ")
        let insert = "INSERT INTO \"\(table)\" (\(columns)) VALUES (NEW.rowid, \(values.joined(separator: ", ")))"
        let scope = { (row: String) in "\(row).doc_id = '\(documentId)' AND \(row)._type = '\(model)'" }
        return [
            "CREATE TRIGGER \"\(table)__d\" AFTER DELETE ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n  DELETE FROM \"\(table)\" WHERE rowid = OLD.rowid;\nEND",
            "CREATE TRIGGER \"\(table)__i\" AFTER INSERT ON record_log_view WHEN \(scope("NEW"))\nBEGIN\n  \(insert);\nEND",
            "CREATE TRIGGER \"\(table)__u\" AFTER UPDATE OF _data ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n"
                + "  DELETE FROM \"\(table)\" WHERE rowid = OLD.rowid;\n  \(insert);\nEND",
        ]
    }

    /// #5223's table DDL for a text index over `fields` (`tokenize` and `prefix` as given).
    static func table5223(_ table: String, fields: [String], tokenize: String = "unicode61 remove_diacritics 2", prefix: [Int] = []) -> String {
        let suffix = prefix.isEmpty ? "" : ", prefix='\(prefix.map(String.init).joined(separator: " "))'"
        return "CREATE VIRTUAL TABLE \"\(table)\" USING fts5(\(fields.indices.map { "f\($0)" }.joined(separator: ", ")), "
            + "content='', contentless_delete=1, tokenize='\(tokenize)'\(suffix))"
    }

    /// Replace `documentId`'s text family on `model` over `connection` with
    /// #5223's: the table and its three triggers dropped, the table created in
    /// #5223's DDL and filled from the view's rows, its triggers in #5223's
    /// text. js-bao's `plant5222` (#5224), for Swift.
    static func plant5223(
        _ connection: any Format2SqlConnection, _ documentId: String, model: String = "Note", fields: [String],
        tokenize: String = "unicode61 remove_diacritics 2", prefix: [Int] = [], table: String? = nil
    ) throws {
        let table = table ?? tableName(documentId, model)
        for suffix in ["__i", "__u", "__d"] { try connection.executeScript("DROP TRIGGER IF EXISTS \"\(table)\(suffix)\"") }
        try connection.executeScript("DROP TABLE IF EXISTS \"\(table)\"")
        try connection.executeScript(table5223(table, fields: fields, tokenize: tokenize, prefix: prefix))
        let values = fields.map { "CASE WHEN json_type(v._data, '$.\($0)') = 'text' THEN json_extract(v._data, '$.\($0)') END" }
        try connection.execute(
            "INSERT INTO \"\(table)\" (rowid, \(fields.indices.map { "f\($0)" }.joined(separator: ", "))) "
                + "SELECT v.rowid, \(values.joined(separator: ", ")) FROM record_log_view v WHERE v.doc_id = ? AND v._type = ?",
            [.text(documentId), .text(model)]
        )
        for statement in triggers5223(table, documentId: documentId, model: model, fields: fields) { try connection.executeScript(statement) }
    }

    /// ``plant5223(_:_:model:fields:tokenize:prefix:table:)`` on `world`'s file.
    static func plant5223(
        _ world: Db3DeviceIndexWorld, _ documentId: String, model: String = "Note", fields: [String],
        tokenize: String = "unicode61 remove_diacritics 2", prefix: [Int] = []
    ) throws {
        try world.provider.withConnection {
            try plant5223($0, documentId, model: model, fields: fields, tokenize: tokenize, prefix: prefix)
        }
    }

    /// The `sql` `sqlite_master` holds for each of `table`'s text family, table first, then its triggers by name.
    static func familySQL(_ world: Db3DeviceIndexWorld, _ table: String) throws -> [String] {
        try world.rows(
            "SELECT sql FROM sqlite_master WHERE name = ? OR (type = 'trigger' AND name IN (?, ?, ?)) ORDER BY type = 'trigger', name",
            [.text(table), .text("\(table)__d"), .text("\(table)__i"), .text("\(table)__u")]
        ).compactMap { $0["sql"].stringValue }
    }

    /// Every line a store logs while `body` runs.
    static func logged(_ body: () throws -> Void) rethrows -> [(level: LogLevel, message: String)] {
        let lines = LockedBox<[(level: LogLevel, message: String)]>([])
        Logger.lineForTest = { level, _, message in lines.withValue { $0.append((level, message)) } }
        defer { Logger.lineForTest = nil }
        try body()
        return lines.value
    }
}

/// #5223 behavior 5 and edge case E5 — `syncIndexes` on a synced db3 caches
/// a text entry placed on the device (`device`, `both`, or with no `on`) with
/// its options and builds a contentless FTS5 table per (db3, model), one
/// column per field named `f<i>`, kept by three triggers on the view, with
/// js-bao's DDL and trigger text (#5224's form, #5309); an entry placed `server`, or of kind
/// `vector`, caches and builds nothing.
final class Db3DeviceTextIndexSyncHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world() async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("text-sync", logger: Logger(level: .info))
        worlds.append(world)
        return world
    }

    private typealias F = Db3TextIndexFixture

    private func cached(_ world: Db3DeviceIndexWorld) throws -> [[String: JSONValue]] {
        try world.rows(
            "SELECT model, fields, kind, is_unique, room_name, members, text, options FROM record_log_indexes ORDER BY model, kind"
        ).map { row in
            var out: [String: JSONValue] = [:]
            for column in ["model", "fields", "kind", "room_name", "members", "text"] {
                out[column] = row[column].stringValue.map(JSONValue.string) ?? .null
            }
            out["is_unique"] = .number(Double(row["is_unique"].intValue ?? -1))
            out["options"] = row["options"].stringValue.flatMap(RecordLogJSON.parse) ?? .null
            return out
        }
    }

    func testCachesADeviceTextEntryWithItsOptionsAndBuildsAnAliasedContentlessTableWithThreeTriggers() async throws {
        let world = try await world()
        try world.store("db3-a")
        try world.seed("db3-a", "Note", [["id": "a", "title": "Red apple", "body": "crisp"], ["id": "b", "title": "pear", "body": "soft red"]])
        let lines = try F.logged {
            try world.store("db3-a").syncIndexes([
                F.textEntry(["title", "body"], ["tokenizer": "porter", "prefix": [2, 3], "weights": ["title": 2, "body": 1]]),
                F.textEntry(["title"], model: "Server", on: .server),
                F.textEntry(["title"], model: "Both", on: .both),
                F.textEntry(["title"], model: "Open", on: nil),
                RecordLogIndexEntry(name: "idx_vec_vec_embedding", model: "Vec", fields: ["embedding"], unique: false, kind: .vector, on: .device),
                F.scalarEntry("title"),
            ])
        }
        let table = F.tableName("db3-a")
        XCTAssertEqual(try cached(world), [
            ["model": "Both", "fields": "[\"title\"]", "kind": "text", "is_unique": 0, "room_name": "idx_text_both", "members": .null,
             "text": .string(F.tableName("db3-a", "Both")),
             "options": ["tokenizer": "unicode61", "prefix": [], "weights": ["title": 1], "on": "both"]],
            ["model": "Note", "fields": "[\"title\"]", "kind": "scalar", "is_unique": 0, "room_name": "idx_records_note_title", "members": .null,
             "text": .null, "options": .null],
            ["model": "Note", "fields": "[\"title\",\"body\"]", "kind": "text", "is_unique": 0, "room_name": "idx_text_note", "members": .null,
             "text": .string(table),
             "options": ["tokenizer": "porter", "prefix": [2, 3], "weights": ["title": 2, "body": 1], "on": "device"]],
            // An entry with no `on` reads `both` (E5).
            ["model": "Open", "fields": "[\"title\"]", "kind": "text", "is_unique": 0, "room_name": "idx_text_open", "members": .null,
             "text": .string(F.tableName("db3-a", "Open")),
             "options": ["tokenizer": "unicode61", "prefix": [], "weights": ["title": 1], "on": "both"]],
            // A vector entry is cached unbuilt.
            ["model": "Vec", "fields": "[\"embedding\"]", "kind": "vector", "is_unique": 0, "room_name": "idx_vec_vec_embedding", "members": .null,
             "text": .null, "options": ["on": "device", "unbuilt": .string(RecordLogIndexes.vectorUnbuilt)]],
        ])
        XCTAssertEqual(
            try world.rows("SELECT sql FROM sqlite_master WHERE name = ?", [.text(table)]).first?["sql"].stringValue,
            "CREATE VIRTUAL TABLE \"\(table)\" USING fts5(f0, f1, content='', "
                + "tokenize='porter unicode61 remove_diacritics 2', prefix='2 3')"
        )
        let triggers = try world.rows(
            "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'record_log_view' AND name LIKE ? ORDER BY name",
            [.text("\(table)%")]
        )
        XCTAssertEqual(triggers.compactMap { $0["sql"].stringValue },
                       F.triggers(table, documentId: "db3-a", model: "Note", fields: ["title", "body"]))
        XCTAssertEqual(try F.textObjects(world), (F.objectsOf(F.tableName("db3-a", "Both")) + F.objectsOf(table)
            + F.objectsOf(F.tableName("db3-a", "Open"))).sorted())
        let built = lines.filter { $0.message.contains("text index idx_text_note") }
        XCTAssertEqual(built.count, 1, "\(lines.map(\.message))")
        XCTAssertEqual(built.first?.level, .info)
        XCTAssertNotNil(built.first?.message.range(
            of: #"^\[record-log\] db3-a: text index idx_text_note on Note built from 2 rows in [0-9.]+ ms\.$"#, options: .regularExpression
        ), built.first?.message ?? "")
        XCTAssertEqual(try F.matched(world, table, "\"apple\""), try F.rowids(world, "db3-a", ["a"]))
        XCTAssertEqual(try F.matched(world, table, "\"red\""), try F.rowids(world, "db3-a", ["a", "b"]))
        XCTAssertEqual(try world.drift(), [])
        // The scalar entry alone is a view index.
        XCTAssertEqual(try world.store("db3-a").indexTuples(), [RecordLogIndexTuple(model: "Note", fields: ["title"], unique: false)])
    }

    func testKeepsAScalarAndATextEntryOverTheSameFieldAndDropsEitherAlone() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", [["id": "a", "title": "kiwi"]])
        try store.syncIndexes([F.scalarEntry("title"), F.textEntry(["title"])])
        XCTAssertEqual(try world.rows("SELECT kind FROM record_log_indexes ORDER BY kind").compactMap { $0["kind"].stringValue }, ["scalar", "text"])
        try store.syncIndexes([F.textEntry(["title"])])
        XCTAssertEqual(try store.indexTuples(), [])
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(F.tableName("db3-a")))
        XCTAssertEqual(try F.matched(world, F.tableName("db3-a"), "\"kiwi\""), try F.rowids(world, "db3-a", ["a"]))
        try store.syncIndexes([F.scalarEntry("title")])
        XCTAssertEqual(try store.indexTuples(), [RecordLogIndexTuple(model: "Note", fields: ["title"], unique: false)])
        XCTAssertEqual(try F.textObjects(world), [])
    }

    /// E5: an entry placed `server` caches and builds nothing on a synced db3; a `vector` entry is cached unbuilt and builds nothing.
    func testAServerPlacedOrVectorEntryCachesAndBuildsNothing() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", [["id": "a", "title": "kiwi", "embedding": "AAAA"]])
        try store.syncIndexes([
            F.textEntry(["title"], on: .server),
            RecordLogIndexEntry(name: "idx_vec_note_embedding", model: "Note", fields: ["embedding"], unique: false, kind: .vector, on: .device),
        ])
        let rows = try world.rows("SELECT kind, options FROM record_log_indexes")
        XCTAssertEqual(rows.map { $0["kind"].stringValue }, ["vector"])
        XCTAssertEqual(rows.first?["options"].stringValue.flatMap(RecordLogJSON.parse), ["on": "device", "unbuilt": .string(RecordLogIndexes.vectorUnbuilt)])
        XCTAssertEqual(try F.textObjects(world), [])
        XCTAssertEqual(try store.indexTuples(), [])
    }
}
