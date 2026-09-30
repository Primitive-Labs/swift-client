import XCTest
@testable import JsBaoClient

/// Issue #3027 — when a passkey ceremony fails because the provider did not
/// verify the user, the server answers with its own code so the app can say
/// "complete Face ID / your passcode and try again" instead of showing an
/// opaque sign-in failure.
///
/// Pinned the way `PASSKEY_RP_NOT_CONFIGURED` is (#3024): an app switching on
/// the typed `HttpError.authCode` must see the case, not `nil`.
///
/// Hermetic: `RecordingTransport` answers with the server's error body; no dev
/// server and no system passkey sheet.
final class PasskeyUserVerificationHermeticTests: XCTestCase {

    private func makeController(status: Int, json: String) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://127.0.0.1:1",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.setTransport(RecordingTransport(status: status, json: json))
        return controller
    }

    private let uvFailureBody = """
    {"error":"Your passkey provider did not verify you. Try again and complete \
    Face ID / PIN.","code":"PASSKEY_USER_VERIFICATION_FAILED"}
    """

    func testAuthCodeDecodesTheServersUserVerificationFailure() {
        XCTAssertEqual(
            AuthCode(rawValue: "PASSKEY_USER_VERIFICATION_FAILED"),
            .passkeyUserVerificationFailed
        )
    }

    func testAuthFinishSurfacesTheTypedUserVerificationFailure() async throws {
        let controller = makeController(status: 401, json: uvFailureBody)

        do {
            _ = try await controller.passkeyAuthFinish(
                credential: .object([:]),
                challengeToken: "challenge.token.value"
            )
            XCTFail("expected the finish call to reject an unverified assertion")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "PASSKEY_USER_VERIFICATION_FAILED")
            XCTAssertEqual(error.authCode, .passkeyUserVerificationFailed)
        }
    }

    func testRegisterFinishSurfacesTheTypedUserVerificationFailure() async throws {
        let controller = makeController(status: 400, json: uvFailureBody)

        do {
            _ = try await controller.passkeyRegisterFinish(
                credential: .object([:]),
                challengeToken: "challenge.token.value"
            )
            XCTFail("expected the finish call to reject an unverified credential")
        } catch let error as HttpError {
            XCTAssertEqual(error.authCode, .passkeyUserVerificationFailed)
        }
    }
}
