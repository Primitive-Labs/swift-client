import XCTest
@testable import JsBaoClient

/// Wire-shape tests for `otpVerify`'s optional `inviteToken` (#1077, JS
/// parity with `otpVerify(email, code, { inviteToken })` — issue #466).
///
/// These don't hit the network. The controller-level tests stub
/// `AuthController.makeRequest` and assert the exact POST body the JS
/// client sends (`inviteToken` trimmed, omitted when nil/blank); the
/// AuthAPI-level tests assert the public `OtpVerifyParams` surface routes
/// the token through the invite-aware closure (and falls back cleanly
/// when it isn't wired).
final class AuthOtpInviteTokenTests: XCTestCase {

    // MARK: - Helpers

    /// Canned OTP-verify response. It carries a real (decodable) JWT because
    /// a 2xx verify without a `token` is a broken server contract the
    /// controller rejects (#1991 Phase B3). These tests only assert the
    /// outbound request body, so the token just has to be applicable.
    static let otpResponse = #"""
    {"token": "\#(makeTestJwt(userId: "u1"))", "user": {"userId": "u1", "email": "otp@example.com"}, "isNewUser": false}
    """#

    private func makeRecorder() -> RecordingTransport {
        RecordingTransport(json: Self.otpResponse)
    }

    private func makeController(_ recorder: RecordingTransport) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.setTransport(recorder)
        return controller
    }

    // MARK: - AuthController wire shape

    func test_otpVerify_sendsInviteToken_inBody() async throws {
        let r = makeRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "invite-tok-1"
        )

        XCTAssertEqual(r.lastCall?.method, .post)
        XCTAssertEqual(r.lastCall?.path, "/auth/otp/verify")
        let body = r.lastCall?.jsonBody
        XCTAssertEqual(body?["email"]?.stringValue, "otp@example.com")
        XCTAssertEqual(body?["code"]?.stringValue, "123456")
        XCTAssertEqual(body?["inviteToken"]?.stringValue, "invite-tok-1")
    }

    func test_otpVerify_trimsInviteToken() async throws {
        let r = makeRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "  invite-tok-2 \n"
        )

        let body = r.lastCall?.jsonBody
        XCTAssertEqual(body?["inviteToken"]?.stringValue, "invite-tok-2")
    }

    func test_otpVerify_omitsInviteToken_whenNil() async throws {
        let r = makeRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(email: "otp@example.com", code: "123456")

        let body = r.lastCall?.jsonBody
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
        // Same body shape JS sends: just email + code.
        XCTAssertEqual(body?.objectValue?.count, 2)
    }

    func test_otpVerify_omitsInviteToken_whenBlank() async throws {
        let r = makeRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "   "
        )

        let body = r.lastCall?.jsonBody
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
    }

    // MARK: - Top-level JsBaoClient wrapper (#1110)

    /// Builds an offline JsBaoClient whose AuthController.makeRequest is
    /// stubbed, so the top-level `client.otpVerify` wrapper can be
    /// exercised without a network.
    private func makeClient(_ recorder: RecordingTransport) -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "test-app",
            offline: true
        ))
        client.authController.replaceTransportForTesting(recorder)
        return client
    }

    /// JS parity (#1110): the top-level `otpVerify(email, code, options)`
    /// forwards `options.inviteToken` to the auth controller. The Swift
    /// wrapper previously dropped it.
    func test_topLevel_otpVerify_forwardsInviteToken() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "invite-tok-top"
        )

        // Select the verify call by path rather than taking the last one: a
        // token-less client now issues a startup POST /auth/refresh (#2656),
        // which can land after this call.
        let call = r.lastCall(to: "/auth/otp/verify")
        XCTAssertEqual(call?.method, .post)
        XCTAssertEqual(call?.jsonBody?["inviteToken"]?.stringValue, "invite-tok-top")
    }

    /// Source compatibility + JS parity: the two-arg call still works and
    /// sends no inviteToken (same body shape JS sends: email + code only).
    func test_topLevel_otpVerify_omitsInviteToken_whenNotPassed() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.otpVerify(email: "otp@example.com", code: "123456")

        let body = r.lastCall(to: "/auth/otp/verify")?.jsonBody
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
        XCTAssertEqual(body?.objectValue?.count, 2)
    }

    // MARK: - AuthAPI params routing

    /// Builds an AuthAPI whose otp closures record what they were called
    /// with. Everything else is inert stubs.
    private final class OtpCapture: @unchecked Sendable {
        var plainCalls: [(email: String, code: String)] = []
        var inviteCalls: [(email: String, code: String, inviteToken: String?)] = []
    }

    private func makeAuthAPI(_ capture: OtpCapture, wireInviteClosure: Bool) -> AuthAPI {
        let user = AuthUser(userId: "u1", email: "otp@example.com", name: nil)
        let otpResult = OtpVerifyResult(user: user, isNewUser: true)
        let magicLinkResult = MagicLinkVerifyResult(user: user, promptAddPasskey: nil, isNewUser: true)
        return AuthAPI(
            getUserId: { nil },
            getToken: { nil },
            isAuthenticated: { false },
            magicLinkRequest: { _, _ in true },
            magicLinkVerify: { _ in magicLinkResult },
            otpRequest: { _ in true },
            otpVerify: { email, code in
                capture.plainCalls.append((email, code))
                return otpResult
            },
            otpVerifyWithInvite: wireInviteClosure
                ? { email, code, inviteToken in
                    capture.inviteCalls.append((email, code, inviteToken))
                    return otpResult
                }
                : nil,
            getAuthConfig: { try JSONCoding.decodeData(AuthConfigInfo.self, from: Data("{}".utf8)) },
            logout: { _ in },
            enableOfflineAccess: { _ in EnableOfflineAccessResult(enabled: true) },
            unlockOffline: { false },
            getOfflineGrantStatus: {
                OfflineGrantStatus(available: false, expiresAt: nil, daysLeft: nil, method: nil)
            },
            renewOfflineGrant: { _ in false },
            revokeOfflineGrant: { _ in },
            hasOfflineGrantStored: { false }
        )
    }

    func test_authAPI_otpVerify_threadsInviteToken_throughParams() async throws {
        let capture = OtpCapture()
        let api = makeAuthAPI(capture, wireInviteClosure: true)

        let result = try await api.otpVerify(
            OtpVerifyParams(email: "otp@example.com", code: "654321", inviteToken: "tok-466")
        )

        XCTAssertEqual(capture.inviteCalls.count, 1)
        XCTAssertEqual(capture.inviteCalls.first?.email, "otp@example.com")
        XCTAssertEqual(capture.inviteCalls.first?.code, "654321")
        XCTAssertEqual(capture.inviteCalls.first?.inviteToken, "tok-466")
        XCTAssertTrue(capture.plainCalls.isEmpty)
        XCTAssertEqual(result.user.userId, "u1")
        XCTAssertEqual(result.isNewUser, true)
    }

    func test_authAPI_otpVerify_convenienceOverload_threadsInviteToken() async throws {
        let capture = OtpCapture()
        let api = makeAuthAPI(capture, wireInviteClosure: true)

        _ = try await api.otpVerify(email: "otp@example.com", code: "654321", inviteToken: "tok-overload")

        XCTAssertEqual(capture.inviteCalls.first?.inviteToken, "tok-overload")
    }

    func test_authAPI_otpVerify_fallsBack_whenInviteClosureUnwired() async throws {
        let capture = OtpCapture()
        let api = makeAuthAPI(capture, wireInviteClosure: false)

        _ = try await api.otpVerify(email: "otp@example.com", code: "654321")

        XCTAssertEqual(capture.plainCalls.count, 1)
        XCTAssertTrue(capture.inviteCalls.isEmpty)
    }

    /// Source compatibility: the pre-#1077 two-arg initializer still works
    /// and leaves `inviteToken` nil.
    func test_otpVerifyParams_twoArgInit_remainsSourceCompatible() {
        let params = OtpVerifyParams(email: "a@b.c", code: "000000")
        XCTAssertNil(params.inviteToken)
    }
}
