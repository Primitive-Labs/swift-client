import Foundation

// MARK: - RuleSetsAPI

public final class RuleSetsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - CRUD

    /// Creates a new rule set with the given name, resource type, and rules.
    ///
    /// - Parameter params: Configuration for the new rule set.
    public func create(params: CreateRuleSetParams) async throws -> RuleSetInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/rule-sets", body)
        return try JSONCoding.decode(RuleSetInfo.self, from: result)
    }

    /// Lists rule sets, optionally filtered by resource type.
    ///
    /// - Parameter options: Filtering options. Pass
    ///   `ListRuleSetsOptions(resourceType:)` to return only rule sets
    ///   targeting that resource type.
    public func list(options: ListRuleSetsOptions = ListRuleSetsOptions()) async throws -> [RuleSetInfo] {
        var query = ""
        if let resourceType = options.resourceType {
            let encoded = resourceType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resourceType
            query = "?resourceType=\(encoded)"
        }
        let result = try await makeRequest("GET", "/rule-sets\(query)", nil)
        return try JSONCoding.decode([RuleSetInfo].self, from: result)
    }

    /// Retrieves a single rule set by its ID.
    public func get(ruleSetId: String) async throws -> RuleSetInfo {
        let result = try await makeRequest("GET", "/rule-sets/\(ruleSetId)", nil)
        return try JSONCoding.decode(RuleSetInfo.self, from: result)
    }

    /// Updates a rule set's name, description, or rules.
    public func update(ruleSetId: String, params: UpdateRuleSetParams) async throws -> RuleSetInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/rule-sets/\(ruleSetId)", body)
        return try JSONCoding.decode(RuleSetInfo.self, from: result)
    }

    /// Deletes a rule set by its ID.
    public func delete(ruleSetId: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/rule-sets/\(ruleSetId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    // MARK: - Schema

    /// Retrieves the rule set schema describing available resource types.
    public func schema() async throws -> RuleSetSchema {
        let result = try await makeRequest("GET", "/rule-sets/schema", nil)
        return try JSONCoding.decode(RuleSetSchema.self, from: result)
    }

    // MARK: - Test & Debug

    /// Evaluates a rule set against a simulated request and returns the access decision.
    ///
    /// - Parameter ruleSetId: The rule set to test.
    /// - Parameter data: Simulated request parameters.
    public func test(ruleSetId: String, data: TestRuleSetParams) async throws -> RuleSetTestResult {
        let body = try JSONCoding.jsonObject(from: data)
        let result = try await makeRequest("POST", "/rule-sets/\(ruleSetId)/test", body)
        return try JSONCoding.decode(RuleSetTestResult.self, from: result)
    }

    /// Debugs rule evaluation for a real user, returning the full evaluation trace and context.
    ///
    /// - Parameter data: Parameters identifying the user, group, and operation to debug.
    public func debug(data: DebugRuleSetParams) async throws -> RuleSetDebugResult {
        let body = try JSONCoding.jsonObject(from: data)
        let result = try await makeRequest("POST", "/rule-sets/debug", body)
        return try JSONCoding.decode(RuleSetDebugResult.self, from: result)
    }
}
