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
    case workflowApplyNotConfirmed = "WORKFLOW_APPLY_NOT_CONFIRMED"
    /// `workflows.waitFor` gave up after `timeoutMs` without the run reaching
    /// a terminal state. Mirrors the JS client's `WORKFLOW_WAIT_TIMEOUT`.
    case workflowWaitTimeout = "WORKFLOW_WAIT_TIMEOUT"
    /// `locks.acquire` reached its `timeoutMs` deadline without winning the
    /// key. Mirrors the JS client's `LockTimeoutError` (`LOCK_TIMEOUT`); the
    /// error's `details` carry `key` and `timeoutMs`.
    case lockTimeout = "LOCK_TIMEOUT"
}

/// Main error type for the JsBao client library
public struct JsBaoError: Error, Sendable {
    public let code: JsBaoErrorCode
    public let message: String
    /// Optional structured diagnostic details. Typed as `[String: JSONValue]?`
    /// to mirror JS's `details?: any` (`src/client/errors.ts`): nested objects,
    /// numbers, and bools are all representable, and because `JSONValue` is
    /// itself `Sendable` the struct's `Sendable` conformance stays real (a raw
    /// `[String: Any]?` would quietly violate it).
    public let details: [String: JSONValue]?

    public init(code: JsBaoErrorCode, message: String? = nil, details: [String: JSONValue]? = nil) {
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

// MARK: - Client-side transport failures

/// `HttpError` is a struct, not an enum, so the transport layer's two
/// non-HTTP failure modes (a required body that arrived empty, and a body
/// that would not decode) are expressed as factory methods rather than new
/// cases. Both carry a **client-side sentinel** in `serverCode`: the server
/// sent no `code`, so the value identifies where the failure came from
/// without pretending it was reported by the server.
public extension HttpError {
    /// `serverCode` on the error thrown when a 2xx response carried no body
    /// but the call site required a value.
    static let emptyBodyCode = "CLIENT_EMPTY_RESPONSE_BODY"
    /// `serverCode` on the error thrown when a 2xx body could not be decoded
    /// into the expected type.
    static let decodingFailedCode = "CLIENT_DECODE_FAILED"

    /// A 2xx response with an empty body where the call site required a
    /// value. `status` is the real HTTP status of the (successful) response —
    /// see `Transport.request`; use `requestOptional` when "nothing" is a
    /// legitimate answer, or `send` for pure side effects.
    static func emptyBody(
        path: String,
        expected: Any.Type,
        status: Int = 200
    ) -> HttpError {
        HttpError(
            status: status,
            message: "Empty response body from \(path) (expected \(expected))",
            body: nil,
            serverCode: emptyBodyCode,
            serverMessage: nil
        )
    }

    /// Stands in for a response body that was withheld because the endpoint
    /// returns credentials — see `isCredentialBearingPath`.
    static let redactedBodyPlaceholder = "<redacted: credential-bearing response body>"

    /// A 2xx body that would not decode into the expected type. Carries the
    /// path and expected type so a decode failure is diagnosable without
    /// re-running the request; the raw body is preserved on `body` — except
    /// on the credential-bearing paths, where it is redacted.
    static func decodingFailure(
        path: String,
        expected: Any.Type,
        status: Int = 200,
        body: String?,
        underlying: Error
    ) -> HttpError {
        HttpError(
            status: status,
            message: "Failed to decode \(expected) from \(path): \(underlying)",
            body: redactedBody(body, path: path),
            serverCode: decodingFailedCode,
            serverMessage: nil
        )
    }

    /// The 2xx bodies of the auth and passkey endpoints carry a live access
    /// token. A decode failure is exactly the error an app forwards to a
    /// crash reporter, and `body` is a `public let` that
    /// `String(describing:)` prints — so on those paths the body is replaced
    /// by a placeholder, keeping only the structured `code`/`error` fields
    /// that make the failure diagnosable.
    static func redactedBody(_ body: String?, path: String) -> String? {
        guard let body = body, isCredentialBearingPath(path) else { return body }
        let parsed = parseBody(body)
        var kept: [String] = [redactedBodyPlaceholder]
        if let code = parsed.code { kept.append("code=\(code)") }
        if let message = parsed.message { kept.append("error=\(message)") }
        return kept.joined(separator: " ")
    }

    /// `true` for the paths whose success bodies contain an access token.
    /// Matched by substring, not prefix: the refresh-proxy paths arrive as
    /// absolute URLs (`https://proxy.example/auth/otp/verify`).
    static func isCredentialBearingPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("/auth/") || lowered.contains("/passkey/")
    }
}

extension HttpError: LocalizedError {
    public var errorDescription: String? {
        if let serverMessage, !serverMessage.isEmpty { return serverMessage }
        return "HTTP \(status): \(message)"
    }
}
