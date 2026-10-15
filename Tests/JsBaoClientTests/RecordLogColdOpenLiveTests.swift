import XCTest
@testable import JsBaoClient

/// #4556 behavior 20 — a Swift client's cold open of a format-3 document,
/// against the dev server: the Swift twin of js-bao's
/// `record-log-cold-open-4556.test.ts`.
///
/// A 3,000-row document is streamed after one `record.catchUp` start, every
/// page marked with its id and at most two credits; a 7,000-row document with
/// no segment is answered `building`, then `segment` naming the segment built
/// for it; a delivery that fails mid stream releases the subscription, and the
/// client opens again at once. Each ends with the room's rows. The rows are
/// written through the room's `submit` test route, and the documents' change
/// checks are held off so that no segment built for change races the opens.
final class RecordLogColdOpenLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-cold-open-4556")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// A random 26-character Crockford ULID.
    private static func ulid() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return "01" + String((0..<24).map { _ in alphabet[Int.random(in: 0..<32)] })
    }

    /// A document of `rows` notes written through the room's `submit` route, with `limits` set on the room.
    private func written(_ rows: Int, limits: [String: Any] = [:]) async throws -> String {
        let creator = try await live.client("creator", models: [Self.note])
        let documentId = try await live.createDocument(creator)
        try await write(documentId, rows, limits: limits)
        return documentId
    }

    /// Write `rows` notes to `documentId` through the room's `submit` route, with `limits` set on the room.
    private func write(_ documentId: String, _ rows: Int, limits: [String: Any] = [:]) async throws {
        var all: [String: Any] = ["segmentQuietMs": 3_600_000]
        for (key, value) in limits { all[key] = value }
        _ = try await live.route(documentId, "set-limits", all)
        let writer = Self.ulid()
        var seq = 0
        var at = 1
        while at <= rows {
            let count = min(500, rows - at + 1)
            let mutations: [[String: Any]] = (at..<(at + count)).map { n in
                ["model": "Note", "id": String(format: "c%06d", n), "kind": "create", "fields": ["title": "row \(n)"]]
            }
            let state = try await live.route(documentId, "state")
            let epochs = state["epochs"] as? [String: Any] ?? [:]
            seq += 1
            let answered = try await live.route(documentId, "submit", [
                "writer": writer,
                "entry": [
                    "seq": seq, "e": (epochs["current"] as? NSNumber)?.intValue ?? 1, "k": (state["lsn"] as? NSNumber)?.intValue ?? 0,
                    "m": mutations[0], "also": Array(mutations.dropFirst()),
                ] as [String: Any],
            ])
            XCTAssertEqual((answered["outcome"] as? [String: Any])?["status"] as? String, "accepted")
            at += count
        }
    }

    private func pages(_ watch: RecordLogClientWatch, _ documentId: String) -> [[String: JSONValue]] {
        watch.received("record.catchUpPage").map(\.frame).filter { $0["documentId"]?.stringValue == documentId }
    }

    func testA3000RowColdOpenIsStreamedAfterOneStartWithAtMostTwoCredits() async throws {
        let documentId = try await written(3_000)
        let x = try await live.client("x", models: [Self.note])
        let watch = RecordLogClientWatch(x)
        let startedAt = Date()
        try await live.open(x, documentId)
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
        print("[#4556] Swift 3,000-row cold open, streamed: \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
        let asked = watch.sent("record.catchUp").filter { $0["documentId"]?.stringValue == documentId }
        let starts = asked.filter { $0["credit"] == nil }
        let credits = asked.filter { $0["credit"] != nil }
        XCTAssertEqual(starts.count, 1, "\(starts)")
        let stream = try XCTUnwrap(starts.first?["stream"]?.stringValue)
        let received = pages(watch, documentId)
        XCTAssertEqual(received.count, 6)
        XCTAssertTrue(received.allSatisfy { $0["stream"]?.stringValue == stream })
        XCTAssertNil(received.last?["next"])
        XCTAssertLessThanOrEqual(credits.count, 2)
        XCTAssertTrue(credits.allSatisfy { $0["stream"]?.stringValue == stream })
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "the cursor to reach the room's log number") {
            try self.live.marks(x, documentId).cursor == lsn
        }
    }

    func testA7000RowColdOpenWaitsForASegmentBuiltForItThenReceivesIt() async throws {
        let documentId = try await written(7_000)
        let x = try await live.client("x", models: [Self.note])
        let watch = RecordLogClientWatch(x)
        let startedAt = Date()
        try await live.open(x, documentId)
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
        print("[#4556] Swift 7,000-row cold open, segment built on demand: \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
        let opened = watch.received("record.opened").map(\.frame).filter { $0["documentId"]?.stringValue == documentId }
        let building = try XCTUnwrap(opened.firstIndex { $0["catchUp"]?["mode"]?.stringValue == "building" }, "\(opened.map { $0["catchUp"]?["mode"] })")
        let served = try XCTUnwrap(opened.firstIndex { $0["catchUp"]?["mode"]?.stringValue == "segment" })
        XCTAssertGreaterThan(served, building)
        XCTAssertEqual(opened[served]["catchUp"]?["segment"]?["segmentId"], opened[building]["catchUp"]?["segmentId"])
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "the cursor to reach the room's log number") {
            try self.live.marks(x, documentId).cursor == lsn
        }
        XCTAssertNil(try live.marks(x, documentId).receipt)
    }

    func testADeliveryThatFailsMidStreamReleasesAndTheClientOpensAgainAtOnce() async throws {
        // x holds the empty document and goes offline; 4,000 rows are written meanwhile: 200 pages of 20,
        // one frame a delivery, so the stream is still running when the failure is armed.
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        await x.goOffline()
        try await write(documentId, 4_000, limits: ["catchUpPageRows": 20, "deliveryBytes": 1])
        let watch = RecordLogClientWatch(x)
        await x.goOnline()
        try await eventually(timeout: 30, description: "the stream's first page") {
            self.pages(watch, documentId).contains { $0["stream"] != nil }
        }
        let state = try await live.route(documentId, "state")
        let subscribers = state["subscribers"] as? [[String: Any]] ?? []
        let connectionId = try XCTUnwrap(subscribers.first?["connectionId"] as? String)
        _ = try await live.route(documentId, "fail-delivery", ["connectionId": connectionId])
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
        let released = watch.received("record.released").filter { $0.frame["documentId"]?.stringValue == documentId }
        XCTAssertFalse(released.isEmpty, "the room released the subscription")
        let failed = (try await live.route(documentId, "state")["counters"] as? [String: Any])?["deliveriesFailed"] as? NSNumber
        XCTAssertGreaterThanOrEqual(failed?.intValue ?? 0, 1)
        XCTAssertGreaterThanOrEqual(watch.sent("record.open").filter { $0["documentId"]?.stringValue == documentId }.count, 2)
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "the cursor to reach the room's log number") {
            try self.live.marks(x, documentId).cursor == lsn
        }
    }
}
