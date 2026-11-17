import XCTest
@testable import JsBaoClient

/// #6020 behavior 20 (live) — a create of a db3 type the app archived is
/// refused by the server `DB3_TYPE_ARCHIVED`; a local-first create returns at
/// once and the refusal arrives as `Db3CreateFailedEvent` naming the db3,
/// the code and the type, with the rows saved on the device kept.
final class Db3TypeArchivedLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private static let schema = """
    [models.Note]
    [models.Note.fields.id]
    type = "id"
    [models.Note.fields.title]
    type = "string"
    """

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-archived-6020")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testACreateOfAnArchivedTypeArrivesAsDb3CreateFailed() async throws {
        let type = "swift-arch-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)",
            body: ["schema": Self.schema, "archived": true], jwt: live.app.ownerJWT
        )
        let owner = try await live.client("owner", models: [Self.note])
        let failed = LockedBox<[Db3CreateFailedEvent]>([])
        let subscription = owner.eventEmitter.subscribe(Db3CreateFailedEvent.self) { event in failed.withValue { $0.append(event) } }
        defer { subscription.cancel() }

        let info = try await owner.db3.create(title: "Archived", type: type)
        XCTAssertEqual(info.type, type)
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("kept")], in: info.id)

        try await eventually(timeout: 15, description: "Db3CreateFailedEvent") { failed.value.count == 1 }
        let event = try XCTUnwrap(failed.value.first)
        XCTAssertEqual(event.id, info.id)
        XCTAssertEqual(event.code, JsBaoErrorCode.db3TypeArchived.rawValue)
        XCTAssertEqual(event.type, type)
        let kept = try XCTUnwrap(owner.sharedModel("Note")?.member(docId: info.id)).query().compactMap { $0["title"]?.stringValue }
        XCTAssertEqual(kept, ["kept"])
    }
}
