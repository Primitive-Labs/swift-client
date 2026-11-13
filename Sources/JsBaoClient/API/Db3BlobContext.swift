import Foundation

/// A db3's blobs, as `client.db3.blobs(_:)`: files stored with the db3 over
/// its `db3/:id/blobs/*` routes, following the db3's access (a reader lists
/// and reads; a writer also uploads and deletes).
///
/// Uploads go through the client's upload queue and follow the JS client's
/// offline rules: while the client is offline `upload` stores the bytes,
/// queues them and answers at once with `bytesTransferred == 0`, sending
/// nothing; an upload that cannot reach the server is queued the same way
/// instead of throwing, and is sent once the client is online again, by
/// this client or the next one over the same storage. A refusal (a 403, or
/// `NOT_A_DB3` for a document that is not a db3) throws and queues nothing.
/// `read` serves this context's local copy first and, with none, throws
/// `JsBaoError` `.offline` while the client is offline. Local copies are
/// this context's own: `client.documents.blobs(documentId:)` never serves
/// them, nor they its.
///
/// ```swift
/// let blobs = client.db3.blobs(db3Id)
/// let uploaded = try await blobs.upload(
///     data: data, options: BlobUploadSourceOptions(filename: "notes.txt", contentType: "text/plain")
/// )
/// let bytes = try await blobs.read(blobId: uploaded.blobId)
/// ```
///
/// To show a blob in SwiftUI, use `BlobImage` from the `JsBaoClientUI`
/// product. The download URL carries no credentials; an image library
/// (Kingfisher, Nuke) sends `downloadRequest(blobId:)`, which does.
public final class Db3BlobContext: Sendable {
    /// The db3.
    /// - Stability: beta
    public let db3Id: String
    private let transport: any Transport
    private let blobManager: BlobManager
    /// Why no request may name the db3 (one that lives only on this device,
    /// #5155), asked before each call that would send one; `nil` lets it go.
    private let refusal: @Sendable () async -> JsBaoError?

    init(
        db3Id: String, transport: any Transport, blobManager: BlobManager,
        refusal: @escaping @Sendable () async -> JsBaoError? = { nil }
    ) {
        self.db3Id = db3Id
        self.transport = transport
        self.blobManager = blobManager
        self.refusal = refusal
    }

    /// The client behind this context, for `BlobImage`'s load identity:
    /// `client.db3.blobs(_:)` builds a new context per call, but each holds
    /// its client's one blob manager.
    /// - Stability: beta
    @_spi(JsBaoClientUI) public var backingClientIdentity: ObjectIdentifier {
        ObjectIdentifier(blobManager)
    }

    /// Throw the db3's refusal, when it has one.
    private func refuseIfLocalOnly() async throws {
        if let error = await refusal() { throw error }
    }

    private func path(_ rest: String = "") -> String {
        "/db3/\(URLEncoding.encodeComponent(db3Id))/blobs\(rest)"
    }

    /// Upload a blob to the db3. Online, it answers once the server has it
    /// (`bytesTransferred == numBytes`); offline or when the server cannot be
    /// reached, once it is queued (`bytesTransferred == 0`).
    /// - Parameters:
    ///   - data: The bytes (at most 10 MB).
    ///   - options: The filename, content type, disposition and `retainLocal`.
    /// - Throws: `HttpError` for a refusal: 403 for a caller who may not
    ///   write the db3, 409 `NOT_A_DB3` for a document that is not a db3.
    /// - Stability: beta
    public func upload(data: Data, options: BlobUploadSourceOptions = BlobUploadSourceOptions()) async throws -> BlobUploadResult {
        try await refuseIfLocalOnly()
        return try await blobManager.uploadFromSource(documentId: db3Id, source: data, options: options, family: .db3)
    }

    /// `upload`, answering the narrowed `{ blobId, numBytes, bytesTransferred }` shape.
    /// - Parameters:
    ///   - data: The bytes (at most 10 MB).
    ///   - options: The filename, content type, disposition and `retainLocal`.
    /// - Stability: beta
    @discardableResult
    public func uploadFile(data: Data, options: BlobUploadSourceOptions = BlobUploadSourceOptions()) async throws -> BlobUploadFileResult {
        let result = try await upload(data: data, options: options)
        return BlobUploadFileResult(blobId: result.blobId, numBytes: result.numBytes, bytesTransferred: result.bytesTransferred)
    }

    /// One page of the db3's blobs; pass `nextCursor` back as `cursor` for the next.
    /// - Parameters:
    ///   - limit: The page size, 1 to 100.
    ///   - cursor: The `nextCursor` of the page before.
    /// - Stability: beta
    public func list(limit: Int? = nil, cursor: String? = nil) async throws -> DocumentBlobListResult {
        try await refuseIfLocalOnly()
        var query = URLQuery()
        if let limit { query.append("limit", limit) }
        if let cursor, !cursor.isEmpty { query.append("cursor", cursor) }
        let page: Db3BlobListResponse = try await transport.request(method: .get, path: path(query.queryString))
        return page.result
    }

    /// A blob's metadata.
    /// - Parameter blobId: The blob.
    /// - Stability: beta
    public func get(blobId: String) async throws -> BlobInfo {
        try await refuseIfLocalOnly()
        return try await transport.request(method: .get, path: path("/\(URLEncoding.encodeComponent(blobId))"))
    }

    /// A blob's download URL, built without a request. It carries no
    /// credentials, so the route refuses a load that adds none (a bare
    /// `AsyncImage`): show the blob with `BlobImage` (`JsBaoClientUI`), or
    /// send `downloadRequest(blobId:disposition:attachmentFilename:)`.
    /// - Parameters:
    ///   - blobId: The blob.
    ///   - disposition: Serve it `inline` (display) or as an `attachment` (download).
    ///   - attachmentFilename: The download's filename (RFC 5987-encoded).
    /// - Stability: beta
    public func downloadUrl(blobId: String, disposition: BlobDisposition? = nil, attachmentFilename: String? = nil) -> String {
        blobManager.downloadUrl(
            family: .db3, documentId: db3Id, blobId: blobId, disposition: disposition, attachmentFilename: attachmentFilename
        )
    }

    /// The authenticated request for a blob's download: a GET of
    /// `downloadUrl(blobId:disposition:attachmentFilename:)` carrying the
    /// signed-in user's token as it is now, for an image library (Kingfisher,
    /// Nuke) to send. Synchronous, so a SwiftUI `body` can build it. It
    /// carries the token in force when it is built, so build one per send.
    /// - Parameters:
    ///   - blobId: The blob.
    ///   - disposition: Serve it `inline` (display) or as an `attachment` (download).
    ///   - attachmentFilename: The download's filename (RFC 5987-encoded).
    /// - Throws: `JsBaoError` `.invalidArgument` when the client has no API URL or app id.
    /// - Stability: beta
    public func downloadRequest(
        blobId: String, disposition: BlobDisposition? = nil, attachmentFilename: String? = nil
    ) throws -> URLRequest {
        guard let request = blobManager.downloadRequest(
            family: .db3, documentId: db3Id, blobId: blobId, disposition: disposition, attachmentFilename: attachmentFilename
        ) else {
            throw JsBaoError(code: .invalidArgument, message: "Blob \(blobId) has no download URL: the client has no API URL or app id")
        }
        return request
    }

    /// Delete a blob. A queued upload of it is cancelled and its local copies go.
    /// - Parameter blobId: The blob.
    /// - Stability: beta
    public func delete(blobId: String) async throws -> BlobDeleteResult {
        try await refuseIfLocalOnly()
        let result: BlobDeleteResult = try await transport.request(
            method: .delete, path: path("/\(URLEncoding.encodeComponent(blobId))")
        )
        await blobManager.cancelQueuedUpload(documentId: db3Id, blobId: blobId, family: .db3)
        return result
    }

    /// A blob's bytes: the local copy, else the server's (kept locally).
    /// - Parameters:
    ///   - blobId: The blob.
    ///   - force: Fetch from the server even with a local copy.
    ///   - disposition: The variant to read and keep (`inline` by default).
    /// - Throws: `JsBaoError` `.offline` with no local copy while the client is offline.
    /// - Stability: beta
    public func read(blobId: String, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> Data {
        try await refuseIfLocalOnly()
        return try await blobManager.read(family: .db3, documentId: db3Id, blobId: blobId, force: force, disposition: disposition)
    }

    /// A blob's bytes as UTF-8 text.
    /// - Parameters:
    ///   - blobId: The blob.
    ///   - type: `String.self`.
    ///   - force: Fetch from the server even with a local copy.
    ///   - disposition: The variant to read and keep (`inline` by default).
    /// - Stability: beta
    public func read(blobId: String, as type: String.Type, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> String {
        let data = try await read(blobId: blobId, force: force, disposition: disposition)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JsBaoError(code: .invalidArgument, message: "Blob \(blobId) is not valid UTF-8 text")
        }
        return string
    }

    /// A blob's bytes decoded as JSON into `type`.
    /// - Parameters:
    ///   - blobId: The blob.
    ///   - type: The `Decodable` type.
    ///   - force: Fetch from the server even with a local copy.
    ///   - disposition: The variant to read and keep (`inline` by default).
    /// - Stability: beta
    public func read<T: Decodable>(blobId: String, as type: T.Type, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> T {
        let data = try await read(blobId: blobId, force: force, disposition: disposition)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    /// Keep local copies of blobs ahead of use. A blob that cannot be fetched
    /// (offline, refused) is skipped.
    /// - Parameters:
    ///   - blobIds: The blobs.
    ///   - concurrency: How many downloads run at once.
    /// - Stability: beta
    public func prefetch(blobIds: [String], concurrency: Int = 2) async {
        if await refusal() != nil { return }
        await blobManager.prefetch(family: .db3, documentId: db3Id, blobIds: blobIds, concurrency: concurrency)
    }

    // MARK: - Upload queue

    /// This db3's queued uploads, most recently changed first.
    /// - Stability: beta
    public func uploadsAsync() async -> [BlobUploadStatus] {
        await blobManager.listUploads(documentId: db3Id, family: .db3)
    }

    /// Pause one of this db3's queued uploads; `false` when none is pausable.
    /// - Parameter blobId: The upload's blob.
    /// - Stability: beta
    @discardableResult
    public func pauseUploadAsync(blobId: String) async -> Bool {
        await blobManager.pauseUpload(blobId, documentId: db3Id, family: .db3)
    }

    /// Resume one of this db3's paused uploads; `false` when none is paused.
    /// - Parameter blobId: The upload's blob.
    /// - Stability: beta
    @discardableResult
    public func resumeUploadAsync(blobId: String) async -> Bool {
        await blobManager.resumeUpload(blobId, documentId: db3Id, family: .db3)
    }

    /// Pause every queued upload of this db3.
    /// - Stability: beta
    public func pauseAllAsync() async {
        await blobManager.pauseAll(documentId: db3Id, family: .db3)
    }

    /// Resume every paused upload of this db3.
    /// - Stability: beta
    public func resumeAllAsync() async {
        await blobManager.resumeAll(documentId: db3Id, family: .db3)
    }
}

/// The db3 blob list answers `{ items, hasMore, nextCursor? }`, or a bare
/// array, which is read as one page.
private struct Db3BlobListResponse: Decodable, Sendable {
    let result: DocumentBlobListResult

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let list = try? container.decode([BlobInfo].self) {
            result = DocumentBlobListResult(items: list, hasMore: false)
            return
        }
        result = try DocumentBlobListResult(from: decoder)
    }
}
