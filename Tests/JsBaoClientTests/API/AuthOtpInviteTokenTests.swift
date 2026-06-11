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

    /// Captures the most recent request the stub closure was asked to make.
    final class CallRecorder: @unchecked Sendable {
        var method: String?
        var path: String?
        var body: Any?
        /// Canned OTP-verify response (no "token" key, so the controller
        /// doesn't try to apply/parse a JWT).
        var response: Any = [
            "user": ["userId": "u1", "email": "otp@example.com"],
            "isNewUser": false,
        ]

        func make(_ method: String, _ path: String, _ data: Any?) async throws -> Any {
            self.method = method
            self.path = path
            self.body = data
            return response
        }
    }

    private func makeController(_ recorder: CallRecorder) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.makeRequest = { method, path, data in
            try await recorder.make(method, path, data)
        }
        return controller
    }

    // MARK: - AuthController wire shape

    func test_otpVerify_sendsInviteToken_inBody() async throws {
        let r = CallRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "invite-tok-1"
        )

        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/auth/otp/verify")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["email"] as? String, "otp@example.com")
        XCTAssertEqual(body?["code"] as? String, "123456")
        XCTAssertEqual(body?["inviteToken"] as? String, "invite-tok-1")
    }

    func test_otpVerify_trimsInviteToken() async throws {
        let r = CallRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "  invite-tok-2 \n"
        )

        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["inviteToken"] as? String, "invite-tok-2")
    }

    func test_otpVerify_omitsInviteToken_whenNil() async throws {
        let r = CallRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(email: "otp@example.com", code: "123456")

        let body = r.body as? [String: Any]
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
        // Same body shape JS sends: just email + code.
        XCTAssertEqual(body?.count, 2)
    }

    func test_otpVerify_omitsInviteToken_whenBlank() async throws {
        let r = CallRecorder()
        let controller = makeController(r)

        _ = try await controller.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "   "
        )

        let body = r.body as? [String: Any]
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
    }

    // MARK: - Top-level JsBaoClient wrapper (#1110)

    /// Builds an offline JsBaoClient whose AuthController.makeRequest is
    /// stubbed, so the top-level `client.otpVerify` wrapper can be
    /// exercised without a network.
    private func makeClient(_ recorder: CallRecorder) -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "test-app",
            offline: true
        ))
        client.authController.makeRequest = { method, path, data in
            try await recorder.make(method, path, data)
        }
        return client
    }

    /// JS parity (#1110): the top-level `otpVerify(email, code, options)`
    /// forwards `options.inviteToken` to the auth controller. The Swift
    /// wrapper previously dropped it.
    func test_topLevel_otpVerify_forwardsInviteToken() async throws {
        let r = CallRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.otpVerify(
            email: "otp@example.com",
            code: "123456",
            inviteToken: "invite-tok-top"
        )

        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/auth/otp/verify")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["inviteToken"] as? String, "invite-tok-top")
    }

    /// Source compatibility + JS parity: the two-arg call still works and
    /// sends no inviteToken (same body shape JS sends: email + code only).
    func test_topLevel_otpVerify_omitsInviteToken_whenNotPassed() async throws {
        let r = CallRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.otpVerify(email: "otp@example.com", code: "123456")

        let body = r.body as? [String: Any]
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
        XCTAssertEqual(body?.count, 2)
    }

    // MARK: - AuthAPI params routing

    /// Builds an AuthAPI whose otp closures record what they were called
    /// with. Everything else is inert stubs.
    private final class OtpCapture: @unchecked Sendable {
        var plainCalls: [(email: String, code: String)] = []
        var inviteCalls: [(email: String, code: String, inviteToken: String?)] = []
    }

    private func makeAuthAPI(_ capture: OtpCapture, wireInviteClosure: Bool) -> AuthAPI {
        let response: [String: Any] = [
            "user": ["userId": "u1", "email": "otp@example.com"],
            "isNewUser": true,
        ]
        return AuthAPI(
            getUserId: { nil },
            getToken: { nil },
            isAuthenticated: { false },
            magicLinkRequest: { _, _ in true },
            magicLinkVerify: { _ in response },
            otpRequest: { _ in true },
            otpVerify: { email, code in
                capture.plainCalls.append((email, code))
                return response
            },
            otpVerifyWithInvite: wireInviteClosure
                ? { email, code, inviteToken in
                    capture.inviteCalls.append((email, code, inviteToken))
                    return response
                }
                : nil,
            getAuthConfig: { [String: Any]() },
            logout: { _ in },
            enableOfflineAccess: { _ in [String: Any]() },
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
