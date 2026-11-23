import XCTest
@testable import JsBaoClient

/// #5852 behavior 15 — the docs' Swift public-access example, run as written
/// against the dev server (project `public-access` phase 9, intent criterion 16).
///
/// `markPublic(client:db3Id:)` is compiled from
/// `primitive-docs/examples/databases/public-access.swift` itself:
/// `PublicAccessExample.swift` beside this file is a symlink to the corpus
/// file, so the bytes a developer copies are the bytes this test runs. Called
/// as an app admin on a new db3, it sets public access, clears it again, and
/// returns `true` (the set changed the db3); the db3 then stores no public
/// access.
final class PublicAccessExampleLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-public-access-example-5852")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testTheCorpusExampleSetsAndClearsPublicAccess() async throws {
        let admin = try await ctx.createTestUser(appId: live.app.appId, role: "admin")
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3", body: ["title": "Example"], jwt: admin.jwt
        )
        let db3Id = try XCTUnwrap(created["id"] as? String)
        let adminClient = try await live.client("admin", models: [], token: admin.jwt)

        let changed = try await markPublic(client: adminClient, db3Id: db3Id)

        XCTAssertTrue(changed)
        let shown = try await adminClient.db3.get(db3Id)
        XCTAssertNil(shown.publicAccess)
    }
}
