import XCTest
@testable import JsBaoClient

/// Live end-to-end test for `client.links` share links (#931):
/// create a document on the dev server, build the share URL with
/// `links.shareURL`, and resolve it back to the document id.
///
/// Alias-based share links were removed with app-scoped aliases (#1168):
/// a user-scoped alias key carries no owner user id, so a recipient
/// cannot resolve it — only concrete-id share links remain.
final class LinksLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-links")

        let user = try await ctx.createTestUser(
            appId: testApp.appId, role: "admin", email: "links-user@test.local"
        )
        client = createTestClient(appId: testApp.appId, token: user.jwt)
        try await client.connect()
        try await waitForConnection(client: client)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testDocumentShareLinkEndToEnd() async throws {
        // `documents.create` returns only metadata; `createWithAlias`
        // (user-scope) is the create variant that returns the id.
        let aliasKey = "links-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        let created = try await client.documents.createWithAlias(
            options: CreateWithAliasOptions(
                title: "Links E2E Doc",
                alias: AliasRef(scope: .user, aliasKey: aliasKey)
            )
        )

        // Build the share URL the way an app would.
        client.links.appBaseURL = URL(string: "https://links-e2e.example.com")
        let url = try XCTUnwrap(
            client.links.shareURL(forDocument: created.documentId)
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://links-e2e.example.com/document/\(created.documentId)"
        )

        // Resolve it as if the OS handed the link to the app — purely,
        // no server hop.
        let target = try await client.links.resolve(url: url)
        XCTAssertEqual(target, .document(id: created.documentId))
    }

    func testNonUlidDocumentLinkIsUnknown() async throws {
        // A `/document/{segment}` link whose segment is not a ULID is no
        // longer treated as an alias (#1168) — it parses as `.unknown`.
        client.links.appBaseURL = URL(string: "https://links-e2e.example.com")
        let url = try XCTUnwrap(
            URL(string: "https://links-e2e.example.com/document/never-bound-alias")
        )
        let target = try await client.links.resolve(url: url)
        XCTAssertEqual(target, .unknown(url))
    }
}
