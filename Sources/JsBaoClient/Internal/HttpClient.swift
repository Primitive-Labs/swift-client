import Foundation

// MARK: - Configuration

/// Configuration for HttpClient
public struct HttpClientConfig {
    public let apiUrl: String
    public let appId: String
    public let getToken: () -> String?
    public let getConnectionId: () -> String?
    public let getGlobalAdminAppId: () -> String
    // Internal: `Logger` is module-internal (#2363).
    let logger: Logger

    /// Single-flight token refresh. HttpClient calls this on a 401 (and when
    /// the current access token is within the expiry window) instead of
    /// running its own refresh. It is wired to
    /// `AuthController.refreshAccessToken`, which coalesces a burst of
    /// concurrent callers into exactly one `POST /auth/refresh` and applies
    /// the logout race guard. Returns the refresh outcome.
    public let refreshAccessToken: () async -> RefreshOutcome

    /// Optional `URLSession` configuration override. `nil` uses the default
    /// configuration. Tests inject a configuration whose `protocolClasses`
    /// stub the network so the 401 / refresh path can be exercised offline
    /// without a live server.
    public let sessionConfiguration: URLSessionConfiguration?

    // Internal: takes the module-internal `Logger` (#2363).
    init(
        apiUrl: String,
        appId: String,
        getToken: @escaping () -> String?,
        getConnectionId: @escaping () -> String?,
        getGlobalAdminAppId: @escaping () -> String,
        logger: Logger,
        refreshAccessToken: @escaping () async -> RefreshOutcome,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.apiUrl = apiUrl
        self.appId = appId
        self.getToken = getToken
        self.getConnectionId = getConnectionId
        self.getGlobalAdminAppId = getGlobalAdminAppId
        self.logger = logger
        self.refreshAccessToken = refreshAccessToken
        self.sessionConfiguration = sessionConfiguration
    }
}

// MARK: - Types

public enum RefreshOutcome: String, Sendable {
    case success
    case invalid
    case network
}

/// Response from raw HTTP request.
///
/// `data` holds the parsed JSON body as a `Sendable` `JSONValue?` (an
/// object body decodes to `.object`, an array to `.array`, and so on; a
/// non-JSON body is carried on `text`). It was previously `Any?` — the
/// parsed `JSONSerialization` graph — which made the struct only
/// nominally `Sendable`. Consumers that need the loosely-typed Foundation
/// graph can bridge back with `JSONCoding.jsonObject(from:)`.
public struct HttpClientResponse: Sendable {
    public let ok: Bool
    public let status: Int
    public let headers: [String: String]
    public let data: JSONValue?
    public let text: String?

    public init(ok: Bool, status: Int, headers: [String: String], data: JSONValue?, text: String?) {
        self.ok = ok
        self.status = status
        self.headers = headers
        self.data = data
        self.text = text
    }
}

/// Options for individual HTTP requests
public struct RequestOptions: Sendable {
    public var rawBody: Bool
    public var customHeaders: [String: String]
    public var timeout: TimeInterval?

    public init(
        rawBody: Bool = false,
        customHeaders: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.rawBody = rawBody
        self.customHeaders = customHeaders
        self.timeout = timeout
    }
}

// MARK: - HttpClient

public final class HttpClient: @unchecked Sendable {
    private let config: HttpClientConfig
    private let logger: Logger
    private let session: URLSession

    public init(config: HttpClientConfig) {
        self.config = config
        self.logger = config.logger.forScope(scope: "http")

        let sessionConfig = config.sessionConfiguration ?? URLSessionConfiguration.default
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Public API

    /// Make an HTTP request and return decoded JSON. Throws on non-2xx responses.
    ///
    /// The deprecated `Any`-graph surface. It now delegates to the same
    /// `executeRaw` spine the typed `Transport` helpers use, so there is one
    /// response-classification policy in the client rather than two — the
    /// classification itself lives on `TransportResponse.legacyParsedJSON`.
    public func request(
        method: String,
        path: String,
        data: Any? = nil,
        options: RequestOptions? = nil
    ) async throws -> Any? {
        let result = try await executeRaw(
            method: method,
            path: path,
            body: try HttpClient.encodeLegacyBody(data, method: method, options: options),
            options: options
        )
        if !result.ok {
            // #850 — parse the structured `{code, error/message}` body
            // so callers see "This app is invite-only..." instead of
            // "HTTP 403", and can switch on `serverCode` /
            // `authCode` without re-parsing.
            let parsed = HttpError.parseBody(result.text)
            throw HttpError(
                status: result.status,
                message: "HTTP \(result.status)",
                body: result.text,
                serverCode: parsed.code,
                serverMessage: parsed.message
            )
        }
        // Hand back the raw `JSONSerialization` graph unchanged — typed
        // decoders downstream cast it with `as? [String: Any]` etc.
        return result.legacyParsedJSON
    }

    /// Make an HTTP request and return the full response without throwing on non-2xx.
    public func requestRaw(
        method: String,
        path: String,
        data: Any? = nil,
        options: RequestOptions? = nil
    ) async throws -> HttpClientResponse {
        try await executeRaw(
            method: method,
            path: path,
            body: try HttpClient.encodeLegacyBody(data, method: method, options: options),
            options: options
        ).toHttpClientResponse()
    }

    /// Perform one round trip and return the **raw** response bytes with the
    /// status and headers. Does not throw on a non-2xx status.
    ///
    /// This is the client's single request spine: `Transport.execute`, the
    /// deprecated `request`/`requestRaw`, and the raw blob path all funnel
    /// through it. It takes the method as a `String` (rather than
    /// `HTTPMethod`) so legacy callers passing an arbitrary verb keep working.
    func executeRaw(
        method: String,
        path: String,
        body: Data?,
        options: RequestOptions?
    ) async throws -> TransportResponse {
        // The direct token-refresh request must NOT run the refresh
        // interceptor: pre-refreshing before it (or refreshing again on its
        // 401) would re-enter AuthController's single-flight refresh while its
        // Task is still running, and the Task would await itself — a deadlock.
        // A 401 from `/auth/refresh` instead surfaces as an HttpError(401),
        // which AuthController classifies as `.invalid`.
        let skipRefresh = HttpClient.isRefreshRequest(path: path)

        if !skipRefresh {
            await refreshIfExpiring()
        }

        let (responseData, response) = try await fetchWithRefresh(
            method: method,
            path: path,
            body: body,
            options: options,
            skipRefresh: skipRefresh
        )

        let httpResponse = response as! HTTPURLResponse
        return TransportResponse(
            status: httpResponse.statusCode,
            headers: serializeHeaders(httpResponse),
            // The untouched `URLSession` bytes — never reconstructed from
            // decoded text, so binary payloads survive byte-for-byte.
            body: responseData
        )
    }

    /// Encode the deprecated `Any` body argument into wire bytes using the
    /// exact rules `buildURLRequest` applied inline before: `rawBody` takes
    /// `Data`/`String` verbatim, everything else goes through
    /// `JSONSerialization`, and methods that cannot carry a body encode to
    /// `nil` (so a fragment body on a GET still never throws).
    static func encodeLegacyBody(
        _ data: Any?,
        method: String,
        options: RequestOptions?
    ) throws -> Data? {
        guard let data = data, canHaveBody(method: method) else { return nil }
        if options?.rawBody == true {
            if let rawData = data as? Data { return rawData }
            if let rawString = data as? String { return rawString.data(using: .utf8) }
            return nil
        }
        return try JSONSerialization.data(withJSONObject: data, options: [])
    }

    private static func canHaveBody(method: String) -> Bool {
        !["GET", "HEAD"].contains(method.uppercased())
    }

    /// The direct token-refresh endpoint. A request to this path skips the
    /// refresh interceptor (see `fetchWithRefresh`): it IS the refresh, so
    /// pre-refreshing or refreshing again on its 401 would deadlock against
    /// `AuthController`'s in-flight single-flight Task.
    private static func isRefreshRequest(path: String) -> Bool {
        let purePath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return purePath == "/auth/refresh"
    }

    // MARK: - Private: Token Expiry

    /// Proactively refresh when the current access token is within 120s of
    /// expiry. Delegates to `AuthController`'s single-flight refresh via
    /// `config.refreshAccessToken` — token parsing and the refresh round trip
    /// both live in `AuthController` now, so HttpClient no longer keeps its own
    /// JWT parser or refresh implementation.
    private func refreshIfExpiring() async {
        guard let token = config.getToken() else { return }
        guard AuthController.isTokenExpiring(token: token) else { return }
        _ = await config.refreshAccessToken()
    }

    // MARK: - Private: Percent-encoding validation

    /// Characters an already-percent-encoded path may contain: everything
    /// `.urlPathAllowed` permits, plus `%` — the escape introducer, which
    /// `.urlPathAllowed` itself excludes.
    private static let percentEncodedPathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.insert(charactersIn: "%")
        return set
    }()

    /// Same idea for the query half, against `.urlQueryAllowed`.
    private static let percentEncodedQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.insert(charactersIn: "%")
        return set
    }()

    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    /// Check that `value` is a well-formed percent-encoded URL component
    /// before it reaches `URLComponents`, whose `.percentEncoded*` setters
    /// trap on invalid input rather than failing.
    ///
    /// Two things make a component invalid: a character outside `allowed`
    /// (the caller interpolated a raw value — a space, a non-ASCII
    /// character, `#`, …), and a `%` that doesn't introduce a two-hex-digit
    /// escape (`100%zz`, a trailing `%`).
    ///
    /// This is a guard, not an escaper: escaping here would double-encode the
    /// segments every sub-API already escapes, which is exactly the bug #1601
    /// fixed. Callers pre-encode their path parameters; this only makes a
    /// caller that forgot get a catchable `HttpError` instead of a crash.
    static func validatePercentEncoded(
        _ value: String,
        allowed: CharacterSet,
        component: String,
        fullPath: String
    ) throws {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard allowed.contains(scalar) else {
                throw HttpError(
                    status: 0,
                    message: "Invalid \(component) for path: \(fullPath) — "
                        + "character \"\(scalar)\" must be percent-encoded. "
                        + "Percent-encode path parameters before passing them to the client."
                )
            }
            if scalar == "%" {
                let escape = scalars[(index + 1)...].prefix(2)
                guard escape.count == 2, escape.allSatisfy({ HttpClient.hexDigits.contains($0) }) else {
                    throw HttpError(
                        status: 0,
                        message: "Invalid \(component) for path: \(fullPath) — "
                            + "\"%\" must introduce a two-digit hex escape (write \"%25\" for a literal percent)."
                    )
                }
                index += 3
            } else {
                index += 1
            }
        }
    }

    // MARK: - Private: Request Building

    // Internal (not private) so URL-construction can be unit-tested directly
    // — the `.percentEncodedPath` handling below (path parameters that contain
    // reserved characters) is otherwise only reachable through the network.
    func buildURLRequest(
        method: String,
        path: String,
        data: Any? = nil,
        options: RequestOptions? = nil
    ) throws -> URLRequest {
        try buildURLRequest(
            method: method,
            path: path,
            body: try HttpClient.encodeLegacyBody(data, method: method, options: options),
            options: options
        )
    }

    /// Build the request from already-encoded body bytes. The `Any` overload
    /// above encodes first and calls through here, so URL construction exists
    /// in one place for both the legacy and the typed path.
    func buildURLRequest(
        method: String,
        path: String,
        body: Data?,
        options: RequestOptions? = nil
    ) throws -> URLRequest {
        // Split path into pure path and query string
        let qIndex = path.firstIndex(of: "?")
        let purePath: String
        let query: String?
        if let qIndex = qIndex {
            purePath = String(path[path.startIndex..<qIndex])
            query = String(path[path.index(after: qIndex)...])
        } else {
            purePath = path
            query = nil
        }

        guard var components = URLComponents(string: config.apiUrl) else {
            throw HttpError(status: 0, message: "Invalid API URL: \(config.apiUrl)")
        }
        // Use `.percentEncodedPath` so a caller's pre-encoded path segment
        // passes through verbatim — mirroring the `.percentEncodedQuery`
        // handling below. The `.path` setter treats its input as *not*
        // percent-encoded and re-encodes it, so a segment a sub-API already
        // escaped with `.addingPercentEncoding(withAllowedCharacters:
        // .urlPathAllowed)` gets double-encoded: an FCM push token containing
        // `:` goes `:` → `%3A` (the sub-API) → `%253A` (the `.path` setter),
        // the server decodes once back to the literal `%3A` (never `:`), and
        // the lookup silently fails to match the stored token — leaving a
        // stale token registered after logout (observed on
        // `DELETE /me/push-tokens/{token}`). Every sub-API already passes a
        // URL-safe path segment (a ULID, or a value escaped with
        // `.urlPathAllowed`), so verbatim pass-through is the correct behavior
        // here — same contract as the query side.
        //
        // Because the setter passes its input through verbatim, it also
        // *traps* (Foundation `fatalError`) when the string isn't a valid
        // percent-encoded path — a caller that interpolated a raw value would
        // kill the app's process instead of getting a catchable error. Check
        // first and throw `HttpError`, matching the rest of this method (#2077).
        let assembledPath = "/app/\(config.appId)/api\(purePath)"
        try HttpClient.validatePercentEncoded(
            assembledPath,
            allowed: HttpClient.percentEncodedPathAllowed,
            component: "path",
            fullPath: path
        )
        components.percentEncodedPath = assembledPath
        if let query = query {
            // Use `.percentEncodedQuery` so the caller's pre-encoded
            // query string passes through verbatim. The `.query` setter
            // treats input as *not* percent-encoded and re-encodes —
            // which turns a caller's `%2B` into `%252B` on the wire,
            // the server decodes once back to the literal string `%2B`
            // (never to `+`), and lookups of values containing a
            // percent-escaped reserved char silently fail to match.
            // Observed concretely on `/users/lookup?email=a%2Bb@…` —
            // server saw `a%2Bb@…` instead of `a+b@…`, returned
            // `{exists: false}` for a user that was clearly a member.
            // Callers are expected to pass a properly percent-encoded
            // query string (all SharingService callers already do).
            //
            // `.percentEncodedQuery` traps on an invalid character for the
            // same reason `.percentEncodedPath` does, so it gets the same
            // guard (#2077).
            try HttpClient.validatePercentEncoded(
                query,
                allowed: HttpClient.percentEncodedQueryAllowed,
                component: "query",
                fullPath: path
            )
            components.percentEncodedQuery = query
        }

        guard let url = components.url else {
            throw HttpError(status: 0, message: "Failed to build URL for path: \(path)")
        }

        var urlRequest = URLRequest(url: url)
        let upperMethod = method.uppercased()
        urlRequest.httpMethod = upperMethod

        // Set default headers
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.getToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue(config.getGlobalAdminAppId(), forHTTPHeaderField: "X-Global-Admin-App-Id")

        if let connId = config.getConnectionId(), !connId.isEmpty {
            urlRequest.setValue(connId, forHTTPHeaderField: "X-JB-Connection-Id")
        }

        // Apply custom headers (can override defaults)
        if let customHeaders = options?.customHeaders {
            for (key, value) in customHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Set timeout
        if let timeout = options?.timeout {
            urlRequest.timeoutInterval = timeout
        }

        // Set body for methods that support it
        if let body = body, !["GET", "HEAD"].contains(upperMethod) {
            urlRequest.httpBody = body
        }

        return urlRequest
    }

    private func fetchWithRefresh(
        method: String,
        path: String,
        body: Data? = nil,
        options: RequestOptions? = nil,
        skipRefresh: Bool
    ) async throws -> (Data, URLResponse) {
        var urlRequest = try buildURLRequest(method: method, path: path, body: body, options: options)
        logger.debug("Making \(method) request to \(urlRequest.url?.absoluteString ?? "unknown")")

        var (responseData, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (responseData, response)
        }

        if httpResponse.statusCode == 401 && !skipRefresh {
            // Delegate to AuthController's single-flight refresh: a burst of
            // concurrent 401s coalesces into one POST /auth/refresh, and the
            // logout race guard applies. Returns the shared outcome.
            let outcome = await config.refreshAccessToken()

            switch outcome {
            case .success:
                // Rebuild request with the refreshed token
                urlRequest = try buildURLRequest(method: method, path: path, body: body, options: options)
                (responseData, response) = try await session.data(for: urlRequest)
            case .invalid:
                throw HttpError(status: 401, message: "Invalid credentials")
            case .network:
                throw HttpError(status: 401, message: "Refresh deferred due to network failure")
            }
        }

        return (responseData, response)
    }

    // MARK: - Private: Helpers

    private func serializeHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let keyStr = key as? String, let valStr = value as? String {
                result[keyStr] = valStr
            }
        }
        return result
    }
}

// MARK: - Transport conformance

/// The production `Transport`. It satisfies the protocol's single requirement
/// by forwarding to the same `executeRaw` spine the deprecated `Any` surface
/// uses, so the URL construction, `percentEncodedPath`/`percentEncodedQuery`
/// pass-through, token/refresh, 401-retry, and refresh-proxy behavior are
/// identical on the typed path — none of it is reimplemented.
extension HttpClient: Transport {
    public func execute(
        method: HTTPMethod,
        path: String,
        body: Data?,
        options: RequestOptions?
    ) async throws -> TransportResponse {
        try await executeRaw(method: method.rawValue, path: path, body: body, options: options)
    }
}
