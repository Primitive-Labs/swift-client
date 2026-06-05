import Foundation

// MARK: - GroupTypeConfigs: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/groupTypeConfigsApi.d.ts`) field-for-field. Timestamps stay as
// ISO-8601 `String`s — exactly what JS exposes.

/// A group type configuration. Mirrors JS `GroupTypeConfigInfo`.
///
/// Binds a rule set and an auto-add-creator policy to a `groupType` tag
/// (e.g. `"team"`, `"organization"`).
public struct GroupTypeConfigInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let groupType: String
    /// `null` when no rule set is bound — `nil` here.
    public let ruleSetId: String?
    public let autoAddCreator: Bool
    public let createdAt: String
    public let modifiedAt: String
    public let createdBy: String
}

/// Parameters for `create`. Mirrors JS `CreateGroupTypeConfigParams`.
public struct CreateGroupTypeConfigParams: Encodable, Sendable {
    /// The group type identifier to configure (e.g., `"team"`, `"organization"`).
    public var groupType: String
    /// Rule set to enforce for groups of this type.
    public var ruleSetId: String?
    /// Whether to automatically add the group creator as a member (defaults to `false`).
    public var autoAddCreator: Bool?

    public init(
        groupType: String,
        ruleSetId: String? = nil,
        autoAddCreator: Bool? = nil
    ) {
        self.groupType = groupType
        self.ruleSetId = ruleSetId
        self.autoAddCreator = autoAddCreator
    }
}

/// Parameters for `update`. Mirrors JS `UpdateGroupTypeConfigParams`.
///
/// `ruleSetId` is tri-state to match JS's `string | null | undefined`:
/// omit (leave unchanged), `.value("rs123")` to set, or `.clear` to remove
/// the current rule set.
public struct UpdateGroupTypeConfigParams: Encodable, Sendable {
    /// `.value("rs123")` to set, `.clear` to remove, `nil` to leave unchanged.
    public var ruleSetId: Updatable<String>?
    /// Whether to automatically add the group creator as a member.
    public var autoAddCreator: Bool?

    public init(
        ruleSetId: Updatable<String>? = nil,
        autoAddCreator: Bool? = nil
    ) {
        self.ruleSetId = ruleSetId
        self.autoAddCreator = autoAddCreator
    }
}
