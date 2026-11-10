import XCTest
@testable import JsBaoClient

/// #5230 behaviors 31 and 32 (criterion 7) — a synced db3's device vector
/// indexes stay equal to the rows the device holds across every sync path
/// and a restart, live against the dev server, on the vehicle of #5223's
/// `Db3DeviceIndexesSyncPathsLiveTests`: an `ann` cos index (its model
/// trained and installed by the device) and an exact l2 index over 4,000
/// rows. After a merge load, a refresh load, a segment received over a
/// pending create (the staged replacement) and an incremental segment with
/// corrections, each re-embedding a tenth of the rows so the ANN table's
/// vectors must change under kept rowids, the oracle on a copy of the store
/// finds no drift in either flat table or the ANN table, rowids and vector
/// bytes alike (F-5230-003), the client's rows equal the room's, and `$near`
/// from the room's own rows equals brute force over them (exact to equality,
/// ann to a mean recall at least 0.8, the row itself first). A store planted at version 8 converts and builds; a
/// restarted client rebuilds nothing and takes the writes made meanwhile.
final class Db3DeviceVectorSyncPathsLiveTests: XCTestCase {

    private typealias Support = Db3VectorTestSupport

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let dims = 16
    private static let encoding = VectorEncoding(dims: dims, element: .f32)
    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "embedding": FieldDescriptor(type: .vector, dims: dims, element: .f32),
        "other": FieldDescriptor(type: .vector, dims: dims, element: .f32),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-vector-sync-paths-5230")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Declare Note as a device's open declares it, so the room knows both vector fields before they are registered.
    private func declare(_ documentId: String) async throws {
        let vector: [String: Any] = ["type": "vector", "dims": Self.dims, "element": "f32"]
        _ = try await live.route(documentId, "declare", [
            "model": "Note", "declaration": ["fields": ["title": ["type": "string"], "embedding": vector, "other": vector]],
        ])
    }

    private static func stored(_ vector: [Float]) -> String { (try? VectorCodec.encode(vector, encoding: encoding)) ?? "" }

    /// Load lines for `ids`, each with an embedding (seeded by `seed`) in both vector fields.
    private func lines(_ ids: ArraySlice<String>, _ tag: String, seed: UInt32) -> [(String, [String: JSONValue])] {
        let vectors = Support.clusteredVectors(ids.count, Self.dims, clusters: 20, seed: seed)
        return ids.enumerated().map { i, id in
            (id, ["title": .string("\(tag) \(id)"), "embedding": .string(Self.stored(vectors[i])), "other": .string(Self.stored(vectors[i]))])
        }
    }

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

    private static func save(_ load: RecordLogLoadDriver, _ id: String, seed: UInt32) async throws {
        let vector = Support.clusteredVectors(1, dims, clusters: 1, seed: seed)[0]
        let status = try await load.save("Note", id, ["title": "saved \(id)", "embedding": stored(vector), "other": stored(vector)])
        XCTAssertEqual(status, 200, "save \(id)")
    }

    private func save(_ load: RecordLogLoadDriver, _ id: String, seed: UInt32) async throws {
        try await Self.save(load, id, seed: seed)
    }

    /// Save each of `ids` (the `n`th with seed `seed + n`), eight requests at a time.
    private func saveAll(_ load: RecordLogLoadDriver, _ ids: ArraySlice<String>, seed: UInt32) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (offset, id) in ids.enumerated() {
                if offset >= 8 { try await group.next() }
                group.addTask { try await Self.save(load, id, seed: seed + UInt32(offset)) }
            }
            try await group.waitForAll()
        }
    }

    /// The client's rows equal the room's, vectors decoded; every flat table and the installed ANN table equal them; and
    /// `$near` from each of a few of the room's own rows answers as brute force over the room's rows.
    private func check(_ x: JsBaoClient, _ documentId: String, _ label: String) async throws {
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 120)
        let room = try await live.roomTable(documentId, "Note")
        let local = try live.localRows(x, documentId, "Note")
        var rows: [(id: String, vector: [Float])] = []
        for (id, row) in room {
            guard let text = row["embedding"]?.stringValue, let vector = try? VectorCodec.decode(text, encoding: Self.encoding) else { continue }
            let mine = local[id]?["embedding"]?.arrayValue?.compactMap { $0.numberValue.map(Float.init) }
            XCTAssertEqual(mine, vector, "\(label): \(id)'s embedding")
            rows.append((id, vector))
        }
        // A fill under way is not yet the ANN table's: the oracle reads it once filled.
        try await eventually(timeout: 120, description: "\(label): the ann index on its model") {
            (try? await x.db3.indexes.local(documentId))?.first { $0.fields == ["embedding"] }?.mode == .ann
        }
        let store = try live.binding(x, documentId).store
        let drift = try await Db3DeviceIndexOracle.driftOnACopy(store)
        XCTAssertEqual(drift, [], label)
        let records = x.db3.records(documentId)
        let probes = rows.sorted { $0.id < $1.id }.enumerated().filter { $0.offset % 97 == 0 }.prefix(10).map(\.element)
        var recalls: [Double] = []
        for probe in probes {
            let vector = JSONValue.array(probe.vector.map { .number(Double($0)) })
            let exact = try records.query("Note", ["$near": ["field": "other", "vector": vector, "k": 10]]).data
            let reference = Support.bruteForce(rows, probe.vector, k: 10, distance: "l2")
            XCTAssertEqual(exact.compactMap { $0.raw["id"]?.stringValue }, reference.map(\.id), "\(label): exact \(probe.id)")
            let approximate = try records.query("Note", ["$near": ["field": "embedding", "vector": vector, "k": 10]]).data
            XCTAssertEqual(approximate.first?.raw["id"]?.stringValue, probe.id, "\(label): ann \(probe.id) first")
            let cosine = Set(Support.bruteForce(rows, probe.vector, k: 10).map(\.id))
            recalls.append(Double(Set(approximate.compactMap { $0.raw["id"]?.stringValue }).intersection(cosine).count) / 10)
        }
        // Recall is the probes' mean, as a measurement takes it: one probe near a bucket's edge answers fewer.
        XCTAssertGreaterThanOrEqual(recalls.reduce(0, +) / Double(max(1, recalls.count)), 0.8, "\(label): ann recall@10 \(recalls)")
    }

    func testTheVectorIndexesEqualARebuildAfterEverySyncPath() async throws {
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        try await declare(documentId)
        _ = try await x.db3.indexes.register(documentId, Db3IndexRegistration(
            model: "Note", field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(distance: .cos, index: .ann())
        ))
        _ = try await x.db3.indexes.register(documentId, Db3IndexRegistration(
            model: "Note", field: "other", kind: .vector, vector: Db3VectorIndexOptions(distance: .l2, index: .exact)
        ))
        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let all = recordLogIds(4_000, prefix: "n")

        // 1. A 4,000-row bulk load, merged: the device trains its model, installs and fills it.
        _ = try await load.test("set-limits", ["loadTickRows": 2_000, "loadTxnRows": 1_000])
        let merged = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: lines(all[0..<2_000], "merged", seed: 1)),
            RecordLogLoadChunk(model: "Note", index: 1, lines: lines(all[2_000...], "merged", seed: 2)),
        ])
        _ = try await load.until(try XCTUnwrap(merged["sessionId"] as? String), timeout: 180) { ($0["state"] as? String) == "complete" }
        try await eventually(timeout: 180, description: "the device on its own model") {
            (try? await x.db3.indexes.local(documentId))?.first { $0.fields == ["embedding"] }?.mode == .ann
        }
        try await check(x, documentId, "merge load")

        // 2. A refresh of the first 400, re-embedded: every other row of the model goes.
        let refreshed = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: lines(all[0..<400], "refreshed", seed: 3))], body: ["mode": "refresh"])
        _ = try await load.until(try XCTUnwrap(refreshed["sessionId"] as? String), timeout: 120) { ($0["state"] as? String) == "complete" }
        try await check(x, documentId, "refresh load")
        // A merge load back to 4,000, a tenth of the kept rows re-embedded.
        let regrown = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: lines(all[0..<40], "re-embedded", seed: 4)),
            RecordLogLoadChunk(model: "Note", index: 1, lines: lines(all[400...], "regrown", seed: 5)),
        ])
        _ = try await load.until(try XCTUnwrap(regrown["sessionId"] as? String), timeout: 180) { ($0["state"] as? String) == "complete" }
        try await check(x, documentId, "merge load re-embedding a tenth")

        // 3. Offline with a pending create, the room segmented and its floor raised: a staged replacement on reconnect.
        _ = try await load.test("set-clock", ["nowMs": Int(Date().timeIntervalSince1970 * 1000)])
        do {
            _ = try await load.test("set-limits", ["segmentChunkRows": 400, "segmentChunksPerAlarm": 4])
            await x.goOffline()
            let pending = Support.clusteredVectors(1, Self.dims, clusters: 1, seed: 6)[0]
            try x.codegen.save(Self.note, id: "x-pending", values: ["title": .string("pending"), "embedding": .vector(pending)], in: documentId)
            try await saveAll(load, all[1_000..<1_400], seed: 100)
            let s1 = try await exportSegment(load)
            let s1Id = try XCTUnwrap(s1["segmentId"] as? String)
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": s1["lsn"] ?? 0, "keepWriters": true])
            await x.goOnline()
            try await eventually(timeout: 120, description: "the client to hold S1") { try self.live.marks(x, documentId).segment?.segmentId == s1Id }
            try await check(x, documentId, "segment over a pending create")

            // 4. An incremental segment with corrections, received after another offline spell.
            await x.goOffline()
            try await saveAll(load, all[2_000..<2_400], seed: 900)
            _ = try await load.remove("Note", all[2_500])
            let s2 = try await exportSegment(load) {
                // Written while the export runs: the segment's corrections carry them.
                try await self.save(load, all[3_000], seed: 7)
                _ = try await load.remove("Note", all[3_001])
            }
            let s2Id = try XCTUnwrap(s2["segmentId"] as? String)
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": s2["lsn"] ?? 0, "keepWriters": true])
            await x.goOnline()
            try await eventually(timeout: 120, description: "the client to hold S2") { try self.live.marks(x, documentId).segment?.segmentId == s2Id }
            try await check(x, documentId, "incremental segment with corrections")
            _ = try await load.test("set-clock", ["nowMs": NSNull()])
        } catch {
            _ = try? await load.test("set-clock", ["nowMs": NSNull()])
            throw error
        }
    }

    func testAStoreConvertedFromVersion8BuildsAndARestartRebuildsNothing() async throws {
        let file = live.file("converted")
        let x = try await live.client("x", models: [Self.note], file: file)
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        try await declare(documentId)
        _ = try await x.db3.indexes.register(documentId, Db3IndexRegistration(
            model: "Note", field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(distance: .cos, index: .ann())
        ))
        _ = try await x.db3.indexes.register(documentId, Db3IndexRegistration(
            model: "Note", field: "other", kind: .vector, vector: Db3VectorIndexOptions(distance: .l2, index: .exact)
        ))
        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let all = recordLogIds(2_000, prefix: "c")
        let loaded = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: lines(all[...], "loaded", seed: 11))])
        _ = try await load.until(try XCTUnwrap(loaded["sessionId"] as? String), timeout: 180) { ($0["state"] as? String) == "complete" }
        try await live.untilEqual(x, documentId, "Note", ["title"], timeout: 120)
        try await eventually(timeout: 180, description: "the model uploaded and installed") {
            (try? await x.db3.indexes.local(documentId))?.first { $0.fields == ["embedding"] }?.mode == .ann
        }
        await x.destroy()

        // Plant version 8: the cache without its vector column, every vector table and trigger gone, each entry as #5322 cached it.
        let planter = SQLiteStorageProvider(path: file)
        try await planter.initialize(namespace: "plant")
        try planter.withConnection { connection in
            for row in try connection.query("SELECT vector FROM record_log_indexes WHERE vector IS NOT NULL", []) {
                if let flat = row["vector"].stringValue { try RecordLogIndexes.dropVectorTables(RecordLogSql(connection: connection), flat) }
            }
            try connection.execute(
                "UPDATE record_log_indexes SET options = ? WHERE kind = 'vector'",
                [.text(#"{"on":"device","unbuilt":"vector indexes are not built by this client build"}"#)]
            )
            try connection.executeScript("ALTER TABLE record_log_indexes DROP COLUMN vector")
            try connection.execute("UPDATE record_log_meta SET value = '8' WHERE key = 'storage_version'", [])
        }
        await planter.close()

        // Converted at open and built at the next list: the listed model fetched and installed, no drift.
        let converted = try await live.client("converted", models: [Self.note], file: file)
        try await live.open(converted, documentId)
        try await eventually(timeout: 120, description: "the converted store on the listed model") {
            (try? await converted.db3.indexes.local(documentId))?.first { $0.fields == ["embedding"] }?.mode == .ann
        }
        XCTAssertEqual(converted.vec1Trainer.runs, 0)
        try await check(converted, documentId, "converted from version 8")
        await converted.destroy()

        // Written while no client runs: re-embedded rows and new ones, over HTTP.
        try await saveAll(load, all[0..<200], seed: 5_000)
        try await saveAll(load, (0..<50).map { "late\($0)" }[...], seed: 6_000)
        // Restarted over the same file: nothing rebuilt, the writes arrive by catch-up, $near from the ANN table.
        let lines = LockedBox<[String]>([])
        Logger.lineForTest = { _, _, message in lines.withValue { $0.append(message) } }
        defer { Logger.lineForTest = nil }
        let restarted = try await live.client("restarted", models: [Self.note], file: file)
        restarted.setLogLevel(.info)
        try await live.open(restarted, documentId)
        try await check(restarted, documentId, "restarted, writes by catch-up")
        XCTAssertEqual(lines.value.filter { $0.contains("vector index") && $0.contains("built from") }, [], "nothing rebuilt")
        let modes = try await restarted.db3.indexes.local(documentId).map { $0.mode }
        XCTAssertEqual(Set(modes.compactMap { $0 }), [.ann, .exact])
        XCTAssertEqual(restarted.vec1Trainer.runs, 0)
    }
}
