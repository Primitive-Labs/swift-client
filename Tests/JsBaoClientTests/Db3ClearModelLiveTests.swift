import XCTest
@testable import JsBaoClient

/// #5994 behavior 25 and edge case "a clear on a db3 whose sync is off" —
/// Swift's `client.db3.clearModel` against the dev server, the twin of
/// `tests/client/db3-clear-model-5994.test.ts`.
///
/// On a db3 this client holds live, the call returns the server's answer only
/// once the device has applied the clear: the local copy holds none of the
/// model's records then, and a record saved right after it is live on the
/// server and here. It returns at once when the clear wrote nothing, when the
/// db3 is not open here, and when the db3's sync is off.
@available(*, deprecated)
final class Db3ClearModelLiveTests: XCTestCase {

    #if PRIMITIVE_EXPERIMENTAL_APIS
    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-clear-model-5994")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil).compactMap { $0["title"]?.stringValue }.sorted()
    }

    private func roomTitles(_ db3Id: String) async throws -> [String] {
        try await live.roomRows(db3Id, "Note").values.compactMap { $0["title"] as? String }.sorted()
    }

    private func save(_ client: JsBaoClient, _ db3Id: String, _ title: String) async throws {
        try await client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: db3Id, confirm: true)
    }

    /// The owner's client holding a new db3 live, with `rows` saved and confirmed.
    private func held(_ rows: [String]) async throws -> (id: String, client: JsBaoClient, handle: Db3Subscription) {
        let id = try await live.db3Written(0, model: "Note")
        let client = try await live.client("owner", models: [Self.note])
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        for title in rows { try await save(client, id, title) }
        return (id, client, handle)
    }

    func testItReturnsOnceTheDeviceAppliedTheClearAndASaveRightAfterItIsLive() async throws {
        let (id, client, _) = try await held(["one", "two", "three"])
        XCTAssertEqual(try titles(client), ["one", "three", "two"])
        let result = try await client.db3.clearModel(id, model: "Note")
        XCTAssertEqual(result.model, "Note")
        XCTAssertEqual(result.rows, 3)
        XCTAssertNotNil(result.lsn)
        XCTAssertNotNil(result.epoch)
        XCTAssertFalse(result.dropped)
        // Returned only once applied: the device holds none of the cleared records now.
        XCTAssertEqual(try titles(client), [])
        let emptied = try await roomTitles(id)
        XCTAssertEqual(emptied, [])
        try await save(client, id, "after")
        let after = try await roomTitles(id)
        XCTAssertEqual(after, ["after"], "a save right after the clear is live on the server")
        XCTAssertEqual(try titles(client), ["after"])
    }

    func testItReturnsAtOnceWhenNothingWasWrittenWhenTheDb3IsNotOpenHereAndWhenItsSyncIsOff() async throws {
        let (id, client, handle) = try await held([])
        let nothing = try await client.db3.clearModel(id, model: "Note")
        XCTAssertEqual(nothing.rows, 0)
        XCTAssertNil(nothing.lsn)

        // Not open here: a second client of the same user that never subscribed.
        try await save(client, id, "kept")
        let other = try await live.client("other", models: [Self.note])
        var started = Date()
        let elsewhere = try await other.db3.clearModel(id, model: "Note")
        XCTAssertEqual(elsewhere.rows, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "no wait for a db3 not open here")

        // Sync off: the holder's copy is gone, and nothing is relayed to it.
        _ = try await ctx.appRequest(method: "PUT", appId: live.app.appId, path: "/db3/\(id)/sync", body: ["sync": false], jwt: live.app.ownerJWT)
        try await eventually(timeout: 15, description: "the copy gone") { handle.state.phase == .gone }
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(id)/records/batch",
            body: ["operations": [["action": "create", "model": "Note", "id": RecordLogLiveApp.ulid(), "data": ["title": "server"]]]],
            jwt: live.app.ownerJWT
        )
        started = Date()
        let off = try await client.db3.clearModel(id, model: "Note")
        XCTAssertEqual(off.rows, 1)
        XCTAssertNotNil(off.lsn)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "no wait for a db3 whose sync is off")
    }
    #endif
}
