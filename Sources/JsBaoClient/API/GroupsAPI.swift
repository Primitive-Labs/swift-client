import Foundation

// MARK: - GroupsAPI

public final class GroupsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - Groups CRUD

    /// Creates a new group with the specified type, ID, and name.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/groups", params)
        return result as? [String: Any] ?? [:]
    }

    /// Lists groups, optionally filtered by group type.
    ///
    /// - Parameter options: Filtering and pagination options. Supported keys:
    ///   - `type` (String, optional): Filter by group type.
    ///   - `limit` (Int, optional): Maximum number of groups per page.
    ///   - `cursor` (String, optional): Pagination cursor.
    public func list(options: [String: Any]? = nil) async throws -> [String: Any] {
        var queryParts: [String] = []
        if let type = options?["type"] as? String {
            queryParts.append("type=\(type.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? type)")
        }
        if let limit = options?["limit"] as? Int {
            queryParts.append("limit=\(limit)")
        }
        if let cursor = options?["cursor"] as? String {
            queryParts.append("cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)")
        }
        let query = queryParts.isEmpty ? "" : "?\(queryParts.joined(separator: "&"))"
        let result = try await makeRequest("GET", "/groups\(query)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Retrieves a single group by its type and ID.
    public func get(groupType: String, groupId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/groups/\(groupType)/\(groupId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Updates a group's name or description.
    public func update(groupType: String, groupId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/groups/\(groupType)/\(groupId)", params)
        return result as? [String: Any] ?? [:]
    }

    /// Deletes a group by its type and ID.
    public func delete(groupType: String, groupId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/groups/\(groupType)/\(groupId)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Members

    /// Lists members of a group with optional pagination.
    public func listMembers(groupType: String, groupId: String, options: PaginationOptions? = nil) async throws -> [String: Any] {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/groups/\(groupType)/\(groupId)/members\(qs)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Adds a user to a group by user ID or email address.
    ///
    /// - Parameter params: Dictionary with either `userId` (String) or `email` (String).
    public func addMember(groupType: String, groupId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/groups/\(groupType)/\(groupId)/members", params)
        return result as? [String: Any] ?? [:]
    }

    /// Removes a member from a group by user ID.
    public func removeMember(groupType: String, groupId: String, userId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/groups/\(groupType)/\(groupId)/members/\(userId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Removes a member from a group by email address.
    public func removeMemberByEmail(groupType: String, groupId: String, email: String) async throws -> [String: Any] {
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let result = try await makeRequest("DELETE", "/groups/\(groupType)/\(groupId)/members?email=\(encodedEmail)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - User Memberships

    /// Lists all group memberships for a given user.
    public func listUserMemberships(userId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/users/\(userId)/memberships", nil)
        return result as? [[String: Any]] ?? []
    }

    // MARK: - Group Documents

    /// Lists all documents accessible to a group.
    public func listDocuments(groupType: String, groupId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/groups/\(groupType)/\(groupId)/documents", nil)
        return result as? [[String: Any]] ?? []
    }
}
