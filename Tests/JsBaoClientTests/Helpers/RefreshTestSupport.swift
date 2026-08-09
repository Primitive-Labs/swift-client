import Foundation
@testable import JsBaoClient

/// Shared support for the server-free tests that drive the 401 → refresh →
/// retry cycle through a stubbed `URLSession`.
///
/// Both the stub and the client wiring below used to be copied per suite; the
/// copies are the production wiring restated, so they drift the moment
/// `HttpClientConfig` or `AuthController.init` changes. One copy lives here.

/// Wire a real `AuthController` + `HttpClient` against a stubbed session,
/// exactly as `JsBaoClient` wires them in production: `HttpClient`'s
/// `refreshAccessToken` delegates to `AuthController.refreshAccessToken`, and
/// `AuthController`'s `makeRequest` routes back through `HttpClient`.
///
/// - Parameters:
///   - initialToken: the access token the controller starts out holding.
///   - protocolClass: the `URLProtocol` subclass that answers every request.
func makeWiredClients(
    initialToken: String,
    protocolClass: AnyClass = RefreshStubURLProtocol.self
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
    stubConfig.protocolClasses = [protocolClass]

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

/// A `URLProtocol` that stubs the two endpoints these tests exercise:
///   * `POST …/auth/refresh` — counts the round trip, then either fails at the
///     transport (an outage: DNS failure, connection refused, radio off),
///     optionally holds the response in flight, and otherwise returns
///     `{token}` (200) or an error status.
///   * everything else (`GET …/me`) — returns 401 unless the request carries
///     the refreshed bearer token, in which case 200 `{userId}`. A suite that
///     configures no refreshed token therefore gets a 401 on every request,
///     which is what drives the caller into the refresh branch.
///
/// State is static (the loading system instantiates a fresh protocol per
/// request) and shared across a concurrent burst, so it lives in one
/// `LockedBox` — a `static var` is a hard error under the Swift 6 language
/// mode however carefully it is locked, and the box keeps every read and write
/// serialised exactly as the old NSLock did. Suites must call `reset()` in
/// `tearDown` so the next one starts from a clean script.
final class RefreshStubURLProtocol: URLProtocol {
    private struct Script {
        var refreshCount = 0
        var sawAuthorizedRetry = false
        var refreshedToken = ""
        var refreshDelay: TimeInterval = 0
        var refreshStatus = 200
        var refreshFailsAtTransport = false
    }

    private static let script = LockedBox(Script())

    /// Script a refresh the server answers — 200 with `refreshedToken`, or any
    /// other status as a rejection.
    static func configure(refreshedToken: String, refreshDelay: TimeInterval, refreshStatus: Int) {
        script.value = Script(
            refreshedToken: refreshedToken,
            refreshDelay: refreshDelay,
            refreshStatus: refreshStatus
        )
    }

    /// Script a refresh that never reaches the server (`true`) or that the
    /// server rejects with a 401 (`false`). Either way no refreshed token is
    /// issued, so every other request keeps 401ing.
    static func configure(refreshFailsAtTransport: Bool) {
        script.value = Script(
            refreshStatus: 401,
            refreshFailsAtTransport: refreshFailsAtTransport
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
            let (delay, status, token, failsAtTransport) = Self.script.withValue { script
                -> (TimeInterval, Int, String, Bool) in
                script.refreshCount += 1
                return (
                    script.refreshDelay,
                    script.refreshStatus,
                    script.refreshedToken,
                    script.refreshFailsAtTransport
                )
            }
            if failsAtTransport {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
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
