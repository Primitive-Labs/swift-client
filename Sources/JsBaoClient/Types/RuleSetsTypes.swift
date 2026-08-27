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

/// Per-model trigger config as stored on a `DatabaseTypeConfig` (`{ triggers }`).
/// Mirrors JS `ModelRulesInfo`.
///
/// NOTE: `ModelRulesInfo` models **triggers**, not rule-set operation
/// expressions. Rule-set `rules` values are per-operation CEL expressions and
/// use ``CategoryRules`` / ``RuleExpression`` instead (issue #1525).
public struct ModelRulesInfo: Codable, Sendable, Equatable {
    public var triggers: [TriggerDefInfo]?

    public init(triggers: [TriggerDefInfo]? = nil) {
        self.triggers = triggers
    }
}

/// A single declared traversal edge for a per-rule `loads` block. Mirrors the
/// JS `PathDeclaration` / the server-side `PathDeclaration`
/// (`src/app-api/helpers/metadata-cel-access.ts`). Exactly one of `from` /
/// `rootFrom` roots the edge.
public struct PathDeclaration: Codable, Sendable, Equatable {
    public var from: String?
    public var rootFrom: String?
    public var via: String?
    public var type: String
    public var categories: [String]

    public init(
        from: String? = nil,
        rootFrom: String? = nil,
        via: String? = nil,
        type: String,
        categories: [String]
    ) {
        self.from = from
        self.rootFrom = rootFrom
        self.via = via
        self.type = type
        self.categories = categories
    }
}

/// Per-rule declared loads colocated on a rule-set operation entry (issue
/// #1525). Mirrors JS `RuleLoads`. Carries **only** `paths` (Fork 4A):
/// memberships are inferred from `memberGroupsOf`, and `secrets`/`vars` stay on
/// the config-level `metadataManifest` allowlist — a per-rule
/// `loads.secrets`/`loads.vars` is a save-time 400.
public struct RuleLoads: Codable, Sendable, Equatable {
    public var paths: [String: PathDeclaration]?

    public init(paths: [String: PathDeclaration]? = nil) {
        self.paths = paths
    }
}

/// A rule-set operation entry value. Mirrors JS
/// `RuleExpression = string | { expr, loads? }`. Either a bare CEL string
/// (unchanged legacy form, stored verbatim) or an object carrying the
/// expression plus its declared `loads` (issue #1525). Parse-on-read: bare
/// strings are never rewritten to the object form, so the two cases round-trip
/// back to the same wire shape they decoded from.
public enum RuleExpression: Codable, Sendable, Equatable {
    /// A bare CEL string — the legacy form, encoded verbatim as a JSON string.
    case string(String)
    /// The object form `{ expr, loads? }` colocating declared loads.
    case object(expr: String, loads: RuleLoads?)

    /// The private object shape backing the `.object` case. Kept internal so
    /// the public surface is just the two-case enum.
    private struct ObjectForm: Codable {
        var expr: String
        var loads: RuleLoads?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            let form = try container.decode(ObjectForm.self)
            self = .object(expr: form.expr, loads: form.loads)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(string):
            try container.encode(string)
        case let .object(expr, loads):
            try container.encode(ObjectForm(expr: expr, loads: loads))
        }
    }

    /// The CEL expression, regardless of which case is stored.
    public var expr: String {
        switch self {
        case let .string(string): return string
        case let .object(expr, _): return expr
        }
    }

    /// The colocated declared loads, or `nil` for the bare-string form.
    public var loads: RuleLoads? {
        switch self {
        case .string: return nil
        case let .object(_, loads): return loads
        }
    }
}

/// A category's per-operation rules: operation name → ``RuleExpression``.
/// Mirrors JS `CategoryRules = Record<string, RuleExpression>`.
public typealias CategoryRules = [String: RuleExpression]

// MARK: Rule set metadata

/// A rule set's full metadata. Mirrors JS `RuleSetInfo`.
public struct RuleSetInfo: Decodable, Sendable, Equatable {
    public let ruleSetId: String
    public let appId: String
    public let name: String
    /// Nullable on the wire — `description: string | null`.
    public let description: String?
    public let resourceType: String
    /// Rules keyed by category/model name, each a ``CategoryRules`` map of
    /// operation → ``RuleExpression`` (bare CEL string or `{ expr, loads }`).
    public let rules: [String: CategoryRules]
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
    /// Rules keyed by category/model name, each a ``CategoryRules`` map of
    /// operation → ``RuleExpression`` (a bare CEL string or, to colocate
    /// declared `loads`, an object `{ expr, loads }`).
    public var rules: [String: CategoryRules]
    /// Optional human-readable description of the rule set's purpose.
    public var description: String?

    public init(
        name: String,
        resourceType: String,
        rules: [String: CategoryRules],
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
    /// Replacement rule definitions, keyed by category/model name. Each value
    /// is a ``CategoryRules`` map of operation → ``RuleExpression``.
    public var rules: [String: CategoryRules]?

    public init(
        name: String? = nil,
        description: String? = nil,
        rules: [String: CategoryRules]? = nil
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
