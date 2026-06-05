import Foundation

// MARK: - GroupsAPI

public final class GroupsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - Groups CRUD

    /// Creates a new group with the specified type, ID, and name.
    public func create(params: CreateGroupParams) async throws -> GroupInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/groups", body)
        return try JSONCoding.decode(GroupInfo.self, from: result)
    }

    /// Lists groups, optionally filtered by group type, with cursor
    /// pagination. Pass `includeSystem: true` to surface platform-managed
    /// internal `_`-prefixed groups (excluded by default).
    public func list(options: ListGroupsOptions? = nil) async throws -> PaginatedResult<GroupInfo> {
        var queryParts: [String] = []
        if let type = options?.type {
            queryParts.append("type=\(type.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? type)")
        }
        if let limit = options?.limit {
            queryParts.append("limit=\(limit)")
        }
        if let cursor = options?.cursor {
            queryParts.append("cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)")
        }
        if options?.includeSystem == true {
            queryParts.append("includeSystem=true")
        }
        let query = queryParts.isEmpty ? "" : "?\(queryParts.joined(separator: "&"))"
        let result = try await makeRequest("GET", "/groups\(query)", nil)
        return try JSONCoding.decode(PaginatedResult<GroupInfo>.self, from: result)
    }

    /// Retrieves a single group by its type and ID.
    public func get(groupType: String, groupId: String) async throws -> GroupInfo {
        let result = try await makeRequest("GET", "/groups/\(groupType)/\(groupId)", nil)
        return try JSONCoding.decode(GroupInfo.self, from: result)
    }

    /// Updates a group's name or description.
    public func update(groupType: String, groupId: String, params: UpdateGroupParams) async throws -> GroupInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/groups/\(groupType)/\(groupId)", body)
        return try JSONCoding.decode(GroupInfo.self, from: result)
    }

    /// Deletes a group by its type and ID. Returns `{ success }`.
    public func delete(groupType: String, groupId: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/groups/\(groupType)/\(groupId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    // MARK: - Members

    /// Lists members of a group with optional pagination. Returns a typed
    /// `PaginatedResult<GroupMemberInfo>` (`{ items, cursor? }`).
    public func listMembers(groupType: String, groupId: String, options: PaginationOptions? = nil) async throws -> PaginatedResult<GroupMemberInfo> {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/groups/\(groupType)/\(groupId)/members\(qs)", nil)
        return try JSONCoding.decode(PaginatedResult<GroupMemberInfo>.self, from: result)
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
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/groups/\(groupType)/\(groupId)/members", body)
        return try JSONCoding.decode(GroupAddMemberResult.self, from: result)
    }

    /// Removes a member from a group by user ID. Returns `{ success }`.
    public func removeMember(groupType: String, groupId: String, userId: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/groups/\(groupType)/\(groupId)/members/\(userId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    /// Removes a member from a group by email address. Returns `{ success }`.
    public func removeMemberByEmail(groupType: String, groupId: String, email: String) async throws -> SuccessResult {
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let result = try await makeRequest("DELETE", "/groups/\(groupType)/\(groupId)/members?email=\(encodedEmail)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    // MARK: - User Memberships

    /// Lists all group memberships for a given user.
    ///
    /// - Parameter groupType: optional server-side filter to a single group
    ///   type. Mirrors js-bao's `groups.listUserMemberships(userId, { groupType })`
    ///   (#960).
    public func listUserMemberships(userId: String, groupType: String? = nil) async throws -> [GroupMembershipInfo] {
        var path = "/users/\(userId)/memberships"
        if let groupType,
           let escaped = groupType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            // Server reads `?type=` (groups-controller.ts:1392); JS sends the same.
            path += "?type=\(escaped)"
        }
        let result = try await makeRequest("GET", path, nil)
        return try JSONCoding.decode([GroupMembershipInfo].self, from: result)
    }

    // MARK: - Group Documents

    /// Lists all documents accessible to a group, with the granted permission.
    public func listDocuments(groupType: String, groupId: String) async throws -> [GroupDocumentInfo] {
        let result = try await makeRequest("GET", "/groups/\(groupType)/\(groupId)/documents", nil)
        return try JSONCoding.decode([GroupDocumentInfo].self, from: result)
    }

    /// Lists databases the group has access to (via `DatabaseGroupPermission`).
    /// Mirrors js-bao's `groups.listDatabases(groupType, groupId)`.
    public func listDatabases(
        groupType: String, groupId: String
    ) async throws -> [GroupDatabaseInfo] {
        let escapedType = groupType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? groupType
        let escapedId = groupId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? groupId
        let result = try await makeRequest(
            "GET", "/groups/\(escapedType)/\(escapedId)/databases", nil
        )
        return try JSONCoding.decode([GroupDatabaseInfo].self, from: result)
    }

    /// Lists pending (unresolved, non-expired) invitations scoped to a group,
    /// so callers can render "members + pending" without touching the internal
    /// deferred-grants surface. Mirrors js-bao's
    /// `groups.listPendingInvitations(groupType, groupId)`.
    public func listPendingInvitations(
        groupType: String, groupId: String
    ) async throws -> [PendingGroupInvitationEntry] {
        let escapedType = groupType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? groupType
        let escapedId = groupId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? groupId
        let result = try await makeRequest(
            "GET",
            "/groups/\(escapedType)/\(escapedId)/pending-invitations",
            nil
        )
        // The server may return a bare array or an `{ items }` envelope —
        // accept both.
        if let dict = result as? [String: Any], let items = dict["items"] {
            return try JSONCoding.decode([PendingGroupInvitationEntry].self, from: items)
        }
        return try JSONCoding.decode([PendingGroupInvitationEntry].self, from: result)
    }
}
