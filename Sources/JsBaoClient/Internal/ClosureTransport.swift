import Foundation

/// Adapts the deprecated injected closures to the typed `Transport` spine so
/// converted and un-converted call sites can coexist during the migration.
///
/// **Deprecated migration machinery.** It exists for one major cycle and is
/// deliberately kept `internal`: the deprecated `init(makeRequest:)` on each
/// API class wraps its closure here, but no new code should adopt it.
///
/// Sendability: the legacy closures are **not** `@Sendable` (requiring that
/// would itself be a source break), so this type is `@unchecked Sendable`. It
/// carries exactly the old closures' semantics — no more, no less — and
/// callers remain responsible for synchronizing whatever state their closure
/// captures. That is a statement of scope, not a safety argument.
///
/// ### Options it cannot honor
/// The legacy `(String, String, Any?) -> Any` closure has no `RequestOptions`
/// parameter, so custom headers, timeouts, and `rawBody` cannot be passed
/// through it. Rather than silently dropping them, `execute` **throws** when
/// a JSON-path call supplies options it cannot carry. The one exception is
/// `rawBody`, which is routed to the raw `(Data, Int)` closure when one was
/// supplied (this is how `requestData` works through the adapter). That
/// closure does take custom headers, so those are forwarded; it has no
/// timeout parameter, so a timeout is rejected on that path too.
final class ClosureTransport: Transport, @unchecked Sendable {

    /// `serverCode` on the error thrown when a caller passes `RequestOptions`
    /// the legacy closure cannot carry.
    static let unsupportedOptionsCode = "CLIENT_LEGACY_TRANSPORT_UNSUPPORTED_OPTIONS"

    /// The legacy JSON shape most API classes hold: `Any?` in, `Any` out.
    /// `Any` here routinely boxes `Optional<Any>.none` (`… as Any`) for a
    /// successful empty body.
    typealias LegacyRequest = (String, String, Any?) async throws -> Any

    /// The `AuthController` shape, which is honest about the optional.
    typealias LegacyOptionalRequest = (String, String, Any?) async throws -> Any?

    /// The blob shape (`BlobBucketsAPI`, `MeAPI`, `BlobManager`).
    typealias LegacyRawRequest = (String, String, Data?, [String: String]) async throws -> (Data, Int)

    /// The `IntegrationsAPI` shape, which inspects the status itself.
    typealias LegacyResponseRequest = (String, String, Any?) async throws -> HttpClientResponse

    private let json: LegacyOptionalRequest?
    private let raw: LegacyRawRequest?
    private let response: LegacyResponseRequest?

    // MARK: - Initializers

    /// Wrap the common `-> Any` closure. A boxed `Optional.none` result is
    /// unwrapped back to "empty body" so a successful empty response survives
    /// the adapter instead of being fabricated as `null`.
    init(makeRequest: @escaping LegacyRequest) {
        self.json = { method, path, body in
            let result = try await makeRequest(method, path, body)
            return ClosureTransport.unboxed(result)
        }
        self.raw = nil
        self.response = nil
    }

    /// Wrap the `-> Any?` closure (`AuthController`'s shape).
    init(optionalRequest: @escaping LegacyOptionalRequest) {
        self.json = optionalRequest
        self.raw = nil
        self.response = nil
    }

    /// Wrap the `-> HttpClientResponse` closure (`IntegrationsAPI`'s shape).
    /// The response's `text` bytes are the body — a status-inspecting caller
    /// goes through `requestRaw`, which never needs the untouched bytes.
    init(responseRequest: @escaping LegacyResponseRequest) {
        self.json = nil
        self.raw = nil
        self.response = responseRequest
    }

    /// Wrap a JSON closure plus the blob `(Data, Int)` closure, so
    /// `requestData` (which sets `rawBody`) routes to the raw path.
    init(makeRequest: @escaping LegacyRequest, makeRawRequest: LegacyRawRequest?) {
        self.json = { method, path, body in
            let result = try await makeRequest(method, path, body)
            return ClosureTransport.unboxed(result)
        }
        self.raw = makeRawRequest
        self.response = nil
    }

    // MARK: - Transport

    func execute(
        method: HTTPMethod,
        path: String,
        body: Data?,
        options: RequestOptions?
    ) async throws -> TransportResponse {
        // Raw-bytes path: `requestData` forces `rawBody`, which only the blob
        // closure can serve.
        if options?.rawBody == true {
            guard let raw = raw else {
                throw ClosureTransport.unsupportedOptions(
                    "rawBody requires a legacy raw-request closure"
                )
            }
            // The raw closure takes headers but has no timeout parameter, so a
            // timeout is rejected here rather than silently dropped — the same
            // rule the JSON path applies below.
            guard options?.timeout == nil else {
                throw ClosureTransport.unsupportedOptions(
                    "the legacy raw-request closure carries no timeout"
                )
            }
            let (data, status) = try await raw(
                method.rawValue,
                path,
                body,
                options?.customHeaders ?? [:]
            )
            return TransportResponse(status: status, headers: [:], body: data)
        }

        if let options = options {
            guard options.customHeaders.isEmpty, options.timeout == nil else {
                throw ClosureTransport.unsupportedOptions(
                    "the legacy closure carries no RequestOptions (custom headers, timeout)"
                )
            }
        }

        // The legacy closures speak the `JSONSerialization` graph, so the
        // already-encoded bytes are converted back for one more cycle.
        let jsonBody: Any? = try body.flatMap { data -> Any? in
            guard !data.isEmpty else { return nil }
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        if let response = response {
            let result = try await response(method.rawValue, path, jsonBody)
            // `result.data` is the value the closure actually parsed — prefer
            // it over re-deriving one from `text`, which only round-trips
            // when the closure's headers happen to say `application/json`.
            // A closure that returns correct `data` with no `Content-Type`
            // (a hand-written closure, or a test fake) would otherwise reach
            // `IntegrationsAPI` as a `.string`, failing the shape check on
            // the very compat path this shim exists to preserve.
            var headers = result.headers
            let body: Data
            if let parsed = result.data, let encoded = try? JSONCoding.encodeData(parsed) {
                body = encoded
                if !headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                    headers["Content-Type"] = "application/json"
                }
            } else {
                body = result.text?.data(using: .utf8) ?? Data()
            }
            return TransportResponse(status: result.status, headers: headers, body: body)
        }

        guard let json = json else {
            throw ClosureTransport.unsupportedOptions("no legacy closure was supplied")
        }

        // The legacy closures throw `HttpError` themselves on a non-2xx
        // status, so a value returned here is always a success. Reporting 200
        // keeps the extension's status policy from re-wrapping an error the
        // legacy path already mapped — exact legacy error mapping preserved.
        let result = try await json(method.rawValue, path, jsonBody)
        guard let result = result else {
            return ClosureTransport.successResponse(body: Data())
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        return ClosureTransport.successResponse(body: data)
    }

    // MARK: - Helpers

    /// `try await closure(...) as Any` boxes `Optional<Any>.none` inside a
    /// non-optional `Any`. Unwrap it back to a real `nil` so an empty 2xx
    /// response is still "empty" on the far side of the adapter.
    private static func unboxed(_ value: Any) -> Any? {
        if value is NSNull { return value }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let child = mirror.children.first else { return nil }
        return child.value
    }

    private static func successResponse(body: Data) -> TransportResponse {
        TransportResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    private static func unsupportedOptions(_ detail: String) -> HttpError {
        HttpError(
            status: 0,
            message: "Deprecated closure transport cannot honor these RequestOptions: \(detail)",
            body: nil,
            serverCode: unsupportedOptionsCode,
            serverMessage: nil
        )
    }
}
