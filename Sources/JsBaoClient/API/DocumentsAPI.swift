import Foundation

// MARK: - DocumentsAPI

public final class DocumentsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let blobManager: BlobManager

    public let aliases: DocumentAliasesAPI

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        blobManager: BlobManager
    ) {
        self.makeRequest = makeRequest
        self.blobManager = blobManager
        self.aliases = DocumentAliasesAPI(makeRequest: makeRequest)
    }

    // MARK: - CRUD

    /// Create a new document.
    public func create(options: [String: Any]? = nil) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents", options)
        return result as? [String: Any] ?? [:]
    }

    /// List documents accessible to the current user.
    public func list(options: PaginationOptions? = nil) async throws -> [String: Any] {
        var qs = ""
        if let options = options {
            var params: [String] = []
            if let limit = options.limit { params.append("limit=\(limit)") }
            if let cursor = options.cursor { params.append("cursor=\(cursor)") }
            if !params.isEmpty { qs = "?\(params.joined(separator: "&"))" }
        }
        let result = try await makeRequest("GET", "/documents\(qs)", nil)
        return result as? [String: Any] ?? [:]
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
    public func delete(documentId: String) async throws -> [String: Any] {
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
    public func acceptInvitation(documentId: String) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/\(documentId)/validate-access", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Invitations

    /// List invitations for a document.
    public func listInvitations(documentId: String) async throws -> [[String: Any]] {
        let result = try await makeRequest("GET", "/documents/\(documentId)/invitations", nil)
        return result as? [[String: Any]] ?? []
    }

    /// Send an invitation to a document.
    public func sendInvitation(documentId: String, email: String, permission: String, options: [String: Any]? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["email": email, "permission": permission]
        if let options = options {
            for (key, value) in options { body[key] = value }
        }
        let result = try await makeRequest("POST", "/documents/\(documentId)/invitations", body)
        return result as? [String: Any] ?? [:]
    }

    /// Get a specific invitation by email (client-side filter from list).
    public func getInvitation(documentId: String, email: String) async throws -> [String: Any]? {
        let invitations = try await listInvitations(documentId: documentId)
        return invitations.first { ($0["email"] as? String) == email }
    }

    /// Update an invitation's permission (re-creates with same email).
    public func updateInvitation(documentId: String, email: String, permission: String, options: [String: Any]? = nil) async throws -> [String: Any] {
        return try await sendInvitation(documentId: documentId, email: email, permission: permission, options: options)
    }

    /// Delete an invitation.
    public func deleteInvitation(documentId: String, invitationId: String) async throws -> [String: Any] {
        let result = try await makeRequest("DELETE", "/documents/\(documentId)/invitations/\(invitationId)", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Decline an invitation (as the invitee).
    public func declineInvitation(documentId: String, invitationId: String) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/\(documentId)/invitations/\(invitationId)/decline", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Update document permissions for a user.
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

    /// Add a tag to a document.
    public func addTag(documentId: String, tag: String) async throws -> [String: Any] {
        let body: [String: Any] = ["tag": tag]
        let result = try await makeRequest("POST", "/documents/\(documentId)/tags", body)
        return result as? [String: Any] ?? [:]
    }

    /// Remove a tag from a document.
    public func removeTag(documentId: String, tag: String) async throws -> [String: Any] {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let result = try await makeRequest("DELETE", "/documents/\(documentId)/tags/\(encodedTag)", nil)
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Create With Alias

    /// Create a document with an alias atomically.
    public func createWithAlias(options: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/documents/create-with-alias", options)
        return result as? [String: Any] ?? [:]
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
