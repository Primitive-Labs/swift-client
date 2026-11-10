import XCTest
@testable import JsBaoClient

/// The Swift client reads an app's sign-in settings from the public
/// `GET settings/sign-in` (#5362, project `api-surface-stability` phase 10),
/// and that read keeps the unauthenticated endpoints' exemption from the
/// refresh interceptor: no expiry preflight, no refresh-and-retry on a 401 or
/// a 404, and the server's error code surfaces verbatim.
///
/// Server-free, over `AuthEndpointCaptureURLProtocol` and `makeWiredClients`
/// (the declared exception in the #5362 spec: the exemption is observable only
/// by counting refresh requests). `startOAuthFlow` is driven end to end; the
/// `auth.getAuthConfig()` / `auth.getAppConfig()` closures `JsBaoClient` wires
/// make the same `HttpClient` request this class sends, and are exercised
/// against the dev server by `SignInSettingsLiveTests`.
final class SignInSettingsPathHermeticTests: XCTestCase {

    private static let settingsUrl = "http://stub.local/app/test-app/api/settings/sign-in"

    /// A sign-in settings body with a usable `ios` Google client.
    private static let settingsJson = """
    {"appId": "test-app", "name": "Test App", "mode": "public",
     "waitlistEnabled": false, "googleOAuthEnabled": true,
     "googleClients": {"clients": {"ios": {"clientId": "ios-client.apps.googleusercontent.com",
       "redirectUris": ["com.example.app:/oauth2redirect"], "usable": true}}},
     "appleSignInEnabled": false, "appleAudiences": null, "hasApple": false,
     "passkeyEnabled": false, "passkeyRpConfig": null, "hasPasskey": false,
     "emailSignInEnabled": true}
    """

    override func setUp() {
        super.setUp()
        AuthEndpointCaptureURLProtocol.reset()
    }

    override func tearDown() {
        AuthEndpointCaptureURLProtocol.reset()
        super.tearDown()
    }

    private func wire(token: String = makeTestJwt(userId: "u1")) -> (auth: AuthController, http: HttpClient) {
        makeWiredClients(
            initialToken: token,
            protocolClass: AuthEndpointCaptureURLProtocol.self
        )
    }

    func testStartOAuthFlowReadsSettingsSignIn() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .successJson(Self.settingsJson)
        let (auth, _) = wire()

        let url = try await auth.startOAuthFlow(redirectUri: "com.example.app:/oauth2redirect")

        XCTAssertTrue(url.absoluteString.contains("ios-client.apps.googleusercontent.com"))
        let call = try XCTUnwrap(AuthEndpointCaptureURLProtocol.firstCall(containing: "/api/"))
        XCTAssertEqual(call.url, Self.settingsUrl)
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "oauth-config"), 0)
    }

    func testTheConfigReadsDecodeTheSettingsSignInBody() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .successJson(Self.settingsJson)
        let (_, http) = wire()

        let config: AuthConfigInfo = try await http.request(method: .get, path: "/settings/sign-in")
        let app: AppConfigInfo = try await http.request(method: .get, path: "/settings/sign-in")

        XCTAssertEqual(config.nativeGoogleClient?.clientId, "ios-client.apps.googleusercontent.com")
        XCTAssertTrue(config.emailSignInEnabled)
        XCTAssertEqual(app.appId, "test-app")
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/settings/sign-in"), 2)
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "oauth-config"), 0)
    }

    func testA401SurfacesTheServerCodeWithoutRefreshing() async {
        AuthEndpointCaptureURLProtocol.verifyResponse = .failure(
            status: 401,
            code: "UNAUTHORIZED",
            error: "Not signed in"
        )
        let (_, http) = wire()

        do {
            let _: AuthConfigInfo = try await http.request(method: .get, path: "/settings/sign-in")
            XCTFail("expected the 401 to surface")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.serverCode, "UNAUTHORIZED")
        } catch {
            XCTFail("expected HttpError, got \(error)")
        }

        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/settings/sign-in"), 1)
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"), 0)
    }

    func testA404SurfacesNotFoundWithoutRefreshing() async {
        AuthEndpointCaptureURLProtocol.verifyResponse = .failure(
            status: 404,
            code: "NOT_FOUND",
            error: "App not found"
        )
        let (auth, _) = wire()

        do {
            _ = try await auth.startOAuthFlow(redirectUri: "com.example.app:/oauth2redirect")
            XCTFail("expected the 404 to surface")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.serverCode, "NOT_FOUND")
        } catch {
            XCTFail("expected HttpError, got \(error)")
        }

        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/settings/sign-in"), 1)
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "oauth-config"), 0)
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"), 0)
    }

    func testAnExpiringTokenRunsNoPreflightRefresh() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .successJson(Self.settingsJson)
        let expiring = makeTestJwt(
            userId: "u1",
            exp: Int(Date().timeIntervalSince1970) + 30
        )
        let (_, http) = wire(token: expiring)

        let _: AuthConfigInfo = try await http.request(method: .get, path: "/settings/sign-in")

        XCTAssertEqual(
            AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"),
            0,
            "the sign-in settings read must not run the expiry preflight"
        )
    }
}
