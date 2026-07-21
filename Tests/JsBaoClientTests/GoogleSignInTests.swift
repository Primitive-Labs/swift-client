import XCTest
@testable import JsBaoClient

/// Tests for the native Google sign-in surface (#928).
///
/// The interactive piece (ASWebAuthenticationSession) can't run headless, so
/// these tests cover everything around it: authorize-URL construction, state
/// encoding, callback parsing, redirect-URI/scheme derivation, plist loading,
/// and error mapping. `GoogleSignInLiveTests` additionally exercises the
/// server endpoints (`GET /oauth-config`, `GET /oauth/callback`) against the
/// local dev server.
final class GoogleSignInUnitTests: XCTestCase {

    // MARK: - OAuth state encoding

    func testEncodeOAuthStateIncludesNonceAndRedirectUri() throws {
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/oauth2redirect/google",
            nonce: "test-nonce"
        )
        let data = try XCTUnwrap(Data(base64Encoded: state))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["nonce"] as? String, "test-nonce")
        XCTAssertEqual(json["redirectUri"] as? String, "com.example:/oauth2redirect/google")
        // JS omits continueUrl when absent — no null placeholder.
        XCTAssertFalse(json.keys.contains("continueUrl"))
    }

    func testEncodeOAuthStateIncludesContinueUrlWhenPresent() throws {
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/oauth2redirect/google",
            continueUrl: "https://example.com/after"
        )
        let data = try XCTUnwrap(Data(base64Encoded: state))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["continueUrl"] as? String, "https://example.com/after")
        XCTAssertNotNil(json["nonce"] as? String)
    }

    // MARK: - Authorize URL construction

    func testBuildGoogleAuthorizationUrl() throws {
        let url = try AuthController.buildGoogleAuthorizationUrl(
            googleClientId: "123-abc.apps.googleusercontent.com",
            redirectUri: "com.googleusercontent.apps.123-abc:/oauth2redirect/google",
            state: "c3RhdGU="
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")

        let items = try XCTUnwrap(components.queryItems)
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        XCTAssertEqual(value("client_id"), "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(
            value("redirect_uri"),
            "com.googleusercontent.apps.123-abc:/oauth2redirect/google"
        )
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("scope"), "openid email profile")
        XCTAssertEqual(value("state"), "c3RhdGU=")
    }

    func testBuildGoogleAuthorizationUrlStrictlyEncodesState() throws {
        // base64 alphabet includes '+', '/', '=' — all must be percent-encoded
        // on the wire or Google decodes '+' as a space and corrupts the state.
        let url = try AuthController.buildGoogleAuthorizationUrl(
            googleClientId: "id",
            redirectUri: "scheme:/cb",
            state: "ab+cd/ef=="
        )
        let raw = url.absoluteString
        XCTAssertTrue(raw.contains("state=ab%2Bcd%2Fef%3D%3D"), "got: \(raw)")
        XCTAssertTrue(raw.contains("scope=openid%20email%20profile"), "got: \(raw)")
        XCTAssertTrue(raw.contains("redirect_uri=scheme%3A%2Fcb"), "got: \(raw)")
    }

    // MARK: - PKCE (RFC 7636)

    func testPkceChallengeMatchesRfc7636TestVector() {
        // Appendix B of RFC 7636: the canonical verifier → S256 challenge.
        XCTAssertEqual(
            AuthController.pkceChallenge(
                forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            ),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGeneratePkceVerifierShapeAndUniqueness() {
        let verifier = AuthController.generatePkceVerifier()
        // RFC 7636 §4.1: 43–128 characters from the unreserved set
        // (ALPHA / DIGIT / "-" / "." / "_" / "~"). 32 random bytes
        // base64url-encoded gives exactly 43.
        XCTAssertEqual(verifier.count, 43)
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        XCTAssertTrue(
            verifier.unicodeScalars.allSatisfy { allowed.contains($0) },
            "unexpected characters in verifier: \(verifier)"
        )
        // Fresh per flow.
        XCTAssertNotEqual(verifier, AuthController.generatePkceVerifier())
    }

    func testBuildGoogleAuthorizationUrlCarriesPkceChallenge() throws {
        let url = try AuthController.buildGoogleAuthorizationUrl(
            googleClientId: "id",
            redirectUri: "scheme:/cb",
            state: "c3RhdGU=",
            codeChallenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        XCTAssertEqual(
            value("code_challenge"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        XCTAssertEqual(value("code_challenge_method"), "S256")
    }

    func testBuildGoogleAuthorizationUrlOmitsPkceWhenNoChallenge() throws {
        // Back-compat: callers that don't run PKCE produce the pre-PKCE URL.
        let url = try AuthController.buildGoogleAuthorizationUrl(
            googleClientId: "id",
            redirectUri: "scheme:/cb",
            state: "c3RhdGU="
        )
        XCTAssertFalse(url.absoluteString.contains("code_challenge"))
    }

    // MARK: - Callback exchange path

    func testOauthCallbackPathEncodesCodeAndState() throws {
        let path = try AuthController.oauthCallbackPath(
            code: "4/0Ab+c/d=",
            state: "eyJh+bGc/iJ9=="
        )
        XCTAssertEqual(
            path,
            "/oauth/callback?code=4%2F0Ab%2Bc%2Fd%3D&state=eyJh%2BbGc%2FiJ9%3D%3D"
        )
    }

    func testOauthCallbackPathIsPrePkceShape() throws {
        // The GET path never carries the PKCE verifier — the server only
        // reads it from `POST /auth/oauth/callback` (JSON `codeVerifier`),
        // which `handleOAuthCallback` uses whenever a verifier is pending.
        let bare = try AuthController.oauthCallbackPath(code: "abc", state: "c3RhdGU=")
        XCTAssertEqual(bare, "/oauth/callback?code=abc&state=c3RhdGU%3D")
    }

    func testHandleOAuthCallbackEmitsGoogleAuthCause() async throws {
        let emitter = EventEmitter()
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: emitter,
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.makeRequest = { _, _, _ in
            ["token": "token-google", "isNewUser": false]
        }

        let events = try await collectEvents(from: emitter, event: .authSuccess) {
            _ = try await controller.handleOAuthCallback(code: "code", state: "state")
        }

        let success = try XCTUnwrap(events.first as? AuthSuccessEvent)
        XCTAssertEqual(success.token, "token-google")
        XCTAssertEqual(success.cause, "google")
    }

    func testStrictPercentEncodeLeavesUnreservedCharacters() throws {
        let encoded = try AuthController.strictPercentEncode("AZaz09-._~")
        XCTAssertEqual(encoded, "AZaz09-._~")
        XCTAssertEqual(try AuthController.strictPercentEncode("a b:c"), "a%20b%3Ac")
    }

    // MARK: - Callback URL parsing

    func testParseOAuthCallbackExtractsCodeAndState() throws {
        let url = try XCTUnwrap(URL(
            string: "com.googleusercontent.apps.123:/oauth2redirect/google?code=4%2FabcDEF&state=c3RhdGU%3D&scope=email"
        ))
        let (code, state) = try GoogleSignInHelpers.parseOAuthCallback(url: url)
        XCTAssertEqual(code, "4/abcDEF")
        XCTAssertEqual(state, "c3RhdGU=")
    }

    func testParseOAuthCallbackThrowsProviderError() {
        let url = URL(string: "com.example:/oauth2redirect/google?error=access_denied")!
        XCTAssertThrowsError(try GoogleSignInHelpers.parseOAuthCallback(url: url)) { error in
            XCTAssertEqual(error as? OAuthSignInError, .providerError("access_denied"))
        }
    }

    func testParseOAuthCallbackThrowsOnMissingParameters() {
        // Missing state
        let noState = URL(string: "com.example:/oauth2redirect/google?code=abc")!
        XCTAssertThrowsError(try GoogleSignInHelpers.parseOAuthCallback(url: noState)) { error in
            XCTAssertEqual(error as? OAuthSignInError, .missingCallbackParameters)
        }
        // Missing everything
        let empty = URL(string: "com.example:/oauth2redirect/google")!
        XCTAssertThrowsError(try GoogleSignInHelpers.parseOAuthCallback(url: empty)) { error in
            XCTAssertEqual(error as? OAuthSignInError, .missingCallbackParameters)
        }
    }

    // MARK: - Redirect URI / callback scheme derivation

    func testRedirectUriForReversedClientId() {
        XCTAssertEqual(
            GoogleSignInHelpers.redirectUri(
                forReversedClientId: "com.googleusercontent.apps.123-abc"
            ),
            "com.googleusercontent.apps.123-abc:/oauth2redirect/google"
        )
    }

    func testCallbackSchemeFromRedirectUri() {
        XCTAssertEqual(
            GoogleSignInHelpers.callbackScheme(
                forRedirectUri: "com.googleusercontent.apps.123:/oauth2redirect/google"
            ),
            "com.googleusercontent.apps.123"
        )
        XCTAssertEqual(
            GoogleSignInHelpers.callbackScheme(forRedirectUri: "myapp://auth/callback"),
            "myapp"
        )
        XCTAssertNil(GoogleSignInHelpers.callbackScheme(forRedirectUri: "no-scheme-here"))
        XCTAssertNil(GoogleSignInHelpers.callbackScheme(forRedirectUri: ":/missing"))
    }

    // MARK: - GoogleService-Info.plist loading

    func testLoadReversedGoogleClientIdFromPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-signin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plistUrl = dir.appendingPathComponent("GoogleService-Info.plist")
        let plist: [String: Any] = [
            "CLIENT_ID": "123-abc.apps.googleusercontent.com",
            "REVERSED_CLIENT_ID": "com.googleusercontent.apps.123-abc",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: plistUrl)

        XCTAssertEqual(
            GoogleSignInHelpers.loadReversedGoogleClientId(from: [plistUrl]),
            "com.googleusercontent.apps.123-abc"
        )
    }

    func testLoadReversedGoogleClientIdReturnsNilWhenAbsent() {
        let missing = URL(fileURLWithPath: "/nonexistent/GoogleService-Info.plist")
        XCTAssertNil(GoogleSignInHelpers.loadReversedGoogleClientId(from: [missing]))
    }

    // MARK: - Error surface

    func testCancelledErrorIsTyped() {
        // The user-cancel case must be a distinct, switchable error so apps
        // can silently dismiss instead of showing an alert.
        let error: Error = OAuthSignInError.cancelled
        XCTAssertEqual(error as? OAuthSignInError, .cancelled)
        XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
    }
}

/// Live tests against the local dev server (`node debug-server.js`).
/// Covers the non-interactive halves of the flow: authorize-URL construction
/// from the app's real `GET /oauth-config`, and the `GET /oauth/callback`
/// exchange endpoint's error handling.
final class GoogleSignInLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-google-signin")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testStartOAuthFlowBuildsAuthorizeUrlFromServerConfig() async throws {
        // NOTE: the admin API currently only allow-lists https/localhost
        // redirect URIs, so a custom-scheme URI (the native
        // `com.googleusercontent.apps.*:/oauth2redirect/google` shape) can't
        // be registered against today's server. Use an https URI here — the
        // client-side flow under test is identical either way.
        let redirectUri = "https://example.com/oauth/callback"
        _ = try await ctx.updateTestApp(appId: testApp.appId, fields: [
            "googleClientId": "test-123.apps.googleusercontent.com",
            "googleClientSecret": "test-secret",
            "googleOAuthEnabled": true,
            "redirectUris": [redirectUri],
        ])

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let url = try await client.startOAuthFlow(redirectUri: redirectUri)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")

        let items = try XCTUnwrap(components.queryItems)
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        XCTAssertEqual(value("client_id"), "test-123.apps.googleusercontent.com")
        XCTAssertEqual(value("redirect_uri"), redirectUri)
        XCTAssertEqual(value("response_type"), "code")

        // State must round-trip: base64 → JSON with our redirectUri + a nonce.
        let stateB64 = try XCTUnwrap(value("state"))
        let stateData = try XCTUnwrap(Data(base64Encoded: stateB64))
        let stateJson = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        )
        XCTAssertEqual(stateJson["redirectUri"] as? String, redirectUri)
        XCTAssertNotNil(stateJson["nonce"] as? String)
    }

    func testStartOAuthFlowThrowsWhenOAuthNotConfigured() async throws {
        // Fresh app has no googleClientId — mirrors the JS client throwing
        // "OAuth not configured".
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            _ = try await client.startOAuthFlow(redirectUri: "com.example:/cb")
            XCTFail("Expected startOAuthFlow to throw for unconfigured app")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
            XCTAssertTrue(error.message.contains("OAuth not configured"), "got: \(error.message)")
        }
    }

    func testHandleOAuthCallbackRejectsInvalidState() async throws {
        // Proves the exchange hits the real `GET /oauth/callback` route (the
        // server answers 400 "Invalid state parameter", not 404/405) and that
        // the error surfaces as a typed HttpError.
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            _ = try await client.handleOAuthCallback(code: "bogus-code", state: "not-base64!")
            XCTFail("Expected handleOAuthCallback to throw for invalid state")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400, "body: \(error.body ?? "nil")")
        }
    }

    func testHandleOAuthCallbackRejectsUnlistedRedirectUri() async throws {
        // Well-formed state whose redirectUri is not in the app's allow-list:
        // the server must reject it (400 "Invalid redirect URI") before ever
        // talking to Google.
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.attacker:/oauth2redirect/google"
        )
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            _ = try await client.handleOAuthCallback(code: "bogus-code", state: state)
            XCTFail("Expected handleOAuthCallback to throw for unlisted redirect URI")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400, "body: \(error.body ?? "nil")")
        }
    }
}
