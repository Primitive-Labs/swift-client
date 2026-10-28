import XCTest
@testable import JsBaoClient

/// A format-3 session receiving loads and segments, driven by scripted room
/// frames over a real store, its connection serving the room's artifacts from
/// memory: the Swift twin of js-bao's `record-log-client-session-load-4311` and
/// `-edges-4311` suites. The live suites are the evidence of the wire; this
/// pins the session's transitions.
///
/// - `record.open` declares `accepts: ["load", "segment", "building"]` when the connection
///   fetches artifacts, none when it cannot, and `[]` after two failed receipts
///   in a row; a completed receipt or full replacement resets the count.
/// - A load received live holds results, fetches the manifest and the chunks
///   through the connection, pages its remainder with `record.catchUp {load}`
///   from the cursor, completes as the receipt, replays the held results and
///   sends a save made meanwhile; a load at open does the same from the
///   catch-up's cursor; a segment replaces the table and pages from `C`.
/// - `record.load started` suppresses the gap re-open; `aborted` and `failed`
///   open again. Failures open again from the cursor and count; abandons do
///   not; a session another client's replacement overtook waits for it.
/// - The marker walks the whole table when the room answers rows.
final class RecordLogReceiptSessionHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let session1 = "01JS4312SESS10NL0ADXXXXX01"
    private static let session2 = "01JS4312SESS10NL0ADXXXXX02"

    private var directories: [String] = []
    private var lines = H.Lines()

    override func setUp() {
        super.setUp()
        let lines = H.Lines()
        self.lines = lines
        Logger.lineForTest = { level, _, message in
            if message.contains(H.documentId) || message.contains("record.load") { lines.append(level, message) }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-receipt-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func harness(
        provider: SQLiteStorageProvider? = nil, clientId: String = "client-a", fetches: Bool = true,
        timings: RecordLogSessionTimings = H.timings
    ) async throws -> H.Fixture {
        let store: SQLiteStorageProvider
        if let provider { store = provider } else { store = try await makeProvider() }
        return try await H.Fixture(provider: store, clientId: clientId, fetches: fetches, timings: timings)
    }

    /// Open the session on an empty room; synced.
    private func openedHarness(timings: RecordLogSessionTimings = H.timings) async throws -> H.Fixture {
        let h = try await harness(timings: timings)
        await h.session.start()
        await h.feed(H.opened())
        XCTAssertEqual(h.synced.value, 1)
        return h
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

    private func pause(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

    private func loadForm(_ pointer: [String: JSONValue], cursor: Int, upTo: Int) -> JSONValue {
        .object(["mode": "load", "load": .object(pointer), "count": 0, "cursor": .number(Double(cursor)), "upTo": .number(Double(upTo))])
    }

    // MARK: - accepts (behavior 10)

    func testTheOpenDeclaresLoadAndSegmentWhenTheConnectionFetchesAndNothingWhenItCannot() async throws {
        let able = try await harness()
        await able.session.start()
        XCTAssertEqual(able.of("record.open").first?["accepts"], ["load", "segment", "building"])
        XCTAssertEqual(able.of("record.open").first?["formats"], [3])
        let unable = try await harness(fetches: false)
        await unable.session.start()
        XCTAssertNotNil(unable.of("record.open").first)
        XCTAssertNil(unable.of("record.open").first?["accepts"])
    }

    // MARK: - A load received live (behaviors 11, 14, 31; edges 006, 013)

    func testALoadReceivedLiveHoldsResultsReceivesItsChunksAndRemainderAndSendsASaveMadeMeanwhile() async throws {
        let h = try await openedHarness()
        await h.feed(H.results([H.result(1, "old", ["title": "a"])]))
        XCTAssertEqual(h.marks.cursor, 1)
        await h.feed(H.started(Self.session1))
        XCTAssertTrue(lines.contains("[record-log] \(H.documentId): load \(Self.session1) is applying; results wait behind it"))
        // Results past the load's numbers (2..4) arrive while it applies: held, and no gap re-open.
        await h.feed(H.results([H.result(5, "w1", ["title": "during"], e: 5)]))
        await pause(300)
        XCTAssertEqual(h.of("record.open").count, 1)
        XCTAssertEqual(h.marks.cursor, 1)

        let pointer = h.publishLoad(
            sessionId: Self.session1,
            chunks: [
                ("Note", [("n1", ["title": "one"]), ("n2", ["title": "two"])]),
                ("Note", [("n3", ["title": "three"]), ("taken", ["slug": "dup"])]),
            ],
            firstLsn: 2, lastLsn: 4, k: 1, refusedRows: 1
        )
        // The second chunk waits until a save has been made after the first chunk's progress.
        let gate = H.Gate()
        h.connection.intercept { path in path.hasSuffix("/Note/1.ATTEMPT1") ? .hold(gate) : .pass }
        await h.feed(H.load("complete", pointer))
        await until("the first chunk") { h.secondChunkHeld() }
        XCTAssertEqual(try h.read("n1"), ["id": "n1", "title": "one"], "the first chunk is applied")
        let seq = try h.save("mine", ["title": "saved during"])
        let confirmed = Task { try await h.binding.whenAcknowledged(seq) }
        gate.open()
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        let request = h.of("record.catchUp")[0]
        XCTAssertEqual(request["cursor"], 1)
        XCTAssertEqual(request["upTo"], 4)
        XCTAssertEqual(request["load"]?.stringValue, Self.session1)
        let base = pointer["download"]?["path"]?.stringValue ?? ""
        XCTAssertEqual(h.connection.fetched, [base, "\(base)/Note/0.ATTEMPT0", "\(base)/Note/1.ATTEMPT1"])
        XCTAssertEqual(h.of("record.entries").count, 0, "a save made during the receipt waits for it (edge 013)")
        // A result arriving during the remainder is held too.
        await h.feed(H.results([H.result(6, "w2", ["title": "later"], e: 5)]))
        // The remainder: the refused key is gone, read at the room's 5 (edge 006: 5 is dropped, 6 replays).
        await h.feed(H.page(rows: [H.row("w1", ["title": "during"])], gone: [H.gone("taken")], lsn: 5))
        await until("the save is sent") { h.of("record.entries").count == 1 }
        XCTAssertEqual(h.marks.cursor, 6)
        XCTAssertNil(h.marks.receipt)
        for id in ["n1", "n2", "n3", "w1", "w2", "old"] { XCTAssertNotNil(try h.read(id), id) }
        XCTAssertNil(try h.read("taken"))
        XCTAssertEqual(h.of("record.entries")[0]["entries"]?.arrayValue?.compactMap { $0["seq"]?.wholeNumber }, [seq])
        await h.feed(H.results([H.result(7, "mine", ["title": "saved during"], e: 5, w: h.binding.writer, seq: seq)]))
        try await confirmed.value
        XCTAssertGreaterThanOrEqual(h.progress.value, 3, "a chunk, a chunk and a page")
        XCTAssertTrue(lines.contains(
            "[record-log] load receipt \(H.documentId): \(Self.session1) 4 rows in 2 chunks (live), from cursor 1"
        ))
        XCTAssertTrue(lines.contains("[record-log] load received \(H.documentId): \(Self.session1) 4 rows in 2 chunks, remainder 2 rows,"))
        // The gap watch is back once the load is over: a result past a missing one opens again in time.
        await h.feed(H.results([H.result(9, "z", e: 5)]))
        await until("the gap re-open") { h.of("record.open").count == 2 }
    }

    func testACompleteFrameBehindTheCursorAndOneOfALoadThatWroteNoRowAreDropped() async throws {
        let h = try await openedHarness()
        await h.feed(H.results([H.result(1, "a")]))
        await h.feed(H.started(Self.session1))
        await h.feed(H.load("complete", h.publishLoad(
            sessionId: Self.session1, chunks: [("Note", [("a", [:])])], firstLsn: 1, lastLsn: 1
        )))
        await h.feed(H.load("complete", h.publishLoad(
            sessionId: Self.session2, chunks: [("Note", [("b", [:])])], firstLsn: nil, lastLsn: nil
        )))
        await pause(50)
        XCTAssertEqual(h.connection.fetched, [])
        XCTAssertEqual(h.of("record.catchUp").count, 0)
        // The gap watch is armed again: the load the session heard of is over.
        await h.feed(H.results([H.result(3, "c")]))
        await until("the gap re-open") { h.of("record.open").count == 2 }
    }

    func testACompleteFrameMidCatchUpIsQueuedAndReceivedAfterOnlyWhileTheCursorIsBelowIt() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened(lsn: 9, catchUp: .object(["mode": "paged", "count": 600, "cursor": 0, "upTo": 9])))
        let covered = h.publishLoad(sessionId: Self.session1, chunks: [("Note", [("a", ["t": 1])])], firstLsn: 2, lastLsn: 5)
        let beyond = h.publishLoad(sessionId: Self.session2, chunks: [("Note", [("b", ["t": 2])])], firstLsn: 11, lastLsn: 12, k: 10)
        await h.feed(H.load("complete", covered))
        await h.feed(H.load("complete", beyond))
        await h.feed(H.load("complete", beyond))  // a duplicate (edge 002)
        XCTAssertTrue(lines.contains("[record-log] \(H.documentId): load \(Self.session2) is already being received; duplicate dropped"))
        XCTAssertEqual(h.connection.fetched, [])
        await h.feed(H.page(rows: [H.row("a", ["t": 1])], lsn: 10))
        await until("the second load's remainder") { h.of("record.catchUp").count == 2 }
        // The covered load was dropped; the one past the cursor is received, once.
        XCTAssertEqual(h.connection.fetched.filter { !$0.contains("/Note/") }, [beyond["download"]?["path"]?.stringValue ?? ""])
        XCTAssertEqual(h.of("record.catchUp")[1]["cursor"], 10)
        XCTAssertEqual(h.of("record.catchUp")[1]["load"]?.stringValue, Self.session2)
        await h.feed(H.page(lsn: 12))
        await until("the cursor at 12") { h.marks.cursor == 12 }
        XCTAssertEqual(try h.read("b"), ["id": "b", "t": 2])
        await pause(20)
        XCTAssertEqual(h.of("record.catchUp").count, 2)
    }

    func testTwoLoadsCompletingBackToBackAreReceivedInOrderTheSecondFromTheCursorTheFirstLeft() async throws {
        let h = try await openedHarness()
        let first = h.publishLoad(sessionId: "S-first", chunks: [("Note", [("a", ["t": 1]), ("b", ["t": 1])])], firstLsn: 1, lastLsn: 2)
        let second = h.publishLoad(sessionId: "S-second", chunks: [("Note", [("c", ["t": 2]), ("d", ["t": 2])])], firstLsn: 3, lastLsn: 4, k: 2)
        await h.feed(H.load("complete", first))
        await h.feed(H.load("complete", second))
        await until("the first remainder") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 0)
        XCTAssertEqual(h.of("record.catchUp")[0]["load"], "S-first")
        await h.feed(H.page(lsn: 2))
        await until("the second remainder") { h.of("record.catchUp").count == 2 }
        XCTAssertEqual(h.of("record.catchUp")[1]["cursor"], 2)
        XCTAssertEqual(h.of("record.catchUp")[1]["load"], "S-second")
        await h.feed(H.page(lsn: 4))
        await until("the cursor at 4") { h.marks.cursor == 4 }
        for id in ["a", "b", "c", "d"] { XCTAssertNotNil(try h.read(id), id) }
        XCTAssertTrue(lines.contains("[record-log] load receipt \(H.documentId): S-first 2 rows in 1 chunks (live), from cursor 0"))
        XCTAssertTrue(lines.contains("[record-log] load receipt \(H.documentId): S-second 2 rows in 1 chunks (live), from cursor 2"))
    }

    // MARK: - A load received at open (behavior 12)

    func testALoadAtOpenTakesItsChunksAndItsRemainderFromTheCatchUpsCursorAndSeesTheHighEpoch() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(
            sessionId: Self.session1, chunks: [("Note", [("n1", ["title": "one"]), ("n2", ["title": "two"])])],
            firstLsn: 1, lastLsn: 3
        )
        await h.session.start()
        await h.feed(H.opened(lsn: 4, current: 6, high: 6, catchUp: loadForm(pointer, cursor: 0, upTo: 4)))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 0)
        XCTAssertEqual(h.of("record.catchUp")[0]["upTo"], 4)
        XCTAssertEqual(h.of("record.catchUp")[0]["load"]?.stringValue, Self.session1)
        await h.feed(H.page(rows: [H.row("w", ["title": "after"])], lsn: 4))
        await until("synced") { h.synced.value == 1 }
        let marks = h.marks
        XCTAssertEqual(marks.cursor, 4)
        XCTAssertNil(marks.receipt)
        XCTAssertEqual(marks.open, 6)
        XCTAssertEqual(try h.read("n2"), ["id": "n2", "title": "two"])
        XCTAssertTrue(lines.contains(
            "[record-log] load receipt \(H.documentId): \(Self.session1) 2 rows in 1 chunks (on reconnect), from cursor 0"
        ))
    }

    func testALoadAtOpenThatWroteNoRowPagesItsRemainderOnly() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(sessionId: Self.session1, chunks: [], firstLsn: nil, lastLsn: nil)
        await h.session.start()
        await h.feed(H.opened(lsn: 3, catchUp: loadForm(pointer, cursor: 0, upTo: 3)))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, [])
        await h.feed(H.page(rows: [H.row("r", ["title": "row"])], lsn: 3))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(h.marks.cursor, 3)
        XCTAssertEqual(try h.read("r"), ["id": "r", "title": "row"])
    }

    // MARK: - record.load started (behavior 14; edges 004, 009)

    func testStartedSuppressesTheGapReopenARepeatIsIgnoredAndCompleteAbortedOrFailedClearIt() async throws {
        let h = try await openedHarness()
        await h.feed(H.started(Self.session1))
        await h.feed(H.started(Self.session1))
        XCTAssertEqual(lines.messages().filter { $0.contains("is applying; results wait behind it") }.count, 1, "a repeat is ignored")
        await h.feed(H.results([H.result(5, "w", e: 5)]))
        await pause(300)
        XCTAssertEqual(h.of("record.open").count, 1, "no gap re-open while the load applies, past the result-gap wait")
        // An unknown phase is ignored (edge 004).
        await h.feed(H.load("paused", ["sessionId": .string(Self.session1)]))
        XCTAssertTrue(lines.contains("[record-log] \(H.documentId): ignored record.load paused", level: .debug))
        await h.feed(H.load("failed", ["sessionId": .string(Self.session1), "epoch": 4, "k": 0]))
        await until("the reopen") { h.of("record.open").count == 2 }
        await h.feed(H.opened(lsn: 5, catchUp: .object(["mode": "inline", "rows": [], "gone": [], "lsn": 5, "upTo": 5])))
        await until("synced again") { h.synced.value == 2 }
        // The load is over: the gap watch is back.
        await h.feed(H.results([H.result(7, "x")]))
        await until("the gap re-open") { h.of("record.open").count == 3 }
    }

    func testAStartedFrameForTheLoadBeingReceivedDoesNothing() async throws {
        let h = try await openedHarness()
        let pointer = h.publishLoad(sessionId: Self.session1, chunks: [("Note", [("a", [:])])], firstLsn: 1, lastLsn: 1)
        let gate = H.Gate()
        h.connection.intercept { _ in .hold(gate) }
        await h.feed(H.load("complete", pointer))
        await h.feed(H.started(Self.session1))
        XCTAssertTrue(lines.contains("[record-log] \(H.documentId): load \(Self.session1) is being received; started ignored", level: .debug))
        XCTAssertFalse(lines.contains("[record-log] \(H.documentId): load \(Self.session1) is applying"))
        gate.open()
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
    }

    // MARK: - aborted and failed (behavior 15)

    func testAnAbortedOrFailedLoadMidCatchUpReopensAfterItAndDropsItsQueuedPointer() async throws {
        for stage in ["aborted", "failed"] {
            let h = try await harness()
            await h.session.start()
            await h.feed(H.opened(lsn: 9, catchUp: .object(["mode": "paged", "count": 600, "cursor": 0, "upTo": 9])))
            await h.feed(H.load("complete", h.publishLoad(
                sessionId: Self.session1, chunks: [("Note", [("a", [:])])], firstLsn: 11, lastLsn: 12
            )))
            await h.feed(H.load(stage, ["sessionId": .string(Self.session1), "epoch": 4, "k": 9, "firstLsn": 11, "lastLsn": 12]))
            await h.feed(H.page(lsn: 10))
            await until("the reopen after \(stage)") { h.of("record.open").count == 2 }
            XCTAssertEqual(h.of("record.open")[1]["cursor"], 10)
            await h.feed(H.opened(lsn: 12, catchUp: .object(["mode": "inline", "rows": [H.row("a")], "gone": [], "lsn": 12, "upTo": 12])))
            await pause(20)
            XCTAssertEqual(h.connection.fetched, [], stage)
            XCTAssertEqual(h.marks.cursor, 12)
        }
    }

    func testAnOpenSessionReopensAtOnceOnAnAbortedFrame() async throws {
        let h = try await openedHarness()
        await h.feed(H.started(Self.session1))
        await h.feed(H.load("aborted", ["sessionId": .string(Self.session1), "epoch": 4, "k": 0, "firstLsn": 1, "lastLsn": 5]))
        XCTAssertEqual(h.of("record.open").count, 2)
        XCTAssertTrue(lines.contains("[record-log] \(H.documentId): load \(Self.session1) aborted; opening again from the cursor"))
    }

    // MARK: - A segment at open (behavior 13)

    func testASegmentReplacesTheTableWithItsChunksAndCorrectionsCompletesAtTheLastPageAndKeepsAnOwnGuess() async throws {
        let h = try await harness()
        _ = try h.binding.store.applyCatchUpPage(
            writer: h.binding.writer, rows: [RecordLogCatchUpRow(model: "Note", id: "x", row: ["id": "x", "title": "only here"])]
        )
        try h.save("mine", ["title": "pending"])
        let segment = h.publishSegment(
            segmentId: "G1", lsn: 10, completedLsn: 14,
            rows: [["id": "a", "title": "at B"], ["id": "b", "title": "at B"]],
            corrections: [("a", ["id": "a", "title": "after B", "_type": "Note"]), ("b", ["_type": "Note", "_deleted": true])]
        )
        await h.session.start()
        await h.feed(H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16])))
        await until("the pages from C") { h.of("record.catchUp").count == 1 }
        let request = h.of("record.catchUp")[0]
        XCTAssertEqual(request["cursor"], 14)
        XCTAssertEqual(request["upTo"], 16)
        XCTAssertNil(request["load"])
        XCTAssertNil(request["full"])
        // The pages from C complete the replacement: until they do, the marker stays.
        let during = h.marks
        XCTAssertEqual(during.cursor, 0)
        XCTAssertEqual(during.receipt, RecordLogReceipt(kind: .segment, id: "G1"))
        XCTAssertTrue(during.replacing)
        XCTAssertEqual(try h.read("mine"), ["id": "mine", "title": "pending"], "the own guess holds through the receipt")
        await h.feed(H.page(rows: [H.row("c", ["title": "after C"])], lsn: 16))
        await until("synced") { h.synced.value == 1 }
        let marks = h.marks
        XCTAssertEqual(marks.cursor, 16)
        XCTAssertNil(marks.receipt)
        XCTAssertFalse(marks.replacing)
        XCTAssertEqual(try h.read("a"), ["id": "a", "title": "after B"])
        XCTAssertNil(try h.read("b"))
        XCTAssertNil(try h.read("x"))
        XCTAssertEqual(try h.read("c"), ["id": "c", "title": "after C"])
        XCTAssertEqual(try h.read("mine"), ["id": "mine", "title": "pending"])
        await until("the own entry is resubmitted") { h.of("record.entries").count == 1 }
        XCTAssertEqual(h.of("record.entries")[0]["entries"]?.arrayValue?.compactMap { $0["m"]?["id"]?.stringValue }, ["mine"])
        XCTAssertTrue(lines.contains("[record-log] segment receipt \(H.documentId): G1 2 rows in 1 chunks at 10, corrections to 14"))
        XCTAssertTrue(lines.contains("[record-log] segment received \(H.documentId): G1 2 rows in 1 chunks, remainder 1 rows,"))
    }

    func testASegmentPointerWithNoGrantFailsBeforeAnyStoreChange() async throws {
        let h = try await harness()
        var segment = h.publishSegment(segmentId: "G1", lsn: 10, completedLsn: 14, rows: [["id": "a"]], corrections: [])
        if case .object(var object) = segment {
            object["download"] = .null
            segment = .object(object)
        }
        await h.session.start()
        await h.feed(H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16])))
        await until("the reopen") { h.of("record.open").count == 2 }
        let marks = h.marks
        XCTAssertNil(marks.receipt)
        XCTAssertFalse(marks.replacing)
        XCTAssertTrue(lines.contains("[record-log] segment receipt failed \(H.documentId): G1 the pointer carries no grant", level: .warn))
    }

    // MARK: - Failures, the fallback and the walk (behaviors 10, 16, 18; edge 011)

    func testEachFailureOpensAgainAndAfterTwoTheOpenDeclaresRowsOnlyAndTheMarkerWalksTheTable() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(
            sessionId: Self.session1, chunks: [("Note", [("n1", ["t": 1])]), ("Note", [("n2", ["t": 2])])], firstLsn: 1, lastLsn: 2
        )
        await h.session.start()
        // First failure: the second chunk is gone (404) after the first committed.
        h.connection.intercept { $0.hasSuffix("/Note/1.ATTEMPT1") ? .status(404) : .pass }
        await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
        await until("the first reopen") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.of("record.open")[1]["cursor"], 0)
        XCTAssertEqual(h.of("record.open").dropFirst().first?["accepts"], ["load", "segment", "building"])
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.session1))
        XCTAssertTrue(lines.contains("[record-log] load receipt failed \(H.documentId): \(Self.session1) fetching ", level: .warn))
        XCTAssertFalse(lines.messages().contains { $0.contains("grant1/Note") && $0.contains("receipt failed") && $0.contains("/doc-artifact/grant1") },
                       "a log line shows the grant path as /doc-artifact/…")
        XCTAssertTrue(lines.messages().contains { $0.contains("/doc-artifact/…/Note/1.ATTEMPT1") })
        // Second failure: the grant expired (403) at the manifest.
        h.connection.intercept { _ in .status(403) }
        await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
        await until("the second reopen") { h.of("record.open").count == 3 }
        XCTAssertEqual(h.of("record.open")[2]["cursor"], 0)
        XCTAssertEqual(h.of("record.open")[2]["accepts"], [])
        // The room answers rows: with the marker set they are not applied; the whole table is walked.
        h.connection.intercept(nil)
        await h.feed(H.opened(lsn: 2, catchUp: .object(["mode": "inline", "rows": [H.row("n2", ["t": 2])], "gone": [], "lsn": 2, "upTo": 2])))
        await until("the walk") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.of("record.catchUp")[0]["full"], true)
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 0)
        XCTAssertEqual(h.of("record.catchUp")[0]["upTo"], 2)
        XCTAssertTrue(lines.contains(
            "[record-log] \(H.documentId): the load receipt \(Self.session1) did not complete; walking the room's whole table (to 2)"
        ))
        XCTAssertNil(try h.read("n2"))
        // The room has n2 only: the refused n1 a committed chunk put is dropped.
        await h.feed(H.page(rows: [H.row("n2", ["t": 2])], lsn: 2))
        await until("synced") { h.synced.value == 1 }
        XCTAssertNil(try h.read("n1"))
        XCTAssertEqual(try h.read("n2"), ["id": "n2", "t": 2])
        let marks = h.marks
        XCTAssertEqual(marks.cursor, 2)
        XCTAssertNil(marks.receipt)
        XCTAssertFalse(marks.replacing)
        // The count was reset: the next open declares accepts again.
        await h.session.disconnected()
        await h.session.start()
        XCTAssertEqual(h.of("record.open")[3]["accepts"], ["load", "segment", "building"])
    }

    func testEveryReceiptFailureOpensAgainFromTheUnchangedCursorWithAWarnLine() async throws {
        typealias Setup = (H.Fixture, inout [String: JSONValue]) -> Void
        func corrupt(_ h: H.Fixture, _ pointer: inout [String: JSONValue], manifest: JSONValue) {
            h.connection.put(pointer["download"]?["path"]?.stringValue ?? "", Data(RecordLogJSON.text(manifest).utf8))
        }
        let cases: [(String, String, Setup)] = [
            ("no grant", "the pointer carries no grant", { _, pointer in pointer["download"] = .null }),
            ("a manifest that is not JSON", "the manifest is not JSON", { h, pointer in
                h.connection.put(pointer["download"]?["path"]?.stringValue ?? "", Data("{not json".utf8))
            }),
            ("not a load's manifest", "the manifest is not a load's", { h, pointer in
                corrupt(h, &pointer, manifest: ["kind": "snapshot", "sessionId": .string(Self.session1), "chunks": []])
            }),
            ("another session's manifest", "the manifest is session other's", { h, pointer in
                corrupt(h, &pointer, manifest: ["kind": "ingest", "sessionId": "other", "chunks": []])
            }),
            ("a different chunk count", "the manifest lists 0 chunks, the pointer 1", { h, pointer in
                corrupt(h, &pointer, manifest: ["kind": "ingest", "sessionId": .string(Self.session1), "chunks": []])
            }),
            ("a descriptor missing a field", "a manifest chunk lacks its descriptor", { h, pointer in
                corrupt(h, &pointer, manifest: [
                    "kind": "ingest", "sessionId": .string(Self.session1), "chunks": [["model": "Note", "path": "Note/0.ATTEMPT0"]],
                ])
            }),
            ("a chunk path that leaves the grant (edge 010)", "a manifest chunk's path leaves the grant", { h, pointer in
                let path = pointer["download"]?["path"]?.stringValue ?? ""
                var manifest = RecordLogJSON.parse(String(decoding: h.connection.artifact(path) ?? Data(), as: UTF8.self))?.objectValue ?? [:]
                var chunk = manifest["chunks"]?.arrayValue?.first?.objectValue ?? [:]
                chunk["path"] = "../grant9/Note/0"
                manifest["chunks"] = [.object(chunk)]
                corrupt(h, &pointer, manifest: .object(manifest))
            }),
            ("an absolute chunk path (edge 010)", "a manifest chunk's path leaves the grant", { h, pointer in
                let path = pointer["download"]?["path"]?.stringValue ?? ""
                var manifest = RecordLogJSON.parse(String(decoding: h.connection.artifact(path) ?? Data(), as: UTF8.self))?.objectValue ?? [:]
                var chunk = manifest["chunks"]?.arrayValue?.first?.objectValue ?? [:]
                chunk["path"] = "/doc-artifact/other/Note/0"
                manifest["chunks"] = [.object(chunk)]
                corrupt(h, &pointer, manifest: .object(manifest))
            }),
            ("a fetch error", "fetching the manifest failed", { h, _ in h.connection.intercept { _ in .error } }),
            ("a non-200 answer", "fetching the manifest failed: GET /doc-artifact/… answered 500", { h, _ in
                h.connection.intercept { _ in .status(500) }
            }),
            ("a 401 on a chunk (edge 011)", "fetching /doc-artifact/…/Note/0.ATTEMPT0 failed", { h, _ in
                h.connection.intercept { $0.hasSuffix("/Note/0.ATTEMPT0") ? .status(401) : .pass }
            }),
            ("a chunk failing its check twice", "the chunk at /doc-artifact/…/Note/0.ATTEMPT0 failed its check twice", { h, pointer in
                let key = "\(pointer["download"]?["path"]?.stringValue ?? "")/Note/0.ATTEMPT0"
                var bytes = h.connection.artifact(key) ?? Data()
                bytes[bytes.count - 1] ^= 0xff
                h.connection.put(key, bytes)
            }),
        ]
        for (name, reason, setup) in cases {
            let h = try await harness()
            await h.feed(H.opened())  // ignored: no open under way
            var pointer = h.publishLoad(sessionId: Self.session1, chunks: [("Note", [("n1", ["t": 1])])], firstLsn: 1, lastLsn: 1)
            setup(h, &pointer)
            await h.session.start()
            await h.feed(H.opened(lsn: 1, catchUp: loadForm(pointer, cursor: 0, upTo: 1)))
            await until("the reopen after \(name)") { h.of("record.open").count == 2 }
            XCTAssertEqual(h.of("record.open")[1]["cursor"], 0, name)
            XCTAssertEqual(h.marks.cursor, 0, name)
            XCTAssertTrue(
                lines.messages(.warn).contains { $0.hasPrefix("[record-log] load receipt failed \(H.documentId): \(Self.session1) \(reason)") },
                "\(name): \(lines.messages(.warn).last ?? "no warn line")"
            )
            if name == "a chunk failing its check twice" {
                XCTAssertEqual(h.connection.fetched.filter { $0.hasSuffix("/Note/0.ATTEMPT0") }.count, 2, "one refetch")
                XCTAssertTrue(lines.contains("[record-log] \(H.documentId): the chunk at /doc-artifact/…/Note/0.ATTEMPT0 failed its check", level: .warn))
            }
            await h.session.close()
        }
    }

    func testAChunkFailingItsCheckOnceIsFetchedAgainAndApplied() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(sessionId: Self.session1, chunks: [("Note", [("n1", ["t": 1])])], firstLsn: 1, lastLsn: 1)
        let key = "\(pointer["download"]?["path"]?.stringValue ?? "")/Note/0.ATTEMPT0"
        let good = h.connection.artifact(key) ?? Data()
        var bad = good
        bad[bad.count - 1] ^= 0xff
        h.connection.put(key, bad)
        let served = LockedBox(0)
        let connection = h.connection
        h.connection.intercept { path in
            // The second fetch of the chunk reads good bytes.
            if path == key, served.withValue({ $0 += 1; return $0 }) == 2 { connection.put(key, good) }
            return .pass
        }
        await h.session.start()
        await h.feed(H.opened(lsn: 1, catchUp: loadForm(pointer, cursor: 0, upTo: 1)))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched.filter { $0 == key }.count, 2)
        XCTAssertEqual(try h.read("n1"), ["id": "n1", "t": 1])
    }

    func testARemainderAnsweredRestartOrAnErrorFailsTheReceipt() async throws {
        for answer in ["restart", "error"] {
            let h = try await harness()
            let pointer = h.publishLoad(sessionId: Self.session1, chunks: [("Note", [("n1", ["t": 1])])], firstLsn: 1, lastLsn: 1)
            await h.session.start()
            await h.feed(H.opened(lsn: 1, catchUp: loadForm(pointer, cursor: 0, upTo: 1)))
            await until("the remainder request") { h.of("record.catchUp").count == 1 }
            if answer == "restart" {
                await h.feed(H.page(lsn: 0, restart: true))
            } else {
                await h.feed([
                    "type": "error", "messageType": "record.catchUp", "code": "INTERNAL_ERROR", "message": "Failed to process request",
                ])
            }
            await until("the reopen after \(answer)") { h.of("record.open").count == 2 }
            XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.session1), answer)
            XCTAssertTrue(lines.contains("[record-log] load receipt failed \(H.documentId): \(Self.session1) ", level: .warn), answer)
        }
    }

    func testASegmentsFailedRemainderCountsTowardsTheRowsFallbackAndIsLoggedReceivedOnlyOnceItCompletes() async throws {
        let h = try await harness()
        let segment = h.publishSegment(segmentId: "G1", lsn: 10, completedLsn: 14, rows: [["id": "s1", "title": "at B"]], corrections: [])
        await h.session.start()
        for (n, restart) in [(1, true), (2, false)] {
            await h.feed(H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16])))
            await until("the pages from C (\(n))") { h.of("record.catchUp").count == n }
            XCTAssertFalse(lines.contains("[record-log] segment received"))
            if restart {
                await h.feed(H.page(lsn: 0, restart: true))
            } else {
                await h.feed(["type": "error", "messageType": "record.catchUp", "code": "INTERNAL_ERROR", "message": "x"])
            }
            await until("the reopen (\(n))") { h.of("record.open").count == n + 1 }
        }
        XCTAssertEqual(h.of("record.open").dropFirst().first?["accepts"], ["load", "segment", "building"])
        XCTAssertEqual(h.of("record.open")[2]["accepts"], [])
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .segment, id: "G1"))
    }

    func testAReopenedStoreHoldingTheMarkerWalksTheTableWhenTheRoomAnswersPagedRows() async throws {
        let first = try await harness()
        let writer = first.binding.writer
        let attempt = try first.binding.store.beginReceipt(writer: writer, kind: .load, id: Self.session1).attempt
        _ = try first.binding.store.applyLoadChunk(
            writer: writer, sessionId: Self.session1, attempt: attempt, model: "Note",
            lines: [RecordLogLoadLine(id: "refused", patch: ["t": 1])]
        )
        // A second session over the same database: a restart.
        let h = try await harness(provider: first.provider, clientId: "client-b")
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.session1))
        await h.session.start()
        await h.feed(H.opened(lsn: 700, catchUp: .object(["mode": "paged", "count": 600, "cursor": 0, "upTo": 700])))
        await until("the walk") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.of("record.catchUp")[0]["full"], true)
        XCTAssertEqual(h.of("record.catchUp")[0]["upTo"], 700)
        await h.feed(H.page(rows: [H.row("kept")], lsn: 700))
        await until("synced") { h.synced.value == 1 }
        XCTAssertNil(try h.read("refused"))
        XCTAssertEqual(h.marks.cursor, 700)
        XCTAssertNil(h.marks.receipt)
    }

    // MARK: - Abandons (behavior 17; edges 007, 008, 018)

    func testAReceiptReleasedWhileItsChunksAreFetchedLetsTheChunkInFlightCompleteThenStopsAndOpensAgain() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(
            sessionId: Self.session1, chunks: [("Note", [("n1", [:])]), ("Note", [("n2", [:])])], firstLsn: 1, lastLsn: 2
        )
        let gate = H.Gate()
        h.connection.intercept { $0.hasSuffix("/Note/1.ATTEMPT1") ? .hold(gate) : .pass }
        await h.session.start()
        await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
        await until("the first chunk") { h.secondChunkHeld() }
        await h.feed(["type": "record.released", "reason": "delivery-failed"])
        gate.open()
        await until("the reopen") { h.of("record.open").count == 2 }
        await pause(20)
        XCTAssertEqual(h.of("record.catchUp").count, 0)
        XCTAssertEqual(try h.read("n2"), ["id": "n2"], "the chunk in flight completed")
        XCTAssertTrue(lines.contains(
            "[record-log] \(H.documentId): load receipt \(Self.session1) abandoned (the room released the subscription); opening again from the cursor"
        ))
        // No failure was counted.
        XCTAssertEqual(h.of("record.open").dropFirst().first?["accepts"], ["load", "segment", "building"])
    }

    func testAReleaseDuringTheRemaindersPagingDiscardsThePageAndOpensAgain() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(sessionId: Self.session1, chunks: [("Note", [("n1", [:])])], firstLsn: 1, lastLsn: 1)
        await h.session.start()
        await h.feed(H.opened(lsn: 1, catchUp: loadForm(pointer, cursor: 0, upTo: 1)))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(["type": "record.released", "reason": "delivery-failed"])
        XCTAssertEqual(h.of("record.open").count, 1, "the open waits for the page request's answer")
        await h.feed(H.page(rows: [H.row("late")], lsn: 1))
        XCTAssertEqual(h.of("record.open").count, 2)
        XCTAssertNil(try h.read("late"), "the page is discarded")
        XCTAssertEqual(h.marks.cursor, 0)
    }

    func testAChunkTheStoreAnswersStaleAbandonsWithoutCountingAndOpensAtOnce() async throws {
        let h = try await harness()
        await h.session.start()
        for round in 1...3 {
            let pointer = h.publishLoad(
                sessionId: Self.session1, chunks: [("Note", [("n1", [:])]), ("Note", [("n2", [:])])], firstLsn: 1, lastLsn: 2
            )
            let gate = H.Gate()
            h.connection.intercept { $0.hasSuffix("/Note/1.ATTEMPT1") ? .hold(gate) : .pass }
            await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
            await until("the first chunk (\(round))") { h.secondChunkHeld(times: round) }
            // Another client of the store completes a full replacement: this attempt's changes are made right.
            let other = RecordLogStore(host: h.provider, documentId: H.documentId, clientId: "client-other")
            let otherWriter = try other.mintWriter()
            let generation = try XCTUnwrap(try other.beginFencedCatchUp(writer: otherWriter, full: true))
            _ = try other.completeCatchUp(writer: otherWriter, lsn: 0, full: true, generation: generation)
            gate.open()
            await until("the reopen (\(round))") { h.of("record.open").count == round + 1 }
            XCTAssertEqual(h.of("record.open").dropFirst(round).first?["accepts"], ["load", "segment", "building"], "an abandon counts no failure")
        }
        XCTAssertNil(try h.read("n2"), "the stale chunk changed nothing")
        XCTAssertTrue(lines.contains(
            "[record-log] \(H.documentId): load receipt \(Self.session1) abandoned (the store ended it: another client's catch-up made its rows right)"
        ))
        XCTAssertFalse(lines.contains("[record-log] \(H.documentId): waiting for another client"))
    }

    /// A segment's chunk held in flight while a second store over the same file
    /// begins a fenced replacement: the chunk is answered stale.
    private func overtakenSegment(_ timings: RecordLogSessionTimings) async throws -> (H.Fixture, RecordLogStore, String, Int) {
        let h = try await harness(timings: timings)
        let segment = h.publishSegment(segmentId: "G1", lsn: 10, completedLsn: 14, rows: [["id": "s1", "title": "mine"]], corrections: [])
        let gate = H.Gate()
        h.connection.intercept { $0.hasSuffix("/Note/0") ? .hold(gate) : .pass }
        await h.session.start()
        await h.feed(H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16])))
        await until("the segment chunk's fetch") { h.connection.fetched.contains { $0.hasSuffix("/Note/0") } }
        let other = RecordLogStore(host: h.provider, documentId: H.documentId, clientId: "client-b")
        let otherWriter = try other.mintWriter()
        let generation = try XCTUnwrap(try other.beginFencedCatchUp(writer: otherWriter, full: true))
        gate.open()
        await until("the wait") { self.lines.contains("[record-log] \(H.documentId): waiting for another client of the store") }
        return (h, other, otherWriter, generation)
    }

    func testASessionOvertakenByAnotherClientsReplacementWaitsForItThenOpensFromTheCursorItLeft() async throws {
        let (h, other, otherWriter, generation) = try await overtakenSegment(H.timings)
        let progressAtWait = h.progress.value
        await pause(200)
        XCTAssertEqual(h.of("record.open").count, 1, "no open while the other replacement is under way")
        XCTAssertGreaterThan(h.progress.value, progressAtWait, "each poll reports progress")
        XCTAssertTrue(lines.contains(
            "[record-log] \(H.documentId): segment receipt G1 abandoned (another client of the store began replacing it)"
        ))
        _ = try other.applyCatchUpPage(
            writer: otherWriter, rows: [RecordLogCatchUpRow(model: "Note", id: "s1", row: ["id": "s1", "title": "theirs"])],
            generation: generation
        )
        _ = try other.completeCatchUp(writer: otherWriter, lsn: 16, full: true, generation: generation)
        await until("the open after the other replacement") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.of("record.open")[1]["cursor"], 16)
        XCTAssertEqual(h.of("record.open")[1]["accepts"], ["load", "segment", "building"], "no failure counted")
        await h.feed(H.opened(lsn: 16))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(try h.read("s1"), ["id": "s1", "title": "theirs"])
        let marks = h.marks
        XCTAssertEqual(marks.cursor, 16)
        XCTAssertFalse(marks.replacing)
    }

    func testAReplacementWaitWhoseDeadlinePassesOpensFromTheCursorAndSaysTheOtherIsTakenToBeGone() async throws {
        var timings = H.timings
        timings.replacementWaitMs = 150
        let (h, _, _, _) = try await overtakenSegment(timings)
        await until("the open past the deadline") { h.of("record.open").count == 2 }
        XCTAssertTrue(lines.contains(
            "[record-log] \(H.documentId): the other client's replacement did not complete within 150 ms; it is taken to be gone",
            level: .warn
        ))
    }

    func testADisconnectDuringTheReplacementWaitEndsIt() async throws {
        let (h, _, _, _) = try await overtakenSegment(H.timings)
        await h.session.disconnected()
        await pause(150)
        XCTAssertEqual(h.of("record.open").count, 1)
    }

    func testAChunkWhoseFetchOutlivedItsConnectionIsNeverApplied() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(
            sessionId: Self.session1, chunks: [("Note", [("n1", ["t": 1])]), ("Note", [("refused", ["t": 2])])], firstLsn: 1, lastLsn: 2
        )
        let gate = H.Gate()
        h.connection.intercept { $0.hasSuffix("/Note/1.ATTEMPT1") ? .hold(gate) : .pass }
        await h.session.start()
        await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
        await until("the first chunk") { h.secondChunkHeld() }
        // The socket drops while the second chunk is on its way (edge 008: the next open starts from idle, marker set).
        await h.session.disconnected()
        h.connection.intercept(nil)
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.session1))
        await h.session.start()
        XCTAssertEqual(h.of("record.open").count, 2)
        // The marker is set: the rows answer is walked as a full replacement, and the room has no "refused".
        await h.feed(H.opened(lsn: 3))
        await until("the walk") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(rows: [H.row("n1", ["t": 1])], lsn: 3))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(h.marks.cursor, 3)
        XCTAssertNil(h.marks.receipt)
        // The old fetch answers now: its bytes are dropped.
        gate.open()
        await pause(50)
        XCTAssertNil(try h.read("refused"))
        XCTAssertEqual(h.marks.cursor, 3)
        XCTAssertNil(h.marks.receipt)
        XCTAssertEqual(h.of("record.open").count, 2)
    }

    func testClosingOrPurgingMidReceiptCancelsItAndNothingAfterTouchesTheStore() async throws {
        for purge in [false, true] {
            let h = try await harness()
            let pointer = h.publishLoad(
                sessionId: Self.session1, chunks: [("Note", [("n1", [:])]), ("Note", [("n2", [:])])], firstLsn: 1, lastLsn: 2
            )
            let gate = H.Gate()
            h.connection.intercept { $0.hasSuffix("/Note/1.ATTEMPT1") ? .hold(gate) : .pass }
            await h.session.start()
            await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
            await until("the first chunk") { h.secondChunkHeld() }
            await h.session.close()
            h.binding.close()
            if purge {
                _ = try h.binding.store.purge(force: true)
            }
            let before = try h.provider.withConnection { try $0.query("SELECT COUNT(*) AS n FROM record_log_rows", []).first?["n"].intValue }
            gate.open()
            await pause(50)
            let after = try h.provider.withConnection { try $0.query("SELECT COUNT(*) AS n FROM record_log_rows", []).first?["n"].intValue }
            XCTAssertEqual(after, before, purge ? "purged" : "closed")
            XCTAssertNil(try h.read("n2"))
            XCTAssertEqual(h.of("record.catchUp").count, 0)
        }
    }

    /// A segment's task starts after the frame handler that scheduled it
    /// returned. A disconnect or a close in that gap leaves the store as it
    /// was: no receipt begun, no replacement started (4312-C2-01).
    func testASegmentTaskStartingAfterADisconnectOrACloseTouchesNothing() async throws {
        for close in [false, true] {
            let h = try await harness()
            let segment = h.publishSegment(segmentId: "G1", lsn: 10, completedLsn: 14, rows: [["id": "a", "title": "at B"]], corrections: [])
            await h.session.start()
            var frame = H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16]))
            frame["documentId"] = .string(H.documentId)
            await h.session.receiveThenStop(frame, close: close)
            await pause(100)
            let marks = h.marks
            XCTAssertNil(marks.receipt, close ? "closed" : "disconnected")
            XCTAssertFalse(marks.replacing, close ? "closed" : "disconnected")
            XCTAssertEqual(h.connection.fetched, [])
            XCTAssertEqual(h.of("record.open").count, 1)
            XCTAssertFalse(lines.contains("[record-log] segment receipt failed"))
        }
    }
}

private extension RecordLogSession {
    /// A frame, then a disconnect or a close, in one turn of the session, so
    /// no task the frame scheduled can start in between.
    func receiveThenStop(_ frame: [String: JSONValue], close stop: Bool) {
        receive(frame)
        if stop { close() } else { disconnected() }
    }
}
