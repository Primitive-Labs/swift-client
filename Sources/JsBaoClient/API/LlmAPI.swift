import Foundation

// MARK: - LlmAPI

public final class LlmAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Sends a chat completion request to the configured LLM provider.
    ///
    /// - Parameter options: Configuration for the chat request. Expected keys:
    ///   - `model` (String, optional): The LLM model identifier to use.
    ///   - `messages` (Array): Conversation messages forming the chat history, each with `role` and `content`.
    ///   - `attachments` (Array, optional): Images, audio clips, or PDFs to include.
    ///   - `temperature` (Double, optional): Sampling temperature controlling randomness.
    ///   - `plugins` (Array, optional): Provider-specific plugin configurations.
    ///   - `tools` (Any, optional): Tool/function definitions the model may invoke.
    ///   - `tool_choice` (Any, optional): Controls tool calling behavior.
    ///   - `top_p` (Double, optional): Nucleus sampling threshold.
    ///   - `max_tokens` (Int, optional): Maximum tokens to generate.
    ///   - `reasoning` (Dictionary, optional): Extended thinking behavior configuration.
    /// - Returns: The assistant message with `role`, `content`, optional `annotations`, and `raw` provider response.
    public func chat(options: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/llm/chat", options)
        return result as? [String: Any] ?? [:]
    }

    /// Lists available LLM models and returns the default model name.
    /// - Returns: Dictionary with `models` array and `defaultModel` name.
    public func models() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/llm/models", nil)
        return result as? [String: Any] ?? [:]
    }
}
