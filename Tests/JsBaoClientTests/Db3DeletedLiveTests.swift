import XCTest
@testable import JsBaoClient

/// #5049 behavior 17 — a deleted db3, against the dev server: the Swift twin
/// of `tests/client/db3-deleted-gone-5049.test.ts`.
///
/// A member subscribed through a grant hears `Db3GoneEvent(reason: .deleted)`
/// (`DB3_DELETED`) once when the owner deletes the db3 over HTTP; the db3 is
/// gone with that code, its rows stay readable, and a subscribe while gone
/// throws `.db3Deleted` with no second gone event. A revoked grant on a db3
/// that still exists reports `.permission`.
final class Db3DeletedLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let permissionCache: TimeInterval = 6

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-deleted-5049")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil).compactMap { $0["title"]?.stringValue }.sorted()
    }

    private struct Member {
        let id: String
        let userId: String
        let client: JsBaoClient
        let handle: Db3Subscription
    }

    /// A member holding read-write on a db3, subscribed, with `rows` confirmed rows.
    private func memberWith(_ rows: [String]) async throws -> Member {
        let id = try await live.db3Written(0, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        try await ctx.grantPermission(
            appId: live.app.appId, documentId: id, userId: member.userId, permission: "read-write", jwt: live.app.ownerJWT
        )
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        for title in rows {
            try await client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: id, confirm: true)
        }
        return Member(id: id, userId: member.userId, client: client, handle: handle)
    }

    func testAMemberHearsTheDb3GoneDeletedOnce() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }

        _ = try await ctx.appRequest(method: "DELETE", appId: live.app.appId, path: "/db3/\(m.id)", body: nil, jwt: live.app.ownerJWT)
        try await eventually(timeout: 15, description: "gone") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id, reason: .deleted)])
        XCTAssertEqual(gone.value.first?.code, "DB3_DELETED")
        try await eventually(description: "the state gone") { m.handle.state.phase == .gone }
        XCTAssertEqual(m.handle.state.permission, .refused)
        XCTAssertEqual(m.handle.state.error?.code, "DB3_DELETED")
        XCTAssertEqual(try titles(c), ["one"], "its rows stay readable")

        // A subscribe while gone throws .db3Deleted, and no second gone event fires.
        let again = try c.db3.subscribe(m.id, options: Db3SubscribeOptions(readyTimeout: 20))
        let got = await db3Outcome { try await again.ready() }
        XCTAssertEqual(got, "DB3_DELETED")
        try await delay(1)
        XCTAssertEqual(gone.value.count, 1)
        again.dispose()
        m.handle.dispose()
    }

    func testARevokedGrantStillReportsPermission() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }
        _ = try await ctx.appRequest(
            method: "DELETE", appId: live.app.appId, path: "/documents/\(m.id)/permissions/\(m.userId)", body: nil, jwt: live.app.ownerJWT
        )
        try await delay(Self.permissionCache)
        try c.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("after the revocation")], in: m.id)
        try await eventually(timeout: 20, description: "gone") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id, reason: .permission)])
        XCTAssertEqual(m.handle.state.error?.code, "DB3_ACCESS_REFUSED")
        m.handle.dispose()
    }
}
