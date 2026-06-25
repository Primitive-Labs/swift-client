import XCTest
@testable import JsBaoClient

/// Passkey tests (#929).
///
/// Two layers:
///  1. `PasskeyWireTests` — pure unit tests for the base64url and WebAuthn
///     JSON translation in `PasskeyWire`. No server, no
///     AuthenticationServices.
///  2. `PasskeyEndpointTests` — live tests against the dev server for the
///     challenge/management endpoints. The *attestation* halves
///     (`register/finish` with a real credential, `auth/finish` with a real
///     assertion) cannot run headless: producing a valid WebAuthn credential
///     requires the system passkey sheet + an Associated Domains
///     entitlement, so the native `registerPasskey` / `signInWithPasskey`
///     happy paths are manually verified in a host app (see PR notes).
final class PasskeyWireTests: XCTestCase {
    // MARK: base64url

    func testBase64UrlRoundTrip() {
        for length in [0, 1, 2, 3, 4, 16, 31, 32, 33, 257] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            let encoded = PasskeyWire.base64UrlEncode(data)
            XCTAssertFalse(encoded.contains("+"), "base64url must not contain '+'")
            XCTAssertFalse(encoded.contains("/"), "base64url must not contain '/'")
            XCTAssertFalse(encoded.contains("="), "base64url must be unpadded")
            XCTAssertEqual(PasskeyWire.base64UrlDecode(encoded), data, "round trip for length \(length)")
        }
    }

    func testBase64UrlEncodeUsesUrlSafeAlphabet() {
        // 0xfb 0xef 0xff is "++//" territory in standard base64 ("++/_" → "-_" url-safe)
        let data = Data([0xfb, 0xef, 0xff])
        let encoded = PasskeyWire.base64UrlEncode(data)
        XCTAssertEqual(encoded, "--__")
        XCTAssertEqual(PasskeyWire.base64UrlDecode(encoded), data)
    }

    func testBase64UrlDecodeAcceptsPaddedInput() {
        XCTAssertEqual(
            PasskeyWire.base64UrlDecode("aGVsbG8="),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            PasskeyWire.base64UrlDecode("aGVsbG8"),
            Data("hello".utf8)
        )
    }

    func testBase64UrlDecodeRejectsGarbage() {
        XCTAssertNil(PasskeyWire.base64UrlDecode("not!valid@base64#"))
    }

    // MARK: Registration options parsing (server → native request)

    /// A realistic `PublicKeyCredentialCreationOptionsJSON` as
    /// @simplewebauthn/server's `generateRegistrationOptions` emits it
    /// (and as `POST /passkey/register/start` returns it, challengeToken
    /// already stripped).
    private func sampleRegistrationOptions() -> [String: Any] {
        [
            "challenge": PasskeyWire.base64UrlEncode(Data("reg-challenge-bytes".utf8)),
            "rp": ["name": "Test App", "id": "example.com"],
            "user": [
                "id": PasskeyWire.base64UrlEncode(Data("user-ulid-123".utf8)),
                "name": "user@example.com",
                "displayName": "Test User",
            ],
            "pubKeyCredParams": [
                ["alg": -8, "type": "public-key"],
                ["alg": -7, "type": "public-key"],
                ["alg": -257, "type": "public-key"],
            ],
            "timeout": 60000,
            "attestation": "none",
            "excludeCredentials": [
                [
                    "id": PasskeyWire.base64UrlEncode(Data([0x01, 0x02, 0x03])),
                    "type": "public-key",
                    "transports": ["internal", "hybrid"],
                ],
            ],
            "authenticatorSelection": [
                "residentKey": "preferred",
                "userVerification": "preferred",
                "requireResidentKey": false,
            ],
            "extensions": ["credProps": true],
        ]
    }

    func testParseRegistrationOptions() throws {
        let parsed = try PasskeyWire.parseRegistrationOptions(sampleRegistrationOptions())
        XCTAssertEqual(parsed.challenge, Data("reg-challenge-bytes".utf8))
        XCTAssertEqual(parsed.rpId, "example.com")
        XCTAssertEqual(parsed.rpName, "Test App")
        XCTAssertEqual(parsed.userId, Data("user-ulid-123".utf8))
        XCTAssertEqual(parsed.userName, "user@example.com")
        XCTAssertEqual(parsed.userDisplayName, "Test User")
        XCTAssertEqual(parsed.excludeCredentialIds, [Data([0x01, 0x02, 0x03])])
        XCTAssertEqual(parsed.userVerification, "preferred")
    }

    func testParseRegistrationOptionsMissingChallengeThrows() {
        var options = sampleRegistrationOptions()
        options.removeValue(forKey: "challenge")
        XCTAssertThrowsError(try PasskeyWire.parseRegistrationOptions(options)) { error in
            guard case PasskeyError.invalidChallenge = error else {
                return XCTFail("Expected PasskeyError.invalidChallenge, got \(error)")
            }
        }
    }

    func testParseRegistrationOptionsMissingRpIdThrows() {
        var options = sampleRegistrationOptions()
        options["rp"] = ["name": "Test App"]
        XCTAssertThrowsError(try PasskeyWire.parseRegistrationOptions(options)) { error in
            guard case PasskeyError.invalidChallenge = error else {
                return XCTFail("Expected PasskeyError.invalidChallenge, got \(error)")
            }
        }
    }

    // MARK: Authentication options parsing

    func testParseAuthenticationOptions() throws {
        let options: [String: Any] = [
            "challenge": PasskeyWire.base64UrlEncode(Data("auth-challenge-bytes".utf8)),
            "timeout": 60000,
            "rpId": "example.com",
            "userVerification": "preferred",
        ]
        let parsed = try PasskeyWire.parseAuthenticationOptions(options)
        XCTAssertEqual(parsed.challenge, Data("auth-challenge-bytes".utf8))
        XCTAssertEqual(parsed.rpId, "example.com")
        XCTAssertEqual(parsed.userVerification, "preferred")
    }

    func testParseAuthenticationOptionsMissingRpIdThrows() {
        let options: [String: Any] = [
            "challenge": PasskeyWire.base64UrlEncode(Data("x".utf8)),
        ]
        XCTAssertThrowsError(try PasskeyWire.parseAuthenticationOptions(options)) { error in
            guard case PasskeyError.invalidChallenge = error else {
                return XCTFail("Expected PasskeyError.invalidChallenge, got \(error)")
            }
        }
    }

    // MARK: Credential payload building (native → server)

    func testRegistrationCredentialJSONShape() throws {
        let credentialId = Data([0xAA, 0xBB, 0xCC])
        let clientDataJSON = Data("{\"type\":\"webauthn.create\"}".utf8)
        let attestationObject = Data([0x01, 0x02, 0x03, 0x04])

        let json = PasskeyWire.registrationCredentialJSON(
            credentialId: credentialId,
            clientDataJSON: clientDataJSON,
            attestationObject: attestationObject,
            transports: ["internal", "hybrid"]
        )

        XCTAssertEqual(json["id"] as? String, PasskeyWire.base64UrlEncode(credentialId))
        XCTAssertEqual(json["rawId"] as? String, json["id"] as? String)
        XCTAssertEqual(json["type"] as? String, "public-key")
        XCTAssertEqual(json["authenticatorAttachment"] as? String, "platform")
        XCTAssertNotNil(json["clientExtensionResults"] as? [String: Any])

        let response = try XCTUnwrap(json["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, PasskeyWire.base64UrlEncode(clientDataJSON))
        XCTAssertEqual(response["attestationObject"] as? String, PasskeyWire.base64UrlEncode(attestationObject))
        XCTAssertEqual(response["transports"] as? [String], ["internal", "hybrid"])

        // Round trip: the server decodes these fields back to the raw bytes.
        XCTAssertEqual(PasskeyWire.base64UrlDecode(response["clientDataJSON"] as! String), clientDataJSON)
        XCTAssertEqual(PasskeyWire.base64UrlDecode(response["attestationObject"] as! String), attestationObject)

        // The body must be JSON-serializable as-is.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: json))
    }

    func testAssertionCredentialJSONShape() throws {
        let credentialId = Data([0x10, 0x20])
        let clientDataJSON = Data("{\"type\":\"webauthn.get\"}".utf8)
        let authenticatorData = Data([0x05, 0x06, 0x07])
        let signature = Data([0x09, 0x08])
        let userHandle = Data("user-ulid-123".utf8)

        let json = PasskeyWire.assertionCredentialJSON(
            credentialId: credentialId,
            clientDataJSON: clientDataJSON,
            authenticatorData: authenticatorData,
            signature: signature,
            userHandle: userHandle
        )

        XCTAssertEqual(json["id"] as? String, PasskeyWire.base64UrlEncode(credentialId))
        XCTAssertEqual(json["rawId"] as? String, json["id"] as? String)
        XCTAssertEqual(json["type"] as? String, "public-key")

        let response = try XCTUnwrap(json["response"] as? [String: Any])
        XCTAssertEqual(response["authenticatorData"] as? String, PasskeyWire.base64UrlEncode(authenticatorData))
        XCTAssertEqual(response["signature"] as? String, PasskeyWire.base64UrlEncode(signature))
        XCTAssertEqual(response["userHandle"] as? String, PasskeyWire.base64UrlEncode(userHandle))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: json))
    }

    func testAssertionCredentialJSONOmitsEmptyUserHandle() throws {
        let json = PasskeyWire.assertionCredentialJSON(
            credentialId: Data([0x01]),
            clientDataJSON: Data([0x02]),
            authenticatorData: Data([0x03]),
            signature: Data([0x04]),
            userHandle: Data()
        )
        let response = try XCTUnwrap(json["response"] as? [String: Any])
        XCTAssertNil(response["userHandle"], "Empty userHandle must be omitted, not sent as \"\"")
    }
}

/// Live tests for the passkey endpoints against the dev server.
final class PasskeyEndpointTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-passkeys")
        // Configure passkeys for the app the same way the JS API suite does.
        // Note: dev-server app creation defaults to passkeyEnabled=true with
        // a `localhost` RP config; `passkeyRpConfig` takes precedence over
        // the legacy passkeyRpId/passkeyRpName fields, so set it explicitly.
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            updates: [
                "passkeyEnabled": true,
                "passkeyRpConfig": ["example.com": ["name": "Swift Passkey Test"]],
            ],
            jwt: testApp.ownerJWT
        )
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: auth/start (unauthenticated)

    func testPasskeyAuthStartReturnsChallenge() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let result = try await client.auth.passkeyAuthStart()
        XCTAssertFalse(result.challengeToken.isEmpty)

        // The typed surface keeps options opaque; check the key fields.
        let challengeB64 = try XCTUnwrap(result.options["challenge"]?.stringValue)
        let challenge = try XCTUnwrap(PasskeyWire.base64UrlDecode(challengeB64))
        XCTAssertGreaterThanOrEqual(challenge.count, 16, "challenge should be real random bytes")
        XCTAssertEqual(result.options["rpId"]?.stringValue, "example.com")

        // And the raw plumbing the native flow uses parses the same payload.
        let raw = try await client.auth.passkeyAuthStartRaw()
        let parsed = try PasskeyWire.parseAuthenticationOptions(raw.options)
        XCTAssertEqual(parsed.rpId, "example.com")
    }

    func testPasskeyAuthStartFailsWhenNotEnabled() async throws {
        let plainApp = try await ctx.createTestApp(name: "swift-passkeys-off")
        // Dev-server app creation defaults passkeyEnabled to true — turn it
        // off explicitly to exercise the PASSKEY_NOT_ENABLED path.
        try await ctx.updateAppSettings(
            appId: plainApp.appId,
            updates: ["passkeyEnabled": false],
            jwt: plainApp.ownerJWT
        )
        let client = createTestClient(appId: plainApp.appId, token: plainApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            _ = try await client.auth.passkeyAuthStart()
            XCTFail("Expected PASSKEY_NOT_ENABLED error")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.authCode, .passkeyNotEnabled)
        }
    }

    // MARK: register/start (authenticated)

    func testPasskeyRegisterStartReturnsCreationOptions() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let raw = try await client.auth.passkeyRegisterStartRaw()
        XCTAssertFalse(raw.challengeToken.isEmpty)

        // The native flow must be able to derive a platform registration
        // request from the live server payload.
        let parsed = try PasskeyWire.parseRegistrationOptions(raw.options)
        XCTAssertEqual(parsed.rpId, "example.com")
        XCTAssertEqual(parsed.rpName, "Swift Passkey Test")
        XCTAssertGreaterThanOrEqual(parsed.challenge.count, 16)
        // simplewebauthn encodes the bao userId (a ULID string) as bytes.
        XCTAssertEqual(String(data: parsed.userId, encoding: .utf8), testApp.ownerUserId)
        XCTAssertFalse(parsed.userName.isEmpty)
        XCTAssertTrue(parsed.excludeCredentialIds.isEmpty, "fresh user should have no registered passkeys")
    }

    // MARK: auth/finish rejects a forged credential

    func testPasskeyAuthFinishRejectsUnknownCredential() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let start = try await client.auth.passkeyAuthStartRaw()
        // A structurally-valid assertion for a credential id the server has
        // never seen. The server must 401 ("Passkey not found") before any
        // signature verification happens.
        let forged = PasskeyWire.assertionCredentialJSON(
            credentialId: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            clientDataJSON: Data("{\"type\":\"webauthn.get\"}".utf8),
            authenticatorData: Data(repeating: 0x00, count: 37),
            signature: Data(repeating: 0x01, count: 64),
            userHandle: nil
        )

        do {
            _ = try await client.auth.passkeyAuthFinish(
                credential: forged,
                challengeToken: start.challengeToken
            )
            XCTFail("Expected 401 for unknown credential")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
        }
    }

    // MARK: management

    func testPasskeyListEmptyForFreshUser() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let result = try await client.auth.passkeyList()
        XCTAssertEqual(result.passkeys, [])
    }

    func testPasskeyDeleteUnknownIdReturns404() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            _ = try await client.auth.passkeyDelete(passkeyId: "pk_does_not_exist")
            XCTFail("Expected 404 for unknown passkey id")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }
}
