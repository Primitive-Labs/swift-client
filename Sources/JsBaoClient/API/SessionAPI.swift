import Foundation

// MARK: - SessionAPI

public final class SessionAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Retrieves information about the current authenticated session.
    /// Mirrors the JS client's `client.session.get()` which calls
    /// `GET /session` (returns a typed `SessionInfo`), distinct from
    /// `GET /me` (returns the user profile).
    public func get() async throws -> SessionInfo {
        try await transport.request(method: .get, path: "/session")
    }
}
