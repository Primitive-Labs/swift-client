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
    public func list() async throws -> [DatabaseTypeConfigInfo] {
        let result = try await makeRequest("GET", "/databases/types", nil)
        return try JSONCoding.decode([DatabaseTypeConfigInfo].self, from: result)
    }

    /// Retrieves the configuration for a specific database type.
    public func get(databaseType: String) async throws -> DatabaseTypeConfigInfo {
        let escaped = databaseType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? databaseType
        let result = try await makeRequest("GET", "/databases/types/\(escaped)", nil)
        return try JSONCoding.decode(DatabaseTypeConfigInfo.self, from: result)
    }

    /// Creates a new database type configuration.
    public func create(params: CreateDatabaseTypeConfigParams) async throws -> DatabaseTypeConfigInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/databases/types", body)
        return try JSONCoding.decode(DatabaseTypeConfigInfo.self, from: result)
    }

    /// Updates an existing database type configuration. Omit a field on
    /// `params` to leave it unchanged; pass `.clear` to null it out.
    public func update(
        databaseType: String,
        params: UpdateDatabaseTypeConfigParams
    ) async throws -> DatabaseTypeConfigInfo {
        let escaped = databaseType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? databaseType
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest(
            "PATCH", "/databases/types/\(escaped)", body
        )
        return try JSONCoding.decode(DatabaseTypeConfigInfo.self, from: result)
    }

    /// Deletes a database type configuration. Resolves to `{ success }`.
    @discardableResult
    public func delete(databaseType: String) async throws -> SuccessResult {
        let escaped = databaseType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? databaseType
        let result = try await makeRequest(
            "DELETE", "/databases/types/\(escaped)", nil
        )
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }
}
