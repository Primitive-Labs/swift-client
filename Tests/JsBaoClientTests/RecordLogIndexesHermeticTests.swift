import XCTest
@testable import JsBaoClient

/// #4700 behaviours 15–17 and 20, edges 31 and 35: a db3 store builds its view
/// indexes from the room's index list, not from model declarations.
///
/// - `syncIndexes` caches a document's list in `record_log_indexes` and
///   reconciles the store's family of indexes over every cached list, by
///   definition: one partial index on `record_log_view` per distinct
///   `(model, fields)` (`doc_id, json_extract(_data, '$.<field>')…, _id`,
///   `WHERE _type = '<model>'`, never `UNIQUE`), one on `record_log_rows` per
///   unique single-field entry, the JS store's names.
/// - `indexTuples` answers the store's view indexes as the room lists its own.
/// - The reads of a document's list apply in the order they were issued.
final class RecordLogIndexesHermeticTests: XCTestCase {

    private var fixtures: [RecordLogViewFixture] = []
    private let warnings = LockedBox<[String]>([])

    override func setUp() async throws {
        try await super.setUp()
        let warnings = warnings
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("index") { warnings.withValue { $0.append(message) } }
        }
    }

    override func tearDown() async throws {
        Logger.lineForTest = nil
        for fixture in fixtures { fixture.remove() }
        fixtures = []
        try await super.tearDown()
    }

    private func fixture() async throws -> RecordLogViewFixture {
        let made = try await RecordLogViewFixture.make("indexes")
        made.logLevel = .warn
        fixtures.append(made)
        return made
    }

    private func store(_ fixture: RecordLogViewFixture, _ documentId: String) throws -> RecordLogStore {
        try fixture.open(documentId).store
    }

    private func entry(_ model: String, _ fields: [String], unique: Bool = false, name: String? = nil) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: name ?? "idx_records_\(model)_\(fields.joined(separator: "_"))", model: model, fields: fields, unique: unique)
    }

    /// Every index on a record-log table: name → its `CREATE INDEX` text.
    private func indexes(_ fixture: RecordLogViewFixture, table: String) throws -> [String: String] {
        let rows = try fixture.provider.withConnection {
            try $0.query("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", [.text(table)])
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"].stringValue ?? "", $0["sql"].stringValue ?? "") })
    }

    private func tuple(_ model: String, _ fields: [String], _ unique: Bool) -> RecordLogIndexTuple {
        RecordLogIndexTuple(model: model, fields: fields, unique: unique)
    }

    // MARK: - Behaviour 15

    func testASyncCachesTheListAndBuildsOneViewIndexPerModelAndFields() async throws {
        let fixture = try await fixture()
        let store = try store(fixture, "db3-a")
        let created = try store.syncIndexes([
            entry("Note", ["title"]),
            entry("Note", ["slug"], unique: true),
            entry("Note", ["a", "b"], unique: true, name: "idx_named_Note_by_ab"),
            entry("Note", ["id"], unique: true),
            entry("bad model", ["x"]),
            entry("Note", ["bad field"]),
        ])
        XCTAssertEqual(created.created, 4)

        let view = try indexes(fixture, table: "record_log_view")
        XCTAssertEqual(
            view["idx_record_log_view_4_note_5_title"],
            "CREATE INDEX \"idx_record_log_view_4_note_5_title\" ON record_log_view(doc_id, json_extract(_data, '$.title'), _id) WHERE _type = 'Note'"
        )
        XCTAssertNotNil(view["idx_record_log_view_4_note_4_slug"])
        XCTAssertEqual(
            view["idx_record_log_view_4_note_1_a_1_b"],
            "CREATE INDEX \"idx_record_log_view_4_note_1_a_1_b\" ON record_log_view(doc_id, json_extract(_data, '$.a'), json_extract(_data, '$.b'), _id) WHERE _type = 'Note'"
        )
        XCTAssertEqual(view.keys.filter { $0.hasPrefix("idx_record_log_view_") }.count, 3, "id alone and the bad names need none: \(view.keys)")
        XCTAssertFalse(view.values.contains { $0.uppercased().contains("UNIQUE") }, "uniqueness is the room's to enforce")
        let rows = try indexes(fixture, table: "record_log_rows")
        XCTAssertEqual(Array(rows.keys.filter { $0.hasPrefix("idx_record_log_rows_") }), ["idx_record_log_rows_4_note_4_slug"],
                       "the confirmed rows get the unique single-field entry")

        XCTAssertEqual(try store.indexTuples(), [
            tuple("Note", ["a", "b"], true), tuple("Note", ["slug"], true), tuple("Note", ["title"], false),
        ])
        let cached = try fixture.provider.withConnection {
            try $0.query("SELECT model, fields, is_unique, room_name FROM record_log_indexes WHERE doc_id = 'db3-a' ORDER BY fields")
        }
        XCTAssertEqual(cached.map { $0["fields"].stringValue }, [#"["a","b"]"#, #"["slug"]"#, #"["title"]"#])
        XCTAssertEqual(cached.first?["room_name"].stringValue, "idx_named_Note_by_ab")
        XCTAssertEqual(warnings.value.count, 2, "one warning per entry that is not an identifier: \(warnings.value)")
        XCTAssertTrue(warnings.value.contains { $0.contains("db3-a") && $0.contains("bad model") }, "\(warnings.value)")
    }

    func testAnIndexMatchedByDefinitionKeepsItsNameAndAHeldNameTakesASuffix() async throws {
        let fixture = try await fixture()
        let store = try store(fixture, "db3-a")
        try fixture.provider.withConnection { connection in
            try connection.executeScript(
                "CREATE INDEX \"idx_record_log_view_mine\" ON record_log_view(doc_id, json_extract(_data, '$.title'), _id) WHERE _type = 'Note'"
            )
            // A name the canonical one would take, held on another table.
            try connection.executeScript("CREATE INDEX \"idx_record_log_view_4_note_5_title\" ON record_log_rows(_id)")
        }
        try store.syncIndexes([entry("Note", ["title"]), entry("note", ["title"])])
        let view = try indexes(fixture, table: "record_log_view")
        XCTAssertNotNil(view["idx_record_log_view_mine"], "matched by its definition, so it keeps its name")
        XCTAssertNil(view["idx_record_log_view_4_note_5_title"])
        XCTAssertEqual(
            view["idx_record_log_view_4_note_5_title_2"],
            "CREATE INDEX \"idx_record_log_view_4_note_5_title_2\" ON record_log_view(doc_id, json_extract(_data, '$.title'), _id) WHERE _type = 'note'",
            "(note, [title]) is its own index, its canonical name taken"
        )
        XCTAssertEqual(try store.indexTuples(), [tuple("Note", ["title"], false), tuple("note", ["title"], false)])
    }

    func testAnIndexNoListWantsIsDroppedAndNoListReconcilesFromTheCache() async throws {
        let fixture = try await fixture()
        let store = try store(fixture, "db3-a")
        try store.syncIndexes([entry("Note", ["title"]), entry("Note", ["slug"], unique: true)])
        let dropped = try store.syncIndexes([entry("Note", ["title"])])
        XCTAssertEqual(dropped.dropped, 2, "the slug view and rows indexes")
        XCTAssertEqual(try store.indexTuples(), [tuple("Note", ["title"], false)])
        XCTAssertNil(try indexes(fixture, table: "record_log_rows")["idx_record_log_rows_4_note_4_slug"])

        try fixture.provider.withConnection { try $0.executeScript("DROP INDEX idx_record_log_view_4_note_5_title") }
        XCTAssertEqual(try store.indexTuples(), [])
        let rebuilt = try store.syncIndexes(nil)
        XCTAssertEqual(rebuilt.created, 1, "the cached list stands")
        XCTAssertEqual(try store.indexTuples(), [tuple("Note", ["title"], false)])
    }

    // MARK: - Behaviour 16: the reconcile is per store

    func testAnIndexAnotherDb3StillListsIsKeptAndDroppedWhenNoneDoes() async throws {
        let fixture = try await fixture()
        let a = try store(fixture, "db3-a")
        let b = try store(fixture, "db3-b")
        try a.syncIndexes([entry("Note", ["title"])])
        try b.syncIndexes([entry("Note", ["title"])])
        XCTAssertEqual(try indexes(fixture, table: "record_log_view").keys.filter { $0.hasPrefix("idx_record_log_view_") },
                       ["idx_record_log_view_4_note_5_title"], "one index for the two lists")
        try a.syncIndexes([])
        XCTAssertEqual(try b.indexTuples(), [tuple("Note", ["title"], false)], "db3-b still lists it")
        try b.syncIndexes([])
        XCTAssertEqual(try a.indexTuples(), [], "dropped once neither lists it")
    }

    // MARK: - Behaviour 17: declarations no longer build indexes

    func testBindingADeclaredModelBuildsNoIndexUntilAListNamesIt() async throws {
        let fixture = try await fixture()
        let schema = PrimitiveSchema(name: "Note", fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, indexed: true),
            "slug": FieldDescriptor(type: .string, unique: true),
        ])
        try fixture.member(schema, "db3-a")
        let family = { (table: String) in try self.indexes(fixture, table: table).keys.filter { $0.hasPrefix("idx_record_log_") } }
        XCTAssertEqual(try family("record_log_view"), [], "a declaration builds no view index")
        XCTAssertEqual(try family("record_log_rows"), [], "nor a confirmed-rows index")
        try store(fixture, "db3-a").syncIndexes([entry("Note", ["title"]), entry("Note", ["slug"], unique: true)])
        XCTAssertEqual(Set(try family("record_log_view")), ["idx_record_log_view_4_note_5_title", "idx_record_log_view_4_note_4_slug"])
        XCTAssertEqual(try family("record_log_rows"), ["idx_record_log_rows_4_note_4_slug"])
    }

    // MARK: - Behaviour 20: the reads apply in the order they were issued

    func testAnOlderReadAnsweredLateIsDropped() async throws {
        let fixture = try await fixture()
        let store = try store(fixture, "db3-a")
        let order = RecordLogIndexReadOrder()
        let first = order.issue("db3-a")
        let second = order.issue("db3-a")
        let other = order.issue("db3-b")
        XCTAssertTrue(try order.apply("db3-a", second) { try store.syncIndexes([entry("Note", ["slug"])]) })
        XCTAssertFalse(try order.apply("db3-a", first) { try store.syncIndexes([entry("Note", ["title"])]) },
                       "the older answer is dropped")
        XCTAssertTrue(try order.apply("db3-b", other) {}, "each document keeps its own order")
        XCTAssertEqual(try store.indexTuples(), [tuple("Note", ["slug"], false)])
        let third = order.issue("db3-a")
        XCTAssertTrue(try order.apply("db3-a", third) {})
    }

    /// Two answers in flight (finding 4700-I3): the older one is past its
    /// check and still applying when the newer one arrives. The newer one
    /// waits for it and applies last, so the store ends on the newer list.
    func testAnOlderReadStillApplyingWhenANewerOneArrivesIsAppliedFirst() async throws {
        let fixture = try await fixture()
        let binding = try fixture.open("db3-a")
        let order = RecordLogIndexReadOrder()
        let older = order.issue("db3-a")
        let newer = order.issue("db3-a")
        let titles = [entry("Note", ["title"])]
        let slugs = [entry("Note", ["slug"])]
        let applied = try Self.interleave(
            order, "db3-a", older: older, newer: newer,
            applyOlder: { _ = try binding.withOperation { try binding.store.syncIndexes(titles) } },
            applyNewer: { _ = try binding.withOperation { try binding.store.syncIndexes(slugs) } }
        )
        XCTAssertEqual(applied, [older, newer], "the newer answer waits for the older one's application")
        XCTAssertEqual(try binding.store.indexTuples(), [tuple("Note", ["slug"], false)], "the store ends on the newer list")
    }

    /// Start applying `older`, hold it inside its application, then apply
    /// `newer` from another thread; release `older` once `newer` had a chance
    /// to run. Answers the reads in the order their applications finished.
    private static func interleave(
        _ order: RecordLogIndexReadOrder, _ documentId: String, older: Int, newer: Int,
        applyOlder: @escaping @Sendable () throws -> Void, applyNewer: @escaping @Sendable () throws -> Void
    ) throws -> [Int] {
        let finished = LockedBox<[Int]>([])
        let failures = LockedBox<[String]>([])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let run = { (read: Int, body: @escaping @Sendable () throws -> Void, hold: Bool) in
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                do {
                    try order.apply(documentId, read) {
                        if hold {
                            entered.signal()
                            release.wait()
                        }
                        try body()
                        finished.withValue { $0.append(read) }
                    }
                } catch {
                    failures.withValue { $0.append("\(read): \(error)") }
                }
            }
        }
        run(older, applyOlder, true)
        entered.wait()
        run(newer, applyNewer, false)
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        done.wait()
        XCTAssertEqual(failures.value, [])
        return finished.value
    }

    // MARK: - Edge 31: any stored type under an expression index

    func testAnIndexIsBuiltOverRowsHoldingAnyStoredType() async throws {
        let fixture = try await fixture()
        try fixture.seed("db3-a", "Note", [
            ["id": "n1", "title": "text"], ["id": "n2", "title": 5], ["id": "n3", "title": ["a", "b"]],
            ["id": "n4", "title": ["k": "v"]], ["id": "n5", "title": nil], ["id": "n6"],
        ])
        let store = try store(fixture, "db3-a")
        XCTAssertEqual(try store.syncIndexes([entry("Note", ["title"])]).created, 1)
        XCTAssertEqual(try store.queryView("Note", ["title": 5]).data.compactMap { $0["id"]?.stringValue }, ["n2"])
        XCTAssertEqual(try store.queryView("Note", ["title": "text"]).data.compactMap { $0["id"]?.stringValue }, ["n1"])
    }

    // MARK: - Edge 35: each file builds its own

    func testTwoProvidersEachBuildTheirOwnIndexes() async throws {
        let one = try await fixture()
        let two = try await fixture()
        try store(one, "db3-a").syncIndexes([entry("Note", ["title"])])
        try store(two, "db3-a").syncIndexes([entry("Note", ["title"])])
        try one.provider.withConnection { try $0.executeScript("DROP INDEX idx_record_log_view_4_note_5_title") }
        XCTAssertEqual(try store(one, "db3-a").indexTuples(), [])
        XCTAssertEqual(try store(two, "db3-a").indexTuples(), [tuple("Note", ["title"], false)])
    }
}
