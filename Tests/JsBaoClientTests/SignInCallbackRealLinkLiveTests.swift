import XCTest
@testable import JsBaoClient

/// A real email sign-in from a Swift process, against the dev server: the
/// client requests an email, `TestContext.latestSignInCredentials` reads the
/// code and link the server captured instead of sending it, and the client
/// finishes the sign-in with them. The server is the oracle throughout: a
/// consumed credential is refused 401, and either credential retires the
/// other.
final class SignInCallbackRealLinkLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-sign-in-real-link")
        try await ctx.updateTestApp(
            appId: testApp.appId,
            fields: [
                "emailSignInEnabled": true,
                "emailRedirectUris": ["https://app.test/oauth/callback"],
            ]
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    /// A signed-out client whose emailed links land on `https://app.test`.
    private func makeClient() -> JsBaoClient {
        let client = createSignInTestClient(appId: testApp.appId)
        client.links.appBaseURL = URL(string: "https://app.test")
        clients.append(client)
        return client
    }

    private func email() -> String { "real-link-\(UUID().uuidString.prefix(8).lowercased())@example.com" }

    /// Request one sign-in email and read it back, skipping captures already seen.
    private func signInEmail(
        _ client: JsBaoClient, to address: String, excluding: Set<String> = []
    ) async throws -> (captureId: String, signIn: SignInCredentials) {
        let requested = try await client.auth.emailSignInRequest(email: address)
        XCTAssertTrue(requested.success)
        return try await ctx.latestSignInCredentials(appId: testApp.appId, recipient: address, excluding: excluding)
    }

    private func linkURL(_ signIn: SignInCredentials) throws -> URL {
        let link = try XCTUnwrap(signIn.link, "the email carries a link")
        return try XCTUnwrap(URL(string: link))
    }

    /// The status of the `HttpError` a call throws, failing the test if it returns.
    private func refusalStatus<T>(_ call: () async throws -> T) async -> Int? {
        do {
            _ = try await call()
            XCTFail("expected the server to refuse the consumed credential")
            return nil
        } catch let error as HttpError {
            return error.status
        } catch {
            XCTFail("expected HttpError, got \(error)")
            return nil
        }
    }

    func testARealMagicLinkSignsTheClientInAndCannotBeReplayed() async throws {
        let client = makeClient()
        let address = email()
        XCTAssertFalse(client.auth.isAuthenticated())

        let (captureId, signIn) = try await signInEmail(client, to: address)
        XCTAssertFalse(captureId.isEmpty)
        XCTAssertNotNil(signIn.code)
        let url = try linkURL(signIn)

        let result = try await client.auth.handleSignInCallback(url)
        XCTAssertEqual(result.method, .magicLink)
        XCTAssertEqual(result.user?.email, address)
        XCTAssertFalse(result.userId.isEmpty)
        XCTAssertEqual(result.isNewUser, true)
        XCTAssertTrue(client.auth.isAuthenticated())
        XCTAssertNotNil(client.auth.token)

        let replay = await refusalStatus { try await client.auth.handleSignInCallback(url) }
        XCTAssertEqual(replay, 401)
    }

    func testTheCodeSignsInAndRetiresTheLinkFromTheSameEmail() async throws {
        let client = makeClient()
        let address = email()

        let (_, signIn) = try await signInEmail(client, to: address)
        let code = try XCTUnwrap(signIn.code, "the email carries a code")
        let url = try linkURL(signIn)

        let verified = try await client.auth.otpVerify(email: address, code: code)
        XCTAssertEqual(verified.user.email, address)

        let link = await refusalStatus { try await client.auth.handleSignInCallback(url) }
        XCTAssertEqual(link, 401)
    }

    func testASecondSignInUsesTheNewerEmailNotTheConsumedOne() async throws {
        let address = email()
        let first = makeClient()
        let (firstId, firstSignIn) = try await signInEmail(first, to: address)
        let firstResult = try await first.auth.handleSignInCallback(try linkURL(firstSignIn))
        XCTAssertEqual(firstResult.isNewUser, true)

        let second = makeClient()
        let (secondId, secondSignIn) = try await signInEmail(second, to: address, excluding: [firstId])
        XCTAssertNotEqual(secondId, firstId)
        XCTAssertNotNil(secondSignIn.magicToken)
        XCTAssertNotEqual(secondSignIn.magicToken, firstSignIn.magicToken)

        let secondResult = try await second.auth.handleSignInCallback(try linkURL(secondSignIn))
        XCTAssertEqual(secondResult.isNewUser, false)
        XCTAssertEqual(secondResult.userId, firstResult.userId)
        XCTAssertTrue(second.auth.isAuthenticated())
    }
}
