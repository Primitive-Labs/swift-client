import XCTest
@testable import JsBaoClient

/// Server-free regression test for #1983: routing the HTTP-triggered refresh
/// through `AuthController.refreshViaProxy` must keep the proxy `baseUrl`
/// normalization the removed `HttpClient` refresh path had. A proxy `baseUrl`
/// with a trailing slash must NOT produce a double-slash `.../proxy//auth/refresh`
/// URL (which strict proxy routes can 404).
///
/// `refreshViaProxy` builds its request against `URLSession.shared`, so the
/// stub is registered globally with `URLProtocol.registerClass` (rather than
/// injected via a session configuration). It captures the requested URL and
/// returns a valid token so the refresh completes.
final class AuthControllerProxyRefreshUrlTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ProxyRefreshCaptureURLProtocol.self)
        ProxyRefreshCaptureURLProtocol.reset()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ProxyRefreshCaptureURLProtocol.self)
        ProxyRefreshCaptureURLProtocol.reset()
        super.tearDown()
    }

    private func makeAuth(proxyBaseUrl: String) -> AuthController {
        let auth = AuthController(
            appId: "test-app",
            apiUrl: "http://stub.local",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: RefreshProxyConfig(baseUrl: proxyBaseUrl),
            persistConfig: AuthConfig()
        )
        auth.bootstrapToken(makeTestJwt(userId: "u1-stale"))
        return auth
    }

    /// A trailing-slash proxy base must produce exactly one slash before
    /// `auth/refresh`.
    func testTrailingSlashProxyBaseHasNoDoubleSlash() async throws {
        ProxyRefreshCaptureURLProtocol.refreshedToken = makeTestJwt(userId: "u1")
        let auth = makeAuth(proxyBaseUrl: "http://proxy.local/base/")

        let outcome = await auth.refreshAccessToken(cause: "test")

        XCTAssertEqual(outcome, .success, "refresh should succeed against the stub")
        XCTAssertEqual(
            ProxyRefreshCaptureURLProtocol.capturedRefreshUrl,
            "http://proxy.local/base/auth/refresh",
            "trailing-slash proxy base must not yield a double-slash refresh URL"
        )
    }

    /// A proxy base without a trailing slash produces the same URL — the strip
    /// only removes a redundant slash, it does not over-normalize.
    func testNonTrailingSlashProxyBaseUnchanged() async throws {
        ProxyRefreshCaptureURLProtocol.refreshedToken = makeTestJwt(userId: "u1")
        let auth = makeAuth(proxyBaseUrl: "http://proxy.local/base")

        let outcome = await auth.refreshAccessToken(cause: "test")

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(
            ProxyRefreshCaptureURLProtocol.capturedRefreshUrl,
            "http://proxy.local/base/auth/refresh"
        )
    }
}

/// Captures the URL of the proxy `POST …/auth/refresh` and returns a token so
/// the refresh completes. Registered globally (the proxy refresh uses
/// `URLSession.shared`).
final class ProxyRefreshCaptureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _capturedRefreshUrl: String?
    static var refreshedToken = ""

    static var capturedRefreshUrl: String? { lock.withLock { _capturedRefreshUrl } }

    static func reset() {
        lock.withLock {
            _capturedRefreshUrl = nil
            refreshedToken = ""
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/auth/refresh") ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self._capturedRefreshUrl = url.absoluteString }
        let token = Self.lock.withLock { Self.refreshedToken }
        let body = (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data()
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
