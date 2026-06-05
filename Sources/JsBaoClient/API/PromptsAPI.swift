import Foundation

// The typed `ExecutePromptOptions` / `ExecutePromptResult` models live in
// `Types/PromptsTypes.swift`.

// MARK: - PromptsAPI

public final class PromptsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Execute a prompt template. Preferred entry point — accepts an
    /// `ExecutePromptOptions` struct so the call site stays readable
    /// when more flags get added.
    ///
    /// Mirrors the JS client's `client.prompts.execute(promptKey, opts)`
    /// and resolves to a typed `ExecutePromptResult` (`success`, `output`,
    /// `error?`, `metrics`, `rawResponse`, `configId`). A malformed body
    /// now throws on decode rather than coercing to an empty dict (#991).
    @discardableResult
    public func execute(
        promptKey: String,
        options: ExecutePromptOptions
    ) async throws -> ExecutePromptResult {
        guard !promptKey.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "promptKey is required for prompts.execute"
            )
        }
        let escaped = promptKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? promptKey
        // Encode the typed options to the JSON `Any` graph. JSONEncoder
        // omits nil `modelOverride`/`configId`, matching the JS client,
        // which only sets those keys when truthy.
        let body = try JSONCoding.jsonObject(from: options)
        let result = try await makeRequest(
            "POST", "/prompts/\(escaped)/execute", body
        )
        return try JSONCoding.decode(ExecutePromptResult.self, from: result)
    }
}
