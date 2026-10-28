import Foundation

// MARK: - GroupsAPI

/// Groups: named sets of users with roles (`owner`, `manager`, `member`),
/// held by one custodian and addressed by `groupId` alone. Mirrors js-bao's
/// `client.groups`.
///
/// The `groupType:` labels address the typed alias routes
/// (`/groups/{groupType}/{groupId}/…`) and are deprecated beside the
/// `groupId:` labels.
public final class GroupsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Groups CRUD

    /// Asks the server to create a group from this session. Only a server
    /// function creates a group on the app routes, so the server refuses
    /// every session's create with a 403 (`FUNCTION_ROUTE_FUNCTION_ONLY`), an
    /// app admin's included.
    @available(*, deprecated, message: "A session cannot create a group: create it from a server function or the admin API. Removed by #4718.")
    public func create(params: CreateGroupParams) async throws -> GroupInfo {
        try await transport.request(method: .post, path: "/groups", body: params)
    }

    /// Lists groups with cursor pagination: an ordinary member's own groups,
    /// or every group in the app for an app owner or admin. Pass
    /// `includeSystem: true` to surface platform-managed internal
    /// `_`-prefixed groups (excluded by default).
    public func list(options: ListGroupsOptions? = nil) async throws -> PaginatedResult<GroupInfo> {
        var query = URLQuery()
        query.appendIfPresent("type", options?.typeFilter)
        if let limit = options?.limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", options?.cursor)
        if options?.includeSystem == true { query.append("includeSystem", "true") }
        return try await transport.request(method: .get, path: "/groups\(query.queryString)")
    }

    /// Retrieves a single group by its ID.
    public func get(groupId: String) async throws -> GroupInfo {
        try await transport.request(method: .get, path: Self.path(groupId))
    }

    /// Retrieves a single group by its type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use get(groupId:). Removed by #4718.")
    public func get(groupType: String, groupId: String) async throws -> GroupInfo {
        try await transport.request(method: .get, path: Self.path(groupType, groupId))
    }

    /// Updates a group's name, description or settings. A manager or the
    /// owner may update.
    public func update(groupId: String, params: UpdateGroupParams) async throws -> GroupInfo {
        try await transport.request(method: .patch, path: Self.path(groupId), body: params)
    }

    /// Updates a group's name or description, addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use update(groupId:params:). Removed by #4718.")
    public func update(groupType: String, groupId: String, params: UpdateGroupParams) async throws -> GroupInfo {
        try await transport.request(method: .patch, path: Self.path(groupType, groupId), body: params)
    }

    /// Deletes a group by its ID. Only the owner, or an app owner or admin,
    /// may delete. Returns `{ success }`.
    public func delete(groupId: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: Self.path(groupId))
    }

    /// Deletes a group by its type and ID. Returns `{ success }`.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use delete(groupId:). Removed by #4718.")
    public func delete(groupType: String, groupId: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: Self.path(groupType, groupId))
    }

    /// Transfers the group to another member: they become its custodian and
    /// hold `owner`, and the previous owner becomes a manager. No other role
    /// changes. Only the owner, or an app owner or admin, may transfer;
    /// moving a group to or from the app is for a server function or the
    /// admin API.
    ///
    /// - Parameter to: the new custodian, `"user:<userId>"`.
    /// - Returns: the group with its new `custodian`.
    public func transfer(groupId: String, to: String) async throws -> GroupInfo {
        try await transport.request(
            method: .post,
            path: "\(Self.path(groupId))/transfer",
            body: ["to": to]
        )
    }

    // MARK: - Members

    /// Lists members of a group, each with their `role`, with optional
    /// pagination. Returns a typed `PaginatedResult<GroupMemberInfo>`
    /// (`{ items, hasMore, nextCursor? }`). A group whose
    /// `settings.memberList` is `managers` answers 403 to a plain member.
    ///
    /// Pass `include: .profiles` to join each member with their basic profile
    /// in the same round trip: `userName`/`userEmail` are reliably populated
    /// and `avatarUrl` is included (null when the user has no avatar, or the
    /// membership is orphaned). This replaces the per-member `users.getBasic`
    /// fan-out for roster views. The server rejects unknown `include` values
    /// with HTTP 400.
    public func listMembers(groupId: String, options: PaginationOptions? = nil, include: GroupMemberInclude? = nil) async throws -> PaginatedResult<GroupMemberInfo> {
        try await transport.request(
            method: .get,
            path: "\(Self.path(groupId))/members\(Self.membersQuery(options, include))"
        )
    }

    /// Lists members of a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use listMembers(groupId:options:include:). Removed by #4718.")
    public func listMembers(groupType: String, groupId: String, options: PaginationOptions? = nil, include: GroupMemberInclude? = nil) async throws -> PaginatedResult<GroupMemberInfo> {
        try await transport.request(
            method: .get,
            path: "\(Self.path(groupType, groupId))/members\(Self.membersQuery(options, include))"
        )
    }

    /// Adds a user to a group by user ID or email address, with a role.
    ///
    /// Returns a discriminated union (`GroupAddMemberResult`) keyed on
    /// `status`:
    ///  * `.direct` with `status == "added"` — new membership created.
    ///  * `.direct` with `status == "already_member"` — the user was already
    ///    a member (`addedAt`/`addedBy`/`role` reflect the pre-existing row).
    ///  * `.deferred` (`status == "pending_signup"`) — email not yet in the
    ///    app; a `DeferredGroupAdd` row was created (or returned idempotently).
    ///
    /// Build `params` with `.userId(_:role:)` or `.email(_:role:)`.
    public func addMember(groupId: String, params: AddGroupMemberParams) async throws -> GroupAddMemberResult {
        try await transport.request(method: .post, path: "\(Self.path(groupId))/members", body: params)
    }

    /// Adds a user to a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use addMember(groupId:params:). Removed by #4718.")
    public func addMember(groupType: String, groupId: String, params: AddGroupMemberParams) async throws -> GroupAddMemberResult {
        try await transport.request(method: .post, path: "\(Self.path(groupType, groupId))/members", body: params)
    }

    /// Changes a member's role to `manager` or `member`. The group's `owner`
    /// row changes only from a server function or the admin API (403
    /// `OWNER_ROW_PROTECTED` from a session).
    public func setMemberRole(groupId: String, userId: String, role: GroupRole) async throws -> GroupMemberRole {
        try await transport.request(
            method: .patch,
            path: "\(Self.path(groupId))/members/\(URLEncoding.encodeComponent(userId))",
            body: ["role": role]
        )
    }

    /// Removes a member from a group by user ID. The owner cannot leave (403
    /// `OWNER_MUST_TRANSFER`): transfer the group first. Returns `{ success }`.
    public func removeMember(groupId: String, userId: String) async throws -> SuccessResult {
        try await transport.request(
            method: .delete,
            path: "\(Self.path(groupId))/members/\(URLEncoding.encodeComponent(userId))"
        )
    }

    /// Removes a member from a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use removeMember(groupId:userId:). Removed by #4718.")
    public func removeMember(groupType: String, groupId: String, userId: String) async throws -> SuccessResult {
        try await transport.request(
            method: .delete,
            path: "\(Self.path(groupType, groupId))/members/\(URLEncoding.encodeComponent(userId))"
        )
    }

    /// Removes a member from a group by email address. Returns `{ success }`.
    public func removeMemberByEmail(groupId: String, email: String) async throws -> SuccessResult {
        var query = URLQuery()
        query.append("email", email)
        return try await transport.request(
            method: .delete,
            path: "\(Self.path(groupId))/members\(query.queryString)"
        )
    }

    /// Removes a member by email from a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use removeMemberByEmail(groupId:email:). Removed by #4718.")
    public func removeMemberByEmail(groupType: String, groupId: String, email: String) async throws -> SuccessResult {
        var query = URLQuery()
        query.append("email", email)
        return try await transport.request(
            method: .delete,
            path: "\(Self.path(groupType, groupId))/members\(query.queryString)"
        )
    }

    // MARK: - User Memberships

    /// Lists all group memberships for a given user, each with its `role`.
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
    public func listDocuments(groupId: String) async throws -> [GroupDocumentInfo] {
        try await transport.request(method: .get, path: "\(Self.path(groupId))/documents")
    }

    /// Lists the documents of a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use listDocuments(groupId:). Removed by #4718.")
    public func listDocuments(groupType: String, groupId: String) async throws -> [GroupDocumentInfo] {
        try await transport.request(method: .get, path: "\(Self.path(groupType, groupId))/documents")
    }

    /// Lists databases the group has access to (via `DatabaseGroupPermission`).
    /// Mirrors js-bao's `groups.listDatabases(groupId)`.
    public func listDatabases(groupId: String) async throws -> [GroupDatabaseInfo] {
        try await transport.request(method: .get, path: "\(Self.path(groupId))/databases")
    }

    /// Lists the databases of a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use listDatabases(groupId:). Removed by #4718.")
    public func listDatabases(groupType: String, groupId: String) async throws -> [GroupDatabaseInfo] {
        try await transport.request(method: .get, path: "\(Self.path(groupType, groupId))/databases")
    }

    /// Lists pending (unresolved, non-expired) invitations scoped to a group,
    /// so callers can render "members + pending" without touching the internal
    /// deferred-grants surface. Mirrors js-bao's
    /// `groups.listPendingInvitations(groupId)`.
    public func listPendingInvitations(groupId: String) async throws -> [PendingGroupInvitationEntry] {
        // The server may return a bare array or an `{ items }` envelope —
        // accept both.
        let response: ItemsEnvelope<PendingGroupInvitationEntry> = try await transport.request(
            method: .get,
            path: "\(Self.path(groupId))/pending-invitations"
        )
        return response.items
    }

    /// Lists pending invitations of a group addressed by type and ID.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use listPendingInvitations(groupId:). Removed by #4718.")
    public func listPendingInvitations(groupType: String, groupId: String) async throws -> [PendingGroupInvitationEntry] {
        let response: ItemsEnvelope<PendingGroupInvitationEntry> = try await transport.request(
            method: .get,
            path: "\(Self.path(groupType, groupId))/pending-invitations"
        )
        return response.items
    }

    // MARK: - Helpers

    /// `/groups/{groupId}`, the id percent-encoded.
    private static func path(_ groupId: String) -> String {
        "/groups/\(URLEncoding.encodeComponent(groupId))"
    }

    /// `/groups/{groupType}/{groupId}`, the typed alias route.
    private static func path(_ groupType: String, _ groupId: String) -> String {
        "/groups/\(URLEncoding.encodeComponent(groupType))/\(URLEncoding.encodeComponent(groupId))"
    }

    /// `?limit=…&cursor=…&include=…` for `listMembers`.
    private static func membersQuery(_ options: PaginationOptions?, _ include: GroupMemberInclude?) -> String {
        var query = URLQuery()
        if let options {
            if let limit = options.limit { query.append("limit", limit) }
            query.appendIfPresent("cursor", options.cursor)
        }
        if let include { query.append("include", include.rawValue) }
        return query.queryString
    }
}
