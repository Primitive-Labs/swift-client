import Foundation
import YSwift

// MARK: - Documents: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/documentsApi.d.ts`) so the two surfaces line up field-for-field.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes — rather
// than `Date`, so a round-trip never loses precision or reformats. Opaque,
// platform-untouched blobs are typed as `JSONValue` (see JSONValue.swift).

// MARK: Aliases

/// Document alias scope. Only `.user` is supported — app-scoped aliases were
/// removed in #1168 (they conferred no access and named a document every caller
/// had to already be permitted to open).
public enum DocumentAliasScope: String, Codable, Sendable {
    case user
}

/// A reference to an alias used when resolving, setting, or creating.
/// For `scope == .user`, `userId` defaults to the current user when omitted.
public struct AliasRef: Codable, Sendable, Equatable {
    public let scope: DocumentAliasScope
    public let aliasKey: String
    public let userId: String?

    public init(scope: DocumentAliasScope, aliasKey: String, userId: String? = nil) {
        self.scope = scope
        self.aliasKey = aliasKey
        self.userId = userId
    }
}

/// A resolved document alias.
public struct DocumentAliasInfo: Decodable, Sendable, Equatable {
    public let aliasKey: String
    public let scope: DocumentAliasScope
    public let documentId: String
    public let userId: String?
    public let createdAt: String?
    public let updatedAt: String?
}

/// Parameters for `aliases.set`.
public struct SetAliasParams: Encodable, Sendable {
    public let scope: DocumentAliasScope
    public let aliasKey: String
    public let documentId: String
    public let userId: String?
    public let mustNotExist: Bool?

    public init(
        scope: DocumentAliasScope,
        aliasKey: String,
        documentId: String,
        userId: String? = nil,
        mustNotExist: Bool? = nil
    ) {
        self.scope = scope
        self.aliasKey = aliasKey
        self.documentId = documentId
        self.userId = userId
        self.mustNotExist = mustNotExist
    }
}

// MARK: Document metadata

/// Metadata for a single document. Mirrors JS `DocumentInfo`.
public struct DocumentInfo: Decodable, Sendable, Equatable {
    public let documentId: String
    public let title: String
    public let createdBy: String
    public let createdAt: String
    /// ISO timestamp of the last modification. Decoded from the server's
    /// `modifiedAt` field when `lastModified` is absent, so the typed
    /// surface matches the JS client's `lastModified` either way.
    public let lastModified: String
    public let permission: DocumentPermission
    public let invitationAccepted: Bool?
    public let upgradedFromPermission: String?
    public let grantedAt: String?
    public let tags: [String]?
    /// Optional reference to a Blob owned by this document.
    public let thumbnailBlobId: String?
    /// Opaque, round-tripped metadata blob (≤ 4 KB). The platform does not
    /// introspect it; the shape is the caller's to define.
    public let metadata: JSONValue?
    /// How the caller's effective permission was obtained. Only the
    /// single-document GET populates this; `nil` on list entries.
    public let accessSource: DocumentAccessSource?
    /// The document's "anyone with the link" access level, or `nil` when link
    /// access is off. Visible to everyone who can open the document.
    ///
    /// To read this for a document you can *manage* but not read (an app owner
    /// inspecting a member's private document), use
    /// `documents.getLinkAccess(documentId:)` — the document GET is gated on
    /// content access and would fail.
    public let linkAccess: DocumentLinkAccessLevel?

    private enum CodingKeys: String, CodingKey {
        case documentId, title, createdBy, createdAt
        case lastModified, modifiedAt
        case permission, invitationAccepted, upgradedFromPermission
        case grantedAt, tags, thumbnailBlobId, metadata
        case accessSource, linkAccess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentId = try c.decode(String.self, forKey: .documentId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
            ?? c.decodeIfPresent(String.self, forKey: .modifiedAt) ?? ""
        permission = try c.decodeIfPresent(DocumentPermission.self, forKey: .permission) ?? .reader
        invitationAccepted = try c.decodeIfPresent(Bool.self, forKey: .invitationAccepted)
        upgradedFromPermission = try c.decodeIfPresent(String.self, forKey: .upgradedFromPermission)
        grantedAt = try c.decodeIfPresent(String.self, forKey: .grantedAt)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        thumbnailBlobId = try c.decodeIfPresent(String.self, forKey: .thumbnailBlobId)
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        accessSource = try c.decodeIfPresent(DocumentAccessSource.self, forKey: .accessSource)
        linkAccess = try c.decodeIfPresent(DocumentLinkAccessLevel.self, forKey: .linkAccess)
    }
}

/// A page of documents with an optional pagination cursor. Decodes from
/// either an `items` or legacy `documents` envelope key.
public struct DocumentListPage: Decodable, Sendable, Equatable {
    public let items: [DocumentInfo]
    /// Continuation token for the next page (#1316).
    public let nextCursor: String?
    /// True when a next page exists (#1316).
    public let hasMore: Bool
    /// Deprecated alias of `nextCursor` kept for one deprecation window (#1316).
    public let cursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, documents, cursor, nextCursor, hasMore
    }

    public init(
        items: [DocumentInfo],
        cursor: String? = nil,
        nextCursor: String? = nil,
        hasMore: Bool? = nil
    ) {
        self.items = items
        let next = nextCursor ?? cursor
        self.nextCursor = next
        self.cursor = next
        self.hasMore = hasMore ?? (next != nil)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([DocumentInfo].self, forKey: .items)
            ?? c.decodeIfPresent([DocumentInfo].self, forKey: .documents) ?? []
        // #1316: prefer `nextCursor`; `cursor` is the deprecated alias.
        let next = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .cursor)
        nextCursor = next
        cursor = next
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? (next != nil)
    }
}

// MARK: YDocument confinement

/// The one holder that carries a live `YDocument` across an isolation
/// boundary, and the one place the safety argument for doing so is written
/// down (#1992, Phase C).
///
/// `YDocument` (from the `YSwift` fork) is a reference type wrapping yrs FFI
/// state and is not `Sendable`. Rather than let each type that needs to hand a
/// document to another isolation domain grow its own `@unchecked Sendable`
/// conformance — which is how two holders with two different (and
/// unverifiable) arguments appear — every such type wraps the document in this
/// value and becomes plainly `Sendable` itself. `OpenDocumentResult` below is
/// the first adopter; `DocumentManager`'s document handoffs are the next
/// (#1993, Phase D).
///
/// ## `@unchecked Sendable` — safety argument
///
/// - `document` is a `let`; the holder itself has no mutable state, so
///   *transferring* it is a copy of one reference and nothing else.
/// - The document it points at is **lock-confined, not isolation-confined**:
///   every raw-FFI mutation and every read on `YDocument` runs inside
///   `withExclusiveAccess` / `transact` / `transactSync`, all of which
///   serialize on the document's single `ffiLock`
///   (`yswift-fork/Sources/YSwift/YDocument.swift:53,61`). That lock is an
///   `NSRecursiveLock` **by design** — the observer path re-enters it while a
///   transaction on the same thread is open — so the guarantee is mutual
///   exclusion between threads, not non-reentrancy on one thread.
/// - So two isolation domains holding the same document is safe in exactly the
///   way two threads holding it is safe: their operations interleave at
///   transaction granularity under `ffiLock`. What it does NOT give you is
///   ordering across the sync and async transaction paths, which serialize on
///   separate queues — never split one logical batch across `transact` and
///   `transactSync` (the same invariant `DynamicModel` records).
///
/// Unwrapping is deliberately explicit (`.document`) so a reviewer can grep
/// for the points where a confined document re-enters ordinary code.
public struct ConfinedYDocument: @unchecked Sendable {
    /// The live, editable document. Every access still goes through the
    /// document's own transaction API, which takes `ffiLock`.
    public let document: YDocument

    public init(_ document: YDocument) {
        self.document = document
    }
}

// MARK: Open results

/// Result of `documents.open` / `documents.openAlias` / `documents.openRoot`.
/// Mirrors js-bao's `{ doc, metadata }` return shape (`documentsApi.ts`'s
/// `open`/`openAlias`): the live `YDocument` plus the document's locally
/// cached metadata at open time (`nil` when no metadata is stored yet).
///
/// Plainly `Sendable` since #1992: the live document is carried in a
/// `ConfinedYDocument`, so this type owns no unchecked claim of its own and
/// the compiler checks the rest (`LocalMetadataEntry` is `Sendable`).
public struct OpenDocumentResult: Sendable {
    /// The live document, in the shared confinement holder. Prefer `doc` for
    /// ordinary use; reach for this when you need to pass the document on to
    /// another isolation domain without re-stating the safety argument.
    public let confinedDoc: ConfinedYDocument

    /// The live, editable document.
    public var doc: YDocument { confinedDoc.document }

    /// Locally cached metadata for the document at open time, or `nil` when
    /// none is stored.
    public let metadata: LocalMetadataEntry?

    public init(doc: YDocument, metadata: LocalMetadataEntry?) {
        self.confinedDoc = ConfinedYDocument(doc)
        self.metadata = metadata
    }
}

// MARK: List inputs

/// Options for the deprecated `documents.list(options:)`. Mirrors js-bao's
/// `DocumentListOptions` for the fields Swift implements, so the deprecated
/// surface lines up across platforms.
///
/// Deprecated alongside `documents.list` — migrate to
/// `client.me.ownedDocuments(...)` / `client.me.sharedDocuments(...)`.
///
/// The five never-implemented fields (`refreshFromServer`, `localOnly`,
/// `serverTimeoutMs`, `waitForLoad`, `returnPage`) were deprecated in #2360 and
/// removed in #2367. `documents.list` is a blocking server fetch: the
/// local-first behavior those fields described lives on
/// `client.me.ownedDocuments(...)`, and the `{ items, cursor }` page shape lives
/// on `documents.listPage(...)`.
public struct ListDocumentsOptions: Sendable {
    /// Include the app's root document in results (excluded by default).
    public var includeRoot: Bool?

    /// Maximum number of documents per page (enables server-side pagination).
    public var limit: Int?
    /// Pagination cursor from a previous response.
    public var cursor: String?
    /// Filter results to documents carrying this tag.
    public var tag: String?
    /// Sort chronologically (oldest first) instead of reverse-chronological.
    public var forward: Bool?

    public init(
        includeRoot: Bool? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        tag: String? = nil,
        forward: Bool? = nil
    ) {
        self.includeRoot = includeRoot
        self.limit = limit
        self.cursor = cursor
        self.tag = tag
        self.forward = forward
    }
}

// MARK: Create / update inputs
//
// `CreateDocumentOptions` lives in Options.swift (it predates this file and
// is shared with `JsBaoClient.createDocument`); it gained a `metadata` field
// and `Encodable` conformance there.

/// Options for `createWithAlias` — title and alias are both required.
public struct CreateWithAliasOptions: Encodable, Sendable {
    public var title: String
    public var alias: AliasRef

    public init(title: String, alias: AliasRef) {
        self.title = title
        self.alias = alias
    }
}

/// Options for `getOrCreateWithAlias`.
public struct GetOrCreateWithAliasOptions: Encodable, Sendable {
    public var alias: AliasRef
    public var title: String?
    public var tags: [String]?

    public init(alias: AliasRef, title: String? = nil, tags: [String]? = nil) {
        self.alias = alias
        self.title = title
        self.tags = tags
    }
}

/// Metadata fields to change on `update`. All keys use replace semantics:
/// omit a property to leave it unchanged. `thumbnailBlobId` and `metadata`
/// are clearable — pass `.clear` / `.null` respectively to null them out.
public struct UpdateDocumentData: Encodable, Sendable {
    public var title: String?
    /// `.value("blob123")` to set, `.clear` to remove, omit to leave as-is.
    public var thumbnailBlobId: Updatable<String>?
    /// A concrete value to set, `.null` to clear, `nil` to leave unchanged.
    public var metadata: JSONValue?

    public init(
        title: String? = nil,
        thumbnailBlobId: Updatable<String>? = nil,
        metadata: JSONValue? = nil
    ) {
        self.title = title
        self.thumbnailBlobId = thumbnailBlobId
        self.metadata = metadata
    }
}

/// Options for `delete`.
public struct DeleteDocumentOptions: Encodable, Sendable {
    /// Close the document first if it's currently open (otherwise deleting
    /// an open doc throws).
    public var forceCloseIfOpen: Bool?

    public init(forceCloseIfOpen: Bool? = nil) {
        self.forceCloseIfOpen = forceCloseIfOpen
    }
}

// MARK: Create / alias results

/// Result of `create`. Mirrors JS `Promise<{ metadata }>` — note `create`
/// returns *only* the metadata blob, not the document id.
public struct CreateDocumentResult: Decodable, Sendable {
    public let metadata: JSONValue?
}

// MARK: - Local-data eviction options
//
// `EvictDocumentOptions` (`{ force }`) lives in `Options.swift`.

/// Options for `documents.evictAll(options:)`. Mirrors js-bao's
/// `EvictAllDocumentsOptions` (`{ onlySynced }`).
public struct EvictAllDocumentsOptions: Sendable {
    /// Only evict documents whose local state is fully synced with the
    /// server, preserving any with unsynced local changes.
    public var onlySynced: Bool

    public init(onlySynced: Bool = false) {
        self.onlySynced = onlySynced
    }
}

// MARK: - Pending-create options & results

/// A document created locally but not yet committed to the server.
/// Mirrors js-bao's `listPendingCreates()` entry shape
/// (`{ documentId, title?, createdAt }`).
public struct PendingCreateInfo: Sendable, Equatable {
    public let documentId: String
    public let title: String?
    public let createdAt: String

    public init(documentId: String, title: String? = nil, createdAt: String = "") {
        self.documentId = documentId
        self.title = title
        self.createdAt = createdAt
    }
}

/// Behavior when `commitOfflineCreate` finds the document already exists on
/// the server. Mirrors js-bao's `{ onExists: "link" | "fail" }`.
public enum DocumentExistsPolicy: String, Sendable {
    /// Treat the existing server doc as the destination and clear the
    /// pending-create flag (the local-first default in js-bao).
    case link
    /// Surface the conflict via `reason: "exists"` without linking.
    case fail
}

/// Options for `documents.commitOfflineCreate(documentId:options:)`.
public struct CommitOfflineCreateOptions: Sendable {
    public var onExists: DocumentExistsPolicy

    public init(onExists: DocumentExistsPolicy = .link) {
        self.onExists = onExists
    }
}

/// Result of `documents.commitOfflineCreate`. Mirrors js-bao's
/// `{ created, linked?, reason? }`.
public struct CommitOfflineCreateResult: Sendable, Equatable {
    /// `true` when the document was freshly created on the server.
    public let created: Bool
    /// `true` when the local doc was linked to a pre-existing server doc
    /// (`onExists: .link`).
    public let linked: Bool?
    /// Failure / no-op reason: `"not_pending"`, `"exists"`, or a server
    /// error message. `nil` on success.
    public let reason: String?

    public init(created: Bool, linked: Bool? = nil, reason: String? = nil) {
        self.created = created
        self.linked = linked
        self.reason = reason
    }
}

/// Options for `documents.cancelPendingCreate(documentId:options:)`.
/// Mirrors js-bao's `{ evictLocal }`.
public struct CancelPendingCreateOptions: Sendable {
    /// Also evict the document's local data after cancelling the pending
    /// create.
    public var evictLocal: Bool

    public init(evictLocal: Bool = false) {
        self.evictLocal = evictLocal
    }
}

/// Result of `createWithAlias`.
public struct CreateWithAliasResult: Decodable, Sendable {
    public let documentId: String
    public let title: String?
    public let createdBy: String?
    public let createdAt: String?
    public let modifiedAt: String?
    public let alias: DocumentAliasInfo
}

/// Result of `getOrCreateWithAlias`. `created` reports whether a new
/// document was made (vs. an existing alias being resolved).
public struct GetOrCreateWithAliasResult: Decodable, Sendable {
    public let documentId: String
    public let title: String?
    public let createdBy: String?
    public let createdAt: String?
    public let modifiedAt: String?
    public let alias: DocumentAliasInfo
    public let created: Bool
}

// MARK: Permissions

/// Target for `documents.removePermission` — mirrors js-bao's
/// `string | { userId } | { email }` union. A bare string literal is a user id
/// (`"u1"` → `.userId("u1")`), matching JS where a bare string targets a user.
public enum DocumentPermissionTarget: Sendable, ExpressibleByStringLiteral {
    case userId(String)
    case email(String)
    public init(stringLiteral value: String) { self = .userId(value) }
}

// MARK: Link access ("anyone with the link")

/// The level an "anyone with the link" share confers. Mirrors js-bao's
/// `"reader" | "read-write"` union on `documents.setLinkAccess`. A deliberate
/// subset of `DocumentPermission`: link access can never confer `owner` or
/// `admin`.
public enum DocumentLinkAccessLevel: String, Codable, Sendable {
    case reader
    case readWrite = "read-write"
}

/// How the caller's effective permission on a document was obtained. Mirrors
/// js-bao's `DocumentInfo.accessSource`. `.link` means the level came from the
/// document's "anyone with the link" access floor rather than an explicit
/// grant — a link-opened document does NOT appear in `me/shared-documents`, so
/// an app that wants a "get back to it" affordance must track it itself.
public enum DocumentAccessSource: String, Codable, Sendable {
    case owner
    case grant
    case group
    case link
}

/// Result of `documents.setLinkAccess` / `clearLinkAccess` / `getLinkAccess`.
/// Mirrors js-bao's `LinkAccessResult`. `linkAccess` is `nil` when link access
/// is off — which is what `clearLinkAccess` always returns.
///
/// `linkAccessUpdatedBy` / `linkAccessUpdatedAt` are absent for a document
/// whose link access has never been set, and the server's clear response omits
/// them too, so both stay optional.
public struct LinkAccessResult: Decodable, Sendable, Equatable {
    public let documentId: String
    public let linkAccess: DocumentLinkAccessLevel?
    public let linkAccessUpdatedBy: String?
    public let linkAccessUpdatedAt: String?
}

/// A user's permission entry on a document.
///
/// `name` is `nil` for a user who has none — the server omits the key rather
/// than sending an empty string, and a user provisioned through the
/// email-code flow gets no name (#2980) — so display code should fall back
/// to `email`. Mirrors js-bao's `DocumentPermissionEntry.name?: string`.
public struct DocumentPermissionEntry: Decodable, Sendable, Equatable {
    public let userId: String
    public let email: String
    public let name: String?
    public let permission: DocumentPermission
    public let grantedAt: String
}

/// A group's permission entry on a document.
public struct DocumentGroupPermissionEntry: Decodable, Sendable, Equatable {
    public let documentId: String
    public let groupType: String
    public let groupId: String
    public let permission: String
    public let grantedAt: String
    public let grantedBy: String
}

/// Parameters for `grantGroupPermission`.
public struct GrantGroupPermissionParams: Encodable, Sendable {
    public var groupType: String
    public var groupId: String
    public var permission: String

    public init(groupType: String, groupId: String, permission: String) {
        self.groupType = groupType
        self.groupId = groupId
        self.permission = permission
    }
}

/// Update document permissions for one user, or a batch. Use the
/// `.user`, `.email`, or `.batch` factory for the common cases.
public struct UpdatePermissionsData: Encodable, Sendable {
    public var userId: String?
    public var email: String?
    public var permission: String?
    public var permissions: [PermissionAssignment]?
    public var sendEmail: Bool?
    public var documentUrl: String?
    public var note: String?

    public init(
        userId: String? = nil,
        email: String? = nil,
        permission: String? = nil,
        permissions: [PermissionAssignment]? = nil,
        sendEmail: Bool? = nil,
        documentUrl: String? = nil,
        note: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.permission = permission
        self.permissions = permissions
        self.sendEmail = sendEmail
        self.documentUrl = documentUrl
        self.note = note
    }

    /// Grant/change an existing app user's permission by id.
    public static func user(
        _ userId: String,
        permission: String,
        sendEmail: Bool? = nil,
        documentUrl: String? = nil,
        note: String? = nil
    ) -> UpdatePermissionsData {
        UpdatePermissionsData(userId: userId, permission: permission, sendEmail: sendEmail, documentUrl: documentUrl, note: note)
    }

    /// Share by email (routes through the deferred-grant flow for
    /// not-yet-registered recipients).
    public static func email(
        _ email: String,
        permission: String,
        sendEmail: Bool? = nil,
        documentUrl: String? = nil,
        note: String? = nil
    ) -> UpdatePermissionsData {
        UpdatePermissionsData(email: email, permission: permission, sendEmail: sendEmail, documentUrl: documentUrl, note: note)
    }

    /// Apply several assignments in one call.
    public static func batch(
        _ permissions: [PermissionAssignment],
        sendEmail: Bool? = nil,
        documentUrl: String? = nil,
        note: String? = nil
    ) -> UpdatePermissionsData {
        UpdatePermissionsData(permissions: permissions, sendEmail: sendEmail, documentUrl: documentUrl, note: note)
    }
}

/// A single user/permission pair for a batch permission update.
public struct PermissionAssignment: Encodable, Sendable {
    public var userId: String?
    public var email: String?
    public var permission: String

    public init(userId: String? = nil, email: String? = nil, permission: String) {
        self.userId = userId
        self.email = email
        self.permission = permission
    }
}

/// Result of a direct permission grant (recipient already in the app).
public struct DirectPermissionGrant: Decodable, Sendable {
    /// `"granted"` or `"updated"`.
    public let status: String
    public let userId: String
    public let permission: String
}

/// Result of a deferred permission grant (recipient not yet in the app).
public struct DeferredPermissionGrant: Decodable, Sendable {
    public let email: String
    public let permission: String
    /// Always `"pending_signup"`.
    public let status: String
    public let appInvitationCreated: Bool
    public let invitationId: String
    /// Tokenized accept token; combine with your accept-page URL to build a
    /// CTA for custom invitation emails. May be `null`.
    public let inviteToken: String?
}

/// One entry in a `PermissionUpdateResult.results` array — either a direct
/// or a deferred grant, distinguished by `status`.
public enum PermissionGrant: Decodable, Sendable {
    case direct(DirectPermissionGrant)
    case deferred(DeferredPermissionGrant)

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decodeIfPresent(String.self, forKey: .status)
        if status == "pending_signup" {
            self = .deferred(try DeferredPermissionGrant(from: decoder))
        } else {
            self = .direct(try DirectPermissionGrant(from: decoder))
        }
    }
}

/// Response from `updatePermissions`.
public struct PermissionUpdateResult: Decodable, Sendable {
    public let success: Bool
    public let message: String
    /// Present when the response includes deferred (email-based) grants.
    public let results: [PermissionGrant]?
}

// MARK: Access

/// Result of `validateAccess` / the deprecated `acceptInvitation`.
public struct DocumentAccessResult: Decodable, Sendable {
    public let success: Bool
    public let hasAccess: Bool
    public let permission: DocumentPermission?
    public let viaInvitation: Bool?
    public let invitationAccepted: Bool?
    public let upgradedFromPermission: String?
    public let error: String?
}

/// A request from a user for access to a document they can't currently see.
public struct DocumentAccessRequest: Decodable, Sendable {
    public let requestId: String
    public let documentId: String
    public let requesterId: String
    /// `"pending"`, `"approved"`, or `"denied"`.
    public let status: String
    /// `"read-write"` or `"reader"`.
    public let requestedPermission: String
    public let message: String?
    public let createdAt: String
    public let resolvedBy: String?
    public let resolvedAt: String?
    public let grantedPermission: String?
}

/// A short document summary attached to an access-request response.
public struct AccessRequestDocumentSummary: Decodable, Sendable {
    public let documentId: String?
    public let title: String?
    public let tags: [String]?
    public let createdAt: String?
    public let lastModified: String?
    public let createdBy: String?
}

/// Response from `requestAccess`.
public struct DocumentAccessRequestResponse: Decodable, Sendable {
    public let success: Bool
    public let message: String
    public let request: DocumentAccessRequest
    public let document: AccessRequestDocumentSummary?
}

/// Response from `approveAccessRequest` / `denyAccessRequest`.
public struct AccessRequestResult: Decodable, Sendable {
    public let success: Bool
    public let message: String
    public let request: DocumentAccessRequest
}

/// Options for `requestAccess`.
public struct RequestAccessOptions: Encodable, Sendable {
    /// `.readWrite` or `.reader`.
    public var permission: DocumentPermission
    public var message: String?
    public var documentUrl: String?
    public var reviewUrl: String?
    public var sendEmail: Bool?

    public init(
        permission: DocumentPermission,
        message: String? = nil,
        documentUrl: String? = nil,
        reviewUrl: String? = nil,
        sendEmail: Bool? = nil
    ) {
        self.permission = permission
        self.message = message
        self.documentUrl = documentUrl
        self.reviewUrl = reviewUrl
        self.sendEmail = sendEmail
    }
}

/// Options for `approveAccessRequest`.
public struct ApproveAccessRequestOptions: Encodable, Sendable {
    public var permission: DocumentPermission?
    public var documentUrl: String?

    public init(permission: DocumentPermission? = nil, documentUrl: String? = nil) {
        self.permission = permission
        self.documentUrl = documentUrl
    }
}

/// Options for `denyAccessRequest`.
public struct DenyAccessRequestOptions: Encodable, Sendable {
    public var documentUrl: String?

    public init(documentUrl: String? = nil) {
        self.documentUrl = documentUrl
    }
}

// MARK: Invitations (pending + legacy)

/// A pending (deferred) invitation scoped to a single document.
public struct PendingInvitationEntry: Decodable, Sendable {
    public let email: String
    public let permission: String
    public let invitationId: String
    public let createdAt: String
    public let expiresAt: String
    public let grantedBy: String?
}

/// A legacy per-document invitation row.
public struct DocumentInvitation: Decodable, Sendable {
    public let invitationId: String
    public let documentId: String?
    public let email: String
    public let permission: String
    public let invitedBy: String
    public let invitedAt: String
    public let expiresAt: String?
    public let accepted: Bool
    public let acceptedAt: String?
}

/// Response from the deprecated `sendInvitation` / `updateInvitation`.
public struct DocumentInvitationResponse: Decodable, Sendable {
    public let success: Bool
    public let message: String
    public let invitationId: String
    public let email: String
    public let permission: String
    public let invitedBy: String
    public let invitedAt: String
    public let expiresAt: String
}

/// Optional email-notification settings for the deprecated invitation verbs.
public struct InvitationEmailOptions: Encodable, Sendable {
    public var sendEmail: Bool?
    public var documentUrl: String?
    public var note: String?

    public init(sendEmail: Bool? = nil, documentUrl: String? = nil, note: String? = nil) {
        self.sendEmail = sendEmail
        self.documentUrl = documentUrl
        self.note = note
    }
}

// MARK: Small result wrappers

/// `{ success }` — returned by `revokeGroupPermission`.
public struct SuccessResult: Decodable, Sendable {
    public let success: Bool
}

/// `{ success, message }` — returned by the deprecated `declineInvitation`
/// and `deleteInvitation`.
public struct MessageResult: Decodable, Sendable {
    public let success: Bool
    public let message: String
}

/// `{ evicted }` — returned by `close`. `evicted` is `true` only when the
/// document's local data was actually evicted; it is skipped (and reported
/// `false`) when local writes were still outstanding at close time.
public struct CloseDocumentResult: Sendable {
    public let evicted: Bool
    public init(evicted: Bool) { self.evicted = evicted }
}
