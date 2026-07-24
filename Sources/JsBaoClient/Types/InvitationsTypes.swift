import Foundation

// MARK: - Invitations: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/invitationsApi.d.ts`) field-for-field. Timestamps stay ISO-8601
// `String`s — exactly what JS exposes. Opaque, untouched-by-the-platform
// fields would be `JSONValue` (none here). The deferred-grant union is
// modeled as a discriminated enum on `type`, the same shape `PermissionGrant`
// uses in DocumentTypes.swift.

// MARK: App invitations

/// Lifecycle status of an invitation. Returned by `invitations.get()`; not
/// present on list responses. Mirrors JS `AppInvitationInfo.status`.
public enum InvitationStatus: String, Codable, Sendable {
    case pending
    case expired
    case accepted
}

/// A single app-level invitation. Mirrors JS `AppInvitationInfo`.
public struct AppInvitationInfo: Decodable, Sendable, Equatable {
    public let invitationId: String
    public let email: String
    public let role: String
    public let invitedBy: String
    public let invitedAt: String
    public let expiresAt: String?
    public let accepted: Bool
    public let acceptedAt: String?
    public let appId: String?
    public let source: String?
    public let note: String?
    /// Tokenized accept token — combine with your app's accept-page URL to
    /// build a working CTA (e.g. `${baseUrl}/invite/accept?inviteToken=…`).
    /// `null` only for legacy rows not yet upgraded; new invitations always
    /// have one.
    public let inviteToken: String?
    /// Lifecycle status. Returned by `get()`, absent on list responses.
    public let status: InvitationStatus?
}

/// The caller's invitation quota. Admins/owners always get `unlimited: true`.
/// Mirrors JS `InvitationQuota`.
public struct InvitationQuota: Decodable, Sendable, Equatable {
    public let used: Int
    public let limit: Int
    public let remaining: Int
    public let unlimited: Bool
}

/// Parameters for `invitations.create`. Only `email` is required. Mirrors JS
/// `CreateInvitationParams`.
public struct CreateInvitationParams: Encodable, Sendable {
    public var email: String
    public var role: String?
    public var expiresAt: String?
    public var source: String?
    public var note: String?
    public var sendEmail: Bool?

    public init(
        email: String,
        role: String? = nil,
        expiresAt: String? = nil,
        source: String? = nil,
        note: String? = nil,
        sendEmail: Bool? = nil
    ) {
        self.email = email
        self.role = role
        self.expiresAt = expiresAt
        self.source = source
        self.note = note
        self.sendEmail = sendEmail
    }
}

/// A page of app invitations with an optional pagination cursor. Mirrors JS
/// `InvitationListResult` (`{ items, cursor }`).
public struct InvitationListResult: Decodable, Sendable, Equatable {
    public let items: [AppInvitationInfo]
    /// Continuation token for the next page (#1316).
    public let nextCursor: String?
    /// True when a next page exists (#1316).
    public let hasMore: Bool
    /// Deprecated alias of `nextCursor` kept for one deprecation window (#1316).
    public let cursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, cursor, nextCursor, hasMore
    }

    public init(
        items: [AppInvitationInfo],
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
        items = try c.decodeIfPresent([AppInvitationInfo].self, forKey: .items) ?? []
        // #1316: prefer `nextCursor`; `cursor` is the deprecated alias.
        let next = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .cursor)
        nextCursor = next
        cursor = next
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? (next != nil)
    }
}

/// Result of `invitations.delete` — `{ success, message }`.
public struct InvitationDeleteResult: Decodable, Sendable, Equatable {
    public let success: Bool
    public let message: String
}

/// Result of `invitations.accept` (#466). The invitation is marked accepted
/// (write-once) and all linked deferred grants resolve to the authenticated
/// user. Mirrors JS `AcceptInviteResult`.
public struct AcceptInviteResult: Decodable, Sendable, Equatable {
    /// Always `"accepted"`.
    public let status: String
    public let invitationId: String
    public let grantsResolved: GrantsResolved

    /// How many deferred grants of each kind resolved on accept.
    public struct GrantsResolved: Decodable, Sendable, Equatable {
        public let groups: Int
        public let documents: Int
    }
}

// MARK: Deferred grants

/// Discriminant for a deferred grant — document- vs group-scoped. Mirrors the
/// JS `"document" | "group"` literal used both on the grant union and the
/// `revokeDeferredGrant` / `listDeferredGrants` `type` parameter.
public enum DeferredGrantType: String, Codable, Sendable {
    case document
    case group
}

/// A deferred document-permission grant (recipient not yet signed up).
/// Mirrors JS `DeferredDocumentGrant`.
public struct DeferredDocumentGrant: Decodable, Sendable, Equatable {
    public let deferredId: String
    /// Always `.document`.
    public let type: DeferredGrantType
    public let email: String
    public let documentId: String
    public let permission: String
    public let grantedBy: String
    public let createdAt: String
    public let expiresAt: String
}

/// A deferred group-membership grant (recipient not yet signed up).
/// Mirrors JS `DeferredGroupGrant`.
public struct DeferredGroupGrant: Decodable, Sendable, Equatable {
    public let deferredId: String
    /// Always `.group`.
    public let type: DeferredGrantType
    public let email: String
    public let groupType: String
    public let groupId: String
    public let addedBy: String
    public let createdAt: String
    public let expiresAt: String
}

/// One entry in `listDeferredGrants` — a document- or group-scoped grant,
/// discriminated on `type`. Mirrors the JS `DeferredGrant` union.
public enum DeferredGrant: Decodable, Sendable, Equatable {
    case document(DeferredDocumentGrant)
    case group(DeferredGroupGrant)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(DeferredGrantType.self, forKey: .type)
        switch type {
        case .document: self = .document(try DeferredDocumentGrant(from: decoder))
        case .group: self = .group(try DeferredGroupGrant(from: decoder))
        }
    }

    /// The `deferredId`, regardless of variant — handy for the `revoke` call.
    public var deferredId: String {
        switch self {
        case let .document(g): return g.deferredId
        case let .group(g): return g.deferredId
        }
    }

    /// The grant's discriminant, regardless of variant.
    public var type: DeferredGrantType {
        switch self {
        case .document: return .document
        case .group: return .group
        }
    }
}

/// A page of deferred grants. Mirrors JS `DeferredGrantListResult`.
/// As of #1316 the server emits the unified `{ items, hasMore, nextCursor }`
/// envelope with `grants` kept as a legacy alias of `items` for one
/// deprecation window; the cursor is a real position token (previously a
/// non-functional `"more"` sentinel).
public struct DeferredGrantListResult: Decodable, Sendable, Equatable {
    public let grants: [DeferredGrant]
    public let nextCursor: String?
    /// True when a next page exists (#1316).
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case grants, items, nextCursor, hasMore
    }

    public init(grants: [DeferredGrant], nextCursor: String? = nil, hasMore: Bool? = nil) {
        self.grants = grants
        self.nextCursor = nextCursor
        self.hasMore = hasMore ?? (nextCursor != nil)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grants = try c.decodeIfPresent([DeferredGrant].self, forKey: .items)
            ?? c.decodeIfPresent([DeferredGrant].self, forKey: .grants) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? (nextCursor != nil)
    }
}

/// Result of `revokeDeferredGrant` — `{ status, deferredId }`. Mirrors JS
/// `DeferredGrantRevokeResult`.
public struct DeferredGrantRevokeResult: Decodable, Sendable, Equatable {
    /// Always `"revoked"`.
    public let status: String
    public let deferredId: String
}
