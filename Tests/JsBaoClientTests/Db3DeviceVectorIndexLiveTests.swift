import XCTest
@testable import JsBaoClient

/// #5230 behaviors 6 (the live half), 9 and 10 — a synced db3's device vector
/// index on a live Swift client:
///
/// - 6: the flat table is built before `ready()` resolves, and `$near`
///   answers at once.
/// - 9: a flat build the disk refuses leaves the entry unbuilt with the
///   reason, holds no `ready()`, refuses only `$near` on it, and is built at a
///   later sync once there is room.
/// - 10: `local()` and `Db3State.indexes` list it unbuilt, built exact,
///   building, built ann and declined; `accept` builds it and installs the
///   listed model; `decline` drops its tables; `Db3StateEvent` fires at the
///   install, the fill's end and the model's drop.
final class Db3DeviceVectorIndexLiveTests: XCTestCase {

    private typealias V = Db3VectorLive

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-device-vector-5230")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static var exact: [String: Any] { [
        "model": V.model, "field": "embedding", "kind": "vector", "on": "device", "vector": ["distance": "cos", "index": "exact"],
    ] }

    func testTheFlatTableIsBuiltBeforeReadyResolves() async throws {
        let id = try await V.seeded(live)
        try await V.register(live, id, Self.exact)
        let client = try await live.client("a", models: [V.note])
        try await client.db3.subscribe(id).ready()
        let local = try await V.local(client, id)
        XCTAssertEqual(local?.status, .built)
        XCTAssertEqual(local?.mode, .exact)
        try await eventually(timeout: 60, description: "every row") { (try? client.db3.records(id).count(V.model)) == V.rows }
        let near = try V.nearest(client, id, 9)
        XCTAssertEqual(near.first?["id"]?.stringValue, V.id(9))
        let reference = Db3VectorTestSupport.bruteForce(V.vectors.enumerated().map { (V.id($0.offset), $0.element) }, V.vectors[9], k: 10)
        XCTAssertEqual(near.compactMap { $0["id"]?.stringValue }, reference.map(\.id))
        let flat = RecordLogVectorIndex.tableName(documentId: id, model: V.model, field: "embedding")
        let drift = try await Db3DeviceIndexOracle.driftOnACopy(try live.binding(client, id).store)
        XCTAssertEqual(drift, [])
        XCTAssertFalse(flat.isEmpty)
    }

    /// Lower the store's page limit to `headroom` pages above what it holds, the free list taken first; answers what puts it back.
    private func limitPages(_ store: RecordLogStore, headroom: Int) throws -> () throws -> Void {
        let onConnection = { (body: @escaping (any Format2SqlConnection) throws -> Int) throws -> Int in
            try store.flush()
            if let host = store.host as? any RecordLogGroupCommitHost { return try host.withRecordLogConnection(body) }
            return try store.host.withConnection(body)
        }
        let run = { (sql: String) throws -> Int in try onConnection { try $0.query(sql, []).first?.columns.values.first?.intValue ?? 0 } }
        let saved = try run("PRAGMA max_page_count")
        var rounds = 0
        while try run("PRAGMA freelist_count") > 0, rounds < 50 {
            let free = try run("PRAGMA freelist_count")
            _ = try onConnection { connection in
                try connection.executeScript("CREATE TABLE IF NOT EXISTS pl_disk_filler_5230 (b BLOB)")
                try connection.execute(
                    "INSERT INTO pl_disk_filler_5230 (b) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) SELECT zeroblob(3800) FROM n",
                    [.integer(Int64(free))]
                )
                return 0
            }
            rounds += 1
        }
        let pages = try run("PRAGMA page_count")
        _ = try run("PRAGMA max_page_count = \(pages + headroom)")
        return {
            _ = try run("PRAGMA max_page_count = \(saved)")
            _ = try onConnection { try $0.executeScript("DROP TABLE IF EXISTS pl_disk_filler_5230"); return 0 }
        }
    }

    func testAFlatBuildTheDiskRefusesHoldsNoReadyRefusesOnlyNearAndIsBuiltOnceThereIsRoom() async throws {
        let id = try await V.seeded(live)
        let device = try await V.device(live, id, name: "full")
        let store = try live.binding(device.client, id).store
        let restore = try limitPages(store, headroom: 2)
        try await V.register(live, id, Self.exact)
        try await eventually(timeout: 20, description: "the index listed") { (try? await V.local(device.client, id)) != nil }
        let unbuilt = try await V.local(device.client, id)
        XCTAssertEqual(unbuilt?.status, .unbuilt)
        XCTAssertTrue(unbuilt?.reason?.contains("disk is full") == true, "\(String(describing: unbuilt?.reason))")
        let started = Date()
        try await device.client.db3.subscribe(id).ready()
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        do {
            _ = try V.nearest(device.client, id, 3)
            XCTFail("$near on an unbuilt index answered")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3IndexPlacementUnsupported)
            XCTAssertEqual(error.details?["engine"], "swift-sqlite")
            XCTAssertEqual(error.details?["kind"], "vector")
            XCTAssertTrue(error.details?["reason"]?.stringValue?.contains("disk is full") == true)
        }
        // Every other query answers.
        XCTAssertEqual(try device.client.db3.records(id).count(V.model, ["n": ["$lt": 10]]), 10)
        try restore()
        // A later sync builds it: another index registered reads the list again.
        _ = try await V.register(live, id, ["model": V.model, "field": "n", "on": "device"])
        try await eventually(timeout: 30, description: "the vector index built once there is room") { (try? await V.local(device.client, id))?.status == .built }
        XCTAssertEqual(try V.nearest(device.client, id, 3).first?["id"]?.stringValue, V.id(3))
        device.subscription.dispose()
    }

    func testLocalAndTheDb3StateListAVectorIndexThroughItsLifeAndDeclineAndAcceptWork() async throws {
        let id = try await V.seeded(live)
        // Left out by the client's default before it was built: declined with the option's reason.
        let declining = try await live.client("kinds", models: [V.note], deviceIndexes: .kinds([.scalar]))
        try await V.register(live, id)
        try await declining.db3.subscribe(id).ready()
        let left = try await V.local(declining, id)
        XCTAssertEqual(left?.status, .declined)
        XCTAssertEqual(left?.reason, "the client's deviceIndexes option excludes vector")
        let modeWhileDeclined = await V.mode(declining, id)
        XCTAssertNil(modeWhileDeclined)
        do {
            _ = try V.nearest(declining, id, 1)
            XCTFail("$near on a declined index answered")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3IndexDeclinedOnDevice)
        }

        // A client building it: exact, then building while its fill runs, then ann; each told on its state.
        let client = try await live.client("a", models: [V.note])
        let heard = LockedBox<[Db3LocalIndex]>([])
        let token = client.eventEmitter.subscribe(Db3StateEvent.self) { event in
            if event.state.id == id, let index = event.state.indexes?.first(where: { $0.name == V.name }) { heard.withValue { $0.append(index) } }
        }
        defer { _ = token }
        let subscription = try client.db3.subscribe(id)
        try await subscription.ready()
        try await eventually(timeout: 120, description: "ann on the state") { heard.value.last?.mode == .ann }
        let modes = heard.value.map { "\($0.status.rawValue)/\($0.mode?.rawValue ?? "-")" }
        XCTAssertTrue(modes.contains("built/exact"), "\(modes)")
        XCTAssertEqual(modes.last, "built/ann")
        let state = try await client.db3.state(id)
        XCTAssertEqual(state.indexes?.first { $0.name == V.name }?.mode, .ann)

        // The declining client accepts: its flat table is built and the listed model installed.
        // Its store caches the listed model first and its list reads settle, so the
        // accept alone asks for the model: no list read comes after it.
        try await eventually(timeout: 60, description: "the listed model cached on the declining client") {
            try Self.cachedAnnModelRevision(live, declining, id) == 1
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let accepted = try await declining.db3.indexes.accept(id, name: V.name)
        XCTAssertEqual(accepted.status, .built)
        try await eventually(timeout: 120, description: "the accepted index on the listed model") { await V.mode(declining, id) == .ann }
        XCTAssertEqual(declining.vec1Trainer.runs, 0)
        // Declined again: its flat and ANN tables and their triggers go.
        let declined = try await declining.db3.indexes.decline(id, name: V.name)
        XCTAssertEqual(declined.status, .declined)
        let objects = try Db3DeviceIndexLiveFixture.objects(live, declining, id, "table", like: #"idx\_record\_log\_vec\_%"#)
            + Db3DeviceIndexLiveFixture.objects(live, declining, id, "trigger", like: #"idx\_record\_log\_vec\_%"#)
        XCTAssertEqual(objects, [])

        // The model dropped (the owner's delete): told on the state as exact.
        let before = heard.value.count
        _ = try await client.db3.indexes.deleteModel(id, name: V.name)
        try await eventually(timeout: 60, description: "the drop told") { heard.value.dropFirst(before).contains { $0.mode == .exact } }
        subscription.dispose()
    }

    /// The revision of the model `client`'s store caches as listed for the db3's vector entry.
    private static func cachedAnnModelRevision(_ live: RecordLogLiveApp, _ client: JsBaoClient, _ documentId: String) throws -> Int? {
        try live.binding(client, documentId).store.readView { sql in
            let options = try sql.rows("SELECT options FROM record_log_indexes WHERE doc_id = ? AND kind = 'vector'", [.text(documentId)])
                .first?["options"].stringValue.flatMap(RecordLogJSON.parse)
            return options?["annModel"]?["revision"]?.numberValue.map(Int.init)
        }
    }
}
