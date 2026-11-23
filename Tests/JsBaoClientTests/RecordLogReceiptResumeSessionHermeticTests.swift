import XCTest
@testable import JsBaoClient

/// #5267 behaviors 9–13b (Swift session, hermetic): the twin of js-bao's
/// `record-log-client-session-resume-5267.test.ts`. An interrupted load or
/// segment download offered again continues where it stopped; it starts over
/// for anything else; two sessions over one store never continue one download
/// at once.
final class RecordLogReceiptResumeSessionHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let s = "01JS5267SESS10NRESUME00001"
    private static let s2 = "01JS5267SESS10NRESUME00002"
    private static let g = "01JG5267SESS10NRESUME00001"

    private var directories: [String] = []
    private var lines = H.Lines()

    override func setUp() {
        super.setUp()
        let lines = H.Lines()
        self.lines = lines
        Logger.lineForTest = { level, _, message in
            if message.contains(H.documentId) { lines.append(level, message) }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-resume-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func harness(
        provider: SQLiteStorageProvider? = nil, clientId: String = "client-a", timings: RecordLogSessionTimings = H.timings
    ) async throws -> H.Fixture {
        let store: SQLiteStorageProvider
        if let provider { store = provider } else { store = try await makeProvider() }
        return try await H.Fixture(provider: store, clientId: clientId, fetches: true, timings: timings)
    }

    /// Another session over the same store (a reload, or another tab), serving the same artifacts.
    private func over(_ h: H.Fixture, clientId: String = "client-a", timings: RecordLogSessionTimings = H.timings) async throws -> H.Fixture {
        let next = try await harness(provider: h.provider, clientId: clientId, timings: timings)
        next.connection.serve(from: h.connection)
        return next
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

    /// A load of `n` chunks of two rows each, `\(prefix)\(i)a` and `\(prefix)\(i)b`.
    private func publishLoad(_ h: H.Fixture, _ n: Int, sessionId: String = s, prefix: String = "n", title: String? = nil) -> [String: JSONValue] {
        h.publishLoad(
            sessionId: sessionId,
            chunks: (0..<n).map { i in
                ("Note", [("\(prefix)\(i)a", ["title": .string(title ?? "t\(i)")]), ("\(prefix)\(i)b", ["title": .string(title ?? "t\(i)")])])
            },
            firstLsn: 1, lastLsn: n * 2
        )
    }

    private func loadForm(_ pointer: [String: JSONValue], upTo: Int = 9) -> [String: JSONValue] {
        H.opened(lsn: upTo, catchUp: .object([
            "mode": "load", "load": .object(pointer), "count": 1, "cursor": 0, "upTo": .number(Double(upTo)),
        ]))
    }

    private func segmentForm(_ segment: JSONValue) -> [String: JSONValue] {
        H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16]))
    }

    private func base(_ pointer: [String: JSONValue]) -> String { pointer["download"]?["path"]?.stringValue ?? "" }
    private func chunkPath(_ pointer: [String: JSONValue], _ i: Int) -> String { "\(base(pointer))/Note/\(i).ATTEMPT\(i)" }
    private func base(_ segment: JSONValue) -> String { segment["download"]?["path"]?.stringValue ?? "" }

    /// The chunk indexes of `pointer` the session fetched, in order.
    private func fetchedChunks(_ h: H.Fixture, _ pointer: [String: JSONValue]) -> [Int] {
        h.connection.fetched.filter { $0.hasPrefix(base(pointer) + "/") }.compactMap { Int($0.split(separator: "/").last!.split(separator: ".")[0]) }
    }

    /// Holds fetches whose path ends with `suffix` until the gate opens.
    private func hold(_ h: H.Fixture, _ suffixes: [String: H.Gate]) {
        h.connection.intercept { path in
            for (suffix, gate) in suffixes where path.hasSuffix(suffix) { return .hold(gate) }
            return .pass
        }
    }

    /// A load stopped after `done` of its `n` chunks: the next fetch held, the session gone.
    private func interruptedLoad(_ n: Int, _ done: Int) async throws -> (H.Fixture, [String: JSONValue]) {
        let h = try await harness()
        let pointer = publishLoad(h, n)
        hold(h, ["/Note/\(done).ATTEMPT\(done)": H.Gate()])
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("chunk \(done) held") { h.connection.fetched.contains(chunkPath(pointer, done)) }
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.s, done: done, completed: false))
        await h.session.disconnected()
        return (h, pointer)
    }

    private func completeRemainder(_ h: H.Fixture, lsn: Int = 9) async {
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        await h.feed(H.page(lsn: lsn))
        await until("synced") { h.synced.value == 1 }
    }

    // MARK: - Behavior 9

    func testAReloadedLoadFetchesOnlyTheChunksItHasNotAppliedAndReportsProgressFromThere() async throws {
        let (first, pointer) = try await interruptedLoad(4, 2)
        let h = try await over(first)
        let gate = H.Gate()
        hold(h, ["/Note/2.ATTEMPT2": gate])
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("chunk 2 held") { h.connection.fetched.contains(chunkPath(pointer, 2)) }
        let status = await h.session.status()
        XCTAssertEqual(status, RecordLogSessionStatus(phase: .loading, progress: RecordLogSessionProgress(done: 2, total: 4, unit: .chunks)))
        XCTAssertTrue(lines.contains("[record-log] load receipt \(H.documentId): \(Self.s) resuming at chunk 2 of 4"))
        gate.open()
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, [base(pointer), chunkPath(pointer, 2), chunkPath(pointer, 3)])
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 0)
        XCTAssertEqual(h.of("record.catchUp")[0]["upTo"], 9)
        XCTAssertEqual(h.of("record.catchUp")[0]["load"]?.stringValue, Self.s)
        await h.feed(H.page(rows: [H.row("w1", ["title": "during"])], lsn: 9, next: "p2"))
        await until("the second page request") { h.of("record.catchUp").count == 2 }
        await h.feed(H.page(lsn: 9))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(h.marks.cursor, 9)
        XCTAssertNil(h.marks.receipt)
        for i in 0..<4 { for s in ["a", "b"] { XCTAssertEqual(try h.read("n\(i)\(s)"), ["id": .string("n\(i)\(s)"), "title": .string("t\(i)")]) } }
        XCTAssertEqual(try h.read("w1"), ["id": "w1", "title": "during"])
        XCTAssertTrue(lines.contains("[record-log] load received \(H.documentId): \(Self.s) 8 rows in 4 chunks"))
    }

    // MARK: - Behavior 10

    private func publishSegment(_ h: H.Fixture) -> JSONValue {
        h.publishSegment(
            segmentId: Self.g, lsn: 10, completedLsn: 14,
            chunks: [.rows([["id": "s1", "title": "at B"], ["id": "s2", "title": "at B"]]), .rows([["id": "s3", "title": "at B"], ["id": "s4", "title": "at B"]])],
            corrections: [("s2", ["id": "s2", "title": "after B", "_type": "Note"])], objects: H.SegmentObjects()
        )
    }

    func testASegmentStoppedAfterItsFirstChunkFetchesTheSecondAndTheCorrectionsUnderTheSameGeneration() async throws {
        let first = try await harness()
        let segment = publishSegment(first)
        hold(first, ["/Note/1": H.Gate()])
        await first.session.start()
        await first.feed(segmentForm(segment))
        await until("chunk 1 held") { first.connection.fetched.contains("\(base(segment))/Note/1") }
        let marks = first.marks
        XCTAssertEqual(marks.receipt, RecordLogReceipt(kind: .segment, id: Self.g, done: 1, completed: false))
        let generation = marks.replacement
        await first.session.disconnected()

        let h = try await over(first)
        await h.session.start()
        await h.feed(segmentForm(segment))
        await until("the pages from C") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, ["\(base(segment))/Note/1", "\(base(segment))/corrections"])
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 14)
        XCTAssertEqual(h.marks.replacement, generation)
        await h.feed(H.page(lsn: 16))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(h.marks.cursor, 16)
        XCTAssertNil(h.marks.receipt)
        XCTAssertFalse(h.marks.replacing)
        XCTAssertEqual(try h.read("s1"), ["id": "s1", "title": "at B"])
        XCTAssertEqual(try h.read("s2"), ["id": "s2", "title": "after B"])
        XCTAssertEqual(try h.read("s4"), ["id": "s4", "title": "at B"])
    }

    func testASegmentStoppedAfterItsCorrectionsFetchesNothingAndPagesFromCAtOnce() async throws {
        let first = try await harness()
        let segment = publishSegment(first)
        await first.session.start()
        await first.feed(segmentForm(segment))
        await until("the pages from C") { first.of("record.catchUp").count == 1 }
        XCTAssertEqual(first.marks.receipt, RecordLogReceipt(kind: .segment, id: Self.g, done: 2, completed: true))
        await first.session.disconnected()

        let h = try await over(first)
        await h.session.start()
        await h.feed(segmentForm(segment))
        await until("the pages from C") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, [])
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 14)
        await h.feed(H.page(rows: [H.row("c", ["title": "after C"])], lsn: 16))
        await until("synced") { h.synced.value == 1 }
        for id in ["s1", "s2", "s3", "s4", "c"] { XCTAssertNotNil(try h.read(id), id) }
        XCTAssertNil(h.marks.receipt)
    }

    // MARK: - Behavior 11

    func testALoadStoppedDuringItsRemainderGoesStraightToTheRemainder() async throws {
        let first = try await harness()
        let pointer = publishLoad(first, 2)
        await first.session.start()
        await first.feed(loadForm(pointer))
        await until("the remainder request") { first.of("record.catchUp").count == 1 }
        XCTAssertEqual(first.marks.receipt, RecordLogReceipt(kind: .load, id: Self.s, done: 2, completed: true))
        await first.session.disconnected()

        let h = try await over(first)
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, [base(pointer)])
        XCTAssertEqual(h.of("record.catchUp")[0]["cursor"], 0)
        XCTAssertEqual(h.of("record.catchUp")[0]["load"]?.stringValue, Self.s)
        await h.feed(H.page(lsn: 9))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(h.marks.cursor, 9)
        XCTAssertNil(h.marks.receipt)
        XCTAssertEqual(try h.read("n1b"), ["id": "n1b", "title": "t1"])
    }

    // MARK: - Behavior 12

    func testItStartsOverForAnotherLoad() async throws {
        let (first, _) = try await interruptedLoad(2, 1)
        let h = try await over(first)
        let other = publishLoad(h, 2, sessionId: Self.s2, prefix: "m")
        await h.session.start()
        await h.feed(loadForm(other))
        await completeRemainder(h)
        XCTAssertEqual(fetchedChunks(h, other), [0, 1])
    }

    func testItStartsOverForTheSameLoadWithAChangedManifest() async throws {
        do {
            let (first, _) = try await interruptedLoad(2, 1)
            let h = try await over(first)
            let changed = publishLoad(h, 2, title: "changed")
            await h.session.start()
            await h.feed(loadForm(changed))
            await completeRemainder(h)
            XCTAssertEqual(fetchedChunks(h, changed), [0, 1])
            XCTAssertEqual(try h.read("n0a"), ["id": "n0a", "title": "changed"])
        }
        do {
            let (first, pointer) = try await interruptedLoad(2, 1)
            let h = try await over(first)
            var manifest = try XCTUnwrap(RecordLogJSON.parse(String(decoding: try XCTUnwrap(h.connection.artifact(base(pointer))), as: UTF8.self)))
            guard case var .object(object) = manifest, case var .array(chunks) = object["chunks"] ?? .null, case var .object(chunk) = chunks[0] else {
                return XCTFail("the manifest")
            }
            chunk["firstId"] = "n0"
            chunks[0] = .object(chunk)
            object["chunks"] = .array(chunks)
            manifest = .object(object)
            h.connection.put(base(pointer), Data(RecordLogJSON.text(manifest).utf8))
            await h.session.start()
            await h.feed(loadForm(pointer))
            // It starts over at chunk 0, whose descriptor no longer matches its bytes: the receipt fails there.
            await until("the reopen") { h.of("record.open").count == 2 }
            XCTAssertEqual(fetchedChunks(h, pointer), [0, 0])
        }
    }

    func testItStartsOverForAnAttemptRecordedWithoutAFingerprint() async throws {
        let first = try await harness()
        let pointer = publishLoad(first, 2)
        let writer = first.binding.writer
        let attempt = try first.binding.store.beginReceipt(writer: writer, kind: .load, id: Self.s).attempt
        _ = try first.binding.store.applyLoadChunk(
            writer: writer, sessionId: Self.s, attempt: attempt, model: "Note",
            lines: [RecordLogLoadLine(id: "n0a", patch: ["title": "t0"]), RecordLogLoadLine(id: "n0b", patch: ["title": "t0"])]
        )
        let h = try await over(first)
        await h.session.start()
        await h.feed(loadForm(pointer))
        await completeRemainder(h)
        XCTAssertEqual(fetchedChunks(h, pointer), [0, 1])
    }

    func testItStartsOverForALoadWhoseGenerationAnotherSessionsReplacementMoved() async throws {
        for completed in [false, true] {
            let first = try await harness()
            let pointer = publishLoad(first, 3)
            let chunk1 = H.Gate()
            hold(first, ["/Note/1.ATTEMPT1": chunk1, "/Note/2.ATTEMPT2": H.Gate()])
            await first.session.start()
            await first.feed(loadForm(pointer))
            await until("chunk 1 held") { first.connection.fetched.contains(chunkPath(pointer, 1)) }
            // Another session of the store begins replacing it from the room's table, which has "x" only so far.
            let other = RecordLogStore(host: first.provider, documentId: H.documentId, clientId: "client-b")
            try other.initialize()
            let otherWriter = try other.mintWriter()
            let generation = try XCTUnwrap(try other.beginFencedCatchUp(writer: otherWriter, full: true))
            // The first session's next chunk lands under that replacement, then it stops.
            chunk1.open()
            await until("chunk 2 held") { first.connection.fetched.contains(chunkPath(pointer, 2)) }
            await first.session.disconnected()
            func replace() throws {
                _ = try other.applyCatchUpPage(writer: otherWriter, rows: [RecordLogCatchUpRow(model: "Note", id: "x", row: ["id": "x"])], generation: generation)
                _ = try other.completeCatchUp(writer: otherWriter, lsn: 5, full: true, generation: generation)
            }
            if completed {
                try replace()
                XCTAssertNil(try other.read(model: "Note", id: "n0a"))
            }
            let h = try await over(first)
            let gate = H.Gate()
            hold(h, ["/Note/2.ATTEMPT2": gate])
            await h.session.start()
            await h.feed(loadForm(pointer))
            await until("chunk 2 held") { h.connection.fetched.contains(chunkPath(pointer, 2)) }
            if !completed { try replace() }
            gate.open()
            await completeRemainder(h)
            XCTAssertEqual(fetchedChunks(h, pointer), [0, 1, 2], "completed: \(completed)")
            for id in ["n0a", "n0b", "n1a", "n1b", "n2a", "n2b", "x"] { XCTAssertNotNil(try h.read(id), "\(id), completed: \(completed)") }
            XCTAssertEqual(h.marks.cursor, 9)
            XCTAssertNil(h.marks.receipt)
        }
    }

    func testItStartsOverForASegmentWhoseGenerationAnotherSessionsReplacementSuperseded() async throws {
        let first = try await harness()
        let segment = publishSegment(first)
        hold(first, ["/Note/1": H.Gate()])
        await first.session.start()
        await first.feed(segmentForm(segment))
        await until("chunk 1 held") { first.connection.fetched.contains("\(base(segment))/Note/1") }
        await first.session.disconnected()
        let other = RecordLogStore(host: first.provider, documentId: H.documentId, clientId: "client-b")
        try other.initialize()
        _ = try other.beginFencedCatchUp(writer: try other.mintWriter(), full: true)
        let h = try await over(first)
        await h.session.start()
        await h.feed(segmentForm(segment))
        await until("the pages from C") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, ["\(base(segment))/Note/0", "\(base(segment))/Note/1", "\(base(segment))/corrections"])
    }

    func testARowsAnswerWhileTheMarkerIsSetWalksTheTableWhichEndsTheAttempt() async throws {
        let (first, _) = try await interruptedLoad(2, 1)
        let h = try await over(first)
        await h.session.start()
        await h.feed(H.opened(lsn: 9))
        await until("the walk") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.of("record.catchUp")[0]["full"], true)
        await h.feed(H.page(rows: [H.row("n0a", ["title": "t0"])], lsn: 9))
        await until("synced") { h.synced.value == 1 }
        XCTAssertEqual(h.marks.cursor, 9)
        XCTAssertNil(h.marks.receipt)
        XCTAssertEqual(h.connection.fetched, [])
    }

    // MARK: - Behavior 13

    private func racing(waitMs: Int = H.timings.replacementWaitMs) async throws -> (a: H.Fixture, b: H.Fixture, pointer: [String: JSONValue], gateA: H.Gate, gateB: H.Gate) {
        var timings = H.timings
        timings.replacementWaitMs = waitMs
        let a = try await harness(timings: timings)
        let pointer = publishLoad(a, 3)
        let gateA = H.Gate()
        hold(a, ["/Note/1.ATTEMPT1": gateA])
        await a.session.start()
        await a.feed(loadForm(pointer))
        await until("a's chunk 1 held") { a.connection.fetched.contains(chunkPath(pointer, 1)) }
        let b = try await over(a, clientId: "client-b")
        let gateB = H.Gate()
        hold(b, ["/Note/2.ATTEMPT2": gateB])
        await b.session.start()
        await b.feed(loadForm(pointer))
        await until("b's chunk 2 held") { b.connection.fetched.contains(chunkPath(pointer, 2)) }
        XCTAssertEqual(b.connection.fetched, [base(pointer), chunkPath(pointer, 1), chunkPath(pointer, 2)])
        return (a, b, pointer, gateA, gateB)
    }

    func testTheLaterSessionTakesTheDownloadOverAndTheEarlierWaitsUntilItCompletes() async throws {
        let (a, b, _, gateA, gateB) = try await racing()
        gateA.open()
        await until("a abandons") {
            self.lines.contains("[record-log] \(H.documentId): load receipt \(Self.s) abandoned (another session of the store took it over)")
        }
        await pause(300)
        XCTAssertEqual(a.of("record.open").count, 1)
        XCTAssertGreaterThan(a.progress.value, 0)
        gateB.open()
        await until("b's remainder") { b.of("record.catchUp").count == 1 }
        await b.feed(H.page(lsn: 9))
        await until("b synced") { b.synced.value == 1 }
        await until("a opens again") { a.of("record.open").count == 2 }
        XCTAssertEqual(a.of("record.open")[1]["cursor"], 9)
        await a.feed(H.opened(lsn: 9))
        await until("a synced") { a.synced.value == 1 }
        XCTAssertEqual(try a.read("n2b"), ["id": "n2b", "title": "t2"])
        XCTAssertEqual(a.marks.cursor, 9)
        XCTAssertNil(a.marks.receipt)
    }

    func testWithTheOtherStalledTheEarlierOpensAgainOnceTheWaitPassesWithNoProgress() async throws {
        let (a, _, _, gateA, _) = try await racing(waitMs: 300)
        gateA.open()
        await until("a abandons") { self.lines.contains("[record-log] \(H.documentId): load receipt \(Self.s) abandoned (another session") }
        let since = Date()
        await pause(150)
        XCTAssertEqual(a.of("record.open").count, 1)
        await until("a opens again") { a.of("record.open").count == 2 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(since), 0.25)
        XCTAssertEqual(a.of("record.open")[1]["cursor"], 0)
    }

    // MARK: - Behavior 13b

    func testTheEarlierSessionsPageAfterATakeoverIsRefusedChangesNoRowAndNeverCompletes() async throws {
        let a = try await harness()
        let pointer = a.publishLoad(sessionId: Self.s, chunks: [("Note", [("n1", ["title": "loaded"])])], firstLsn: 1, lastLsn: 1)
        await a.session.start()
        await a.feed(loadForm(pointer, upTo: 10))
        await until("a's remainder") { a.of("record.catchUp").count == 1 }
        await a.feed(H.page(rows: [H.row("w1", ["title": "old"])], lsn: 10, next: "p2"))
        await until("a's second page request") { a.of("record.catchUp").count == 2 }

        let b = try await over(a, clientId: "client-b")
        await b.session.start()
        await b.feed(loadForm(pointer, upTo: 12))
        await until("b's remainder") { b.of("record.catchUp").count == 1 }
        XCTAssertEqual(b.connection.fetched, [base(pointer)])
        await b.feed(H.page(rows: [H.row("w2", ["title": "new"])], lsn: 12, next: "q2"))
        await until("b's second page request") { b.of("record.catchUp").count == 2 }

        // a's second page, read at 10, arrives after the takeover.
        await a.feed(H.page(rows: [H.row("w2", ["title": "old"])], lsn: 10))
        XCTAssertEqual(try b.read("w2"), ["id": "w2", "title": "new"])
        XCTAssertEqual(a.marks.cursor, 0, "a's completion is never applied")
        await pause(200)
        XCTAssertEqual(a.of("record.open").count, 1)

        await b.feed(H.page(lsn: 12))
        await until("b synced") { b.synced.value == 1 }
        await until("a opens again") { a.of("record.open").count == 2 }
        XCTAssertEqual(a.of("record.open")[1]["cursor"], 12)
        await a.feed(H.opened(lsn: 12))
        await until("a synced") { a.synced.value == 1 }
        XCTAssertEqual(try a.read("n1"), ["id": "n1", "title": "loaded"])
        XCTAssertEqual(try a.read("w1"), ["id": "w1", "title": "old"])
        XCTAssertEqual(try a.read("w2"), ["id": "w2", "title": "new"])
        XCTAssertEqual(a.marks.cursor, 12)
        XCTAssertNil(a.marks.receipt)
    }

    // MARK: - Edge cases

    func testAChunkFailingItsCheckOnAResumedReceiptIsFetchedOnceMoreAndTheNextOfferResumesWhereItWas() async throws {
        let (first, pointer) = try await interruptedLoad(3, 1)
        let h = try await over(first)
        let good = try XCTUnwrap(h.connection.artifact(chunkPath(pointer, 1)))
        var bad = good
        bad[bad.count - 1] ^= 0xff
        h.connection.put(chunkPath(pointer, 1), bad)
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("the reopen") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.connection.fetched.filter { $0 == chunkPath(pointer, 1) }.count, 2)
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.s, done: 1, completed: false))
        h.connection.put(chunkPath(pointer, 1), good)
        await h.feed(loadForm(pointer))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(lines.messages().filter { $0 == "[record-log] load receipt \(H.documentId): \(Self.s) resuming at chunk 1 of 3" }.count, 2)
        XCTAssertEqual(h.connection.fetched.filter { $0 == chunkPath(pointer, 0) }.count, 0)
        XCTAssertEqual(h.connection.fetched.filter { $0 == chunkPath(pointer, 2) }.count, 1)
    }

    func testTwoFailuresInARowDeclareAcceptsEmptyAndTheRowsWalkThatFollowsEndsTheAttempt() async throws {
        let (first, pointer) = try await interruptedLoad(2, 1)
        let h = try await over(first)
        let missing = chunkPath(pointer, 1)
        h.connection.intercept { $0 == missing ? .status(404) : .pass }
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("the first reopen") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.of("record.open")[1]["accepts"], ["load", "segment", "building"])
        await h.feed(loadForm(pointer))
        await until("the second reopen") { h.of("record.open").count == 3 }
        XCTAssertEqual(h.of("record.open")[2]["accepts"], [])
        await h.feed(H.opened(lsn: 9))
        await until("the walk") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.of("record.catchUp")[0]["full"], true)
        await h.feed(H.page(lsn: 9))
        await until("synced") { h.synced.value == 1 }
        XCTAssertNil(h.marks.receipt)
    }

    func testARecordReleasedDuringAResumedReceiptStopsAfterTheChunkInFlightAndKeepsTheProgress() async throws {
        let (first, pointer) = try await interruptedLoad(3, 1)
        let h = try await over(first)
        let gate = H.Gate()
        hold(h, ["/Note/1.ATTEMPT1": gate])
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("chunk 1 held") { h.connection.fetched.contains(chunkPath(pointer, 1)) }
        await h.feed(["type": "record.released", "reason": "delivery-failed"])
        gate.open()
        await until("the reopen") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.marks.receipt, RecordLogReceipt(kind: .load, id: Self.s, done: 2, completed: false))
        XCTAssertEqual(h.connection.fetched.filter { $0 == chunkPath(pointer, 2) }.count, 0)
        h.connection.intercept(nil)
        await h.feed(loadForm(pointer))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched.filter { $0 == chunkPath(pointer, 1) }.count, 1)
        XCTAssertEqual(h.connection.fetched.filter { $0 == chunkPath(pointer, 2) }.count, 1)
    }
}
