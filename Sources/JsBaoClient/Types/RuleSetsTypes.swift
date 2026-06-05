import Foundation

// MARK: - Rule sets: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/ruleSetsApi.d.ts`) field-for-field. Timestamps stay as ISO-8601
// `String`s — exactly what JS exposes. Fields the platform does not
// introspect (CEL evaluation `context`, simulated `record` data, the
// untyped schema `resourceTypes` map, and trace `args`/`result`) are typed
// as `JSONValue` (see JSONValue.swift), mirroring JS's `any` / `Record<string, any>`.

// MARK: Rule grammar

/// A single CEL trigger definition. Mirrors JS `TriggerDefInfo`.
public struct TriggerDefInfo: Codable, Sendable, Equatable {
    /// The lifecycle hook this trigger fires on.
    public enum On: String, Codable, Sendable {
        case create
        case update
        case save
    }

    public var on: On
    /// Optional CEL guard expression; the trigger only applies when it evaluates truthy.
    public var when: String?
    /// Map of field name → CEL expression to assign.
    public var set: [String: String]

    public init(on: On, when: String? = nil, set: [String: String]) {
        self.on = on
        self.when = when
        self.set = set
    }
}

/// The rule definitions for a single model. Mirrors JS `ModelRulesInfo`.
public struct ModelRulesInfo: Codable, Sendable, Equatable {
    public var triggers: [TriggerDefInfo]?

    public init(triggers: [TriggerDefInfo]? = nil) {
        self.triggers = triggers
    }
}

// MARK: Rule set metadata

/// A rule set's full metadata. Mirrors JS `RuleSetInfo`.
public struct RuleSetInfo: Decodable, Sendable, Equatable {
    public let ruleSetId: String
    public let appId: String
    public let name: String
    /// Nullable on the wire — `description: string | null`.
    public let description: String?
    public let resourceType: String
    /// Map of model name → that model's rule definitions.
    public let rules: [String: ModelRulesInfo]
    public let version: Int
    public let createdAt: String
    public let modifiedAt: String
    public let createdBy: String
}

/// The rule set schema describing available resource types. Mirrors JS
/// `RuleSetSchema` — `resourceTypes` is an opaque `Record<string, any>`.
public struct RuleSetSchema: Decodable, Sendable, Equatable {
    public let resourceTypes: [String: JSONValue]
}

// MARK: Create / update / list inputs

/// Parameters for `create`. Mirrors JS `CreateRuleSetParams`.
public struct CreateRuleSetParams: Encodable, Sendable {
    /// Display name for the rule set.
    public var name: String
    /// The type of resource these rules apply to (e.g. `"document"`, `"group"`).
    public var resourceType: String
    /// Map of model names to their rule definitions.
    public var rules: [String: ModelRulesInfo]
    /// Optional human-readable description of the rule set's purpose.
    public var description: String?

    public init(
        name: String,
        resourceType: String,
        rules: [String: ModelRulesInfo],
        description: String? = nil
    ) {
        self.name = name
        self.resourceType = resourceType
        self.rules = rules
        self.description = description
    }
}

/// Parameters for `update`. Mirrors JS `UpdateRuleSetParams` — every field is
/// optional; omit to leave unchanged.
public struct UpdateRuleSetParams: Encodable, Sendable {
    /// New display name for the rule set.
    public var name: String?
    /// New description for the rule set.
    public var description: String?
    /// Replacement rule definitions, keyed by model name.
    public var rules: [String: ModelRulesInfo]?

    public init(
        name: String? = nil,
        description: String? = nil,
        rules: [String: ModelRulesInfo]? = nil
    ) {
        self.name = name
        self.description = description
        self.rules = rules
    }
}

/// Options for `list`. Mirrors JS `ListRuleSetsOptions`.
public struct ListRuleSetsOptions: Encodable, Sendable {
    /// If provided, only rule sets targeting this resource type are returned.
    public var resourceType: String?

    public init(resourceType: String? = nil) {
        self.resourceType = resourceType
    }
}

// MARK: Test / debug inputs

/// A simulated user for `test`.
public struct TestRuleSetUser: Encodable, Sendable {
    public var userId: String
    public var role: String?

    public init(userId: String, role: String? = nil) {
        self.userId = userId
        self.role = role
    }
}

/// A group membership: a simulated one for `test`, or a resolved one in a
/// `debug` result. Mirrors JS `{ groupType, groupId }`.
public struct RuleSetMembership: Codable, Sendable, Equatable {
    public var groupType: String
    public var groupId: String

    public init(groupType: String, groupId: String) {
        self.groupType = groupType
        self.groupId = groupId
    }
}

/// A simulated group context for group-scoped `test` evaluation.
public struct TestRuleSetGroup: Encodable, Sendable {
    public var groupType: String
    public var groupId: String
    public var name: String
    public var createdBy: String

    public init(groupType: String, groupId: String, name: String, createdBy: String) {
        self.groupType = groupType
        self.groupId = groupId
        self.name = name
        self.createdBy = createdBy
    }
}

/// The target user of a simulated operation.
public struct TestRuleSetTarget: Encodable, Sendable {
    public var userId: String

    public init(userId: String) {
        self.userId = userId
    }
}

/// Parameters for `test`. Mirrors JS `TestRuleSetParams`.
public struct TestRuleSetParams: Encodable, Sendable {
    /// The resource category being accessed (e.g. `"members"`, `"documents"`).
    public var category: String
    /// The operation being performed (e.g. `"read"`, `"write"`, `"delete"`).
    public var operation: String
    /// The simulated user performing the action.
    public var user: TestRuleSetUser
    /// Group memberships to simulate for the user.
    public var memberships: [RuleSetMembership]?
    /// The group context for group-scoped rule evaluation.
    public var group: TestRuleSetGroup?
    /// The target user of the operation, if applicable.
    public var target: TestRuleSetTarget?
    /// Arbitrary record data to evaluate field-level rules against.
    public var record: [String: JSONValue]?

    public init(
        category: String,
        operation: String,
        user: TestRuleSetUser,
        memberships: [RuleSetMembership]? = nil,
        group: TestRuleSetGroup? = nil,
        target: TestRuleSetTarget? = nil,
        record: [String: JSONValue]? = nil
    ) {
        self.category = category
        self.operation = operation
        self.user = user
        self.memberships = memberships
        self.group = group
        self.target = target
        self.record = record
    }
}

/// Parameters for `debug`. Mirrors JS `DebugRuleSetParams`.
public struct DebugRuleSetParams: Encodable, Sendable {
    /// The real user ID to evaluate rules against.
    public var userId: String
    /// The group type whose rule set should be evaluated.
    public var groupType: String
    /// The resource category being accessed (e.g. `"members"`, `"documents"`).
    public var category: String
    /// The operation being performed (e.g. `"read"`, `"write"`, `"delete"`).
    public var operation: String
    /// If provided, evaluates rules within a specific group's context.
    public var groupId: String?
    /// If provided, the target user of the operation being debugged.
    public var targetUserId: String?

    public init(
        userId: String,
        groupType: String,
        category: String,
        operation: String,
        groupId: String? = nil,
        targetUserId: String? = nil
    ) {
        self.userId = userId
        self.groupType = groupType
        self.category = category
        self.operation = operation
        self.groupId = groupId
        self.targetUserId = targetUserId
    }
}

// MARK: Test / debug results

/// One entry in an evaluation trace. Mirrors JS `TraceEntry` — `args` and
/// `result` are opaque (`any[]` / `any`).
public struct TraceEntry: Decodable, Sendable, Equatable {
    public let function: String
    public let args: [JSONValue]
    public let result: JSONValue
}

/// Result of `test`. Mirrors JS `RuleSetTestResult`.
public struct RuleSetTestResult: Decodable, Sendable, Equatable {
    public let allowed: Bool
    public let expression: String?
    /// Opaque CEL evaluation context (`Record<string, any>`).
    public let context: [String: JSONValue]?
    public let trace: [TraceEntry]?
    public let error: String?
}

/// The resolved user attached to a debug result.
public struct RuleSetDebugUser: Decodable, Sendable, Equatable {
    public let userId: String
    public let appRole: String
}

/// Result of `debug`. Mirrors JS `RuleSetDebugResult`.
public struct RuleSetDebugResult: Decodable, Sendable, Equatable {
    public let allowed: Bool
    public let expression: String?
    public let reason: String?
    public let ruleSetId: String?
    public let ruleSetName: String?
    public let user: RuleSetDebugUser?
    public let memberships: [RuleSetMembership]?
    /// Opaque CEL evaluation context (`Record<string, any>`).
    public let context: [String: JSONValue]?
    public let trace: [TraceEntry]?
}
