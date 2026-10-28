import Foundation

// MARK: - DocumentIngestsAPI

/// Bulk loads of a large document. Accessed as `client.documents.ingests`.
///
/// A bulk load writes many records into a record-log document in one session,
/// without taking it offline. By default it merges: each row is upserted and
/// every other record is left as it is. A refresh replaces the models it
/// covers. Connected clients receive the result rather than reloading the
/// document.
///
/// The verbs are thin — one request each: `buildChunks` turns rows into the
/// artifact, `create` opens the session, `uploadChunk` sends the artifact a
/// chunk at a time, `commit` freezes it and starts the load, and `get` reports
/// progress until the session is `complete`, `failed` or `aborted`. `abort`
/// gives up and sweeps what was uploaded. `primitive documents ingest` is the
/// same sequence from a terminal.
public final class DocumentIngestsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    private func path(_ documentId: String, _ sessionId: String? = nil, _ verb: String? = nil) -> String {
        var path = "/documents/\(URLEncoding.encodeComponent(documentId))/ingest"
        if let sessionId { path += "/\(URLEncoding.encodeComponent(sessionId))" }
        if let verb { path += "/\(verb)" }
        return path
    }

    /// Build a load's chunks from rows, ready for `uploadChunk`.
    ///
    /// Models are emitted in UTF-8 byte order of their names, each model's rows
    /// in id order, and each chunk is numbered from 0 within its model. A chunk
    /// is closed at `cutRows` rows or before a row that would take it past
    /// `cutRawBytes`, and one whose gzipped size passes the 8 MiB a chunk may
    /// store is split in half by rows. The server's limits are checked before
    /// anything is returned: 50,000 rows and 16 MiB decompressed in a chunk,
    /// 4096 chunks and 2 GiB stored in a load. For the same rows the JS client
    /// writes the same chunk text.
    ///
    /// Everything is held in memory. An input of more than a few hundred
    /// thousand rows belongs to `primitive documents ingest`.
    ///
    /// - Throws: `JsBaoError` with code `.invalidArgument`, naming the row or
    ///   the limit, for a cut option out of range, a model name the upload
    ///   cannot address, a row whose id is empty, carries a tab, newline or
    ///   carriage return, or starts with U+FEFF, a non-finite number, a `(model, id)` named
    ///   twice, a row too large for any chunk, or an artifact past a load's
    ///   limits.
    public func buildChunks(
        rows: [DocumentIngestRow],
        options: DocumentIngestBuildOptions = DocumentIngestBuildOptions()
    ) throws -> [DocumentIngestChunk] {
        try DocumentIngestChunkBuilder.build(rows, options: options)
    }

    /// Open a bulk-load session on a document.
    ///
    /// With no option set the request carries no body and the server applies
    /// its defaults (`.merge`, `.open`); otherwise the body holds exactly the
    /// options set. The server refuses an option the document's format does
    /// not take with `HttpError` status 400, `serverCode`
    /// `"INGEST_OPTION_INVALID"`, and a second session while one is running
    /// with `"DOCUMENT_INGEST_ACTIVE"`.
    public func create(
        documentId: String,
        options: DocumentIngestCreateOptions? = nil
    ) async throws -> DocumentIngestSession {
        if let options, !options.isEmpty {
            return try await transport.request(method: .post, path: path(documentId), body: options)
        }
        return try await transport.request(method: .post, path: path(documentId))
    }

    /// Upload one chunk of the artifact as the multipart body the server
    /// takes. The server checks the body's length and SHA-256 against the
    /// descriptor before anything is stored.
    ///
    /// Answers for the chunk, not for the session.
    public func uploadChunk(
        documentId: String,
        sessionId: String,
        chunk: DocumentIngestChunk
    ) async throws -> DocumentIngestChunkUploadResult {
        let boundary = DocumentIngestMultipart.boundary()
        return try await transport.request(
            method: .post,
            path: path(documentId, sessionId, "chunks"),
            bodyData: DocumentIngestMultipart.body(chunk: chunk, boundary: boundary),
            options: DocumentIngestMultipart.options(boundary: boundary)
        )
    }

    /// Freeze the session's chunks and start the load.
    ///
    /// Returns as soon as the session is committed; poll `get` until it reads
    /// `complete` or `failed`.
    public func commit(documentId: String, sessionId: String) async throws -> DocumentIngestSession {
        try await transport.request(method: .post, path: path(documentId, sessionId, "commit"))
    }

    /// Give up on a session and sweep what it uploaded. Rows a committed load
    /// already applied stay. A session that has finished is refused with
    /// `"INGEST_SESSION_NOT_ABORTABLE"`.
    public func abort(documentId: String, sessionId: String) async throws -> DocumentIngestSession {
        try await transport.request(method: .post, path: path(documentId, sessionId, "abort"))
    }

    /// One session's state and progress.
    public func get(documentId: String, sessionId: String) async throws -> DocumentIngestSession {
        try await transport.request(method: .get, path: path(documentId, sessionId))
    }

    /// A document's bulk-load sessions, newest first.
    public func list(documentId: String, limit: Int? = nil, cursor: String? = nil) async throws -> DocumentIngestPage {
        var query = URLQuery()
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        return try await transport.request(method: .get, path: path(documentId) + query.queryString)
    }
}

/// The multipart body a chunk upload sends, shared by `client.documents.ingests`
/// and `client.db3.ingests`: the descriptor's fields, then the chunk's bytes.
enum DocumentIngestMultipart {
    /// A fresh boundary for one upload.
    static func boundary() -> String { "JsBaoIngest-\(UUID().uuidString)" }

    /// The body for `chunk`, framed by `boundary`.
    static func body(chunk: DocumentIngestChunk, boundary: String) -> Data {
        var payload = Data()
        func append(_ text: String) { payload.append(contentsOf: text.utf8) }
        let fields: [(String, String)] = [
            ("model", chunk.model), ("index", String(chunk.index)), ("rows", String(chunk.rows)),
            ("bytes", String(chunk.bytes)), ("rawBytes", String(chunk.rawBytes)), ("sha256", chunk.sha256),
            ("firstId", chunk.firstId), ("lastId", chunk.lastId),
        ]
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunk\"; filename=\"\(chunk.index).ndjson.gz\"\r\n")
        append("Content-Type: application/gzip\r\n\r\n")
        payload.append(chunk.body)
        append("\r\n--\(boundary)--\r\n")
        return payload
    }

    /// The request options an upload goes out with: the body as it is, and its boundary.
    static func options(boundary: String) -> RequestOptions {
        RequestOptions(rawBody: true, customHeaders: ["Content-Type": "multipart/form-data; boundary=\(boundary)"])
    }
}
