import Foundation

// MARK: - CollectionsAPI

public final class CollectionsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - CRUD

    /// Create a new collection.
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
    public func addMember(collectionId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/collections/\(collectionId)/members", params)
        return result as? [String: Any] ?? [:]
    }

    /// Remove a member from a collection.
    public func removeMember(collectionId: String, userId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/members/\(userId)", nil)
        return result as? [String: Any] ?? [:]
    }
}
