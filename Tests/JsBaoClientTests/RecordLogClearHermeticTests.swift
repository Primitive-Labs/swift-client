import XCTest
@testable import JsBaoClient

/// #5994 behaviors 24 and 34 and their edge cases — the Swift device client
/// applies a model clear, the twin of js-bao's
/// `record-log-client-clear-5994` and `db3-store-clear-indexes-5994` suites.
///
/// - The client declares wire version 5, the room's clear version.
/// - A relayed clear item `{l, e, clear: {model, dropped}}` empties its model
///   in log order: a row of the model relayed at a higher number survives,
///   other models' rows stay, the cursor moves to its number and the model's
///   listeners hear it once.
/// - `record.opened`'s `clears` apply before its rows and before the first
///   chunk of a load it points at; a page's `clears` apply once each before
///   its rows. Each clear applies once: the store keeps the highest clear
///   applied, durably, in the transaction that removes the rows, and a clear
///   at or below it or the cursor changes nothing.
/// - After a clear the device's member, text and vector tables hold no entry
///   of a cleared record, and index the model's later records as usual.
final class RecordLogClearHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let load1 = "01JS5994SESS10NL0ADXXXXX01"

    private var directories: [String] = []
    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-clear-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func harness(_ provider: SQLiteStorageProvider? = nil) async throws -> H.Fixture {
        let store: SQLiteStorageProvider
        if let provider { store = provider } else { store = try await makeProvider() }
        return try await H.Fixture(provider: store, clientId: "client-a", fetches: true, timings: H.timings)
    }

    /// A session opened on an empty room, then sent `rows` as results 1, 2, …; synced.
    private func seeded(_ rows: [(model: String, id: String)]) async throws -> H.Fixture {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened())
        XCTAssertEqual(h.synced.value, 1)
        await h.feed(H.results(rows.enumerated().map { Self.result($0.offset + 1, $0.element.id, model: $0.element.model) }))
        XCTAssertEqual(h.marks.cursor, rows.count)
        return h
    }

    /// The same store opened again by a new session (a restarted client): started, not yet answered.
    private func reopened(_ h: H.Fixture) async throws -> H.Fixture {
        let again = try await harness(h.provider)
        await again.session.start()
        return again
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    static func result(_ l: Int, _ id: String, model: String = "Note", e: Int = 1) -> JSONValue {
        .object([
            "l": .number(Double(l)), "e": .number(Double(e)),
            "changes": [.object(["model": .string(model), "id": .string(id), "row": .object(["id": .string(id), "n": .number(Double(l))])])],
        ])
    }

    static func clearItem(_ l: Int, model: String = "Note", e: Int = 2, dropped: Bool = false) -> JSONValue {
        .object(["l": .number(Double(l)), "e": .number(Double(e)), "clear": .object(["model": .string(model), "dropped": .bool(dropped)])])
    }

    static func clears(_ list: [(model: String, l: Int)]) -> JSONValue {
        .array(list.map { .object(["model": .string($0.model), "l": .number(Double($0.l)), "e": 2]) })
    }

    /// The highest clear the store applied for the harness's document, or `nil` before one.
    private func mark(_ provider: SQLiteStorageProvider, _ documentId: String = H.documentId) throws -> Int? {
        try provider.withConnection {
            try $0.query("SELECT cleared_lsn FROM record_log_state WHERE doc_id = ?", [.text(documentId)])
        }.first?["cleared_lsn"].intValue
    }

    private func ids(_ h: H.Fixture, _ candidates: [String], model: String = "Note") throws -> [String] {
        try candidates.filter { try h.read($0, model) != nil }
    }

    // MARK: - The wire version

    func testTheClientDeclaresTheClearWireVersion5() async throws {
        XCTAssertEqual(recordLogWireVersion, 5)
        let h = try await harness()
        await h.session.start()
        XCTAssertEqual(h.of("record.open").first?["wireVersion"], 5)
    }

    func testAClearItemParsesAsAResultCarryingTheClear() {
        guard case .result(let result)? = RecordLogResultItem(json: Self.clearItem(7, dropped: true)) else {
            return XCTFail("a clear item is a result")
        }
        XCTAssertEqual(result.l, 7)
        XCTAssertEqual(result.e, 2)
        XCTAssertNil(result.changes)
        XCTAssertEqual(result.clear, RecordLogClearItem(model: "Note", dropped: true))
    }

    // MARK: - A clear item, live (behaviors 18 and 24)

    func testALiveClearItemAppliesInLogOrderKeepsLaterRowsAndOtherModelsAndMovesTheCursor() async throws {
        let h = try await seeded([("Note", "n1"), ("Other", "o1"), ("Note", "n2")])
        let noted = LockedBox(0)
        h.binding.onModelChanged("Note") { noted.withValue { $0 += 1 } }
        // 5 arrives before the clear at 4: it waits for it, and survives it.
        await h.feed(H.results([Self.result(5, "n5"), Self.clearItem(4)]))
        XCTAssertEqual(try ids(h, ["n1", "n2", "n5"]), ["n5"])
        XCTAssertEqual(try ids(h, ["o1"], model: "Other"), ["o1"])
        XCTAssertEqual(h.marks.cursor, 5)
        XCTAssertEqual(try mark(h.provider), 4)
        XCTAssertEqual(noted.value, 1, "the model's listeners hear the frame once")
    }

    func testAClearAloneMovesTheCursorToItsNumber() async throws {
        let h = try await seeded([("Note", "n1")])
        await h.feed(H.results([Self.clearItem(2)]))
        XCTAssertEqual(h.marks.cursor, 2)
        XCTAssertEqual(try ids(h, ["n1"]), [])
        XCTAssertEqual(try mark(h.provider), 2)
    }

    // MARK: - clears on a catch-up (behaviors 19 and 24)

    func testOpenedsClearsApplyBeforeItsInlineRows() async throws {
        let h = try await seeded([("Note", "n1"), ("Note", "n2"), ("Other", "o1")])
        let again = try await reopened(h)
        await again.feed(H.opened(lsn: 6, catchUp: .object([
            "mode": "inline", "lsn": 6, "upTo": 6, "clears": Self.clears([("Note", 4)]),
            "rows": [H.row("n6", ["title": "after"])], "gone": [],
        ])))
        await until("synced") { again.synced.value == 1 }
        XCTAssertEqual(try ids(again, ["n1", "n2", "n6"]), ["n6"])
        XCTAssertEqual(try ids(again, ["o1"], model: "Other"), ["o1"])
        XCTAssertEqual(again.marks.cursor, 6)
        XCTAssertEqual(try mark(again.provider), 4)
    }

    func testOpenedsClearsApplyBeforeTheFirstChunkOfALoadItPointsAt() async throws {
        let h = try await seeded([("Note", "n1")])
        let again = try await harness(h.provider)
        let pointer = again.publishLoad(
            sessionId: Self.load1, chunks: [("Note", [("l1", ["title": "loaded"]), ("l2", ["title": "loaded too"])])],
            firstLsn: 3, lastLsn: 3, mode: "refresh"
        )
        await again.session.start()
        await again.feed(H.opened(lsn: 3, catchUp: .object([
            "mode": "load", "load": .object(pointer), "count": 0, "cursor": 1, "upTo": 3, "clears": Self.clears([("Note", 2)]),
        ])))
        await until("the remainder request") { again.of("record.catchUp").count == 1 }
        await again.feed(H.page(lsn: 3))
        await until("synced") { again.synced.value == 1 }
        XCTAssertEqual(try ids(again, ["n1", "l1", "l2"]), ["l1", "l2"])
        XCTAssertEqual(again.marks.cursor, 3)
        XCTAssertEqual(try mark(again.provider), 2)
    }

    func testAPagesClearsApplyOnceEachBeforeItsRows() async throws {
        let h = try await seeded([("Note", "n1")])
        let again = try await reopened(h)
        await again.feed(H.opened(lsn: 9, catchUp: .object(["mode": "paged", "cursor": 1, "upTo": 9, "count": 2])))
        await until("the first page request") { again.of("record.catchUp").count == 1 }
        // A page is read at the room's head, so its `lsn` is at or past every clear it carries.
        var first = H.page(rows: [H.row("p1", ["title": "one"])], lsn: 11, next: .object(["model": "Note", "id": "p1"]))
        first["clears"] = Self.clears([("Note", 11)])
        await again.feed(first)
        await until("the second page request") { again.of("record.catchUp").count == 2 }
        // The second page carries the clear again: it is not applied twice, and the first page's row stays.
        var second = H.page(rows: [H.row("p2", ["title": "two"])], lsn: 11)
        second["clears"] = Self.clears([("Note", 11)])
        await again.feed(second)
        await until("synced") { again.synced.value == 1 }
        XCTAssertEqual(try ids(again, ["n1", "p1", "p2"]), ["p1", "p2"])
        XCTAssertEqual(try mark(again.provider), 11)
    }

    // MARK: - Once each (edge cases)

    func testAClearAtOrBelowTheCursorOrTheMarkChangesNothing() async throws {
        let h = try await seeded([("Note", "n1")])
        await h.feed(H.results([Self.clearItem(2)]))
        await h.feed(H.results([Self.result(3, "n3")]))
        let writer = try XCTUnwrap(h.marks.writer)
        // At or below the cursor.
        let below = try h.binding.store.applyClears(writer: writer, clears: [RecordLogClear(model: "Note", l: 3, e: 2)])
        XCTAssertEqual(below.models, [])
        XCTAssertEqual(try ids(h, ["n3"]), ["n3"])
        // Past the cursor, at the mark: the row stays (a resumed download sends the clear again).
        try h.provider.withConnection {
            try $0.execute("UPDATE record_log_state SET cleared_lsn = 7 WHERE doc_id = ?", [.text(H.documentId)])
        }
        let atMark = try h.binding.store.applyClears(writer: writer, clears: [RecordLogClear(model: "Note", l: 7, e: 2)])
        XCTAssertEqual(atMark.models, [])
        XCTAssertEqual(try ids(h, ["n3"]), ["n3"])
        // Past both: applied.
        let past = try h.binding.store.applyClears(writer: writer, clears: [RecordLogClear(model: "Note", l: 8, e: 2)])
        XCTAssertEqual(past.models, ["Note"])
        XCTAssertEqual(try ids(h, ["n3"]), [])
        XCTAssertEqual(try mark(h.provider), 8)
        XCTAssertEqual(h.marks.cursor, 3, "a catch-up's clears move no cursor")
    }

    /// Two stores over one database, as two sessions sharing a device store: `a` at cursor 1 holding Note `a`, and `b`.
    private func sharedStores() async throws -> (a: RecordLogStore, writerA: String, b: RecordLogStore, writerB: String) {
        let provider = try await makeProvider()
        let a = RecordLogStore(host: provider, documentId: H.documentId, clientId: "client-a", logger: nil)
        try a.initialize()
        let writerA = try a.mintWriter()
        try a.beginCatchUp(writer: writerA, full: false)
        _ = try a.applyCatchUpPage(writer: writerA, rows: [Self.catchUpRow("Note", "a")], lsn: 1)
        _ = try a.completeCatchUp(writer: writerA, lsn: 1)
        let b = RecordLogStore(host: provider, documentId: H.documentId, clientId: "client-b", logger: nil)
        try b.initialize()
        return (a, writerA, b, try b.mintWriter())
    }

    static func catchUpRow(_ model: String, _ id: String) -> RecordLogCatchUpRow {
        RecordLogCatchUpRow(model: model, id: id, row: ["id": .string(id), "title": .string(id)])
    }

    private static func items(_ json: [JSONValue]) -> [RecordLogResultItem] { json.compactMap { RecordLogResultItem(json: $0) } }

    func testAResultOlderThanAClearAnotherSessionSharingTheStoreAppliedPutsNoRowBack() async throws {
        let (a, writerA, b, writerB) = try await sharedStores()
        // `b` catches up from 1 and applies the clear at 3 first; `a`, live on
        // the same store, is then handed the create at 2 and the clear at 3;
        // `b` completes at 4.
        try b.beginCatchUp(writer: writerB, full: false)
        _ = try b.applyClears(writer: writerB, clears: [RecordLogClear(model: "Note", l: 3, e: 2)])
        XCTAssertNil(try a.read(model: "Note", id: "a"))
        let both: JSONValue = .object([
            "l": 2, "e": 1,
            "changes": [
                .object(["model": "Note", "id": "x", "row": .object(["id": "x", "title": "x"])]),
                .object(["model": "Other", "id": "y", "row": .object(["id": "y", "title": "y"])]),
            ],
        ])
        _ = try a.receive(writer: writerA, items: Self.items([both, Self.clearItem(3)]))
        _ = try b.applyCatchUpPage(
            writer: writerB, rows: [Self.catchUpRow("Note", "n"), Self.catchUpRow("Other", "y")], lsn: 4
        )
        _ = try b.completeCatchUp(writer: writerB, lsn: 4)
        for store in [a, b] {
            XCTAssertEqual(try store.marks().cursor, 4)
            XCTAssertNil(try store.read(model: "Note", id: "x"), "the clear at 3 removed what 2 wrote")
            XCTAssertNil(try store.read(model: "Note", id: "a"))
            XCTAssertNotNil(try store.read(model: "Note", id: "n"))
            XCTAssertNotNil(try store.read(model: "Other", id: "y"), "another model's row of the same result applies")
        }
        // Records of the model written after the clear apply as usual.
        _ = try a.receive(writer: writerA, items: Self.items([Self.result(5, "x")]))
        XCTAssertNotNil(try b.read(model: "Note", id: "x"))
    }

    func testAnOwnEntryAcknowledgedCompactlyBelowAClearAlreadyAppliedPutsNoRowBack() async throws {
        let (a, writerA, b, writerB) = try await sharedStores()
        _ = try a.commitEntries(writer: writerA, writes: [RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "p", kind: .create, fields: ["title": "mine"]),
        ])])
        try a.flush()
        _ = try b.applyClears(writer: writerB, clears: [RecordLogClear(model: "Note", l: 3, e: 2)])
        _ = try a.receive(writer: writerA, items: Self.items([
            .object(["l": 2, "e": 1, "w": .string(writerA), "seq": 1]), Self.clearItem(3),
        ]))
        XCTAssertEqual(try a.marks().cursor, 3)
        XCTAssertNil(try a.read(model: "Note", id: "p"))
    }

    /// ``sharedStores()`` with `b` having applied the clear at 3 from its
    /// catch-up and a page read past it (`n`, written after the clear).
    private func clearedByB() async throws -> (a: RecordLogStore, writerA: String, b: RecordLogStore, writerB: String) {
        let (a, writerA, b, writerB) = try await sharedStores()
        try b.beginCatchUp(writer: writerB, full: false)
        _ = try b.applyClears(writer: writerB, clears: [RecordLogClear(model: "Note", l: 3, e: 2)])
        XCTAssertNil(try a.read(model: "Note", id: "a"))
        _ = try b.applyCatchUpPage(writer: writerB, rows: [Self.catchUpRow("Note", "n")], lsn: 4)
        return (a, writerA, b, writerB)
    }

    private func assertAfterB(_ stores: [RecordLogStore], cursor: Int = 4, file: StaticString = #filePath, line: UInt = #line) throws {
        for store in stores {
            XCTAssertEqual(try store.marks().cursor, cursor, file: file, line: line)
            XCTAssertNil(try store.read(model: "Note", id: "a"), file: file, line: line)
            XCTAssertNil(try store.read(model: "Note", id: "x"), "a row read below the clear stays gone", file: file, line: line)
            XCTAssertNotNil(try store.read(model: "Note", id: "n"), "a row written after the clear stays", file: file, line: line)
            XCTAssertNotNil(try store.read(model: "Other", id: "y"), "another model's row applies", file: file, line: line)
        }
    }

    func testADelayedInlineAnswerReadBelowAClearAnotherSessionAppliedPutsNoRowBack() async throws {
        let (a, writerA, b, writerB) = try await clearedByB()
        // `a`'s inline answer, read at 2, before the clear: `x` of the cleared
        // model, a gone `n` (an older record of the same id), `y` of another.
        try a.beginCatchUp(writer: writerA, full: false)
        let page = try a.applyCatchUpPage(
            writer: writerA, rows: [Self.catchUpRow("Note", "x"), Self.catchUpRow("Other", "y")],
            gone: [RecordLogRecordKey(model: "Note", id: "n")], lsn: 2
        )
        XCTAssertFalse(page.stale)
        _ = try a.completeCatchUp(writer: writerA, lsn: 2)
        _ = try a.receive(writer: writerA, items: Self.items([Self.clearItem(3)]))
        _ = try b.completeCatchUp(writer: writerB, lsn: 4)
        try assertAfterB([a, b])
    }

    func testADelayedPagedAnswerReadBelowAClearAnotherSessionAppliedPutsNoRowBackAndItsLaterPagesApply() async throws {
        let (a, writerA, b, writerB) = try await clearedByB()
        try a.beginCatchUp(writer: writerA, full: false)
        _ = try a.applyCatchUpPage(writer: writerA, rows: [Self.catchUpRow("Note", "x"), Self.catchUpRow("Other", "y")], lsn: 2)
        // The next page was read past the clear and carries it: applied already.
        _ = try a.applyClears(writer: writerA, clears: [RecordLogClear(model: "Note", l: 3, e: 2)])
        _ = try a.applyCatchUpPage(writer: writerA, rows: [Self.catchUpRow("Note", "w")], lsn: 5)
        _ = try a.completeCatchUp(writer: writerA, lsn: 5)
        try assertAfterB([a, b], cursor: 5)
        XCTAssertNotNil(try b.read(model: "Note", id: "w"))
        XCTAssertTrue(try b.completeCatchUp(writer: writerB, lsn: 4).stale)
        try assertAfterB([a, b], cursor: 5)
    }

    func testALoadsChunksReadBelowAClearAnotherSessionAppliedPutNoRowBack() async throws {
        let (a, writerA, b, writerB) = try await clearedByB()
        let attempt = try a.beginReceipt(writer: writerA, kind: .load, id: "L1").attempt
        // The load's rows are as of its last number, 2.
        let chunk = try a.applyLoadChunk(
            writer: writerA, sessionId: "L1", attempt: attempt, model: "Note",
            lines: [RecordLogLoadLine(id: "x", patch: ["title": "x"]), RecordLogLoadLine(id: "n", patch: ["_deleted": true])],
            readAt: 2
        )
        XCTAssertFalse(chunk.stale)
        _ = try a.applyLoadChunk(
            writer: writerA, sessionId: "L1", attempt: attempt, model: "Other",
            lines: [RecordLogLoadLine(id: "y", patch: ["title": "y"])], readAt: 2
        )
        _ = try a.completeLoad(writer: writerA, sessionId: "L1", attempt: attempt, mode: .refresh, models: ["Note", "Other"])
        _ = try b.completeCatchUp(writer: writerB, lsn: 4)
        try assertAfterB([a, b])
        // A chunk read past the clear applies.
        let later = try a.beginReceipt(writer: writerA, kind: .load, id: "L2").attempt
        _ = try a.applyLoadChunk(
            writer: writerA, sessionId: "L2", attempt: later, model: "Note",
            lines: [RecordLogLoadLine(id: "z", patch: ["title": "z"])], readAt: 5
        )
        XCTAssertNotNil(try b.read(model: "Note", id: "z"))
    }

    func testASegmentsChunksKeptChunksAndCorrectionsReadBelowAClearAnotherSessionAppliedPutNoRowBack() async throws {
        let (a, writerA, b, writerB) = try await clearedByB()
        _ = try b.completeCatchUp(writer: writerB, lsn: 4)
        let attempt = try a.beginReceipt(writer: writerA, kind: .segment, id: "G1").attempt
        let generation = try XCTUnwrap(try a.beginSegmentReplacement(writer: writerA, attempt: attempt).generation)
        // The segment's rows and corrections are as of its C, 2.
        let kept = try a.keepSegmentChunk(
            writer: writerA, generation: generation, attempt: attempt, segmentId: "G1", object: "o", sha256: "s",
            model: "Note", firstId: "a", lastId: "z", rows: 1, readAt: 2
        )
        XCTAssertTrue(kept.mismatch)
        _ = try a.applySegmentChunk(
            writer: writerA, generation: generation, attempt: attempt,
            rows: [Self.catchUpRow("Note", "x"), Self.catchUpRow("Other", "y")], readAt: 2
        )
        _ = try a.applySegmentCorrections(
            writer: writerA, generation: generation, attempt: attempt,
            lines: [RecordLogCorrection(model: "Note", id: "v", row: ["id": "v", "title": "v"]), RecordLogCorrection(model: "Note", id: "n", row: nil)],
            readAt: 2
        )
        // The remainder from C carries the clear (applied already) and `n`, written after it.
        _ = try a.applyClears(writer: writerA, clears: [RecordLogClear(model: "Note", l: 3, e: 2)])
        _ = try a.applyCatchUpPage(
            writer: writerA, rows: [Self.catchUpRow("Note", "n")], lsn: 4, generation: generation, receipt: attempt
        )
        _ = try a.completeCatchUp(writer: writerA, lsn: 4, full: true, generation: generation, receipt: attempt)
        try assertAfterB([a, b])
        XCTAssertNil(try a.read(model: "Note", id: "v"))
    }

    func testTwoClearsApplyOldestFirstAndAModelNamedProtoClearsLikeAnyOther() async throws {
        let h = try await seeded([("__proto__", "a"), ("constructor", "b"), ("Note", "c")])
        let writer = try XCTUnwrap(h.marks.writer)
        let reply = try h.binding.store.applyClears(
            writer: writer, clears: [RecordLogClear(model: "constructor", l: 6, e: 2), RecordLogClear(model: "__proto__", l: 5, e: 2)]
        )
        XCTAssertEqual(reply.models.sorted(), ["__proto__", "constructor"])
        XCTAssertNil(try h.read("a", "__proto__"))
        XCTAssertNil(try h.read("b", "constructor"))
        XCTAssertNotNil(try h.read("c"))
        XCTAssertEqual(try mark(h.provider), 6)
    }

    func testTheMarkIsDurableAndAStoreAtVersion10GainsItEmpty() async throws {
        XCTAssertGreaterThanOrEqual(RecordLogSchema.storageVersion, 11)
        let h = try await seeded([("Note", "n1")])
        await h.feed(H.results([Self.clearItem(2)]))
        let again = try await harness(h.provider)
        XCTAssertEqual(try mark(again.provider), 2)
        // A store of version 10 has no mark: the open adds it, empty, and the next clear writes it.
        try h.provider.withConnection { connection in
            try connection.execute("ALTER TABLE record_log_state DROP COLUMN cleared_lsn")
            try connection.execute("ALTER TABLE record_log_state DROP COLUMN cleared_models")
            try connection.execute("UPDATE record_log_meta SET value = '10' WHERE key = 'storage_version'")
        }
        let store = RecordLogStore(host: h.provider, documentId: H.documentId, clientId: "client-a", logger: nil)
        try store.initialize()
        XCTAssertNil(try mark(h.provider))
        let writer = try XCTUnwrap(try store.writer())
        _ = try store.applyClears(writer: writer, clears: [RecordLogClear(model: "Note", l: 5, e: 2)])
        XCTAssertEqual(try mark(h.provider), 5)
    }

    // MARK: - The device's indexes (behaviors 24 and 36)

    func testAClearLeavesTheMemberTextAndVectorTablesCleanAndTheyIndexLaterRecords() async throws {
        let world = try await Db3DeviceIndexWorld.make("clear")
        worlds.append(world)
        let encoding = Db3VectorFixture.f32
        let store = try world.store("db3-a")
        try store.syncIndexes([
            Db3TextIndexFixture.textEntry(["title"]),
            RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, kind: .members, on: .device),
            Db3VectorTestSupport.vectorEntry("Note", "embedding", encoding),
        ])
        let vectors = try Db3VectorFixture.notes(6, encoding)
        func noteRow(_ i: Int, _ word: String) -> JSONValue {
            var row = vectors[i].row.objectValue ?? [:]
            row["id"] = .string("note-\(word)-\(i)")
            row["title"] = .string("\(word) river")
            row["tags"] = [.string(word)]
            return .object(row)
        }
        try world.seed("db3-a", "Note", (0..<3).map { noteRow($0, "old") })
        try world.seed("db3-a", "Other", [["id": "o1", "title": "old river"]])
        XCTAssertEqual(try world.drift(), [])
        let cursor = try store.marks().cursor
        _ = try store.receive(writer: world.writer("db3-a"), items: [
            .result(RecordLogResult(l: cursor + 1, e: 2, changes: nil, clear: RecordLogClearItem(model: "Note", dropped: false))),
        ])
        XCTAssertEqual(try world.drift(), [], "no member, text or vector entry of a cleared record remains")
        XCTAssertEqual(try store.countView("Note", [:]), 0)
        XCTAssertEqual(try store.countView("Note", ["tags": ["$contains": "old"]]), 0)
        XCTAssertEqual(try store.countView("Other", [:]), 1)
        try world.seed("db3-a", "Note", (3..<5).map { noteRow($0, "new") })
        XCTAssertEqual(try world.drift(), [], "the model's later records are indexed as usual")
        XCTAssertEqual(try store.countView("Note", ["tags": ["$contains": "new"]]), 2)
        XCTAssertEqual(try store.countView("Note", ["tags": ["$contains": "old"]]), 0)
    }
}

/// #5994 behaviors 22 and 34 — Swift's `client.db3.clearModel` answers the
/// server's clear and, on a db3 this device has open, waits for the device
/// to apply it; past 10 s without it, it throws `clearApplyPending` with the
/// server's answer. Nothing is waited for when the clear wrote nothing or the
/// db3 is not open here.
final class Db3ClearModelHermeticTests: XCTestCase {

    #if PRIMITIVE_EXPERIMENTAL_APIS
    private static let answer = #"{"ok": true, "model": "Note", "rows": 3, "lsn": 41, "epoch": 7, "dropped": false, "cost": {"rowsRead": 1, "rowsWritten": 2}}"#

    private func api(_ body: String = answer) -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(responder: { _ in
            TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        })
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    /// A clock that moves only when the wait sleeps.
    private final class Clock: Db3ClearWaitClock, @unchecked Sendable {
        private let lock = NSLock()
        private var ms: Int64 = 1_000
        private(set) var slept = 0
        func now() -> Int64 { lock.withLock { ms } }
        func sleep(ms: Int) async { lock.withLock { self.ms += Int64(ms); slept += 1 } }
    }

    func testItPostsTheClearAndAnswersTheServersResultWithoutWaitingWhenTheDb3IsNotOpenHere() async throws {
        let (db3, transport) = api()
        let result = try await db3.clearModel("db3-1", model: "Note", drop: true)
        XCTAssertEqual(result, Db3ClearResult(model: "Note", rows: 3, lsn: 41, epoch: 7, dropped: false, cost: Db3Cost(rowsRead: 1, rowsWritten: 2)))
        XCTAssertEqual(transport.calls.map(\.path), ["/db3/db3-1/records/Note/clear"])
        XCTAssertEqual(transport.calls.first?.method, .post)
        XCTAssertEqual(transport.calls.first?.jsonBody, ["drop": true])
    }

    func testTheWaitResolvesOnceTheCursorReachesTheClear() async throws {
        let result = Db3ClearResult(model: "Note", rows: 3, lsn: 41, epoch: 7, dropped: false, cost: nil)
        let clock = Clock()
        let reads = LockedBox(0)
        try await db3AwaitClearApplied(result, db3Id: "db3-1", cursor: {
            reads.withValue { $0 += 1 }
            return reads.value >= 3 ? 41 : 40
        }, clock: clock)
        XCTAssertEqual(reads.value, 3)
    }

    func testAStalledApplyThrowsClearApplyPendingWithTheServersAnswerAfter10Seconds() async throws {
        let result = Db3ClearResult(model: "Note", rows: 3, lsn: 41, epoch: 7, dropped: false, cost: nil)
        let clock = Clock()
        do {
            try await db3AwaitClearApplied(result, db3Id: "db3-1", cursor: { 40 }, clock: clock)
            XCTFail("a stalled apply never resolves")
        } catch Db3ClearError.clearApplyPending(let answer) {
            XCTAssertEqual(answer, result)
            XCTAssertGreaterThanOrEqual(clock.now() - 1_000, Int64(db3ClearApplyWaitMs))
        }
        XCTAssertEqual(db3ClearApplyWaitMs, 10_000)
    }

    func testNothingIsWaitedForWhenTheClearWroteNothingOrNoCursorIsHeld() async throws {
        let clock = Clock()
        let none = Db3ClearResult(model: "Note", rows: 0, lsn: nil, epoch: nil, dropped: false, cost: nil)
        try await db3AwaitClearApplied(none, db3Id: "db3-1", cursor: { 0 }, clock: clock)
        let written = Db3ClearResult(model: "Note", rows: 1, lsn: 9, epoch: 2, dropped: false, cost: nil)
        try await db3AwaitClearApplied(written, db3Id: "db3-1", cursor: nil, clock: clock)
        XCTAssertEqual(clock.slept, 0)
    }
    #endif
}
