import Foundation

// MARK: - SessionAPI

public final class SessionAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Retrieves information about the current authenticated session.
    public func get() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/me", nil)
        return result as? [String: Any] ?? [:]
    }
}
