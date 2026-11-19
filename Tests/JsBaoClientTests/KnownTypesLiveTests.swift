import XCTest
@testable import JsBaoClient

/// #6024 behavior 33 (live) — a build generated with `--known-types-only`
/// (its `GeneratedModels.db3Types` registered) creates and opens a db3 of
/// its own type, is refused creating one of a type it does not declare, and
/// is refused opening a db3 of such a type `.db3TypeUnknownToClient`.
final class KnownTypesLiveTests: XCTestCase {

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
        let app = try await ctx.createTestApp(name: "swift-known-types-6024")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func pushType(_ prefix: String) async throws -> String {
        let type = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)", body: ["schema": Self.schema], jwt: live.app.ownerJWT
        )
        return type
    }

    func testABuildCreatesAndOpensItsOwnTypeAndRefusesOthers() async throws {
        let known = try await pushType("swift-known")
        let undeclared = try await pushType("swift-undeclared")
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3", body: ["title": "Theirs", "type": undeclared], jwt: live.app.ownerJWT
        )
        let theirs = try XCTUnwrap(created["id"] as? String)

        let owner = try await live.client("owner", models: [Self.note])
        owner.registerDb3Types(PrimitiveDb3Types(knownTypesOnly: true, types: [PrimitiveDb3Types.DeclaredType(name: known)]))

        let mine = try await owner.db3.create(title: "Mine", type: known)
        XCTAssertEqual(mine.type, known)
        let opened = try owner.db3.subscribe(mine.id)
        try await opened.ready()
        opened.dispose()

        do {
            _ = try await owner.db3.create(title: "Nope", type: undeclared)
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.details?["reason"], .string("unknown-type"))
        }

        let refused = try owner.db3.subscribe(theirs)
        do {
            try await refused.ready()
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3TypeUnknownToClient)
            XCTAssertEqual(error.details?["type"], .string(undeclared))
        }
        let state = try await owner.db3.state(theirs)
        XCTAssertEqual(state.error?.code, "DB3_TYPE_UNKNOWN_TO_CLIENT")
        XCTAssertFalse(state.resident)
        let stored = try await owner.db3.stored()
        XCTAssertTrue(stored.first { $0.id == theirs }?.rows ?? 0 == 0, "nothing of it was applied")
    }
}
