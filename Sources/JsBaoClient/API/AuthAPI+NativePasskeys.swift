import Foundation

// MARK: - Native passkey flows (#929)
//
// `signInWithPasskey` / `registerPasskey`: drive Apple's system passkey UI
// (AuthenticationServices) against the SAME server challenge/verify
// endpoints the JS client uses — only the credential collection differs
// (ASAuthorizationPlatformPublicKeyCredentialProvider instead of the
// browser's `navigator.credentials`). The wire translation (base64url,
// WebAuthn JSON shapes) lives in `PasskeyWire`; the wire-level endpoint
// methods live on `AuthAPI` (see AuthAPI.swift).
//
// Platform requirements for callers:
//  * The app must declare an Associated Domains capability with a
//    `webcredentials:<rpId>` entitlement, and the RP domain must serve an
//    `apple-app-site-association` file listing the app — otherwise the
//    system sheet fails with "application not associated with domain".
//  * The RP id must be one of the app's configured passkey RP ids
//    (`passkeyRpConfig` / `passkeyRpId` in app settings). Name it — via
//    `AuthConfig.passkeyRpId` or the `rpId:` argument — because a native
//    request carries no `Origin` header for the server to derive it from
//    (#3024). Verification accepts `https://<rpId>`, which is what Apple
//    reports as the clientDataJSON origin, with no CORS entry needed.
//
// Gated so `swift build` succeeds on platforms without
// AuthenticationServices (e.g. Linux). `webauthn-large-blob` remains
// excluded (see docs/exclusions-v1.md).

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension AuthAPI {
    /// Sign in with a passkey using the system sheet (discoverable
    /// credential flow — the user picks from passkeys saved for the app's
    /// RP domain). On success the SDK has already applied the returned
    /// access token (cause `"passkeyAuth"`), emitting `.authSuccess` /
    /// `.authState` like the other sign-in paths.
    ///
    /// - Parameters:
    ///   - presentationAnchor: The window to present the system sheet from.
    ///     Pass `nil` to let the system pick a default anchor.
    ///   - rpId: The relying party to sign in against — the host in the app's
    ///     `webcredentials:` entitlement. Defaults to `AuthConfig.passkeyRpId`.
    ///     A native request sends no `Origin` header, so with neither the
    ///     server picks among the app's configured relying parties on its own
    ///     and a multi-RP app can get the wrong one (#3024).
    ///   - preferImmediatelyAvailableCredentials: When `true`, only consult
    ///     passkeys already on this device — if none exist the request fails
    ///     fast with `PasskeyError.canceled` instead of showing the
    ///     "use another device / QR" fallback sheet. This is the standard
    ///     pattern for opportunistic "sign in with your passkey?" prompts on
    ///     return visits; leave `false` for an explicit user-initiated
    ///     button, where the cross-device fallback is desirable.
    /// - Throws: `PasskeyError.canceled` when the user dismisses the sheet
    ///   (or no local passkey exists under
    ///   `preferImmediatelyAvailableCredentials`); `HttpError` for
    ///   server-side verification failures.
    public func signInWithPasskey(
        presentationAnchor: ASPresentationAnchor? = nil,
        preferImmediatelyAvailableCredentials: Bool = false,
        rpId: String? = nil
    ) async throws -> PasskeySignInResult {
        let start = try await passkeyAuthStart(rpId: rpId)
        let challenge = try PasskeyWire.parseAuthenticationOptions(start.wireOptions)

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: challenge.rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge.challenge)
        if let uv = challenge.userVerification {
            request.userVerificationPreference =
                ASAuthorizationPublicKeyCredentialUserVerificationPreference(rawValue: uv)
        }

        let authorization = try await PasskeyAuthorizationSession()
            .perform(
                requests: [request],
                anchor: presentationAnchor,
                preferImmediatelyAvailableCredentials: preferImmediatelyAvailableCredentials
            )
        guard let assertion = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.unexpectedCredential
        }

        let credential = PasskeyWire.assertionCredentialJSON(
            credentialId: assertion.credentialID,
            clientDataJSON: assertion.rawClientDataJSON,
            authenticatorData: assertion.rawAuthenticatorData,
            signature: assertion.signature,
            userHandle: assertion.userID
        )
        return try await passkeyAuthFinish(
            credential: try JSONCoding.decode(JSONValue.self, from: credential),
            challengeToken: start.challengeToken
        )
    }

    /// Register a new passkey for the **current (authenticated) user** using
    /// the system sheet. The credential is created for the app's configured
    /// RP domain and saved to iCloud Keychain.
    ///
    /// - Parameters:
    ///   - deviceName: Optional human-readable label stored server-side for
    ///     this passkey (e.g. `"Rhett's iPhone"`). Maps to the wire field
    ///     `deviceName`; defaults server-side to `"Unknown device"`.
    ///   - inviteToken: Optional invitation token (#466) — folds invitation
    ///     acceptance into the registration call.
    ///   - presentationAnchor: The window to present the system sheet from.
    ///     Pass `nil` to let the system pick a default anchor.
    ///   - rpId: The relying party to register the passkey under — the host in
    ///     the app's `webcredentials:` entitlement. Defaults to
    ///     `AuthConfig.passkeyRpId` (#3024).
    /// - Throws: `PasskeyError.canceled` when the user dismisses the sheet;
    ///   `HttpError` for server-side verification failures.
    @discardableResult
    public func registerPasskey(
        deviceName: String? = nil,
        inviteToken: String? = nil,
        presentationAnchor: ASPresentationAnchor? = nil,
        rpId: String? = nil
    ) async throws -> PasskeyRegistrationResult {
        let start = try await passkeyRegisterStart(rpId: rpId)
        let challenge = try PasskeyWire.parseRegistrationOptions(start.wireOptions)

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: challenge.rpId
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge.challenge,
            name: challenge.userName,
            userID: challenge.userId
        )
        if let uv = challenge.userVerification {
            request.userVerificationPreference =
                ASAuthorizationPublicKeyCredentialUserVerificationPreference(rawValue: uv)
        }
        // Honor the server's excludeCredentials (don't re-register an
        // existing passkey) where the OS supports it.
        if #available(iOS 17.4, macOS 14.4, *) {
            if !challenge.excludeCredentialIds.isEmpty {
                request.excludedCredentials = challenge.excludeCredentialIds.map {
                    ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
                }
            }
        }

        let authorization = try await PasskeyAuthorizationSession()
            .perform(requests: [request], anchor: presentationAnchor)
        guard let registration = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PasskeyError.unexpectedCredential
        }
        guard let attestationObject = registration.rawAttestationObject else {
            throw PasskeyError.missingAttestation
        }

        // Platform passkeys are reachable on-device ("internal") and via
        // cross-device sign-in ("hybrid") — same hints Safari reports.
        let credential = PasskeyWire.registrationCredentialJSON(
            credentialId: registration.credentialID,
            clientDataJSON: registration.rawClientDataJSON,
            attestationObject: attestationObject,
            transports: ["internal", "hybrid"]
        )
        return try await passkeyRegisterFinish(
            credential: try JSONCoding.decode(JSONValue.self, from: credential),
            challengeToken: start.challengeToken,
            deviceName: deviceName,
            inviteToken: inviteToken
        )
    }
}

// MARK: - ASAuthorizationController async bridge

/// Bridges the delegate-based `ASAuthorizationController` to async/throws.
/// One-shot: create a fresh session per `perform` call. User cancellation is
/// mapped to the typed `PasskeyError.canceled`.
final class PasskeyAuthorizationSession: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding,
    @unchecked Sendable {

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var anchor: ASPresentationAnchor?
    // Strong reference keeps the controller (and ourselves, via the
    // delegate's back-pointer captured in `perform`) alive until a delegate
    // callback fires.
    private var controller: ASAuthorizationController?

    @MainActor
    func perform(
        requests: [ASAuthorizationRequest],
        anchor: ASPresentationAnchor?,
        preferImmediatelyAvailableCredentials: Bool = false
    ) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.anchor = anchor
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            // ALWAYS install the provider. Without one, iOS can fail to
            // present the sheet silently — no delegate callback ever fires
            // and the caller awaits forever. A nil anchor is resolved to
            // the key window in `presentationAnchor(for:)` below, same as
            // `WebAuthenticationPresenter` (GoogleSignIn.swift).
            controller.presentationContextProvider = self
            self.controller = controller
            if preferImmediatelyAvailableCredentials {
                // Local-credentials-only: fails fast (delegate error,
                // surfaced as .canceled) when this device has no passkey,
                // instead of presenting the cross-device/QR sheet.
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            finish(.failure(PasskeyError.canceled))
        } else {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // The framework calls this on the main thread.
        MainActor.assumeIsolated {
            if let anchor {
                return anchor
            }
            #if os(macOS)
            return NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        self.controller = nil
        continuation.resume(with: result)
    }
}
#endif
