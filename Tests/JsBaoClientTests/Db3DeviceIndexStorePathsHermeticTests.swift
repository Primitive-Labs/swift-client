import XCTest
@testable import JsBaoClient

/// #5223 behavior 8 and edge case E6 — every store path keeps a synced db3's
/// device text index and member table equal to a rebuild from the view (the
/// oracle after each step): local commits of every shape, catch-up pages and
/// results, a load merged then refreshed, a segment chunk with corrections
/// and its completion, a staged replacement begun over a pending guess, a
/// withdrawn guess, the bulk shape, and another model's and another db3's
/// writes; a purge drops both families of its db3 and leaves another's.
final class Db3DeviceIndexStorePathsHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private typealias F = Db3TextIndexFixture

    private static let entries = [
        F.textEntry(["title", "body"]),
        RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, kind: .members, on: .device),
    ]

    private func create(_ id: String, _ fields: [String: JSONValue], model: String = "Note") -> RecordLogMutation {
        RecordLogMutation(model: model, id: id, kind: .create, fields: fields)
    }

    private func patch(_ id: String, _ fields: [String: JSONValue?]) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: .patch, fields: fields.mapValues { $0 ?? .null })
    }

    private func note(_ id: String, _ fields: [String: JSONValue]) -> RecordLogCatchUpRow {
        var row = fields
        row["id"] = .string(id)
        return RecordLogCatchUpRow(model: "Note", id: id, row: row)
    }

    /// The ids `$search`'s MATCH of `word` finds in `documentId`'s text table, sorted.
    private func found(_ world: Db3DeviceIndexWorld, _ word: String, _ documentId: String = "db3-a") throws -> [String] {
        let table = F.tableName(documentId)
        return try world.rows(
            "SELECT _id AS id FROM record_log_view WHERE doc_id = ? AND rowid IN (SELECT rowid FROM \"\(table)\" WHERE \"\(table)\" MATCH ?) ORDER BY _id",
            [.text(documentId), .text("\"\(word)\"")]
        ).compactMap { $0["id"].stringValue }
    }

    func testEveryStorePathKeepsTheTextIndexAndMemberTableEqualToARebuild() async throws {
        let world = try await Db3DeviceIndexWorld.make("store-paths")
        worlds.append(world)
        let store = try world.store("db3-a", constraints: [RecordLogConstraint(model: "Note", name: "slug_unique", fields: ["slug"])])
        let writer = world.writer("db3-a")
        try store.syncIndexes(Self.entries)
        let other = try world.store("db3-b")
        try other.syncIndexes(Self.entries)
        func rebuilt(_ step: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try world.drift(), [], step, file: file, line: line)
        }

        // Local commits of every shape.
        try world.commit("db3-a", [create("a", ["title": "red apple", "body": "crisp", "tags": ["x", "y"], "slug": "s-a"])])
        try rebuilt("a create")
        try world.commit("db3-a", [patch("a", ["title": "green apple"])])
        try rebuilt("a patch of a covered field")
        try world.commit("db3-a", [patch("a", ["n": 5])])
        try rebuilt("a patch of another field")
        try world.commit("db3-a", [patch("a", ["title": 42])])
        try rebuilt("a covered value to a number")
        XCTAssertEqual(try found(world, "green"), [])
        try world.commit("db3-a", [patch("a", ["title": "green again"])])
        try rebuilt("and back")
        try world.commit("db3-a", [patch("a", ["body": nil])])
        try rebuilt("a field cleared")
        try world.commit("db3-a", [patch("a", ["body": ["nested": "word"]]), patch("a", ["title": ["in", "array"]])])
        try rebuilt("an object and an array")
        try world.commit("db3-a", [patch("a", ["title": "steady", "body": "steady"])])
        try world.commit("db3-a", [patch("a", ["title": "steady"])])
        try rebuilt("a write leaving _data equal")
        try world.commit("db3-a", [create("b", ["title": "pear", "slug": "s-b", "tags": ["z"]])])
        try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "b", kind: .delete)])
        try rebuilt("a delete")
        try world.commit("db3-a", [create("b", ["title": "pear revived", "slug": "s-b"])])
        try rebuilt("a revival")
        let upsert = try world.commit("db3-a", [create("u", ["slug": "s-b", "title": "upserted pear", "tags": ["w"]])], upsertOn: "slug")
        XCTAssertEqual(try store.read(model: "Note", id: "b")?["title"], "upserted pear", "\(upsert)")
        try rebuilt("an upsert landing on another record")
        try world.commit("db3-a", [patch("a", ["tags": "x"])])
        try rebuilt("a string set written as a string")
        XCTAssertEqual(try found(world, "steady"), ["a"])

        // Catch-up pages and results.
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: [note("c1", ["title": "caught one", "tags": ["q"]]), note("c2", ["title": "caught two"])], lsn: 30)
        _ = try store.completeCatchUp(writer: writer, lsn: 30, at: 1)
        try rebuilt("a catch-up page and its completion")
        try world.seed("db3-a", "Note", [["id": "c1", "title": "result one", "tags": ["r"]], ["id": "r1", "title": "result new"]])
        try rebuilt("results")

        // A load merged, then refreshed.
        for (mode, session) in [(RecordLogLoadMode.merge, "LMERGE"), (.refresh, "LREFRESH")] {
            let attempt = try store.beginReceipt(writer: writer, kind: .load, id: session).attempt
            _ = try store.applyLoadChunk(writer: writer, sessionId: session, attempt: attempt, model: "Note", lines: [
                RecordLogLoadLine(id: "l1", patch: ["title": .string("loaded \(mode.rawValue)"), "tags": ["z"]]),
                RecordLogLoadLine(id: "c2", patch: ["title": .string("two \(mode.rawValue)")]),
            ])
            try rebuilt("a \(mode.rawValue) chunk")
            _ = try store.completeLoad(writer: writer, sessionId: session, attempt: attempt, mode: mode, models: ["Note"])
            try rebuilt("a \(mode.rawValue) completion")
        }
        XCTAssertEqual(try found(world, "refresh"), ["c2", "l1"])

        // A segment chunk with corrections, and its completion.
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applySegmentChunk(writer: writer, generation: generation, rows: [note("s1", ["title": "segment one"]), note("c2", ["title": "segment two"])])
        _ = try store.applySegmentCorrections(writer: writer, generation: generation, lines: [
            RecordLogCorrection(model: "Note", id: "s2", row: ["id": "s2", "title": "corrected", "tags": ["k"]]),
        ])
        try rebuilt("a segment chunk and corrections")
        _ = try store.completeCatchUp(writer: writer, lsn: 40, full: true, generation: generation, at: 2)
        try rebuilt("the segment's completion")

        // A staged replacement begun over a pending guess, and completed.
        try world.commit("db3-a", [create("p", ["title": "pending guess", "slug": "s-p", "tags": ["g"]])])
        let staged = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertTrue(try store.storedState().staged)
        _ = try store.applySegmentChunk(writer: writer, generation: staged, rows: [note("r9", ["title": "replaced", "tags": ["n"]])])
        try rebuilt("a staged chunk")
        _ = try store.completeCatchUp(writer: writer, lsn: 50, full: true, generation: staged, at: 3)
        try rebuilt("the staged completion")
        XCTAssertEqual(try found(world, "replaced"), ["r9"])
        XCTAssertEqual(try found(world, "guess"), ["p"])

        // A withdrawn guess leaves the view, and the indexes with it.
        let pending = try XCTUnwrap(try store.pendingOf(writer).last { $0.keys.contains(RecordLogRecordKey(model: "Note", id: "p")) })
        _ = try store.refused(writer: writer, refusal: RecordLogRefusal(
            seq: pending.seq, code: "DOCUMENT_CONSTRAINT_VIOLATED", scope: .record, from: pending.seq,
            records: [RecordLogRefusedRecord(model: "Note", id: "p", from: pending.seq)]
        ))
        try rebuilt("a withdrawn guess")
        XCTAssertEqual(try found(world, "guess"), [])

        // The bulk shape: view rows deleted, then inserted again from the confirmed rows.
        try world.exec("DELETE FROM record_log_view WHERE doc_id = 'db3-a' AND _type = 'Note' AND _id IN ('r9', 's2')")
        try rebuilt("the bulk shape's delete")
        try world.exec(
            """
            INSERT INTO record_log_view (doc_id, _type, _id, _data)
              SELECT doc_id, _type, _id, _data FROM record_log_rows WHERE doc_id = 'db3-a' AND _type = 'Note' AND _id IN ('r9', 's2')
            """
        )
        try rebuilt("the bulk shape's insert")
        XCTAssertEqual(try found(world, "replaced"), ["r9"])

        // Another model's and another db3's writes leave the tables as they were.
        let text = try world.rows("SELECT rowid FROM \"\(F.tableName("db3-a"))\" WHERE \"\(F.tableName("db3-a"))\" MATCH '\"replaced\" OR \"corrected\" OR \"steady\"' ORDER BY rowid")
        let members = try world.rows("SELECT value, rid FROM \"\(Db3SyncedMemberIndexStoreHermeticTests.table("db3-a", "tags"))\" ORDER BY 1, 2")
        try world.commit("db3-a", [create("t1", ["title": "replaced", "tags": ["zz"]], model: "Tag")])
        try world.seed("db3-b", "Note", [["id": "o1", "title": "replaced elsewhere", "tags": ["zz"]]])
        XCTAssertEqual(
            try world.rows("SELECT rowid FROM \"\(F.tableName("db3-a"))\" WHERE \"\(F.tableName("db3-a"))\" MATCH '\"replaced\" OR \"corrected\" OR \"steady\"' ORDER BY rowid").map(\.columns),
            text.map(\.columns)
        )
        XCTAssertEqual(
            try world.rows("SELECT value, rid FROM \"\(Db3SyncedMemberIndexStoreHermeticTests.table("db3-a", "tags"))\" ORDER BY 1, 2").map(\.columns),
            members.map(\.columns)
        )
        try rebuilt("another model's and another db3's writes")

        // E6: a purge drops both families of its db3 and leaves another's, whose triggers still fire.
        XCTAssertTrue(try store.purge(force: true).purged)
        let left = try world.rows(
            #"SELECT name FROM sqlite_master WHERE (name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\' OR name LIKE 'idx\_record\_log\_members\_%' ESCAPE '\') AND name LIKE ? ORDER BY name"#,
            [.text("%_5_db3-a_%")]
        )
        XCTAssertEqual(left.compactMap { $0["name"].stringValue }, [])
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(F.tableName("db3-b")))
        try world.seed("db3-b", "Note", [["id": "o2", "title": "still indexed", "tags": ["yy"]]])
        XCTAssertEqual(try found(world, "indexed", "db3-b"), ["o2"])
        try rebuilt("after the purge")
    }
}
