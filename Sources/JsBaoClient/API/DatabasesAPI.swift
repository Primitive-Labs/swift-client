import Foundation

// MARK: - DatabasesAPI

public final class DatabasesAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - CRUD

    /// Create a new database.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/databases", params)
        return result as? [String: Any] ?? [:]
    }

    /// List all databases owned by the current user.
    public func list() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/databases", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Get database info by ID.
    public func get(databaseId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/databases/\(databaseId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Update a database's title or type.
    public func update(databaseId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)", params)
        return result as? [String: Any] ?? [:]
    }

    /// Update a database's custom metadata.
    public func updateMetadata(databaseId: String, metadata: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)/metadata", metadata)
        return result as? [String: Any] ?? [:]
    }

    /// Delete a database.
    public func delete(databaseId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Permissions

    /// List all permission entries for a database.
    public func listPermissions(databaseId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/permissions", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Grant a user permission to access a database.
    public func grantPermission(databaseId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PUT", "/databases/\(databaseId)/permissions", params)
        return result as? [String: Any] ?? [:]
    }

    /// Revoke a user's permission to a database.
    public func revokePermission(databaseId: String, userId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)/permissions/\(userId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Transfer database ownership to another user.
    public func transferOwnership(databaseId: String, newOwnerId: String) async throws -> [String: Any] {
        let body: [String: Any] = ["newOwnerId": newOwnerId]
        let result = try await makeRequest("POST", "/databases/\(databaseId)/permissions/transfer", body)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Operations

    /// Create a new operation (query or mutation) on a database.
    public func createOperation(databaseId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/databases/\(databaseId)/operations", params)
        return result as? [String: Any] ?? [:]
    }

    /// List all operations registered on a database.
    public func listOperations(databaseId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/operations", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Get a single operation by name.
    public func getOperation(databaseId: String, name: String) async throws -> [String: Any] {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let result = try await makeRequest("GET", "/databases/\(databaseId)/operations/\(encodedName)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Update an existing operation's definition or access level.
    public func updateOperation(databaseId: String, name: String, params: [String: Any]) async throws -> [String: Any] {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let result = try await makeRequest("PATCH", "/databases/\(databaseId)/operations/\(encodedName)", params)
        return result as? [String: Any] ?? [:]
    }

    /// Delete an operation from a database.
    public func deleteOperation(databaseId: String, name: String) async throws -> [String: Any] {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let result = try await makeRequest("DELETE", "/databases/\(databaseId)/operations/\(encodedName)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Execute a registered operation by name, with optional parameters and pagination.
    public func executeOperation(databaseId: String, name: String, options: [String: Any]? = nil) async throws -> Any {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let body = options ?? [:]
        let result = try await makeRequest("POST", "/databases/\(databaseId)/operations/\(encodedName)/execute", body)
        return result
    }

    // MARK: - Bulk Import

    /// Import a batch of records using a named mutation operation.
    public func importBulk(databaseId: String, operationName: String, batch: [[String: Any]]) async throws -> [String: Any] {
        let encodedName = operationName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? operationName
        let body: [String: Any] = ["batch": batch]
        let result = try await makeRequest("POST", "/databases/\(databaseId)/operations/\(encodedName)/import-bulk", body)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Schema

    /// Get the field schema for a model in a database.
    public func describe(databaseId: String, modelName: String) async throws -> [[String: Any]] {
        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelName
        let result = try await makeRequest("GET", "/databases/\(databaseId)/records/describe?modelName=\(encodedModel)", nil)
        if let dict = result as? [String: Any], let fields = dict["fields"] as? [[String: Any]] {
            return fields
        }
        return result as? [[String: Any]] ?? []
    }
}
