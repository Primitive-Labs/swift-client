import XCTest
@testable import JsBaoClient

/// Live end-to-end test for `client.links` alias resolution (#931):
/// create a document bound to an alias on the dev server, build the
/// share URL with `links.shareURL`, and resolve it back to the
/// document id through `GET /document-aliases/{scope}/{aliasKey}`.
final class LinksLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-links")

        // App-scoped aliases can only be created by app admins
        // (document-aliases-controller: "Only admins can create
        // app-scoped aliases"), so the test user is an admin.
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

    func testResolveAliasShareLinkEndToEnd() async throws {
        let aliasKey = "spring-planning-\(UUID().uuidString.prefix(8).lowercased())"

        // Create the document bound to an app-scoped alias.
        let created = try await client.documents.createWithAlias(
            options: CreateWithAliasOptions(
                title: "Links E2E Doc",
                alias: AliasRef(scope: .app, aliasKey: aliasKey)
            )
        )

        // Build the share URL the way an app would.
        client.links.appBaseURL = URL(string: "https://links-e2e.example.com")
        let url = try XCTUnwrap(
            client.links.shareURL(forDocument: created.documentId, alias: aliasKey)
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://links-e2e.example.com/document/\(aliasKey)"
        )

        // Resolve it as if the OS handed the link to the app.
        let target = try await client.links.resolve(url: url)
        XCTAssertEqual(target, .document(id: created.documentId))

        // The concrete-id share link resolves purely, no alias hop.
        let idURL = try XCTUnwrap(
            client.links.shareURL(forDocument: created.documentId)
        )
        let idTarget = try await client.links.resolve(url: idURL)
        XCTAssertEqual(idTarget, .document(id: created.documentId))
    }

    func testResolveUnknownAliasThrows() async throws {
        client.links.appBaseURL = URL(string: "https://links-e2e.example.com")
        let url = try XCTUnwrap(
            URL(string: "https://links-e2e.example.com/document/never-bound-alias")
        )
        do {
            _ = try await client.links.resolve(url: url)
            XCTFail("expected aliasNotFound")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .aliasNotFound)
        }
    }
}
