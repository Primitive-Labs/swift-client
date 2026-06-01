import Foundation

// MARK: - Request / Response types

/// Structured request for `IntegrationsAPI.call(_:)`. Mirrors the JS
/// client's `IntegrationCallRequest` so a Swift app and a JS app can
/// proxy the same upstream call against the same integration.
public struct IntegrationCallRequest: Sendable {
    public let integrationKey: String
    public let method: String
    public let path: String
    public let query: [String: String]?
    public let headers: [String: String]?
    public let body: Any?

    public init(
        integrationKey: String,
        method: String = "GET",
        path: String = "",
        query: [String: String]? = nil,
        headers: [String: String]? = nil,
        body: Any? = nil
    ) {
        self.integrationKey = integrationKey
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// Structured response from a successful `IntegrationsAPI.call(_:)`.
/// Mirrors the JS `IntegrationCallResponse<T>` shape. The `body` is
/// `Any?` (rather than generic) for Swift ergonomics — callers cast
/// at the call site.
public struct IntegrationCallResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Any?
    public let traceId: String?
    public let durationMs: Double?
    public let errorCode: String?

    public init(
        status: Int,
        headers: [String: String],
        body: Any?,
        traceId: String? = nil,
        durationMs: Double? = nil,
        errorCode: String? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.traceId = traceId
        self.durationMs = durationMs
        self.errorCode = errorCode
    }
}

// MARK: - IntegrationsAPI

public final class IntegrationsAPI: @unchecked Sendable {
    /// The raw-response form of `makeRequest`. Returns the full
    /// `HttpClientResponse` so we can read `status`, `headers`, and
    /// the parsed `data` — the integration proxy contract puts the
    /// upstream status in the response body, not the HTTP status, so
    /// we need both layers to surface a structured response.
    private let makeRawRequest: (String, String, Any?) async throws -> HttpClientResponse

    public init(
        makeRawRequest: @escaping (String, String, Any?) async throws -> HttpClientResponse
    ) {
        self.makeRawRequest = makeRawRequest
    }

    /// Call a third-party integration through the server proxy.
    ///
    /// Mirrors the JS client's `client.integrations.call(request)`:
    /// the request describes how to call the upstream (method, path,
    /// query, headers, body) and the response unwraps the proxy's
    /// envelope into `(status, headers, body, traceId?, durationMs?,
    /// errorCode?)`.
    ///
    /// Throws a typed `JsBaoError` on non-OK responses so callers can
    /// distinguish auth failures from missing integrations from
    /// invalid requests etc. — matching the JS error mapping in
    /// `JsBaoClient.callIntegration`.
    public func call(_ request: IntegrationCallRequest) async throws -> IntegrationCallResponse {
        guard !request.integrationKey.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "integrationKey is required for integrations.call"
            )
        }

        // Build the proxy URL with the integration key URL-encoded so
        // keys containing slashes or special chars route correctly.
        let escapedKey = request.integrationKey
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? request.integrationKey
        let path = "/integrations/\(escapedKey)/proxy"

        // Wire payload mirrors the JS shape exactly. We omit nil-valued
        // fields so the wire bytes match what JS sends when the caller
        // doesn't specify query/headers/body.
        var payload: [String: Any] = [
            "method": request.method,
            "path": request.path,
        ]
        if let query = request.query { payload["query"] = query }
        if let headers = request.headers { payload["headers"] = headers }
        if let body = request.body { payload["body"] = body }

        let raw: HttpClientResponse
        do {
            raw = try await makeRawRequest("POST", path, payload)
        } catch let error as JsBaoError {
            throw error
        } catch {
            // Map low-level transport errors to the same auth/proxy
            // categories the JS side does.
            let message = error.localizedDescription
            let isAuthError = message.lowercased().contains("401")
            throw JsBaoError(
                code: isAuthError ? .accessDenied : .integrationProxyFailed,
                message: isAuthError
                    ? "Authentication required to call integration"
                    : "Integration request failed",
                details: ["cause": message]
            )
        }

        if !raw.ok {
            throw createIntegrationError(raw)
        }

        // Validate the proxy envelope shape before unwrapping.
        guard let data = raw.data as? [String: Any] else {
            throw JsBaoError(
                code: .integrationProxyFailed,
                message: "Integration response malformed"
            )
        }

        // The upstream HTTP status lives in the body, not the proxy's
        // own status. JS rejects non-finite numbers; Swift does the
        // same by requiring an Int (or Double-coercible) value.
        let upstreamStatus: Int
        if let i = data["status"] as? Int {
            upstreamStatus = i
        } else if let d = data["status"] as? Double, d.isFinite {
            upstreamStatus = Int(d)
        } else {
            throw JsBaoError(
                code: .integrationProxyFailed,
                message: "Integration response missing status"
            )
        }

        let headers = normalizeIntegrationHeaders(
            (data["headers"] as? [String: Any]) ?? [:]
        )

        return IntegrationCallResponse(
            status: upstreamStatus,
            headers: headers,
            body: data["body"],
            traceId: data["traceId"] as? String,
            durationMs: (data["durationMs"] as? Double)
                ?? (data["durationMs"] as? Int).map(Double.init),
            errorCode: data["errorCode"] as? String
        )
    }

    /// Coerce a header dict's values to `String`. Mirrors JS's
    /// `normalizeIntegrationHeaders` so a Swift caller and a JS caller
    /// see identically-shaped header strings even when the upstream
    /// proxied non-string header values.
    private func normalizeIntegrationHeaders(_ raw: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in raw {
            if value is NSNull { continue }
            if let s = value as? String {
                result[key] = s
            } else if let n = value as? NSNumber {
                // NSNumber covers both Bool and numeric types in
                // bridged dictionaries — branch on objCType to format
                // bools as "true"/"false" rather than "1"/"0".
                if String(cString: n.objCType) == "c" {
                    result[key] = n.boolValue ? "true" : "false"
                } else {
                    result[key] = "\(n)"
                }
            } else if JSONSerialization.isValidJSONObject(value),
                      let json = try? JSONSerialization.data(withJSONObject: value),
                      let str = String(data: json, encoding: .utf8) {
                result[key] = str
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    /// Map a non-OK proxy response into a typed `JsBaoError`. Mirrors
    /// the JS error categorization so a cross-platform caller sees the
    /// same code for the same upstream condition.
    private func createIntegrationError(_ response: HttpClientResponse) -> JsBaoError {
        let payload = response.data as? [String: Any]
        let upstreamCode = (payload?["errorCode"] as? String)
            ?? (payload?["code"] as? String)
            ?? ((payload?["details"] as? [String: Any])?["code"] as? String)
        let traceId = (payload?["traceId"] as? String)
            ?? ((payload?["details"] as? [String: Any])?["traceId"] as? String)
        let message = (payload?["message"] as? String)
            ?? (payload?["error"] as? String)
            ?? "Integration call failed with HTTP \(response.status)"

        let code: JsBaoErrorCode
        switch (response.status, upstreamCode) {
        case (401, _), (403, _):
            code = .accessDenied
        case (404, _):
            code = .integrationNotFound
        case (_, "INTEGRATION_INACTIVE"), (_, "INTEGRATION_NOT_FOUND"):
            code = .integrationNotFound
        case (409, _), (_, "MISSING_SECRET"):
            code = .integrationSecretMissing
        case (400, _), (413, _), (422, _):
            code = .integrationRequestInvalid
        case (_, "DISALLOWED_METHOD"), (_, "DISALLOWED_PATH"), (_, "REQUEST_BODY_TOO_LARGE"):
            code = .integrationRequestInvalid
        default:
            code = .integrationProxyFailed
        }

        var details: [String: String] = ["status": "\(response.status)"]
        if let traceId = traceId { details["traceId"] = traceId }
        if let upstreamCode = upstreamCode { details["upstreamCode"] = upstreamCode }
        return JsBaoError(code: code, message: message, details: details)
    }

    // MARK: - Catalog (list / get)
    //
    // The JS client's `list()` / `get()` go through the standard JSON
    // path, not the raw-response one used by `call`. We piggy-back on
    // the raw closure (the only one we have) and decode the body
    // ourselves, mapping non-2xx to a `JsBaoError`.

    /// List integrations configured for the current app.
    public func list() async throws -> [[String: Any]] {
        let response = try await makeRawRequest("GET", "/integrations", nil)
        guard let json = decodeJsonBody(response: response) else { return [] }
        if let dict = json as? [String: Any],
           let items = dict["integrations"] as? [[String: Any]] {
            return items
        }
        return json as? [[String: Any]] ?? []
    }

    /// Get a single integration by id or key.
    public func get(integrationIdOrKey: String) async throws -> [String: Any] {
        let escaped = integrationIdOrKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? integrationIdOrKey
        let response = try await makeRawRequest("GET", "/integrations/\(escaped)", nil)
        if let json = decodeJsonBody(response: response) as? [String: Any] {
            return json
        }
        return [:]
    }

    private func decodeJsonBody(response: HttpClientResponse) -> Any? {
        if (200..<300).contains(response.status) {
            if let data = response.data { return data }
            if let text = response.text,
               let raw = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: raw) {
                return json
            }
        }
        return nil
    }
}
