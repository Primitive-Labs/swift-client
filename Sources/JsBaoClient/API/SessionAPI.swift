import Foundation

// MARK: - SessionAPI

public final class SessionAPI: @unchecked Sendable {
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

    /// Retrieves information about the current authenticated session.
    /// Mirrors the JS client's `client.session.get()` which calls
    /// `GET /session` (returns a typed `SessionInfo`), distinct from
    /// `GET /me` (returns the user profile).
    public func get() async throws -> SessionInfo {
        try await transport.request(method: .get, path: "/session")
    }
}
