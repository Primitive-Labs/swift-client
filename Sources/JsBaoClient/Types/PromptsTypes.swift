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
        /// #3358 — the reasoning/thinking tokens the provider reports,
        /// separately from `outputTokens`: how the effect of a config's
        /// `reasoningEffort` / `reasoningBudget` is measured. OpenRouter counts
        /// reasoning inside its output tokens and Gemini counts it outside, so
        /// neither headline number says how much of the decode was
        /// deliberation. `nil` when the provider reports none.
        public let reasoningTokens: Double?
        /// #3626 — what this call cost, in USD, as the provider reported it.
        /// A decisions model's whole case is economic, so a result reporting
        /// tokens and not price would leave the one number the decision turns
        /// on unreadable. `nil` when the provider reports none.
        public let cost: Double?

        public init(
            durationMs: Double,
            inputTokens: Double? = nil,
            outputTokens: Double? = nil,
            totalTokens: Double? = nil,
            reasoningTokens: Double? = nil,
            cost: Double? = nil
        ) {
            self.durationMs = durationMs
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.reasoningTokens = reasoningTokens
            self.cost = cost
        }
    }

    public let success: Bool
    public let output: String
    public let error: String?
    /// #3663 — the upstream provider's own HTTP status, on a failure where the
    /// call reached the provider and it answered. It does not depend on which
    /// provider the prompt's configuration names, and it is what a retry
    /// decision is made on without parsing `error`: retry on 408, 429, 502,
    /// 503 and 504; any other 4xx will fail the same way next time.
    ///
    /// `nil` on success, and `nil` on a failure where no provider answer was
    /// observed — an unset provider key, an oversized payload, a completion
    /// that came back empty — so a number here is always the provider's own.
    public let upstreamStatus: Int?
    /// #3663 — the code naming the failure, when the failure has one.
    ///
    /// `"PROMPT_UPSTREAM_TIMEOUT"` when the provider itself ran out of time,
    /// which is the one failure of the model call that carries a code. `nil`
    /// on success and on every other provider failure, so `error` with no
    /// `errorCode` still means "the call failed for some other reason".
    ///
    /// Typed as a plain `String` rather than an enum so a code the platform
    /// adds later still decodes: the function path's envelope already carries
    /// the `PROMPT_OUTPUT_*` family (#3330) in this field's place.
    public let errorCode: String?
    public let metrics: Metrics
    /// Opaque provider response. Mirrors JS's `rawResponse: any`; inspect
    /// via `JSONValue` accessors / subscripts.
    public let rawResponse: JSONValue?
    public let configId: String

    public init(
        success: Bool,
        output: String,
        error: String? = nil,
        upstreamStatus: Int? = nil,
        errorCode: String? = nil,
        metrics: Metrics,
        rawResponse: JSONValue? = nil,
        configId: String
    ) {
        self.success = success
        self.output = output
        self.error = error
        self.upstreamStatus = upstreamStatus
        self.errorCode = errorCode
        self.metrics = metrics
        self.rawResponse = rawResponse
        self.configId = configId
    }
}
