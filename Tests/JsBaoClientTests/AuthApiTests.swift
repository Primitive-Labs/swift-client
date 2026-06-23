import XCTest
@testable import JsBaoClient

/// Live integration coverage for the typed `client.auth` namespace
/// (#964 / #1058): identity accessors, auth/app config, magic-link + OTP
/// request/verify, and logout. The JS client's authController is the source
/// of truth for the wire shapes.
///
/// Native flows (passkeys #929, Google OAuth #928) are deferred and not
/// covered here — they have no Swift surface yet.
final class AuthApiTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-auth-api")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    // MARK: - Identity accessors

    /// Happy path: with a valid token applied, the typed accessors mirror JS
    /// `getUserId()/getToken()/isAuthenticated()` and `waitForUserId` resolves
    /// immediately with the JWT's user id.
    func testIdentityAccessorsReflectToken() async throws {
        XCTAssertTrue(client.auth.isAuthenticated())
        XCTAssertEqual(client.auth.getToken(), testApp.ownerJWT)
        XCTAssertEqual(client.auth.getUserId(), testApp.ownerUserId)

        let uid = try await client.auth.waitForUserId(timeoutMs: 2000)
        XCTAssertEqual(uid, testApp.ownerUserId)
    }

    // MARK: - Auth / app config

    /// `getAuthConfig()` decodes the typed `AuthConfigInfo` and reflects
    /// admin-side feature flags (otpEnabled flips after the admin PUT).
    func testGetAuthConfigTypedReflectsAdminSettings() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: ["otpEnabled": true]
        )

        let config = try await client.auth.getAuthConfig()
        XCTAssertEqual(config.appId, testApp.appId)
        XCTAssertEqual(config.name, testApp.name)
        XCTAssertEqual(config.mode, "public")
        XCTAssertTrue(config.otpEnabled, "otpEnabled must reflect the admin PUT")
    }

    /// `getAppConfig()` returns the typed app-launch subset, including
    /// `magicLinkEnabled`.
    func testGetAppConfigTyped() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: ["magicLinkEnabled": true]
        )

        let config = try await client.auth.getAppConfig()
        XCTAssertEqual(config.appId, testApp.appId)
        XCTAssertEqual(config.mode, "public")
        XCTAssertTrue(config.magicLinkEnabled)
    }

    // MARK: - OTP

    /// Happy path: with OTP enabled, `otpRequest` resolves `{ success: true }`
    /// (the server answers success regardless of account existence to prevent
    /// enumeration). Edge: a wrong 6-digit code on `otpVerify` surfaces the
    /// server's "Invalid or expired" rejection as a thrown error, not a decode
    /// of garbage.
    func testOtpRequestSucceedsAndBadCodeVerifyThrows() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: ["otpEnabled": true]
        )

        // The endpoint answers success for any well-formed email (enumeration
        // safety), so a synthetic address is fine here.
        let result = try await client.auth.otpRequest(email: "test@example.com")
        XCTAssertTrue(result.success)

        do {
            _ = try await client.auth.otpVerify(email: "test@example.com", code: "000000")
            XCTFail("otpVerify with a wrong code must throw")
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("Invalid or expired") || msg.contains("401"),
                "Expected invalid/expired rejection, got: \(msg)"
            )
        }
    }

    /// Edge: with OTP disabled the request endpoint rejects rather than
    /// silently succeeding.
    func testOtpRequestRejectsWhenDisabled() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: ["otpEnabled": false]
        )

        do {
            _ = try await client.auth.otpRequest(email: "test@example.com")
            XCTFail("otpRequest must throw when OTP is disabled for the app")
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("not enabled") || msg.contains("400"),
                "Expected 'not enabled' rejection, got: \(msg)"
            )
        }
    }

    // MARK: - Magic link

    /// Happy path: with magic link enabled and an allow-listed redirectUri,
    /// `magicLinkRequest` resolves `{ success: true }`. Edge: verifying a
    /// garbage token throws instead of returning a half-decoded result.
    func testMagicLinkRequestSucceedsAndBadVerifyThrows() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: [
                "magicLinkEnabled": true,
                "redirectUris": ["https://example.com/callback"],
            ]
        )

        let result = try await client.auth.magicLinkRequest(
            email: "test@example.com",
            redirectUri: "https://example.com/callback"
        )
        XCTAssertTrue(result.success)

        do {
            _ = try await client.auth.magicLinkVerify(token: "not-a-real-token")
            XCTFail("magicLinkVerify with a bogus token must throw")
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("Invalid") || msg.contains("expired") || msg.contains("401") || msg.contains("400"),
                "Expected invalid-token rejection, got: \(msg)"
            )
        }
    }

    /// Edge: a redirectUri that is NOT on the app's allowlist is rejected.
    func testMagicLinkRequestRejectsUnlistedRedirectUri() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: [
                "magicLinkEnabled": true,
                "redirectUris": ["https://example.com/callback"],
            ]
        )

        do {
            _ = try await client.auth.magicLinkRequest(
                email: "test@example.com",
                redirectUri: "https://evil.example.net/steal"
            )
            XCTFail("magicLinkRequest must reject a non-allow-listed redirectUri")
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("Invalid redirect URI") || msg.contains("400"),
                "Expected redirect-URI rejection, got: \(msg)"
            )
        }
    }

    // MARK: - Logout

    /// `auth.logout()` clears the local identity: token gone, accessors flip
    /// to unauthenticated. (Uses a dedicated client so the shared one keeps
    /// its session for other assertions.)
    func testLogoutClearsIdentity() async throws {
        let loggedOut = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await loggedOut.destroy() } }

        XCTAssertTrue(loggedOut.auth.isAuthenticated())
        try await loggedOut.auth.logout()
        XCTAssertFalse(loggedOut.auth.isAuthenticated())
        XCTAssertNil(loggedOut.auth.getToken())
        XCTAssertNil(loggedOut.auth.getUserId())
    }
}
