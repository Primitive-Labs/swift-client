import XCTest
@testable import JsBaoClient

/// #5361 behavior 15 — `client.db3.aliases` against the dev server, the Swift
/// twin of the JS client's suite.
///
/// A member binds, resolves (the db3's row and the alias), deletes, and then
/// resolves `nil`; resolving an alias that names a plain document throws
/// `HttpError` 409 `NOT_A_DB3`; an app owner binds for a member by `userId`
/// and the member resolves it; a member naming another user gets the 403; a
/// mixed-case key binds lowercased; an unknown key resolves `nil`.
final class Db3AliasesLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-aliases-5361")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func aliasKey(_ base: String) -> String {
        "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// A member of the app and a connected client signed in as them.
    private func member(_ name: String) async throws -> (TestUser, JsBaoClient) {
        let user = try await ctx.createTestUser(appId: live.app.appId)
        return (user, try await live.client(name, models: [Self.note], token: user.jwt))
    }

    /// The `HttpError` `body` throws; a failure when it throws nothing or something else.
    private func httpError(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> HttpError? {
        do {
            try await body()
            XCTFail("nothing was thrown", file: file, line: line)
        } catch let error as HttpError {
            return error
        } catch {
            XCTFail("threw \(error), not an HttpError", file: file, line: line)
        }
        return nil
    }

    func testAMemberBindsResolvesAndDeletesAnAlias() async throws {
        let (user, client) = try await member("member")
        let created = try await client.db3.create(title: "Inbox")
        let key = aliasKey("inbox")

        let bound = try await client.db3.aliases.set(SetAliasParams(scope: .user, aliasKey: key, documentId: created.id))
        XCTAssertEqual(bound.aliasKey, key)
        XCTAssertEqual(bound.documentId, created.id)
        XCTAssertEqual(bound.userId, user.userId)

        let resolved = try await client.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: key))
        let row = try XCTUnwrap(resolved)
        XCTAssertEqual(row.id, created.id)
        XCTAssertEqual(row.title, "Inbox")
        XCTAssertEqual(row.createdBy, user.userId)
        XCTAssertEqual(row.custodian, "user:\(user.userId)")
        XCTAssertTrue(row.sync)
        XCTAssertNil(row.type)
        XCTAssertEqual(row.alias.documentId, created.id)
        XCTAssertEqual(row.alias.userId, user.userId)

        try await client.db3.aliases.delete(AliasRef(scope: .user, aliasKey: key))
        let gone = try await client.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: key))
        XCTAssertNil(gone)
        // A delete of nothing is quiet.
        try await client.db3.aliases.delete(AliasRef(scope: .user, aliasKey: key))
    }

    func testResolvingAnAliasThatNamesAPlainDocumentThrowsNotADb3() async throws {
        let (user, client) = try await member("plain")
        let plain = try await ctx.appRequest(method: "POST", appId: live.app.appId, path: "/documents", body: ["title": "Plain"], jwt: user.jwt)
        let documentId = try XCTUnwrap(plain["documentId"] as? String)
        let key = aliasKey("plain")
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/document-aliases/user/\(key)", body: ["documentId": documentId], jwt: user.jwt
        )
        let error = await httpError { _ = try await client.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: key)) }
        XCTAssertEqual(error?.status, 409)
        XCTAssertEqual(error?.serverCode, "NOT_A_DB3")
    }

    func testAnOwnerBindsForAMemberWhoResolvesItAndAnotherMemberIsRefused() async throws {
        let (alice, aliceClient) = try await member("alice")
        let (_, bobClient) = try await member("bob")
        let owner = try await live.client("owner", models: [Self.note])
        let created = try await aliceClient.db3.create(title: "For Alice")
        // Another client cannot wait for Alice's create: read it once it has committed.
        _ = try await aliceClient.db3.get(created.id)
        let key = aliasKey("for-alice")

        let bound = try await owner.db3.aliases.set(
            SetAliasParams(scope: .user, aliasKey: key, documentId: created.id, userId: alice.userId)
        )
        XCTAssertEqual(bound.userId, alice.userId)
        let resolved = try await aliceClient.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: key))
        XCTAssertEqual(resolved?.id, created.id)

        let refused = await httpError {
            _ = try await bobClient.db3.aliases.set(SetAliasParams(scope: .user, aliasKey: key, documentId: created.id, userId: alice.userId))
        }
        XCTAssertEqual(refused?.status, 403)
        let refusedDelete = await httpError {
            try await bobClient.db3.aliases.delete(AliasRef(scope: .user, aliasKey: key, userId: alice.userId))
        }
        XCTAssertEqual(refusedDelete?.status, 403)
        try await owner.db3.aliases.delete(AliasRef(scope: .user, aliasKey: key, userId: alice.userId))
        let gone = try await aliceClient.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: key))
        XCTAssertNil(gone)
    }

    func testAMixedCaseKeyBindsLowercasedAndAnUnknownKeyResolvesNil() async throws {
        let (_, client) = try await member("keys")
        let created = try await client.db3.create(title: "Keys")
        let key = aliasKey("Mixed-Case")
        let bound = try await client.db3.aliases.set(SetAliasParams(scope: .user, aliasKey: key, documentId: created.id))
        XCTAssertEqual(bound.aliasKey, key.lowercased())
        for spelling in [key, key.lowercased(), key.uppercased()] {
            let resolved = try await client.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: spelling))
            XCTAssertEqual(resolved?.id, created.id, spelling)
        }
        let unknown = try await client.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: aliasKey("nothing")))
        XCTAssertNil(unknown)
    }
}
