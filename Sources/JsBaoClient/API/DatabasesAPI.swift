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
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.updateMetadata`.
    @available(*, deprecated, message: "Use databases.updateCelContext(databaseId:celContext:) instead.")
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
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.grantPermission`.
    @available(*, deprecated, message: "Use databases.addManager(databaseId:params:) instead.")
    public func grantPermission(databaseId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PUT", "/databases/\(databaseId)/permissions", params)
        return result as? [String: Any] ?? [:]
    }

    /// Revoke a user's permission to a database.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.revokePermission`.
    @available(*, deprecated, message: "Use databases.removeManager(databaseId:userId:) instead.")
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
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `databases.importBulk`.
    @available(*, deprecated, message: "Use databases.executeBatch(databaseId:operations:) instead.")
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

    // MARK: - CEL Context

    /// Read a database's CEL context dict. Values are referenced from
    /// CEL access rules as `database.celContext.<key>` and from filter
    /// JSON as `$database.celContext.<key>`.
    ///
    /// Response payload includes the same dict under both `metadata`
    /// (legacy wire name) and `celContext` (current name).
    public func getCelContext(databaseId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/databases/\(databaseId)/metadata", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Merge new key-value pairs into a database's CEL context dict.
    public func updateCelContext(
        databaseId: String,
        celContext: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await makeRequest(
            "PATCH", "/databases/\(databaseId)/metadata", celContext
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Managers

    /// List a database's managers (permissions entries with manager grants).
    /// Convenience wrapper over `listPermissions` that filters to the
    /// `manager` rows. js-bao counterpart: `listManagers(databaseId)`.
    public func listManagers(databaseId: String) async throws -> [[String: Any]] {
        let perms = try await listPermissions(databaseId: databaseId)
        return perms.filter { ($0["permission"] as? String) == "manager" }
    }

    /// Add a user as a manager of a database.
    public func addManager(
        databaseId: String,
        userId: String
    ) async throws -> [String: Any] {
        let body: [String: Any] = [
            "userId": userId,
            "permission": "manager",
        ]
        let result = try await makeRequest(
            "PUT", "/databases/\(databaseId)/permissions", body
        )
        return result as? [String: Any] ?? [:]
    }

    /// Remove a manager from a database.
    public func removeManager(
        databaseId: String,
        userId: String
    ) async throws -> [String: Any] {
        let escapedId = userId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? userId
        let result = try await makeRequest(
            "DELETE", "/databases/\(databaseId)/permissions/\(escapedId)", nil
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Group Permissions

    /// List the group permissions configured on a database.
    /// Platform-managed groups (whose `groupType` starts with `_`) are
    /// excluded unless `includeSystem: true`.
    public func listGroupPermissions(
        databaseId: String,
        includeSystem: Bool = false
    ) async throws -> [[String: Any]] {
        let qs = includeSystem ? "?includeSystem=true" : ""
        let result = try await makeRequest(
            "GET", "/databases/\(databaseId)/group-permissions\(qs)", nil
        )
        return result as? [[String: Any]] ?? []
    }

    /// Grant a group permission on a database. Members of the
    /// specified group gain `params["permission"]` on the database.
    ///
    /// - Parameter params: Expected keys:
    ///   - `groupType` (String, required)
    ///   - `groupId` (String, required)
    ///   - `permission` (String, required)
    public func grantGroupPermission(
        databaseId: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await makeRequest(
            "POST", "/databases/\(databaseId)/group-permissions", params
        )
        return result as? [String: Any] ?? [:]
    }

    /// Revoke a group's permission on a database.
    public func revokeGroupPermission(
        databaseId: String,
        groupType: String,
        groupId: String
    ) async throws -> [String: Any] {
        let gType = groupType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? groupType
        let gId = groupId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? groupId
        let result = try await makeRequest(
            "DELETE",
            "/databases/\(databaseId)/group-permissions/\(gType)/\(gId)",
            nil
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Batch operations

    /// Execute a batch of records via a named mutation operation.
    /// Returns `{ "imported": Int, "failed": Int }`.
    ///
    /// - Parameter batch: Each element should be `["params": [String: Any]]`.
    public func executeBatch(
        databaseId: String,
        operationName: String,
        batch: [[String: Any]]
    ) async throws -> [String: Any] {
        let encodedName = operationName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? operationName
        let body: [String: Any] = ["batch": batch]
        let result = try await makeRequest(
            "POST",
            "/databases/\(databaseId)/operations/\(encodedName)/batch",
            body
        )
        return result as? [String: Any] ?? [:]
    }

    /// Import a parsed list of row dicts into a database via a named
    /// mutation operation. Thin wrapper over `executeBatch` that wraps
    /// each row as `{params: row}` and batches in groups of
    /// `batchSize` records (defaults to 5000 — matches js-bao).
    ///
    /// - Note: js-bao's `importCsv` also handles raw CSV parsing,
    ///   schema-aware type coercion, and progress callbacks. Those
    ///   higher-level conveniences are deferred to a v1.1 polish; the
    ///   Swift surface starts with pre-parsed rows for simplicity. To
    ///   import a CSV string, parse it with a third-party parser
    ///   (e.g. `CodableCSV`) before calling.
    public func importRows(
        databaseId: String,
        operationName: String = "save",
        rows: [[String: Any]],
        batchSize: Int = 5000
    ) async throws -> [String: Any] {
        guard !rows.isEmpty else {
            return ["imported": 0, "failed": 0]
        }
        var imported = 0
        var failed = 0
        var i = 0
        while i < rows.count {
            let end = min(i + batchSize, rows.count)
            let slice = rows[i..<end].map { ["params": $0] }
            let result = try await executeBatch(
                databaseId: databaseId,
                operationName: operationName,
                batch: Array(slice)
            )
            imported += result["imported"] as? Int ?? 0
            failed += result["failed"] as? Int ?? 0
            i = end
        }
        return ["imported": imported, "failed": failed]
    }
}
