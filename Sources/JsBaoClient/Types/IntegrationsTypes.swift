import Foundation

// MARK: - Integrations: typed request & response models
//
// These mirror the interfaces published by the JS client on
// `JsBaoClient` (`IntegrationCallRequest` / `IntegrationCallResponse<T>`;
// the integrations sub-API is `{ call }`). The two surfaces line up
// field-for-field. Opaque, platform-untouched payloads — the request
// `body`, each `query` value, and the response `body` — are typed as
// `JSONValue` (see JSONValue.swift) so they round-trip losslessly while
// still participating in `Codable`, matching JS's `any`/`Record<string,
// any>` typing.

// MARK: Request

/// Structured request for `IntegrationsAPI.call(_:)`. Mirrors the JS
/// client's `IntegrationCallRequest` so a Swift app and a JS app can
/// proxy the same upstream call against the same integration.
///
/// `method` and `path` are optional and carry **no** client-side default
/// (matching the JS interface, where they are `method?`/`path?` and the
/// server applies any defaults). Omitting them sends no `method`/`path`
/// field, exactly like the JS client — see #958.
public struct IntegrationCallRequest: Encodable, Sendable {
    public let integrationKey: String
    public let method: String?
    public let path: String?
    /// Query parameters. Each value is a `JSONValue` (not just `String`),
    /// mirroring JS's `Record<string, any>` — values may be numbers,
    /// bools, arrays, etc. (#958).
    public let query: [String: JSONValue]?
    public let headers: [String: String]?
    /// Opaque request body, round-tripped verbatim. Mirrors JS's `any`.
    public let body: JSONValue?

    public init(
        integrationKey: String,
        method: String? = nil,
        path: String? = nil,
        query: [String: JSONValue]? = nil,
        headers: [String: String]? = nil,
        body: JSONValue? = nil
    ) {
        self.integrationKey = integrationKey
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

// MARK: Response

/// Structured response from a successful `IntegrationsAPI.call(_:)`.
/// Mirrors the JS `IntegrationCallResponse<T>` shape. The upstream HTTP
/// `status` lives here (the proxy puts it in the body, not the transport
/// status). The `body` is a `JSONValue` — the JS generic `T` defaults to
/// `any`, so callers introspect it via `JSONValue`'s accessors.
public struct IntegrationCallResponse: Decodable, Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    /// Opaque upstream response body. Mirrors JS's generic `body: T`
    /// (default `any`); inspect via `JSONValue` accessors / subscripts.
    public let body: JSONValue?
    public let traceId: String?
    public let durationMs: Double?
    public let errorCode: String?

    public init(
        status: Int,
        headers: [String: String],
        body: JSONValue?,
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
