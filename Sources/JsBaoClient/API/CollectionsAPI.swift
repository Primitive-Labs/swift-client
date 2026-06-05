import Foundation

// MARK: - CollectionsAPI

public final class CollectionsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    // MARK: - CRUD

    /// Create a new collection. `name` is required; `collectionType` and
    /// `contextId` are immutable after create.
    public func create(params: CreateCollectionParams) async throws -> CollectionInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/collections", body)
        return try JSONCoding.decode(CollectionInfo.self, from: result)
    }

    /// List collections the caller is a direct member of (reader or
    /// read-write). Each returned item carries a `permission` reflecting the
    /// caller's direct access level. Use `listAll()` for the app-wide set.
    public func list(options: PaginationOptions? = nil) async throws -> PaginatedResult<CollectionInfo> {
        let result = try await makeRequest("GET", "/collections\(Self.queryString(options))", nil)
        let page = try JSONCoding.decode(CollectionInfoPage.self, from: result)
        return PaginatedResult(items: page.items, cursor: page.cursor)
    }

    /// List every collection in the app (admin-only). Non-admin callers
    /// receive a 403. Unlike `list()`, returned items do not carry a
    /// `permission` field. Mirrors js-bao's `collections.listAll(options)`.
    public func listAll(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> PaginatedResult<CollectionInfo> {
        let qs = Self.queryString(PaginationOptions(limit: limit, cursor: cursor))
        let result = try await makeRequest("GET", "/admin/collections\(qs)", nil)
        let page = try JSONCoding.decode(CollectionInfoPage.self, from: result)
        return PaginatedResult(items: page.items, cursor: page.cursor)
    }

    /// Get collection info by ID. Callers without any access receive a 404
    /// (to avoid leaking collection existence).
    public func get(collectionId: String) async throws -> CollectionInfo {
        let result = try await makeRequest("GET", "/collections/\(collectionId)", nil)
        return try JSONCoding.decode(CollectionInfo.self, from: result)
    }

    /// Update a collection's name or description.
    public func update(collectionId: String, params: UpdateCollectionParams) async throws -> CollectionInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/collections/\(collectionId)", body)
        return try JSONCoding.decode(CollectionInfo.self, from: result)
    }

    /// Delete a collection.
    public func delete(collectionId: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    // MARK: - Documents

    /// Add a document to a collection.
    public func addDocument(collectionId: String, documentId: String) async throws -> CollectionDocumentInfo {
        let body: [String: Any] = ["documentId": documentId]
        let result = try await makeRequest("POST", "/collections/\(collectionId)/documents", body)
        return try JSONCoding.decode(CollectionDocumentInfo.self, from: result)
    }

    /// Remove a document from a collection.
    public func removeDocument(collectionId: String, documentId: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/documents/\(documentId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    /// List all documents in a collection, each with the caller's effective
    /// permission.
    public func listDocuments(collectionId: String, options: PaginationOptions? = nil) async throws -> PaginatedResult<CollectionDocumentInfo> {
        let result = try await makeRequest("GET", "/collections/\(collectionId)/documents\(Self.queryString(options))", nil)
        let page = try JSONCoding.decode(CollectionDocumentPage.self, from: result)
        return PaginatedResult(items: page.items, cursor: page.cursor)
    }

    /// List collections that contain a specific document. For non-admin
    /// callers this returns only collections the caller is a direct member of.
    public func listCollectionsForDocument(documentId: String, options: PaginationOptions? = nil) async throws -> PaginatedResult<DocumentCollectionInfo> {
        let result = try await makeRequest("GET", "/documents/\(documentId)/collections\(Self.queryString(options))", nil)
        let page = try JSONCoding.decode(DocumentCollectionPage.self, from: result)
        return PaginatedResult(items: page.items, cursor: page.cursor)
    }

    // MARK: - Access

    /// Get the current user's access info for a collection (groups + members).
    public func getAccess(collectionId: String) async throws -> CollectionAccessInfo {
        let result = try await makeRequest("GET", "/collections/\(collectionId)/access", nil)
        return try JSONCoding.decode(CollectionAccessInfo.self, from: result)
    }

    /// Grant a group a permission level on a collection.
    public func grantGroupPermission(collectionId: String, params: GrantCollectionGroupPermissionParams) async throws -> CollectionGroupPermissionInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/collections/\(collectionId)/group-permissions", body)
        return try JSONCoding.decode(CollectionGroupPermissionInfo.self, from: result)
    }

    /// Revoke a group's permission from a collection.
    public func revokeGroupPermission(collectionId: String, groupType: String, groupId: String) async throws -> SuccessResult {
        let gType = groupType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupType
        let gId = groupId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupId
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/group-permissions/\(gType)/\(gId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
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
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/collections/\(collectionId)/members", body)
        return try JSONCoding.decode(CollectionAddMemberResult.self, from: result)
    }

    /// Remove a member from a collection.
    public func removeMember(collectionId: String, userId: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/collections/\(collectionId)/members/\(userId)", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }

    // MARK: - Invitations

    /// List pending (unresolved, non-expired) invitations scoped to a
    /// collection. Mirrors js-bao's
    /// `collections.listPendingInvitations(collectionId)`. The server returns
    /// a bare array; an `{ items }` envelope is also accepted defensively.
    public func listPendingInvitations(
        collectionId: String
    ) async throws -> [PendingCollectionInvitationEntry] {
        let result = try await makeRequest(
            "GET",
            "/collections/\(collectionId)/pending-invitations",
            nil
        )
        if let dict = result as? [String: Any], let items = dict["items"] {
            return try JSONCoding.decode([PendingCollectionInvitationEntry].self, from: items)
        }
        return try JSONCoding.decode([PendingCollectionInvitationEntry].self, from: result)
    }

    // MARK: - Helpers

    /// Build a `?limit=…&cursor=…` query string from pagination options,
    /// percent-encoding the cursor (the previous `listAll` raw-interpolated
    /// it — a latent escaping bug, sweep collections D4).
    private static func queryString(_ options: PaginationOptions?) -> String {
        guard let options else { return "" }
        var params: [String] = []
        if let limit = options.limit { params.append("limit=\(limit)") }
        if let cursor = options.cursor {
            let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            params.append("cursor=\(escaped)")
        }
        return params.isEmpty ? "" : "?\(params.joined(separator: "&"))"
    }
}
