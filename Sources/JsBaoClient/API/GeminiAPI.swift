import Foundation

// MARK: - GeminiAPI

public final class GeminiAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Sends a structured prompt to Gemini and returns the generated response.
    ///
    /// - Parameter options: Configuration for the generation request. Expected keys:
    ///   - `model` (String, optional): The Gemini model to use.
    ///   - `system` (Array, optional): System-level content parts.
    ///   - `messages` (Array): Conversation history with `role` and `parts`.
    ///   - `safety` (Array, optional): Safety filter settings.
    ///   - `generationConfig` (Dictionary, optional): Low-level generation parameters.
    ///   - `structuredOutput` (Dictionary, optional): Constrains response to a specific MIME type/schema.
    /// - Returns: Dictionary with `message`, optional `candidates`, `usage`, and `raw` response.
    public func generate(options: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/gemini/generate", options)
        return result as? [String: Any] ?? [:]
    }

    /// Lists available Gemini models and returns the default model name.
    /// - Returns: Dictionary with `models` array and `defaultModel` name.
    public func models() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/gemini/models", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Counts the number of tokens in a prompt without generating a response.
    ///
    /// - Parameter options: The prompt to measure (same shape as generate options).
    /// - Returns: Dictionary with `totalTokens` count and optional `promptTokens`, `candidates`, and `raw`.
    public func countTokens(options: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/gemini/count-tokens", options)
        return result as? [String: Any] ?? [:]
    }

    /// Sends a raw request body to a specified Gemini model, bypassing structured prompt formatting.
    ///
    /// - Parameter options: Raw request configuration. Expected keys:
    ///   - `model` (String, required): The Gemini model to target.
    ///   - `body` (Dictionary, required): The raw JSON payload forwarded to the Gemini API.
    ///   - `query` (Dictionary, optional): Additional query-string parameters.
    /// - Returns: The raw response from the Gemini API.
    public func generateRaw(options: [String: Any]) async throws -> Any {
        guard let model = options["model"] as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "model is required for generateRaw")
        }
        guard let body = options["body"] as? [String: Any] else {
            throw JsBaoError(code: .invalidArgument, message: "body must be a JSON object for generateRaw")
        }

        var queryParts = ["model=\(model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model)"]
        if let query = options["query"] as? [String: Any] {
            for (key, value) in query {
                if value is NSNull { continue }
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = "\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(value)"
                queryParts.append("\(encodedKey)=\(encodedValue)")
            }
        }
        let path = "/gemini/generate-raw?\(queryParts.joined(separator: "&"))"

        let result = try await makeRequest("POST", path, body)
        return result
    }
}
