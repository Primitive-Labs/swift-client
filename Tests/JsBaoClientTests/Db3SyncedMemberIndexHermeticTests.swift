import XCTest
@testable import JsBaoClient

/// #5223 behavior 6 — on a synced db3 a `members` entry placed `device` or
/// `both` is cached with its device table and built with #5156's table and
/// three triggers, statistics gathered after the build; one placed `server`,
/// or with no `on` (a member index without `on` is the room's), caches and
/// builds nothing.
final class Db3SyncedMemberIndexStoreHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world() async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("synced-members")
        worlds.append(world)
        return world
    }

    static func member(_ field: String, on: Db3IndexPlacement?, model: String = "Note") -> RecordLogIndexEntry {
        RecordLogIndexEntry(
            name: "idx_members_\(model.lowercased())_\(field)", model: model, fields: [field], unique: false, kind: .members, on: on
        )
    }

    /// The device table `documentId`'s member index on `model.field` is kept in.
    static func table(_ documentId: String, _ field: String, model: String = "Note") -> String {
        RecordLogIndexes.memberTableName(documentId: documentId, model: model, field: field)
    }

    private func family(_ world: Db3DeviceIndexWorld) throws -> [String] {
        try world.rows(#"SELECT type, name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_members\_%' ESCAPE '\' ORDER BY type, name"#)
            .map { "\($0["type"].stringValue ?? "") \($0["name"].stringValue ?? "")" }
    }

    private func familyOf(_ table: String) -> [String] {
        ["table \(table)", "trigger \(table)__d", "trigger \(table)__i", "trigger \(table)__u"]
    }

    private func statistics(_ world: Db3DeviceIndexWorld) throws -> [String] {
        guard try !world.rows("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'").isEmpty else { return [] }
        return Array(Set(try world.rows("SELECT tbl FROM sqlite_stat1").compactMap { $0["tbl"].stringValue })).sorted()
    }

    private func mark(_ world: Db3DeviceIndexWorld) throws -> Int? {
        try world.rows("SELECT value FROM record_log_meta WHERE key = 'statistics_rowid'").first?["value"].intValue
    }

    private func seeded(_ world: Db3DeviceIndexWorld) throws -> RecordLogStore {
        let store = try world.store("db3-s")
        try world.seed("db3-s", "Note", [
            ["id": "r1", "tags": ["a", "b"], "labels": ["x"]], ["id": "r2", "tags": ["b", "c"], "labels": ["x", "y"]],
            ["id": "r3", "tags": "a"], ["id": "r4", "title": "none"],
        ])
        return store
    }

    func testBuildsAMemberEntryPlacedOnTheDeviceOrBothAndGathersStatistics() async throws {
        let world = try await world()
        let store = try seeded(world)
        let sync = try store.syncIndexes([
            Self.member("tags", on: .device), Self.member("labels", on: .both),
            Self.member("other", on: .server), Self.member("open", on: nil),
        ])
        XCTAssertEqual(sync.created, 2)
        let tags = Self.table("db3-s", "tags")
        let labels = Self.table("db3-s", "labels")
        XCTAssertEqual(
            try world.rows("SELECT fields, kind, room_name, members FROM record_log_indexes ORDER BY fields").map {
                "\($0["fields"].stringValue ?? "") \($0["kind"].stringValue ?? "") \($0["room_name"].stringValue ?? "") \($0["members"].stringValue ?? "")"
            },
            ["[\"labels\"] members idx_members_note_labels \(labels)", "[\"tags\"] members idx_members_note_tags \(tags)"]
        )
        XCTAssertEqual(try family(world), (familyOf(labels) + familyOf(tags)).sorted())
        XCTAssertEqual(
            try world.rows("SELECT sql FROM sqlite_master WHERE name = ?", [.text(tags)]).first?["sql"].stringValue,
            "CREATE TABLE \"\(tags)\" (value TEXT NOT NULL, rid INTEGER NOT NULL, PRIMARY KEY (value, rid)) WITHOUT ROWID"
        )
        XCTAssertEqual(
            try world.rows("SELECT value FROM \"\(tags)\" ORDER BY value, rid").compactMap { $0["value"].stringValue }, ["a", "b", "b", "c"]
        )
        XCTAssertEqual(try world.drift(), [])
        XCTAssertEqual(try statistics(world), [labels, tags, "record_log_view"].sorted())
        XCTAssertEqual(try mark(world), try world.rows("SELECT MAX(rowid) AS n FROM record_log_view").first?["n"].intValue)
        // No view index for a member entry, and the same list again builds nothing.
        XCTAssertEqual(try store.indexTuples(), [])
        XCTAssertEqual(try store.syncIndexes([Self.member("tags", on: .device), Self.member("labels", on: .both)]),
                       RecordLogIndexSync(created: 0, dropped: 0))
        // The triggers keep the table as the room's results land.
        try world.seed("db3-s", "Note", [["id": "r2", "tags": ["d"]], ["id": "r5", "tags": ["a", "e"]]])
        try world.seedDeletes("db3-s", "Note", ["r1"])
        XCTAssertEqual(try world.drift(), [])
    }

    func testAServerPlacedOrUnplacedMemberEntryCachesAndBuildsNothing() async throws {
        let world = try await world()
        let store = try seeded(world)
        try store.syncIndexes([Self.member("tags", on: .device)])
        XCTAssertEqual(try family(world), familyOf(Self.table("db3-s", "tags")))
        XCTAssertEqual(try store.syncIndexes([Self.member("tags", on: .server), Self.member("labels", on: nil)]),
                       RecordLogIndexSync(created: 0, dropped: 1))
        XCTAssertEqual(try world.rows("SELECT * FROM record_log_indexes").count, 0)
        XCTAssertEqual(try family(world), [])
    }

    /// A local-only db3's member entry is cached and built whatever its `on`, as before.
    func testALocalOnlyDb3sMemberEntryBehavesAsBefore() async throws {
        let world = try await world()
        let store = try world.store("db3-l", localOnly: true)
        try world.commit("db3-l", [RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["tags": ["a"]])])
        try store.syncIndexes([RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true)])
        XCTAssertEqual(try family(world), familyOf(Self.table("db3-l", "tags")))
        XCTAssertEqual(try world.drift(), [])
    }
}

/// #5223 behavior 10 — a synced store holding a member table gathers
/// statistics once the view grows past its mark after a catch-up page, a
/// catch-up completion, a load chunk and its completion, and a segment's
/// chunk and corrections, as js-bao's `statisticsAfter` does; a store with
/// no member table gathers nothing on those paths.
final class Db3SyncedMemberIndexStatisticsHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world() async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("synced-statistics")
        worlds.append(world)
        return world
    }

    private static let genres = ["Action", "Comedy", "Drama", "Horror", "Western", "Sci-Fi", "Film-Noir", "it's", "naïve"]

    /// `count` films from `from`, as the JS behavior-17 fixture writes them: genre sets, a string, a number, none.
    private static func films(_ count: Int, from: Int = 1) -> [RecordLogCatchUpRow] {
        (from..<(from + count)).map { n in
            var row: RecordLogRow = ["id": .string(String(format: "f%05d", n)), "year": .number(Double(1950 + n % 70))]
            if n % 101 == 0 { row["genres"] = "Drama" } else if n % 103 == 0 { row["genres"] = 7 } else if n % 107 != 0 {
                row["genres"] = .array([genres[n % genres.count], genres[(n / 3) % genres.count]].map { .string($0) })
            }
            return RecordLogCatchUpRow(model: "Film", id: String(format: "f%05d", n), row: row)
        }
    }

    private static let member = RecordLogIndexEntry(
        name: "idx_members_film_genres", model: "Film", fields: ["genres"], unique: false, kind: .members, on: .both
    )

    private func mark(_ world: Db3DeviceIndexWorld) throws -> Int? {
        try world.rows("SELECT value FROM record_log_meta WHERE key = 'statistics_rowid'").first?["value"].intValue
    }

    private func highest(_ world: Db3DeviceIndexWorld) throws -> Int {
        try world.rows("SELECT MAX(rowid) AS n FROM record_log_view").first?["n"].intValue ?? 0
    }

    private func statistics(_ world: Db3DeviceIndexWorld) throws -> Bool {
        try !world.rows("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'").isEmpty
    }

    func testTheMarkMovesAfterACatchUpPageAndALoadAsTheViewGrows() async throws {
        let world = try await world()
        let store = try world.store("db3-f")
        let writer = world.writer("db3-f")
        _ = try store.applyCatchUpPage(writer: writer, rows: Self.films(50), lsn: 50)
        try store.syncIndexes([Self.member])
        XCTAssertEqual(try mark(world), 50)
        _ = try store.applyCatchUpPage(writer: writer, rows: Self.films(1000, from: 100), lsn: 1100)
        XCTAssertEqual(try mark(world), 1050)
        let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "LSTATS").attempt
        _ = try store.applyLoadChunk(writer: writer, sessionId: "LSTATS", attempt: attempt, model: "Film",
                                     lines: Self.films(10_000, from: 5000).map { line in
                                         var patch = line.row
                                         patch["id"] = nil
                                         return RecordLogLoadLine(id: line.id, patch: patch)
                                     })
        XCTAssertEqual(try mark(world), 11_050)
        _ = try store.completeLoad(writer: writer, sessionId: "LSTATS", attempt: attempt, mode: .merge, models: ["Film"])
        XCTAssertEqual(try mark(world), 11_050)
        XCTAssertEqual(try world.drift(), [])
    }

    /// Each path gathers once its growth makes statistics due: the mark is
    /// set back by hand before it, and moves to the highest rowid after it.
    func testEachSyncPathGathersStatisticsOnceTheyAreDue() async throws {
        let world = try await world()
        let store = try world.store("db3-f")
        let writer = world.writer("db3-f")
        _ = try store.applyCatchUpPage(writer: writer, rows: Self.films(1200), lsn: 1200)
        try store.syncIndexes([Self.member])
        func due() throws { try world.exec("UPDATE record_log_meta SET value = '1' WHERE key = 'statistics_rowid'") }
        func gathered(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try mark(world), try highest(world), path, file: file, line: line)
        }

        try due()
        _ = try store.applyCatchUpPage(writer: writer, rows: Self.films(5, from: 2000), lsn: 1300)
        try gathered("a catch-up page")
        try due()
        _ = try store.completeCatchUp(writer: writer, lsn: 1300, at: 1)
        try gathered("a catch-up completion")
        let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "LDUE").attempt
        try due()
        _ = try store.applyLoadChunk(writer: writer, sessionId: "LDUE", attempt: attempt, model: "Film",
                                     lines: [RecordLogLoadLine(id: "f09001", patch: ["genres": ["Drama"]])])
        try gathered("a load chunk")
        try due()
        _ = try store.completeLoad(writer: writer, sessionId: "LDUE", attempt: attempt, mode: .merge, models: ["Film"])
        try gathered("a load completion")
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        try due()
        _ = try store.applySegmentChunk(writer: writer, generation: generation, rows: Self.films(1300))
        try gathered("a segment chunk")
        try due()
        _ = try store.applySegmentCorrections(writer: writer, generation: generation, lines: [
            RecordLogCorrection(model: "Film", id: "f09002", row: ["id": "f09002", "genres": ["Horror"]]),
        ])
        try gathered("a segment's corrections")
        XCTAssertEqual(try world.drift(), [])
    }

    func testAStoreWithNoMemberTableGathersNothingOnThosePaths() async throws {
        let world = try await world()
        let store = try world.store("db3-f")
        let writer = world.writer("db3-f")
        _ = try store.applyCatchUpPage(writer: writer, rows: Self.films(1200), lsn: 1200)
        _ = try store.completeCatchUp(writer: writer, lsn: 1200, at: 1)
        let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "LNONE").attempt
        _ = try store.applyLoadChunk(writer: writer, sessionId: "LNONE", attempt: attempt, model: "Film",
                                     lines: [RecordLogLoadLine(id: "f09001", patch: ["genres": ["Drama"]])])
        _ = try store.completeLoad(writer: writer, sessionId: "LNONE", attempt: attempt, mode: .merge, models: ["Film"])
        XCTAssertFalse(try statistics(world))
        XCTAssertNil(try mark(world))
    }
}

/// #5223 behavior 15 and edge case E11 — a synced db3 whose member index is
/// placed on the device answers every set shape the same as a copy without
/// it (#5156's read fixture of 600 notes and the odd members, the rows
/// arriving as the room's results): `$contains`, an any-of, a membership
/// level and an unfiltered facet read the device table, a sorted facet
/// orders tied members by the member as the room does, and every other read
/// emits the statement it emits without the table; a read over two db3s
/// reads `_data`.
final class Db3SyncedMemberIndexReadsHermeticTests: XCTestCase {

    private static let genres = ["Action", "Comedy", "Drama", "Horror", "Romance", "Sci-Fi", "Thriller", "War", "Western"]
    private static let odd = ["it's", "back\\slash", "naïve"]
    private static let document = "db3-reads"
    private static var table: String { Db3SyncedMemberIndexStoreHermeticTests.table(document, "tags") }
    private static var probe: String { "record_log_view.rowid IN (SELECT rid FROM \"\(table)\" WHERE value = ?)" }

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    /// #5156's 600 deterministic Notes and the edge records, as the room's rows.
    private static func fixture() -> [JSONValue] {
        var state: UInt32 = 5156
        func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
        var out: [JSONValue] = []
        for n in 1...600 {
            var tags = Set<String>()
            for _ in 0..<Int(next() * 4) { tags.insert(genres[Int(next() * Double(genres.count))]) }
            out.append([
                "id": .string(String(format: "n%04d", n)), "title": .string("t\(Int(next() * 50))"),
                "year": .number(Double(1950 + Int(next() * 70))), "labels": ["l"], "tags": .array(tags.sorted().map { .string($0) }),
            ])
        }
        out.append(["id": "e1", "title": "string", "tags": "Drama"])
        out.append(["id": "e2", "title": "empty", "tags": []])
        out.append(["id": "e3", "title": "none"])
        out.append(["id": "e4", "title": "number", "tags": 7])
        out.append(["id": "e5", "title": "object", "tags": ["a": "Drama"]])
        out.append(["id": "e6", "title": "odd", "year": 1980, "tags": .array(odd.map { .string($0) })])
        return out
    }

    /// The fixture in a synced store, its member index on `tags` placed on the device when `indexed` (synced after the rows).
    private func world(indexed: Bool) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make(indexed ? "synced-indexed" : "synced-plain")
        worlds.append(world)
        try world.store(Self.document)
        try world.seed(Self.document, "Note", Self.fixture())
        if indexed { try world.store(Self.document).syncIndexes([Db3SyncedMemberIndexStoreHermeticTests.member("tags", on: .device)]) }
        return world
    }

    private static let filters: [(String, DocumentFilter)] = [
        ("contains", ["tags": ["$contains": "Drama"]]),
        ("anyOf", ["$or": [["tags": ["$contains": "War"]], ["tags": ["$contains": "Western"]]]]),
        ("all", ["tags": ["$all": ["Drama", "Comedy"]]]),
        ("size", ["tags": ["$size": 2]]),
        ("sizeZero", ["tags": ["$size": 0]]),
        ("containsText", ["tags": ["$containsText": "ram"]]),
        ("startsWith", ["tags": ["$startsWith": "Sci"]]),
        ("containsAndRange", ["tags": ["$contains": "Comedy"], "year": ["$gte": 2000]]),
        ("containsNobody", ["tags": ["$contains": "Nobody"]]),
        ("quote", ["tags": ["$contains": "it's"]]),
        ("backslash", ["tags": ["$contains": "back\\slash"]]),
        ("nonAscii", ["tags": ["$contains": "naïve"]]),
        ("notOptedIn", ["labels": ["$contains": "l"]]),
    ]

    private static let count = AggregateOperation(type: .count)
    private static let avg = AggregateOperation(type: .avg, field: "year")
    private static var unsorted: [(String, AggregateOptions)] { [
        ("facet", AggregateOptions(groupBy: ["tags"], operations: [count])),
        ("facetAvg", AggregateOptions(groupBy: ["tags"], operations: [count, avg])),
        ("facetFiltered", AggregateOptions(groupBy: ["tags"], operations: [count], filter: ["year": ["$gte": 2000]])),
        ("membership", AggregateOptions(groupBy: [.stringSetMembership(field: "tags", contains: "Drama")], operations: [count, avg])),
    ] }

    private func reader(_ world: Db3DeviceIndexWorld, _ documents: [String] = [document]) throws -> RecordLogViewReader {
        RecordLogViewReader(store: try world.store(Self.document), documents: documents)
    }

    private func ids(_ world: Db3DeviceIndexWorld, _ filter: DocumentFilter, sorted: Bool = false) throws -> [String] {
        let options = QueryOptions(sortOrder: sorted ? [("year", -1), ("id", 1)] : nil, limit: 10_000)
        return try world.store(Self.document).queryView("Note", filter, options: options).data.compactMap { $0["id"]?.stringValue }
    }

    private func texts(_ rows: [[String: JSONValue]]) -> Set<String> { Set(rows.map { RecordLogJSON.text(.object($0)) }) }

    func testEveryShapeAnswersTheSameFromTheTableAsFromACopyWithoutIt() async throws {
        let indexed = try await world(indexed: true)
        let plain = try await world(indexed: false)
        for (name, filter) in Self.filters {
            XCTAssertEqual(Set(try ids(indexed, filter)), Set(try ids(plain, filter)), "\(name): unsorted")
            XCTAssertEqual(try ids(indexed, filter, sorted: true), try ids(plain, filter, sorted: true), "\(name): sorted")
            XCTAssertEqual(try indexed.store(Self.document).countView("Note", filter), try plain.store(Self.document).countView("Note", filter), name)
        }
        for (name, options) in Self.unsorted {
            let fromTable = try reader(indexed).aggregate("Note", options, setFields: ["tags"])
            let fromData = try reader(plain).aggregate("Note", options, setFields: ["tags"])
            XCTAssertFalse(fromData.isEmpty, name)
            XCTAssertEqual(texts(fromTable), texts(fromData), name)
        }
        let sortedByMember = AggregateOptions(groupBy: ["tags"], operations: [Self.count], sort: AggregateSort(field: "tags", direction: -1), limit: 5)
        XCTAssertEqual(try reader(indexed).aggregate("Note", sortedByMember, setFields: ["tags"]),
                       try reader(plain).aggregate("Note", sortedByMember, setFields: ["tags"]))
        // E11: a facet sorted by count orders the members it leaves tied by the member, as the room does.
        let all = try reader(plain).aggregate("Note", AggregateOptions(groupBy: ["tags"], operations: [Self.count]), setFields: ["tags"])
        for (direction, limit) in [(-1, nil), (1, 4)] as [(Int, Int?)] {
            let tied = all.sorted { a, b in
                let (ca, cb) = (a["count"]?.numberValue ?? 0, b["count"]?.numberValue ?? 0)
                if ca != cb { return direction == 1 ? ca < cb : ca > cb }
                return Array((a["group"]?["tags"]?.stringValue ?? "").utf8).lexicographicallyPrecedes(Array((b["group"]?["tags"]?.stringValue ?? "").utf8))
            }
            let options = AggregateOptions(groupBy: ["tags"], operations: [Self.count], sort: AggregateSort(field: "count", direction: direction), limit: limit)
            XCTAssertEqual(try reader(indexed).aggregate("Note", options, setFields: ["tags"]), Array(tied.prefix(limit ?? tied.count)))
        }
        for member in Self.odd { XCTAssertEqual(try ids(indexed, ["tags": ["$contains": .string(member)]]), ["e6"]) }
        XCTAssertFalse(try ids(indexed, ["tags": ["$contains": "Drama"]]).contains { ["e1", "e2", "e3", "e4", "e5"].contains($0) })
    }

    func testTheIndexedShapesReadTheDeviceTableAndTheRestReadData() async throws {
        let indexed = try await world(indexed: true)
        let plain = try await world(indexed: false)
        let indexedTrace = try RecordLogStatementTrace.install(on: indexed.provider, self)
        let plainTrace = try RecordLogStatementTrace.install(on: plain.provider, self)
        func ran(_ world: Db3DeviceIndexWorld, _ trace: RecordLogStatementTrace, _ read: (Db3DeviceIndexWorld) throws -> Void) throws -> String {
            trace.clear()
            try read(world)
            return try XCTUnwrap(trace.statements.filter { statement in
                let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.hasPrefix("SELECT") && (text.contains("record_log_view") || text.contains("idx_record_log_members_"))
                    && !text.contains("record_log_indexes") && !text.contains("record_log_state")
            }.last, "a read ran")
        }
        func plan(_ statement: String) throws -> String {
            try indexed.rows("EXPLAIN QUERY PLAN \(statement)").compactMap { $0["detail"].stringValue }.joined(separator: " | ")
        }

        let contains = try ran(indexed, indexedTrace) { _ = try $0.store(Self.document).countView("Note", ["tags": ["$contains": "Drama"]]) }
        XCTAssertTrue(contains.contains(Self.probe), contains)
        XCTAssertFalse(contains.contains("json_each"), contains)
        let steps = try plan(contains)
        XCTAssertTrue(steps.contains("SEARCH record_log_view USING INTEGER PRIMARY KEY (rowid=?)"), steps)
        let page = try ran(indexed, indexedTrace) { _ = try $0.store(Self.document).queryView("Note", ["tags": ["$contains": "Drama"]]) }
        XCTAssertTrue(page.contains(Self.probe), page)
        let anyOf = try ran(indexed, indexedTrace) {
            _ = try $0.store(Self.document).countView("Note", ["$or": [["tags": ["$contains": "War"]], ["tags": ["$contains": "Western"]]]])
        }
        XCTAssertEqual(anyOf.components(separatedBy: Self.probe).count - 1, 2, anyOf)
        let membership = try ran(indexed, indexedTrace) {
            _ = try self.reader($0).aggregate("Note", AggregateOptions(groupBy: [.stringSetMembership(field: "tags", contains: "Drama")], operations: [Self.count]), setFields: ["tags"])
        }
        XCTAssertTrue(membership.contains("CASE WHEN \(Self.probe) THEN 'true' ELSE 'false' END"), membership)
        let counted = try ran(indexed, indexedTrace) {
            _ = try self.reader($0).aggregate("Note", AggregateOptions(groupBy: ["tags"], operations: [Self.count]), setFields: ["tags"])
        }
        XCTAssertTrue(counted.contains("FROM \"\(Self.table)\" AS _facet GROUP BY"), counted)
        XCTAssertFalse(counted.contains("record_log_view"), counted)
        let averaged = try ran(indexed, indexedTrace) {
            _ = try self.reader($0).aggregate("Note", AggregateOptions(groupBy: ["tags"], operations: [Self.count, Self.avg]), setFields: ["tags"])
        }
        XCTAssertTrue(averaged.contains("FROM \"\(Self.table)\" AS _facet JOIN record_log_view ON record_log_view.rowid = _facet.rid"), averaged)

        // Every other read emits the statement it emits without the table.
        for filter: DocumentFilter in [
            ["tags": ["$all": ["Drama", "Comedy"]]], ["tags": ["$size": 2]], ["tags": ["$startsWith": "Sci"]],
            ["tags": ["$endsWith": "ma"]], ["tags": ["$containsText": "ram"]], ["labels": ["$contains": "l"]],
        ] {
            XCTAssertEqual(try ran(indexed, indexedTrace) { _ = try $0.store(Self.document).countView("Note", filter) },
                           try ran(plain, plainTrace) { _ = try $0.store(Self.document).countView("Note", filter) }, "\(filter)")
        }
        let filtered = AggregateOptions(groupBy: ["tags"], operations: [Self.count], filter: ["year": ["$gte": 2000]])
        XCTAssertEqual(try ran(indexed, indexedTrace) { _ = try self.reader($0).aggregate("Note", filtered, setFields: ["tags"]) },
                       try ran(plain, plainTrace) { _ = try self.reader($0).aggregate("Note", filtered, setFields: ["tags"]) })
        // A read over two db3s reads `_data`.
        let both = [Self.document, "db3-other"]
        let a = try ran(indexed, indexedTrace) { _ = try self.reader($0, both).count("Note", ["tags": ["$contains": "Drama"]]) }
        let b = try ran(plain, plainTrace) { _ = try self.reader($0, both).count("Note", ["tags": ["$contains": "Drama"]]) }
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.contains(Self.table), a)
    }
}
