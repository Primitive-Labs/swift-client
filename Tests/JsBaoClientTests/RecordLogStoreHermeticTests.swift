import XCTest
@testable import JsBaoClient

/// The record-log store over a real `SQLiteStorageProvider` on a temp file:
/// its tables, its writer, its commits, and the rules it runs inside its
/// commands — refusals, results, catch-up, the epoch budget and the writer
/// re-mint. No server: the room's answers are the JS wire's shapes, built here.
final class RecordLogStoreHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "u": FieldDescriptor(type: .string, unique: true),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/record-log-store-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeProvider(path: String? = nil) async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: path ?? newDatabasePath())
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A store with its tables, the `Note` query tables, and a minted writer.
    private func makeStore(_ provider: SQLiteStorageProvider, documentId: String = "doc-1") throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1")
        try store.initialize()
        try RecordLogQueryProjection.prepare(schema: Self.schema, engine: BaoModelQueryEngine(host: provider), host: provider)
        return (store, try store.mintWriter())
    }

    private var spec: RecordLogProjectionSpec { RecordLogProjectionSpec(schema: Self.schema) }

    private func note(_ id: String, _ kind: RecordLogWriteKind = .create, _ fields: [String: JSONValue]? = nil,
                      tags: [String: Bool]? = nil) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: kind, fields: fields, stringSetDeltas: tags.map { ["tags": $0] })
    }

    @discardableResult
    private func write(_ store: RecordLogStore, _ writer: String, _ mutations: RecordLogMutation..., upsertOn: String? = nil) throws -> RecordLogPendingEntry {
        try store.commitEntries(
            writer: writer, writes: [RecordLogWrite(mutations: mutations, upsertOn: upsertOn)], project: [spec]
        ).entries[0]
    }

    private func key(_ id: String) -> RecordLogRecordKey { RecordLogRecordKey(model: "Note", id: id) }

    private func result(_ l: Int, e: Int = 1, _ changes: [RecordLogChange], w: String? = nil, seq: Int? = nil,
                        alias: RecordLogAlias? = nil) -> RecordLogResultItem {
        .result(RecordLogResult(l: l, e: e, changes: changes, alias: alias, w: w, seq: seq))
    }

    private func tableNames(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection { connection in
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .compactMap { $0["name"].stringValue }
        }
    }

    private func columns(_ provider: SQLiteStorageProvider, _ table: String) throws -> [String] {
        try provider.withConnection { connection in
            try connection.query("PRAGMA table_info(\"\(table)\")").map {
                "\($0["name"].stringValue ?? "") \($0["type"].stringValue ?? "")"
            }
        }
    }

    // MARK: - Behavior 1: the tables

    func testInitializeCreatesTheElevenTablesWithTheJSColumnsAndTheOwnerTableIdempotently() async throws {
        let provider = try await makeProvider()
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-1")
        try store.initialize()
        try store.initialize()

        let names = Set(try tableNames(provider).filter { $0.hasPrefix("record_log_") })
        XCTAssertEqual(names, Set(RecordLogSchema.clientTables + ["record_log_owner"]))
        XCTAssertEqual(RecordLogSchema.clientTables.count, 11)
        XCTAssertEqual(try columns(provider, "record_log_rows"), ["doc_id TEXT", "_type TEXT", "_id TEXT", "_data TEXT", "_gen INTEGER"])
        XCTAssertEqual(try columns(provider, "record_log_view"), ["doc_id TEXT", "_type TEXT", "_id TEXT", "_data TEXT"])
        XCTAssertEqual(try columns(provider, "record_log_state"), [
            "doc_id TEXT", "cursor INTEGER", "open_epoch INTEGER", "grant_epoch INTEGER", "epoch_entries INTEGER",
            "constraints TEXT", "last_catch_up_at INTEGER", "permission TEXT", "rows_gen INTEGER", "replacing INTEGER",
            "receipt TEXT",
        ])
        XCTAssertEqual(try columns(provider, "record_log_writers"), [
            "doc_id TEXT", "client_id TEXT", "writer TEXT", "next_seq INTEGER", "resumed_at INTEGER",
        ])
        XCTAssertEqual(try columns(provider, "record_log_pending"), [
            "doc_id TEXT", "writer TEXT", "seq INTEGER", "ord INTEGER", "e INTEGER", "entry TEXT", "ts INTEGER",
            "void INTEGER", "acked INTEGER",
        ])
        XCTAssertEqual(try columns(provider, "record_log_pending_keys"), [
            "doc_id TEXT", "writer TEXT", "seq INTEGER", "_type TEXT", "_id TEXT", "resolved INTEGER",
        ])
        XCTAssertEqual(try columns(provider, "record_log_pending_values"), [
            "doc_id TEXT", "writer TEXT", "seq INTEGER", "_type TEXT", "field TEXT", "value ", "upsert INTEGER",
        ])
        XCTAssertEqual(try columns(provider, "record_log_handled"), [
            "doc_id TEXT", "writer TEXT", "_type TEXT", "_id TEXT", "from_seq INTEGER", "until_seq INTEGER",
        ])
        XCTAssertEqual(try columns(provider, "record_log_epoch_counts"), ["doc_id TEXT", "epoch INTEGER", "count INTEGER"])
        XCTAssertEqual(try columns(provider, "record_log_projection"), ["doc_id TEXT", "model TEXT"])
        XCTAssertEqual(try columns(provider, "record_log_load_keys"), ["doc_id TEXT", "attempt TEXT", "_type TEXT", "_id TEXT"])
        XCTAssertEqual(try columns(provider, "record_log_owner"), ["user_id TEXT"])
        let rows = try provider.withConnection { try $0.query("SELECT COUNT(*) AS n FROM record_log_state") }
        XCTAssertEqual(rows.first?["n"].intValue, 0, "creating the tables writes no row")
    }

    func testAFormatOneSessionCreatesNoRecordLogTable() async throws {
        let path = newDatabasePath()
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "record-log-format-one-app",
            token: makeTestJwt(userId: "record-log-format-one-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let created = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        try client.codegen.save(Self.schema, id: "n1", values: ["title": .string("one")], in: documentId)
        XCTAssertEqual(try client.codegen.query(Self.schema).count, 1)
        await client.destroy()

        let reopened = try await makeProvider(path: path)
        let names = try tableNames(reopened)
        XCTAssertTrue(names.contains("kv_store"), "the session wrote its own storage: \(names)")
        XCTAssertEqual(names.filter { $0.hasPrefix("record_log_") }, [], "a client that never binds a format-3 document creates none")
    }

    // MARK: - Behavior 2: the writer

    func testMintWriterMintsOneULIDPerDocumentAndClientAndAnswersItAgain() async throws {
        let provider = try await makeProvider()
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-1")
        XCTAssertEqual(try store.storedState(), RecordLogStoredState(cursor: 0, rows: 0, writers: [], replacing: false),
                       "an unbound document: cursor 0, no rows, no writers — and nothing created")
        XCTAssertEqual(try tableNames(provider).filter { $0.hasPrefix("record_log_") }, [])
        try store.initialize()
        XCTAssertNil(try store.writer())

        let writer = try store.mintWriter()
        XCTAssertEqual(writer.count, 26)
        XCTAssertTrue(writer.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }, writer)
        XCTAssertEqual(try store.mintWriter(), writer)
        XCTAssertEqual(try store.writer(), writer)

        let other = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-2")
        XCTAssertNotEqual(try other.mintWriter(), writer, "another client of the store has a writer of its own")
        let elsewhere = RecordLogStore(host: provider, documentId: "doc-2", clientId: "client-1")
        XCTAssertNotEqual(try elsewhere.mintWriter(), writer, "another document has a writer of its own")
        XCTAssertEqual(try RecordLogStore(host: provider, documentId: "doc-3", clientId: "client-1").storedState(),
                       RecordLogStoredState(cursor: 0, rows: 0, writers: [], replacing: false))
    }

    // MARK: - Behavior 3: a commit

    func testCommitWritesThePendingEntryTheViewRowAndTheQueryRow() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)

        let first = try write(store, writer, note("n1", .create, ["title": "one", "u": .null], tags: ["b": true, "a": true, "é": true]))
        XCTAssertEqual([first.seq, first.e, first.k], [1, 1, 0])
        let second = try write(store, writer, note("n1", .patch, tags: ["a": false, "Z": true]))
        XCTAssertEqual(second.seq, 2)

        let row = try XCTUnwrap(try store.read(model: "Note", id: "n1"))
        XCTAssertEqual(row["u"], .null, "a field written null is a present null")
        XCTAssertEqual(row["title"], "one")
        XCTAssertEqual(row["tags"], ["Z", "b", "é"], "members in code-point order")
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [1, 2])
        XCTAssertEqual(try store.marks().nextSeq, 3)

        let projected = try provider.withConnection { connection in
            try connection.query("SELECT * FROM \"Note\" WHERE _meta_doc_id = ? AND id = ?", [.text("doc-1"), .text("n1")])
        }
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?["title"].stringValue, "one")
        let members = try provider.withConnection { connection in
            try connection.query("SELECT value FROM \"Note__tags\" WHERE _meta_doc_id = ? ORDER BY value", [.text("doc-1")])
        }.compactMap { $0["value"].stringValue }
        XCTAssertEqual(members, ["Z", "b", "é"])

        // The entry, its view row and its query row are one save: read back
        // after the group committed, they are all there.
        try store.flush()
        let stored = try provider.withConnection { connection in
            try connection.query("SELECT seq, e, entry FROM record_log_pending WHERE doc_id = ? ORDER BY seq", [.text("doc-1")])
        }
        XCTAssertEqual(stored.compactMap { $0["seq"].intValue }, [1, 2])
        XCTAssertEqual(stored.first?["e"].intValue, 1)
    }

    // MARK: - Behavior 6: refusals

    func testARecordRefusalHandsBackTheClosureLeavesVoidMarkersAndResumesOnce() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try write(store, writer, note("a", .create, ["title": "a"]))                     // 1
        try write(store, writer, note("b", .create, ["title": "b"]))                     // 2
        try write(store, writer, note("a", .patch, ["title": "a2"]), note("c", .create, ["title": "c"]))  // 3
        try write(store, writer, note("c", .patch, ["title": "c2"]))                     // 4
        try write(store, writer, note("b", .patch, ["title": "b2"]))                     // 5

        let refusal = RecordLogRefusal(
            seq: 1, code: "DOCUMENT_CONSTRAINT_VIOLATED", scope: .record, from: 1,
            records: [RecordLogRefusedRecord(model: "Note", id: "a", from: 1)]
        )
        let reply = try store.refused(writer: writer, refusal: refusal, project: [spec])
        XCTAssertEqual(reply.handedBack.map(\.seq), [1, 3, 4], "the refused record, and a withdrawn entry's other record from its number")
        XCTAssertEqual(reply.frames, [.resume(nextSeq: 6, records: [
            RecordLogRefusedRecord(model: "Note", id: "a", from: 1),
            RecordLogRefusedRecord(model: "Note", id: "c", from: 3),
        ])])
        let pending = try store.pendingOf(writer)
        XCTAssertEqual(pending.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertEqual(pending.filter(\.isVoid).map(\.seq), [1, 3, 4], "withdrawn entries stay in line as void markers")
        XCTAssertNil(try store.read(model: "Note", id: "a"))
        XCTAssertNil(try store.read(model: "Note", id: "c"))
        XCTAssertEqual(try store.read(model: "Note", id: "b")?["title"], "b2", "a record outside the closure is untouched")

        let again = try store.refused(writer: writer, refusal: refusal, project: [spec])
        XCTAssertEqual(again.handedBack.map(\.seq), [], "a refusal already acted on hands back nothing")
        XCTAssertEqual(again.frames, [], "and answers nothing")
    }

    func testAWriterRefusalHandsBackFromItsNumberAndAStaleOneOnlyTheRunBeforeTheResume() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        for id in ["a", "b", "c"] { try write(store, writer, note(id, .create, ["title": .string(id)])) }

        let reply = try store.refused(
            writer: writer,
            refusal: RecordLogRefusal(seq: 2, code: "DOCUMENT_OFFLINE_WINDOW_EXPIRED", scope: .writer, from: 2),
            project: [spec]
        )
        XCTAssertEqual(reply.handedBack.map(\.seq), [2, 3])
        XCTAssertEqual(reply.frames, [.resume(nextSeq: 4, records: nil)])
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [1])

        try write(store, writer, note("d", .create, ["title": "d"]))  // 4, after the resume
        let stale = try store.refused(
            writer: writer,
            refusal: RecordLogRefusal(seq: 1, code: "DOCUMENT_EPOCH_FROZEN", scope: .writer, from: 1),
            project: [spec]
        )
        XCTAssertEqual(stale.handedBack.map(\.seq), [1], "only the run before the resume")
        XCTAssertEqual(stale.frames, [], "a stale refusal answers no frame")
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [4])
    }

    // MARK: - Behavior 7 and edge 37: results

    func testResultsApplyInLogOrderAcknowledgeAtOnceAndSettleOnceTheCursorPasses() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try write(store, writer, note("a", .create, ["title": "a"]))   // 1
        try write(store, writer, note("b", .create, ["title": "b"]))   // 2
        try write(store, writer, note("c", .create, ["title": "c"]))   // 3

        // Our seq 2 is acknowledged at log number 3, ahead of the cursor: it is
        // acknowledged at once, and waits for 1 and 2 to settle.
        let ahead = try store.receive(writer: writer, items: [
            result(3, [RecordLogChange(model: "Note", id: "b", row: ["id": "b", "title": "b"])], w: writer, seq: 2),
        ], project: [spec])
        XCTAssertEqual(ahead.acknowledged, [RecordLogEntryRef(writer: writer, seq: 2)])
        XCTAssertEqual(ahead.settled, [])
        XCTAssertEqual(ahead.cursor, 0, "a result two ahead waits for the gap")
        XCTAssertEqual(try store.pendingOf(writer).first { $0.seq == 2 }?.acked, 3)

        let gap = try store.receive(writer: writer, items: [
            result(1, [RecordLogChange(model: "Note", id: "x", row: ["id": "x", "title": "other"])]),
            result(2, [RecordLogChange(model: "Note", id: "a", row: ["id": "a", "title": "a"])], w: writer, seq: 1),
        ], project: [spec])
        XCTAssertEqual(gap.cursor, 3, "the gap filled: 1, 2 and the held 3 applied in order")
        XCTAssertEqual(Set(gap.settled.map(\.seq)), [1, 2], "this writer's entries up to the acknowledged one confirmed")
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [3])
        XCTAssertEqual(try store.read(model: "Note", id: "x")?["title"], "other")

        // A result at or below the cursor is ignored — but still acknowledges.
        let late = try store.receive(writer: writer, items: [
            result(2, [RecordLogChange(model: "Note", id: "c", row: ["id": "c", "title": "WRONG"])], w: writer, seq: 3),
        ], project: [spec])
        XCTAssertEqual(late.acknowledged, [RecordLogEntryRef(writer: writer, seq: 3)])
        XCTAssertEqual(late.cursor, 3)
        XCTAssertNil(try store.confirmedRows().first { $0["id"] == "c" }, "a result at or below the cursor is not applied")
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [], "the cursor has passed its log number, so it settles at once")
    }

    func testAnAliasRenamesLaterWritesAndVoidAndDuplicateItemsSettle() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try write(store, writer, note("mine", .create, ["u": "k1", "title": "t"]), upsertOn: "u")  // 1
        try write(store, writer, note("mine", .patch, ["title": "t2"]))                           // 2
        try write(store, writer, note("z", .create, ["title": "z"]))                              // 3
        try write(store, writer, note("y", .create, ["title": "y"]))                              // 4

        _ = try store.receive(writer: writer, items: [
            result(1, [RecordLogChange(model: "Note", id: "theirs", set: ["title": "t"])], w: writer, seq: 1,
                   alias: RecordLogAlias(model: "Note", from: "mine", to: "theirs")),
        ], project: [spec])
        let renamed = try XCTUnwrap(try store.pendingOf(writer).first { $0.seq == 2 })
        XCTAssertEqual(renamed.m.id, "theirs", "what the writer wrote since belongs to the record the upsert resolved to")

        let settled = try store.receive(writer: writer, items: [.void(seq: 3), .duplicate(seq: 4)], project: [spec])
        XCTAssertEqual(settled.settled.map(\.seq), [3, 4])
        XCTAssertEqual(settled.acknowledged.map(\.seq), [4], "a duplicate was accepted before; a void was not")
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [2])
    }

    // MARK: - Behavior 8: catch-up

    func testAFullCatchUpReplacesTheRowsEvenThoseAnInterruptedAttemptPut() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try store.beginCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Note", id: "old", row: ["id": "old", "title": "old"]),
        ], project: [spec])
        _ = try store.completeCatchUp(writer: writer, lsn: 5, full: true, project: [spec])

        // An attempt that put a row and was interrupted…
        try store.beginCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Note", id: "half", row: ["id": "half", "title": "interrupted"]),
        ], lsn: 6, project: [spec])
        XCTAssertTrue(try store.storedState().replacing)
        // …and the next that completes.
        try store.beginCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Note", id: "new", row: ["id": "new", "title": "new"]),
        ], lsn: 7, project: [spec])
        let done = try store.completeCatchUp(writer: writer, lsn: 7, high: 3, full: true, project: [spec])
        XCTAssertEqual(done.cursor, 7)
        XCTAssertEqual(try store.confirmedRows().compactMap { $0["id"]?.stringValue }, ["new"])
        XCTAssertNil(try store.read(model: "Note", id: "half"))
        XCTAssertNil(try store.read(model: "Note", id: "old"))
        XCTAssertFalse(try store.storedState().replacing)
        XCTAssertEqual(try store.marks().open, 3, "the catch-up saw epoch 3")
        let projected = try provider.withConnection {
            try $0.query("SELECT id FROM \"Note\" WHERE _meta_doc_id = ? ORDER BY id", [.text("doc-1")])
        }.compactMap { $0["id"].stringValue }
        XCTAssertEqual(projected, ["new"])
    }

    func testPagedCatchUpAppliesPagesAndAPageOrCompletionBelowTheCursorIsStale() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Note", id: "p1", row: ["id": "p1"]),
        ], lsn: 10, project: [spec])
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Note", id: "p2", row: ["id": "p2"]),
        ], gone: [key("p1")], lsn: 10, project: [spec])
        let done = try store.completeCatchUp(writer: writer, lsn: 10, high: 2, project: [spec])
        XCTAssertFalse(done.stale)
        XCTAssertEqual(done.cursor, 10)
        XCTAssertEqual(try store.readRowsAfter(model: "Note", after: nil, limit: 10).compactMap { $0["id"]?.stringValue }, ["p2"])
        XCTAssertEqual(try store.marks().grant, 2)

        let stalePage = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Note", id: "stale", row: ["id": "stale"]),
        ], lsn: 9, project: [spec])
        XCTAssertTrue(stalePage.stale)
        let staleDone = try store.completeCatchUp(writer: writer, lsn: 9, project: [spec])
        XCTAssertTrue(staleDone.stale)
        XCTAssertEqual(staleDone.cursor, 10, "the cursor never moves back")
        XCTAssertNil(try store.read(model: "Note", id: "stale"), "a stale page changes nothing")
    }

    // MARK: - Behavior 9 and edge 49: the epoch budget

    func testTheBudgetSpillsToTheGrantedEpochAndRefusesWhenBothAreFull() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try store.setState(writer: writer, notice: (current: 1, next: 2, entries: 3))
        _ = try store.receive(writer: writer, items: [result(1, e: 1, [])], project: [spec])   // one applied in epoch 1
        try write(store, writer, note("a", .create, ["title": "a"]))
        try write(store, writer, note("b", .create, ["title": "b"]))                         // epoch 1 holds 3
        let spilled = try write(store, writer, note("c", .create, ["title": "c"]))
        XCTAssertEqual(spilled.e, 2, "the open epoch is full: the write spills to the granted one")
        try write(store, writer, note("d", .create, ["title": "d"]))
        try write(store, writer, note("e", .create, ["title": "e"]))                         // epoch 2 holds 3

        XCTAssertThrowsError(try write(store, writer, note("f", .create, ["title": "f"]))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .documentEpochBudget)
        }
        XCTAssertNil(try store.read(model: "Note", id: "f"), "nothing of a refused save lands")
        XCTAssertEqual(try store.marks().nextSeq, 6)

        // A notice raises the grant; the open epoch never moves below what was seen.
        try store.setState(writer: writer, notice: (current: 1, next: 3, entries: nil))
        XCTAssertEqual(try store.marks().open, 2)
        XCTAssertEqual(try store.marks().grant, 3)
        try store.sawEpoch(writer: writer, 1)
        XCTAssertEqual([try store.marks().open, try store.marks().grant], [2, 3], "sawEpoch never lowers either")
        XCTAssertEqual(try write(store, writer, note("f", .create, ["title": "f"])).e, 3)
        try store.spill(writer: writer)
        XCTAssertEqual(try store.marks().open, 3, "spill does not pass the grant")
    }

    // MARK: - Behavior 10 and edge 40: re-mint and purge

    func testRemintRenumbersTheUnacknowledgedEntriesAndKeepsAcknowledgedOnesUnderTheOldId() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try write(store, writer, note("a", .create, ["title": "a"]))                         // 1, acknowledged below
        try write(store, writer, note("b", .create, ["title": "b"]))                         // 2
        try write(store, writer, note("c", .create, ["title": "c"]))                         // 3, withdrawn
        try store.setState(writer: writer, notice: (current: 2, next: 3, entries: nil))
        try write(store, writer, note("d", .create, ["title": "d"]))                         // 4, epoch 2
        _ = try store.receive(writer: writer, items: [result(5, [], w: writer, seq: 1)], project: [spec])
        _ = try store.refused(writer: writer, refusal: RecordLogRefusal(
            seq: 3, code: "DOCUMENT_CONSTRAINT_VIOLATED", scope: .record, from: 3,
            records: [RecordLogRefusedRecord(model: "Note", id: "c", from: 3)]
        ), project: [spec])
        let before = try store.pendingOf(writer)

        let (fresh, renumbered) = try store.remintWriter(writer)
        XCTAssertNotEqual(fresh, writer)
        XCTAssertEqual(renumbered.map(\.from), [2, 4])
        XCTAssertEqual(renumbered.map(\.to), [1, 2])
        let moved = try store.pendingOf(fresh)
        XCTAssertEqual(moved.map(\.seq), [1, 2])
        XCTAssertEqual(moved.map(\.e), before.filter { [2, 4].contains($0.seq) }.map(\.e), "epochs kept")
        XCTAssertEqual(moved.map(\.k), before.filter { [2, 4].contains($0.seq) }.map(\.k), "cursors kept")
        XCTAssertEqual(moved.map(\.m.id), ["b", "d"])
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [1], "the acknowledged entry stays under the old id until it settles")
        XCTAssertEqual(try store.writer(), fresh)
        XCTAssertEqual(try store.marks().nextSeq, 3)
        let handled = try provider.withConnection { try $0.query("SELECT COUNT(*) AS n FROM record_log_handled") }
        XCTAssertEqual(handled.first?["n"].intValue, 0, "the refusals it acted on are dropped")

        // Edge 40: a writer whose entries are all acknowledged (their results
        // held behind a gap, so not yet settled) renumbers nothing, and its
        // next sequence number is 1.
        _ = try store.receive(writer: fresh, items: [
            result(8, [], w: fresh, seq: 1), result(9, [], w: fresh, seq: 2),
        ], project: [spec])
        XCTAssertEqual(try store.pendingOf(fresh).compactMap(\.acked), [8, 9])
        let (last, nothing) = try store.remintWriter(fresh)
        XCTAssertEqual(nothing.count, 0)
        XCTAssertEqual(try store.marks().nextSeq, 1)
        XCTAssertEqual(try store.writer(), last)
        XCTAssertEqual(try store.pendingOf(fresh).map(\.seq), [1, 2], "kept under the id they were acknowledged for")
    }

    func testPurgeIsRefusedWhilePendingAndAForcedPurgeRemovesEverythingAndAnswersWhatItDropped() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        let (other, otherWriter) = try makeStore(provider, documentId: "doc-2")
        try write(store, writer, note("a", .create, ["title": "a"]))
        try write(store, writer, note("b", .create, ["title": "b"], tags: ["x": true]))
        try write(other, otherWriter, note("keep", .create, ["title": "kept"]))
        _ = try store.projectModel(spec: spec)

        let refused = try store.purge(force: false, project: [spec])
        XCTAssertFalse(refused.purged)
        XCTAssertTrue(refused.refusedForPending)
        XCTAssertEqual(refused.pendingOps, 2)
        XCTAssertNotNil(try store.read(model: "Note", id: "a"))

        let purged = try store.purge(force: true, project: [spec])
        XCTAssertTrue(purged.purged)
        XCTAssertEqual(purged.handedBack.map(\.m.id), ["a", "b"], "in write order")
        try provider.withConnection { connection in
            for table in RecordLogSchema.clientTables {
                let n = try connection.query("SELECT COUNT(*) AS n FROM \(table) WHERE doc_id = 'doc-1'").first?["n"].intValue
                XCTAssertEqual(n, 0, table)
            }
            XCTAssertEqual(try connection.query("SELECT COUNT(*) AS n FROM \"Note\" WHERE _meta_doc_id = 'doc-1'").first?["n"].intValue, 0)
            XCTAssertEqual(try connection.query("SELECT COUNT(*) AS n FROM \"Note__tags\" WHERE _meta_doc_id = 'doc-1'").first?["n"].intValue, 0)
            XCTAssertEqual(try connection.query("SELECT COUNT(*) AS n FROM \"Note\" WHERE _meta_doc_id = 'doc-2'").first?["n"].intValue, 1,
                           "another document is untouched")
        }
        XCTAssertEqual(try other.read(model: "Note", id: "keep")?["title"], "kept")
    }

    // MARK: - Edge 38: upsert holders in view order

    func testAnUpsertResolvesToTheFirstHolderInViewOrder() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        // Confirmed rows in arrival order: "z" first, then "a" — both hold k1.
        _ = try store.receive(writer: writer, items: [
            result(1, [RecordLogChange(model: "Note", id: "z", row: ["id": "z", "u": "k1"])]),
            result(2, [RecordLogChange(model: "Note", id: "a", row: ["id": "a", "u": "k1"])]),
        ], project: [spec])
        try write(store, writer, note("mine", .create, ["u": "k1", "title": "upserted"]), upsertOn: "u")
        XCTAssertEqual(try store.read(model: "Note", id: "z")?["title"], "upserted", "the first confirmed row in arrival order")
        XCTAssertNil(try store.read(model: "Note", id: "a")?["title"])
        XCTAssertNil(try store.read(model: "Note", id: "mine"))

        // A guess-held record comes after every confirmed row; one a guess creates goes last.
        try write(store, writer, note("g1", .create, ["u": "k2"]))
        try write(store, writer, note("g2", .create, ["u": "k2"]))
        try write(store, writer, note("mine2", .create, ["u": "k2", "title": "second"]), upsertOn: "u")
        XCTAssertEqual(try store.read(model: "Note", id: "g1")?["title"], "second")

        // A result that gives another record the value moves the guess: the
        // refresh reaching a record with an unjudged upsert recomputes it.
        _ = try store.receive(writer: writer, items: [
            result(3, [RecordLogChange(model: "Note", id: "z", set: ["u": "k9"])]),
        ], project: [spec])
        XCTAssertEqual(try store.read(model: "Note", id: "a")?["title"], "upserted", "the guess moved to the next holder")
        XCTAssertNil(try store.read(model: "Note", id: "z")?["title"])
    }
}
