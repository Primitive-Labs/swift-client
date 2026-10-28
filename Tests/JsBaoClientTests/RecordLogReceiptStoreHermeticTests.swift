import XCTest
@testable import JsBaoClient

/// A load's chunk, a refresh, a segment and the receipt marker through the
/// record-log store over a real `SQLiteStorageProvider` on a temp file: the
/// Swift twin of js-bao's `record-log-client-store-load-4311.test.ts`.
///
/// - `applyLoadChunk` writes the confirmed rows and, set-based, the view rows
///   of every key no unjudged entry touches and no unjudged upsert's value
///   lands on; the rest go through the per-record refresh, all in one
///   transaction (a db3's rows live in its view only since #4700). A 10,000-row
///   chunk applies in under 2 s, and its reply names the model rather than
///   10,000 changed rows.
/// - `completeLoad` of a refresh removes the covered rows no line named, in the
///   view too, keeps other models' rows and the client's
///   own pending create.
/// - The receipt marker is persisted in `record_log_state.receipt`; only a
///   receipt's or a full replacement's completion clears it. A chunk of an
///   attempt a full replacement ended is answered `stale`.
/// - `beginFencedCatchUp(full: true)` hands out the replacement's generation;
///   a segment chunk, its corrections, a page or a completion under an older
///   one is answered `stale` and changes nothing.
final class RecordLogReceiptStoreHermeticTests: XCTestCase {

    private static let session = "01JS4312ST0RE10ADSESS10N01"
    private var directories: [String] = []

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }


    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/record-log-receipt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeProvider(path: String? = nil) async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: path ?? newDatabasePath())
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A store with its tables and a minted writer.
    private func opened(
        _ provider: SQLiteStorageProvider, clientId: String = "client-a", logger: Logger? = nil
    ) throws -> (store: RecordLogStore, writer: String) {
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: clientId, logger: logger)
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private func attempt(_ store: RecordLogStore, _ writer: String, _ id: String = session) throws -> String {
        try store.beginReceipt(writer: writer, kind: .load, id: id).attempt
    }

    private func lines(_ count: Int, from: Int = 1) -> [RecordLogLoadLine] {
        (from..<(from + count)).map { i in
            RecordLogLoadLine(id: Self.id(i), patch: ["title": .string("t\(i)"), "n": .number(Double(i))])
        }
    }

    private static func id(_ i: Int) -> String { "n" + String(format: "%05d", i) }

    private func row(_ id: String, _ fields: RecordLogRow, model: String = "Note") -> RecordLogCatchUpRow {
        var row = fields
        row["id"] = .string(id)
        return RecordLogCatchUpRow(model: model, id: id, row: row)
    }

    private func mutation(_ id: String, _ kind: RecordLogWriteKind, _ fields: [String: JSONValue]) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: kind, fields: fields, stringSetDeltas: nil)
    }

    private func count(_ provider: SQLiteStorageProvider, _ sql: String) throws -> Int {
        try provider.withConnection { try $0.query(sql, []).first?["n"].intValue ?? -1 }
    }

    /// The `Note` row a query reads, from the view (the query tables until
    /// #4700): id, title, slug, n, a field the row lacks as null.
    private func queryRow(_ provider: SQLiteStorageProvider, _ id: String) throws -> [String: JSONValue]? {
        try provider.withConnection { connection in
            try connection.query(
                "SELECT _data FROM record_log_view WHERE doc_id = 'doc-1' AND _type = 'Note' AND _id = ?", [.text(id)]
            ).first.map { row in
                let stored = RecordLogJSON.row(row["_data"].stringValue)
                var out: [String: JSONValue] = [:]
                for column in ["id", "title", "slug", "n"] { out[column] = stored[column] ?? .null }
                return out
            }
        }
    }

    private func rowIds(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection {
            try $0.query("SELECT _id FROM record_log_rows ORDER BY _id", []).compactMap { $0["_id"].stringValue }
        }
    }

    // MARK: - The schema (behavior 6)

    func testAStoreCreatedBeforeTheReceiptColumnIsMigratedAndTheLoadKeysAreItsTable() async throws {
        let provider = try await makeProvider()
        try provider.withConnection { connection in
            try connection.executeScript("""
                CREATE TABLE record_log_state (
                  doc_id TEXT PRIMARY KEY,
                  cursor INTEGER NOT NULL DEFAULT 0,
                  open_epoch INTEGER NOT NULL DEFAULT 1,
                  grant_epoch INTEGER NOT NULL DEFAULT 2,
                  epoch_entries INTEGER NOT NULL DEFAULT 10000,
                  constraints TEXT NOT NULL DEFAULT '[]',
                  last_catch_up_at INTEGER,
                  permission TEXT,
                  rows_gen INTEGER NOT NULL DEFAULT 0,
                  replacing INTEGER
                )
                """)
            try connection.execute("INSERT INTO record_log_state (doc_id, cursor) VALUES (?, 9)", [.text("doc-1")])
        }
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a")
        try store.initialize()
        try store.initialize()
        let writer = try store.mintWriter()
        let marks = try store.marks()
        XCTAssertEqual(marks.cursor, 9)
        XCTAssertNil(marks.receipt)
        _ = try store.beginReceipt(writer: writer, kind: .segment, id: "G1")
        XCTAssertEqual(try store.marks().receipt, RecordLogReceipt(kind: .segment, id: "G1"))
        XCTAssertTrue(RecordLogSchema.clientTables.contains("record_log_load_keys"))
    }

    func testAPurgeClearsTheLoadKeysAndTheMarker() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        _ = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: try attempt(store, writer), model: "Note", lines: lines(2)
        )
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 2)
        XCTAssertTrue(try store.purge(force: true).purged)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 0)
        XCTAssertNil(try store.marks().receipt)
    }

    func testTheMarkerIsPersistedReadBackAfterTheStoreClosesAndClearedOnlyByAReceiptsOrAReplacementsCompletion() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (store, writer) = try opened(provider)
        XCTAssertNil(try store.marks().receipt)
        _ = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: try attempt(store, writer), model: "Note", lines: lines(2)
        )
        await provider.close()

        let reopened = try await makeProvider(path: path)
        let again = RecordLogStore(host: reopened, documentId: "doc-1", clientId: "client-a")
        try again.initialize()
        XCTAssertEqual(try again.marks().receipt, RecordLogReceipt(kind: .load, id: Self.session))
        // A rows catch-up does not clear it.
        try again.beginCatchUp(writer: writer, full: false)
        _ = try again.completeCatchUp(writer: writer, lsn: 4)
        XCTAssertEqual(try again.marks().receipt, RecordLogReceipt(kind: .load, id: Self.session))
        // A full replacement does, and the marks report it while it is under way.
        let generation = try XCTUnwrap(try again.beginFencedCatchUp(writer: writer, full: true))
        let during = try again.marks()
        XCTAssertTrue(during.replacing)
        XCTAssertEqual(during.replacement, generation)
        _ = try again.completeCatchUp(writer: writer, lsn: 5, full: true, generation: generation)
        let after = try again.marks()
        XCTAssertNil(after.receipt)
        XCTAssertFalse(after.replacing)
        XCTAssertNil(after.replacement)
        // As does a receipt's completion.
        let second = try again.beginReceipt(writer: writer, kind: .load, id: "S2").attempt
        XCTAssertEqual(try again.marks().receipt, RecordLogReceipt(kind: .load, id: "S2"))
        _ = try again.completeCatchUp(writer: writer, lsn: 6, receipt: second)
        XCTAssertNil(try again.marks().receipt)
        await reopened.close()
    }

    func testAMarkerAnEarlierBuildWroteIsOneAttemptOnlyAFullReplacementCompletes() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try provider.withConnection { connection in
            try connection.execute(
                "UPDATE record_log_state SET receipt = ? WHERE doc_id = ?", [.text("{\"kind\":\"load\",\"id\":\"S0\"}"), .text("doc-1")]
            )
        }
        XCTAssertEqual(try store.marks().receipt, RecordLogReceipt(kind: .load, id: "S0"))
        _ = try store.completeCatchUp(writer: writer, lsn: 3)
        XCTAssertEqual(try store.marks().receipt, RecordLogReceipt(kind: .load, id: "S0"))
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.completeCatchUp(writer: writer, lsn: 4, full: true, generation: generation)
        XCTAssertNil(try store.marks().receipt)
    }

    // MARK: - applyLoadChunk (behavior 7)

    func testAChunkWritesTheConfirmedRowsTheViewAndTheQueryTablesAndNamesTheModel() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("n00001", ["title": "old", "slug": "keep"])])
        let reply = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: try attempt(store, writer), model: "Note", lines: lines(3)
        )
        XCTAssertEqual(reply.applied, 3)
        XCTAssertEqual(reply.removed, 0)
        XCTAssertEqual(reply.models, ["Note"])
        XCTAssertEqual(reply.ranges, [RecordLogIdRange(model: "Note", firstId: "n00001", lastId: "n00003")])
        XCTAssertTrue(reply.changed.isEmpty, "no unjudged entry touches the chunk (edge 017)")
        XCTAssertFalse(reply.stale)
        XCTAssertEqual(reply.cursor, 0)
        XCTAssertEqual(try store.read(model: "Note", id: "n00001"), ["id": "n00001", "title": "t1", "slug": "keep", "n": 1])
        XCTAssertEqual(try store.read(model: "Note", id: "n00003"), ["id": "n00003", "title": "t3", "n": 3])
        XCTAssertEqual(try queryRow(provider, "n00002"), ["id": "n00002", "title": "t2", "slug": .null, "n": 2])
        XCTAssertEqual(try queryRow(provider, "n00001"), ["id": "n00001", "title": "t1", "slug": "keep", "n": 1])
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_rows"), 3)
    }

    func testAChunkRemovesADeletedRecordFromTheViewAndTheQueryTables() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let a = try attempt(store, writer)
        _ = try store.applyLoadChunk(writer: writer, sessionId: Self.session, attempt: a, model: "Note", lines: lines(2))
        let reply = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: a, model: "Note",
            lines: [RecordLogLoadLine(id: "n00001", patch: ["_deleted": true]), RecordLogLoadLine(id: "absent", patch: ["_deleted": true])]
        )
        XCTAssertEqual(reply.applied, 0)
        XCTAssertEqual(reply.removed, 1)
        XCTAssertNil(try store.read(model: "Note", id: "n00001"))
        XCTAssertNil(try queryRow(provider, "n00001"))
        XCTAssertNotNil(try queryRow(provider, "n00002"))
    }

    func testAChunkKeepsAPendingPatchsGuessOnTopOfTheLoadedRow() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("n00001", ["title": "old", "n": 0])])
        _ = try store.commitEntries(
            writer: writer, writes: [RecordLogWrite(mutations: [mutation("n00001", .patch, ["title": "mine"])])]
        )
        let reply = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: try attempt(store, writer), model: "Note", lines: lines(2)
        )
        XCTAssertEqual(try store.read(model: "Note", id: "n00001"), ["id": "n00001", "title": "mine", "n": 1])
        XCTAssertEqual(try queryRow(provider, "n00001")?["title"], "mine")
        XCTAssertEqual(reply.changed.map(\.id), ["n00001"])
        XCTAssertEqual(try store.read(model: "Note", id: "n00002"), ["id": "n00002", "title": "t2", "n": 2])
    }

    func testAChunkResolvesAnUnjudgedUpsertOntoARecordALoadedRowNowHoldsItsValueOn() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        _ = try store.commitEntries(
            writer: writer,
            writes: [RecordLogWrite(mutations: [mutation("guess", .create, ["slug": "shared", "title": "mine"])], upsertOn: "slug")]
        )
        XCTAssertEqual(try store.read(model: "Note", id: "guess")?["slug"], "shared")
        let reply = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: try attempt(store, writer), model: "Note",
            lines: [RecordLogLoadLine(id: "n00007", patch: ["slug": "shared", "title": "loaded", "n": 7])]
        )
        XCTAssertNil(try store.read(model: "Note", id: "guess"))
        XCTAssertEqual(try store.read(model: "Note", id: "n00007"), ["id": "n00007", "slug": "shared", "title": "mine", "n": 7])
        XCTAssertEqual(Set(reply.changed.map(\.id)), ["guess", "n00007"])
        XCTAssertNil(try queryRow(provider, "guess"))
        XCTAssertEqual(try queryRow(provider, "n00007")?["title"], "mine")
    }

    func testAChunkThatThrowsMidWayLeavesNoRowOfIt() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let a = try attempt(store, writer)
        // The chunk's fourth view row is refused after its confirmed rows were
        // written (until #4700 the missing query tables failed it there).
        try provider.withConnection { connection in
            try connection.executeScript("""
                CREATE TRIGGER refuse_fourth BEFORE INSERT ON record_log_view WHEN NEW._id = 'n00004'
                BEGIN SELECT RAISE(ABORT, 'the chunk fails mid-way'); END
                """)
        }
        XCTAssertThrowsError(try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: a, model: "Note", lines: lines(5)
        ))
        try provider.withConnection { try $0.executeScript("DROP TRIGGER refuse_fourth") }
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_rows"), 0)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_view"), 0)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 0)
        XCTAssertEqual(try store.marks().cursor, 0)
        XCTAssertTrue(try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: a, model: "Note", lines: lines(5)
        ).models == ["Note"], "the attempt is still in progress: nothing of the failed chunk counted")
    }

    func testAnEmptyChunkAppliesNothingAndAnswersNoRange() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let reply = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: try attempt(store, writer), model: "Note", lines: []
        )
        XCTAssertEqual(reply.applied, 0)
        XCTAssertEqual(reply.removed, 0)
        XCTAssertEqual(reply.ranges, [])
        XCTAssertTrue(reply.changed.isEmpty)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_rows"), 0)
    }

    func testATenThousandRowChunkAppliesInUnderTwoSeconds() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let a = try attempt(store, writer)
        // Older values of every twentieth id, and a pending patch on one of them.
        _ = try store.applyCatchUpPage(
            writer: writer, rows: (0..<500).map { k in row(Self.id(k * 20 + 1), ["title": .string("old\(k)")]) }
        )
        _ = try store.commitEntries(
            writer: writer, writes: [RecordLogWrite(mutations: [mutation("n00021", .patch, ["title": "mine"])])]
        )
        let chunk = lines(10_000)
        let started = Date()
        let reply = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: a, model: "Note", lines: chunk
        )
        let ms = Date().timeIntervalSince(started) * 1000
        FileHandle.standardError.write(Data("[4312] a 10,000-row chunk applied in \(Int(ms)) ms on the Swift store\n".utf8))
        XCTAssertLessThan(ms, 2_000)
        XCTAssertEqual(reply.applied, 10_000)
        XCTAssertLessThan(reply.changed.count, 5)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_view WHERE _type = 'Note'"), 10_000)
        XCTAssertEqual(try store.read(model: "Note", id: "n00021")?["title"], "mine")
        XCTAssertEqual(try store.read(model: "Note", id: "n00021")?["n"], 21)
        XCTAssertEqual(try store.read(model: "Note", id: "n09999"), ["id": "n09999", "title": "t9999", "n": 9999])
    }

    // MARK: - completeLoad (behavior 8)

    func testARefreshRemovesItsCoveredRowsNoLineNamedAndKeepsOtherModelsAndTheClientsOwnPendingCreate() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let a = try attempt(store, writer)
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            row("n00001", ["title": "a"]), row("stale", ["title": "b"]), row("t1", ["title": "task"], model: "Task"),
        ])
        _ = try store.commitEntries(
            writer: writer, writes: [RecordLogWrite(mutations: [mutation("mine", .create, ["title": "pending"])])]
        )
        _ = try store.applyLoadChunk(writer: writer, sessionId: Self.session, attempt: a, model: "Note", lines: lines(1))
        let reply = try store.completeLoad(
            writer: writer, sessionId: Self.session, attempt: a, mode: .refresh, models: ["Note"]
        )
        XCTAssertEqual(reply.removed, 1)
        XCTAssertEqual(reply.models, ["Note"])
        XCTAssertNil(try store.read(model: "Note", id: "stale"))
        XCTAssertNil(try queryRow(provider, "stale"))
        XCTAssertEqual(try store.read(model: "Task", id: "t1"), ["id": "t1", "title": "task"])
        XCTAssertEqual(try store.read(model: "Note", id: "mine"), ["id": "mine", "title": "pending"])
        XCTAssertEqual(try queryRow(provider, "mine")?["title"], "pending")
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 0)
    }

    func testTwoStoresAttemptsOfOneRefreshKeepTheirKeysApart() async throws {
        let provider = try await makeProvider()
        let (a, wa) = try opened(provider)
        _ = try a.applyCatchUpPage(writer: wa, rows: [row("stale", ["title": "b"])])
        let (b, wb) = try opened(provider, clientId: "client-b")
        let attemptA = try attempt(a, wa)
        let attemptB = try attempt(b, wb)
        _ = try a.applyLoadChunk(writer: wa, sessionId: Self.session, attempt: attemptA, model: "Note", lines: lines(2))
        _ = try b.applyLoadChunk(writer: wb, sessionId: Self.session, attempt: attemptB, model: "Note", lines: lines(2))
        XCTAssertEqual(try a.completeLoad(
            writer: wa, sessionId: Self.session, attempt: attemptA, mode: .refresh, models: ["Note"]
        ).removed, 1)
        // B's refresh completes after A forgot its keys: B's own are still there.
        let second = try b.completeLoad(
            writer: wb, sessionId: Self.session, attempt: attemptB, mode: .refresh, models: ["Note"]
        )
        XCTAssertFalse(second.stale)
        XCTAssertEqual(second.removed, 0)
        _ = try a.completeCatchUp(writer: wa, lsn: 4, receipt: attemptA)
        _ = try b.completeCatchUp(writer: wb, lsn: 4, receipt: attemptB)
        XCTAssertEqual(try rowIds(provider), ["n00001", "n00002"])
        XCTAssertEqual(try queryRow(provider, "n00002")?["title"], "t2")
        XCTAssertNil(try b.marks().receipt)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 0)
    }

    func testAChunkOfAnAttemptAFullReplacementEndedIsAnsweredStaleWithItsLoadKeysDropped() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let old = try attempt(store, writer)
        _ = try store.applyLoadChunk(writer: writer, sessionId: Self.session, attempt: old, model: "Note", lines: lines(1))
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 1)
        // The recovery walks the room's table, which does not have n00001.
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("kept", [:])], generation: generation)
        _ = try store.completeCatchUp(writer: writer, lsn: 7, full: true, generation: generation)
        XCTAssertNil(try store.marks().receipt)
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_load_keys"), 0)
        // The ended attempt's chunk arrives late: nothing changes.
        let late = try store.applyLoadChunk(
            writer: writer, sessionId: Self.session, attempt: old, model: "Note", lines: lines(1)
        )
        XCTAssertTrue(late.stale)
        XCTAssertEqual(late.applied, 0)
        XCTAssertTrue(try store.completeLoad(
            writer: writer, sessionId: Self.session, attempt: old, mode: .refresh, models: ["Note"]
        ).stale)
        XCTAssertEqual(try rowIds(provider), ["kept"])
        XCTAssertNil(try queryRow(provider, "n00001"))
        let marks = try store.marks()
        XCTAssertEqual(marks.cursor, 7)
        XCTAssertNil(marks.receipt)
    }

    // MARK: - A segment under its generation (behaviors 5 and 8, the store)

    func testASegmentAppliesUnderItsGenerationAndAnOlderGenerationIsAnsweredStale() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("x1", ["title": "only here"]), row("n00001", ["title": "old"])])
        _ = try store.commitEntries(
            writer: writer, writes: [RecordLogWrite(mutations: [mutation("mine", .create, ["title": "pending"])])]
        )
        _ = try store.beginReceipt(writer: writer, kind: .segment, id: "G1")
        let first = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        let rows = try store.applySegmentChunk(
            writer: writer, generation: first,
            rows: [row("n00001", ["title": "at B"]), row("n00002", ["title": "at B"])]
        )
        XCTAssertEqual(rows.applied, 2)
        XCTAssertEqual(rows.models, ["Note"])
        XCTAssertEqual(rows.ranges, [RecordLogIdRange(model: "Note", firstId: "n00001", lastId: "n00002")])
        let corrections = try store.applySegmentCorrections(
            writer: writer, generation: first,
            lines: [
                RecordLogCorrection(model: "Note", id: "n00002", row: nil),
                RecordLogCorrection(model: "Note", id: "n00003", row: ["id": "n00003", "title": "after B"]),
            ]
        )
        XCTAssertEqual(corrections.applied, 1)
        XCTAssertEqual(corrections.removed, 1)

        // Another client of the store begins its own replacement: this one is stale.
        let second = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertGreaterThan(second, first)
        let before = try provider.withConnection { try $0.query("SELECT _id, _data FROM record_log_rows ORDER BY _id", []) }
            .map { "\($0["_id"].stringValue ?? "")=\($0["_data"].stringValue ?? "")" }
        XCTAssertTrue(try store.applySegmentChunk(writer: writer, generation: first, rows: [row("z", [:])]).stale)
        XCTAssertTrue(try store.applySegmentCorrections(writer: writer, generation: first, lines: []).stale)
        XCTAssertTrue(try store.applyCatchUpPage(writer: writer, rows: [row("z", [:])], generation: first).stale)
        XCTAssertTrue(try store.completeCatchUp(writer: writer, lsn: 30, full: true, generation: first).stale)
        let after = try provider.withConnection { try $0.query("SELECT _id, _data FROM record_log_rows ORDER BY _id", []) }
            .map { "\($0["_id"].stringValue ?? "")=\($0["_data"].stringValue ?? "")" }
        XCTAssertEqual(after, before)
        XCTAssertEqual(try store.marks().cursor, 0)

        // The surviving replacement puts its rows and completes.
        _ = try store.applySegmentChunk(
            writer: writer, generation: second,
            rows: [row("n00001", ["title": "at B"]), row("n00003", ["title": "after B"])]
        )
        let done = try store.completeCatchUp(writer: writer, lsn: 30, high: 3, full: true, generation: second)
        XCTAssertFalse(done.stale)
        let marks = try store.marks()
        XCTAssertEqual(marks.cursor, 30)
        XCTAssertNil(marks.receipt)
        XCTAssertFalse(marks.replacing)
        XCTAssertEqual(try rowIds(provider), ["n00001", "n00003"])
        XCTAssertNil(try store.read(model: "Note", id: "x1"))
        XCTAssertNil(try queryRow(provider, "x1"))
        // The client's own unjudged create keeps its guess.
        XCTAssertEqual(try store.read(model: "Note", id: "mine"), ["id": "mine", "title": "pending"])
    }

    // MARK: - A model never registered (edge 005)

    /// A model's rows are in the view whether or not a model was ever
    /// registered for it; until #4700 its query tables were rebuilt from the
    /// view when it was (a projection pin the retirement moved).
    func testARefreshOfAModelNeverRegisteredFillsTheView() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let a = try attempt(store, writer)
        _ = try store.applyLoadChunk(writer: writer, sessionId: Self.session, attempt: a, model: "Note", lines: lines(3))
        _ = try store.completeLoad(writer: writer, sessionId: Self.session, attempt: a, mode: .refresh, models: ["Note"])
        XCTAssertEqual(try store.read(model: "Note", id: "n00002")?["title"], "t2")
        XCTAssertEqual(try queryRow(provider, "n00002"), ["id": "n00002", "title": "t2", "slug": .null, "n": 2])
        XCTAssertEqual(try count(provider, "SELECT COUNT(*) AS n FROM record_log_view WHERE _type = 'Note'"), 3)
    }

    // MARK: - Results held ahead of the cursor (behavior 31, the store's line)

    func testMoreThanTenThousandHeldResultsAreSaidOnceUntilTheyFallBelowIt() async throws {
        let provider = try await makeProvider()
        let lines = LockedLines()
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("results held ahead of the cursor") { lines.append(message) }
        }
        let (store, writer) = try opened(provider, logger: Logger(level: .warn))
        // The load took 1..20000; the results after it arrive while its chunks apply.
        let items = (20_001...30_002).map { l in
            RecordLogResultItem.result(RecordLogResult(
                l: l, e: 1, changes: [RecordLogChange(json: .object(["model": "Note", "id": .string("r\(l)"), "gone": true]))!]
            ))
        }
        _ = try store.receive(writer: writer, items: items)
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all.first?.contains("[record-log] doc-1: 10001 results held ahead of the cursor 0") == true, lines.all.first ?? "")
        _ = try store.receive(writer: writer, items: [items[0]])
        XCTAssertEqual(lines.all.count, 1, "said once")
        _ = try store.completeCatchUp(writer: writer, lsn: 30_002)
        _ = try store.receive(writer: writer, items: (30_004...40_006).map { l in
            RecordLogResultItem.result(RecordLogResult(l: l, e: 1, changes: []))
        })
        XCTAssertEqual(lines.all.count, 2, "said again once they fell below it and passed it again")
    }
}

/// Lines a test collects from the logger's test seam.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

