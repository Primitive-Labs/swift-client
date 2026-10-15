import XCTest
@testable import JsBaoClient

/// A Swift client that holds a segment moves to the next one without
/// downloading the chunks it already holds, against the dev server (#4394
/// behavior 23): the Swift twin of js-bao's
/// `record-log-segment-incremental-4394.test.ts`.
///
/// The client receives S1 as a segment (its cursor below the floor). While it
/// is offline one bucket changes (a patch and a delete in one range) and a
/// record is created past the last id, so S2 reuses S1's three other chunks
/// and writes the rewritten range and a tail chunk; a record of a reused range
/// is patched after S2 completes. Pointed at S2, the client fetches only S2's
/// two own chunks and its corrections, equals the room, and its marks name S2.
final class RecordLogSegmentIncrementalLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-segment-incremental")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Export a segment to completion under the pinned clock; answers its view.
    private func exportSegment(_ load: RecordLogLoadDriver) async throws -> [String: Any] {
        let started = try await load.request("POST", "/snapshots", body: [:])
        XCTAssertEqual(started.status, 201, "\(started.json)")
        let segmentId = try XCTUnwrap(started.json["segmentId"] as? String)
        for _ in 0..<10 {
            try await load.test("run-alarm")
            let view = try await load.request("GET", "/snapshots/\(segmentId)")
            if view.json["state"] as? String == "complete" { return view.json }
        }
        throw JsBaoError(code: .unavailable, message: "segment \(segmentId) did not complete")
    }

    func testHoldingS1ItFetchesOnlyS2sRewrittenAndTailChunksAndItsCorrectionsAndEqualsTheRoom() async throws {
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        await x.goOffline()
        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let ids = recordLogIds(40, prefix: "s")
        let seeded = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: ids.map { ($0, ["title": .string("seeded \($0)")]) })])
        try await load.until(try XCTUnwrap(seeded["sessionId"] as? String)) { ($0["state"] as? String) == "complete" }
        try await load.test("set-clock", ["nowMs": Int(Date().timeIntervalSince1970 * 1000)])
        do {
            try await load.test("set-limits", ["segmentChunkRows": 10, "segmentChunksPerAlarm": 10])
            // S1: four chunks of ten rows. The client, below the floor, receives it as a segment.
            let s1 = try await exportSegment(load)
            XCTAssertEqual((s1["chunks"] as? NSNumber)?.intValue, 4)
            let s1Id = try XCTUnwrap(s1["segmentId"] as? String)
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": s1["lsn"] ?? 0, "keepWriters": true])
            let first = RecordLogClientWatch(x)
            await x.goOnline()
            let openedS1 = try await eventuallyValue(timeout: 30, description: "record.opened for S1") {
                first.received("record.opened").first?.frame
            }
            XCTAssertEqual(openedS1["catchUp"]?["mode"], "segment")
            XCTAssertEqual(openedS1["catchUp"]?["segment"]?["segmentId"]?.stringValue, s1Id)
            try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
            try await eventually(timeout: 30, description: "the client to hold S1") {
                try self.live.marks(x, documentId).segment?.segmentId == s1Id
            }
            XCTAssertEqual(try live.marks(x, documentId).segment?.chunks.count, 4)
            await x.goOffline()

            // One bucket changes, and a record lands past the last id: S2 reuses the other three chunks.
            let patched = try await load.save("Note", ids[11], ["title": "patched before S2"])
            XCTAssertEqual(patched, 200)
            let removed = try await load.remove("Note", ids[12])
            XCTAssertEqual(removed, 200)
            let created = try await load.save("Note", "z-new", ["title": "created past the last id"])
            XCTAssertEqual(created, 200)
            let s2 = try await exportSegment(load)
            let s2Id = try XCTUnwrap(s2["segmentId"] as? String)
            XCTAssertEqual((s2["basedOn"] as? [String: Any])?["segmentId"] as? String, s1Id)
            XCTAssertEqual((s2["reused"] as? NSNumber)?.intValue, 3)
            XCTAssertEqual((s2["written"] as? NSNumber)?.intValue, 2)
            // After S2 completed, a record of a reused range changes: the pages from C carry it.
            let after = try await load.save("Note", ids[24], ["title": "patched after C"])
            XCTAssertEqual(after, 200)
            try await load.test("set-limits", ["catchUpPointerRows": 2])

            let watch = RecordLogClientWatch(x)
            await x.goOnline()
            let opened = try await eventuallyValue(timeout: 30, description: "record.opened for S2") {
                watch.received("record.opened").first?.frame
            }
            XCTAssertEqual(opened["catchUp"]?["mode"], "segment")
            let pointer = try XCTUnwrap(opened["catchUp"]?["segment"])
            XCTAssertEqual(pointer["segmentId"]?.stringValue, s2Id)
            let chunks = pointer["chunks"]?.arrayValue ?? []
            XCTAssertEqual(chunks.filter { $0["source"]?["segmentId"]?.stringValue == s1Id }.count, 3)
            try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 60)
            try await eventually(timeout: 30, description: "the client to hold S2") {
                try self.live.marks(x, documentId).segment?.segmentId == s2Id
            }
            let grant = try XCTUnwrap(pointer["download"]?["path"]?.stringValue)
            XCTAssertEqual(watch.fetched.map { $0.path.hasPrefix("\(grant)/") ? String($0.path.dropFirst(grant.count + 1)) : $0.path }, [
                "Note/0", "Note/1", "corrections",
            ])
            XCTAssertEqual(watch.fetched.map(\.status), [200, 200, 200])
            let held = try XCTUnwrap(try live.marks(x, documentId).segment)
            XCTAssertEqual(held.chunks.map(\.object), chunks.map { chunk in
                "\(chunk["source"]?["segmentId"]?.stringValue ?? s2Id)/\(chunk["model"]?.stringValue ?? "")/\(chunk["index"]?.wholeNumber ?? -1)"
            })
            XCTAssertNil(try live.marks(x, documentId).receipt)
            try await load.test("set-clock", ["nowMs": NSNull()])
        } catch {
            _ = try? await load.test("set-clock", ["nowMs": NSNull()])
            throw error
        }
    }
}
