import Foundation
import YSwift

// MARK: - DocumentsAPI

public final class DocumentsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let blobManager: BlobManager
    /// Optional document-manager hook for local-only operations
    /// (`isOpen`, `listPendingCreates`, `cancelPendingCreate`,
    /// `getLocalMetadata`, `getDocumentPermission`, …). When `nil`
    /// the local-only methods throw `unavailable`. Set by
    /// `JsBaoClient.setupSubApis` in practice.
    private weak var documentManager: DocumentManager?

    /// Optional weak ref to the owning client. Lets the ergonomic
    /// wrappers (`open`, `openRoot`, `close`, `evict`, `waitForSync`, …)
    /// route through the top-level methods that already own the
    /// authoritative implementation. `nil` when DocumentsAPI is
    /// constructed in isolation (tests).
    private weak var client: JsBaoClient?

    public let aliases: DocumentAliasesAPI

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        blobManager: BlobManager,
        documentManager: DocumentManager? = nil,
        client: JsBaoClient? = nil
    ) {
        self.makeRequest = makeRequest
        self.blobManager = blobManager
        self.documentManager = documentManager
        self.client = client
        self.aliases = DocumentAliasesAPI(makeRequest: makeRequest)
    }

    // MARK: - CRUD

    /// Create a new document.
    public func create(options: [String: Any]? = nil) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents", options)
        return result as? [String: Any] ?? [:]
    }

    /// List documents accessible to the current user.
    ///
    /// - Parameter includeRoot: when `false` (default), the app's root
    ///   document is filtered out of the returned `items`. Pass
    ///   `true` to keep it. The server endpoint always returns the
    ///   root; we filter client-side to match js-bao behavior.
    ///
    /// Deprecated: this returns the legacy owner + read-write + reader
    /// union and will eventually be removed. Migrate to
    /// `client.me.ownedDocuments(...)` for the owner-only subset and
    /// `client.me.sharedDocuments(...)` for the non-owner subset.
    /// Mirrors js-bao's `@deprecated` annotation on `DocumentsAPI.list`
    /// (issue #628).
    @available(*, deprecated, message: "documents.list() returns the legacy owner+read-write+reader union. Use client.me.ownedDocuments(...) for owned docs and client.me.sharedDocuments(...) for shared docs.")
    public func list(
        options: PaginationOptions? = nil,
        includeRoot: Bool = false
    ) async throws -> [String: Any] {
        return try await _listImpl(options: options, includeRoot: includeRoot)
    }

    /// Underscore-prefixed implementation that internal callers (e.g.
    /// `PrimitiveAppState`-style consumers that want to migrate
    /// gradually) can reach without tripping the deprecation warning.
    /// Mirrors js-bao's `_internalListImpl` pattern from `documentsApi.ts`.
    public func _listImpl(
        options: PaginationOptions? = nil,
        includeRoot: Bool = false
    ) async throws -> [String: Any] {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/documents\(qs)", nil)
        var response = result as? [String: Any] ?? [:]
        if !includeRoot {
            var rootDocId: String? = nil
            if let client { rootDocId = try? await client.getRootDocId() }
            response = Self.filterOutRoot(response, rootDocId: rootDocId)
        }
        return response
    }

    /// Sentinel tag the server attaches to a root document. Mirrors
    /// js-bao's `ROOT_DOCUMENT_TAG` in `documentsApi.ts`.
    private static let rootDocumentTag = "__ROOT_TAG__"

    /// Strip the app root document from a server-shaped list response,
    /// matching js-bao's `_listImpl` filter exactly: drop any entry whose
    /// `documentId` equals the known root id, OR whose `tags` include the
    /// `__ROOT_TAG__` sentinel. The tag check runs even when `rootDocId`
    /// is unknown (e.g. a JWT without the `rootDocId` claim), so the root
    /// never leaks on tokens that lack the claim. Other keys (cursor,
    /// total, etc.) pass through untouched.
    private static func filterOutRoot(
        _ response: [String: Any],
        rootDocId: String?
    ) -> [String: Any] {
        var out = response
        let keyCandidates = ["items", "documents"]
        for key in keyCandidates {
            guard let items = response[key] as? [[String: Any]] else { continue }
            out[key] = items.filter { item in
                let isIdRoot = rootDocId != nil && (item["documentId"] as? String) == rootDocId
                let isRootTagged = (item["tags"] as? [String])?.contains(Self.rootDocumentTag) ?? false
                return !isIdRoot && !isRootTagged
            }
        }
        return out
    }

    /// Get a document by ID.
    public func get(documentId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/documents/\(documentId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Update a document's metadata.
    public func update(documentId: String, data: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PUT", "/documents/\(documentId)", data)
        return result as? [String: Any] ?? [:]
    }

    /// Delete a document.
    ///
    /// - Parameter forceCloseIfOpen: when `true`, the local
    ///   `DocumentManager` is asked to close the doc before the
    ///   server DELETE call lands. Mirrors js-bao's
    ///   `documents.delete(id, {forceCloseIfOpen: true})`. Without
    ///   it, deleting a still-open doc surfaces stale state to the
    ///   caller.
    public func delete(
        documentId: String,
        forceCloseIfOpen: Bool = false
    ) async throws -> [String: Any] {
        if forceCloseIfOpen, documentManager?.isOpen(documentId) == true {
            await documentManager?.closeDocument(documentId: documentId)
        }
        return try await deleteRaw(documentId: documentId)
    }

    private func deleteRaw(documentId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/documents/\(documentId)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Permissions

    /// Get the list of members (permission entries) for a document.
    public func getPermissions(documentId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/permissions", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Remove a user's permission from a document.
    public func removePermission(documentId: String, userId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/documents/\(documentId)/permissions/\(userId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Cancel an email-targeted permission (live `DocumentPermission`
    /// if the email resolves to an app member, otherwise all matching
    /// unresolved `DeferredDocumentPermission` rows). Mirrors js-bao's
    /// `documents.removePermission(documentId, { email })` (issue #619).
    /// Sends `DELETE /documents/:documentId/permissions?email=<email>`.
    public func removePermission(documentId: String, email: String) async throws -> [String: Any] {
        let escaped = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let result = try await makeRequest(
            "DELETE",
            "/documents/\(documentId)/permissions?email=\(escaped)",
            nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Transfer ownership of a document to another user.
    public func transferOwnership(documentId: String, newOwnerId: String) async throws -> [String: Any] {
        let body: [String: Any] = ["newOwnerId": newOwnerId]
        let result = try await makeRequest("POST", "/documents/\(documentId)/permissions/transfer", body)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Group Permissions

    /// List group permissions for a document.
    public func listGroupPermissions(documentId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/group-permissions", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Grant a group permission on a document.
    public func grantGroupPermission(documentId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/\(documentId)/group-permissions", params)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Access

    /// Validate the current user's access to a document.
    public func validateAccess(documentId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/access", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Accept a pending invitation to a document.
    ///
    /// Deprecated: the per-document accept concept has been removed.
    /// Shares to existing app users auto-resolve at signup or write
    /// time. Cross-identity shares use `client.invitations.accept(inviteToken:)`
    /// with the token from the invitation email (issue #619).
    @available(*, deprecated, message: "Per-doc accept removed. Email-matched shares auto-resolve; cross-identity uses client.invitations.accept(inviteToken:) (issue #619).")
    public func acceptInvitation(documentId: String) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/\(documentId)/validate-access", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Invitations

    /// List pending deferred-grant invitations for a document. Returns
    /// rows from the new `DeferredDocumentPermission` model (the
    /// replacement for the legacy `DocumentInvitation` model).
    /// Mirrors js-bao's `documents.listPendingInvitations` (issue #619).
    /// Sends `GET /documents/:documentId/pending-invitations`.
    /// Response shape: `[{email, permission, invitationId, createdAt, expiresAt, grantedBy?}, ...]`.
    public func listPendingInvitations(documentId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/pending-invitations", nil)
        let dict = result as? [String: Any] ?? [:]
        return dict["items"] as? [[String: Any]] ?? []
    }

    /// List invitations for a document.
    ///
    /// Deprecated: reads the legacy `DocumentInvitation` model. New
    /// shares go through `DeferredDocumentPermission` and are surfaced
    /// by `listPendingInvitations`. Existing `DocumentInvitation` rows
    /// remain visible here until they drain.
    @available(*, deprecated, message: "Use documents.listPendingInvitations(documentId:) — reads new DeferredDocumentPermission rows (issue #619).")
    public func listInvitations(documentId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/invitations", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Send an invitation to a document.
    ///
    /// Deprecated: use `updatePermissions(documentId:, params:)` with
    /// `{ email, permission, sendEmail?, documentUrl?, note? }`. The
    /// new API is idempotent and routes through the unified deferred-
    /// grant flow.
    @available(*, deprecated, message: "Use documents.updatePermissions(documentId:, params:) with email+permission (issue #619).")
    public func sendInvitation(documentId: String, email: String, permission: String, options: [String: Any]? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["email": email, "permission": permission]
        if let options = options {
            for (key, value) in options { body[key] = value }
        }
        let result = try await makeRequest("POST", "/documents/\(documentId)/invitations", body)
        return result as? [String: Any] ?? [:]
    }

    /// Get a specific invitation by email (client-side filter from list).
    ///
    /// Deprecated: use `client.invitations.get(invitationId:)` for the
    /// app-level invitation, or `listPendingInvitations(documentId:)`
    /// filtered by email for the doc-scoped deferred grant.
    @available(*, deprecated, message: "Use client.invitations.get(invitationId:) or documents.listPendingInvitations(documentId:) filtered by email (issue #619).")
    public func getInvitation(documentId: String, email: String) async throws -> [String: Any]? {
        let invitations = try await makeRequest("GET", "/documents/\(documentId)/invitations", nil)
        let list = invitations as? [[String: Any]] ?? []
        return list.first { ($0["email"] as? String) == email }
    }

    /// Update an invitation's permission (re-creates with same email).
    ///
    /// Deprecated: `updatePermissions(documentId:, params:)` is
    /// idempotent — re-call it with the new permission to upsert.
    @available(*, deprecated, message: "Use documents.updatePermissions(documentId:, params:) — it's idempotent (issue #619).")
    public func updateInvitation(documentId: String, email: String, permission: String, options: [String: Any]? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["email": email, "permission": permission]
        if let options = options {
            for (key, value) in options { body[key] = value }
        }
        let result = try await makeRequest("POST", "/documents/\(documentId)/invitations", body)
        return result as? [String: Any] ?? [:]
    }

    /// Delete an invitation.
    ///
    /// Deprecated: use `removePermission(documentId:, email:)` (drops
    /// both live and deferred rows for the email) or
    /// `client.invitations.delete(invitationId:)` for app-level
    /// invitations.
    @available(*, deprecated, message: "Use documents.removePermission(documentId:, email:) or client.invitations.delete(invitationId:) (issue #619).")
    public func deleteInvitation(documentId: String, invitationId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/documents/\(documentId)/invitations/\(invitationId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Decline an invitation (as the invitee).
    ///
    /// Deprecated: no invitee-side decline verb. Pending invitations
    /// expire automatically. To remove yourself from an already-
    /// accepted share, call `removePermission(documentId:, userId:)`
    /// with your own user ID (issue #630, won't-fix).
    @available(*, deprecated, message: "No invitee-side decline verb. Pending invitations expire automatically; self-remove via removePermission(documentId:, userId:) after acceptance (issue #619).")
    public func declineInvitation(documentId: String, invitationId: String) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/\(documentId)/invitations/\(invitationId)/decline", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Update document permissions for a user.
    ///
    /// Idempotent email-based share — the standard verb for "invite X to
    /// this doc" since the deprecation of `sendInvitation`. Routes
    /// through the unified deferred-grant flow:
    ///  * if the email already maps to an app user → live `DocumentPermission` row;
    ///  * otherwise → `DeferredDocumentPermission` row that resolves on signup.
    ///
    /// - Parameter params: dict keys (mirrors JS):
    ///   - `email` (String, required) OR `userId` (String, required) — the target.
    ///   - `permission` (String, required) — `"owner"`, `"read-write"`, `"reader"`.
    ///   - `sendEmail` (Bool, optional, default true).
    ///   - `documentUrl` (String, optional) — surfaces in the invite email body.
    ///   - `note` (String, optional) — surfaces in the invite email body.
    ///
    /// For the email-typed common case prefer the typed wrapper
    /// `invite(documentId:email:permission:sendEmail:documentUrl:note:)`.
    public func updatePermissions(documentId: String, params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("PUT", "/documents/\(documentId)/permissions", params)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Root Document

    /// Get the root document for the app.
    public func getRoot() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/documents/root", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Tags

    /// Add a tag to a document. Returns the updated tag list (matches
    /// js-bao's `[String]` return). Falls back to an empty list if
    /// the server response is shaped differently.
    public func addTag(documentId: String, tag: String) async throws -> [String] {
        let body: [String: Any] = ["tag": tag]
        let result = try await makeRequest("POST", "/documents/\(documentId)/tags", body)
        return Self.extractTags(from: result)
    }

    /// Remove a tag from a document. Returns the updated tag list.
    public func removeTag(documentId: String, tag: String) async throws -> [String] {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let result = try await makeRequest("DELETE", "/documents/\(documentId)/tags/\(encodedTag)", nil)
        return Self.extractTags(from: result)
    }

    /// Pull a `[String]` tag list out of the dict the server returns
    /// regardless of whether the field is called `tags`, the response
    /// itself is the array, or the response is empty.
    private static func extractTags(from result: Any) -> [String] {
        if let arr = result as? [String] { return arr }
        if let dict = result as? [String: Any],
           let arr = dict["tags"] as? [String] {
            return arr
        }
        return []
    }

    // MARK: - Create With Alias

    /// Create a document with an alias atomically.
    public func createWithAlias(options: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/create-with-alias", options)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Owner

    /// Get the current owner of a document. Convenience wrapper over
    /// `get(documentId:)` that extracts the `ownerId`/`createdBy`
    /// field. js-bao counterpart: `client.documents.getOwner(id)`.
    public func getOwner(documentId: String) async throws -> String? {
        let doc = try await get(documentId: documentId)
        return doc["ownerId"] as? String ?? doc["createdBy"] as? String
    }

    // MARK: - Group permissions

    /// Revoke a group's permission on a document.
    public func revokeGroupPermission(
        documentId: String,
        groupType: String,
        groupId: String
    ) async throws -> [String: Any] {
        let gType = groupType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupType
        let gId = groupId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupId
        let result = try await makeRequest(
            "DELETE",
            "/documents/\(documentId)/group-permissions/\(gType)/\(gId)",
            nil
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Access requests

    /// Request access to a document the current user doesn't have a
    /// permission grant on. Owners (and app admins) can approve/deny
    /// via `listAccessRequests` / `approveAccessRequest` /
    /// `denyAccessRequest`.
    ///
    /// - Parameter params: Expected keys:
    ///   - `permission` (String, required): `"read-write"` or `"reader"`.
    ///   - `message` (String, optional, max 500 chars).
    ///   - `documentUrl` (String, optional): included in the owner email.
    ///   - `reviewUrl` (String, optional): owner-side review link.
    ///   - `sendEmail` (Bool, optional): defaults to true.
    public func requestAccess(
        documentId: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await makeRequest(
            "POST",
            "/documents/\(documentId)/access-requests",
            params
        )
        return result as? [String: Any] ?? [:]
    }

    /// List pending access requests for a document. Owner/admin only.
    public func listAccessRequests(
        documentId: String
    ) async throws -> [[String: Any]] {
        let result = try await makeRequest(
            "GET",
            "/documents/\(documentId)/access-requests",
            nil
        )
        return result as? [[String: Any]] ?? []
    }

    /// Approve a pending access request. Owner/admin only.
    ///
    /// - Parameter params: Optional keys:
    ///   - `permission` (String): override the requested level.
    ///   - `documentUrl` (String): included in the requester's email.
    public func approveAccessRequest(
        documentId: String,
        requestId: String,
        params: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let body = params ?? [:]
        let result = try await makeRequest(
            "POST",
            "/documents/\(documentId)/access-requests/\(requestId)/approve",
            body
        )
        return result as? [String: Any] ?? [:]
    }

    /// Deny a pending access request. Owner/admin only.
    ///
    /// - Parameter params: Optional keys:
    ///   - `documentUrl` (String): included in the requester's email.
    public func denyAccessRequest(
        documentId: String,
        requestId: String,
        params: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let body = params ?? [:]
        let result = try await makeRequest(
            "POST",
            "/documents/\(documentId)/access-requests/\(requestId)/deny",
            body
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Local-only methods (delegate to DocumentManager)

    /// Check whether a document is currently open locally. Does NOT
    /// hit the server. Requires the `documentManager` to be wired by
    /// `JsBaoClient.setupSubApis`.
    public func isOpen(documentId: String) -> Bool {
        return documentManager?.isOpen(documentId) ?? false
    }

    /// Check whether a document has a pending local create that has
    /// not been committed to the server.
    public func isPendingCreate(documentId: String) -> Bool {
        return documentManager?.isPendingCreate(documentId) ?? false
    }

    /// Check whether a document has a local copy stored on this device.
    public func hasLocalCopy(documentId: String) -> Bool {
        return documentManager?.hasLocalCopy(documentId) ?? false
    }

    /// List all documents that were created locally but not yet
    /// committed to the server. Returns an array of `documentId`
    /// strings — the JS surface returns richer entries, but
    /// `DocumentManager` only tracks the IDs at this layer.
    public func listPendingCreates() -> [String] {
        return documentManager?.listPendingCreates() ?? []
    }

    /// Cancel a pending local document create. Optionally evicts the
    /// document's local data after cancellation.
    public func cancelPendingCreate(documentId: String) async {
        await documentManager?.cancelPendingCreate(documentId)
    }

    /// Get the current user's permission level for a document, as
    /// last observed by the local document manager. Returns `nil`
    /// when the document isn't open locally.
    public func getDocumentPermission(documentId: String) -> DocumentPermission? {
        return documentManager?.getPermission(documentId)
    }

    /// Get locally cached metadata for a document. Returns `nil`
    /// when no metadata is stored.
    public func getLocalMetadata(documentId: String) -> LocalMetadataEntry? {
        return documentManager?.getLocalMetadata(documentId)
    }

    // MARK: - Blob Context

    /// Get a blob context scoped to a specific document.
    public func blobs(documentId: String) -> DocumentBlobContext {
        return DocumentBlobContext(
            documentId: documentId,
            makeRequest: makeRequest,
            blobManager: blobManager
        )
    }

    // MARK: - Get-or-create with alias (P1)

    /// Atomic upsert against an alias: if a doc already exists at the
    /// alias return it, otherwise create one. Used for singleton docs
    /// like "the user's notes doc". Mirrors js-bao's
    /// `documents.getOrCreateWithAlias(options)`.
    ///
    /// - Parameter alias: dict with `scope` (`"app"` or `"user"`),
    ///   `aliasKey` (required), and optional `userId`. For `scope:
    ///   "user"`, `userId` defaults to the current user when omitted.
    /// - Parameter title: title for the doc if a new one is created.
    /// - Parameter tags: tags applied if a new one is created.
    ///
    /// Returns: `{ documentId, title?, createdBy?, createdAt?,
    /// modifiedAt?, alias, created }`.
    public func getOrCreateWithAlias(
        alias: [String: Any],
        title: String? = nil,
        tags: [String]? = nil
    ) async throws -> [String: Any] {
        guard let scope = alias["scope"] as? String,
              scope == "app" || scope == "user" else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "alias.scope must be 'app' or 'user'"
            )
        }
        guard let aliasKey = alias["aliasKey"] as? String, !aliasKey.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "alias.aliasKey is required"
            )
        }

        var aliasPayload: [String: Any] = [
            "scope": scope,
            "aliasKey": aliasKey,
        ]
        var userId = alias["userId"] as? String
        if scope == "user", userId == nil {
            userId = client?.getUserId()
        }
        if let userId { aliasPayload["userId"] = userId }

        var body: [String: Any] = ["alias": aliasPayload]
        if let title { body["title"] = title }
        if let tags, !tags.isEmpty { body["tags"] = tags }

        let result = try await makeRequest(
            "POST", "/documents/get-or-create-with-alias", body
        )
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Ergonomic wrappers around top-level client methods (P1)
    //
    // js-bao surfaces `documents.open()` / `openRoot()` / `close()` as
    // thin wrappers around the client root's `openDocument` / etc.
    // Swift's top-level versions own the implementation; these are
    // sub-API forwarders so cross-platform code that calls
    // `client.documents.open(id)` works.

    /// Open a document. Forwards to `client.openDocument(_:options:)`.
    public func open(
        _ documentId: String,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> YDocument {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "DocumentsAPI.open requires a wired JsBaoClient"
            )
        }
        return try await client.openDocument(documentId, options: options)
    }

    /// Open the app's root document (the one returned by
    /// `getRootDocId()`). Throws `notFound` if the app has no root.
    public func openRoot(
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> YDocument {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "DocumentsAPI.openRoot requires a wired JsBaoClient"
            )
        }
        guard let docId = try await client.getRootDocId() else {
            throw JsBaoError(
                code: .notFound,
                message: "App has no root document"
            )
        }
        return try await client.openDocument(docId, options: options)
    }

    /// Close a document. Forwards to
    /// `client.closeDocument(_:options:)`.
    public func close(
        _ documentId: String,
        options: CloseDocumentOptions = CloseDocumentOptions()
    ) async {
        await client?.closeDocument(documentId, options: options)
    }

    // MARK: - Sync-state predicates (P2)

    /// `true` iff the local doc has pending writes that haven't been
    /// acknowledged by the server. Mirrors js-bao's
    /// `documents.includesWrites(documentId)`. Local-only check.
    public func includesWrites(documentId: String) -> Bool {
        // The Swift document manager tracks pending updates via
        // `pendingUpdates`; isSynced flips to false when any are
        // outstanding. Surface it as the inverse so callers can ask
        // the question in either direction.
        guard let mgr = documentManager else { return false }
        return mgr.isOpen(documentId) && !mgr.isSynced(documentId)
    }

    /// `true` iff the doc is currently in sync with the server. Inverse
    /// of `includesWrites`. Mirrors js-bao's
    /// `documents.inSync(documentId)`.
    public func inSync(documentId: String) -> Bool {
        return documentManager?.isSynced(documentId) ?? false
    }

    // MARK: - waitFor* sub-API wrappers (P2)
    //
    // Top-level versions live on `JsBaoClient`; these forward so
    // cross-platform call sites can use either path.

    public func waitForWriteConfirmation(
        documentId: String,
        timeoutMs: Int = 10_000,
        pollMs: Int = 200
    ) async throws {
        guard let client else {
            throw JsBaoError(code: .unavailable, message: "client unset")
        }
        try await client.waitForWriteConfirmation(
            documentId: documentId, timeoutMs: timeoutMs, pollMs: pollMs
        )
    }

    public func waitForInSync(
        documentId: String,
        timeoutMs: Int = 10_000,
        pollMs: Int = 200
    ) async throws {
        guard let client else {
            throw JsBaoError(code: .unavailable, message: "client unset")
        }
        try await client.waitForInSync(
            documentId: documentId, timeoutMs: timeoutMs, pollMs: pollMs
        )
    }

    // MARK: - Local-eviction sub-API wrappers (P2)

    /// Evict a single document's local data. Forwards to the
    /// top-level `client.evictLocalDocument(_:)`.
    public func evict(documentId: String) async {
        await client?.evictLocalDocument(documentId)
    }

    /// Evict every doc's local data. Walks the metadata index and
    /// evicts each entry. The top-level client doesn't expose a
    /// dedicated `evictAll` — we walk the index here.
    public func evictAll() async {
        guard let client else { return }
        let metadata = client.listLocalDocuments()
        for documentId in metadata.keys {
            await client.evictLocalDocument(documentId)
        }
    }
}

// MARK: - DocumentAliasesAPI

public final class DocumentAliasesAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Create or update a document alias.
    public func set(scope: String, aliasKey: String, documentId: String, userId: String? = nil, mustNotExist: Bool = false) async throws -> [String: Any] {
        let encodedKey = aliasKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? aliasKey
        var body: [String: Any] = ["documentId": documentId]
        if let userId = userId { body["userId"] = userId }
        if mustNotExist { body["mustNotExist"] = true }
        let result = try await makeRequest("PUT", "/document-aliases/\(scope)/\(encodedKey)", body)
        return result as? [String: Any] ?? [:]
    }

    /// Resolve a document alias, returning nil if not found.
    public func resolve(scope: String, aliasKey: String, userId: String? = nil) async throws -> [String: Any]? {
        let encodedKey = aliasKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? aliasKey
        var path = "/document-aliases/\(scope)/\(encodedKey)"
        if scope == "user", let userId = userId {
            let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
            path += "?userId=\(encodedUserId)"
        }
        do {
            let result = try await makeRequest("GET", path, nil)
            return result as? [String: Any]
        } catch {
            if isNotFoundError(error) { return nil }
            throw error
        }
    }

    /// Delete a document alias.
    public func delete(scope: String, aliasKey: String, userId: String? = nil) async throws {
        let encodedKey = aliasKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? aliasKey
        var path = "/document-aliases/\(scope)/\(encodedKey)"
        if scope == "user", let userId = userId {
            let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
            path += "?userId=\(encodedUserId)"
        }
        do {
            _ = try await makeRequest("DELETE", path, nil)
        } catch {
            if isNotFoundError(error) { return }
            throw error
        }
    }

    /// List all aliases for a document.
    public func listForDocument(documentId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/aliases", nil)
        return result as? [[String: Any]] ?? []
    }

    private func isNotFoundError(_ error: Error) -> Bool {
        let msg = String(describing: error)
        return msg.contains("HTTP 404") || msg.contains("status: 404")
    }
}

// MARK: - DocumentBlobContext

public final class DocumentBlobContext: @unchecked Sendable {
    private let documentId: String
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let blobManager: BlobManager

    public init(
        documentId: String,
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        blobManager: BlobManager
    ) {
        self.documentId = documentId
        self.makeRequest = makeRequest
        self.blobManager = blobManager
    }

    /// Upload a blob to the document.
    public func upload(data: Data, options: BlobUploadSourceOptions = BlobUploadSourceOptions()) async throws -> BlobUploadResult {
        return try await blobManager.uploadFromSource(
            documentId: documentId,
            source: data,
            options: options
        )
    }

    /// List blobs attached to the document.
    public func list(limit: Int? = nil) async throws -> [[String: Any]] {
        var path = "/documents/\(documentId)/blobs"
        if let limit = limit {
            path += "?limit=\(limit)"
        }
        let result = try await makeRequest("GET", path, nil)
        if let dict = result as? [String: Any], let items = dict["items"] as? [[String: Any]] {
            return items
        }
        return result as? [[String: Any]] ?? []
    }

    /// Get metadata for a specific blob.
    public func get(blobId: String) async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/blobs/\(blobId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Build a download URL for a blob.
    public func downloadUrl(blobId: String, disposition: BlobDisposition? = nil) -> String {
        return blobManager.downloadUrl(documentId: documentId, blobId: blobId, disposition: disposition)
    }

    /// Delete a blob from the document.
    public func delete(blobId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/documents/\(documentId)/blobs/\(blobId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Read (download) the raw blob data.
    public func read(blobId: String) async throws -> Data {
        return try await blobManager.read(documentId: documentId, blobId: blobId)
    }
}
