import Foundation

// MARK: - InvitationsAPI

/// Mirrors the JS `InvitationsAPI` — app-level invitation lifecycle plus
/// deferred-grant browsing for the deferred-grant flow (#466). Distinct
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
    public func quota() async throws -> InvitationQuota {
        let result = try await makeRequest("GET", "/invitations/quota", nil)
        return try JSONCoding.decode(InvitationQuota.self, from: result)
    }

    /// Create an app-level invitation. Members can create invitations
    /// when `memberInvitationsEnabled` is true; admins/owners always can.
    /// Only `params.email` is required.
    public func create(params: CreateInvitationParams) async throws -> AppInvitationInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/invitations", body)
        return try JSONCoding.decode(AppInvitationInfo.self, from: result)
    }

    /// List app-level invitations (admin/owner only). Returns a typed
    /// `{ items, cursor }` page.
    public func list(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> InvitationListResult {
        var qs: [String] = []
        if let limit { qs.append("limit=\(limit)") }
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        let path = qs.isEmpty ? "/invitations" : "/invitations?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return try JSONCoding.decode(InvitationListResult.self, from: result)
    }

    /// Fetch a single app invitation by id. Includes `inviteToken` so
    /// callers can build their own accept-page CTA.
    /// Permissions: app admin/owner, OR the original inviter.
    public func get(invitationId: String) async throws -> AppInvitationInfo {
        let result = try await makeRequest("GET", "/invitations/\(invitationId)", nil)
        return try JSONCoding.decode(AppInvitationInfo.self, from: result)
    }

    /// Delete an app-level invitation (admin/owner only). Cascade-deletes
    /// any linked deferred grants.
    public func delete(invitationId: String) async throws -> InvitationDeleteResult {
        let result = try await makeRequest("DELETE", "/invitations/\(invitationId)", nil)
        return try JSONCoding.decode(InvitationDeleteResult.self, from: result)
    }

    /// Accept an invitation via its invite token (#466). For an
    /// authenticated user whose session already exists; the server marks
    /// the invitation accepted (write-once) and resolves any pending
    /// deferred grants to the caller's `userId`. The result's
    /// `grantsResolved` reports how many group and document grants resolved.
    ///
    /// Throws on any failure with a uniform `INVITE_TOKEN_INVALID` code
    /// (the server collapses invalid / expired / already-accepted to one
    /// shape so existence isn't leaked to probing).
    public func accept(inviteToken: String) async throws -> AcceptInviteResult {
        let result = try await makeRequest(
            "POST", "/invitations/accept",
            ["inviteToken": inviteToken]
        )
        return try JSONCoding.decode(AcceptInviteResult.self, from: result)
    }

    // MARK: - Deferred grants

    /// List pending deferred grants (admin/owner only). Grants are
    /// permissions/memberships created for users who haven't signed up
    /// yet — they activate when the user accepts the linked invitation.
    /// Returns a typed `{ grants, nextCursor }` page; each grant is a
    /// `DeferredGrant` discriminated on `type`.
    ///
    /// - Parameters:
    ///   - type: Filter to `.document` or `.group` only.
    ///   - email: Filter to grants targeting this email.
    ///   - limit: Page size.
    public func listDeferredGrants(
        type: DeferredGrantType? = nil,
        email: String? = nil,
        limit: Int? = nil
    ) async throws -> DeferredGrantListResult {
        var qs: [String] = []
        if let type { qs.append("type=\(type.rawValue)") }
        if let email,
           let escaped = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("email=\(escaped)")
        }
        if let limit { qs.append("limit=\(limit)") }
        let path = qs.isEmpty
            ? "/deferred-grants"
            : "/deferred-grants?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return try JSONCoding.decode(DeferredGrantListResult.self, from: result)
    }

    /// Revoke a deferred grant. Admins/owners can revoke any; the
    /// original granter can revoke their own.
    ///
    /// - Parameter type: `.document` or `.group` — required because
    ///   document and group deferred grants live in separate tables.
    public func revokeDeferredGrant(
        deferredId: String,
        type: DeferredGrantType
    ) async throws -> DeferredGrantRevokeResult {
        let result = try await makeRequest(
            "DELETE", "/deferred-grants/\(deferredId)?type=\(type.rawValue)", nil
        )
        return try JSONCoding.decode(DeferredGrantRevokeResult.self, from: result)
    }
}
