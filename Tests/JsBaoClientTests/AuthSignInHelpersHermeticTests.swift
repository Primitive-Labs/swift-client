import XCTest
@testable import JsBaoClient

/// The public surface of the sign-in helpers: the `oauthRedirectUri` option on
/// `AuthConfig`, and the `client.auth` facade's new methods when an `AuthAPI`
/// is built by hand. Pure construction: no client, no session, no request.
/// The wired methods are proven live in `EmailSignInLinkTargetLiveTests` and
/// `SignInCallbackLiveTests`.
final class AuthSignInHelpersHermeticTests: XCTestCase {

    func testAuthConfigStoresOAuthRedirectUriAndDefaultsToNil() {
        XCTAssertNil(AuthConfig().oauthRedirectUri)
        XCTAssertEqual(
            AuthConfig(oauthRedirectUri: "myapp://oauth/callback").oauthRedirectUri,
            "myapp://oauth/callback"
        )
        let passkey = AuthConfig(passkeyRpId: "app.example")
        XCTAssertEqual(passkey.passkeyRpId, "app.example")
        XCTAssertNil(passkey.oauthRedirectUri)
    }

    /// An `AuthAPI` built with the argument list it had before the helpers
    /// existed, as an app or test that builds one by hand still does.
    private func unwiredAuthAPI() -> AuthAPI {
        AuthAPI(
            getUserId: { nil },
            getToken: { nil },
            isAuthenticated: { false },
            emailSignInRequest: { _, _ in true },
            magicLinkVerify: { _ in throw JsBaoError(code: .unavailable) },
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
            hasOfflineGrantStored: { false }
        )
    }

    func testAnUnwiredCallbackHandlerThrowsUnavailable() async {
        do {
            _ = try await unwiredAuthAPI().handleSignInCallback(
                URL(string: "https://app.example/oauth/callback?magic_token=t")!
            )
            XCTFail("expected unavailable")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    func testAnUnwiredTargetOverloadThrowsUnavailable() async {
        do {
            _ = try await unwiredAuthAPI().emailSignInRequest(email: "a@b.test", target: .codeOnly)
            XCTFail("expected unavailable")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    func testAnUnwiredLinkTargetAppliesTheBareRule() {
        let api = unwiredAuthAPI()
        XCTAssertNil(api.emailSignInLinkTarget())
        XCTAssertNil(api.emailSignInLinkTarget(.codeOnly))
        XCTAssertNil(api.emailSignInLinkTarget(.uri("")))
        XCTAssertEqual(api.emailSignInLinkTarget(.uri("https://x.test/cb")), "https://x.test/cb")
    }

    func testWiredClosuresReceiveTheirArguments() async throws {
        let seenTarget = LockedBox<EmailSignInTarget?>(nil)
        let seenCallback = LockedBox<(URL, String?)?>(nil)
        let api = AuthAPI(
            getUserId: { nil },
            getToken: { nil },
            isAuthenticated: { false },
            magicLinkVerify: { _ in throw JsBaoError(code: .unavailable) },
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
            emailSignInRequestWithTarget: { _, target in
                seenTarget.value = target
                return true
            },
            emailSignInLinkTarget: { target in target == .automatic ? "wired" : nil },
            handleSignInCallback: { url, inviteToken in
                seenCallback.value = (url, inviteToken)
                return SignInCallbackResult(method: .oauth, userId: "u1")
            }
        )

        let sent = try await api.emailSignInRequest(email: "a@b.test", target: .codeOnly)
        XCTAssertTrue(sent.success)
        XCTAssertEqual(seenTarget.value, .codeOnly)
        XCTAssertEqual(api.emailSignInLinkTarget(), "wired")

        let url = URL(string: "https://app.example/oauth/callback?magic_token=t")!
        let result = try await api.handleSignInCallback(url, inviteToken: "inv")
        XCTAssertEqual(result.userId, "u1")
        XCTAssertEqual(seenCallback.value?.0, url)
        XCTAssertEqual(seenCallback.value?.1, "inv")
    }
}
