import XCTest
@testable import JsBaoClient

/// #5268 behavior 13 (Swift session, hermetic): the twin of js-bao's
/// `record-log-client-session-unfinished-5268.test.ts`. `record.open` names
/// the download the store's receipt marker says was left unfinished — a load,
/// a segment, a load whose remainder was in progress — and names nothing with
/// no marker, on the open that declares `accepts: []` after two failed
/// receipts, or on a connection that cannot fetch artifacts. A marker an
/// earlier build left without a fingerprint is named too, and the load offered
/// again is then downloaded from its first chunk.
final class RecordLogUnfinishedOpenHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let s = "01JS5268SESS10NUNF1N1SHED1"
    private static let g = "01JG5268SESS10NUNF1N1SHED1"

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-unfinished-open-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func harness(provider: SQLiteStorageProvider? = nil, fetches: Bool = true) async throws -> H.Fixture {
        let store: SQLiteStorageProvider
        if let provider { store = provider } else { store = try await makeProvider() }
        return try await H.Fixture(provider: store, clientId: "client-a", fetches: fetches, timings: H.timings)
    }

    /// Another session over the same store, serving the same artifacts.
    private func over(_ h: H.Fixture, fetches: Bool = true) async throws -> H.Fixture {
        let next = try await harness(provider: h.provider, fetches: fetches)
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

    private func publishLoad(_ h: H.Fixture, _ n: Int) -> [String: JSONValue] {
        h.publishLoad(
            sessionId: Self.s,
            chunks: (0..<n).map { i in ("Note", [("n\(i)a", ["title": .string("t\(i)")]), ("n\(i)b", ["title": .string("t\(i)")])]) },
            firstLsn: 1, lastLsn: n * 2
        )
    }

    private func loadForm(_ pointer: [String: JSONValue]) -> [String: JSONValue] {
        H.opened(lsn: 9, catchUp: .object(["mode": "load", "load": .object(pointer), "count": 1, "cursor": 0, "upTo": 9]))
    }

    private func segmentForm(_ segment: JSONValue) -> [String: JSONValue] {
        H.opened(lsn: 16, catchUp: .object(["mode": "segment", "segment": segment, "count": 1, "cursor": 14, "upTo": 16]))
    }

    private func base(_ pointer: [String: JSONValue]) -> String { pointer["download"]?["path"]?.stringValue ?? "" }
    private func chunkPath(_ pointer: [String: JSONValue], _ i: Int) -> String { "\(base(pointer))/Note/\(i).ATTEMPT\(i)" }

    private func hold(_ h: H.Fixture, _ suffix: String) {
        let gate = H.Gate()
        h.connection.intercept { path in path.hasSuffix(suffix) ? .hold(gate) : .pass }
    }

    /// A load stopped after `done` of its `n` chunks: the next fetch held, the session gone.
    private func interruptedLoad(_ n: Int, _ done: Int) async throws -> (H.Fixture, [String: JSONValue]) {
        let h = try await harness()
        let pointer = publishLoad(h, n)
        hold(h, "/Note/\(done).ATTEMPT\(done)")
        await h.session.start()
        await h.feed(loadForm(pointer))
        await until("chunk \(done) held") { h.connection.fetched.contains(chunkPath(pointer, done)) }
        XCTAssertEqual(h.marks.receipt?.id, Self.s)
        await h.session.disconnected()
        return (h, pointer)
    }

    /// The first `record.open` a new session over `first`'s store sends.
    private func reopened(_ first: H.Fixture, fetches: Bool = true) async throws -> (H.Fixture, [String: JSONValue]) {
        let h = try await over(first, fetches: fetches)
        await h.session.start()
        await until("the open") { h.of("record.open").count == 1 }
        return (h, h.of("record.open")[0])
    }

    private func named(_ kind: String, _ id: String) -> JSONValue { .object(["kind": .string(kind), "id": .string(id)]) }

    func testItNamesALoadStoppedPartWay() async throws {
        let (first, _) = try await interruptedLoad(4, 2)
        let (_, open) = try await reopened(first)
        XCTAssertEqual(open["accepts"], ["load", "segment", "building"])
        XCTAssertEqual(open["unfinished"], named("load", Self.s))
    }

    func testItNamesASegmentStoppedPartWay() async throws {
        let first = try await harness()
        let segment = first.publishSegment(
            segmentId: Self.g, lsn: 10, completedLsn: 14,
            chunks: [.rows([["id": "s1", "title": "at B"], ["id": "s2", "title": "at B"]]), .rows([["id": "s3", "title": "at B"], ["id": "s4", "title": "at B"]])],
            corrections: [("s2", ["id": "s2", "title": "after B", "_type": "Note"])], objects: H.SegmentObjects()
        )
        hold(first, "/Note/1")
        await first.session.start()
        await first.feed(segmentForm(segment))
        await until("chunk 1 held") { first.connection.fetched.contains("\(segment["download"]?["path"]?.stringValue ?? "")/Note/1") }
        await first.session.disconnected()
        let (_, open) = try await reopened(first)
        XCTAssertEqual(open["unfinished"], named("segment", Self.g))
    }

    func testItNamesALoadWhoseChunksCompletedAndWhoseRemainderDidNot() async throws {
        let first = try await harness()
        let pointer = publishLoad(first, 2)
        await first.session.start()
        await first.feed(loadForm(pointer))
        await until("the remainder request") { first.of("record.catchUp").count == 1 }
        XCTAssertEqual(first.marks.receipt, RecordLogReceipt(kind: .load, id: Self.s, done: 2, completed: true))
        await first.session.disconnected()
        let (_, open) = try await reopened(first)
        XCTAssertEqual(open["unfinished"], named("load", Self.s))
    }

    func testItNamesNothingWhenTheStoreHasNoMarker() async throws {
        let h = try await harness()
        await h.session.start()
        await until("the open") { h.of("record.open").count == 1 }
        XCTAssertEqual(h.of("record.open")[0]["accepts"], ["load", "segment", "building"])
        XCTAssertNil(h.of("record.open")[0]["unfinished"])
    }

    func testItNamesNothingOnTheOpenThatDeclaresAcceptsEmptyAfterTwoFailedReceipts() async throws {
        let (first, pointer) = try await interruptedLoad(2, 1)
        let h = try await over(first)
        let missing = chunkPath(pointer, 1)
        h.connection.intercept { $0 == missing ? .status(404) : .pass }
        await h.session.start()
        await until("the open") { h.of("record.open").count == 1 }
        XCTAssertEqual(h.of("record.open")[0]["unfinished"], named("load", Self.s))
        await h.feed(loadForm(pointer))
        await until("the first reopen") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.of("record.open")[1]["unfinished"], named("load", Self.s))
        await h.feed(loadForm(pointer))
        await until("the second reopen") { h.of("record.open").count == 3 }
        XCTAssertEqual(h.of("record.open")[2]["accepts"], [])
        XCTAssertNil(h.of("record.open")[2]["unfinished"])
    }

    func testItNamesNothingOnAConnectionThatCannotFetchArtifacts() async throws {
        let (first, _) = try await interruptedLoad(4, 2)
        let (_, open) = try await reopened(first, fetches: false)
        XCTAssertNil(open["accepts"])
        XCTAssertNil(open["unfinished"])
    }

    func testAMarkerWithoutAFingerprintIsNamedAndTheLoadOfferedAgainIsDownloadedFromItsFirstChunk() async throws {
        let first = try await harness()
        let pointer = publishLoad(first, 2)
        let writer = first.binding.writer
        let attempt = try first.binding.store.beginReceipt(writer: writer, kind: .load, id: Self.s).attempt
        _ = try first.binding.store.applyLoadChunk(
            writer: writer, sessionId: Self.s, attempt: attempt, model: "Note",
            lines: [RecordLogLoadLine(id: "n0a", patch: ["title": "t0"]), RecordLogLoadLine(id: "n0b", patch: ["title": "t0"])]
        )
        let (h, open) = try await reopened(first)
        XCTAssertEqual(open["unfinished"], named("load", Self.s))
        await h.feed(loadForm(pointer))
        await until("the remainder request") { h.of("record.catchUp").count == 1 }
        XCTAssertEqual(h.connection.fetched, [base(pointer), chunkPath(pointer, 0), chunkPath(pointer, 1)])
        await h.feed(H.page(lsn: 9))
        await until("synced") { h.synced.value == 1 }
        XCTAssertNil(h.marks.receipt)
    }
}
