import XCTest
@testable import JsBaoClient

/// #5136 (db3 storage, C1 on Swift), against the dev server: a Swift client's
/// store keeps a db3's rows as JSONB without `id` and reads equal to the room.
///
/// - Behaviour 14: a client synced fresh (a 5,000-row bulk load through the
///   room's receipt path, then 50 rows another client writes) holds only
///   JSONB rows with no `$.id`, its rows equal the room's, and a local
///   create's guess row is JSONB and lands in the room.
/// - Behaviour 15: a client whose store the previous release left (version
///   2, the db3's rows JSON text with `id`, its cursor at the room's log
///   number) converts at open, stays resident without a full replacement,
///   equals the room, and its next write lands.
final class RecordLogJsonbLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let fields = ["title", "n"]
    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-jsonb")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func host(_ client: JsBaoClient) async throws -> any Format2SqlHost {
        let found = await client.db3Host()
        return try XCTUnwrap(found)
    }

    /// The document's `_data` rows in `table` that are not JSONB without `id`.
    private func notJsonb(_ host: any Format2SqlHost, _ table: String, _ documentId: String) throws -> Int {
        try host.withConnection { connection in
            try connection.query(
                """
                SELECT COUNT(*) AS n FROM \(table)
                 WHERE doc_id = ? AND (typeof(_data) <> 'blob' OR json_extract(_data, '$.id') IS NOT NULL)
                """,
                [.text(documentId)]
            ).first?["n"].intValue ?? -1
        }
    }

    private func count(_ host: any Format2SqlHost, _ table: String, _ documentId: String) throws -> Int {
        try host.withConnection {
            try $0.query("SELECT COUNT(*) AS n FROM \(table) WHERE doc_id = ?", [.text(documentId)]).first?["n"].intValue ?? -1
        }
    }

    // MARK: - Behaviour 14

    func testAClientSyncedFreshHoldsJsonbRowsWithoutIdAndEqualsTheRoom() async throws {
        let y = try await live.client("y", models: [Self.note])
        let documentId = try await live.createDocument(y)
        let x = try await live.client("x", models: [Self.note])
        try await live.open(x, documentId)
        try await live.open(y, documentId)

        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let ids = recordLogIds(5_000, prefix: "j")
        let session = try await load.load((0..<5).map { chunk in
            RecordLogLoadChunk(model: "Note", index: chunk, lines: ids[(chunk * 1_000)..<((chunk + 1) * 1_000)].map { id in
                (id, ["title": .string("loaded \(id) é \"quoted\""), "n": .number(Double(id.dropFirst())!)])
            })
        })
        try await load.until(try XCTUnwrap(session["sessionId"] as? String)) { ($0["state"] as? String) == "complete" }
        try await live.untilEqual(x, documentId, "Note", Self.fields, timeout: 60)

        // 50 rows another client writes reach x by catch-up.
        let notes = try live.member(y, documentId, "Note")
        for i in 0..<50 { _ = try notes.create(id: "y\(i)", values: ["title": .string("from y \(i)"), "n": .number(Double(i))]) }
        try await live.settled(y, documentId)
        try await live.untilEqual(x, documentId, "Note", Self.fields, timeout: 60)

        let store = try await host(x)
        XCTAssertEqual(try count(store, "record_log_rows", documentId), 5_050)
        XCTAssertEqual(try count(store, "record_log_view", documentId), 5_050)
        XCTAssertEqual(try notJsonb(store, "record_log_rows", documentId), 0, "every confirmed row is JSONB without id")
        XCTAssertEqual(try notJsonb(store, "record_log_view", documentId), 0, "every view row is JSONB without id")
        let local = try live.localRows(x, documentId, "Note")
        XCTAssertEqual(local.count, 5_050)
        for (id, row) in local { XCTAssertEqual(row["id"]?.stringValue, id, "each row answers its id") }
        XCTAssertEqual(local["j00007"]?["title"], "loaded j00007 é \"quoted\"")

        // A local create's guess is stored as JSONB, and lands in the room.
        _ = try live.member(x, documentId, "Note").create(id: "x-mine", values: ["title": .string("mine"), "n": .number(1)])
        let guess = try store.withConnection {
            try $0.query(
                "SELECT typeof(_data) AS kind, json_extract(_data, '$.id') IS NULL AS no_id FROM record_log_view WHERE doc_id = ? AND _id = 'x-mine'",
                [.text(documentId)]
            ).first
        }
        XCTAssertEqual(guess?["kind"].stringValue, "blob")
        XCTAssertEqual(guess?["no_id"].intValue, 1)
        try await live.settled(x, documentId)
        let room = try await live.roomTable(documentId, "Note")
        XCTAssertEqual(room["x-mine"]?["title"], "mine")
        try await live.untilEqual(x, documentId, "Note", Self.fields, timeout: 30)
        XCTAssertEqual(try notJsonb(store, "record_log_rows", documentId), 0)
    }

    // MARK: - Behaviour 15

    func testAClientWhoseStoreThePreviousReleaseLeftConvertsAtOpenAndEqualsTheRoom() async throws {
        let y = try await live.client("y", models: [Self.note])
        let documentId = try await live.createDocument(y)
        try await live.open(y, documentId)
        let notes = try live.member(y, documentId, "Note")
        for i in 0..<40 { _ = try notes.create(id: "p\(i)", values: ["title": .string("before \(i) é"), "n": .number(Double(i))]) }
        try await live.settled(y, documentId)

        // A client syncs the db3 into a file and quits; the file is then left as the previous release kept it.
        let file = live.file("previous-release")
        let x1 = try await live.client("x1", models: [Self.note], file: file)
        try await live.open(x1, documentId)
        try await live.untilEqual(x1, documentId, "Note", Self.fields)
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "x1's cursor to reach the room's log number") {
            try self.live.marks(x1, documentId).cursor >= lsn
        }
        XCTAssertNotNil(try live.marks(x1, documentId).lastCatchUpAt)
        await x1.destroy()
        let planted = SQLiteStorageProvider(path: file)
        try await planted.initialize(namespace: "previous-release")
        try RecordLogPreviousRelease.downgrade(planted)
        let before = try planted.withConnection { connection in
            (
                try connection.query("SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue,
                try connection.query(
                    "SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = ? AND typeof(_data) = 'text' AND json_extract(_data, '$.id') = _id",
                    [.text(documentId)]
                ).first?["n"].intValue,
                try connection.query("SELECT rows_gen, cursor FROM record_log_state WHERE doc_id = ?", [.text(documentId)]).first
            )
        }
        await planted.close()
        XCTAssertEqual(before.0, "2")
        XCTAssertEqual(before.1, 40, "the view's rows are text with id")
        XCTAssertEqual(before.2?["cursor"].intValue, lsn)

        // The next client on that file converts it at open.
        let x2 = try await live.client("x2", models: [Self.note], file: file)
        try await live.open(x2, documentId)
        let store = try await host(x2)
        let after = try store.withConnection { connection in
            (
                try connection.query("SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue,
                try connection.query("SELECT rows_gen FROM record_log_state WHERE doc_id = ?", [.text(documentId)]).first
            )
        }
        XCTAssertEqual(after.0, "4")
        XCTAssertEqual(try count(store, "record_log_rows", documentId), 40)
        XCTAssertEqual(try notJsonb(store, "record_log_rows", documentId), 0, "the confirmed rows are JSONB without id")
        XCTAssertEqual(try notJsonb(store, "record_log_view", documentId), 0, "the view rows are JSONB without id")
        XCTAssertEqual(after.1?["rows_gen"], before.2?["rows_gen"], "no full replacement ran")
        XCTAssertTrue(RecordLogStore.isResident(try live.marks(x2, documentId)), "the binding is resident")
        try await live.untilEqual(x2, documentId, "Note", Self.fields)
        let local = try live.localRows(x2, documentId, "Note")
        XCTAssertEqual(local["p7"]?.filter { $0.key != "_meta_doc_id" }, ["id": "p7", "title": "before 7 é", "n": 7])

        _ = try live.member(x2, documentId, "Note").create(id: "x2-after", values: ["title": .string("after"), "n": .number(1)])
        try await live.settled(x2, documentId)
        let room = try await live.roomTable(documentId, "Note")
        XCTAssertEqual(room["x2-after"]?["title"], "after")
        try await live.untilEqual(x2, documentId, "Note", Self.fields)
    }
}
