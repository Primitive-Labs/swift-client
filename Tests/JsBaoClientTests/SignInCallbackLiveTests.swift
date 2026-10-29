import XCTest
@testable import JsBaoClient

/// `client.auth.handleSignInCallback` against the dev server: a `magic_token`
/// on `links.appBaseURL`'s origin goes to the magic-link verify, a `code` +
/// `state` pair to the OAuth exchange, and any other URL is refused before a
/// request. Here a bogus credential lets the server's own refusal prove the
/// routing; `SignInCallbackRealLinkLiveTests` completes a real sign-in with
/// the link from a captured email, and the OAuth success mapping is proven
/// purely in `SignInRulesHermeticTests` (no Google in a test process).
final class SignInCallbackLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var recorder: RecordingTransport!

    private let verifyPath = "/auth/magic-link/verify"
    private let exchangePath = "/oauth/callback"

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-sign-in-callback")
        try await ctx.updateTestApp(
            appId: testApp.appId,
            fields: [
                "emailSignInEnabled": true,
                "emailRedirectUris": ["https://app.test/oauth/callback"],
            ]
        )
        client = createSignInTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        client.links.appBaseURL = URL(string: "https://app.test")
        recorder = recordAuthRequests(of: client, appId: testApp.appId)
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private func encoded(_ value: String) -> String {
        try! AuthController.strictPercentEncode(value)
    }

    private func bag(_ fields: [String: String]) -> String {
        try! JSONCoding.encodeData(fields.mapValues { JSONValue.string($0) }).base64EncodedString()
    }

    private func status(of error: Error) -> Int? {
        (error as? HttpError)?.status
    }

    /// The error a call throws, failing the test if it returns.
    private func thrown<T>(_ call: () async throws -> T) async -> Error? {
        do {
            _ = try await call()
            XCTFail("expected the server to refuse the bogus credential")
            return nil
        } catch {
            return error
        }
    }

    func testAMagicTokenIsVerifiedOnceWithTheBagsInviteAndTheServersRefusalPassesThrough() async throws {
        let token = "bogus-\(UUID().uuidString)"
        let url = URL(string:
            "https://app.test/oauth/callback?magic_token=\(token)&state=\(encoded(bag(["inviteToken": "inv-bag"])))"
        )!

        let viaCallback = await thrown { try await client.auth.handleSignInCallback(url) }
        let calls = recorder.calls(to: verifyPath)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.method, .post)
        XCTAssertEqual(calls.first?.bodyString("token"), token)
        XCTAssertEqual(calls.first?.bodyString("inviteToken"), "inv-bag")

        let direct = await thrown {
            try await client.auth.magicLinkVerify(token: token, inviteToken: "inv-bag")
        }
        XCTAssertNotNil(viaCallback as? HttpError, "got \(String(describing: viaCallback))")
        XCTAssertEqual(status(of: viaCallback!), status(of: direct!))
        XCTAssertEqual(
            (viaCallback as? HttpError)?.serverMessage,
            (direct as? HttpError)?.serverMessage
        )
    }

    func testTheInviteParameterWinsAndNoInviteIsSentWithoutOne() async throws {
        let withBag = URL(string:
            "https://app.test/oauth/callback?magic_token=bogus-a&state=\(encoded(bag(["inviteToken": "inv-bag"])))"
        )!
        _ = await thrown { try await client.auth.handleSignInCallback(withBag, inviteToken: "inv-param") }
        let bare = URL(string: "https://app.test/oauth/callback?magic_token=bogus-b")!
        _ = await thrown { try await client.auth.handleSignInCallback(bare) }

        let calls = recorder.calls(to: verifyPath)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.bodyString("inviteToken"), "inv-param")
        XCTAssertEqual(calls.last?.bodyString("token"), "bogus-b")
        XCTAssertEqual(calls.last?.bodyHasKey("inviteToken"), false)
    }

    func testACodeAndStateAreExchangedOnceWithTheRawStateAndTheServersRefusalPassesThrough() async throws {
        let code = "bogus-code-\(UUID().uuidString)"
        let state = try AuthController.encodeOAuthState(redirectUri: "https://app.test/oauth/callback")
        let url = URL(string:
            "https://app.test/oauth/callback?code=\(code)&state=\(encoded(state))"
        )!

        let viaCallback = await thrown { try await client.auth.handleSignInCallback(url) }
        let calls = recorder.calls(to: exchangePath)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.method, .get)
        XCTAssertEqual(
            calls.first?.path,
            try AuthController.oauthCallbackPath(code: code, state: state),
            "the raw state goes to the exchange unchanged"
        )

        let direct = await thrown { try await client.handleOAuthCallback(code: code, state: state) }
        XCTAssertNotNil(viaCallback as? HttpError, "got \(String(describing: viaCallback))")
        XCTAssertEqual(status(of: viaCallback!), status(of: direct!))
        XCTAssertEqual(
            (viaCallback as? HttpError)?.serverMessage,
            (direct as? HttpError)?.serverMessage
        )
    }

    func testARefusedURLThrowsTheCodedErrorBeforeAnyRequest() async throws {
        let state = encoded(try AuthController.encodeOAuthState(redirectUri: "https://app.test/oauth/callback"))
        for (url, rule) in [
            ("https://other.test/oauth/callback?magic_token=bogus", "origin"),
            ("https://app.test/oauth%2Fcallback?magic_token=bogus", "path"),
            ("https://app.test/oauth/callback?code=bogus", "code without state"),
            ("https://app.test/oauth/callback?code=bogus&magic_token=bogus&state=\(state)", "both"),
            ("myapp://oauth/callback?magic_token=bogus", "scheme"),
        ] {
            do {
                _ = try await client.auth.handleSignInCallback(URL(string: url)!)
                XCTFail("expected \(url) to be refused")
            } catch let error as AuthError {
                XCTAssertEqual(error.code, .invalidToken, url)
                XCTAssertTrue(error.message.hasPrefix("Sign-in callback refused:"), error.message)
                XCTAssertTrue(error.message.contains(rule), "\(error.message) should name \(rule)")
            }
        }
        XCTAssertTrue(recorder.calls.isEmpty, "no request for a refused URL: \(recorder.calls.map(\.path))")
    }

    func testASchemeCallbackIsAcceptedWhenTheOptionRegistersIt() async throws {
        let scheme = createSignInTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            auth: AuthConfig(oauthRedirectUri: "myapp://oauth/callback")
        )
        defer { Task { await scheme.destroy() } }
        let schemeRecorder = recordAuthRequests(of: scheme, appId: testApp.appId)

        _ = await thrown {
            try await scheme.auth.handleSignInCallback(URL(string: "myapp://oauth/callback?magic_token=bogus-s")!)
        }
        XCTAssertEqual(schemeRecorder.calls(to: verifyPath).count, 1)
        XCTAssertEqual(schemeRecorder.calls(to: verifyPath).first?.bodyString("token"), "bogus-s")
    }
}
