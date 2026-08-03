import Foundation

// MARK: - HTTPMethod

/// The HTTP verbs the client speaks. Replaces the bare `String` method
/// argument of the legacy `makeRequest(_:_:_:)` closure.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    /// Verbs that cannot carry a request body. Matches
    /// `HttpClient.canHaveBody`, so the typed spine and the deprecated
    /// `Any` spine drop bodies on exactly the same verbs.
    public var allowsBody: Bool { self != .get && self != .head }
}

// MARK: - TransportResponse

/// The raw result of one HTTP round trip: the **untouched** response bytes
/// plus status and headers.
///
/// `body` is the exact `URLSession` payload — it is never reconstructed from
/// decoded text, so binary payloads (blob downloads) survive byte-for-byte.
public struct TransportResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `true` for 2xx.
    public var ok: Bool { (200..<300).contains(status) }

    /// Case-insensitive header lookup (`HTTPURLResponse` canonicalizes header
    /// names inconsistently across platforms).
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        for (key, value) in headers where key.lowercased() == lowered { return value }
        return nil
    }

    /// UTF-8 view of the body. `nil` when the bytes are not valid UTF-8.
    public var text: String? { String(data: body, encoding: .utf8) }
}

// MARK: - Transport

/// The client's HTTP injection seam.
///
/// It has exactly **one** requirement — `execute` — which returns raw bytes
/// and does *not* throw on a non-2xx status. Every typed ergonomic
/// (`request`, `requestOptional`, `send`, `requestRaw`, `requestData`) is a
/// protocol-extension helper layered on top, so the encoding, decoding,
/// empty-body, and non-2xx→`HttpError` policies are defined exactly once and
/// a test fake cannot diverge from the real implementation's semantics.
///
/// `HttpClient` is the production conformance; `ClosureTransport` adapts the
/// deprecated `(String, String, Any?) async throws -> Any` closures during the
/// migration window.
public protocol Transport: Sendable {
    /// Perform one HTTP round trip.
    ///
    /// Implementations build the URL, apply the token / refresh / 401-retry /
    /// refresh-proxy machinery, and return the raw response bytes with the
    /// status. They must **not** throw on a non-2xx status — the status is
    /// carried in the response so the throwing policy lives in one place (the
    /// extension below).
    ///
    /// - Parameters:
    ///   - body: the literal HTTP body bytes, already encoded by the caller.
    ///   - options: `rawBody` / `customHeaders` / `timeout`, honored as today.
    func execute(
        method: HTTPMethod,
        path: String,
        body: Data?,
        options: RequestOptions?
    ) async throws -> TransportResponse
}

// MARK: - The one private primitive

private extension Transport {
    /// The single status-validating primitive. `request`, `requestOptional`,
    /// and `send` are all thin wrappers around it, so the non-2xx policy and
    /// the error-body extraction exist in exactly one place.
    ///
    /// Non-2xx is surfaced as `HttpError` with `{serverCode, serverMessage}`
    /// extracted by the existing `HttpError.parseBody` (#850) — the same
    /// mapping `HttpClient.request` has always applied.
    func executeValidated(
        method: HTTPMethod,
        path: String,
        body: Data?,
        options: RequestOptions?
    ) async throws -> Data {
        let response = try await execute(method: method, path: path, body: body, options: options)
        guard response.ok else {
            let text = response.text
            let parsed = HttpError.parseBody(text)
            throw HttpError(
                status: response.status,
                message: "HTTP \(response.status)",
                body: text,
                serverCode: parsed.code,
                serverMessage: parsed.message
            )
        }
        return response.body
    }

    /// Decode a **required** response value.
    ///
    /// An empty (or whitespace-only) 2xx body throws `HttpError.emptyBody`
    /// rather than silently producing `nil` — callers that legitimately accept
    /// "nothing or a value" use `requestOptional`, and pure-side-effect
    /// endpoints use `send`.
    func decodeRequired<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data,
        path: String
    ) throws -> Response {
        guard !Self.isEffectivelyEmpty(data) else {
            throw HttpError.emptyBody(path: path, expected: Response.self)
        }
        do {
            return try JSONCoding.decodeData(Response.self, from: data)
        } catch {
            throw HttpError.decodingFailure(
                path: path,
                expected: Response.self,
                body: String(data: data, encoding: .utf8),
                underlying: error
            )
        }
    }

    /// Decode an **optional** response value.
    ///
    /// Byte-level rules:
    /// * zero bytes, or bytes that are only JSON whitespace, → `nil`
    ///   (there is no document to decode).
    /// * everything else is handed to `JSONDecoder` as `Optional<Response>`,
    ///   so a literal `null` — with or without surrounding whitespace —
    ///   decodes to `nil` through the standard decoder rather than an ad-hoc
    ///   text comparison.
    /// * malformed JSON still throws (wrapped as `HttpError.decoding`).
    func decodeOptional<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data,
        path: String
    ) throws -> Response? {
        guard !Self.isEffectivelyEmpty(data) else { return nil }
        do {
            return try JSONCoding.decodeData(Optional<Response>.self, from: data)
        } catch {
            throw HttpError.decodingFailure(
                path: path,
                expected: Response.self,
                body: String(data: data, encoding: .utf8),
                underlying: error
            )
        }
    }

    /// A body with no JSON document in it at all: zero bytes, or nothing but
    /// JSON whitespace (space, tab, CR, LF).
    static func isEffectivelyEmpty(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }
}

// MARK: - Typed ergonomics

public extension Transport {

    // MARK: Required response

    /// Typed body in, typed response out. Throws `HttpError` on non-2xx and on
    /// an empty body.
    func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions? = nil
    ) async throws -> Response {
        let data = try await executeValidated(
            method: method,
            path: path,
            body: try JSONCoding.encodeData(body),
            options: options
        )
        return try decodeRequired(Response.self, from: data, path: path)
    }

    /// No request body. (A `Body?` of `nil` cannot infer `Body`, so the
    /// no-body form is its own overload.)
    func request<Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        options: RequestOptions? = nil
    ) async throws -> Response {
        let data = try await executeValidated(
            method: method,
            path: path,
            body: nil,
            options: options
        )
        return try decodeRequired(Response.self, from: data, path: path)
    }

    /// **Pre-encoded** body bytes in, typed response out.
    ///
    /// For the handful of endpoints whose request body is an opaque,
    /// caller-supplied JSON graph the client is not allowed to interpret
    /// (`workflows.start` / `runSync` `rootInput` and `meta`). Re-encoding
    /// such a graph through `JSONValue` would collapse every number to
    /// `Double` and silently lose exactness past 2^53, so the caller composes
    /// the bytes itself and they go out untouched.
    ///
    /// Everything else — the non-2xx policy, the empty-body policy, the
    /// decode — is the same single primitive the other helpers use.
    func request<Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        bodyData: Data,
        options: RequestOptions? = nil
    ) async throws -> Response {
        let data = try await executeValidated(
            method: method,
            path: path,
            body: bodyData,
            options: options
        )
        return try decodeRequired(Response.self, from: data, path: path)
    }

    // MARK: Optional response

    /// Typed body in, **optional** response out: an empty body or a JSON
    /// `null` yields `nil` instead of throwing. Malformed JSON still throws.
    func requestOptional<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions? = nil
    ) async throws -> Response? {
        let data = try await executeValidated(
            method: method,
            path: path,
            body: try JSONCoding.encodeData(body),
            options: options
        )
        return try decodeOptional(Response.self, from: data, path: path)
    }

    /// No request body, optional response.
    func requestOptional<Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        options: RequestOptions? = nil
    ) async throws -> Response? {
        let data = try await executeValidated(
            method: method,
            path: path,
            body: nil,
            options: options
        )
        return try decodeOptional(Response.self, from: data, path: path)
    }

    // MARK: Fire-and-forget

    /// Execute, throw on non-2xx, discard the body.
    func send<Body: Encodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions? = nil
    ) async throws {
        _ = try await executeValidated(
            method: method,
            path: path,
            body: try JSONCoding.encodeData(body),
            options: options
        )
    }

    /// No request body.
    func send(
        method: HTTPMethod,
        path: String,
        options: RequestOptions? = nil
    ) async throws {
        _ = try await executeValidated(method: method, path: path, body: nil, options: options)
    }

    // MARK: Full response (no throw on non-2xx)

    /// The full response — status, headers, parsed `JSONValue?`, text —
    /// **without** throwing on a non-2xx status, for callers that inspect the
    /// status themselves (`IntegrationsAPI`, access validation). Same name and
    /// meaning as the existing `HttpClient.requestRaw`.
    func requestRaw<Body: Encodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions? = nil
    ) async throws -> HttpClientResponse {
        try await execute(
            method: method,
            path: path,
            body: try JSONCoding.encodeData(body),
            options: options
        ).toHttpClientResponse()
    }

    /// No request body.
    func requestRaw(
        method: HTTPMethod,
        path: String,
        options: RequestOptions? = nil
    ) async throws -> HttpClientResponse {
        try await execute(method: method, path: path, body: nil, options: options)
            .toHttpClientResponse()
    }

    // MARK: Raw bytes

    /// Raw bytes in, raw bytes out — blob upload/download.
    ///
    /// Returns `execute`'s **untouched** bytes with the status, and (like the
    /// legacy `makeRawRequest` it replaces) does not throw on a non-2xx
    /// status. Takes `RequestOptions` rather than a bare header dictionary so
    /// callers can also set a timeout; `rawBody` is forced on because the
    /// body is already encoded bytes.
    func requestData(
        method: HTTPMethod,
        path: String,
        body: Data? = nil,
        options: RequestOptions? = nil
    ) async throws -> (Data, Int) {
        var effective = options ?? RequestOptions()
        effective.rawBody = true
        let response = try await execute(
            method: method,
            path: path,
            body: body,
            options: effective
        )
        return (response.body, response.status)
    }
}

// MARK: - TransportResponse → legacy views

extension TransportResponse {
    /// The loosely-typed `JSONSerialization` graph the deprecated `Any` spine
    /// speaks, produced by the **one** classification rule the client has
    /// always used (previously `HttpClient.fetchParsed`):
    ///
    /// * non-JSON content type → the body's UTF-8 text
    /// * JSON content type + empty body → `nil`
    /// * JSON content type + malformed body → the text (lenient fallback)
    /// * otherwise → the parsed graph (fragments allowed)
    ///
    /// Used by the deprecated `HttpClient.request` / `requestRaw` surface.
    /// The typed `Transport` helpers never go through it.
    var legacyParsedJSON: Any? {
        let contentType = header("Content-Type") ?? ""
        let text = self.text
        guard contentType.contains("application/json") else { return text }
        guard let text = text, !text.isEmpty else { return nil }
        if let parsed = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed) {
            return parsed
        }
        return text
    }

    /// The single `TransportResponse` → `HttpClientResponse` conversion, so
    /// `requestRaw` never independently re-parses or re-classifies a response.
    func toHttpClientResponse() -> HttpClientResponse {
        HttpClientResponse(
            ok: ok,
            status: status,
            headers: headers,
            data: legacyParsedJSON.flatMap { try? JSONCoding.decode(JSONValue.self, from: $0) },
            text: text
        )
    }
}
