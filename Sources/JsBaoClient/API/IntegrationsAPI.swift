import Foundation

// The typed `IntegrationCallRequest` / `IntegrationCallResponse` models
// live in `Types/IntegrationsTypes.swift`.

// MARK: - IntegrationsAPI

public final class IntegrationsAPI: @unchecked Sendable {
    /// Calls go through `Transport.requestRaw`, which returns the full
    /// `HttpClientResponse` without throwing on a non-2xx status — the
    /// integration proxy contract puts the upstream status in the response
    /// body, not the HTTP status, so both layers are needed to surface a
    /// structured response.
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Deprecated: construct with a `Transport` instead. The legacy closure is
    /// wrapped in an adapter so existing call sites keep working for one major
    /// cycle.
    @available(*, deprecated, message: "Use init(transport:) — the untyped makeRawRequest closure is removed in the next major release.")
    public convenience init(
        makeRawRequest: @escaping (String, String, Any?) async throws -> HttpClientResponse
    ) {
        self.init(transport: ClosureTransport(responseRequest: makeRawRequest))
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
        let escapedKey = URLEncoding.encodeComponent(request.integrationKey)
        let path = "/integrations/\(escapedKey)/proxy"

        // Wire payload mirrors the JS shape exactly. JS builds
        // `{ method, path, query, headers, body }` straight off the
        // request and lets `JSON.stringify` drop the `undefined` fields —
        // it applies NO `method`/`path` defaults (#958). The typed payload
        // below does the same: a `nil` field is omitted by `JSONEncoder`,
        // and `JSONValue` carries the opaque query/body losslessly.
        let payload = IntegrationProxyRequest(
            method: request.method,
            path: request.path,
            query: request.query,
            headers: request.headers,
            body: request.body
        )

        let raw: HttpClientResponse
        do {
            raw = try await transport.requestRaw(method: .post, path: path, body: payload)
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
                details: ["cause": .string(message)]
            )
        }

        if !raw.ok {
            throw createIntegrationError(raw)
        }

        // Validate the proxy envelope shape before unwrapping. `raw.data` is
        // a `Sendable` `JSONValue?`, walked directly — no `Any` graph.
        guard let data = raw.data?.objectValue else {
            throw JsBaoError(
                code: .integrationProxyFailed,
                message: "Integration response malformed"
            )
        }

        // The upstream HTTP status lives in the body, not the proxy's
        // own status. JS rejects non-finite numbers; so does this.
        // `Int(_: Double)` traps on ±infinity, NaN, and anything past
        // `Int.max`, so the range check is part of the guard rather than a
        // separate conversion the parser could crash on (#2056).
        guard let statusNumber = data["status"]?.numberValue, statusNumber.isFinite,
              let upstreamStatus = Int(exactly: statusNumber.rounded(.towardZero)) else {
            throw JsBaoError(
                code: .integrationProxyFailed,
                // Kept verbatim from JS (`src/client/JsBaoClient.ts`) even
                // though a present-but-out-of-range status also lands here:
                // JS rejects non-finite statuses with this same message, and
                // diverging the text would break error-message parity between
                // the clients.
                message: "Integration response missing status"
            )
        }

        let headers = normalizeIntegrationHeaders(data["headers"]?.objectValue ?? [:])

        // The opaque upstream body is already a typed `JSONValue`. A missing
        // key yields `nil`; `null` is `.null`.
        let body = data["body"]

        return IntegrationCallResponse(
            status: upstreamStatus,
            headers: headers,
            body: body,
            traceId: data["traceId"]?.stringValue,
            durationMs: data["durationMs"]?.numberValue,
            errorCode: data["errorCode"]?.stringValue
        )
    }

    /// Coerce a header dict's values to `String`. Mirrors JS's
    /// `normalizeIntegrationHeaders` so a Swift caller and a JS caller
    /// see identically-shaped header strings even when the upstream
    /// proxied non-string header values.
    private func normalizeIntegrationHeaders(_ raw: [String: JSONValue]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case .null:
                continue
            case let .string(s):
                result[key] = s
            case let .bool(b):
                result[key] = b ? "true" : "false"
            case let .number(n):
                result[key] = Self.headerNumberString(n)
            case .object, .array:
                if let json = try? JSONCoding.encodeData(value),
                   let str = String(data: json, encoding: .utf8) {
                    result[key] = str
                } else {
                    result[key] = String(describing: value)
                }
            }
        }
        return result
    }

    /// JSON has one number type, so an integral header value must still print
    /// as `200`, not `200.0` — matching JS's `String(200)` and the previous
    /// `NSNumber` formatting.
    private static func headerNumberString(_ n: Double) -> String {
        guard n.isFinite else { return "\(n)" }
        if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
            return String(Int64(n))
        }
        return "\(n)"
    }

    /// Map a non-OK proxy response into a typed `JsBaoError`. Mirrors
    /// the JS error categorization so a cross-platform caller sees the
    /// same code for the same upstream condition.
    private func createIntegrationError(_ response: HttpClientResponse) -> JsBaoError {
        let payload = response.data?.objectValue
        let payloadDetails = payload?["details"]?.objectValue
        let upstreamCode = payload?["errorCode"]?.stringValue
            ?? payload?["code"]?.stringValue
            ?? payloadDetails?["code"]?.stringValue
        let traceId = payload?["traceId"]?.stringValue
            ?? payloadDetails?["traceId"]?.stringValue
        let message = payload?["message"]?.stringValue
            ?? payload?["error"]?.stringValue
            ?? "Integration call failed with HTTP \(response.status)"

        let code: JsBaoErrorCode
        switch (response.status, upstreamCode) {
        case (401, _), (403, _):
            code = .accessDenied
        case (404, _):
            code = .integrationNotFound
        case (_, "INTEGRATION_INACTIVE"), (_, "INTEGRATION_NOT_FOUND"):
            code = .integrationNotFound
        // Retired in #2257: current servers emit neither a 409 nor
        // `MISSING_SECRET` on the integration path. Kept for older servers.
        case (409, _), (_, "MISSING_SECRET"):
            code = .integrationSecretMissing
        case (400, _), (413, _), (422, _):
            code = .integrationRequestInvalid
        case (_, "DISALLOWED_METHOD"), (_, "DISALLOWED_PATH"), (_, "REQUEST_BODY_TOO_LARGE"):
            code = .integrationRequestInvalid
        default:
            code = .integrationProxyFailed
        }

        var details: [String: JSONValue] = ["status": .number(Double(response.status))]
        if let traceId = traceId { details["traceId"] = .string(traceId) }
        if let upstreamCode = upstreamCode { details["upstreamCode"] = .string(upstreamCode) }
        return JsBaoError(code: code, message: message, details: details)
    }
}

// MARK: - Wire shim

/// The proxy request envelope. `nil` fields are omitted by `JSONEncoder`,
/// matching JS's `JSON.stringify` dropping `undefined` (#958) — no `method`
/// or `path` default is applied.
private struct IntegrationProxyRequest: Encodable, Sendable {
    let method: String?
    let path: String?
    let query: [String: JSONValue]?
    let headers: [String: String]?
    let body: JSONValue?
}
