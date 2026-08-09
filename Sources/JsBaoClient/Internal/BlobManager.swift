import Foundation
import CryptoKit

/// Manages blob upload/download with queue, caching, and SHA256 hashing.
///
/// An `actor` since #2172 (the follow-up split out of #1993 Phase D). What used
/// to be one `NSLock` guarding the upload queue, the memory blob cache, the
/// concurrency setting and the coalesced queue timer is actor isolation; the
/// `@unchecked Sendable` opt-out and every `lock.withLock` are gone, and no
/// lock of any kind survives. Four consequences worth stating because they are
/// not obvious from the type:
///
/// * **The network work stays off the actor.** `uploadImmediate`, `read`,
///   `prefetch`, `processQueue` and `runUploadTask` are `nonisolated`, so
///   concurrent transfers stay genuinely concurrent. The actor serializes only
///   the same critical sections the lock did — selecting tasks, bookkeeping a
///   result, arming the timer.
/// * **Emissions run off the actor.** `EventEmitter` delivers callback
///   subscribers *synchronously*, so an emit runs arbitrary app code. Every
///   emit helper is `nonisolated` and no isolated method calls one, which is
///   what stops a slow `blobs:upload-progress` handler from occupying the
///   upload queue (the rule Phase D2 shipped for `KvCache`).
/// * **`downloadUrl` stays synchronous, permanently.** It reads only the
///   immutable `getApiUrl` / `getAppId` closures, so it is `nonisolated` and
///   keeps its exact shape — it feeds URLs straight from SwiftUI bodies.
/// * **Everything else on the queue surface is `async`.** The synchronous
///   forms that have to survive (or be guided through) the deprecation window
///   live on `JsBaoClient`, `DocumentsAPI` and `DocumentBlobContext`; see the
///   Fork 1 Option C note on those types.
public actor BlobManager {
    private nonisolated let logger: Logger

    // Dependencies. Supplied at construction rather than assigned afterwards
    // (#2172): an actor has no synchronous setter — the same wall Phase D2 hit
    // with `KvCache.setEmitter` and D3 with the analytics collaborators.
    // Immutable and `Sendable`, so they are `nonisolated` and readable from the
    // nonisolated members above without an actor hop.
    /// The typed HTTP transport. Blob upload/download go through
    /// `Transport.requestData`, which returns the response bytes untouched —
    /// the previous raw closure reconstructed them from decoded text and
    /// corrupted any non-UTF-8 payload.
    nonisolated let transport: (any Transport)?
    nonisolated let getApiUrl: (@Sendable () -> String)?
    nonisolated let getAppId: (@Sendable () -> String)?
    nonisolated let getToken: (@Sendable () -> String?)?
    nonisolated let getGlobalAdminAppId: (@Sendable () -> String)?

    /// Emits the blob lifecycle events (`blobs:upload-*`, `blobs:queue-drained`).
    /// A closure rather than a `weak var emitter: EventEmitter?` — the exact
    /// shape `KvCache` took in Phase D2 (`JsBaoClient.swift`, `KvCache.init`):
    /// it preserves the previous weak lifetime (the closure captures the
    /// emitter weakly), it is `Sendable`, and it is callable from `nonisolated`
    /// context.
    ///
    /// **It is invoked from `nonisolated` context, never while the actor is
    /// held.** `EventEmitter.dispatch` delivers callback subscribers
    /// *synchronously*, so this closure runs arbitrary app code. Emitting from
    /// an isolated step would put that app code on the manager's executor,
    /// where a slow `blobs:upload-progress` handler serializes the whole upload
    /// queue and a handler that waits on work needing the manager deadlocks
    /// outright. Before the conversion the emits ran with no lock held; keeping
    /// them off the actor preserves exactly that.
    nonisolated let emit: (@Sendable (any JsBaoEventPayload) -> Void)?

    // Upload queue — isolated state, exactly what the NSLock guarded.
    private var uploadQueue: [String: UploadTask] = [:]
    private var activeUploads = 0
    private var uploadConcurrency: Int

    // The single coalesced queue timer, mirroring the JS client's
    // `uploadTimer` / `scheduleQueueProcessing` / `clearQueueTimer`
    // (`src/client/internal/blobManager.ts`). One timer is pending at a time,
    // armed for the earliest retry deadline — never one timer per failure.
    private var queueTimerTask: Task<Void, Never>?
    private var queueTimerDeadline: TimeInterval?
    private var queueTimerGeneration: UInt64 = 0
    /// Number of queue timers actually started. Test-visible so the
    /// "one coalesced timer, not one per failure" invariant can be asserted.
    private var queueTimerStartCountValue = 0

    // Memory cache for blobs
    private var memoryBlobs: [String: Data] = [:]

    // Backoff settings. `nonisolated` so `computeBackoff` needs no actor hop.
    private nonisolated let backoffBase: Int
    private nonisolated let backoffMax: Int

    /// The one designated initializer. Every collaborator is supplied here —
    /// there is no post-construction setter, because an `actor` cannot have one
    /// (#2172), and this is also why the previous `convenience init` is gone:
    /// the Swift 6 language mode rejects convenience initializers on an actor
    /// (`KvCache.swift`'s two designated inits record the same precedent).
    ///
    /// `backoffBaseMs` / `backoffMaxMs` default to the production 2s…60s bounds
    /// when omitted; they are injectable so tests can exercise the retry loop on
    /// a millisecond timescale. They are `Int?` rather than defaulted to the
    /// `defaultBackoff*Ms` constants because those constants are `internal`, and
    /// a public default argument cannot reference an internal declaration.
    // Internal: takes the module-internal `Logger` (#2363).
    init(
        logger: Logger,
        uploadConcurrency: Int = 2,
        backoffBaseMs: Int? = nil,
        backoffMaxMs: Int? = nil,
        transport: (any Transport)? = nil,
        getApiUrl: (@Sendable () -> String)? = nil,
        getAppId: (@Sendable () -> String)? = nil,
        getToken: (@Sendable () -> String?)? = nil,
        getGlobalAdminAppId: (@Sendable () -> String)? = nil,
        emit: (@Sendable (any JsBaoEventPayload) -> Void)? = nil
    ) {
        self.logger = logger.forScope(scope: "blob")
        self.uploadConcurrency = uploadConcurrency
        self.backoffBase = max(1, backoffBaseMs ?? BlobManager.defaultBackoffBaseMs)
        self.backoffMax = max(1, backoffMaxMs ?? BlobManager.defaultBackoffMaxMs)
        self.transport = transport
        self.getApiUrl = getApiUrl
        self.getAppId = getAppId
        self.getToken = getToken
        self.getGlobalAdminAppId = getGlobalAdminAppId
        self.emit = emit
    }

    static let defaultBackoffBaseMs = 2000
    static let defaultBackoffMaxMs = 60000

    /// Deadlines within 5ms of an already-armed timer are treated as covered
    /// by it, so concurrent scheduling requests coalesce onto one timer.
    private static let queueTimerCoalesceSlack: TimeInterval = 0.005

    /// Cancel the pending queue timer.
    ///
    /// The safety argument is **rewritten** for the actor (#2172), not carried
    /// over: the pre-conversion one was "the lock makes this read safe", which
    /// says nothing once there is no lock. The argument now is that `deinit`
    /// runs only when no reference to the actor remains, so no isolated work
    /// can be in flight and none can be scheduled — nothing can race this read
    /// of `queueTimerTask`. The timer holds `self` **weakly**
    /// (see `makeQueueTimer`), so a pending timer never kept the actor alive,
    /// and cancelling it only wakes a sleeping task to exit.
    ///
    /// What it explicitly **cannot** do is drain the queue: cancelling
    /// in-flight uploads and emitting `blobs:queue-drained` needs `await`, and
    /// a `deinit` cannot await — the same limitation `AnalyticsQueue.deinit`
    /// records. Queued uploads are dropped with the manager, exactly as they
    /// were before the conversion.
    deinit {
        queueTimerTask?.cancel()
    }

    /// Number of queue timers started since this manager was created.
    var queueTimerStartCount: Int { queueTimerStartCountValue }

    /// Whether a queue timer is currently armed.
    var hasPendingQueueTimer: Bool { queueTimerDeadline != nil }

    /// The generation the currently-armed timer was issued under. Test-visible
    /// so the stale-re-arm guard (`claimQueueTimer`) can be exercised directly
    /// rather than through a microsecond-wide timing race.
    var currentQueueTimerGeneration: UInt64 { queueTimerGeneration }

    // MARK: - Upload

    /// Upload a blob immediately.
    ///
    /// `nonisolated`: it touches no isolated state (the transport and the emit
    /// closure are both immutable), so the network transfer runs off the actor
    /// and concurrent uploads stay concurrent.
    public nonisolated func uploadImmediate(
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

        guard let transport = transport else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let (responseData, status) = try await transport.requestData(
            method: .put,
            path: path,
            body: data,
            options: RequestOptions(customHeaders: headers)
        )

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
        emit?(BlobUploadCompletedEvent(
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

    /// Upload from source data with queuing.
    ///
    /// `nonisolated`: the transfer and the emits run off the actor; only the
    /// three state steps (cache the bytes, evict them, enqueue the retry
    /// record) hop onto it. Each post-`await` step re-derives from the actor's
    /// current state rather than assuming the pre-`await` one — an actor
    /// releases isolation at every suspension point.
    public nonisolated func uploadFromSource(
        documentId: String,
        source: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> BlobUploadResult {
        let blobId = ULID.generate()
        let sha256 = options.sha256Base64 ?? hashSHA256Base64(source)

        // Store in memory cache under the disposition-qualified key (defaulting
        // to inline) so a subsequent `read` — which looks up the inline variant
        // by default — finds the just-uploaded bytes.
        await cacheBlob(source, forKey: Self.cacheKey(documentId, blobId, options.disposition ?? .inline))

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
                await evict(documentId: documentId, blobId: blobId)
            }
            return result
        } catch {
            let task = UploadTask(
                blobId: blobId,
                documentId: documentId,
                data: source,
                options: options,
                sha256: sha256,
                attempts: 1,
                lastError: error.localizedDescription
            )

            // JS gates the requeue on `shouldQueueError`
            // (`src/client/internal/blobManager.ts:1188-1192`): a permanent
            // rejection is never queued at all. The record and the retained
            // bytes are dropped, a single terminal `willRetry: false` is
            // emitted, and the error propagates to the caller.
            guard Self.shouldQueueError(error) else {
                await evict(documentId: task.documentId, blobId: task.blobId)
                emitTerminalUploadFailure(task)
                throw error
            }

            // Queue for retry
            await enqueue(task)

            // Mirror JS `emitUploadFailed`: carry the full queue record. The
            // task was just queued (attempt 1), so it will be retried — hence
            // `willRetry: true`. `lastError` is optional in the payload (JS
            // parity) but always present here.
            emit?(BlobUploadFailedEvent(
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

            await scheduleQueueProcessing()
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
    ///
    /// `nonisolated`, and therefore **synchronous permanently** — it reads only
    /// the immutable `getApiUrl` / `getAppId` closures. This is deliberate: it
    /// is the blob member most likely to be called from a SwiftUI `body` (it
    /// feeds an `AsyncImage` URL), so it carries no deprecation and no `Async`
    /// twin.
    public nonisolated func downloadUrl(
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

    /// Read a blob's content.
    ///
    /// - Parameter disposition: serve the download `inline` (the default when
    ///   omitted) or as an `attachment`. Mirrors JS `BlobReadOptions.disposition`:
    ///   the disposition is folded into the cache key so an `inline` and an
    ///   `attachment` read of the same blob don't collide, and is forwarded to
    ///   the download URL.
    ///
    /// `nonisolated`: only the two cache steps hop onto the actor, so a
    /// download never occupies it and concurrent reads stay concurrent.
    public nonisolated func read(documentId: String, blobId: String, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> Data {
        // Effective disposition for both the cache key and the request — JS
        // defaults `read` to the inline variant when none is supplied.
        let effectiveDisposition = disposition ?? .inline
        // Check memory cache first. The disposition is part of the key so an
        // inline read and an attachment read of the same blob cache separately,
        // mirroring js-bao's `::disp=` cache-key suffix in `blobManager.ts`.
        let cacheKey = Self.cacheKey(documentId, blobId, effectiveDisposition)
        if !force {
            if let cached = await cachedBlob(forKey: cacheKey) {
                return cached
            }
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

        let (data, response) = try await NetworkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw HttpError(status: status, message: "Blob download failed")
        }

        // Cache in memory
        await cacheBlob(data, forKey: cacheKey)

        return data
    }

    /// Prefetch multiple blobs.
    public nonisolated func prefetch(documentId: String, blobIds: [String], concurrency: Int = 2) async {
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for blobId in blobIds {
                if active >= concurrency {
                    await group.next()
                    active -= 1
                }
                group.addTask {
                    _ = try? await self.read(documentId: documentId, blobId: blobId)
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
    ///
    /// `nonisolated` so the two emits run off the actor; the mutation itself is
    /// the isolated `markUploadPaused`.
    public nonisolated func pauseUpload(_ blobId: String, documentId: String? = nil) async -> Bool {
        guard let task = await markUploadPaused(blobId, documentId: documentId) else { return false }
        // Mirror JS `pauseUpload`: paused event + progress frame (#996).
        emitUploadPaused(task)
        emitUploadProgress(task, status: "paused")
        // The pending timer may have been armed for this task; re-arm it for
        // whatever is still runnable (or clear it when nothing is).
        await rearmQueueTimer()
        return true
    }

    private func markUploadPaused(_ blobId: String, documentId: String?) -> UploadTask? {
        guard var task = uploadQueue[blobId] else { return nil }
        if let documentId = documentId, task.documentId != documentId { return nil }
        if task.paused { return nil }
        task.paused = true
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        return task
    }

    /// Resume a paused upload by blob ID, optionally scoped to `documentId`.
    public nonisolated func resumeUpload(_ blobId: String, documentId: String? = nil) async -> Bool {
        guard let task = await markUploadResumed(blobId, documentId: documentId) else { return false }
        // Mirror JS `resumeUpload`: resumed event + progress frame with the
        // queued-for-retry ("pending") state (#996).
        emitUploadResumed(task)
        emitUploadProgress(task, status: "pending")
        await scheduleQueueProcessing()
        return true
    }

    private func markUploadResumed(_ blobId: String, documentId: String?) -> UploadTask? {
        guard var task = uploadQueue[blobId] else { return nil }
        if let documentId = documentId, task.documentId != documentId { return nil }
        guard task.paused else { return nil }
        task.paused = false
        task.nextAttemptAt = Date().timeIntervalSince1970
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        return task
    }

    /// Pause every queued upload, optionally scoped to a single document.
    public nonisolated func pauseAll(documentId: String? = nil) async {
        let pausedTasks = await markAllPaused(documentId: documentId)
        for task in pausedTasks {
            emitUploadPaused(task)
            emitUploadProgress(task, status: "paused")
        }
        if !pausedTasks.isEmpty {
            await rearmQueueTimer()
        }
    }

    private func markAllPaused(documentId: String?) -> [UploadTask] {
        var paused: [UploadTask] = []
        for (blobId, var task) in uploadQueue {
            if let documentId = documentId, task.documentId != documentId { continue }
            if task.paused { continue }
            task.paused = true
            task.updatedAt = Date().timeIntervalSince1970
            uploadQueue[blobId] = task
            paused.append(task)
        }
        return paused
    }

    /// Resume every paused upload, optionally scoped to a single document.
    public nonisolated func resumeAll(documentId: String? = nil) async {
        let resumedTasks = await markAllResumed(documentId: documentId)
        for task in resumedTasks {
            emitUploadResumed(task)
            emitUploadProgress(task, status: "pending")
        }
        if !resumedTasks.isEmpty {
            await scheduleQueueProcessing()
        }
    }

    private func markAllResumed(documentId: String?) -> [UploadTask] {
        var resumed: [UploadTask] = []
        for (blobId, var task) in uploadQueue {
            if let documentId = documentId, task.documentId != documentId { continue }
            if task.paused {
                task.paused = false
                task.nextAttemptAt = Date().timeIntervalSince1970
                task.updatedAt = Date().timeIntervalSince1970
                uploadQueue[blobId] = task
                resumed.append(task)
            }
        }
        return resumed
    }

    /// Remove a queued upload (if any) for a blob and evict its cached bytes.
    /// Mirrors the queue-cleanup half of JS `delete`: a delete issued
    /// mid-upload cancels the in-flight transfer and emits `queue-drained`
    /// once the queue empties.
    nonisolated func cancelQueuedUpload(documentId: String, blobId: String) async {
        let outcome = await removeQueuedUpload(documentId: documentId, blobId: blobId)
        if outcome.removed {
            // The cancelled task may have been the one the timer was armed for.
            await rearmQueueTimer()
        }
        if outcome.removed && outcome.queueEmpty {
            emit?(BlobsQueueDrainedEvent())
        }
    }

    /// Drop the queue record and the retained bytes in one isolated step. Under
    /// the lock these were two separate holds with a window between them.
    private func removeQueuedUpload(
        documentId: String,
        blobId: String
    ) -> (removed: Bool, queueEmpty: Bool) {
        let removed = uploadQueue.removeValue(forKey: blobId) != nil
        let queueEmpty = uploadQueue.isEmpty
        evict(documentId: documentId, blobId: blobId)
        return (removed, queueEmpty)
    }

    public func setUploadConcurrency(_ value: Int) {
        uploadConcurrency = max(1, value)
    }

    public func getUploadConcurrency() -> Int {
        uploadConcurrency
    }

    /// Snapshot of tracked uploads, newest-updated first. When `documentId` is
    /// supplied only that document's uploads are returned (mirrors JS
    /// `getUploads(documentId?)`, which the per-document context scopes).
    public func listUploads(documentId: String? = nil) -> [BlobUploadStatus] {
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
                    status: task.paused ? "paused" : (task.uploading ? "uploading" : "pending"),
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

    /// Drop every locally-retained blob. Async-only — there is no synchronous
    /// form and no twin (#2172): the facade path (`JsBaoClient.evictAllLocal`)
    /// was already `async`, and a direct holder of the manager is taking the
    /// all-members-async break anyway.
    public func clearCache() {
        memoryBlobs.removeAll()
    }

    /// Evict a single blob from the local memory cache (no server call).
    /// Mirrors JS `deleteBlobBytes`, so a deleted blob isn't served stale
    /// from cache on a later `read`.
    func evict(documentId: String, blobId: String) {
        // Drop every disposition variant cached for this blob (the key is
        // disposition-qualified), plus any legacy un-qualified entry, so a
        // deleted blob can't be served stale under any disposition.
        let prefix = "\(documentId)::\(blobId)"
        for key in memoryBlobs.keys where key == prefix || key.hasPrefix("\(prefix)::") {
            memoryBlobs.removeValue(forKey: key)
        }
    }

    // MARK: - Private

    /// The isolated half of the memory cache, so `read` / `uploadFromSource`
    /// can stay `nonisolated` and keep their network work off the actor.
    private func cachedBlob(forKey key: String) -> Data? {
        memoryBlobs[key]
    }

    private func cacheBlob(_ data: Data, forKey key: String) {
        memoryBlobs[key] = data
    }

    private func enqueue(_ task: UploadTask) {
        uploadQueue[task.blobId] = task
    }

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

    /// Arm the single shared queue timer to run `processQueue()` in `delayMs`.
    ///
    /// Mirrors JS `scheduleQueueProcessing` (`src/client/internal/blobManager.ts`):
    /// at most one timer is pending at a time, and an already-armed timer that
    /// fires no later than the requested deadline is kept rather than replaced.
    /// The previous implementation spawned a fresh detached `Task` per failure,
    /// so a repeatedly failing upload accumulated concurrent retry passes —
    /// each of which re-selected the same task and bumped its `attempts` (#2056).
    ///
    /// **The whole method is one isolated, `await`-free decision region.** Under
    /// the lock this took two or three separate holds — `nextQueueDelayMs()`
    /// took one, the coalescing check took another, and storing the timer handle
    /// took a third — with a window for another pass to interleave in each gap.
    /// Atomicity strictly increases here. The post-hoc "store the handle only if
    /// this generation is still current" step the third hold needed is gone with
    /// it: the task is created and assigned inside this region, and its body
    /// cannot re-enter the actor before the region returns (its first act is a
    /// suspension). An `await` anywhere in here would reopen the #2056
    /// double-arming class, which is why the structural test slices it.
    func scheduleQueueProcessing(delayMs: Int = 0) {
        let delay = max(0, delayMs)
        let deadline = Date().timeIntervalSince1970 + Double(delay) / 1000.0

        // Nothing runnable: drop any pending timer, like JS's
        // `clearQueueTimer()` on an empty / fully paused queue.
        let hasRunnable = uploadQueue.values.contains { !$0.paused && !$0.uploading }
        guard hasRunnable else {
            clearQueueTimer()
            return
        }
        // Coalesce: an existing timer that already fires by this deadline
        // covers this request. The small tolerance keeps a burst of
        // concurrent requests for the "same" deadline — each of which reads
        // its own `now` — from replacing each other's timer in turn.
        if let existing = queueTimerDeadline, existing <= deadline + Self.queueTimerCoalesceSlack {
            return
        }
        clearQueueTimer()
        queueTimerGeneration &+= 1
        queueTimerDeadline = deadline
        queueTimerStartCountValue += 1
        queueTimerTask = makeQueueTimer(delayMs: delay, generation: queueTimerGeneration)
    }

    /// The queue timer's body lives here, in a **`nonisolated`** factory, and
    /// not inline in `scheduleQueueProcessing()`. Two reasons, both load-bearing:
    ///
    /// * A `Task {}` created inside an isolated context **inherits the actor's
    ///   isolation**, so an inline timer would sleep and re-enter as an isolated
    ///   task and the claim reasoning below would silently change. (Phase D2's
    ///   `testIsolatedCompletionStepsDoNotEmit` records the same lesson for
    ///   `KvCache.makeFetchTask`.)
    /// * It keeps the word `await` out of the decision region above, which the
    ///   structural test slices on code anchors.
    ///
    /// `[weak self]` so a pending timer never keeps the manager alive — the
    /// property `deinit`'s safety argument depends on.
    private nonisolated func makeQueueTimer(delayMs: Int, generation: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            guard !Task.isCancelled, let self = self else { return }
            guard await self.claimQueueTimer(generation: generation) else { return }
            await self.processQueue()
        }
    }

    /// The generation check, as one isolated step.
    ///
    /// Actor isolation does **not** subsume the generation counter. The timer
    /// body sleeps *outside* isolation and re-enters here afterwards, so between
    /// its wake and this call another `scheduleQueueProcessing` can have
    /// superseded it — exactly the stale re-arm the counter exists to reject.
    /// A superseded generation declines to run and says so at debug level,
    /// which makes the failure mode this conversion is most likely to introduce
    /// greppable.
    ///
    /// Internal rather than private so the guard has a direct test — see
    /// `ActorizedBlobManagerTests.testASupersededGenerationDeclinesToRunTheQueue`.
    func claimQueueTimer(generation: UInt64) -> Bool {
        guard queueTimerGeneration == generation else {
            logger.debug(
                "Queue timer generation superseded; declining to process the queue",
                "generation=\(generation) current=\(queueTimerGeneration)"
            )
            return false
        }
        queueTimerTask = nil
        queueTimerDeadline = nil
        return true
    }

    /// Cancel any pending queue timer. Isolated (it was `…Locked` before).
    private func clearQueueTimer() {
        queueTimerGeneration &+= 1
        queueTimerTask?.cancel()
        queueTimerTask = nil
        queueTimerDeadline = nil
    }

    /// Milliseconds until the earliest runnable (unpaused, not in-flight)
    /// queued task is due, or `nil` when nothing is runnable. Mirrors JS
    /// `computeNextDelay`.
    private func nextQueueDelayMs() -> Int? {
        let now = Date().timeIntervalSince1970
        var minWait: Double?
        for task in uploadQueue.values where !task.paused && !task.uploading {
            let wait = max(0, task.nextAttemptAt - now)
            if minWait == nil || wait < minWait! { minWait = wait }
        }
        guard let minWait = minWait else { return nil }
        // Cap in the Double domain before converting (see `computeBackoff`).
        return Int(min(minWait * 1000.0, Double(backoffMax)).rounded(.up))
    }

    /// Re-arm the shared timer for whatever is due next, or clear it when the
    /// queue has nothing runnable left. Mirrors the `finally` block of JS
    /// `processUploadQueue`. Isolated and `await`-free, so the "what is due"
    /// read and the arming decision can no longer be split by another pass.
    private func rearmQueueTimer() {
        if let delay = nextQueueDelayMs() {
            scheduleQueueProcessing(delayMs: delay)
        } else {
            clearQueueTimer()
        }
    }

    /// `nonisolated` so the child uploads run off the actor — the conversion
    /// must not turn concurrent transfers into serialized ones.
    nonisolated func processQueue() async {
        let selection = await selectDueTasks()

        guard !selection.selected.isEmpty else {
            // Every slot is busy: the in-flight uploads re-arm the timer when
            // they finish. Re-arming here would ask for a zero delay (the due
            // task is runnable, just unschedulable) and spin.
            guard !selection.saturated else { return }
            // Nothing due yet — make sure the shared timer is armed for the
            // earliest deadline instead of dropping the queue on the floor.
            await rearmQueueTimer()
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for task in selection.selected {
                group.addTask { [weak self] in
                    await self?.runUploadTask(task)
                }
            }
            await group.waitForAll()
        }
    }

    /// Select tasks and mark them in-flight in **one isolated, `await`-free
    /// region**, so concurrent passes can never select the same task twice.
    /// `now` is read inside the region too — reading it outside left a window
    /// where two passes filtered against different clocks (#2056). This is the
    /// #2056 guard itself; an `await` in here reopens the double-selection class.
    private func selectDueTasks() -> (selected: [UploadTask], saturated: Bool) {
        var available = uploadConcurrency - activeUploads
        guard available > 0 else { return ([], true) }

        let candidates = uploadQueue.values
            .filter { !$0.paused && !$0.uploading }
            .sorted(by: { $0.nextAttemptAt < $1.nextAttemptAt })

        let now = Date().timeIntervalSince1970
        var selected: [UploadTask] = []
        for var task in candidates {
            if available <= 0 { break }
            guard task.nextAttemptAt <= now else { continue }
            task.uploading = true
            task.updatedAt = now
            uploadQueue[task.blobId] = task
            activeUploads += 1
            available -= 1
            selected.append(task)
        }
        return (selected, available <= 0)
    }

    /// Run one attempt for a queued task, then re-arm the shared timer.
    /// Mirrors JS `runUploadTask` plus the `finally` that reschedules.
    ///
    /// `nonisolated`: the transfer and all four emits stay off the actor, and
    /// the bookkeeping hops onto it as one isolated step each.
    private nonisolated func runUploadTask(_ task: UploadTask) async {
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

            if await completeUploadTask(blobId: task.blobId) {
                emit?(BlobsQueueDrainedEvent())
            }
        } catch {
            // JS `runUploadTask` classifies the error before deciding what to
            // do with the task (`shouldQueueError`,
            // `src/client/internal/blobManager.ts:1188-1192`). A permanent
            // rejection (a 4xx other than 408/409/429) is terminal: retrying
            // it re-sends the same bytes to the same rejection forever.
            let queueable = Self.shouldQueueError(error)
            let outcome = await recordUploadFailure(task, error: error, queueable: queueable)

            if let failedTask = outcome.failedTask, !queueable {
                // JS `handleUploadFailure` (non-queueable): the queue record and
                // the locally-retained bytes are already gone (both dropped in
                // the isolated step above); emit a single terminal
                // `willRetry: false` and let the queue drain. No progress frame
                // — the task no longer exists.
                emitTerminalUploadFailure(failedTask)
                if outcome.queueEmpty {
                    emit?(BlobsQueueDrainedEvent())
                }
            } else if let failedTask = outcome.failedTask {
                // Mirror JS `emitUploadFailed`: emit on every failed attempt
                // (not just the first), carrying the updated queue record so
                // subscribers see the incremented `attempts`, the backoff
                // `nextAttemptAt`, and the latest `lastError`. The task stays
                // queued, so `willRetry: true` — a *queueable* failure (5xx,
                // 408/409/429, network) retries indefinitely at the
                // `backoffMax` cap, matching JS.
                emit?(BlobUploadFailedEvent(
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
                emitUploadProgress(failedTask, status: failedTask.paused ? "paused" : "pending")
            }
        }

        await rearmQueueTimer()
    }

    /// Success bookkeeping. Removing the task clears its in-flight marker with
    /// it. Returns whether the queue is now empty.
    private func completeUploadTask(blobId: String) -> Bool {
        uploadQueue.removeValue(forKey: blobId)
        activeUploads = max(0, activeUploads - 1)
        return uploadQueue.isEmpty
    }

    /// Failure bookkeeping, as **one isolated, `await`-free region**. It
    /// deliberately re-reads `uploadQueue[task.blobId]` rather than trusting the
    /// copy taken before the upload `await`: a task cancelled (or drained)
    /// mid-flight is simply gone, and there is nothing to unmark. That was
    /// already true under the lock and must not be "simplified" away here —
    /// an actor releases isolation at every suspension point, so the pre-await
    /// copy is even less trustworthy than it was.
    private func recordUploadFailure(
        _ task: UploadTask,
        error: Error,
        queueable: Bool
    ) -> (failedTask: UploadTask?, queueEmpty: Bool) {
        activeUploads = max(0, activeUploads - 1)
        guard var updatedTask = uploadQueue[task.blobId] else {
            return (nil, uploadQueue.isEmpty)
        }
        updatedTask.attempts += 1
        updatedTask.lastError = error.localizedDescription
        let now = Date().timeIntervalSince1970
        updatedTask.updatedAt = now

        guard queueable else {
            // Terminal: drop the queue record entirely and release the retained
            // bytes, mirroring JS `handleUploadFailure`'s non-queueable branch.
            // The matching terminal event is emitted by the nonisolated caller.
            uploadQueue.removeValue(forKey: task.blobId)
            evict(documentId: updatedTask.documentId, blobId: updatedTask.blobId)
            return (updatedTask, uploadQueue.isEmpty)
        }

        // Clear the in-flight marker on the failure path so the task
        // becomes eligible again once its backoff elapses.
        updatedTask.uploading = false
        let delay = computeBackoff(attempts: updatedTask.attempts)
        updatedTask.nextAttemptAt = now + Double(delay) / 1000.0
        uploadQueue[task.blobId] = updatedTask
        return (updatedTask, false)
    }

    /// Emit `blobs:upload-progress` with the full queue record, mirroring
    /// JS `emitUploadProgress` (`src/client/internal/blobManager.ts`).
    /// `status` ∈ `"queued" | "uploading" | "pending" | "paused"` (#996).
    ///
    /// `nonisolated`, like every emit helper here: the closure runs app code.
    private nonisolated func emitUploadProgress(_ task: UploadTask, status: String) {
        emit?(BlobUploadProgressEvent(
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

    /// Terminal failure path, emit half: one `blobs:upload-failed` with
    /// `willRetry: false`. Mirrors the non-queueable branch of JS
    /// `handleUploadFailure` (`src/client/internal/blobManager.ts:1348-1355`),
    /// which deletes the upload record, calls `deleteBlobBytes`, and emits the
    /// terminal event.
    ///
    /// The state half — dropping the queue record and releasing the
    /// locally-retained bytes — is the caller's, and it happens in an isolated
    /// step. The two used to be one method; they are split (#2172) because the
    /// state work belongs on the actor and the emit must not run there.
    private nonisolated func emitTerminalUploadFailure(_ task: UploadTask) {
        emit?(BlobUploadFailedEvent(
            documentId: task.documentId,
            blobId: task.blobId,
            queueId: task.queueId,
            filename: task.filename,
            contentType: task.contentType,
            numBytes: task.data.count,
            attempts: task.attempts,
            retainLocal: task.retainLocal,
            lastError: task.lastError,
            willRetry: false,
            nextAttemptAt: task.nextAttemptAt,
            updatedAt: task.updatedAt
        ))
    }

    private nonisolated func emitUploadPaused(_ task: UploadTask) {
        emit?(BlobUploadPausedEvent(
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

    private nonisolated func emitUploadResumed(_ task: UploadTask) {
        emit?(BlobUploadResumedEvent(
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

    nonisolated func computeBackoff(attempts: Int) -> Int {
        return Self.uploadBackoffMs(attempts: attempts, baseMs: backoffBase, maxMs: backoffMax)
    }

    /// Whether a failed upload attempt should be requeued for retry.
    ///
    /// Port of the JS client's `shouldQueueError`
    /// (`src/client/internal/blobManager.ts:1305-1318`):
    ///
    /// - `408` (request timeout), `409` (conflict) and `429` (rate limited)
    ///   are retryable even though they are 4xx.
    /// - Any `5xx` is retryable — the server may recover.
    /// - Every other `4xx` (400 validation, 401, 403, 404, 413, …) is
    ///   permanent: retrying re-sends the same bytes to the same rejection
    ///   forever, pinning them in memory and re-emitting a failure every
    ///   backoff interval.
    /// - Everything else — network failures (`URLError`), transport errors,
    ///   any error carrying no HTTP status — is retryable, matching JS's
    ///   `isNetworkError` branch and its `return true` fallthrough.
    ///
    /// A refresh-time transport failure takes that last branch: no HTTP
    /// response was received, so the error carries `status == 0` and never
    /// reaches the terminal `status >= 400` case. It used to arrive here as a
    /// synthetic `HttpError(status: 401)`, which is what dropped the upload
    /// (#2366); the fix is at the throw site in `HttpClient.fetchWithRefresh`,
    /// so no rule here needs to know how that failure is spelled.
    /// `BlobRefreshOutageTests` pins the behavior end to end.
    static func shouldQueueError(_ error: Error) -> Bool {
        if let httpError = error as? HttpError {
            let status = httpError.status
            if status == 408 || status == 409 || status == 429 { return true }
            if status >= 500 { return true }
            if status >= 400 { return false }
        }
        // Network / transport failures and anything without a status: retry.
        return true
    }

    /// Test-visible: whether any locally-retained bytes are still cached for
    /// this blob under any disposition. A terminal upload failure must release
    /// them (JS `handleUploadFailure` → `deleteBlobBytes`).
    func hasCachedBytes(documentId: String, blobId: String) -> Bool {
        let prefix = "\(documentId)::\(blobId)"
        return memoryBlobs.keys.contains { $0 == prefix || $0.hasPrefix("\(prefix)::") }
    }

    /// Pure exponential-backoff delay for a queued upload retry, split out so
    /// it can be unit tested independently of the manager's isolation and queue
    /// state.
    ///
    /// The cap is applied in the `Double` domain *before* converting to `Int`.
    /// Doing the `min` in `Int` (the old `min(Int(delay), maxMs)`) traps once
    /// `baseMs * 2^(attempts-1)` exceeds `Int.max` — from `attempts == 54` on
    /// with the production 2000ms base — and the trap aborts the whole process
    /// before the cap can clamp anything (#2056). In `Double`, an overflowing
    /// `pow` simply yields `.infinity`, which `min` discards in favour of the
    /// finite cap, so the final `Int(...)` is always in range. The explicit
    /// non-finite guard covers a NaN input as well.
    ///
    /// Mirrors the JS reference (`src/client/internal/blobManager.ts`
    /// `computeBackoff`), including its `max(0, attempts - 1)` exponent clamp.
    static func uploadBackoffMs(attempts: Int, baseMs: Int, maxMs: Int) -> Int {
        // `Double(attempts) - 1` rather than `attempts - 1`: the Int form
        // would itself overflow for `attempts == Int.min`.
        let exponent = max(0.0, Double(attempts) - 1.0)
        let delay = Double(baseMs) * pow(2.0, exponent)
        guard delay.isFinite else { return maxMs }
        return Int(min(delay, Double(maxMs)))
    }

    private nonisolated func hashSHA256Base64(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - Supporting Types

/// `Sendable` since #2172 — it crosses the manager's actor boundary on every
/// selection and bookkeeping step. Every field already was.
struct UploadTask: Sendable {
    let blobId: String
    let documentId: String
    let data: Data
    let options: BlobUploadSourceOptions
    let sha256: String
    var attempts: Int
    var lastError: String?
    var paused: Bool = false
    /// In-flight marker, mirroring the JS record's `status === "uploading"`.
    /// Set synchronously in the same isolated step that snapshots the queue
    /// when a `processQueue()` pass selects the task, and cleared on every exit
    /// path (success removes the task outright; failure clears it; a cancelled
    /// task is already gone). Without it, concurrent passes re-select the same
    /// task and each bumps `attempts` (#2056).
    var uploading: Bool = false
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
