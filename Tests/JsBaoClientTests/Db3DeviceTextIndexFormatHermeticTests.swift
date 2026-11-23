import XCTest
@testable import JsBaoClient

/// #5309 behaviors 1–4 and edge cases 8–12 — a Swift device keeps a text
/// index in js-bao's form (#5224): a contentless FTS5 table with no
/// `contentless_delete`, kept by triggers that remove a row's old values
/// through FTS5's `'delete'` command. A table held in #5223's form is
/// rebuilt once at the next index sync, with no row lost; through every
/// write path the table equals a rebuild from the view, rowid for rowid and
/// `-bm25` for `-bm25`.
final class Db3DeviceTextIndexFormatHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world(_ label: String = "text-format") async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make(label, logger: Logger(level: .info))
        worlds.append(world)
        return world
    }

    private typealias F = Db3TextIndexFixture

    private static let seeded: [JSONValue] = [
        ["id": "a", "title": "Red apple pie", "body": "a sweet apple dessert"],
        ["id": "b", "title": "Green apple", "body": "tart and crisp"],
        ["id": "c", "title": "Pear tart", "body": "pears and apples baked"],
        ["id": "d", "title": "Running notes", "body": "notes about runners"],
    ]

    private static let words = ["apple", "pie", "green", "tart", "pear", "pears", "running", "notes", "runners", "sweet", "crisp"]

    /// The rowids `table` matches each of ``words`` with.
    private func matches(_ world: Db3DeviceIndexWorld, _ table: String) throws -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for word in Self.words { out[word] = try F.matched(world, table, "\"\(word)\"") }
        return out
    }

    private func builds(_ lines: [(level: LogLevel, message: String)]) -> [String] {
        lines.filter { $0.message.contains("text index") && $0.message.contains("built from") }.map(\.message)
    }

    // MARK: - 1, 2: the table and its triggers in js-bao's form

    func testTheTableAndItsTriggersTakeJsBaosFormWithNoContentlessDelete() async throws {
        let world = try await world()
        try world.store("db3-a")
        try world.seed("db3-a", "Note", Self.seeded)
        try world.store("db3-a").syncIndexes([
            F.textEntry(["title", "body"], ["tokenizer": "porter", "prefix": [2, 3], "weights": ["title": 3]]),
            F.textEntry(["title"], model: "Tag"),
        ])
        let table = F.tableName("db3-a")
        let family = try F.familySQL(world, table)
        XCTAssertEqual(family.first,
                       "CREATE VIRTUAL TABLE \"\(table)\" USING fts5(f0, f1, content='', tokenize='porter unicode61 remove_diacritics 2', prefix='2 3')")
        let tag = F.tableName("db3-a", "Tag")
        XCTAssertEqual(try F.familySQL(world, tag).first,
                       "CREATE VIRTUAL TABLE \"\(tag)\" USING fts5(f0, content='', tokenize='unicode61 remove_diacritics 2')")

        // 2: the triggers are js-bao's `textTriggersDDL`, the old values leaving through 'delete'.
        XCTAssertEqual(Array(family.dropFirst()), F.triggers(table, documentId: "db3-a", model: "Note", fields: ["title", "body"]))
        XCTAssertEqual(Array(try F.familySQL(world, tag).dropFirst()), F.triggers(tag, documentId: "db3-a", model: "Tag", fields: ["title"]))
        let deleteOld = "INSERT INTO \"\(table)\" (\"\(table)\", rowid, f0, f1) VALUES ('delete', OLD.rowid, "
            + "CASE WHEN json_type(OLD._data, '$.title') = 'text' THEN json_extract(OLD._data, '$.title') END, "
            + "CASE WHEN json_type(OLD._data, '$.body') = 'text' THEN json_extract(OLD._data, '$.body') END)"
        let triggers = Dictionary(uniqueKeysWithValues: try world.rows(
            "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE ?", [.text("\(table)__%")]
        ).map { ($0["name"].stringValue ?? "", $0["sql"].stringValue ?? "") })
        XCTAssertEqual(triggers["\(table)__u"]?.contains(deleteOld), true, triggers["\(table)__u"] ?? "")
        XCTAssertEqual(triggers["\(table)__d"]?.contains(deleteOld), true, triggers["\(table)__d"] ?? "")
        for sql in try F.familySQL(world, table) + F.familySQL(world, tag) {
            XCTAssertFalse(sql.contains("contentless_delete"), sql)
            XCTAssertFalse(sql.contains("DELETE FROM"), sql)
        }

        // The triggers keep it: a patch and a delete remove the old values.
        try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "b", kind: .patch, fields: ["title": "Green pear"])])
        try world.seedDeletes("db3-a", "Note", ["a"])
        XCTAssertEqual(try F.matched(world, table, "\"apple\""), try F.rowids(world, "db3-a", ["c"]))
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 3: a #5223 table is rebuilt once

    func testATableHeldInThe5223FormIsRebuiltOnceWithNoRowLost() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", Self.seeded)
        let entry = F.textEntry(["title", "body"], ["weights": ["title": 3]])
        try store.syncIndexes([entry])
        let table = F.tableName("db3-a")
        try F.plant5223(world, "db3-a", fields: ["title", "body"])
        XCTAssertEqual(try F.familySQL(world, table).first, F.table5223(table, fields: ["title", "body"]))
        let before = try matches(world, table)
        XCTAssertEqual(before["apple"]?.count, 2)

        var sync = RecordLogIndexSync(created: -1, dropped: -1)
        let lines = try F.logged { sync = try store.syncIndexes(nil) }
        XCTAssertEqual(sync, RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(table))
        let family = try F.familySQL(world, table)
        XCTAssertEqual(family.first, "CREATE VIRTUAL TABLE \"\(table)\" USING fts5(f0, f1, content='', tokenize='unicode61 remove_diacritics 2')")
        XCTAssertEqual(Array(family.dropFirst()), F.triggers(table, documentId: "db3-a", model: "Note", fields: ["title", "body"]))
        XCTAssertEqual(try matches(world, table), before, "every row the #5223 table matched is matched after the rebuild")
        XCTAssertEqual(try world.drift(), [])
        let built = builds(lines)
        XCTAssertEqual(built.count, 1, "\(lines.map(\.message))")
        XCTAssertNotNil(built.first?.range(
            of: #"^\[record-log\] db3-a: text index idx_text_note on Note built from 4 rows in [0-9.]+ ms\.$"#, options: .regularExpression
        ), built.first ?? "")

        // The sync after builds nothing and logs nothing.
        let again = try F.logged { sync = try store.syncIndexes(nil) }
        XCTAssertEqual(sync, RecordLogIndexSync(created: 0, dropped: 0))
        XCTAssertEqual(builds(again), [])

        // A store planted the same way rebuilds as well from a sync with its list.
        let other = try await self.world("text-format-list")
        let listed = try other.store("db3-a")
        try other.seed("db3-a", "Note", Self.seeded)
        try listed.syncIndexes([entry])
        try F.plant5223(other, "db3-a", fields: ["title", "body"])
        let listedBefore = try matches(other, table)
        let listedLines = try F.logged { sync = try listed.syncIndexes([entry]) }
        XCTAssertEqual(sync, RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(builds(listedLines).count, 1, "\(listedLines.map(\.message))")
        XCTAssertEqual(try F.textObjects(other), F.objectsOf(table))
        XCTAssertEqual(try F.familySQL(other, table), family)
        XCTAssertEqual(try matches(other, table), listedBefore)
        XCTAssertEqual(try other.drift(), [])
        XCTAssertEqual(try listed.syncIndexes([entry]), RecordLogIndexSync(created: 0, dropped: 0))
    }

    // MARK: - 10: two db3s on one file, one planted

    func testOnlyThePlantedDb3sTableIsRebuiltAndTheOtherKeepsItsText() async throws {
        let world = try await world()
        for documentId in ["db3-a", "db3-b"] {
            try world.store(documentId)
            try world.seed(documentId, "Note", Self.seeded)
            try world.store(documentId).syncIndexes([F.textEntry(["title"])])
        }
        let kept = try F.familySQL(world, F.tableName("db3-b"))
        XCTAssertEqual(kept.count, 4)
        try F.plant5223(world, "db3-a", fields: ["title"])
        XCTAssertEqual(try world.store("db3-a").syncIndexes(nil), RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(try F.familySQL(world, F.tableName("db3-b")), kept)
        XCTAssertEqual(try F.familySQL(world, F.tableName("db3-a")).dropFirst().map { $0.contains("DELETE FROM") }, [false, false, false])
        XCTAssertEqual(try F.textObjects(world), (F.objectsOf(F.tableName("db3-a")) + F.objectsOf(F.tableName("db3-b"))).sorted())
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 11: one #5223 trigger in a new-form family

    func testANewFormTableWhoseDeleteTriggerIsThe5223BodyIsRebuilt() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", Self.seeded)
        try store.syncIndexes([F.textEntry(["title", "body"])])
        let table = F.tableName("db3-a")
        let wanted = F.triggers(table, documentId: "db3-a", model: "Note", fields: ["title", "body"])
        try world.exec("DROP TRIGGER \"\(table)__d\"")
        try world.exec(F.triggers5223(table, documentId: "db3-a", model: "Note", fields: ["title", "body"])[0])
        XCTAssertEqual(try F.familySQL(world, table).dropFirst().first?.contains("DELETE FROM"), true)

        XCTAssertEqual(try store.syncIndexes(nil), RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(Array(try F.familySQL(world, table).dropFirst()), wanted)
        try world.seedDeletes("db3-a", "Note", ["a"])
        XCTAssertEqual(try F.matched(world, table, "\"apple\""), try F.rowids(world, "db3-a", ["b"]))
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 12: a purge drops the new-form family

    func testAPurgeDropsTheTableAndItsThreeTriggers() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", Self.seeded)
        try store.syncIndexes([F.textEntry(["title", "body"])])
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(F.tableName("db3-a")))
        XCTAssertTrue(try store.purge(force: true).purged)
        XCTAssertEqual(try world.rows(#"SELECT name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\'"#).count, 0)
    }

    // MARK: - 4, 8, 9: equal to a rebuild through every write path

    /// `store`'s answers to `search`, as `(id, _score)`.
    private func answers(_ store: RecordLogStore, _ search: JSONValue) throws -> [(id: String, score: Double)] {
        try store.queryView("Note", ["$search": search], options: QueryOptions(limit: 1_000)).data.map {
            ($0["id"]?.stringValue ?? "", $0["_score"]?.numberValue ?? .nan)
        }
    }

    private func note(_ id: String, _ fields: [String: JSONValue]) -> RecordLogCatchUpRow {
        var row = fields
        row["id"] = .string(id)
        return RecordLogCatchUpRow(model: "Note", id: id, row: row)
    }

    func testEveryWritePathKeepsTheTableEqualToARebuildScoreForScore() async throws {
        let filler = Array(repeating: "filler", count: 100).joined(separator: " ")
        for tokenizer in ["unicode61", "porter"] {
            let world = try await world("text-format-\(tokenizer)")
            let store = try world.store("db3-a")
            let writer = world.writer("db3-a")
            try store.syncIndexes([F.textEntry(["title", "body"], ["tokenizer": .string(tokenizer), "weights": ["title": 3]])])
            func rebuilt(_ step: String, file: StaticString = #filePath, line: UInt = #line) throws {
                XCTAssertEqual(try world.drift(), [], "\(tokenizer): \(step)", file: file, line: line)
            }
            try world.seed("db3-a", "Note", [
                ["id": "s1", "title": "confirmed apple", "body": "from the room"], ["id": "s2", "title": "confirmed pear", "body": "running"],
            ])
            try rebuilt("rows from the room")

            // Local creates, and the deletion fixture with its third row deleted.
            try world.commit("db3-a", [
                RecordLogMutation(model: "Note", id: "a1", kind: .create, fields: ["title": "Red apple pie", "body": "a sweet apple dessert"]),
                RecordLogMutation(model: "Note", id: "a2", kind: .create, fields: ["title": "Running notes", "body": "notes about runners"]),
            ])
            try rebuilt("local creates")
            try world.commit("db3-a", [
                RecordLogMutation(model: "Note", id: "d1", kind: .create, fields: ["title": "apple", "body": "apples running"]),
                RecordLogMutation(model: "Note", id: "d2", kind: .create, fields: ["title": "apple apple x x x x x x x x", "body": "apples running"]),
                RecordLogMutation(model: "Note", id: "d3", kind: .create, fields: ["title": .string(filler), "body": "apples running"]),
            ])
            try rebuilt("the deletion fixture")
            try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "d3", kind: .delete)])
            try rebuilt("the deletion fixture's third row deleted")
            XCTAssertEqual(try answers(store, "filler").map(\.id), [])

            // 8: a patch that sets `body` and turns `title` into a number, then a string again.
            try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "d2", kind: .patch, fields: ["body": "running late", "title": 42])])
            try rebuilt("a patch setting body and title to a number")
            XCTAssertEqual(try answers(store, "x").map(\.id), [])
            try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "d2", kind: .patch, fields: ["title": "apple x"])])
            try rebuilt("title a string again")
            XCTAssertEqual(try answers(store, "x").map(\.id), ["d2"])

            // 9: a patch of an uncovered field removes and re-adds the same values.
            let scored = try XCTUnwrap(try answers(store, "apple").first { $0.id == "d1" })
            try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "d1", kind: .patch, fields: ["rank": 7])])
            try rebuilt("a patch of an uncovered field")
            let rescored = try XCTUnwrap(try answers(store, "apple").first { $0.id == "d1" })
            XCTAssertEqual(rescored.score, scored.score, accuracy: 1e-9, tokenizer)

            // A revival of the deleted id.
            try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "d3", kind: .create, fields: ["title": "filler revived", "body": "apples"])])
            try rebuilt("a revival")
            XCTAssertEqual(try answers(store, "filler").map(\.id), ["d3"])

            // A catch-up page that creates one row and deletes another.
            let lsn = try store.marks().cursor + 10
            try store.beginCatchUp(writer: writer, full: false)
            _ = try store.applyCatchUpPage(
                writer: writer, rows: [note("c1", ["title": "caught apple", "body": "pear"])],
                gone: [RecordLogRecordKey(model: "Note", id: "s1")], lsn: lsn
            )
            _ = try store.completeCatchUp(writer: writer, lsn: lsn, at: 1)
            try rebuilt("a catch-up page creating one row and deleting another")
            XCTAssertNil(try answers(store, "confirmed").first { $0.id == "s1" })

            // A refresh load naming two ids drops the confirmed rows it does not name.
            let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "LREFRESH").attempt
            _ = try store.applyLoadChunk(writer: writer, sessionId: "LREFRESH", attempt: attempt, model: "Note", lines: [
                RecordLogLoadLine(id: "c1", patch: ["title": "caught apple again"]),
                RecordLogLoadLine(id: "l1", patch: ["title": "loaded apple", "body": "x"]),
            ])
            _ = try store.completeLoad(writer: writer, sessionId: "LREFRESH", attempt: attempt, mode: .refresh, models: ["Note"])
            try rebuilt("a refresh load naming two ids")
            XCTAssertNil(try answers(store, "confirmed").first { $0.id == "s2" })

            // The weighted answers equal those of a table built fresh from the same rows.
            let searches: [JSONValue] = ["apple", "x", "filler", "running", "\"apple pie\"", ["query": "apple pear", "mode": "any"]]
            let held = try searches.map { try answers(store, $0) }
            try world.exec("DROP TABLE \"\(F.tableName("db3-a"))\"")
            XCTAssertEqual(try store.syncIndexes(nil).created, 1)
            for (search, before) in zip(searches, held) {
                let fresh = try answers(store, search)
                let label = "\(tokenizer) \(RecordLogJSON.text(search))"
                XCTAssertEqual(before.map(\.id), fresh.map(\.id), label)
                for (a, b) in zip(before, fresh) { XCTAssertEqual(a.score, b.score, accuracy: 1e-9, "\(label) \(a.id)") }
            }
            XCTAssertFalse(held[0].isEmpty)
        }
    }
}
