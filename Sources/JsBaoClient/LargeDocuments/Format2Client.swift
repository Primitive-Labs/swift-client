import Foundation
import YSwift

/// The client's format-2 state, built on first use (#3436).
///
/// A client that never opens a large document never builds any of this — no
/// coordinator, no client id, no record store, no table in its database. That
/// is what makes "an ordinary document is untouched" a property of
/// construction rather than of review.
final class Format2ClientState: @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var _clientId: String?
    private var _coordinator: Format2Coordinator?

    /// The identity this client's pending ops are recorded under: a ULID
    /// minted lazily once per `JsBaoClient` instance, and NEVER persisted
    /// (#3431).
    ///
    /// Lazily, not at construction: minting reads a clock and the random
    /// source, and the client is constructed on paths that must not do either
    /// — #3431 lost a dev server to exactly that, a field initializer that ran
    /// when the module loaded.
    ///
    /// Not persisted, because a relaunch is a different client. Reusing the
    /// previous session's id would claim sequences the server already
    /// acknowledged for a connection that is gone; a fresh one makes the
    /// previous session's unacknowledged ops visibly somebody else's, which is
    /// what makes them adoptable at all.
    var clientId: String {
        lock.withLock {
            if let _clientId { return _clientId }
            let minted = ULID.generate()
            _clientId = minted
            return minted
        }
    }

    /// The coordinator, or `nil` while this client has never opened a large
    /// document.
    var coordinator: Format2Coordinator? { lock.withLock { _coordinator } }

    /// The coordinator, building it over `host` on first use.
    func coordinator(
        host: any Format2SqlHost,
        logger: Logger?,
        onFoldBroken: (@Sendable (String, JsBaoError) -> Void)? = nil,
        onSnapshotLoad: (@Sendable (DocumentSnapshotLoadEvent) -> Void)? = nil,
        onWriteRefused: (@Sendable (DocumentWriteRefusedEvent) -> Void)? = nil,
        onOfflineWritesResolved:
            (@Sendable (DocumentOfflineWritesResolvedEvent) -> Void)? = nil
    ) -> Format2Coordinator {
        lock.withLock {
            if let _coordinator { return _coordinator }
            let built = Format2Coordinator(host: host, clientId: clientId, logger: logger)
            built.onFoldBroken = onFoldBroken
            built.onSnapshotLoad = onSnapshotLoad
            built.onWriteRefused = onWriteRefused
            built.onOfflineWritesResolved = onOfflineWritesResolved
            _coordinator = built
            return built
        }
    }

    // MARK: - Judging a deferred replay after a restart (#3437, behavior 20a)

    /// Documents whose conflict ledger is being re-read off the sealed chain.
    private var _rebuildingLedger: Set<String> = []
    /// Documents whose joined epoch has already finished syncing while that
    /// read was still running.
    private var _syncedWhileRebuilding: Set<String> = []

    /// Claim the ledger rebuild for this document. `false` when one is already
    /// running, and the caller starts nothing.
    func beginLedgerRebuild(_ documentId: String) -> Bool {
        lock.withLock {
            _syncedWhileRebuilding.remove(documentId)
            return _rebuildingLedger.insert(documentId).inserted
        }
    }

    /// The evidence is ready.
    ///
    /// - Returns: whether the joined epoch's `syncComplete` arrived while it
    ///   was being read — in which case the caller judges now, because nothing
    ///   else will come to.
    func finishLedgerRebuild(_ documentId: String) -> Bool {
        lock.withLock {
            _rebuildingLedger.remove(documentId)
            return _syncedWhileRebuilding.remove(documentId) != nil
        }
    }

    /// The joined epoch has synced.
    ///
    /// - Returns: whether the judgement may run now. `false` while the chain
    ///   it would be judged against is still being read: judging without it
    ///   would call every owed write unverifiable and keep writes newer online
    ///   state should have dropped.
    func noteSyncedForDeferredReplay(_ documentId: String) -> Bool {
        lock.withLock {
            guard _rebuildingLedger.contains(documentId) else { return true }
            _syncedWhileRebuilding.insert(documentId)
            return false
        }
    }

    func forgetDeferredReplayGate(_ documentId: String) {
        lock.withLock {
            _rebuildingLedger.remove(documentId)
            _syncedWhileRebuilding.remove(documentId)
        }
    }

    /// Forget everything — the account this state belongs to is gone.
    func reset() {
        lock.withLock {
            _coordinator = nil
            _clientId = nil
            _rebuildingLedger.removeAll()
            _syncedWhileRebuilding.removeAll()
        }
    }
}

// MARK: - The client's large-document front door

extension JsBaoClient {

    /// The large documents this client has open, or `nil` when it has never
    /// opened one.
    var format2: Format2Coordinator? { format2State.coordinator }

    /// Whether `documentId` is a large document as far as this client is
    /// concerned. The one question every format-1 path asks, and the answer is
    /// `false` for every document until something binds one.
    func isLargeDocument(_ documentId: String) -> Bool {
        format2State.coordinator?.isLargeDocument(documentId) ?? false
    }

    /// Resolve `documentId`'s format before anything about it reaches the
    /// wire (behaviors 3, 14 and 16).
    ///
    /// Two decisions, in this order, and the order is the point:
    ///
    /// 1. **The socket's receive limit.** Raised for any document NOT locally
    ///    known to be format 1. It cannot wait for the format to be learned,
    ///    because the frame that carries the answer — `epoch.info`, which
    ///    grows with the sealed chain — is the very frame the limit protects,
    ///    and `URLSessionWebSocketTask` fails the RECEIVE rather than the
    ///    handler on an oversized message. A client that waited would be
    ///    refused the answer that would have told it (decision 3436-SO-07).
    /// 2. **The binding.** Only for a document the local row already calls
    ///    large. A first open has no row and binds when `epoch.info` says so.
    ///
    /// Called at the top of `openDocument`, so the storage refusal below is
    /// raised before a single frame goes out.
    func prepareDocumentFormat(_ documentId: String) async throws {
        let stored = documentManager.documentFormat(documentId)
        if Format2Transport.needsRaisedMessageSize(storedDocumentFormat: stored) {
            await wsManager.setMaximumMessageSize(Format2Transport.maximumMessageSize)
        }
        guard stored == Format2Transport.documentFormat else { return }
        // The capability, asked before the open rather than at the bind that
        // follows it — an app that configured storage which cannot hold a
        // large document is told so before a single frame goes out.
        _ = try await format2Host(documentId)
    }

    /// Settle this socket's receive limit BEFORE the socket exists.
    ///
    /// `URLSessionWebSocketTask` honours `maximumMessageSize` only on a task
    /// that has not been resumed, so a raise decided after the connect costs a
    /// rebuilt socket. Deciding it here — at every connect, and once storage
    /// has bound — means the ordinary client never pays that: by the time a
    /// document opens, the limit it would have asked for is already the one
    /// the live task was built with.
    ///
    /// The rule is decision 3436-SO-07's, applied to the whole client rather
    /// than to one document: raise unless EVERY document this client knows of
    /// is locally known to be format 1. A client with no local documents at
    /// all is not such a client — its next open has no row to resolve and will
    /// learn the format from `epoch.info`, the frame the limit protects.
    func ensureReceiveLimitForKnownDocuments() async {
        let known = documentManager.getMetadataIndex()
        let allOrdinary = !known.isEmpty && known.values.allSatisfy { $0.documentFormat == 1 }
        guard !allOrdinary else { return }
        await wsManager.setMaximumMessageSize(Format2Transport.maximumMessageSize)
    }

    /// The record-store host for this client's storage, or the typed refusal.
    private func format2Host(_ documentId: String) async throws -> any Format2SqlHost {
        guard let provider = await offlineStore.getStorageProvider() else {
            throw Format2Storage.unavailable(reason: .notPersistent, documentId: documentId)
        }
        return try Format2Storage.host(for: provider, documentId: documentId)
    }

    /// Bind a document the open has already resolved as large, over the Y.Doc
    /// the open produced. Called after the document exists, because for a
    /// large document that Y.Doc IS the current epoch's overlay.
    func bindLargeDocumentIfResolved(_ documentId: String, doc: YDocument) async throws {
        guard documentManager.documentFormat(documentId) == Format2Transport.documentFormat
        else { return }
        _ = try await bindLargeDocument(documentId, doc: doc)
    }

    /// Whether the hold kept `frame` for `documentId`. `false` — the ordinary
    /// answer, and every answer for an ordinary document — means the caller
    /// sends it.
    func holdKeeps(_ documentId: String, frame: String) -> Bool {
        guard let hold = format2State.coordinator?.hold,
              let reason = hold.reason(documentId)
        else { return false }
        hold.enqueue(documentId, frame: frame)
        logger.debug("[format2] holding a frame for", documentId, "—", reason)
        return true
    }

    /// Note that the update just enqueued for `documentId` carries every local
    /// sequence committed so far. A no-op for an ordinary document.
    func noteLocalUpdateForLargeDocument(_ documentId: String) {
        guard let coordinator = format2State.coordinator else { return }
        try? coordinator.noteLocalUpdate(documentId: documentId)
    }

    /// Bind `documentId` as a large document, building the coordinator if this
    /// is the first one.
    ///
    /// Throws `FORMAT2_STORAGE_UNAVAILABLE` when this client's storage cannot
    /// host one. The capability is a conformance, not a probe: a provider that
    /// keeps nothing on disk does not implement ``Format2SqlHost``, so the
    /// question is answered by the type system and cannot answer differently
    /// on the second call.
    @discardableResult
    func bindLargeDocument(
        _ documentId: String, doc: YDocument? = nil
    ) async throws -> Format2DocumentBinding {
        if let existing = format2State.coordinator?.binding(documentId) { return existing }
        let host = try await format2Host(documentId)
        let coordinator = format2State.coordinator(
            host: host, logger: logger,
            // #3436, decision 3436-SO-08 — a fold fails on the fold queue,
            // where no caller is waiting for it. Every read and write is
            // refused from then on, but `find` answers `nil` and `delete`
            // reports nothing (both non-throwing), which is exactly what an
            // absent record and a completed delete look like. The event is how
            // an application tells a broken local view from either.
            onFoldBroken: { [weak self] documentId, error in
                guard let self else { return }
                // `detail.code`, the shape every other connection error on this
                // client uses (`errorFrameDetail`), beside the cause the fold
                // failed with.
                var detail = error.details ?? [:]
                detail["code"] = .string(error.code.rawValue)
                self.eventEmitter.emit(ConnectionErrorEvent(
                    message: error.message,
                    documentId: documentId,
                    messageType: "fold",
                    detail: .object(detail)
                ))
            },
            // #3436, behavior 24 — a cold open streams the whole base before
            // the document can answer anything, so an application that shows
            // a spinner needs to know it is moving.
            onSnapshotLoad: { [weak self] event in
                self?.eventEmitter.emit(event)
            },
            // #3437, behavior 2a — `delete(id:)` and a `PrimitiveRecord` field
            // setter cannot throw, so past the offline window they refuse with
            // nowhere to say so. This is where an application finds out.
            onWriteRefused: { [weak self] event in
                self?.eventEmitter.emit(event)
            },
            // #3437, behavior 20 — what a returning client's offline writes
            // were judged to be. Silence means every one of them replayed
            // cleanly, so the event only ever carries notices.
            onOfflineWritesResolved: { [weak self] event in
                self?.eventEmitter.emit(event)
            }
        )
        // #3437, behavior 10 — for a LARGE document the open Y.Doc IS the
        // current epoch's overlay, so following a seal means replacing it.
        // The coordinator knows about overlays and epochs; the manager knows
        // about open documents and their persistence, and this is the seam.
        coordinator.replaceDocument = { [weak self] documentId, document in
            await self?.documentManager.replaceOpenDocument(
                documentId: documentId, with: document
            )
        }
        // And the updates still waiting in this client's outbound queue, which
        // a move has to drop (#3437, behavior 10). Every one of them is a Yjs
        // DELTA built on the overlay the room has just archived, so the room
        // cannot integrate it — it PARKS it, and from then on it answers every
        // later update from this connection with another resync request
        // instead of an acknowledgement. Measured live: a document whose
        // pre-seal delta reached the room after the seal never got another ack.
        // The carry puts that write's content on the fresh overlay afresh, so
        // dropping the delta loses nothing.
        coordinator.discardQueuedUpdates = { [weak self] documentId in
            self?.discardQueuedOutboundUpdates(documentId: documentId)
        }
        // How much room this app will give a large document (#3437,
        // behavior 34). Carried from the options as configured — including
        // `nil`, which is what makes a base load probe the volume the client's
        // own database is on.
        coordinator.storageOptions = largeDocumentStorageOptions
        guard let document = doc ?? documentManager.getDocument(documentId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(documentId)` is not open, so there is no overlay to bind."
            )
        }
        let binding = try coordinator.bind(
            documentId: documentId,
            models: registeredModelNames(),
            document: document
        )
        // The overlay this document opened with is not new to IT — a
        // relaunched client restores the epoch's overlay from disk, and a
        // document bound only when `epoch.info` arrived has already taken a
        // `syncStep2`. The observer sees changes from here on and knows
        // nothing about what is already there, so the bind folds the whole
        // overlay once. Idempotent: an overlay already folded produces the
        // rows it produced before.
        try binding.writePath.withOperation { try binding.observer.catchUp() }
        // Then the writes a PREVIOUS instance of this client left owed (#3437,
        // behaviors 4 and 6). Swift mints its client id per instance and never
        // persists it, so those rows are invisible to this one until they are
        // adopted — never carried, never replayed, never acknowledged (finding
        // 3437-R02). After the catch-up fold, because the classification's
        // merged-row rule reads rows the fold moves; before anything is sent,
        // because the first frame out claims the sequences it finds pending.
        do {
            let adoption = try binding.adoptAndRestore()
            if !adoption.adopted.isEmpty {
                logger.log(
                    "[format2] adopted", adoption.adopted.count,
                    "unacknowledged write(s) of a previous instance of", documentId,
                    "— restored:", adoption.restored.count,
                    "deferred:", adoption.deferred.count,
                    "unreproducible:", adoption.unreproducible.count
                )
            }
        } catch {
            // The document is still usable: the ops stay in `_pending_ops`,
            // and the next open adopts them. Reported rather than swallowed
            // (principle 8) — an adoption that silently did nothing is a write
            // the app was told was saved and that no machine will deliver.
            logger.warn(
                "[format2] the adoption pass for", documentId, "did not complete:",
                error.localizedDescription
            )
        }
        // And every model connected before the bind is still reading nested
        // Y.Maps, which a large document does not have.
        bindLargeDocumentToSharedModels(documentId, binding: binding)
        return binding
    }

    /// Handle an `epoch.info` frame: bind the document if nothing had yet said
    /// it was large, then let the coordinator decide what this client may do.
    func handleEpochInfoFrame(_ frame: [String: Any]) async {
        guard let documentId = frame["documentId"] as? String,
              !documentId.isEmpty,
              documentManager.isOpen(documentId)
        else {
            logger.debug(
                "[format2] epoch.info for a document that is not open, dropped:",
                frame["documentId"] as? String ?? "<none>"
            )
            return
        }
        do {
            _ = try await bindLargeDocument(documentId)
            // The room has now said what this document is, so the next open
            // binds before the handshake instead of learning it again.
            documentManager.noteDocumentFormat(documentId, Format2Transport.documentFormat)
            guard let coordinator = format2State.coordinator else { return }
            // The EVIDENCE a judgement this document owes from before the
            // restart will need (#3437, behavior 20a). Started here and
            // finished off this handler: it reads sealed archives, and this
            // handler is the socket's receive loop — a download run on it
            // stops every frame for every document on this connection,
            // including the `epoch.grants` answer the download's own grant
            // refresh is waiting for (finding 3437-REVIEW-009).
            //
            // The judgement itself waits for the joined epoch's `syncComplete`
            // exactly as a deferral made in this session does: the room sends
            // `epoch.info` BEFORE the `syncStep2` carrying that epoch's
            // content, so judging here would weigh the owed writes against an
            // overlay that is empty (finding 3437-REVIEW-002).
            prepareDeferredReplayIfOwed(
                documentId,
                sealed: Format2Coordinator.decodeSealedChain(frame["sealedEpochs"]),
                coordinator: coordinator
            )
            let outcome = try coordinator.handleEpochInfo(
                frame, now: Int(Date().timeIntervalSince1970 * 1000)
            )
            switch outcome.plan {
            case .join:
                // The hold released: everything it kept goes out, in order,
                // and the queue it was gating drains behind it — then the
                // writes this client still OWES, as one self-contained frame
                // claiming exactly the span above the durable acked mark
                // (#3437, behavior 7).
                //
                // Without that last one an adopted write is never
                // acknowledged. The room answers `syncStep1` ONCE per
                // connection, and adoption runs inside the bind — so the only
                // frame that could have claimed those sequences went out
                // before this instance owned them, and every later
                // `update.ack` names a CONTIGUOUS mark that stops at the gap
                // they leave. #3431 found exactly this on the JS client, live,
                // through a browser hand-run; on Swift it is the same shape
                // and the same fix.
                //
                // All three run on the document's outbound lane, in this
                // order, rather than on this handler: any of them can carry a
                // payload over `MAX_UPDATE_SIZE`, whose upload waits for a
                // reply that arrives as a frame on the loop this handler is
                // holding (#3559).
                runOffReceiveLoop(documentId) { client in
                    await client.sendReleasedFrames(outcome.released)
                    await client.flushOutboundUpdates(documentId: documentId)
                    await client.claimOwedWritesAfterJoin(
                        documentId, coordinator: coordinator
                    )
                }
            case .loadBase:
                guard let base = outcome.base else { return }
                startColdStartLoad(
                    documentId, base: base, reported: outcome.reported,
                    sealed: outcome.sealed, coordinator: coordinator
                )
            case .loadOverlays:
                // No base was ever built: the chain from the document's first
                // epoch IS the document, applied under the open overlay.
                startColdChain(
                    documentId, from: outcome.base?.epoch ?? 1,
                    to: outcome.reported, sealed: outcome.sealed,
                    coordinator: coordinator
                )
            case .catchUp:
                // Behind the room with an overlay of its own: apply the chain
                // between the two epochs, then move onto a fresh overlay
                // carrying what the server has not acknowledged (#3437,
                // behaviors 16 and 18).
                startCatchUp(
                    documentId, to: outcome.reported, sealed: outcome.sealed,
                    coordinator: coordinator
                )
            case .awaitBase:
                // A bulk load stands between everything readable and the room
                // (#3437, behaviors 29 and 31). When its base is already on
                // offer the rebuild runs now; otherwise the document waits,
                // held but answering, and the `snapshot.ready` that announces
                // the base is what starts it.
                //
                // Off this handler, like every other load: a rebuild is a
                // download of the whole document, and running it on the
                // socket's receive loop would stop every frame for every
                // document until it finished — including the `epoch.grants`
                // answer its own grant refresh waits for, which is a deadlock
                // rather than a delay (finding 3437-REVIEW-009).
                Task { [weak self] in
                    guard let self else { return }
                    await startRebuild(
                        documentId, reported: outcome.reported, sealed: outcome.sealed,
                        reason: .discontinuity, coordinator: coordinator
                    )
                }
            case .reloadRequired:
                // Stopped, not failed: reads keep answering from the local
                // merged view and nothing written locally has been lost. What
                // the application is owed is the reason — a document that
                // quietly stops accepting writes is the hardest kind of bug to
                // diagnose.
                reportReloadRequired(documentId, messageType: "epoch.info", coordinator: coordinator)
            case .dropped:
                break
            }
        } catch let error as JsBaoError {
            logger.warn("[format2] epoch.info could not be honoured for", documentId, error.code.rawValue)
            eventEmitter.emit(ConnectionErrorEvent(
                message: error.message,
                documentId: documentId,
                messageType: "epoch.info",
                detail: error.details.map { JSONValue.object($0) }
            ))
            failAwaitingOpen(documentId, error: error)
        } catch {
            logger.warn("[format2] epoch.info could not be honoured for", documentId, error.localizedDescription)
        }
    }

    /// After a join, state the writes this client still owes (#3437,
    /// behavior 7).
    ///
    /// One self-contained frame carrying the whole overlay and claiming
    /// `[ackedSeq + 1, highestLocalSeq]` — which is honest, because a
    /// whole-state update really does contain every local sequence above the
    /// durable acked mark. It is also what closes the hole a dropped or
    /// adopted sequence leaves: the server acknowledges a CONTIGUOUS run, so
    /// one unclaimed sequence stops every later acknowledgement behind it.
    ///
    /// A no-op for a document with nothing owed, which is the ordinary open.
    private func claimOwedWritesAfterJoin(
        _ documentId: String, coordinator: Format2Coordinator
    ) async {
        guard let binding = coordinator.binding(documentId) else { return }
        do {
            guard try !binding.store.pendingOps().isEmpty else { return }
        } catch {
            logger.warn(
                "[format2] could not read the owed writes of", documentId, "after its join:",
                error.localizedDescription
            )
            return
        }
        await answerResync(documentId, coordinator: coordinator)
    }

    /// Put the frames a released hold was keeping on the wire, in the order
    /// they were queued. Held means kept: the writes behind them are the
    /// user's.
    func sendReleasedFrames(_ frames: [String]) async {
        for frame in frames {
            do {
                try await wsManager.send(frame)
            } catch {
                logger.warn(
                    "[format2] a released frame could not be sent:",
                    error.localizedDescription
                )
            }
        }
    }

    /// Start the base load a cold start needs and RETURN, at once.
    ///
    /// Not awaited, and that is the whole point. `handleWebSocketMessage` is
    /// awaited by the socket's receive loop, which takes one complete frame
    /// before it asks for the next — so a load awaited from a frame handler
    /// stalls every frame for every document on this socket for the whole
    /// download. Including the `epoch.grants` reply the load itself waits for
    /// when a signature expires mid-stream: that reply arrives as a frame, on
    /// the loop the load would be blocking, so the one recovery the loader has
    /// could never complete.
    ///
    /// The attempt is claimed HERE rather than inside the load, so the
    /// supersession this handshake performs is settled before the task that
    /// runs it is even scheduled.
    private func startColdStartLoad(
        _ documentId: String,
        base: Format2Coordinator.BaseToLoad,
        reported: Int,
        sealed: [SealedEpochChainEntry],
        coordinator: Format2Coordinator
    ) {
        let attempt = coordinator.beginBaseLoad(documentId)
        Task { [weak self] in
            await self?.runColdStartLoad(
                documentId, base: base, reported: reported, sealed: sealed,
                coordinator: coordinator, attempt: attempt
            )
        }
    }

    /// Read one sealed epoch's archive, through the same one-grant-refresh rule
    /// a chunk is read by (#3437, behavior 15).
    private func sealedArchiveFetcher(
        _ documentId: String, coordinator: Format2Coordinator
    ) -> @Sendable (FastForwardStep) throws -> Data {
        { [weak self] step in
            guard let self else {
                throw JsBaoError(
                    code: .unavailable,
                    message: "The client went away while the sealed chain of "
                        + "`\(documentId)` was being read."
                )
            }
            let reader = Format2ArtifactReader(
                apiUrl: apiUrl,
                documentId: documentId,
                grantPath: step.downloadPath,
                logger: logger,
                read: Format2ArtifactReader.urlSessionReader(),
                refreshGrant: { [weak self] in
                    self?.requestFreshSealedGrant(
                        documentId, epoch: step.epoch, coordinator: coordinator
                    )
                }
            )
            return try reader.read(
                // Named by its PLACE: the path carries a signature and never
                // reaches a log line.
                what: "the sealed overlay of epoch \(step.epoch)"
            ).body
        }
    }

    /// The `epoch.grants` request, built in ONE place.
    ///
    /// Both the base's refresh and a sealed archive's send exactly this frame;
    /// two builders would be two chances for them to drift, and the untyped
    /// budget in `TransportSpineTests` counts the site for the same reason.
    static func epochGrantsFrame(_ documentId: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "type": "epoch.grants", "documentId": documentId,
        ]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Ask the room to re-mint the chain's signatures and wait for the one this
    /// read needs.
    ///
    /// The same shape as the base's refresh, against the chain's own record:
    /// `epoch.grants` answers with every sealed epoch's fresh path, and the
    /// coordinator notes them as they arrive.
    private func requestFreshSealedGrant(
        _ documentId: String, epoch: Int, coordinator: Format2Coordinator
    ) -> String? {
        let before = coordinator.sealedGrantPath(documentId, epoch: epoch)
        guard let text = Self.epochGrantsFrame(documentId) else { return before }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await wsManager.send(text)
            } catch {
                logger.warn(
                    "[format2] could not ask for fresh archive grants:",
                    error.localizedDescription
                )
            }
        }
        let deadline = Date().addingTimeInterval(Format2Transport.grantRefreshTimeout)
        while Date() < deadline {
            let fresh = coordinator.sealedGrantPath(documentId, epoch: epoch)
            if let fresh, fresh != before { return fresh }
            Thread.sleep(forTimeInterval: 0.05)
        }
        logger.warn(
            "[format2] no fresh grant for epoch", epoch, "of", documentId,
            "within", Format2Transport.grantRefreshTimeout, "seconds"
        )
        return before
    }

    /// Apply the sealed chain a client behind the room owes, then move onto a
    /// fresh overlay (#3437, behaviors 16 and 18).
    ///
    /// Off the frame handler for the same reason a base load is: it is a
    /// download per epoch, and the socket's receive loop has to keep running
    /// underneath it.
    private func startCatchUp(
        _ documentId: String,
        to reported: Int,
        sealed: [SealedEpochChainEntry],
        coordinator: Format2Coordinator
    ) {
        let fetch = sealedArchiveFetcher(documentId, coordinator: coordinator)
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await coordinator.runCatchUp(
                    documentId: documentId, target: reported,
                    sealed: sealed, fetch: fetch
                )
                switch outcome {
                case .caughtUp:
                    // On a fresh overlay now, carrying what the server has not
                    // acknowledged: resync it, then state what is owed.
                    await resyncAfterMove(documentId, coordinator: coordinator)
                case .reload:
                    // A chain that cannot be trusted is not the end of the
                    // document: when the room has a base past everything this
                    // client has crossed, it reloads from that instead of
                    // stopping (#3437, behavior 22). Only when there is none
                    // is the application told to reload.
                    if await startRebuild(
                        documentId, reported: reported, sealed: sealed,
                        reason: .refusedChain, coordinator: coordinator
                    ) { return }
                    reportReloadRequired(
                        documentId, messageType: "epoch.info",
                        coordinator: coordinator
                    )
                case .converge(_, let discontinuities):
                    // The chain crosses a bulk load, so it is not a chain: the
                    // sum of the overlays either side of it is not the
                    // document. What gets this client current is the base the
                    // ingest produced — now if it is already on offer, or on
                    // the `snapshot.ready` that announces it (#3437,
                    // behavior 31).
                    for epoch in discontinuities {
                        try? coordinator.binding(documentId)?
                            .store.noteDiscontinuity(epoch: epoch)
                    }
                    await startRebuild(
                        documentId, reported: reported, sealed: sealed,
                        reason: .discontinuity, coordinator: coordinator
                    )
                case .none:
                    // Nothing to apply: a seal this document followed in place
                    // moved it between the plan and this run. The coordinator
                    // has given back everything the plan took; what it cannot
                    // give back are the frames the room sent while the gate was
                    // up, so this client says where it is and asks again.
                    await resyncAfterMove(documentId, coordinator: coordinator)
                case .dropped:
                    // The document is gone, and the coordinator has logged it.
                    break
                }
            } catch {
                logger.warn(
                    "[format2] the catch-up of", documentId, "could not finish:",
                    error.localizedDescription
                )
            }
        }
    }

    /// Reload this document whole from the newest base the room has offered
    /// (#3437, behaviors 21, 22, 29 and 31).
    ///
    /// - Returns: whether a base was on offer and the reload ran. `false` is
    ///   "there is nothing to reload from", which every caller answers
    ///   differently — a refused chain stops the document, a discontinuity
    ///   waits for the build.
    @discardableResult
    private func startRebuild(
        _ documentId: String,
        reported: Int,
        sealed: [SealedEpochChainEntry],
        reason: Format2Coordinator.RebuildReason,
        coordinator: Format2Coordinator
    ) async -> Bool {
        guard let base = coordinator.rebuildBaseOnOffer(documentId) else { return false }
        // One reload at a time. A reload runs with the document's refusal
        // still set — the refusal is what it answers — so a `snapshot.ready`
        // arriving meanwhile would start a second one over it, and the second
        // discard would take the writes the first had just judged and stated
        // (edge E11; found live).
        guard coordinator.beginRebuild(documentId) else { return false }
        defer { coordinator.endRebuild(documentId) }
        let source = Format2SnapshotSource(
            apiUrl: apiUrl,
            documentId: documentId,
            grantPath: base.grantPath,
            logger: logger,
            read: Format2SnapshotSource.urlSessionReader(),
            refreshGrant: { [weak self] in
                self?.requestFreshGrants(documentId, coordinator: coordinator)
            }
        )
        let fetch = sealedArchiveFetcher(documentId, coordinator: coordinator)
        let attempt = coordinator.beginBaseLoad(documentId)
        do {
            let outcome = try await coordinator.runRebuild(
                documentId: documentId, base: base, source: source,
                reported: reported, sealed: sealed, reason: reason,
                fetch: fetch,
                permittedModels: try await hydrationScope(
                    documentId, coordinator: coordinator
                ),
                attempt: attempt
            )
            switch outcome {
            case .rebuilt:
                await resyncAfterMove(documentId, coordinator: coordinator)
            case .refused:
                reportReloadRequired(
                    documentId, messageType: "epoch.info", coordinator: coordinator
                )
            case .dropped:
                break
            }
        } catch {
            logger.warn(
                "[format2] the rebuild of", documentId, "could not finish:",
                error.localizedDescription
            )
            return false
        }
        return true
    }

    /// The models this device is PERMITTED to hold, which a reload's base is
    /// planned within: a capped load stays capped across a rebuild
    /// (behavior 34), and the replacement base is still measured against the
    /// device's free space before a chunk of it is fetched — a model that used
    /// to fit can have outgrown the device since (finding 3437-REVIEW-010).
    private func hydrationScope(
        _ documentId: String, coordinator: Format2Coordinator
    ) async throws -> [String]? {
        try coordinator.binding(documentId)?.store.hydrationScope()
    }

    /// Apply the chain a cold start needs above its base (or instead of one).
    private func startColdChain(
        _ documentId: String,
        from: Int,
        to: Int,
        sealed: [SealedEpochChainEntry],
        coordinator: Format2Coordinator
    ) {
        let fetch = sealedArchiveFetcher(documentId, coordinator: coordinator)
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Format2Coordinator.HandshakeOutcome, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            try coordinator.runColdChain(
                                documentId: documentId, from: from, to: to,
                                fetch: fetch, sealed: sealed
                            )
                        })
                    }
                }
                if outcome.plan == .reloadRequired {
                    reportReloadRequired(
                        documentId, messageType: "epoch.info",
                        coordinator: coordinator
                    )
                    return
                }
                await sendReleasedFrames(outcome.released)
                await flushOutboundUpdates(documentId: documentId)
            } catch {
                logger.warn(
                    "[format2] the chain of", documentId, "could not be applied:",
                    error.localizedDescription
                )
            }
        }
    }

    /// Stream in the base a cold start needs, then let the hold go.
    ///
    /// Off the frame handler, on a task of its own: the base is however many
    /// megabytes the document is, and the socket's receive loop has to keep
    /// running underneath it — `epoch.info` is not the last frame this
    /// document will get, and a load that blocked the loop would stall the
    /// very sync that delivers the open epoch's overlay.
    private func runColdStartLoad(
        _ documentId: String,
        base: Format2Coordinator.BaseToLoad,
        reported: Int,
        sealed: [SealedEpochChainEntry],
        coordinator: Format2Coordinator,
        attempt: Int
    ) async {
        let source = Format2SnapshotSource(
            apiUrl: apiUrl,
            documentId: documentId,
            grantPath: base.grantPath,
            logger: logger,
            read: Format2SnapshotSource.urlSessionReader(),
            refreshGrant: { [weak self] in
                self?.requestFreshGrants(documentId, coordinator: coordinator)
            }
        )
        do {
            // On a plain dispatch queue, not the cooperative pool: the load
            // blocks its thread on every chunk's read, and doing that on a
            // pool thread would take one out of circulation for the whole
            // download. `models: nil` — the whole snapshot; capping a load to
            // what a device can hold is the storage cap, which is #3437's.
            let outcome = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Format2Coordinator.HandshakeOutcome, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try coordinator.runBaseLoad(
                            documentId: documentId, base: base,
                            source: source, models: nil, attempt: attempt
                        )
                    })
                }
            }
            // The base is one epoch's worth of rows. When the room has rotated
            // since it was cut, the overlays sealed in between are the rest of
            // the document (#3437, behavior 18): applied UNDER the open
            // overlay, which is then refolded, so the changes since the last
            // rotation end up on top.
            if outcome.plan == .join, reported > base.epoch {
                startColdChain(
                    documentId, from: base.epoch, to: reported,
                    sealed: sealed, coordinator: coordinator
                )
                return
            }
            await sendReleasedFrames(outcome.released)
            await flushOutboundUpdates(documentId: documentId)
        } catch let error as JsBaoError {
            logger.warn(
                "[format2] the cold start of", documentId, "could not finish:",
                error.code.rawValue
            )
            stopAfterFailedColdStart(
                documentId, error: error, coordinator: coordinator, attempt: attempt
            )
        } catch {
            logger.warn(
                "[format2] the cold start of", documentId, "could not finish:",
                error.localizedDescription
            )
            stopAfterFailedColdStart(
                documentId,
                error: JsBaoError(
                    code: .format2ReloadRequired,
                    message: "The base snapshot of `\(documentId)` could not be "
                        + "read: \(error.localizedDescription)",
                    details: [
                        "documentId": .string(documentId),
                        "plan": .string("snapshot"),
                    ]
                ),
                coordinator: coordinator,
                attempt: attempt
            )
        }
    }

    /// Ask the room to re-mint this document's artifact grants, and wait,
    /// bounded, for the answer (#3436, behavior 23).
    ///
    /// A base of the size this design exists for takes longer to stream than a
    /// signature lives, so an expired one is a step rather than a failure: the
    /// room re-mints over the socket that is already open and the one read
    /// that was refused is repeated. The reply is an ordinary `epoch.grants`
    /// frame, recorded by the arm that handles it — deliberately NOT an
    /// `epoch.info`, which would re-run the handshake decision on a document
    /// in the middle of being rebuilt.
    ///
    /// Blocking, on the load's own dispatch-queue thread: the loader is
    /// synchronous, and this is the one place it waits on the socket.
    private func requestFreshGrants(
        _ documentId: String, coordinator: Format2Coordinator
    ) -> String? {
        let before = coordinator.snapshotInfo(documentId)?.downloadPath
        guard let text = Self.epochGrantsFrame(documentId) else { return before }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await wsManager.send(text)
            } catch {
                logger.warn(
                    "[format2] could not ask for fresh artifact grants:",
                    error.localizedDescription
                )
            }
        }
        let deadline = Date().addingTimeInterval(Format2Transport.grantRefreshTimeout)
        while Date() < deadline {
            let fresh = coordinator.snapshotInfo(documentId)?.downloadPath
            if let fresh, fresh != before { return fresh }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Nothing arrived in the window. The caller repeats its read with the
        // grant it already had, which fails and is reported — rather than
        // waiting on a socket that may be gone.
        logger.warn(
            "[format2] no fresh grant for", documentId, "within",
            Format2Transport.grantRefreshTimeout, "seconds"
        )
        return before
    }

    /// A base that could not be read leaves the document stopped rather than
    /// half-loaded: the merged view is whatever landed, the load marks say
    /// which chunks those were, and the next open resumes from them.
    ///
    /// Silent when the attempt has been superseded: a load that was overtaken
    /// by a newer handshake, or by a close, must not stop a document that
    /// something later has already decided about. Its failure is its own.
    private func stopAfterFailedColdStart(
        _ documentId: String, error: JsBaoError, coordinator: Format2Coordinator,
        attempt: Int
    ) {
        guard coordinator.baseLoadIsCurrent(documentId, attempt: attempt) else {
            logger.debug(
                "[format2] a superseded base load of", documentId,
                "failed; the document has already moved on"
            )
            return
        }
        coordinator.hold.hold(documentId, reason: "cold start failed")
        coordinator.binding(documentId)?.requireReload(error)
        reportReloadRequired(
            documentId, messageType: "epoch.info", coordinator: coordinator
        )
    }

    /// Tell the application why a large document has stopped taking writes.
    private func reportReloadRequired(
        _ documentId: String, messageType: String, coordinator: Format2Coordinator
    ) {
        guard let error = coordinator.binding(documentId)?.reloadRefusal else { return }
        var detail = error.details ?? [:]
        detail["code"] = .string(error.code.rawValue)
        eventEmitter.emit(ConnectionErrorEvent(
            message: error.message,
            documentId: documentId,
            messageType: messageType,
            detail: .object(detail)
        ))
        failAwaitingOpen(documentId, error: error)
    }

    /// Handle an `epoch.seal` or `epoch.resync` frame (behavior 30).
    func handleEpochSealFrame(_ frame: [String: Any]) async {
        guard let coordinator = format2State.coordinator,
              let documentId = frame["documentId"] as? String
        else { return }
        let decision: Format2Coordinator.SealDecision
        do {
            decision = try coordinator.handleEpochSeal(frame)
        } catch {
            logger.warn(
                "[format2] an epoch frame for", documentId, "could not be handled:",
                error.localizedDescription
            )
            return
        }

        switch decision {
        case .dropped, .alreadyCurrent:
            return
        case .resyncOwed:
            // A resync at the epoch this document is already on asks for
            // self-contained state, not a reload (finding 3436-B01). The whole
            // overlay is exactly the answer most likely to be over
            // `MAX_UPDATE_SIZE`, so it goes out on the lane rather than from
            // this handler (#3559).
            runOffReceiveLoop(documentId) { client in
                await client.answerResync(documentId, coordinator: coordinator)
            }
        case .move(let next):
            await followSeal(documentId, next: next, coordinator: coordinator)
        case .catchUp(let from, let to):
            // Behind the room by more than the one epoch a move can cross
            // (edge E2). The seal frame carries no chain — `epoch.seal` has no
            // `sealedEpochs` — so this client asks for a fresh handshake and
            // plans from what THAT says. The document is not stopped: it keeps
            // answering reads and accepting writes, and its overlay is held
            // against the room's current epoch meanwhile (behavior 17).
            logger.debug(
                "[format2] a seal left", documentId, "behind the room (",
                from, "→", to, ") — asking for a fresh handshake to read the chain"
            )
            if let step1 = documentManager.buildSyncStep1Message(documentId: documentId) {
                await sendReleasedFrames([step1])
            }
        case .stopped:
            reportReloadRequired(
                documentId, messageType: "epoch.seal", coordinator: coordinator
            )
        }
    }

    /// Follow a seal onto a fresh overlay, then ask the room for the new
    /// epoch's state (#3437, behavior 10).
    ///
    /// The `syncStep1` at the end is what makes the move complete: the fresh
    /// document has this client's owed writes on it and nothing else, so the
    /// room's answer is the new epoch's content, and the frame this client
    /// sends back claims the owed sequences whose content it really carries.
    private func followSeal(
        _ documentId: String, next: Int, coordinator: Format2Coordinator
    ) async {
        do {
            let outcome = try await coordinator.runEpochMove(
                documentId: documentId, next: next
            )
            guard outcome == .moved(epoch: next) else { return }
        } catch {
            // The move could not be completed, so the document is where it
            // was: held, with its pending log intact, and repaired by the next
            // handshake's plan. Reported rather than swallowed (principle 8).
            logger.warn(
                "[format2] the epoch move of", documentId, "to", next,
                "did not complete:", error.localizedDescription
            )
            reportReloadRequired(
                documentId, messageType: "epoch.seal", coordinator: coordinator
            )
            return
        }
        // The carried entries are on the fresh overlay as local updates, and
        // the resync answer is what puts them on the wire claiming exactly the
        // sequences they carry. On the lane: this runs from the `epoch.seal`
        // handler, and the answer can be an offloaded frame whose upload waits
        // on a reply the loop would have to deliver (#3559).
        runOffReceiveLoop(documentId) { client in
            await client.resyncAfterMove(documentId, coordinator: coordinator)
        }
    }

    /// Re-read the evidence a judgement a restart interrupted needs (#3437,
    /// behavior 20a).
    ///
    /// Only when the document's mark is still the epoch the note was written
    /// for — if the room has rotated again the judgement is about a span this
    /// client is no longer on, and the catch-up that follows will defer afresh
    /// — and only when this session does not already hold the ledger, which it
    /// does for a deferral it made itself.
    ///
    /// Returns at once. The archives are read on a plain dispatch queue for
    /// the reason the chain itself is (the reads block their thread) and off
    /// the caller's frame handler for a stronger one: that handler is the
    /// socket's receive loop, and the grant refresh a long read may need is
    /// answered by a frame only that loop can deliver.
    ///
    /// The judgement runs at the joined epoch's `syncComplete` — here, if it
    /// has already arrived by the time the evidence is ready, and otherwise in
    /// ``completeDeferredReplayIfOwed(_:)`` as for any other deferral.
    private func prepareDeferredReplayIfOwed(
        _ documentId: String,
        sealed: [SealedEpochChainEntry],
        coordinator: Format2Coordinator
    ) {
        guard coordinator.deferredReplayNeedsChain(documentId),
              format2State.beginLedgerRebuild(documentId)
        else { return }
        let fetch = sealedArchiveFetcher(documentId, coordinator: coordinator)
        Task { [weak self] in
            guard let self else { return }
            var ready = false
            do {
                ready = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Bool, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            try coordinator.resumeDeferredReplay(
                                documentId: documentId, sealed: sealed, fetch: fetch
                            )
                        })
                    }
                }
            } catch {
                logger.warn(
                    "[format2] the evidence the deferred replay of", documentId,
                    "needs could not be read:", error.localizedDescription
                )
            }
            // Whatever happened, this document is no longer waiting on a read.
            // A failure leaves no ledger, which the resolution reads as
            // `unverifiable` — the writes are KEPT and surfaced, never dropped
            // on evidence nobody has.
            let syncedMeanwhile = format2State.finishLedgerRebuild(documentId)
            guard ready, syncedMeanwhile else { return }
            await completeDeferredReplayIfOwed(documentId)
        }
    }

    /// Judge the writes a move deferred, now that the joined epoch's content
    /// has arrived (#3437, behavior 20).
    ///
    /// A no-op for every document with no judgement owed, which is every
    /// ordinary sync of every document — the note is what makes it not one.
    /// The survivors go out afterwards as one self-contained frame, which is
    /// also the first frame allowed to claim their sequences: the withhold is
    /// released inside the judgement, after they are on the overlay.
    func completeDeferredReplayIfOwed(_ documentId: String) async {
        guard let coordinator = format2State.coordinator,
              coordinator.isLargeDocument(documentId)
        else { return }
        // Not while the chain this judgement is weighed against is still being
        // read: the reader runs the judgement itself when it is done.
        guard format2State.noteSyncedForDeferredReplay(documentId) else {
            logger.debug(
                "[format2] the joined epoch of", documentId,
                "has synced while its chain is still being read — the "
                    + "judgement runs when the evidence is in"
            )
            return
        }
        do {
            guard let outcome = try coordinator.completeDeferredReplay(
                documentId: documentId
            ) else { return }
            if outcome.rebuildRequired {
                // The resolution would drop a delete, and this merged view has
                // already folded it: the record has to come back from a base
                // before the verdict can be carried out (#3437, behavior 21).
                // The note stands meanwhile, so a restart still knows.
                //
                // Started off this caller's frame handler: a reload is a
                // download of the whole document, and the receive loop has to
                // keep running underneath it (finding 3437-REVIEW-009).
                let reported = max(
                    coordinator.reportedEpoch(documentId),
                    (try? coordinator.binding(documentId)?.store.epoch())
                        .flatMap { $0 } ?? outcome.epoch
                )
                Task { [weak self] in
                    guard let self else { return }
                    if await startRebuild(
                        documentId, reported: reported,
                        sealed: coordinator.sealedChain(documentId),
                        reason: .droppedDelete, coordinator: coordinator
                    ) { return }
                    logger.warn(
                        "[format2] the offline writes of", documentId,
                        "need a base past the delete they would drop, and none "
                            + "is on offer — they stay owed until one is"
                    )
                }
                return
            }
        } catch {
            // The note stays, so the next handshake resumes the judgement. A
            // judgement that failed silently would leave those writes withheld
            // for ever, which is why it is reported (principle 8).
            logger.warn(
                "[format2] the deferred replay of", documentId,
                "could not be completed:", error.localizedDescription
            )
            return
        }
        // The survivors, and the queue behind them, on the lane: this runs from
        // the `syncComplete` handler, and the survivors' frame is a whole
        // overlay — the answer most likely to need an offload (#3559).
        runOffReceiveLoop(documentId) { client in
            await client.answerResync(documentId, coordinator: coordinator)
            await client.flushOutboundUpdates(documentId: documentId)
        }
    }

    /// What every move owes the room afterwards: this client's state, and a
    /// request for the room's (#3437, behaviors 20, 22 and 29).
    ///
    /// The `syncStep1` is not a nicety. A move installs a FRESH overlay, and a
    /// move that deferred its carry has a judgement waiting on the joined
    /// epoch's content — which arrives as the room's answer to exactly this
    /// frame, and whose `syncComplete` is what runs the judgement. Without it
    /// a returning client's owed writes stay withheld for ever, judged by
    /// nobody: found live, on the relaunch and offline-replay rows, where
    /// `followSeal` had it and the catch-up and the reload did not.
    private func resyncAfterMove(
        _ documentId: String, coordinator: Format2Coordinator
    ) async {
        await answerResync(documentId, coordinator: coordinator)
        await flushOutboundUpdates(documentId: documentId)
        if let step1 = documentManager.buildSyncStep1Message(documentId: documentId) {
            await sendReleasedFrames([step1])
        }
    }

    /// Send the whole overlay, which is the self-contained state the room
    /// asked for.
    ///
    /// Held documents are not resynced: a document waiting on its handshake,
    /// or stopped for a reload, must not put local state on the wire — which
    /// is the whole of decision 3436-SO-02. The room re-asks after the hold
    /// releases, because the frame it could not integrate is still unintegrated.
    private func answerResync(
        _ documentId: String, coordinator: Format2Coordinator
    ) async {
        guard !coordinator.hold.isHeld(documentId) else {
            logger.debug(
                "[format2] a resync for", documentId,
                "arrived while it is held — not answered"
            )
            return
        }
        do {
            guard let resend = try coordinator.wholeStateResend(documentId: documentId)
            else { return }
            let sent = await documentManager.sendLocalUpdate(
                documentId: documentId, update: resend.update, claiming: resend.claim
            )
            logger.debug(
                "[format2] resync answered for", documentId,
                "— whole overlay,", resend.update.count, "byte(s), sent:", sent
            )
        } catch {
            logger.warn(
                "[format2] the resync of", documentId, "could not be built:",
                error.localizedDescription
            )
        }
    }

    /// Handle a `snapshot.ready` or `epoch.grants` frame.
    ///
    /// A build completing is also the retry a held document was waiting for:
    /// one converging on a bulk load, and one stopped because its chain could
    /// not be applied, are both waiting for exactly this (#3437, behaviors 22
    /// and 29). A document with nothing owed records the offer and no more.
    func handleSnapshotInfoFrame(_ frame: [String: Any]) {
        guard let coordinator = format2State.coordinator,
              coordinator.handleSnapshotInfo(frame),
              let documentId = frame["documentId"] as? String,
              let binding = coordinator.binding(documentId)
        else { return }
        let converging = (try? binding.store.discontinuityEpochs())?.isEmpty == false
        guard converging || binding.reloadRequired else { return }
        // Recorded above, and that is all: a reload already running is
        // answering this very refusal (edge E11).
        guard !coordinator.isRebuilding(documentId) else {
            logger.debug(
                "[format2] a base was announced for", documentId,
                "while its reload is still running — recorded, not restarted"
            )
            return
        }
        guard let base = coordinator.rebuildBaseOnOffer(documentId) else { return }
        Task { [weak self] in
            guard let self else { return }
            // The ROOM's epoch, not the base's. A `snapshot.ready` names the
            // epoch its base covers and says nothing about how far the room
            // has rotated since — and a base announced at epoch B while the
            // room is on R is B..R−1 sealed overlays short of the document. A
            // rebuild that took B for its target would apply none of them and
            // then mark this client current, dropping every write that lives
            // only in them (finding 3437-REVIEW-007). The last handshake's
            // number is the floor; the `syncStep1` the rebuild sends
            // afterwards draws a fresh `epoch.info` for anything sealed since.
            await startRebuild(
                documentId,
                reported: max(coordinator.reportedEpoch(documentId), base.epoch),
                sealed: coordinator.sealedChain(documentId),
                reason: converging ? .discontinuity : .refusedChain,
                coordinator: coordinator
            )
        }
    }

    /// Handle an `update.ack` frame: prune this client's pending ops at or
    /// below the server's contiguous high-water mark.
    func handleUpdateAckFrame(_ frame: [String: Any]) {
        guard let coordinator = format2State.coordinator else { return }
        do {
            _ = try coordinator.handleUpdateAck(frame)
        } catch {
            logger.warn("[format2] update.ack could not be applied:", error.localizedDescription)
        }
    }

    /// Forget everything this client stored for one large document: its own
    /// tables, its rows in every shared table, and the writes the server has
    /// not yet acknowledged (behavior 35).
    ///
    /// Called from the eviction path, which is an explicit instruction to
    /// forget the document — not from an ordinary close, which keeps
    /// everything, because that is what makes the next open cheap.
    ///
    /// It runs for every document an eviction sweeps, most of which are
    /// format 1, and on clients that have never opened a large document at
    /// all: the store asks the database what it has before dropping anything,
    /// so both are a no-op rather than an error.
    /// Hold every open large document because a socket has just come up
    /// (#3436, decision 3436-SO-02).
    ///
    /// Synchronous by design: the ws-open flush is scheduled in the same method
    /// that calls this, so a hold taken asynchronously could be taken after the
    /// writes it was meant to keep back had gone out. A no-op on a client with
    /// no large document open, which is every ordinary client.
    func holdLargeDocumentsForNewConnection() {
        format2State.coordinator?.holdAllForNewConnection()
    }

    func purgeLargeDocument(_ documentId: String) async {
        format2State.coordinator?.unbind(documentId: documentId)
        guard let provider = await offlineStore.getStorageProvider(),
              let host = provider as? any Format2SqlHost
        else { return }
        do {
            try Format2RecordStore.purge(host: host, documentId: documentId)
        } catch {
            logger.warn(
                "[format2] purge failed for", documentId, error.localizedDescription
            )
        }
    }

    /// The same for every large document in this client's database — the
    /// account wipe.
    ///
    /// The document ids come from the tables themselves, so a document this
    /// session never opened is still reached. That is the case the in-memory
    /// close sweep cannot see, and the one criterion 7 is about: a previous
    /// account's records may not survive a `wipeLocal` logout.
    func purgeAllLargeDocuments() async {
        if let coordinator = format2State.coordinator {
            for documentId in coordinator.boundDocumentIds() {
                coordinator.unbind(documentId: documentId)
            }
        }
        guard let provider = await offlineStore.getStorageProvider(),
              let host = provider as? any Format2SqlHost
        else { return }
        do {
            try Format2RecordStore.purgeAll(host: host)
        } catch {
            logger.warn("[format2] account purge failed:", error.localizedDescription)
        }
        // The coordinator's client id and bindings belonged to the account
        // that is gone; the next open builds a fresh one over whatever storage
        // the next session binds.
        format2State.reset()
    }

    /// A handshake that completed with no `epoch.info` in it is the answer
    /// "format 1" — record it, so this client's next session keeps
    /// Foundation's receive limit for this document.
    func noteHandshakeWithoutEpochInfo(_ documentId: String) {
        guard !isLargeDocument(documentId) else { return }
        documentManager.noteDocumentFormat(documentId, 1)
    }
}
