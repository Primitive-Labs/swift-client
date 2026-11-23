import XCTest
@testable import JsBaoClient

/// Where an emailed sign-in link lands, against the dev server: with no
/// target the request carries `options.auth.oauthRedirectUri`, else
/// `links.appBaseURL`'s origin + `/oauth/callback`, else none. The server is
/// the oracle (it accepts an allow-listed target and refuses another with
/// `Invalid redirect URI`); `recordAuthRequests` reads the exact body and
/// count of what the client sent it.
final class EmailSignInLinkTargetLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    private let base = URL(string: "https://app.test")!
    private let derived = "https://app.test/oauth/callback"
    private let requestPath = "/auth/email/request"

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-email-link-target")
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private func allowList(_ uris: [String]) async throws {
        try await ctx.updateTestApp(
            appId: testApp.appId,
            fields: ["emailSignInEnabled": true, "emailRedirectUris": uris]
        )
    }

    private func makeClient(auth: AuthConfig = AuthConfig()) -> (JsBaoClient, RecordingTransport) {
        let client = createSignInTestClient(appId: testApp.appId, token: testApp.ownerJWT, auth: auth)
        clients.append(client)
        return (client, recordAuthRequests(of: client, appId: testApp.appId))
    }

    private func email() -> String { "link-target-\(UUID().uuidString.prefix(8))@example.com" }

    func testTheLinkTargetIsReadAtCallTimeAndSendsNothing() async throws {
        let (client, recorder) = makeClient()
        XCTAssertNil(client.auth.emailSignInLinkTarget())

        client.links.appBaseURL = base
        XCTAssertEqual(client.auth.emailSignInLinkTarget(), derived)
        XCTAssertEqual(client.auth.emailSignInLinkTarget(.codeOnly), nil)
        XCTAssertEqual(client.auth.emailSignInLinkTarget(.uri("https://x.test/cb")), "https://x.test/cb")

        let (optioned, optionedRecorder) = makeClient(auth: AuthConfig(oauthRedirectUri: "myapp://oauth/callback"))
        optioned.links.appBaseURL = base
        XCTAssertEqual(optioned.auth.emailSignInLinkTarget(), "myapp://oauth/callback")

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertTrue(optionedRecorder.calls.isEmpty)
    }

    /// The breaking default: a request with no target now carries the base
    /// URL's callback, through `client.auth` and the public controller alike.
    func testNoTargetPostsTheBaseURLsCallback() async throws {
        try await allowList([derived])
        let (client, recorder) = makeClient()
        client.links.appBaseURL = base

        let viaAPI = try await client.auth.emailSignInRequest(email: email())
        XCTAssertTrue(viaAPI.success)
        let viaNil = try await client.auth.emailSignInRequest(email: email(), redirectUri: nil)
        XCTAssertTrue(viaNil.success)
        let viaController = try await client.authController.emailSignInRequest(email: email(), redirectUri: nil)
        XCTAssertTrue(viaController)

        let calls = recorder.calls(to: requestPath)
        XCTAssertEqual(calls.count, 3)
        for call in calls {
            XCTAssertEqual(call.method, .post)
            XCTAssertEqual(call.bodyString("redirectUri"), derived)
        }
    }

    func testARefusedDerivedTargetThrowsAfterOneRequest() async throws {
        try await allowList(["https://other.test/cb"])
        let (client, recorder) = makeClient()
        client.links.appBaseURL = base

        do {
            _ = try await client.auth.emailSignInRequest(email: email())
            XCTFail("an unlisted derived target must be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(
                (error.serverMessage ?? error.message).contains("Invalid redirect URI"),
                "got \(error)"
            )
        }
        let calls = recorder.calls(to: requestPath)
        XCTAssertEqual(calls.count, 1, "nothing retries code-only")
        XCTAssertEqual(calls.first?.bodyString("redirectUri"), derived)
    }

    func testTheOptionWinsCodeOnlySendsNoTargetAndAnExplicitTargetIsSentAsIs() async throws {
        let option = "myapp://oauth/callback"
        try await allowList([option, "https://x.test/cb"])
        let (client, recorder) = makeClient(auth: AuthConfig(oauthRedirectUri: option))
        client.links.appBaseURL = base

        let viaOption = try await client.auth.emailSignInRequest(email: email(), target: .automatic)
        XCTAssertTrue(viaOption.success)

        try await allowList(["https://x.test/cb"])
        let codeOnly = try await client.auth.emailSignInRequest(email: email(), target: .codeOnly)
        XCTAssertTrue(codeOnly.success)
        let explicit = try await client.auth.emailSignInRequest(email: email(), target: .uri("https://x.test/cb"))
        XCTAssertTrue(explicit.success)
        let explicitString = try await client.auth.emailSignInRequest(email: email(), redirectUri: "https://x.test/cb")
        XCTAssertTrue(explicitString.success)

        let calls = recorder.calls(to: requestPath)
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[0].bodyString("redirectUri"), option)
        XCTAssertFalse(calls[1].bodyHasKey("redirectUri"))
        XCTAssertEqual(calls[2].bodyString("redirectUri"), "https://x.test/cb")
        XCTAssertEqual(calls[3].bodyString("redirectUri"), "https://x.test/cb")
    }

    /// An empty `redirectUri` counts as absent, the same break as nil.
    func testAnEmptyRedirectUriPostsTheDerivedTarget() async throws {
        try await allowList([derived])
        let (client, recorder) = makeClient()
        client.links.appBaseURL = base

        let result = try await client.auth.emailSignInRequest(email: email(), redirectUri: "")
        XCTAssertTrue(result.success)
        XCTAssertEqual(recorder.calls(to: requestPath).first?.bodyString("redirectUri"), derived)
    }

    func testWithNothingConfiguredTheRequestCarriesNoTarget() async throws {
        try await allowList(["https://x.test/cb"])
        let (client, recorder) = makeClient()

        let result = try await client.auth.emailSignInRequest(email: email())
        XCTAssertTrue(result.success)
        XCTAssertEqual(recorder.calls(to: requestPath).count, 1)
        XCTAssertFalse(recorder.calls(to: requestPath)[0].bodyHasKey("redirectUri"))
    }
}
