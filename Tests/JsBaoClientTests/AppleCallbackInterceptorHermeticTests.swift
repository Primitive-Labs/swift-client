import XCTest
@testable import JsBaoClient

/// Server-free pins for the native Sign in with Apple callback and the refresh
/// interceptor (#3084).
///
/// `POST /auth/apple/callback` is an *unauthenticated* auth endpoint, exactly
/// like the native Google callback (`POST /auth/oauth/callback`): a signed-out
/// client posts a single-use Apple identity token to it. When the server
/// rejects the sign-in (`ADDED_TO_WAITLIST`, `APPLE_IDENTITY_INVALID`, …) with
/// a 401, running the refresh interceptor over that answer refreshes a session
/// that doesn't exist, and the refresh's own rejection replaces the server's
/// body with `HttpError(401, "Invalid credentials")` — the app loses the code
/// it has to branch on, and sees an `authFailed` for a sign-in it made with no
/// session at all. The two provider paths must agree.
final class AppleCallbackInterceptorHermeticTests: XCTestCase {

    /// Thread-safe event log.
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    override func setUp() {
        super.setUp()
        AppleCallbackStubURLProtocol.reset()
    }

    override func tearDown() {
        AppleCallbackStubURLProtocol.reset()
        super.tearDown()
    }

    private func wire(
        token: String = "",
        emitter: EventEmitter = EventEmitter()
    ) -> (auth: AuthController, http: HttpClient) {
        makeWiredClients(
            initialToken: token,
            protocolClass: AppleCallbackStubURLProtocol.self,
            emitter: emitter
        )
    }

    private func appleCallback(_ auth: AuthController) async throws -> OAuthCallbackResult {
        try await auth.handleAppleCallback(
            identityToken: "eyJ.identity.token",
            rawNonce: "raw-nonce",
            user: "001234.abcdef.5678"
        )
    }

    // MARK: - Behavior 1: the server's own code and message reach the caller

    func testAppleCallback401CarriesServerCodeAndMessage() async {
        AppleCallbackStubURLProtocol.appleResponse = .failure(
            status: 401,
            code: "ADDED_TO_WAITLIST",
            error: "This app is invite-only. You've been added to the waitlist."
        )
        let (auth, _) = wire()

        do {
            _ = try await appleCallback(auth)
            XCTFail("expected the Apple 401 to surface")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(
                error.serverCode,
                "ADDED_TO_WAITLIST",
                "a refresh over the Apple 401 replaces the code with 'Invalid credentials'"
            )
            XCTAssertEqual(
                error.authCode,
                .addedToWaitlist,
                "the app branches on the typed AuthCode"
            )
            XCTAssertEqual(
                error.serverMessage,
                "This app is invite-only. You've been added to the waitlist."
            )
        } catch {
            XCTFail("expected HttpError, got \(error)")
        }
    }

    /// The other rejection codes take the same path — nothing about the fix is
    /// specific to the waitlist answer — and each resolves to a typed
    /// `AuthCode` so the app branches without comparing raw strings.
    func testAppleCallback401CarriesIdentityRejectionCode() async {
        let rejections: [(raw: String, typed: AuthCode, message: String)] = [
            ("APPLE_IDENTITY_INVALID", .appleIdentityInvalid, "Apple identity token invalid"),
            ("APPLE_IDENTITY_UNKNOWN", .appleIdentityUnknown, "No account for this Apple ID"),
        ]

        for rejection in rejections {
            AppleCallbackStubURLProtocol.reset()
            AppleCallbackStubURLProtocol.appleResponse = .failure(
                status: 401,
                code: rejection.raw,
                error: rejection.message
            )
            let (auth, _) = wire()

            do {
                _ = try await appleCallback(auth)
                XCTFail("expected the Apple 401 to surface for \(rejection.raw)")
            } catch let error as HttpError {
                XCTAssertEqual(error.serverCode, rejection.raw)
                XCTAssertEqual(
                    error.authCode,
                    rejection.typed,
                    "\(rejection.raw) must resolve to a typed AuthCode"
                )
                XCTAssertEqual(error.serverMessage, rejection.message)
            } catch {
                XCTFail("expected HttpError, got \(error)")
            }
        }
    }

    // MARK: - Behavior 2: no refresh, no re-post, no authFailed

    func testAppleCallback401DoesNotRefreshOrEmitAuthFailed() async {
        AppleCallbackStubURLProtocol.appleResponse = .failure(
            status: 401,
            code: "ADDED_TO_WAITLIST",
            error: "This app is invite-only. You've been added to the waitlist."
        )
        let emitter = EventEmitter()
        let failures = Recorder<AuthFailedEvent>()
        let sub = emitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
        defer { sub.cancel() }
        let (auth, _) = wire(emitter: emitter)

        _ = try? await appleCallback(auth)

        XCTAssertEqual(
            AppleCallbackStubURLProtocol.refreshCount,
            0,
            "a sign-in attempt made with no session must not refresh"
        )
        XCTAssertEqual(
            AppleCallbackStubURLProtocol.appleCount,
            1,
            "the single-use Apple identity token must not be re-posted"
        )
        XCTAssertEqual(
            failures.all.count,
            0,
            "no authFailed for a sign-in attempt made with no session; got: "
                + failures.all.map { $0.reason ?? "nil" }.joined(separator: ", ")
        )
    }

    // MARK: - Edge cases

    /// An access token inside the 120s expiry window makes `executeRaw`
    /// pre-refresh. The Apple callback carries no bearer token, so it must not.
    func testExpiringTokenDoesNotPreflightRefreshOnAppleCallback() async {
        AppleCallbackStubURLProtocol.appleResponse = .failure(
            status: 401,
            code: "ADDED_TO_WAITLIST",
            error: "This app is invite-only. You've been added to the waitlist."
        )
        let expiring = makeTestJwt(
            userId: "u1",
            exp: Int(Date().timeIntervalSince1970) + 30
        )
        let (auth, _) = wire(token: expiring)

        _ = try? await appleCallback(auth)

        XCTAssertEqual(
            AppleCallbackStubURLProtocol.refreshCount,
            0,
            "an unauthenticated auth endpoint must not run the expiry preflight"
        )
    }

    /// The exemption must not widen: a 401 from an authenticated endpoint still
    /// refreshes once and retries with the fresh token.
    func testAuthenticatedEndpointStillRefreshesOn401() async throws {
        AppleCallbackStubURLProtocol.refreshedToken = makeTestJwt(userId: "u1-fresh")
        let (_, http) = wire(token: makeTestJwt(userId: "u1-stale"))

        let response = try await http.requestRaw(method: "GET", path: "/me")

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            AppleCallbackStubURLProtocol.refreshCount,
            1,
            "an authenticated 401 must still refresh once and retry"
        )
    }
}

// MARK: - Stub

/// Answers the two endpoints this suite exercises and counts both:
///   * `POST …/auth/apple/callback` — from the script.
///   * `POST …/auth/refresh` — 401 `{"error":"Missing refresh token"}` (the
///     signed-out answer) unless a refreshed token is scripted.
/// Everything else (`GET …/me`) authorizes only the refreshed bearer token, so
/// the first attempt 401s and drives the caller into the refresh branch.
///
/// Injected through the session configuration only (never registered globally),
/// so it never answers another suite's traffic.
final class AppleCallbackStubURLProtocol: URLProtocol {

    /// What `POST /auth/apple/callback` answers with.
    enum ScriptedResponse: Sendable {
        /// 200 with the `{token, isNewUser}` shape the callback returns.
        case success(token: String)
        /// A non-2xx with the server's `{error, code}` envelope.
        case failure(status: Int, code: String, error: String)
    }

    private struct Script {
        var appleResponse: ScriptedResponse = .success(token: "")
        var appleCount = 0
        var refreshCount = 0
        var refreshedToken = ""
    }

    private static let script = LockedBox(Script())

    static var appleResponse: ScriptedResponse {
        get { script.value.appleResponse }
        set { script.withValue { $0.appleResponse = newValue } }
    }

    static var refreshedToken: String {
        get { script.value.refreshedToken }
        set { script.withValue { $0.refreshedToken = newValue } }
    }

    static var appleCount: Int { script.value.appleCount }
    static var refreshCount: Int { script.value.refreshCount }

    static func reset() { script.value = Script() }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.local"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path

        if path.hasSuffix("/auth/refresh") {
            let token = Self.script.withValue { script -> String in
                script.refreshCount += 1
                return script.refreshedToken
            }
            if token.isEmpty {
                respond(status: 401, json: ["error": "Missing refresh token"])
            } else {
                respond(status: 200, json: ["token": token])
            }
            return
        }

        if path.hasSuffix("/auth/apple/callback") {
            let scripted = Self.script.withValue { script -> ScriptedResponse in
                script.appleCount += 1
                return script.appleResponse
            }
            switch scripted {
            case .success(let token):
                respond(status: 200, json: ["token": token, "isNewUser": true])
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

    private func respond(status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
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
