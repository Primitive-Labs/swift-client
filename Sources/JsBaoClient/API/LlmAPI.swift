import Foundation

// MARK: - LlmAPI

public final class LlmAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Emits a lifecycle analytics event. Injected by the client so the API
    /// can fire `prompt_started` / `prompt_succeeded` / `prompt_failed`
    /// around each `chat` call without holding a reference to the client.
    /// Mirrors js-bao's `getLlmAnalyticsContext().logEvent(...)`
    /// (`src/client/api/llmApi.ts`). Defaults to a no-op so a caller that
    /// constructs `LlmAPI(transport:)` without the client keeps working.
    private let logAnalytics: (AnalyticsEventInput) -> Void

    /// Designated initializer — the typed transport spine.
    public init(
        transport: any Transport,
        logAnalytics: @escaping (AnalyticsEventInput) -> Void = { _ in }
    ) {
        self.transport = transport
        self.logAnalytics = logAnalytics
    }

    /// Sends a chat completion request to the configured LLM provider.
    ///
    /// - Parameter options: Configuration for the chat request — model,
    ///   messages, optional image/audio/PDF `attachments`, `temperature`,
    ///   `tools`/`tool_choice`/`plugins`, sampling controls, and `reasoning`.
    /// - Returns: The assistant message with `role`, `content`, optional
    ///   `annotations`, and the provider `raw` response.
    @available(*, deprecated, message: "The direct LLM client API is deprecated and will be removed in a future major release. Use client.prompts.execute (managed prompts) or a workflow llm.chat step instead.")
    public func chat(options: LlmChatOptions) async throws -> LlmChatResponse {
        let startedAt = Date()

        // `prompt_started`: model + message/attachment counts. Mirrors the
        // `start` event in `llmApi.ts`.
        logAnalytics(
            AnalyticsEventInput(
                action: "prompt_started",
                feature: "llm",
                context_json: .object([
                    "model": options.model.map(JSONValue.string) ?? .null,
                    "messages": .number(Double(options.messages.count)),
                    "attachments": .number(Double(options.attachments?.count ?? 0)),
                ])
            )
        )

        do {
            let response: LlmChatResponse = try await transport.request(
                method: .post,
                path: "/llm/chat",
                body: options
            )
            // `prompt_succeeded`: model + duration.
            logAnalytics(
                AnalyticsEventInput(
                    action: "prompt_succeeded",
                    feature: "llm",
                    context_json: .object([
                        "model": options.model.map(JSONValue.string) ?? .null,
                        "duration_ms": .number(Double(Self.durationMs(since: startedAt))),
                    ])
                )
            )
            return response
        } catch {
            // `prompt_failed`: model + duration + error message.
            logAnalytics(
                AnalyticsEventInput(
                    action: "prompt_failed",
                    feature: "llm",
                    context_json: .object([
                        "model": options.model.map(JSONValue.string) ?? .null,
                        "duration_ms": .number(Double(Self.durationMs(since: startedAt))),
                        "error": .string(Self.errorMessage(error)),
                    ])
                )
            )
            throw error
        }
    }

    /// Elapsed milliseconds since `start`, matching JS's
    /// `Date.now() - startedAt`.
    private static func durationMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Human-readable error message for the `error` analytics field,
    /// mirroring JS's `error instanceof Error ? error.message : String(error)`.
    private static func errorMessage(_ error: Error) -> String {
        if let jsBao = error as? JsBaoError { return jsBao.message }
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return "\(error)"
    }

    /// Lists available LLM models and returns the default model name.
    /// - Returns: The `models` array and the `defaultModel` name.
    @available(*, deprecated, message: "The direct LLM client API is deprecated and will be removed in a future major release. Use client.prompts.execute (managed prompts) or a workflow llm.chat step instead.")
    public func models() async throws -> LlmModelsResponse {
        try await transport.request(method: .get, path: "/llm/models")
    }
}
