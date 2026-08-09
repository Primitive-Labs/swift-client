import Foundation

// MARK: - RuleSetsAPI

public final class RuleSetsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - CRUD

    /// Creates a new rule set with the given name, resource type, and rules.
    ///
    /// - Parameter params: Configuration for the new rule set.
    public func create(params: CreateRuleSetParams) async throws -> RuleSetInfo {
        try await transport.request(method: .post, path: "/rule-sets", body: params)
    }

    /// Lists rule sets, optionally filtered by resource type.
    ///
    /// - Parameter options: Filtering options. Pass
    ///   `ListRuleSetsOptions(resourceType:)` to return only rule sets
    ///   targeting that resource type.
    public func list(options: ListRuleSetsOptions = ListRuleSetsOptions()) async throws -> [RuleSetInfo] {
        var query = URLQuery()
        query.appendIfPresent("resourceType", options.resourceType)
        return try await transport.request(method: .get, path: "/rule-sets\(query.queryString)")
    }

    /// Retrieves a single rule set by its ID.
    public func get(ruleSetId: String) async throws -> RuleSetInfo {
        try await transport.request(method: .get, path: "/rule-sets/\(ruleSetId)")
    }

    /// Updates a rule set's name, description, or rules.
    public func update(ruleSetId: String, params: UpdateRuleSetParams) async throws -> RuleSetInfo {
        try await transport.request(method: .patch, path: "/rule-sets/\(ruleSetId)", body: params)
    }

    /// Deletes a rule set by its ID.
    public func delete(ruleSetId: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: "/rule-sets/\(ruleSetId)")
    }

    // MARK: - Schema

    /// Retrieves the rule set schema describing available resource types.
    public func schema() async throws -> RuleSetSchema {
        try await transport.request(method: .get, path: "/rule-sets/schema")
    }

    // MARK: - Test & Debug

    /// Evaluates a rule set against a simulated request and returns the access decision.
    ///
    /// - Parameter ruleSetId: The rule set to test.
    /// - Parameter data: Simulated request parameters.
    public func test(ruleSetId: String, data: TestRuleSetParams) async throws -> RuleSetTestResult {
        try await transport.request(method: .post, path: "/rule-sets/\(ruleSetId)/test", body: data)
    }

    /// Debugs rule evaluation for a real user, returning the full evaluation trace and context.
    ///
    /// - Parameter data: Parameters identifying the user, group, and operation to debug.
    public func debug(data: DebugRuleSetParams) async throws -> RuleSetDebugResult {
        try await transport.request(method: .post, path: "/rule-sets/debug", body: data)
    }
}
