import XCTest
@testable import JsBaoClient

/// Server-free tests for the #1983 fix: `HttpClient` no longer runs its own
/// uncoalesced token refresh. Its 401 path now delegates to
/// `AuthController.refreshAccessToken`, which is single-flight — so a burst of
/// N concurrent 401s produces exactly ONE `POST /auth/refresh` instead of N.
///
/// The network layer is stubbed with a `URLProtocol` (injected via
/// `HttpClientConfig.sessionConfiguration`) so the 401 → refresh → retry cycle
/// runs entirely offline. The stub counts refresh round trips directly, which
/// is the assertion a live dev server cannot make (it does not rotate refresh
/// cookies, so N parallel refreshes all succeed there whether or not
/// coalescing is active).
final class HttpClientRefreshCoalescingTests: XCTestCase {

    override func tearDown() {
        RefreshStubURLProtocol.reset()
        super.tearDown()
    }

    /// Build the real AuthController + HttpClient wiring against the stubbed
    /// session, exactly as `JsBaoClient` wires them in production: HttpClient's
    /// `refreshAccessToken` delegates to `AuthController.refreshAccessToken`,
    /// and AuthController's `makeRequest` routes back through HttpClient.
    private func makeWiredClients(
        initialToken: String
    ) -> (auth: AuthController, http: HttpClient) {
        let auth = AuthController(
            appId: "test-app",
            apiUrl: "http://stub.local",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )

        let stubConfig = URLSessionConfiguration.ephemeral
        stubConfig.protocolClasses = [RefreshStubURLProtocol.self]

        let http = HttpClient(config: HttpClientConfig(
            apiUrl: "http://stub.local",
            appId: "test-app",
            getToken: { auth.getToken() },
            getConnectionId: { nil },
            getGlobalAdminAppId: { "global-admin-app" },
            logger: Logger(level: .error),
            refreshAccessToken: { await auth.refreshAccessToken(cause: "http") },
            sessionConfiguration: stubConfig
        ))

        auth.setTransport(http)

        auth.bootstrapToken(initialToken)
        return (auth, http)
    }

    /// Behavior 1 + 2 (and edge case 1): a burst of N concurrent requests that
    /// each get a 401 must coalesce into exactly ONE `POST /auth/refresh`, and
    /// every request must then retry with the refreshed token and succeed.
    func testConcurrentUnauthorizedRequestsCoalesceRefresh() async throws {
        let refreshedJwt = makeTestJwt(userId: "u1")
        RefreshStubURLProtocol.configure(
            refreshedToken: refreshedJwt,
            // Hold the single refresh in flight long enough that every
            // concurrent 401'd caller reaches the coalescing check.
            refreshDelay: 0.2,
            refreshStatus: 200
        )

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        let callerCount = 50
        let results: [Bool] = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<callerCount {
                group.addTask {
                    do {
                        _ = try await http.request(method: "GET", path: "/me")
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var collected: [Bool] = []
            for await ok in group { collected.append(ok) }
            return collected
        }

        XCTAssertEqual(
            RefreshStubURLProtocol.refreshCount, 1,
            "N concurrent 401s must coalesce to exactly one POST /auth/refresh"
        )
        XCTAssertEqual(results.count, callerCount)
        XCTAssertTrue(
            results.allSatisfy { $0 },
            "every request must retry with the refreshed token and succeed"
        )
        XCTAssertTrue(
            RefreshStubURLProtocol.sawAuthorizedRetryWithNewToken,
            "the retry after refresh must carry the refreshed bearer token"
        )
    }

    /// Behavior 3 (and edge case 1): when the refresh itself returns 401
    /// (invalid refresh cookie), the original request surfaces an
    /// `HttpError(status: 401)` — the logout/invalid path is preserved — and
    /// the refresh does not recurse into a second round trip.
    func testInvalidRefreshSurfaces401() async throws {
        RefreshStubURLProtocol.configure(
            refreshedToken: makeTestJwt(userId: "u1"),
            refreshDelay: 0,
            refreshStatus: 401
        )

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("Expected a 401 to be thrown when the refresh is invalid")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401, "invalid refresh must surface as HTTP 401")
        } catch {
            XCTFail("Expected HttpError(401), got: \(error)")
        }

        XCTAssertEqual(
            RefreshStubURLProtocol.refreshCount, 1,
            "an invalid refresh must not recurse into a second POST /auth/refresh"
        )
    }
}

/// A `URLProtocol` that stubs the two endpoints these tests exercise:
///   * `POST …/auth/refresh` — counts the round trip, optionally holds it in
///     flight, and returns either `{token}` (200) or a 401.
///   * everything else (`GET …/me`) — returns 401 unless the request carries
///     the refreshed bearer token, in which case 200 `{userId}`.
///
/// State is static (the loading system instantiates a fresh protocol per
/// request) and shared across the concurrent burst, so it lives in one
/// `LockedBox` — a `static var` is a hard error under the Swift 6 language
/// mode however carefully it is locked, and the box keeps every read and write
/// serialised exactly as the old NSLock did.
final class RefreshStubURLProtocol: URLProtocol {
    private struct Script {
        var refreshCount = 0
        var sawAuthorizedRetry = false
        var refreshedToken = ""
        var refreshDelay: TimeInterval = 0
        var refreshStatus = 200
    }

    private static let script = LockedBox(Script())

    static func configure(refreshedToken: String, refreshDelay: TimeInterval, refreshStatus: Int) {
        script.value = Script(
            refreshedToken: refreshedToken,
            refreshDelay: refreshDelay,
            refreshStatus: refreshStatus
        )
    }

    static func reset() {
        script.value = Script()
    }

    static var refreshCount: Int { script.value.refreshCount }
    static var sawAuthorizedRetryWithNewToken: Bool { script.value.sawAuthorizedRetry }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path

        if path.hasSuffix("/auth/refresh") {
            let (delay, status, token): (TimeInterval, Int, String) = Self.script.withValue { script in
                script.refreshCount += 1
                return (script.refreshDelay, script.refreshStatus, script.refreshedToken)
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if status == 200 {
                respond(status: 200, json: ["token": token])
            } else {
                respond(status: status, json: ["error": "invalid_refresh"])
            }
            return
        }

        // Any other request: authorize only when it presents the refreshed
        // bearer token (i.e. it is the retry after a successful refresh).
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let refreshed = Self.script.value.refreshedToken
        if let auth = auth, auth == "Bearer \(refreshed)", !refreshed.isEmpty {
            Self.script.withValue { $0.sawAuthorizedRetry = true }
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
