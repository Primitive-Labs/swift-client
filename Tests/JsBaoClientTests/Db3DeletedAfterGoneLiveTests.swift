import XCTest
@testable import JsBaoClient

/// #5091 behavior 10 — a db3 already gone for a revoked grant that is then
/// deleted, against the dev server: the Swift twin of
/// `tests/client/db3-deleted-after-gone-5091.test.ts`.
///
/// A member gone `.permission` after its grant was revoked hears exactly one
/// `Db3GoneEvent(reason: .deleted)` after the owner deletes the db3 over HTTP
/// and the member subscribes again; that `ready()` throws `.db3Deleted`, and
/// the rows stay readable.
final class Db3DeletedAfterGoneLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let permissionCache: TimeInterval = 6

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-deleted-after-gone-5091")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil).compactMap { $0["title"]?.stringValue }.sorted()
    }

    func testAMemberGoneForPermissionHearsTheDeletionOnce() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        try await ctx.grantPermission(
            appId: live.app.appId, documentId: id, userId: member.userId, permission: "read-write", jwt: live.app.ownerJWT
        )
        let c = try await live.client("member", models: [Self.note], token: member.jwt)
        let handle = try c.db3.subscribe(id)
        try await handle.ready()
        try await c.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("one")], in: id, confirm: true)
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }

        // Gone for the revoked grant.
        _ = try await ctx.appRequest(
            method: "DELETE", appId: live.app.appId, path: "/documents/\(id)/permissions/\(member.userId)", body: nil, jwt: live.app.ownerJWT
        )
        try await delay(Self.permissionCache)
        try c.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("after the revocation")], in: id)
        try await eventually(timeout: 20, description: "gone") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: id, reason: .permission)])

        // Deleted, then the member's next contact with the room.
        _ = try await ctx.appRequest(method: "DELETE", appId: live.app.appId, path: "/db3/\(id)", body: nil, jwt: live.app.ownerJWT)
        try await delay(Self.permissionCache)
        let again = try c.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 20))
        let got = await db3Outcome { try await again.ready() }
        XCTAssertEqual(got, "DB3_DELETED")
        try await eventually(timeout: 15, description: "the deleted gone") { gone.value.count > 1 }
        try await delay(1)
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: id, reason: .permission), Db3GoneEvent(id: id, reason: .deleted)])
        XCTAssertEqual(gone.value.last?.code, "DB3_DELETED")
        XCTAssertEqual(again.state.error?.code, "DB3_DELETED")
        XCTAssertTrue(try titles(c).contains("one"), "its rows stay readable")
        again.dispose()
        handle.dispose()
    }
}
