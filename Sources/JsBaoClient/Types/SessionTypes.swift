import Foundation

// MARK: - Session: typed response model
//
// Mirrors the interface published by the JS client (`api/sessionApi.d.ts`)
// so the two surfaces line up field-for-field. Timestamps stay as ISO-8601
// `String`s — exactly what JS exposes — rather than `Date`, so a round-trip
// never loses precision or reformats.

/// Information about the current authenticated session. Mirrors JS
/// `SessionInfo`, returned by `client.session.get()`.
public struct SessionInfo: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let userId: String
    /// ISO-8601 timestamp of when the session expires.
    public let expiresAt: String
    /// ISO-8601 timestamp of when the session was created.
    public let createdAt: String
    /// ISO-8601 timestamp of the last observed activity on the session.
    public let lastActivity: String
}
