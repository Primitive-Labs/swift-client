import XCTest
@testable import JsBaoClient

/// What the Swift device vector suites share (#5230): the family's text as
/// the shared fixture holds it, seeded notes, a model trained by vec1 on a
/// connection of the test's own, and an ANN table planted beside a flat one.
enum Db3VectorFixture {
    typealias Support = Db3VectorTestSupport

    static let note = "Note"
    static let f32 = VectorEncoding(dims: 8, element: .f32)
    static let f16 = VectorEncoding(dims: 8, element: .f16)
    static let i8 = VectorEncoding(dims: 8, element: .i8)

    static let fixtureDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/Db3Vectors")
    }()

    /// The shared fixture `vector-index-family.json`, js-bao's text (#5230 behavior 6).
    static func family() throws -> JSONValue {
        try XCTUnwrap(JSONValue(jsonText: String(contentsOf: fixtureDirectory.appendingPathComponent("vector-index-family.json"), encoding: .utf8)))
    }

    /// `count` seeded notes with an `embedding` in `encoding`, a `title` and `n`.
    static func notes(_ count: Int, _ encoding: VectorEncoding = f32, seed: UInt32 = 5229, field: String = "embedding") throws -> [(id: String, vector: [Float], row: JSONValue)] {
        try Support.randomVectors(count, encoding.dims, seed: seed).enumerated().map { offset, vector in
            let id = "n\(String(format: "%05d", offset))"
            let row: JSONValue = ["id": .string(id), "title": .string("t\(offset % 7)"), "n": .number(Double(offset)),
                                  field: .string(try VectorCodec.encode(vector, encoding: encoding))]
            return (id, try Support.heldAs(vector, encoding), row)
        }
    }

    static func flat(_ documentId: String, field: String = "embedding", model: String = note) -> String {
        RecordLogVectorIndex.tableName(documentId: documentId, model: model, field: field)
    }

    /// The rowids and bytes a vec1 table holds, by rowid.
    static func held(_ world: Db3DeviceIndexWorld, _ table: String) throws -> [Int: Data] {
        var out: [Int: Data] = [:]
        for row in try world.rows("SELECT rowid, vector FROM \"\(table)\"") {
            if let rowid = row["rowid"].intValue, case .blob(let bytes) = row["vector"] { out[rowid] = bytes }
        }
        return out
    }

    /// The vector family's objects on the file, `type:name`, sorted.
    static func objects(_ world: Db3DeviceIndexWorld) throws -> [String] {
        try world.rows(
            #"SELECT type, name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_vec\_%' ESCAPE '\' AND (type = 'trigger' OR sql LIKE 'CREATE VIRTUAL%') ORDER BY type, name"#
        ).map { "\($0["type"].stringValue ?? ""):\($0["name"].stringValue ?? "")" }
    }

    /// A cached vector entry's options.
    static func options(_ world: Db3DeviceIndexWorld, _ documentId: String, field: String = "embedding") throws -> JSONValue? {
        try world.rows(
            "SELECT options FROM record_log_indexes WHERE doc_id = ? AND kind = 'vector' AND fields = ?",
            [.text(documentId), .text("[\"\(field)\"]")]
        ).first?["options"].stringValue.flatMap(RecordLogJSON.parse)
    }

    /// A model vec1 trains over the flat table's vectors (no quantizer, `nbucket` buckets).
    static func trainedOver(_ world: Db3DeviceIndexWorld, _ table: String, distance: String = "cos", nbucket: Int = 4) throws -> Data {
        let vectors = try held(world, table).sorted { $0.key < $1.key }.map { Support.floats($0.value) }
        return try Support.trainModel(vectors, distance: distance, nbucket: nbucket, codesize: 0, quantizer: "none")
    }

    /// Plant an ANN table beside `documentId`'s flat table as an install
    /// leaves it, filled from the flat table (or with `fill`, not yet): the
    /// table rebuilt from `model`, the triggers keeping both tables, and
    /// `ann` (with `fill`) on the entry's options.
    static func plantAnn(
        _ world: Db3DeviceIndexWorld, _ documentId: String, model: Data, generation: Int? = 1, revision: Int? = 1, source: String = "shared",
        fill: Bool = false, field: String = "embedding", encoding: VectorEncoding = f32
    ) throws {
        let table = flat(documentId, field: field)
        let ann = RecordLogVectorIndex.annTable(table)
        try world.provider.withConnection { connection in
            try connection.executeScript("DROP TABLE IF EXISTS \"\(ann)\"")
            try connection.executeScript(RecordLogVectorIndex.tableDDL(ann))
            try connection.execute("INSERT INTO \"\(ann)\" (cmd, arg) VALUES ('rebuild', ?)", [.blob(model)])
            if !fill { try connection.executeScript("INSERT INTO \"\(ann)\" (rowid, vector) SELECT rowid, vector FROM \"\(table)\"") }
            for suffix in RecordLogVectorIndex.triggerSuffixes { try connection.executeScript("DROP TRIGGER IF EXISTS \"\(table)\(suffix)\"") }
            let target = RecordLogVectorIndex.Target(documentId: documentId, model: note, field: field, element: encoding.element.rawValue, dims: encoding.dims)
            for statement in RecordLogVectorIndex.triggersDDL([table, ann], target) { try connection.executeScript(statement) }
            let row = try connection.query(
                "SELECT options FROM record_log_indexes WHERE doc_id = ? AND kind = 'vector' AND fields = ?", [.text(documentId), .text("[\"\(field)\"]")]
            ).first
            var options = row?["options"].stringValue.flatMap(RecordLogJSON.parse)?.objectValue ?? [:]
            var installed: [String: JSONValue] = [
                "source": .string(source), "params": ["nbucket": 4, "codesize": 0, "quantizer": "none"], "rows": 1,
                "trainedAt": "2026-11-05T00:00:00.000Z", "vec1": "0.8",
            ]
            if let generation { installed["generation"] = .number(Double(generation)) }
            if let revision { installed["revision"] = .number(Double(revision)) }
            options["ann"] = .object(installed)
            if fill { options["fill"] = ["rowid": 0] } else { options.removeValue(forKey: "fill") }
            try connection.execute(
                "UPDATE record_log_indexes SET options = ? WHERE doc_id = ? AND kind = 'vector' AND fields = ?",
                [.text(RecordLogJSON.text(.object(options))), .text(documentId), .text("[\"\(field)\"]")]
            )
        }
    }

    /// The room's listing of a shared model at `revision`.
    static func annModel(revision: Int, rows: Int = 300) -> JSONValue {
        ["revision": .number(Double(revision)), "trainedAt": "2026-11-05T00:00:00.000Z", "rows": .number(Double(rows)), "bytes": 1000, "format": "pvm1"]
    }

    static func ann(nbucket: Int? = nil) -> JSONValue {
        var index: [String: JSONValue] = ["mode": "ann"]
        if let nbucket { index["nbucket"] = .number(Double(nbucket)) }
        return .object(index)
    }
}

/// #5230 behaviors 4 to 8, 10 (the store's half) and 11, and edge cases 36
/// and 42 (the reconcile's half) — a db3's device vector index in the Swift
/// store, the port of js-bao's (#5229):
///
/// - 4: storage version 9 adds `record_log_indexes.vector`; a store at 8 with
///   a #5322-cached vector entry opens at 9 with its rows and cache kept, the
///   entry reported unbuilt with js-bao's reason until a list gives its
///   options, then built; a store from a later version is never lowered.
/// - 5: an entry reads `vector`, `generation`, `revision` and `annModel`;
///   the options are checked as js-bao's `vectorOptionsOf` checks them.
/// - 6: the reconcile builds a vec1 flat table per vector entry with the
///   family's text (the shared fixture's), filled from the view's
///   convertible rows only, one info line, kept by a second list.
/// - 7 (the flat table's half and the oracle): the triggers keep the flat
///   table across creates, patches, nulls and deletes; a patch of another
///   field writes nothing to vec1; the oracle names planted drift in the flat
///   table and in an ANN table, a stale ANN vector under a kept rowid
///   included (F-5230-003).
/// - 8: the drop half.
/// - 10: `localIndexes` lists a vector entry unbuilt, built `exact`, built
///   `ann`, building, declined.
/// - 11: evict drops the family with the rows.
/// - 36: a value of the wrong length holds no flat row.
/// - 42: a text and a vector index on one model coexist and both go at evict.
final class Db3DeviceVectorIndexStoreHermeticTests: XCTestCase {

    private typealias F = Db3VectorFixture
    private typealias Support = Db3VectorTestSupport

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world(_ label: String = "vector-store") async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make(label, logger: Logger(level: .info))
        worlds.append(world)
        return world
    }

    private func entry(_ field: String = "embedding", _ encoding: VectorEncoding = F.f32, distance: String = "cos", index: JSONValue = "exact",
                       generation: Int? = 1, revision: Int? = 1, annModel: JSONValue? = nil) -> RecordLogIndexEntry {
        Support.vectorEntry(F.note, field, encoding, distance: distance, index: index, generation: generation, revision: revision, annModel: annModel)
    }

    private func viewRowid(_ world: Db3DeviceIndexWorld, _ documentId: String, _ id: String) throws -> Int {
        try XCTUnwrap(world.rows("SELECT rowid FROM record_log_view WHERE doc_id = ? AND _id = ?", [.text(documentId), .text(id)]).first?["rowid"].intValue)
    }

    // MARK: - 4: storage version 9 (10 since #5241's skip table)

    func testTheVersionIs9AndAFreshCacheHasTheVectorColumn() async throws {
        XCTAssertEqual(RecordLogSchema.storageVersion, 10)
        let world = try await world()
        try world.store("db3-a")
        let columns = try world.rows("SELECT name FROM pragma_table_info('record_log_indexes') ORDER BY cid").compactMap { $0["name"].stringValue }
        XCTAssertEqual(columns, ["doc_id", "model", "fields", "kind", "is_unique", "room_name", "members", "text", "options", "vector"])
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
    }

    func testAStoreAt8OpensAt9WithItsRowsAndCacheAndBuildsTheVectorEntryAtTheNextList() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        let notes = try F.notes(30)
        try world.seed("db3-a", F.note, notes.map(\.row))
        try store.syncIndexes([
            RecordLogIndexEntry(name: "idx_records_note_title", model: F.note, fields: ["title"], unique: false),
            RecordLogIndexEntry(name: "idx_text_note", model: F.note, fields: ["title"], unique: false, kind: .text, on: .device),
        ])
        // Plant version 8: the cache without its vector column, the vector entry as #5322 cached it.
        try world.exec("ALTER TABLE record_log_indexes DROP COLUMN vector")
        try world.exec(
            "INSERT INTO record_log_indexes (doc_id, model, fields, kind, is_unique, room_name, options) VALUES (?, ?, ?, 'vector', 0, ?, ?)",
            [.text("db3-a"), .text(F.note), .text("[\"embedding\"]"), .text("idx_vec_note_embedding"),
             .text(#"{"on":"device","unbuilt":"vector indexes are not built by this client build"}"#)]
        )
        try world.exec("UPDATE record_log_meta SET value = '8' WHERE key = 'storage_version'")
        let objects = try world.objects()
        let before = try store.storedState()

        let reopened = try world.reopen("db3-a")
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        XCTAssertTrue(try world.rows("SELECT name FROM pragma_table_info('record_log_indexes')").contains { $0["name"].stringValue == "vector" })
        // The rows, the view index, the text table and its triggers are exactly as they were.
        XCTAssertEqual(try world.objects(), objects)
        XCTAssertEqual(try reopened.storedState().rows, before.rows)
        XCTAssertEqual(try reopened.localIndexes().first { $0.kind == .vector }?.status, .unbuilt)
        // A reconcile with no list reports js-bao's reason for an entry with no options.
        try reopened.syncIndexes(nil)
        let unbuilt = try XCTUnwrap(reopened.localIndexes().first { $0.kind == .vector })
        XCTAssertEqual(unbuilt.status, .unbuilt)
        XCTAssertEqual(unbuilt.reason, RecordLogVectorIndex.unbuilt)
        XCTAssertEqual(RecordLogVectorIndex.unbuilt, "the room's index list does not give this vector index's options and field encoding yet")
        // The next list builds it.
        try reopened.syncIndexes([RecordLogIndexEntry(name: "idx_records_note_title", model: F.note, fields: ["title"], unique: false), entry()])
        let built = try XCTUnwrap(reopened.localIndexes().first { $0.kind == .vector })
        XCTAssertEqual(built.status, .built)
        XCTAssertEqual(built.mode, .exact)
        XCTAssertEqual(try F.held(world, F.flat("db3-a")).count, 30)
        XCTAssertEqual(try world.drift(), [])
    }

    func testAStoreFromALaterVersionIsNeverLowered() async throws {
        let world = try await world()
        try world.store("db3-a")
        try world.exec("UPDATE record_log_meta SET value = '10' WHERE key = 'storage_version'")
        _ = try world.reopen("db3-a")
        XCTAssertEqual(try world.version(), "10")
    }

    // MARK: - 5: the room's listing

    func testAnEntryReadsTheListingsVectorFieldsAndTheOptionsAreChecked() throws {
        let json: JSONValue = [
            "name": "idx_vec_note_embedding", "model": "Note", "fields": ["embedding"], "unique": false, "kind": "vector", "on": "device",
            "vector": ["distance": "l2", "index": ["mode": "ann", "nbucket": 32, "codesize": 8, "quantizer": "pq"], "dims": 64, "element": "f16"],
            "generation": 3, "revision": 2,
            "annModel": ["revision": 2, "trainedAt": "2026-11-05T00:00:00.000Z", "rows": 1200, "bytes": 5000, "format": "pvm1"],
        ]
        let entry = try XCTUnwrap(RecordLogIndexEntry(json: json))
        XCTAssertEqual(entry.kind, .vector)
        XCTAssertEqual(entry.generation, 3)
        XCTAssertEqual(entry.revision, 2)
        XCTAssertEqual(entry.annModel?["revision"], 2)
        XCTAssertEqual(entry.annModel?["format"], "pvm1")
        let options = try XCTUnwrap(RecordLogVectorOptions(cached: entry.vector))
        XCTAssertEqual(options, RecordLogVectorOptions(distance: "l2", index: .ann(nbucket: 32, codesize: 8, quantizer: "pq"), dims: 64, element: .f16))
        // A vector entry with no `on` is on the device.
        XCTAssertEqual(RecordLogIndexEntry(json: ["name": "v", "model": "Note", "fields": ["e"], "kind": "vector"])?.on, .device)
        // The checks of js-bao's `vectorOptionsOf`.
        XCTAssertNil(RecordLogVectorOptions(cached: nil))
        XCTAssertNil(RecordLogVectorOptions(cached: "exact"))
        XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 0, "element": "f32"]))
        XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 4097, "element": "f32"]))
        XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 2.5, "element": "f32"]))
        XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 8, "element": "f64"]))
        XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 8]))
        XCTAssertEqual(RecordLogVectorOptions(cached: ["dims": 8, "element": "i8"]), RecordLogVectorOptions(distance: "cos", index: .exact, dims: 8, element: .i8))
        XCTAssertEqual(RecordLogVectorOptions(cached: ["dims": 4096, "element": "f32", "distance": "chebyshev", "index": ["mode": "flat"]])?.index, .exact)
        XCTAssertEqual(RecordLogVectorOptions(cached: ["dims": 1, "element": "f32", "index": ["mode": "ann"]])?.index, .ann(nbucket: nil, codesize: nil, quantizer: nil))
    }

    func testAListWithoutVectorOptionsCachesTheEntryUnbuiltWithJsBaosReason() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        let lines = try Db3TextIndexFixture.logged {
            try store.syncIndexes([RecordLogIndexEntry(name: "idx_vec_note_embedding", model: F.note, fields: ["embedding"], unique: false, kind: .vector)])
        }
        XCTAssertEqual(try F.options(world, "db3-a"), ["on": "device", "unbuilt": .string(RecordLogVectorIndex.unbuilt)])
        XCTAssertEqual(try F.objects(world), [])
        // As js-bao: the reason is the cache's own from the list on, so it is said at debug, never warned.
        XCTAssertEqual(lines.filter { $0.message.contains("vector index idx_vec_note_embedding") && $0.level != .debug }.count, 0)
        let debug = try Db3TextIndexFixture.logged {
            let store = RecordLogStore(host: world.provider, documentId: "db3-a", clientId: "client-1", logger: Logger(level: .debug))
            try store.syncIndexes(nil)
        }
        XCTAssertEqual(
            debug.filter { $0.message.contains("vector index idx_vec_note_embedding") }.map(\.message),
            ["[record-log] db3-a: vector index idx_vec_note_embedding on Note is not built: \(RecordLogVectorIndex.unbuilt); $near on it is refused, every other query answers."]
        )
    }

    /// F-5230-CODE-004: the room admits any positive integer `nbucket` or
    /// `codesize`, 1e20 too; such an entry builds nothing and says why, and
    /// the list applies with no trap.
    func testAnAnnCountPastWhatTheDeviceHoldsBuildsNothingAndSaysWhy() async throws {
        let index = { (key: String, value: Double) -> JSONValue in .object(["mode": "ann", key: .number(value)]) }
        for value in [1e20, -1e20, 9_007_199_254_740_992, 0, 2.5] {
            XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 8, "element": "f32", "index": index("nbucket", value)]), "nbucket \(value)")
            XCTAssertNil(RecordLogVectorOptions(cached: ["dims": 8, "element": "f32", "index": index("codesize", value)]), "codesize \(value)")
        }
        XCTAssertEqual(
            RecordLogVectorOptions(cached: ["dims": 8, "element": "f32", "index": index("nbucket", 9_007_199_254_740_991)])?.index,
            .ann(nbucket: 9_007_199_254_740_991, codesize: nil, quantizer: nil)
        )
        // Its want's row floor neither traps nor is reached.
        XCTAssertEqual(RecordLogVectorIndex.minRows(nbucket: RecordLogVectorOptions.maxCount), 4 * RecordLogVectorOptions.maxCount)

        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(20).map(\.row))
        try store.syncIndexes([entry(index: index("nbucket", 1e20))])
        let reason = "vector.index.nbucket 100000000000000000000 is not an integer from 1 to 9007199254740991; this device builds no vector index with it"
        let listed = try XCTUnwrap(store.localIndexes().first { $0.kind == .vector })
        XCTAssertEqual(listed.status, .unbuilt)
        XCTAssertEqual(listed.reason, reason)
        XCTAssertEqual(try F.objects(world), [])
        XCTAssertEqual(try store.vectorModelWants(), [])
        // A later list with counts the device holds builds it.
        try store.syncIndexes([entry(index: F.ann(nbucket: 4))])
        XCTAssertEqual(try store.localIndexes().first { $0.kind == .vector }?.status, .built)
    }

    // MARK: - 6: the flat table

    func testTheReconcileBuildsAFlatTablePerFieldFromTheViewsConvertibleRowsWithTheFamilysText() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        let values = Support.randomVectors(4, 8, seed: 7)
        let encode = { (vector: [Float], encoding: VectorEncoding) -> JSONValue in .string(try! VectorCodec.encode(vector, encoding: encoding)) }
        try world.seed("db3-a", F.note, [
            ["id": "a", "embedding": encode(values[0], F.f32), "half": encode(values[0], F.f16), "byte": encode(values[0], F.i8)],
            ["id": "b", "embedding": encode(values[1], F.f32), "half": encode(values[1], F.f16), "byte": encode(values[1], F.i8)],
            ["id": "c", "embedding": .null, "half": "not base64!",
             "byte": encode(Array(values[2].prefix(4)), VectorEncoding(dims: 4, element: .i8))],
            ["id": "d", "title": "no vector at all"],
        ])
        let lines = try Db3TextIndexFixture.logged {
            let sync = try store.syncIndexes([entry("embedding", F.f32), entry("half", F.f16, distance: "l2"), entry("byte", F.i8)])
            XCTAssertEqual(sync, RecordLogIndexSync(created: 3, dropped: 0))
        }
        let table = F.flat("db3-a")
        XCTAssertEqual(table, "idx_record_log_vec_5_db3-a_4_note_9_embedding")
        XCTAssertEqual(try F.objects(world), ["byte", "embedding", "half"].flatMap { field in
            ["table:\(F.flat("db3-a", field: field))"] + ["__d", "__i", "__u"].map { "trigger:\(F.flat("db3-a", field: field))\($0)" }
        }.sorted())
        XCTAssertEqual(
            try world.rows("SELECT vector FROM record_log_indexes WHERE doc_id = 'db3-a' AND kind = 'vector' ORDER BY fields").compactMap { $0["vector"].stringValue },
            [F.flat("db3-a", field: "byte"), F.flat("db3-a", field: "embedding"), F.flat("db3-a", field: "half")]
        )
        // The table's DDL and its triggers are js-bao's text.
        XCTAssertEqual(try world.rows("SELECT sql FROM sqlite_master WHERE name = ?", [.text(table)]).first?["sql"].stringValue,
                       RecordLogVectorIndex.tableDDL(table))
        let triggers = try world.rows("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name IN (?, ?, ?) ORDER BY name = ?, name = ?",
                                      [.text("\(table)__i"), .text("\(table)__u"), .text("\(table)__d"), .text("\(table)__d"), .text("\(table)__u")])
        let target = RecordLogVectorIndex.Target(documentId: "db3-a", model: F.note, field: "embedding", element: "f32", dims: 8)
        XCTAssertEqual(triggers.compactMap { $0["sql"].stringValue }, RecordLogVectorIndex.triggersDDL([table], target))
        let insertNew = "INSERT INTO \"\(table)\" (rowid, vector) SELECT NEW.rowid, v FROM (SELECT record_log_vec_f32(json_extract(NEW._data, '$.embedding'), 'f32', 8) AS v LIMIT -1) WHERE v IS NOT NULL"
        XCTAssertEqual(RecordLogVectorIndex.triggersDDL([table], target), [
            "CREATE TRIGGER \"\(table)__i\" AFTER INSERT ON record_log_view WHEN NEW.doc_id = 'db3-a' AND NEW._type = 'Note'\nBEGIN\n  \(insertNew);\nEND",
            "CREATE TRIGGER \"\(table)__u\" AFTER UPDATE OF _data ON record_log_view WHEN OLD.doc_id = 'db3-a' AND OLD._type = 'Note' AND json_extract(OLD._data, '$.embedding') IS NOT json_extract(NEW._data, '$.embedding')\n"
                + "BEGIN\n  DELETE FROM \"\(table)\" WHERE rowid = OLD.rowid;\n  \(insertNew);\nEND",
            "CREATE TRIGGER \"\(table)__d\" AFTER DELETE ON record_log_view WHEN OLD.doc_id = 'db3-a' AND OLD._type = 'Note'\nBEGIN\n  DELETE FROM \"\(table)\" WHERE rowid = OLD.rowid;\nEND",
        ])
        // Each element type held as binary32, as the codec decodes it; null, absent and malformed values hold no row.
        for (field, encoding) in [("embedding", F.f32), ("half", F.f16), ("byte", F.i8)] {
            let held = try F.held(world, F.flat("db3-a", field: field))
            XCTAssertEqual(held.keys.sorted(), [try viewRowid(world, "db3-a", "a"), try viewRowid(world, "db3-a", "b")], field)
            XCTAssertEqual(held[try viewRowid(world, "db3-a", "a")], Support.bytes(try Support.heldAs(values[0], encoding)), field)
        }
        XCTAssertEqual(try world.drift(), [])
        // The pointer and the flat table's definition on the options.
        XCTAssertEqual(try F.options(world, "db3-a", field: "half")?["flat"], ["distance": "l2", "dims": 8, "element": "f16"])
        XCTAssertNil(try F.options(world, "db3-a")?["unbuilt"])
        // One info line per table, with its row count.
        let built = lines.filter { $0.message.contains("vector index idx_vec_note_embedding") }
        XCTAssertEqual(built.map(\.level), [.info])
        XCTAssertNotNil(built.first?.message.range(
            of: #"^\[record-log\] db3-a: vector index idx_vec_note_embedding on Note\.embedding built from 2 rows in [0-9.]+ ms\.$"#, options: .regularExpression
        ), built.first?.message ?? "")
        XCTAssertEqual(try store.localIndexes().map { [$0.name, $0.status.rawValue, $0.mode?.rawValue ?? "-"] }, [
            ["idx_vec_note_byte", "built", "exact"], ["idx_vec_note_embedding", "built", "exact"], ["idx_vec_note_half", "built", "exact"],
        ])
        // A second list keeps the tables.
        XCTAssertEqual(try store.syncIndexes([entry("embedding", F.f32), entry("half", F.f16, distance: "l2"), entry("byte", F.i8)]),
                       RecordLogIndexSync(created: 0, dropped: 0))
        XCTAssertEqual(try F.held(world, table).count, 2)
    }

    func testTheFamilysTextIsTheSharedFixtures() throws {
        let fixture = try F.family()
        for target in try XCTUnwrap(fixture["targets"]?.arrayValue) {
            let documentId = try XCTUnwrap(target["docId"]?.stringValue)
            let model = try XCTUnwrap(target["model"]?.stringValue)
            let field = try XCTUnwrap(target["field"]?.stringValue)
            let table = RecordLogVectorIndex.tableName(documentId: documentId, model: model, field: field)
            let ann = RecordLogVectorIndex.annTable(table)
            let vector = RecordLogVectorIndex.Target(
                documentId: documentId, model: model, field: field, element: try XCTUnwrap(target["element"]?.stringValue),
                dims: Int(try XCTUnwrap(target["dims"]?.numberValue))
            )
            XCTAssertEqual(.string(table), target["table"], documentId)
            XCTAssertEqual(.string(ann), target["annTable"], documentId)
            XCTAssertEqual(.string(RecordLogVectorIndex.tableDDL(table)), target["ddl"], documentId)
            XCTAssertEqual(.string(RecordLogVectorIndex.tableDDL(ann)), target["annDdl"], documentId)
            XCTAssertEqual(.string(RecordLogVectorIndex.flatRebuildArg("cos")), target["flatRebuild"]?["cos"])
            XCTAssertEqual(.string(RecordLogVectorIndex.flatRebuildArg("l2")), target["flatRebuild"]?["l2"])
            XCTAssertEqual(.array(RecordLogVectorIndex.triggersDDL([table], vector).map(JSONValue.string)), target["triggers"], documentId)
            XCTAssertEqual(.array(RecordLogVectorIndex.triggersDDL([table, ann], vector).map(JSONValue.string)), target["triggersWithAnn"], documentId)
            XCTAssertEqual(.string(RecordLogVectorIndex.fillSQL(vector)), target["fill"], documentId)
        }
    }

    // MARK: - 7: the triggers and the oracle

    func testTheTriggersKeepTheFlatTableAcrossCreatesPatchesNullsAndDeletes() async throws {
        let world = try await world()
        let store = try world.store("db3-a", localOnly: true)
        try store.syncIndexes([entry()])
        let table = F.flat("db3-a")
        let encode = { (vector: [Float]) -> JSONValue in .string(try! VectorCodec.encode(vector, encoding: F.f32)) }
        let (a, b, c) = { let v = Support.randomVectors(3, 8, seed: 11); return (v[0], v[1], v[2]) }()
        try world.commit("db3-a", [
            RecordLogMutation(model: F.note, id: "x", kind: .create, fields: ["embedding": encode(a)]),
            RecordLogMutation(model: F.note, id: "y", kind: .create, fields: ["embedding": encode(b)]),
            RecordLogMutation(model: F.note, id: "z", kind: .create, fields: ["title": "none"]),
        ])
        XCTAssertEqual(try F.held(world, table).count, 2)
        XCTAssertEqual(try world.drift(), [])
        try world.commit("db3-a", [
            RecordLogMutation(model: F.note, id: "x", kind: .patch, fields: ["embedding": encode(c)]),
            RecordLogMutation(model: F.note, id: "y", kind: .patch, fields: ["embedding": .null]),
            RecordLogMutation(model: F.note, id: "z", kind: .patch, fields: ["embedding": encode(a)]),
        ])
        XCTAssertEqual(try F.held(world, table)[try viewRowid(world, "db3-a", "x")], Support.bytes(c))
        XCTAssertEqual(try F.held(world, table).count, 2)
        XCTAssertEqual(try world.drift(), [])
        try world.commit("db3-a", [RecordLogMutation(model: F.note, id: "x", kind: .delete)])
        XCTAssertEqual(try F.held(world, table).count, 1)
        XCTAssertEqual(try world.drift(), [])
        // A patch of another field writes nothing to vec1: the update trigger's guard holds.
        let before = try F.held(world, table)
        let changes = try world.provider.withConnection { connection -> Int in
            let start = try connection.query("SELECT total_changes() AS n", []).first?["n"].intValue ?? 0
            try connection.execute("UPDATE record_log_view SET _data = json_set(_data, '$.title', 'renamed') WHERE doc_id = 'db3-a' AND _id = 'z'", [])
            return (try connection.query("SELECT total_changes() AS n", []).first?["n"].intValue ?? 0) - start
        }
        XCTAssertEqual(changes, 1, "only the view row changed")
        XCTAssertEqual(try F.held(world, table), before)
        XCTAssertEqual(try world.drift(), [])
    }

    func testTheOracleNamesPlantedDriftInTheFlatAndAnnTables() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        let notes = try F.notes(300)
        try world.seed("db3-a", F.note, notes.map(\.row))
        try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
        let table = F.flat("db3-a")
        let ann = RecordLogVectorIndex.annTable(table)
        try F.plantAnn(world, "db3-a", model: try F.trainedOver(world, table))
        XCTAssertEqual(try world.drift(), [])
        let (one, two, three) = (try viewRowid(world, "db3-a", "n00001"), try viewRowid(world, "db3-a", "n00002"), try viewRowid(world, "db3-a", "n00003"))
        let other = Support.bytes(Support.randomVectors(1, 8, seed: 99)[0])
        // vec1 updates a row by deleting and inserting it.
        let replace = { (table: String, rowid: Int, bytes: Data) throws in
            try world.exec("DELETE FROM \"\(table)\" WHERE rowid = ?", [.integer(Int64(rowid))])
            try world.exec("INSERT INTO \"\(table)\" (rowid, vector) VALUES (?, ?)", [.integer(Int64(rowid)), .blob(bytes)])
        }
        // A flat table's drift shows in the ANN table too: it is compared with the flat table.
        let planted: [(String, [String], () throws -> Void, () throws -> Void)] = [
            ("a missing flat row", ["\(table): rowids missing [\(one)]", "\(ann): stray rowids [\(one)]"],
             { try world.exec("DELETE FROM \"\(table)\" WHERE rowid = ?", [.integer(Int64(one))]) },
             { try world.exec("INSERT INTO \"\(table)\" (rowid, vector) VALUES (?, ?)", [.integer(Int64(one)), .blob(Support.bytes(notes[1].vector))]) }),
            ("a differing flat vector", ["\(table): vectors differ under rowids [\(two)]", "\(ann): vectors differ under rowids [\(two)]"],
             { try replace(table, two, other) },
             { try replace(table, two, Support.bytes(notes[2].vector)) }),
            ("a stray ANN row", ["\(ann): stray rowids [99999]"],
             { try world.exec("INSERT INTO \"\(ann)\" (rowid, vector) VALUES (99999, ?)", [.blob(other)]) },
             { try world.exec("DELETE FROM \"\(ann)\" WHERE rowid = 99999") }),
            ("a missing ANN row", ["\(ann): rowids missing [\(three)]"],
             { try world.exec("DELETE FROM \"\(ann)\" WHERE rowid = ?", [.integer(Int64(three))]) },
             { try world.exec("INSERT INTO \"\(ann)\" (rowid, vector) VALUES (?, ?)", [.integer(Int64(three)), .blob(Support.bytes(notes[3].vector))]) }),
            ("a stale ANN vector under an unchanged rowid", ["\(ann): vectors differ under rowids [\(one)]"],
             { try replace(ann, one, other) },
             { try replace(ann, one, Support.bytes(notes[1].vector)) }),
        ]
        for (name, problem, plant, undo) in planted {
            try plant()
            XCTAssertEqual(try world.drift(), problem, name)
            try undo()
            XCTAssertEqual(try world.drift(), [], name)
        }
    }

    // MARK: - 8: the drop half

    func testTheDropHalfDropsWhatNoEntryKeepsAndRebuildsChangedOptions() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        let notes = try F.notes(40)
        try world.seed("db3-a", F.note, notes.map(\.row))
        let table = F.flat("db3-a")
        try store.syncIndexes([entry()])
        // Options changed: distance, dims or element drop and rebuild the flat table.
        XCTAssertEqual(try store.syncIndexes([entry(distance: "l2")]), RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(try F.options(world, "db3-a")?["flat"]?["distance"], "l2")
        XCTAssertEqual(try F.held(world, table).count, 40)
        XCTAssertEqual(try store.syncIndexes([entry("embedding", VectorEncoding(dims: 4, element: .f32))]), RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(try F.held(world, table).count, 0, "no value is a 4-d vector")
        XCTAssertEqual(try store.syncIndexes([entry("embedding", F.f16)]), RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(try F.held(world, table).count, 0, "no value is an f16 vector")
        XCTAssertEqual(try store.syncIndexes([entry()]), RecordLogIndexSync(created: 1, dropped: 0))
        XCTAssertEqual(try world.drift(), [])
        // A kept flat table's triggers are rewritten when their text is not the mode's.
        try world.exec("DROP TRIGGER \"\(table)__u\"")
        try world.exec("CREATE TRIGGER \"\(table)__u\" AFTER UPDATE OF _data ON record_log_view BEGIN SELECT 1; END")
        XCTAssertEqual(try store.syncIndexes([entry()]), RecordLogIndexSync(created: 0, dropped: 0))
        let target = RecordLogVectorIndex.Target(documentId: "db3-a", model: F.note, field: "embedding", element: "f32", dims: 8)
        XCTAssertEqual(try world.rows("SELECT sql FROM sqlite_master WHERE name = ?", [.text("\(table)__u")]).first?["sql"].stringValue,
                       RecordLogVectorIndex.triggersDDL([table], target)[1])
        // An entry gone from the list drops its table and triggers.
        XCTAssertEqual(try store.syncIndexes([]), RecordLogIndexSync(created: 0, dropped: 1))
        XCTAssertEqual(try F.objects(world), [])
    }

    func testTheAnnTableIsDroppedWhenItsModelIsNoLongerTheIndexs() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(300).map(\.row))
        let table = F.flat("db3-a")
        let ann = RecordLogVectorIndex.annTable(table)
        let target = RecordLogVectorIndex.Target(documentId: "db3-a", model: F.note, field: "embedding", element: "f32", dims: 8)
        let triggers = { try world.rows("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE ? ORDER BY name = ?, name = ?, name",
                                        [.text("\(table)__%"), .text("\(table)__d"), .text("\(table)__u")]).compactMap { $0["sql"].stringValue } }
        try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
        let model = try F.trainedOver(world, table)
        let cases: [(String, RecordLogIndexEntry)] = [
            ("the room lists another revision's model", entry(index: F.ann(), revision: 2, annModel: F.annModel(revision: 2))),
            ("the room lists no model", entry(index: F.ann(), annModel: nil)),
            ("the index is exact now", entry(index: "exact", annModel: F.annModel(revision: 1))),
            ("another generation", entry(index: F.ann(), generation: 2, annModel: F.annModel(revision: 1))),
        ]
        for (name, changed) in cases {
            try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
            try F.plantAnn(world, "db3-a", model: model)
            // The same listing keeps it, its triggers keeping both tables.
            XCTAssertEqual(try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))]), RecordLogIndexSync(created: 0, dropped: 0), name)
            XCTAssertTrue(try F.objects(world).contains("table:\(ann)"), name)
            XCTAssertEqual(try triggers(), RecordLogVectorIndex.triggersDDL([table, ann], target), name)
            XCTAssertEqual(try store.localIndexes().first?.mode, .ann, name)
            // A listing that moved drops it in the cache's transaction, the flat table kept.
            XCTAssertEqual(try store.syncIndexes([changed]), RecordLogIndexSync(created: 0, dropped: 0), name)
            XCTAssertFalse(try F.objects(world).contains("table:\(ann)"), name)
            XCTAssertEqual(try triggers(), RecordLogVectorIndex.triggersDDL([table], target), name)
            XCTAssertNil(try F.options(world, "db3-a")?["ann"], name)
            XCTAssertNil(try F.options(world, "db3-a")?["fill"], name)
            XCTAssertEqual(try store.localIndexes().first?.mode, .exact, name)
            XCTAssertEqual(try world.drift(), [], name)
        }
    }

    func testADeclinedEntrysTablesAndTriggersGoAndItsPointerClears() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(300).map(\.row))
        try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
        try F.plantAnn(world, "db3-a", model: try F.trainedOver(world, F.flat("db3-a")))
        let declined = try store.declineIndex("idx_vec_note_embedding")
        XCTAssertEqual(declined.status, .declined)
        XCTAssertNil(declined.mode)
        XCTAssertEqual(try F.objects(world), [])
        XCTAssertTrue(try world.rows("SELECT vector FROM record_log_indexes WHERE kind = 'vector'").allSatisfy { $0["vector"].isNull })
        // A list keeps it declined.
        try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
        XCTAssertEqual(try F.objects(world), [])
        // Accepted, its flat table is built again.
        let accepted = try store.acceptIndex("idx_vec_note_embedding")
        XCTAssertEqual(accepted.status, .built)
        XCTAssertEqual(accepted.mode, .exact)
        XCTAssertEqual(try F.held(world, F.flat("db3-a")).count, 300)
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 10: statuses

    func testLocalIndexesListAVectorEntryUnbuiltBuiltAnnBuildingAndDeclined() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(300).map(\.row))
        try store.syncIndexes([RecordLogIndexEntry(name: "idx_vec_note_embedding", model: F.note, fields: ["embedding"], unique: false, kind: .vector)])
        XCTAssertEqual(try store.localIndexes(), [Db3LocalIndex(
            name: "idx_vec_note_embedding", model: F.note, fields: ["embedding"], kind: .vector, on: .device, status: .unbuilt, reason: RecordLogVectorIndex.unbuilt
        )])
        try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
        XCTAssertEqual(try store.localIndexes(), [Db3LocalIndex(
            name: "idx_vec_note_embedding", model: F.note, fields: ["embedding"], kind: .vector, on: .device, status: .built, mode: .exact
        )])
        let model = try F.trainedOver(world, F.flat("db3-a"))
        try F.plantAnn(world, "db3-a", model: model, fill: true)
        XCTAssertEqual(try store.localIndexes().map { [$0.status.rawValue, $0.mode?.rawValue ?? "-"] }, [["building", "exact"]])
        try F.plantAnn(world, "db3-a", model: model)
        XCTAssertEqual(try store.localIndexes().map { [$0.status.rawValue, $0.mode?.rawValue ?? "-"] }, [["built", "ann"]])
        // Left out by the client's default before it was built: declined, with the option's reason.
        let other = RecordLogStore(host: world.provider, documentId: "db3-b", clientId: "client-1", deviceIndexes: .kinds([.scalar]))
        try other.initialize()
        try other.setState(writer: try other.mintWriter())
        try other.syncIndexes([Support.vectorEntry(F.note, "embedding", F.f32)])
        XCTAssertEqual(try other.localIndexes().map { [$0.status.rawValue, $0.reason ?? "-"] }, [["declined", "the client's deviceIndexes option excludes vector"]])
        XCTAssertFalse(try F.objects(world).contains { $0.contains(F.flat("db3-b")) })
        XCTAssertEqual(try other.acceptIndex("idx_vec_note_embedding").status, .built)
    }

    // MARK: - 11: evict

    func testEvictDropsTheDb3sFlatAndAnnTablesAndTriggersWithItsRows() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(300).map(\.row))
        try store.syncIndexes([entry(index: F.ann(), annModel: F.annModel(revision: 1))])
        try F.plantAnn(world, "db3-a", model: try F.trainedOver(world, F.flat("db3-a")))
        let kept = try world.store("db3-b")
        try world.seed("db3-b", F.note, try F.notes(5).map(\.row))
        try kept.syncIndexes([entry()])
        XCTAssertTrue(try store.purge(force: false).purged)
        XCTAssertEqual(try F.objects(world), ["table:\(F.flat("db3-b"))"] + ["__d", "__i", "__u"].map { "trigger:\(F.flat("db3-b"))\($0)" })
        XCTAssertEqual(try world.rows("SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = 'db3-a'").first?["n"].intValue, 0)
        XCTAssertEqual(try world.drift(), [])
    }

    func testAStoreWhoseCacheHasNoVectorColumnPurgesAsBefore() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(3).map(\.row))
        try world.exec("ALTER TABLE record_log_indexes DROP COLUMN vector")
        try world.provider.withConnection { try RecordLogIndexes.dropDeviceTables(RecordLogSql(connection: $0), documentId: "db3-a") }
        XCTAssertNotNil(store)
    }

    // MARK: - Edge cases 36 and 42

    func testAValueOfTheWrongLengthHoldsNoRowUntilAFittingOneIsWritten() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try store.syncIndexes([entry()])
        let short = try VectorCodec.encode([1, 2, 3, 4], encoding: VectorEncoding(dims: 4, element: .f32))
        try world.seed("db3-a", F.note, [["id": "w", "embedding": .string(short)]])
        XCTAssertEqual(try F.held(world, F.flat("db3-a")).count, 0)
        try world.seed("db3-a", F.note, [["id": "w", "embedding": .null]])
        XCTAssertEqual(try F.held(world, F.flat("db3-a")).count, 0)
        let fitting = Support.randomVectors(1, 8, seed: 3)[0]
        try world.seed("db3-a", F.note, [["id": "w", "embedding": .string(try VectorCodec.encode(fitting, encoding: F.f32))]])
        XCTAssertEqual(try F.held(world, F.flat("db3-a")).values.first, Support.bytes(fitting))
        XCTAssertEqual(try world.drift(), [])
    }

    func testATextAndAVectorIndexOnOneModelCoexistAndBothGoAtEvict() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", F.note, try F.notes(20).map(\.row))
        try store.syncIndexes([entry(), RecordLogIndexEntry(name: "idx_text_note", model: F.note, fields: ["title"], unique: false, kind: .text, on: .device)])
        XCTAssertEqual(try store.localIndexes().map(\.status), [.built, .built])
        XCTAssertEqual(try world.drift(), [])
        XCTAssertTrue(try store.purge(force: false).purged)
        XCTAssertEqual(try F.objects(world), [])
        XCTAssertEqual(try Db3TextIndexFixture.textObjects(world), [])
    }
}
