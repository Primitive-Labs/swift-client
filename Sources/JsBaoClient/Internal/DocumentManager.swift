import Foundation
import YSwift

/// Tracks per-document awareness (presence) state for local and remote clients.
public struct AwarenessEntry: @unchecked Sendable {
    public var localState: [String: Any]?
    public var remoteStates: [String: [String: Any]] = [:]
}

/// Delta of awareness changes produced by applying a remote awareness frame.
/// Mirrors the JS `applyRemoteAwarenessStates` return value
/// (`src/client/internal/documentManager.ts`): arrays of client IDs that
/// were added, updated, or removed.
public struct AwarenessDelta: Sendable {
    public var added: [String] = []
    public var updated: [String] = []
    public var removed: [String] = []

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}

/// Manages document lifecycle, Yjs sync protocol, metadata, and pending creates.
public final class DocumentManager: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: Logger

    // Open documents
    private var openDocs: [String: YDocument] = [:]
    /// In-flight `openDocument(...)` Tasks keyed by `documentId`.
    /// Coalesces concurrent opens for the same id so all callers
    /// receive the SAME `YDocument` instance — without this, two
    /// callers racing on `openDocument(id)` for an unopened doc would
    /// each construct a new `YDocument` and the second insert into
    /// `openDocs` would silently clobber the first, leaving the loser
    /// caller holding an orphaned doc with no observer wiring.
    ///
    /// The Task's success type is `ConfinedYDocument` — the shared holder
    /// Phase C landed (`Types/DocumentTypes.swift`) — because a `Task`
    /// result crosses an isolation boundary and `YDocument` is not
    /// `Sendable`. It still carries the one live document, so the
    /// coalescing guarantee above is unchanged (#1993, Phase D1).
    private var pendingOpens: [String: Task<ConfinedYDocument, Error>] = [:]
    private var docSyncStates: [String: Bool] = [:]
    private var docPermissions: [String: DocumentPermission] = [:]
    private var docOpenStartTime: [String: CFAbsoluteTime] = [:]
    private var docServerBytes: [String: Int] = [:]

    // Yjs persistence (SQLite-backed, replacing y-indexeddb)
    private var docPersistence: [String: YjsSQLitePersistence] = [:]

    // Metadata
    private var metadataIndex: [String: LocalMetadataEntry] = [:]

    // Pending creates
    private var pendingCreates: Set<String> = []
    private var pendingCreateRetryTimers: [String: Task<Void, Never>] = [:]
    private var localOnlyDocs: Set<String> = []

    // Awareness state per document
    private var docAwareness: [String: AwarenessEntry] = [:]

    // Docs that asked the server for sync-perf timings (JS
    // `syncPerfRequestedByDoc`). Consulted when building syncStep1.
    private var syncPerfRequestedDocs: Set<String> = []

    // Per-doc client-side sync timing capture (JS `clientSyncTimings`).
    // Keys mirror the JS field names emitted on `syncPerf.clientTimings`
    // (`clientRoundTripMs`, `clientUpdateBytes`, `clientApplyMs`,
    // `clientTotalMs`) plus the internal `syncStep1SentAt` anchor, which
    // is stripped before the map is emitted. Values are `Double`
    // (milliseconds, except `clientUpdateBytes` which is a byte count).
    private var clientSyncTimings: [String: [String: Double]] = [:]

    // Sync protocol state
    private var syncProtocols: [String: YProtocol] = [:]

    // Update observers (one per open document)
    private var updateSubscriptions: [String: YSubscription] = [:]
    // Flag to suppress update observer during remote update application
    private var applyingRemoteUpdate: [String: Bool] = [:]

    /// Docs holding a local edit that hasn't been transmitted to the server
    /// yet — set when an update is queued for outbound send, cleared once the
    /// send actually reaches the socket. Mirrors js-bao's
    /// `hasUnsyncedLocalChangesByDoc`. This is the real outbound-drain signal
    /// the evict guard relies on; `docSyncStates` only records the initial
    /// sync round-trip and never resets on a later local edit or a disconnect.
    private var unconfirmedLocalWrites: Set<String> = []

    /// Per-doc debounce tasks for local-first SQLite persistence. Every
    /// YDoc update (local edit OR remote-applied sync) reschedules a
    /// `persistDocumentToLocal` call after a short delay so bursty
    /// writes collapse into one SQLite snapshot instead of N. Mirrors
    /// js-bao's `y-indexeddb` integration, which writes on every update
    /// — without this, swift-client's SQLite mirror only got refreshed
    /// when a sync round-trip completed (`handleSyncComplete`) or the
    /// doc was explicitly closed, so any writes that arrived while
    /// sync wasn't completing (server rejection, transient offline,
    /// app force-quit between rounds) were lost on restart.
    private var persistDebounceTasks: [String: Task<Void, Never>] = [:]

    /// How long to wait after the last update before flushing the
    /// YDoc state to SQLite. Trades a small window of crash-loss risk
    /// (250ms of in-memory edits) against I/O thrashing during bursty
    /// editing — `persistDocumentToLocal` serialises the whole doc
    /// state on each call, so coalescing matters.
    private static let persistDebounceNanos: UInt64 = 250_000_000 // 250ms

    // Dependencies (set externally)
    var offlineStore: OfflineStore?
    var appId: String = ""
    var userId: String = ""
    weak var emitter: EventEmitter?
    var sendWebSocketMessage: ((String) async throws -> Void)?
    var onLocalUpdate: ((String, [UInt8]) -> Void)?
    var fetchDocumentInfo: ((String) async throws -> DocumentInfo)?
    var createRemoteDocument: (([String: Any]) async throws -> [String: Any])?
    var commitRetryBackoff: CommitRetryBackoff = CommitRetryBackoff()
    /// Online-state probe used to gate background-commit retries (mirrors
    /// js-bao's `ctx.isOnline()`). When nil, retries assume online.
    var isOnlineProvider: (() -> Bool)?

    // Internal: takes the module-internal `Logger` (#2363).
    init(logger: Logger) {
        self.logger = logger.forScope(scope: "docMgr")
    }

    /// Decision produced under `lock` in `openDocument` so the trailing
    /// `await` runs OUTSIDE the lock: return an already-open doc, await
    /// another caller's in-flight open, or claim the slot ourselves.
    private enum OpenOutcome {
        /// Never leaves this call's isolation domain — the already-open doc is
        /// handed straight back, so it needs no confinement holder.
        case existing(YDocument)
        case awaitInFlight(Task<ConfinedYDocument, Error>)
        case started(Task<ConfinedYDocument, Error>)
    }

    // MARK: - Document Lifecycle

    /// Open a document, restoring from local persistence if available.
    ///
    /// Concurrent calls for the same `documentId` are coalesced through
    /// `pendingOpens` so every caller receives the *same* `YDocument`
    /// instance — preventing the open-race regression where two
    /// concurrent callers each constructed their own `YDocument` and
    /// the second `openDocs[documentId] = ...` clobbered the first,
    /// orphaning the loser.
    public func openDocument(
        documentId: String,
        options: OpenDocumentOptions
    ) async throws -> YDocument {
        // Fast path / coalesce: decide under one lock hold. The check
        // for an already-open doc, the check for another caller's
        // in-flight open, and claiming the slot by registering our own
        // Task are atomic together — without that atomicity two callers
        // could both miss `pendingOpens` and each start a duplicate
        // open. The `await` that follows always runs OUTSIDE the lock.
        let outcome: OpenOutcome = lock.withLock {
            // Fast path: already fully open
            if let existing = openDocs[documentId] {
                return .existing(existing)
            }
            // Coalesce: another caller is already opening this docId —
            // await their Task instead of starting a duplicate open.
            if let inFlight = pendingOpens[documentId] {
                return .awaitInFlight(inFlight)
            }
            // Claim the slot atomically by registering a Task that will
            // run the full open lifecycle. Subsequent callers in the
            // window before this Task completes will see `pendingOpens`
            // and await it.
            let task = Task<ConfinedYDocument, Error> { [weak self] in
                guard let self = self else {
                    throw NSError(
                        domain: "DocumentManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "DocumentManager deallocated mid-open"]
                    )
                }
                return ConfinedYDocument(
                    try await self._openDocumentImpl(documentId: documentId, options: options)
                )
            }
            pendingOpens[documentId] = task
            return .started(task)
        }

        switch outcome {
        case .existing(let existing):
            return existing
        case .awaitInFlight(let inFlight):
            return try await inFlight.value.document
        case .started(let task):
            defer {
                lock.withLock { _ = pendingOpens.removeValue(forKey: documentId) }
            }
            return try await task.value.document
        }
    }

    /// Actual open-document implementation. Always runs inside the
    /// `pendingOpens` Task so it's serialized per-`documentId`.
    private func _openDocumentImpl(
        documentId: String,
        options: OpenDocumentOptions
    ) async throws -> YDocument {
        let doc = YDocument()
        let startTime = CFAbsoluteTimeGetCurrent()

        lock.withLock {
            openDocs[documentId] = doc
            docOpenStartTime[documentId] = startTime
            docSyncStates[documentId] = false
            docAwareness[documentId] = AwarenessEntry()
        }

        // Create sync protocol for this document
        let syncProtocol = YProtocol(document: doc)
        lock.withLock { syncProtocols[documentId] = syncProtocol }

        // Wire up SQLite-backed Y.Doc persistence for this document.
        // Previously `docPersistence` was declared but never populated —
        // both the save block (in `persistDocumentToLocal`) and the
        // restore block below silently no-op'd, so every launch started
        // with an empty Y.Doc regardless of `waitForLoad` mode. That
        // forced every consumer to wait for the `.sync` event (WS
        // handshake + full-doc sync) before any local query returned
        // data, adding seconds of skeleton time to every launch.
        //
        // Note on the race: `setupStorage()` runs as a Task on the main
        // client and can finish *after* the first `openDocument` call.
        // If `getStorageProvider()` is still nil here, we skip the
        // wiring and `persistDocumentToLocal` will late-bind on the
        // first save attempt instead. Logging makes that path visible.
        if let offlineStore = offlineStore,
           let storageProvider = await offlineStore.getStorageProvider() {
            let persistence = YjsSQLitePersistence(
                storageProvider: storageProvider,
                documentId: documentId
            )
            lock.withLock { docPersistence[documentId] = persistence }

            // Restore from SQLite: load the serialized Y.Doc state and
            // apply it inside a transaction so BaoModel<T> queries work
            // synchronously after open, before any network sync arrives.
            //
            // Previously the load was wrapped in `try?` which swallowed
            // every failure mode — provider not initialized, decode
            // failure, etc. Now we log the cause and proceed without
            // local data (the network sync still runs).
            let loaded: Data?
            do {
                loaded = try await persistence.loadDocument()
            } catch {
                logger.warn(
                    "openDocument: loadDocument failed for",
                    documentId,
                    error.localizedDescription
                )
                loaded = nil
            }
            if let data = loaded, !data.isEmpty {
                var applied = false
                doc.transactSync { txn in
                    do {
                        try txn.transactionApplyUpdate(update: Array(data))
                        applied = true
                    } catch {
                        self.logger.warn(
                            "Failed to apply persisted Y.Doc state:",
                            documentId,
                            error.localizedDescription
                        )
                    }
                }
                if applied {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    emitter?.emit(DocumentLoadedEvent(
                        // Matches js-bao's `documentLoaded.source` value
                        // for offline-store hydration. JS emits one of
                        // `"local"` (offline store), `"server"` (fresh
                        // sync), or `"indexeddb"` (browser only). Swift
                        // uses `"local"` for both SQLite-backed and
                        // memory-backed stores, so cross-platform
                        // subscribers can `switch source { case "local",
                        // "server" }` consistently.
                        documentId: documentId,
                        source: "local",
                        hadData: true,
                        bytes: data.count,
                        elapsedMs: elapsed
                    ))
                }
            }
        } else {
            // Storage provider isn't ready yet. Persist will late-bind
            // on the first save; this log makes the deferred path
            // visible so we don't silently miss the first-open case.
            logger.log(
                "openDocument: storage provider not yet ready for",
                documentId,
                "(offlineStore=\(offlineStore == nil ? "nil" : "set")) — persistence will late-bind"
            )
        }

        // Load metadata
        if let metadata = try? await offlineStore?.getMetadata(appId: appId, userId: userId, documentId: documentId) {
            lock.withLock {
                metadataIndex[documentId] = metadata
                if let permStr = metadata.permission, let perm = DocumentPermission(rawValue: permStr) {
                    docPermissions[documentId] = perm
                }
            }
        }

        // Stamp `lastOpenedAt` so retention policy enforcement can
        // sort and TTL-evict by recency. Mirrors js-bao
        // `documentManager._openCore` line 676.
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let metaSnapshot: LocalMetadataEntry = lock.withLock {
            var meta = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
            meta.lastOpenedAt = nowIso
            metadataIndex[documentId] = meta
            return meta
        }
        try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: metaSnapshot)

        // Register update observer — equivalent to JS `doc.on("update", handler)`.
        // This captures ALL writes and forwards local ones for WebSocket sync.
        let docId = documentId
        let subscription = doc.observeUpdate { [weak self] update in
            guard let self = self else { return }
            // Atomically read the isRemote flag AND snapshot the callback while
            // holding the lock, so a remote-update apply that arrives between
            // the read and the dispatch can't reclassify a local update as
            // remote (or vice-versa).
            let (isRemote, callback) = self.lock.withLock {
                (self.applyingRemoteUpdate[docId] == true, self.onLocalUpdate)
            }
            if !isRemote {
                callback?(docId, update)
            }
            // Persist to local SQLite on EVERY update — local edits and
            // remote-applied updates alike. Debounced so a burst of
            // updates only triggers one snapshot write. Independent of
            // sync round-trip: even if `handleSyncComplete` never fires
            // (server rejection, intermittent disconnect, doc whose
            // sync hangs), the local mirror still reflects the latest
            // YDoc state. Closes the durability gap left by #852.
            self.schedulePersist(documentId: docId)
        }
        lock.withLock { updateSubscriptions[documentId] = subscription }

        return doc
    }

    /// Close a document and optionally evict local data
    public func closeDocument(documentId: String, options: CloseDocumentOptions = CloseDocumentOptions()) async {
        // Cancel any pending debounced persist for this doc — we're
        // about to flush immediately (or evict), and letting a
        // delayed task fire afterwards would race the close logic.
        cancelPendingPersist(documentId: documentId)
        // Persist before tearing down: if the app is being backgrounded
        // or the doc is being closed between server syncs, this flushes
        // any local updates that `handleSyncComplete` hasn't captured.
        // Skipped when `evictLocal` is set — that branch is deleting
        // the data on purpose.
        if !options.evictLocal {
            await persistDocumentToLocal(documentId: documentId)
        }

        lock.withLock {
            _ = openDocs.removeValue(forKey: documentId)
            docSyncStates.removeValue(forKey: documentId)
            unconfirmedLocalWrites.remove(documentId)
            docOpenStartTime.removeValue(forKey: documentId)
            docServerBytes.removeValue(forKey: documentId)
            syncProtocols.removeValue(forKey: documentId)
            updateSubscriptions.removeValue(forKey: documentId)?.cancel()
            docAwareness.removeValue(forKey: documentId)
            docPersistence.removeValue(forKey: documentId)
            syncPerfRequestedDocs.remove(documentId)
            clientSyncTimings.removeValue(forKey: documentId)
        }

        if options.evictLocal {
            await evictLocalData(documentId: documentId)
        }

        emitter?.emit(DocumentClosedEvent(documentId: documentId))
    }

    // MARK: - Sync Protocol

    /// Generate syncStep1 message (state vector) for a document
    public func buildSyncStep1Message(documentId: String) -> String? {
        let syncProto: YProtocol? = lock.withLock {
            guard openDocs[documentId] != nil else { return nil }
            return syncProtocols[documentId]
        }

        guard let syncProto = syncProto else { return nil }

        let step1 = syncProto.handleConnectionStarted()
        let base64 = Data(step1.buffer).base64EncodedString()

        var message: [String: Any] = [
            "type": "syncStep1",
            "documentId": documentId,
            "stateVector": base64,
        ]
        // Mirror JS `sendSyncStep1`: when the doc requested sync-perf
        // telemetry, ask the server to send a `syncPerf` frame.
        if isSyncPerfRequested(documentId) {
            message["requestPerf"] = true
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        // Mirror JS `sendSyncStep1`, which clears prior timings and stamps
        // `syncStep1SentAt` immediately before the frame goes on the wire.
        // This is the per-phase anchor that `clientTimings` durations are
        // measured against. We stamp here (rather than in the caller)
        // because every syncStep1 send — initial open and the 350ms
        // re-send loop — funnels through this builder.
        markSyncStep1Sent(documentId)

        return jsonString
    }

    /// Mark a document as wanting server sync-perf timings on its next
    /// sync round-trips. Mirrors JS `setSyncPerfRequested`.
    public func setSyncPerfRequested(_ documentId: String, _ value: Bool) {
        lock.withLock {
            if value {
                syncPerfRequestedDocs.insert(documentId)
            } else {
                syncPerfRequestedDocs.remove(documentId)
            }
        }
    }

    /// Mirrors JS `isSyncPerfRequested`.
    public func isSyncPerfRequested(_ documentId: String) -> Bool {
        lock.withLock { syncPerfRequestedDocs.contains(documentId) }
    }

    // MARK: - Client sync-perf instrumentation

    /// Current time in milliseconds since the epoch — the Swift analogue
    /// of JS `Date.now()`. Used to anchor and measure sync phases so the
    /// emitted `clientTimings` durations match the JS units (ms).
    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000.0
    }

    /// Record a single client-side timing value for a document. Mirrors
    /// JS `DocumentManager.setSyncTiming`.
    public func setSyncTiming(_ documentId: String, _ key: String, _ value: Double) {
        lock.withLock {
            var timings = clientSyncTimings[documentId] ?? [:]
            timings[key] = value
            clientSyncTimings[documentId] = timings
        }
    }

    /// Read the raw client-side timing map for a document (including the
    /// internal `syncStep1SentAt` anchor). Mirrors JS
    /// `DocumentManager.getSyncTimings`.
    public func getSyncTimings(_ documentId: String) -> [String: Double]? {
        lock.withLock { clientSyncTimings[documentId] }
    }

    /// Drop all client-side timings for a document. Mirrors JS
    /// `DocumentManager.clearSyncTimings`.
    public func clearSyncTimings(_ documentId: String) {
        lock.withLock { _ = clientSyncTimings.removeValue(forKey: documentId) }
    }

    /// Reset and anchor a fresh sync-timing window for a document.
    /// Mirrors JS `sendSyncStep1`, which clears prior timings and stamps
    /// `syncStep1SentAt` immediately before sending the syncStep1 frame.
    public func markSyncStep1Sent(_ documentId: String) {
        lock.withLock { clientSyncTimings[documentId] = ["syncStep1SentAt": Self.nowMs()] }
    }

    /// Capture the per-phase timings that JS records inside `handleUpdate`
    /// (which handles both `syncStep2` and incremental `update` frames):
    /// the round-trip from syncStep1, the applied byte count, and the
    /// apply duration. `applyMs` is measured around the YDoc apply by the
    /// caller. Mirrors the `clientRoundTripMs` / `clientUpdateBytes` /
    /// `clientApplyMs` writes in JS `handleUpdate`.
    private func recordUpdatePhaseTimings(documentId: String, updateBytes: Int, applyMs: Double) {
        let sentAt = lock.withLock { clientSyncTimings[documentId]?["syncStep1SentAt"] }
        if let sentAt = sentAt {
            setSyncTiming(documentId, "clientRoundTripMs", Self.nowMs() - sentAt)
        }
        setSyncTiming(documentId, "clientUpdateBytes", Double(updateBytes))
        setSyncTiming(documentId, "clientApplyMs", applyMs)
    }

    /// Build a syncStep2 response message given the server's state vector.
    /// This sends the client's diff back to the server so it gets any data we have that it doesn't.
    public func buildSyncStep2Response(documentId: String, serverStateVectorBase64: String) -> String? {
        guard let doc = lock.withLock({ openDocs[documentId] }) else { return nil }

        guard let svData = Data(base64Encoded: serverStateVectorBase64) else { return nil }
        let serverSV = [UInt8](svData)

        // Compute the diff: what we have that the server doesn't
        var clientUpdate: [UInt8] = []
        doc.transactSync { [self] txn in
            do {
                clientUpdate = try txn.transactionEncodeStateAsUpdateFromSv(stateVector: serverSV)
            } catch {
                self.logger.warn("Failed to encode diff for syncStep2 response:", documentId, error.localizedDescription)
            }
        }

        guard !clientUpdate.isEmpty else { return nil }

        let updateB64 = Data(clientUpdate).base64EncodedString()
        let message: [String: Any] = [
            "type": "syncStep2",
            "documentId": documentId,
            "update": updateB64,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }

    /// Apply a remote update from the server. Handles both `syncStep2` responses
    /// and incremental `update` frames — the JS client routes both through a
    /// single `handleUpdate`, so this mirrors that (including always accumulating
    /// `docServerBytes`, which the previous split Swift `handleUpdate` omitted).
    ///
    /// Internal message-router plumbing: the sole caller is `JsBaoClient`'s own
    /// message handler (same module). It replaces the previous `handleSyncStep2`
    /// / `handleUpdate` pair, which were `public` only incidentally — they lived
    /// in `Internal/` and were never a supported entry point. Kept `internal` so
    /// that accidental public surface is not recreated.
    func handleRemoteUpdate(documentId: String, updateBase64: String) {
        let doc: YDocument? = lock.withLock {
            guard let d = openDocs[documentId] else { return nil }
            applyingRemoteUpdate[documentId] = true
            return d
        }
        guard let doc else { return }

        guard let updateData = Data(base64Encoded: updateBase64) else {
            logger.warn("Invalid base64 in remote update for doc:", documentId)
            lock.withLock { applyingRemoteUpdate[documentId] = false }
            return
        }

        let updateBytes = [UInt8](updateData)
        let applyStartMs = Self.nowMs()
        doc.transactSync { [self] txn in
            do {
                try txn.transactionApplyUpdate(update: updateBytes)
                self.logger.debug("Remote update applied for doc:", documentId)
            } catch {
                self.logger.warn("Failed to apply remote update for doc:", documentId, error.localizedDescription)
            }
        }
        let applyMs = Self.nowMs() - applyStartMs

        lock.withLock { applyingRemoteUpdate[documentId] = false }

        let bytes = updateData.count
        // Accumulate server bytes applied for first-sync metrics — JS does this
        // for both syncStep2 and update frames (`incrementServerBytes`).
        lock.withLock { docServerBytes[documentId] = (docServerBytes[documentId] ?? 0) + bytes }

        // Mirror JS `handleUpdate`: capture round-trip, byte count, and apply
        // duration for `syncPerf.clientTimings`.
        recordUpdatePhaseTimings(documentId: documentId, updateBytes: bytes, applyMs: applyMs)
    }

    /// Handle syncComplete message
    public func handleSyncComplete(documentId: String) {
        let (startTime, bytes, syncStep1SentAt): (CFAbsoluteTime?, Int?, Double?) = lock.withLock {
            docSyncStates[documentId] = true
            return (
                docOpenStartTime[documentId],
                docServerBytes[documentId],
                clientSyncTimings[documentId]?["syncStep1SentAt"]
            )
        }

        // Mirror JS `syncComplete` handler: total time from syncStep1 send
        // to sync completion, for `syncPerf.clientTimings.clientTotalMs`.
        if let syncStep1SentAt = syncStep1SentAt {
            setSyncTiming(documentId, "clientTotalMs", Self.nowMs() - syncStep1SentAt)
        }

        let elapsed = startTime.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0

        emitter?.emit(DocumentLoadedEvent(
            documentId: documentId,
            source: "server",
            hadData: (bytes ?? 0) > 0,
            bytes: bytes,
            elapsedMs: elapsed
        ))

        emitter?.emit(SyncEvent(documentId: documentId, synced: true))

        // Persist to local storage
        Task { [weak self] in
            guard let self = self else { return }
            await self.persistDocumentToLocal(documentId: documentId)

            // Also persist metadata so hasLocalCopy works across sessions
            if self.offlineStore != nil {
                let entry: LocalMetadataEntry = self.lock.withLock {
                    var e = self.metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
                    e.metadataSyncedAt = ISO8601DateFormatter().string(from: Date())
                    self.metadataIndex[documentId] = e
                    return e
                }
                try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: entry)
            }
        }
    }

    /// Send a local update to the server. Returns `true` when the update was
    /// handed to the socket, `false` when there is no socket wired or the send
    /// threw (e.g. the connection is down). Callers use this to decide whether
    /// the doc's outbound edits have actually drained.
    @discardableResult
    public func sendLocalUpdate(documentId: String, update: [UInt8]) async -> Bool {
        let base64 = Data(update).base64EncodedString()
        let message: [String: Any] = [
            "type": "update",
            "documentId": documentId,
            "update": base64,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return false
        }

        guard let send = sendWebSocketMessage else { return false }
        do {
            try await send(jsonString)
            return true
        } catch {
            logger.warn("Failed to send update for doc:", documentId, error.localizedDescription)
            return false
        }
    }

    // MARK: - Document State

    public func getDocument(_ documentId: String) -> YDocument? {
        lock.withLock { openDocs[documentId] }
    }

    /// Snapshot of every currently-open `(documentId, YDocument)`. Used by
    /// `JsBaoClient.registerModels` to connect already-open documents to a
    /// model's shared cross-document store the moment it's registered.
    public func openDocumentsSnapshot() -> [(documentId: String, doc: YDocument)] {
        lock.withLock { openDocs.map { (documentId: $0.key, doc: $0.value) } }
    }

    public func isSynced(_ documentId: String) -> Bool {
        lock.withLock { docSyncStates[documentId] ?? false }
    }

    /// Whether any CRDT updates have been applied to the open ydoc.
    /// Mirrors JS `documentManager.ydocHasData`: the state vector of an
    /// empty doc encodes as a single byte (varint 0 — "AA==" in base64),
    /// so anything longer means real updates exist. More reliable than
    /// checking shared-type sizes, which can read 0 before the shared
    /// types are materialized after an applyUpdate.
    public func ydocHasData(_ documentId: String) -> Bool {
        let doc = lock.withLock { openDocs[documentId] }
        guard let doc else { return false }
        var stateVectorLength = 0
        doc.transactSync { txn in
            stateVectorLength = txn.transactionStateVector().count
        }
        return stateVectorLength > 1
    }

    public func isOpen(_ documentId: String) -> Bool {
        lock.withLock { openDocs[documentId] != nil }
    }

    public func getPermission(_ documentId: String) -> DocumentPermission? {
        lock.withLock { docPermissions[documentId] }
    }

    public func setPermission(_ documentId: String, permission: DocumentPermission) {
        lock.withLock { docPermissions[documentId] = permission }
        emitter?.emit(PermissionEvent(documentId: documentId, permission: permission))
    }

    public func isReadOnly(_ documentId: String) -> Bool {
        lock.withLock { docPermissions[documentId] == .reader }
    }

    public func listOpenDocuments() -> [String] {
        lock.withLock { Array(openDocs.keys) }
    }

    // MARK: - Metadata

    public func getMetadataIndex() -> [String: LocalMetadataEntry] {
        lock.withLock { metadataIndex }
    }

    public func getLocalMetadata(_ documentId: String) -> LocalMetadataEntry? {
        lock.withLock { metadataIndex[documentId] }
    }

    public func setMetadata(_ documentId: String, entry: LocalMetadataEntry) {
        lock.withLock { metadataIndex[documentId] = entry }
    }

    /// Encode a `LocalMetadataEntry` to a `[String: Any]` for event
    /// payloads (the typed `DocumentMetadataChangedEvent.metadata` field).
    private func metadataDictionary(_ entry: LocalMetadataEntry) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(entry),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    public func handleServerDocuments(_ documents: [[String: Any]]) async {
        for docData in documents {
            guard let documentId = docData["documentId"] as? String else { continue }

            var entry = getLocalMetadata(documentId) ?? LocalMetadataEntry(documentId: documentId)
            if let title = docData["title"] as? String { entry.title = title }
            if let perm = docData["permission"] as? String { entry.permission = perm }
            if let createdBy = docData["createdBy"] as? String { entry.createdBy = createdBy }
            if let createdAt = docData["createdAt"] as? String { entry.createdAt = createdAt }
            if let modifiedAt = docData["modifiedAt"] as? String { entry.modifiedAt = modifiedAt }
            if let tags = docData["tags"] as? [String] { entry.tags = tags }
            entry.metadataSyncedAt = ISO8601DateFormatter().string(from: Date())

            setMetadata(documentId, entry: entry)

            if let permStr = docData["permission"] as? String,
               let perm = DocumentPermission(rawValue: permStr) {
                lock.withLock { docPermissions[documentId] = perm }
            }

            // Persist
            try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: entry)

            // Per-doc typed event, mirroring JS `handleServerDocuments`
            // (`src/client/internal/documentManager.ts`): action "updated",
            // source "server". (#996 — was a single untyped `[:]` emit that
            // typed subscribers never received.)
            emitter?.emit(DocumentMetadataChangedEvent(
                documentId: documentId,
                action: "updated",
                metadata: metadataDictionary(entry),
                changedFields: nil,
                source: "server"
            ))
        }
    }

    // MARK: - Pending Creates

    public func isPendingCreate(_ documentId: String) -> Bool {
        lock.withLock { pendingCreates.contains(documentId) }
    }

    public func isLocalOnly(_ documentId: String) -> Bool {
        lock.withLock { localOnlyDocs.contains(documentId) }
    }

    /// Create a document locally (offline or local-only). Pass
    /// `tags` to carry them through the eventual server commit
    /// (`commitOfflineCreate`) — mirrors js-bao's local-first create
    /// path (#852).
    public func createLocalDocument(
        documentId: String,
        title: String?,
        localOnly: Bool,
        tags: [String]? = nil,
        docMetadata: JSONValue? = nil
    ) async throws -> YDocument {
        let doc = YDocument()

        var metadata = LocalMetadataEntry(documentId: documentId)
        metadata.title = title
        metadata.tags = tags
        metadata.pendingCreate = !localOnly
        metadata.localOnly = localOnly
        metadata.createdAt = ISO8601DateFormatter().string(from: Date())
        // Stash the create-time opaque metadata blob so the background
        // `commitOfflineCreate` can replay it into the server POST body
        // rather than dropping it. Mirrors js-bao (#673).
        metadata.docMetadata = docMetadata

        // A freshly-created doc is immediately "open" (added to `openDocs`
        // below), so a subsequent `openDocument` hits the fast-path and never
        // runs `_openDocumentImpl` — which is where the per-doc sync protocol
        // and awareness entry are normally built. Set up both here so a
        // created-then-opened doc behaves like one opened via the full path:
        //   • Sync protocol: without it `buildSyncStep1Message` returns nil,
        //     `startNetworkSync` sends nothing, and a `.network` open of the
        //     new doc stalls until the 30s `availabilityWaitMs` timeout
        //     (#852 local-first-create regression).
        //   • Awareness entry: without it `setLocalAwarenessState` / remote
        //     awareness applies silently no-op (presence/cursors).
        // (`docPersistence` is intentionally not built here — it late-binds on
        // the first save, mirroring `_openDocumentImpl`'s deferred path.)
        let syncProtocol = YProtocol(document: doc)

        lock.withLock {
            openDocs[documentId] = doc
            docSyncStates[documentId] = false
            syncProtocols[documentId] = syncProtocol
            docAwareness[documentId] = AwarenessEntry()
            metadataIndex[documentId] = metadata
            if localOnly {
                localOnlyDocs.insert(documentId)
            } else {
                pendingCreates.insert(documentId)
            }
        }

        // Persist metadata
        try await offlineStore?.putMetadata(appId: appId, userId: userId, record: metadata)

        // Typed event (#996 — was an untyped dict that typed subscribers
        // never received). A local create originates on-device: source
        // "local", matching JS's local-first create path.
        emitter?.emit(DocumentMetadataChangedEvent(
            documentId: documentId,
            action: "created",
            metadata: metadataDictionary(metadata),
            changedFields: nil,
            source: "local"
        ))

        return doc
    }

    /// Commit a pending create to the server
    public func commitOfflineCreate(
        documentId: String,
        onExists: String = "fail"
    ) async throws -> [String: Any] {
        guard isPendingCreate(documentId) else {
            throw JsBaoError(code: .invalidArgument, message: "Document is not a pending create")
        }

        let metadata = getLocalMetadata(documentId)

        do {
            var body: [String: Any] = ["documentId": documentId]
            if let title = metadata?.title { body["title"] = title }
            if let tags = metadata?.tags, !tags.isEmpty {
                body["tags"] = tags
            }
            // Replay the create-time metadata blob the local-first create
            // stashed, so `documents.create({ metadata })` reaches the
            // server on commit instead of being dropped (#673).
            if let docMetadata = metadata?.docMetadata {
                body["metadata"] = docMetadata.toAny()
            }

            guard let createRemote = createRemoteDocument else {
                throw JsBaoError(code: .unavailable, message: "Remote create not configured")
            }

            _ = try await createRemote(body)

            // Success
            let metaToPersist: LocalMetadataEntry? = lock.withLock {
                pendingCreates.remove(documentId)
                guard var meta = metadataIndex[documentId] else { return nil }
                meta.pendingCreate = false
                meta.commitError = nil
                metadataIndex[documentId] = meta
                return meta
            }
            if let metaToPersist {
                try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: metaToPersist)
            }

            return ["created": true]
        } catch let error as HttpError where error.status == 409 {
            if onExists == "link" {
                let metaToPersist: LocalMetadataEntry? = lock.withLock {
                    pendingCreates.remove(documentId)
                    guard var meta = metadataIndex[documentId] else { return nil }
                    meta.pendingCreate = false
                    metadataIndex[documentId] = meta
                    return meta
                }
                if let metaToPersist {
                    try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: metaToPersist)
                }
                return ["linked": true]
            }
            return ["reason": "exists"]
        } catch {
            // Record error and schedule retry
            let metaToPersist: LocalMetadataEntry? = lock.withLock {
                guard var meta = metadataIndex[documentId] else { return nil }
                meta.commitError = CommitError(
                    message: error.localizedDescription,
                    at: ISO8601DateFormatter().string(from: Date())
                )
                metadataIndex[documentId] = meta
                return meta
            }
            if let metaToPersist {
                try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: metaToPersist)
            }

            emitter?.emit(PendingCreateFailedEvent(documentId: documentId, error: error.localizedDescription))
            throw error
        }
    }

    /// Background commit with exponential-backoff retry. Mirrors js-bao's
    /// `DocumentManager.scheduleCommitRetry` (`documentManager.ts`): attempts
    /// `commitOfflineCreate(onExists: "fail")`; on a transient failure it
    /// records `commitError` / `commitRetryCount` / `nextCommitAttemptAt`,
    /// emits `documentCreateCommitFailed`, and reschedules after
    /// `min(maxMs, baseMs * factor^attempt)` (optionally jittered) up to
    /// `maxAttempts`. Stops once the doc is no longer a pending create
    /// (committed elsewhere / cancelled) or we've gone offline.
    func scheduleCommitRetry(documentId: String, attempt: Int = 0) {
        if let isOnlineProvider, !isOnlineProvider() { return }
        let backoff = commitRetryBackoff

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.commitOfflineCreate(documentId: documentId, onExists: "fail")
                // created / linked / already-exists → committed, no retry.
                if result["created"] != nil || result["linked"] != nil { return }
                if (result["reason"] as? String) == "exists" { return }
            } catch {
                // Doc is no longer pending (committed or cancelled mid-flight) → stop.
                guard self.isPendingCreate(documentId) else { return }

                let message = error.localizedDescription
                let nowIso = ISO8601DateFormatter().string(from: Date())

                // Record the error + bump the retry counter, then persist.
                let metaAfterError: LocalMetadataEntry? = self.lock.withLock {
                    guard var meta = self.metadataIndex[documentId] else { return nil }
                    meta.commitError = CommitError(message: message, at: nowIso)
                    meta.commitRetryCount = (meta.commitRetryCount ?? 0) + 1
                    self.metadataIndex[documentId] = meta
                    return meta
                }
                if let metaAfterError {
                    try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: metaAfterError)
                }

                self.emitter?.emit(
                    DocumentCreateCommitFailedEvent(documentId: documentId, reason: message)
                )

                // Exponential backoff: min(maxMs, baseMs * factor^attempt), jittered.
                // Cap in Double BEFORE converting: the `pow` term grows past
                // Int.max (and reaches +infinity) at high attempt counts, and
                // `Int(_:)` traps on such a value — capping after the
                // conversion never runs.
                //
                // Bound as a `let`: the retry timer below captures this value
                // in a `Task`, and a captured `var` would be mutable state
                // shared between this task and the timer.
                let cappedDelayMs = Int(
                    min(
                        Double(backoff.maxMs),
                        Double(backoff.baseMs) * pow(backoff.factor, Double(attempt))
                    )
                )
                let delayMs = backoff.jitter && cappedDelayMs > 0
                    ? Int.random(in: 0...cappedDelayMs)
                    : cappedDelayMs

                // Persist the next-attempt timestamp.
                let nextAtIso = ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(Double(delayMs) / 1000.0)
                )
                let metaAfterSchedule: LocalMetadataEntry? = self.lock.withLock {
                    guard var meta = self.metadataIndex[documentId] else { return nil }
                    meta.nextCommitAttemptAt = nextAtIso
                    self.metadataIndex[documentId] = meta
                    return meta
                }
                if let metaAfterSchedule {
                    try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: metaAfterSchedule)
                }

                // Give up after maxAttempts.
                if attempt >= backoff.maxAttempts {
                    self.emitter?.emit(
                        DocumentCreateCommitFailedEvent(
                            documentId: documentId,
                            reason: "max retries exceeded (\(backoff.maxAttempts))"
                        )
                    )
                    return
                }

                // Schedule the next attempt.
                self.lock.withLock {
                    self.pendingCreateRetryTimers[documentId]?.cancel()
                    let timer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
                        if Task.isCancelled { return }
                        guard let self else { return }
                        self.lock.withLock { _ = self.pendingCreateRetryTimers.removeValue(forKey: documentId) }
                        self.scheduleCommitRetry(documentId: documentId, attempt: attempt + 1)
                    }
                    self.pendingCreateRetryTimers[documentId] = timer
                }
            }
        }
    }

    /// Cancel a pending create
    public func cancelPendingCreate(_ documentId: String) async {
        lock.withLock {
            pendingCreates.remove(documentId)
            pendingCreateRetryTimers[documentId]?.cancel()
            pendingCreateRetryTimers.removeValue(forKey: documentId)
            let _ = openDocs.removeValue(forKey: documentId)
            _ = metadataIndex.removeValue(forKey: documentId)
        }

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func listPendingCreates() -> [String] {
        lock.withLock { Array(pendingCreates) }
    }

    // MARK: - Awareness State

    /// Set the local awareness state for a document. Returns the previous
    /// local state plus whether the doc had an awareness entry at all
    /// (mirrors JS `setLocalAwarenessState`'s `{ previousState, exists }`
    /// so the caller can emit an `added` vs `updated` delta).
    @discardableResult
    public func setLocalAwarenessState(
        _ documentId: String,
        state: [String: Any]
    ) -> (previousState: [String: Any]?, exists: Bool) {
        lock.withLock {
            guard var entry = docAwareness[documentId] else {
                return (nil, false)
            }
            let previous = entry.localState
            entry.localState = state
            docAwareness[documentId] = entry
            return (previous, true)
        }
    }

    /// Get the full awareness snapshot for a document (local + remote states).
    public func getAwarenessSnapshot(_ documentId: String) -> AwarenessEntry? {
        lock.withLock { docAwareness[documentId] }
    }

    /// Apply an incoming remote awareness frame for a document and return
    /// the delta. Mirrors JS `applyRemoteAwarenessStates`.
    ///
    /// The wire format (both directions — see `sendExistingStates` in
    /// `src/doc-worker/awareness.ts` and `sendAwarenessState` in
    /// `src/client/JsBaoClient.ts`) is an array of `[clientId, state]`
    /// tuples; `state == null` means "this client's awareness was removed".
    public func applyRemoteAwarenessStates(
        _ documentId: String,
        states: [[Any]]
    ) -> AwarenessDelta {
        lock.withLock {
            guard var entry = docAwareness[documentId] else {
                return AwarenessDelta()
            }

            var delta = AwarenessDelta()
            for tuple in states {
            guard tuple.count >= 2, let clientId = tuple[0] as? String else { continue }
            let rawState = tuple[1]
            if rawState is NSNull {
                if entry.remoteStates.removeValue(forKey: clientId) != nil {
                    delta.removed.append(clientId)
                }
            } else if let state = rawState as? [String: Any] {
                let previous = entry.remoteStates[clientId]
                entry.remoteStates[clientId] = state
                if previous == nil {
                    delta.added.append(clientId)
                } else if !(previous! as NSDictionary).isEqual(to: state) {
                    // A re-sent identical state is a no-op, matching the
                    // JS awareness layer — don't report it in `updated`.
                    delta.updated.append(clientId)
                }
            }
        }
            docAwareness[documentId] = entry
            return delta
        }
    }

    /// Remove awareness states for specific clients. Returns the IDs that
    /// were actually removed. When `removeLocal` is true the doc's local
    /// awareness state is also cleared (mirrors JS `removeAwarenessClients`'s
    /// `removeLocal` flag, used when the caller passes its own
    /// connectionId).
    @discardableResult
    public func removeAwarenessClients(
        _ documentId: String,
        clientIds: [String],
        removeLocal: Bool = false
    ) -> [String] {
        lock.withLock {
            guard var entry = docAwareness[documentId] else {
                return []
            }
            var removed: [String] = []
            for clientId in clientIds {
                if entry.remoteStates.removeValue(forKey: clientId) != nil {
                    removed.append(clientId)
                }
            }
            if removeLocal {
                entry.localState = nil
            }
            docAwareness[documentId] = entry
            return removed
        }
    }

    // MARK: - Local Data Management

    public func hasLocalCopy(_ documentId: String) -> Bool {
        lock.withLock { metadataIndex[documentId] != nil || docPersistence[documentId] != nil }
    }

    public func evictLocalData(documentId: String) async {
        cancelPendingPersist(documentId: documentId)
        lock.withLock {
            metadataIndex.removeValue(forKey: documentId)
            _ = docPersistence.removeValue(forKey: documentId)
        }

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func evictAllLocalData() async {
        lock.withLock {
            metadataIndex.removeAll()
            docPersistence.removeAll()
            openDocs.removeAll()
            docSyncStates.removeAll()
            unconfirmedLocalWrites.removeAll()
            docPermissions.removeAll()
            pendingCreates.removeAll()
            localOnlyDocs.removeAll()
            pendingCreateRetryTimers.values.forEach { $0.cancel() }
            pendingCreateRetryTimers.removeAll()
            persistDebounceTasks.values.forEach { $0.cancel() }
            persistDebounceTasks.removeAll()
        }

        // Purge BOTH on-disk stores at the store level — the metadata store
        // (`meta`) AND the Yjs CRDT store (`yjs_docs`). A per-document delete
        // driven by `metadataIndex` (the previous approach) evicted nothing
        // when nothing was loaded — the index is empty in the
        // `persistJwtInStorage == false` path — and never touched `yjs_docs`
        // at all, so a reused document ID reopened later could still hydrate a
        // prior account's CRDT content (issue #1780). The store-level clear
        // truncates both tables regardless of what is in memory. Fast no-op on
        // empty tables.
        try? await offlineStore?.clearAllDocumentData(appId: appId, userId: userId)
    }

    // MARK: - Retention Policy

    /// Apply a retention policy to the local metadata index. Mirrors
    /// js-bao `documentManager.enforceRetentionPolicy`:
    ///  - `ttlMs`: evict any doc whose `lastOpenedAt` age exceeds the TTL.
    ///  - `maxDocs`: evict the oldest-by-`lastOpenedAt` docs until count fits.
    ///  - `maxBytes`: evict the oldest-by-`lastOpenedAt` docs until total
    ///    `localBytes` fits.
    ///
    /// Open docs are skipped (eviction while open would corrupt the
    /// in-memory Y.Doc); pending-create docs are skipped (unsynced
    /// local state). Order of enforcement matches JS: TTL first, then
    /// maxDocs, then maxBytes.
    public func enforceRetentionPolicy(
        ttlMs: Int? = nil,
        maxDocs: Int? = nil,
        maxBytes: Int? = nil
    ) async {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let formatter = ISO8601DateFormatter()

        // Snapshot the metadata under the lock; eviction itself is
        // async and takes the lock, so we can't hold it across the
        // whole loop.
        let (entries, openSet, pendingSet) = lock.withLock {
            (Array(metadataIndex.values), Set(openDocs.keys), pendingCreates)
        }

        // TTL: evict any doc whose lastOpenedAt is older than ttlMs.
        if let ttlMs {
            for meta in entries {
                guard let lastOpenedAt = meta.lastOpenedAt,
                      let date = formatter.date(from: lastOpenedAt) else { continue }
                let ageMs = nowMs - (date.timeIntervalSince1970 * 1000)
                if ageMs > Double(ttlMs),
                   !openSet.contains(meta.documentId),
                   !pendingSet.contains(meta.documentId) {
                    await evictLocalData(documentId: meta.documentId)
                }
            }
        }

        // Re-snapshot after TTL pass; we may have evicted some entries.
        let (remainingSnapshot, openSet2, pendingSet2) = lock.withLock {
            (Array(metadataIndex.values), Set(openDocs.keys), pendingCreates)
        }
        var remaining = remainingSnapshot

        // Sort oldest-first by lastOpenedAt; treat missing as epoch.
        remaining.sort { a, b in
            let aTs = a.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
            let bTs = b.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
            return aTs < bTs
        }

        // Skip open + pending-create docs in retention math; evicting
        // them out from under their callers would corrupt local state.
        let evictable = remaining.filter {
            !openSet2.contains($0.documentId) && !pendingSet2.contains($0.documentId)
        }

        // maxDocs: drop the oldest until count fits.
        if let maxDocs, evictable.count > maxDocs {
            let toEvict = evictable.prefix(evictable.count - maxDocs)
            for meta in toEvict {
                await evictLocalData(documentId: meta.documentId)
            }
        }

        // maxBytes: drop the oldest until total bytes fits.
        if let maxBytes {
            // Re-snapshot post-maxDocs pass.
            let (afterSnapshot, openSet3, pendingSet3) = lock.withLock {
                (Array(metadataIndex.values), Set(openDocs.keys), pendingCreates)
            }
            var after = afterSnapshot
            after.sort { a, b in
                let aTs = a.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
                let bTs = b.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
                return aTs < bTs
            }
            var total = after.reduce(0) { $0 + ($1.localBytes ?? 0) }
            for meta in after {
                if total <= maxBytes { break }
                if openSet3.contains(meta.documentId) || pendingSet3.contains(meta.documentId) {
                    continue
                }
                await evictLocalData(documentId: meta.documentId)
                total -= (meta.localBytes ?? 0)
            }
        }
    }

    // MARK: - Document Hash

    public func getDocHash(documentId: String) -> String? {
        guard let doc = lock.withLock({ openDocs[documentId] }) else { return nil }

        // Use state vector as a content hash for the document
        let stateVector: [UInt8] = doc.transactSync { txn in
            txn.transactionStateVector()
        }
        return Data(stateVector).base64EncodedString()
    }

    /// Base64-encoded raw Yjs state vector for an open document, or `nil`
    /// when the doc isn't open locally. Sent to the server in a
    /// `stateVectorCheck` round-trip so it can report `includesWrites` /
    /// `inSync`. Mirrors js-bao's `toBase64(Y.encodeStateVector(ydoc))`.
    public func encodeStateVectorBase64(_ documentId: String) -> String? {
        guard let doc = lock.withLock({ openDocs[documentId] }) else { return nil }

        let stateVector: [UInt8] = doc.transactSync { txn in
            txn.transactionStateVector()
        }
        return Data(stateVector).base64EncodedString()
    }

    /// `true` when the document holds local state the server may not have
    /// yet. Drives the `evict` / `evictAll` guard, mirroring js-bao's
    /// `hasUnsyncedLocalChangesByDoc` check. A doc is unsynced when any of:
    ///   - it's a pending offline create (never persisted server-side), or
    ///   - it has a local edit queued for send that hasn't reached the socket
    ///     yet (still in the outbound debounce, or the send failed because the
    ///     connection is down) — the real outbound-drain signal, and
    ///   - it's open but hasn't completed its initial sync round-trip.
    /// The middle clause is what makes this honest after initial sync:
    /// `docSyncStates` sticks at `true` once initial sync completes and never
    /// resets on a later edit or disconnect, so it alone can't protect a
    /// just-made edit from eviction.
    public func hasUnsyncedLocalChanges(_ documentId: String) -> Bool {
        lock.withLock {
            if pendingCreates.contains(documentId) { return true }
            if unconfirmedLocalWrites.contains(documentId) { return true }
            if openDocs[documentId] != nil, !(docSyncStates[documentId] ?? false) {
                return true
            }
            return false
        }
    }

    /// Record whether a doc has a local edit that hasn't reached the server
    /// yet. Set `true` when an update is queued for outbound send, `false`
    /// once the send actually reaches the socket. Mirrors js-bao's
    /// `documentManager.markUnsyncedLocalChanges(documentId, value)`.
    public func markUnsyncedLocalChanges(_ documentId: String, _ value: Bool) {
        lock.withLock {
            if value {
                unconfirmedLocalWrites.insert(documentId)
            } else {
                unconfirmedLocalWrites.remove(documentId)
            }
        }
        // Called outside `lock` so a test can block here (to drive an
        // interleaving) without wedging `hasUnsyncedLocalChanges`.
        onMarkUnsyncedForTest?(documentId, value)
    }

    /// Test-observability hook: invoked after each unsynced-flag transition,
    /// outside `lock`. Internal (visible only via `@testable import`) — the
    /// outbound flag-ordering tests use it to hold a thread between marking a
    /// document unsynced and queueing the update itself. Never set in
    /// production code.
    var onMarkUnsyncedForTest: ((String, Bool) -> Void)?

    // MARK: - Persistence

    /// Schedule a debounced `persistDocumentToLocal` call. Cancels any
    /// previously-scheduled task for the same doc so a continuous
    /// stream of updates only flushes once after the burst settles.
    ///
    /// Lock semantics: the cancel-and-replace happens under `lock` so
    /// two concurrent updates can't both win the race and leave an
    /// orphaned task running. The completed task does NOT remove its
    /// own dict entry — that would race against the next
    /// `schedulePersist`'s cancel-and-replace and could wrongly drop
    /// a newer task. Stale dict entries holding finished `Task` values
    /// are cheap and get replaced on the next update; full cleanup
    /// happens in `closeDocument` / `evictLocalData` / `evictAllLocalData`.
    private func schedulePersist(documentId: String) {
        lock.withLock {
            persistDebounceTasks[documentId]?.cancel()
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
                if Task.isCancelled { return }
                guard let self = self else { return }
                await self.persistDocumentToLocal(documentId: documentId)
            }
            persistDebounceTasks[documentId] = task
        }
    }

    /// Cancel a pending debounced persist for one doc, if any. Called
    /// from the explicit-flush paths (`closeDocument`,
    /// `evictLocalData`) so we don't race the immediate save / delete
    /// against the debounce.
    private func cancelPendingPersist(documentId: String) {
        lock.withLock { persistDebounceTasks.removeValue(forKey: documentId)?.cancel() }
    }

    private func persistDocumentToLocal(documentId: String) async {
        guard let doc = lock.withLock({ openDocs[documentId] }) else { return }

        // Get full document state as an update.
        // Use raw YrsDoc to avoid blocking the cooperative thread pool on
        // syncQueue — but bracket it with the doc's FFI lock so it can't
        // overlap an observer registration or another transaction (#1126).
        // The transaction is freed before the awaits below; only the
        // encoded bytes escape the locked scope.
        let state: [UInt8] = doc.withExclusiveAccess {
            let txn = doc.document.transact(origin: nil)
            defer { txn.free() }
            return txn.transactionEncodeStateAsUpdate()
        }

        // Resolve persistence lazily. `openDocument` wires `docPersistence`
        // up-front, but only if `offlineStore.getStorageProvider()` was
        // already non-nil at that moment — and `setupStorage()` runs as a
        // Task that can land *after* the first doc opens. Without this
        // late-bind, the very first sync of the very first doc silently
        // skipped persistence, and every subsequent save+sync looked
        // identical from the outside (nothing in `kv_store`, no error
        // because the original code wrapped the whole thing in `try?`).
        //
        // This used to be a *synchronous* immediately-invoked closure. It
        // cannot be one any more: `OfflineStore` is an actor since #1993 Phase
        // D2, so the provider lookup suspends. It is an `async` closure now —
        // the sequence, the lock holds and the race handling below are
        // otherwise unchanged.
        let persistence: YjsSQLitePersistence? = await {
            if let existing = lock.withLock({ docPersistence[documentId] }) {
                return existing
            }
            guard let offlineStore = offlineStore,
                  let provider = await offlineStore.getStorageProvider() else {
                return nil
            }
            let p = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
            // Re-check under the lock — concurrent persists for the same
            // documentId could both reach this point and double-late-bind
            // (the `await` above is now an explicit suspension point where
            // that interleaving can happen, where before it was merely
            // possible across threads). The instances would share a backing
            // store and last-writer-wins (no data loss), but log noise +
            // redundant work. Keep the first one that won the race. The whole
            // check-and-register is one atomic `withLock`: returning a winner
            // means someone else registered first (use theirs); returning nil
            // means we registered `p`.
            let existingWinner: YjsSQLitePersistence? = lock.withLock {
                if let winner = docPersistence[documentId] { return winner }
                docPersistence[documentId] = p
                return nil
            }
            if let existingWinner { return existingWinner }
            logger.log(
                "persistDocumentToLocal: late-bound persistence for",
                documentId,
                "(storageProvider became available after openDocument)"
            )
            return p
        }()

        guard let persistence else {
            logger.warn(
                "persistDocumentToLocal: no persistence available for",
                documentId,
                "(offlineStore=\(offlineStore == nil ? "nil" : "set"))"
            )
            return
        }

        do {
            try await persistence.saveDocument(data: Data(state))
        } catch {
            // Surface the real reason. Previously this was `try?`, so any
            // failure looked exactly like a silent no-op.
            logger.error(
                "persistDocumentToLocal: saveDocument failed for",
                documentId,
                error.localizedDescription
            )
        }

        // Record the on-disk size + open-recency on the metadata entry
        // so `setRetentionPolicy` can enforce `maxBytes` / TTL / LRU.
        // Mirrors js-bao `documentManager._closeDocCore` lines 945–953.
        let bytes = state.count
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let metaSnapshot: LocalMetadataEntry = lock.withLock {
            var meta = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
            meta.localBytes = bytes
            meta.lastOpenedAt = nowIso
            metadataIndex[documentId] = meta
            return meta
        }
        try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: metaSnapshot)
    }

    /// Reset in-memory, user-scoped state and re-point at `newUserId` WITHOUT
    /// deleting the previous user's persisted metadata (unlike
    /// `evictAllLocalData`, which purges disk). Used when the signed-in user
    /// changes before any document is opened — e.g. the test bootstrap where
    /// OTP signs in a different account than the restored session (#1780). The
    /// caller reloads the new user's metadata via `loadLocalMetadata()` after.
    public func resetInMemoryUserState(userId newUserId: String) async {
        lock.withLock {
            metadataIndex.removeAll()
            pendingCreates.removeAll()
            unconfirmedLocalWrites.removeAll()
            localOnlyDocs.removeAll()
            userId = newUserId
        }
    }

    /// Load all local metadata from storage
    public func loadLocalMetadata() async {
        guard let offlineStore = offlineStore else { return }
        guard let entries = try? await offlineStore.loadAllMetadata(appId: appId, userId: userId) else { return }

        lock.withLock {
            for entry in entries {
                metadataIndex[entry.documentId] = entry
                if entry.pendingCreate == true {
                    pendingCreates.insert(entry.documentId)
                }
                if entry.localOnly == true {
                    localOnlyDocs.insert(entry.documentId)
                }
            }
        }
    }

    // MARK: - Cleanup

    public func destroy() async {
        let docIds = lock.withLock { Array(openDocs.keys) }

        for docId in docIds {
            await closeDocument(documentId: docId)
        }

        lock.withLock {
            pendingCreateRetryTimers.values.forEach { $0.cancel() }
            pendingCreateRetryTimers.removeAll()
            syncProtocols.removeAll()
        }
    }
}

// MARK: - Yjs SQLite Persistence

/// Persists Yjs document state to SQLite (replaces y-indexeddb)
public final class YjsSQLitePersistence: @unchecked Sendable {
    private let storageProvider: StorageProvider
    private let documentId: String
    /// The on-disk store (table partition) holding Yjs CRDT document
    /// content, keyed by `documentId` alone (app-wide). Exposed at module
    /// scope so a store-level purge (`OfflineStore.clearAllDocumentData`)
    /// can truncate it alongside the `meta` store.
    static let store = "yjs_docs"

    public init(storageProvider: StorageProvider, documentId: String) {
        self.storageProvider = storageProvider
        self.documentId = documentId
    }

    public func loadDocument() async throws -> Data? {
        let record: StorageRecord<Data>? = try await storageProvider.get(store: Self.store, key: documentId)
        return record?.value
    }

    public func saveDocument(data: Data) async throws {
        try await storageProvider.put(store: Self.store, key: documentId, value: data, metadata: nil)
    }

    public func deleteDocument() async throws {
        try await storageProvider.delete(store: Self.store, key: documentId)
    }
}
