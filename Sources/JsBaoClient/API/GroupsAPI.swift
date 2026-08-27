import Foundation

// MARK: - GroupsAPI

public final class GroupsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Groups CRUD

    /// Creates a new group with the specified type, ID, and name.
    public func create(params: CreateGroupParams) async throws -> GroupInfo {
        try await transport.request(method: .post, path: "/groups", body: params)
    }

    /// Lists groups, optionally filtered by group type, with cursor
    /// pagination. Pass `includeSystem: true` to surface platform-managed
    /// internal `_`-prefixed groups (excluded by default).
    public func list(options: ListGroupsOptions? = nil) async throws -> PaginatedResult<GroupInfo> {
        var query = URLQuery()
        query.appendIfPresent("type", options?.type)
        if let limit = options?.limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", options?.cursor)
        if options?.includeSystem == true { query.append("includeSystem", "true") }
        return try await transport.request(method: .get, path: "/groups\(query.queryString)")
    }

    /// Retrieves a single group by its type and ID.
    public func get(groupType: String, groupId: String) async throws -> GroupInfo {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(method: .get, path: "/groups/\(escapedType)/\(escapedId)")
    }

    /// Updates a group's name or description.
    public func update(groupType: String, groupId: String, params: UpdateGroupParams) async throws -> GroupInfo {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .patch,
            path: "/groups/\(escapedType)/\(escapedId)",
            body: params
        )
    }

    /// Deletes a group by its type and ID. Returns `{ success }`.
    public func delete(groupType: String, groupId: String) async throws -> SuccessResult {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(method: .delete, path: "/groups/\(escapedType)/\(escapedId)")
    }

    // MARK: - Members

    /// Lists members of a group with optional pagination. Returns a typed
    /// `PaginatedResult<GroupMemberInfo>` (`{ items, cursor? }`).
    ///
    /// Pass `include: .profiles` to join each member with their basic profile
    /// in the same round trip: `userName`/`userEmail` are reliably populated
    /// and `avatarUrl` is included (null when the user has no avatar, or the
    /// membership is orphaned). This replaces the per-member `users.getBasic`
    /// fan-out for roster views. The server rejects unknown `include` values
    /// with HTTP 400.
    public func listMembers(groupType: String, groupId: String, options: PaginationOptions? = nil, include: GroupMemberInclude? = nil) async throws -> PaginatedResult<GroupMemberInfo> {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        var query = URLQuery()
        if let options = options {
            if let limit = options.limit { query.append("limit", limit) }
            query.appendIfPresent("cursor", options.cursor)
        }
        if let include = include { query.append("include", include.rawValue) }
        return try await transport.request(
            method: .get,
            path: "/groups/\(escapedType)/\(escapedId)/members\(query.queryString)"
        )
    }

    /// Adds a user to a group by user ID or email address.
    ///
    /// Returns a discriminated union (`GroupAddMemberResult`) keyed on
    /// `status`:
    ///  * `.direct` with `status == "added"` — new membership created.
    ///  * `.direct` with `status == "already_member"` — the user was already
    ///    a member (`addedAt`/`addedBy` reflect the pre-existing row).
    ///  * `.deferred` (`status == "pending_signup"`) — email not yet in the
    ///    app; a `DeferredGroupAdd` row was created (or returned idempotently).
    ///
    /// Build `params` with `.userId(_:)` or `.email(_:)`.
    public func addMember(groupType: String, groupId: String, params: AddGroupMemberParams) async throws -> GroupAddMemberResult {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .post,
            path: "/groups/\(escapedType)/\(escapedId)/members",
            body: params
        )
    }

    /// Removes a member from a group by user ID. Returns `{ success }`.
    public func removeMember(groupType: String, groupId: String, userId: String) async throws -> SuccessResult {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        let escapedUserId = URLEncoding.encodeComponent(userId)
        return try await transport.request(
            method: .delete,
            path: "/groups/\(escapedType)/\(escapedId)/members/\(escapedUserId)"
        )
    }

    /// Removes a member from a group by email address. Returns `{ success }`.
    public func removeMemberByEmail(groupType: String, groupId: String, email: String) async throws -> SuccessResult {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        var query = URLQuery()
        query.append("email", email)
        return try await transport.request(
            method: .delete,
            path: "/groups/\(escapedType)/\(escapedId)/members\(query.queryString)"
        )
    }

    // MARK: - User Memberships

    /// Lists all group memberships for a given user.
    ///
    /// - Parameter groupType: optional server-side filter to a single group
    ///   type. Mirrors js-bao's `groups.listUserMemberships(userId, { groupType })`
    ///   (#960).
    public func listUserMemberships(userId: String, groupType: String? = nil) async throws -> [GroupMembershipInfo] {
        let escapedUserId = URLEncoding.encodeComponent(userId)
        // Server reads `?type=` (groups-controller.ts:1392); JS sends the same.
        var query = URLQuery()
        query.appendIfPresent("type", groupType)
        return try await transport.request(
            method: .get,
            path: "/users/\(escapedUserId)/memberships\(query.queryString)"
        )
    }

    // MARK: - Group Documents

    /// Lists all documents accessible to a group, with the granted permission.
    public func listDocuments(groupType: String, groupId: String) async throws -> [GroupDocumentInfo] {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .get,
            path: "/groups/\(escapedType)/\(escapedId)/documents"
        )
    }

    /// Lists databases the group has access to (via `DatabaseGroupPermission`).
    /// Mirrors js-bao's `groups.listDatabases(groupType, groupId)`.
    public func listDatabases(
        groupType: String, groupId: String
    ) async throws -> [GroupDatabaseInfo] {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .get,
            path: "/groups/\(escapedType)/\(escapedId)/databases"
        )
    }

    /// Lists pending (unresolved, non-expired) invitations scoped to a group,
    /// so callers can render "members + pending" without touching the internal
    /// deferred-grants surface. Mirrors js-bao's
    /// `groups.listPendingInvitations(groupType, groupId)`.
    public func listPendingInvitations(
        groupType: String, groupId: String
    ) async throws -> [PendingGroupInvitationEntry] {
        let escapedType = URLEncoding.encodeComponent(groupType)
        let escapedId = URLEncoding.encodeComponent(groupId)
        // The server may return a bare array or an `{ items }` envelope —
        // accept both.
        let response: ItemsEnvelope<PendingGroupInvitationEntry> = try await transport.request(
            method: .get,
            path: "/groups/\(escapedType)/\(escapedId)/pending-invitations"
        )
        return response.items
    }
}
