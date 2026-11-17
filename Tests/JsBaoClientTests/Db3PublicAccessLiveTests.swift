import XCTest
@testable import JsBaoClient

/// #5842 behavior 21 (live half) — public access from the Swift client against
/// the dev server, project `public-access` phase 3 (intent criteria 5 and 16).
///
/// An app admin's `client.db3.permissions(id).setPublicAccess(.reader)` and
/// `(nil)` set and clear public access on a member's db3, and `client.db3.get`
/// carries the stored value for the admin while it is set. The db3's own owner,
/// a member who is not an app admin, is refused 403.
final class Db3PublicAccessLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-public-access-5842")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testAnAppAdminSetsAndClearsAndAMemberIsRefused() async throws {
        let alice = try await ctx.createTestUser(appId: live.app.appId)
        let admin = try await ctx.createTestUser(appId: live.app.appId, role: "admin")
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3", body: ["title": "Public?"], jwt: alice.jwt
        )
        let db3Id = try XCTUnwrap(created["id"] as? String)

        let adminClient = try await live.client("admin", models: [], token: admin.jwt)
        let set = try await adminClient.db3.permissions(db3Id).setPublicAccess(.reader)
        XCTAssertEqual(set, Db3PublicAccessChange(id: db3Id, level: .reader, changed: true, signedOutAccess: false))
        let shown = try await adminClient.db3.get(db3Id)
        XCTAssertEqual(shown.publicAccess, .reader)
        XCTAssertEqual(shown.publicAccessUpdatedBy, admin.userId)
        XCTAssertNotNil(shown.publicAccessUpdatedAt)

        let cleared = try await adminClient.db3.permissions(db3Id).setPublicAccess(nil)
        XCTAssertEqual(cleared, Db3PublicAccessChange(id: db3Id, level: nil, changed: true, signedOutAccess: false))
        let hidden = try await adminClient.db3.get(db3Id)
        XCTAssertNil(hidden.publicAccess)

        let owner = try await live.client("alice", models: [], token: alice.jwt)
        do {
            _ = try await owner.db3.permissions(db3Id).setPublicAccess(.reader)
            XCTFail("the db3's owner, a member, must be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
    }
}
