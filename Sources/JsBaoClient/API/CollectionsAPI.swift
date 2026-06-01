import Foundation

// MARK: - CollectionsAPI

public final class CollectionsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - CRUD

    /// Create a new collection.
    ///
    /// - Parameter params: dict keys:
    ///   - `name` (String, required) — display name. Older callers may
    ///     pass `title` (alias); newer servers accept either.
    ///   - `description` (String, optional).
    ///   - `metadata` (`[String: Any]`, optional) — opaque app-defined blob.
    ///
    /// Response: `{ collectionId, name, … }`.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/collections", params)
        return result as? [String: Any] ?? [:]
    }

    /// List collections the user has access to.
    public func list(options: PaginationOptions? = nil) async throws -> [String: Any] {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/collections\(qs)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Get collection info by ID.
    public func get(collectionId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/collections/\(collectionId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Update a collection's name or description.
    public func update(collectionId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/collections/\(collectionId)", params)
        return result as? [String: Any] ?? [:]
    }

    /// Delete a collection.
    public func delete(collectionId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Documents

    /// Add a document to a collection.
    public func addDocument(collectionId: String, documentId: String) async throws -> [String: Any] {
        let body: [String: Any] = ["documentId": documentId]
        let result = try await makeRequest("POST", "/collections/\(collectionId)/documents", body)
        return result as? [String: Any] ?? [:]
    }

    /// Remove a document from a collection.
    public func removeDocument(collectionId: String, documentId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/documents/\(documentId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// List all documents in a collection.
    public func listDocuments(collectionId: String, options: PaginationOptions? = nil) async throws -> [String: Any] {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/collections/\(collectionId)/documents\(qs)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// List collections that contain a specific document.
    public func listCollectionsForDocument(documentId: String, options: PaginationOptions? = nil) async throws -> [String: Any] {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/documents/\(documentId)/collections\(qs)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Access

    /// Get the current user's access info for a collection.
    public func getAccess(collectionId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/collections/\(collectionId)/access", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Grant a group permission to a collection.
    public func grantGroupPermission(collectionId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/collections/\(collectionId)/group-permissions", params)
        return result as? [String: Any] ?? [:]
    }

    /// Revoke a group's permission from a collection.
    public func revokeGroupPermission(collectionId: String, groupType: String, groupId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/group-permissions/\(groupType)/\(groupId)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Members

    /// Add a member to a collection.
    ///
    /// - Parameter params: exactly one of `userId` or `email` is required.
    ///   - `userId` (String) — adds a live member directly.
    ///   - `email` (String) — if the email maps to an app user, adds
    ///     them directly; otherwise creates a `DeferredGroupAdd` row
    ///     (groupType `_col-reader` or `_col-writer`) that resolves on
    ///     signup. Mirrors `documents.updatePermissions`'s deferred
    ///     flow (issue #671).
    ///   - `permission` (String, required) — `"reader"` or `"read-write"`.
    ///   - `sendEmail` (Bool, optional, email path only).
    ///
    /// Returns `{ status, userId?, permission, addedAt?, addedBy?,
    /// deferredId?, invitationId?, inviteToken?, expiresAt? }`. Status
    /// ∈ `"added" | "already_member" | "pending_signup"`.
    public func addMember(collectionId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/collections/\(collectionId)/members", params)
        return result as? [String: Any] ?? [:]
    }

    /// Remove a member from a collection.
    public func removeMember(collectionId: String, userId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/members/\(userId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Admin-scoped listing of every collection in the app. Mirrors
    /// js-bao's `collections.listAll(options)`. Cursor-paginated;
    /// response shape: `{ "items": [...], "cursor"?: String }`.
    public func listAll(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> [String: Any] {
        var qs: [String] = []
        if let limit { qs.append("limit=\(limit)") }
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        let path = qs.isEmpty
            ? "/admin/collections"
            : "/admin/collections?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        return result as? [String: Any] ?? [:]
    }

    /// List pending invitations attached to a collection. Mirrors
    /// js-bao's `collections.listPendingInvitations(collectionId)`.
    public func listPendingInvitations(
        collectionId: String
    ) async throws -> [[String: Any]] {
        let result = try await makeRequest(
            "GET",
            "/collections/\(collectionId)/pending-invitations",
            nil
        )
        if let dict = result as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            return items
        }
        return result as? [[String: Any]] ?? []
    }
}
