import Foundation

// The typed `ExecutePromptOptions` / `ExecutePromptResult` models live in
// `Types/PromptsTypes.swift`.

// MARK: - PromptsAPI

public final class PromptsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Deprecated: construct with a `Transport` instead. The legacy closure is
    /// wrapped in an adapter so existing call sites keep working for one major
    /// cycle.
    @available(*, deprecated, message: "Use init(transport:) — the untyped makeRequest closure is removed in the next major release.")
    public convenience init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.init(transport: ClosureTransport(makeRequest: makeRequest))
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
        let escaped = URLEncoding.encodeComponent(promptKey)
        // The typed options are encoded straight to the wire bytes.
        // JSONEncoder omits nil `modelOverride`/`configId`, matching the JS
        // client, which only sets those keys when truthy.
        return try await transport.request(
            method: .post,
            path: "/prompts/\(escaped)/execute",
            body: options
        )
    }
}
