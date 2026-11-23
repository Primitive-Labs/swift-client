import XCTest
@testable import JsBaoClient

/// #5322 behavior 27 and edge cases 35 and 44 (Swift) — a device store's index
/// builds are contained, its member and text pointers name only tables it
/// holds, and the device's own index policy (`record_log_index_policy`,
/// storage version 8) decides what it builds: the port of js-bao's store, over
/// a file-backed store.
///
/// Disk full is SQLite's own: `PRAGMA max_page_count` lowered on the store's
/// connection a few pages above what it holds (the free list taken first by a
/// filler table), and put back by setting the saved positive value again and
/// reading it back (SQLite ignores `PRAGMA max_page_count = 0`).
final class Db3IndexPolicyStoreHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []
    private let lines = CapturedLines()

    override func setUp() {
        super.setUp()
        let lines = self.lines
        Logger.lineForTest = { level, _, message in lines.append(level, message) }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    /// The log lines the tests read, as they came.
    final class CapturedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(level: LogLevel, message: String)] = []

        func append(_ level: LogLevel, _ message: String) { lock.withLock { lines.append((level, message)) } }

        func about(_ name: String, _ level: LogLevel) -> [String] {
            lock.withLock { lines.filter { $0.level == level && $0.message.contains(name) }.map(\.message) }
        }
    }

    private static let film = "Film"
    private static let tag = "Tag"

    private func world(_ label: String) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("policy-\(label)", logger: Logger(level: .debug))
        worlds.append(world)
        return world
    }

    /// A synced store of `documentId` over `world`'s file with the client's `deviceIndexes` default.
    private func store(
        _ world: Db3DeviceIndexWorld, _ documentId: String, deviceIndexes: Db3DeviceIndexes = .all, localOnly: Bool = false
    ) throws -> RecordLogStore {
        let store = RecordLogStore(host: world.provider, documentId: documentId, clientId: "client-1", logger: world.logger, deviceIndexes: deviceIndexes)
        try store.initialize()
        let writer = try store.mintWriter()
        _ = try store.setState(writer: writer, localOnly: localOnly ? true : nil)
        return store
    }

    /// `count` Film rows and the Tag rows, written into `documentId` as the room's results.
    private func seed(_ store: RecordLogStore, films count: Int, from: Int = 1) throws {
        let genres = ["Action", "Comedy", "Drama", "Horror", "Western", "Sci-Fi"]
        var next = try store.marks().cursor
        var items: [RecordLogResultItem] = []
        func flush() throws {
            guard !items.isEmpty else { return }
            _ = try store.receive(writer: try XCTUnwrap(try store.writer()), items: items)
            items = []
        }
        for n in from..<(from + count) {
            next += 1
            let id = String(format: "f%06d", n)
            let row: [String: JSONValue] = [
                "id": .string(id), "title": .string("film number \(n) of a long and wordy catalogue \(n * 31)"),
                "year": .number(Double(1900 + n % 120)),
                "genres": .array(Array(Set([genres[n % genres.count], genres[(n * 7) % genres.count]])).sorted().map { .string($0) }),
            ]
            items.append(.result(RecordLogResult(l: next, e: 1, changes: [RecordLogChange(model: Self.film, id: id, row: row)])))
            if items.count == 2000 { try flush() }
        }
        for (i, title) in ["red apple", "green pear", "red cherry"].enumerated() {
            next += 1
            let id = "t\(i + 1)"
            items.append(.result(RecordLogResult(l: next, e: 1, changes: [
                RecordLogChange(model: Self.tag, id: id, row: ["id": .string(id), "title": .string(title)]),
            ])))
        }
        try flush()
    }

    private func pragma(_ world: Db3DeviceIndexWorld, _ name: String) throws -> Int {
        try world.rows("PRAGMA \(name)").first.flatMap { $0.columns.values.first?.intValue } ?? 0
    }

    /// Lower the file's page limit to `headroom` pages above what it holds; answers what puts it back.
    private func limitPages(_ world: Db3DeviceIndexWorld, headroom: Int = 40) throws -> () throws -> Void {
        let saved = try pragma(world, "max_page_count")
        var rounds = 0
        while try pragma(world, "freelist_count") > 0, rounds < 50 {
            let free = try pragma(world, "freelist_count")
            try world.exec("CREATE TABLE IF NOT EXISTS pl_disk_filler_5322 (b BLOB)")
            try world.exec(
                "INSERT INTO pl_disk_filler_5322 (b) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) SELECT zeroblob(3800) FROM n",
                [.integer(Int64(free))]
            )
            rounds += 1
        }
        let pages = try pragma(world, "page_count")
        _ = try world.rows("PRAGMA max_page_count = \(pages + headroom)")
        XCTAssertEqual(try pragma(world, "max_page_count"), pages + headroom)
        return {
            _ = try world.rows("PRAGMA max_page_count = \(saved)")
            XCTAssertEqual(try self.pragma(world, "max_page_count"), saved, "the saved page limit is back")
            try world.exec("DROP TABLE IF EXISTS pl_disk_filler_5322")
        }
    }

    private func scalar(_ model: String, _ field: String, unique: Bool = false, name: String? = nil) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: name ?? "idx_records_\(model.lowercased())_\(field)", model: model, fields: [field], unique: unique, on: .device)
    }

    private func members(_ model: String, _ field: String, on: Db3IndexPlacement = .device) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: "idx_members_\(model.lowercased())_\(field)", model: model, fields: [field], unique: false, kind: .members, on: on)
    }

    private func text(_ model: String, _ fields: [String], on: Db3IndexPlacement = .device, name: String? = nil) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: name ?? "idx_text_\(model.lowercased())", model: model, fields: fields, unique: false, kind: .text, on: on)
    }

    private func vector(_ model: String, _ field: String) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: "idx_vec_\(model.lowercased())_\(field)", model: model, fields: [field], unique: false, kind: .vector, on: .device)
    }

    private var list: [RecordLogIndexEntry] {
        [scalar(Self.film, "year"), members(Self.film, "genres"), text(Self.film, ["title"]), text(Self.tag, ["title"])]
    }

    private func cached(_ world: Db3DeviceIndexWorld, _ documentId: String) throws -> [Format2SqlRow] {
        try world.rows(
            "SELECT model, kind, room_name, members, text, options FROM record_log_indexes WHERE doc_id = ? ORDER BY model, kind", [.text(documentId)]
        )
    }

    private func unbuilt(_ row: Format2SqlRow?) -> String? {
        row?["options"].stringValue.flatMap(RecordLogJSON.parse)?["unbuilt"]?.stringValue
    }

    /// The objects of a device family, as `type:name`.
    private func family(_ world: Db3DeviceIndexWorld, _ name: String) throws -> [String] {
        let which = name == "text" ? "(type = 'trigger' OR sql LIKE 'CREATE VIRTUAL%')" : name == "members" ? "type IN ('table', 'trigger')" : "type = 'index'"
        return try world.rows(
            "SELECT type, name FROM sqlite_master WHERE name LIKE ? ESCAPE '\\' AND \(which) ORDER BY type, name",
            [.text("idx\\_record\\_log\\_\(name)\\_%")]
        ).map { "\($0["type"].stringValue ?? ""):\($0["name"].stringValue ?? "")" }
    }

    private func status(_ store: RecordLogStore, _ name: String) throws -> Db3LocalIndex? {
        try store.localIndexes().first { $0.name == name }
    }

    private func policy(_ world: Db3DeviceIndexWorld) throws -> [String] {
        try world.rows("SELECT doc_id, model, fields, kind, verdict FROM record_log_index_policy ORDER BY doc_id, model, kind").map {
            "\($0["doc_id"].stringValue ?? "") \($0["model"].stringValue ?? "") \($0["fields"].stringValue ?? "") \($0["kind"].stringValue ?? "") \($0["verdict"].stringValue ?? "")"
        }
    }

    private func refusal(_ body: () throws -> Void) -> JsBaoError? {
        do {
            try body()
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    // MARK: - Storage version 8

    func testStorageVersion8KeepsThePolicyOutsideThePurgedTablesAndAVersion7FileMigrates() async throws {
        let world = try await world("v8")
        let store = try store(world, "db3-a")
        try seed(store, films: 50)
        try store.syncIndexes(list)
        // 8 or later: #5230 raised it to 9 for the vector entry's flat table.
        XCTAssertGreaterThanOrEqual(RecordLogSchema.storageVersion, 8)
        XCTAssertEqual(
            try world.rows("SELECT name FROM pragma_table_info('record_log_index_policy') ORDER BY cid").compactMap { $0["name"].stringValue },
            ["doc_id", "model", "fields", "kind", "verdict", "at"]
        )
        XCTAssertFalse(RecordLogSchema.clientTables.contains("record_log_index_policy"))
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        // Planted as version 7 kept it: no policy table.
        let before = try family(world, "members") + family(world, "text") + family(world, "view")
        try world.exec("DROP TABLE record_log_index_policy")
        try world.exec("UPDATE record_log_meta SET value = '7' WHERE key = 'storage_version'")
        let reopened = try world.reopen("db3-a")
        XCTAssertEqual(try world.version(), String(RecordLogSchema.storageVersion))
        XCTAssertEqual(try world.rows("SELECT COUNT(*) AS n FROM record_log_index_policy").first?["n"].intValue, 0)
        XCTAssertEqual(try family(world, "members") + family(world, "text") + family(world, "view"), before)
        XCTAssertEqual(try reopened.storedState().rows, 53)
    }

    // MARK: - Contained builds

    func testAScalarBuildThatFillsTheDiskIsKeptUnbuiltWarnedOnceAndBuiltOnceThereIsRoom() async throws {
        let world = try await world("scalar")
        let store = try store(world, "db3-a")
        try seed(store, films: 20_000)
        let entries = [scalar(Self.film, "title"), text(Self.tag, ["title"])]
        let restore = try limitPages(world)
        XCTAssertNoThrow(try store.syncIndexes(entries))
        let rows = try cached(world, "db3-a")
        XCTAssertEqual(rows.map { "\($0["model"].stringValue ?? ""):\($0["kind"].stringValue ?? "")" }, ["Film:scalar", "Tag:text"])
        XCTAssertTrue(unbuilt(rows.first)?.contains("database or disk is full") == true, "\(String(describing: unbuilt(rows.first)))")
        XCTAssertNotNil(rows.last?["text"].stringValue)
        XCTAssertNil(unbuilt(rows.last))
        XCTAssertEqual(try family(world, "view"), [])
        XCTAssertEqual(lines.about("idx_records_film_title", .warn).count, 1)
        XCTAssertTrue(lines.about("idx_records_film_title", .warn).first?.contains("scalar index idx_records_film_title on Film is not built") == true)
        try store.syncIndexes(entries)
        XCTAssertEqual(lines.about("idx_records_film_title", .warn).count, 1, "the same failure again is said at debug")
        XCTAssertFalse(lines.about("idx_records_film_title", .debug).filter { $0.contains("is not built") }.isEmpty)
        try restore()
        try store.syncIndexes(entries)
        XCTAssertEqual(try family(world, "view").count, 1)
        XCTAssertNil(unbuilt(try cached(world, "db3-a").first))
        XCTAssertEqual(try status(store, "idx_records_film_title")?.status, .built)
    }

    func testAMemberFillThatFailsLeavesNothingAndItsPointerNamesNoTable() async throws {
        let world = try await world("members")
        let store = try store(world, "db3-a")
        try seed(store, films: 20_000)
        let restore = try limitPages(world)
        XCTAssertNoThrow(try store.syncIndexes([members(Self.film, "genres")]))
        let row = try cached(world, "db3-a").first
        XCTAssertNil(row?["members"].stringValue)
        XCTAssertTrue(unbuilt(row)?.contains("database or disk is full") == true)
        XCTAssertEqual(try family(world, "members"), [])
        XCTAssertNil(try store.readView { try RecordLogIndexes.memberTable($0, documentId: "db3-a", model: Self.film, field: "genres") })
        try restore()
        // The view's later writes raise no trigger error.
        try world.commit("db3-a", [RecordLogMutation(model: Self.film, id: "late", kind: .create, fields: ["title": "late", "genres": ["Drama"]])])
        try store.syncIndexes([members(Self.film, "genres")])
        let table = try XCTUnwrap(try cached(world, "db3-a").first?["members"].stringValue)
        XCTAssertEqual(try family(world, "members").count, 4)
        XCTAssertFalse(try world.rows("SELECT 1 FROM sqlite_stat1 WHERE tbl = ?", [.text(table)]).isEmpty)
        XCTAssertEqual(try world.drift(), [])
    }

    func testATextFillThatFailsLeavesNothingAndTheListItCameWithIsCached() async throws {
        let world = try await world("text")
        let store = try store(world, "db3-a")
        try seed(store, films: 20_000)
        try store.syncIndexes([scalar(Self.tag, "title")])
        let restore = try limitPages(world)
        XCTAssertNoThrow(try store.syncIndexes([text(Self.film, ["title"]), scalar(Self.tag, "title", name: "idx_records_tag_title_renamed")]))
        XCTAssertEqual(
            try cached(world, "db3-a").map { "\($0["model"].stringValue ?? ""):\($0["kind"].stringValue ?? ""):\($0["room_name"].stringValue ?? "")" },
            ["Film:text:idx_text_film", "Tag:scalar:idx_records_tag_title_renamed"]
        )
        XCTAssertNil(try cached(world, "db3-a").first?["text"].stringValue)
        XCTAssertEqual(try family(world, "text"), [])
        try restore()
    }

    // MARK: - Status, decline and accept

    func testLocalIndexesListsEachIndexPlacedOnTheDevice() async throws {
        let world = try await world("local")
        let store = try store(world, "db3-a")
        try seed(store, films: 100)
        try store.syncIndexes([
            scalar(Self.film, "year"), members(Self.film, "genres"), text(Self.tag, ["title"], on: .both), text(Self.film, ["title"], on: .server),
            vector(Self.film, "embedding"),
        ])
        XCTAssertEqual(try store.localIndexes(), [
            Db3LocalIndex(name: "idx_members_film_genres", model: Self.film, fields: ["genres"], kind: .members, on: .device, status: .built),
            Db3LocalIndex(name: "idx_records_film_year", model: Self.film, fields: ["year"], kind: .scalar, on: .device, status: .built),
            Db3LocalIndex(name: "idx_text_tag", model: Self.tag, fields: ["title"], kind: .text, on: .both, status: .built),
            Db3LocalIndex(
                name: "idx_vec_film_embedding", model: Self.film, fields: ["embedding"], kind: .vector, on: .device, status: .unbuilt,
                reason: RecordLogIndexes.vectorUnbuilt
            ),
        ])
    }

    func testAMemberIndexPlacedOnBothIsListedDeclinedAndAccepted() async throws {
        let world = try await world("members-both")
        let both = try store(world, "db3-a")
        try seed(both, films: 100)
        try both.syncIndexes([members(Self.film, "genres", on: .both)])
        XCTAssertEqual(try both.localIndexes(), [
            Db3LocalIndex(name: "idx_members_film_genres", model: Self.film, fields: ["genres"], kind: .members, on: .both, status: .built),
        ])
        XCTAssertEqual(try both.declineIndex("idx_members_film_genres").status, .declined)
        XCTAssertEqual(try family(world, "members"), [])
        XCTAssertEqual(try both.acceptIndex("idx_members_film_genres").status, .built)

        let excluded = try store(world, "db3-b", deviceIndexes: .kinds([.scalar]))
        try seed(excluded, films: 10)
        try excluded.syncIndexes([members(Self.film, "genres", on: .both)])
        XCTAssertEqual(try excluded.localIndexes(), [
            Db3LocalIndex(
                name: "idx_members_film_genres", model: Self.film, fields: ["genres"], kind: .members, on: .both, status: .declined,
                reason: "the client's deviceIndexes option excludes members"
            ),
        ])
        XCTAssertEqual(try excluded.acceptIndex("idx_members_film_genres").status, .built)
    }

    func testDeclineDropsTheTableAndRemembersTheIdentity() async throws {
        let world = try await world("decline")
        let store = try store(world, "db3-a")
        try seed(store, films: 100)
        try store.syncIndexes(list + [scalar(Self.film, "title", unique: true)])
        XCTAssertEqual(
            try store.declineIndex("idx_text_film"),
            Db3LocalIndex(name: "idx_text_film", model: Self.film, fields: ["title"], kind: .text, on: .device, status: .declined, reason: "declined on this device")
        )
        XCTAssertEqual(try policy(world), ["db3-a Film [\"title\"] text declined"])
        XCTAssertNil(try world.rows("SELECT text FROM record_log_indexes WHERE model = 'Film' AND kind = 'text'").first?["text"].stringValue)
        XCTAssertFalse(try family(world, "text").contains { $0.contains("_4_film") })
        XCTAssertFalse(lines.about("idx_text_film declined on this device", .info).isEmpty)
        let master = try world.objects()
        XCTAssertEqual(try store.declineIndex("idx_text_film").status, .declined)
        XCTAssertEqual(try world.objects(), master)

        XCTAssertEqual(try store.declineIndex("idx_members_film_genres").status, .declined)
        XCTAssertEqual(try family(world, "members"), [])
        XCTAssertNil(try store.readView { try RecordLogIndexes.memberTable($0, documentId: "db3-a", model: Self.film, field: "genres") })

        XCTAssertEqual(try family(world, "view").count, 2)
        XCTAssertEqual(try family(world, "rows").count, 1)
        _ = try store.declineIndex("idx_records_film_title")
        XCTAssertEqual(try family(world, "view").count, 1)
        XCTAssertEqual(try family(world, "rows"), [])

        let unknown = refusal { _ = try store.declineIndex("nope") }
        XCTAssertEqual(unknown?.code, .db3IndexNotFound)
        XCTAssertEqual(unknown?.details?["index"], "nope")
    }

    func testAcceptRebuildsWhateverLeftAnIndexUnbuilt() async throws {
        let world = try await world("accept")
        let store = try store(world, "db3-a")
        try seed(store, films: 20_000)
        let entries = [scalar(Self.film, "title"), members(Self.film, "genres")]
        let restore = try limitPages(world)
        try store.syncIndexes(entries)
        XCTAssertEqual(try status(store, "idx_records_film_title")?.status, .unbuilt)
        XCTAssertEqual(try status(store, "idx_members_film_genres")?.status, .unbuilt)
        let still = try store.acceptIndex("idx_records_film_title")
        XCTAssertEqual(still.status, .unbuilt)
        XCTAssertTrue(still.reason?.contains("disk is full") == true)
        XCTAssertEqual(try policy(world), ["db3-a Film [\"title\"] scalar accepted"])
        try restore()
        XCTAssertEqual(try store.acceptIndex("idx_members_film_genres").status, .built)
        try store.syncIndexes(entries)
        XCTAssertEqual(try status(store, "idx_records_film_title")?.status, .built)
        // Declined, then accepted: rebuilt from the view's rows.
        _ = try store.declineIndex("idx_members_film_genres")
        XCTAssertEqual(try store.acceptIndex("idx_members_film_genres").status, .built)
        XCTAssertEqual(try world.drift(), [])
        // Already built: nothing is rebuilt.
        let master = try world.objects()
        XCTAssertEqual(try store.acceptIndex("idx_members_film_genres").status, .built)
        XCTAssertEqual(try world.objects(), master)
    }

    func testADeclineLastsAcrossARefreshARenameAndAPurge() async throws {
        let world = try await world("lasts")
        let store = try store(world, "db3-a")
        try seed(store, films: 100)
        try store.syncIndexes(list)
        _ = try store.declineIndex("idx_text_film")
        let film = { try self.family(world, "text").filter { $0.contains("_4_film") } }
        try store.syncIndexes(list + [scalar(Self.tag, "title")])
        XCTAssertEqual(try film(), [])
        XCTAssertEqual(try status(store, "idx_text_film")?.status, .declined)
        XCTAssertEqual(try status(store, "idx_records_tag_title")?.status, .built)
        let renamed = [scalar(Self.film, "year"), members(Self.film, "genres"), text(Self.film, ["title"], name: "idx_text_film_2")]
        try store.syncIndexes(renamed)
        XCTAssertEqual(try film(), [])
        XCTAssertEqual(try status(store, "idx_text_film_2")?.status, .declined)
        _ = try store.purge(force: true)
        XCTAssertEqual(try policy(world), ["db3-a Film [\"title\"] text declined"])
        let again = try self.store(world, "db3-a")
        try seed(again, films: 50)
        try again.syncIndexes(renamed)
        XCTAssertEqual(try film(), [])
        XCTAssertEqual(try status(again, "idx_text_film_2")?.status, .declined)
        XCTAssertEqual(try status(again, "idx_members_film_genres")?.status, .built)
    }

    func testTheDeviceIndexesDefault() async throws {
        let world = try await world("default")
        let none = try store(world, "db3-a", deviceIndexes: .none)
        try seed(none, films: 100)
        try none.syncIndexes(list)
        XCTAssertEqual(try family(world, "view") + family(world, "members") + family(world, "text"), [])
        for index in try none.localIndexes() {
            XCTAssertEqual(index.status, .declined, index.name)
            XCTAssertEqual(index.reason, "the client's deviceIndexes option excludes \(index.kind.rawValue)", index.name)
        }
        XCTAssertNil(try none.readView { try RecordLogIndexes.memberTable($0, documentId: "db3-a", model: Self.film, field: "genres") })
        // Accepted overrides none.
        XCTAssertEqual(try none.acceptIndex("idx_text_tag").status, .built)

        let scalarOnly = try store(world, "db3-b", deviceIndexes: .kinds([.scalar]))
        try seed(scalarOnly, films: 10)
        try scalarOnly.syncIndexes(list)
        XCTAssertEqual(try scalarOnly.localIndexes().map { "\($0.name):\($0.status.rawValue)" }, [
            "idx_members_film_genres:declined", "idx_records_film_year:built", "idx_text_film:declined", "idx_text_tag:declined",
        ])

        // Built under all, kept under none; declined stays unbuilt under all.
        let all = try store(world, "db3-c")
        try seed(all, films: 10)
        try all.syncIndexes(list)
        _ = try all.declineIndex("idx_text_tag")
        let reopened = RecordLogStore(host: world.provider, documentId: "db3-c", clientId: "client-1", logger: world.logger, deviceIndexes: .none)
        try reopened.initialize()
        try reopened.syncIndexes(list)
        XCTAssertEqual(try reopened.localIndexes().map { "\($0.name):\($0.status.rawValue)" }, [
            "idx_members_film_genres:built", "idx_records_film_year:built", "idx_text_film:built", "idx_text_tag:declined",
        ])
        try all.syncIndexes(list)
        XCTAssertEqual(try status(all, "idx_text_tag")?.status, .declined)
    }

    func testAPurgeKeepsThePolicyUnlessAskedToClearItAndTheFileStaysWithIt() async throws {
        let world = try await world("purge")
        let store = try store(world, "db3-a")
        try seed(store, films: 20)
        try store.syncIndexes(list)
        _ = try store.declineIndex("idx_text_film")
        XCTAssertTrue(try store.purge(force: true).purged)
        XCTAssertEqual(try policy(world), ["db3-a Film [\"title\"] text declined"])
        for table in RecordLogSchema.clientTables {
            XCTAssertEqual(try world.rows("SELECT COUNT(*) AS n FROM \(table) WHERE doc_id = 'db3-a'").first?["n"].intValue, 0, table)
        }
        // Swift keeps no scope files to reclaim: the store's file stays (pin).
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.directory + "/store.sqlite"))
        XCTAssertTrue(try store.purge(force: true, policy: .clear).purged)
        XCTAssertEqual(try policy(world), [])
    }

    func testALocalOnlyDb3HasNoPolicy() async throws {
        let world = try await world("local-only")
        let store = try store(world, "db3-l", deviceIndexes: .none, localOnly: true)
        try seed(store, films: 10)
        try store.syncIndexes([scalar(Self.film, "year"), members(Self.film, "genres")])
        XCTAssertEqual(try store.localIndexes().map(\.status), [.built, .built])
        XCTAssertEqual(refusal { _ = try store.declineIndex("idx_records_film_year") }?.code, .db3LocalOnly)
        XCTAssertEqual(refusal { _ = try store.acceptIndex("idx_records_film_year") }?.code, .db3LocalOnly)
    }
}
