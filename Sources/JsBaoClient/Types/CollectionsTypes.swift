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

// MARK: Permission enums

/// A collection-level access level. Members and group grants hold one of
/// these. `read-write` carries an explicit raw value (the hyphen isn't a
/// legal Swift identifier).
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
    /// Selects the `CollectionTypeConfig` (rule set). Defaults to `"default"`.
    /// Immutable after create.
    public let collectionType: String
    /// Per-instance context identifier (e.g. a class ID). `nil` for
    /// collections not bound to any context. Immutable after create.
    public let contextId: String?
    public let documentCount: Int
    public let createdAt: String
    public let createdBy: String
    public let modifiedAt: String
    /// The caller's direct permission on the collection. Populated by
    /// `list()` only — `nil` from `listAll()` / `get()`.
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
    public let groupType: String
    public let groupId: String
    public let permission: String
    public let grantedAt: String
    public let grantedBy: String
}

/// A direct member of a collection. Mirrors JS `CollectionMemberInfo`.
public struct CollectionMemberInfo: Decodable, Sendable, Equatable {
    public let userId: String
    public let permission: String
    public let addedAt: String?
    public let addedBy: String
}

/// A collection's access info: its group grants and direct members.
/// Mirrors JS `CollectionAccessInfo`.
public struct CollectionAccessInfo: Decodable, Sendable, Equatable {
    public let groups: [CollectionGroupPermissionInfo]
    public let members: [CollectionMemberInfo]
}

// MARK: Invitations

/// A pending (deferred) collection invitation. Mirrors JS
/// `PendingCollectionInvitationEntry`.
public struct PendingCollectionInvitationEntry: Decodable, Sendable, Equatable {
    public let email: String
    /// The permission the recipient will hold once they accept and sign in.
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
    /// Selects the rule set. Defaults to `"default"` server-side when omitted.
    /// Must not contain `"#"`. Immutable after create.
    public var collectionType: String?
    /// Ties the collection to an external entity, exposed to CEL rules as
    /// `collection.contextId`. Must not contain `"#"`. Immutable after create.
    public var contextId: String?

    public init(
        name: String,
        description: String? = nil,
        collectionType: String? = nil,
        contextId: String? = nil
    ) {
        self.name = name
        self.description = description
        self.collectionType = collectionType
        self.contextId = contextId
    }
}

/// Fields to change on `update`. Mirrors JS `UpdateCollectionParams`.
public struct UpdateCollectionParams: Encodable, Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Parameters for `grantGroupPermission`. Mirrors JS
/// `GrantCollectionGroupPermissionParams`.
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
/// user) *or* `email` (existing user OR yet-to-sign-up) — never both. Use
/// the `.user(...)` / `.email(...)` factories for the common cases; mutual
/// exclusion is enforced server-side. Mirrors JS's
/// `AddCollectionMemberParams` discriminated union (#671).
public struct AddCollectionMemberParams: Encodable, Sendable {
    public var userId: String?
    public var email: String?
    public var permission: CollectionPermission
    /// When true, send the (deferred-)share email after adding.
    public var sendEmail: Bool?
    /// Optional URL the email links the recipient to.
    public var collectionUrl: String?
    /// Optional personal note included in the share email.
    public var note: String?

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

    /// Add by email — resolves to a direct add for existing users, otherwise
    /// a deferred grant that resolves on signup.
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
/// app user, so a real `_col-reader` / `_col-writer` membership row exists
/// (or was just created). Mirrors JS `DirectCollectionAdd`.
public struct DirectCollectionAdd: Decodable, Sendable, Equatable {
    /// `"added"` (new membership created) or `"already_member"`.
    public let status: String
    public let userId: String
    public let permission: CollectionPermission
    public let addedAt: String?
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

// MARK: Paginated decode envelopes
//
// The server returns `{ items, cursor? }`. These private `*Page` types decode
// it; the API methods map them onto the shared `PaginatedResult<T>` so the
// return type matches every other paginated surface.

struct CollectionInfoPage: Decodable {
    let items: [CollectionInfo]
    let cursor: String?
}

struct CollectionDocumentPage: Decodable {
    let items: [CollectionDocumentInfo]
    let cursor: String?
}

struct DocumentCollectionPage: Decodable {
    let items: [DocumentCollectionInfo]
    let cursor: String?
}
