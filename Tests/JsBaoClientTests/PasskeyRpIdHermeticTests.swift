import XCTest
@testable import JsBaoClient

/// Issue #3024 — a native passkey ceremony must run against the relying party
/// the app's `webcredentials:` entitlement names. URLSession sends no `Origin`
/// header, so the server used to fall back to whichever RP came first in
/// `passkeyRpConfig` and the Apple sheet failed with "not associated with
/// domain". The start calls therefore carry an explicit `rpId`, taken from the
/// call or from `AuthConfig.passkeyRpId`.
///
/// Hermetic: `RecordingTransport` records the request the controller builds;
/// no dev server, and no system passkey sheet.
final class PasskeyRpIdHermeticTests: XCTestCase {

    private let rpId = "compound-alpha.primitive.app"

    private let startJSON = """
    {"challenge":"Y2hhbGxlbmdl","rpId":"compound-alpha.primitive.app",\
    "challengeToken":"challenge.token.value"}
    """

    private func makeController(
        auth: AuthConfig = AuthConfig()
    ) -> (AuthController, RecordingTransport) {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://127.0.0.1:1",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: auth
        )
        let transport = RecordingTransport(json: startJSON)
        controller.setTransport(transport)
        return (controller, transport)
    }

    private func requestedRpId(
        _ transport: RecordingTransport,
        path: String
    ) -> String? {
        guard let call = transport.lastCall(to: path),
              case .object(let body)? = call.jsonBody,
              case .string(let value)? = body["rpId"] else { return nil }
        return value
    }

    private func bodyHasRpIdKey(
        _ transport: RecordingTransport,
        path: String
    ) -> Bool {
        guard let call = transport.lastCall(to: path),
              case .object(let body)? = call.jsonBody else { return false }
        return body["rpId"] != nil
    }

    // MARK: - Explicit rpId

    func testAuthStartSendsRequestedRpId() async throws {
        let (controller, transport) = makeController()

        _ = try await controller.passkeyAuthStart(rpId: rpId)

        XCTAssertEqual(requestedRpId(transport, path: "/passkey/auth/start"), rpId)
    }

    func testRegisterStartSendsRequestedRpId() async throws {
        let (controller, transport) = makeController()

        _ = try await controller.passkeyRegisterStart(rpId: rpId)

        XCTAssertEqual(
            requestedRpId(transport, path: "/passkey/register/start"),
            rpId
        )
    }

    // MARK: - Configured default

    func testConfiguredPasskeyRpIdIsSentWhenTheCallNamesNone() async throws {
        let (controller, transport) = makeController(
            auth: AuthConfig(passkeyRpId: rpId)
        )

        _ = try await controller.passkeyAuthStart()
        _ = try await controller.passkeyRegisterStart()

        XCTAssertEqual(requestedRpId(transport, path: "/passkey/auth/start"), rpId)
        XCTAssertEqual(
            requestedRpId(transport, path: "/passkey/register/start"),
            rpId
        )
    }

    func testExplicitRpIdWinsOverTheConfiguredOne() async throws {
        let (controller, transport) = makeController(
            auth: AuthConfig(passkeyRpId: "localhost")
        )

        _ = try await controller.passkeyAuthStart(rpId: rpId)

        XCTAssertEqual(requestedRpId(transport, path: "/passkey/auth/start"), rpId)
    }

    func testNoRpIdIsSentWhenNoneIsCalledForOrConfigured() async throws {
        let (controller, transport) = makeController()

        _ = try await controller.passkeyAuthStart()

        XCTAssertFalse(bodyHasRpIdKey(transport, path: "/passkey/auth/start"))
    }

    func testBlankConfiguredRpIdIsTreatedAsAbsent() async throws {
        let (controller, transport) = makeController(
            auth: AuthConfig(passkeyRpId: "   ")
        )

        _ = try await controller.passkeyAuthStart()

        XCTAssertFalse(bodyHasRpIdKey(transport, path: "/passkey/auth/start"))
    }

    // MARK: - AuthAPI forwarding

    /// `AuthAPI.passkeyAuthStart(rpId:)` — what the native
    /// `signInWithPasskey(rpId:)` convenience calls — hands the rpId to the
    /// wired closure rather than dropping it.
    func testAuthApiForwardsRpIdToTheWiredClosure() async throws {
        let seen = RpIdBox()
        let api = AuthAPI(
            getUserId: { nil },
            getToken: { nil },
            isAuthenticated: { false },
            magicLinkRequest: { _, _ in true },
            magicLinkVerify: { _ in throw JsBaoError(code: .unavailable) },
            otpRequest: { _ in true },
            otpVerify: { _, _ in throw JsBaoError(code: .unavailable) },
            getAuthConfig: { throw JsBaoError(code: .unavailable) },
            logout: { _ in },
            enableOfflineAccess: { _ in throw JsBaoError(code: .unavailable) },
            unlockOffline: { false },
            getOfflineGrantStatus: {
                OfflineGrantStatus(available: false, expiresAt: nil, daysLeft: nil, method: nil)
            },
            renewOfflineGrant: { _ in false },
            revokeOfflineGrant: { _ in },
            hasOfflineGrantStored: { false },
            passkeyAuthStartWithRpId: { requested in
                seen.value = requested
                return PasskeyAuthStartResult(
                    options: .object([:]),
                    challengeToken: "challenge.token.value"
                )
            }
        )

        _ = try await api.passkeyAuthStart(rpId: rpId)

        XCTAssertEqual(seen.value, rpId)
    }

    // MARK: - Rejected rpId

    /// The server rejects an rpId the app does not configure with
    /// `PASSKEY_RP_NOT_CONFIGURED`; an app switching on the typed
    /// `HttpError.authCode` must see it rather than `nil`.
    func testRejectedRpIdSurfacesAsATypedAuthCode() async throws {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://127.0.0.1:1",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.setTransport(
            RecordingTransport(
                status: 400,
                json: """
                {"error":"Requested passkey rpId \\"nope.example\\" is not configured \
                for this app","code":"PASSKEY_RP_NOT_CONFIGURED"}
                """
            )
        )

        do {
            _ = try await controller.passkeyAuthStart(rpId: "nope.example")
            XCTFail("expected the start call to reject an unconfigured rpId")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "PASSKEY_RP_NOT_CONFIGURED")
            XCTAssertEqual(error.authCode, .passkeyRpNotConfigured)
        }
    }

    private final class RpIdBox: @unchecked Sendable {
        var value: String?
    }
}
