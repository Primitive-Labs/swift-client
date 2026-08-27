import Foundation

// MARK: - Passkeys: typed request & response models (#929)
//
// Typed models for the passkey surface exposed by `client.auth`. The wire
// contract mirrors the JS client (`src/client/internal/authController.ts`)
// and the server's `PasskeyController` (`src/app-api/controllers/
// passkey-controller.ts`):
//
//   POST /passkey/auth/start       → WebAuthn request options + challengeToken
//   POST /passkey/auth/finish      → { token, user, isNewUser } (session lands)
//   POST /passkey/register/start   → WebAuthn creation options + challengeToken
//   POST /passkey/register/finish  → { success, credentialBackedUp?, invitation? }
//   GET  /passkey/list             → { passkeys: [...] }
//   DELETE /passkey/{passkeyId}    → { success }
//   PATCH  /passkey/{passkeyId}    → { passkey: {...} }
//
// All binary WebAuthn fields (challenge, credential id, clientDataJSON,
// attestationObject, authenticatorData, signature, userHandle) travel as
// **base64url without padding**, exactly as @simplewebauthn/server expects.

// MARK: Errors

/// Typed errors for the passkey flows. `canceled` is the documented
/// "user dismissed the system sheet" signal from the native flows.
public enum PasskeyError: Error, Sendable, Equatable {
    /// The user canceled the system passkey sheet.
    case canceled
    /// The server's challenge options were missing a required field.
    case invalidChallenge(String)
    /// The platform returned a credential type the SDK doesn't handle.
    case unexpectedCredential
    /// Registration completed without an attestation object (should not
    /// happen for platform passkey registrations).
    case missingAttestation
}

extension PasskeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .canceled:
            return "Passkey operation canceled by the user"
        case .invalidChallenge(let detail):
            return "Invalid passkey challenge options: \(detail)"
        case .unexpectedCredential:
            return "Unexpected credential type returned by the platform"
        case .missingAttestation:
            return "Passkey registration returned no attestation object"
        }
    }
}

// MARK: Start results

/// Result of `auth.passkeyAuthStart()`. Mirrors JS
/// `{ options, challengeToken }` — `options` is the WebAuthn
/// `PublicKeyCredentialRequestOptionsJSON` the server generated (challenge
/// is base64url), kept opaque as `JSONValue`. Pass `challengeToken` back to
/// `passkeyAuthFinish`.
public struct PasskeyAuthStartResult: Sendable {
    public let options: JSONValue
    public let challengeToken: String

    public init(options: JSONValue, challengeToken: String) {
        self.options = options
        self.challengeToken = challengeToken
    }
}

/// Result of `auth.passkeyRegisterStart()`. Mirrors JS
/// `{ options, challengeToken }` — `options` is the WebAuthn
/// `PublicKeyCredentialCreationOptionsJSON` (challenge and `user.id` are
/// base64url). Pass `challengeToken` back to `passkeyRegisterFinish`.
public struct PasskeyRegisterStartResult: Sendable {
    public let options: JSONValue
    public let challengeToken: String

    public init(options: JSONValue, challengeToken: String) {
        self.options = options
        self.challengeToken = challengeToken
    }
}

// MARK: Finish results

/// Result of `auth.passkeyAuthFinish(...)` / `auth.signInWithPasskey(...)`.
/// Mirrors JS `{ user, isNewUser? }`. On success the SDK has already applied
/// the returned access token (cause `"passkeyAuth"`), emitting
/// `.authSuccess` / `.authState` like the other sign-in paths.
public struct PasskeySignInResult: Decodable, Sendable, Equatable {
    public let user: AuthUser
    /// Always `false` from the server today — passkey sign-in requires a
    /// previously-registered credential.
    public let isNewUser: Bool?
}

/// Deferred-grant resolution summary returned when an `inviteToken` is
/// folded into passkey registration (#466).
public struct PasskeyInvitationGrants: Decodable, Sendable, Equatable {
    public let groups: Int
    public let documents: Int
}

/// Invitation acceptance info returned by `passkeyRegisterFinish` when an
/// `inviteToken` was supplied.
public struct PasskeyInvitationResult: Decodable, Sendable, Equatable {
    public let invitationId: String
    public let grantsResolved: PasskeyInvitationGrants
}

/// Result of `auth.passkeyRegisterFinish(...)` / `auth.registerPasskey(...)`.
/// Mirrors JS `{ success, credentialBackedUp?, invitation? }`.
public struct PasskeyRegistrationResult: Decodable, Sendable, Equatable {
    public let success: Bool
    /// Whether the authenticator reported the credential as backed up
    /// (synced to iCloud Keychain).
    public let credentialBackedUp: Bool?
    /// Present when an `inviteToken` was supplied and accepted (#466).
    public let invitation: PasskeyInvitationResult?
}

// MARK: Management

/// A registered passkey as returned by `auth.passkeyList()` /
/// `auth.passkeyUpdate(...)`. Mirrors the sanitized server shape
/// (`passkeyId`, `deviceName`, ISO-8601 timestamps, and — list only — a
/// truncated `credentialIdPreview`).
public struct PasskeyInfo: Decodable, Sendable, Equatable {
    public let passkeyId: String
    public let deviceName: String
    public let createdAt: String
    public let lastUsedAt: String?
    /// Truncated credential id for identification (list endpoint only).
    public let credentialIdPreview: String?
}

/// Result of `auth.passkeyList()`. Mirrors JS `{ passkeys: [...] }`.
public struct PasskeyListResult: Decodable, Sendable, Equatable {
    public let passkeys: [PasskeyInfo]
}

/// Result of `auth.passkeyDelete(...)`. Mirrors JS `{ success: boolean }`.
public struct PasskeyDeleteResult: Decodable, Sendable, Equatable {
    public let success: Bool
}

/// Result of `auth.passkeyUpdate(...)`. Mirrors JS `{ passkey: {...} }`.
public struct PasskeyUpdateResult: Decodable, Sendable, Equatable {
    public let passkey: PasskeyInfo
}
