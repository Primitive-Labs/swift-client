import Foundation

// MARK: - PasskeyWire (#929)
//
// Pure helpers that translate between the server's WebAuthn JSON wire format
// (@simplewebauthn/server) and the raw `Data` values Apple's
// AuthenticationServices framework speaks. Deliberately framework-free so
// the encode/decode round-trips are unit-testable on any platform; the
// AuthenticationServices bridging lives in `AuthAPI+NativePasskeys.swift`.
//
// Encoding rule: every binary field is **base64url without padding**
// (`+`→`-`, `/`→`_`, trailing `=` stripped) — the exact format
// @simplewebauthn/server emits in challenge options and expects back in
// `RegistrationResponseJSON` / `AuthenticationResponseJSON`.
public enum PasskeyWire {
    // MARK: Base64url

    /// Encode bytes as base64url without padding.
    public static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string (padded or unpadded). Returns `nil` for
    /// malformed input.
    public static func base64UrlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    // MARK: Parsed challenge options

    /// The fields of a server `PublicKeyCredentialCreationOptionsJSON` the
    /// native registration flow needs, with binary fields decoded.
    public struct RegistrationChallenge: Sendable, Equatable {
        public let challenge: Data
        public let rpId: String
        public let rpName: String?
        public let userId: Data
        public let userName: String
        public let userDisplayName: String?
        /// Decoded `excludeCredentials[].id` values (already-registered
        /// credential ids the authenticator should refuse to duplicate).
        public let excludeCredentialIds: [Data]
        /// `authenticatorSelection.userVerification` when present
        /// (`"required"` / `"preferred"` / `"discouraged"`).
        public let userVerification: String?
    }

    /// The fields of a server `PublicKeyCredentialRequestOptionsJSON` the
    /// native assertion flow needs, with the challenge decoded.
    public struct AssertionChallenge: Sendable, Equatable {
        public let challenge: Data
        public let rpId: String
        /// Top-level `userVerification` when present.
        public let userVerification: String?
    }

    /// Parse the registration (creation) options dict returned by
    /// `POST /passkey/register/start`.
    public static func parseRegistrationOptions(_ options: [String: Any]) throws -> RegistrationChallenge {
        guard let challengeB64 = options["challenge"] as? String,
              let challenge = base64UrlDecode(challengeB64) else {
            throw PasskeyError.invalidChallenge("missing or undecodable challenge")
        }
        guard let rp = options["rp"] as? [String: Any],
              let rpId = rp["id"] as? String, !rpId.isEmpty else {
            throw PasskeyError.invalidChallenge("missing rp.id")
        }
        guard let user = options["user"] as? [String: Any],
              let userIdB64 = user["id"] as? String,
              let userId = base64UrlDecode(userIdB64),
              let userName = user["name"] as? String else {
            throw PasskeyError.invalidChallenge("missing user.id or user.name")
        }

        var excludeIds: [Data] = []
        if let exclude = options["excludeCredentials"] as? [[String: Any]] {
            for descriptor in exclude {
                if let idB64 = descriptor["id"] as? String,
                   let id = base64UrlDecode(idB64) {
                    excludeIds.append(id)
                }
            }
        }

        let selection = options["authenticatorSelection"] as? [String: Any]
        return RegistrationChallenge(
            challenge: challenge,
            rpId: rpId,
            rpName: rp["name"] as? String,
            userId: userId,
            userName: userName,
            userDisplayName: user["displayName"] as? String,
            excludeCredentialIds: excludeIds,
            userVerification: selection?["userVerification"] as? String
        )
    }

    /// Parse the authentication (request) options dict returned by
    /// `POST /passkey/auth/start`.
    public static func parseAuthenticationOptions(_ options: [String: Any]) throws -> AssertionChallenge {
        guard let challengeB64 = options["challenge"] as? String,
              let challenge = base64UrlDecode(challengeB64) else {
            throw PasskeyError.invalidChallenge("missing or undecodable challenge")
        }
        guard let rpId = options["rpId"] as? String, !rpId.isEmpty else {
            throw PasskeyError.invalidChallenge("missing rpId")
        }
        return AssertionChallenge(
            challenge: challenge,
            rpId: rpId,
            userVerification: options["userVerification"] as? String
        )
    }

    // MARK: Credential payloads

    /// Build the `RegistrationResponseJSON` body for
    /// `POST /passkey/register/finish` from the raw values an
    /// `ASAuthorizationPlatformPublicKeyCredentialRegistration` exposes.
    public static func registrationCredentialJSON(
        credentialId: Data,
        clientDataJSON: Data,
        attestationObject: Data,
        transports: [String]? = nil
    ) -> [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": base64UrlEncode(clientDataJSON),
            "attestationObject": base64UrlEncode(attestationObject),
        ]
        if let transports = transports, !transports.isEmpty {
            response["transports"] = transports
        }
        return [
            "id": base64UrlEncode(credentialId),
            "rawId": base64UrlEncode(credentialId),
            "type": "public-key",
            "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: Any](),
            "response": response,
        ]
    }

    /// Build the `AuthenticationResponseJSON` body for
    /// `POST /passkey/auth/finish` from the raw values an
    /// `ASAuthorizationPlatformPublicKeyCredentialAssertion` exposes.
    public static func assertionCredentialJSON(
        credentialId: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userHandle: Data?
    ) -> [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": base64UrlEncode(clientDataJSON),
            "authenticatorData": base64UrlEncode(authenticatorData),
            "signature": base64UrlEncode(signature),
        ]
        if let userHandle = userHandle, !userHandle.isEmpty {
            response["userHandle"] = base64UrlEncode(userHandle)
        }
        return [
            "id": base64UrlEncode(credentialId),
            "rawId": base64UrlEncode(credentialId),
            "type": "public-key",
            "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: Any](),
            "response": response,
        ]
    }
}
