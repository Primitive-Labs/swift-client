import XCTest
@testable import JsBaoClient

/// #4921 behavior 37 — `client.db3.create` with networking stopped, against
/// the dev server: the db3 is created here, two saves land in its store, and
/// back online it commits through `POST db3` under the id this client minted,
/// `Db3CreatedEvent` fires, `GET db3/<id>` answers it, and after `ready()` the
/// room holds both rows, which a second client of the same user reads.
final class Db3OfflineCreateLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-offline-create-4921")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient, _ db3Id: String) throws -> [String] {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: db3Id)).query().compactMap { $0["title"]?.stringValue }.sorted()
    }

    func testAnOfflineCreateCommitsUnderItsIdWithItsRows() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let created = LockedBox<[String]>([])
        let subscription = owner.eventEmitter.subscribe(Db3CreatedEvent.self) { event in
            created.withValue { $0.append(event.id) }
        }
        defer { subscription.cancel() }

        await owner.goOffline()
        let info = try await owner.db3.create(title: "Made offline")
        XCTAssertEqual(info.custodian, "user:\(live.app.ownerUserId)")
        let pending = try await owner.db3.state(info.id)
        XCTAssertTrue(pending.pendingCreate)
        XCTAssertTrue(pending.resident)
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("first")], in: info.id)
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("second")], in: info.id)
        XCTAssertEqual(try titles(owner, info.id), ["first", "second"])

        await owner.goOnline()
        try await eventually(timeout: 30, description: "Db3CreatedEvent") { created.value == [info.id] }
        let got = try await owner.db3.get(info.id)
        XCTAssertEqual(got.id, info.id)
        XCTAssertEqual(got.createdBy, live.app.ownerUserId)
        try await eventually(timeout: 15, description: "pendingCreate false") { try await !owner.db3.state(info.id).pendingCreate }

        let handle = try owner.db3.subscribe(info.id)
        try await handle.ready()
        try await live.settled(owner, info.id)
        let room = try await live.roomRows(info.id, "Note").values.compactMap { $0["title"] as? String }.sorted()
        XCTAssertEqual(room, ["first", "second"])

        let second = try await live.client("owner-second", models: [Self.note])
        let secondHandle = try second.db3.subscribe(info.id)
        try await secondHandle.ready()
        XCTAssertEqual(try titles(second, info.id), ["first", "second"])
        handle.dispose()
        secondHandle.dispose()
        XCTAssertEqual(created.value, [info.id], "Db3CreatedEvent fired once")
    }
}
