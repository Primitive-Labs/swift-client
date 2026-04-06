import Foundation

// MARK: - RuleSetsAPI

public final class RuleSetsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - CRUD

    /// Creates a new rule set.
    ///
    /// - Parameter params: Configuration for the new rule set. Expected keys:
    ///   - `name` (String): Display name.
    ///   - `resourceType` (String): The type of resource these rules apply to.
    ///   - `rules` (Dictionary): Map of model names to their rule definitions.
    ///   - `description` (String, optional): Human-readable description.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/rule-sets", params)
        return result as? [String: Any] ?? [:]
    }

    /// Lists rule sets, optionally filtered by resource type.
    ///
    /// - Parameter resourceType: If provided, only rule sets targeting this resource type are returned.
    public func list(resourceType: String? = nil) async throws -> [[String: Any]] {
        var query = ""
        if let resourceType = resourceType {
            let encoded = resourceType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resourceType
            query = "?resourceType=\(encoded)"
        }
        let result = try await makeRequest("GET", "/rule-sets\(query)", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Retrieves a single rule set by its ID.
    public func get(ruleSetId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/rule-sets/\(ruleSetId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Updates a rule set's name, description, or rules.
    public func update(ruleSetId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PATCH", "/rule-sets/\(ruleSetId)", params)
        return result as? [String: Any] ?? [:]
    }

    /// Deletes a rule set by its ID.
    public func delete(ruleSetId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/rule-sets/\(ruleSetId)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Schema

    /// Retrieves the rule set schema describing available resource types.
    public func schema() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/rule-sets/schema", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Test & Debug

    /// Evaluates a rule set against a simulated request and returns the access decision.
    ///
    /// - Parameter ruleSetId: The rule set to test.
    /// - Parameter data: Simulated request parameters. Expected keys:
    ///   - `category` (String): The resource category being accessed.
    ///   - `operation` (String): The operation being performed.
    ///   - `user` (Dictionary): The simulated user with `userId` and optional `role`.
    ///   - `memberships` (Array, optional): Group memberships to simulate.
    ///   - `group` (Dictionary, optional): Group context for evaluation.
    ///   - `target` (Dictionary, optional): The target user of the operation.
    ///   - `record` (Dictionary, optional): Record data for field-level rules.
    public func test(ruleSetId: String, data: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/rule-sets/\(ruleSetId)/test", data)
        return result as? [String: Any] ?? [:]
    }

    /// Debugs rule evaluation for a real user, returning the full evaluation trace and context.
    ///
    /// - Parameter data: Debug parameters. Expected keys:
    ///   - `userId` (String): The real user ID to evaluate rules against.
    ///   - `groupType` (String): The group type whose rule set should be evaluated.
    ///   - `category` (String): The resource category being accessed.
    ///   - `operation` (String): The operation being performed.
    ///   - `groupId` (String, optional): Specific group context.
    ///   - `targetUserId` (String, optional): Target user of the operation.
    public func debug(data: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/rule-sets/debug", data)
        return result as? [String: Any] ?? [:]
    }
}
