import XCTest
@testable import JsBaoClient

/// Swift mirror of `tests/client/js-bao-client-auth-raw-fetch-parity.test.ts`
/// (issue #2658, parity items A7/A8). JS is the reference:
///
///   * A8 — with a refresh proxy configured, magic-link and OTP verify POST to
///     `{proxyBase}/auth/magic-link/verify` (resp. `/auth/otp/verify`), with a
///     body carrying no `appId`.
///   * A7 — the unauthenticated auth endpoints skip the refresh interceptor: no
///     expiry preflight, no refresh-and-retry on 401, and the server's error
///     code surfaces verbatim instead of `HttpError(401, "Invalid credentials")`.
///
/// Server-free. The stub answers both the `HttpClient` session (injected via the
/// session configuration) and `URLSession.shared` (registered globally, which is
/// what the proxy requests use — same wiring as
/// `AuthControllerProxyRefreshUrlTests`).
final class AuthUnauthenticatedEndpointsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(AuthEndpointCaptureURLProtocol.self)
        AuthEndpointCaptureURLProtocol.reset()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(AuthEndpointCaptureURLProtocol.self)
        AuthEndpointCaptureURLProtocol.reset()
        super.tearDown()
    }

    private func wire(
        proxyBaseUrl: String? = nil,
        token: String = makeTestJwt(userId: "u1")
    ) -> AuthController {
        let (auth, _) = makeWiredClients(
            initialToken: token,
            protocolClass: AuthEndpointCaptureURLProtocol.self,
            refreshProxy: proxyBaseUrl.map { RefreshProxyConfig(baseUrl: $0) }
        )
        return auth
    }

    // MARK: - A8: proxy verify URL and body

    func testMagicLinkVerifyPostsToProxyBase() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .success(
            token: makeTestJwt(userId: "u1")
        )
        let auth = wire(proxyBaseUrl: "http://proxy.local/base")

        _ = try await auth.magicLinkVerify(token: "magic-token")

        let call = try XCTUnwrap(
            AuthEndpointCaptureURLProtocol.firstCall(containing: "magic-link/verify")
        )
        XCTAssertEqual(call.url, "http://proxy.local/base/auth/magic-link/verify")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.jsonBody?["token"] as? String, "magic-token")
        XCTAssertNil(call.jsonBody?["appId"], "the JS proxy verify body carries no appId")
    }

    func testOtpVerifyPostsToProxyBase() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .success(
            token: makeTestJwt(userId: "u1")
        )
        let auth = wire(proxyBaseUrl: "http://proxy.local/base")

        _ = try await auth.otpVerify(email: "a@b.test", code: "123456")

        let call = try XCTUnwrap(
            AuthEndpointCaptureURLProtocol.firstCall(containing: "otp/verify")
        )
        XCTAssertEqual(call.url, "http://proxy.local/base/auth/otp/verify")
        XCTAssertEqual(call.jsonBody?["email"] as? String, "a@b.test")
        XCTAssertEqual(call.jsonBody?["code"] as? String, "123456")
        XCTAssertNil(call.jsonBody?["appId"])
    }

    /// A trailing-slash proxy base yields exactly one slash, same normalization
    /// the proxy refresh URL already applies (#1983).
    func testTrailingSlashProxyBaseHasNoDoubleSlash() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .success(
            token: makeTestJwt(userId: "u1")
        )
        let auth = wire(proxyBaseUrl: "http://proxy.local/base/")

        _ = try await auth.magicLinkVerify(token: "magic-token")

        let call = try XCTUnwrap(
            AuthEndpointCaptureURLProtocol.firstCall(containing: "magic-link/verify")
        )
        XCTAssertEqual(call.url, "http://proxy.local/base/auth/magic-link/verify")
    }

    /// Without a proxy the verify still goes to the API path.
    func testMagicLinkVerifyWithoutProxyUsesApiPath() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .success(
            token: makeTestJwt(userId: "u1")
        )
        let auth = wire()

        _ = try await auth.magicLinkVerify(token: "magic-token")

        let call = try XCTUnwrap(
            AuthEndpointCaptureURLProtocol.firstCall(containing: "magic-link/verify")
        )
        XCTAssertEqual(
            call.url,
            "http://stub.local/app/test-app/api/auth/magic-link/verify"
        )
    }

    /// A proxy that is configured but disabled keeps the direct API path.
    func testDisabledProxyUsesApiPath() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .success(
            token: makeTestJwt(userId: "u1")
        )
        let (auth, _) = makeWiredClients(
            initialToken: makeTestJwt(userId: "u1"),
            protocolClass: AuthEndpointCaptureURLProtocol.self,
            refreshProxy: RefreshProxyConfig(
                baseUrl: "http://proxy.local/base",
                enabled: false
            )
        )

        _ = try await auth.magicLinkVerify(token: "magic-token")

        let call = try XCTUnwrap(
            AuthEndpointCaptureURLProtocol.firstCall(containing: "magic-link/verify")
        )
        XCTAssertEqual(
            call.url,
            "http://stub.local/app/test-app/api/auth/magic-link/verify"
        )
    }

    // MARK: - A7: no refresh interceptor on unauthenticated endpoints

    func testVerify401SurfacesServerCodeAndDoesNotRetry() async {
        AuthEndpointCaptureURLProtocol.verifyResponse = .failure(
            status: 401,
            code: "INVITE_TOKEN_EXPIRED",
            error: "Invite token expired"
        )
        let auth = wire()

        do {
            _ = try await auth.magicLinkVerify(token: "magic-token", inviteToken: "invite-1")
            XCTFail("expected the 401 to surface")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(
                error.serverCode,
                "INVITE_TOKEN_EXPIRED",
                "the server's error code must survive; a refresh replaces it with 'Invalid credentials'"
            )
        } catch {
            XCTFail("expected HttpError, got \(error)")
        }

        XCTAssertEqual(
            AuthEndpointCaptureURLProtocol.count(containing: "magic-link/verify"),
            1,
            "the single-use credential must not be re-posted"
        )
        XCTAssertEqual(
            AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"),
            0,
            "an unauthenticated verify must not trigger a token refresh"
        )
    }

    func testOtpVerify401SurfacesServerCodeAndDoesNotRetry() async {
        AuthEndpointCaptureURLProtocol.verifyResponse = .failure(
            status: 401,
            code: "OTP_CODE_EXPIRED",
            error: "Code expired"
        )
        let auth = wire()

        do {
            _ = try await auth.otpVerify(email: "a@b.test", code: "123456")
            XCTFail("expected the 401 to surface")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "OTP_CODE_EXPIRED")
        } catch {
            XCTFail("expected HttpError, got \(error)")
        }

        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "otp/verify"), 1)
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"), 0)
    }

    func testPasskeyAuthStart401DoesNotRefresh() async {
        AuthEndpointCaptureURLProtocol.verifyResponse = .failure(
            status: 401,
            code: "PASSKEY_NOT_FOUND",
            error: "No passkeys"
        )
        let auth = wire()

        do {
            _ = try await auth.passkeyAuthStart()
            XCTFail("expected the 401 to surface")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "PASSKEY_NOT_FOUND")
        } catch {
            XCTFail("expected HttpError, got \(error)")
        }

        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/passkey/auth/start"), 1)
        XCTAssertEqual(AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"), 0)
    }

    /// An access token inside the 120s expiry window makes `executeRaw`
    /// pre-refresh. An unauthenticated auth endpoint must not do that.
    func testExpiringTokenDoesNotPreflightRefreshOnUnauthenticatedEndpoint() async throws {
        AuthEndpointCaptureURLProtocol.verifyResponse = .successJson("{\"success\": true}")
        let expiring = makeTestJwt(
            userId: "u1",
            exp: Int(Date().timeIntervalSince1970) + 30
        )
        let auth = wire(token: expiring)

        _ = try await auth.magicLinkRequest(
            email: "a@b.test",
            redirectUri: "http://app.local/callback"
        )

        XCTAssertEqual(
            AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"),
            0,
            "an unauthenticated auth endpoint must not run the expiry preflight"
        )
    }

    /// The exemption must not widen to authenticated endpoints: a 401 from
    /// `GET /me` still refreshes and retries.
    func testAuthenticatedEndpointStillRefreshesOn401() async throws {
        AuthEndpointCaptureURLProtocol.refreshedToken = makeTestJwt(userId: "u1-fresh")
        let (_, http) = makeWiredClients(
            initialToken: makeTestJwt(userId: "u1"),
            protocolClass: AuthEndpointCaptureURLProtocol.self
        )

        let response = try await http.requestRaw(method: "GET", path: "/me")

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            AuthEndpointCaptureURLProtocol.count(containing: "/auth/refresh"),
            1,
            "an authenticated 401 must still refresh once and retry"
        )
    }
}

// MARK: - Stub

/// Records every request and answers the auth endpoints from a script.
///
/// State is static (the loading system builds a fresh instance per request) and
/// lives in one `LockedBox`, matching `RefreshStubURLProtocol`.
final class AuthEndpointCaptureURLProtocol: URLProtocol {

    struct Call: Sendable {
        let url: String
        let method: String
        let body: Data?

        /// The body decoded as a JSON object. Computed rather than stored so
        /// the recorded call stays `Sendable` under the Swift 6 language mode.
        var jsonBody: [String: Any]? {
            guard let body = body, !body.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    /// What the auth endpoints under test answer with.
    enum ScriptedResponse: Sendable {
        /// 200 with `{token, user}` — the shape the verify endpoints return.
        case success(token: String)
        /// 200 with the given JSON object text.
        case successJson(String)
        /// A non-2xx with the server's `{error, code}` envelope.
        case failure(status: Int, code: String, error: String)
    }

    private struct Script {
        var calls: [Call] = []
        var verifyResponse: ScriptedResponse = .successJson("{}")
        var refreshedToken = ""
    }

    private static let script = LockedBox(Script())

    static var verifyResponse: ScriptedResponse {
        get { script.value.verifyResponse }
        set { script.withValue { $0.verifyResponse = newValue } }
    }

    static var refreshedToken: String {
        get { script.value.refreshedToken }
        set { script.withValue { $0.refreshedToken = newValue } }
    }

    static func reset() { script.value = Script() }

    static func count(containing fragment: String) -> Int {
        script.value.calls.filter { $0.url.contains(fragment) }.count
    }

    static func firstCall(containing fragment: String) -> Call? {
        script.value.calls.first { $0.url.contains(fragment) }
    }

    /// Only this suite's two synthetic hosts. The stub is registered globally
    /// (the proxy requests go through `URLSession.shared`), so a `true` here
    /// would also answer traffic from the live-server suites that run in the
    /// same process — answering another suite's client with a 401 sends it into
    /// a refresh loop and the run stops making progress.
    private static let stubbedHosts: Set<String> = ["stub.local", "proxy.local"]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return stubbedHosts.contains(host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let call = Call(
            url: url.absoluteString,
            method: request.httpMethod ?? "GET",
            body: Self.readBody(request)
        )
        Self.script.withValue { $0.calls.append(call) }

        if url.path.hasSuffix("/auth/refresh") {
            let token = Self.script.value.refreshedToken
            if token.isEmpty {
                respond(status: 401, json: ["error": "invalid_refresh"])
            } else {
                respond(status: 200, json: ["token": token])
            }
            return
        }

        // The endpoints under test answer from the script; everything else
        // (`GET /me`) authorizes only the refreshed bearer token, so the first
        // attempt 401s and drives the caller into the refresh branch.
        if Self.isScriptedAuthPath(url.path) {
            switch Self.script.value.verifyResponse {
            case .success(let token):
                respond(status: 200, json: [
                    "token": token,
                    "user": ["userId": "u1", "email": "a@b.test"],
                ])
            case .successJson(let text):
                respondRaw(status: 200, body: Data(text.utf8))
            case .failure(let status, let code, let error):
                respond(status: status, json: ["error": error, "code": code])
            }
            return
        }

        let auth = request.value(forHTTPHeaderField: "Authorization")
        let refreshed = Self.script.value.refreshedToken
        if let auth = auth, !refreshed.isEmpty, auth == "Bearer \(refreshed)" {
            respond(status: 200, json: ["userId": "u1"])
        } else {
            respond(status: 401, json: ["error": "unauthorized"])
        }
    }

    override func stopLoading() {}

    private static func isScriptedAuthPath(_ path: String) -> Bool {
        [
            "/auth/magic-link/request",
            "/auth/magic-link/verify",
            "/auth/otp/request",
            "/auth/otp/verify",
            "/passkey/auth/start",
            "/passkey/auth/finish",
            "/oauth-config",
        ].contains { path.hasSuffix($0) }
    }

    /// `URLSession` moves a request body onto `httpBodyStream` before a
    /// `URLProtocol` sees it, so `httpBody` alone is not enough.
    private static func readBody(_ request: URLRequest) -> Data? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data = data, !data.isEmpty else { return nil }
        return data
    }

    private func respond(status: Int, json: [String: Any]) {
        respondRaw(status: status, body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private func respondRaw(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
