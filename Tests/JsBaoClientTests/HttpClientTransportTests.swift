import XCTest
@testable import JsBaoClient

/// Server-free tests that `HttpClient`'s `Transport` conformance reuses the
/// existing request machinery rather than reimplementing it (#1991 Phase B1).
///
/// The network is stubbed with a `URLProtocol` injected through
/// `HttpClientConfig.sessionConfiguration`, so the 401 → refresh → retry cycle
/// (behavior 11) and the raw-byte contract (behavior 8) run entirely offline.
final class HttpClientTransportTests: XCTestCase {

    struct Payload: Codable, Sendable, Equatable {
        let userId: String
    }

    override func tearDown() {
        TransportStubURLProtocol.reset()
        super.tearDown()
    }

    /// Wire a real `AuthController` + `HttpClient` against the stub, exactly as
    /// `JsBaoClient` does in production.
    private func makeWiredClients(initialToken: String) -> (auth: AuthController, http: HttpClient) {
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
        stubConfig.protocolClasses = [TransportStubURLProtocol.self]

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

    // MARK: - Behavior 11: 401 refresh through the typed path

    func testTypedRequestRefreshesOn401AndReturnsTheDecodedResponse() async throws {
        let refreshed = makeTestJwt(userId: "u1")
        TransportStubURLProtocol.configure(refreshedToken: refreshed)

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        // The typed helper goes through `execute`, which reuses
        // `fetchWithRefresh` — so the 401 retry happens under it.
        let result: Payload = try await http.request(method: .get, path: "/me")

        XCTAssertEqual(result, Payload(userId: "u1"))
        XCTAssertEqual(TransportStubURLProtocol.refreshCount, 1)
        XCTAssertTrue(TransportStubURLProtocol.sawAuthorizedRetryWithNewToken)
    }

    // MARK: - A failed refresh is a network error, not a credential error

    /// `JsBaoNetworkError` documents that the client raises it for any refresh
    /// failure other than an HTTP 401/403 — 5xx responses and decode failures
    /// included. The 401-retry path used to reduce those to
    /// `HttpError(status: 401, message: "Refresh deferred due to network
    /// failure")`, so an app could not tell a server outage from a revoked
    /// session and would sign the user out. Matches the JS client, which
    /// throws `JsBaoNetworkError` on the same branch.
    func testRefreshFailingWithA5xxSurfacesAsANetworkErrorNotA401() async throws {
        TransportStubURLProtocol.configure(refreshedToken: "", refreshStatus: 503)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            let _: Payload = try await http.request(method: .get, path: "/me")
            XCTFail("a request whose refresh 503s must throw")
        } catch let error as JsBaoNetworkError {
            XCTAssertTrue(
                error.message.contains("503"),
                "the underlying refresh failure must survive, got: \(error.message)"
            )
        } catch let error as HttpError {
            XCTFail(
                "a transient refresh outage surfaced as HttpError(\(error.status)) — "
                    + "callers read that as invalid credentials"
            )
        }
    }

    /// The other half of the contract: a refresh the server answers with 401
    /// really is a credential problem and must stay an `HttpError`, so this
    /// fix does not reroute genuine sign-outs to the retry path.
    func testRefreshRejectedWith401StillSurfacesAsAnHttpError() async throws {
        TransportStubURLProtocol.configure(refreshedToken: "", refreshStatus: 401)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            let _: Payload = try await http.request(method: .get, path: "/me")
            XCTFail("a request whose refresh is rejected must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.message, "Invalid credentials")
        } catch let error as JsBaoNetworkError {
            XCTFail("an invalid refresh token is not a network failure: \(error.message)")
        }
    }

    // MARK: - Behavior 8: raw bytes are never reconstructed from text

    func testRequestDataReturnsTheUntouchedResponseBytes() async throws {
        // A blob body that is NOT valid UTF-8. The shipping
        // `JsBaoClient.makeRawRequest` rebuilds the body from
        // `HttpClientResponse.text` (`(result.text ?? "").data(using: .utf8)`),
        // which corrupts exactly this payload.
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00, 0xFE, 0x80])
        XCTAssertNil(String(data: binary, encoding: .utf8), "fixture must not be valid UTF-8")

        TransportStubURLProtocol.configure(
            refreshedToken: "",
            binaryBody: binary,
            binaryContentType: "application/octet-stream"
        )

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1"))
        let (data, status) = try await http.requestData(method: .get, path: "/blobs/raw")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(data, binary, "blob bytes must survive byte-for-byte")
    }

    func testRequestDataUploadsRawBodyBytesVerbatim() async throws {
        let upload = Data([0x00, 0xFF, 0x10])
        TransportStubURLProtocol.configure(refreshedToken: "", binaryBody: Data(), binaryContentType: "application/octet-stream")

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1"))
        _ = try await http.requestData(method: .put, path: "/blobs/raw", body: upload)

        XCTAssertEqual(TransportStubURLProtocol.lastRequestBody, upload)
    }

    // MARK: - The pre-encoded query pass-through survives the refactor

    func testPreEncodedQueryStringPassesThroughVerbatim() throws {
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1"))
        let request = try http.buildURLRequest(
            method: "GET",
            path: "/users/lookup?email=a%2Bb@example.com",
            body: nil
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://stub.local/app/test-app/api/users/lookup?email=a%2Bb@example.com"
        )
    }

    func testLegacyAnyBodyStillEncodesAsJson() async throws {
        TransportStubURLProtocol.configure(refreshedToken: "", echoBody: true)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1"))

        _ = try await http.request(method: "POST", path: "/echo", data: ["a": 1])
        let sent = try XCTUnwrap(TransportStubURLProtocol.lastRequestBody)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        )
        XCTAssertEqual(parsed["a"] as? Int, 1)
    }

    func testGetWithLegacyBodySendsNoBody() async throws {
        TransportStubURLProtocol.configure(refreshedToken: "", echoBody: true)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1"))

        _ = try? await http.request(method: "GET", path: "/echo", data: ["a": 1])
        XCTAssertNil(TransportStubURLProtocol.lastRequestBody, "GET must not carry a body")
    }
}

// MARK: - Stub

/// A scriptable `URLProtocol`:
///   * `POST …/auth/refresh` — counts the round trip and returns `{token}`.
///   * `…/blobs/raw` — returns the configured binary body verbatim.
///   * `…/echo` — 200 `{}` and records the request body.
///   * everything else — 401 unless the request carries the refreshed bearer
///     token, in which case 200 `{"userId":"u1"}`.
final class TransportStubURLProtocol: URLProtocol {
    /// The stub's whole mutable surface. `URLProtocol` instances are made by
    /// URLSession on its own threads, so the script has to be shared statically
    /// — and under the Swift 6 language mode a `static var` is a hard error
    /// however carefully it is locked. Holding all of it in one `LockedBox`
    /// keeps the state in a `static let` and preserves what the old NSLock did:
    /// `configure` publishes every field in one atomic step.
    private struct Script {
        var refreshCount = 0
        var sawAuthorizedRetry = false
        var lastRequestBody: Data?
        var refreshedToken = ""
        var binaryBody = Data()
        var binaryContentType = "application/octet-stream"
        var echoBody = false
        /// Status the refresh endpoint answers with. `200` returns a token;
        /// anything else exercises the refresh-failure branch (a 5xx is the
        /// "server is down" case, a 401 the "credentials really are invalid"
        /// case).
        var refreshStatus = 200
    }

    private static let script = LockedBox(Script())

    static func configure(
        refreshedToken: String,
        binaryBody: Data = Data(),
        binaryContentType: String = "application/octet-stream",
        echoBody: Bool = false,
        refreshStatus: Int = 200
    ) {
        script.value = Script(
            refreshedToken: refreshedToken,
            binaryBody: binaryBody,
            binaryContentType: binaryContentType,
            echoBody: echoBody,
            refreshStatus: refreshStatus
        )
    }

    static func reset() {
        configure(refreshedToken: "")
    }

    static var refreshCount: Int { script.value.refreshCount }
    static var sawAuthorizedRetryWithNewToken: Bool { script.value.sawAuthorizedRetry }
    static var lastRequestBody: Data? { script.value.lastRequestBody }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        // `URLProtocol` strips `httpBody` for streamed uploads; read it back
        // from the body stream when necessary.
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            return collected
        }
        if let body = body, !body.isEmpty {
            Self.script.withValue { $0.lastRequestBody = body }
        }

        if path.hasSuffix("/auth/refresh") {
            let (token, status) = Self.script.withValue { script -> (String, Int) in
                script.refreshCount += 1
                return (script.refreshedToken, script.refreshStatus)
            }
            guard status == 200 else {
                respond(
                    status: status,
                    body: Data(#"{"error":"refresh unavailable"}"#.utf8),
                    contentType: "application/json"
                )
                return
            }
            respond(status: 200, body: Data(#"{"token":"\#(token)"}"#.utf8), contentType: "application/json")
            return
        }

        if path.hasSuffix("/blobs/raw") {
            let (data, contentType) = Self.script.withValue { ($0.binaryBody, $0.binaryContentType) }
            respond(status: 200, body: data, contentType: contentType)
            return
        }

        if path.hasSuffix("/echo") {
            respond(status: 200, body: Data("{}".utf8), contentType: "application/json")
            return
        }

        let auth = request.value(forHTTPHeaderField: "Authorization")
        let refreshed = Self.script.value.refreshedToken
        if let auth = auth, auth == "Bearer \(refreshed)", !refreshed.isEmpty {
            Self.script.withValue { $0.sawAuthorizedRetry = true }
            respond(status: 200, body: Data(#"{"userId":"u1"}"#.utf8), contentType: "application/json")
        } else {
            respond(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8), contentType: "application/json")
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, body: Data, contentType: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
