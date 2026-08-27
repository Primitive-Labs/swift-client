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
    /// `openDocument` waited out its `availabilityWait` budget without the
    /// document's sync completing — the server never answered. Mirrors JS
    /// `waitForAvailability`'s `NETWORK_TIMEOUT` (#2667, parity C8).
    case networkTimeout = "NETWORK_TIMEOUT"
    /// `openDocument` needed the network, but the WebSocket is neither up nor
    /// able to come up — no token, or `setShouldConnect(false)` (the state an
    /// auth failure or a logout leaves behind). Mirrors JS
    /// `waitForAvailability`'s `CONNECTION_DISABLED` (#2667, parity C8).
    case connectionDisabled = "CONNECTION_DISABLED"
    /// `openDocument` had no local copy of the document and no way to fetch
    /// one — `waitForLoad: .localIfAvailableElseNetwork` with the document's
    /// sync left to the caller (`enableNetworkSync: false`). Mirrors JS
    /// `waitForAvailability`'s `NO_LOCAL_AND_NO_NETWORK` (#2667, parity C8).
    case noLocalAndNoNetwork = "NO_LOCAL_AND_NO_NETWORK"
    /// `openDocument` asked for the network path (`waitForLoad: .network`)
    /// with `enableNetworkSync: false`, so nothing would ever start the sync
    /// it is waiting for. Mirrors JS `waitForAvailability`'s
    /// `NETWORK_REQUIRES_AUTOSTART` (#2667, parity C8).
    case networkRequiresAutostart = "NETWORK_REQUIRES_AUTOSTART"
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
        // #2652 — the per-resource access-rule surfaces answer with `errorCode`
        // (`PROMPT_ACCESS_DENIED`, `WORKFLOW_ACCESS_DENIED`,
        // `INTEGRATION_ACCESS_DENIED`) rather than `code`, so that spelling is
        // lifted onto `serverCode` too, mirroring the JS client's
        // `makeApiError`. `code` wins when a body carries both.
        let code = dict["code"] as? String
            ?? (dict["details"] as? [String: Any])?["code"] as? String
            ?? dict["errorCode"] as? String
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

// MARK: - WebSocketError

/// Errors thrown by the client's WebSocket connect and send paths. Public
/// because apps catch it; the `WebSocketManager` that raises it is
/// module-internal (#2363), so the error type lives here with the client's
/// other public errors rather than in `Internal/`.
public enum WebSocketError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
    /// A transport-level failure, reduced to a `Sendable` value at the
    /// `URLSession` delegate boundary (#2171). `URLSession` hands the client a
    /// bare `Error`, which is not `Sendable` and so cannot travel on the
    /// manager's ordered delegate-event channel; the message and the
    /// `URLError` code are carried instead.
    ///
    /// `message` is the original error's `localizedDescription`, and
    /// `errorDescription` returns it **verbatim** — apps read it through
    /// `ConnectionErrorEvent.message`, and prefixing it here would change that
    /// text for every transport failure.
    case transportFailure(message: String, code: Int?)
}

extension WebSocketError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "WebSocket is not connected"
        case .connectionFailed(let reason):
            return "WebSocket connection failed: \(reason)"
        case .transportFailure(let message, _):
            return message
        }
    }
}

// MARK: - JsBaoNetworkError

/// A transport or token-refresh failure: the request could not be completed
/// against the server. Parity with the JS client's `JsBaoNetworkError`
/// (`src/client/errors.ts`).
///
/// **This does not mean the request never reached the server.** The client
/// raises it whenever the HTTP layer could not produce a usable response —
/// DNS/TLS/connection failures, timeouts, and (via `AuthController`) any
/// refresh failure other than an HTTP 401/403, which includes 5xx responses
/// and decode failures. Treat it as *retryable*, not as proof of no side
/// effect.
///
/// Before #2367 these surfaced as the raw `URLError` `URLSession` produced, so
/// apps had to catch a Foundation type to handle them. They are now normalized
/// through one internal helper, so `URLError` no longer escapes the client's
/// HTTP paths.
///
/// A cancelled request is **not** reported here: `URLError.cancelled` is
/// normalized to `CancellationError`, matching how the client already reports
/// cancellation elsewhere.
public struct JsBaoNetworkError: Error, Sendable, Equatable {
    /// The underlying failure's `localizedDescription`, verbatim — except on
    /// the refresh path, where a non-`LocalizedError` `HttpError` is spelled
    /// out as `"Token refresh failed: HTTP <status> …"` (see
    /// ``init(refreshFailure:)``).
    public let message: String
    /// The `URLError.Code` raw value when the failure came from `URLSession`,
    /// `nil` otherwise.
    public let urlErrorCode: Int?

    public init(message: String, urlErrorCode: Int? = nil) {
        self.message = message
        self.urlErrorCode = urlErrorCode
    }

    /// Whether the failure was a timeout. Computed from ``urlErrorCode``
    /// rather than stored, so it cannot contradict it.
    public var isTimeout: Bool {
        urlErrorCode == URLError.Code.timedOut.rawValue
    }
}

extension JsBaoNetworkError: LocalizedError {
    /// The underlying message verbatim — the client does not prefix it.
    public var errorDescription: String? { message }
}

extension JsBaoNetworkError {
    /// The client's ONE mapping from a transport `Error` to the message/code
    /// pair every network-failure surface reports. `WebSocketError
    /// .transportFailure` is built from this too, so the WS and HTTP paths
    /// cannot drift apart.
    init(transport error: Error) {
        self.init(
            message: error.localizedDescription,
            urlErrorCode: (error as? URLError)?.errorCode
        )
    }

    /// A failed token refresh, described in the same vocabulary.
    ///
    /// `HttpError` does not conform to `LocalizedError`, so its
    /// `localizedDescription` is Foundation's generic "operation couldn't be
    /// completed" text — useless for a 5xx refresh. Spell the status out
    /// instead; every other failure goes through ``init(transport:)``.
    init(refreshFailure error: Error) {
        if let already = error as? JsBaoNetworkError {
            self = already
        } else if let http = error as? HttpError {
            self.init(
                message: "Token refresh failed: HTTP \(http.status) "
                    + (http.serverMessage ?? http.message)
            )
        } else {
            self.init(transport: error)
        }
    }

    /// Normalize an error raised by a `URLSession` call into the client's own
    /// vocabulary. Errors the client already owns pass through untouched.
    ///
    /// - `URLError.cancelled` becomes `CancellationError`, so a cancelled task
    ///   is reported the same way everywhere in the client.
    /// - Any other `URLError` becomes a `JsBaoNetworkError`.
    /// - Anything else is returned as-is.
    static func normalizing(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled { return CancellationError() }
        return JsBaoNetworkError(transport: urlError)
    }
}

/// The one place the client calls `URLSession`'s async data methods.
///
/// Every HTTP path in the client goes through here so `URLError` is normalized
/// in exactly one place (#2367). Calling `URLSession.data(...)` directly
/// anywhere else re-introduces the raw-`URLError` leak this exists to close —
/// `TransportSpineTests` asserts that it doesn't happen.
enum NetworkSession {
    static func data(
        for request: URLRequest,
        using session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw JsBaoNetworkError.normalizing(error)
        }
    }

    static func data(
        from url: URL,
        using session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(from: url)
        } catch {
            throw JsBaoNetworkError.normalizing(error)
        }
    }
}
