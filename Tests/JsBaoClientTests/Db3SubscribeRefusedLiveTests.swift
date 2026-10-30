import XCTest
@testable import JsBaoClient

/// #5021 behavior 17 and edge case E6 — a Swift subscribe whose format lookup
/// is refused settles at once, against the dev server.
///
/// A device that never held the db3 asks the documents API for its format.
/// A 403 (no grant) makes `available()` and `ready()` throw
/// `DB3_ACCESS_REFUSED` within a few seconds under a two-minute ready
/// timeout, told as `Db3ErrorEvent`, with nothing stored; after a grant a new
/// subscribe becomes ready. A 404 (no such document) throws `NOT_FOUND`.
final class Db3SubscribeRefusedLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let permissionCache: TimeInterval = 6

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-subscribe-refused-5021")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// How long `body` takes to throw, and the code it throws.
    private func timed(_ body: () async throws -> Void) async -> (String, TimeInterval) {
        let started = Date()
        let code = await db3Outcome(body)
        return (code, Date().timeIntervalSince(started))
    }

    func testAMemberWithNoGrantIsRefusedAtOnceAndReadiesAfterAGrant() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        try await waitForConnection(client: client, timeout: 15)
        let errors = ThreadSafeBox<[Db3ErrorEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3ErrorEvent.self) { event in errors.mutate { $0.append(event) } }
        defer { heard.cancel() }

        let handle = try client.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 120))
        let (available, availableTook) = await timed { try await handle.available() }
        let (ready, readyTook) = await timed { try await handle.ready() }
        XCTAssertEqual(available, "DB3_ACCESS_REFUSED")
        XCTAssertEqual(ready, "DB3_ACCESS_REFUSED")
        XCTAssertLessThan(availableTook, 5)
        XCTAssertLessThan(readyTook, 5)
        try await eventually(description: "the error event") { errors.value.contains { $0.id == id } }
        XCTAssertEqual(errors.value.filter { $0.id == id }.map(\.code), ["DB3_ACCESS_REFUSED"])
        let stored = try await client.db3.stored().map(\.id)
        XCTAssertFalse(stored.contains(id))

        try await ctx.grantPermission(
            appId: live.app.appId, documentId: id, userId: member.userId, permission: "read-write", jwt: live.app.ownerJWT
        )
        try await delay(Self.permissionCache)
        let again = try client.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 60))
        try await again.ready()
        XCTAssertEqual(again.state.phase, .live)
        again.dispose()
    }

    func testAnIdNoDocumentHasIsNotFoundAtOnce() async throws {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        try await waitForConnection(client: client, timeout: 15)
        let id = "01JD5021" + String(repeating: "Z", count: 18)
        let handle = try client.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 120))
        let (available, took) = await timed { try await handle.available() }
        XCTAssertEqual(available, "NOT_FOUND")
        XCTAssertLessThan(took, 5)
        let ready = await db3Outcome { try await handle.ready() }
        XCTAssertEqual(ready, "NOT_FOUND")
    }
}
