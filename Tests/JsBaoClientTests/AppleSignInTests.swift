import XCTest
@testable import JsBaoClient

/// Tests for the native Sign in with Apple surface (#409 port).
///
/// The interactive piece (ASAuthorizationController) can't run headless, so
/// these tests cover everything around it: nonce generation, the
/// raw-nonce → SHA-256-hex hashing the server's verifier recomputes, the
/// `POST /auth/apple/callback` request-body construction, and error mapping.
/// Mirrors the structure of `GoogleSignInUnitTests`.
final class AppleSignInUnitTests: XCTestCase {

    // MARK: - Raw nonce generation

    func testGenerateRawNonceShapeAndUniqueness() {
        let nonce = AppleSignInHelpers.generateRawNonce()
        // 32 bytes base64url (no padding) = 43 characters.
        XCTAssertEqual(nonce.count, 43)

        // base64url alphabet only — URL- and JSON-safe.
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        XCTAssertTrue(
            nonce.unicodeScalars.allSatisfy { allowed.contains($0) },
            "unexpected characters in nonce: \(nonce)"
        )

        // Fresh value per sign-in attempt (replay protection).
        XCTAssertNotEqual(nonce, AppleSignInHelpers.generateRawNonce())
    }

    // MARK: - Nonce hashing

    func testSha256HexKnownVectors() {
        // ASAuthorizationAppleIDRequest.nonce takes the SHA-256 of the raw
        // nonce as LOWERCASE HEX; the server recomputes sha256Hex(rawNonce)
        // and compares it to the identity token's `nonce` claim, so the
        // format must match exactly (NIST FIPS 180-4 test vector for "abc").
        XCTAssertEqual(
            AppleSignInHelpers.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            AppleSignInHelpers.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testSha256HexIsLowercase() {
        let digest = AppleSignInHelpers.sha256Hex(AppleSignInHelpers.generateRawNonce())
        XCTAssertEqual(digest, digest.lowercased())
        XCTAssertEqual(digest.count, 64)
    }

    // MARK: - Callback request body

    func testCallbackBodyRequiredFieldsOnly() {
        let body = AppleSignInHelpers.callbackBody(
            identityToken: "eyJ.identity.token",
            rawNonce: "raw-nonce-43-chars",
            user: "001234.abcdef.5678"
        )
        XCTAssertEqual(body["identityToken"] as? String, "eyJ.identity.token")
        // The RAW nonce goes to the server (it re-hashes); never the digest.
        XCTAssertEqual(body["nonce"] as? String, "raw-nonce-43-chars")
        XCTAssertEqual(body["user"] as? String, "001234.abcdef.5678")
        // First-authorization hints omitted when Apple didn't provide them —
        // no null placeholders on the wire.
        XCTAssertFalse(body.keys.contains("email"))
        XCTAssertFalse(body.keys.contains("firstName"))
        XCTAssertFalse(body.keys.contains("lastName"))
        XCTAssertEqual(body.count, 3)
    }

    func testCallbackBodyIncludesHintsWhenPresent() {
        let body = AppleSignInHelpers.callbackBody(
            identityToken: "tok",
            rawNonce: "nonce",
            user: "user",
            email: "rhett@example.com",
            firstName: "Rhett",
            lastName: "Owen"
        )
        XCTAssertEqual(body["email"] as? String, "rhett@example.com")
        XCTAssertEqual(body["firstName"] as? String, "Rhett")
        XCTAssertEqual(body["lastName"] as? String, "Owen")
    }

    func testCallbackBodyOmitsEmptyHints() {
        let body = AppleSignInHelpers.callbackBody(
            identityToken: "tok",
            rawNonce: "nonce",
            user: "user",
            email: "",
            firstName: "",
            lastName: nil
        )
        XCTAssertFalse(body.keys.contains("email"))
        XCTAssertFalse(body.keys.contains("firstName"))
        XCTAssertFalse(body.keys.contains("lastName"))
    }

    func testCallbackBodySerializesToJSON() throws {
        // The body must be JSONSerialization-clean (it's posted as JSON).
        let body = AppleSignInHelpers.callbackBody(
            identityToken: "tok",
            rawNonce: "nonce",
            user: "user",
            email: "a@b.c"
        )
        let data = try JSONSerialization.data(withJSONObject: body)
        let roundTrip = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(roundTrip["user"] as? String, "user")
    }

    // MARK: - Server error mapping

    func testMapServerError501ToNotConfigured() {
        let http = HttpError(
            status: 501,
            message: "HTTP 501",
            serverMessage: "Sign in with Apple is not enabled for this app"
        )
        let mapped = AppleSignInHelpers.mapServerError(http)
        XCTAssertEqual(
            mapped as? AppleSignInError,
            .notConfigured("Sign in with Apple is not enabled for this app")
        )
    }

    func testMapServerErrorByCodeToNotConfigured() {
        let http = HttpError(
            status: 400,
            message: "HTTP 400",
            serverCode: "APPLE_AUTH_NOT_CONFIGURED"
        )
        let mapped = AppleSignInHelpers.mapServerError(http)
        guard case .notConfigured = mapped as? AppleSignInError else {
            return XCTFail("expected .notConfigured, got \(mapped)")
        }
    }

    func testMapServerErrorPassesThroughAuthRejections() {
        // A 401 (bad identity token, nonce mismatch, waitlist...) is a real
        // auth failure and must surface as the original HttpError.
        let http = HttpError(
            status: 401,
            message: "HTTP 401",
            serverCode: "APPLE_IDENTITY_INVALID"
        )
        let mapped = AppleSignInHelpers.mapServerError(http)
        XCTAssertEqual((mapped as? HttpError)?.status, 401)
        XCTAssertEqual((mapped as? HttpError)?.serverCode, "APPLE_IDENTITY_INVALID")
    }

    // MARK: - Error surface

    func testCancelledErrorIsTyped() {
        // The user-cancel case must be a distinct, switchable error so apps
        // can silently dismiss instead of showing an alert.
        let error: Error = AppleSignInError.cancelled
        XCTAssertEqual(error as? AppleSignInError, .cancelled)
        XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
    }

    func testErrorDescriptionsAreNonEmpty() {
        let errors: [AppleSignInError] = [
            .cancelled,
            .notConfigured("not set up"),
            .providerError("entitlement missing"),
            .missingIdentityToken,
        ]
        for error in errors {
            let description = (error as LocalizedError).errorDescription
            XCTAssertEqual(description?.isEmpty, false, "empty description for \(error)")
        }
    }
}
