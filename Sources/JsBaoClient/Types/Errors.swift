import Foundation

/// Error codes matching the JS client's JsBaoErrorCode
public enum JsBaoErrorCode: String, Sendable {
    case offline = "OFFLINE"
    case documentUnavailableOffline = "DOCUMENT_UNAVAILABLE_OFFLINE"
    case localOnlyUnsupportedOption = "LOCAL_ONLY_UNSUPPORTED_OPTION"
    case pendingCreate = "PENDING_CREATE"
    case accessDenied = "ACCESS_DENIED"
    case notFound = "NOT_FOUND"
    case aliasInvalid = "ALIAS_INVALID"
    case invalidArgument = "INVALID_ARGUMENT"
    case aliasUserRequired = "ALIAS_USER_REQUIRED"
    case aliasNotFound = "ALIAS_NOT_FOUND"
    case listTimeout = "LIST_TIMEOUT"
    case listUnavailableOffline = "LIST_UNAVAILABLE_OFFLINE"
    case unavailable = "UNAVAILABLE"
    case websocketNotConnected = "WEBSOCKET_NOT_CONNECTED"
    case geminiError = "GEMINI_ERROR"
    case integrationNotFound = "INTEGRATION_NOT_FOUND"
    case integrationSecretMissing = "INTEGRATION_SECRET_MISSING"
    case integrationRequestInvalid = "INTEGRATION_REQUEST_INVALID"
    case integrationProxyFailed = "INTEGRATION_PROXY_FAILED"
}

/// Main error type for the JsBao client library
public struct JsBaoError: Error, Sendable {
    public let code: JsBaoErrorCode
    public let message: String
    /// Optional structured diagnostic details. Typed as `[String: String]?`
    /// rather than `[String: Any]?` so the struct's `Sendable` conformance is
    /// real (not just nominally declared) — the previous `Any` value was
    /// quietly violating it.
    public let details: [String: String]?

    public init(code: JsBaoErrorCode, message: String? = nil, details: [String: String]? = nil) {
        self.code = code
        self.message = message ?? code.rawValue
        self.details = details
    }
}

extension JsBaoError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Check if an error is a JsBaoError
public func isJsBaoError(_ error: Error) -> Bool {
    error is JsBaoError
}

/// Auth error codes. The first block is client-side (token lifecycle
/// inside the SDK); the second block mirrors js-bao's `AUTH_CODES`
/// (see `authController.ts`) — server-returned codes that surface
/// in the JSON error body so apps can switch on them
/// (#850 / issue #466).
public enum AuthCode: String, Sendable {
    // Client-side (SDK-generated)
    case tokenExpired = "TOKEN_EXPIRED"
    case tokenInvalid = "TOKEN_INVALID"
    case refreshFailed = "REFRESH_FAILED"
    case networkError = "NETWORK_ERROR"
    case unauthorized = "UNAUTHORIZED"
    // Server-returned (parsed from response body)
    case addedToWaitlist = "ADDED_TO_WAITLIST"
    case invitationRequired = "INVITATION_REQUIRED"
    case domainNotAllowed = "DOMAIN_NOT_ALLOWED"
    case invalidToken = "INVALID_TOKEN"
    case passkeyNotEnabled = "PASSKEY_NOT_ENABLED"
    case magicLinkNotEnabled = "MAGIC_LINK_NOT_ENABLED"
    case waitlistEntryUpdated = "WAITLIST_ENTRY_UPDATED"
    case inviteTokenInvalid = "INVITE_TOKEN_INVALID"
    case inviteTokenExpired = "INVITE_TOKEN_EXPIRED"
    case inviteAlreadyAccepted = "INVITE_ALREADY_ACCEPTED"
    case memberInvitationsDisabled = "MEMBER_INVITATIONS_DISABLED"
}

/// Authentication error
public struct AuthError: Error, Sendable {
    public let code: AuthCode?
    public let message: String

    public init(code: AuthCode? = nil, message: String) {
        self.code = code
        self.message = message
    }
}

extension AuthError: LocalizedError {
    public var errorDescription: String? { message }
}

/// HTTP response error
public struct HttpError: Error, Sendable {
    public let status: Int
    public let message: String
    public let body: String?
    /// Machine-readable error code parsed from the JSON body's `"code"`
    /// field (e.g. `"INVITATION_REQUIRED"`). Mirrors js-bao's
    /// `AuthError.code`. Use `authCode` to get a typed `AuthCode` when
    /// the value matches a known case.
    public let serverCode: String?
    /// Human-readable message parsed from the body's `"error"`,
    /// `"message"`, or nested `"details.error"` field. Falls back to
    /// the generic `"HTTP <status>"` when the body isn't structured.
    public let serverMessage: String?

    public init(
        status: Int,
        message: String,
        body: String? = nil,
        serverCode: String? = nil,
        serverMessage: String? = nil
    ) {
        self.status = status
        self.message = message
        self.body = body
        self.serverCode = serverCode
        self.serverMessage = serverMessage
    }

    /// Typed view of `serverCode` when it matches a known `AuthCode`
    /// case. `nil` for codes the SDK doesn't know about yet — fall back
    /// to `serverCode` for raw-string comparison.
    public var authCode: AuthCode? {
        guard let code = serverCode else { return nil }
        return AuthCode(rawValue: code)
    }

    /// Parse a JSON error body into `(serverCode, serverMessage)`.
    /// Public because callers building errors outside `HttpClient`
    /// (rare — admin proxies, raw refresh path) need the same parser.
    public static func parseBody(_ body: String?) -> (code: String?, message: String?) {
        guard
            let body, !body.isEmpty,
            let data = body.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
            let dict = parsed as? [String: Any]
        else { return (nil, nil) }
        let code = dict["code"] as? String
            ?? (dict["details"] as? [String: Any])?["code"] as? String
        let message = dict["error"] as? String
            ?? dict["message"] as? String
            ?? (dict["details"] as? [String: Any])?["error"] as? String
        return (code, message)
    }
}

extension HttpError: LocalizedError {
    public var errorDescription: String? {
        if let serverMessage, !serverMessage.isEmpty { return serverMessage }
        return "HTTP \(status): \(message)"
    }
}
