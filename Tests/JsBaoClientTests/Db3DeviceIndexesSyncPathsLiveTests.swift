import XCTest
@testable import JsBaoClient

/// #5223 behavior 22 — a synced db3's device text index and device member
/// table stay equal to the rows the device holds across every sync path,
/// live against the dev server: the Swift twin of js-bao's
/// `db3-device-indexes-sync-paths-5222.test.ts`. After a 5,000-row merge
/// load, a refresh load, a segment received after an offline spell with a
/// pending create (the staged replacement), and an incremental segment with
/// corrections, the oracle on a copy of the store file finds no drift, the
/// client's rows equal the room's, and `$search` and `$contains` answer the
/// rows the room holds.
final class Db3DeviceIndexesSyncPathsLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "tags": FieldDescriptor(type: .stringset),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-device-sync-paths-5223")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static func words(_ text: Any?) -> [String] {
        ((text as? String) ?? "").lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    /// Export a segment to completion under the pinned clock, running `between` once it started; answers its view.
    private func exportSegment(_ load: RecordLogLoadDriver, between: (() async throws -> Void)? = nil) async throws -> [String: Any] {
        let started = try await load.request("POST", "/snapshots", body: [:])
        XCTAssertEqual(started.status, 201, "\(started.json)")
        let segmentId = try XCTUnwrap(started.json["segmentId"] as? String)
        try await load.test("run-alarm")
        try await between?()
        for _ in 0..<40 {
            try await load.test("run-alarm")
            let view = try await load.request("GET", "/snapshots/\(segmentId)")
            if view.json["state"] as? String == "complete" { return view.json }
        }
        throw JsBaoError(code: .unavailable, message: "segment \(segmentId) did not complete")
    }

    /// Save a record over HTTP, as another device would.
    private func saved(_ load: RecordLogLoadDriver, _ id: String, _ data: [String: Any]) async throws {
        let status = try await load.save("Note", id, data)
        XCTAssertEqual(status, 200, "save \(id)")
    }

    /// Delete a record over HTTP, as another device would.
    private func removed(_ load: RecordLogLoadDriver, _ id: String) async throws {
        let status = try await load.remove("Note", id)
        XCTAssertEqual(status, 200, "delete \(id)")
    }

    private func lines(_ ids: ArraySlice<String>, _ tag: String) -> [(String, [String: JSONValue])] {
        ids.enumerated().map { i, id in (id, ["title": .string("\(tag) w\(i % 10) \(id)"), "tags": [.string("t\(i % 5)")]]) }
    }

    func testTheDeviceIndexesEqualARebuildAfterEverySyncPath() async throws {
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        _ = try await x.db3.indexes.register(documentId, Db3IndexRegistration(model: "Note", field: "title", kind: .text, on: .device))
        _ = try await x.db3.indexes.register(documentId, Db3IndexRegistration(model: "Note", field: "tags", kind: .members, on: .device))
        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let notes = x.sharedModel(for: Self.note)

        func check(_ label: String) async throws {
            try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 90)
            let drift = try await Db3DeviceIndexOracle.driftOnACopy(live.binding(x, documentId).store)
            XCTAssertEqual(drift, [], label)
            let room = try await live.roomTable(documentId, "Note")
            for word in ["w3", "pending"] {
                let expected = room.filter { Self.words($0.value["title"]?.stringValue).contains(word) }.map(\.key).sorted()
                let found = try notes.query(["$search": .string(word)], options: QueryOptions(limit: 10_000)).compactMap { $0["id"]?.stringValue }
                XCTAssertEqual(found.sorted(), expected, "\(label): $search \(word)")
            }
            let tagged = room.values.filter { $0["tags"]?.arrayValue?.contains("t2") == true }.count
            XCTAssertEqual(try notes.count(["tags": ["$contains": "t2"]]), tagged, "\(label): $contains")
        }

        // 1. A 5,000-row bulk load, merged.
        let all = recordLogIds(5_000, prefix: "n")
        _ = try await load.test("set-limits", ["loadTickRows": 2_500, "loadTxnRows": 1_250])
        let merged = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: lines(all[0..<2_500], "merged")),
            RecordLogLoadChunk(model: "Note", index: 1, lines: lines(all[2_500...], "merged")),
        ])
        _ = try await load.until(try XCTUnwrap(merged["sessionId"] as? String), timeout: 180) { ($0["state"] as? String) == "complete" }
        try await check("merge load")

        // 2. A refresh of the first 300: every other row of the model goes.
        let refreshed = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: lines(all[0..<300], "refreshed"))], body: ["mode": "refresh"])
        _ = try await load.until(try XCTUnwrap(refreshed["sessionId"] as? String), timeout: 120) { ($0["state"] as? String) == "complete" }
        try await check("refresh load")

        // 3. Offline with a pending create, the room segmented and its floor raised: a staged replacement on reconnect.
        _ = try await load.test("set-clock", ["nowMs": Int(Date().timeIntervalSince1970 * 1000)])
        do {
            _ = try await load.test("set-limits", ["segmentChunkRows": 50, "segmentChunksPerAlarm": 2])
            await x.goOffline()
            try x.codegen.save(Self.note, id: "x-pending", values: ["title": .string("pending w3 create"), "tags": .stringset(["t2"])], in: documentId)
            try await saved(load, all[5], ["title": "changed w3 while offline", "tags": ["t2"]])
            try await removed(load, all[6])
            let s1 = try await exportSegment(load)
            let s1Id = try XCTUnwrap(s1["segmentId"] as? String)
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": s1["lsn"] ?? 0, "keepWriters": true])
            let watch = RecordLogClientWatch(x)
            await x.goOnline()
            let opened = try await eventuallyValue(timeout: 30, description: "record.opened for S1") { watch.received("record.opened").first?.frame }
            XCTAssertEqual(opened["catchUp"]?["mode"], "segment")
            try await eventually(timeout: 90, description: "the client to hold S1") { try self.live.marks(x, documentId).segment?.segmentId == s1Id }
            try await check("segment over a pending create")
            // The pending create went out after the floor was raised and the room refused it: its guess left the view and the index.
            XCTAssertEqual(try notes.query(["$search": "pending"]), [])

            // 4. An incremental segment with corrections, received after another offline spell.
            await x.goOffline()
            try await saved(load, all[11], ["title": "patched w3 before S2", "tags": ["t2"]])
            try await removed(load, all[12])
            try await saved(load, "z-new", ["title": "created w3 past the last id", "tags": ["t2"]])
            let s2 = try await exportSegment(load) {
                // Written while the export runs: the segment's corrections carry them.
                try await self.saved(load, all[20], ["title": "corrected w3 during S2", "tags": ["t2"]])
                try await self.removed(load, all[21])
            }
            let s2Id = try XCTUnwrap(s2["segmentId"] as? String)
            XCTAssertEqual((s2["basedOn"] as? [String: Any])?["segmentId"] as? String, s1Id)
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": s2["lsn"] ?? 0, "keepWriters": true])
            let watch2 = RecordLogClientWatch(x)
            await x.goOnline()
            let opened2 = try await eventuallyValue(timeout: 30, description: "record.opened for S2") { watch2.received("record.opened").first?.frame }
            XCTAssertEqual(opened2["catchUp"]?["mode"], "segment")
            try await eventually(timeout: 90, description: "the client to hold S2") { try self.live.marks(x, documentId).segment?.segmentId == s2Id }
            try await check("incremental segment with corrections")
            _ = try await load.test("set-clock", ["nowMs": NSNull()])
        } catch {
            _ = try? await load.test("set-clock", ["nowMs": NSNull()])
            throw error
        }
    }
}
