import XCTest
@testable import JsBaoClient

/// #5223 behavior 7 and edge cases E1, E2 — the text family is reconciled
/// by definition: the same list again builds nothing (its table and three
/// triggers found in `sqlite_master` by #5222's `LIKE … ESCAPE '\'`
/// predicates); a changed tokenizer, prefix or fields rebuilds under the
/// same name; an entry gone from the list drops its table and triggers; a
/// list-less sync keeps everything and rebuilds a trigger or table dropped by
/// hand; a reopened store builds nothing. Two db3s with the same model keep
/// separate tables; a name held without case makes the table `<canonical>_2`.
final class Db3DeviceTextIndexReconcileHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world() async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("text-reconcile", logger: Logger(level: .info))
        worlds.append(world)
        return world
    }

    private typealias F = Db3TextIndexFixture

    private func sql(_ world: Db3DeviceIndexWorld, _ table: String) throws -> String? {
        try world.rows("SELECT sql FROM sqlite_master WHERE name = ?", [.text(table)]).first?["sql"].stringValue
    }

    func testTheSameListAgainBuildsNothingAndADefinitionChangeRebuildsUnderTheSameName() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", [["id": "a", "title": "running fast", "body": "kiwi"], ["id": "b", "title": "slow", "body": "running"]])
        let table = F.tableName("db3-a")
        XCTAssertEqual(try store.syncIndexes([F.textEntry(["title"])]).created, 1)
        XCTAssertEqual(try F.matched(world, table, "\"run\""), [])

        // The same list again: nothing built, nothing logged, the family discovered.
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        var sync = RecordLogIndexSync(created: -1, dropped: -1)
        let lines = try F.logged { sync = try store.syncIndexes([F.textEntry(["title"])]) }
        XCTAssertEqual(sync, RecordLogIndexSync(created: 0, dropped: 0))
        XCTAssertEqual(lines.filter { $0.message.contains("text index") }.map(\.message), [])
        XCTAssertFalse(trace.statements.contains { $0.hasPrefix("CREATE VIRTUAL TABLE") }, "\(trace.statements)")
        let discovery = trace.statements.filter { $0.contains(#"LIKE 'idx\_record\_log\_text\_%' ESCAPE '\'"#) }
        XCTAssertEqual(discovery.filter { $0.contains("type = 'table'") && $0.contains("CREATE VIRTUAL TABLE%") }.count, 1, "\(discovery)")
        XCTAssertEqual(discovery.filter { $0.contains("type = 'trigger'") }.count, 1, "\(discovery)")

        // A changed tokenizer, prefix or fields rebuilds the table under the same name.
        try store.syncIndexes([F.textEntry(["title"], ["tokenizer": "porter"])])
        XCTAssertEqual(try sql(world, table)?.contains("tokenize='porter unicode61 remove_diacritics 2'"), true)
        XCTAssertEqual(try F.matched(world, table, "\"run\""), try F.rowids(world, "db3-a", ["a"]))
        try store.syncIndexes([F.textEntry(["title"], ["tokenizer": "porter", "prefix": [2]])])
        XCTAssertEqual(try sql(world, table)?.hasSuffix(", prefix='2')"), true)
        try store.syncIndexes([F.textEntry(["title", "body"], ["tokenizer": "porter", "prefix": [2]])])
        XCTAssertEqual(try sql(world, table)?.contains("fts5(f0, f1, "), true)
        XCTAssertEqual(try F.matched(world, table, "\"run\""), try F.rowids(world, "db3-a", ["a", "b"]))
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(table))
        XCTAssertEqual(try world.drift(), [])

        // A list-less sync keeps everything.
        let objects = try world.objects()
        XCTAssertEqual(try store.syncIndexes(nil), RecordLogIndexSync(created: 0, dropped: 0))
        XCTAssertEqual(try world.objects(), objects)

        // An entry gone from the list drops its table and triggers.
        XCTAssertEqual(try store.syncIndexes([F.scalarEntry("title")]).dropped, 1)
        XCTAssertEqual(try F.textObjects(world), [])
        XCTAssertEqual(try world.rows(#"SELECT name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\'"#).count, 0)
    }

    func testATriggerOrTheTableDroppedByHandIsRebuiltAndAReopenedStoreBuildsNothing() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", [["id": "a", "title": "kiwi"]])
        let table = F.tableName("db3-a")
        try store.syncIndexes([F.textEntry(["title"])])
        try world.exec("DROP TRIGGER \"\(table)__u\"")
        XCTAssertEqual(try store.syncIndexes(nil).created, 1)
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(table))
        try world.exec("DROP TABLE \"\(table)\"")
        XCTAssertEqual(try store.syncIndexes(nil).created, 1)
        XCTAssertEqual(try F.textObjects(world), F.objectsOf(table))
        XCTAssertEqual(try F.matched(world, table, "\"kiwi\""), try F.rowids(world, "db3-a", ["a"]))

        // A store reopened on the file finds the family held and builds nothing.
        let reopened = try world.reopen("db3-a")
        var sync = RecordLogIndexSync(created: -1, dropped: -1)
        let lines = try F.logged { sync = try reopened.syncIndexes(nil) }
        XCTAssertEqual(sync, RecordLogIndexSync(created: 0, dropped: 0))
        XCTAssertEqual(lines.filter { $0.message.contains("text index") }.map(\.message), [])
        try world.seed("db3-a", "Note", [["id": "b", "title": "kiwi too"]])
        XCTAssertEqual(try F.matched(world, table, "\"kiwi\""), try F.rowids(world, "db3-a", ["a", "b"]))
        XCTAssertEqual(try world.drift(), [])
    }

    /// E1: two db3s with the same model keep separate tables; neither sees the other's rows.
    func testTwoDb3sWithTheSameModelKeepSeparateTables() async throws {
        let world = try await world()
        try world.store("db3-a").syncIndexes([F.textEntry(["title"])])
        try world.store("db3-b").syncIndexes([F.textEntry(["title"])])
        try world.seed("db3-a", "Note", [["id": "a1", "title": "shared apple"], ["id": "a2", "title": "only here"]])
        try world.seed("db3-b", "Note", [["id": "b1", "title": "shared pear"]])
        XCTAssertEqual(try F.textObjects(world), (F.objectsOf(F.tableName("db3-a")) + F.objectsOf(F.tableName("db3-b"))).sorted())
        XCTAssertEqual(try F.matched(world, F.tableName("db3-a"), "\"shared\""), try F.rowids(world, "db3-a", ["a1"]))
        XCTAssertEqual(try F.matched(world, F.tableName("db3-b"), "\"shared\""), try F.rowids(world, "db3-b", ["b1"]))
        XCTAssertEqual(try world.drift(), [])
        try world.seedDeletes("db3-a", "Note", ["a1"])
        XCTAssertEqual(try F.matched(world, F.tableName("db3-b"), "\"shared\""), try F.rowids(world, "db3-b", ["b1"]))
        XCTAssertEqual(try world.drift(), [])
    }

    /// E2: a schema object holding the canonical name without case makes the table `<canonical>_2`, kept across syncs.
    func testANameHeldWithoutCaseTakes_2AndKeepsIt() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.seed("db3-a", "Note", [["id": "a", "title": "kiwi"]])
        let canonical = F.tableName("db3-a")
        try world.exec("CREATE TABLE \"\(canonical.uppercased())\" (x)")
        try store.syncIndexes([F.textEntry(["title"])])
        XCTAssertEqual(try world.rows("SELECT text FROM record_log_indexes WHERE kind = 'text'").first?["text"].stringValue, "\(canonical)_2")
        XCTAssertEqual(try F.textObjects(world), F.objectsOf("\(canonical)_2"))
        try world.exec("DROP TABLE \"\(canonical.uppercased())\"")
        XCTAssertEqual(try store.syncIndexes([F.textEntry(["title"], ["tokenizer": "porter"])]).created, 1)
        XCTAssertEqual(try world.rows("SELECT text FROM record_log_indexes WHERE kind = 'text'").first?["text"].stringValue, "\(canonical)_2")
        XCTAssertEqual(try F.matched(world, "\(canonical)_2", "\"kiwi\""), try F.rowids(world, "db3-a", ["a"]))
    }
}
