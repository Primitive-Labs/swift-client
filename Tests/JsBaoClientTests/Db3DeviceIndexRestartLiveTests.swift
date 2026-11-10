import XCTest
@testable import JsBaoClient

/// #5223 behavior 23 — a restarted client answers from its kept device
/// indexes, live against the dev server: over the same file, `$search` and
/// `$contains` answer from the tables the first client built, with no
/// rebuild (a marker row only the kept table holds survives, no build line
/// is logged, the three triggers are held); a file planted at storage
/// version 5 (the cache without `kind`, the text table dropped) opens,
/// converts to 6, keeps its member table and rebuilds the text index from the
/// list at subscribe.
final class Db3DeviceIndexRestartLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private typealias L = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-device-restart-5223")
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

    func testARestartedClientAnswersFromTheKeptTablesAndAVersion5FileConverts() async throws {
        let file = live.file("restart")
        let (first, id) = try await L.subscribed(live, "first", file: file)
        _ = try await first.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "title", kind: .text, on: .device))
        _ = try await first.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "tags", kind: .members, on: .device))
        let expected = try ids(first, ["$search": "apple"])
        XCTAssertEqual(expected.count, 3)
        await first.destroy()

        // A marker only the kept table holds: a rebuild from the view would drop it.
        let table = "idx_record_log_text_\(id.utf16.count)_\(id.lowercased())_4_note"
        let members = RecordLogIndexes.memberTableName(documentId: id, model: "Note", field: "tags")
        try await onFile(file) { try $0.executeScript("INSERT INTO \"\(table)\" (rowid, f0) VALUES (987654321, 'zzkeptmarker')") }

        let built = LockedBox<[String]>([])
        Logger.lineForTest = { _, _, message in
            if message.contains("text index") && message.contains("built from") { built.withValue { $0.append(message) } }
        }
        let (second, _) = try await L.subscribed(live, "second", documentId: id, file: file, write: false, logLevel: .info)
        XCTAssertEqual(try ids(second, ["$search": "apple"]), expected)
        XCTAssertEqual(try ids(second, ["tags": ["$contains": "sweet"]]).count, 2)
        let kept = try live.binding(second, id).store.readView { sql in
            try sql.rows("SELECT rowid FROM \"\(table)\" WHERE \"\(table)\" MATCH 'zzkeptmarker'").compactMap { $0["rowid"].intValue }
        }
        XCTAssertEqual(kept, [987654321], "the kept table was not rebuilt")
        XCTAssertEqual(try L.objects(live, second, id, "trigger", like: "\(table)__%").count, 3)
        XCTAssertEqual(built.value, [], "no text index was built at the restart")
        await second.destroy()

        // A file planted at storage version 5: the cache without `kind`, the text table dropped, the member table kept.
        try await onFile(file) { connection in
            try connection.executeScript("DROP TABLE IF EXISTS \"\(table)\"")
            for suffix in ["__i", "__u", "__d"] { try connection.executeScript("DROP TRIGGER IF EXISTS \"\(table)\(suffix)\"") }
            let cached = try connection.query("SELECT doc_id, model, fields, is_unique, room_name, members FROM record_log_indexes WHERE kind <> 'text'", [])
            try connection.executeScript("DROP TABLE record_log_indexes")
            try connection.executeScript(Db3DeviceIndexWorld.indexCache(version: 5))
            for row in cached {
                try connection.execute(
                    "INSERT INTO record_log_indexes (doc_id, model, fields, is_unique, room_name, members) VALUES (?, ?, ?, ?, ?, ?)",
                    [row["doc_id"], row["model"], row["fields"], row["is_unique"], row["room_name"], row["members"]]
                )
            }
            try connection.execute("UPDATE record_log_meta SET value = '5' WHERE key = 'storage_version'", [])
        }
        let (third, _) = try await L.subscribed(live, "third", documentId: id, file: file, write: false, logLevel: .info)
        let converted = try live.binding(third, id).store.readView { sql in
            (try sql.first("SELECT value FROM record_log_meta WHERE key = 'storage_version'")?["value"].stringValue,
             try sql.rows("SELECT name FROM pragma_table_info('record_log_indexes')").compactMap { $0["name"].stringValue })
        }
        XCTAssertEqual(converted.0, String(RecordLogSchema.storageVersion))
        XCTAssertTrue(converted.1.contains("kind"))
        XCTAssertEqual(try L.objects(live, third, id, "table", like: members), [members], "the member table is kept")
        XCTAssertEqual(try ids(third, ["tags": ["$contains": "sweet"]]).count, 2)
        // The list arrives at subscribe: the text index is built again from the view and answers.
        try await eventually(timeout: 30, description: "the text index rebuilt from the list") {
            try L.objects(self.live, third, id, "table", like: table) == [table]
        }
        XCTAssertEqual(try ids(third, ["$search": "apple"]).sorted(), expected.sorted())
        XCTAssertEqual(built.value.count, 1, "the converted file's text index was built once: \(built.value)")
        Logger.lineForTest = nil
        let drift = try await Db3DeviceIndexOracle.driftOnACopy(live.binding(third, id).store)
        XCTAssertEqual(drift, [])
    }
}
