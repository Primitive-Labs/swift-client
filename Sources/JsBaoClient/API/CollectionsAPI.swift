import Foundation

// MARK: - CollectionsAPI

public final class CollectionsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - CRUD

    /// Create a new collection. `name` is required; `collectionType` and
    /// `contextId` are immutable after create.
    public func create(params: CreateCollectionParams) async throws -> CollectionInfo {
        try await transport.request(method: .post, path: "/collections", body: params)
    }

    /// List collections the caller is a direct member of (reader or
    /// read-write). Each returned item carries a `permission` reflecting the
    /// caller's direct access level. Use `listAll()` for the app-wide set.
    public func list(options: PaginationOptions? = nil) async throws -> PaginatedResult<CollectionInfo> {
        let page: CollectionInfoPage = try await transport.request(
            method: .get,
            path: "/collections\(Self.queryString(options))"
        )
        return PaginatedResult(items: page.items, cursor: page.cursor, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    /// List every collection in the app (admin-only). Non-admin callers
    /// receive a 403. Unlike `list()`, returned items do not carry a
    /// `permission` field. Mirrors js-bao's `collections.listAll(options)`.
    public func listAll(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> PaginatedResult<CollectionInfo> {
        let qs = Self.queryString(PaginationOptions(limit: limit, cursor: cursor))
        let page: CollectionInfoPage = try await transport.request(
            method: .get,
            path: "/admin/collections\(qs)"
        )
        return PaginatedResult(items: page.items, cursor: page.cursor, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    /// Get collection info by ID. Callers without any access receive a 404
    /// (to avoid leaking collection existence).
    public func get(collectionId: String) async throws -> CollectionInfo {
        try await transport.request(method: .get, path: "/collections/\(collectionId)")
    }

    /// Update a collection's name or description.
    public func update(collectionId: String, params: UpdateCollectionParams) async throws -> CollectionInfo {
        try await transport.request(method: .patch, path: "/collections/\(collectionId)", body: params)
    }

    /// Delete a collection.
    public func delete(collectionId: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: "/collections/\(collectionId)")
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
        return PaginatedResult(items: page.items, cursor: page.cursor, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    /// List collections that contain a specific document. For non-admin
    /// callers this returns only collections the caller is a direct member of.
    public func listCollectionsForDocument(documentId: String, options: PaginationOptions? = nil) async throws -> PaginatedResult<DocumentCollectionInfo> {
        let page: DocumentCollectionPage = try await transport.request(
            method: .get,
            path: "/documents/\(documentId)/collections\(Self.queryString(options))"
        )
        return PaginatedResult(items: page.items, cursor: page.cursor, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    // MARK: - Access

    /// Get the current user's access info for a collection (groups + members).
    public func getAccess(collectionId: String) async throws -> CollectionAccessInfo {
        try await transport.request(method: .get, path: "/collections/\(collectionId)/access")
    }

    /// Grant a group a permission level on a collection.
    public func grantGroupPermission(collectionId: String, params: GrantCollectionGroupPermissionParams) async throws -> CollectionGroupPermissionInfo {
        try await transport.request(
            method: .post,
            path: "/collections/\(collectionId)/group-permissions",
            body: params
        )
    }

    /// Revoke a group's permission from a collection.
    public func revokeGroupPermission(collectionId: String, groupType: String, groupId: String) async throws -> SuccessResult {
        let gType = URLEncoding.encodeComponent(groupType)
        let gId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .delete,
            path: "/collections/\(collectionId)/group-permissions/\(gType)/\(gId)"
        )
    }

    // MARK: - Members

    /// Add a member to a collection by user ID or email.
    ///
    /// Provide exactly one of `userId` / `email` on `params` (use the
    /// `.user(...)` / `.email(...)` factories). Returns a discriminated
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

    /// Remove a member from a collection.
    public func removeMember(collectionId: String, userId: String) async throws -> SuccessResult {
        try await transport.request(
            method: .delete,
            path: "/collections/\(collectionId)/members/\(userId)"
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
