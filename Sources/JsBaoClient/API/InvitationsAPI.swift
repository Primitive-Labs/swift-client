import Foundation

// MARK: - InvitationsAPI

/// Mirrors the JS `InvitationsAPI` — app-level invitation lifecycle plus
/// deferred-grant browsing for the deferred-grant flow (#466). Distinct
/// from the per-document invitation methods on `client.documents.*`,
/// which were the only invitation surface before this PR.
public final class InvitationsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Invitations

    /// Check the caller's invitation quota. Admins/owners always get
    /// `unlimited: true`.
    public func quota() async throws -> InvitationQuota {
        try await transport.request(method: .get, path: "/invitations/quota")
    }

    /// Create an app-level invitation. Members can create invitations
    /// when `memberInvitationsEnabled` is true; admins/owners always can.
    /// Only `params.email` is required.
    public func create(params: CreateInvitationParams) async throws -> AppInvitationInfo {
        try await transport.request(method: .post, path: "/invitations", body: params)
    }

    /// List app-level invitations (admin/owner only). Returns a typed
    /// `{ items, cursor }` page.
    public func list(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> InvitationListResult {
        var query = URLQuery()
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        return try await transport.request(method: .get, path: "/invitations\(query.queryString)")
    }

    /// Fetch a single app invitation by id. Includes `inviteToken` so
    /// callers can build their own accept-page CTA.
    /// Permissions: app admin/owner, OR the original inviter.
    public func get(invitationId: String) async throws -> AppInvitationInfo {
        try await transport.request(method: .get, path: "/invitations/\(invitationId)")
    }

    /// Delete an app-level invitation (admin/owner only). Cascade-deletes
    /// any linked deferred grants.
    public func delete(invitationId: String) async throws -> InvitationDeleteResult {
        try await transport.request(method: .delete, path: "/invitations/\(invitationId)")
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
        try await transport.request(
            method: .post,
            path: "/invitations/accept",
            body: ["inviteToken": inviteToken]
        )
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
    ///   - cursor: Continuation token from a previous page's `nextCursor`
    ///     (#1316). Without it the server's real position cursor is
    ///     unreachable and a caller can never advance past page one.
    public func listDeferredGrants(
        type: DeferredGrantType? = nil,
        email: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> DeferredGrantListResult {
        var query = URLQuery()
        if let type { query.append("type", type.rawValue) }
        query.appendIfPresent("email", email)
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        return try await transport.request(
            method: .get,
            path: "/deferred-grants\(query.queryString)"
        )
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
        try await transport.request(
            method: .delete,
            path: "/deferred-grants/\(deferredId)?type=\(type.rawValue)"
        )
    }
}
