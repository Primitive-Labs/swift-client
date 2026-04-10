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

/// Auth error codes
public enum AuthCode: String, Sendable {
    case tokenExpired = "TOKEN_EXPIRED"
    case tokenInvalid = "TOKEN_INVALID"
    case refreshFailed = "REFRESH_FAILED"
    case networkError = "NETWORK_ERROR"
    case unauthorized = "UNAUTHORIZED"
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

    public init(status: Int, message: String, body: String? = nil) {
        self.status = status
        self.message = message
        self.body = body
    }
}

extension HttpError: LocalizedError {
    public var errorDescription: String? { "HTTP \(status): \(message)" }
}
