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
    private var pendingOpens: [String: Task<YDocument, Error>] = [:]
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

    // Sync protocol state
    private var syncProtocols: [String: YProtocol] = [:]

    // Update observers (one per open document)
    private var updateSubscriptions: [String: YSubscription] = [:]
    // Flag to suppress update observer during remote update application
    private var applyingRemoteUpdate: [String: Bool] = [:]

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

    public init(logger: Logger) {
        self.logger = logger.forScope(scope: "docMgr")
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
        // Fast path: already fully open
        lock.lock()
        if let existing = openDocs[documentId] {
            lock.unlock()
            return existing
        }
        // Coalesce: another caller is already opening this docId — await
        // their Task instead of starting a duplicate open.
        if let inFlight = pendingOpens[documentId] {
            lock.unlock()
            return try await inFlight.value
        }
        // Claim the slot atomically by registering a Task that will
        // run the full open lifecycle. Subsequent callers in the
        // window before this Task completes will see `pendingOpens`
        // and await it.
        let task = Task<YDocument, Error> { [weak self] in
            guard let self = self else {
                throw NSError(
                    domain: "DocumentManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "DocumentManager deallocated mid-open"]
                )
            }
            return try await self._openDocumentImpl(documentId: documentId, options: options)
        }
        pendingOpens[documentId] = task
        lock.unlock()

        defer {
            lock.lock()
            pendingOpens.removeValue(forKey: documentId)
            lock.unlock()
        }
        return try await task.value
    }

    /// Actual open-document implementation. Always runs inside the
    /// `pendingOpens` Task so it's serialized per-`documentId`.
    private func _openDocumentImpl(
        documentId: String,
        options: OpenDocumentOptions
    ) async throws -> YDocument {
        let doc = YDocument()
        let startTime = CFAbsoluteTimeGetCurrent()

        lock.lock()
        openDocs[documentId] = doc
        docOpenStartTime[documentId] = startTime
        docSyncStates[documentId] = false
        docAwareness[documentId] = AwarenessEntry()
        lock.unlock()

        // Create sync protocol for this document
        let syncProtocol = YProtocol(document: doc)
        lock.lock()
        syncProtocols[documentId] = syncProtocol
        lock.unlock()

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
           let storageProvider = offlineStore.getStorageProvider() {
            let persistence = YjsSQLitePersistence(
                storageProvider: storageProvider,
                documentId: documentId
            )
            lock.lock()
            docPersistence[documentId] = persistence
            lock.unlock()

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
                    emitter?.emit(.documentLoaded, DocumentLoadedEvent(
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
            lock.lock()
            metadataIndex[documentId] = metadata
            if let permStr = metadata.permission, let perm = DocumentPermission(rawValue: permStr) {
                docPermissions[documentId] = perm
            }
            lock.unlock()
        }

        // Stamp `lastOpenedAt` so retention policy enforcement can
        // sort and TTL-evict by recency. Mirrors js-bao
        // `documentManager._openCore` line 676.
        let nowIso = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        var meta = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
        meta.lastOpenedAt = nowIso
        metadataIndex[documentId] = meta
        let metaSnapshot = meta
        lock.unlock()
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
            self.lock.lock()
            let isRemote = self.applyingRemoteUpdate[docId] == true
            let callback = self.onLocalUpdate
            self.lock.unlock()
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
        lock.lock()
        updateSubscriptions[documentId] = subscription
        lock.unlock()

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

        lock.lock()
        let doc = openDocs.removeValue(forKey: documentId)
        docSyncStates.removeValue(forKey: documentId)
        docOpenStartTime.removeValue(forKey: documentId)
        docServerBytes.removeValue(forKey: documentId)
        syncProtocols.removeValue(forKey: documentId)
        updateSubscriptions.removeValue(forKey: documentId)?.cancel()
        docAwareness.removeValue(forKey: documentId)
        docPersistence.removeValue(forKey: documentId)
        syncPerfRequestedDocs.remove(documentId)
        lock.unlock()

        if options.evictLocal {
            await evictLocalData(documentId: documentId)
        }

        emitter?.emit(.documentClosed, DocumentClosedEvent(documentId: documentId))
    }

    // MARK: - Sync Protocol

    /// Generate syncStep1 message (state vector) for a document
    public func buildSyncStep1Message(documentId: String) -> String? {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        let syncProto = syncProtocols[documentId]
        lock.unlock()

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
        return jsonString
    }

    /// Mark a document as wanting server sync-perf timings on its next
    /// sync round-trips. Mirrors JS `setSyncPerfRequested`.
    public func setSyncPerfRequested(_ documentId: String, _ value: Bool) {
        lock.lock()
        if value {
            syncPerfRequestedDocs.insert(documentId)
        } else {
            syncPerfRequestedDocs.remove(documentId)
        }
        lock.unlock()
    }

    /// Mirrors JS `isSyncPerfRequested`.
    public func isSyncPerfRequested(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return syncPerfRequestedDocs.contains(documentId)
    }

    /// Build a syncStep2 response message given the server's state vector.
    /// This sends the client's diff back to the server so it gets any data we have that it doesn't.
    public func buildSyncStep2Response(documentId: String, serverStateVectorBase64: String) -> String? {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

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

    /// Handle syncStep2 response from server
    public func handleSyncStep2(documentId: String, updateBase64: String) {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return
        }
        applyingRemoteUpdate[documentId] = true
        lock.unlock()

        guard let updateData = Data(base64Encoded: updateBase64) else {
            logger.warn("Invalid base64 in syncStep2 for doc:", documentId)
            lock.lock()
            applyingRemoteUpdate[documentId] = false
            lock.unlock()
            return
        }

        let updateBytes = [UInt8](updateData)
        doc.transactSync { [self] txn in
            do {
                try txn.transactionApplyUpdate(update: updateBytes)
                self.logger.debug("SyncStep2 applied for doc:", documentId)
            } catch {
                self.logger.warn("Failed to apply syncStep2 for doc:", documentId, error.localizedDescription)
            }
        }

        lock.lock()
        applyingRemoteUpdate[documentId] = false
        lock.unlock()

        let bytes = updateData.count
        lock.lock()
        docServerBytes[documentId] = (docServerBytes[documentId] ?? 0) + bytes
        lock.unlock()
    }

    /// Handle an incremental update from server
    public func handleUpdate(documentId: String, updateBase64: String) {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return
        }
        applyingRemoteUpdate[documentId] = true
        lock.unlock()

        guard let updateData = Data(base64Encoded: updateBase64) else {
            logger.warn("Invalid base64 in update for doc:", documentId)
            lock.lock()
            applyingRemoteUpdate[documentId] = false
            lock.unlock()
            return
        }

        let updateBytes = [UInt8](updateData)
        doc.transactSync { [self] txn in
            do {
                try txn.transactionApplyUpdate(update: updateBytes)
                self.logger.debug("Update applied for doc:", documentId)
            } catch {
                self.logger.warn("Failed to apply update for doc:", documentId, error.localizedDescription)
            }
        }

        lock.lock()
        applyingRemoteUpdate[documentId] = false
        lock.unlock()
    }

    /// Handle syncComplete message
    public func handleSyncComplete(documentId: String) {
        lock.lock()
        docSyncStates[documentId] = true
        let startTime = docOpenStartTime[documentId]
        let bytes = docServerBytes[documentId]
        lock.unlock()

        let elapsed = startTime.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0

        emitter?.emit(.documentLoaded, DocumentLoadedEvent(
            documentId: documentId,
            source: "server",
            hadData: (bytes ?? 0) > 0,
            bytes: bytes,
            elapsedMs: elapsed
        ))

        emitter?.emit(.sync, SyncEvent(documentId: documentId, synced: true))

        // Persist to local storage
        Task { [weak self] in
            guard let self = self else { return }
            await self.persistDocumentToLocal(documentId: documentId)

            // Also persist metadata so hasLocalCopy works across sessions
            if self.offlineStore != nil {
                self.lock.lock()
                var entry = self.metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
                entry.metadataSyncedAt = ISO8601DateFormatter().string(from: Date())
                self.metadataIndex[documentId] = entry
                self.lock.unlock()
                try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: entry)
            }
        }
    }

    /// Send a local update to the server
    public func sendLocalUpdate(documentId: String, update: [UInt8]) async {
        let base64 = Data(update).base64EncodedString()
        let message: [String: Any] = [
            "type": "update",
            "documentId": documentId,
            "update": base64,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        do {
            try await sendWebSocketMessage?(jsonString)
        } catch {
            logger.warn("Failed to send update for doc:", documentId, error.localizedDescription)
        }
    }

    // MARK: - Document State

    public func getDocument(_ documentId: String) -> YDocument? {
        lock.lock()
        defer { lock.unlock() }
        return openDocs[documentId]
    }

    /// Snapshot of every currently-open `(documentId, YDocument)`. Used by
    /// `JsBaoClient.registerModels` to connect already-open documents to a
    /// model's shared cross-document store the moment it's registered.
    public func openDocumentsSnapshot() -> [(documentId: String, doc: YDocument)] {
        lock.lock()
        defer { lock.unlock() }
        return openDocs.map { (documentId: $0.key, doc: $0.value) }
    }

    public func isSynced(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return docSyncStates[documentId] ?? false
    }

    /// Whether any CRDT updates have been applied to the open ydoc.
    /// Mirrors JS `documentManager.ydocHasData`: the state vector of an
    /// empty doc encodes as a single byte (varint 0 — "AA==" in base64),
    /// so anything longer means real updates exist. More reliable than
    /// checking shared-type sizes, which can read 0 before the shared
    /// types are materialized after an applyUpdate.
    public func ydocHasData(_ documentId: String) -> Bool {
        lock.lock()
        let doc = openDocs[documentId]
        lock.unlock()
        guard let doc else { return false }
        var stateVectorLength = 0
        doc.transactSync { txn in
            stateVectorLength = txn.transactionStateVector().count
        }
        return stateVectorLength > 1
    }

    public func isOpen(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openDocs[documentId] != nil
    }

    public func getPermission(_ documentId: String) -> DocumentPermission? {
        lock.lock()
        defer { lock.unlock() }
        return docPermissions[documentId]
    }

    public func setPermission(_ documentId: String, permission: DocumentPermission) {
        lock.lock()
        docPermissions[documentId] = permission
        lock.unlock()
        emitter?.emit(.permission, PermissionEvent(documentId: documentId, permission: permission))
    }

    public func isReadOnly(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return docPermissions[documentId] == .reader
    }

    public func listOpenDocuments() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(openDocs.keys)
    }

    // MARK: - Metadata

    public func getMetadataIndex() -> [String: LocalMetadataEntry] {
        lock.lock()
        defer { lock.unlock() }
        return metadataIndex
    }

    public func getLocalMetadata(_ documentId: String) -> LocalMetadataEntry? {
        lock.lock()
        defer { lock.unlock() }
        return metadataIndex[documentId]
    }

    public func setMetadata(_ documentId: String, entry: LocalMetadataEntry) {
        lock.lock()
        metadataIndex[documentId] = entry
        lock.unlock()
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
                lock.lock()
                docPermissions[documentId] = perm
                lock.unlock()
            }

            // Persist
            try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: entry)

            // Per-doc typed event, mirroring JS `handleServerDocuments`
            // (`src/client/internal/documentManager.ts`): action "updated",
            // source "server". (#996 — was a single untyped `[:]` emit that
            // typed subscribers never received.)
            emitter?.emit(.documentMetadataChanged, DocumentMetadataChangedEvent(
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
        lock.lock()
        defer { lock.unlock() }
        return pendingCreates.contains(documentId)
    }

    public func isLocalOnly(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return localOnlyDocs.contains(documentId)
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

        lock.lock()
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
        lock.unlock()

        // Persist metadata
        try await offlineStore?.putMetadata(appId: appId, userId: userId, record: metadata)

        // Typed event (#996 — was an untyped dict that typed subscribers
        // never received). A local create originates on-device: source
        // "local", matching JS's local-first create path.
        emitter?.emit(.documentMetadataChanged, DocumentMetadataChangedEvent(
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

            let result = try await createRemote(body)

            // Success
            lock.lock()
            pendingCreates.remove(documentId)
            if var meta = metadataIndex[documentId] {
                meta.pendingCreate = false
                meta.commitError = nil
                metadataIndex[documentId] = meta
                lock.unlock()
                try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: meta)
            } else {
                lock.unlock()
            }

            return ["created": true]
        } catch let error as HttpError where error.status == 409 {
            if onExists == "link" {
                lock.lock()
                pendingCreates.remove(documentId)
                if var meta = metadataIndex[documentId] {
                    meta.pendingCreate = false
                    metadataIndex[documentId] = meta
                    lock.unlock()
                    try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: meta)
                } else {
                    lock.unlock()
                }
                return ["linked": true]
            }
            return ["reason": "exists"]
        } catch {
            // Record error and schedule retry
            lock.lock()
            if var meta = metadataIndex[documentId] {
                meta.commitError = CommitError(
                    message: error.localizedDescription,
                    at: ISO8601DateFormatter().string(from: Date())
                )
                metadataIndex[documentId] = meta
                lock.unlock()
                try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: meta)
            } else {
                lock.unlock()
            }

            emitter?.emit(.pendingCreateFailed, ["documentId": documentId, "error": error.localizedDescription] as [String: Any])
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
                self.lock.lock()
                if var meta = self.metadataIndex[documentId] {
                    meta.commitError = CommitError(message: message, at: nowIso)
                    meta.commitRetryCount = (meta.commitRetryCount ?? 0) + 1
                    self.metadataIndex[documentId] = meta
                    self.lock.unlock()
                    try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: meta)
                } else {
                    self.lock.unlock()
                }

                self.emitter?.emit(
                    .documentCreateCommitFailed,
                    DocumentCreateCommitFailedEvent(documentId: documentId, reason: message)
                )

                // Exponential backoff: min(maxMs, baseMs * factor^attempt), jittered.
                var delayMs = min(
                    backoff.maxMs,
                    Int(Double(backoff.baseMs) * pow(backoff.factor, Double(attempt)))
                )
                if backoff.jitter, delayMs > 0 {
                    delayMs = Int.random(in: 0...delayMs)
                }

                // Persist the next-attempt timestamp.
                let nextAtIso = ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(Double(delayMs) / 1000.0)
                )
                self.lock.lock()
                if var meta = self.metadataIndex[documentId] {
                    meta.nextCommitAttemptAt = nextAtIso
                    self.metadataIndex[documentId] = meta
                    self.lock.unlock()
                    try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: meta)
                } else {
                    self.lock.unlock()
                }

                // Give up after maxAttempts.
                if attempt >= backoff.maxAttempts {
                    self.emitter?.emit(
                        .documentCreateCommitFailed,
                        DocumentCreateCommitFailedEvent(
                            documentId: documentId,
                            reason: "max retries exceeded (\(backoff.maxAttempts))"
                        )
                    )
                    return
                }

                // Schedule the next attempt.
                self.lock.lock()
                self.pendingCreateRetryTimers[documentId]?.cancel()
                let timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.lock.lock()
                    self.pendingCreateRetryTimers.removeValue(forKey: documentId)
                    self.lock.unlock()
                    self.scheduleCommitRetry(documentId: documentId, attempt: attempt + 1)
                }
                self.pendingCreateRetryTimers[documentId] = timer
                self.lock.unlock()
            }
        }
    }

    /// Cancel a pending create
    public func cancelPendingCreate(_ documentId: String) async {
        lock.lock()
        pendingCreates.remove(documentId)
        pendingCreateRetryTimers[documentId]?.cancel()
        pendingCreateRetryTimers.removeValue(forKey: documentId)
        let _ = openDocs.removeValue(forKey: documentId)
        metadataIndex.removeValue(forKey: documentId)
        lock.unlock()

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func listPendingCreates() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pendingCreates)
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
        lock.lock()
        defer { lock.unlock() }
        guard var entry = docAwareness[documentId] else {
            return (nil, false)
        }
        let previous = entry.localState
        entry.localState = state
        docAwareness[documentId] = entry
        return (previous, true)
    }

    /// Get the full awareness snapshot for a document (local + remote states).
    public func getAwarenessSnapshot(_ documentId: String) -> AwarenessEntry? {
        lock.lock()
        defer { lock.unlock() }
        return docAwareness[documentId]
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
        lock.lock()
        defer { lock.unlock() }
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
                let isNew = entry.remoteStates[clientId] == nil
                entry.remoteStates[clientId] = state
                if isNew {
                    delta.added.append(clientId)
                } else {
                    delta.updated.append(clientId)
                }
            }
        }
        docAwareness[documentId] = entry
        return delta
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
        lock.lock()
        guard var entry = docAwareness[documentId] else {
            lock.unlock()
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
        lock.unlock()
        return removed
    }

    // MARK: - Local Data Management

    public func hasLocalCopy(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadataIndex[documentId] != nil || docPersistence[documentId] != nil
    }

    public func evictLocalData(documentId: String) async {
        cancelPendingPersist(documentId: documentId)
        lock.lock()
        metadataIndex.removeValue(forKey: documentId)
        docPersistence.removeValue(forKey: documentId)
        lock.unlock()

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func evictAllLocalData() async {
        lock.lock()
        let docIds = Array(metadataIndex.keys)
        metadataIndex.removeAll()
        docPersistence.removeAll()
        openDocs.removeAll()
        docSyncStates.removeAll()
        docPermissions.removeAll()
        pendingCreates.removeAll()
        localOnlyDocs.removeAll()
        pendingCreateRetryTimers.values.forEach { $0.cancel() }
        pendingCreateRetryTimers.removeAll()
        persistDebounceTasks.values.forEach { $0.cancel() }
        persistDebounceTasks.removeAll()
        lock.unlock()

        for docId in docIds {
            try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: docId)
        }
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
        lock.lock()
        let entries = Array(metadataIndex.values)
        let openSet = Set(openDocs.keys)
        let pendingSet = pendingCreates
        lock.unlock()

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
        lock.lock()
        var remaining = Array(metadataIndex.values)
        let openSet2 = Set(openDocs.keys)
        let pendingSet2 = pendingCreates
        lock.unlock()

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
            lock.lock()
            var after = Array(metadataIndex.values)
            let openSet3 = Set(openDocs.keys)
            let pendingSet3 = pendingCreates
            lock.unlock()
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
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

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
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let stateVector: [UInt8] = doc.transactSync { txn in
            txn.transactionStateVector()
        }
        return Data(stateVector).base64EncodedString()
    }

    /// `true` when the document holds local state the server may not have
    /// yet — a pending offline create, or an open doc whose writes haven't
    /// drained (`isSynced == false`). Drives the `evict` / `evictAll`
    /// guard, mirroring js-bao's `hasUnsyncedLocalChangesByDoc` check.
    public func hasUnsyncedLocalChanges(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pendingCreates.contains(documentId) { return true }
        if openDocs[documentId] != nil, !(docSyncStates[documentId] ?? false) {
            return true
        }
        return false
    }

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
        lock.lock()
        persistDebounceTasks[documentId]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
            if Task.isCancelled { return }
            guard let self = self else { return }
            await self.persistDocumentToLocal(documentId: documentId)
        }
        persistDebounceTasks[documentId] = task
        lock.unlock()
    }

    /// Cancel a pending debounced persist for one doc, if any. Called
    /// from the explicit-flush paths (`closeDocument`,
    /// `evictLocalData`) so we don't race the immediate save / delete
    /// against the debounce.
    private func cancelPendingPersist(documentId: String) {
        lock.lock()
        persistDebounceTasks.removeValue(forKey: documentId)?.cancel()
        lock.unlock()
    }

    private func persistDocumentToLocal(documentId: String) async {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Get full document state as an update.
        // Use raw YrsDoc to avoid blocking the cooperative thread pool on syncQueue.
        let txn = doc.document.transact(origin: nil)
        defer { txn.free() }
        let state: [UInt8] = txn.transactionEncodeStateAsUpdate()

        // Resolve persistence lazily. `openDocument` wires `docPersistence`
        // up-front, but only if `offlineStore.getStorageProvider()` was
        // already non-nil at that moment — and `setupStorage()` runs as a
        // Task that can land *after* the first doc opens. Without this
        // late-bind, the very first sync of the very first doc silently
        // skipped persistence, and every subsequent save+sync looked
        // identical from the outside (nothing in `kv_store`, no error
        // because the original code wrapped the whole thing in `try?`).
        let persistence: YjsSQLitePersistence? = {
            lock.lock()
            if let existing = docPersistence[documentId] {
                lock.unlock()
                return existing
            }
            lock.unlock()
            guard let offlineStore = offlineStore,
                  let provider = offlineStore.getStorageProvider() else {
                return nil
            }
            let p = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
            // Re-check under the lock — concurrent persists for the same
            // documentId could both reach this point and double-late-bind.
            // The instances would share a backing store and last-writer-
            // wins (no data loss), but log noise + redundant work. Keep
            // the first one that won the race.
            lock.lock()
            if let winner = docPersistence[documentId] {
                lock.unlock()
                return winner
            }
            docPersistence[documentId] = p
            lock.unlock()
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
        lock.lock()
        var meta = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
        meta.localBytes = bytes
        meta.lastOpenedAt = nowIso
        metadataIndex[documentId] = meta
        let metaSnapshot = meta
        lock.unlock()
        try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: metaSnapshot)
    }

    /// Load all local metadata from storage
    public func loadLocalMetadata() async {
        guard let offlineStore = offlineStore else { return }
        guard let entries = try? await offlineStore.loadAllMetadata(appId: appId, userId: userId) else { return }

        lock.lock()
        for entry in entries {
            metadataIndex[entry.documentId] = entry
            if entry.pendingCreate == true {
                pendingCreates.insert(entry.documentId)
            }
            if entry.localOnly == true {
                localOnlyDocs.insert(entry.documentId)
            }
        }
        lock.unlock()
    }

    // MARK: - Cleanup

    public func destroy() async {
        lock.lock()
        let docIds = Array(openDocs.keys)
        lock.unlock()

        for docId in docIds {
            await closeDocument(documentId: docId)
        }

        lock.lock()
        pendingCreateRetryTimers.values.forEach { $0.cancel() }
        pendingCreateRetryTimers.removeAll()
        syncProtocols.removeAll()
        lock.unlock()
    }
}

// MARK: - Yjs SQLite Persistence

/// Persists Yjs document state to SQLite (replaces y-indexeddb)
public final class YjsSQLitePersistence: @unchecked Sendable {
    private let storageProvider: StorageProvider
    private let documentId: String
    private static let store = "yjs_docs"

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
