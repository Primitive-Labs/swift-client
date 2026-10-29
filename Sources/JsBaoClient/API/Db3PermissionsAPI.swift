import Foundation

/// A db3's sharing, as `client.db3.permissions(_:)`: its users' grants and
/// pending invitations, its groups' grants, its "anyone with the link" level
/// and its access requests. Each call answers what the same call on
/// `client.documents` answers, over the db3's own routes.
///
/// A refusal throws the route's `HttpError`, its `serverCode` naming why:
/// 403 for a caller who may not share, 409 `DB3_SYNC_OFF_NO_SHARING` for a
/// grant on a sync-off db3, 409 `NOT_A_DB3` for a document that is not a db3.
///
/// ```swift
/// let sharing = client.db3.permissions(db3Id)
/// _ = try await sharing.set(.user(bobId, permission: "reader"))
/// try await sharing.setLinkAccess(.reader)
/// let people = try await sharing.list()
/// ```
public final class Db3PermissionsAPI: Sendable {
    /// The db3.
    public let db3Id: String
    private let transport: any Transport
    /// The wait for a pending create of the db3 (#5000).
    private let awaitCreate: @Sendable (String) async throws -> Void

    init(db3Id: String, transport: any Transport, awaitCreate: @escaping @Sendable (String) async throws -> Void = { _ in }) {
        self.db3Id = db3Id
        self.transport = transport
        self.awaitCreate = awaitCreate
    }

    private func path(_ suffix: String) -> String {
        "/db3/\(URLEncoding.encodeComponent(db3Id))/\(suffix)"
    }

    // MARK: - Users

    /// The users with a direct grant on the db3.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func list() async throws -> [DocumentPermissionEntry] {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: path("permissions"))
    }

    /// Grant or change users' levels: one user by id, one email (which
    /// invites someone not yet in the app), or several at once. Build
    /// `params` with `.user(...)`, `.email(...)` or `.batch(...)`.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter params: The grant or grants, with an optional notification email.
    public func set(_ params: UpdatePermissionsData) async throws -> PermissionUpdateResult {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .put, path: path("permissions"), body: params)
    }

    /// Remove a user's grant (a user id, or a string literal), or cancel a
    /// pending invitation (`.email(...)`). Removing your own grant keeps the
    /// db3's copy on this device readable; the room refuses the next subscribe.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter target: The user, or the invited email.
    /// - Throws: `JsBaoError` `.invalidArgument` for an empty user id or email,
    ///   before any request.
    public func remove(_ target: DocumentPermissionTarget) async throws {
        try await awaitCreate(db3Id)
        switch target {
        case let .email(email):
            guard !email.isEmpty else {
                throw JsBaoError(code: .invalidArgument, message: "client.db3.permissions(id).remove: a userId or an email is required")
            }
            var query = URLQuery()
            query.append("email", email)
            try await transport.send(method: .delete, path: path("permissions") + query.queryString)
        case let .userId(userId):
            guard !userId.isEmpty else {
                throw JsBaoError(code: .invalidArgument, message: "client.db3.permissions(id).remove: a userId or an email is required")
            }
            try await transport.send(method: .delete, path: path("permissions/\(URLEncoding.encodeComponent(userId))"))
        }
    }

    /// The invitations sent by email that no one has accepted yet.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func listPendingInvitations() async throws -> [PendingInvitationEntry] {
        try await awaitCreate(db3Id)
        let answer: ItemsEnvelope<PendingInvitationEntry> = try await transport.request(method: .get, path: path("pending-invitations"))
        return answer.items
    }

    // MARK: - Groups

    /// The groups granted the db3. Platform-managed groups (a `groupType`
    /// starting with `_`, such as the db3's app access) are left out unless
    /// `includeSystem`.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter includeSystem: List the platform-managed groups too.
    public func listGroups(includeSystem: Bool = false) async throws -> [DocumentGroupPermissionEntry] {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: path("group-permissions" + (includeSystem ? "?includeSystem=true" : "")))
    }

    /// Grant a group a level on the db3; granting it again changes the level.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter params: The group and the level.
    public func grantGroup(_ params: GrantGroupPermissionParams) async throws -> DocumentGroupPermissionEntry {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .post, path: path("group-permissions"), body: params)
    }

    /// Revoke a group's grant.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter groupId: The group.
    public func revokeGroup(_ groupId: String) async throws -> SuccessResult {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .delete, path: path("group-permissions/\(URLEncoding.encodeComponent(groupId))"))
    }

    // MARK: - Link access

    /// The db3's "anyone with the link" level; `linkAccess` is `nil` when it is off.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func getLinkAccess() async throws -> LinkAccessResult {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: path("link-access"))
    }

    /// Let any signed-in member of the app who has the db3's id read it, or
    /// read and write it.
    /// - Parameter level: `.reader` or `.readWrite`.
    @discardableResult
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func setLinkAccess(_ level: DocumentLinkAccessLevel) async throws -> LinkAccessResult {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .put, path: path("link-access"), body: ["level": level.rawValue])
    }

    /// Turn link access off; explicit grants are unaffected.
    @discardableResult
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func clearLinkAccess() async throws -> LinkAccessResult {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .delete, path: path("link-access"))
    }

    // MARK: - Access requests

    /// Ask the db3's owner for access.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter options: The level asked for, a note, the URLs the
    ///   notification links to, and `sendEmail: false` to send none.
    public func requestAccess(_ options: RequestAccessOptions) async throws -> DocumentAccessRequestResponse {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .post, path: path("access-requests"), body: options)
    }

    /// The pending access requests (the db3's owner and app admins).
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func listAccessRequests() async throws -> [DocumentAccessRequest] {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: path("access-requests"))
    }

    /// Approve an access request, optionally at another level.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameters:
    ///   - requestId: The request.
    ///   - options: The level to grant, and the URL the notification links to.
    public func approveAccessRequest(_ requestId: String, options: ApproveAccessRequestOptions? = nil) async throws -> AccessRequestResult {
        try await awaitCreate(db3Id)
        return try await transport.request(
            method: .post,
            path: path("access-requests/\(URLEncoding.encodeComponent(requestId))/approve"),
            body: options ?? ApproveAccessRequestOptions()
        )
    }

    /// Deny an access request.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameters:
    ///   - requestId: The request.
    ///   - options: The URL the notification links to.
    public func denyAccessRequest(_ requestId: String, options: DenyAccessRequestOptions? = nil) async throws -> AccessRequestResult {
        try await awaitCreate(db3Id)
        return try await transport.request(
            method: .post,
            path: path("access-requests/\(URLEncoding.encodeComponent(requestId))/deny"),
            body: options ?? DenyAccessRequestOptions()
        )
    }
}
