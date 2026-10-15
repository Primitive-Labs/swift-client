import XCTest
@testable import JsBaoClient

/// Keeping the chunks of the segment a store holds (#4394 behavior 21, and
/// edges 035–038): the Swift twin of js-bao's
/// `record-log-client-segment-keep-4394` and `-session-keep-4394` suites,
/// over memory tables, the SQL store on a temp file, and a session whose
/// connection serves the room's artifacts from memory.
///
/// - Rules and store: under the replacement's generation, `keepSegmentChunk`
///   marks exactly the confirmed-generation rows of the model in
///   `[firstId, lastId]` as the replacement's when their count equals `rows`
///   and the held marker lists the same object, digest, rows and range; it
///   answers mismatch and changes nothing otherwise, or while another receipt
///   attempt is in progress, and does not count rows an interrupted
///   replacement put; it is stale under a superseded generation and for an
///   attempt no longer in progress.
/// - Marker: a segment receipt's completion writes `record_log_state.segment`,
///   `marks.segment` reports it, the replacement's begin answers it; a full
///   paged replacement's completion and a purge clear it; a store created
///   before the column gains it.
/// - Session: holding S1 and pointed at S2 it keeps the held chunk and fetches
///   only the rewritten one and the corrections; a mismatch falls back to the
///   fetch (036); a chunk rewritten with identical bytes is fetched (035);
///   another session's load that changes a kept range between the held read
///   and the keep leaves the store equal to the room; a later replacement
///   makes the earlier's keeps stale, the marker naming the segment that
///   completed (037); an interrupted receipt leaves an attempt in progress, so
///   the next keeps nothing (038).
final class RecordLogSegmentKeepHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private let writer = "01JW4394KEEPWR1TER00000001"
    private static let s1 = "01JG4394SEGMENT0NE00000001"
    private static let s2 = "01JG4394SEGMENTTW000000002"
    private static let load = "01JS4394SESS10NL0ADXXXXX01"

    private var directories: [String] = []

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let held = RecordLogHeldSegment(
        segmentId: s1,
        chunks: [
            RecordLogHeldSegmentChunk(object: "\(s1)/Note/0", model: "Note", index: 0, firstId: "n1", lastId: "n2", rows: 2, sha256: "sha-a"),
            RecordLogHeldSegmentChunk(object: "\(s1)/Note/1", model: "Note", index: 1, firstId: "n3", lastId: "n4", rows: 2, sha256: "sha-b"),
        ]
    )

    private struct Keep {
        var object = "\(RecordLogSegmentKeepHermeticTests.s1)/Note/0"
        var sha256 = "sha-a"
        var firstId = "n1"
        var lastId = "n2"
        var rows = 2
    }

    private func row(_ id: String, _ title: String? = nil) -> RecordLogCatchUpRow {
        RecordLogCatchUpRow(model: "Note", id: id, row: ["id": .string(id), "title": .string(title ?? "t-\(id)")])
    }

    func testTheObjectIsTheSourceSegmentsElseTheSegmentsOwn() {
        XCTAssertEqual(recordLogSegmentChunkObject(segmentId: Self.s2, model: "Note", index: 3, source: nil), "\(Self.s2)/Note/3")
        XCTAssertEqual(recordLogSegmentChunkObject(segmentId: Self.s2, model: "Note", index: 3, source: Self.s1), "\(Self.s1)/Note/3")
        let json = RecordLogJSON.parse(RecordLogJSON.text(Self.held.json))
        XCTAssertEqual(RecordLogHeldSegment(json: json), Self.held)
    }

    // MARK: - The rules, over memory tables

    private func holdingS1() throws -> (tables: RecordLogMemoryTables, rules: RecordLogRules) {
        let tables = RecordLogMemoryTables(writers: [writer])
        let rules = RecordLogRules(tables: tables, writer: writer)
        let attempt = try rules.beginReceipt(RecordLogReceipt(kind: .segment, id: Self.s1))
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.applySegmentRows(generation: generation, attempt: attempt, rows: ["n1", "n2", "n3", "n4"].map { row($0) })
        _ = try rules.completeCatchUp(lsn: 10, high: nil, full: true, generation: generation, receipt: attempt, segment: Self.held)
        return (tables, rules)
    }

    private func receivingS2(_ rules: RecordLogRules) throws -> (attempt: String, generation: Int) {
        let attempt = try rules.beginReceipt(RecordLogReceipt(kind: .segment, id: Self.s2))
        return (attempt, try XCTUnwrap(try rules.beginFencedCatchUp(full: true)))
    }

    private func keep(_ rules: RecordLogRules, _ attempt: String, _ generation: Int, _ k: Keep = Keep()) throws -> RecordLogKeepOutcome {
        try rules.keepSegmentChunk(
            generation: generation, attempt: attempt, object: k.object, sha256: k.sha256, model: "Note",
            firstId: k.firstId, lastId: k.lastId, rows: k.rows
        )
    }

    private func ids(_ tables: RecordLogMemoryTables) -> [String] { tables.rows.orderedRows.map { $0.0.id }.sorted() }

    func testTheRulesKeepAHeldChunksRowsAndTheCompletionKeepsThemWhileDroppingTheRest() throws {
        let (tables, rules) = try holdingS1()
        XCTAssertEqual(tables.heldSegment(), Self.held)
        let (attempt, generation) = try receivingS2(rules)
        XCTAssertEqual(
            try keep(rules, attempt, generation),
            .kept(rows: 2, ranges: [RecordLogIdRange(model: "Note", firstId: "n1", lastId: "n2")])
        )
        _ = try rules.applySegmentRows(generation: generation, attempt: attempt, rows: [row("n3", "new"), row("n5")])
        let marker = RecordLogHeldSegment(segmentId: Self.s2, chunks: [
            Self.held.chunks[0],
            RecordLogHeldSegmentChunk(object: "\(Self.s2)/Note/0", model: "Note", index: 0, firstId: "n3", lastId: "n5", rows: 2, sha256: "sha-c"),
        ])
        let out = try rules.completeCatchUp(lsn: 20, high: nil, full: true, generation: generation, receipt: attempt, segment: marker)
        XCTAssertEqual(out.touched.map(\.id), ["n4"])
        XCTAssertEqual(ids(tables), ["n1", "n2", "n3", "n5"])
        XCTAssertEqual(tables.rows.row(RecordLogRecordKey(model: "Note", id: "n3"))?["title"], "new")
        XCTAssertEqual(tables.heldSegment(), marker)
    }

    func testTheRulesAnswerMismatchWhenTheCountTheMarkerOrAnotherAttemptDiffers() throws {
        // The count: n2 left the confirmed rows after S1 (edge 036).
        do {
            let (tables, rules) = try holdingS1()
            _ = try rules.catchUp(RecordLogCatchUpInput(rows: [], gone: [RecordLogRecordKey(model: "Note", id: "n2")]), lsn: 12, high: nil)
            let (attempt, generation) = try receivingS2(rules)
            XCTAssertEqual(try keep(rules, attempt, generation), .mismatch)
            _ = try rules.completeCatchUp(
                lsn: 20, high: nil, full: true, generation: generation, receipt: attempt,
                segment: RecordLogHeldSegment(segmentId: Self.s2, chunks: [])
            )
            XCTAssertEqual(ids(tables), [])
        }
        // The marker: another object, digest, row count or range.
        for variant in [
            Keep(object: "\(Self.s2)/Note/0"), Keep(sha256: "sha-other"), Keep(rows: 3), Keep(firstId: "n0"), Keep(lastId: "n3"),
        ] {
            let (_, rules) = try holdingS1()
            let (attempt, generation) = try receivingS2(rules)
            XCTAssertEqual(try keep(rules, attempt, generation, variant), .mismatch)
        }
        // A store holding no segment.
        let bare = RecordLogMemoryTables(rows: [(RecordLogRecordKey(model: "Note", id: "n1"), ["id": "n1"])], writers: [writer])
        let rules = RecordLogRules(tables: bare, writer: writer)
        let (attempt, generation) = try receivingS2(rules)
        XCTAssertNil(bare.heldSegment())
        XCTAssertEqual(try keep(rules, attempt, generation, Keep(lastId: "n1", rows: 1)), .mismatch)
        // Another attempt in progress (edge 038).
        let (tables, again) = try holdingS1()
        _ = try again.beginReceipt(RecordLogReceipt(kind: .segment, id: Self.s2))
        let (attempt2, generation2) = try receivingS2(again)
        XCTAssertEqual(try keep(again, attempt2, generation2), .mismatch)
        _ = try again.completeCatchUp(
            lsn: 20, high: nil, full: true, generation: generation2, receipt: attempt2,
            segment: RecordLogHeldSegment(segmentId: Self.s2, chunks: [])
        )
        XCTAssertEqual(ids(tables), [])
    }

    func testTheRulesDoNotCountRowsAnInterruptedReplacementPut() throws {
        let (tables, rules) = try holdingS1()
        // Another replacement put n2 again and was interrupted: n2 is not of the confirmed generation.
        let other = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [row("n2", "half-applied")]), generation: other)
        let (attempt, generation) = try receivingS2(rules)
        XCTAssertGreaterThan(generation, other)
        XCTAssertEqual(try keep(rules, attempt, generation), .mismatch)
        // The other chunk's rows are all confirmed: it is kept.
        XCTAssertEqual(
            try keep(rules, attempt, generation, Keep(object: "\(Self.s1)/Note/1", sha256: "sha-b", firstId: "n3", lastId: "n4")),
            .kept(rows: 2, ranges: [RecordLogIdRange(model: "Note", firstId: "n3", lastId: "n4")])
        )
        _ = try rules.completeCatchUp(
            lsn: 20, high: nil, full: true, generation: generation, receipt: attempt,
            segment: RecordLogHeldSegment(segmentId: Self.s2, chunks: [Self.held.chunks[1]])
        )
        XCTAssertEqual(ids(tables), ["n3", "n4"])
    }

    func testTheRulesAreStaleUnderASupersededGenerationAndForAnAttemptNoLongerInProgress() throws {
        let (_, rules) = try holdingS1()
        let (attempt, generation) = try receivingS2(rules)
        let later = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        XCTAssertThrowsError(try keep(rules, attempt, generation)) { XCTAssertTrue($0 is RecordLogStaleReplacementError) }
        _ = try rules.completeCatchUp(lsn: 30, high: nil, full: true, generation: later)
        let again = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        XCTAssertThrowsError(try keep(rules, attempt, again)) { XCTAssertTrue($0 is RecordLogStaleReceiptError) }
    }

    // MARK: - The store, over SQLite

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-keep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func storeHoldingS1() async throws -> (provider: SQLiteStorageProvider, store: RecordLogStore, writer: String) {
        let provider = try await makeProvider()
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a")
        try store.initialize()
        let writer = try store.mintWriter()
        let attempt = try store.beginReceipt(writer: writer, kind: .segment, id: Self.s1).attempt
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applySegmentChunk(writer: writer, generation: generation, attempt: attempt, rows: ["n1", "n2", "n3", "n4"].map { row($0) })
        _ = try store.completeCatchUp(writer: writer, lsn: 10, full: true, generation: generation, receipt: attempt, segment: Self.held)
        return (provider, store, writer)
    }

    private func gens(_ provider: SQLiteStorageProvider) throws -> [String: Int] {
        try provider.withConnection { connection in
            var out: [String: Int] = [:]
            for row in try connection.query("SELECT _id, _gen FROM record_log_rows ORDER BY _id", []) {
                if let id = row["_id"].stringValue { out[id] = row["_gen"].intValue }
            }
            return out
        }
    }

    private func storeKeep(
        _ store: RecordLogStore, _ writer: String, _ attempt: String, _ generation: Int, _ k: Keep = Keep()
    ) throws -> RecordLogChunkReply {
        try store.keepSegmentChunk(
            writer: writer, generation: generation, attempt: attempt, segmentId: Self.s2, object: k.object, sha256: k.sha256,
            model: "Note", firstId: k.firstId, lastId: k.lastId, rows: k.rows
        )
    }

    func testTheMarkerIsWrittenReportedAndAnsweredByTheReplacementsBegin() async throws {
        let (provider, store, writer) = try await storeHoldingS1()
        let stored = try provider.withConnection { try $0.query("SELECT segment FROM record_log_state", []).first?["segment"].stringValue }
        XCTAssertEqual(RecordLogHeldSegment(json: RecordLogJSON.parse(try XCTUnwrap(stored))), Self.held)
        XCTAssertEqual(try store.marks().segment, Self.held)
        let begun = try store.beginSegmentReplacement(writer: writer)
        XCTAssertNotNil(begun.generation)
        XCTAssertEqual(begun.held, Self.held)
    }

    func testTheMarkerIsClearedByAFullPagedReplacementAndByAPurgeAndKeptByARowsCatchUp() async throws {
        do {
            let (_, store, writer) = try await storeHoldingS1()
            _ = try store.applyCatchUpPage(writer: writer, rows: [row("n9")], lsn: 12)
            _ = try store.completeCatchUp(writer: writer, lsn: 12)
            XCTAssertEqual(try store.marks().segment, Self.held)
            let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
            _ = try store.applyCatchUpPage(writer: writer, rows: [row("n1")], lsn: 20, generation: generation)
            _ = try store.completeCatchUp(writer: writer, lsn: 20, full: true, generation: generation)
            XCTAssertNil(try store.marks().segment)
        }
        let (_, store, _) = try await storeHoldingS1()
        XCTAssertTrue(try store.purge(force: true).purged)
        try store.initialize()
        _ = try store.mintWriter()
        XCTAssertNil(try store.marks().segment)
    }

    func testAStoreCreatedBeforeTheSegmentColumnGainsIt() async throws {
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
                  replacing INTEGER,
                  receipt TEXT
                )
                """)
            try connection.execute("INSERT INTO record_log_state (doc_id, cursor) VALUES (?, 9)", [.text("doc-1")])
        }
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a")
        try store.initialize()
        try store.initialize()
        _ = try store.mintWriter()
        let marks = try store.marks()
        XCTAssertEqual(marks.cursor, 9)
        XCTAssertNil(marks.segment)
        let has = try provider.withConnection {
            try $0.query("SELECT COUNT(*) AS n FROM pragma_table_info('record_log_state') WHERE name = 'segment'", []).first?["n"].intValue
        }
        XCTAssertEqual(has, 1)
        XCTAssertTrue(RecordLogSchema.addedColumns.contains { $0.table == "record_log_state" && $0.column == "segment" })
    }

    func testTheStoreKeepsExactlyTheConfirmedRowsOfTheRangeAndTheCompletionKeepsThem() async throws {
        let (provider, store, writer) = try await storeHoldingS1()
        let attempt = try store.beginReceipt(writer: writer, kind: .segment, id: Self.s2).attempt
        let begun = try store.beginSegmentReplacement(writer: writer)
        let generation = try XCTUnwrap(begun.generation)
        XCTAssertEqual(begun.held, Self.held)
        let reply = try storeKeep(store, writer, attempt, generation)
        XCTAssertFalse(reply.mismatch)
        XCTAssertFalse(reply.stale)
        XCTAssertEqual(reply.applied, 2)
        XCTAssertEqual(reply.ranges, [RecordLogIdRange(model: "Note", firstId: "n1", lastId: "n2")])
        XCTAssertEqual(try gens(provider), ["n1": generation, "n2": generation, "n3": generation - 1, "n4": generation - 1])
        _ = try store.completeCatchUp(
            writer: writer, lsn: 20, full: true, generation: generation, receipt: attempt,
            segment: RecordLogHeldSegment(segmentId: Self.s2, chunks: [Self.held.chunks[0]])
        )
        XCTAssertEqual(Array(try gens(provider).keys).sorted(), ["n1", "n2"])
        XCTAssertEqual(try store.read(model: "Note", id: "n1")?["title"], "t-n1")
        XCTAssertNil(try store.read(model: "Note", id: "n3"))
        XCTAssertEqual(try store.marks().segment, RecordLogHeldSegment(segmentId: Self.s2, chunks: [Self.held.chunks[0]]))
    }

    func testTheStoreAnswersMismatchAndChangesNothingWhenTheCountTheMarkerOrAnotherAttemptDiffers() async throws {
        let cases: [(String, (RecordLogStore, String) throws -> Keep)] = [
            ("a row the client has extra", { store, writer in
                _ = try store.applyCatchUpPage(writer: writer, rows: [self.row("n15")], lsn: 12)
                _ = try store.completeCatchUp(writer: writer, lsn: 12)
                return Keep()
            }),
            ("the object differs", { _, _ in Keep(object: "\(Self.s2)/Note/0") }),
            ("the digest differs", { _, _ in Keep(sha256: "sha-z") }),
            ("the rows differ", { _, _ in Keep(rows: 1) }),
            ("the range differs", { _, _ in Keep(lastId: "n3") }),
            ("another attempt is in progress", { store, writer in
                _ = try store.beginReceipt(writer: writer, kind: .load, id: "01JS4394LOADINPROGRESS0001")
                return Keep()
            }),
        ]
        for (name, arrange) in cases {
            let (provider, store, writer) = try await storeHoldingS1()
            let variant = try arrange(store, writer)
            let attempt = try store.beginReceipt(writer: writer, kind: .segment, id: Self.s2).attempt
            let generation = try XCTUnwrap(try store.beginSegmentReplacement(writer: writer).generation)
            let before = try gens(provider)
            let reply = try storeKeep(store, writer, attempt, generation, variant)
            XCTAssertTrue(reply.mismatch, name)
            XCTAssertEqual(reply.applied, 0, name)
            XCTAssertEqual(try gens(provider), before, name)
        }
    }

    func testTheStoreDoesNotCountRowsAnInterruptedReplacementPut() async throws {
        let (provider, store, writer) = try await storeHoldingS1()
        let other = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applySegmentChunk(writer: writer, generation: other, rows: [row("n2", "half-applied")])
        let attempt = try store.beginReceipt(writer: writer, kind: .segment, id: Self.s2).attempt
        let generation = try XCTUnwrap(try store.beginSegmentReplacement(writer: writer).generation)
        XCTAssertGreaterThan(generation, other)
        XCTAssertTrue(try storeKeep(store, writer, attempt, generation).mismatch)
        XCTAssertEqual(try gens(provider)["n2"], other)
    }

    func testTheStoreIsStaleUnderASupersededGenerationAndForAnAttemptNoLongerInProgress() async throws {
        let (_, store, writer) = try await storeHoldingS1()
        let attempt = try store.beginReceipt(writer: writer, kind: .segment, id: Self.s2).attempt
        let generation = try XCTUnwrap(try store.beginSegmentReplacement(writer: writer).generation)
        let later = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        let stale = try storeKeep(store, writer, attempt, generation)
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.applied, 0)
        _ = try store.completeCatchUp(writer: writer, lsn: 30, full: true, generation: later)
        let again = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertTrue(try storeKeep(store, writer, attempt, again).stale)
    }

    // MARK: - The session

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func n(_ id: String, _ title: String? = nil) -> [String: JSONValue] {
        ["id": .string(id), "title": .string(title ?? "t-\(id)")]
    }

    private func segmentOpen(_ pointer: JSONValue, cursor: Int, upTo: Int) -> [String: JSONValue] {
        H.opened(lsn: upTo, catchUp: .object([
            "mode": "segment", "segment": pointer, "count": 1, "cursor": .number(Double(cursor)), "upTo": .number(Double(upTo)),
        ]))
    }

    /// Every confirmed row of the document, by id.
    private func confirmedRows(_ h: H.Fixture) throws -> [String: [String: JSONValue]] {
        try h.provider.withConnection { connection in
            var out: [String: [String: JSONValue]] = [:]
            for row in try connection.query("SELECT _id, _data FROM record_log_rows ORDER BY _id", []) {
                if let id = row["_id"].stringValue { out[id] = RecordLogJSON.row(row["_data"].stringValue) }
            }
            return out
        }
    }

    /// A store that received S1 (Note/0: a, b; Note/1: c, d) through a session, at cursor 12, and S1's objects.
    private func holdingS1Session() async throws -> (h: H.Fixture, objects: H.SegmentObjects) {
        let directory = NSTemporaryDirectory() + "/record-log-keep-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let h = try await H.Fixture(provider: provider, clientId: "client-a", fetches: true, timings: H.timings)
        let objects = H.SegmentObjects()
        let s1 = h.publishSegment(segmentId: Self.s1, lsn: 10, completedLsn: 12, chunks: [
            .rows([n("a"), n("b")]), .rows([n("c"), n("d")]),
        ], corrections: [], objects: objects)
        await h.session.start()
        await h.feed(segmentOpen(s1, cursor: 0, upTo: 12))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(lsn: 12))
        await until("S1 to complete") { h.synced.value == 1 }
        return (h, objects)
    }

    private func again(_ h: H.Fixture, clientId: String = "client-a") async throws -> H.Fixture {
        try await H.Fixture(provider: h.provider, clientId: clientId, fetches: true, timings: H.timings)
    }

    func testASessionKeepsAHeldChunkAndFetchesOnlyTheRewrittenOneAndTheCorrections() async throws {
        let (first, objects) = try await holdingS1Session()
        let heldS1 = try XCTUnwrap(first.marks.segment)
        XCTAssertEqual(heldS1.segmentId, Self.s1)
        XCTAssertEqual(heldS1.chunks.map(\.object), ["\(Self.s1)/Note/0", "\(Self.s1)/Note/1"])
        let h = try await again(first)
        let s2 = h.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: [
            .reuse("\(Self.s1)/Note/0"), .rows([n("c", "c at B2"), n("e")]),
        ], corrections: [("e", ["id": "e", "title": "e after B2", "_type": "Note"])], objects: objects)
        await h.session.start()
        await h.feed(segmentOpen(s2, cursor: 12, upTo: 24))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(rows: [H.row("f", ["title": "t-f"])], lsn: 24))
        await until("S2 to complete") { h.synced.value == 1 }
        let grant = try XCTUnwrap(s2["download"]?["path"]?.stringValue)
        XCTAssertEqual(h.connection.fetched, ["\(grant)/Note/0", "\(grant)/corrections"])
        XCTAssertEqual(try confirmedRows(h), [
            "a": n("a"), "b": n("b"), "c": n("c", "c at B2"), "e": n("e", "e after B2"), "f": n("f"),
        ])
        let marks = h.marks
        XCTAssertEqual(marks.cursor, 24)
        XCTAssertNil(marks.receipt)
        XCTAssertEqual(marks.segment?.segmentId, Self.s2)
        XCTAssertEqual(marks.segment?.chunks.map(\.object), ["\(Self.s1)/Note/0", "\(Self.s2)/Note/0"])
    }

    func testASessionFetchesAHeldChunkWhoseKeepIsAnsweredMismatch() async throws {
        let (first, objects) = try await holdingS1Session()
        // The client lost b after S1: its count no longer matches (edge 036).
        _ = try first.binding.store.applyCatchUpPage(writer: try XCTUnwrap(first.marks.writer), rows: [], gone: [RecordLogRecordKey(model: "Note", id: "b")], lsn: 13)
        _ = try first.binding.store.completeCatchUp(writer: try XCTUnwrap(first.marks.writer), lsn: 13)
        let h = try await again(first)
        let s2 = h.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: [
            .reuse("\(Self.s1)/Note/0"), .rows([n("c", "c at B2"), n("e")]),
        ], corrections: [], objects: objects)
        await h.session.start()
        await h.feed(segmentOpen(s2, cursor: 13, upTo: 22))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(lsn: 22))
        await until("S2 to complete") { h.synced.value == 1 }
        let grant = try XCTUnwrap(s2["download"]?["path"]?.stringValue)
        XCTAssertEqual(h.connection.fetched, ["\(grant)/\(Self.s1)/Note/0", "\(grant)/Note/0", "\(grant)/corrections"])
        XCTAssertEqual(try confirmedRows(h), ["a": n("a"), "b": n("b"), "c": n("c", "c at B2"), "e": n("e")])
    }

    func testASessionFetchesAChunkRewrittenWithIdenticalBytes() async throws {
        let (first, objects) = try await holdingS1Session()
        let h = try await again(first)
        let s2 = h.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: [
            .rows([n("a"), n("b")]), .reuse("\(Self.s1)/Note/1"),
        ], corrections: [], objects: objects)
        XCTAssertEqual(s2["chunks"]?.arrayValue?.first?["sha256"], objects.entry("\(Self.s1)/Note/0")?["sha256"])
        await h.session.start()
        await h.feed(segmentOpen(s2, cursor: 12, upTo: 22))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(lsn: 22))
        await until("S2 to complete") { h.synced.value == 1 }
        let grant = try XCTUnwrap(s2["download"]?["path"]?.stringValue)
        XCTAssertEqual(h.connection.fetched, ["\(grant)/Note/0", "\(grant)/corrections"])
        XCTAssertEqual(try confirmedRows(h), ["a": n("a"), "b": n("b"), "c": n("c"), "d": n("d")])
    }

    func testAnotherSessionsLoadChangingAKeptRangeBetweenTheHeldReadAndTheKeepLeavesTheStoreEqualToTheRoom() async throws {
        let (first, objects) = try await holdingS1Session()
        let other = try await again(first, clientId: "client-b")
        await other.session.start()
        await other.feed(H.opened(lsn: 12))
        await until("the other session to open") { other.synced.value == 1 }

        let h = try await again(first)
        // The room: c patched and d deleted at 21–22, after S2 began (its corrections carry both).
        let s2 = h.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: [
            .rows([n("a", "a at B2"), n("b")]), .reuse("\(Self.s1)/Note/1"),
        ], corrections: [
            ("c", ["id": "c", "title": "c by the load", "_type": "Note"]), ("d", ["_type": "Note", "_deleted": true]),
        ], objects: objects)
        let grant = try XCTUnwrap(s2["download"]?["path"]?.stringValue)
        // The rewritten chunk's fetch waits: the held marker is read, the keep is not yet asked.
        let gate = H.Gate()
        h.connection.intercept { $0 == "\(grant)/Note/0" ? .hold(gate) : .pass }
        await h.session.start()
        await h.feed(segmentOpen(s2, cursor: 12, upTo: 24))
        await until("the rewritten chunk's fetch") { h.connection.fetched.contains("\(grant)/Note/0") }

        let load = other.publishLoad(
            sessionId: Self.load, chunks: [(model: "Note", lines: [("c", ["title": "c by the load"]), ("d", ["_deleted": true])])],
            firstLsn: 21, lastLsn: 22
        )
        await other.feed(H.load("complete", load))
        await until("the load's remainder request") { other.of("record.catchUp").count == 1 }
        await other.feed(H.page(lsn: 22))
        await until("the load to complete") { other.marks.cursor == 22 }

        gate.open()
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(lsn: 24))
        await until("S2 to complete") { h.synced.value == 1 }
        XCTAssertEqual(h.connection.fetched, ["\(grant)/Note/0", "\(grant)/\(Self.s1)/Note/1", "\(grant)/corrections"])
        XCTAssertEqual(try confirmedRows(h), ["a": n("a", "a at B2"), "b": n("b"), "c": n("c", "c by the load")])
        XCTAssertEqual(h.marks.segment?.segmentId, Self.s2)
    }

    func testALaterReplacementMakesTheEarliersKeepsStaleAndTheMarkerNamesTheSegmentThatCompleted() async throws {
        let (first, objects) = try await holdingS1Session()
        let a = try await again(first)
        let b = try await again(first, clientId: "client-c")
        let chunks: [H.PublishedChunk] = [.reuse("\(Self.s1)/Note/0"), .rows([n("c", "c at B2"), n("e")])]
        let s2a = a.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: chunks, corrections: [], objects: objects)
        let s2b = b.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: chunks, corrections: [], objects: objects)
        let grantA = try XCTUnwrap(s2a["download"]?["path"]?.stringValue)
        let grantB = try XCTUnwrap(s2b["download"]?["path"]?.stringValue)
        // a keeps S1's Note/0, then waits at the rewritten chunk's fetch.
        let gate = H.Gate()
        a.connection.intercept { $0 == "\(grantA)/Note/0" ? .hold(gate) : .pass }
        await a.session.start()
        await a.feed(segmentOpen(s2a, cursor: 12, upTo: 22))
        await until("a's rewritten chunk's fetch") { a.connection.fetched.contains("\(grantA)/Note/0") }
        // b's replacement begins after a's (whose attempt is in progress, so b keeps nothing) and completes.
        await b.session.start()
        await b.feed(segmentOpen(s2b, cursor: 12, upTo: 22))
        await until("b's remainder request") { b.of("record.catchUp").count == 1 }
        await b.feed(H.page(lsn: 22))
        await until("b to complete") { b.synced.value == 1 }
        XCTAssertEqual(b.connection.fetched, ["\(grantB)/\(Self.s1)/Note/0", "\(grantB)/Note/0", "\(grantB)/corrections"])

        gate.open()
        await until("a to open again") { a.of("record.open").count == 2 }
        XCTAssertEqual(a.connection.fetched, ["\(grantA)/Note/0"])
        XCTAssertEqual(try confirmedRows(b), ["a": n("a"), "b": n("b"), "c": n("c", "c at B2"), "e": n("e")])
        XCTAssertEqual(b.marks.segment?.segmentId, Self.s2)
    }

    func testAnInterruptedReceiptLeavesItsAttemptInProgressSoTheNextKeepsNothing() async throws {
        let (first, objects) = try await holdingS1Session()
        let h = try await again(first)
        let s2 = h.publishSegment(segmentId: Self.s2, lsn: 20, completedLsn: 22, chunks: [
            .reuse("\(Self.s1)/Note/0"), .rows([n("c", "c at B2"), n("e")]),
        ], corrections: [], objects: objects)
        let grant = try XCTUnwrap(s2["download"]?["path"]?.stringValue)
        // The rewritten chunk fails once, after Note/0 of S1 was kept.
        let failed = LockedBox(false)
        h.connection.intercept { path in
            guard path == "\(grant)/Note/0" else { return .pass }
            return failed.withValue { done in
                if done { return .pass }
                done = true
                return .status(500)
            }
        }
        await h.session.start()
        await h.feed(segmentOpen(s2, cursor: 12, upTo: 22))
        await until("the session to open again") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.connection.fetched, ["\(grant)/Note/0"])
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .segment, id: Self.s2))

        await h.feed(segmentOpen(s2, cursor: 12, upTo: 22))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(lsn: 22))
        await until("S2 to complete") { h.synced.value == 1 }
        XCTAssertEqual(h.connection.fetched, ["\(grant)/Note/0", "\(grant)/\(Self.s1)/Note/0", "\(grant)/Note/0", "\(grant)/corrections"])
        XCTAssertEqual(try confirmedRows(h), ["a": n("a"), "b": n("b"), "c": n("c", "c at B2"), "e": n("e")])
        XCTAssertNil(h.marks.receipt)
        XCTAssertFalse(h.marks.replacing)
    }
}
