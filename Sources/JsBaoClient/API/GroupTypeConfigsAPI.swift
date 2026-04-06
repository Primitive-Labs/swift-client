import Foundation

// MARK: - GroupTypeConfigsAPI

public final class GroupTypeConfigsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Lists all group type configurations for the current app.
    public func list() async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/group-type-configs", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Retrieves the configuration for a specific group type.
    public func get(groupType: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/group-type-configs/\(groupType)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Creates a new group type configuration.
    ///
    /// - Parameter params: Configuration for the new group type. Expected keys:
    ///   - `groupType` (String): The group type identifier.
    ///   - `ruleSetId` (String, optional): Rule set to enforce.
    ///   - `autoAddCreator` (Bool, optional): Whether to auto-add the creator as a member.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/group-type-configs", params)
        return result as? [String: Any] ?? [:]
    }

    /// Updates an existing group type configuration.
    ///
    /// - Parameter groupType: The group type identifier to update.
    /// - Parameter params: Fields to update. Expected keys:
    ///   - `ruleSetId` (String or nil, optional): New rule set ID or nil to remove.
    ///   - `autoAddCreator` (Bool, optional): Whether to auto-add the creator as a member.
    public func update(groupType: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/group-type-configs/\(groupType)", params)
        return result as? [String: Any] ?? [:]
    }

    /// Deletes a group type configuration.
    public func delete(groupType: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/group-type-configs/\(groupType)", nil)
        return result as? [String: Any] ?? [:]
    }
}
