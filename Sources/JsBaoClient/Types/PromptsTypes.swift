import Foundation

// MARK: - Prompts: typed request & response models
//
// These mirror the interfaces published by the JS client on
// `JsBaoClient` (`PromptsAPI` = `{ execute }`, `ExecutePromptOptions`,
// `ExecutePromptResult`). The two surfaces line up field-for-field.
// Opaque, platform-untouched payloads — each `variables` value and the
// `rawResponse` blob — are typed as `JSONValue` (see JSONValue.swift) so
// they round-trip losslessly while still participating in `Codable`,
// matching JS's `Record<string, any>` / `any` typing.

// MARK: Request

/// Options bag for `PromptsAPI.execute(promptKey:options:)`. Mirrors the
/// JS client's `ExecutePromptOptions` second-argument shape so
/// cross-platform code can construct the same payload from either side.
///
/// `variables` is `[String: JSONValue]` (not `[String: Any]`) so the body
/// encodes losslessly via `Codable`, matching JS's `Record<string, any>`.
/// Construct values with literals: `["topic": "otters", "count": 3]`.
public struct ExecutePromptOptions: Encodable, Sendable {
    /// Variables to pass to the prompt template.
    public var variables: [String: JSONValue]
    /// Override the model specified in the prompt config.
    public var modelOverride: String?
    /// Specific config ID to use (defaults to the prompt's activeConfigId).
    public var configId: String?

    public init(
        variables: [String: JSONValue] = [:],
        modelOverride: String? = nil,
        configId: String? = nil
    ) {
        self.variables = variables
        self.modelOverride = modelOverride
        self.configId = configId
    }
}

// MARK: Response

/// Result from executing a prompt. Mirrors the JS `ExecutePromptResult`
/// field-for-field. `rawResponse` is the opaque upstream payload (JS's
/// `any`) typed as `JSONValue`; inspect it via `JSONValue` accessors.
public struct ExecutePromptResult: Decodable, Sendable, Equatable {
    /// Per-call token/latency accounting. Mirrors JS's nested `metrics`.
    public struct Metrics: Decodable, Sendable, Equatable {
        public let durationMs: Double
        public let inputTokens: Double?
        public let outputTokens: Double?
        public let totalTokens: Double?

        public init(
            durationMs: Double,
            inputTokens: Double? = nil,
            outputTokens: Double? = nil,
            totalTokens: Double? = nil
        ) {
            self.durationMs = durationMs
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public let success: Bool
    public let output: String
    public let error: String?
    public let metrics: Metrics
    /// Opaque provider response. Mirrors JS's `rawResponse: any`; inspect
    /// via `JSONValue` accessors / subscripts.
    public let rawResponse: JSONValue?
    public let configId: String

    public init(
        success: Bool,
        output: String,
        error: String? = nil,
        metrics: Metrics,
        rawResponse: JSONValue? = nil,
        configId: String
    ) {
        self.success = success
        self.output = output
        self.error = error
        self.metrics = metrics
        self.rawResponse = rawResponse
        self.configId = configId
    }
}
