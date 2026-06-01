import Foundation

// MARK: - CollectionTypeConfigsAPI

/// Mirrors the JS `CollectionTypeConfigsAPI` — configure which TOML
/// model types are valid for app-defined collections. Same five-method
/// CRUD shape as `GroupTypeConfigsAPI`, against
/// `/collection-type-configs`.
public final class CollectionTypeConfigsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Lists all collection type configurations for the current app.
    public func list() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/collection-type-configs", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Retrieves the configuration for a specific collection type.
    public func get(collectionType: String) async throws -> [String: Any] {
        let escaped = collectionType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? collectionType
        let result = try await makeRequest(
            "GET", "/collection-type-configs/\(escaped)", nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Creates a new collection type configuration.
    ///
    /// - Parameter params: Expected keys:
    ///   - `collectionType` (String): The type identifier.
    ///   - `ruleSetId` (String, optional): Rule set to enforce. Must have
    ///     `resourceType: "collection"`.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/collection-type-configs", params)
        return result as? [String: Any] ?? [:]
    }

    /// Updates an existing collection type configuration's rule set.
    ///
    /// - Parameter params: Expected keys:
    ///   - `ruleSetId` (String or NSNull, optional): New rule set ID, or
    ///     NSNull to remove.
    public func update(
        collectionType: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let escaped = collectionType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? collectionType
        let result = try await makeRequest(
            "PATCH", "/collection-type-configs/\(escaped)", params
        )
        return result as? [String: Any] ?? [:]
    }

    /// Deletes a collection type configuration.
    public func delete(collectionType: String) async throws -> [String: Any] {
        let escaped = collectionType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? collectionType
        let result = try await makeRequest(
            "DELETE", "/collection-type-configs/\(escaped)", nil
        )
        return result as? [String: Any] ?? [:]
    }
}
