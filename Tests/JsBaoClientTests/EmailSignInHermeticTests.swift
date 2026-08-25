import XCTest
@testable import JsBaoClient

/// #2884 — one email sign-in request, one email carrying both credentials.
///
/// The Swift client's half of that change is a single `emailSignInRequest`
/// against `POST /auth/email/request` (no method to select any more) and one
/// `emailSignInEnabled` flag on the auth config.
///
/// Server-free (`*HermeticTests`): the request shape is captured by a stubbed
/// `URLProtocol` wired into this suite's session only, and the config half is
/// literal payloads through the decoder.
final class EmailSignInHermeticTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EmailSignInCaptureURLProtocol.reset()
    }

    override func tearDown() {
        EmailSignInCaptureURLProtocol.reset()
        super.tearDown()
    }

    private func wire() -> AuthController {
        let (auth, _) = makeWiredClients(
            initialToken: "",
            protocolClass: EmailSignInCaptureURLProtocol.self
        )
        return auth
    }

    // MARK: - The one request endpoint

    func testEmailSignInRequestPostsTheUnifiedEndpointWithTheRedirectTarget() async throws {
        let auth = wire()

        let ok = try await auth.emailSignInRequest(
            email: "someone@example.test",
            redirectUri: "myapp://auth/email"
        )

        XCTAssertTrue(ok)
        let call = try XCTUnwrap(
            EmailSignInCaptureURLProtocol.firstCall(containing: "/auth/email/request")
        )
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.jsonBody?["email"] as? String, "someone@example.test")
        XCTAssertEqual(call.jsonBody?["redirectUri"] as? String, "myapp://auth/email")
        XCTAssertNil(
            call.jsonBody?["emailAuthMethod"],
            "there is no method to select any more"
        )
    }

    /// No redirect target at all is a legal request: the server issues a
    /// code-only email (DSO-2884-002) rather than refusing.
    func testEmailSignInRequestOmitsTheRedirectKeyWhenThereIsNoTarget() async throws {
        let auth = wire()

        _ = try await auth.emailSignInRequest(email: "someone@example.test")

        let call = try XCTUnwrap(
            EmailSignInCaptureURLProtocol.firstCall(containing: "/auth/email/request")
        )
        XCTAssertEqual(call.jsonBody?["email"] as? String, "someone@example.test")
        XCTAssertNil(call.jsonBody?["redirectUri"])
    }

    // MARK: - The one config flag

    private func decodeConfig(_ json: String) throws -> AuthConfigInfo {
        try JSONDecoder().decode(AuthConfigInfo.self, from: json.data(using: .utf8)!)
    }

    func testAuthConfigDecodesTheSingleEmailSignInFlag() throws {
        let enabled = try decodeConfig(
            #"{ "appId": "a", "emailSignInEnabled": true }"#
        )
        XCTAssertTrue(enabled.emailSignInEnabled)

        let disabled = try decodeConfig(
            #"{ "appId": "a", "emailSignInEnabled": false }"#
        )
        XCTAssertFalse(disabled.emailSignInEnabled)
    }

    /// Against a server that predates #2884 there is no `emailSignInEnabled`
    /// key at all, so the flag is derived from the pair it replaced: email
    /// sign-in is off only when BOTH legacy flags are explicitly false.
    func testAuthConfigFallsBackToTheLegacyPairAgainstAnOlderServer() throws {
        let onlyOtp = try decodeConfig(
            #"{ "appId": "a", "magicLinkEnabled": false, "otpEnabled": true }"#
        )
        XCTAssertTrue(onlyOtp.emailSignInEnabled)

        let bothOff = try decodeConfig(
            #"{ "appId": "a", "magicLinkEnabled": false, "otpEnabled": false }"#
        )
        XCTAssertFalse(bothOff.emailSignInEnabled)
    }
}

/// Captures the unauthenticated sign-in request this suite makes. Registered
/// only on this suite's session configuration (never globally), so it cannot
/// answer traffic from the live-server suites sharing the process.
final class EmailSignInCaptureURLProtocol: URLProtocol {

    struct Call: Sendable {
        let url: String
        let method: String
        let body: Data?

        var jsonBody: [String: Any]? {
            guard let body = body, !body.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    private static let calls = LockedBox<[Call]>([])

    static func reset() { calls.value = [] }

    static func firstCall(containing fragment: String) -> Call? {
        calls.value.first { $0.url.contains(fragment) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.calls.withValue {
            $0.append(
                Call(
                    url: url.absoluteString,
                    method: request.httpMethod ?? "GET",
                    body: Self.readBody(request)
                )
            )
        }
        respond(status: 200, json: ["success": true])
    }

    override func stopLoading() {}

    /// `URLSession` moves a request body onto `httpBodyStream` before a
    /// `URLProtocol` sees it, so `httpBody` alone is not enough.
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func respond(status: Int, json: [String: Any]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
}
