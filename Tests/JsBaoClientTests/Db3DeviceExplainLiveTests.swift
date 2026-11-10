import XCTest
@testable import JsBaoClient

/// #5241 behavior 19 (Swift) — against the dev server: on a subscribed db3
/// with a field index placed on both sides, `client.db3.records(id)
/// .explain(_:_:)` and the server's `POST db3/:id/records/:model/explain`
/// name the same `indexes` and the same `scanned` for the plain read, the
/// read forced onto the index by its registry name, and `none`.
final class Db3DeviceExplainLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private typealias F = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-device-explain-5241")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testTheDeviceAndTheServerNameTheSameIndexesAndScansPlainForcedAndNone() async throws {
        let (client, id) = try await F.subscribed(live, "explain")
        let registered = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(id)/indexes", body: ["model": "Note", "field": "rank", "on": "both"], jwt: live.app.ownerJWT
        )
        let name = try XCTUnwrap((registered["index"] as? [String: Any])?["name"] as? String, "\(registered)")
        try await eventually(timeout: 20, description: "the rank index built on the device") {
            try await client.db3.indexes.local(id).contains { $0.name == name && $0.status == .built }
        }
        let records = client.db3.records(id)
        for index in [nil, name, "none"] as [String?] {
            var body: [String: Any] = ["op": "query", "filter": ["rank": 13]]
            if let index { body["index"] = index }
            let server = try await ctx.appRequest(method: "POST", appId: live.app.appId, path: "/db3/\(id)/records/Note/explain", body: body, jwt: live.app.ownerJWT)
            let device = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["rank": 13], index: index))
            XCTAssertEqual(device.indexes, server["indexes"] as? [String], "\(index ?? "plain"): \(server)")
            XCTAssertEqual(device.scanned, server["scanned"] as? [String], "\(index ?? "plain"): \(server)")
            XCTAssertEqual(device.answered, (server["answered"] as? NSNumber)?.intValue)
            XCTAssertEqual(device.index, index)
        }
        let plain = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["rank": 13]))
        XCTAssertEqual(plain.indexes, [name])
        XCTAssertEqual(plain.answered, 2)
        let none = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["rank": 13], index: "none"))
        XCTAssertEqual(none.scanned, ["Note"])
    }
}
