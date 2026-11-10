import XCTest
@testable import JsBaoClient

/// #5241 behavior 15 (Swift) — the registry entries a device copy skipped,
/// the port of js-bao's store over a file-backed store.
///
/// When the store applies a db3's list it keeps, beside the cache, in
/// `record_log_index_skips`, each entry it skipped and why: placed on the
/// server only (a synced db3's), a model or field that is not an identifier,
/// an entry naming no field, an `id`-only entry the primary key serves, a
/// vector or member entry over more than one field, a text entry whose
/// options do not parse. ``RecordLogIndexes/skips(_:documentId:)`` lists them
/// by registry name; ``RecordLogIndexes/statuses(_:documentId:deviceIndexes:)``
/// is unchanged. The table is one of the copy's (an evict clears it), and
/// storage version 10 creates it on a store of version 9 or older.
final class Db3IndexSkipsStoreHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private static let doc = "01JD5241SK1PSSW1FT0000000A"
    private static let other = "01JD5241SK1PSSW1FT0000000B"
    private static let film = "Film"
    private static let tag = "Tag"
    private static let serverOnly = "placed on the server only; this device builds nothing for it"
    private static let idOnly = "the primary key serves id; no index of its own is built"

    private func world(_ label: String) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("skips-\(label)")
        worlds.append(world)
        return world
    }

    /// `documentId`'s store over `world`, holding a few Film and Tag rows.
    private func store(_ world: Db3DeviceIndexWorld, _ documentId: String = doc, localOnly: Bool = false) throws -> RecordLogStore {
        let store = try world.store(documentId, localOnly: localOnly)
        if !localOnly {
            try world.seed(documentId, Self.film, (1...20).map { n in
                .object(["id": .string("f\(n)"), "title": .string("film \(n)"), "year": .number(Double(1900 + n)), "genres": .array([.string("Drama")])])
            })
            try world.seed(documentId, Self.tag, [.object(["id": "t1", "title": "red apple"])])
        }
        return store
    }

    private func entry(
        _ name: String, _ model: String, _ fields: [String], kind: Db3IndexKind = .scalar, on: Db3IndexPlacement = .device, text: JSONValue? = nil
    ) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: name, model: model, fields: fields, unique: false, kind: kind, on: on, text: text)
    }

    private var usable: [RecordLogIndexEntry] {
        [
            entry("idx_records_film_year", Self.film, ["year"]),
            entry("idx_members_film_genres", Self.film, ["genres"], kind: .members),
            entry("idx_text_film", Self.film, ["title"], kind: .text),
        ]
    }

    /// (a)–(f): every rule the store skips an entry by.
    private var skipped: [RecordLogIndexEntry] {
        [
            entry("idx_members_film_genres_server", Self.film, ["genres"], kind: .members, on: .server),
            entry("idx_records_film_id", Self.film, ["id"], on: .both),
            entry("idx_records_film_bad", Self.film, ["bad-field"]),
            entry("idx_vec_film_two", Self.film, ["embedding", "other"], kind: .vector),
            entry("idx_text_tag_bad", Self.tag, ["title"], kind: .text, text: .object(["tokenizer": "klingon"])),
            entry("idx_text_tag_server", Self.tag, ["title"], kind: .text, on: .server),
        ]
    }

    private var expected: [Db3SkippedIndex] {
        [
            Db3SkippedIndex(name: "idx_members_film_genres_server", model: Self.film, fields: ["genres"], kind: .members, on: .server, reason: Self.serverOnly),
            Db3SkippedIndex(name: "idx_records_film_bad", model: Self.film, fields: ["bad-field"], kind: .scalar, on: .device, reason: "field 'bad-field' is not an identifier"),
            Db3SkippedIndex(name: "idx_records_film_id", model: Self.film, fields: ["id"], kind: .scalar, on: .both, reason: Self.idOnly),
            Db3SkippedIndex(
                name: "idx_text_tag_bad", model: Self.tag, fields: ["title"], kind: .text, on: .device,
                reason: "text.tokenizer must be one of \(RecordLogTextTokenizer.allCases.map(\.rawValue).joined(separator: ", "))"
            ),
            Db3SkippedIndex(name: "idx_text_tag_server", model: Self.tag, fields: ["title"], kind: .text, on: .server, reason: Self.serverOnly),
            Db3SkippedIndex(name: "idx_vec_film_two", model: Self.film, fields: ["embedding", "other"], kind: .vector, on: .device, reason: "a vector index covers one field"),
        ]
    }

    func testSkipsListsEachSkippedEntryWithItsReasonAndStatusesAreWhatTheyWereWithoutThem() async throws {
        let plainWorld = try await world("plain")
        let plain = try store(plainWorld)
        try plain.syncIndexes(usable)
        let without = try plain.localIndexes()

        let world = try await world("all")
        let store = try store(world)
        try store.syncIndexes(usable + skipped)
        XCTAssertEqual(try store.localIndexSkips(), expected)
        XCTAssertEqual(try store.readView { try RecordLogIndexes.skips($0, documentId: Self.doc) }, expected)
        XCTAssertEqual(try store.localIndexes(), without)
        XCTAssertEqual(try store.localIndexes().map(\.name), ["idx_members_film_genres", "idx_records_film_year", "idx_text_film"])

        // A later list holding none of them leaves no skip row.
        try store.syncIndexes(usable)
        XCTAssertEqual(try store.localIndexSkips(), [])
        XCTAssertEqual(try world.rows("SELECT COUNT(*) AS n FROM record_log_index_skips").first?["n"].intValue, 0)
    }

    func testALocalOnlyDb3ListsItsIdOnlyAndUnusableEntriesAndNothingAsServerOnly() async throws {
        let world = try await world("local")
        let store = try store(world, localOnly: true)
        try store.syncIndexes(usable + [
            entry("idx_records_film_id", Self.film, ["id"], on: .server),
            entry("idx_members_film_id", Self.film, ["id"], kind: .members),
            entry("idx_records_bad_model", "bad model", ["year"]),
            entry("idx_records_film_none", Self.film, []),
            entry("idx_members_film_two", Self.film, ["genres", "tags"], kind: .members),
            entry("idx_records_film_title_server", Self.film, ["title"], on: .server),
        ])
        let skips = try store.localIndexSkips()
        XCTAssertEqual(skips.map(\.name), ["idx_members_film_id", "idx_members_film_two", "idx_records_bad_model", "idx_records_film_id", "idx_records_film_none"])
        XCTAssertEqual(skips.map(\.reason), [
            Self.idOnly, "a member index covers one field", "model 'bad model' is not an identifier", Self.idOnly, "it names no field",
        ])
        XCTAssertFalse(skips.contains { $0.reason == Self.serverOnly })
        XCTAssertTrue(try store.localIndexes().map(\.name).contains("idx_records_film_title_server"))
    }

    func testStorageVersion10CreatesTheTableOnAVersion9StoreAndTheNextSyncFillsIt() async throws {
        let world = try await world("version")
        _ = try store(world)
        XCTAssertEqual(RecordLogSchema.storageVersion, 10)
        // The store as #5230's version 9 left it: no skip table.
        try world.exec("DROP TABLE record_log_index_skips")
        try world.exec("UPDATE record_log_meta SET value = '9' WHERE key = 'storage_version'")
        let reopened = try world.reopen(Self.doc)
        XCTAssertEqual(try world.rows("SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue, "10")
        XCTAssertEqual(
            try world.rows("SELECT name FROM pragma_table_info('record_log_index_skips') ORDER BY cid").compactMap { $0["name"].stringValue },
            ["doc_id", "room_name", "model", "fields", "kind", "on", "reason"]
        )
        XCTAssertEqual(try reopened.localIndexSkips(), [])
        try reopened.syncIndexes(skipped)
        XCTAssertEqual(try reopened.localIndexSkips(), expected)
    }

    func testAStoreOfAnOlderVersionGainsTheTableToo() async throws {
        let world = try await world("older")
        _ = try store(world)
        try world.exec("DROP TABLE record_log_index_skips")
        try world.exec("UPDATE record_log_meta SET value = '7' WHERE key = 'storage_version'")
        let reopened = try world.reopen(Self.doc)
        XCTAssertEqual(try world.rows("SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue, "10")
        try reopened.syncIndexes(skipped)
        XCTAssertEqual(try reopened.localIndexSkips().count, 6)
    }

    func testTheTableIsOneOfTheCopysAnEvictClearsTheDb3sRowsAndLeavesAnothers() async throws {
        let world = try await world("evict")
        let store = try store(world)
        XCTAssertTrue(RecordLogSchema.clientTables.contains("record_log_index_skips"))
        try store.syncIndexes(skipped)
        let other = try self.store(world, Self.other)
        try other.syncIndexes([skipped[0]])
        let purged = try store.purge(force: true)
        XCTAssertTrue(purged.purged)
        let rows = try world.rows("SELECT doc_id, room_name FROM record_log_index_skips")
        XCTAssertEqual(rows.map { $0["doc_id"].stringValue ?? "" }, [Self.other])
        XCTAssertEqual(rows.map { $0["room_name"].stringValue ?? "" }, ["idx_members_film_genres_server"])
    }

    func testAnEntrySkippedBeforeAndUsableNowMovesToTheCacheInOneSync() async throws {
        let world = try await world("move")
        let store = try store(world)
        try store.syncIndexes([entry("idx_members_film_genres", Self.film, ["genres"], kind: .members, on: .server)])
        XCTAssertEqual(try store.localIndexSkips().map(\.name), ["idx_members_film_genres"])
        XCTAssertEqual(try store.localIndexes(), [])
        try store.syncIndexes([entry("idx_members_film_genres", Self.film, ["genres"], kind: .members, on: .both)])
        XCTAssertEqual(try store.localIndexSkips(), [])
        XCTAssertEqual(try store.localIndexes().map { "\($0.name):\($0.status.rawValue)" }, ["idx_members_film_genres:built"])
    }
}
