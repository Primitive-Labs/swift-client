import Foundation

// MARK: - Configuration

/// Configuration for HttpClient
public struct HttpClientConfig {
    public let apiUrl: String
    public let appId: String
    public let getToken: () -> String?
    public let getConnectionId: () -> String?
    public let onTokenRefresh: (String) -> Void
    public let onRefreshOutcome: (RefreshOutcome) -> Void
    public let getGlobalAdminAppId: () -> String
    public let logger: Logger
    public let refreshProxy: RefreshProxyConfig?

    public init(
        apiUrl: String,
        appId: String,
        getToken: @escaping () -> String?,
        getConnectionId: @escaping () -> String?,
        onTokenRefresh: @escaping (String) -> Void,
        onRefreshOutcome: @escaping (RefreshOutcome) -> Void,
        getGlobalAdminAppId: @escaping () -> String,
        logger: Logger,
        refreshProxy: RefreshProxyConfig? = nil
    ) {
        self.apiUrl = apiUrl
        self.appId = appId
        self.getToken = getToken
        self.getConnectionId = getConnectionId
        self.onTokenRefresh = onTokenRefresh
        self.onRefreshOutcome = onRefreshOutcome
        self.getGlobalAdminAppId = getGlobalAdminAppId
        self.logger = logger
        self.refreshProxy = refreshProxy
    }
}

// MARK: - Types

public enum RefreshOutcome: String, Sendable {
    case success
    case invalid
    case network
}

/// Response from raw HTTP request
public struct HttpClientResponse: Sendable {
    public let ok: Bool
    public let status: Int
    public let headers: [String: String]
    public let data: Any?
    public let text: String?

    public init(ok: Bool, status: Int, headers: [String: String], data: Any?, text: String?) {
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
    private let refreshProxyBase: String?
    private let refreshProxyCookieMaxAge: Int?
    private let lock = NSLock()

    public init(config: HttpClientConfig) {
        self.config = config
        self.logger = config.logger.forScope(scope: "http")

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        self.session = URLSession(configuration: sessionConfig)

        self.refreshProxyBase = HttpClient.normalizeProxyBase(config.refreshProxy?.baseUrl)
        if let base = self.refreshProxyBase, base.isEmpty == false {
            if let candidate = config.refreshProxy?.cookieMaxAgeSeconds,
               candidate > 0 {
                self.refreshProxyCookieMaxAge = candidate
            } else {
                self.refreshProxyCookieMaxAge = nil
            }
        } else {
            self.refreshProxyCookieMaxAge = nil
        }
    }

    // MARK: - Public API

    /// Make an HTTP request and return decoded JSON. Throws on non-2xx responses.
    public func request(
        method: String,
        path: String,
        data: Any? = nil,
        options: RequestOptions? = nil
    ) async throws -> Any? {
        let result = try await requestRaw(method: method, path: path, data: data, options: options)
        if !result.ok {
            throw HttpError(
                status: result.status,
                message: "HTTP \(result.status)",
                body: result.text
            )
        }
        return result.data
    }

    /// Make an HTTP request and return the full response without throwing on non-2xx.
    public func requestRaw(
        method: String,
        path: String,
        data: Any? = nil,
        options: RequestOptions? = nil
    ) async throws -> HttpClientResponse {
        await refreshIfExpiring()

        let (responseData, response) = try await fetchWithRefresh(
            method: method,
            path: path,
            data: data,
            options: options
        )

        let httpResponse = response as! HTTPURLResponse
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let text = String(data: responseData, encoding: .utf8)

        var parsed: Any? = text
        if contentType.contains("application/json") {
            if let text = text, !text.isEmpty {
                do {
                    parsed = try JSONSerialization.jsonObject(with: responseData, options: .fragmentsAllowed)
                } catch {
                    parsed = text
                }
            } else {
                parsed = nil
            }
        }

        let statusCode = httpResponse.statusCode
        return HttpClientResponse(
            ok: (200..<300).contains(statusCode),
            status: statusCode,
            headers: serializeHeaders(httpResponse),
            data: parsed,
            text: text
        )
    }

    /// Attempt to refresh the access token. Returns the outcome.
    public func tryRefreshAccessToken() async -> RefreshOutcome {
        do {
            let (url, headers) = buildRefreshRequestConfig()
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            for (key, value) in headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .network
            }

            if httpResponse.statusCode == 401 {
                return .invalid
            }
            if !(200..<300).contains(httpResponse.statusCode) {
                return .network
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["token"] as? String else {
                return .invalid
            }

            config.onTokenRefresh(newToken)
            return .success
        } catch {
            return .network
        }
    }

    // MARK: - JWT Parsing

    /// Parse a JWT token payload and extract the expiration timestamp.
    public func parseJwtPayload(token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        let payloadSegment = String(parts[1])
        guard let payloadData = base64UrlDecode(payloadSegment) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Private: Token Expiry

    private func getTokenExpiry(_ token: String?) -> Double? {
        guard let token = token else { return nil }
        guard let payload = parseJwtPayload(token: token) else { return nil }
        if let exp = payload["exp"] as? Double {
            return exp
        }
        if let exp = payload["exp"] as? Int {
            return Double(exp)
        }
        return nil
    }

    private func refreshIfExpiring() async {
        do {
            guard let token = config.getToken() else { return }
            guard let exp = getTokenExpiry(token) else { return }
            let now = Date().timeIntervalSince1970
            if exp - now < 120 {
                let outcome = await tryRefreshAccessToken()
                config.onRefreshOutcome(outcome)
            }
        } catch {
            // Swallow errors silently, matching JS behavior
        }
    }

    // MARK: - Private: Request Building

    private func buildURLRequest(
        method: String,
        path: String,
        data: Any? = nil,
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
        components.path = "/app/\(config.appId)/api\(purePath)"
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
        let canHaveBody = !["GET", "HEAD"].contains(upperMethod)
        if let data = data, canHaveBody {
            if options?.rawBody == true {
                if let rawData = data as? Data {
                    urlRequest.httpBody = rawData
                } else if let rawString = data as? String {
                    urlRequest.httpBody = rawString.data(using: .utf8)
                }
            } else {
                urlRequest.httpBody = try JSONSerialization.data(
                    withJSONObject: data,
                    options: []
                )
            }
        }

        return urlRequest
    }

    private func fetchWithRefresh(
        method: String,
        path: String,
        data: Any? = nil,
        options: RequestOptions? = nil
    ) async throws -> (Data, URLResponse) {
        var urlRequest = try buildURLRequest(method: method, path: path, data: data, options: options)
        logger.debug("Making \(method) request to \(urlRequest.url?.absoluteString ?? "unknown")")

        var (responseData, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (responseData, response)
        }

        if httpResponse.statusCode == 401 {
            let outcome = await tryRefreshAccessToken()
            config.onRefreshOutcome(outcome)

            switch outcome {
            case .success:
                // Rebuild request with new token
                urlRequest = try buildURLRequest(method: method, path: path, data: data, options: options)
                (responseData, response) = try await session.data(for: urlRequest)
            case .invalid:
                throw HttpError(status: 401, message: "Invalid credentials")
            case .network:
                throw HttpError(status: 401, message: "Refresh deferred due to network failure")
            }
        }

        return (responseData, response)
    }

    // MARK: - Private: Refresh Config

    private func buildRefreshRequestConfig() -> (URL, [String: String]) {
        var headers: [String: String] = [
            "Content-Type": "application/json"
        ]

        if let token = config.getToken() {
            headers["Authorization"] = "Bearer \(token)"
        }

        let url: URL
        if let proxyBase = refreshProxyBase {
            url = resolveProxyUrl(base: proxyBase, path: "/auth/refresh")
            headers["Accept"] = "application/json"
            if let maxAge = refreshProxyCookieMaxAge, maxAge > 0 {
                headers["X-Refresh-Cookie-Max-Age"] = String(maxAge)
            }
            headers["X-App-Id"] = config.appId
        } else {
            var components = URLComponents(string: config.apiUrl)!
            components.path = "/app/\(config.appId)/api/auth/refresh"
            url = components.url!
        }

        logger.debug("buildRefreshRequestConfig url=\(url.absoluteString)")
        return (url, headers)
    }

    private func resolveProxyUrl(base: String, path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let normalizedBase = base.hasSuffix("/") ? base : "\(base)/"
        return URL(string: normalizedPath, relativeTo: URL(string: normalizedBase)!)!.absoluteURL
    }

    private static func normalizeProxyBase(_ baseUrl: String?) -> String? {
        guard let baseUrl = baseUrl, !baseUrl.isEmpty else { return nil }
        guard var components = URLComponents(string: baseUrl) else { return nil }
        components.fragment = nil
        components.query = nil
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url?.absoluteString
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

    private func base64UrlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
