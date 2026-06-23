import Foundation
import CryptoKit

/// Manages blob upload/download with queue, caching, and SHA256 hashing.
public final class BlobManager: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: Logger

    // Dependencies (set externally)
    var makeRequest: ((String, String, Any?) async throws -> Any)?
    var makeRawRequest: ((String, String, Data?, [String: String]?) async throws -> (Data, Int))?
    var getApiUrl: (() -> String)?
    var getAppId: (() -> String)?
    var getToken: (() -> String?)?
    var getGlobalAdminAppId: (() -> String)?
    var getCurrentUserId: (() -> String?)?
    weak var emitter: EventEmitter?

    // Upload queue
    private var uploadQueue: [String: UploadTask] = [:]
    private var activeUploads = 0
    private var uploadConcurrency: Int

    // Memory cache for blobs
    private var memoryBlobs: [String: Data] = [:]

    // Backoff settings
    private let backoffBase: Int = 2000
    private let backoffMax: Int = 60000

    public init(logger: Logger, uploadConcurrency: Int = 2) {
        self.logger = logger.forScope(scope: "blob")
        self.uploadConcurrency = uploadConcurrency
    }

    // MARK: - Upload

    /// Upload a blob immediately
    public func uploadImmediate(
        documentId: String,
        blobId: String,
        data: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions(),
        attempts: Int = 1
    ) async throws -> BlobUploadResult {
        let sha256 = options.sha256Base64 ?? hashSHA256Base64(data)
        let filename = options.filename ?? blobId
        let contentType = options.contentType ?? "application/octet-stream"

        let path = "/documents/\(documentId)/blobs/\(blobId)"
        var headers: [String: String] = [
            "Content-Type": contentType,
            "X-Blob-Filename": filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename,
            "X-Blob-Size": "\(data.count)",
            "X-Blob-Sha256": sha256,
        ]
        if let disposition = options.disposition {
            headers["X-Blob-Disposition"] = disposition.rawValue
        }

        guard let makeRawRequest = makeRawRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let (responseData, status) = try await makeRawRequest("PUT", path, data, headers)

        guard status >= 200 && status < 300 else {
            throw HttpError(status: status, message: "Blob upload failed", body: String(data: responseData, encoding: .utf8))
        }

        let result = BlobUploadResult(
            blobId: blobId,
            numBytes: data.count,
            contentType: contentType,
            bytesTransferred: data.count
        )

        // Mirror JS `emitUploadComplete`: carry the full queue record. The
        // immediate path isn't queued, so `queueId == blobId` (the JS
        // invariant) and `attempts` reflects the attempt count passed in by
        // the caller (1 for a first immediate try; the retry count when the
        // queue worker re-invokes after a failure).
        emitter?.emit(.blobsUploadCompleted, BlobUploadCompletedEvent(
            documentId: documentId,
            blobId: blobId,
            queueId: blobId,
            filename: filename,
            contentType: contentType,
            numBytes: data.count,
            attempts: attempts,
            retainLocal: options.retainLocal,
            updatedAt: Date().timeIntervalSince1970
        ))

        return result
    }

    /// Upload from source data with queuing
    public func uploadFromSource(
        documentId: String,
        source: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> BlobUploadResult {
        let blobId = ULID.generate()
        let sha256 = options.sha256Base64 ?? hashSHA256Base64(source)

        // Store in memory cache under the disposition-qualified key (defaulting
        // to inline) so a subsequent `read` — which looks up the inline variant
        // by default — finds the just-uploaded bytes.
        lock.lock()
        memoryBlobs[Self.cacheKey(documentId, blobId, options.disposition ?? .inline)] = source
        lock.unlock()

        // Try immediate upload
        do {
            let result = try await uploadImmediate(
                documentId: documentId,
                blobId: blobId,
                data: source,
                options: BlobUploadSourceOptions(
                    filename: options.filename,
                    contentType: options.contentType,
                    sha256Base64: sha256,
                    disposition: options.disposition,
                    retainLocal: options.retainLocal
                )
            )
            // retainLocal defaults to `true` (matching JS). When the caller
            // opts out, drop the bytes from the local cache after a successful
            // upload so a later `read` re-fetches from the server.
            if options.retainLocal == false {
                evict(documentId: documentId, blobId: blobId)
            }
            return result
        } catch {
            // Queue for retry
            let task = UploadTask(
                blobId: blobId,
                documentId: documentId,
                data: source,
                options: options,
                sha256: sha256,
                attempts: 1,
                lastError: error.localizedDescription
            )

            lock.lock()
            uploadQueue[blobId] = task
            lock.unlock()

            // Mirror JS `emitUploadFailed`: carry the full queue record. The
            // task was just queued (attempt 1), so it will be retried — hence
            // `willRetry: true`. `lastError` is optional in the payload (JS
            // parity) but always present here.
            emitter?.emit(.blobsUploadFailed, BlobUploadFailedEvent(
                documentId: documentId,
                blobId: blobId,
                queueId: task.queueId,
                filename: task.filename,
                contentType: task.contentType,
                numBytes: task.data.count,
                attempts: task.attempts,
                retainLocal: task.retainLocal,
                lastError: task.lastError,
                willRetry: true,
                nextAttemptAt: task.nextAttemptAt,
                updatedAt: task.updatedAt
            ))
            // JS `handleUploadFailure` follows the failed event with a
            // progress frame showing the queued-for-retry state (#996).
            emitUploadProgress(task, status: "pending")

            scheduleQueueProcessing()
            throw error
        }
    }

    // MARK: - Download

    /// Build download URL for a blob.
    ///
    /// Mirrors JS `getDownloadUrl` / `BlobDownloadUrlParams`: an optional
    /// `disposition` plus an optional `attachmentFilename` that overrides the
    /// download filename. The filename is emitted as an RFC 5987 ext-value
    /// (`UTF-8''<pct-encoded>`), matching the JS client's `encodeRFC5987Value`.
    public func downloadUrl(
        documentId: String,
        blobId: String,
        disposition: BlobDisposition? = nil,
        attachmentFilename: String? = nil
    ) -> String {
        guard let apiUrl = getApiUrl?(), let appId = getAppId?() else { return "" }
        var url = "\(apiUrl)/app/\(appId)/api/documents/\(documentId)/blobs/\(blobId)/download"
        var query: [String] = []
        if let disposition = disposition {
            query.append("disposition=\(disposition.rawValue)")
        }
        if let attachmentFilename = attachmentFilename, !attachmentFilename.isEmpty {
            let encoded = "UTF-8''\(Self.encodeRFC5987Value(attachmentFilename))"
            query.append("attachmentFilename=\(encoded)")
        }
        if !query.isEmpty {
            url += "?" + query.joined(separator: "&")
        }
        return url
    }

    /// Percent-encode a string as an RFC 5987 ext-value payload. Everything
    /// outside the unreserved set is percent-encoded so the result is always
    /// safe to decode server-side. Mirrors the JS client's `encodeRFC5987Value`.
    static func encodeRFC5987Value(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Read a blob's content
    ///
    /// - Parameter disposition: serve the download `inline` (the default when
    ///   omitted) or as an `attachment`. Mirrors JS `BlobReadOptions.disposition`:
    ///   the disposition is folded into the cache key so an `inline` and an
    ///   `attachment` read of the same blob don't collide, and is forwarded to
    ///   the download URL.
    public func read(documentId: String, blobId: String, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> Data {
        // Effective disposition for both the cache key and the request — JS
        // defaults `read` to the inline variant when none is supplied.
        let effectiveDisposition = disposition ?? .inline
        // Check memory cache first. The disposition is part of the key so an
        // inline read and an attachment read of the same blob cache separately,
        // mirroring js-bao's `::disp=` cache-key suffix in `blobManager.ts`.
        let cacheKey = Self.cacheKey(documentId, blobId, effectiveDisposition)
        if !force {
            lock.lock()
            if let cached = memoryBlobs[cacheKey] {
                lock.unlock()
                return cached
            }
            lock.unlock()
        }

        // Download from server
        let url = downloadUrl(documentId: documentId, blobId: blobId, disposition: effectiveDisposition)
        guard let requestUrl = URL(string: url) else {
            throw JsBaoError(code: .invalidArgument, message: "Invalid blob URL")
        }

        var request = URLRequest(url: requestUrl)
        if let token = getToken?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let adminAppId = getGlobalAdminAppId?() {
            request.setValue(adminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw HttpError(status: status, message: "Blob download failed")
        }

        // Cache in memory
        lock.lock()
        memoryBlobs[cacheKey] = data
        lock.unlock()

        return data
    }

    /// Prefetch multiple blobs
    public func prefetch(documentId: String, blobIds: [String], concurrency: Int = 2) async {
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for blobId in blobIds {
                if active >= concurrency {
                    await group.next()
                    active -= 1
                }
                group.addTask {
                    try? await self.read(documentId: documentId, blobId: blobId)
                }
                active += 1
            }
        }
    }

    // MARK: - Queue Management

    /// Pause an in-progress upload by blob ID. When `documentId` is supplied,
    /// the upload is only paused if it belongs to that document (mirrors JS
    /// `pauseUpload(queueId, documentId?)`, which the per-document context
    /// passes its own id to).
    public func pauseUpload(_ blobId: String, documentId: String? = nil) -> Bool {
        lock.lock()
        guard var task = uploadQueue[blobId] else {
            lock.unlock()
            return false
        }
        if let documentId = documentId, task.documentId != documentId {
            lock.unlock()
            return false
        }
        if task.paused {
            lock.unlock()
            return false
        }
        task.paused = true
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        lock.unlock()
        // Mirror JS `pauseUpload`: paused event + progress frame (#996).
        emitUploadPaused(task)
        emitUploadProgress(task, status: "paused")
        return true
    }

    /// Resume a paused upload by blob ID, optionally scoped to `documentId`.
    public func resumeUpload(_ blobId: String, documentId: String? = nil) -> Bool {
        lock.lock()
        guard var task = uploadQueue[blobId] else {
            lock.unlock()
            return false
        }
        if let documentId = documentId, task.documentId != documentId {
            lock.unlock()
            return false
        }
        guard task.paused else {
            lock.unlock()
            return false
        }
        task.paused = false
        task.nextAttemptAt = Date().timeIntervalSince1970
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        lock.unlock()
        // Mirror JS `resumeUpload`: resumed event + progress frame with the
        // queued-for-retry ("pending") state (#996).
        emitUploadResumed(task)
        emitUploadProgress(task, status: "pending")
        scheduleQueueProcessing()
        return true
    }

    /// Pause every queued upload, optionally scoped to a single document.
    public func pauseAll(documentId: String? = nil) {
        var pausedTasks: [UploadTask] = []
        lock.lock()
        for (blobId, var task) in uploadQueue {
            if let documentId = documentId, task.documentId != documentId { continue }
            if task.paused { continue }
            task.paused = true
            task.updatedAt = Date().timeIntervalSince1970
            uploadQueue[blobId] = task
            pausedTasks.append(task)
        }
        lock.unlock()
        for task in pausedTasks {
            emitUploadPaused(task)
            emitUploadProgress(task, status: "paused")
        }
    }

    /// Resume every paused upload, optionally scoped to a single document.
    public func resumeAll(documentId: String? = nil) {
        var resumedTasks: [UploadTask] = []
        lock.lock()
        for (blobId, var task) in uploadQueue {
            if let documentId = documentId, task.documentId != documentId { continue }
            if task.paused {
                task.paused = false
                task.nextAttemptAt = Date().timeIntervalSince1970
                task.updatedAt = Date().timeIntervalSince1970
                uploadQueue[blobId] = task
                resumedTasks.append(task)
            }
        }
        lock.unlock()
        for task in resumedTasks {
            emitUploadResumed(task)
            emitUploadProgress(task, status: "pending")
        }
        if !resumedTasks.isEmpty {
            scheduleQueueProcessing()
        }
    }

    /// Remove a queued upload (if any) for a blob and evict its cached bytes.
    /// Mirrors the queue-cleanup half of JS `delete`: a delete issued
    /// mid-upload cancels the in-flight transfer and emits `queue-drained`
    /// once the queue empties.
    func cancelQueuedUpload(documentId: String, blobId: String) {
        lock.lock()
        let removed = uploadQueue.removeValue(forKey: blobId) != nil
        let queueEmpty = uploadQueue.isEmpty
        lock.unlock()
        evict(documentId: documentId, blobId: blobId)
        if removed && queueEmpty {
            emitter?.emit(.blobsQueueDrained, [:] as [String: Any])
        }
    }

    public func setUploadConcurrency(_ value: Int) {
        lock.lock()
        uploadConcurrency = max(1, value)
        lock.unlock()
    }

    public func getUploadConcurrency() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return uploadConcurrency
    }

    /// Snapshot of tracked uploads, newest-updated first. When `documentId` is
    /// supplied only that document's uploads are returned (mirrors JS
    /// `getUploads(documentId?)`, which the per-document context scopes).
    public func listUploads(documentId: String? = nil) -> [BlobUploadStatus] {
        lock.lock()
        defer { lock.unlock() }
        return uploadQueue.values
            .filter { documentId == nil || $0.documentId == documentId }
            .map { task in
                BlobUploadStatus(
                    queueId: task.queueId,
                    documentId: task.documentId,
                    blobId: task.blobId,
                    filename: task.filename,
                    contentType: task.contentType,
                    numBytes: task.data.count,
                    status: task.paused ? "paused" : "pending",
                    attempts: task.attempts,
                    nextAttemptAt: task.nextAttemptAt,
                    retainLocal: task.retainLocal,
                    lastError: task.lastError,
                    updatedAt: task.updatedAt
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Cleanup

    public func clearCache() {
        lock.lock()
        memoryBlobs.removeAll()
        lock.unlock()
    }

    /// Evict a single blob from the local memory cache (no server call).
    /// Mirrors JS `deleteBlobBytes`, so a deleted blob isn't served stale
    /// from cache on a later `read`.
    func evict(documentId: String, blobId: String) {
        lock.lock()
        // Drop every disposition variant cached for this blob (the key is
        // disposition-qualified), plus any legacy un-qualified entry, so a
        // deleted blob can't be served stale under any disposition.
        let prefix = "\(documentId)::\(blobId)"
        for key in memoryBlobs.keys where key == prefix || key.hasPrefix("\(prefix)::") {
            memoryBlobs.removeValue(forKey: key)
        }
        lock.unlock()
    }

    // MARK: - Private

    /// Build the memory-cache key for a blob read/write. The disposition is
    /// part of the key so an inline read and an attachment read of the same
    /// blob cache separately, mirroring js-bao's `::disp=` cache-key suffix
    /// in `blobManager.ts`.
    private static func cacheKey(
        _ documentId: String,
        _ blobId: String,
        _ disposition: BlobDisposition
    ) -> String {
        return "\(documentId)::\(blobId)::disp=\(disposition.rawValue)"
    }

    private func scheduleQueueProcessing() {
        Task {
            await processQueue()
        }
    }

    private func processQueue() async {
        lock.lock()
        let tasks = uploadQueue.values.filter { !$0.paused }
            .sorted(by: { $0.nextAttemptAt < $1.nextAttemptAt })
        let available = uploadConcurrency - activeUploads
        lock.unlock()

        guard available > 0 else { return }

        let now = Date().timeIntervalSince1970
        let toProcess = tasks.prefix(available).filter { $0.nextAttemptAt <= now }

        for task in toProcess {
            lock.lock()
            activeUploads += 1
            lock.unlock()

            // Mirror JS `runUploadTask`: progress frame when the attempt
            // actually starts (#996).
            emitUploadProgress(task, status: "uploading")

            do {
                let _ = try await uploadImmediate(
                    documentId: task.documentId,
                    blobId: task.blobId,
                    data: task.data,
                    options: task.options,
                    attempts: task.attempts
                )

                lock.lock()
                uploadQueue.removeValue(forKey: task.blobId)
                activeUploads -= 1
                let queueEmpty = uploadQueue.isEmpty
                lock.unlock()

                if queueEmpty {
                    emitter?.emit(.blobsQueueDrained, [:] as [String: Any])
                }
            } catch {
                lock.lock()
                activeUploads -= 1
                var failedTask: UploadTask?
                if var updatedTask = uploadQueue[task.blobId] {
                    updatedTask.attempts += 1
                    updatedTask.lastError = error.localizedDescription
                    let delay = computeBackoff(attempts: updatedTask.attempts)
                    updatedTask.nextAttemptAt = Date().timeIntervalSince1970 + Double(delay) / 1000.0
                    updatedTask.updatedAt = Date().timeIntervalSince1970
                    uploadQueue[task.blobId] = updatedTask
                    failedTask = updatedTask
                }
                lock.unlock()

                // Mirror JS `emitUploadFailed`: emit on every failed attempt
                // (not just the first), carrying the updated queue record so
                // subscribers see the incremented `attempts`, the backoff
                // `nextAttemptAt`, and the latest `lastError`. The task stays
                // queued, so `willRetry: true`.
                if let failedTask = failedTask {
                    emitter?.emit(.blobsUploadFailed, BlobUploadFailedEvent(
                        documentId: failedTask.documentId,
                        blobId: failedTask.blobId,
                        queueId: failedTask.queueId,
                        filename: failedTask.filename,
                        contentType: failedTask.contentType,
                        numBytes: failedTask.data.count,
                        attempts: failedTask.attempts,
                        retainLocal: failedTask.retainLocal,
                        lastError: failedTask.lastError,
                        willRetry: true,
                        nextAttemptAt: failedTask.nextAttemptAt,
                        updatedAt: failedTask.updatedAt
                    ))
                    // JS `handleUploadFailure` parity: progress frame with
                    // the queued-for-retry state (#996).
                    emitUploadProgress(failedTask, status: "pending")
                }

                // Schedule retry
                let delay = computeBackoff(attempts: task.attempts + 1)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    await self.processQueue()
                }
            }
        }
    }

    /// Emit `blobs:upload-progress` with the full queue record, mirroring
    /// JS `emitUploadProgress` (`src/client/internal/blobManager.ts`).
    /// `status` ∈ `"queued" | "uploading" | "pending" | "paused"` (#996).
    private func emitUploadProgress(_ task: UploadTask, status: String) {
        emitter?.emit(.blobsUploadProgress, BlobUploadProgressEvent(
            documentId: task.documentId,
            blobId: task.blobId,
            queueId: task.queueId,
            filename: task.filename,
            contentType: task.contentType,
            numBytes: task.data.count,
            status: status,
            attempts: task.attempts,
            nextAttemptAt: task.nextAttemptAt,
            retainLocal: task.retainLocal,
            lastError: task.lastError,
            updatedAt: task.updatedAt
        ))
    }

    private func emitUploadPaused(_ task: UploadTask) {
        emitter?.emit(.blobsUploadPaused, BlobUploadPausedEvent(
            documentId: task.documentId,
            blobId: task.blobId,
            queueId: task.queueId,
            filename: task.filename,
            contentType: task.contentType,
            numBytes: task.data.count,
            attempts: task.attempts,
            retainLocal: task.retainLocal,
            updatedAt: task.updatedAt
        ))
    }

    private func emitUploadResumed(_ task: UploadTask) {
        emitter?.emit(.blobsUploadResumed, BlobUploadResumedEvent(
            documentId: task.documentId,
            blobId: task.blobId,
            queueId: task.queueId,
            filename: task.filename,
            contentType: task.contentType,
            numBytes: task.data.count,
            attempts: task.attempts,
            retainLocal: task.retainLocal,
            updatedAt: task.updatedAt
        ))
    }

    private func computeBackoff(attempts: Int) -> Int {
        let delay = Double(backoffBase) * pow(2.0, Double(attempts - 1))
        return min(Int(delay), backoffMax)
    }

    private func hashSHA256Base64(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - Supporting Types

struct UploadTask {
    let blobId: String
    let documentId: String
    let data: Data
    let options: BlobUploadSourceOptions
    let sha256: String
    var attempts: Int
    var lastError: String?
    var paused: Bool = false
    var nextAttemptAt: TimeInterval = 0
    var updatedAt: TimeInterval = Date().timeIntervalSince1970

    /// The queue identifier. Mirrors JS, where `queueId === blobId`.
    var queueId: String { blobId }
    var filename: String { options.filename ?? blobId }
    var contentType: String { options.contentType ?? "application/octet-stream" }
    var retainLocal: Bool? { options.retainLocal }
}

public struct BlobUploadResult: Sendable {
    public let blobId: String
    public let numBytes: Int
    public let contentType: String
    public let bytesTransferred: Int?
}

/// Status of a tracked upload. Field-for-field mirror of the JS
/// `BlobUploadStatus` returned by `uploads()`.
public struct BlobUploadStatus: Sendable {
    public let queueId: String
    public let documentId: String
    public let blobId: String
    public let filename: String
    public let contentType: String
    public let numBytes: Int
    public let status: String
    public let attempts: Int
    public let nextAttemptAt: TimeInterval
    public let retainLocal: Bool?
    public let lastError: String?
    public let updatedAt: TimeInterval
}

public struct BlobListResult: Sendable, Codable {
    public let items: [BlobInfo]
}

public struct BlobInfo: Sendable, Codable {
    public let blobId: String
    public let filename: String?
    public let contentType: String?
    public let numBytes: Int?
    public let sha256: String?
    public let createdAt: String?
    public let disposition: String?
}

// MARK: - ULID Generator

enum ULID {
    private static let encoding: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var chars = [Character](repeating: "0", count: 26)

        // Encode 10-char timestamp (48-bit ms) in Crockford's Base32, big-endian
        var t = now
        for i in stride(from: 9, through: 0, by: -1) {
            chars[i] = encoding[Int(t & 0x1F)]
            t >>= 5
        }

        // Encode 16 chars of randomness
        for i in 10..<26 {
            chars[i] = encoding[Int.random(in: 0..<32)]
        }

        return String(chars)
    }
}
