import Foundation

// A session's attachments, as `view.attachments` offers them — the Swift half
// of the JS client's `src/client/agents/sessionAttachments.ts`, member for
// member.
//
// Uploads go through the client's blob queue with the session as their
// destination: the bytes are kept locally first, each attempt PUTs to
// `/agent-sessions/{sessionId}/attachments/{blobId}`, and a queued upload
// survives the view's close and, with SQLite storage, the process: the next
// client for the same app and user restores it. The files are blobs of the
// session's db3, whose id is the session's.

/// A file uploaded to a session: what `files: [AgentSessionFileRef(blobId:)]`
/// on a send names.
public struct AgentSessionAttachment: Sendable, Equatable, Hashable {
    public let blobId: String
    public let filename: String
    public let contentType: String
    public let numBytes: Int

    public init(blobId: String, filename: String, contentType: String, numBytes: Int) {
        self.blobId = blobId
        self.filename = filename
        self.contentType = contentType
        self.numBytes = numBytes
    }
}

/// Options for `view.attachments.upload(_:options:)`.
public struct AgentSessionAttachmentUploadOptions: Sendable, Equatable {
    /// The file's name (default `blob-<epoch ms>`).
    public var filename: String?
    /// The file's media type (default `application/octet-stream`). A
    /// message's files must be an image (png, jpeg, webp, gif) or a PDF.
    public var contentType: String?
    /// How downloads serve the file by default: `.attachment` (the server's
    /// default) or `.inline`.
    public var disposition: BlobDisposition?

    public init(filename: String? = nil, contentType: String? = nil, disposition: BlobDisposition? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.disposition = disposition
    }
}

/// One of the session's uploads that has not completed, from
/// `view.attachments.uploads()`.
public struct AgentSessionUploadStatus: Sendable, Equatable {
    /// `.pending` while it waits for an attempt (or the network),
    /// `.uploading` during one, `.paused` after `pause`, `.failed` once the
    /// server refused it (it keeps its bytes until `resume` retries it or
    /// `cancel` drops it). A completed upload leaves the list, so `.uploaded`
    /// is never listed.
    public enum State: String, Sendable, Equatable {
        case pending
        case uploading
        case uploaded
        case paused
        case failed
    }

    /// Why an upload failed: the server's `code` when it answered one.
    public struct Failure: Sendable, Equatable {
        public let code: String?
        public let message: String

        public init(code: String?, message: String) {
            self.code = code
            self.message = message
        }
    }

    public let blobId: String
    public let filename: String
    public let contentType: String
    public let numBytes: Int
    public let state: State
    /// Attempts made so far.
    public let attempts: Int
    /// Seconds since 1970 of the next attempt while one is scheduled.
    public let nextAttemptAt: TimeInterval
    /// Seconds since 1970 of the last change.
    public let updatedAt: TimeInterval
    /// The last attempt's message while a retry is scheduled.
    public let lastError: String?
    /// Why the upload failed; `.failed` only.
    public let error: Failure?

    public init(
        blobId: String, filename: String, contentType: String, numBytes: Int, state: State, attempts: Int,
        nextAttemptAt: TimeInterval, updatedAt: TimeInterval, lastError: String? = nil, error: Failure? = nil
    ) {
        self.blobId = blobId
        self.filename = filename
        self.contentType = contentType
        self.numBytes = numBytes
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.error = error
    }
}

/// A session's files, from `view.attachments`: upload them (queued and
/// retried, surviving the view's close and, with SQLite storage, a restart
/// of the app), follow and control the queue, and read any file of the
/// session.
///
/// Send an uploaded file with `view.send(text:files:)`; a message naming an
/// upload still queued waits for it. After `view.close()`, `upload` and
/// `read` throw `.invalidArgument`; the queue members keep answering and a
/// queued upload keeps going.
public final class AgentSessionAttachments: Sendable {
    private let manager: BlobManager
    private let sessionId: String
    /// The session's db3 (its id the session's): the local store's key and the
    /// `blobs:upload-*` events' `documentId`, never a route.
    private let documentId: String
    private let isClosed: @Sendable () -> Bool

    init(manager: BlobManager, sessionId: String, documentId: String, isClosed: @escaping @Sendable () -> Bool) {
        self.manager = manager
        self.sessionId = sessionId
        self.documentId = documentId
        self.isClosed = isClosed
    }

    /// Upload a file to the session. The bytes are kept locally and one
    /// attempt is made at once; returns once it landed or, on a retryable
    /// failure or while the client may not use the network, once it is
    /// queued for retry. A refusal (`AGENT_SESSION_PARTICIPANT_ONLY`,
    /// `AGENT_SESSION_NOT_FOUND`, a size or integrity error) throws
    /// `HttpError` with the server's `serverCode`, and the upload stays in
    /// `uploads()` as `.failed` with its bytes.
    public func upload(
        _ data: Data, options: AgentSessionAttachmentUploadOptions = AgentSessionAttachmentUploadOptions()
    ) async throws -> AgentSessionAttachment {
        try requireOpen()
        return try await manager.uploadSessionAttachment(
            sessionId: sessionId, documentId: documentId, data: data, options: options
        )
    }

    /// The session's uploads that have not completed, most recently changed
    /// first.
    public func uploads() async -> [AgentSessionUploadStatus] {
        await manager.listSessionUploads(sessionId: sessionId)
    }

    /// Pause a pending or uploading upload; a transfer in flight is cancelled
    /// and its outcome ignored.
    ///
    /// - Returns: `false` for an unknown id or an upload that is not pending
    ///   or uploading.
    @discardableResult
    public func pause(blobId: String) async -> Bool {
        await manager.pauseSessionUpload(blobId: blobId, sessionId: sessionId)
    }

    /// Make a paused or failed upload pending at once; for a failed one this
    /// is the retry.
    ///
    /// - Returns: `false` for an unknown id or an upload that is not paused
    ///   or failed.
    @discardableResult
    public func resume(blobId: String) async -> Bool {
        await manager.resumeSessionUpload(blobId: blobId, sessionId: sessionId)
    }

    /// Drop an upload from the queue with its local bytes, cancelling a
    /// transfer in flight. Never deletes anything on the server.
    ///
    /// - Returns: `false` when the id is not queued (completed, cancelled or
    ///   unknown).
    @discardableResult
    public func cancel(blobId: String) async -> Bool {
        await manager.cancelSessionUpload(blobId: blobId, sessionId: sessionId)
    }

    /// Return once the upload completes, or at once for one that completed in
    /// this process. Throws the upload's error once it fails, and
    /// `JsBaoError` with `.agentSessionUploadCancelled` after `cancel`,
    /// `.agentSessionUploadIdentityChanged` when the signed-in user changes,
    /// `.agentSessionUploadUnknown` for an id this client never uploaded, or
    /// `.unavailable` once the client is destroyed (the upload stays stored
    /// for the next launch).
    @discardableResult
    public func waitUntilUploaded(blobId: String) async throws -> AgentSessionAttachment {
        try await manager.waitUntilSessionUploaded(blobId: blobId, sessionId: sessionId)
    }

    /// Read a file of the session: the local copy when this client holds one
    /// (an upload it made, or an earlier read), else a download through the
    /// session, kept for next time. A refusal throws `HttpError` with the
    /// server's code (`AGENT_SESSION_ATTACHMENT_NOT_FOUND` for an id the
    /// session does not hold); with no local copy while the client may not use
    /// the network, `JsBaoError(.offline)`.
    ///
    /// - Parameters:
    ///   - force: download again even when a local copy exists.
    ///   - disposition: read the `inline` (default) or `attachment` variant.
    public func read(blobId: String, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> Data {
        try requireOpen()
        return try await manager.readSessionAttachment(
            sessionId: sessionId, documentId: documentId, blobId: blobId, force: force, disposition: disposition
        )
    }

    /// Read a file of the session as UTF-8 text.
    public func read(
        blobId: String, as type: String.Type, force: Bool = false, disposition: BlobDisposition? = nil
    ) async throws -> String {
        let data = try await read(blobId: blobId, force: force, disposition: disposition)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JsBaoError(code: .invalidArgument, message: "Attachment \(blobId) is not valid UTF-8 text")
        }
        return string
    }

    /// Read a file of the session and JSON-decode it.
    public func read<T: Decodable>(
        blobId: String, as type: T.Type, force: Bool = false, disposition: BlobDisposition? = nil
    ) async throws -> T {
        let data = try await read(blobId: blobId, force: force, disposition: disposition)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    private func requireOpen() throws {
        if isClosed() {
            throw JsBaoError(code: .invalidArgument, message: "The session view is closed")
        }
    }
}
