import XCTest
@testable import JsBaoClient

/// #5221 behavior 19 — drift on a live Swift client, against the dev server:
/// the twin of the JS client's `db3-drift-5221` suite.
///
/// - A subscribed client reports `drift` with `entriesBehind` 0, `live` true
///   and a fresh `asOf` on `Db3State` and on a page; offline it reports
///   `live` false with `asOf` unchanged while the room takes another write,
///   and bounds it holds pass; back online and subscribed again, once
///   `ready()`, `entriesBehind` is 0 and `asOf` advanced.
/// - A second client over the same store file, kept offline, reports the
///   stored drift and refuses `maxDrift(age: 0.001)`.
final class Db3DriftLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-drift-5221")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func page(_ client: JsBaoClient, _ id: String, maxDrift: Db3MaxDrift? = nil) throws -> PagedQueryResult<PrimitiveRow> {
        try client.sharedModel(for: Self.note).queryPaged(nil, options: QueryOptions(db3: [id], maxDrift: maxDrift))
    }

    func testDriftIsLiveWhileSubscribedALowerBoundOfflineAndCurrentAgainOnceLive() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let current = try await eventuallyValue(timeout: 15, description: "a live drift") { () -> Db3Drift? in
            let drift = try await x.db3.state(id).drift
            return drift?.live == true ? drift : nil
        }
        XCTAssertEqual(current.entriesBehind, 0)
        XCTAssertLessThan(Date().timeIntervalSince(current.asOf), 30)
        XCTAssertEqual(try page(x, id).drift?[id]?.entriesBehind, 0)
        XCTAssertEqual(try page(x, id).drift?[id]?.live, true)

        x.setNetworkMode(.offline)
        let offline = try await eventuallyValue(timeout: 15, description: "the drift to stop being live") { () -> Db3Drift? in
            let drift = try await x.db3.state(id).drift
            return drift?.live == false ? drift : nil
        }
        try await live.submit(id, model: "Note", rows: 1, from: 3)
        let held = try await x.db3.state(id).drift
        XCTAssertEqual(held?.asOf, offline.asOf, "asOf unchanged offline")
        XCTAssertEqual(held?.entriesBehind, 0, "the head is a lower bound")
        // A page agrees with the state, though offline mode may leave the socket open.
        let paged = try page(x, id).drift?[id]
        XCTAssertEqual(paged?.live, false, "a page offline is not live")
        XCTAssertEqual(paged?.asOf, offline.asOf, "a page's asOf unchanged offline")
        XCTAssertEqual(try page(x, id, maxDrift: Db3MaxDrift(age: 3_600)).data.count, 2)
        XCTAssertEqual(try page(x, id, maxDrift: Db3MaxDrift(entries: 0)).data.count, 2)

        x.setNetworkMode(.online)
        // The room's `submit` route relays nothing to subscribers, so the
        // client hears that write only on its next open: unsubscribed until
        // its session has closed, then subscribed again, it opens and catches up.
        handle.dispose()
        try await eventually(timeout: 15, description: "\(id) to be unsubscribed") {
            let state = try await x.db3.state(id)
            return !state.subscribed && state.phase == .idle
        }
        let again = try x.db3.subscribe(id)
        try await again.ready()
        let back = try await eventuallyValue(timeout: 30, description: "a live drift again, past the offline one") { () -> Db3Drift? in
            let state = try await x.db3.state(id)
            guard state.phase == .live, let drift = state.drift, drift.live, drift.asOf > offline.asOf else { return nil }
            return drift
        }
        XCTAssertEqual(back.entriesBehind, 0)
        XCTAssertEqual(try page(x, id).data.count, 3)
        again.dispose()
    }

    func testAClientOverTheSameStoreKeptOfflineReportsTheStoredDriftAndRefusesATightAge() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let file = live.file("restart")
        let x = try await live.client("x", models: [Self.note], file: file)
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let before = try await eventuallyValue(timeout: 15, description: "a drift before the restart") { () -> Db3Drift? in
            try await x.db3.state(id).drift
        }
        handle.dispose()
        await x.destroy()

        let x2 = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT, storageConfig: .sqlite(directory: file), autoNetwork: false
        )
        defer { Task { await x2.destroy() } }
        x2.registerModels([Self.note])
        _ = await x2.waitForStorageReady()
        x2.setNetworkMode(.offline)
        let stored = try await x2.db3.state(id).drift
        XCTAssertEqual(stored?.entriesBehind, before.entriesBehind)
        XCTAssertEqual(stored?.asOf, before.asOf)
        XCTAssertEqual(stored?.live, false)
        let kept = try x2.db3.subscribe(id)
        try await kept.available()
        let answered = try page(x2, id)
        XCTAssertEqual(answered.data.count, 2)
        XCTAssertEqual(answered.drift?[id]?.asOf, before.asOf)
        XCTAssertEqual(answered.drift?[id]?.live, false)
        XCTAssertThrowsError(try page(x2, id, maxDrift: Db3MaxDrift(age: 0.001))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .db3DriftExceeded, "\(error)")
            XCTAssertEqual((error as? JsBaoError)?.details?["db3Id"], .string(id))
        }
        kept.dispose()
    }
}
