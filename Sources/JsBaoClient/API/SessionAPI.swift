import Foundation

// MARK: - SessionAPI

public final class SessionAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Retrieves information about the current authenticated session.
    /// Mirrors the JS client's `client.session.get()` which calls
    /// `GET /session` (returns `{sessionId, ...}`), distinct from
    /// `GET /me` (returns the user profile).
    public func get() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/session", nil)
        return result as? [String: Any] ?? [:]
    }
}
