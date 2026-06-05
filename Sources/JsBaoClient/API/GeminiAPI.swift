import Foundation

// MARK: - GeminiAPI

public final class GeminiAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    /// Emits a lifecycle analytics event. Injected by the client so the API
    /// can fire `prompt_started` / `prompt_succeeded` / `prompt_failed`
    /// around each call without holding a reference to the client. Mirrors
    /// js-bao's `getGeminiAnalyticsContext().logEvent(...)`
    /// (`src/client/api/geminiApi.ts`). Defaults to a no-op so existing
    /// callers/tests that construct `GeminiAPI(makeRequest:)` keep working.
    private let logAnalytics: (AnalyticsEventInput) -> Void

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        logAnalytics: @escaping (AnalyticsEventInput) -> Void = { _ in }
    ) {
        self.makeRequest = makeRequest
        self.logAnalytics = logAnalytics
    }

    /// Operation label stamped into the `context_json.operation` field,
    /// matching JS's `GeminiOperation` strings.
    private enum Operation: String {
        case generate
        case countTokens
        case generateRaw
    }

    /// Sends a structured prompt to Gemini and returns the generated response.
    ///
    /// - Parameter options: Configuration for the generation request
    ///   (`GeminiGenerateOptions`). `messages` is required; `model` falls back
    ///   to the server default when omitted.
    /// - Returns: A typed `GeminiGenerateResult` with `message`, optional
    ///   `candidates`, `usage`, and the `raw` provider response.
    public func generate(options: GeminiGenerateOptions) async throws -> GeminiGenerateResult {
        let body = try JSONCoding.jsonObject(from: options)
        let startedAt = Date()
        let details = Self.promptDetails(options)
        emitAnalytics(.start, operation: .generate, details: details)
        do {
            let result = try await makeRequest("POST", "/gemini/generate", body)
            emitAnalytics(.success, operation: .generate, details: details, startedAt: startedAt)
            return try JSONCoding.decode(GeminiGenerateResult.self, from: result)
        } catch {
            emitAnalytics(.failure, operation: .generate, details: details, startedAt: startedAt, error: error)
            throw Self.rethrowAsGeminiError(error)
        }
    }

    /// Lists available Gemini models and returns the default model name.
    /// - Returns: A typed `GeminiModelsResult` with `models` and `defaultModel`.
    public func models() async throws -> GeminiModelsResult {
        let result = try await makeRequest("GET", "/gemini/models", nil)
        return try JSONCoding.decode(GeminiModelsResult.self, from: result)
    }

    /// Counts the number of tokens in a prompt without generating a response.
    ///
    /// - Parameter options: The prompt to measure (`GeminiPromptOptions`, the
    ///   same shape as `generate`). `safety` / `generationConfig` /
    ///   `structuredOutput` are accepted for parity but do not affect counts.
    /// - Returns: A typed `GeminiCountTokensResult` with `totalTokens` and
    ///   optional `promptTokens`, `candidates`, and `raw`.
    public func countTokens(options: GeminiPromptOptions) async throws -> GeminiCountTokensResult {
        let body = try JSONCoding.jsonObject(from: options)
        let startedAt = Date()
        let details = Self.promptDetails(options)
        emitAnalytics(.start, operation: .countTokens, details: details)
        do {
            let result = try await makeRequest("POST", "/gemini/count-tokens", body)
            emitAnalytics(.success, operation: .countTokens, details: details, startedAt: startedAt)
            return try JSONCoding.decode(GeminiCountTokensResult.self, from: result)
        } catch {
            emitAnalytics(.failure, operation: .countTokens, details: details, startedAt: startedAt, error: error)
            throw Self.rethrowAsGeminiError(error)
        }
    }

    /// Sends a raw request body to a specified Gemini model, bypassing
    /// structured prompt formatting.
    ///
    /// - Parameter options: Raw request configuration (`GeminiGenerateRawOptions`).
    ///   `model` is required; `body` must be a JSON object. `query` values are
    ///   stringified and appended to the request URL.
    /// - Returns: The raw response from the Gemini API as a `JSONValue`.
    public func generateRaw(options: GeminiGenerateRawOptions) async throws -> JSONValue {
        let model = options.model
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw JsBaoError(code: .geminiError, message: "model is required for generateRaw")
        }
        guard let bodyObject = options.body.objectValue else {
            throw JsBaoError(code: .geminiError, message: "body must be a JSON object for generateRaw")
        }

        var queryParts = ["model=\(model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model)"]
        if let query = options.query {
            for (key, value) in query {
                if value.isNull { continue }
                let stringValue = Self.queryStringValue(value)
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = stringValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stringValue
                queryParts.append("\(encodedKey)=\(encodedValue)")
            }
        }
        let path = "/gemini/generate-raw?\(queryParts.joined(separator: "&"))"

        // Re-materialize the typed `body` into the `Any` graph `makeRequest`
        // expects for its JSON body argument.
        let bodyAny = try JSONCoding.jsonObject(from: JSONValue.object(bodyObject))

        let startedAt = Date()
        let details = Self.rawDetails(model: model, body: bodyObject)
        emitAnalytics(.start, operation: .generateRaw, details: details)
        do {
            let result = try await makeRequest("POST", path, bodyAny)
            emitAnalytics(.success, operation: .generateRaw, details: details, startedAt: startedAt)
            return try JSONCoding.decode(JSONValue.self, from: result)
        } catch {
            emitAnalytics(.failure, operation: .generateRaw, details: details, startedAt: startedAt, error: error)
            throw Self.rethrowAsGeminiError(error)
        }
    }

    /// Normalize any provider/transport failure from `makeRequest` into a
    /// uniform `JsBaoError(code: .geminiError, …)`, so callers can catch a
    /// single stable code across every `gemini.*` method. Mirrors the JS
    /// client's `rethrowAsGeminiError` / `parseHttpError`
    /// (`src/client/api/geminiApi.ts`): already-typed `JsBaoError`s
    /// (including the client-side `.geminiError` validation errors) pass
    /// through unchanged; everything else is re-wrapped, preserving the
    /// underlying status / provider message / raw body in `message` and
    /// `details`.
    private static func rethrowAsGeminiError(_ error: Error) -> Error {
        // Leave SDK-typed errors as-is (e.g. `.geminiError` validation).
        if let jsBao = error as? JsBaoError {
            return jsBao
        }

        // The Swift transport throws a structured `HttpError`; pull the
        // provider message and status out of it directly rather than
        // regex-matching a string the way the JS client must.
        if let http = error as? HttpError {
            let message = http.serverMessage?.isEmpty == false
                ? http.serverMessage!
                : "HTTP \(http.status)"
            var details: [String: JSONValue] = ["status": .number(Double(http.status))]
            if let serverCode = http.serverCode { details["code"] = .string(serverCode) }
            if let body = http.body, !body.isEmpty { details["raw"] = .string(body) }
            return JsBaoError(code: .geminiError, message: message, details: details)
        }

        // Any other transport/decode failure: preserve its description.
        let message = (error as? LocalizedError)?.errorDescription
            ?? "\(error)"
        return JsBaoError(
            code: .geminiError,
            message: message.isEmpty ? "Gemini request failed" : message
        )
    }

    // MARK: - Analytics

    /// Lifecycle phase of an analytics event. Maps to JS's
    /// `"start" | "success" | "failure"`.
    private enum Phase {
        case start, success, failure

        /// Action suffix used in the event name, matching JS:
        /// `prompt_started` / `prompt_succeeded` / `prompt_failed`.
        var actionSuffix: String {
            switch self {
            case .start: return "started"
            case .success: return "succeeded"
            case .failure: return "failed"
            }
        }
    }

    /// Per-call analytics details, mirroring JS's `GeminiAnalyticsDetails`.
    /// `structuredOutput` is nil for `generateRaw` (JS leaves it
    /// `undefined`).
    private struct Details {
        var model: String?
        var messages: Int?
        var structuredOutput: Bool?
    }

    /// Build the `prompt_<phase>` analytics event and hand it to the
    /// injected logger. Mirrors `GeminiAPI.emitAnalytics`
    /// (`src/client/api/geminiApi.ts`): `feature: "gemini"`, an action of
    /// `prompt_started`/`prompt_succeeded`/`prompt_failed`, and a
    /// `context_json` carrying `operation` / `model` / `messages` /
    /// `structured_output` plus `duration_ms` (success/failure) and
    /// `error` (failure). Keys whose value is absent serialize to `null`,
    /// matching JS where the same keys are set from `undefined` fields.
    private func emitAnalytics(
        _ phase: Phase,
        operation: Operation,
        details: Details,
        startedAt: Date? = nil,
        error: Error? = nil
    ) {
        var context: [String: JSONValue] = [
            "operation": .string(operation.rawValue),
            "model": details.model.map(JSONValue.string) ?? .null,
            "messages": details.messages.map { .number(Double($0)) } ?? .null,
            "structured_output": details.structuredOutput.map(JSONValue.bool) ?? .null,
        ]
        if let startedAt {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            context["duration_ms"] = .number(Double(durationMs))
        }
        if phase == .failure, let error {
            context["error"] = .string(Self.errorMessage(error))
        }

        logAnalytics(
            AnalyticsEventInput(
                action: "prompt_\(phase.actionSuffix)",
                feature: "gemini",
                context_json: .object(context)
            )
        )
    }

    /// Details for `generate` / `countTokens`, mirroring JS's
    /// `buildPromptAnalyticsDetails`.
    private static func promptDetails(_ options: GeminiPromptOptions) -> Details {
        Details(
            model: options.model,
            messages: options.messages.count,
            structuredOutput: options.structuredOutput != nil
        )
    }

    /// Details for `generateRaw`, mirroring JS's `buildRawAnalyticsDetails`
    /// (message count estimated from `body.contents`; `structuredOutput`
    /// left nil).
    private static func rawDetails(model: String, body: [String: JSONValue]) -> Details {
        Details(model: model, messages: body["contents"]?.arrayValue?.count, structuredOutput: nil)
    }

    /// Extract a human-readable message from an error for the `error`
    /// analytics field, mirroring JS's
    /// `error instanceof Error ? error.message : String(error)`.
    private static func errorMessage(_ error: Error) -> String {
        if let jsBao = error as? JsBaoError { return jsBao.message }
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return "\(error)"
    }

    /// Stringify a scalar query-param value the way the JS client does
    /// (`string | number | boolean`); `null` is filtered out by the caller.
    private static func queryStringValue(_ value: JSONValue) -> String {
        switch value {
        case let .string(s): return s
        case let .bool(b): return b ? "true" : "false"
        case let .number(n):
            // Render integral doubles without a trailing `.0`.
            if n == n.rounded(), abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        default:
            return ""
        }
    }
}
