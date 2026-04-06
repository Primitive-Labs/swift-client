import Foundation

public final class PromptsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Execute a prompt template with variables.
    public func execute(promptKey: String, variables: [String: Any], modelOverride: String? = nil, configId: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["variables": variables]
        if let modelOverride = modelOverride { body["modelOverride"] = modelOverride }
        if let configId = configId { body["configId"] = configId }
        let result = try await makeRequest("POST", "/prompts/\(promptKey)/execute", body)
        return result as? [String: Any] ?? [:]
    }
}
