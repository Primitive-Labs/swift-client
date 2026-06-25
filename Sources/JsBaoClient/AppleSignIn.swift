import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Native Sign in with Apple (#409 port)
//
// One-call native Sign in with Apple, modeled on `signInWithGoogle`
// (GoogleSignIn.swift): present the system Apple ID sheet
// (`ASAuthorizationController` + `ASAuthorizationAppleIDProvider`), then
// POST the identity token to the server's `POST /auth/apple/callback`
// (relative to the app API base, like every other auth endpoint) and land
// the session, emitting the same `.authSuccess` / `.authState` events as
// the other interactive sign-in paths (cause `"apple"`).
//
// Nonce protocol (what the server's `apple-identity-verifier` expects):
// the client generates a random **raw** nonce, puts its SHA-256 digest as
// **lowercase hex** on `ASAuthorizationAppleIDRequest.nonce` (Apple embeds
// that value verbatim in the identity token's `nonce` claim), and sends the
// raw nonce to the server, which re-hashes it and compares — replay
// protection without the server ever pre-registering a nonce.

// MARK: - Result & errors

/// Result of a completed native Sign in with Apple.
public struct AppleSignInResult: Sendable {
    /// The signed-in user's ID (from the freshly applied JWT).
    public let userId: String?
    /// Whether the server provisioned a new user for this sign-in
    /// (the `isNewUser` field of the Apple callback response).
    public let isNewUser: Bool

    public init(userId: String?, isNewUser: Bool) {
        self.userId = userId
        self.isNewUser = isNewUser
    }
}

/// Typed errors for the native Sign in with Apple flow. Mirrors
/// `OAuthSignInError`: user cancellation is a first-class case
/// (`.cancelled`) so apps can silently dismiss instead of showing an error.
public enum AppleSignInError: Error, Equatable, Sendable {
    /// The user dismissed the system Apple ID sheet.
    case cancelled
    /// The server has Sign in with Apple disabled or unconfigured for this
    /// app (HTTP 501 / `APPLE_AUTH_NOT_CONFIGURED`).
    case notConfigured(String)
    /// AuthenticationServices failed with a non-cancel error (e.g. the app
    /// is missing the Sign in with Apple capability/entitlement).
    case providerError(String)
    /// The authorization completed but the credential carried no identity
    /// token (nothing to send to the server).
    case missingIdentityToken
}

extension AppleSignInError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in was cancelled"
        case .notConfigured(let message):
            return message
        case .providerError(let message):
            return "Apple authorization failed: \(message)"
        case .missingIdentityToken:
            return "Apple authorization returned no identity token"
        }
    }
}

// MARK: - Pure helpers (unit-testable, no UI)

enum AppleSignInHelpers {
    /// Generate the random **raw** nonce for one sign-in attempt: 32 random
    /// bytes, base64url-encoded (43 unreserved characters). The raw value
    /// goes to the server; its SHA-256 hex goes to Apple (see `sha256Hex`).
    static func generateRawNonce() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return PasskeyWire.base64UrlEncode(Data(bytes))
    }

    /// Lowercase-hex SHA-256 of a string — the value to set on
    /// `ASAuthorizationAppleIDRequest.nonce`. Apple copies it into the
    /// identity token's `nonce` claim; the server recomputes
    /// `sha256Hex(rawNonce)` and compares, so the format must be exactly
    /// `digest.map { String(format: "%02x", $0) }.joined()`.
    static func sha256Hex(_ input: String) -> String {
        hashSHA256(Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Build the JSON body for `POST /auth/apple/callback`. Required fields
    /// `identityToken` / `nonce` (raw) / `user`; the email/name hints are
    /// included only when Apple provided them (first authorization only).
    static func callbackBody(
        identityToken: String,
        rawNonce: String,
        user: String,
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "identityToken": identityToken,
            "nonce": rawNonce,
            "user": user,
        ]
        if let email, !email.isEmpty { body["email"] = email }
        if let firstName, !firstName.isEmpty { body["firstName"] = firstName }
        if let lastName, !lastName.isEmpty { body["lastName"] = lastName }
        return body
    }

    /// Map a server-side failure of the callback exchange to the typed
    /// error surface where it has a clear meaning. HTTP 501 (or the
    /// explicit `APPLE_AUTH_NOT_CONFIGURED` code) means the app hasn't
    /// enabled Sign in with Apple — a configuration problem, not a
    /// credential problem. Everything else passes through unchanged
    /// (`HttpError` for 4xx auth rejections, etc.).
    static func mapServerError(_ error: Error) -> Error {
        if let httpError = error as? HttpError,
           httpError.status == 501 || httpError.serverCode == "APPLE_AUTH_NOT_CONFIGURED" {
            return AppleSignInError.notConfigured(
                httpError.serverMessage ?? "Sign in with Apple is not configured for this app"
            )
        }
        return error
    }
}

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst) || os(visionOS))

// MARK: - JsBaoClient.signInWithApple

extension JsBaoClient {
    /// Native Sign in with Apple: presents the system Apple ID sheet,
    /// exchanges the identity token with the server
    /// (`POST /auth/apple/callback`), and lands the session — one call,
    /// like `signInWithGoogle` (#928).
    ///
    /// ```swift
    /// let result = try await client.signInWithApple(presentationAnchor: window)
    /// ```
    ///
    /// Requires the app to have the **Sign in with Apple** capability, and
    /// the server app config to have Apple auth enabled with the app's
    /// bundle ID registered as an allowed audience.
    ///
    /// - Parameter presentationAnchor: The window to present the sheet
    ///   from. Pass `nil` to let the system pick a default anchor.
    /// - Returns: `AppleSignInResult` with the signed-in `userId` and the
    ///   server's `isNewUser` flag.
    /// - Throws: `AppleSignInError.cancelled` when the user dismisses the
    ///   sheet; `.providerError` / `.missingIdentityToken` /
    ///   `.notConfigured` for the other flow failures; `HttpError` /
    ///   `JsBaoError` for server-side failures.
    @MainActor
    public func signInWithApple(
        presentationAnchor: ASPresentationAnchor? = nil
    ) async throws -> AppleSignInResult {
        // 1. Fresh nonce pair: raw → server, SHA-256 hex → Apple.
        let rawNonce = AppleSignInHelpers.generateRawNonce()

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleSignInHelpers.sha256Hex(rawNonce)

        // 2. Present the system sheet and wait for the authorization.
        let authorization = try await AppleAuthorizationSession()
            .perform(requests: [request], anchor: presentationAnchor)
        guard let credential = authorization.credential
                as? ASAuthorizationAppleIDCredential else {
            throw AppleSignInError.providerError(
                "Unexpected credential type: \(type(of: authorization.credential))"
            )
        }
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              !identityToken.isEmpty else {
            throw AppleSignInError.missingIdentityToken
        }

        // 3. Exchange with the server. This applies the session token
        //    (cause "apple"), emits .authSuccess/.authState, and reconnects
        //    the WebSocket — same sequencing as handleOAuthCallback.
        let response: [String: Any]
        do {
            response = try await handleAppleCallback(
                identityToken: identityToken,
                rawNonce: rawNonce,
                user: credential.user,
                email: credential.email,
                firstName: credential.fullName?.givenName,
                lastName: credential.fullName?.familyName
            )
        } catch {
            throw AppleSignInHelpers.mapServerError(error)
        }

        return AppleSignInResult(
            userId: getUserId(),
            isNewUser: response["isNewUser"] as? Bool ?? false
        )
    }
}

// MARK: - ASAuthorizationController async bridge

/// Bridges the delegate-based `ASAuthorizationController` to async/throws
/// for the Apple ID flow. One-shot: create a fresh session per `perform`
/// call. Mirrors `PasskeyAuthorizationSession` (AuthAPI+NativePasskeys.swift)
/// but maps cancellation to the Apple-flow's typed `.cancelled`.
final class AppleAuthorizationSession: NSObject,
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
        anchor: ASPresentationAnchor?
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
            controller.performRequests()
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
            finish(.failure(AppleSignInError.cancelled))
        } else if let asError = error as? ASAuthorizationError {
            finish(.failure(AppleSignInError.providerError(asError.localizedDescription)))
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
