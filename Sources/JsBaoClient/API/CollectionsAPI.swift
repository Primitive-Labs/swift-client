import Foundation

// MARK: - CollectionsAPI

/// Collections: shared sets of documents whose members — users and groups,
/// each a principal — hold fixed roles (`owner`, `manager`, `editor`,
/// `contributor`, `viewer`) under one custodian. Mirrors js-bao's
/// `client.collections`.
public final class CollectionsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - CRUD

    /// Create a new collection. `name` is required. The caller becomes its
    /// custodian and holds `owner`.
    public func create(params: CreateCollectionParams) async throws -> CollectionInfo {
        try await transport.request(method: .post, path: "/collections", body: params)
    }

    /// List collections the caller is a direct member of. Each returned item
    /// carries the caller's `role`. Use `listAll()` for the app-wide set.
    public func list(options: PaginationOptions? = nil) async throws -> PaginatedResult<CollectionInfo> {
        let page: CollectionInfoPage = try await transport.request(
            method: .get,
            path: "/collections\(Self.queryString(options))"
        )
        return PaginatedResult(items: page.items, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    /// List every collection in the app (admin-only). Non-admin callers
    /// receive a 403. Unlike `list()`, returned items do not carry the
    /// caller's `role`. Mirrors js-bao's `collections.listAll(options)`.
    public func listAll(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> PaginatedResult<CollectionInfo> {
        let qs = Self.queryString(PaginationOptions(limit: limit, cursor: cursor))
        let page: CollectionInfoPage = try await transport.request(
            method: .get,
            path: "/admin/collections\(qs)"
        )
        return PaginatedResult(items: page.items, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    /// Get collection info by ID. Callers without any access receive a 404
    /// (to avoid leaking collection existence).
    public func get(collectionId: String) async throws -> CollectionInfo {
        try await transport.request(method: .get, path: "/collections/\(collectionId)")
    }

    /// Update a collection's name, description or settings.
    public func update(collectionId: String, params: UpdateCollectionParams) async throws -> CollectionInfo {
        try await transport.request(method: .patch, path: "/collections/\(collectionId)", body: params)
    }

    /// Delete a collection. Only the owner, or an app owner or admin, may
    /// delete.
    public func delete(collectionId: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: "/collections/\(collectionId)")
    }

    /// Transfers the collection to another member: they become its custodian
    /// and hold `owner`, and the previous owner becomes a manager. Moving a
    /// collection to or from the app is for a server function or the admin
    /// API (403 `CUSTODIAN_NOT_ALLOWED` from a session).
    ///
    /// - Parameter to: the new custodian, `"user:<userId>"`.
    /// - Returns: the collection with its new `custodian`.
    public func transfer(collectionId: String, to: String) async throws -> CollectionInfo {
        try await transport.request(
            method: .post,
            path: "\(Self.path(collectionId))/transfer",
            body: ["to": to]
        )
    }

    // MARK: - Documents

    /// Add a document to a collection.
    public func addDocument(collectionId: String, documentId: String) async throws -> CollectionDocumentInfo {
        try await transport.request(
            method: .post,
            path: "/collections/\(collectionId)/documents",
            body: ["documentId": documentId]
        )
    }

    /// Remove a document from a collection.
    public func removeDocument(collectionId: String, documentId: String) async throws -> SuccessResult {
        try await transport.request(
            method: .delete,
            path: "/collections/\(collectionId)/documents/\(documentId)"
        )
    }

    /// List all documents in a collection, each with the caller's effective
    /// permission.
    public func listDocuments(collectionId: String, options: PaginationOptions? = nil) async throws -> PaginatedResult<CollectionDocumentInfo> {
        let page: CollectionDocumentPage = try await transport.request(
            method: .get,
            path: "/collections/\(collectionId)/documents\(Self.queryString(options))"
        )
        return PaginatedResult(items: page.items, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    /// List collections that contain a specific document. For non-admin
    /// callers this returns only collections the caller is a direct member of.
    public func listCollectionsForDocument(documentId: String, options: PaginationOptions? = nil) async throws -> PaginatedResult<DocumentCollectionInfo> {
        let page: DocumentCollectionPage = try await transport.request(
            method: .get,
            path: "/documents/\(documentId)/collections\(Self.queryString(options))"
        )
        return PaginatedResult(items: page.items, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    // MARK: - Access

    /// Get the current user's access info for a collection (groups + members).
    @available(*, deprecated, message: "Use listMembers(collectionId:), which answers users and groups as principals. Removed by #4718.")
    public func getAccess(collectionId: String) async throws -> CollectionAccessInfo {
        try await transport.request(method: .get, path: "/collections/\(collectionId)/access")
    }

    /// Grant a group a permission level on a collection.
    @available(*, deprecated, message: "Groups are members: use addGroupMember(collectionId:groupId:role:). Removed by #4718.")
    public func grantGroupPermission(collectionId: String, params: GrantCollectionGroupPermissionParams) async throws -> CollectionGroupPermissionInfo {
        try await transport.request(
            method: .post,
            path: "/collections/\(collectionId)/group-permissions",
            body: params
        )
    }

    /// Revoke a group's permission from a collection.
    @available(*, deprecated, message: "Groups are members: use removeMember(collectionId:principal:) with group:<groupId>. Removed by #4718.")
    public func revokeGroupPermission(collectionId: String, groupType: String, groupId: String) async throws -> SuccessResult {
        let gType = URLEncoding.encodeComponent(groupType)
        let gId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .delete,
            path: "/collections/\(collectionId)/group-permissions/\(gType)/\(gId)"
        )
    }

    // MARK: - Members

    /// List every member of a collection — users and groups, each a
    /// principal with its role — in one answer (the list is complete, with
    /// no cursor). A collection whose `settings.memberList` is `managers`
    /// answers 403 to a member below manager.
    public func listMembers(collectionId: String) async throws -> [CollectionMemberEntry] {
        let response: ItemsEnvelope<CollectionMemberEntry> = try await transport.request(
            method: .get,
            path: "\(Self.path(collectionId))/members"
        )
        return response.items
    }

    /// Add a member to a collection by user ID or email, with a role.
    ///
    /// Provide exactly one of `userId` / `email` on `params` (use the
    /// `.user(_:role:…)` / `.email(_:role:…)` factories). Returns a discriminated
    /// union: `.direct` when the target maps to an existing app user
    /// (`status == "added"` / `"already_member"`), or `.deferred` when the
    /// email isn't an app user yet (`status == "pending_signup"`, carrying
    /// the `deferredId` / `invitationId` / `inviteToken`). Mirrors the
    /// deferred-grant flow on `documents.updatePermissions` (issue #671).
    public func addMember(collectionId: String, params: AddCollectionMemberParams) async throws -> CollectionAddMemberResult {
        try await transport.request(
            method: .post,
            path: "/collections/\(collectionId)/members",
            body: params
        )
    }

    /// Give a group a role on a collection, up to `manager`: every member of
    /// the group holds it. The caller must belong to the group.
    public func addGroupMember(collectionId: String, groupId: String, role: CollectionRole) async throws -> CollectionGroupMemberAdd {
        try await transport.request(
            method: .post,
            path: "\(Self.path(collectionId))/members",
            body: ["groupId": groupId, "role": role.rawValue]
        )
    }

    /// Change a member's role. `principal` is a user's id, or
    /// `group:<groupId>` for a group. The `owner` row changes only by
    /// transfer.
    public func setMemberRole(collectionId: String, principal: String, role: CollectionRole) async throws -> CollectionMemberEntry {
        try await transport.request(
            method: .patch,
            path: "\(Self.path(collectionId))/members/\(URLEncoding.encodeComponent(principal))",
            body: ["role": role]
        )
    }

    /// Remove a member — a user's id, or `group:<groupId>` for a group. A
    /// member may remove themselves; the owner cannot leave (403
    /// `OWNER_MUST_TRANSFER`): transfer the collection first.
    public func removeMember(collectionId: String, principal: String) async throws -> SuccessResult {
        try await transport.request(
            method: .delete,
            path: "\(Self.path(collectionId))/members/\(URLEncoding.encodeComponent(principal))"
        )
    }

    /// Remove a member from a collection.
    @available(*, deprecated, message: "Use removeMember(collectionId:principal:). Removed by #4718.")
    public func removeMember(collectionId: String, userId: String) async throws -> SuccessResult {
        try await transport.request(
            method: .delete,
            path: "/collections/\(collectionId)/members/\(userId)"
        )
    }

    /// The caller's role on a collection, or a named user's, and where it
    /// comes from: their own row (`.direct`) or a group. Naming a user other
    /// than the caller needs app authority (403 `SUBJECT_USER_FORBIDDEN`
    /// otherwise). `role` is `nil` when the user holds none.
    public func resolveRole(collectionId: String, userId: String? = nil) async throws -> ResolvedCollectionRole {
        var query = URLQuery()
        query.appendIfPresent("userId", userId)
        return try await transport.request(
            method: .get,
            path: "\(Self.path(collectionId))/role\(query.queryString)"
        )
    }

    // MARK: - Invitations

    /// List pending (unresolved, non-expired) invitations scoped to a
    /// collection. Mirrors js-bao's
    /// `collections.listPendingInvitations(collectionId)`. The server returns
    /// a bare array; an `{ items }` envelope is also accepted defensively.
    public func listPendingInvitations(
        collectionId: String
    ) async throws -> [PendingCollectionInvitationEntry] {
        let response: ItemsEnvelope<PendingCollectionInvitationEntry> = try await transport.request(
            method: .get,
            path: "/collections/\(collectionId)/pending-invitations"
        )
        return response.items
    }

    // MARK: - Helpers

    /// `/collections/{collectionId}`, the id percent-encoded.
    private static func path(_ collectionId: String) -> String {
        "/collections/\(URLEncoding.encodeComponent(collectionId))"
    }

    /// Build a `?limit=…&cursor=…` query string from pagination options,
    /// routing both values through the shared `URLQuery` builder (#2076).
    private static func queryString(_ options: PaginationOptions?) -> String {
        guard let options else { return "" }
        var query = URLQuery()
        if let limit = options.limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", options.cursor)
        return query.queryString
    }
}
