import XCTest
@testable import JsBaoClient

/// #4556 behavior 19 — the Swift session's side of streamed catch-ups and of
/// waiting for a segment being built, against scripted room frames over a real
/// store, mirroring the JS session's suite:
///
/// - every catch-up start carries a fresh `stream` id; pages marked with it are
///   applied without a request, one marked with another id is ignored, and a
///   credit `{stream, credit: next}` goes after every fourth page that has
///   `next`, never for the last;
/// - a page with no `stream` (an older room) is followed by a request per
///   `next`, as before;
/// - `record.released` during a stream whose pages arrived, or before its first
///   one when `record.opened` said the room streams, opens again at once, as
///   does a pushed `restart` and a start while the stream stalled (edge 031);
///   an earlier stream's last page never completes a later one; a room not
///   known to stream may owe the start an unmarked page, and a release or a
///   retry waits for it, so it never completes the next open;
/// - `mode: "building"` reports progress and opens again after `retryMs`; past
///   the wait's cap the open no longer declares `building`.
final class RecordLogStreamHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    /// A socket that keeps every frame it is handed, in order, and fetches artifacts.
    final class StreamConnection: RecordLogConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [[String: JSONValue]] = []
        var frames: [[String: JSONValue]] { lock.withLock { _frames } }
        var fetchesArtifacts: Bool { true }
        func send(_ frame: [String: JSONValue]) { lock.withLock { _frames.append(frame) } }
        func connected() -> Bool { true }
        func all(_ type: String) -> [[String: JSONValue]] { frames.filter { $0["type"]?.stringValue == type } }
        func starts() -> [[String: JSONValue]] { all("record.catchUp").filter { $0["credit"] == nil } }
        func credits() -> [[String: JSONValue]] { all("record.catchUp").filter { $0["credit"] != nil } }
    }

    private struct Fixture {
        let binding: RecordLogDocumentBinding
        let session: RecordLogSession
        let connection: StreamConnection
        let synced: LockedBox<Int>
        let progress: LockedBox<Int>
    }

    private func makeFixture(buildingMaxWaitMs: Int = 60_000) async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-stream-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "client-1",
            logger: Logger(level: .none)
        )
        try binding.registerModel(Self.schema)
        let connection = StreamConnection()
        let synced = LockedBox(0)
        let progress = LockedBox(0)
        var timings = RecordLogSessionTimings(tickMs: 1, resultGapMs: 150, drainWaitMs: 300, writerTakenRetryMs: 40, catchUpRetryMs: 40)
        timings.buildingMaxWaitMs = buildingMaxWaitMs
        let session = RecordLogSession(
            documentId: "doc-1", binding: binding,
            host: RecordLogSessionHost(
                connection: { connection },
                declarations: { ["Note": .object(["fields": .object(["title": .object(["type": "string"])])])] },
                synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, _ in },
                progress: { _ in progress.withValue { $0 += 1 } }
            ),
            timings: timings, logger: Logger(level: .none)
        )
        await session.attach()
        return Fixture(binding: binding, session: session, connection: connection, synced: synced, progress: progress)
    }

    private func opened(lsn: Int, catchUp: JSONValue, streams: Bool = false) -> [String: JSONValue] {
        var frame: [String: JSONValue] = [
            "type": "record.opened", "documentId": "doc-1", "lsn": .number(Double(lsn)), "lastSeq": 0,
            "epochs": .object(["current": 1, "next": 2, "floor": 0, "entries": 10_000, "high": 1]),
            "cursorFloor": 0, "constraints": [], "catchUp": catchUp,
        ]
        if streams { frame["streams"] = true }
        return frame
    }

    private func paged(_ count: Int, upTo: Int, full: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["mode": "paged", "count": .number(Double(count)), "cursor": 0, "upTo": .number(Double(upTo))]
        if full { object["full"] = true }
        return .object(object)
    }

    private func row(_ id: String) -> JSONValue {
        .object(["model": "Note", "id": .string(id), "row": .object(["id": .string(id), "title": .string(id)])])
    }

    private func at(_ n: Int) -> JSONValue { .object(["lsn": .number(Double(n)), "model": "Note", "id": .string("r\(n)")]) }

    /// The pages of a stream over rows r1…rN, one row a page; the last has no `next`.
    private func pages(_ stream: String?, _ count: Int, lsn: Int? = nil) -> [[String: JSONValue]] {
        (1...count).map { n in
            var page: [String: JSONValue] = [
                "type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("r\(n)")], "gone": [],
                "lsn": .number(Double(lsn ?? count)),
            ]
            if let stream { page["stream"] = .string(stream) }
            if n < count { page["next"] = at(n) }
            return page
        }
    }

    private func read(_ fixture: Fixture, _ id: String) throws -> Bool { try fixture.binding.store.read(model: "Note", id: id) != nil }

    private func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: () async throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testAStreamIsAppliedWithoutRequestsCreditedEveryFourthPageAndCompletesAtTheLast() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 9, catchUp: paged(9, upTo: 9)))
        let start = try XCTUnwrap(f.connection.starts().first)
        let stream = try XCTUnwrap(start["stream"]?.stringValue)
        XCTAssertFalse(stream.isEmpty)
        XCTAssertNil(start["after"])
        let all = pages(stream, 9)
        for page in all.prefix(8) { await f.session.receive(page) }
        // A page of another stream is ignored.
        await f.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "stream": .string(stream + "-other"),
            "rows": [row("foreign")], "gone": [], "lsn": 9,
        ])
        XCTAssertEqual(f.connection.starts().count, 1, "no page is asked for")
        XCTAssertEqual(f.connection.credits().map { $0["credit"] }, [at(4), at(8)])
        XCTAssertEqual(f.connection.credits().map { $0["stream"]?.stringValue }, [stream, stream])
        XCTAssertEqual(f.synced.value, 0)
        await f.session.receive(all[8])
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertEqual(f.connection.credits().count, 2, "never a credit for the last page")
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 9)
        for n in 1...9 { XCTAssertTrue(try read(f, "r\(n)")) }
        XCTAssertFalse(try read(f, "foreign"))
        XCTAssertGreaterThanOrEqual(f.progress.value, 9)
    }

    func testEachStartHasAFreshIdAndAnEightPageStreamCreditsOnce() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 8, catchUp: paged(8, upTo: 8)))
        let first = try XCTUnwrap(f.connection.starts().first?["stream"]?.stringValue)
        for page in pages(first, 8) { await f.session.receive(page) }
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertEqual(f.connection.credits().map { $0["credit"] }, [at(4)])
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        await f.session.receive(opened(lsn: 12, catchUp: paged(3, upTo: 12, full: true)))
        let second = try XCTUnwrap(f.connection.starts().last)
        XCTAssertEqual(second["full"], true)
        XCTAssertNotEqual(second["stream"]?.stringValue, first)
        for page in pages(second["stream"]?.stringValue, 3, lsn: 12) { await f.session.receive(page) }
        XCTAssertEqual(f.synced.value, 2)
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 12)
        XCTAssertFalse(try read(f, "r4"), "the full replacement kept only what its pages carried")
    }

    func testAPageWithNoStreamIsFollowedByARequestPerNext() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 3, catchUp: paged(3, upTo: 3)))
        let legacy = pages(nil, 3)
        await f.session.receive(legacy[0])
        XCTAssertEqual(f.connection.starts().count, 2)
        XCTAssertEqual(f.connection.starts()[1]["after"], at(1))
        XCTAssertNil(f.connection.starts()[1]["stream"])
        await f.session.receive(legacy[1])
        XCTAssertEqual(f.connection.starts()[2]["after"], at(2))
        await f.session.receive(legacy[2])
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertTrue(f.connection.credits().isEmpty)
    }

    func testAnEarlierStreamsLastPageNeverCompletesALaterOne() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 4, catchUp: .object(["mode": "full", "rows": [row("r1"), row("r2")], "gone": [], "lsn": 4, "upTo": 4])))
        XCTAssertEqual(f.synced.value, 1)
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        await f.session.receive(opened(lsn: 9, catchUp: paged(900, upTo: 9, full: true)))
        let s1 = try XCTUnwrap(f.connection.starts().last?["stream"]?.stringValue)
        await f.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "stream": .string(s1), "rows": [row("r1")], "gone": [],
            "lsn": 9, "next": at(1),
        ])
        // Released after a page of the stream: no request is out, so the open goes at once.
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        XCTAssertEqual(f.connection.all("record.open").count, 3)
        await f.session.receive(opened(lsn: 9, catchUp: paged(900, upTo: 9, full: true)))
        let s2 = try XCTUnwrap(f.connection.starts().last?["stream"]?.stringValue)
        XCTAssertNotEqual(s1, s2)
        await f.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "stream": .string(s1), "rows": [row("r2")], "gone": [], "lsn": 9])
        XCTAssertEqual(f.synced.value, 1, "s1's last page completes nothing")
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 4)
        await f.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "stream": .string(s2), "rows": [row("r1")], "gone": [],
            "lsn": 9, "next": at(1),
        ])
        await f.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "stream": .string(s2), "rows": [row("r2")], "gone": [], "lsn": 9])
        XCTAssertEqual(f.synced.value, 2)
        XCTAssertTrue(try read(f, "r1"))
        XCTAssertTrue(try read(f, "r2"))
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 9)
    }

    func testAPushedRestartAndAStartDuringAStalledStreamOpenAgain() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 9, catchUp: paged(9, upTo: 9)))
        let s1 = try XCTUnwrap(f.connection.starts().last?["stream"]?.stringValue)
        for page in pages(s1, 9).prefix(4) { await f.session.receive(page) }
        // The room was evicted: the watchdog's retry starts the open again.
        await f.session.start()
        XCTAssertEqual(f.connection.all("record.open").count, 2)
        await f.session.receive(opened(lsn: 9, catchUp: paged(9, upTo: 9)))
        let s2 = try XCTUnwrap(f.connection.starts().last?["stream"]?.stringValue)
        await f.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "stream": .string(s2), "restart": true])
        XCTAssertEqual(f.connection.all("record.open").count, 3)
        await f.session.receive(opened(lsn: 9, catchUp: .object(["mode": "inline", "rows": [row("r1")], "gone": [], "lsn": 9, "upTo": 9])))
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 9)
    }

    func testAFailedFirstPageDeliveryOpensAgainAtOnceWhenTheRoomSaidItStreams() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 9, catchUp: paged(9, upTo: 9), streams: true))
        let s1 = try XCTUnwrap(f.connection.starts().last?["stream"]?.stringValue)
        // The delivery carrying the first page failed: the notice is all that comes.
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        XCTAssertEqual(f.connection.all("record.open").count, 2)
        await f.session.receive(opened(lsn: 9, catchUp: paged(9, upTo: 9), streams: true))
        let s2 = try XCTUnwrap(f.connection.starts().last?["stream"]?.stringValue)
        await f.session.receive(pages(s1, 9)[0])
        for page in pages(s2, 9) { await f.session.receive(page) }
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 9)
        let stalePages = await f.session.streamCounters.stalePages
        XCTAssertEqual(stalePages, 1)

        // The watchdog's retry before any page of a stream also opens at once.
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        await f.session.receive(opened(lsn: 12, catchUp: paged(3, upTo: 12), streams: true))
        await f.session.start()
        XCTAssertEqual(f.connection.all("record.open").count, 4)
    }

    func testARoomNotKnownToStreamIsWaitedOnForTheUnmarkedPageItOwes() async throws {
        let f = try await makeFixture()
        await f.session.start()
        await f.session.receive(opened(lsn: 9, catchUp: paged(2, upTo: 9, full: true)))
        XCTAssertEqual(f.connection.starts().count, 1)
        // The open's watchdog retries before the older room's first page arrives: the page is still owed.
        await f.session.start()
        XCTAssertEqual(f.connection.all("record.open").count, 1)
        await f.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("r1")], "gone": [], "lsn": 9, "next": at(1),
        ])
        XCTAssertEqual(f.connection.starts().last?["after"], at(1))
        XCTAssertNil(f.connection.starts().last?["stream"])
        await f.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("r2")], "gone": [], "lsn": 9])
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertTrue(try read(f, "r1"))
        XCTAssertTrue(try read(f, "r2"))
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 9)

        // Released before an older room's first page: that page is waited for, then the open goes again.
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        await f.session.receive(opened(lsn: 12, catchUp: paged(2, upTo: 12, full: true)))
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        XCTAssertEqual(f.connection.all("record.open").count, 2)
        await f.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("r3")], "gone": [], "lsn": 12, "next": at(1),
        ])
        XCTAssertEqual(f.connection.all("record.open").count, 3)
        XCTAssertFalse(try read(f, "r3"))
    }

    func testBuildingReportsProgressAndOpensAgainAfterRetryMs() async throws {
        let f = try await makeFixture()
        await f.session.start()
        XCTAssertEqual(f.connection.all("record.open").first?["accepts"], ["load", "segment", "building"])
        let progressed = f.progress.value
        await f.session.receive(opened(lsn: 7_000, catchUp: .object(["mode": "building", "segmentId": "G1", "retryMs": 20])))
        XCTAssertEqual(f.progress.value, progressed + 1)
        XCTAssertEqual(f.synced.value, 0)
        XCTAssertEqual(f.connection.all("record.open").count, 1)
        await eventually("the open goes again") { f.connection.all("record.open").count == 2 }
        XCTAssertEqual(f.connection.all("record.open")[1]["accepts"], ["load", "segment", "building"])
        await f.session.receive(opened(lsn: 7_001, catchUp: .object(["mode": "inline", "rows": [row("r1")], "gone": [], "lsn": 7_001, "upTo": 7_001])))
        XCTAssertEqual(f.synced.value, 1)
        XCTAssertEqual(try f.binding.refreshMarks().cursor, 7_001)
    }

    func testPastTheWaitsCapTheOpenNoLongerDeclaresBuilding() async throws {
        let f = try await makeFixture(buildingMaxWaitMs: 80)
        await f.session.start()
        await f.session.receive(opened(lsn: 7_000, catchUp: .object(["mode": "building", "segmentId": "G1", "retryMs": 5])))
        await eventually("the second open") { f.connection.all("record.open").count == 2 }
        XCTAssertEqual(f.connection.all("record.open")[1]["accepts"], ["load", "segment", "building"])
        try await Task.sleep(nanoseconds: 120_000_000)
        await f.session.receive(opened(lsn: 7_000, catchUp: .object(["mode": "building", "segmentId": "G1", "retryMs": 5])))
        await eventually("the third open") { f.connection.all("record.open").count == 3 }
        XCTAssertEqual(f.connection.all("record.open")[2]["accepts"], ["load", "segment"])
        await f.session.receive(opened(lsn: 7_000, catchUp: .object(["mode": "inline", "rows": [], "gone": [], "lsn": 7_000, "upTo": 7_000])))
        XCTAssertEqual(f.synced.value, 1)
        await f.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        XCTAssertEqual(f.connection.all("record.open")[3]["accepts"], ["load", "segment", "building"], "the next open declares it again")
    }
}
