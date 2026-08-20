import Foundation
import YSwift

/// Tracks per-document awareness (presence) state for local and remote clients.
public struct AwarenessEntry: Sendable {
    public var localState: [String: JSONValue]?
    public var remoteStates: [String: [String: JSONValue]] = [:]
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
    // In-flight syncStep1->syncComplete cycles, keyed by send time. Mirrors
    // js-bao `documentManager.pendingSyncOperations`: while a cycle is in
    // flight, `startNetworkSync` skips re-sending syncStep1. Without this the
    // 350ms availability-retry loop floods the document DO with duplicate
    // syncStep1 frames during a cold load (#2584).
    private var pendingSyncOperations: [String: Date] = [:]
    /// Documents that claimed a local copy at the moment they were opened,
    /// sampled BEFORE this open wired up their persistence. Mirrors JS
    /// `openDocument`'s `hasLocalNow`, which is deliberately read "BEFORE
    /// openDocument creates IndexedDB persistence" — reading it afterwards
    /// would report every document as claiming a local copy, since attaching
    /// the provider is itself one of the claim's conditions (#2664, C14).
    private var localCopyClaimedAtOpen: Set<String> = []
    private var docPermissions: [String: DocumentPermission] = [:]
    private var docOpenStartTime: [String: CFAbsoluteTime] = [:]
    private var docServerBytes: [String: Int] = [:]

    // Yjs persistence (SQLite-backed, replacing y-indexeddb)
    private var docPersistence: [String: YjsSQLitePersistence] = [:]

    /// `OpenDocumentOptions.retainLocal` per open document. A `false` entry
    /// evicts the document's local data at close, matching js-bao's
    /// `retainLocalByDoc` (`src/client/internal/documentManager.ts`). Before
    /// #2668 the option was stored on the options struct and read nowhere.
    private var retainLocalByDoc: [String: Bool] = [:]

    /// Documents whose local persistence has been evicted while they were still
    /// open. js-bao destroys the document's persistence provider on evict, so
    /// later edits and the eventual close write nothing back until the document
    /// is reopened. Without this, retention "reclaiming" an open document was
    /// undone by its own next persist (#2668).
    private var persistenceSuspended: Set<String> = []

    // Metadata
    private var metadataIndex: [String: LocalMetadataEntry] = [:]

    /// Documents for which a `deleted` metadata event has already been
    /// emitted. A revoke can reach this client twice — once as a
    /// `docMetadata` frame with `metadata: null`, once as an absence from the
    /// next authoritative server listing — and subscribers must see one
    /// delete, not two. Cleared when the document reappears. Mirrors js-bao's
    /// `lastDeletedAt` suppression (`src/client/internal/documentManager.ts`).
    private var deletedMetadataIds: Set<String> = []

    // Pending creates
    private var pendingCreates: Set<String> = []
    private var pendingCreateRetryTimers: [String: Task<Void, Never>] = [:]
    private var localOnlyDocs: Set<String> = []
    /// Documents opened before their stored metadata could be read at all — a
    /// cold start whose storage provider is not bound yet. For these,
    /// local-only is *unknown*, not known-false, and an edit must be held
    /// rather than sent until the classification lands (#2691). Emptied by
    /// `resolveLocalOnlyClassifications()` once startup metadata has loaded.
    private var localOnlyClassificationPending: Set<String> = []

    // Awareness state per document
    private var docAwareness: [String: AwarenessEntry] = [:]

    // Docs that asked the server for sync-perf timings (JS
    // `syncPerfRequestedByDoc`). Consulted when building syncStep1.
    private var syncPerfRequestedDocs: Set<String> = []

    // Per-document network-sync policy, mirroring js-bao's
    // `startNetworkModeByDoc`. Recorded at open time and consulted by the
    // post-commit path so a document the caller opened with
    // `deferNetworkSync` / `enableNetworkSync: false` never gets an
    // unrequested syncStep1 when its background create commits. JS has a
    // third mode (`afterIndexedDb`); Swift's local store has no equivalent
    // staged hand-off, so only `immediate` and `manual` exist here.
    private var startNetworkModeByDoc: [String: StartNetworkMode] = [:]

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

    /// Documents whose `documentLoaded(source:"server")` has already been
    /// emitted for the CURRENT open cycle. Mirrors js-bao's
    /// `docLoadedEmitted` flag (`documentManager.ts:475`): JS announces a
    /// server-side load once per open, not once per `syncComplete`, so a
    /// document held open across several reconnects does not tell its
    /// subscribers it was freshly loaded on every resync (#2666).
    ///
    /// Reset at open and cleared at close, so a reopen is a new cycle and
    /// does announce the load again.
    private var serverLoadedEmitted: Set<String> = []

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
    /// Fires once a `pendingCreate` document exists server-side. The
    /// syncStep1 sent before the commit landed gets no `syncComplete` back
    /// (the server had no such document), so its in-flight claim is released
    /// on commit and sync is re-triggered here. Mirrors js-bao's
    /// `applyPostCommitPolicy`, which deletes the doc's `pendingSyncOperations`
    /// entry and calls `startNetworkSync` on the same path.
    ///
    /// Fires only for documents in `immediate` mode — see
    /// `applyPostCommitPolicy` below.
    var onPendingCreateCommitted: ((String) -> Void)?
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

    /// How a call to `openDocument` produced the document it handed back.
    /// The caller needs this to know whether it may tear the document down
    /// again: only the invocation that actually ran the open owns the
    /// document's lifecycle. An `.existing` document belongs to whoever
    /// opened it, and a `.coalesced` one to the caller whose Task ran the
    /// open — dropping either would pull the document out from under a
    /// caller that is still using it.
    public enum OpenOrigin: Sendable {
        /// This call ran the open: it created the document and registered it.
        case created
        /// The document was already open; this call got the existing handle.
        case existing
        /// Another caller's open was in flight; this call awaited it.
        case coalesced
    }

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
        try await openDocumentReportingOrigin(
            documentId: documentId,
            options: options
        ).document
    }

    /// `openDocument` plus the `OpenOrigin` of the document it returns, for
    /// the client's open path — it installs a failure cleanup that must only
    /// fire for a document this invocation itself opened (#2667).
    public func openDocumentReportingOrigin(
        documentId: String,
        options: OpenDocumentOptions
    ) async throws -> (document: YDocument, origin: OpenOrigin) {
        // Who drives this document's network sync (JS
        // `startNetworkModeByDoc`). `deferNetworkSync` / `enableNetworkSync:
        // false` means the caller does, so client-driven triggers — the
        // connect sweep, the post-commit re-sync of a pending create — must
        // leave it alone. `networkingAllowed()` is deliberately not part of
        // the mode: that is a transient online check, not the caller's
        // intent, and those paths check it separately.
        //
        // Recorded on every call that returns a document, including one that
        // returns an already-open document (a locally-created document is
        // already open by the time the caller opens it, which is exactly the
        // deferred-sync case this exists for). JS `open` sets
        // `startNetworkModeByDoc` the same way — the latest open's intent
        // wins.
        //
        // Recorded in the same `lock.withLock` that claims `pendingOpens`,
        // below — i.e. before `_openDocumentImpl` can put the document into
        // `openDocs`. Writing it on the way *out* instead left a window that
        // spans the storage provider, `loadDocument()`, `getMetadata` and
        // `putMetadata`: for all of it the document is in
        // `listOpenDocuments()` with no mode entry, and `startNetworkMode(_:)`
        // defaults an absent entry to `.immediate`. A `connect()` overlapping
        // the open of a `deferNetworkSync` document would then put an
        // unrequested syncStep1 on the wire against a half-restored ydoc —
        // the #2475 hazard the connect-sweep filter exists to close, on the
        // common app-launch shape (open and connect concurrently, local
        // restore of a large document taking hundreds of ms).
        // `clearStartNetworkModeIfNotOpen` undoes the write on the throwing
        // path, so an open that fails still leaves no entry behind.
        let startMode: StartNetworkMode =
            options.enableNetworkSync && !options.deferNetworkSync ? .immediate : .manual

        // Fast path / coalesce: decide under one lock hold. The check
        // for an already-open doc, the check for another caller's
        // in-flight open, and claiming the slot by registering our own
        // Task are atomic together — without that atomicity two callers
        // could both miss `pendingOpens` and each start a duplicate
        // open. The `await` that follows always runs OUTSIDE the lock.
        let outcome: OpenOutcome = lock.withLock {
            // Atomic with the document becoming visible: whichever branch we
            // take below, any reader that can see this document from now on
            // also sees the caller's start mode.
            startNetworkModeByDoc[documentId] = startMode
            retainLocalByDoc[documentId] = options.retainLocal
            // Fast path: already fully open
            if let existing = openDocs[documentId] {
                // Deliberately does NOT lift a persistence suspension. Only a
                // real close-then-open does. A document evicted while open stays
                // suspended, otherwise a second `openDocument` on the still-open
                // handle would re-enable persistence and the next edit or close
                // would write the evicted CRDT bytes back (#2668).
                return .existing(existing)
            }
            // A genuine open: the document is not in `openDocs`, so this is the
            // close-then-open that lifts any eviction's persistence suspension.
            persistenceSuspended.remove(documentId)
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
            return (existing, .existing)
        case .awaitInFlight(let inFlight):
            do {
                return (try await inFlight.value.document, .coalesced)
            } catch {
                clearStartNetworkModeIfNotOpen(documentId)
                throw error
            }
        case .started(let task):
            defer {
                lock.withLock { _ = pendingOpens.removeValue(forKey: documentId) }
            }
            do {
                return (try await task.value.document, .created)
            } catch {
                clearStartNetworkModeIfNotOpen(documentId)
                throw error
            }
        }
    }

    /// Drop a start-mode entry written by an open that then threw — but only
    /// while the document is genuinely not open. The guard matters because
    /// concurrent opens share one entry: a failing open must not delete the
    /// mode a successful one (or a `documents.create`) recorded for a
    /// document that IS visible. The invariant it maintains is "an entry
    /// exists exactly while the document is in `openDocs`".
    private func clearStartNetworkModeIfNotOpen(_ documentId: String) {
        lock.withLock {
            if openDocs[documentId] == nil {
                startNetworkModeByDoc.removeValue(forKey: documentId)
            }
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
            // Cleared here and decided once this open has loaded the
            // document's stored metadata (see `recordLocalCopyClaim` below) —
            // a claim left over from a previous open must not leak into this
            // one.
            localCopyClaimedAtOpen.remove(documentId)
            openDocs[documentId] = doc
            docOpenStartTime[documentId] = startTime
            docSyncStates[documentId] = false
            docAwareness[documentId] = AwarenessEntry()
            // A fresh open cycle has not announced a server-side load yet.
            serverLoadedEmitted.remove(documentId)
        }

        // The document is visible now, so announce the open before anything
        // that can take time (local restore, metadata read) runs. JS emits
        // `documentOpened` at exactly this point — right after the Y.Doc is
        // registered and before the local hydration payload is flushed
        // (`documentManager.ts:696`). Consumers rely on the ordering:
        // `requestManualSync` defers its syncStep1 until this event arrives
        // for a document that is not open yet, so a client that never emits
        // it strands a deferred-sync document (#2666).
        emitter?.emit(DocumentOpenedEvent(documentId: documentId))

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

        // Load metadata — and note whether the store could answer at all. On a
        // cold start the provider may not be bound yet, and then a missing row
        // says nothing about the document: local-only is unknown, not false,
        // and its edits are held until the classification lands (#2691).
        if let offlineStore {
            let read = try? await offlineStore.readMetadata(
                appId: appId, userId: userId, documentId: documentId
            )
            lock.withLock {
                if let entry = read?.entry { metadataIndex[documentId] = entry }
                if read?.readable == true
                    || metadataIndex[documentId] != nil
                    || localOnlyDocs.contains(documentId) {
                    // Either the store answered, or this session already knows
                    // what the document is (it was created or listed here).
                    localOnlyClassificationPending.remove(documentId)
                } else {
                    localOnlyClassificationPending.insert(documentId)
                }
            }
        }

        // Restore the cached permission from whichever metadata entry is now
        // current — the one just loaded, or one an earlier refresh left in the
        // index. `lastKnownPermission` wins over `permission`: it is what the
        // permission-apply path (and the open-time refresh below) writes,
        // while `permission` stays as the raw server-listing value.
        lock.withLock {
            if let meta = metadataIndex[documentId],
               let permStr = meta.lastKnownPermission ?? meta.permission,
               let perm = DocumentPermission(rawValue: permStr) {
                docPermissions[documentId] = perm
            }
        }

        // Seed a permission and refresh it from the server in the background,
        // as JS does at open (`documentManager._openCore`). Runs after the
        // restore above so a cached reader grant is not overwritten by the
        // optimistic default (#2667, parity C19).
        bootstrapPermission(documentId: documentId)

        // Pin local-only-ness for as long as this document stays open, whatever
        // told us about it — the stored row just read, or one already in the
        // index. Eviction deletes that row out from under an open document,
        // which stays editable, and its edits must still never go on the wire
        // (#2691). JS pins the same way, once its own open path has read the
        // stored row (`_primeLocalOnlyFromLocalMetadata`).
        lock.withLock {
            if metadataIndex[documentId]?.localOnly == true {
                localOnlyDocs.insert(documentId)
            }
        }

        // Decide the local-copy claim now: the stored metadata has been loaded
        // (a fresh session's metadata index is otherwise still empty, and the
        // claim would be missed for exactly the restart-with-a-stale-snapshot
        // case it exists to catch), and this open's own persistence provider
        // does not count towards it. Mirrors JS's `hasLocalNow`, which reads
        // the metadata's `localBytes` / `localOnly` rather than the presence of
        // a provider (#2664, C14).
        recordLocalCopyClaim(documentId)

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

    /// Open-time permission bootstrap, mirroring js-bao's `_openCore`
    /// (`setPermission(documentId, "read-write")` followed by a background
    /// `fetchDocumentInfo` whose answer is cached).
    ///
    /// The seed is what stops a freshly opened document from having no
    /// permission at all: `isReadOnly` reads `docPermissions`, so an absent
    /// entry answers "writable" for a reader. Unlike JS, Swift restores a
    /// cached permission from local metadata at open, so the seed is applied
    /// only when nothing is known — a stale-but-real `reader` grant is a
    /// better answer than the optimistic default.
    private func bootstrapPermission(documentId: String) {
        let seeded: Bool = lock.withLock {
            guard docPermissions[documentId] == nil else { return false }
            docPermissions[documentId] = .readWrite
            return true
        }
        if seeded {
            emitter?.emit(PermissionEvent(documentId: documentId, permission: .readWrite))
        }

        // The hook is the client's `documents.get`. Absent (a client wired
        // without it, or a unit test), there is nothing to refresh from and
        // the seed/cached value stands.
        guard let fetchDocumentInfo else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await fetchDocumentInfo(documentId)
                await self.cachePermission(documentId: documentId, permission: info.permission)
            } catch {
                // Background refresh: a failure leaves the seeded or cached
                // permission in place, exactly as JS's `.catch` does.
                self.logger.warn(
                    "Background permission fetch failed for",
                    documentId,
                    error.localizedDescription
                )
            }
        }
    }

    /// Record a server-supplied permission and cache it in local metadata with
    /// its age, so a later offline open can both honour and judge it. Mirrors
    /// the `lastKnownPermission` / `permissionCachedAt` write JS performs on
    /// the same path.
    private func cachePermission(documentId: String, permission: DocumentPermission) async {
        setPermission(documentId, permission: permission)

        let nowIso = ISO8601DateFormatter().string(from: Date())
        let snapshot: LocalMetadataEntry = lock.withLock {
            var meta = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
            meta.documentId = documentId
            meta.lastKnownPermission = permission.rawValue
            meta.permissionCachedAt = nowIso
            metadataIndex[documentId] = meta
            return meta
        }
        try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: snapshot)
    }

    /// Drop a document that never finished opening, without any of
    /// `closeDocument`'s flush/evict/announce work — the document was never
    /// handed to a caller, so there is nothing to persist and no `close` to
    /// report. Mirrors js-bao's `removeOpenDoc`, which `openDocument` calls
    /// when a later step of the open throws so the next attempt re-runs the
    /// full initialization instead of short-circuiting to a half-open
    /// document (#2667).
    public func removeOpenDoc(_ documentId: String) {
        lock.withLock {
            _ = openDocs.removeValue(forKey: documentId)
            docSyncStates.removeValue(forKey: documentId)
            docAwareness.removeValue(forKey: documentId)
            docPermissions.removeValue(forKey: documentId)
            docPersistence.removeValue(forKey: documentId)
            syncProtocols.removeValue(forKey: documentId)
            updateSubscriptions.removeValue(forKey: documentId)?.cancel()
            pendingSyncOperations.removeValue(forKey: documentId)
            docOpenStartTime.removeValue(forKey: documentId)
            docServerBytes.removeValue(forKey: documentId)
            syncPerfRequestedDocs.remove(documentId)
            startNetworkModeByDoc.removeValue(forKey: documentId)
            // `clientSyncTimings` is deliberately kept, as JS keeps its own:
            // the timings record what this open attempted, which is exactly
            // what a caller (or a test) inspects after it failed.
            serverLoadedEmitted.remove(documentId)
            localCopyClaimedAtOpen.remove(documentId)
            retainLocalByDoc.removeValue(forKey: documentId)
        }
    }

    /// Close a document and optionally evict local data
    public func closeDocument(documentId: String, options: CloseDocumentOptions = CloseDocumentOptions()) async {
        // Cancel any pending debounced persist for this doc — we're
        // about to flush immediately (or evict), and letting a
        // delayed task fire afterwards would race the close logic.
        cancelPendingPersist(documentId: documentId)

        // `retainLocal: false` at open means "don't keep this document on this
        // device", so it evicts at close exactly like an explicit
        // `evictLocal` — js-bao `closeDocument`'s
        // `evictLocal || retainLocalByDoc.get(id) === false` (#2668).
        let evictLocal = options.evictLocal
            || lock.withLock { retainLocalByDoc[documentId] } == false

        // Persist before tearing down: if the app is being backgrounded
        // or the doc is being closed between server syncs, this flushes
        // any local updates that `handleSyncComplete` hasn't captured.
        // Skipped when evicting — that branch is deleting the data on purpose.
        if !evictLocal {
            await persistDocumentToLocal(documentId: documentId)
        }

        lock.withLock {
            retainLocalByDoc.removeValue(forKey: documentId)
            persistenceSuspended.remove(documentId)
            _ = openDocs.removeValue(forKey: documentId)
            docSyncStates.removeValue(forKey: documentId)
            pendingSyncOperations.removeValue(forKey: documentId)
            unconfirmedLocalWrites.remove(documentId)
            docOpenStartTime.removeValue(forKey: documentId)
            docServerBytes.removeValue(forKey: documentId)
            syncProtocols.removeValue(forKey: documentId)
            updateSubscriptions.removeValue(forKey: documentId)?.cancel()
            docAwareness.removeValue(forKey: documentId)
            docPersistence.removeValue(forKey: documentId)
            syncPerfRequestedDocs.remove(documentId)
            startNetworkModeByDoc.removeValue(forKey: documentId)
            clientSyncTimings.removeValue(forKey: documentId)
            // End of the open cycle — a reopen announces its server-side load
            // again, as JS does by deleting the `docLoadedEmitted` entry on
            // close (`documentManager.ts:1025`).
            serverLoadedEmitted.remove(documentId)
            localCopyClaimedAtOpen.remove(documentId)
            // The marker outlives an evicted document's metadata row only
            // because the document stays open and editable, and its edits must
            // still stay off the wire (#2691). Closed, there is nothing left to
            // filter — and a marker held past its row would go on claiming,
            // through `hasLocalCopy`, a local copy eviction has deleted. A
            // document whose row still says `localOnly` keeps its marker: the
            // row is the classification, and it survives the close.
            if metadataIndex[documentId]?.localOnly != true {
                localOnlyDocs.remove(documentId)
            }
            localOnlyClassificationPending.remove(documentId)
        }

        if evictLocal {
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
        // Mirror JS `sendSyncStep1`'s `docHash` (SHA-256 hex over the full
        // encoded state - the server's `calculateDocHash` algorithm). When it
        // matches the server's hash, the server skips the diff/R2 cycle and
        // answers with a bare syncComplete; Swift could never hit that
        // fast path while it omitted the field (#2584).
        if let contentHash = getContentDocHash(documentId: documentId) {
            message["docHash"] = contentHash
        }
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

    // MARK: - Pending sync operations (JS parity, #2584)

    /// Claim the in-flight sync slot for a document before sending
    /// syncStep1. Returns `false` when a cycle is already in flight - the
    /// caller must skip the send. Mirrors js-bao
    /// `documentManager.beginPendingSyncOperation`, with a staleness escape
    /// hatch standing in for the JS sync watchdog (10s, the JS
    /// `syncWatchdogTimeoutMs` default): a pending entry older than
    /// `staleAfter` is treated as lost and replaced, so a dropped
    /// syncComplete cannot wedge the document's sync forever.
    public func beginPendingSyncOperation(
        _ documentId: String,
        staleAfter: TimeInterval = 10
    ) -> Bool {
        lock.withLock {
            if let startedAt = pendingSyncOperations[documentId],
               Date().timeIntervalSince(startedAt) < staleAfter {
                return false
            }
            pendingSyncOperations[documentId] = Date()
            return true
        }
    }

    /// Release the in-flight sync slot (cycle finished, send failed, or the
    /// document closed). Mirrors JS `completePendingSyncOperation`.
    public func completePendingSyncOperation(_ documentId: String) {
        lock.withLock { _ = pendingSyncOperations.removeValue(forKey: documentId) }
    }

    /// Drop every in-flight sync claim - the transport died, so no
    /// syncComplete is coming for any of them. Mirrors JS
    /// `clearPendingSyncOperations` (ws-close path).
    public func clearPendingSyncOperations() {
        lock.withLock { pendingSyncOperations.removeAll() }
    }

    /// Record a document's sync state and report it. Mirrors JS
    /// `documentManager.applySyncState`, including its one exception: a
    /// `.manual` document is never *promoted* to synced from here, because the
    /// caller owns that document's sync timing. Marking one unsynced always
    /// applies — a dead transport is not something the caller opted out of.
    ///
    /// The event is emitted on every call, not only on a change, matching JS.
    public func applySyncState(_ documentId: String, isSynced: Bool) {
        if isSynced, startNetworkMode(documentId) == .manual { return }
        lock.withLock { docSyncStates[documentId] = isSynced }
        emitter?.emit(SyncEvent(documentId: documentId, synced: isSynced))
    }

    /// Mark every open document unsynced and report each one. The transport
    /// paths (connecting, close, deliberate disconnect) call this; mirrors the
    /// `forEachOpenDoc(... _updateSynced(id, false))` sweep JS runs in all
    /// three (#2663).
    public func markAllOpenDocumentsUnsynced() {
        for documentId in listOpenDocuments() {
            applySyncState(documentId, isSynced: false)
        }
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

    /// Whether the client drives this document's network sync itself
    /// (`immediate`) or the caller does (`manual` — the document was opened
    /// with `deferNetworkSync` or `enableNetworkSync: false`). Mirrors
    /// js-bao's `startNetworkModeByDoc` values.
    public enum StartNetworkMode: Sendable {
        case immediate
        case manual
    }

    /// Record a document's network-sync policy. Called by `openDocument` and
    /// by `startNetworkSync` (an explicit start promotes a `manual` document
    /// to `immediate`, exactly as JS `startNetworkSync` does).
    public func setStartNetworkMode(_ documentId: String, _ mode: StartNetworkMode) {
        lock.withLock { startNetworkModeByDoc[documentId] = mode }
    }

    /// The recorded policy, defaulting to `immediate` for documents opened
    /// through a path that records none — matching the pre-existing behavior
    /// of every non-deferred open.
    public func startNetworkMode(_ documentId: String) -> StartNetworkMode {
        lock.withLock { startNetworkModeByDoc[documentId] ?? .immediate }
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

    /// Decide how to answer a server-initiated `syncStep1`, mirroring JS
    /// `handleSyncStep1` (`src/client/JsBaoClient.ts:6883-7001`; #2665).
    ///
    /// A diff goes back only when the server's `docHash` differs from ours AND
    /// the document is writable. The other two cases end the sync locally:
    /// matching hashes mean there is nothing to send, and a read-only document
    /// cannot push its diff at all — both mark the document synced here,
    /// because no `syncStep2` means no `syncComplete` will come back to do it.
    ///
    /// Returns the message to put on the wire, or `nil` when nothing should be
    /// sent. A frame carrying no `docHash` (an older server) never matches, so
    /// it is answered with the diff exactly as before.
    public func syncStep2ResponseForServerSyncStep1(
        documentId: String,
        serverDocHash: String?,
        serverStateVectorBase64: String
    ) -> String? {
        guard lock.withLock({ openDocs[documentId] != nil }) else {
            logger.warn("Received syncStep1 for a document that is not open:", documentId)
            return nil
        }

        let readOnly = isReadOnly(documentId)
        let localHash = getContentDocHash(documentId: documentId)
        let hashesMatch = serverDocHash != nil && localHash != nil && serverDocHash == localHash

        if !hashesMatch && !readOnly {
            return buildSyncStep2Response(
                documentId: documentId,
                serverStateVectorBase64: serverStateVectorBase64
            )
        }

        logger.debug(
            "Answering syncStep1 without a diff for",
            documentId,
            readOnly ? "(read-only)" : "(hash match)"
        )
        markSyncedLocally(documentId)
        return nil
    }

    /// Mark a document synced without a server round-trip — the cases where
    /// the client deliberately sends nothing back, so the `syncComplete` that
    /// normally ends the sync will never arrive.
    ///
    /// It runs the full completion path rather than only setting the flag:
    /// this *replaces* that `syncComplete`, so a subscriber waiting on
    /// `documentLoaded`, and the local metadata a completed sync persists,
    /// must not be left behind. `handleSyncComplete` reports zero server bytes
    /// here, which is exactly what happened.
    ///
    /// A document that is already synced only gets the sync event: a server
    /// can send `syncStep1` repeatedly, and re-running the completion path
    /// would emit a fresh `documentLoaded` for each one.
    private func markSyncedLocally(_ documentId: String) {
        let alreadySynced = lock.withLock { docSyncStates[documentId] ?? false }
        guard !alreadySynced else {
            lock.withLock { _ = pendingSyncOperations.removeValue(forKey: documentId) }
            emitter?.emit(SyncEvent(documentId: documentId, synced: true))
            return
        }
        handleSyncComplete(documentId: documentId)
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
        guard let updateData = Data(base64Encoded: updateBase64) else {
            logger.warn("Invalid base64 in remote update for doc:", documentId)
            return
        }
        handleRemoteUpdate(documentId: documentId, updateData: updateData)
    }

    /// Data-based twin of the base64 overload. `syncStep2`/`update` frames
    /// whose payload exceeds the server's `MAX_UPDATE_SIZE` arrive as an
    /// `updateUrl` pointing at R2; the router downloads those to raw bytes,
    /// so the apply path must not require a base64 round-trip.
    func handleRemoteUpdate(documentId: String, updateData: Data) {
        let doc: YDocument? = lock.withLock {
            guard let d = openDocs[documentId] else { return nil }
            applyingRemoteUpdate[documentId] = true
            return d
        }
        guard let doc else { return }

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

    /// Handle syncComplete message.
    ///
    /// `synced` is the server's verdict for the round-trip, taken from the
    /// frame's optional `synced` field. A frame without the field means
    /// success, which is why the parameter defaults to `true` — JS resolves it
    /// the same way (`data.synced === false ? false : true`,
    /// `JsBaoClient.ts:7440`). Before #2666 Swift recorded every completion as
    /// a success, so a document the server reported as NOT synced was still
    /// treated as up to date.
    public func handleSyncComplete(documentId: String, synced: Bool = true) {
        let (startTime, bytes, syncStep1SentAt, shouldEmitLoaded):
            (CFAbsoluteTime?, Int?, Double?, Bool) = lock.withLock {
            let wasSynced = docSyncStates[documentId] ?? false
            docSyncStates[documentId] = synced
            // The cycle this claim guarded is finished (JS parity: the
            // syncComplete handler calls `completePendingSyncOperation`).
            // Released whatever the verdict — an unsuccessful completion must
            // not wedge the document's sync behind a claim nobody releases.
            pendingSyncOperations.removeValue(forKey: documentId)

            // JS gates `documentLoaded` on `isSynced && !wasSynced` AND on the
            // per-open-cycle `docLoadedEmitted.server` flag
            // (`documentManager.ts:1338-1364`). Both matter: the first keeps a
            // repeated success quiet, the second keeps a
            // disconnect-then-resync quiet, which is the shape #2666 was
            // reported against.
            let emitLoaded = synced && !wasSynced && !serverLoadedEmitted.contains(documentId)
            if emitLoaded { serverLoadedEmitted.insert(documentId) }

            return (
                docOpenStartTime[documentId],
                docServerBytes[documentId],
                clientSyncTimings[documentId]?["syncStep1SentAt"],
                emitLoaded
            )
        }

        // Mirror JS `syncComplete` handler: total time from syncStep1 send
        // to sync completion, for `syncPerf.clientTimings.clientTotalMs`.
        if let syncStep1SentAt = syncStep1SentAt {
            setSyncTiming(documentId, "clientTotalMs", Self.nowMs() - syncStep1SentAt)
        }

        if shouldEmitLoaded {
            let elapsed = startTime.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0
            emitter?.emit(DocumentLoadedEvent(
                documentId: documentId,
                source: "server",
                hadData: (bytes ?? 0) > 0,
                bytes: bytes,
                elapsedMs: elapsed
            ))
        }

        emitter?.emit(SyncEvent(documentId: documentId, synced: synced))

        // Persist to local storage. The Y.Doc snapshot is written whatever the
        // verdict — it reflects what the client actually holds, and dropping it
        // on an unsuccessful round-trip would lose local edits.
        Task { [weak self] in
            guard let self = self else { return }
            await self.persistDocumentToLocal(documentId: documentId)

            // Also persist metadata so hasLocalCopy works across sessions.
            // Only a SUCCESSFUL sync stamps the sync timestamp: stamping it
            // after a completion the server reported as unsynced would claim a
            // round-trip that did not happen.
            if synced, self.offlineStore != nil {
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

    /// Merge several encoded Yjs updates into one frame (JS parity:
    /// `Y.mergeUpdates` in `flushLocalUpdates`) by applying them to a scratch
    /// doc and encoding its state. One outbound frame per flush matters
    /// server-side: a cold document room reconstructs the full document once
    /// per concurrently-arriving message, so a burst of N tiny updates (the
    /// fresh-open `_meta_*` registration writes) triggers N concurrent
    /// multi-second reconstructions and starves the initial sync (#2584).
    public func mergeUpdates(_ updates: [[UInt8]]) -> [UInt8] {
        guard updates.count > 1 else { return updates.first ?? [] }
        let scratch = YDocument()
        scratch.transactSync { [logger] txn in
            for u in updates {
                do { try txn.transactionApplyUpdate(update: u) } catch {
                    logger.warn("mergeUpdates: failed to apply queued update:", error.localizedDescription)
                }
            }
        }
        return scratch.transactSync { txn in
            txn.transactionEncodeStateAsUpdate()
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

    /// Whether this document claimed a local copy when it was opened, decided
    /// from its stored metadata rather than from the persistence provider the
    /// open itself attaches. Combined with an empty ydoc this is the "claims
    /// local data but has none" signal that JS's stale-persistence recovery
    /// keys off (#2664, C14).
    public func claimedLocalCopyAtOpen(_ documentId: String) -> Bool {
        lock.withLock { localCopyClaimedAtOpen.contains(documentId) }
    }

    /// Record whether this document's metadata claims locally stored data:
    /// bytes were written for it, or it is a local-only document. Called by
    /// `openDocument` once the stored metadata is loaded.
    private func recordLocalCopyClaim(_ documentId: String) {
        lock.withLock {
            let meta = metadataIndex[documentId]
            let claims = (meta?.localBytes ?? 0) > 0 || meta?.localOnly == true
            if claims {
                localCopyClaimedAtOpen.insert(documentId)
            } else {
                localCopyClaimedAtOpen.remove(documentId)
            }
        }
    }

    /// Mark a document as no longer in sync with the server and tell
    /// subscribers. Mirrors JS `_updateSynced(documentId, false)` — used by the
    /// sync watchdog when a `syncStep1` gets no answer (#2664, C7).
    public func markUnsynced(_ documentId: String) {
        let changed: Bool = lock.withLock {
            guard docSyncStates[documentId] != false else { return false }
            docSyncStates[documentId] = false
            return true
        }
        guard changed else { return }
        emitter?.emit(SyncEvent(documentId: documentId, synced: false))
    }

    /// Discard a document's local Yjs persistence and reset its sync state, so
    /// the next `syncStep1` carries an empty state vector and the server sends
    /// the full document. Mirrors JS `resetYjsPersistenceAndResync`'s first
    /// half; the caller sends the follow-up `syncStep1` (#2664, C14).
    ///
    /// The open `YDocument` is deliberately left in place: this only runs when
    /// the ydoc has already been observed empty, so there is nothing to clear,
    /// and callers hold references to that instance.
    public func resetLocalPersistence(documentId: String) async {
        cancelPendingPersist(documentId: documentId)
        let persistence: YjsSQLitePersistence? = lock.withLock {
            docSyncStates[documentId] = false
            return docPersistence.removeValue(forKey: documentId)
        }
        if let persistence {
            do {
                try await persistence.deleteDocument()
            } catch {
                logger.warn(
                    "Failed to clear stale local persistence for doc:",
                    documentId, error.localizedDescription
                )
            }
        }
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

    /// Encode a `LocalMetadataEntry` to a `[String: JSONValue]` for event
    /// payloads (the typed `DocumentMetadataChangedEvent.metadata` field).
    private func metadataDictionary(_ entry: LocalMetadataEntry) -> [String: JSONValue]? {
        (try? JSONValue(encoding: entry))?.objectValue
    }

    /// Apply a server document listing to the local metadata index.
    ///
    /// `authoritative: true` makes the listing a replacement rather than a
    /// merge: local entries the server did not list are evicted and a
    /// `deleted` event is emitted for each. That is how a document whose
    /// access was revoked while this client was offline finally leaves the
    /// device — the revoke `docMetadata` frame was never delivered, so the
    /// reconnect listing is the only signal. Pending creates and local-only
    /// documents are exempt: the server has never heard of them, so their
    /// absence from the listing means nothing. Mirrors js-bao's
    /// `upsertServerDocuments(..., { authoritative })`
    /// (`src/client/internal/documentManager.ts`).
    public func handleServerDocuments(
        _ documents: [[String: Any]],
        authoritative: Bool = false
    ) async {
        var seenIds: Set<String> = []
        let nowIso = ISO8601DateFormatter().string(from: Date())

        for docData in documents {
            guard let documentId = docData["documentId"] as? String else { continue }
            seenIds.insert(documentId)

            var entry = getLocalMetadata(documentId) ?? LocalMetadataEntry(documentId: documentId)
            if let title = docData["title"] as? String { entry.title = title }
            if let perm = docData["permission"] as? String { entry.permission = perm }
            if let createdBy = docData["createdBy"] as? String { entry.createdBy = createdBy }
            if let createdAt = docData["createdAt"] as? String { entry.createdAt = createdAt }
            if let modifiedAt = docData["modifiedAt"] as? String { entry.modifiedAt = modifiedAt }
            if let tags = docData["tags"] as? [String] { entry.tags = tags }
            // A key the server sends as null is a *clear*, not "unchanged" —
            // js-bao's `{...existing, ...incoming}` merge overwrites with the
            // null. Assigning only on a `String` would keep a thumbnail alive
            // locally forever after another client removed it.
            if let thumbnailBlobId = docData["thumbnailBlobId"] {
                entry.thumbnailBlobId = thumbnailBlobId as? String
            }
            if let grantedAt = docData["grantedAt"] { entry.grantedAt = grantedAt as? String }
            if let lastModified = docData["lastModified"] as? String {
                entry.lastSyncedAt = lastModified
            }
            entry.metadataSyncedAt = nowIso

            if let permStr = docData["permission"] as? String {
                entry.lastKnownPermission = permStr
                entry.permissionCachedAt = nowIso
            }

            setMetadata(documentId, entry: entry)
            // The doc is present again; a prior delete no longer suppresses a
            // future one.
            lock.withLock { _ = deletedMetadataIds.remove(documentId) }

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

        guard authoritative else { return }

        let candidates: [String] = lock.withLock {
            metadataIndex.keys.filter { documentId in
                if seenIds.contains(documentId) { return false }
                if pendingCreates.contains(documentId) { return false }
                if localOnlyDocs.contains(documentId) { return false }
                if metadataIndex[documentId]?.localOnly == true { return false }
                if metadataIndex[documentId]?.pendingCreate == true { return false }
                return true
            }
        }

        for documentId in candidates {
            await evictLocalData(documentId: documentId)
            let alreadyDeleted = lock.withLock { !deletedMetadataIds.insert(documentId).inserted }
            if alreadyDeleted { continue }
            emitter?.emit(DocumentMetadataChangedEvent(
                documentId: documentId,
                action: "deleted",
                metadata: nil,
                changedFields: ["deleted"],
                source: "server"
            ))
        }
    }

    /// Apply a server-pushed `docMetadata` frame to local state.
    ///
    /// Mirrors js-bao's `applyDocumentMetadataUpdate`
    /// (`src/client/internal/documentManager.ts`) plus the derived permission
    /// apply its caller performs (`JsBaoClient.ts:handleDocumentMetadataUpdate`):
    ///
    /// - a frame carrying metadata merges into the cache, is persisted, and is
    ///   stamped with `metadataSyncedAt` (when this client refreshed) and
    ///   `lastSyncedAt` (the frame's `lastModified`);
    /// - `metadata == nil` is a local delete — cache row and persisted row go,
    ///   and a `deleted` event is emitted once;
    /// - a `permission` on the frame updates the document's permission state,
    ///   so `isReadOnly` flips mid-session;
    /// - a server `created` for a document already cached is emitted as
    ///   `updated`, so the creating client does not see two `created` events.
    public func applyDocumentMetadataUpdate(
        documentId: String,
        metadata: [String: JSONValue]?,
        changedFields: [String]? = nil,
        action: String? = nil,
        source: String = "server"
    ) async {
        guard !documentId.isEmpty else { return }

        guard let metadata = metadata else {
            // metadata: null — the document was deleted or access was revoked.
            await evictLocalData(documentId: documentId)
            let alreadyDeleted = lock.withLock { !deletedMetadataIds.insert(documentId).inserted }
            if alreadyDeleted { return }
            emitter?.emit(DocumentMetadataChangedEvent(
                documentId: documentId,
                action: action ?? "deleted",
                metadata: nil,
                changedFields: changedFields,
                source: source
            ))
            return
        }

        let existing = getLocalMetadata(documentId)
        var next = existing ?? LocalMetadataEntry(documentId: documentId)

        // Present key → assign; present-but-null → clear. That is what js-bao's
        // `{...existing, ...incoming}` merge does, and it is the difference
        // between a cleared thumbnail disappearing locally and surviving every
        // later sync. An absent key leaves the cached value alone.
        if let title = metadata["title"] { next.title = title.stringValue }
        if let createdBy = metadata["createdBy"] { next.createdBy = createdBy.stringValue }
        if let createdAt = metadata["createdAt"] { next.createdAt = createdAt.stringValue }
        if let modifiedAt = metadata["modifiedAt"] { next.modifiedAt = modifiedAt.stringValue }
        if let thumbnailBlobId = metadata["thumbnailBlobId"] {
            next.thumbnailBlobId = thumbnailBlobId.stringValue
        }
        if let grantedAt = metadata["grantedAt"] { next.grantedAt = grantedAt.stringValue }
        if let createCommittedAt = metadata["createCommittedAt"] {
            next.createCommittedAt = createCommittedAt.stringValue
        }
        if let tags = metadata["tags"] {
            next.tags = tags.arrayValue?.compactMap { $0.stringValue }
        }
        // The server's opaque per-document blob is cached under `docMetadata`
        // so it cannot collide with the envelope's own fields — same split JS
        // makes.
        if let docMetadata = metadata["metadata"] { next.docMetadata = docMetadata }

        let nowIso = ISO8601DateFormatter().string(from: Date())
        if source == "server" {
            next.metadataSyncedAt = nowIso
            if let lastModified = metadata["lastModified"]?.stringValue {
                next.lastSyncedAt = lastModified
            }
        }

        let permissionString = metadata["permission"]?.stringValue
        if let permissionString = permissionString {
            next.permission = permissionString
            next.lastKnownPermission = permissionString
            next.permissionCachedAt = nowIso
        }

        setMetadata(documentId, entry: next)
        lock.withLock { _ = deletedMetadataIds.remove(documentId) }
        try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: next)

        // A server `created` for a document we already knew about is an
        // update; emitting `created` twice would make listeners double-insert.
        let effectiveAction = (action == "created" && existing != nil) ? "updated" : (action ?? "updated")

        emitter?.emit(DocumentMetadataChangedEvent(
            documentId: documentId,
            action: effectiveAction,
            metadata: metadataDictionary(next),
            changedFields: changedFields ?? Array(metadata.keys),
            source: source
        ))

        // Derived permission change: this is what flips `isReadOnly` for an
        // open document when another session downgrades access mid-session.
        if let permissionString = permissionString,
           let permission = DocumentPermission(rawValue: permissionString),
           getPermission(documentId) != permission {
            setPermission(documentId, permission: permission)
        }
    }

    // MARK: - Pending Creates

    public func isPendingCreate(_ documentId: String) -> Bool {
        lock.withLock { pendingCreates.contains(documentId) }
    }

    /// Local-only is a property of the document, not of the session that
    /// created it: `localOnlyDocs` holds the ones created here, and the
    /// metadata row carries the flag across a reload. `hasLocalCopy` reads both
    /// for the same reason — a metadata row restored before
    /// `loadLocalMetadata` refills the set (e.g. `setMetadata` from a listing
    /// merge) would otherwise look like an ordinary document.
    public func isLocalOnly(_ documentId: String) -> Bool {
        lock.withLock {
            localOnlyDocs.contains(documentId) || metadataIndex[documentId]?.localOnly == true
        }
    }

    /// Whether this document was opened before anything could say what it is.
    ///
    /// `isLocalOnly` answers false for such a document, but only because
    /// nothing has been read yet — so the outbound flush holds its batch
    /// instead of sending it. Resolved (for every document at once) when
    /// startup metadata has loaded, or when the storage bind has finished
    /// without one.
    public func isLocalOnlyClassificationPending(_ documentId: String) -> Bool {
        lock.withLock { localOnlyClassificationPending.contains(documentId) }
    }

    /// Test seam for the state above: opening a document before the storage
    /// provider binds is a startup race, and pinning the hold it produces is
    /// worth more than reproducing the race.
    func markLocalOnlyClassificationPendingForTest(_ documentId: String) {
        lock.withLock { _ = localOnlyClassificationPending.insert(documentId) }
    }

    /// Declare every held classification resolved, returning the documents that
    /// were waiting — their held batches are the ones to flush now.
    @discardableResult
    public func resolveLocalOnlyClassifications() -> [String] {
        lock.withLock {
            let waiting = Array(localOnlyClassificationPending)
            localOnlyClassificationPending.removeAll()
            return waiting
        }
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
            // This is the start of an open cycle too — the created doc goes
            // straight into `openDocs`, so a later `openDocument` takes the
            // fast path and never reaches `_openDocumentImpl`'s reset.
            serverLoadedEmitted.remove(documentId)
            metadataIndex[documentId] = metadata
            deletedMetadataIds.remove(documentId)
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

    /// js-bao's `applyPostCommitPolicy`: run once a `pendingCreate` document
    /// exists server-side.
    ///
    /// An `immediate` document releases the claim held by the syncStep1 that
    /// went out before the commit (it can never be answered — the server had
    /// no such document) and re-syncs, so the 350ms availability-retry loop
    /// resumes at once instead of waiting out the 10s staleness window.
    /// A `manual` document — opened with `deferNetworkSync` or
    /// `enableNetworkSync: false` — is left untouched: the caller owns its
    /// sync timing, and an unrequested syncStep1 here would pull server state
    /// into a ydoc at a moment the caller did not choose (#2475).
    private func applyPostCommitPolicy(_ documentId: String) {
        guard startNetworkMode(documentId) == .immediate else { return }
        lock.withLock { _ = pendingSyncOperations.removeValue(forKey: documentId) }
        onPendingCreateCommitted?(documentId)
    }

    // MARK: - Server-pushed document lifecycle frames (#2661)

    /// Apply the sync state carried by an `availability` frame. Mirrors js-bao's
    /// `documentManager.applySyncState`: a `manual` document that the server
    /// reports as synced is left alone (the caller owns its sync timing), and
    /// everything else takes the server's word and emits `.sync`, which is what
    /// an open parked on the network is waiting for.
    public func applyAvailabilitySyncState(_ documentId: String, synced: Bool) {
        if synced, startNetworkMode(documentId) == .manual { return }
        lock.withLock { docSyncStates[documentId] = synced }
        emitter?.emit(SyncEvent(documentId: documentId, synced: synced))
    }

    /// Apply the metadata blob an `availability` frame carries. The typed
    /// fields the local entry actually models are merged into the index; the
    /// whole blob goes out on `.documentMetadataChanged`, the same event
    /// Swift's `docMetadata` frame emits.
    public func applyServerMetadata(
        _ documentId: String,
        metadata: [String: JSONValue],
        action: String?,
        changedFields: [String]?
    ) {
        let merged: LocalMetadataEntry = lock.withLock {
            var entry = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
            if let title = metadata["title"]?.stringValue { entry.title = title }
            if let permission = metadata["permission"]?.stringValue { entry.permission = permission }
            if let createdBy = metadata["createdBy"]?.stringValue { entry.createdBy = createdBy }
            if let createdAt = metadata["createdAt"]?.stringValue { entry.createdAt = createdAt }
            if let modifiedAt = metadata["modifiedAt"]?.stringValue { entry.modifiedAt = modifiedAt }
            if let tags = metadata["tags"]?.arrayValue {
                entry.tags = tags.compactMap { $0.stringValue }
            }
            metadataIndex[documentId] = entry
            return entry
        }
        persistMetadata(merged)

        emitter?.emit(DocumentMetadataChangedEvent(
            documentId: documentId,
            action: action ?? "updated",
            metadata: metadata,
            changedFields: changedFields ?? Array(metadata.keys),
            source: "server"
        ))
    }

    /// A `pendingCreateCommitted` frame: the server confirmed a document this
    /// client created offline. Mirrors js-bao's `handlePendingCreateCommitted`
    /// — stop the retry loop, clear the flag, stamp the commit time, tell
    /// subscribers, and run the post-commit policy.
    public func handlePendingCreateCommitted(_ documentId: String) {
        guard !documentId.isEmpty else { return }

        let committed: LocalMetadataEntry = lock.withLock {
            pendingCreateRetryTimers[documentId]?.cancel()
            pendingCreateRetryTimers.removeValue(forKey: documentId)
            pendingCreates.remove(documentId)

            var entry = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
            entry.pendingCreate = false
            entry.createCommittedAt = ISO8601DateFormatter().string(from: Date())
            entry.commitError = nil
            entry.commitRetryCount = nil
            entry.nextCommitAttemptAt = nil
            metadataIndex[documentId] = entry
            return entry
        }
        persistMetadata(committed)

        emitter?.emit(DocumentMetadataChangedEvent(
            documentId: documentId,
            action: "updated",
            metadata: metadataDictionary(committed),
            changedFields: ["pendingCreate"],
            source: "server"
        ))
        emitter?.emit(PendingCreateCommittedEvent(documentId: documentId))

        applyPostCommitPolicy(documentId)
    }

    /// A `pendingCreateFailed` frame: the server refused the create. Mirrors
    /// js-bao's `handlePendingCreateFailed` — the document stays pending and
    /// carries the reason, so the app can surface it and the retry path still
    /// owns the document.
    public func handlePendingCreateFailed(_ documentId: String, reason: String?) {
        guard !documentId.isEmpty else { return }
        let message = reason ?? "unknown"

        let failedEntry: LocalMetadataEntry = lock.withLock {
            pendingCreates.insert(documentId)
            var entry = metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
            entry.pendingCreate = true
            entry.commitError = CommitError(
                message: message,
                at: ISO8601DateFormatter().string(from: Date())
            )
            metadataIndex[documentId] = entry
            return entry
        }
        persistMetadata(failedEntry)

        emitter?.emit(DocumentMetadataChangedEvent(
            documentId: documentId,
            action: "updated",
            metadata: metadataDictionary(failedEntry),
            changedFields: ["pendingCreate", "commitError"],
            source: "server"
        ))
        emitter?.emit(PendingCreateFailedEvent(documentId: documentId, error: message))
    }

    /// Write an already-updated entry through to the offline store. Fire and
    /// forget: the in-memory index is the read path, and a storage failure must
    /// not hold up the event that told the app what changed.
    private func persistMetadata(_ entry: LocalMetadataEntry) {
        guard offlineStore != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.offlineStore?.putMetadata(
                appId: self.appId, userId: self.userId, record: entry
            )
        }
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
            applyPostCommitPolicy(documentId)

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
                applyPostCommitPolicy(documentId)
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
                        backoff.max * 1000,
                        backoff.base * 1000 * pow(backoff.factor, Double(attempt))
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
            // The document leaves `openDocs`, so its open cycle is over.
            serverLoadedEmitted.remove(documentId)
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
        state: [String: JSONValue]
    ) -> (previousState: [String: JSONValue]?, exists: Bool) {
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
            } else if let rawDict = rawState as? [String: Any],
                      let state = try? JSONValue.typedRow(from: rawDict, subject: "Awareness state") {
                let previous = entry.remoteStates[clientId]
                entry.remoteStates[clientId] = state
                if previous == nil {
                    delta.added.append(clientId)
                } else if previous! != state {
                    // A re-sent identical state is a no-op, matching the
                    // JS awareness layer — don't report it in `updated`.
                    // `JSONValue` is `Equatable` (#2367), so this is a plain
                    // value comparison rather than the previous
                    // `NSDictionary.isEqual(to:)` bridge.
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

    /// Drop every remote awareness state for a document and return the client
    /// IDs that were dropped. The local state is kept — it is this client's
    /// own presence, which it re-broadcasts on reconnect. Mirrors JS
    /// `documentManager.clearRemoteAwareness`.
    @discardableResult
    public func clearRemoteAwareness(_ documentId: String) -> [String] {
        lock.withLock {
            guard var entry = docAwareness[documentId] else { return [] }
            let removed = Array(entry.remoteStates.keys)
            entry.remoteStates.removeAll()
            docAwareness[documentId] = entry
            return removed
        }
    }

    /// Every document that has an awareness entry. Mirrors JS
    /// `documentManager.listAwarenessDocIds`.
    public func listAwarenessDocIds() -> [String] {
        lock.withLock { Array(docAwareness.keys) }
    }

    // MARK: - Local Data Management

    /// The `retainLocal` decision recorded when the document was opened, or
    /// `nil` when it is not open. `false` means the close will evict.
    func retainLocalSetting(_ documentId: String) -> Bool? {
        lock.withLock { retainLocalByDoc[documentId] }
    }

    /// Downgrade a `retainLocal: false` open back to "keep the local data",
    /// used when the server has not confirmed the document's writes: an
    /// eviction there would drop the only remaining copy of an edit.
    func preserveLocalOnClose(_ documentId: String) {
        lock.withLock {
            if retainLocalByDoc[documentId] != nil {
                retainLocalByDoc[documentId] = true
            }
        }
    }

    /// `true` when the document has real local data behind it.
    ///
    /// Mirrors js-bao's `hasLocalCopy` (`src/client/internal/documentManager.ts`):
    /// persistence wired up, a pending local create, a local-only document, an
    /// open document holding data, or recorded `localBytes`. A metadata row on
    /// its own is not a local copy — before #2668 every document that had ever
    /// appeared in a server listing reported `true` with zero CRDT bytes on
    /// disk.
    public func hasLocalCopy(_ documentId: String) -> Bool {
        let (hasPersistence, isPending, isLocalOnly, isOpen, localBytes) = lock.withLock {
            (
                docPersistence[documentId] != nil,
                pendingCreates.contains(documentId),
                localOnlyDocs.contains(documentId) || metadataIndex[documentId]?.localOnly == true,
                openDocs[documentId] != nil,
                metadataIndex[documentId]?.localBytes
            )
        }
        if hasPersistence || isPending || isLocalOnly { return true }
        if isOpen && ydocHasData(documentId) { return true }
        if let localBytes, localBytes > 0 { return true }
        return false
    }

    /// Evict one document's local data: the metadata row, the in-memory
    /// bookkeeping, and — since #2668 — the persisted CRDT snapshot in
    /// `yjs_docs`. Leaving that row behind meant an evicted document rehydrated
    /// its old content on the next open, and `maxBytes` enforcement reduced the
    /// accounted total without reclaiming any disk.
    public func evictLocalData(documentId: String) async {
        cancelPendingPersist(documentId: documentId)
        let persistence: YjsSQLitePersistence? = lock.withLock {
            metadataIndex.removeValue(forKey: documentId)
            // Clear pending-create state too, so `hasLocalCopy` doesn't keep
            // reporting an evicted document (js-bao does the same on its evict
            // paths).
            pendingCreates.remove(documentId)
            // Eviction drops the metadata row the local-only flag also lives
            // in, but an evicted document that is still open is still editable
            // — and its edits must still stay off the wire (#2691). Keep the
            // marker until it is closed; for a document that is not open there
            // is nothing left to filter.
            if openDocs[documentId] == nil {
                localOnlyDocs.remove(documentId)
            }
            pendingCreateRetryTimers.removeValue(forKey: documentId)?.cancel()
            // A document evicted while still open must not write itself back on
            // the next edit or at close. Cleared when it is reopened.
            if openDocs[documentId] != nil {
                persistenceSuspended.insert(documentId)
            }
            return docPersistence.removeValue(forKey: documentId)
        }

        // A document that was never opened in this session has no
        // `docPersistence` entry — build one so the row is still deleted.
        let target: YjsSQLitePersistence?
        if let persistence {
            target = persistence
        } else if let provider = await offlineStore?.getStorageProvider() {
            target = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        } else {
            target = nil
        }

        if let target {
            do {
                try await target.deleteDocument()
            } catch {
                logger.warn(
                    "evictLocalData: deleting the persisted document failed for", documentId,
                    error.localizedDescription
                )
            }
        }

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func evictAllLocalData() async {
        lock.withLock {
            // Every document the app may still be holding a `YDocument` for:
            // one that is open, and one whose update observer is still
            // attached. Read before `openDocs` is cleared below.
            let stillHeld = Set(openDocs.keys).union(updateSubscriptions.keys)
            metadataIndex.removeAll()
            docPersistence.removeAll()
            openDocs.removeAll()
            docSyncStates.removeAll()
            pendingSyncOperations.removeAll()
            // A mode entry exists exactly while its document is in `openDocs`
            // (written under the `pendingOpens` claim in `openDocument`,
            // removed in `closeDocument`). Clearing `openDocs` here without
            // clearing this map would leave a stale `.manual` behind: a later
            // `createLocalDocument` for the same id does not write the map, so
            // `applyPostCommitPolicy` would read the dead entry and skip the
            // post-commit re-sync.
            startNetworkModeByDoc.removeAll()
            // Same invariant as the map above: an entry exists only while its
            // document is open. A flag left behind here would suppress the
            // `documentLoaded` of the next open cycle for that id.
            serverLoadedEmitted.removeAll()
            localCopyClaimedAtOpen.removeAll()
            unconfirmedLocalWrites.removeAll()
            docPermissions.removeAll()
            pendingCreates.removeAll()
            // `openDocs` is cleared above, but nothing here closes the
            // documents or cancels their update observers: a `YDocument` the
            // app still holds keeps forwarding its edits to
            // `queueOutboundUpdate`. Keep the local-only marker of every
            // document that was still held — with the metadata index gone too,
            // dropping it would turn a still-edited local-only document into
            // an ordinary outbound one (#2691). Same rule as the per-document
            // evict above.
            localOnlyDocs.formIntersection(stillHeld)
            deletedMetadataIds.removeAll()
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
    /// Every eviction is forced: JS calls `evictLocalDocument(id, { force: true })`
    /// for all three limits, so open and pending-create documents are evicted
    /// alongside closed ones. Before #2668 Swift exempted them, which let one
    /// long-lived open document hold the local store over its byte budget
    /// indefinitely. Order of enforcement matches JS: TTL first, then maxDocs,
    /// then maxBytes.
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
        let entries = lock.withLock { Array(metadataIndex.values) }

        // TTL: evict any doc whose lastOpenedAt is older than ttlMs.
        if let ttlMs {
            for meta in entries {
                guard let lastOpenedAt = meta.lastOpenedAt,
                      let date = formatter.date(from: lastOpenedAt) else { continue }
                let ageMs = nowMs - (date.timeIntervalSince1970 * 1000)
                if ageMs > Double(ttlMs) {
                    await evictLocalData(documentId: meta.documentId)
                }
            }
        }

        // Re-snapshot after TTL pass; we may have evicted some entries.
        var evictable = lock.withLock { Array(metadataIndex.values) }

        // Sort oldest-first by lastOpenedAt; treat missing as epoch.
        evictable.sort { a, b in
            let aTs = a.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
            let bTs = b.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
            return aTs < bTs
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
            var after = lock.withLock { Array(metadataIndex.values) }
            after.sort { a, b in
                let aTs = a.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
                let bTs = b.lastOpenedAt.flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
                return aTs < bTs
            }
            var total = after.reduce(0) { $0 + ($1.localBytes ?? 0) }
            for meta in after {
                if total <= maxBytes { break }
                await evictLocalData(documentId: meta.documentId)
                total -= (meta.localBytes ?? 0)
            }
        }
    }

    // MARK: - Document Hash

    /// SHA-256 hex digest over the document's full encoded state - the
    /// server's `calculateDocHash` algorithm (`sha256(Y.encodeStateAsUpdate(doc))`,
    /// lowercase hex), and what JS `getDocHash` sends in syncStep1. Distinct
    /// from `getDocHash(documentId:)` below, which predates this and returns
    /// the base64 state vector (kept for its existing public-API callers).
    public func getContentDocHash(documentId: String) -> String? {
        guard let doc = lock.withLock({ openDocs[documentId] }) else { return nil }
        let update: [UInt8] = doc.transactSync { txn in
            txn.transactionEncodeStateAsUpdate()
        }
        return hashSHA256(Data(update)).map { String(format: "%02x", $0) }.joined()
    }

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
    /// `docSyncStates` does not reset on a later *edit* (only on a transport
    /// change — see `applySyncState`), so it alone can't protect a just-made
    /// edit from eviction. It was originally needed because `docSyncStates`
    /// stuck at `true` through a disconnect as well; #2663 fixed that half.
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
        let (doc, suspended) = lock.withLock {
            (openDocs[documentId], persistenceSuspended.contains(documentId))
        }
        guard let doc else { return }
        // Evicted while open: keep the local store clear until the document is
        // reopened, so a retention eviction is not undone by the next persist.
        if suspended {
            logger.debug(
                "persistDocumentToLocal: skipped for evicted open document", documentId
            )
            return
        }

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
            // Every document the app may still be holding a `YDocument` for:
            // this reset closes nothing and cancels no update observer, so a
            // retained local-only document keeps forwarding its edits to
            // `queueOutboundUpdate` — and with the metadata index cleared below,
            // dropping its marker would turn it into an ordinary outbound one
            // over the newly authenticated socket (#2691). Same rule as the
            // bulk evict, and as JS's identity-change handling
            // (`clearLocalOnlyMarkers`).
            let stillHeld = Set(openDocs.keys).union(updateSubscriptions.keys)
            metadataIndex.removeAll()
            pendingCreates.removeAll()
            unconfirmedLocalWrites.removeAll()
            localOnlyDocs.formIntersection(stillHeld)
            deletedMetadataIds.removeAll()
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
