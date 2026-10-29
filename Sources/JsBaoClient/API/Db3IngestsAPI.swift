import Foundation

// MARK: - Db3IngestsAPI

/// Bulk loads of a db3. Accessed as `client.db3.ingests`.
///
/// The documents bulk load (`client.documents.ingests`) over the db3's own
/// routes, `db3/<id>/ingest…`, with the same chunks, options and answers:
/// `buildChunks` turns rows into the artifact, `create` opens the session,
/// `uploadChunk` sends it a chunk at a time, `commit` starts the load, and
/// `get` reports progress until the session is `complete`, `failed` or
/// `aborted`. `abort` gives up and sweeps what was uploaded. A document that
/// is not a db3 is refused `HttpError` status 409, `serverCode` `"NOT_A_DB3"`.
///
/// ```swift
/// let chunks = try client.db3.ingests.buildChunks(rows: rows)
/// let session = try await client.db3.ingests.create(db3Id: db3Id)
/// for chunk in chunks {
///     _ = try await client.db3.ingests.uploadChunk(db3Id: db3Id, sessionId: session.sessionId, chunk: chunk)
/// }
/// _ = try await client.db3.ingests.commit(db3Id: db3Id, sessionId: session.sessionId)
/// ```
public final class Db3IngestsAPI: @unchecked Sendable {
    private let transport: any Transport
    /// The wait for a pending create of the db3 a call names (#5000).
    private let awaitCreate: @Sendable (String) async throws -> Void

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
        self.awaitCreate = { _ in }
    }

    /// `client.db3.ingests`: each call waits first for a pending create of its db3 (#5000).
    init(transport: any Transport, awaitCreate: @escaping @Sendable (String) async throws -> Void) {
        self.transport = transport
        self.awaitCreate = awaitCreate
    }

    private func path(_ db3Id: String, _ sessionId: String? = nil, _ verb: String? = nil) -> String {
        var path = "/db3/\(URLEncoding.encodeComponent(db3Id))/ingest"
        if let sessionId { path += "/\(URLEncoding.encodeComponent(sessionId))" }
        if let verb { path += "/\(verb)" }
        return path
    }

    /// Build a load's chunks from rows, ready for `uploadChunk`: the chunks
    /// `client.documents.ingests.buildChunks` builds for the same rows.
    ///
    /// - Throws: `JsBaoError` with code `.invalidArgument`, as
    ///   `DocumentIngestsAPI.buildChunks` does.
    public func buildChunks(
        rows: [DocumentIngestRow],
        options: DocumentIngestBuildOptions = DocumentIngestBuildOptions()
    ) throws -> [DocumentIngestChunk] {
        try DocumentIngestChunkBuilder.build(rows, options: options)
    }

    /// Open a bulk-load session on a db3. With no option set the request
    /// carries no body and the server applies its defaults (`.merge`,
    /// `.open`). A second session while one is running is refused
    /// `"DOCUMENT_INGEST_ACTIVE"`.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func create(
        db3Id: String,
        options: DocumentIngestCreateOptions? = nil
    ) async throws -> DocumentIngestSession {
        try await awaitCreate(db3Id)
        if let options, !options.isEmpty {
            return try await transport.request(method: .post, path: path(db3Id), body: options)
        }
        return try await transport.request(method: .post, path: path(db3Id))
    }

    /// Upload one chunk as the multipart body the server takes. The server
    /// checks the body's length and SHA-256 against the descriptor before
    /// anything is stored. Answers for the chunk, not for the session.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func uploadChunk(
        db3Id: String,
        sessionId: String,
        chunk: DocumentIngestChunk
    ) async throws -> DocumentIngestChunkUploadResult {
        try await awaitCreate(db3Id)
        let boundary = DocumentIngestMultipart.boundary()
        return try await transport.request(
            method: .post,
            path: path(db3Id, sessionId, "chunks"),
            bodyData: DocumentIngestMultipart.body(chunk: chunk, boundary: boundary),
            options: DocumentIngestMultipart.options(boundary: boundary)
        )
    }

    /// Freeze the session's chunks and start the load; poll `get` until it
    /// reads `complete` or `failed`.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func commit(db3Id: String, sessionId: String) async throws -> DocumentIngestSession {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .post, path: path(db3Id, sessionId, "commit"))
    }

    /// Give up on a session and sweep what it uploaded. A session that has
    /// finished is refused `"INGEST_SESSION_NOT_ABORTABLE"`.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func abort(db3Id: String, sessionId: String) async throws -> DocumentIngestSession {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .post, path: path(db3Id, sessionId, "abort"))
    }

    /// One session's state and progress.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func get(db3Id: String, sessionId: String) async throws -> DocumentIngestSession {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: path(db3Id, sessionId))
    }

    /// A db3's bulk-load sessions, newest first.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    public func list(db3Id: String, limit: Int? = nil, cursor: String? = nil) async throws -> DocumentIngestPage {
        try await awaitCreate(db3Id)
        var query = URLQuery()
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        return try await transport.request(method: .get, path: path(db3Id) + query.queryString)
    }
}
