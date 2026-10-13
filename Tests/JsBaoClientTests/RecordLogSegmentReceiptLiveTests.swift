import XCTest
@testable import JsBaoClient

/// A Swift client receives the room's checkpoint segment on reconnect,
/// against the dev server: the Swift twin of js-bao's
/// `record-log-segment-receipt-4311.test.ts`.
///
/// A client whose cursor is below the cursor floor, or whose changed rows
/// exceed the pointer bound, is answered the `segment` form: it replaces its
/// table with the segment's chunks, applies the corrections (a row patched
/// after `B`, a record deleted after `B`), pages what changed after `C`, and
/// equals the room; its own unjudged create keeps its guess through the
/// receipt and is resubmitted after — handed back
/// `DOCUMENT_OFFLINE_WINDOW_EXPIRED` when written below the floor, accepted
/// when above it.
final class RecordLogSegmentReceiptLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-segment-receipt")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Give `documentId` a complete segment whose corrections are not empty (a
    /// row patched and one deleted after it began), then writes after it: rows
    /// through a load, the export through `POST …/snapshots`, its ticks through
    /// `run-alarm` under a pinned clock. Answers the segment's `B` and `C`.
    private func segmented(_ documentId: String) async throws -> (B: Int, C: Int, ids: [String]) {
        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let ids = recordLogIds(40, prefix: "s")
        let seeded = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: ids.map { ($0, ["title": .string("seeded \($0)")]) })])
        try await load.until(try XCTUnwrap(seeded["sessionId"] as? String)) { ($0["state"] as? String) == "complete" }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try await load.test("set-clock", ["nowMs": now])
        do {
            try await load.test("set-limits", ["segmentChunkRows": 15, "segmentChunksPerAlarm": 1])
            let started = try await load.request("POST", "/snapshots", body: [:])
            XCTAssertEqual(started.status, 201, "\(started.json)")
            let segmentId = try XCTUnwrap(started.json["segmentId"] as? String)
            try await load.test("run-alarm")
            let status1 = try await load.save("Note", ids[0], ["title": "after B"])
            XCTAssertEqual(status1, 200)
            let status2 = try await load.remove("Note", ids[ids.count - 1])
            XCTAssertEqual(status2, 200)
            for _ in 0..<8 { try await load.test("run-alarm") }
            let done = try await load.request("GET", "/snapshots/\(segmentId)")
            XCTAssertEqual(done.json["state"] as? String, "complete", "\(done.json)")
            // After C: a patch, a delete, a create.
            let status3 = try await load.save("Note", ids[1], ["title": "after C"])
            XCTAssertEqual(status3, 200)
            let status4 = try await load.remove("Note", ids[2])
            XCTAssertEqual(status4, 200)
            let status5 = try await load.save("Note", "z-after-c", ["title": "created after C"])
            XCTAssertEqual(status5, 200)
            try await load.test("set-clock", ["nowMs": NSNull()])
            return (
                (done.json["lsn"] as? NSNumber)?.intValue ?? -1, (done.json["completedLsn"] as? NSNumber)?.intValue ?? -1, ids
            )
        } catch {
            _ = try? await load.test("set-clock", ["nowMs": NSNull()])
            throw error
        }
    }

    func testACursorBelowTheFloorTakesTheSegmentItsCorrectionsAndThePagesAfterCAndAnOwnCreateIsHandedBack() async throws {
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        await x.goOffline()
        // x's own create, not yet sent: written below the floor the checkpoint raises.
        _ = try live.member(x, documentId, "Note").create(id: "x-mine", values: ["title": .string("pending create")])
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = x.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in refusals.withValue { $0.append(event) } }
        defer { subscription.cancel() }
        let (B, C, ids) = try await segmented(documentId)
        _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": B, "keepWriters": true])
        let watch = RecordLogClientWatch(x)
        // Its guess stays on the view while the segment replaces the table.
        let held = watch.holdNext { $0.hasSuffix("/corrections") }
        await x.goOnline()
        await held.reached.wait()
        XCTAssertEqual(try live.localRows(x, documentId, "Note")["x-mine"]?["title"], "pending create")
        held.release.open()
        let opened = try await eventuallyValue(timeout: 30, description: "record.opened") { watch.received("record.opened").first?.frame }
        XCTAssertEqual(opened["catchUp"]?["mode"], "segment")
        XCTAssertEqual(opened["catchUp"]?["segment"]?["lsn"]?.wholeNumber, B)
        XCTAssertEqual(opened["catchUp"]?["segment"]?["completedLsn"]?.wholeNumber, C)
        XCTAssertGreaterThanOrEqual(opened["catchUp"]?["segment"]?["corrections"]?["rows"]?.wholeNumber ?? 0, 2)
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
        let local = try live.localRows(x, documentId, "Note")
        XCTAssertEqual(local[ids[0]]?["title"], "after B")
        XCTAssertNil(local[ids[ids.count - 1]])
        XCTAssertEqual(local[ids[1]]?["title"], "after C")
        XCTAssertNil(local[ids[2]])
        XCTAssertEqual(local["z-after-c"]?["title"], "created after C")
        // Resubmitted after the receipt, and refused: it was written below the floor.
        let refused = try await eventuallyValue(timeout: 30, description: "x-mine to be handed back") {
            refusals.value.first { $0.writes?.contains { $0.recordId == "x-mine" } == true }
        }
        XCTAssertEqual(refused.error.code, .documentOfflineWindowExpired)
        XCTAssertNil(try live.localRows(x, documentId, "Note")["x-mine"])
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "x's cursor to reach the room's log number") {
            try self.live.marks(x, documentId).cursor >= lsn
        }
        XCTAssertNil(try live.marks(x, documentId).receipt)
    }

    func testChangedRowsPastThePointerBoundTakeTheSegmentTooAndAnOwnCreateAboveTheFloorIsAccepted() async throws {
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        await x.goOffline()
        _ = try live.member(x, documentId, "Note").create(id: "x-mine", values: ["title": .string("pending create")])
        _ = try await segmented(documentId)
        _ = try await live.route(documentId, "set-limits", ["catchUpPointerRows": 2])
        let watch = RecordLogClientWatch(x)
        await x.goOnline()
        let opened = try await eventuallyValue(timeout: 30, description: "record.opened") { watch.received("record.opened").first?.frame }
        XCTAssertEqual(opened["catchUp"]?["mode"], "segment")
        try await live.settled(x, documentId)
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
        // Its own create, above the floor, was resubmitted after the receipt and accepted.
        let room = try await live.roomTable(documentId, "Note")
        XCTAssertEqual(room["x-mine"]?["title"], "pending create")
        XCTAssertNil(try live.marks(x, documentId).receipt)
    }
}
