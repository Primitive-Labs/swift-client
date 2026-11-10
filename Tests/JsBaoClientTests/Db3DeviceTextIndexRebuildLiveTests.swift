import XCTest
@testable import JsBaoClient

/// #5309 behavior 6 — a Swift client's file holding a text table in #5223's
/// form (`contentless_delete=1`, rows removed by `DELETE FROM`) is rebuilt
/// once in js-bao's form, live against the dev server: a client restarted
/// on the file applies the index list it receives at subscribe, holds the
/// table and its three triggers in the new form, answers the same `$search`
/// ids as before the restart, logs one build at info, and a sync after
/// builds nothing.
final class Db3DeviceTextIndexRebuildLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private typealias L = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-text-rebuild-5309")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        Logger.lineForTest = nil
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// `body` on a provider of its own over `file`, while no client holds it open.
    private func onFile<T>(_ file: String, _ body: (any Format2SqlConnection) throws -> T) async throws -> T {
        let provider = SQLiteStorageProvider(path: file)
        try await provider.initialize(namespace: "planter")
        defer { Task { await provider.close() } }
        return try provider.withConnection(body)
    }

    private func ids(_ client: JsBaoClient, _ filter: DocumentFilter) throws -> [String] {
        try client.sharedModel(for: L.note).query(filter).compactMap { $0["id"]?.stringValue }
    }

    /// The `sql` of `table`'s family in `client`'s store, the table first, then its triggers by name.
    private func family(_ client: JsBaoClient, _ id: String, _ table: String) throws -> [String] {
        try live.binding(client, id).store.readView { sql in
            try sql.rows(
                "SELECT sql FROM sqlite_master WHERE name = ? OR (type = 'trigger' AND name IN (?, ?, ?)) ORDER BY type = 'trigger', name",
                [.text(table), .text("\(table)__d"), .text("\(table)__i"), .text("\(table)__u")]
            ).compactMap { $0["sql"].stringValue }
        }
    }

    func testARestartedClientRebuildsA5223TableOnceInTheNewForm() async throws {
        let file = live.file("rebuild")
        let (first, id) = try await L.subscribed(live, "first", file: file)
        _ = try await first.db3.indexes.register(id, Db3IndexRegistration(
            model: "Note", fields: ["title", "body"], kind: .text, on: .device
        ))
        let expected = try ids(first, ["$search": "apple"])
        XCTAssertEqual(expected.count, 3)
        let table = RecordLogIndexes.textTableName(documentId: id, model: "Note")
        let wanted = try family(first, id, table)
        XCTAssertEqual(wanted.count, 4)
        await first.destroy()

        let planted = try await onFile(file) { connection in
            try Db3TextIndexFixture.plant5223(connection, id, fields: ["title", "body"])
            return try connection.query("SELECT sql FROM sqlite_master WHERE name = ?", [.text(table)]).first?["sql"].stringValue
        }
        XCTAssertEqual(planted, Db3TextIndexFixture.table5223(table, fields: ["title", "body"]))

        let built = LockedBox<[(level: LogLevel, message: String)]>([])
        Logger.lineForTest = { level, _, message in
            if message.contains("text index") && message.contains("built from") { built.withValue { $0.append((level, message)) } }
        }
        let (second, _) = try await L.subscribed(live, "second", documentId: id, file: file, write: false, logLevel: .info)
        try await eventually(timeout: 30, description: "the index list applied and the table rebuilt in the new form") {
            let held = try self.family(second, id, table)
            return held.count == 4 && !held.contains { $0.contains("contentless_delete") || $0.contains("DELETE FROM") }
        }
        XCTAssertEqual(try family(second, id, table), wanted, "the form the first client built")
        XCTAssertEqual(try L.objects(live, second, id, "table", like: table), [table])
        XCTAssertEqual(try L.objects(live, second, id, "trigger", like: "\(table)__%"), ["\(table)__d", "\(table)__i", "\(table)__u"])
        XCTAssertEqual(try ids(second, ["$search": "apple"]), expected)
        XCTAssertEqual(built.value.count, 1, "\(built.value.map(\.message))")
        XCTAssertEqual(built.value.first?.level, .info)
        XCTAssertEqual(try live.binding(second, id).store.syncIndexes(nil), RecordLogIndexSync(created: 0, dropped: 0))
        XCTAssertEqual(built.value.count, 1, "the sync after built nothing")
        Logger.lineForTest = nil
        let drift = try await Db3DeviceIndexOracle.driftOnACopy(live.binding(second, id).store)
        XCTAssertEqual(drift, [])
    }
}
