import Foundation

// MARK: - Me: typed request & response models
//
// These mirror the interfaces published by the JS client (`api/meApi.d.ts`)
// so the two surfaces line up field-for-field (issue #954). Timestamps stay
// as ISO-8601 `String`s — exactly what JS exposes. Document rows reuse
// `DocumentInfo` (DocumentTypes.swift); `SharedDocument` layers the
// shared-only extras on top, matching JS's `extends DocumentInfo`.

// MARK: Profile

/// Cache metadata for the `me` profile entry. Mirrors js-bao's
/// `{ updatedAt?, ageMs? }` object.
public struct MeCacheInfo: Sendable, Equatable {
    public let updatedAt: String?
    public let ageMs: Double?
    public init(updatedAt: String?, ageMs: Double?) {
        self.updatedAt = updatedAt
        self.ageMs = ageMs
    }
}

/// The signed-in user's profile. Mirrors JS `UserProfile`.
public struct UserProfile: Decodable, Sendable, Equatable {
    public let userId: String
    public let email: String
    /// Optional: `User.name` isn't required in models.yaml and `me-controller.ts`
    /// omits the key when unset (JS types it `string` but never enforces it).
    public let name: String?
    public let avatarUrl: String?
    public let appRole: String
    public let appId: String
}

/// Parameters for `me.update(params:)`. Mirrors JS `UpdateMeParams`.
///
/// `avatarUrl` is clearable: pass `.value(url)` to set, `.clear` to remove the
/// current avatar (JS `avatarUrl: null`), or omit (`nil`) to leave it unchanged.
public struct UpdateMeParams: Encodable, Sendable {
    public var name: String?
    public var avatarUrl: Updatable<String>?

    public init(name: String? = nil, avatarUrl: Updatable<String>? = nil) {
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

/// Result of `me.uploadAvatar(...)`. Mirrors JS `{ avatarUrl }`.
public struct AvatarUploadResult: Decodable, Sendable, Equatable {
    public let avatarUrl: String
}

/// MIME type accepted by `me.uploadAvatar(...)`. Mirrors JS's typed union
/// `"image/png" | "image/jpeg" | "image/gif" | "image/webp"` — the four
/// formats the avatar endpoint accepts. Modeling it as an enum (rawValue =
/// the MIME string sent in the `Content-Type` header) makes an invalid MIME
/// a compile error instead of a server-side 4xx, matching the JS surface.
public enum AvatarContentType: String, Sendable, Equatable, CaseIterable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webp = "image/webp"
}

// MARK: Owned / shared document list options (issue #628)

/// Options for `me.ownedDocuments(...)`. Mirrors JS `OwnedDocumentsOptions`,
/// which itself mirrors the legacy `documents.list(...)` option set so the
/// owner-only reader has cache-aware / offline-first parity.
///
/// Field-for-field with JS:
/// - `includeRoot` — include the app's root document (excluded by default);
///   sent as `includeRoot=true` in the query.
/// - `refreshFromServer` — when `false`, skip the server and return only
///   cached metadata (defaults to `true`). `localOnly: true` forces this off.
/// - `localOnly` — return only docs with local data on this device, ignoring
///   the server entirely.
/// - `serverTimeoutMs` — max time to wait for the server response
///   (JS default 10000).
/// - `waitForLoad` — cache-read strategy.
/// - `forward` — chronological order (oldest first); sent as `forward=true`.
/// - `returnPage` — return a `DocumentListPage` (cursor) instead of a flat
///   array. Surfaced in Swift as the separate `ownedDocumentsPage(...)`
///   overload rather than a union return; this flag mirrors the JS field for
///   completeness but the page-returning entry point is the canonical way to
///   get a cursor in Swift.
///
/// `cursor`/`limit`/`tag` stay as positional params on `ownedDocuments(...)`
/// (they already existed); this struct carries only the additive fields.
public struct MeOwnedDocumentsOptions: Sendable, Equatable {
    public var includeRoot: Bool?
    public var refreshFromServer: Bool?
    public var localOnly: Bool?
    public var serverTimeoutMs: Int?
    public var waitForLoad: WaitForLoadMode?
    public var forward: Bool?
    public var returnPage: Bool?

    public init(
        includeRoot: Bool? = nil,
        refreshFromServer: Bool? = nil,
        localOnly: Bool? = nil,
        serverTimeoutMs: Int? = nil,
        waitForLoad: WaitForLoadMode? = nil,
        forward: Bool? = nil,
        returnPage: Bool? = nil
    ) {
        self.includeRoot = includeRoot
        self.refreshFromServer = refreshFromServer
        self.localOnly = localOnly
        self.serverTimeoutMs = serverTimeoutMs
        self.waitForLoad = waitForLoad
        self.forward = forward
        self.returnPage = returnPage
    }
}

// MARK: Document lists

/// A document shared with the current user. Mirrors JS `SharedDocument`,
/// which `extends DocumentInfo`: the base document fields plus the
/// shared-only extras. Swift can't inherit a struct, so the base
/// `DocumentInfo` is decoded inline alongside the extras.
///
/// `permission` is the granted level (never `"owner"` — owned docs surface
/// via `ownedDocuments` instead).
public struct SharedDocument: Decodable, Sendable, Equatable {
    /// The base document fields (documentId, title, permission, …).
    public let document: DocumentInfo
    /// Who granted access (the actor) — always present on shared rows.
    public let grantedBy: String
    /// `"permission"` for accepted shares, `"invitation"` for pending legacy
    /// `DocumentInvitation`s.
    public let source: String?
    /// Present when `source == "invitation"` — the pending invitation ID.
    public let invitationId: String?

    private enum CodingKeys: String, CodingKey {
        case grantedBy, source, invitationId
    }

    public init(from decoder: Decoder) throws {
        document = try DocumentInfo(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grantedBy = try c.decodeIfPresent(String.self, forKey: .grantedBy) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        invitationId = try c.decodeIfPresent(String.self, forKey: .invitationId)
    }
}

/// A page of shared documents. Mirrors JS `SharedDocumentListResult`
/// (`{ items, cursor? }`, raw-JSON cursor). Decodes from either an `items`
/// or legacy `documents` envelope key.
public struct SharedDocumentListResult: Decodable, Sendable, Equatable {
    public let items: [SharedDocument]
    public let cursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, documents, cursor
    }

    public init(items: [SharedDocument], cursor: String? = nil) {
        self.items = items
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([SharedDocument].self, forKey: .items)
            ?? c.decodeIfPresent([SharedDocument].self, forKey: .documents) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

// MARK: Pending invitations

/// A short document summary attached to a pending-invitation row.
/// Mirrors the nested `document` object on JS's `pendingDocumentInvitations`.
public struct PendingInvitationDocumentSummary: Decodable, Sendable, Equatable {
    public let documentId: String?
    public let title: String?
    public let tags: [String]?
    public let createdAt: String?
    public let lastModified: String?
    public let createdBy: String?
}

/// A pending document invitation for the current user. Mirrors the element
/// type of JS `me.pendingDocumentInvitations()`.
public struct PendingDocumentInvitation: Decodable, Sendable, Equatable {
    public let invitationId: String
    public let documentId: String
    public let title: String?
    public let email: String
    /// `"owner"`, `"read-write"`, or `"reader"`.
    public let permission: String
    public let invitedAt: String
    public let invitedBy: String
    public let expiresAt: String?
    public let accepted: Bool
    public let document: PendingInvitationDocumentSummary?
}
