import XCTest
@testable import JsBaoClient

/// #2891 — Google is a typed client MAP keyed by client type, because Google
/// registers a client per platform.
///
/// The derived availability flags `/oauth-config` used to publish are gone:
/// `hasOAuth` was clientId-only, so it told a Swift app that Google sign-in was
/// available on a WEB-only configuration and the PKCE exchange then failed at
/// Google. A native client reads its own `ios` entry instead, and the answer is
/// the provider being enabled AND that entry being usable — both together.
///
/// Server-free (`*HermeticTests`): decoding and the availability predicate are
/// entirely client-side, so the payloads are literals. The live-server halves
/// (the authorize URL, the callback route) stay in `GoogleSignInTests`.
final class GoogleClientMapHermeticTests: XCTestCase {

    private func configJSON(
        googleOAuthEnabled: Bool = true,
        clients: String = """
        {
          "web": {
            "clientId": "web-123.apps.googleusercontent.com",
            "redirectUris": ["https://app.example.com/oauth/callback"],
            "usable": true
          },
          "ios": {
            "clientId": "ios-456.apps.googleusercontent.com",
            "redirectUris": ["com.googleusercontent.apps.ios-456:/oauth2redirect"],
            "usable": true
          }
        }
        """
    ) -> Data {
        """
        {
          "appId": "app_1",
          "name": "Test App",
          "mode": "public",
          "waitlistEnabled": false,
          "googleOAuthEnabled": \(googleOAuthEnabled),
          "googleClients": { "clients": \(clients) },
          "passkeyEnabled": true,
          "passkeyRpConfig": { "example.com": { "name": "Test App" } },
          "hasPasskey": true,
          "appleSignInEnabled": false,
          "hasApple": false,
          "magicLinkEnabled": true,
          "otpEnabled": true
        }
        """.data(using: .utf8)!
    }

    private func decode(_ data: Data) throws -> AuthConfigInfo {
        try JSONDecoder().decode(AuthConfigInfo.self, from: data)
    }

    func testDecodesTheClientMapKeyedByType() throws {
        let config = try decode(configJSON())

        XCTAssertEqual(config.googleOAuthEnabled, true)
        XCTAssertEqual(
            config.googleClients?.clients["ios"]?.clientId,
            "ios-456.apps.googleusercontent.com"
        )
        XCTAssertEqual(
            config.googleClients?.clients["ios"]?.redirectUris,
            ["com.googleusercontent.apps.ios-456:/oauth2redirect"]
        )
        XCTAssertEqual(config.googleClients?.clients["ios"]?.usable, true)
        XCTAssertEqual(config.googleClients?.clients["web"]?.usable, true)
    }

    func testDecodesAnAbsentOrEmptyMap() throws {
        // An app with no Google client at all: the map decodes to an empty
        // collection rather than throwing, so a login screen renders with the
        // Google button hidden instead of failing to load.
        let empty = try decode(configJSON(googleOAuthEnabled: false, clients: "{}"))
        XCTAssertEqual(empty.googleClients?.clients.isEmpty, true)
        XCTAssertFalse(empty.googleSignInAvailable)
    }

    func testAvailabilityIsTheEnableFlagAndTheIosEntryTogether() throws {
        // The predicate every native consumer shares (DSO-2891-001).
        XCTAssertTrue(try decode(configJSON()).googleSignInAvailable)

        // Provider switched off, both entries perfectly usable.
        XCTAssertFalse(try decode(configJSON(googleOAuthEnabled: false)).googleSignInAvailable)
    }

    func testAWebOnlyConfigurationIsNotAvailableToANativeClient() throws {
        // The defect `hasOAuth` carried: it was clientId-only, so a web-only
        // app advertised Google sign-in to a Swift client whose PKCE exchange
        // could only fail at Google.
        let webOnly = try decode(configJSON(clients: """
        {
          "web": {
            "clientId": "web-123.apps.googleusercontent.com",
            "redirectUris": ["https://app.example.com/oauth/callback"],
            "usable": true
          }
        }
        """))

        XCTAssertEqual(webOnly.googleClients?.clients["web"]?.usable, true)
        XCTAssertFalse(webOnly.googleSignInAvailable)
    }

    func testAnUnusableIosEntryIsNotAvailable() throws {
        let unusable = try decode(configJSON(clients: """
        {
          "ios": {
            "clientId": "ios-456.apps.googleusercontent.com",
            "redirectUris": [],
            "usable": false
          }
        }
        """))

        XCTAssertFalse(unusable.googleSignInAvailable)
    }

    func testAnOldServerStillSendingHasOAuthReportsUnavailable() throws {
        // The documented client-version floor, not a shim: a server describing
        // a shape this client no longer understands reports unavailable —
        // button hidden, no crash — rather than having availability inferred.
        let legacy = """
        {
          "appId": "app_1",
          "name": "Test App",
          "mode": "public",
          "waitlistEnabled": false,
          "googleOAuthEnabled": true,
          "googleClientId": "ios-456.apps.googleusercontent.com",
          "hasOAuth": true,
          "redirectUris": ["com.googleusercontent.apps.ios-456:/oauth2redirect"],
          "passkeyEnabled": false,
          "hasPasskey": false,
          "appleSignInEnabled": false,
          "hasApple": false,
          "magicLinkEnabled": true,
          "otpEnabled": true
        }
        """.data(using: .utf8)!

        let config = try decode(legacy)
        XCTAssertNil(config.googleClients)
        XCTAssertFalse(config.googleSignInAvailable)
    }

    func testAppConfigInfoReportsTheSamePredicate() throws {
        // `getAppConfig()` is the launch-UI projection of the same envelope, so
        // it must not be able to disagree with `getAuthConfig()` about whether
        // to show the button.
        let available = try decode(configJSON())
        XCTAssertEqual(
            AppConfigInfo(from: available).googleAvailable,
            available.googleSignInAvailable
        )

        let disabled = try decode(configJSON(googleOAuthEnabled: false))
        XCTAssertEqual(AppConfigInfo(from: disabled).googleAvailable, false)
    }
}
