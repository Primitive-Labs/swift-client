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
/// * **Everything else on the queue surface is `async`.** The public forms are
///   the `…Async` members on `JsBaoClient`, `DocumentsAPI` and
///   `DocumentBlobContext`. The synchronous forms that bridged the conversion
///   were removed in #2367; `DocumentsAPI` keeps a few as unavailable-renamed
///   stubs so the compiler points a migrating call at its twin (see the note
///   above its app-wide upload-queue verbs).
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

    /// The token in force and the user it names, read together: one token
    /// read, the user parsed from that token, so the pair always agrees. An
    /// upload belongs to the user signed in when it was queued and is
    /// attempted only with that user's token (`isRunnable(_:in:)`).
    nonisolated let currentIdentity: (@Sendable () -> UploadIdentity)?
    /// Whether the client may use the network now (its network mode and,
    /// in `.auto`, reachability). Session and db3 uploads wait for it, and a
    /// db3 read refuses a download without it; document uploads do not
    /// consult it.
    nonisolated let networkingAllowed: (@Sendable () -> Bool)?
    /// Where the queue is kept across launches: the client's own database,
    /// one record and one bytes row per upload in the stores of the app and
    /// the upload's user (`OfflineStore.blobUploadsStore`). `nil` keeps the
    /// queue in memory only, as a manager built for a unit test does.
    nonisolated let offlineStore: OfflineStore?

    // Upload queue — isolated state, exactly what the NSLock guarded.
    private var uploadQueue: [String: UploadTask] = [:]
    private var activeUploads = 0
    private var uploadConcurrency: Int

    /// Advanced on every change of signed-in user (`identityChanged()`). A
    /// session task carries the generation it was queued or re-adopted
    /// under, and anything that captured an older one acts on nothing.
    private var identityGeneration: UInt64 = 0
    /// The auth epoch (`UploadIdentity.epoch`) the queue last settled.
    private var settledEpoch: UInt64 = 0
    /// Who waits for which session upload, by blob id.
    private var uploadWaiters: [String: [UploadWaiter]] = [:]
    /// Session uploads completed in this process under the current identity,
    /// so `waitUntilUploaded` answers them at once.
    private var completedSessionUploads: [String: CompletedSessionUpload] = [:]

    // Persistence. A write is issued in the isolated step that changes the
    // task and applied, in issue order, by the write chain off the actor.
    /// Whether the storage provider is bound (`storageDidBecomeReady()`).
    /// Before it is, nothing is written; what is queued then is written
    /// when it binds.
    private var storageBound = false
    /// Set by `shutdown()`: nothing is selected, written or recorded after.
    private var isShutdown = false
    /// The last write issued; each write waits for the one before it.
    private var persistenceTail: Task<Void, Never>?
    /// Every upload this manager has queued or attempted. A restored row
    /// whose upload is one of them is not queued again: the task in memory
    /// is newer than any row.
    private var knownUploads: Set<String> = []
    /// Owned document uploads whose first PUT is in flight: not queued (not
    /// listed, not attempted), but written, so a process that ends during
    /// the PUT restores them.
    private var immediateUploads: [String: UploadTask] = [:]

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
        emit: (@Sendable (any JsBaoEventPayload) -> Void)? = nil,
        currentIdentity: (@Sendable () -> UploadIdentity)? = nil,
        networkingAllowed: (@Sendable () -> Bool)? = nil,
        offlineStore: OfflineStore? = nil
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
        self.currentIdentity = currentIdentity
        self.networkingAllowed = networkingAllowed
        self.offlineStore = offlineStore
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
    /// records. Queued uploads are dropped from memory with the manager; what
    /// the write chain already applied stays in storage (#4592).
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
        let contentType = options.contentType ?? "application/octet-stream"
        try await putDocumentBlob(documentId: documentId, blobId: blobId, data: data, options: options, token: nil)

        let result = BlobUploadResult(
            blobId: blobId,
            numBytes: data.count,
            contentType: contentType,
            bytesTransferred: data.count
        )

        emitImmediateCompleted(documentId: documentId, blobId: blobId, data: data, options: options, attempts: attempts)
        return result
    }

    /// Mirror JS `emitUploadComplete`: carry the full queue record. The
    /// immediate path isn't queued, so `queueId == blobId` (the JS invariant)
    /// and `attempts` reflects the attempt count passed in by the caller (1
    /// for a first immediate try).
    private nonisolated func emitImmediateCompleted(
        documentId: String, blobId: String, data: Data, options: BlobUploadSourceOptions, attempts: Int
    ) {
        emit?(BlobUploadCompletedEvent(
            documentId: documentId,
            blobId: blobId,
            queueId: blobId,
            filename: options.filename ?? blobId,
            contentType: options.contentType ?? "application/octet-stream",
            numBytes: data.count,
            attempts: attempts,
            retainLocal: options.retainLocal,
            updatedAt: Date().timeIntervalSince1970
        ))
    }

    /// One PUT to the document's blob route, emitting nothing. `token`, when
    /// given, is the attempt's own `Authorization`, as `putSessionAttachment`
    /// sends it: the transport applies a custom header over its default on
    /// the first dispatch and on its refresh-and-retry alike, so a queued
    /// attempt never takes on whoever is signed in when it leaves. `nil`
    /// sends the transport's current token.
    nonisolated func putDocumentBlob(
        documentId: String,
        blobId: String,
        data: Data,
        options: BlobUploadSourceOptions,
        token: String?,
        family: BlobRouteFamily = .documents
    ) async throws {
        var headers = Self.uploadHeaders(
            byteCount: data.count,
            filename: options.filename ?? blobId,
            contentType: options.contentType ?? "application/octet-stream",
            sha256: options.sha256Base64 ?? hashSHA256Base64(data),
            disposition: options.disposition
        )
        if let token { headers["Authorization"] = "Bearer \(token)" }

        guard let transport = transport else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let (responseData, status) = try await transport.requestData(
            method: .put,
            path: Self.blobPath(family, documentId: documentId, blobId: blobId),
            body: data,
            options: RequestOptions(customHeaders: headers)
        )

        guard status >= 200 && status < 300 else {
            // #3403 — the raw-bytes paths do not go through the JSON spine, so
            // the parse `HttpClient` applies to every other failure is applied
            // here too. The message is unchanged; only the server's own cause
            // is added, where before `serverCode` was always nil.
            throw HttpError.fromBytes(
                status: status,
                message: "Blob upload failed",
                body: responseData
            )
        }
    }

    /// Upload from source data with queuing.
    ///
    /// `nonisolated`: the transfer and the emits run off the actor; only the
    /// state steps (keep the bytes and bind the owner, settle the outcome)
    /// hop onto it. Each post-`await` step re-derives from the actor's
    /// current state rather than assuming the pre-`await` one — an actor
    /// releases isolation at every suspension point.
    ///
    /// With a user signed in and storage bound, the upload's record
    /// (`uploading`, no attempts yet) and bytes are written before the PUT
    /// leaves, so a process that ends during it restores the upload. The
    /// rows are deleted before this returns or throws a refusal, and read
    /// `pending` before it throws a queued failure. The write emits nothing.
    /// The PUT sends the token of the user it is bound to, taken with the
    /// binding; an outcome that answers while another user is signed in is
    /// not theirs: a landed upload's rows go with nothing emitted, a failed
    /// one stays queued for its user.
    public nonisolated func uploadFromSource(
        documentId: String,
        source: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> BlobUploadResult {
        try await uploadFromSource(documentId: documentId, source: source, options: options, family: .documents)
    }

    /// `uploadFromSource` over `family`'s routes. The db3 family follows the
    /// JS client's rules where the documents family does not: while the
    /// client may not use the network nothing is sent and the queued result
    /// (`bytesTransferred: 0`) is answered; an attempt refused for a
    /// retryable reason answers the queued result instead of throwing; a
    /// `NOT_A_DB3` refusal is terminal.
    nonisolated func uploadFromSource(
        documentId: String,
        source: Data,
        options: BlobUploadSourceOptions,
        family: BlobRouteFamily
    ) async throws -> BlobUploadResult {
        let blobId = ULID.generate()
        let sha256 = options.sha256Base64 ?? hashSHA256Base64(source)

        // Keep the bytes, take the upload's owner (the user signed in now,
        // whose upload it stays if it is queued) and write it.
        let begun = await beginDocumentUpload(UploadTask(
            blobId: blobId,
            documentId: documentId,
            data: source,
            options: options,
            sha256: sha256,
            attempts: 0,
            lastError: nil,
            destination: family == .db3 ? .db3(documentId) : .document
        ))
        await begun.write?.value

        let immediateOptions = BlobUploadSourceOptions(
            filename: options.filename,
            contentType: options.contentType,
            sha256Base64: sha256,
            disposition: options.disposition,
            retainLocal: options.retainLocal
        )
        let queuedResult = BlobUploadResult(
            blobId: blobId,
            numBytes: source.count,
            contentType: options.contentType ?? "application/octet-stream",
            bytesTransferred: 0
        )

        if family == .db3 {
            emitUploadProgress(begun.task, status: "queued")
            // JS `runUploadTask`: no attempt while the network is not allowed.
            guard networkingAllowed?() ?? true else {
                var task = begun.task
                task.nextAttemptAt = Date().timeIntervalSince1970
                let queued = await queueForRetry(task)
                if queued.live {
                    emitUploadProgress(task, status: "pending")
                    // The network may have come back while the task was being
                    // queued, after `networkingChanged()` found nothing to arm.
                    await scheduleQueueProcessing()
                }
                await queued.write?.value
                return queuedResult
            }
            emitUploadProgress(begun.task, status: "uploading")
        }

        // Try immediate upload
        do {
            try await putOwnedDocumentBlob(begun.task, options: immediateOptions, token: begun.token)
            let result = BlobUploadResult(
                blobId: blobId,
                numBytes: source.count,
                contentType: options.contentType ?? "application/octet-stream",
                bytesTransferred: source.count
            )
            // After `shutdown()` the outcome changes nothing: the row stays as
            // written and nothing is emitted. Under another user the rows go
            // and nothing is emitted.
            let finished = await finishImmediateUpload(begun.task)
            guard finished.live else {
                await finished.write?.value
                return result
            }
            emitImmediateCompleted(
                documentId: documentId, blobId: blobId, data: source, options: immediateOptions, attempts: 1
            )
            // retainLocal defaults to `true` (matching JS). When the caller
            // opts out, drop the bytes from the local cache after a successful
            // upload so a later `read` re-fetches from the server.
            if options.retainLocal == false {
                await evict(documentId: documentId, blobId: blobId, family: family)
            }
            await finished.write?.value
            return result
        } catch {
            var task = begun.task
            task.attempts = 1
            task.lastError = error.localizedDescription
            task.updatedAt = Date().timeIntervalSince1970

            // JS gates the requeue on `shouldQueueError`
            // (`src/client/internal/blobManager.ts:1188-1192`): a permanent
            // rejection is never queued at all. The record and the retained
            // bytes are dropped, a single terminal `willRetry: false` is
            // emitted, and the error propagates to the caller.
            guard Self.shouldQueueError(error, family: family) else {
                let dropped = await dropImmediateUpload(task)
                if dropped.live { emitTerminalUploadFailure(task) }
                await dropped.write?.value
                throw error
            }

            // Queue for retry
            let queued = await queueForRetry(task)
            guard queued.live else {
                await queued.write?.value
                throw error
            }

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
            await queued.write?.value
            // The db3 family answers the queued upload, as JS does; the
            // documents family keeps throwing the failure.
            if family == .db3 { return queuedResult }
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
        downloadUrl(
            family: .documents, documentId: documentId, blobId: blobId,
            disposition: disposition, attachmentFilename: attachmentFilename
        )
    }

    /// `downloadUrl` over `family`'s route: the db3 family's is
    /// `/app/<appId>/api/db3/<id>/blobs/<blobId>/download`, each id encoded.
    nonisolated func downloadUrl(
        family: BlobRouteFamily,
        documentId: String,
        blobId: String,
        disposition: BlobDisposition? = nil,
        attachmentFilename: String? = nil
    ) -> String {
        guard let apiUrl = getApiUrl?(), let appId = getAppId?() else { return "" }
        var url = "\(apiUrl)/app/\(appId)/api" + Self.blobPath(family, documentId: documentId, blobId: blobId) + "/download"
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
        try await read(family: .documents, documentId: documentId, blobId: blobId, force: force, disposition: disposition)
    }

    /// `read` over `family`'s route and local copies. The db3 family's copies
    /// are its own, and with no local copy it refuses to download while the
    /// client may not use the network (JS: "Blob cache unavailable while
    /// offline"), on the `readSessionAttachment` precedent.
    nonisolated func read(
        family: BlobRouteFamily, documentId: String, blobId: String, force: Bool = false, disposition: BlobDisposition? = nil
    ) async throws -> Data {
        // Effective disposition for both the cache key and the request — JS
        // defaults `read` to the inline variant when none is supplied.
        let effectiveDisposition = disposition ?? .inline
        // Check memory cache first. The disposition is part of the key so an
        // inline read and an attachment read of the same blob cache separately,
        // mirroring js-bao's `::disp=` cache-key suffix in `blobManager.ts`.
        let cacheKey = Self.cacheKey(family, documentId, blobId, effectiveDisposition)
        if !force {
            if let cached = await cachedBlob(forKey: cacheKey) {
                return cached
            }
        }
        if family == .db3, !(networkingAllowed?() ?? true) {
            throw JsBaoError(
                code: .offline, message: "Blob \(blobId) has no local copy and the client is offline",
                details: ["blobId": .string(blobId)]
            )
        }

        // Download from server
        let url = downloadUrl(family: family, documentId: documentId, blobId: blobId, disposition: effectiveDisposition)
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
            // #3403 — this one discarded the body outright, so a refusal the
            // server named reached the app as a bare status. The bytes of a
            // failed download ARE the error envelope.
            throw HttpError.fromBytes(
                status: status,
                message: "Blob download failed",
                body: data
            )
        }

        // Cache in memory
        await cacheBlob(data, forKey: cacheKey)

        return data
    }

    /// Prefetch multiple blobs.
    public nonisolated func prefetch(documentId: String, blobIds: [String], concurrency: Int = 2) async {
        await prefetch(family: .documents, documentId: documentId, blobIds: blobIds, concurrency: concurrency)
    }

    /// `prefetch` over `family`'s route and local copies. A blob that fails
    /// is skipped; the db3 family logs why.
    nonisolated func prefetch(family: BlobRouteFamily, documentId: String, blobIds: [String], concurrency: Int = 2) async {
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for blobId in blobIds {
                if active >= concurrency {
                    await group.next()
                    active -= 1
                }
                group.addTask {
                    do {
                        _ = try await self.read(family: family, documentId: documentId, blobId: blobId)
                    } catch where family == .db3 {
                        self.logger.debug("Prefetch skipped a blob", "documentId=\(documentId) blobId=\(blobId) error=\(error)")
                    } catch {}
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
        await pauseUpload(blobId, documentId: documentId, family: nil)
    }

    /// `pauseUpload` of `family`'s uploads only; `nil` matches either.
    nonisolated func pauseUpload(_ blobId: String, documentId: String?, family: BlobRouteFamily?) async -> Bool {
        guard let task = await markUploadPaused(blobId, documentId: documentId, family: family) else { return false }
        // Mirror JS `pauseUpload`: paused event + progress frame (#996).
        emitUploadPaused(task)
        emitUploadProgress(task, status: "paused")
        // The pending timer may have been armed for this task; re-arm it for
        // whatever is still runnable (or clear it when nothing is).
        await rearmQueueTimer()
        return true
    }

    private func markUploadPaused(_ blobId: String, documentId: String?, family: BlobRouteFamily?) -> UploadTask? {
        guard var task = uploadQueue[blobId], !task.isSession, isAvailable(task, to: runContext().identity) else {
            return nil
        }
        if let documentId = documentId, task.documentId != documentId { return nil }
        if let family, task.family != family { return nil }
        if task.paused { return nil }
        task.paused = true
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        persist(task)
        return task
    }

    /// Resume a paused upload by blob ID, optionally scoped to `documentId`.
    public nonisolated func resumeUpload(_ blobId: String, documentId: String? = nil) async -> Bool {
        await resumeUpload(blobId, documentId: documentId, family: nil)
    }

    /// `resumeUpload` of `family`'s uploads only; `nil` matches either.
    nonisolated func resumeUpload(_ blobId: String, documentId: String?, family: BlobRouteFamily?) async -> Bool {
        guard let task = await markUploadResumed(blobId, documentId: documentId, family: family) else { return false }
        // Mirror JS `resumeUpload`: resumed event + progress frame with the
        // queued-for-retry ("pending") state (#996).
        emitUploadResumed(task)
        emitUploadProgress(task, status: "pending")
        await scheduleQueueProcessing()
        return true
    }

    private func markUploadResumed(_ blobId: String, documentId: String?, family: BlobRouteFamily?) -> UploadTask? {
        guard var task = uploadQueue[blobId], !task.isSession, isAvailable(task, to: runContext().identity) else {
            return nil
        }
        if let documentId = documentId, task.documentId != documentId { return nil }
        if let family, task.family != family { return nil }
        guard task.paused else { return nil }
        task.paused = false
        task.nextAttemptAt = Date().timeIntervalSince1970
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        persist(task)
        return task
    }

    /// Pause every queued upload, optionally scoped to a single document.
    public nonisolated func pauseAll(documentId: String? = nil) async {
        await pauseAll(documentId: documentId, family: nil)
    }

    /// `pauseAll` of `family`'s uploads only; `nil` matches either.
    nonisolated func pauseAll(documentId: String?, family: BlobRouteFamily?) async {
        let pausedTasks = await markAllPaused(documentId: documentId, family: family)
        for task in pausedTasks {
            emitUploadPaused(task)
            emitUploadProgress(task, status: "paused")
        }
        if !pausedTasks.isEmpty {
            await rearmQueueTimer()
        }
    }

    private func markAllPaused(documentId: String?, family: BlobRouteFamily?) -> [UploadTask] {
        let identity = runContext().identity
        var paused: [UploadTask] = []
        for (blobId, var task) in uploadQueue where !task.isSession && isAvailable(task, to: identity) {
            if let documentId = documentId, task.documentId != documentId { continue }
            if let family, task.family != family { continue }
            if task.paused { continue }
            task.paused = true
            task.updatedAt = Date().timeIntervalSince1970
            uploadQueue[blobId] = task
            persist(task)
            paused.append(task)
        }
        return paused
    }

    /// Resume every paused upload, optionally scoped to a single document.
    public nonisolated func resumeAll(documentId: String? = nil) async {
        await resumeAll(documentId: documentId, family: nil)
    }

    /// `resumeAll` of `family`'s uploads only; `nil` matches either.
    nonisolated func resumeAll(documentId: String?, family: BlobRouteFamily?) async {
        let resumedTasks = await markAllResumed(documentId: documentId, family: family)
        for task in resumedTasks {
            emitUploadResumed(task)
            emitUploadProgress(task, status: "pending")
        }
        if !resumedTasks.isEmpty {
            await scheduleQueueProcessing()
        }
    }

    private func markAllResumed(documentId: String?, family: BlobRouteFamily?) -> [UploadTask] {
        let identity = runContext().identity
        var resumed: [UploadTask] = []
        for (blobId, var task) in uploadQueue where !task.isSession && isAvailable(task, to: identity) {
            if let documentId = documentId, task.documentId != documentId { continue }
            if let family, task.family != family { continue }
            if task.paused {
                task.paused = false
                task.nextAttemptAt = Date().timeIntervalSince1970
                task.updatedAt = Date().timeIntervalSince1970
                uploadQueue[blobId] = task
                persist(task)
                resumed.append(task)
            }
        }
        return resumed
    }

    /// Remove a queued upload (if any) for a blob and evict its cached bytes.
    /// Mirrors the queue-cleanup half of JS `delete`: a delete issued
    /// mid-upload cancels the in-flight transfer and emits `queue-drained`
    /// once the queue empties.
    nonisolated func cancelQueuedUpload(documentId: String, blobId: String, family: BlobRouteFamily = .documents) async {
        let outcome = await removeQueuedUpload(documentId: documentId, blobId: blobId, family: family)
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
        blobId: String,
        family: BlobRouteFamily
    ) -> (removed: Bool, queueEmpty: Bool) {
        // A session upload is the session's, cancelled only through
        // `view.attachments.cancel`: a document delete leaves it and its bytes.
        // So does a delete while another user than the upload's is signed in,
        // and a delete through the other route family.
        if let task = uploadQueue[blobId],
           task.isSession || !isAvailable(task, to: runContext().identity) || task.family != family {
            return (false, uploadQueue.isEmpty)
        }
        let removedTask = uploadQueue.removeValue(forKey: blobId)
        if let removedTask { unpersist(removedTask) }
        let removed = removedTask != nil
        let queueEmpty = uploadQueue.isEmpty
        evict(documentId: documentId, blobId: blobId, family: family)
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
    /// A session upload is never listed here, nor paused, resumed or
    /// cancelled by the document members: it is `view.attachments`'. Nor is
    /// an upload another user queued, until that user signs in again.
    public func listUploads(documentId: String? = nil) -> [BlobUploadStatus] {
        listUploads(documentId: documentId, family: nil)
    }

    /// `listUploads` of `family`'s uploads only; `nil` lists either.
    func listUploads(documentId: String?, family: BlobRouteFamily?) -> [BlobUploadStatus] {
        let identity = runContext().identity
        return uploadQueue.values
            .filter {
                !$0.isSession && isAvailable($0, to: identity) && (documentId == nil || $0.documentId == documentId)
                    && (family == nil || $0.family == family)
            }
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

    // MARK: - Agent session uploads

    /// The identity and network state one decision reads, once.
    private struct RunContext {
        let identity: UploadIdentity
        let networking: Bool
    }

    /// Read once per decision. A change of user the read reveals is settled
    /// here, before the caller acts on anything: the generation advances,
    /// transfers in flight are invalidated and waits end, so no step ever
    /// runs one user's identity against the previous user's generation.
    private func runContext() -> RunContext {
        let context = RunContext(
            identity: currentIdentity?() ?? UploadIdentity(token: nil, userId: nil),
            networking: networkingAllowed?() ?? true
        )
        if context.identity.epoch != settledEpoch {
            settledEpoch = context.identity.epoch
            Self.rejectIdentityWaits(advanceIdentity(for: context.identity))
        }
        return context
    }

    /// The one rule for what the queue may attempt now, read by
    /// `selectDueTasks`, `scheduleQueueProcessing` and `nextQueueDelayMs`
    /// alike, so the timer is armed only for work selection can take: not
    /// paused and not in flight; for a document task with a user, owned by the
    /// signed-in user under the current generation, and for a db3 task only
    /// while the client may use the network (JS); for a session task also
    /// not failed, owned, and only while the client may use the network.
    private func isRunnable(_ task: UploadTask, in context: RunContext) -> Bool {
        guard !task.paused, !task.uploading else { return false }
        guard task.isSession else {
            return isAvailable(task, to: context.identity) && (task.family != .db3 || context.networking)
        }
        return !task.failed && context.networking && isOwned(task, by: context.identity)
    }

    /// Whether a task belongs to the user signed in now. Every session task
    /// has a user; a document task has one when a user was signed in when
    /// it was queued.
    private func isOwned(_ task: UploadTask, by identity: UploadIdentity) -> Bool {
        task.generation == identityGeneration && task.userId != nil && task.userId == identity.userId
    }

    /// Whether the document members may list and act on a task now: it is
    /// the signed-in user's, or it was queued with nobody signed in.
    private func isAvailable(_ task: UploadTask, to identity: UploadIdentity) -> Bool {
        task.userId == nil || isOwned(task, by: identity)
    }

    /// The queued upload `blobId` when it is this session's and the signed-in
    /// user's.
    private func sessionTask(_ blobId: String, sessionId: String, identity: UploadIdentity) -> UploadTask? {
        guard let task = uploadQueue[blobId], task.sessionId == sessionId, isOwned(task, by: identity) else {
            return nil
        }
        return task
    }

    /// A session's attachments over this queue: uploads go to the session's
    /// attachment route and are listed, paused and resumed here, never in a
    /// document context; reads fall back to the session's download route.
    /// `documentId` is the binding's, for the local store and the events only.
    nonisolated func forAgentSession(
        sessionId: String, documentId: String, isClosed: @escaping @Sendable () -> Bool = { false }
    ) -> AgentSessionAttachments {
        AgentSessionAttachments(manager: self, sessionId: sessionId, documentId: documentId, isClosed: isClosed)
    }

    /// Store the bytes, queue the upload for the signed-in user and make one
    /// attempt at once while the client may use the network. Returns once it
    /// landed or is queued; throws a refusal. With no signed-in user nothing
    /// is queued: one attempt is made and its failure thrown.
    nonisolated func uploadSessionAttachment(
        sessionId: String, documentId: String, data: Data, options: AgentSessionAttachmentUploadOptions
    ) async throws -> AgentSessionAttachment {
        let task = UploadTask(
            blobId: ULID.generate(),
            documentId: documentId,
            data: data,
            options: BlobUploadSourceOptions(
                filename: options.filename ?? "blob-\(Int64(Date().timeIntervalSince1970 * 1000))",
                contentType: options.contentType ?? "application/octet-stream",
                disposition: options.disposition,
                retainLocal: true
            ),
            sha256: hashSHA256Base64(data),
            attempts: 0,
            lastError: nil,
            destination: .agentSession(sessionId)
        )
        switch await startSessionTask(task) {
        case .direct(let token):
            do {
                try await putSessionAttachment(task, token: token)
            } catch {
                await evict(documentId: documentId, blobId: task.blobId)
                throw error
            }
            await rememberCompleted(task)
            return task.attachment
        case .queued(let queued, let write):
            // Written before this returns, so the upload outlives the process.
            await write?.value
            emitUploadProgress(queued, status: "queued")
            return task.attachment
        case .attempt(let started, let token, let write):
            // Written before the first PUT leaves.
            await write?.value
            emitUploadProgress(started, status: "queued")
            switch await runSessionAttempt(started, token: token, countsSlot: false) {
            case .completed:
                return task.attachment
            case .failed(let error):
                throw error
            case .queued:
                break
            case .stale:
                // Invalidated meanwhile: a failure recorded since is this
                // call's answer; a pause, a cancel or a user change is not.
                if let failure = await sessionFailure(task.blobId) { throw failure }
            }
            await scheduleQueueProcessing()
            return task.attachment
        }
    }

    private enum SessionStart: Sendable {
        /// No signed-in user: one attempt with this token, nothing queued.
        case direct(token: String?)
        /// Queued without an attempt: the client may not use the network.
        /// `write` stores its record and bytes.
        case queued(UploadTask, write: Task<Void, Never>?)
        /// Queued and in flight with the signed-in user's token, once `write`
        /// has stored its record and bytes.
        case attempt(UploadTask, token: String?, write: Task<Void, Never>?)
    }

    /// Keep the bytes and queue the task, in one isolated step that also reads
    /// the identity the task belongs to and takes its first attempt's token,
    /// and issue the write of its record and bytes, which the caller awaits
    /// before it returns or sends anything.
    private func startSessionTask(_ task: UploadTask) -> SessionStart {
        var task = task
        cacheBlob(task.data, forKey: Self.cacheKey(task.documentId, task.blobId, task.options.disposition ?? .inline))
        let context = runContext()
        guard let userId = context.identity.userId else { return .direct(token: context.identity.token) }
        let now = Date().timeIntervalSince1970
        knownUploads.insert(task.blobId)
        task.userId = userId
        task.generation = identityGeneration
        task.nextAttemptAt = now
        task.updatedAt = now
        guard context.networking else {
            uploadQueue[task.blobId] = task
            return .queued(task, write: persist(task, withBytes: true))
        }
        task.uploading = true
        task.attempt &+= 1
        uploadQueue[task.blobId] = task
        return .attempt(task, token: context.identity.token, write: persist(task, withBytes: true))
    }

    private func rememberCompleted(_ task: UploadTask) {
        guard let sessionId = task.sessionId else { return }
        completedSessionUploads[task.blobId] = CompletedSessionUpload(sessionId: sessionId, attachment: task.attachment)
    }

    /// The failure of a session upload that failed, if it did.
    private func sessionFailure(_ blobId: String) -> (any Error)? {
        guard let task = uploadQueue[blobId], task.failed else { return nil }
        return task.failureError
    }

    /// One queued attempt of a session task, then the timer re-armed.
    private nonisolated func runSessionUploadTask(_ task: UploadTask, token: String?) async {
        _ = await runSessionAttempt(task, token: token, countsSlot: true)
        await rearmQueueTimer()
    }

    private enum SessionAttemptOutcome: Sendable {
        case completed
        case queued
        case failed(any Error)
        /// The attempt was invalidated (a pause, a cancel, a resume, a user
        /// change, the session observed gone): its outcome changed nothing.
        case stale
    }

    /// One attempt of a session task with `token`, the credentials taken when
    /// it was selected. The transfer runs as its own task so a pause, a
    /// cancel or a user change can cancel it; whatever it answers is recorded
    /// only while its attempt token is still the task's.
    private nonisolated func runSessionAttempt(
        _ task: UploadTask, token: String?, countsSlot: Bool
    ) async -> SessionAttemptOutcome {
        emitUploadProgress(task, status: "uploading")
        guard let transfer = await startTransfer(task, token: token, countsSlot: countsSlot) else {
            // Invalidated since it was selected: nothing was sent.
            return .stale
        }
        switch await transfer.result {
        case .success:
            guard let done = await completeSessionTask(task, countsSlot: countsSlot) else { return .stale }
            emit?(BlobUploadCompletedEvent(
                documentId: done.task.documentId,
                blobId: done.task.blobId,
                queueId: done.task.queueId,
                filename: done.task.filename,
                contentType: done.task.contentType,
                numBytes: done.task.data.count,
                attempts: done.task.attempts + 1,
                retainLocal: done.task.retainLocal,
                updatedAt: Date().timeIntervalSince1970
            ))
            for waiter in done.waiters { waiter.continuation.resume(returning: done.task.attachment) }
            if done.queueEmpty { emit?(BlobsQueueDrainedEvent()) }
            return .completed
        case .failure(let error):
            if Self.isSessionGone(error) {
                // The session route answered that the session is gone: every
                // queued upload of the session fails with this answer, this
                // one included.
                guard let failed = await settleGoneAttempt(task, error: error, countsSlot: countsSlot) else {
                    return .stale
                }
                deliverSessionGone(failed, error: error)
                return .failed(error)
            }
            // A 401 is the token's, not the upload's: retried while its user
            // is signed in (the next attempt takes that user's token then),
            // inert otherwise.
            let retryable = Self.shouldQueueError(error) || (error as? HttpError)?.status == 401
            guard let recorded = await recordSessionFailure(
                task, error: error, retryable: retryable, countsSlot: countsSlot
            ) else { return .stale }
            if retryable {
                emitSessionUploadFailed(recorded.task, willRetry: true)
                emitUploadProgress(recorded.task, status: "pending")
                return .queued
            }
            emitSessionUploadFailed(recorded.task, willRetry: false)
            for waiter in recorded.waiters { waiter.continuation.resume(throwing: error) }
            return .failed(error)
        }
    }

    /// Start the attempt's transfer and record its cancel handle, in one
    /// isolated step that first checks the attempt is still the task's: a
    /// pause, a cancel, a user change or the session observed gone either
    /// came first, and nothing starts, or comes after and finds the handle.
    /// An attempt that does not start gives back its slot.
    private func startTransfer(_ task: UploadTask, token: String?, countsSlot: Bool) -> Task<Void, any Error>? {
        _ = runContext()
        guard var current = uploadQueue[task.blobId], current.attempt == task.attempt, current.uploading else {
            if countsSlot { activeUploads = max(0, activeUploads - 1) }
            return nil
        }
        let transfer = makeTransfer(task, token: token)
        current.cancelTransfer = { transfer.cancel() }
        uploadQueue[task.blobId] = current
        return transfer
    }

    /// The transfer task, made off the actor (as `makeQueueTimer` is) so its
    /// body does not inherit the actor's isolation.
    private nonisolated func makeTransfer(_ task: UploadTask, token: String?) -> Task<Void, any Error> {
        Task { try await self.putSessionAttachment(task, token: token) }
    }

    /// Ends the attempt in flight, if any: its transfer is cancelled and its
    /// outcome will find a newer attempt token.
    private func invalidateAttempt(_ task: inout UploadTask) {
        task.attempt &+= 1
        task.cancelTransfer?()
        task.cancelTransfer = nil
        task.uploading = false
    }

    /// Success bookkeeping for a session attempt, unless it was invalidated.
    private func completeSessionTask(
        _ task: UploadTask, countsSlot: Bool
    ) -> (task: UploadTask, waiters: [UploadWaiter], queueEmpty: Bool)? {
        if countsSlot { activeUploads = max(0, activeUploads - 1) }
        guard !isShutdown else { return nil }
        _ = runContext()
        guard let current = uploadQueue[task.blobId], current.attempt == task.attempt else { return nil }
        uploadQueue.removeValue(forKey: task.blobId)
        unpersist(current)
        rememberCompleted(current)
        return (current, uploadWaiters.removeValue(forKey: task.blobId) ?? [], uploadQueue.isEmpty)
    }

    /// Failure bookkeeping for a session attempt, unless it was invalidated:
    /// a retryable failure is scheduled on the queue's backoff; a refusal
    /// makes the upload `failed`, keeping its record and bytes, and hands back
    /// its waiters.
    private func recordSessionFailure(
        _ task: UploadTask, error: any Error, retryable: Bool, countsSlot: Bool
    ) -> (task: UploadTask, waiters: [UploadWaiter])? {
        if countsSlot { activeUploads = max(0, activeUploads - 1) }
        guard !isShutdown else { return nil }
        _ = runContext()
        guard var current = uploadQueue[task.blobId], current.attempt == task.attempt else { return nil }
        let now = Date().timeIntervalSince1970
        current.uploading = false
        current.cancelTransfer = nil
        current.attempts += 1
        current.lastError = error.localizedDescription
        current.updatedAt = now
        if retryable {
            current.nextAttemptAt = now + Double(computeBackoff(attempts: current.attempts)) / 1000.0
            uploadQueue[task.blobId] = current
            persist(current)
            return (current, [])
        }
        current.failed = true
        current.failure = error
        current.lastErrorCode = (error as? HttpError)?.serverCode
        uploadQueue[task.blobId] = current
        persist(current)
        return (current, uploadWaiters.removeValue(forKey: task.blobId) ?? [])
    }

    /// One PUT to the session's attachment route with the document route's
    /// headers. `token` is the attempt's own `Authorization`: the transport
    /// applies a custom header over its default on the first dispatch and on
    /// its refresh-and-retry alike, so the request never takes on whoever is
    /// signed in when it leaves.
    private nonisolated func putSessionAttachment(_ task: UploadTask, token: String?) async throws {
        guard case .agentSession(let sessionId) = task.destination else {
            throw JsBaoError(code: .invalidArgument, message: "Upload \(task.blobId) is not a session upload")
        }
        guard let transport = transport else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        try Task.checkCancellation()
        var headers = Self.uploadHeaders(
            byteCount: task.data.count, filename: task.filename, contentType: task.contentType,
            sha256: task.sha256, disposition: task.options.disposition
        )
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let (body, status) = try await transport.requestData(
            method: .put,
            path: Self.sessionAttachmentPath(sessionId: sessionId, blobId: task.blobId),
            body: task.data,
            options: RequestOptions(customHeaders: headers)
        )
        guard (200..<300).contains(status) else {
            throw HttpError.fromBytes(status: status, message: "Attachment upload failed", body: body)
        }
    }

    /// The session's uploads that have not completed, for the signed-in user,
    /// most recently changed first.
    func listSessionUploads(sessionId: String) -> [AgentSessionUploadStatus] {
        let identity = runContext().identity
        return uploadQueue.values
            .filter { $0.sessionId == sessionId && isOwned($0, by: identity) }
            .map(\.sessionStatus)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pause a pending or uploading session upload, cancelling its transfer.
    nonisolated func pauseSessionUpload(blobId: String, sessionId: String) async -> Bool {
        guard let task = await markSessionPaused(blobId: blobId, sessionId: sessionId) else { return false }
        emitUploadPaused(task)
        emitUploadProgress(task, status: "paused")
        return true
    }

    private func markSessionPaused(blobId: String, sessionId: String) -> UploadTask? {
        guard var task = sessionTask(blobId, sessionId: sessionId, identity: runContext().identity),
              !task.failed, !task.paused
        else { return nil }
        if task.uploading { invalidateAttempt(&task) }
        task.paused = true
        task.updatedAt = Date().timeIntervalSince1970
        uploadQueue[blobId] = task
        persist(task)
        rearmQueueTimer()
        return task
    }

    /// Make a paused or failed session upload pending at once.
    nonisolated func resumeSessionUpload(blobId: String, sessionId: String) async -> Bool {
        guard let task = await markSessionResumed(blobId: blobId, sessionId: sessionId) else { return false }
        emitUploadResumed(task)
        emitUploadProgress(task, status: "pending")
        return true
    }

    private func markSessionResumed(blobId: String, sessionId: String) -> UploadTask? {
        guard var task = sessionTask(blobId, sessionId: sessionId, identity: runContext().identity),
              !task.uploading, task.paused || task.failed
        else { return nil }
        // Whatever an earlier attempt answers from now on changes nothing.
        task.attempt &+= 1
        task.paused = false
        task.failed = false
        task.failure = nil
        task.lastErrorCode = nil
        let now = Date().timeIntervalSince1970
        task.nextAttemptAt = now
        task.updatedAt = now
        uploadQueue[blobId] = task
        persist(task)
        scheduleQueueProcessing()
        return task
    }

    /// Drop a queued session upload with its local bytes; its transfer is
    /// cancelled and its waiters throw `.agentSessionUploadCancelled`.
    nonisolated func cancelSessionUpload(blobId: String, sessionId: String) async -> Bool {
        guard let dropped = await dropSessionTask(blobId: blobId, sessionId: sessionId) else { return false }
        let error = Self.uploadWaitError(.agentSessionUploadCancelled, blobId: blobId)
        for waiter in dropped.waiters { waiter.continuation.resume(throwing: error) }
        if dropped.queueEmpty { emit?(BlobsQueueDrainedEvent()) }
        return true
    }

    private func dropSessionTask(blobId: String, sessionId: String) -> (waiters: [UploadWaiter], queueEmpty: Bool)? {
        guard var task = sessionTask(blobId, sessionId: sessionId, identity: runContext().identity) else { return nil }
        invalidateAttempt(&task)
        uploadQueue.removeValue(forKey: blobId)
        unpersist(task)
        evict(documentId: task.documentId, blobId: blobId)
        rearmQueueTimer()
        return (uploadWaiters.removeValue(forKey: blobId) ?? [], uploadQueue.isEmpty)
    }

    /// Return once the session upload completes, or at once for one completed
    /// in this process. Throws its failure, `.agentSessionUploadCancelled`,
    /// `.agentSessionUploadIdentityChanged`, `.agentSessionUploadUnknown`,
    /// `.unavailable` once the client is destroyed, or `CancellationError`
    /// when the waiting task is cancelled (the upload is left as it was).
    func waitUntilSessionUploaded(blobId: String, sessionId: String) async throws -> AgentSessionAttachment {
        guard !isShutdown else { throw Self.uploadWaitError(.unavailable, blobId: blobId) }
        if let task = sessionTask(blobId, sessionId: sessionId, identity: runContext().identity) {
            if task.failed { throw task.failureError }
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    addWaiter(UploadWaiter(id: id, continuation: continuation), blobId: blobId)
                }
            } onCancel: {
                Task { await self.cancelWaiter(id, blobId: blobId) }
            }
        }
        if let done = completedSessionUploads[blobId], done.sessionId == sessionId { return done.attachment }
        throw Self.uploadWaitError(.agentSessionUploadUnknown, blobId: blobId)
    }

    private func addWaiter(_ waiter: UploadWaiter, blobId: String) {
        if Task.isCancelled {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        if isShutdown {
            waiter.continuation.resume(throwing: Self.uploadWaitError(.unavailable, blobId: blobId))
            return
        }
        uploadWaiters[blobId, default: []].append(waiter)
    }

    private func cancelWaiter(_ id: UUID, blobId: String) {
        guard var waiters = uploadWaiters[blobId], let at = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: at)
        uploadWaiters[blobId] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// A session's file: the local copy first (an upload this client made, or
    /// an earlier read), else the session's download route, kept locally. The
    /// session counterpart of `read(documentId:blobId:)`, which stays the
    /// document route's.
    nonisolated func readSessionAttachment(
        sessionId: String, documentId: String, blobId: String, force: Bool, disposition: BlobDisposition?
    ) async throws -> Data {
        let generation = await captureIdentity()
        let cacheKey = Self.cacheKey(documentId, blobId, disposition ?? .inline)
        if !force, let cached = await localSessionCopy(documentId, blobId, preferring: cacheKey) {
            return cached
        }
        guard networkingAllowed?() ?? true else {
            throw JsBaoError(
                code: .offline, message: "Attachment \(blobId) has no local copy and the client is offline",
                details: ["blobId": .string(blobId)]
            )
        }
        guard let apiUrl = getApiUrl?(), let appId = getAppId?() else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }
        var url = "\(apiUrl)/app/\(appId)/api" + Self.sessionAttachmentPath(sessionId: sessionId, blobId: blobId)
            + "/download"
        if let disposition { url += "?disposition=\(disposition.rawValue)" }
        guard let requestUrl = URL(string: url) else {
            throw JsBaoError(code: .invalidArgument, message: "Invalid attachment URL")
        }
        var request = URLRequest(url: requestUrl)
        if let token = getToken?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let adminAppId = getGlobalAdminAppId?() {
            request.setValue(adminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        }
        let (data, response) = try await NetworkSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = HttpError.fromBytes(status: status, message: "Attachment download failed", body: data)
            // The session is gone for the identity that asked: its uploads fail too.
            if Self.isSessionGone(error) {
                await failAgentSessionUploads(sessionId: sessionId, error: error, identity: generation)
            }
            throw error
        }
        await cacheBlob(data, forKey: cacheKey)
        return data
    }

    /// A session file's local copy, under the requested disposition first and
    /// else under any other: the bytes do not depend on it, and an upload
    /// keeps its bytes under the disposition it was made with.
    private func localSessionCopy(_ documentId: String, _ blobId: String, preferring key: String) -> Data? {
        if let exact = memoryBlobs[key] { return exact }
        let prefix = "\(documentId)::\(blobId)::disp="
        return memoryBlobs.first { $0.key.hasPrefix(prefix) }?.value
    }

    /// The identity generation now: a session call captures it before its
    /// request and passes it back with what it observed, so an observation
    /// made for one user never acts on the next one's queue.
    func captureIdentity() -> UInt64 {
        _ = runContext()
        return identityGeneration
    }

    /// The session is gone (deleted, or this user is no longer in it): every
    /// queued upload of `sessionId` becomes `failed` with `error`, keeping its
    /// record and bytes until it is resumed or cancelled; its waiters throw
    /// `error`; `blobs:upload-failed` fires once for each, `willRetry: false`.
    /// An attempt in flight is cancelled and its outcome ignored. Nothing
    /// happens when `identity` is not the current generation, or for an
    /// upload already failed.
    nonisolated func failAgentSessionUploads(sessionId: String, error: any Error, identity: UInt64) async {
        guard let failed = await markSessionGone(sessionId: sessionId, error: error, identity: identity) else { return }
        deliverSessionGone(failed, error: error)
    }

    private func markSessionGone(
        sessionId: String, error: any Error, identity: UInt64
    ) -> [(task: UploadTask, waiters: [UploadWaiter])]? {
        let owner = runContext().identity
        guard identity == identityGeneration else {
            logger.debug(
                "Dropped a session-gone observation made under another identity",
                "sessionId=\(sessionId) generation=\(identity) current=\(identityGeneration)"
            )
            return nil
        }
        let now = Date().timeIntervalSince1970
        var failed: [(task: UploadTask, waiters: [UploadWaiter])] = []
        for (blobId, var task) in uploadQueue
        where task.sessionId == sessionId && !task.failed && isOwned(task, by: owner) {
            invalidateAttempt(&task)
            task.paused = false
            task.failed = true
            task.failure = error
            task.lastError = error.localizedDescription
            task.lastErrorCode = (error as? HttpError)?.serverCode
            task.updatedAt = now
            uploadQueue[blobId] = task
            persist(task)
            failed.append((task, uploadWaiters.removeValue(forKey: blobId) ?? []))
        }
        guard !failed.isEmpty else { return nil }
        logger.debug("Failed the uploads of a session observed gone", "sessionId=\(sessionId) failed=\(failed.count)")
        rearmQueueTimer()
        return failed
    }

    /// The bookkeeping of an attempt the session route answered gone, unless
    /// it was invalidated: the session's uploads fail under the generation the
    /// attempt was selected in.
    private func settleGoneAttempt(
        _ task: UploadTask, error: any Error, countsSlot: Bool
    ) -> [(task: UploadTask, waiters: [UploadWaiter])]? {
        if countsSlot { activeUploads = max(0, activeUploads - 1) }
        guard !isShutdown else { return nil }
        _ = runContext()
        guard let current = uploadQueue[task.blobId], current.attempt == task.attempt,
              let sessionId = current.sessionId
        else { return nil }
        return markSessionGone(sessionId: sessionId, error: error, identity: current.generation) ?? []
    }

    private nonisolated func deliverSessionGone(
        _ failed: [(task: UploadTask, waiters: [UploadWaiter])], error: any Error
    ) {
        for (task, waiters) in failed {
            emitSessionUploadFailed(task, willRetry: false)
            for waiter in waiters { waiter.continuation.resume(throwing: error) }
        }
    }

    /// Whether `error` is a session route's answer that the session is gone
    /// for this user.
    static func isSessionGone(_ error: any Error) -> Bool {
        (error as? HttpError)?.serverCode == "AGENT_SESSION_NOT_FOUND"
    }

    /// The signed-in user changed: another user's token applied, a logout, or
    /// a sign-in after one. A new generation; every owned attempt in flight
    /// is invalidated (a session transfer is cancelled); every waiter throws
    /// `.agentSessionUploadIdentityChanged`; the completed-upload memory is
    /// cleared. The owned tasks of the user signed in now, session and
    /// document alike, are re-adopted under the new generation and listed and
    /// attempted again; the others stay inert until their user signs in
    /// again.
    nonisolated func identityChanged() async {
        Self.rejectIdentityWaits(await advanceIdentity())
    }

    /// Settle a change of user the client reported, if the queue has not
    /// already met it (`runContext()`). Nothing happens when it has.
    func syncIdentity() {
        _ = runContext()
    }

    private func advanceIdentity() -> [String: [UploadWaiter]] {
        advanceIdentity(for: runContext().identity)
    }

    private static func rejectIdentityWaits(_ rejected: [String: [UploadWaiter]]) {
        for (blobId, waiters) in rejected {
            let error = uploadWaitError(.agentSessionUploadIdentityChanged, blobId: blobId)
            for waiter in waiters { waiter.continuation.resume(throwing: error) }
        }
    }

    private func advanceIdentity(for identity: UploadIdentity) -> [String: [UploadWaiter]] {
        identityGeneration &+= 1
        var changed = false
        for (blobId, var task) in uploadQueue where task.userId != nil {
            if task.uploading {
                invalidateAttempt(&task)
                changed = true
            }
            if let userId = task.userId, userId == identity.userId {
                task.generation = identityGeneration
                changed = true
            }
            uploadQueue[blobId] = task
        }
        completedSessionUploads.removeAll()
        let waiting = uploadWaiters
        uploadWaiters.removeAll()
        if changed { rearmQueueTimer() }
        logger.debug("Identity changed; owned uploads re-read", "generation=\(identityGeneration)")
        // The rows the user signed in now left in storage, restored.
        startHydration(for: identity)
        return waiting
    }

    /// The client's networking may be allowed again: arm the timer for
    /// whatever is runnable now (the session and db3 uploads that waited).
    func networkingChanged() {
        let context = runContext()
        guard uploadQueue.values.contains(where: { isRunnable($0, in: context) }) else { return }
        rearmQueueTimer()
    }

    /// The headers both upload routes take.
    static func uploadHeaders(
        byteCount: Int, filename: String, contentType: String, sha256: String, disposition: BlobDisposition?
    ) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": contentType,
            "X-Blob-Filename": filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename,
            "X-Blob-Size": "\(byteCount)",
            "X-Blob-Sha256": sha256,
        ]
        if let disposition { headers["X-Blob-Disposition"] = disposition.rawValue }
        return headers
    }

    /// `/agent-sessions/{sessionId}/attachments/{blobId}`, each id encoded.
    static func sessionAttachmentPath(sessionId: String, blobId: String) -> String {
        "/agent-sessions/\(URLEncoding.encodeComponent(sessionId))/attachments/\(URLEncoding.encodeComponent(blobId))"
    }

    /// The error a wait throws when the upload itself did not fail.
    static func uploadWaitError(_ code: JsBaoErrorCode, blobId: String) -> JsBaoError {
        let message: String
        switch code {
        case .agentSessionUploadUnknown:
            message = "No upload \"\(blobId)\" is queued or completed on this client"
        case .agentSessionUploadCancelled:
            message = "The upload \"\(blobId)\" was cancelled"
        case .unavailable:
            message = "The client was destroyed while waiting for the upload \"\(blobId)\""
        default:
            message = "The signed-in user changed while waiting for the upload \"\(blobId)\""
        }
        return JsBaoError(code: code, message: message, details: ["blobId": .string(blobId)])
    }

    private nonisolated func emitSessionUploadFailed(_ task: UploadTask, willRetry: Bool) {
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
            willRetry: willRetry,
            nextAttemptAt: task.nextAttemptAt,
            updatedAt: task.updatedAt
        ))
    }

    // MARK: - Persistence

    /// Write `task`'s record, and its bytes when `withBytes`, unless it has
    /// no user (an unbound upload is never written). Issued in the caller's
    /// isolated step; applied by the write chain.
    @discardableResult
    private func persist(_ task: UploadTask, withBytes: Bool = false) -> Task<Void, Never>? {
        guard let userId = task.userId else { return nil }
        let record = task.persistedRecord
        let bytes = withBytes ? task.data : nil
        return schedulePersistence("put queueId=\(task.queueId) status=\(record.status)") { store, appId in
            try await store.putBlobUpload(appId: appId, userId: userId, record: record, bytes: bytes)
        }
    }

    /// Delete `task`'s record and bytes.
    @discardableResult
    private func unpersist(_ task: UploadTask) -> Task<Void, Never>? {
        guard let userId = task.userId else { return nil }
        let (queueId, documentId, blobId) = (task.queueId, task.documentId, task.blobId)
        return schedulePersistence("delete queueId=\(queueId)") { store, appId in
            try await store.deleteBlobUpload(
                appId: appId, userId: userId, queueId: queueId, documentId: documentId, blobId: blobId
            )
        }
    }

    /// Append one write to the chain. Nothing is written before storage is
    /// bound, nor after `shutdown()`.
    private func schedulePersistence(
        _ what: String, _ write: @escaping @Sendable (OfflineStore, String) async throws -> Void
    ) -> Task<Void, Never>? {
        guard let store = offlineStore, storageBound, let appId = getAppId?() else { return nil }
        guard !isShutdown else {
            logger.debug("Refused an upload write after shutdown", what)
            return nil
        }
        let next = makePersistenceWrite(after: persistenceTail, store: store, appId: appId, what: what, write)
        persistenceTail = next
        return next
    }

    /// One write of the chain, made off the actor (as `makeQueueTimer` is) so
    /// its body does not inherit the actor's isolation. It waits for the
    /// write before it, so writes apply in the order they were issued however
    /// the actor is re-entered. A write that fails is a warning: the upload
    /// goes on in memory.
    private nonisolated func makePersistenceWrite(
        after previous: Task<Void, Never>?, store: OfflineStore, appId: String, what: String,
        _ write: @escaping @Sendable (OfflineStore, String) async throws -> Void
    ) -> Task<Void, Never> {
        Task { [logger] in
            await previous?.value
            do {
                try await write(store, appId)
            } catch {
                logger.warn("An upload write failed; the upload goes on in memory", "\(what) error=\(error)")
            }
        }
    }

    /// Return once every write issued so far has applied.
    func awaitPendingPersistence() async {
        await persistenceTail?.value
    }

    // MARK: - Hydration

    /// Storage is bound: write what was queued before it was, then restore
    /// the signed-in user's uploads. Returns once they are in the queue.
    func storageDidBecomeReady() async {
        await beginStorage()?.value
    }

    private func beginStorage() -> Task<Void, Never>? {
        let identity = runContext().identity
        guard offlineStore != nil, !storageBound, !isShutdown else { return nil }
        storageBound = true
        for task in uploadQueue.values { persist(task, withBytes: true) }
        for task in immediateUploads.values {
            var inFlight = task
            inFlight.uploading = true
            persist(inFlight, withBytes: true)
        }
        return startHydration(for: identity)
    }

    /// Read `identity`'s rows after every write issued so far, and queue
    /// those this manager does not already hold. Restoring emits nothing:
    /// a restored upload's first event is its next attempt's.
    @discardableResult
    private func startHydration(for identity: UploadIdentity) -> Task<Void, Never>? {
        guard let store = offlineStore, storageBound, !isShutdown, let appId = getAppId?(),
              let userId = identity.userId
        else { return nil }
        return makeHydration(
            after: persistenceTail, store: store, appId: appId, userId: userId, generation: identityGeneration
        )
    }

    /// The read, off the actor. Bytes are read only for rows of uploads this
    /// manager does not hold. A row is missing its bytes only when the read
    /// answers none; a read that fails leaves the row as it is, for the
    /// next hydration.
    private nonisolated func makeHydration(
        after previous: Task<Void, Never>?, store: OfflineStore, appId: String, userId: String, generation: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self, logger] in
            await previous?.value
            let records: [PersistedUploadRecord]
            do {
                records = try await store.loadBlobUploads(appId: appId, userId: userId)
            } catch {
                logger.warn("Could not read the stored uploads", "error=\(error)")
                return
            }
            guard let self, !records.isEmpty else { return }
            let unknown = await self.unknownUploads(records)
            var restorable: [(record: PersistedUploadRecord, data: Data)] = []
            var missing: [PersistedUploadRecord] = []
            for record in unknown {
                let data: Data?
                do {
                    data = try await store.loadBlobUploadBytes(
                        appId: appId, userId: userId, documentId: record.documentId, blobId: record.blobId
                    )
                } catch {
                    logger.warn(
                        "Could not read a stored upload's bytes; it stays stored",
                        "queueId=\(record.queueId) error=\(error)"
                    )
                    continue
                }
                if let data {
                    restorable.append((record, data))
                } else {
                    missing.append(record)
                }
            }
            // The drops are part of the restore: storage reports ready only
            // once they are written.
            let drops = await self.adoptRestoredUploads(
                restorable, missing: missing, userId: userId, generation: generation
            )
            for drop in drops { await drop.value }
        }
    }

    private func unknownUploads(_ records: [PersistedUploadRecord]) -> [PersistedUploadRecord] {
        records.filter { !knownUploads.contains($0.blobId) && $0.status != "uploaded" }
    }

    /// Queue the restored uploads, unless the signed-in user changed while
    /// they were read: then they are not this user's, and their owner's next
    /// sign-in reads them again. A row whose bytes are gone is deleted;
    /// returns those deletes.
    private func adoptRestoredUploads(
        _ rows: [(record: PersistedUploadRecord, data: Data)], missing: [PersistedUploadRecord],
        userId: String, generation: UInt64
    ) -> [Task<Void, Never>] {
        guard !isShutdown, generation == identityGeneration else {
            logger.debug("Discarded the uploads read for a user no longer signed in", "rows=\(rows.count)")
            return []
        }
        var drops: [Task<Void, Never>] = []
        for record in missing where !knownUploads.contains(record.blobId) {
            logger.warn("Dropped a stored upload whose bytes are missing", "queueId=\(record.queueId)")
            if let drop = unpersist(UploadTask(restoring: record, data: Data(), userId: userId, generation: generation)) {
                drops.append(drop)
            }
        }
        var restored = 0
        for row in rows where !knownUploads.contains(row.record.blobId) {
            let task = UploadTask(restoring: row.record, data: row.data, userId: userId, generation: generation)
            knownUploads.insert(task.blobId)
            uploadQueue[task.blobId] = task
            cacheBlob(row.data, forKey: task.cacheKey)
            restored += 1
        }
        guard restored > 0 else { return drops }
        logger.debug("Restored stored uploads", "count=\(restored)")
        rearmQueueTimer()
        return drops
    }

    // MARK: - Shutdown

    /// The client is going away (`JsBaoClient.destroy()`): nothing is
    /// selected or written from now on, the queue timer is cancelled, and an
    /// attempt in flight changes neither the queue nor the store when it
    /// answers. Rows stay as written, so an upload in flight restores
    /// `pending` next launch. Writes issued before this still apply;
    /// `awaitPendingPersistence()` waits for them. Every wait for a session
    /// upload, and every later one, throws `.unavailable`: no outcome will
    /// end it.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        clearQueueTimer()
        let waiting = uploadWaiters
        uploadWaiters.removeAll()
        for (blobId, waiters) in waiting {
            let error = Self.uploadWaitError(.unavailable, blobId: blobId)
            for waiter in waiters { waiter.continuation.resume(throwing: error) }
        }
        logger.debug("Upload queue shut down", "queued=\(uploadQueue.count) waits=\(waiting.count)")
    }

    /// Test-visible: whether `blobId` is in the queue, whoever it belongs to.
    func hasQueuedUpload(_ blobId: String) -> Bool {
        uploadQueue[blobId] != nil
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
    func evict(documentId: String, blobId: String, family: BlobRouteFamily = .documents) {
        // Drop every disposition variant cached for this blob (the key is
        // disposition-qualified), plus any legacy un-qualified entry, so a
        // deleted blob can't be served stale under any disposition. Only
        // `family`'s copies go: the other family's are its own.
        let prefix = Self.cachePrefix(family, documentId, blobId)
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

    /// Keep a document upload's bytes and bind it to the user signed in now,
    /// in one isolated step, and write its record (`uploading`, no attempts)
    /// and bytes. `token` is that user's, from the same read: the first PUT
    /// sends it whoever is signed in by the time it leaves. With no user
    /// signed in it stays unbound, nothing is written and the PUT sends the
    /// transport's token.
    private func beginDocumentUpload(
        _ task: UploadTask
    ) -> (task: UploadTask, token: String?, write: Task<Void, Never>?) {
        var task = task
        cacheBlob(task.data, forKey: task.cacheKey)
        knownUploads.insert(task.blobId)
        let identity = runContext().identity
        guard let userId = identity.userId else { return (task, nil, nil) }
        task.userId = userId
        task.generation = identityGeneration
        immediateUploads[task.blobId] = task
        var inFlight = task
        inFlight.uploading = true
        return (task, identity.token, persist(inFlight, withBytes: true))
    }

    /// Whether the first PUT's outcome is its user's to see: the upload is
    /// unbound, or its user is signed in now.
    private func ownerSignedIn(_ task: UploadTask) -> Bool {
        task.userId == nil || task.userId == runContext().identity.userId
    }

    /// The first PUT landed: its rows go. `live` is false after `shutdown()`,
    /// when nothing changes, and while another user is signed in, when the
    /// rows go and nothing is emitted.
    private func finishImmediateUpload(_ task: UploadTask) -> (live: Bool, write: Task<Void, Never>?) {
        immediateUploads.removeValue(forKey: task.blobId)
        guard !isShutdown else { return (false, nil) }
        return (ownerSignedIn(task), unpersist(task))
    }

    /// The first PUT was refused: the bytes and the rows go. While another
    /// user is signed in the refusal is not applied: the upload is queued
    /// for its user instead, and `live` is false.
    private func dropImmediateUpload(_ task: UploadTask) -> (live: Bool, write: Task<Void, Never>?) {
        guard ownerSignedIn(task) else { return queueForRetry(task) }
        immediateUploads.removeValue(forKey: task.blobId)
        guard !isShutdown else { return (false, nil) }
        evict(documentId: task.documentId, blobId: task.blobId, family: task.family)
        return (true, unpersist(task))
    }

    /// The first PUT failed and may be retried: the task is queued and its
    /// record reads `pending` with one attempt. The bytes are written again,
    /// in case the write before the PUT failed. While another user is signed
    /// in it is queued inert for its user, who re-adopts it on sign-in, and
    /// `live` is false: nothing is emitted.
    private func queueForRetry(_ task: UploadTask) -> (live: Bool, write: Task<Void, Never>?) {
        immediateUploads.removeValue(forKey: task.blobId)
        guard !isShutdown else { return (false, nil) }
        var task = task
        let live = ownerSignedIn(task)
        if live, task.userId != nil { task.generation = identityGeneration }
        uploadQueue[task.blobId] = task
        return (live, persist(task, withBytes: true))
    }

    /// The owner's token now, when a 401 answered `token`, the one an
    /// attempt of `task` sent, and the owner has another since (the
    /// transport refreshed it): the owner is still signed in and the attempt
    /// is still the task's. `nil` otherwise.
    private func refreshedToken(for task: UploadTask, replacing token: String) -> String? {
        guard !isShutdown, let userId = task.userId else { return nil }
        let identity = runContext().identity
        guard identity.userId == userId, let current = identity.token, current != token else { return nil }
        if let queued = uploadQueue[task.blobId] {
            guard queued.attempt == task.attempt, queued.uploading else { return nil }
        } else if immediateUploads[task.blobId] == nil {
            return nil
        }
        return current
    }

    /// One PUT of a document upload with `token`, its owner's (`nil` for an
    /// unbound upload, which sends the transport's). A 401 is the token's:
    /// the transport's refresh-and-retry re-sends the attempt's own header,
    /// so when the owner has a new token since, the PUT is sent once more
    /// with it, which is what the transport's retry did before the header
    /// was pinned.
    private nonisolated func putOwnedDocumentBlob(
        _ task: UploadTask, options: BlobUploadSourceOptions, token: String?
    ) async throws {
        do {
            try await putDocumentBlob(
                documentId: task.documentId, blobId: task.blobId, data: task.data, options: options, token: token,
                family: task.family
            )
        } catch let error as HttpError where error.status == 401 {
            guard let token, let refreshed = await refreshedToken(for: task, replacing: token) else { throw error }
            try await putDocumentBlob(
                documentId: task.documentId, blobId: task.blobId, data: task.data, options: options, token: refreshed,
                family: task.family
            )
        }
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

    /// The memory-cache key of `family`'s copy: the db3 family's are
    /// `db3::<id>::<blob>::disp=…`, so a copy one family fetched is never
    /// served by the other (the JS `memoryKey` rule).
    static func cacheKey(
        _ family: BlobRouteFamily,
        _ documentId: String,
        _ blobId: String,
        _ disposition: BlobDisposition
    ) -> String {
        "\(cachePrefix(family, documentId, blobId))::disp=\(disposition.rawValue)"
    }

    /// Every key of `family`'s copies of a blob starts with this.
    static func cachePrefix(_ family: BlobRouteFamily, _ documentId: String, _ blobId: String) -> String {
        family == .db3 ? "db3::\(documentId)::\(blobId)" : "\(documentId)::\(blobId)"
    }

    /// The route of a blob in `family`: `/documents/{documentId}/blobs/{blobId}`
    /// as it always was, or `/db3/{db3Id}/blobs/{blobId}` with each id encoded.
    static func blobPath(_ family: BlobRouteFamily, documentId: String, blobId: String) -> String {
        switch family {
        case .documents:
            return "/documents/\(documentId)/blobs/\(blobId)"
        case .db3:
            return "/db3/\(URLEncoding.encodeComponent(documentId))/blobs/\(URLEncoding.encodeComponent(blobId))"
        }
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
        guard !isShutdown else {
            clearQueueTimer()
            return
        }
        let delay = max(0, delayMs)
        let deadline = Date().timeIntervalSince1970 + Double(delay) / 1000.0

        // Nothing runnable: drop any pending timer, like JS's
        // `clearQueueTimer()` on an empty / fully paused queue. Runnable is
        // the one rule selection uses too, so the timer never fires for a
        // task selection cannot take.
        let context = runContext()
        let hasRunnable = uploadQueue.values.contains { isRunnable($0, in: context) }
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

    /// Milliseconds until the earliest runnable (`isRunnable(_:in:)`)
    /// queued task is due, or `nil` when nothing is runnable. Mirrors JS
    /// `computeNextDelay`.
    private func nextQueueDelayMs() -> Int? {
        let now = Date().timeIntervalSince1970
        let context = runContext()
        var minWait: Double?
        for task in uploadQueue.values where isRunnable(task, in: context) {
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
            for selected in selection.selected {
                group.addTask { [weak self] in
                    if selected.task.isSession {
                        await self?.runSessionUploadTask(selected.task, token: selected.token)
                    } else {
                        await self?.runUploadTask(selected.task, token: selected.token)
                    }
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
    ///
    /// An owned task's credentials are taken here too, session or document,
    /// from the same single read of the identity that decided it is
    /// runnable: the token whose user is the task's. Its attempt sends that
    /// token whatever is signed in by the time the request leaves or is
    /// retried, and takes a new attempt token, so an outcome that answers
    /// after a change of user finds a newer one and changes nothing.
    private func selectDueTasks() -> (selected: [SelectedUpload], saturated: Bool) {
        guard !isShutdown else { return ([], true) }
        var available = uploadConcurrency - activeUploads
        guard available > 0 else { return ([], true) }

        let context = runContext()
        let candidates = uploadQueue.values
            .filter { isRunnable($0, in: context) }
            .sorted(by: { $0.nextAttemptAt < $1.nextAttemptAt })

        let now = Date().timeIntervalSince1970
        var selected: [SelectedUpload] = []
        for var task in candidates {
            if available <= 0 { break }
            guard task.nextAttemptAt <= now else { continue }
            task.uploading = true
            task.updatedAt = now
            let owned = task.userId != nil
            if owned { task.attempt &+= 1 }
            uploadQueue[task.blobId] = task
            persist(task)
            activeUploads += 1
            available -= 1
            selected.append(SelectedUpload(task: task, token: owned ? context.identity.token : nil))
        }
        return (selected, available <= 0)
    }

    /// Run one attempt for a queued task, then re-arm the shared timer.
    /// Mirrors JS `runUploadTask` plus the `finally` that reschedules.
    ///
    /// `nonisolated`: the transfer and all four emits stay off the actor, and
    /// the bookkeeping hops onto it as one isolated step each. `token` is the
    /// one taken at selection for an owned task, `nil` for an unbound one.
    private nonisolated func runUploadTask(_ task: UploadTask, token: String?) async {
        // Mirror JS `runUploadTask`: progress frame when the attempt
        // actually starts (#996).
        emitUploadProgress(task, status: "uploading")

        do {
            try await putOwnedDocumentBlob(task, options: task.options, token: token)

            // An attempt that is no longer the task's (its user signed out,
            // or it was cancelled) completes nothing and emits nothing.
            if let queueEmpty = await completeUploadTask(task) {
                // Mirror JS `emitUploadComplete`: carry the full queue record.
                emit?(BlobUploadCompletedEvent(
                    documentId: task.documentId,
                    blobId: task.blobId,
                    queueId: task.queueId,
                    filename: task.filename,
                    contentType: task.contentType,
                    numBytes: task.data.count,
                    attempts: task.attempts,
                    retainLocal: task.retainLocal,
                    updatedAt: Date().timeIntervalSince1970
                ))
                if queueEmpty {
                    emit?(BlobsQueueDrainedEvent())
                }
            }
        } catch {
            // JS `runUploadTask` classifies the error before deciding what to
            // do with the task (`shouldQueueError`,
            // `src/client/internal/blobManager.ts:1188-1192`). A permanent
            // rejection (a 4xx other than 408/409/429) is terminal: retrying
            // it re-sends the same bytes to the same rejection forever.
            let queueable = Self.shouldQueueError(error, family: task.family)
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
    /// it. Returns whether the queue is now empty, or `nil` when the attempt
    /// of an owned task is no longer the task's (a change of user or a cancel
    /// came first): nothing is completed. An unbound task completes as it
    /// always did.
    private func completeUploadTask(_ task: UploadTask) -> Bool? {
        activeUploads = max(0, activeUploads - 1)
        guard !isShutdown else { return nil }
        _ = runContext()
        if task.userId != nil {
            guard let current = uploadQueue[task.blobId], current.attempt == task.attempt else { return nil }
        }
        if let removed = uploadQueue.removeValue(forKey: task.blobId) { unpersist(removed) }
        // JS `handleUploadSuccess`: a db3 upload made with `retainLocal: false`
        // keeps no local copy once it lands, queued or not.
        if task.family == .db3, task.retainLocal == false {
            evict(documentId: task.documentId, blobId: task.blobId, family: .db3)
        }
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
        guard !isShutdown else { return (nil, false) }
        _ = runContext()
        guard var updatedTask = uploadQueue[task.blobId] else {
            return (nil, uploadQueue.isEmpty)
        }
        // An owned task's attempt that is no longer its own records nothing.
        if updatedTask.userId != nil, updatedTask.attempt != task.attempt {
            return (nil, false)
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
            evict(documentId: updatedTask.documentId, blobId: updatedTask.blobId, family: updatedTask.family)
            unpersist(updatedTask)
            return (updatedTask, uploadQueue.isEmpty)
        }

        // Clear the in-flight marker on the failure path so the task
        // becomes eligible again once its backoff elapses.
        updatedTask.uploading = false
        let delay = computeBackoff(attempts: updatedTask.attempts)
        updatedTask.nextAttemptAt = now + Double(delay) / 1000.0
        uploadQueue[task.blobId] = updatedTask
        persist(updatedTask)
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
    static func shouldQueueError(_ error: Error, family: BlobRouteFamily) -> Bool {
        // The db3 route answers `NOT_A_DB3` for a document that is not a db3:
        // no retry changes that (JS `isNotADb3`).
        if family == .db3, let httpError = error as? HttpError, httpError.status == 409, httpError.serverCode == "NOT_A_DB3" {
            return false
        }
        return shouldQueueError(error)
    }

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
    func hasCachedBytes(documentId: String, blobId: String, family: BlobRouteFamily = .documents) -> Bool {
        let prefix = Self.cachePrefix(family, documentId, blobId)
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
        Self.sha256Base64(data)
    }

    /// The base64 SHA-256 the upload routes check (`X-Blob-Sha256`).
    static func sha256Base64(_ data: Data) -> String {
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
    /// When the upload was first queued, as JS records it.
    var createdAt: TimeInterval = Date().timeIntervalSince1970

    // The session-upload fields. A document upload keeps their defaults and
    // behaves exactly as it did before they existed.

    /// Where each attempt PUTs: the document's blob route, the db3's blob
    /// route or the session's attachment route.
    var destination: UploadDestination = .document
    /// The user the upload was queued by: always set for a session upload,
    /// and for a document upload queued while a user was signed in. It is
    /// listed and attempted only while that user is signed in, with their
    /// token. `nil` is an unbound document upload, as before #4592.
    var userId: String?
    /// The identity generation the task was queued or re-adopted under.
    var generation: UInt64 = 0
    /// A session upload the server refused: kept, with its bytes, until
    /// `resume` retries it or `cancel` drops it.
    var failed = false
    /// The refusal a failed upload's waiters throw.
    var failure: (any Error)?
    /// The server's `code` for a failed upload.
    var lastErrorCode: String?
    /// Taken by each attempt of an owned upload; a user change, a cancel
    /// and, for a session upload, a pause, a resume or the session observed
    /// gone take a new one, so whatever an earlier attempt answers changes
    /// nothing.
    var attempt: UInt64 = 0
    /// Cancels the session attempt in flight.
    var cancelTransfer: (@Sendable () -> Void)?

    /// The queue identifier. Mirrors JS, where `queueId === blobId`.
    var queueId: String { blobId }
    var filename: String { options.filename ?? blobId }
    var contentType: String { options.contentType ?? "application/octet-stream" }
    var retainLocal: Bool? { options.retainLocal }

    var isSession: Bool { sessionId != nil }

    /// The route family a document or db3 upload uses; a session upload's
    /// local copy is kept as a document one is.
    var family: BlobRouteFamily {
        if case .db3 = destination { return .db3 }
        return .documents
    }

    /// The memory-cache key of the upload's bytes, under its disposition.
    var cacheKey: String {
        BlobManager.cacheKey(family, documentId, blobId, options.disposition ?? .inline)
    }

    var sessionId: String? {
        if case .agentSession(let sessionId) = destination { return sessionId }
        return nil
    }

    var attachment: AgentSessionAttachment {
        AgentSessionAttachment(blobId: blobId, filename: filename, contentType: contentType, numBytes: data.count)
    }

    /// What a failed upload throws to its waiters: the refusal itself, or,
    /// for one restored from storage, an `HttpError` carrying its server code
    /// (JS `failureOf` rebuilds the same).
    var failureError: any Error {
        failure ?? HttpError(status: 0, message: lastError ?? "Upload failed", serverCode: lastErrorCode)
    }

    var sessionStatus: AgentSessionUploadStatus {
        let state: AgentSessionUploadStatus.State = failed ? .failed : paused ? .paused : uploading ? .uploading : .pending
        return AgentSessionUploadStatus(
            blobId: blobId, filename: filename, contentType: contentType, numBytes: data.count, state: state,
            attempts: attempts, nextAttemptAt: nextAttemptAt, updatedAt: updatedAt,
            lastError: failed ? nil : lastError,
            error: failed ? AgentSessionUploadStatus.Failure(code: lastErrorCode, message: lastError ?? "Upload failed") : nil
        )
    }
}

extension UploadTask {
    /// The status a record stores: `uploaded` is never written.
    var persistedStatus: String {
        failed ? "failed" : paused ? "paused" : uploading ? "uploading" : "pending"
    }

    /// The JS `UploadRecord` for this task, times in ms since the epoch.
    var persistedRecord: PersistedUploadRecord {
        PersistedUploadRecord(
            queueId: queueId,
            documentId: documentId,
            blobId: blobId,
            filename: filename,
            contentType: contentType,
            sha256Base64: sha256,
            disposition: options.disposition?.rawValue,
            retainLocal: options.retainLocal,
            numBytes: data.count,
            status: persistedStatus,
            attempts: attempts,
            nextAttemptAt: Self.milliseconds(nextAttemptAt),
            createdAt: Self.milliseconds(createdAt),
            updatedAt: Self.milliseconds(updatedAt),
            lastError: lastError,
            lastErrorCode: lastErrorCode,
            destination: destination == .document ? nil : destination
        )
    }

    /// A task restored from `record` for `userId`, as JS
    /// `hydrateUploadsForIdentity` restores one: `uploading` comes back
    /// `pending`, `paused` and `failed` stay.
    init(restoring record: PersistedUploadRecord, data: Data, userId: String, generation: UInt64) {
        let sha256 = record.sha256Base64.isEmpty ? BlobManager.sha256Base64(data) : record.sha256Base64
        self.init(
            blobId: record.blobId,
            documentId: record.documentId,
            data: data,
            options: BlobUploadSourceOptions(
                filename: record.filename,
                contentType: record.contentType,
                sha256Base64: sha256,
                disposition: record.disposition.flatMap(BlobDisposition.init(rawValue:)),
                retainLocal: record.retainLocal
            ),
            sha256: sha256,
            attempts: record.attempts,
            lastError: record.lastError
        )
        paused = record.status == "paused"
        failed = record.status == "failed"
        lastErrorCode = record.lastErrorCode
        nextAttemptAt = record.nextAttemptAt / 1000
        createdAt = record.createdAt / 1000
        updatedAt = record.updatedAt / 1000
        destination = record.destination ?? .document
        self.userId = userId
        self.generation = generation
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Double {
        (seconds * 1000).rounded()
    }
}

/// Where an upload goes.
enum UploadDestination: Sendable, Equatable {
    /// `/documents/{documentId}/blobs/{blobId}`.
    case document
    /// `/db3/{db3Id}/blobs/{blobId}`, the db3 being the upload's document.
    case db3(String)
    /// `/agent-sessions/{sessionId}/attachments/{blobId}`.
    case agentSession(String)
}

/// Which routes a blob is reached through: `documents/:id/blobs/*`, or a
/// db3's own `db3/:id/blobs/*`. The two keep their local copies apart, and
/// the db3 family follows the JS client's offline rules.
enum BlobRouteFamily: Sendable, Equatable {
    case documents
    case db3
}

/// The token in force, the user it names, and the auth epoch: a count the
/// client advances in the same step that installs a token for another user
/// or clears it, so a change of user is seen with the token that made it.
struct UploadIdentity: Sendable, Equatable {
    let token: String?
    let userId: String?
    var epoch: UInt64 = 0
}

/// A task a selection pass took, with the token an owned task's attempt
/// sends (`nil` for an unbound document task).
struct SelectedUpload: Sendable {
    let task: UploadTask
    let token: String?
}

/// One `waitUntilUploaded` in progress.
struct UploadWaiter: Sendable {
    let id: UUID
    let continuation: CheckedContinuation<AgentSessionAttachment, any Error>
}

struct CompletedSessionUpload: Sendable {
    let sessionId: String
    let attachment: AgentSessionAttachment
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
