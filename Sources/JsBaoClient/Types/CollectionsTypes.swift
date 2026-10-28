import Foundation

// MARK: - Collections: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/collectionsApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. Opaque,
// platform-untouched blobs are typed as `JSONValue` (see JSONValue.swift).
//
// `PaginationOptions` / `PaginatedResult<T>` are reused from Options.swift;
// the cursor-paginated list methods decode through a private `*Page` envelope
// and return the shared `PaginatedResult<T>`.

// MARK: Roles and permission enums

/// A role on a collection, highest first. A group holds up to `manager`;
/// `owner` is the custodian user's row. Mirrors JS `CollectionRole`.
public enum CollectionRole: String, Codable, Sendable, Equatable {
    case owner
    case manager
    case editor
    case contributor
    case viewer
}

/// A collection-level access level from before collection roles: `reader`
/// (a viewer) or `read-write` (an editor). `read-write` carries an explicit
/// raw value (the hyphen isn't a legal Swift identifier).
@available(*, deprecated, message: "Collections have fixed roles: use CollectionRole. Removed by #4718.")
public enum CollectionPermission: String, Codable, Sendable, Equatable {
    case reader
    case readWrite = "read-write"
}

/// The caller's effective permission on a document *inside* a collection.
/// Admins/owners always resolve to `.owner`. Mirrors JS
/// `CollectionDocumentInfo.permission`.
public enum CollectionDocumentPermission: String, Codable, Sendable, Equatable {
    case owner
    case readWrite = "read-write"
    case reader
}

// MARK: Collection metadata

/// Metadata for a single collection. Mirrors JS `CollectionInfo`.
public struct CollectionInfo: Decodable, Sendable, Equatable {
    public let collectionId: String
    public let appId: String
    public let name: String
    public let description: String?
    /// The collection's stored type; `"default"` for every collection created
    /// since collection roles.
    @available(*, deprecated, message: "Collections have fixed roles: read role and settings. Removed by #4718.")
    public let collectionType: String
    public let documentCount: Int
    public let createdAt: String
    public let createdBy: String
    public let modifiedAt: String
    /// Who holds the collection: `user:<userId>` (that user holds its
    /// `owner` row) or `app`. `nil` on a collection created before
    /// collections had a custodian.
    public let custodian: String?
    /// The collection's settings. `nil` only from a server that predates them.
    public let settings: ResourceSettings?
    /// The caller's role on the collection. Populated by `list()`.
    public let role: CollectionRole?
    /// The caller's direct permission on the collection. Populated by
    /// `list()` only — `nil` from `listAll()` / `get()`.
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: CollectionPermission?
}

/// A document belonging to a collection. Mirrors JS `CollectionDocumentInfo`.
///
/// The JS `CollectionDocumentInfo` interface declares the document-derived
/// fields (`title`/`createdBy`/`createdAt`/`lastModified`/`permission`) as
/// required, but TS erases those annotations at runtime and two server paths
/// return different shapes: `collections.listDocuments` hydrates the full
/// document (all fields present), while `collections.addDocument` returns only
/// `{ collectionId, documentId, addedBy }`. JS tolerates the sparse shape; to
/// match that runtime behavior the document-derived fields are optional here.
/// Only the membership-row fields (`documentId`/`collectionId`/`addedBy`) are
/// guaranteed across both paths.
public struct CollectionDocumentInfo: Decodable, Sendable, Equatable {
    public let documentId: String
    public let collectionId: String
    /// ISO timestamp of when the document entered this collection.
    public let addedAt: String?
    /// UserId of the caller who added the document to the collection.
    public let addedBy: String
    /// Present from `listDocuments` (hydrated doc); absent from `addDocument`.
    public let title: String?
    /// UserId of the document's creator. Absent from `addDocument`.
    public let createdBy: String?
    public let createdAt: String?
    public let lastModified: String?
    /// The caller's effective permission on this specific document. Absent
    /// from `addDocument` (only the membership row is returned there).
    public let permission: CollectionDocumentPermission?
    /// Document tags (omitted when the document has no tags).
    public let tags: [String]?
}

/// A summary of a collection a given document belongs to. Mirrors JS
/// `DocumentCollectionInfo`.
public struct DocumentCollectionInfo: Decodable, Sendable, Equatable {
    public let collectionId: String
    public let name: String
    public let addedAt: String?
}

// MARK: Access (groups + members)

/// A group's permission entry on a collection. Mirrors JS
/// `CollectionGroupPermissionInfo`.
public struct CollectionGroupPermissionInfo: Decodable, Sendable, Equatable {
    public let collectionId: String
    @available(*, deprecated, message: "Groups are addressed by groupId alone. Removed by #4718.")
    public let groupType: String
    public let groupId: String
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: String
    /// The group's role on the collection.
    public let role: CollectionRole?
    public let grantedAt: String
    public let grantedBy: String
}

/// A direct member of a collection. Mirrors JS `CollectionMemberInfo`.
public struct CollectionMemberInfo: Decodable, Sendable, Equatable {
    public let userId: String
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: String
    /// The member's role on the collection.
    public let role: CollectionRole?
    public let addedAt: String?
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let addedBy: String
}

/// A collection's access info: its group grants and direct members.
/// Mirrors JS `CollectionAccessInfo`. Returned by the deprecated
/// `getAccess`; `listMembers` answers both as principals.
public struct CollectionAccessInfo: Decodable, Sendable, Equatable {
    public let groups: [CollectionGroupPermissionInfo]
    public let members: [CollectionMemberInfo]
}

// MARK: Invitations

/// A pending (deferred) collection invitation. Mirrors JS
/// `PendingCollectionInvitationEntry`.
public struct PendingCollectionInvitationEntry: Decodable, Sendable, Equatable {
    public let email: String
    /// The role the recipient will hold once they accept and sign in.
    public let role: CollectionRole?
    /// The permission the recipient will hold once they accept and sign in.
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: CollectionPermission
    public let invitationId: String
    public let createdAt: String
    public let expiresAt: String
    public let addedBy: String?
}

// MARK: Create / update inputs

/// Parameters for `create`. Mirrors JS `CreateCollectionParams`.
public struct CreateCollectionParams: Encodable, Sendable {
    public var name: String
    public var description: String?
    /// The collection's stored type; sent only by the deprecated init.
    @available(*, deprecated, message: "Collections have fixed roles; omit it. Removed by #4718.")
    public var collectionType: String?
    /// The collection's settings; `memberList: .members` when omitted.
    public var settings: ResourceSettings?
    /// Create-time resource metadata to stamp on the new collection, keyed by
    /// category name → that category's values. Each entry is
    /// schema-validated but the category `writeRule` is waived — creation
    /// authority covers the initial stamp. At most 10 categories; any invalid
    /// entry fails the whole create.
    ///
    /// The values are staged before the collection type's `collection.create`
    /// rule runs (issue #1876), so a CEL create rule can gate on them via
    /// `md.self.<category>.<key>`. Mirrors js-bao's
    /// `CreateCollectionParams.initialMetadata`. This is how a collection is
    /// bound to an external entity (a class, a project): stamp a category here
    /// and read it in rules as `md.self.<category>.<key>`.
    public var initialMetadata: [String: [String: JSONValue]]? = nil

    public init(
        name: String,
        description: String? = nil,
        settings: ResourceSettings? = nil,
        initialMetadata: [String: [String: JSONValue]]? = nil
    ) {
        self.name = name
        self.description = description
        self.settings = settings
        self.initialMetadata = initialMetadata
    }

    @available(*, deprecated, message: "Collections have fixed roles: use init(name:description:settings:initialMetadata:). Removed by #4718.")
    public init(
        name: String,
        description: String? = nil,
        collectionType: String?,
        initialMetadata: [String: [String: JSONValue]]? = nil
    ) {
        self.name = name
        self.description = description
        self.collectionType = collectionType
        self.initialMetadata = initialMetadata
    }
}

/// Fields to change on `update`. Mirrors JS `UpdateCollectionParams`.
public struct UpdateCollectionParams: Encodable, Sendable {
    public var name: String?
    public var description: String?
    /// New settings for the collection.
    public var settings: ResourceSettings?

    public init(name: String? = nil, description: String? = nil, settings: ResourceSettings? = nil) {
        self.name = name
        self.description = description
        self.settings = settings
    }
}

/// Parameters for `grantGroupPermission`. Mirrors JS
/// `GrantCollectionGroupPermissionParams`.
@available(*, deprecated, message: "Groups are members: use CollectionsAPI.addGroupMember(collectionId:groupId:role:). Removed by #4718.")
public struct GrantCollectionGroupPermissionParams: Encodable, Sendable {
    public var groupType: String
    public var groupId: String
    public var permission: String

    public init(groupType: String, groupId: String, permission: String) {
        self.groupType = groupType
        self.groupId = groupId
        self.permission = permission
    }
}

// MARK: addMember input (userId XOR email)

/// Parameters for `addMember`. Provide *either* `userId` (an existing app
/// user) *or* `email` (existing user OR yet-to-sign-up) — never both — and
/// the role they get. Use the `.user(_:role:…)` / `.email(_:role:…)`
/// factories for the common cases; mutual exclusion is enforced server-side.
/// Mirrors JS's `AddCollectionMemberParams` discriminated union (#671).
public struct AddCollectionMemberParams: Encodable, Sendable {
    public var userId: String?
    public var email: String?
    /// The member's role. `owner` only from a server function, for the
    /// custodian user.
    public var role: CollectionRole?
    /// The access level from before collection roles; sent only by the
    /// deprecated factories and init.
    @available(*, deprecated, message: "Send role. Removed by #4718.")
    public var permission: CollectionPermission?
    /// When true, send the (deferred-)share email after adding.
    public var sendEmail: Bool?
    /// Optional URL the email links the recipient to.
    public var collectionUrl: String?
    /// Optional personal note included in the share email.
    public var note: String?

    public init(
        userId: String? = nil,
        email: String? = nil,
        role: CollectionRole,
        sendEmail: Bool? = nil,
        collectionUrl: String? = nil,
        note: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.role = role
        self.sendEmail = sendEmail
        self.collectionUrl = collectionUrl
        self.note = note
    }

    @available(*, deprecated, message: "Send role: use init(userId:email:role:sendEmail:collectionUrl:note:). Removed by #4718.")
    public init(
        userId: String? = nil,
        email: String? = nil,
        permission: CollectionPermission,
        sendEmail: Bool? = nil,
        collectionUrl: String? = nil,
        note: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.permission = permission
        self.sendEmail = sendEmail
        self.collectionUrl = collectionUrl
        self.note = note
    }

    /// Add an existing app user by id.
    public static func user(
        _ userId: String,
        role: CollectionRole,
        sendEmail: Bool? = nil,
        collectionUrl: String? = nil,
        note: String? = nil
    ) -> AddCollectionMemberParams {
        AddCollectionMemberParams(
            userId: userId, role: role,
            sendEmail: sendEmail, collectionUrl: collectionUrl, note: note
        )
    }

    /// Add by email — resolves to a direct add for existing users, otherwise
    /// a deferred grant that resolves on signup.
    public static func email(
        _ email: String,
        role: CollectionRole,
        sendEmail: Bool? = nil,
        collectionUrl: String? = nil,
        note: String? = nil
    ) -> AddCollectionMemberParams {
        AddCollectionMemberParams(
            email: email, role: role,
            sendEmail: sendEmail, collectionUrl: collectionUrl, note: note
        )
    }

    /// Add an existing app user by id with a permission.
    @available(*, deprecated, message: "Send role: use user(_:role:sendEmail:collectionUrl:note:). Removed by #4718.")
    public static func user(
        _ userId: String,
        permission: CollectionPermission,
        sendEmail: Bool? = nil,
        collectionUrl: String? = nil,
        note: String? = nil
    ) -> AddCollectionMemberParams {
        AddCollectionMemberParams(
            userId: userId, permission: permission,
            sendEmail: sendEmail, collectionUrl: collectionUrl, note: note
        )
    }

    /// Add by email with a permission.
    @available(*, deprecated, message: "Send role: use email(_:role:sendEmail:collectionUrl:note:). Removed by #4718.")
    public static func email(
        _ email: String,
        permission: CollectionPermission,
        sendEmail: Bool? = nil,
        collectionUrl: String? = nil,
        note: String? = nil
    ) -> AddCollectionMemberParams {
        AddCollectionMemberParams(
            email: email, permission: permission,
            sendEmail: sendEmail, collectionUrl: collectionUrl, note: note
        )
    }
}

// MARK: addMember result (discriminated union)

/// Result of a direct collection add — the user/email mapped to an existing
/// app user, so a real membership row exists (or was just created). Mirrors
/// JS `DirectCollectionAdd`.
public struct DirectCollectionAdd: Decodable, Sendable, Equatable {
    /// `"added"` (new membership created) or `"already_member"`.
    public let status: String
    public let userId: String
    /// The member as a principal: their user id.
    public let principal: String?
    /// The member's role (for `already_member`, the role already held).
    public let role: CollectionRole?
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: CollectionPermission
    public let addedAt: String?
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let addedBy: String
    public let userName: String?
    public let userEmail: String?
}

/// Result of a deferred collection add — the email does not yet map to an
/// app user, so a `DeferredGroupAdd` row was created (or an existing
/// unresolved one returned idempotently). Mirrors JS `DeferredCollectionAdd`.
public struct DeferredCollectionAdd: Decodable, Sendable, Equatable {
    /// Always `"pending_signup"`.
    public let status: String
    public let email: String
    /// The role the invitee receives when they sign up.
    public let role: CollectionRole?
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: CollectionPermission
    public let appInvitationCreated: Bool
    public let deferredId: String
    public let expiresAt: String
    public let collectionId: String
    /// The `AppInvitation` record created or reused for this email.
    public let invitationId: String
    /// Tokenized accept token; combine with your app's accept-page URL. May
    /// be `nil`.
    public let inviteToken: String?
}

/// Result of `addMember` — either a direct or a deferred add, distinguished
/// by `status` (`"pending_signup"` ⇒ deferred). Mirrors JS's
/// `CollectionAddMemberResult` discriminated union (#671).
public enum CollectionAddMemberResult: Decodable, Sendable, Equatable {
    case direct(DirectCollectionAdd)
    case deferred(DeferredCollectionAdd)

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decodeIfPresent(String.self, forKey: .status)
        if status == "pending_signup" {
            self = .deferred(try DeferredCollectionAdd(from: decoder))
        } else {
            self = .direct(try DirectCollectionAdd(from: decoder))
        }
    }
}

/// Result of `addGroupMember`: the group as a member with its role. Mirrors
/// JS `CollectionGroupMemberAdd`.
public struct CollectionGroupMemberAdd: Decodable, Sendable, Equatable {
    /// `"added"` (the group was not a member) or `"already_member"`.
    public let status: String
    /// The group as a principal: `group:<groupId>`.
    public let principal: String
    public let groupId: String
    @available(*, deprecated, message: "Groups are addressed by groupId alone. Removed by #4718.")
    public let groupType: String
    public let role: CollectionRole
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: String
    public let addedAt: String?
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let addedBy: String
}

// MARK: Members as principals

/// A member of a collection: a user or a group, with its role. Returned by
/// `listMembers` and `setMemberRole`. Mirrors JS `CollectionMemberEntry`.
public struct CollectionMemberEntry: Decodable, Sendable, Equatable {
    /// A user's id, or `group:<groupId>` for a group.
    public let principal: String
    /// Set for a user member.
    public let userId: String?
    /// Set for a group member.
    public let groupId: String?
    @available(*, deprecated, message: "Groups are addressed by groupId alone. Removed by #4718.")
    public let groupType: String?
    public let role: CollectionRole
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let permission: String
    public let addedAt: String?
    @available(*, deprecated, message: "Read role. Removed by #4718.")
    public let addedBy: String?
}

/// Where a user's collection role comes from: their own row, or the group
/// that grants it. Decoded from `"direct"` or `{ "groupId": … }`.
public enum CollectionRoleSource: Decodable, Sendable, Equatable {
    case direct
    case group(groupId: String)

    private enum CodingKeys: String, CodingKey { case groupId }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            guard text == "direct" else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown role source \"\(text)\""
                ))
            }
            self = .direct
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .group(groupId: try c.decode(String.self, forKey: .groupId))
    }
}

/// A user's role on a collection and where it comes from. Returned by
/// `resolveRole`. `role` and `source` are `nil` when the user holds none.
/// Mirrors JS `ResolvedCollectionRole`.
public struct ResolvedCollectionRole: Decodable, Sendable, Equatable {
    public let role: CollectionRole?
    public let source: CollectionRoleSource?

    public init(role: CollectionRole?, source: CollectionRoleSource?) {
        self.role = role
        self.source = source
    }
}

// MARK: Paginated decode envelopes
//
// The server returns `{ items, hasMore, nextCursor? }`. These private `*Page` types decode
// it; the API methods map them onto the shared `PaginatedResult<T>` so the
// return type matches every other paginated surface.

struct CollectionInfoPage: Decodable {
    let items: [CollectionInfo]
    let nextCursor: String?
    let hasMore: Bool?
}

struct CollectionDocumentPage: Decodable {
    let items: [CollectionDocumentInfo]
    let nextCursor: String?
    let hasMore: Bool?
}

struct DocumentCollectionPage: Decodable {
    let items: [DocumentCollectionInfo]
    let nextCursor: String?
    let hasMore: Bool?
}
