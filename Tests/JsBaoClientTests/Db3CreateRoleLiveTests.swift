import XCTest
@testable import JsBaoClient

/// #5998 behavior 45 (live) — a member's create of a db3 type whose file
/// says `create = "admins"` is refused by the server
/// `DB3_CREATE_ROLE_REQUIRED`: a local-first create returns at once and the
/// refusal arrives as `Db3CreateFailedEvent` naming the db3, the code and
/// the type; the alias create throws the code.
final class Db3CreateRoleLiveTests: XCTestCase {

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
        let app = try await ctx.createTestApp(name: "swift-db3-create-role-5998")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testAMembersCreateOfARestrictedTypeArrivesAsDb3CreateFailed() async throws {
        let type = "swift-role-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)",
            body: ["schema": Self.schema, "create": "admins"], jwt: live.app.ownerJWT
        )
        let member = try await ctx.createTestUser(appId: live.app.appId, role: "member")
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let failed = LockedBox<[Db3CreateFailedEvent]>([])
        let subscription = client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { event in failed.withValue { $0.append(event) } }
        defer { subscription.cancel() }

        let info = try await client.db3.create(title: "Team", type: type)
        XCTAssertEqual(info.type, type)

        try await eventually(timeout: 15, description: "Db3CreateFailedEvent") { failed.value.contains { $0.id == info.id } }
        let event = try XCTUnwrap(failed.value.first { $0.id == info.id })
        XCTAssertEqual(event.code, JsBaoErrorCode.db3CreateRoleRequired.rawValue)
        XCTAssertEqual(event.type, type)

        do {
            _ = try await client.db3.getOrCreateWithAlias(
                Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "team-\(UUID().uuidString.prefix(6))"), title: "Team", type: type)
            )
            XCTFail("a member's alias create of a restricted type should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, JsBaoErrorCode.db3CreateRoleRequired.rawValue)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3CreateRoleRequired)
        }
    }
}
