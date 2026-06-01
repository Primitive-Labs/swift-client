import Foundation

/// Options bag for `PromptsAPI.execute(_:options:)`. Mirrors the JS
/// client's `executePrompt(promptKey, opts)` second-argument shape so
/// cross-platform code can construct the same payload from either side.
public struct ExecutePromptOptions: Sendable {
    public var variables: [String: Any]
    public var modelOverride: String?
    public var configId: String?

    public init(
        variables: [String: Any] = [:],
        modelOverride: String? = nil,
        configId: String? = nil
    ) {
        self.variables = variables
        self.modelOverride = modelOverride
        self.configId = configId
    }
}

public final class PromptsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// List the prompts available to the current app/user.
    public func list() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/prompts", nil)
        if let dict = result as? [String: Any],
           let items = dict["prompts"] as? [[String: Any]] {
            return items
        }
        return result as? [[String: Any]] ?? []
    }

    /// Get a single prompt by key.
    public func get(promptKey: String) async throws -> [String: Any] {
        let escaped = promptKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? promptKey
        let result = try await makeRequest("GET", "/prompts/\(escaped)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Execute a prompt template. Preferred entry point — accepts an
    /// `ExecutePromptOptions` struct so the call site stays readable
    /// when more flags get added.
    public func execute(
        promptKey: String,
        options: ExecutePromptOptions
    ) async throws -> [String: Any] {
        let escaped = promptKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? promptKey
        var body: [String: Any] = ["variables": options.variables]
        if let modelOverride = options.modelOverride {
            body["modelOverride"] = modelOverride
        }
        if let configId = options.configId {
            body["configId"] = configId
        }
        let result = try await makeRequest(
            "POST", "/prompts/\(escaped)/execute", body
        )
        return result as? [String: Any] ?? [:]
    }

    /// Positional convenience that forwards to `execute(_:options:)`.
    /// Kept for source compatibility with pre-#791 callers.
    public func execute(
        promptKey: String,
        variables: [String: Any],
        modelOverride: String? = nil,
        configId: String? = nil
    ) async throws -> [String: Any] {
        try await execute(
            promptKey: promptKey,
            options: ExecutePromptOptions(
                variables: variables,
                modelOverride: modelOverride,
                configId: configId
            )
        )
    }
}
