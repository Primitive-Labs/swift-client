import Foundation

public final class IntegrationsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Call a third-party integration via the server proxy.
    public func call(integrationKey: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/integrations/\(integrationKey)/proxy", params)
        return result as? [String: Any] ?? [:]
    }
}
