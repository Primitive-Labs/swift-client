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

// MARK: - Native Google sign-in (#928)
//
// One-call native Google sign-in built atop the raw `startOAuthFlow` /
// `handleOAuthCallback` building blocks. Mirrors the JS client's one-call
// web experience: present the system auth UI (`ASWebAuthenticationSession`),
// catch the custom-scheme redirect, exchange the code, and land the session
// (emitting the same `.authSuccess` / `.authState` events as every other
// interactive sign-in path).
//
// The raw `startOAuthFlow(redirectUri:continueUrl:)` remains public for apps
// that want to drive their own auth UI.

// MARK: - Result & errors

/// Result of a completed native sign-in.
public struct GoogleSignInResult: Sendable {
    /// The signed-in user's ID (from the freshly applied JWT).
    public let userId: String?
    /// Whether the server provisioned a new user for this sign-in
    /// (the `isNewUser` field of the OAuth callback response).
    public let isNewUser: Bool

    public init(userId: String?, isNewUser: Bool) {
        self.userId = userId
        self.isNewUser = isNewUser
    }
}

/// Typed errors for the native OAuth sign-in flow. User cancellation is a
/// first-class case (`.cancelled`) so apps can silently dismiss instead of
/// showing an error.
public enum OAuthSignInError: Error, Equatable, Sendable {
    /// The user dismissed the system auth sheet.
    case cancelled
    /// The flow can't start: no redirect URI was provided and none could be
    /// derived from a bundled `GoogleService-Info.plist`.
    case notConfigured(String)
    /// The OAuth provider returned an error on the callback
    /// (e.g. `access_denied`).
    case providerError(String)
    /// The callback URL was missing the `code` / `state` parameters.
    case missingCallbackParameters
    /// The system web-auth session could not be presented.
    case presentationFailed(String)
}

extension OAuthSignInError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in was cancelled"
        case .notConfigured(let message):
            return message
        case .providerError(let code):
            return "OAuth provider returned an error: \(code)"
        case .missingCallbackParameters:
            return "OAuth callback was missing code/state parameters"
        case .presentationFailed(let message):
            return message
        }
    }
}

// MARK: - Pure helpers (unit-testable, no UI)

enum GoogleSignInHelpers {
    /// Google iOS OAuth clients require the redirect URI scheme to be the
    /// `REVERSED_CLIENT_ID` from `GoogleService-Info.plist`, with the path
    /// `/oauth2redirect/google` (single colon-slash, no host). This matches
    /// Google's official iOS SDK (GIDSignIn). Both `://oauth/callback` and
    /// `://oauth2redirect` are rejected by Google with `invalid_request`.
    static func redirectUri(forReversedClientId reversedClientId: String) -> String {
        "\(reversedClientId):/oauth2redirect/google"
    }

    /// The URL scheme `ASWebAuthenticationSession` should listen for —
    /// everything before the first `:` of the redirect URI.
    static func callbackScheme(forRedirectUri redirectUri: String) -> String? {
        guard let colon = redirectUri.firstIndex(of: ":"), colon != redirectUri.startIndex else {
            return nil
        }
        return String(redirectUri[redirectUri.startIndex..<colon])
    }

    /// Extract `code` and `state` from the OAuth callback URL. Throws
    /// `.providerError` when the provider sent `error=...` (e.g. the user
    /// denied consent at Google), `.missingCallbackParameters` otherwise.
    static func parseOAuthCallback(url: URL) throws -> (code: String, state: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthSignInError.missingCallbackParameters
        }
        let items = components.queryItems ?? []
        if let providerError = items.first(where: { $0.name == "error" })?.value,
           !providerError.isEmpty {
            throw OAuthSignInError.providerError(providerError)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw OAuthSignInError.missingCallbackParameters
        }
        return (code, state)
    }

    /// Read `REVERSED_CLIENT_ID` from the first existing
    /// `GoogleService-Info.plist` among `candidates`. Returns nil when no
    /// candidate has one — apps that don't use Google OAuth don't ship the
    /// plist and don't need it.
    static func loadReversedGoogleClientId(from candidates: [URL]) -> String? {
        let fm = FileManager.default
        for url in candidates {
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: Any],
                  let reversed = plist["REVERSED_CLIENT_ID"] as? String,
                  !reversed.isEmpty
            else {
                continue
            }
            return reversed
        }
        return nil
    }

    /// Default search locations for `GoogleService-Info.plist`:
    /// 1. The current working directory — covers SwiftPM `swift run` dev
    ///    builds where the plist sits next to the app's config files.
    /// 2. The main bundle — covers Xcode `.app` builds where the plist is
    ///    declared as a bundled resource.
    static func defaultPlistCandidates(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> [URL] {
        var candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("GoogleService-Info.plist")
        ]
        if let bundled = bundle.url(forResource: "GoogleService-Info", withExtension: "plist") {
            candidates.append(bundled)
        }
        return candidates
    }
}

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst) || os(visionOS))

// MARK: - JsBaoClient.signInWithGoogle

extension JsBaoClient {
    /// Native Google sign-in: presents `ASWebAuthenticationSession`, handles
    /// the redirect callback, exchanges the authorization code, and lands the
    /// session — mirroring the JS client's one-call sign-in (#928).
    ///
    /// ```swift
    /// let result = try await client.signInWithGoogle(presentationAnchor: window)
    /// ```
    ///
    /// - Parameters:
    ///   - presentationAnchor: The window to present the auth sheet from.
    ///     When nil, falls back to the key window (iOS: first window of the
    ///     first connected scene; macOS: `NSApplication.keyWindow`).
    ///   - redirectUri: Override the OAuth redirect URI. When nil, derived
    ///     from a bundled `GoogleService-Info.plist`'s `REVERSED_CLIENT_ID`
    ///     as `{reversedClientId}:/oauth2redirect/google`. The URI must be in
    ///     the app's allow-listed `redirectUris`.
    ///   - continueUrl: Optional continue URL threaded through the OAuth
    ///     state bag (parity with the JS `startOAuthFlow(continueUrl:)`).
    ///   - waitlist: Optional waitlist enrollment threaded through the state
    ///     bag (parity with JS `startOAuthFlow(continueUrl, { waitlist })`).
    ///   - inviteToken: Optional invite token threaded through the state bag
    ///     (parity with JS `startOAuthFlow(continueUrl, { inviteToken })`,
    ///     #466) so an invite-gated OAuth signup can complete natively.
    ///   - prefersEphemeralWebBrowserSession: Opt in to an ephemeral browser
    ///     session (no shared cookies; the user always types credentials).
    /// - Returns: `GoogleSignInResult` with the signed-in `userId` and the
    ///   server's `isNewUser` flag.
    /// - Throws: `OAuthSignInError.cancelled` when the user dismisses the
    ///   sheet; `.notConfigured` / `.providerError` /
    ///   `.missingCallbackParameters` / `.presentationFailed` for the other
    ///   flow failures; `HttpError` / `JsBaoError` for server-side failures.
    @MainActor
    public func signInWithGoogle(
        presentationAnchor: ASPresentationAnchor? = nil,
        redirectUri: String? = nil,
        continueUrl: String? = nil,
        waitlist: OAuthWaitlist? = nil,
        inviteToken: String? = nil,
        prefersEphemeralWebBrowserSession: Bool = false
    ) async throws -> GoogleSignInResult {
        // 1. Resolve the redirect URI (explicit > GoogleService-Info.plist).
        let resolvedRedirectUri: String
        if let redirectUri, !redirectUri.isEmpty {
            resolvedRedirectUri = redirectUri
        } else if let reversedClientId = GoogleSignInHelpers.loadReversedGoogleClientId(
            from: GoogleSignInHelpers.defaultPlistCandidates()
        ) {
            resolvedRedirectUri = GoogleSignInHelpers.redirectUri(forReversedClientId: reversedClientId)
        } else {
            throw OAuthSignInError.notConfigured(
                "Google sign-in is not configured: pass redirectUri: explicitly, "
                + "or bundle a GoogleService-Info.plist with a REVERSED_CLIENT_ID."
            )
        }

        guard let callbackScheme = GoogleSignInHelpers.callbackScheme(
            forRedirectUri: resolvedRedirectUri
        ) else {
            throw OAuthSignInError.notConfigured(
                "Redirect URI has no URL scheme: \(resolvedRedirectUri)"
            )
        }

        // 2. Build the authorize URL (GET /oauth-config + client-side URL
        //    construction, same as the JS client).
        let authUrl = try await startOAuthFlow(
            redirectUri: resolvedRedirectUri,
            continueUrl: continueUrl,
            waitlist: waitlist,
            inviteToken: inviteToken
        )

        // 3. Present the system auth sheet and wait for the redirect.
        let presenter = WebAuthenticationPresenter(anchor: presentationAnchor)
        let callbackUrl = try await presenter.authenticate(
            url: authUrl,
            callbackScheme: callbackScheme,
            prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
        )

        // 4. Exchange the code. This applies the session token (cause
        //    "oauth"), emits .authSuccess/.authState, and reconnects the
        //    WebSocket per the JS oauth:callback sequencing.
        let (code, state) = try GoogleSignInHelpers.parseOAuthCallback(url: callbackUrl)
        let response = try await handleOAuthCallback(code: code, state: state)

        return GoogleSignInResult(
            userId: getUserId(),
            isNewUser: response["isNewUser"] as? Bool ?? false
        )
    }
}

// MARK: - ASWebAuthenticationSession bridge

/// Bridges `ASWebAuthenticationSession`'s delegate/completion-handler API to
/// async/throws. Holds a strong reference to the in-flight session (the
/// session is not retained by the system while running) and serves as its
/// presentation context provider.
@MainActor
final class WebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    private var session: ASWebAuthenticationSession?

    init(anchor: ASPresentationAnchor?) {
        self.anchor = anchor
    }

    /// Present the auth session and suspend until the callback redirect (or
    /// failure). User cancellation surfaces as `OAuthSignInError.cancelled` —
    /// never a hang: ASWebAuthenticationSession always invokes its completion
    /// handler exactly once (with `.canceledLogin` on dismiss), and a failed
    /// `start()` resumes with `.presentationFailed`.
    func authenticate(
        url: URL,
        callbackScheme: String,
        prefersEphemeralWebBrowserSession: Bool
    ) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackUrl, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: OAuthSignInError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let callbackUrl {
                    continuation.resume(returning: callbackUrl)
                } else {
                    continuation.resume(throwing: OAuthSignInError.missingCallbackParameters)
                }
            }
            session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                // Per the docs the completion handler is NOT invoked when
                // start() fails, so resuming here cannot double-resume.
                self.session = nil
                continuation.resume(throwing: OAuthSignInError.presentationFailed(
                    "ASWebAuthenticationSession failed to start"
                ))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
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
}

#endif
