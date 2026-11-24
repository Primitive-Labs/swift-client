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
/// let info = try await blobs.get(blobId: uploaded.blobId)   // info.createdBy, info.etag
/// _ = try await blobs.deleteBatch(blobIds: [uploaded.blobId])
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
    /// Why no request may name the db3 (one that lives only on this device),
    /// asked before each call that would send one; `nil` lets it go.
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

    private func path(_ rest: String = "") throws -> String {
        "/db3/\(try URLEncoding.pathSegment(db3Id, name: "db3Id"))/blobs\(rest)"
    }

    /// Throw `.invalidArgument` when the db3 id or one of `blobIds` is
    /// exactly `.` or `..` (``URLEncoding/pathSegment(_:name:)``), before any
    /// queue, cache or network step.
    private func refuseDotSegments(_ blobIds: [String] = []) throws {
        _ = try URLEncoding.pathSegment(db3Id, name: "db3Id")
        for blobId in blobIds { _ = try URLEncoding.pathSegment(blobId, name: "blobId") }
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
        try refuseDotSegments()
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
        try refuseDotSegments()
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
        try refuseDotSegments([blobId])
        try await refuseIfLocalOnly()
        let blob = try URLEncoding.pathSegment(blobId, name: "blobId")
        return try await transport.request(method: .get, path: path("/\(blob)"))
    }

    /// A blob's download URL, built without a request. It carries no
    /// credentials, so the route refuses a load that adds none (a bare
    /// `AsyncImage`): show the blob with `BlobImage` (`JsBaoClientUI`), or
    /// send `downloadRequest(blobId:disposition:attachmentFilename:)`.
    /// - Parameters:
    ///   - blobId: The blob.
    ///   - disposition: Serve it `inline` (display) or as an `attachment` (download).
    ///   - attachmentFilename: The download's filename (RFC 5987-encoded).
    /// - Throws: `JsBaoError` `.invalidArgument` when the db3 id or `blobId` is exactly `.` or `..`.
    /// - Stability: beta
    public func downloadUrl(blobId: String, disposition: BlobDisposition? = nil, attachmentFilename: String? = nil) throws -> String {
        try blobManager.downloadUrl(
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
        guard let request = try blobManager.downloadRequest(
            family: .db3, documentId: db3Id, blobId: blobId, disposition: disposition, attachmentFilename: attachmentFilename
        ) else {
            throw JsBaoError(code: .invalidArgument, message: "Blob \(blobId) has no download URL: the client has no API URL or app id")
        }
        return request
    }

    /// Delete a blob. Once the server accepts, an upload of the id queued for
    /// this db3 is cancelled and this db3's local copy goes; an upload of the
    /// id queued for another db3 or a document stays queued, and a refused
    /// delete changes nothing on the device.
    /// - Parameter blobId: The blob.
    /// - Stability: beta
    public func delete(blobId: String) async throws -> BlobDeleteResult {
        try refuseDotSegments([blobId])
        try await refuseIfLocalOnly()
        // The cleanup is the batch delete's, for this one id.
        let requester = blobManager.requestingUserId()
        let blob = try URLEncoding.pathSegment(blobId, name: "blobId")
        let result: BlobDeleteResult = try await transport.request(
            method: .delete, path: path("/\(blob)")
        )
        await blobManager.cancelQueuedUploadsInDb3(db3Id: db3Id, blobIds: [blobId], requester: requester)
        return result
    }

    /// Delete up to 500 of the db3's blobs in one request. An id that is not
    /// a blob of this db3 is skipped and counted. Once the server accepts, a
    /// named upload queued for this db3 is cancelled and this db3's local
    /// copy of each id goes; a refused batch changes nothing on the device.
    /// - Parameter blobIds: The blobs, 0 to 500 ids.
    /// - Throws: `HttpError` for a refusal: 400 for more than 500 ids or an
    ///   empty id, 403 for a caller who may not write the db3.
    /// - Stability: beta
    public func deleteBatch(blobIds: [String]) async throws -> Db3BlobBatchDeleteResult {
        try refuseDotSegments(blobIds)
        try await refuseIfLocalOnly()
        // The cleanup is the requester's, even when another user signs in
        // while the request is out (CSO-6245-009).
        let requester = blobManager.requestingUserId()
        let result: Db3BlobBatchDeleteResult = try await transport.request(
            method: .post, path: path("/delete"), body: ["blobIds": blobIds]
        )
        await blobManager.cancelQueuedUploadsInDb3(db3Id: db3Id, blobIds: blobIds, requester: requester)
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
        try refuseDotSegments([blobId])
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
    /// - Throws: `.invalidArgument` when the db3 id or a blob id is exactly
    ///   `.` or `..`, before anything is fetched.
    /// - Stability: beta
    public func prefetch(blobIds: [String], concurrency: Int = 2) async throws {
        try refuseDotSegments(blobIds)
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
