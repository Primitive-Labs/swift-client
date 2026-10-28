import Foundation

// MARK: - Groups: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/groupsApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. Inputs
// are `Encodable` option structs; outputs are `Decodable` models.

// MARK: Roles and settings

/// A role on a group, highest first: `owner` (the custodian user's row),
/// `manager` or `member`. Mirrors JS `GroupRole`.
public enum GroupRole: String, Codable, Sendable, Equatable {
    case owner
    case manager
    case member
}

/// Who may list a group's or a collection's members and pending invitations:
/// every member (the default) or only the owner and managers.
public enum MemberListSetting: String, Codable, Sendable, Equatable {
    case members
    case managers
}

/// A group's or a collection's settings. Mirrors JS `GroupSettings` and
/// `CollectionSettings`. Sent whole on `update`.
public struct ResourceSettings: Codable, Sendable, Equatable {
    /// Who may list the members and pending invitations.
    public var memberList: MemberListSetting

    public init(memberList: MemberListSetting) {
        self.memberList = memberList
    }
}

// MARK: Group metadata

/// Metadata for a single group. Mirrors JS `GroupInfo`.
public struct GroupInfo: Decodable, Sendable, Equatable {
    public let appId: String
    /// The group's stored type.
    @available(*, deprecated, message: "Groups are addressed by groupId alone. Removed by #4718.")
    public let groupType: String
    public let groupId: String
    public let name: String
    public let description: String?
    public let memberCount: Int
    /// Who holds the group: `user:<userId>` (that user holds its `owner`
    /// row) or `app`. `nil` on a group created before groups had a custodian.
    public let custodian: String?
    /// The group's settings. `nil` only from a server that predates them.
    public let settings: ResourceSettings?
    public let createdAt: String
    public let createdBy: String
    public let modifiedAt: String
}

/// A member of a group. Mirrors JS `GroupMemberInfo`.
public struct GroupMemberInfo: Decodable, Sendable, Equatable {
    public let userId: String
    /// The member's role: a `GroupRole` raw value. A platform-managed system
    /// group's (`_col-*`) row, listed through the typed label, holds the
    /// collection's role as stored, or `nil`; so does a row from a server
    /// that predates roles.
    public let role: String?
    public let addedAt: String?
    public let addedBy: String
    public let userName: String?
    public let userEmail: String?
    /// The member's avatar URL. Only populated when the member was fetched
    /// with `include: .profiles` (see `GroupsAPI.listMembers`). `null` when
    /// the user has no avatar, or the membership is orphaned (the user no
    /// longer exists). Absent from the default (no-`include`) response.
    public let avatarUrl: String?
}

/// Optional joins for `GroupsAPI.listMembers`. Mirrors the JS client's
/// `include?: "profiles"` option (serialized as `?include=profiles`). With
/// `.profiles`, each member is joined with their basic profile in the same
/// round trip: `userName`/`userEmail` are reliably populated and `avatarUrl`
/// is included. The server rejects unknown values with HTTP 400.
public enum GroupMemberInclude: String, Sendable {
    case profiles
}

/// One of the current user's (or a queried user's) group memberships.
/// Mirrors JS `GroupMembershipInfo`. `name`/`description` are joined from
/// the group record at call time.
public struct GroupMembershipInfo: Decodable, Sendable, Equatable {
    public let groupType: String
    public let groupId: String
    /// Display name of the group (joined from the group record at call time).
    public let name: String
    /// Optional description; omitted when the group has no description set.
    public let description: String?
    /// The user's role on the group: a `GroupRole` raw value, or a system
    /// group's stored collection role, or `nil`.
    public let role: String?
    public let addedAt: String?
    public let addedBy: String
}

/// A document a group has access to. Mirrors JS `GroupDocumentInfo`.
public struct GroupDocumentInfo: Decodable, Sendable, Equatable {
    public let documentId: String
    /// Optional: `Document.title` isn't required and `formatDocumentInfo`
    /// (`document-helpers.ts`) drops it when undefined — untitled docs shared
    /// with a group omit the key. Matches the `CollectionDocumentInfo.title`
    /// precedent.
    public let title: String?
    public let createdBy: String
    public let createdAt: String
    public let lastModified: String
    public let permission: String
    public let grantedAt: String?
}

/// A database a group has access to (via `DatabaseGroupPermission`).
/// Mirrors JS `GroupDatabaseInfo`.
public struct GroupDatabaseInfo: Decodable, Sendable, Equatable {
    public let databaseId: String
    public let title: String
    /// `null` when the database has no type set — kept optional to match JS
    /// `string | null`.
    public let databaseType: String?
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String
    public let permission: String
    public let grantedAt: String?
}

/// A pending (unresolved, non-expired) invitation scoped to a group.
/// Mirrors JS `PendingGroupInvitationEntry` (re-exported by groupsApi).
public struct PendingGroupInvitationEntry: Decodable, Sendable, Equatable {
    public let email: String
    /// Role the user will hold after signup. Always `"member"` today.
    public let role: String
    public let invitationId: String
    /// Deferred-grant id for this pending invitation. Pass to
    /// `client.invitations.revokeDeferredGrant(deferredId:type:)` with
    /// `.group` to cancel it. Required — mirrors JS `deferredId: string`.
    public let deferredId: String
    public let createdAt: String
    public let expiresAt: String
    public let addedBy: String?
}

// MARK: Create / update / list inputs

/// Parameters for `create`. Mirrors JS `CreateGroupParams` —
/// `groupType` and `name` are required. There is no `groupId`: the server
/// assigns the new group's id and returns it on the `GroupInfo`.
///
/// Deprecated with `GroupsAPI.create(params:)`: the server refuses every
/// session's group create.
@available(*, deprecated, message: "A session cannot create a group: create it from a server function or the admin API. Removed by #4718.")
public struct CreateGroupParams: Encodable, Sendable {
    /// The type category for the group (e.g., `"team"`, `"organization"`).
    public var groupType: String
    /// Display name for the group.
    public var name: String
    /// Optional human-readable description of the group's purpose.
    public var description: String?
    /// Create-time resource metadata to stamp on the new group, keyed by
    /// category name → that category's values. Each entry is
    /// schema-validated but the category `writeRule` is waived — creation
    /// authority covers the initial stamp. At most 10 categories; any invalid
    /// entry fails the whole create.
    ///
    /// The stamp only writes fresh rows: a row already stored for the new
    /// group's id and category fails the create with 409 `METADATA_EXISTS`.
    /// Mirrors js-bao's `CreateGroupParams.initialMetadata`.
    public var initialMetadata: [String: [String: JSONValue]]?

    public init(
        groupType: String,
        name: String,
        description: String? = nil,
        initialMetadata: [String: [String: JSONValue]]? = nil
    ) {
        self.groupType = groupType
        self.name = name
        self.description = description
        self.initialMetadata = initialMetadata
    }
}

/// Fields to update on `update`. Mirrors JS `UpdateGroupParams`. Omit a
/// property to leave it unchanged.
public struct UpdateGroupParams: Encodable, Sendable {
    /// New display name for the group.
    public var name: String?
    /// New description for the group.
    public var description: String?
    /// New settings for the group.
    public var settings: ResourceSettings?

    public init(name: String? = nil, description: String? = nil, settings: ResourceSettings? = nil) {
        self.name = name
        self.description = description
        self.settings = settings
    }
}

/// Filtering and pagination options for `list`. Mirrors JS
/// `ListGroupsOptions`.
public struct ListGroupsOptions: Sendable {
    /// The type filter `list` sends, set only by the deprecated init.
    var typeFilter: String?
    /// If provided, only groups of this type are returned.
    @available(*, deprecated, message: "Groups are addressed by groupId alone; list without a type. Removed by #4718.")
    public var type: String? {
        get { typeFilter }
        set { typeFilter = newValue }
    }
    /// Maximum number of groups to return per page.
    public var limit: Int?
    /// Cursor for fetching the next page of results.
    public var cursor: String?
    /// If `true`, include platform-managed internal groups (those whose
    /// `groupType` is prefixed with `_`, e.g. `_col-reader` / `_col-writer`
    /// backing collection sharing). Defaults to `false` — internal groups
    /// are an implementation detail and are not user-meaningful.
    public var includeSystem: Bool?

    public init(
        limit: Int? = nil,
        cursor: String? = nil,
        includeSystem: Bool? = nil
    ) {
        self.limit = limit
        self.cursor = cursor
        self.includeSystem = includeSystem
    }

    /// Filters by group type.
    @available(*, deprecated, message: "Groups are addressed by groupId alone: use init(limit:cursor:includeSystem:). Removed by #4718.")
    public init(
        type: String?,
        limit: Int? = nil,
        cursor: String? = nil,
        includeSystem: Bool? = nil
    ) {
        self.typeFilter = type
        self.limit = limit
        self.cursor = cursor
        self.includeSystem = includeSystem
    }
}

/// Identifier for `addMember` — provide either `userId` or `email`, never
/// both — and the role the membership gets. Mirrors JS
/// `AddGroupMemberParams` (a userId-XOR-email union with `role`).
/// Use the `.userId(_:role:)` / `.email(_:role:)` factories.
public struct AddGroupMemberParams: Encodable, Sendable {
    public var userId: String?
    public var email: String?
    /// `manager` or `member`; the server gives `member` when it is `nil`.
    /// `owner` is the custodian's row, which only a server function or the
    /// admin API writes.
    public var role: GroupRole?

    private init(userId: String?, email: String?, role: GroupRole?) {
        self.userId = userId
        self.email = email
        self.role = role
    }

    /// Add an existing app user by id.
    public static func userId(_ userId: String, role: GroupRole? = nil) -> AddGroupMemberParams {
        AddGroupMemberParams(userId: userId, email: nil, role: role)
    }

    /// Add by email (deferred add when the email has no app user yet).
    public static func email(_ email: String, role: GroupRole? = nil) -> AddGroupMemberParams {
        AddGroupMemberParams(userId: nil, email: email, role: role)
    }
}

/// A member's role after `setMemberRole`. Mirrors the JS answer
/// `{ userId, role, addedAt?, addedBy? }`.
public struct GroupMemberRole: Decodable, Sendable, Equatable {
    public let userId: String
    public let role: GroupRole
    public let addedAt: String?
    public let addedBy: String?
}

// MARK: addMember result (discriminated union, #453)

/// Result of a direct group add — the email or userId mapped to an existing
/// app user, so a real membership row exists (or was just created).
/// Mirrors JS `DirectGroupAdd`.
public struct DirectGroupAdd: Decodable, Sendable, Equatable {
    /// `"added"` = new membership created by this call.
    /// `"already_member"` = the user was already a member (the response
    /// fields reflect the existing membership row, not "now").
    public let status: String
    public let userId: String
    public let userName: String?
    public let userEmail: String?
    /// The membership's role (for `already_member`, the role it already
    /// holds). `nil` for a platform-managed system group (`_col-*`).
    public let role: GroupRole?
    public let addedAt: String?
    public let addedBy: String
}

/// Result of a deferred group add — the email does not yet map to an app
/// user, so a `DeferredGroupAdd` row was created (or an existing unresolved
/// one was returned for idempotency). Mirrors JS `DeferredGroupAdd`.
///
/// The `deferredId` can be passed to
/// `client.invitations.revokeDeferredGrant(deferredId:, "group")` to cancel
/// the pending add. Combine `inviteToken` with the app's accept-page URL to
/// build a CTA for a custom invitation email.
public struct DeferredGroupAdd: Decodable, Sendable, Equatable {
    /// Always `"pending_signup"`.
    public let status: String
    public let email: String
    public let appInvitationCreated: Bool
    public let deferredId: String
    public let expiresAt: String
    public let groupType: String
    public let groupId: String
    /// The role the invitee receives when they sign up. `nil` for a
    /// platform-managed system group (`_col-*`).
    public let role: GroupRole?
    /// The `AppInvitation` record created or reused for this email.
    public let invitationId: String
    /// Tokenized accept token; combine with your app's accept-page URL.
    /// May be `null`.
    public let inviteToken: String?
}

/// Result of `addMember` — either a direct or a deferred add, distinguished
/// by `status`. Mirrors JS `GroupAddMemberResult`.
public enum GroupAddMemberResult: Decodable, Sendable, Equatable {
    /// `status == "added"` or `"already_member"`.
    case direct(DirectGroupAdd)
    /// `status == "pending_signup"`.
    case deferred(DeferredGroupAdd)

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decodeIfPresent(String.self, forKey: .status)
        if status == "pending_signup" {
            self = .deferred(try DeferredGroupAdd(from: decoder))
        } else {
            self = .direct(try DirectGroupAdd(from: decoder))
        }
    }

    /// The `status` discriminator string, regardless of case.
    public var status: String {
        switch self {
        case let .direct(d): return d.status
        case let .deferred(d): return d.status
        }
    }
}

// MARK: PaginatedResult decoding

// `PaginatedResult<T>` (items + optional cursor) is the shared HTTP-layer
// pagination envelope declared in `Types/Options.swift`. It predates the
// typed surfaces and was `Sendable`-only; this constrained extension teaches
// it to `Decodable` so the typed `groups` returns can decode straight into
// it without redeclaring the type.
extension PaginatedResult: Decodable where T: Decodable {
    private enum CodingKeys: String, CodingKey {
        case items, nextCursor, hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = try c.decodeIfPresent([T].self, forKey: .items) ?? []
        let nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        let hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore)
        self.init(items: items, nextCursor: nextCursor, hasMore: hasMore)
    }
}
