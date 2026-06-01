import Foundation

// MARK: - InvitationsAPI

/// Mirrors the JS `InvitationsAPI` — app-level invitation lifecycle plus
/// deferred-grant browsing for the eight-grant flow (#466). Distinct
/// from the per-document invitation methods on `client.documents.*`,
/// which were the only invitation surface before this PR.
public final class InvitationsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - Invitations

    /// Check the caller's invitation quota. Admins/owners always get
    /// `unlimited: true`.
    public func quota() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/invitations/quota", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Create an app-level invitation. Members can create invitations
    /// when `memberInvitationsEnabled` is true; admins/owners always can.
    ///
    /// - Parameter params: Expected keys:
    ///   - `email` (String, required)
    ///   - `role` (String, optional)
    ///   - `expiresAt` (String, optional, ISO date)
    ///   - `source` (String, optional)
    ///   - `note` (String, optional)
    ///   - `sendEmail` (Bool, optional)
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/invitations", params)
        return result as? [String: Any] ?? [:]
    }

    /// List app-level invitations (admin/owner only). Response carries
    /// `items` and optional `cursor` for pagination.
    public func list(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> [String: Any] {
        var qs: [String] = []
        if let limit { qs.append("limit=\(limit)") }
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        let path = qs.isEmpty ? "/invitations" : "/invitations?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return result as? [String: Any] ?? [:]
    }

    /// Fetch a single app invitation by id. Includes `inviteToken` so
    /// callers can build their own accept-page CTA.
    /// Permissions: app admin/owner, OR the original inviter.
    public func get(invitationId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/invitations/\(invitationId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Delete an app-level invitation (admin/owner only). Cascade-deletes
    /// any linked deferred grants.
    public func delete(invitationId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/invitations/\(invitationId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Accept an invitation via its invite token (#466). For an
    /// authenticated user whose session already exists; the server marks
    /// the invitation accepted (write-once) and resolves any pending
    /// deferred grants to the caller's `userId`.
    ///
    /// Throws on any failure with a uniform `INVITE_TOKEN_INVALID` code
    /// (the server collapses invalid / expired / already-accepted to one
    /// shape so existence isn't leaked to probing).
    public func accept(inviteToken: String) async throws -> [String: Any] {
        let result = try await makeRequest(
            "POST", "/invitations/accept",
            ["inviteToken": inviteToken]
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Deferred grants

    /// List pending deferred grants (admin/owner only). Grants are
    /// permissions/memberships created for users who haven't signed up
    /// yet — they activate when the user accepts the linked invitation.
    ///
    /// - Parameters:
    ///   - type: Filter to `"document"` or `"group"` only.
    ///   - email: Filter to grants targeting this email.
    ///   - limit: Page size.
    public func listDeferredGrants(
        type: String? = nil,
        email: String? = nil,
        limit: Int? = nil
    ) async throws -> [String: Any] {
        var qs: [String] = []
        if let type { qs.append("type=\(type)") }
        if let email,
           let escaped = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("email=\(escaped)")
        }
        if let limit { qs.append("limit=\(limit)") }
        let path = qs.isEmpty
            ? "/deferred-grants"
            : "/deferred-grants?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return result as? [String: Any] ?? [:]
    }

    /// Revoke a deferred grant. Admins/owners can revoke any; the
    /// original granter can revoke their own.
    ///
    /// - Parameter type: `"document"` or `"group"` — required because
    ///   document and group deferred grants live in separate tables.
    public func revokeDeferredGrant(
        deferredId: String,
        type: String
    ) async throws -> [String: Any] {
        let result = try await makeRequest(
            "DELETE", "/deferred-grants/\(deferredId)?type=\(type)", nil
        )
        return result as? [String: Any] ?? [:]
    }
}
