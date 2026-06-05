import Foundation

// MARK: - Groups: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/groupsApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. Inputs
// are `Encodable` option structs; outputs are `Decodable` models.

// MARK: Group metadata

/// Metadata for a single group. Mirrors JS `GroupInfo`.
public struct GroupInfo: Decodable, Sendable, Equatable {
    public let appId: String
    public let groupType: String
    public let groupId: String
    public let name: String
    public let description: String?
    public let memberCount: Int
    public let createdAt: String
    public let createdBy: String
    public let modifiedAt: String
}

/// A member of a group. Mirrors JS `GroupMemberInfo`.
public struct GroupMemberInfo: Decodable, Sendable, Equatable {
    public let userId: String
    public let addedAt: String?
    public let addedBy: String
    public let userName: String?
    public let userEmail: String?
}

/// One of the current user's (or a queried user's) group memberships.
/// Mirrors JS `GroupMembershipInfo`. `name`/`description` are joined from
/// the `AppGroup` row at call time.
public struct GroupMembershipInfo: Decodable, Sendable, Equatable {
    public let groupType: String
    public let groupId: String
    /// Display name of the group (joined from AppGroup at call time).
    public let name: String
    /// Optional description; omitted when the group has no description set.
    public let description: String?
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
    public let createdAt: String
    public let expiresAt: String
    public let addedBy: String?
}

// MARK: Create / update / list inputs

/// Parameters for `create`. Mirrors JS `CreateGroupParams` —
/// `groupType`, `groupId`, and `name` are required.
public struct CreateGroupParams: Encodable, Sendable {
    /// The type category for the group (e.g., `"team"`, `"organization"`).
    public var groupType: String
    /// A unique identifier for the group within its type.
    public var groupId: String
    /// Display name for the group.
    public var name: String
    /// Optional human-readable description of the group's purpose.
    public var description: String?

    public init(
        groupType: String,
        groupId: String,
        name: String,
        description: String? = nil
    ) {
        self.groupType = groupType
        self.groupId = groupId
        self.name = name
        self.description = description
    }
}

/// Fields to update on `update`. Mirrors JS `UpdateGroupParams`. Omit a
/// property to leave it unchanged.
public struct UpdateGroupParams: Encodable, Sendable {
    /// New display name for the group.
    public var name: String?
    /// New description for the group.
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Filtering and pagination options for `list`. Mirrors JS
/// `ListGroupsOptions`.
public struct ListGroupsOptions: Sendable {
    /// If provided, only groups of this type are returned.
    public var type: String?
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
        type: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        includeSystem: Bool? = nil
    ) {
        self.type = type
        self.limit = limit
        self.cursor = cursor
        self.includeSystem = includeSystem
    }
}

/// Identifier for `addMember` — provide either `userId` or `email`, never
/// both. Mirrors JS `AddGroupMemberParams` (a userId-XOR-email union).
/// Use the `.userId(_:)` / `.email(_:)` factories.
public struct AddGroupMemberParams: Encodable, Sendable {
    public var userId: String?
    public var email: String?

    private init(userId: String?, email: String?) {
        self.userId = userId
        self.email = email
    }

    /// Add an existing app user by id.
    public static func userId(_ userId: String) -> AddGroupMemberParams {
        AddGroupMemberParams(userId: userId, email: nil)
    }

    /// Add by email (deferred add when the email has no app user yet).
    public static func email(_ email: String) -> AddGroupMemberParams {
        AddGroupMemberParams(userId: nil, email: email)
    }
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
    private enum CodingKeys: String, CodingKey { case items, cursor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = try c.decodeIfPresent([T].self, forKey: .items) ?? []
        let cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        self.init(items: items, cursor: cursor)
    }
}
