import Foundation

// MARK: - DatabaseTypeConfigsAPI

/// Mirrors the JS `DatabaseTypeConfigsAPI` — schema-less database type
/// configs that bind a rule set + CEL trigger rules + metadata-access
/// CEL gate to a `databaseType` tag. Five-method CRUD against
/// `/databases/types`.
public final class DatabaseTypeConfigsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Lists all database type configurations for the current app.
    public func list() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/databases/types", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Retrieves the configuration for a specific database type.
    public func get(databaseType: String) async throws -> [String: Any] {
        let escaped = databaseType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? databaseType
        let result = try await makeRequest("GET", "/databases/types/\(escaped)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Creates a new database type configuration.
    ///
    /// - Parameter params: Expected keys:
    ///   - `databaseType` (String): The type identifier (e.g. `"userDB"`).
    ///   - `ruleSetId` (String, optional): Rule set to enforce. Must have
    ///     `resourceType: "database_type"`.
    ///   - `triggers` ([String: Any], optional): Trigger rules keyed by
    ///     model name. Server validates the structure.
    ///   - `metadataAccess` (String, optional): CEL expression gating
    ///     metadata access.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/databases/types", params)
        return result as? [String: Any] ?? [:]
    }

    /// Updates an existing database type configuration.
    ///
    /// - Parameter params: Fields to update. Same shape as `create`,
    ///   except each key may be `NSNull` to clear the current value.
    public func update(
        databaseType: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let escaped = databaseType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? databaseType
        let result = try await makeRequest(
            "PATCH", "/databases/types/\(escaped)", params
        )
        return result as? [String: Any] ?? [:]
    }

    /// Deletes a database type configuration.
    public func delete(databaseType: String) async throws -> [String: Any] {
        let escaped = databaseType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? databaseType
        let result = try await makeRequest(
            "DELETE", "/databases/types/\(escaped)", nil
        )
        return result as? [String: Any] ?? [:]
    }
}
