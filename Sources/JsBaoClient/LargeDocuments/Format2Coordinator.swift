import Foundation
import YSwift

/// Everything the client knows about the large documents it has open
/// (#3436).
///
/// One per client. It owns the per-document bindings, the outbound hold, and
/// the handling of the epoch frames — so "is this document large, and what is
/// it allowed to do right now" has one answer, reachable from the message
/// router, the update queue and the open path alike.
///
/// A document that is NOT bound here is an ordinary format-1 document and is
/// untouched by every rule in this file, which is what makes the intent's
/// "ordinary documents are unchanged" true by construction rather than by
/// review.
public final class Format2Coordinator: @unchecked Sendable {

    private let host: any Format2SqlHost
    private let clientId: String
    private let logger: Logger?

    private let lock = NSLock()
    private var bindings: [String: Format2DocumentBinding] = [:]
    private var _queryProjection: Format2QueryProjection?
    /// The newest snapshot each open document was told about, by `epoch.info`
    /// or by a later `snapshot.ready`.
    private var snapshots: [String: SnapshotOffer] = [:]
    /// The base load each document is currently waiting for.
    ///
    /// A load is a download of however many megabytes the document is, and it
    /// runs off the frame handler — so the socket keeps delivering frames
    /// under it, and a reconnect's `epoch.info`, a seal or a close can all
    /// land while one is in flight. Every one of those supersedes it: the
    /// number here goes up and the load in flight finishes into nothing rather
    /// than setting the epoch mark and releasing a hold something newer took.
    private var loadGeneration: [String: Int] = [:]

    /// The file-backed query tables this client's large documents project
    /// into, built on first use over the same storage host.
    ///
    /// One per client, not one per document: a model's rows from every large
    /// document share a table, tagged by `_meta_doc_id`, exactly as the
    /// in-memory mirror tags an ordinary document's.
    public var queryProjection: Format2QueryProjection {
        lock.withLock {
            if let _queryProjection { return _queryProjection }
            let built = Format2QueryProjection(host: host, logger: logger)
            _queryProjection = built
            return built
        }
    }

    /// The per-document outbound hold every path carrying local state
    /// consults.
    public let hold = Format2OutboundHold()

    /// What each outbound frame may claim: the sequences whose content it
    /// actually carries.
    public let outbound = Format2OutboundAckLedger()

    /// Which epoch generation each document's outbound payloads belong to
    /// (#3559). Read and bumped through ``outboundGeneration(_:)`` and
    /// ``invalidateOutboundGeneration(_:)``.
    private let outboundGenerationLock = NSLock()
    private var outboundGenerations: [String: Int] = [:]

    /// Told when a document's merged view first becomes untrustworthy, so the
    /// client can emit `ConnectionErrorEvent` with `FORMAT2_FOLD_BROKEN`
    /// (decision 3436-SO-08, the spec's Observability section). A fold fails on
    /// the fold queue with no caller to hand the error to, and the refusals it
    /// causes afterwards are indistinguishable from an absent record on the
    /// non-throwing read paths — this is how an application learns the
    /// difference.
    public var onFoldBroken: (@Sendable (String, JsBaoError) -> Void)?

    /// Told how a cold start's base load is going, so the client can emit
    /// `document:snapshot-load`. A load of a multi-hundred-megabyte base that
    /// reported only at the end would be indistinguishable from a hang.
    public var onSnapshotLoad: (@Sendable (DocumentSnapshotLoadEvent) -> Void)?

    /// Told when a local mutation was refused through a verb that cannot throw
    /// (#3437, behavior 2a), so the client can emit `DocumentWriteRefusedEvent`.
    ///
    /// `DynamicModel.delete(id:)` and a `PrimitiveRecord` field setter swallow
    /// the write path's error with `try?`, so without this an application
    /// cannot tell a refused mutation from a completed one — and a document
    /// past its offline window refuses every one of them.
    public var onWriteRefused: (@Sendable (DocumentWriteRefusedEvent) -> Void)?

    /// Where a judged set of offline writes is reported (#3437, behavior 20).
    ///
    /// Emitted with the notices and nothing else: silence means every offline
    /// write replayed cleanly, so an event with no notices would be noise an
    /// application had to filter.
    public var onOfflineWritesResolved:
        (@Sendable (DocumentOfflineWritesResolvedEvent) -> Void)?

    init(host: any Format2SqlHost, clientId: String, logger: Logger? = nil) {
        self.host = host
        self.clientId = clientId
        self.logger = logger
    }

    // MARK: - Bindings

    /// Bind a document as format 2, HELD.
    ///
    /// Held from the bind, not from the handshake: the socket may already be
    /// open and the flush may already be due, and a write that escaped before
    /// the room said which epoch this client is on is a write against an
    /// overlay that may no longer exist.
    ///
    /// - Parameter document: the document's own Y.Doc — which for a large
    ///   document IS the current epoch's overlay, not the document. A caller
    ///   with no document in hand gets a detached one, which is a store and a
    ///   write path with nothing attached to the wire.
    @discardableResult
    public func bind(
        documentId: String,
        models: [String],
        document: YDocument = YDocument()
    ) throws -> Format2DocumentBinding {
        if let existing = binding(documentId) { return existing }

        let store = Format2RecordStore(
            host: host, documentId: documentId, clientId: clientId
        )
        try store.initialize()
        let overlay = OverlayDocument(document: document)
        let observer = Format2Observer(store: store, overlay: overlay, logger: logger)
        observer.onFoldBroken = { [weak self] error in
            self?.onFoldBroken?(documentId, error)
        }
        for model in models { observer.register(model: model) }
        let binding = Format2DocumentBinding(
            documentId: documentId,
            store: store,
            overlay: overlay,
            observer: observer,
            writePath: Format2WritePath(store: store, overlay: overlay, observer: observer),
            projection: queryProjection,
            logger: logger
        )
        binding.onWriteRefused = { [weak self] event in
            self?.onWriteRefused?(event)
        }
        // The report is the GATE's (#3758): `Format2WritePath` is the one
        // place every door runs through, so it is what knows a write was
        // refused — and it delivers the event once the document's operation
        // lock is released, never under it.
        binding.writePath.onWindowRefused = { [weak binding] event in
            binding?.reportWriteRefused(event)
        }
        binding.withholdOwed = { [weak self] through in
            self?.outbound.withhold(documentId, upTo: through)
        }
        // Kept on the binding so a rebind's fresh observer reaches the same
        // place, rather than being wired once to the observer this bind made.
        binding.onFoldBrokenForDocument = { [weak self] documentId, error in
            self?.onFoldBroken?(documentId, error)
        }
        for model in models { binding.noteRegisteredModel(model) }
        lock.withLock { bindings[documentId] = binding }
        hold.hold(documentId, reason: "awaiting epoch.info")
        logger?.debug("[format2] bound", documentId, "— held awaiting epoch.info")
        return binding
    }

    public func binding(_ documentId: String) -> Format2DocumentBinding? {
        lock.withLock { bindings[documentId] }
    }

    // MARK: - Base loads in flight

    /// Claim the right to run a base load for `documentId`, superseding
    /// whatever was in flight for it.
    ///
    /// Called by the caller that is about to start one, before the task that
    /// runs it is scheduled, so the supersession is settled synchronously with
    /// the decision that caused it.
    @discardableResult
    func beginBaseLoad(_ documentId: String) -> Int {
        lock.withLock {
            let next = (loadGeneration[documentId] ?? 0) + 1
            loadGeneration[documentId] = next
            return next
        }
    }

    /// Whether `attempt` is still the load this document is waiting for.
    ///
    /// Checked before a load commits any of its completion — the epoch mark,
    /// the cleared refusal, the released hold. An obsolete attempt answering
    /// `true` here is precisely how a finished download from before a
    /// reconnect would release the reload-required hold that reconnect set.
    func baseLoadIsCurrent(_ documentId: String, attempt: Int) -> Bool {
        lock.withLock { loadGeneration[documentId] == attempt }
    }

    /// Supersede whatever base load is in flight for `documentId`. Called
    /// wherever the document's state is decided again: a new handshake, a
    /// close, a purge.
    private func supersedeBaseLoadLocked(_ documentId: String) {
        loadGeneration[documentId] = (loadGeneration[documentId] ?? 0) + 1
    }

    /// Hold every bound document because a socket has just come up.
    ///
    /// A new connection is a new handshake: until this one's `epoch.info` has
    /// been handled, nothing this client holds locally may go out on it, for
    /// the same reason the bind's own hold exists — the room may have rotated
    /// or replaced the epoch those writes were made against while this client
    /// was away. Idempotent, and it does not disturb a document already held
    /// for another reason: a hold set twice releases once, on the handshake
    /// (edge E16).
    ///
    /// - Returns: the documents it holds, for the log line and for a test.
    @discardableResult
    public func holdAllForNewConnection() -> [String] {
        let documentIds = boundDocumentIds()
        for documentId in documentIds {
            hold.hold(documentId, reason: "awaiting epoch.info on a new connection")
        }
        if !documentIds.isEmpty {
            logger?.debug(
                "[format2] socket open — holding", documentIds.count,
                "large document(s) until this connection's epoch.info"
            )
        }
        return documentIds
    }

    /// Whether this document is a large document as far as the client is
    /// concerned. The one question every format-1 path asks.
    public func isLargeDocument(_ documentId: String) -> Bool {
        binding(documentId) != nil
    }

    public func boundDocumentIds() -> [String] {
        lock.withLock { Array(bindings.keys) }.sorted()
    }

    /// Release a document: fold what it has already captured, cancel its
    /// observers, and forget it. The STORE's rows stay — an ordinary close
    /// keeps everything, which is what makes the next open cheap.
    ///
    /// The drain comes FIRST, and it is not tidiness. Keys the observer
    /// captured and has not folded are work this document owes its own merged
    /// view; cancelling over them drops that work for good, because the reopen
    /// finds the epoch mark current, runs no catch-up, and leaves the row
    /// behind the overlay with nothing scheduled to notice. A drain that fails
    /// marks the binding fold-broken, which a rebind's catch-up repairs — the
    /// same repair path every other failed fold takes.
    public func unbind(documentId: String) {
        let binding = lock.withLock { () -> Format2DocumentBinding? in
            // A base load still streaming into this document is now nobody's:
            // the Y.Doc it would fold the open overlay from is going away, and
            // a reopen binds a new one. Superseded before the binding is
            // removed, so the load cannot see a half-released document.
            supersedeBaseLoadLocked(documentId)
            return bindings.removeValue(forKey: documentId)
        }
        if let binding {
            do {
                // Whatever the queue is already folding finishes first; then
                // this takes whatever is still captured and nothing is left
                // owed to a document that will not be watching.
                binding.settleFolds()
                try binding.writePath.foldPendingUnderOperation()
            } catch {
                logger?.warn(
                    "[format2] the fold owed at close of", documentId,
                    "did not commit:", error.localizedDescription
                )
            }
            binding.observer.cancel()
        }
        hold.forget(documentId)
        outbound.forget(documentId)
        lock.withLock {
            snapshots.removeValue(forKey: documentId)
            // The chain evidence is in-session by construction: the archives it
            // was built from are still readable while their grants live, and a
            // reopen re-reads whatever chain the next handshake reports.
            ledgers.removeValue(forKey: documentId)
            chainGrants.removeValue(forKey: documentId)
            behindTheRoom.remove(documentId)
            droppedInbound.removeValue(forKey: documentId)
            loggedInboundDrop.remove(documentId)
            reportedEpochs.removeValue(forKey: documentId)
            resumedNotes.remove(documentId)
        }
    }

    // MARK: - epoch.info

    // MARK: - Behind the room (#3437, behavior 17, edge E15)

    /// Documents whose held overlay belongs to an epoch the room has archived.
    ///
    /// While a document is in here, nothing the room sends for its CURRENT
    /// epoch may be merged into that overlay. Suspending the fold is not
    /// enough: the move's carry READS each owed record's value off the overlay,
    /// and a Yjs merge of two independent epoch documents can let a peer's
    /// value win the key before the carry reads it (finding 3437-SO-01). The
    /// frames are not lost — the fresh document's resync re-delivers the
    /// current epoch, which folds normally.
    private var behindTheRoom: Set<String> = []
    /// How many inbound frames were refused, and whether the refusal has been
    /// logged for this episode.
    private var droppedInbound: [String: Int] = [:]
    private var loggedInboundDrop: Set<String> = []

    /// Whether an inbound `syncStep2`/`update` frame may be applied to this
    /// document's open Y.Doc.
    ///
    /// `true` for every document this coordinator does not hold, which is every
    /// format-1 document: the gate is a property of a LARGE document behind the
    /// room and of nothing else.
    public func acceptsInbound(_ documentId: String) -> Bool {
        lock.withLock { !behindTheRoom.contains(documentId) }
    }

    /// ``acceptsInbound(_:)``, and the one log line a refusal is worth.
    ///
    /// The path `DocumentManager` calls. Logged once per document per episode
    /// rather than once per frame (edge E15): a burst of frames behind the room
    /// is ONE fact, and a line per frame would bury it.
    public func admitInbound(_ documentId: String) -> Bool {
        let shouldLog: Bool = lock.withLock {
            guard behindTheRoom.contains(documentId) else { return false }
            droppedInbound[documentId] = (droppedInbound[documentId] ?? 0) + 1
            return loggedInboundDrop.insert(documentId).inserted
        }
        if shouldLog {
            logger?.debug(
                "[format2] dropped an inbound frame for a document behind the",
                "room:", documentId,
                "— its resync on the fresh overlay re-delivers the current epoch"
            )
            return false
        }
        return acceptsInbound(documentId)
    }

    /// How many inbound frames this document has had refused.
    ///
    /// A counter rather than a log assertion because this client's `Logger`
    /// writes to stdout with no sink to read back; the count and
    /// ``inboundDropLogCount(_:)`` beside it are how "once per document, not
    /// once per frame" is graded at all.
    public func droppedInboundFrameCount(_ documentId: String) -> Int {
        lock.withLock { droppedInbound[documentId] ?? 0 }
    }

    /// How many lines the refusals above have produced: one per episode.
    public func inboundDropLogCount(_ documentId: String) -> Int {
        lock.withLock { loggedInboundDrop.contains(documentId) ? 1 : 0 }
    }

    /// This document is behind the room: hold its overlay, its folds and its
    /// outbound frames.
    ///
    /// The outbound hold matters as much as the inbound gate. Every update this
    /// document would send is a Yjs DELTA against an overlay the room has
    /// archived: the room PARKS such a frame instead of integrating it, and
    /// from then on answers every later update from that connection with a
    /// resync request rather than an acknowledgement — permanently (measured
    /// live in phase A). Held means KEPT: the writes behind those frames are
    /// the user's, they commit locally as they always did, and the move carries
    /// their content onto the fresh overlay.
    func noteBehindTheRoom(_ binding: Format2DocumentBinding) {
        let fresh: Bool = lock.withLock {
            behindTheRoom.insert(binding.documentId).inserted
        }
        guard fresh else { return }
        binding.observer.suspendRemoteFolds()
        hold.hold(binding.documentId, reason: Self.behindTheRoomReason)
        logger?.debug(
            "[format2]", binding.documentId,
            "is behind the room — its overlay is its own until it has moved"
        )
    }

    /// Why ``noteBehindTheRoom(_:)`` holds, named once: the undo below releases
    /// only a hold it recognises as its own.
    static let behindTheRoomReason = "behind the room"

    /// Why a seal holds, named once, for the same reason.
    static let sealHoldReason = "epoch sealed"

    /// Give back the hold a seal took when the move it was for did not run.
    ///
    /// The move releases on its way out, so this is only the paths that never
    /// reach one — `already-current`, a document closed meanwhile. A hold left
    /// behind there leaves the document committing writes and sending none of
    /// them, with nothing else coming to release it.
    func releaseSealHold(_ documentId: String) {
        guard hold.reason(documentId) == Self.sealHoldReason else { return }
        hold.release(documentId, reason: "the seal moved nothing")
    }

    /// It is not any more: the move installed a fresh overlay, or the catch-up
    /// gave up and the document is held for a reload.
    func clearBehindTheRoom(_ documentId: String) {
        lock.withLock {
            behindTheRoom.remove(documentId)
            droppedInbound.removeValue(forKey: documentId)
            loggedInboundDrop.remove(documentId)
        }
        binding(documentId)?.observer.resumeRemoteFolds()
    }

    /// The document was never behind the room, or is not any more, and no move
    /// is coming to say so.
    ///
    /// A catch-up that finds nothing to apply has been OVERTAKEN: the seal its
    /// plan was made for was followed in place before it ran. Everything
    /// ``noteBehindTheRoom(_:)`` took is undone by the move at the end of a
    /// chain, and this path never reaches one — so a hold the handshake set
    /// after that move had already released its own has nothing left to release
    /// it. The document goes on answering reads and committing writes, and not
    /// one of them ever reaches the room again.
    ///
    /// Only a hold this coordinator recognises as the behind-the-room one is
    /// released: a document stopped for a reload, or awaiting a base, is held
    /// for a reason this knows nothing about. The frames that hold kept are
    /// DROPPED with it, as a move drops them — each is an answer built against
    /// the overlay the room has archived, and the caller's resync is what puts
    /// this client's state on the wire instead.
    ///
    /// - Returns: whether anything was undone.
    @discardableResult
    func endBehindTheRoom(_ documentId: String) -> Bool {
        guard lock.withLock({ behindTheRoom.contains(documentId) }) else { return false }
        clearBehindTheRoom(documentId)
        guard hold.reason(documentId) == Self.behindTheRoomReason else { return true }
        let dropped = hold.release(documentId, reason: "not behind the room")
        logger?.log(
            "[format2]", documentId,
            "was not behind the room after all — releasing it, and dropping",
            dropped.count, "frame(s) built against the epoch it has left"
        )
        return true
    }

    /// What the handshake decided.
    public enum HandshakePlan: String, Equatable, Sendable {
        /// This client is on the room's epoch (or starting empty on it):
        /// note the marks, release the hold, carry on.
        case join
        /// The frame was for a document this client does not hold, or it was
        /// malformed. Nothing happened.
        case dropped
        /// The document's local state cannot be advanced in place. Held, with
        /// the typed refusal. #3437 fills this seam.
        case reloadRequired
        /// This client is COLD and the room offered a base: stream that base
        /// in, fold the open overlay over it, and join. The caller runs it — it
        /// is a download, not a frame handler's work — through
        /// ``runBaseLoad(documentId:base:source:models:now:attempt:)``.
        ///
        /// When the base's epoch is BELOW the one the room reports, the outcome
        /// also carries the sealed chain between them: the base is one epoch's
        /// worth of rows and the overlays above it are the rest of the
        /// document, so the load is followed by ``runColdChain`` before the
        /// document is current.
        case loadBase
        /// This client HOLDS an epoch the room has archived: apply the sealed
        /// chain between them, then move. The caller runs it through
        /// ``runCatchUp(documentId:target:sealed:fetch:now:)``.
        case catchUp
        /// No base was ever built, but the chain from the document's first
        /// epoch is whole: that chain IS the document. The caller runs
        /// ``runColdChain`` over an empty view.
        case loadOverlays
        /// A bulk load stands between everything this client can read and the
        /// room (#3435, #3437 behaviors 29 and 31). NOT a refusal: the ingest's
        /// own base is being built and the `snapshot.ready` that announces it
        /// is what this document is waiting for. Reads keep answering and
        /// local writes keep committing; nothing goes out until it has
        /// converged. The caller runs ``runRebuild`` the moment a base past
        /// the boundary is on offer.
        case awaitBase
    }

    /// The base a `loadBase` plan names, and the grant to read it through.
    public struct BaseToLoad: Equatable, Sendable {
        /// The epoch the base is a base FOR, which is the epoch the document
        /// joins once it is in.
        public let epoch: Int
        /// The origin-relative signed path the manifest is at and the chunks
        /// are under. Never logged.
        public let grantPath: String
        /// How many rows the handshake said it carries, for the started event.
        public let rows: Int
    }

    public struct HandshakeOutcome: Equatable, Sendable {
        public let plan: HandshakePlan
        /// Frames the hold was keeping, now released in order. Empty unless
        /// the plan released the hold.
        public let released: [String]
        /// The base to stream in, on a `loadBase` plan; on `loadOverlays`, the
        /// epoch the chain starts at.
        public let base: BaseToLoad?
        /// The epoch the room reported — what a catch-up or a chain targets.
        public let reported: Int
        /// The sealed chain the frame named, for the caller that has to run it.
        ///
        /// Carried on every plan that needs archives, because the frame is the
        /// only place it appears: a seal does not carry one, and the caller
        /// would otherwise have to re-handshake to learn what it was just told.
        public let sealed: [SealedEpochChainEntry]

        init(
            plan: HandshakePlan,
            released: [String],
            base: BaseToLoad? = nil,
            reported: Int = 0,
            sealed: [SealedEpochChainEntry] = []
        ) {
            self.plan = plan
            self.released = released
            self.base = base
            self.reported = reported
            self.sealed = sealed
        }
    }

    /// Handle an `epoch.info` frame.
    ///
    /// - Parameter now: this client's wall clock in milliseconds, so the
    ///   measured clock offset is a value the caller can pin in a test rather
    ///   than whatever `Date()` said.
    @discardableResult
    public func handleEpochInfo(
        _ frame: [String: Any],
        now: Int
    ) throws -> HandshakeOutcome {
        guard let documentId = frame["documentId"] as? String,
              let binding = binding(documentId)
        else {
            // A frame for a document this client is not holding. Logged and
            // dropped — NEVER treated as a join: a join moves the epoch mark,
            // and moving it for a document nobody holds would tell the next
            // open that it is current when it is not.
            logger?.debug(
                "[format2] epoch.info for a document that is not open, dropped:",
                frame["documentId"] as? String ?? "<none>"
            )
            return HandshakeOutcome(plan: .dropped, released: [])
        }
        guard let reported = frame["epoch"] as? Int else {
            logger?.warn("[format2] malformed epoch.info dropped for", documentId)
            return HandshakeOutcome(plan: .dropped, released: [])
        }

        // The window and the clock travel whatever else the frame says,
        // including to a client that cannot act on the rest of it.
        try binding.store.noteOfflineWindow(frame["offlineWindowDays"] as? Int)
        if let serverTime = frame["serverTime"] as? Int {
            try binding.store.noteClockOffset(serverTime - now)
        }

        // This handshake decides the document's state from here, so a base
        // load still streaming from an earlier one is superseded before the
        // decision is taken — otherwise a download that finishes after a
        // reconnect stopped the document would clear that refusal and release
        // its hold. A `loadBase` plan below claims a fresh attempt of its own.
        lock.withLock { supersedeBaseLoadLocked(documentId) }

        let held = try binding.store.epoch()
        // The room's own epoch, remembered. `snapshot.ready` names the epoch
        // its BASE covers and nothing else, so a rebuild triggered by one has
        // no other way to learn how far the room has rotated since — and a
        // rebuild that targets the base's epoch skips every sealed overlay
        // above it and then calls itself current (finding 3437-REVIEW-007).
        noteReported(documentId, reported)
        logger?.debug(
            "[format2] handshake", documentId, "held:", held, "reported:", reported
        )

        // The snapshot the handshake offered, if any: its epoch decides
        // whether a cold client can be made current from it alone.
        let snapshot = Format2Coordinator.decodeSnapshotOffer(frame["snapshot"])
        if let snapshot { noteSnapshot(documentId, snapshot) }
        let sealed = Format2Coordinator.decodeSealedChain(frame["sealedEpochs"])
        noteChainGrants(documentId, sealed)
        let plan = Format2ColdStart.plan(
            held: held,
            reported: reported,
            sealed: sealed,
            snapshotEpoch: snapshot?.epoch
        )
        logger?.debug(
            "[format2] handshake", documentId, "held:", held,
            "reported:", reported, "plan:", plan.kind
        )

        // `held == reported` is decided BEFORE the planner, which calls any
        // client holding an epoch `catch-up`: the marks already agreeing is
        // the one form of "behind" that is not behind at all.
        //
        // Every other plan the planner can produce is honoured here (#3437,
        // behavior 18) except the two that need a base past a bulk load —
        // `await-base` and a `converge` chain — which are phase C's and still
        // stop the document, as does `unavailable`.
        if held != reported {
            switch plan {
            case .join:
                break

            case .snapshot(let base):
                // Nothing is moved and no mark is written here. The load is a
                // download; the caller runs it and comes back through
                // `runBaseLoad`, which is where the document joins — and when
                // the base's epoch is below the room's, through `runColdChain`
                // after it.
                guard let grantPath = snapshot?.downloadPath, !grantPath.isEmpty
                else {
                    return stop(
                        binding, plan: plan,
                        because: "the base it needs came with no way to read it"
                    )
                }
                logger?.debug(
                    "[format2] cold start for", documentId,
                    "— loading the base for epoch", base,
                    "with the room on", reported
                )
                return HandshakeOutcome(
                    plan: .loadBase, released: [],
                    base: BaseToLoad(
                        epoch: base, grantPath: grantPath, rows: snapshot?.rows ?? 0
                    ),
                    reported: reported,
                    sealed: sealed
                )

            case .overlays(let base):
                // No base was ever built and the chain from the document's
                // first epoch is whole, so the chain IS the document. It is
                // applied UNDER the open overlay, exactly as a base is.
                logger?.debug(
                    "[format2] cold start for", documentId,
                    "— no base; the chain from epoch", base, "is the document"
                )
                return HandshakeOutcome(
                    plan: .loadOverlays, released: [],
                    base: BaseToLoad(epoch: base, grantPath: "", rows: 0),
                    reported: reported,
                    sealed: sealed
                )

            case .catchUp:
                // Behind the room, with an overlay of its own to carry. From
                // here until the move nothing the room sends for its current
                // epoch may reach that overlay (behavior 17).
                noteBehindTheRoom(binding)
                logger?.debug(
                    "[format2] catch-up owed for", documentId,
                    "— held", held, "reported", reported
                )
                return HandshakeOutcome(
                    plan: .catchUp, released: [],
                    reported: reported, sealed: sealed
                )

            case .awaitBase(let discontinuities):
                // A bulk load stands between every base on offer and the room.
                // The document is HELD, not stopped: the ingest's base is
                // being built, and until it is announced there is nothing
                // wrong with the view this client reads from — only with
                // anything it would send (behaviors 29 and 31).
                for epoch in discontinuities {
                    try binding.store.noteDiscontinuity(epoch: epoch)
                }
                hold.hold(documentId, reason: "awaiting a base past a bulk load")
                logger?.log(
                    "[format2] holding", documentId,
                    "until a base past the bulk load at epoch",
                    discontinuities.first ?? 0, "is announced"
                )
                return HandshakeOutcome(
                    plan: .awaitBase, released: [],
                    reported: reported, sealed: sealed
                )

            case .unavailable:
                return stop(binding, plan: plan, because: nil)
            }
        }

        try binding.store.noteSync(at: now, windowDays: frame["offlineWindowDays"] as? Int)
        try binding.store.setEpoch(reported)
        binding.clearReload()
        let released = hold.release(documentId, reason: "join")
        logger?.debug(
            "[format2] hold released for", documentId,
            "— join, releasing", released.count, "frame(s)"
        )
        return HandshakeOutcome(plan: .join, released: released)
    }

    /// Stop a document whose local state cannot be advanced in place.
    ///
    /// Nothing is loaded, the merged view is NOT discarded — it is what keeps
    /// answering reads — the old-epoch Y.Doc is never folded over a newer
    /// base, and `_pending_ops` and `_client_acks` are untouched: the writes
    /// this client owes are still owed. The hold stays set so none of them
    /// escapes onto an epoch the room has replaced.
    private func stop(
        _ binding: Format2DocumentBinding,
        plan: ColdStartPlan,
        because: String?
    ) -> HandshakeOutcome {
        logger?.warn(
            "[format2] reload required for", binding.documentId,
            "— plan:", plan.kind, because ?? ""
        )
        hold.hold(binding.documentId, reason: "reload required (\(plan.kind))")
        binding.requireReload(Format2Coordinator.reloadRequired(
            documentId: binding.documentId, plan: plan.kind, detail: because
        ))
        return HandshakeOutcome(plan: .reloadRequired, released: [])
    }

    /// Read the `sealedEpochs` array off an `epoch.info` frame.
    ///
    /// Here rather than beside the planner, which is pure: this is frame
    /// decoding, the same `json["x"] as? T` currency every arm of
    /// `handleWebSocketMessage` speaks, and keeping it here is what leaves the
    /// cold-start module with no untyped surface at all. Anything that is not
    /// an entry is skipped rather than guessed at — a chain link this client
    /// cannot read is a link it does not have, which is what
    /// `chainIsWhole` already decides on.
    static func decodeSealedChain(_ raw: Any?) -> [SealedEpochChainEntry] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { element in
            guard let entry = element as? [String: Any],
                  let epoch = entry["epoch"] as? Int
            else { return nil }
            return SealedEpochChainEntry(
                epoch: epoch,
                sealedAt: entry["sealedAt"] as? Int ?? 0,
                baseDiscontinuity: entry["baseDiscontinuity"] as? Bool ?? false,
                downloadPath: path(in: entry["download"])
            )
        }
    }

    /// The signed path out of a frame's `download` block.
    static func path(in download: Any?) -> String? {
        (download as? [String: Any])?["path"] as? String
    }

    /// The typed refusal a stopped document answers a write with, and the one
    /// its `ConnectionErrorEvent` carries.
    public static func reloadRequired(
        documentId: String, plan: String, detail: String? = nil
    ) -> JsBaoError {
        var details: [String: JSONValue] = [
            "documentId": .string(documentId),
            "plan": .string(plan),
        ]
        if let detail { details["detail"] = .string(detail) }
        return JsBaoError(
            code: .format2ReloadRequired,
            message: "Large document `\(documentId)` has to be reloaded before it "
                + "can be written to again: the room's epoch was replaced under it "
                + "(plan: \(plan)). Reads keep answering from the local view and "
                + "nothing written locally has been lost.",
            details: details
        )
    }

    // MARK: - Running a cold start's base load

    /// Stream in the base a `loadBase` plan named, then join.
    ///
    /// Run by the CALLER, off the frame handler: it is a download of however
    /// many megabytes the document is, and the socket's receive loop has to
    /// keep running underneath it — `epoch.info` is not the last frame this
    /// document will get.
    ///
    /// The order at the end is the point. The base is a set of ROWS, not a
    /// diff: every row it carries replaces what the merged view held. The open
    /// epoch's overlay — the changes since the base was cut — is the one part
    /// of the document that does not arrive through the load at all; this
    /// client syncs it as an ordinary Y.Doc, before the load, during it or
    /// after. So whatever of it had already been folded was overwritten by the
    /// load, and folding it again is what makes the merged view the document
    /// rather than the document as of the last rotation. It costs one walk of
    /// a bounded overlay and is idempotent.
    ///
    /// - Parameter attempt: the claim ``beginBaseLoad(_:)`` handed the caller.
    ///   `nil` claims one here, which is what a direct caller — a test driving
    ///   a load by hand — wants; the client claims its own before scheduling
    ///   the task, so the supersession happens with the decision.
    @discardableResult
    func runBaseLoad(
        documentId: String,
        base: BaseToLoad,
        source: Format2SnapshotSource,
        models: [String]? = nil,
        permittedModels: [String]? = nil,
        now: Int = Int(Date().timeIntervalSince1970 * 1000),
        attempt: Int? = nil,
        refoldOpenOverlay: Bool = true,
        finalizes: Bool = true
    ) throws -> HandshakeOutcome {
        guard let binding = binding(documentId) else {
            return HandshakeOutcome(plan: .dropped, released: [])
        }
        let attempt = attempt ?? beginBaseLoad(documentId)
        let manifest = try source.manifest()
        // Before the first chunk is asked for: what this device can hold
        // (#3437, behavior 34). A capped plan is not fetched and then
        // discarded — the skipped models' chunks are never downloaded at all,
        // so it is bytes not transferred as well as bytes not stored.
        let models = try models
            ?? hydrationModels(
                binding: binding, manifest: manifest, permitted: permittedModels
            )
        // Before the first chunk is asked for: the manifest read is itself a
        // network round trip, and a document closed or re-handshaked during it
        // has no use for however many megabytes would follow.
        guard baseLoadIsCurrent(documentId, attempt: attempt) else {
            return supersededLoad(documentId)
        }
        onSnapshotLoad?(DocumentSnapshotLoadEvent(
            documentId: documentId, phase: .started, epoch: manifest.epoch,
            rows: 0, totalRows: manifest.totalRows,
            chunks: 0, totalChunks: manifest.chunks.count, model: nil
        ))
        logger?.debug(
            "[format2] loading base", manifest.buildId, "for", documentId,
            "— epoch", manifest.epoch, manifest.totalRows, "row(s) over",
            manifest.chunks.count, "chunk(s)"
        )

        let result = try Format2SnapshotLoader.load(
            store: binding.store,
            manifest: manifest,
            fetchChunk: { try source.fetchChunk($0) },
            onProgress: { [weak self] progress in
                self?.onSnapshotLoad?(DocumentSnapshotLoadEvent(
                    documentId: documentId, phase: .progress, epoch: manifest.epoch,
                    rows: progress.rows, totalRows: progress.totalRows,
                    chunks: progress.chunks, totalChunks: progress.totalChunks,
                    model: progress.model
                ))
            },
            onModelReady: { [weak self] model in
                self?.onSnapshotLoad?(DocumentSnapshotLoadEvent(
                    documentId: documentId, phase: .model, epoch: manifest.epoch,
                    rows: 0, totalRows: manifest.totalRows,
                    chunks: 0, totalChunks: manifest.chunks.count, model: model
                ))
            },
            models: models
        )

        // Nothing below may run for a load something newer has overtaken: it
        // sets the epoch mark, clears the reload refusal and releases the
        // hold, and every one of those is a statement about the CURRENT state
        // of the document. The rows the load wrote stay — they are the base
        // this document has, the load marks say which chunks landed, and the
        // next open resumes from them.
        guard baseLoadIsCurrent(documentId, attempt: attempt),
              self.binding(documentId) === binding
        else { return supersededLoad(documentId) }

        // The open epoch's overlay, over the base that has just been written
        // under it. The whole document's rows moved, so every model watching it
        // is told once the operation is released.
        //
        // A RELOAD suppresses this and refolds at its own point: the Y.Doc it
        // holds may be an epoch the room archived long ago, and putting that
        // back on top of a base cut above it would restore a superseded state
        // (#3437, behaviors 21 and 22).
        if refoldOpenOverlay {
            let folded = try binding.writePath.withOperation { try binding.observer.catchUp() }
            binding.notifyFolded(folded)
        }
        // The mark, the refusal and the hold say this document is CURRENT, and
        // a rebuild's base is not on its own: the sealed overlays above it are
        // still to be applied and the fresh overlay still to be installed and
        // persisted. Writing them here would leave a crash in that window
        // restarting with the OLD epoch's Y.Doc under the NEW mark — the very
        // shape the move's persist-then-mark order exists to avoid — and would
        // let a local write in the meantime put a delta against the replaced
        // view on the wire (finding 3437-REVIEW-005). The rebuild writes all
        // three itself, once it really is current.
        var released: [String] = []
        if finalizes {
            try binding.store.noteSync(at: now)
            try binding.store.setEpoch(base.epoch)
            binding.clearReload()
            released = hold.release(documentId, reason: "cold start complete")
        }
        onSnapshotLoad?(DocumentSnapshotLoadEvent(
            documentId: documentId, phase: .loaded, epoch: manifest.epoch,
            rows: result.rows, totalRows: manifest.totalRows,
            chunks: result.chunks, totalChunks: manifest.chunks.count, model: nil
        ))
        logger?.debug(
            "[format2] base loaded for", documentId, "—", result.rows, "row(s),",
            result.chunks, "chunk(s),", result.resumed, "resumed,",
            result.refetched, "refetched; releasing", released.count, "frame(s)"
        )
        return HandshakeOutcome(plan: .join, released: released)
    }

    /// What an app said about the room it will give a large document, and the
    /// capability to plan against when it did not say (#3437, behavior 34).
    ///
    /// Set once by the client when it builds this coordinator. `nil` is an app
    /// that configured nothing, which probes the database's own volume.
    public var storageOptions: LargeDocumentStorageOptions?

    /// Which models this device is taking, decided before the first chunk.
    ///
    /// Durable, because a restart reconnects and starts folding the epoch
    /// overlay again: without the recorded scope that fold would quietly
    /// repopulate a skipped model with the handful of records the epoch
    /// touched, and a query over them would answer from a fragment.
    ///
    /// - Parameter permitted: the model set a PREVIOUS capped load recorded,
    ///   for a reload that has to stay inside it. It is the permitted set, not
    ///   the answer: handing it back unplanned would skip the probe entirely,
    ///   so a model that used to fit and has since outgrown the device would
    ///   be fetched and written with no over-quota refusal at all (finding
    ///   3437-REVIEW-010). Every base load plans first.
    /// - Returns: the models to fetch, or `nil` for the whole snapshot.
    private func hydrationModels(
        binding: Format2DocumentBinding,
        manifest: SnapshotManifest,
        permitted: [String]? = nil
    ) throws -> [String]? {
        let capability = storageOptions?.capability
            ?? binding.store.databaseDirectory.map {
                Format2StorageCapability.probe(directory: $0)
            }
        // No capability at all — an in-memory host, or a provider that does
        // not say where it lives. Refusing on ignorance would take large
        // documents away from every such host; the not-persistent refusal at
        // `openDocument` is what catches the one that genuinely cannot hold one.
        guard let capability else { return nil }
        let plan = try Format2StorageCapability.planSnapshotHydration(
            manifest: manifest,
            capability: capability,
            models: permitted ?? storageOptions?.models ?? [],
            completedChunks: Set(try binding.store.completedChunks(buildId: manifest.buildId))
        )
        guard plan.kind == .capped else {
            try binding.store.setHydrationScope(nil)
            return nil
        }
        logger?.warn(
            "[format2]", binding.documentId,
            "does not fit on this device: hydrating",
            plan.models.joined(separator: ", "), "and leaving",
            plan.skipped.joined(separator: ", "), "— a query on a model this "
                + "device does not hold is refused rather than answered short"
        )
        try binding.store.setHydrationScope(plan.models)
        return plan.models
    }

    /// A load that was overtaken. It commits nothing and releases nothing; the
    /// decision that overtook it owns the document.
    private func supersededLoad(_ documentId: String) -> HandshakeOutcome {
        logger?.debug(
            "[format2] a base load of", documentId,
            "was superseded — its completion is dropped"
        )
        return HandshakeOutcome(plan: .dropped, released: [])
    }

    // MARK: - epoch.seal, epoch.resync, snapshot.ready, epoch.grants

    /// What an `epoch.seal` or `epoch.resync` frame asks of this client
    /// (#3437, behaviors 10 and 12).
    public enum SealDecision: Equatable, Sendable {
        /// The frame was for a document this client does not hold, or it was
        /// malformed. Nothing happened.
        case dropped
        /// The epoch the frame names is one this document has already left —
        /// a duplicate seal, or a resync for an epoch behind it. Nothing to do
        /// (edge E1).
        case alreadyCurrent
        /// A resync naming the epoch the document is ON: the room could not
        /// integrate ONE frame and wants self-contained state, not a reload.
        /// The caller answers with the whole overlay.
        case resyncOwed
        /// Follow it onto a fresh overlay. The caller runs
        /// ``runEpochMove(documentId:next:now:)`` — off the frame handler,
        /// because it persists and the socket's receive loop has to keep
        /// running underneath it.
        case move(next: Int)
        /// This client is behind the room by more than the one epoch a move can
        /// cross, so the sealed chain has to be applied first (edge E2).
        ///
        /// A seal frame carries no chain, so the caller re-handshakes to learn
        /// which archives stand between the two epochs and then runs
        /// ``runCatchUp(documentId:target:sealed:fetch:now:)``. The document is
        /// NOT stopped — it keeps answering reads and accepting writes, and its
        /// overlay is held against the room's current epoch meanwhile.
        case catchUp(from: Int, to: Int)
        /// The document cannot be advanced in place.
        case stopped(JsBaoError)

        /// Compared by CODE for the stopped case, because `JsBaoError` carries
        /// a message and details that are diagnostics rather than identity —
        /// two refusals for the same reason are the same decision.
        public static func == (left: SealDecision, right: SealDecision) -> Bool {
            switch (left, right) {
            case (.dropped, .dropped),
                 (.alreadyCurrent, .alreadyCurrent),
                 (.resyncOwed, .resyncOwed):
                return true
            case (.move(let a), .move(let b)):
                return a == b
            case (.catchUp(let a, let b), .catchUp(let c, let d)):
                return a == c && b == d
            case (.stopped(let a), .stopped(let b)):
                return a.code == b.code
            default:
                return false
            }
        }
    }

    /// Decide what an `epoch.seal` or `epoch.resync` frame means.
    ///
    /// Synchronous and side-effect-light on purpose: it runs on the frame
    /// handler, and what it decides may be a download and a persist.
    @discardableResult
    public func handleEpochSeal(_ frame: [String: Any]) throws -> SealDecision {
        guard let documentId = frame["documentId"] as? String,
              let binding = binding(documentId)
        else {
            logger?.debug(
                "[format2] epoch frame for a document that is not open, dropped:",
                frame["documentId"] as? String ?? "<none>"
            )
            return .dropped
        }
        let kind = frame["type"] as? String ?? "epoch.seal"
        // `epoch.seal` names the epoch that REPLACES the sealed one in `next`;
        // `epoch.resync` names the epoch the room is already on.
        let target = frame["next"] as? Int ?? frame["epoch"] as? Int ?? 0
        let held = try binding.store.epoch()

        // A `resync` naming the epoch this client is ALREADY on is not a
        // rotation (finding 3436-B01, found live). The room sends it when ONE
        // frame could not be integrated — it says so itself: "asking for a
        // resync, which sends self-contained state" — and it keeps the update
        // in its log meanwhile. Nothing has moved, so stopping the document
        // here would refuse every later write on a document that is perfectly
        // current; a real large document draws these routinely while a burst
        // of writes is in flight.
        if kind == "epoch.resync", target > 0, target == held {
            logger?.debug(
                "[format2] resync for", documentId, "at epoch", held,
                "— a frame did not integrate; re-sending the whole overlay"
            )
            return .resyncOwed
        }

        // An epoch this document has already left: a duplicate seal, or a
        // resync naming an epoch behind the mark. Nothing to follow.
        if target > 0, target <= held {
            logger?.debug(
                "[format2]", kind, "for", documentId, "names epoch", target,
                "which it has already left (held:", held, ") — already-current"
            )
            return .alreadyCurrent
        }

        // One step forward, and this client is on the epoch being sealed: the
        // ordinary rotation, which it can follow in place.
        if kind == "epoch.seal", target == held + 1 {
            // A bulk load re-founded the document at the epoch being sealed
            // (#3435). The boundary is written BEFORE the move, and durably:
            // the sum of the overlays on either side of it is not the
            // document, so a client that crossed it and forgot would go on
            // writing against a view the server has replaced (behavior 28).
            if frame["baseDiscontinuity"] as? Bool == true {
                try binding.store.noteDiscontinuity(epoch: held)
                logger?.log(
                    "[format2] a bulk load re-founded", documentId, "at epoch",
                    held, "— its owed writes wait for a base past it"
                )
            }
            // Nothing built against the overlay the room has just archived may
            // leave from HERE, rather than from the move that discards the
            // queue several milliseconds later. A debounced flush waiting on a
            // write made just before the seal fires in that window: measured
            // live, the delta went out in the same millisecond as the move.
            //
            // What the room does with it is why the window matters. It cannot
            // integrate a delta against an epoch it has sealed, and it does not
            // drop it either — the structs stay unintegrated in the room's
            // document, and from then on EVERY frame from that connection is
            // answered with a resync request instead of an acknowledgement, for
            // ever. Held means KEPT: the write is the user's, it commits as it
            // always did, and the move carries its content onto the fresh
            // overlay.
            //
            // A document already held is left exactly as it is: its reason is
            // one a rotation knows nothing about, and the release below is what
            // would then give back a hold this never took.
            if hold.reason(documentId) == nil {
                hold.hold(documentId, reason: Self.sealHoldReason)
            }
            return .move(next: target)
        }

        // Behind the room by more than one epoch: the sealed chain between them
        // has to be applied before this client can be moved (edge E2). Moving
        // one step would leave the chain unapplied and the merged view short of
        // everything those epochs held, so it is handed to the catch-up
        // instead — and NOT stopped, because a chain nobody has tried yet is
        // not a document that has to be reloaded.
        //
        // The frame carries no chain (`epoch.seal` has no `sealedEpochs`), so
        // the caller needs a fresh `epoch.info` to learn the archives. From
        // here the held overlay is the client's own (behavior 17).
        if target > held + 1 {
            logger?.debug(
                "[format2]", kind, "for", documentId, "skips epochs (held:",
                held, "target:", target, ") — the sealed chain has to be applied"
            )
            // A base a load in flight is streaming was cut for an epoch the
            // room has replaced, so its completion must not make this document
            // current: the chain above it has not been applied.
            lock.withLock { supersedeBaseLoadLocked(documentId) }
            noteBehindTheRoom(binding)
            return .catchUp(from: held, to: target)
        }

        return .stopped(stopForSeal(binding, kind: kind))
    }

    /// Stop a document a seal has left behind.
    private func stopForSeal(
        _ binding: Format2DocumentBinding, kind: String
    ) -> JsBaoError {
        let error = Format2Coordinator.reloadRequired(
            documentId: binding.documentId, plan: kind
        )
        // The base a load in flight is streaming was cut for an epoch the room
        // has just replaced, so its completion must not release this hold.
        lock.withLock { supersedeBaseLoadLocked(binding.documentId) }
        hold.hold(binding.documentId, reason: kind)
        binding.requireReload(error)
        logger?.warn(
            "[format2] held", binding.documentId, "on", kind,
            "— writes refused until it reloads from a covering base"
        )
        return error
    }

    // MARK: - Running an epoch move

    /// What a move did.
    public enum MoveOutcome: Equatable, Sendable {
        /// The document is on `epoch` now, carrying its owed writes.
        case moved(epoch: Int)
        /// Another move got there first, or the document had already left the
        /// epoch being sealed.
        case alreadyCurrent
        /// The document is gone — closed or purged while the move waited.
        case dropped
    }

    /// Where a document's moves are serialized (#3437, behavior 12).
    ///
    /// One at a time per document: two moves interleaving would each read the
    /// owed ops off a different overlay and install a different fresh one, and
    /// the second swap would throw away the first's carry.
    private var moveTokens: [String: Int] = [:]

    /// Follow a seal onto a fresh overlay (#3437, behavior 10).
    ///
    /// Run by the CALLER, off the frame handler: it persists, and the socket's
    /// receive loop has to keep running underneath it.
    ///
    /// The order:
    ///
    /// 1. under the operation lock, settle the folds and read the owed ops;
    /// 2. build the fresh overlay with the carry written onto it, discard the
    ///    frames queued against the sealed one (every one is a delta against
    ///    an overlay the room has archived), and REBIND — from here a local
    ///    write lands on the fresh overlay (edge E5);
    /// 3. hand the fresh document to the manager, which swaps it in and
    ///    persists it, awaited;
    /// 4. in ONE store transaction, move the epoch mark and the sync mark.
    ///
    /// Step 3 before step 4 is what makes a crash in between safe: the restart
    /// holds the FRESH overlay under the OLD mark, and the next handshake's
    /// catch-up repairs that idempotently. The reverse order would restart
    /// with the SEALED overlay under the NEW mark and resend it whole into the
    /// new epoch (finding 3437-R05, edge E7).
    @discardableResult
    public func runEpochMove(
        documentId: String,
        next: Int,
        now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) async throws -> MoveOutcome {
        // Serialized per document. The token is taken synchronously, so two
        // callers cannot both read "nothing in flight".
        let token = await claimMove(documentId)
        defer { releaseMove(documentId, token: token) }
        // A move that crosses a bulk load defers its carry (behavior 28). The
        // boundary was written before this ran, by the handshake or the seal
        // that learned of it, so the decision is read off the store rather
        // than passed along — which is also what makes it survive a restart.
        var deferring: DeferredReplayKind?
        if let binding = binding(documentId) {
            let held = try binding.store.epoch()
            if try binding.store.discontinuityEpochs().contains(where: { $0 >= held }) {
                deferring = .discontinuity
            }
        }
        return try await performMove(
            documentId: documentId, next: next, now: now, deferring: deferring
        )
    }

    /// The move itself, for a caller that already holds the document's turn.
    ///
    /// A catch-up takes the turn for the whole of its chain AND the move that
    /// ends it (behavior 12), so the move body is here and the claiming is in
    /// ``runEpochMove(documentId:next:now:)`` — a second claim from inside the
    /// catch-up would wait for a turn the catch-up itself is holding.
    /// - Parameter evenIfCurrent: install the fresh overlay even though the
    ///   epoch mark already reads as `next`. A RELOAD's base load moves the
    ///   mark onto the base's epoch before the swap can run, so "already
    ///   current" there is a statement about the MARK while the open Y.Doc is
    ///   still the overlay of an epoch the room archived long ago — and
    ///   refolding that over the base would restore a superseded state. Found
    ///   live: the reload published this client's owed write and never folded
    ///   it, because stating a value the stale overlay already held changed no
    ///   key and so captured nothing.
    private func performMove(
        documentId: String,
        next: Int,
        now: Int,
        deferring: DeferredReplayKind? = nil,
        evenIfCurrent: Bool = false
    ) async throws -> MoveOutcome {
        guard let binding = binding(documentId) else {
            releaseSealHold(documentId)
            return .dropped
        }
        let held = try binding.store.epoch()
        guard next > held || evenIfCurrent else {
            logger?.debug(
                "[format2] a move of", documentId, "to epoch", next,
                "found it already on", held, "— already-current"
            )
            // Something else moved it between the seal being read and this
            // running. The release at the end of a move is what gives back the
            // hold the seal took, and this path never reaches one.
            releaseSealHold(documentId)
            return .alreadyCurrent
        }

        // (1) and (2), under the operation lock: nothing may commit between
        // reading the owed values off the sealed overlay and installing the
        // fresh one.
        let fresh = YDocument()
        binding.settleFolds()
        var note: DeferredReplayNote?
        try binding.writePath.withOperation {
            try binding.writePath.foldPendingUnderOperation()
            let owed = try binding.store.pendingOps()

            // A returning client's carry is DEFERRED (#3437, behavior 20). Its
            // owed writes were made against an epoch the room archived while
            // it was away, so replaying them unconditionally is the original
            // D1 — it overwrites whatever anyone else wrote in between. The
            // fresh overlay is installed WITHOUT them, their sequences are
            // withheld from every claim before it is installed, and the note
            // that says so goes into the same transaction as the mark.
            if let kind = deferring, let through = owed.map(\.seq).max() {
                outbound.withhold(documentId, upTo: through)
                note = DeferredReplayNote(
                    throughSeq: through, fromEpoch: held, toEpoch: next, kind: kind
                )
                logger?.log(
                    "[format2] holding", owed.count, "unsent sequence(s) of",
                    documentId, "back until they are judged"
                )
            } else {
                let sealed = binding.overlay
                let carried = Format2EpochHandoff.carryUnackedOverlay(
                    ops: owed,
                    read: { model, recordId in
                        sealed.recordEntry(model: model, recordId: recordId)
                    }
                )
                let freshOverlay = OverlayDocument(document: fresh)
                for entry in carried {
                    Format2EpochHandoff.writeCarriedOverlay(
                        into: freshOverlay, model: entry.model, entry: entry.entry
                    )
                }
                logger?.debug(
                    "[format2] epoch move of", documentId, "from", held, "to",
                    next, "— carrying", carried.count, "record(s) for",
                    owed.count, "owed write(s)"
                )
            }
            // Every queued frame is a delta against the overlay the room has
            // archived; the fresh overlay carries their content afresh. BOTH
            // halves go: the ledger's claimed places, and the queued update
            // BYTES the transport would otherwise still send.
            forgetQueuedUpdates(documentId: documentId)
            discardQueuedUpdates?(documentId)
            // And the THIRD half, which neither of those can reach: a payload
            // already taken off that queue and waiting on an R2 upload to
            // complete before its frame goes out (#3559). Bumping the
            // generation here is what makes the dispatch at the far end of
            // that upload find itself stale and send nothing.
            invalidateOutboundGeneration(documentId)
            binding.rebind(to: fresh)
        }

        // (3) The manager's trio, and the fresh overlay on disk, awaited.
        if let replaceDocument { await replaceDocument(documentId, fresh) }

        // (4) The marks, together — and the judgement note with them, so a
        // crash cannot leave the mark moved with the debt unrecorded.
        try binding.store.withTransaction {
            try binding.store.setEpoch(next)
            try binding.store.noteSync(at: now)
            if let note {
                try binding.store.noteDeferredReplay(
                    throughSeq: note.throughSeq, fromEpoch: note.fromEpoch,
                    toEpoch: note.toEpoch, kind: note.kind
                )
            }
        }
        binding.clearReload()
        let released = hold.release(documentId, reason: "epoch move")
        logger?.log(
            "[format2] epoch move", documentId, held, "→", next,
            "— releasing", released.count, "frame(s)"
        )
        return .moved(epoch: next)
    }

    /// Hand the fresh epoch document to whatever owns the open documents.
    ///
    /// Injected rather than reached for: the coordinator knows about overlays,
    /// stores and frames, and `DocumentManager` knows about open documents and
    /// their persistence. A move needs both, and this is the seam between them.
    public var replaceDocument: (@Sendable (String, YDocument) async -> Void)?

    /// Drop the outbound updates still QUEUED for this document.
    ///
    /// Injected for the same reason `replaceDocument` is: the queue belongs to
    /// the client's transport, not to the coordinator. Every queued update is
    /// a delta against the overlay the room has archived — the room parks such
    /// a frame instead of integrating it, and then answers every later update
    /// from that connection with a resync request rather than an
    /// acknowledgement, permanently. The carry has already put the same
    /// content on the fresh overlay, so dropping them loses nothing.
    public var discardQueuedUpdates: (@Sendable (String) -> Void)?

    /// Wait until this document has no move in flight, then claim it.
    private func claimMove(_ documentId: String) async -> Int {
        while true {
            let claimed: Int? = lock.withLock {
                if moveTokens[documentId] != nil { return nil }
                let token = (moveTokens[documentId] ?? 0) + 1
                moveTokens[documentId] = token
                return token
            }
            if let claimed { return claimed }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func releaseMove(_ documentId: String, token: Int) {
        lock.withLock {
            if moveTokens[documentId] == token { moveTokens.removeValue(forKey: documentId) }
        }
    }

    // MARK: - Running a catch-up over the sealed chain (#3437, behavior 16)

    /// How a catch-up ended.
    public enum CatchUpOutcome: Equatable, Sendable {

        /// Why the chain cannot be trusted, as the document is told.
        public enum Refusal: String, Equatable, Sendable {
            /// The chain skips an epoch.
            case gap
            /// An archive the chain needs has been pruned.
            case unavailable
            /// A verified chain that could not be READ — twice.
            case failed
        }

        /// The document is gone — closed or purged while the chain ran.
        case dropped
        /// There was nothing to catch up.
        case none(reason: FastForwardPlan.NoneReason)
        /// The chain landed and the document moved onto `epoch`.
        case caughtUp(applied: [Int], epoch: Int)
        /// A bulk load stands between the chain and the room's epoch (#3435).
        /// Handed back rather than run: converging needs a BASE folded between
        /// the chain and the move, which this path cannot fetch.
        case converge(from: Int, discontinuities: [Int])
        /// Nothing was downloaded and nothing was moved.
        case reload(reason: Refusal, epoch: Int)
    }

    /// The sealed overlays this document has applied, as evidence.
    ///
    /// Kept per document, because it is what a returning client's owed writes
    /// are judged against AFTER the chain has landed (behavior 20) — the epochs
    /// are decoded once, while they are being folded, and the conflict
    /// detection costs one walk of artifacts the client was downloading anyway.
    private var ledgers: [String: OfflineConflictLedger] = [:]

    /// The conflict ledger the chain built for this document, if any.
    public func conflictLedger(_ documentId: String) -> OfflineConflictLedger? {
        lock.withLock { ledgers[documentId] }
    }

    /// The document's ledger, created on first use.
    func conflictLedgerForUpdate(_ documentId: String) -> OfflineConflictLedger {
        lock.withLock {
            if let existing = ledgers[documentId] { return existing }
            let created = OfflineConflictLedger()
            ledgers[documentId] = created
            return created
        }
    }

    /// Forget a document's evidence — the judgement it was for has run.
    func discardConflictLedger(_ documentId: String) {
        lock.withLock { _ = ledgers.removeValue(forKey: documentId) }
    }

    /// Apply the sealed chain between the epoch this document holds and the one
    /// the room reports, then move onto it (#3437, behavior 16).
    ///
    /// Run by the CALLER, off the frame handler: it is a download per epoch and
    /// the socket's receive loop has to keep running underneath it.
    ///
    /// The order is the behavior. Nothing is downloaded until the chain is
    /// known to be complete, each archive is folded WHOLE in one transaction
    /// under the operation lock, and the epoch mark is not moved until every
    /// archive has landed — so a chain that fails halfway leaves the client
    /// exactly where it was: behind, readable, and told to reload, rather than
    /// half-caught-up on an epoch it would then write into.
    ///
    /// One retry of the remainder, and only one. An archive read that fails
    /// twice is not an expiry or a blip, and a runner that kept trying would be
    /// indistinguishable from one that had hung (edge E4).
    @discardableResult
    public func runCatchUp(
        documentId: String,
        target: Int,
        sealed: [SealedEpochChainEntry],
        fetch: @escaping @Sendable (FastForwardStep) throws -> Data,
        now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) async throws -> CatchUpOutcome {
        // A catch-up holds the document's turn for its whole chain AND the move
        // that ends it: a seal landing halfway would otherwise install a fresh
        // overlay under a chain still folding into the old one (behavior 12).
        let token = await claimMove(documentId)
        defer { releaseMove(documentId, token: token) }

        guard let binding = binding(documentId) else { return .dropped }
        let held = try binding.store.epoch()
        let plan = Format2FastForward.plan(
            current: held, target: target, sealed: sealed
        )
        logger?.debug(
            "[format2] catch-up of", documentId, "held:", held, "target:", target,
            "plan:", plan.kind
        )

        switch plan {
        case .none(let reason):
            // Overtaken: the seal this plan was made for was followed in place
            // before the chain ran, so there is nothing to apply and this
            // document is not behind the room. Nothing else will say so — the
            // undo lives at the end of a chain, which this path never reaches.
            endBehindTheRoom(documentId)
            return .none(reason: reason)

        case .reload(let reason, let epoch):
            // Nothing is downloaded and nothing is moved. The merged view is
            // NOT discarded — it is what keeps answering reads — and the
            // pending log is kept, because the writes this client owes are
            // still owed.
            logger?.warn(
                "[format2] the sealed-overlay chain cannot be applied for",
                documentId, "—", reason.rawValue, "at epoch", epoch
            )
            stopForChain(binding, reason: reason.rawValue, epoch: epoch)
            return .reload(
                reason: CatchUpOutcome.Refusal(rawValue: reason.rawValue) ?? .failed,
                epoch: epoch
            )

        case .converge(let from, let discontinuities, _):
            logger?.warn(
                "[format2] the chain of", documentId,
                "crosses a bulk load at epoch", discontinuities.first ?? 0,
                "— a base past it is owed before this client can move"
            )
            return .converge(from: from, discontinuities: discontinuities)

        case .apply(_, let to, let steps):
            let ledger = conflictLedgerForUpdate(documentId)
            ledger.noteSealTimes(sealed.map {
                (epoch: $0.epoch, sealedAt: $0.sealedAt > 0 ? $0.sealedAt : nil)
            })

            let applied: [Int]
            do {
                applied = try applyChainWithOneRetry(
                    steps, binding: binding, ledger: ledger, fetch: fetch
                )
            } catch let failure as Format2FastForwardChainError {
                logger?.warn(
                    "[format2] the sealed-overlay chain cannot be applied for",
                    documentId, "— failed at epoch", failure.epoch
                )
                stopForChain(binding, reason: "failed", epoch: failure.epoch)
                return .reload(reason: .failed, epoch: failure.epoch)
            }

            // The chain landed, so this client has reconciled with the server
            // up to the room's open epoch: the offline window's mark is earned
            // here exactly as a join and a completed base load earn it
            // (behavior 3).
            try binding.store.noteSync(at: now)
            // A client that was away has writes to judge, not to replay: the
            // chain it has just applied is the evidence, and the move defers
            // the carry so recency can have its say first (behavior 20).
            let owed = try binding.store.pendingOps()
            let moved = try await performMove(
                documentId: documentId, next: to, now: now,
                deferring: owed.isEmpty ? nil : .ordinary
            )
            // Whatever the move did, this document is no longer behind the
            // room: the fresh overlay's resync re-delivers the current epoch,
            // and the frames that were refused come back with it.
            clearBehindTheRoom(documentId)
            switch moved {
            case .dropped:
                return .dropped
            case .alreadyCurrent, .moved:
                logger?.log(
                    "[format2] catch-up of", documentId, "applied",
                    applied.count, "sealed overlay(s) and reached epoch", to
                )
                return .caughtUp(applied: applied, epoch: to)
            }
        }
    }

    /// Apply the chain, and on a failure apply the REMAINDER once more.
    ///
    /// The steps that landed are folded and re-folding them would be work for
    /// nothing, so the retry starts at the epoch that stopped — which is what
    /// `onApplied` recorded. Once, and only once (edge E4).
    private func applyChainWithOneRetry(
        _ steps: [FastForwardStep],
        binding: Format2DocumentBinding,
        ledger: OfflineConflictLedger,
        fetch: (FastForwardStep) throws -> Data
    ) throws -> [Int] {
        var applied: [Int] = []
        do {
            try applyChain(
                steps, binding: binding, ledger: ledger, fetch: fetch,
                into: &applied
            )
        } catch let failure as Format2FastForwardChainError {
            let done = Set(applied)
            let remaining = steps.filter { !done.contains($0.epoch) }
            logger?.warn(
                "[format2] the sealed-overlay chain of", binding.documentId,
                "stopped at epoch", failure.epoch, "— retrying once"
            )
            try applyChain(
                remaining, binding: binding, ledger: ledger, fetch: fetch,
                into: &applied
            )
        }
        return applied
    }

    /// Apply the chain a COLD start needs above its base, then complete it
    /// (#3437, behavior 18).
    ///
    /// A base is one epoch's worth of rows. When the room has rotated since it
    /// was cut — which it has whenever the build trails the room — the overlays
    /// sealed in between are the rest of the document, and a client that
    /// installed the base and called itself current would be missing every
    /// write in them. The design doc's three-layer invariant is `S_E ⊕ D_E` for
    /// ONE epoch.
    ///
    /// Nothing is swapped, and that is the difference from a catch-up: a cold
    /// client's open Y.Doc IS the room's current overlay, delivered by ordinary
    /// sync. So the chain goes UNDER it and the open overlay is refolded last —
    /// the changes since the last rotation on top of the chain, on top of the
    /// base.
    ///
    /// Run by the CALLER, off the frame handler, like the base load it follows.
    @discardableResult
    func runColdChain(
        documentId: String,
        from: Int,
        to: Int,
        fetch: (FastForwardStep) throws -> Data,
        sealed: [SealedEpochChainEntry],
        now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) throws -> HandshakeOutcome {
        var applied: [Int] = []
        return try runColdChain(
            documentId: documentId, from: from, to: to, fetch: fetch,
            sealed: sealed, now: now, applied: &applied
        )
    }

    /// The same, reporting which epochs landed — what a rebuild names in its
    /// log line and what a test asserts the chain above the base really was.
    func runColdChain(
        documentId: String,
        from: Int,
        to: Int,
        fetch: (FastForwardStep) throws -> Data,
        sealed: [SealedEpochChainEntry],
        now: Int = Int(Date().timeIntervalSince1970 * 1000),
        applied: inout [Int]
    ) throws -> HandshakeOutcome {
        guard let binding = binding(documentId) else {
            return HandshakeOutcome(plan: .dropped, released: [])
        }
        let plan = Format2FastForward.plan(current: from, target: to, sealed: sealed)

        switch plan {
        case .none:
            // Nothing stands between the base and the room. The base load has
            // already completed the document.
            break

        case .reload(let reason, let epoch):
            logger?.warn(
                "[format2] the chain above the base of", documentId,
                "cannot be applied —", reason.rawValue, "at epoch", epoch
            )
            stopForChain(binding, reason: reason.rawValue, epoch: epoch)
            return HandshakeOutcome(plan: .reloadRequired, released: [])

        case .converge(_, let discontinuities, _):
            // A bulk load stands between the base and the room, so the base on
            // offer is the wrong side of it. Phase C's rebuild owns this.
            logger?.warn(
                "[format2] the chain above the base of", documentId,
                "crosses a bulk load at epoch", discontinuities.first ?? 0
            )
            stopForChain(
                binding, reason: "discontinuity", epoch: discontinuities.first ?? 0
            )
            return HandshakeOutcome(plan: .reloadRequired, released: [])

        case .apply(_, _, let steps):
            let ledger = conflictLedgerForUpdate(documentId)
            ledger.noteSealTimes(sealed.map {
                (epoch: $0.epoch, sealedAt: $0.sealedAt > 0 ? $0.sealedAt : nil)
            })
            do {
                applied = try applyChainWithOneRetry(
                    steps, binding: binding, ledger: ledger, fetch: fetch
                )
            } catch let failure as Format2FastForwardChainError {
                logger?.warn(
                    "[format2] the chain above the base of", documentId,
                    "cannot be applied — failed at epoch", failure.epoch
                )
                stopForChain(binding, reason: "failed", epoch: failure.epoch)
                return HandshakeOutcome(plan: .reloadRequired, released: [])
            }
        }

        // The open epoch's overlay, over the chain that has just been written
        // under it. Last, and idempotent.
        let folded = try binding.writePath.withOperation {
            try binding.observer.catchUp()
        }
        binding.notifyFolded(folded)
        try binding.store.withTransaction {
            try binding.store.setEpoch(to)
            try binding.store.noteSync(at: now)
        }
        binding.clearReload()
        clearBehindTheRoom(documentId)
        let released = hold.release(documentId, reason: "cold chain complete")
        logger?.log(
            "[format2] cold start of", documentId, "applied", applied.count,
            "sealed overlay(s) above its base and reached epoch", to,
            "— releasing", released.count, "frame(s)"
        )
        return HandshakeOutcome(plan: .join, released: released)
    }

    /// Fetch, decode and fold each step in turn, noting it into the ledger.
    ///
    /// - Parameter applied: every epoch that landed, appended as it lands — so
    ///   a failure leaves behind which steps are already folded and the retry
    ///   starts at the one that stopped rather than at the beginning.
    private func applyChain(
        _ steps: [FastForwardStep],
        binding: Format2DocumentBinding,
        ledger: OfflineConflictLedger,
        fetch: (FastForwardStep) throws -> Data,
        into applied: inout [Int]
    ) throws {
        try Format2FastForward.apply(
            .apply(
                from: steps.first?.epoch ?? 0,
                to: (steps.last?.epoch ?? 0) + 1,
                steps: steps
            ),
            fetch: fetch,
            fold: { overlay, epoch in
                // Noted BEFORE it is folded: the ledger is a statement about
                // what the epoch touched, which the fold then makes true of
                // the merged view. Noting it afterwards would lose the record
                // of an epoch whose fold failed, and the retry would read a
                // chain it could not account for.
                ledger.noteOverlay(
                    epoch: epoch, overlay, models: binding.watchedModels
                )
                let folded = try binding.foldSealedOverlay(overlay, epoch: epoch)
                binding.notifyFolded(folded)
            },
            onApplied: { epoch, _, _ in applied.append(epoch) }
        )
    }

    /// Hold a document whose chain could not be applied.
    private func stopForChain(
        _ binding: Format2DocumentBinding, reason: String, epoch: Int
    ) {
        lock.withLock { supersedeBaseLoadLocked(binding.documentId) }
        hold.hold(binding.documentId, reason: "catch-up (\(reason))")
        binding.requireReload(Format2Coordinator.reloadRequired(
            documentId: binding.documentId,
            plan: "catch-up",
            detail: "the sealed-overlay chain cannot be applied "
                + "(\(reason) at epoch \(epoch))"
        ))
    }

    // MARK: - Reloading whole from a base (#3437, behaviors 21, 22, 29 and 31)

    /// Why a document is being reloaded whole rather than advanced in place.
    public enum RebuildReason: String, Equatable, Sendable {
        /// The sealed chain between the epoch this client holds and the room's
        /// cannot be trusted — an epoch missing from it, or an archive
        /// retention has taken (behavior 22).
        case refusedChain = "refused-chain"
        /// A replay's resolution would drop a delete. A merged view the delete
        /// has already been folded into cannot put the record back from
        /// anything it holds, so the record comes back from a base (behavior 21).
        case droppedDelete = "dropped-delete"
        /// A bulk load re-founded the document (#3435). No chain crosses it,
        /// which is what the flag on the sealed epoch says (behaviors 29, 31).
        case discontinuity
    }

    /// How a reload ended.
    public enum RebuildOutcome: Equatable, Sendable {
        /// The document is gone — closed or purged while the base streamed —
        /// or something newer overtook the load.
        case dropped
        /// The view is the base plus every sealed overlay above it plus the
        /// open one, and the mark is the room's epoch.
        case rebuilt(epoch: Int, applied: [Int])
        /// The base could not be loaded, or the chain above it could not be
        /// applied. The document is held and told to reload.
        case refused(JsBaoError)

        public static func == (left: RebuildOutcome, right: RebuildOutcome) -> Bool {
            switch (left, right) {
            case (.dropped, .dropped):
                return true
            case (.rebuilt(let a, let b), .rebuilt(let c, let d)):
                return a == c && b == d
            case (.refused(let a), .refused(let b)):
                return a.code == b.code
            default:
                return false
            }
        }
    }

    /// Throw this document's view away and build it again from `base`
    /// (#3437, behaviors 21, 22, 29 and 31).
    ///
    /// The intent's Swift rule: a document that cannot be advanced in place is
    /// RELOADED from the latest snapshot, never range-replaced. So this is the
    /// ordinary cold path — load the base whole, apply the sealed overlays
    /// above it, refold the open one — run over a view that has been discarded
    /// first, which is the only difference from a first open.
    ///
    /// Applying the chain above the base is not optional. A base announced at
    /// epoch B while the room is already on R > B is B..R−1 sealed overlays
    /// short of the document, and a client that installed it and called itself
    /// current would have dropped every write that lives only in them — the
    /// design doc's three-layer invariant is `S_E ⊕ D_E` for ONE epoch
    /// (finding 3437-SO-04).
    ///
    /// The owed writes are judged at the end rather than replayed: whatever
    /// evidence the chain above the base carries is what they are judged
    /// against, and a write made below the base's epoch is `unverifiable` —
    /// kept, and said to be unverifiable rather than silently trusted.
    ///
    /// Run by the CALLER, off the frame handler: it is a download of however
    /// many megabytes the document is.
    @discardableResult
    func runRebuild(
        documentId: String,
        base: BaseToLoad,
        source: Format2SnapshotSource,
        reported: Int,
        sealed: [SealedEpochChainEntry],
        reason: RebuildReason,
        fetch: @escaping (FastForwardStep) throws -> Data,
        permittedModels: [String]? = nil,
        now: Int = Int(Date().timeIntervalSince1970 * 1000),
        attempt: Int? = nil
    ) async throws -> RebuildOutcome {
        // A rebuild holds the document's turn for the whole of it: a seal
        // landing halfway would otherwise install a fresh overlay over a view
        // that is still being replaced (behavior 12).
        let token = await claimMove(documentId)
        defer { releaseMove(documentId, token: token) }
        guard let binding = binding(documentId) else { return .dropped }

        let held = try binding.store.epoch()
        let target = max(reported, base.epoch)
        logger?.log(
            "[format2] rebuilding", documentId, "from base", base.epoch,
            "past the discontinuity at", try binding.store.discontinuityEpochs().last ?? 0,
            "— reason:", reason.rawValue, "held:", held, "room:", target
        )

        // The merged view AND its projections. A record the replacement base
        // does not carry has to be gone from `query`, `count`, `aggregate` and
        // the stringset index as well as from `find` (finding 3437-SO-05).
        try binding.store.discardMergedView()

        let loaded = try runBaseLoad(
            documentId: documentId, base: base, source: source,
            // The scope a capped load recorded is what this device is ALLOWED
            // to hold, not a plan: the replacement base is planned against the
            // device's capacity afresh (finding 3437-REVIEW-010).
            permittedModels: permittedModels, now: now, attempt: attempt,
            refoldOpenOverlay: false,
            // The base alone does not make this document current: the chain
            // above it is still to be applied and the fresh overlay still to
            // be installed (finding 3437-REVIEW-005). The mark, the refusal
            // and the hold are written at the end of THIS method.
            finalizes: false
        )
        guard loaded.plan == .join else { return .dropped }

        var applied: [Int] = []
        let chainPlan = Format2FastForward.plan(
            current: base.epoch, target: target, sealed: sealed
        )
        switch chainPlan {
        case .none:
            // The base already covers the room's epoch: nothing stands above it.
            break

        case .apply(_, _, let steps):
            let ledger = conflictLedgerForUpdate(documentId)
            ledger.noteSealTimes(sealed.map {
                (epoch: $0.epoch, sealedAt: $0.sealedAt > 0 ? $0.sealedAt : nil)
            })
            do {
                applied = try applyChainWithOneRetry(
                    steps, binding: binding, ledger: ledger, fetch: fetch
                )
            } catch let failure as Format2FastForwardChainError {
                logger?.warn(
                    "[format2] the chain above the rebuilt base of", documentId,
                    "cannot be applied — failed at epoch", failure.epoch
                )
                stopForChain(binding, reason: "failed", epoch: failure.epoch)
                return .refused(Format2Coordinator.reloadRequired(
                    documentId: documentId, plan: "rebuild",
                    detail: "the sealed-overlay chain above base \(base.epoch) "
                        + "could not be applied (failed at epoch \(failure.epoch))"
                ))
            }
            logger?.log(
                "[format2] rebuild applied", applied.count,
                "sealed overlay(s) above the base of", documentId
            )

        case .reload(let refusal, let epoch):
            // A gap in the chain, or an archive the room no longer holds. The
            // base plus what IS readable does not reach the room's epoch, and
            // finishing anyway would mark this document current while every
            // write that lives only in the missing overlays is gone (finding
            // 3437-REVIEW-008). Held, with the view the base left and the
            // pending log intact, until a base closer to the room is offered.
            logger?.warn(
                "[format2] the chain above the rebuilt base of", documentId,
                "cannot be applied —", refusal.rawValue, "at epoch", epoch
            )
            stopForChain(binding, reason: refusal.rawValue, epoch: epoch)
            return .refused(Format2Coordinator.reloadRequired(
                documentId: documentId, plan: "rebuild",
                detail: "the sealed-overlay chain above base \(base.epoch) is "
                    + "\(refusal.rawValue) at epoch \(epoch)"
            ))

        case .converge(_, let discontinuities, _):
            // A SECOND bulk load stands between this base and the room, so
            // this base is on the wrong side of it too. The discontinuity is
            // recorded and the document waits for a base past that one.
            for epoch in discontinuities { try binding.store.noteDiscontinuity(epoch: epoch) }
            logger?.warn(
                "[format2] the base of", documentId, "at epoch", base.epoch,
                "is below a further bulk load at epoch", discontinuities.first ?? 0,
                "— a base past that one is owed"
            )
            stopForChain(
                binding, reason: "unavailable", epoch: discontinuities.first ?? target
            )
            return .refused(Format2Coordinator.reloadRequired(
                documentId: documentId, plan: "rebuild",
                detail: "base \(base.epoch) is below a further bulk load at "
                    + "epoch \(discontinuities.first ?? target)"
            ))
        }

        // What the open Y.Doc holds decides whether it may be refolded.
        //
        // A document that was CURRENT with the room holds the room's current
        // overlay — ordinary sync delivered it — so it goes back on top, as a
        // cold start's does. A document BEHIND the room holds an epoch the
        // room archived long ago, and refolding it over a base cut above it
        // would put a superseded state back on top of the rows that replaced
        // it. That one moves instead: a fresh overlay for the room's epoch,
        // whose resync delivers what the room actually has (behavior 17's rule
        // in the shape a reload needs it).
        if held < target {
            let moved = try await performMove(
                documentId: documentId, next: target, now: now,
                deferring: reason == .discontinuity ? .discontinuity : .ordinary,
                // The mark is still the epoch this document HELD when the
                // reload began — the base load no longer moves it — so the
                // guard reads it correctly. Passed anyway for the one case
                // that would still read as current: a reload whose target is
                // the epoch the mark already names while the open Y.Doc
                // belongs to an epoch the room archived long ago.
                evenIfCurrent: true
            )
            if moved == .dropped { return .dropped }
            try judgeAfterRebuild(
                binding: binding, held: held, target: target, reason: reason, now: now
            )
        } else {
            try binding.store.withTransaction {
                try binding.store.setEpoch(target)
                try binding.store.noteSync(at: now)
            }
            // The judgement runs BEFORE the refold here, not after: a delete it
            // drops has to come off the live overlay first, or the refold puts
            // the tombstone straight back over the record the base restored.
            try judgeAfterRebuild(
                binding: binding, held: held, target: target, reason: reason, now: now
            )
            let folded = try binding.writePath.withOperation {
                try binding.observer.catchUp()
            }
            binding.notifyFolded(folded)
        }
        binding.clearReload()
        clearBehindTheRoom(documentId)
        // The frames the hold was keeping are dropped rather than returned, as
        // a catch-up's are: each is a delta against a view that has just been
        // replaced whole, and what the caller sends instead is the one
        // self-contained frame `answerResync` builds.
        _ = hold.release(documentId, reason: "rebuild complete")

        // The derived tables are copied afresh from the reloaded view. The
        // discard took their marks, so nothing returns early and what they end
        // up holding is exactly what `find` now answers.
        binding.projection.reprojectAll(store: binding.store)
        return .rebuilt(epoch: target, applied: applied)
    }

    /// Documents with a reload in flight (#3437, edge E11).
    ///
    /// A reload runs with the document's refusal still set — the refusal is
    /// what it is answering — so "is this document stuck?" is true for the
    /// whole of it, and a `snapshot.ready` arriving meanwhile would start a
    /// SECOND reload over the first. The second one discards the merged view
    /// again, which takes with it the writes the first one had just judged and
    /// stated: found live, on a build that completed while the reload it
    /// triggered was still running.
    private var rebuilding: Set<String> = []

    /// Claim this document's reload. `false` when one is already running, and
    /// the caller does nothing.
    public func beginRebuild(_ documentId: String) -> Bool {
        lock.withLock { rebuilding.insert(documentId).inserted }
    }

    public func endRebuild(_ documentId: String) {
        lock.withLock { _ = rebuilding.remove(documentId) }
    }

    /// Whether a reload is running for this document.
    public func isRebuilding(_ documentId: String) -> Bool {
        lock.withLock { rebuilding.contains(documentId) }
    }

    /// The base the room has offered this document, when one stands past every
    /// bulk load it has crossed (#3437, behaviors 22 and 29).
    ///
    /// `nil` when nothing has been offered, or when the newest offer is at or
    /// below the highest discontinuity: a base cut on the wrong side of a bulk
    /// load is not a base this document can be re-founded on.
    public func rebuildBaseOnOffer(_ documentId: String) -> BaseToLoad? {
        guard let binding = binding(documentId),
              let offer = snapshotInfo(documentId),
              let path = offer.downloadPath, !path.isEmpty
        else { return nil }
        let boundary = (try? binding.store.discontinuityEpochs().max()) ?? nil
        if let boundary, offer.epoch <= boundary { return nil }
        return BaseToLoad(epoch: offer.epoch, grantPath: path, rows: offer.rows)
    }

    /// Settle the owed writes after a reload, whether or not a note was owed.
    ///
    /// A reload after a REFUSED chain has no note — the catch-up refused before
    /// it moved anything — and its owed writes still have to be judged, or they
    /// would be published as if nobody had written anything in the meantime.
    /// So a note is synthesised over everything outstanding, which reads the
    /// same to the judgement as one the move wrote.
    private func judgeAfterRebuild(
        binding: Format2DocumentBinding,
        held: Int,
        target: Int,
        reason: RebuildReason,
        now: Int
    ) throws {
        let documentId = binding.documentId
        let recorded = try binding.store.deferredReplay()
        let outstanding = try binding.store.pendingOps()
        let note = recorded ?? outstanding.map(\.seq).max().map({
            DeferredReplayNote(
                throughSeq: $0, fromEpoch: held, toEpoch: target,
                kind: reason == .discontinuity ? .discontinuity : .ordinary
            )
        })

        if let note {
            let ingest = reason == .discontinuity
                ? try presenceOfOwedRecords(binding: binding, ops: outstanding, note: note)
                : nil
            _ = try judge(
                binding: binding, note: note,
                ledger: conflictLedgerForUpdate(documentId),
                now: now, resumed: recorded != nil, rebuilding: true, ingest: ingest
            )
        }

        // The marker goes whether or not anything was owed on it (finding
        // 3437-REVIEW-011). It records that this client has not converged on a
        // bulk load, and the rebuild above IS that convergence: a client with
        // nothing pending when the ingest landed would otherwise keep the
        // marker for ever and reload again from every later `snapshot.ready`.
        if reason == .discontinuity {
            let boundary = try binding.store.discontinuityEpochs().max() ?? 0
            if boundary > 0 { try binding.store.clearDiscontinuities(through: boundary) }
        }
    }

    /// Whether each owed record is in the rebuilt view (#3437, behavior 29).
    ///
    /// The recency machinery cannot answer for a write that raced a bulk load:
    /// it works from the sealed overlays the chain folded, and a bulk load's
    /// changes are in none of them. What IS a fact once the base has landed is
    /// whether the record is there — so presence decides, read once over
    /// exactly the records these ops name.
    ///
    /// `scope: .all` because this client cannot name the ranges of every
    /// ingest it crossed: a record missing from the map is then information
    /// nobody has, and a write is never discarded on that.
    private func presenceOfOwedRecords(
        binding: Format2DocumentBinding,
        ops: [PendingOp],
        note: DeferredReplayNote
    ) throws -> OfflineReplayIngest {
        let owed = ops.filter { $0.seq <= note.throughSeq }
        var byModel: [String: [String]] = [:]
        for op in owed { byModel[op.model, default: []].append(op.recordId) }
        var records: [String: OfflineReplayIngest.Presence] = [:]
        for (model, ids) in byModel {
            // A model this device does not hold cannot be read and must not be
            // guessed at: it is left out of the map, which `scope: .all` reads
            // as "nobody knows" (edge E10).
            guard (try? binding.store.isHydrated(model)) == true else { continue }
            let rows = try binding.store.readMany(model: model, recordIds: ids)
            for (id, row) in zip(ids, rows) {
                records[Format2OfflineReplay.recordKey(model, id)] =
                    row == nil ? .absent : .present
            }
        }
        let boundary = try binding.store.discontinuityEpochs().max() ?? note.toEpoch
        return OfflineReplayIngest(through: boundary, scope: .all, records: records)
    }

    // MARK: - Completing a deferred judgement (#3437, behaviors 20 and 20a)

    /// What a deferred judgement did.
    public struct DeferredReplayOutcome: Equatable, Sendable {
        /// The epoch the writes were judged against and replayed onto.
        public let epoch: Int
        /// Sequences the online side clearly beat. Forgotten from
        /// `_pending_ops`: leaving them would replay them at the next open.
        public let dropped: [Int]
        /// Sequences that survived in PART, rewritten in the durable row.
        public let narrowed: [Int]
        /// Sequences stated on the live overlay, which is what publishes them.
        public let stated: [Int]
        public let notices: [OfflineReplayNotice]
        /// Whether this judgement was picked up from a durable note after a
        /// restart rather than run in the session that deferred it.
        public let resumed: Bool
        /// The resolution would DROP a delete, which a merged view the delete
        /// has already been folded into cannot carry out: the record has to
        /// come back from a base (#3437, behavior 21). Nothing was applied,
        /// nothing was forgotten and the note still stands — the caller
        /// reloads from the latest base on offer and judges again there.
        public let rebuildRequired: Bool
    }

    /// Judge the writes the move deferred, now that the joined epoch's content
    /// has arrived (#3437, behavior 20).
    ///
    /// Called on the joined epoch's `syncComplete`: until then the open
    /// overlay is only as much of the epoch as has been delivered, and a
    /// judgement against a half-arrived epoch would read a field nobody had
    /// written yet as uncontested. That is also why it is not called from
    /// `epoch.info`, which the room sends BEFORE the `syncStep2` carrying that
    /// content (finding 3437-REVIEW-002).
    ///
    /// A DISCONTINUITY note is not this path's to settle. Its writes raced a
    /// bulk load, whose changes are in no sealed overlay at all, so the only
    /// evidence that can decide them is whether the record is in the rebuilt
    /// view — which is `judgeAfterRebuild`'s presence input, and exists only
    /// once the replacement base has landed (finding 3437-REVIEW-001).
    ///
    /// - Returns: `nil` when there is no judgement owed, which is every
    ///   ordinary sync.
    @discardableResult
    public func completeDeferredReplay(
        documentId: String,
        now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) throws -> DeferredReplayOutcome? {
        guard let binding = binding(documentId),
              let note = try binding.store.deferredReplay()
        else { return nil }
        guard note.kind == .ordinary else {
            logger?.debug(
                "[format2] the deferred replay of", documentId,
                "waits for a base past the bulk load at epoch",
                (try? binding.store.discontinuityEpochs().max() ?? 0) ?? 0,
                "— presence is what decides it, not recency"
            )
            return nil
        }
        let ledger = conflictLedgerForUpdate(documentId)
        let resumed = lock.withLock { resumedNotes.contains(documentId) }
        return try judge(
            binding: binding, note: note, ledger: ledger, now: now, resumed: resumed
        )
    }

    /// Documents whose deferred judgement was picked up from a durable note
    /// rather than run in the session that deferred it.
    private var resumedNotes: Set<String> = []

    /// Whether a judgement is owed whose EVIDENCE this session does not have.
    ///
    /// True only for a note a restart left behind: the session that deferred
    /// keeps its conflict ledger in memory, so a deferral made in this one has
    /// its chain already read and needs no download at all. The caller uses it
    /// to decide whether to pay for ``resumeDeferredReplay(documentId:sealed:fetch:now:)``,
    /// which reads archives and therefore may not run on the socket's receive
    /// loop (finding 3437-REVIEW-009).
    public func deferredReplayNeedsChain(_ documentId: String) -> Bool {
        guard let binding = binding(documentId),
              let note = try? binding.store.deferredReplay(),
              note.kind == .ordinary,
              (try? binding.store.epoch()) == note.toEpoch
        else { return false }
        return lock.withLock { ledgers[documentId] == nil }
    }

    /// Rebuild the evidence a judgement a restart interrupted needs (#3437,
    /// behavior 20a, finding 3437-SO-03).
    ///
    /// The session that deferred is gone and its ledger with it, so the chain
    /// the note names is re-read off the handshake and decoded into a FRESH
    /// ledger. Never folded: the merged view already holds those epochs — the
    /// move applied them before it deferred — and folding them again would be
    /// work for nothing.
    ///
    /// It does NOT judge. `epoch.info` is the frame this runs on, and the room
    /// sends it before the `syncStep2` that carries the joined epoch's
    /// content: a judgement here would weigh the owed writes against an
    /// overlay that is empty, miss every conflict made in the OPEN epoch, and
    /// replay a write newer online state should have dropped (finding
    /// 3437-REVIEW-002). The ledger is left where
    /// ``completeDeferredReplay(documentId:now:)`` will find it, and
    /// `syncComplete` runs the judgement exactly as it does for a deferral
    /// this session made.
    ///
    /// When the chain no longer covers `[from_epoch, to_epoch)` the owed writes
    /// cannot be checked at all, so they replay whole and are surfaced as
    /// `unverifiable` rather than silently trusted.
    ///
    /// - Returns: whether a judgement is owed and its evidence is now ready.
    @discardableResult
    public func resumeDeferredReplay(
        documentId: String,
        sealed: [SealedEpochChainEntry],
        fetch: (FastForwardStep) throws -> Data,
        now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) throws -> Bool {
        guard let binding = binding(documentId),
              let note = try binding.store.deferredReplay()
        else { return false }
        // A discontinuity's writes are the rebuild's to judge, by presence.
        // Reading a chain for them would build evidence nothing consults.
        guard note.kind == .ordinary else { return false }

        // The document's own ledger, added to rather than replaced. This read
        // runs off the frame handler now (finding 3437-REVIEW-009), so a
        // handshake plan for the same document — a catch-up applying the chain
        // above the note's epoch — can be noting overlays into that ledger
        // while this one reads the archives below it. A fresh ledger assigned
        // at the end would take those with it, and the judgement would then
        // call epochs it has in fact read `unverifiable`.
        let ledger = conflictLedgerForUpdate(documentId)
        ledger.noteSealTimes(sealed.map {
            (epoch: $0.epoch, sealedAt: $0.sealedAt > 0 ? $0.sealedAt : nil)
        })
        let plan = Format2FastForward.plan(
            current: note.fromEpoch, target: note.toEpoch, sealed: sealed
        )
        if case .apply(_, _, let steps) = plan {
            do {
                try Format2FastForward.apply(
                    plan,
                    fetch: fetch,
                    fold: { overlay, epoch in
                        ledger.noteOverlay(
                            epoch: epoch, overlay, models: binding.watchedModels
                        )
                    }
                )
                logger?.debug(
                    "[format2] deferred replay of", documentId,
                    "re-read", steps.count, "sealed overlay(s) to judge against"
                )
            } catch {
                // An archive that cannot be read leaves the ledger short, and
                // `covers` then answers false — which is exactly the
                // `unverifiable` verdict, reached honestly rather than by
                // refusing the judgement and holding the writes for ever.
                logger?.warn(
                    "[format2] the chain a deferred replay of", documentId,
                    "needed could not be read — its writes are unverifiable"
                )
            }
        }
        logger?.log(
            "[format2] deferred replay resumed after a restart for", documentId,
            "— judging against epochs", note.fromEpoch, "to", note.toEpoch - 1,
            "once the joined epoch's state has arrived"
        )
        lock.withLock { _ = resumedNotes.insert(documentId) }
        return true
    }

    /// Run the resolution, act on it, and settle the debt.
    ///
    /// The ORDER at the end is the contract: the survivors are stated, the
    /// dropped sequences forgotten, the note cleared, and only THEN the
    /// withhold released — so no frame can claim a sequence before the thing
    /// that carries it is on the overlay.
    private func judge(
        binding: Format2DocumentBinding,
        note: DeferredReplayNote,
        ledger: OfflineConflictLedger,
        now: Int,
        resumed: Bool,
        rebuilding: Bool = false,
        ingest: OfflineReplayIngest? = nil
    ) throws -> DeferredReplayOutcome {
        let documentId = binding.documentId
        let epoch = try binding.store.epoch()
        // The epoch being replayed onto is OPEN, and its window ends now. It
        // is noted so a conflict written in it counts, which is what the JS
        // client's `noteOverlay(epoch, openDoc)` does before it resolves.
        ledger.noteOverlay(
            epoch: epoch, binding.overlay, models: binding.watchedModels
        )

        let all = try binding.store.pendingOps()
        let owed = all.filter { $0.seq <= note.throughSeq }
        let later = all.filter { $0.seq > note.throughSeq }
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: owed,
            ledger: ledger,
            currentEpoch: epoch,
            now: now,
            clockOffsetKnown: try binding.store.clockOffsetKnown(),
            ingest: ingest
        )

        // A dropped delete cannot be carried out here. Dropping it means the
        // record has to be back, and this merged view has already folded the
        // delete — so nothing is applied, nothing is forgotten, the note
        // stands and the caller reloads from a base (behavior 21). Ignored
        // once the reload HAS run: the base is what put the record back, and
        // a second refusal would loop.
        if plan.rebuildRequired, !rebuilding {
            logger?.log(
                "[format2] the offline writes of", documentId,
                "cannot be resolved in place — a delete they would drop needs "
                    + "the record back from a base"
            )
            return DeferredReplayOutcome(
                epoch: epoch, dropped: [], narrowed: [], stated: [],
                notices: [], resumed: resumed, rebuildRequired: true
            )
        }

        let survivors = Set(plan.ops.map(\.seq))
        let dropped = owed.map(\.seq).filter { !survivors.contains($0) }

        var stated: [Int] = []
        try binding.writePath.withOperation {
            try binding.store.withTransaction {
                if !dropped.isEmpty { try binding.store.forgetPendingOps(dropped) }
                if !plan.narrowed.isEmpty {
                    try binding.store.narrowPendingOps(
                        plan.narrowed.compactMap { op in
                            op.mutation.map {
                                (seq: op.seq, fields: op.fields, mutation: $0)
                            }
                        }
                    )
                }
            }
            // Stated as ordinary local writes, so the observer folds them into
            // the merged view and the transport sends them — narrowed, KEY by
            // key, by what a later local write already owns.
            //
            // Per RECORD would be wrong in both directions (finding
            // 3437-REVIEW-003): a survivor writing field `a` of a record a
            // later write touched only in field `b` would never be stated at
            // all, while the whole-state claim that follows covers its
            // sequence — the field gone, reported durable. And a survivor that
            // is a DELETE has no fields to narrow: a later write that is not
            // itself a delete means the record lives now, so the tombstone no
            // longer describes anything and must not be stated over it. This
            // is `suppressSupersededKeys`' rule, applied to ops rather than to
            // carried entries.
            let (toState, keep) = Self.narrowToUnownedKeys(plan.ops, later: later)
            stated = toState.map(\.seq)
            _ = Format2PendingRestore.statePendingOps(
                overlay: binding.overlay,
                ops: toState,
                suppressDeletes: plan.suppressedDeletes.map {
                    (model: $0.model, recordId: $0.recordId)
                },
                keep: keep
            )
            // A delete this resolution dropped may already be ON the live
            // overlay — it is where the app wrote it — and a reload that put
            // the record back would have the next fold take it away again. The
            // tombstone is cleared the way a carry clears one, by writing the
            // marker false rather than by deleting the key: key-level LWW
            // means an absent key is not a decision (behavior 21).
            for suppressed in plan.suppressedDeletes {
                binding.overlay.applyRawEntries(
                    [(
                        OverlayKeys.markerKey(
                            recordId: suppressed.recordId,
                            marker: OverlayKeys.markerDeleted
                        ),
                        .bool(false)
                    )],
                    model: suppressed.model
                )
            }
        }
        try binding.writePath.foldPendingUnderOperation()

        // The debt is settled, and only now may a claim reach these sequences.
        try binding.store.clearDeferredReplay()
        lock.withLock { _ = resumedNotes.remove(documentId) }
        outbound.releaseWithheld(documentId)
        discardConflictLedger(documentId)

        if !plan.notices.isEmpty {
            logger?.log(
                "[format2] offline writes resolved against later epochs for",
                documentId, "—", plan.notices.count, "notice(s) on epoch", epoch
            )
            onOfflineWritesResolved?(DocumentOfflineWritesResolvedEvent(
                documentId: documentId, epoch: epoch, notices: plan.notices
            ))
        }

        return DeferredReplayOutcome(
            epoch: epoch,
            dropped: dropped,
            narrowed: plan.narrowed.map(\.seq),
            stated: stated,
            notices: plan.notices,
            resumed: resumed,
            rebuildRequired: false
        )
    }

    /// Take back the keys a LATER local write already owns, key by key.
    ///
    /// The rule is `Format2EpochHandoff.suppressSupersededKeys`', in the form a
    /// judgement needs it: the survivors are ops rather than carried entries,
    /// and a create still has to be STATED — its `_replace` is what makes the
    /// record exist — so the keys the later write owns travel with it as
    /// `keep`, which is what stops the replace from clearing them.
    ///
    /// - Returns: the ops to state, and per sequence the overlay keys a
    ///   `create` among them must not clear.
    private static func narrowToUnownedKeys(
        _ survivors: [PendingOp], later: [PendingOp]
    ) -> (ops: [PendingOp], keep: [Int: Set<String>]) {
        guard !later.isEmpty else { return (survivors, [:]) }
        var ownedFields: [String: Set<String>] = [:]
        var ownedKeys: [String: Set<String>] = [:]
        var revived: Set<String> = []
        for op in later {
            let identity = recordKey(op.model, op.recordId)
            ownedFields[identity, default: []].formUnion(op.fields)
            // The overlay KEYS, taken from the later op's own mutation rather
            // than derived from its field names: a stringset's keys name their
            // members, which a field name does not say.
            if let mutation = op.mutation {
                ownedKeys[identity, default: []]
                    .formUnion(OverlayKeys.encode(mutation).map(\.key))
            }
            if op.op != .delete { revived.insert(identity) }
        }

        var ops: [PendingOp] = []
        var keep: [Int: Set<String>] = [:]
        for op in survivors {
            let identity = recordKey(op.model, op.recordId)
            guard let owned = ownedFields[identity] else {
                ops.append(op)
                continue
            }
            if op.op == .delete {
                // A tombstone is a whole record, not a key: a later write that
                // is not a delete means the record lives now.
                if !revived.contains(identity) { ops.append(op) }
                continue
            }
            let survivingFields = op.fields.filter { !owned.contains($0) }
            if survivingFields.isEmpty, op.op != .create { continue }
            if op.op == .create {
                // A create's `_replace` sweeps the record's earlier keys, and
                // the later write's are among them (finding 3431-R14's shape).
                keep[op.seq] = ownedKeys[identity] ?? []
            }
            ops.append(Format2OfflineReplay.narrow(op, to: survivingFields))
        }
        return (ops, keep)
    }

    private static func recordKey(_ model: String, _ recordId: String) -> String {
        Format2OfflineReplay.recordKey(model, recordId)
    }

    /// Whether this frame asks for self-contained state rather than a reload:
    /// a `resync` naming the epoch the document is already on.
    public func resyncIsOwed(_ frame: [String: Any]) throws -> Bool {
        guard frame["type"] as? String == "epoch.resync",
              let documentId = frame["documentId"] as? String,
              let binding = binding(documentId),
              let target = frame["epoch"] as? Int, target > 0
        else { return false }
        return try binding.store.epoch() == target
    }

    /// The whole of this document's overlay, and the span a frame carrying it
    /// may claim.
    ///
    /// Everything the SERVER still owes an acknowledgement for: a whole-state
    /// update is self-contained, so every local sequence above the durable
    /// acked mark really is in it. That is the number to claim from — the
    /// local claimed floor is already at the top, because the deltas the room
    /// refused were all claimed on their way out.
    public func wholeStateResend(
        documentId: String
    ) throws -> (update: [UInt8], claim: OutboundClaim)? {
        guard let binding = binding(documentId) else { return nil }
        let acked = try binding.store.ackedSeq()
        let claim = outbound.wholeState(
            documentId, from: acked + 1, upTo: try binding.store.highestLocalSeq()
        )
        guard let range = claim.range else {
            return (binding.overlay.encodeStateAsUpdate(),
                    OutboundClaim(ledgerClaim: claim, stamps: nil))
        }
        return (
            binding.overlay.encodeStateAsUpdate(),
            OutboundClaim(
                ledgerClaim: claim,
                stamps: OutboundStamps(
                    seq: range.to, seqFrom: range.from, ackedSeq: acked
                )
            )
        )
    }

    /// A new base finished building (`snapshot.ready`), or fresh grants
    /// arrived (`epoch.grants`). Recorded for a load in flight and for the
    /// next handshake; nothing is moved by either.
    @discardableResult
    public func handleSnapshotInfo(_ frame: [String: Any]) -> Bool {
        guard let documentId = frame["documentId"] as? String,
              binding(documentId) != nil
        else {
            logger?.debug(
                "[format2] snapshot frame for a document that is not open, dropped:",
                frame["documentId"] as? String ?? "<none>"
            )
            return false
        }
        // `snapshot.ready` nests the block; `epoch.grants` re-mints the paths
        // for the build it names and carries them at the top level.
        // `epoch.grants` re-mints the whole chain, not only the base, so the
        // archive paths are taken from it too (behavior 15's refresh).
        noteChainGrants(
            documentId, Format2Coordinator.decodeSealedChain(frame["sealedEpochs"])
        )
        guard let offer = Format2Coordinator.decodeSnapshotOffer(frame["snapshot"])
                ?? Format2Coordinator.decodeSnapshotOffer(frame)
        else { return false }
        // A build OLDER than the one already on offer is not news (edge E11).
        // The grants of the newest build are what a load in flight refreshes
        // against, and replacing them with an older build's would point every
        // later read at the wrong artifacts.
        if let known = snapshotInfo(documentId), offer.epoch < known.epoch {
            logger?.debug(
                "[format2] snapshot info for", documentId, "names epoch",
                offer.epoch, "below the", known.epoch, "already offered — ignored"
            )
            return false
        }
        noteSnapshot(documentId, offer)
        return true
    }

    /// What the newest snapshot info said, per document. Read by the next
    /// handshake and by a load that has to refresh its grant.
    public func snapshotInfo(_ documentId: String) -> SnapshotOffer? {
        lock.withLock { snapshots[documentId] }
    }

    /// The room's own epoch, as the last `epoch.info` reported it.
    ///
    /// A `snapshot.ready` carries the epoch its BASE covers and no statement
    /// about the room at all, so a rebuild started by one has nowhere else to
    /// read the target from. Taking the base's epoch for it would leave every
    /// sealed overlay above the base unapplied and the document marked current
    /// anyway (finding 3437-REVIEW-007); the last handshake's number is a
    /// floor, and the `syncStep1` a rebuild sends afterwards draws a fresh
    /// `epoch.info` that catches up anything sealed since.
    private var reportedEpochs: [String: Int] = [:]

    func noteReported(_ documentId: String, _ epoch: Int) {
        guard epoch > 0 else { return }
        lock.withLock {
            reportedEpochs[documentId] = max(reportedEpochs[documentId] ?? 0, epoch)
        }
    }

    public func reportedEpoch(_ documentId: String) -> Int {
        lock.withLock { reportedEpochs[documentId] ?? 0 }
    }

    /// The freshest signed path each sealed epoch's archive is at.
    ///
    /// Recorded from every frame that names the chain — `epoch.info` and the
    /// `epoch.grants` answer — so a chain application whose signature expires
    /// mid-way has somewhere to read the re-minted one from, exactly as a base
    /// load reads ``snapshotInfo(_:)``.
    private var chainGrants: [String: [Int: String]] = [:]

    func noteChainGrants(_ documentId: String, _ sealed: [SealedEpochChainEntry]) {
        guard !sealed.isEmpty else { return }
        lock.withLock {
            var known = chainGrants[documentId] ?? [:]
            for entry in sealed {
                guard let path = entry.downloadPath, !path.isEmpty else { continue }
                known[entry.epoch] = path
            }
            chainGrants[documentId] = known
        }
    }

    /// Where this epoch's archive is now, as the room last said.
    public func sealedGrantPath(_ documentId: String, epoch: Int) -> String? {
        lock.withLock { chainGrants[documentId]?[epoch] }
    }

    /// The chain as the last frame that named it described it.
    ///
    /// For a caller that has to apply a chain outside a handshake — a reload a
    /// judgement asked for, a rebuild a `snapshot.ready` triggered — and so
    /// has no `epoch.info` in hand. The seal TIMES are not recorded with the
    /// grants, so the entries carry none: a reload's writes are judged by
    /// presence or as `unverifiable`, neither of which reads a window.
    public func sealedChain(_ documentId: String) -> [SealedEpochChainEntry] {
        lock.withLock { chainGrants[documentId] ?? [:] }
            .sorted { $0.key < $1.key }
            .map { SealedEpochChainEntry(epoch: $0.key, downloadPath: $0.value) }
    }

    /// Read a snapshot block off a frame. `nil` for anything that does not
    /// name an epoch: a block this client cannot read is one it does not
    /// record, rather than one it guesses at.
    static func decodeSnapshotOffer(_ raw: Any?) -> SnapshotOffer? {
        guard let block = raw as? [String: Any],
              let epoch = block["epoch"] as? Int
        else { return nil }
        return SnapshotOffer(
            epoch: epoch,
            buildId: block["buildId"] as? String,
            rows: block["rows"] as? Int ?? 0,
            manifestVersion: block["manifestVersion"] as? Int,
            downloadPath: path(in: block["download"])
        )
    }

    private func noteSnapshot(_ documentId: String, _ offer: SnapshotOffer) {
        lock.withLock { snapshots[documentId] = offer }
        logger?.debug(
            "[format2] snapshot info for", documentId,
            "— epoch", offer.epoch, offer.rows, "row(s)"
        )
    }

    // MARK: - update.ack

    /// Handle an `update.ack` frame: prune this client's pending ops at or
    /// below the server's contiguous high-water mark.
    ///
    /// - Returns: the mark applied, or `nil` when the frame was dropped.
    /// - Parameter now: this client's wall clock in milliseconds, which the
    ///   offline-window mark is written from (behavior 3).
    @discardableResult
    public func handleUpdateAck(
        _ frame: [String: Any],
        now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) throws -> Int? {
        guard let documentId = frame["documentId"] as? String,
              let binding = binding(documentId)
        else {
            logger?.debug(
                "[format2] update.ack for a document that is not open, dropped:",
                frame["documentId"] as? String ?? "<none>"
            )
            return nil
        }
        guard let mark = frame["maxContiguousSeq"] as? Int else {
            logger?.warn("[format2] malformed update.ack dropped for", documentId)
            return nil
        }
        // An ack is the server speaking about THIS client's own writes —
        // proof of contact as good as a handshake's — so it earns the offline
        // window's mark, which is where the JS client earns it too
        // (behavior 3). Written before the prune, so a prune that fails still
        // leaves a document that can be written to.
        try binding.store.noteSync(at: now)
        let before = try binding.store.pendingOps().count
        try binding.store.prunePendingOps(maxContiguousSeq: mark)
        let after = try binding.store.pendingOps().count
        logger?.debug(
            "[format2] ack", documentId, "mark:", mark, "pruned:", before - after
        )
        return mark
    }

    // MARK: - Outbound stamps

    /// What an outbound `update` frame for a large document claims.
    public struct OutboundStamps: Equatable, Sendable {
        /// The highest sequence this client has committed locally.
        public let seq: Int
        /// The lowest sequence the frame's span starts at.
        public let seqFrom: Int
        /// The mark the server has already acknowledged.
        public let ackedSeq: Int
    }

    /// Note that the Yjs update just enqueued for `documentId` carries every
    /// local sequence committed so far.
    ///
    /// Called where the update is ENQUEUED, not where the frame is sent: the
    /// queue merges a debounce window into one frame, and the frame that
    /// carries that window is the only frame those sequences will ever have.
    /// A no-op for an ordinary document.
    public func noteLocalUpdate(documentId: String) throws {
        guard let binding = binding(documentId) else { return }
        outbound.note(documentId, seq: try binding.store.highestLocalSeq())
    }

    /// What one outbound frame took from the queue, and what it stamps.
    public struct OutboundClaim: Sendable {
        let ledgerClaim: Format2OutboundAckLedger.Claim
        /// The stamps for the frame, or `nil` when the updates it carries
        /// claimed no local sequence.
        public let stamps: OutboundStamps?
    }

    /// Claim the stamps for the frame now being built, which carries the first
    /// `count` queued updates. `nil` for an ordinary document — or for a large
    /// document with nothing enqueued.
    ///
    /// The claim is CONSUMED: the span it returns is the one the frame carries,
    /// and the next frame starts above it. A caller whose send then fails owes
    /// ``restoreClaim(documentId:claim:)``, and one whose send succeeds owes
    /// ``markSent(documentId:claim:)``.
    ///
    /// `count` is the number of QUEUED UPDATES the frame merges, not a byte
    /// budget: a flush sends the prefix of the queue that fits one frame and
    /// leaves the rest, so a claim over everything queued would get a write
    /// still sitting in that queue acknowledged. `seqFrom` is what the frame's
    /// content actually covers, never "everything above the acked mark": the
    /// server takes the span as proof of commit for every sequence in it, so a
    /// frame claiming a sequence it does not carry gets that write
    /// acknowledged — and pruned from `_pending_ops` — although the frame that
    /// really carries it may never arrive.
    public func outboundClaim(
        documentId: String, covering count: Int
    ) throws -> OutboundClaim? {
        guard let binding = binding(documentId) else { return nil }
        guard let claim = outbound.take(documentId, covering: count) else { return nil }
        guard let range = claim.range else {
            return OutboundClaim(ledgerClaim: claim, stamps: nil)
        }
        return OutboundClaim(
            ledgerClaim: claim,
            stamps: OutboundStamps(
                seq: range.to, seqFrom: range.from,
                ackedSeq: try binding.store.ackedSeq()
            )
        )
    }

    /// The socket accepted the frame that made `claim`.
    public func markSent(documentId: String, claim: OutboundClaim?) {
        outbound.markSent(documentId, claim: claim?.ledgerClaim)
    }

    /// The send failed: the claim goes back on the queue for the next frame.
    public func restoreClaim(documentId: String, claim: OutboundClaim?) {
        outbound.restore(documentId, claim: claim?.ledgerClaim)
    }

    /// The frame this claim was taken for is not going out, AND neither is its
    /// content — the epoch move that invalidated it discarded the queue the
    /// claim came off and carried the writes onto the fresh overlay afresh
    /// (#3559).
    ///
    /// So the places are dropped rather than restored. ``restoreClaim`` would
    /// put them back at the front of a line that no longer holds the updates
    /// they stand for, and the next claim would count somebody else's — the
    /// misalignment ``forgetQueuedUpdates`` exists to prevent. `covered` is
    /// untouched either way: the frame never went out, so nothing it named is
    /// claimed, and the fresh overlay's own writes claim those sequences again.
    public func discardClaim(documentId: String, claim: OutboundClaim?) {
        guard let claim else { return }
        logger?.debug(
            "[format2] dropping an outbound claim of", documentId,
            "— its epoch moved while the frame was being built:",
            claim.ledgerClaim.marks.count, "place(s)"
        )
    }

    /// The outbound queue was discarded unsent, so its places go with it.
    public func forgetQueuedUpdates(documentId: String) {
        outbound.forgetQueued(documentId)
    }

    // MARK: - Outbound generation (#3559)

    /// Which generation of `documentId`'s outbound queue a frame being built
    /// belongs to.
    ///
    /// A frame whose payload has to be UPLOADED is built long before it is
    /// sent: the claim and the bytes are taken, then a `getUploadUrl` round
    /// trip and a PUT run, and only then does the frame go on the wire. An
    /// epoch move landing in that window discards every queued update —
    /// because each is a delta against the overlay the room has just archived,
    /// which the room cannot integrate (see `discardQueuedUpdates`) — but it
    /// cannot reach the payload already in flight. Sending it afterwards is
    /// exactly the delta the move exists to drop, now claiming sequences in
    /// the NEW epoch.
    ///
    /// So the generation is captured with the claim and checked again before
    /// the frame is dispatched. It changes on every move, and on nothing else:
    /// an ordinary local edit must NOT invalidate an upload in flight (that is
    /// the cancellation `uploadOutboundUpdate` detaches itself from).
    public func outboundGeneration(_ documentId: String) -> Int {
        outboundGenerationLock.withLock { outboundGenerations[documentId] ?? 0 }
    }

    /// Every outbound payload built against the epoch being left is stale from
    /// here on. Called under the move's operation lock, with the queue it
    /// discards.
    func invalidateOutboundGeneration(_ documentId: String) {
        outboundGenerationLock.withLock {
            outboundGenerations[documentId] = (outboundGenerations[documentId] ?? 0) + 1
        }
    }
}

/// One open large document: its merged view, its overlay, its observer and its
/// write path.
public final class Format2DocumentBinding: @unchecked Sendable {

    public let documentId: String
    public let store: Format2RecordStore
    public let writePath: Format2WritePath

    /// This document's CURRENT epoch overlay and its observer.
    ///
    /// Read through the write path rather than held here, because an epoch
    /// move replaces them (#3437, behavior 10) and every reader — the model
    /// delegate, the facade, the fold queue — has to see the replacement at
    /// once. The write path is what keeps them, because its operation lock is
    /// what the swap runs under.
    public var overlay: OverlayDocument { writePath.overlay }
    public var observer: Format2Observer { writePath.observer }
    /// The file-backed query tables this document's rows are projected into
    /// (#3436, behavior 13). Shared by every large document on this client:
    /// one model, one table, rows tagged by document.
    public let projection: Format2QueryProjection

    /// Where an arriving update's fold runs.
    ///
    /// Serial and off the yswift callback: `YMap.observe` fires inside the
    /// commit under the FFI lock, where a write transaction may not be opened.
    /// Every fold goes through the document's operation lock, so one cannot
    /// land between a local write's commit and its publish.
    private let foldQueue: DispatchQueue
    private let foldQueueKey = DispatchSpecificKey<Bool>()
    private let logger: Logger?

    /// Guards ``foldListeners`` only — never held while one of them runs.
    private let notifyLock = NSLock()
    private var foldListeners: [String: @Sendable () -> Void] = [:]

    /// Told when a mutation was refused through a verb that cannot throw
    /// (#3437, behavior 2a). Set by the coordinator at bind.
    var onWriteRefused: (@Sendable (DocumentWriteRefusedEvent) -> Void)?

    /// Hold every sequence at or below this one back from every outbound claim
    /// (#3437, behavior 27). Set by the coordinator at bind, because the
    /// outbound ledger is the coordinator's and the debt is the document's.
    ///
    /// Called by the adoption pass when a `_deferred_replay` note survived a
    /// restart: the writes it covers are kept OFF the overlay until the
    /// judgement has run, so no frame this client sends carries them, and an
    /// unwithheld claim would have every one of them acknowledged and pruned
    /// unsent (finding 3437-REVIEW-004).
    var withholdOwed: (@Sendable (Int) -> Void)?

    /// Report a refusal the caller had no way to receive, and log it once.
    ///
    /// The log line is the operator's half (principle 8): an application that
    /// subscribes to nothing still leaves a trace of why its write did not
    /// happen.
    func reportWriteRefused(_ event: DocumentWriteRefusedEvent) {
        logger?.warn(
            "[format2] write refused: past the offline window —", documentId,
            event.model, event.recordId, event.error.code.rawValue
        )
        onWriteRefused?(event)
    }

    /// Whether the document is stopped pending a reload from a covering base.
    /// Reads keep answering from the local merged view; writes and outbound
    /// frames do not.
    ///
    /// The state lives on the WRITE PATH rather than beside it, because the
    /// write path is what has to act on it: a refusal recorded somewhere a
    /// write does not look at is a document that reports itself stopped and
    /// goes on publishing.
    public var reloadRequired: Bool { writePath.stoppedReason != nil }

    /// Why, for the refusal a write gets and the event the client emits.
    public var reloadRefusal: JsBaoError? { writePath.stoppedReason }

    /// Stop the document: every later write is refused with `error` before it
    /// takes the operation, so it leaves no pending op and publishes nothing.
    public func requireReload(_ error: JsBaoError) { writePath.stop(error) }

    /// The document is on the room's epoch again.
    public func clearReload() { writePath.resume() }

    /// The models this document watches, so a rebind's fresh observer watches
    /// exactly the same ones — a model left unregistered would capture
    /// nothing, and nothing would be scheduled to notice.
    private let modelsLock = NSLock()
    private var registeredModels: [String] = []

    init(
        documentId: String,
        store: Format2RecordStore,
        overlay: OverlayDocument,
        observer: Format2Observer,
        writePath: Format2WritePath,
        projection: Format2QueryProjection,
        logger: Logger? = nil
    ) {
        self.documentId = documentId
        self.store = store
        self.writePath = writePath
        self.projection = projection
        self.logger = logger
        self.foldQueue = DispatchQueue(label: "format2.fold.\(documentId)")
        foldQueue.setSpecific(key: foldQueueKey, value: true)
        store.projection = projection
        observer.onCaptured = { [weak self] in self?.scheduleFold() }
        _ = overlay
    }

    /// Point this binding at a FRESH epoch overlay (#3437, behavior 10).
    ///
    /// Called from inside the document's operation, so no write is between its
    /// commit and its publish while the swap happens, and a write that was
    /// WAITING for the lock lands on the fresh overlay (edge E5).
    ///
    /// The observer is new because it watches a new document, and it is
    /// registered for exactly the models the old one watched: an observer with
    /// no registrations captures nothing, so a model left out would go stale
    /// with nothing scheduled to notice (#3436's lesson). The fold listeners
    /// are the binding's own and are re-pointed by construction — they live
    /// here, not on the observer.
    func rebind(to document: YDocument) {
        let fresh = OverlayDocument(document: document)
        let observer = Format2Observer(store: store, overlay: fresh, logger: logger)
        observer.onFoldBroken = { [weak self] error in
            guard let self else { return }
            onFoldBrokenForDocument?(documentId, error)
        }
        for model in modelsLock.withLock({ registeredModels }) {
            observer.register(model: model)
        }
        observer.onCaptured = { [weak self] in self?.scheduleFold() }
        writePath.rebind(overlay: fresh, observer: observer)
    }

    /// Where a broken fold is reported, kept so a rebind's fresh observer can
    /// be wired to the same place.
    var onFoldBrokenForDocument: (@Sendable (String, JsBaoError) -> Void)?

    /// The models this document watches.
    public var watchedModels: [String] {
        modelsLock.withLock { registeredModels }
    }

    /// Fold ONE SEALED EPOCH's whole overlay into the merged view
    /// (#3437, behavior 16).
    ///
    /// The archive of a sealed epoch is not a delta to be captured and drained
    /// — it is a whole overlay for an epoch this client never held open — so it
    /// is folded record by record in ONE store transaction, and under the
    /// operation lock, which is what keeps a local write from landing between
    /// two of its records.
    ///
    /// Per model rather than per key, because a sealed overlay carries every
    /// key of every record it touched, and the fold is idempotent at the record
    /// level: applying a chain that failed halfway again changes nothing.
    ///
    /// - Parameter overlay: a throwaway document decoded from the archive. It
    ///   is never installed and never observed.
    /// - Returns: the models it folded, for the caller's notifications.
    @discardableResult
    public func foldSealedOverlay(
        _ overlay: OverlayDocument, epoch: Int
    ) throws -> [String] {
        let models = watchedModels.sorted()
        var folded: [String] = []
        try writePath.withOperation {
            try store.transaction {
                for model in models {
                    let entries = overlay.entries(model: model)
                    guard !entries.isEmpty else { continue }
                    let grouped = OverlayKeys.group(entries)
                    for entry in grouped.values.sorted(by: { $0.id < $1.id }) {
                        try store.applyRemote(model: model, entry: entry)
                    }
                    folded.append(model)
                }
            }
        }
        logger?.debug(
            "[format2] catch-up applied a sealed overlay of", documentId,
            "— epoch", epoch, "over", folded.count, "model(s)"
        )
        return folded
    }

    /// Record that `model` is watched, so a rebind re-registers it.
    func noteRegisteredModel(_ model: String) {
        modelsLock.withLock {
            if !registeredModels.contains(model) { registeredModels.append(model) }
        }
    }

    // MARK: - The fold queue

    /// Fold what the observer captured, on this document's fold queue.
    private func scheduleFold() {
        foldQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Outside the operation the fold ran under: a subscriber is
                // application code, free to read and write the model it was
                // told about, and running it under the document's operation
                // lock would deadlock it against its own read.
                notifyFolded(try writePath.foldPendingUnderOperation())
            } catch {
                // A failed fold is already sticky and already logged by the
                // observer; there is no caller here to hand it to. The next
                // read or write is refused with it, which is the point.
                logger?.debug(
                    "[format2] the fold of", documentId, "did not commit:",
                    error.localizedDescription
                )
            }
        }
    }

    /// Wait for the folds already scheduled to finish.
    ///
    /// What a read calls before it answers, so an update that has landed is in
    /// the merged view — the same contract `DynamicModel.awaitObserverDrain`
    /// gives an ordinary document. Re-entrant from the fold queue itself,
    /// where the work is already done and waiting would deadlock.
    public func settleFolds() {
        guard DispatchQueue.getSpecific(key: foldQueueKey) != true else { return }
        // And re-entrant from inside this document's own operation, where a
        // scheduled fold is blocked on the lock this thread holds: waiting for
        // the queue would be waiting for work that cannot start until we
        // return. Nothing is owed either — no fold can have landed since the
        // operation began.
        guard !writePath.isInsideOperation else { return }
        foldQueue.sync {}
    }

    // MARK: - Telling the models a fold moved their rows

    /// What to call when `model`'s rows change under it.
    ///
    /// A large document's records are not nested Y.Maps, so the per-record and
    /// root-map observers that tell an ordinary model's subscribers about a
    /// peer's edit see nothing here: the overlay's keys are flat scalars on the
    /// model map, which those observers ignore by design. Without this a
    /// `Model.subscribe` on a large document fires for the subscriber's OWN
    /// writes and never for anybody else's — queries stay current while the
    /// view watching them goes stale, which is the hardest kind of staleness to
    /// notice.
    ///
    /// One per model name, replaced on a rebind: a model has one member per
    /// document, and this is that member's.
    func onFolded(model: String, _ notify: @escaping @Sendable () -> Void) {
        notifyLock.withLock { foldListeners[model] = notify }
    }

    /// Tell `models`' subscribers. Called OUTSIDE the document's operation.
    func notifyFolded(_ models: [String]) {
        guard !models.isEmpty else { return }
        let listeners = notifyLock.withLock { models.compactMap { foldListeners[$0] } }
        for notify in listeners { notify() }
    }

    // MARK: - The bind's catch-up (#3782)

    /// Fold what this document's overlay holds that the store does not.
    ///
    /// The bind used to fold every registered model's WHOLE overlay, on every
    /// open. Now it asks the store what it last folded:
    ///
    /// - the overlay's vector equals the stored one and every registered model
    ///   is covered — nothing is folded, and the observer is told those models
    ///   are caught up, so a registration folds nothing either;
    /// - the vector is equal but some models were never covered — each of
    ///   those is caught up on its own;
    /// - nothing is known, the vectors differ, or the fold is broken — the
    ///   whole catch-up, as before. That is also the repair of a crash between
    ///   the Y.Doc's persist and its fold's commit, which leaves the overlay
    ///   ahead of the stamp.
    ///
    /// A document whose local row says format 2 binds at open, before any
    /// frame from the room, so what arrives after this is the observer's to
    /// fold incrementally. Call it under the document's operation lock.
    @discardableResult
    func catchUpAtBind() throws -> Format2BindCatchUp {
        let models = observer.registeredModels()
        if !observer.isFoldBroken,
           let stored = try store.foldedState(),
           stored.vector == overlay.stateVector() {
            let uncovered = models.filter { !stored.models.contains($0) }
            observer.markCaughtUp(models.filter { stored.models.contains($0) })
            if uncovered.isEmpty {
                logger?.debug(
                    "[format2]", documentId,
                    "— the overlay is unchanged since the last fold; the bind folds nothing"
                )
                return .skipped
            }
            try observer.catchUp(models: uncovered)
            return .partial(uncovered)
        }
        try observer.catchUp()
        return .whole(models)
    }

    // MARK: - Model registration

    /// Take `schema` into this document: watch its overlay map, fold whatever
    /// that map already holds, and project the result into the query tables.
    ///
    /// The order is the whole point. Watching first means an update arriving
    /// during the catch-up is captured rather than missed; the catch-up then
    /// gives the store this model's records as the overlay already holds them;
    /// and the projection copies rows that exist. A registration that skipped
    /// the catch-up would project an EMPTY model and mark it done — a filtered
    /// read then answers nothing, durably, and nothing is scheduled to notice.
    ///
    /// A no-op for a model the bind already covered, which is every model
    /// registered before the document opened.
    func registerModel(_ schema: PrimitiveSchema) {
        noteRegisteredModel(schema.name)
        do {
            try writePath.withOperation {
                observer.register(model: schema.name)
                try observer.catchUpIfNeeded(model: schema.name)
            }
        } catch {
            // The catch-up already marked the document fold-broken and logged
            // it; there is no caller here to hand it to, and the next read or
            // write on this model is refused with it. The projection below is
            // skipped for the same reason — it would copy rows this model's
            // fold could not vouch for.
            logger?.warn(
                "[format2] the catch-up for", schema.name, "of", documentId,
                "did not commit:", error.localizedDescription
            )
            return
        }
        projectModel(schema)
    }

    // MARK: - Adopting and restoring a previous instance's writes

    /// What a bind's adoption pass did (#3437, behavior 6).
    public struct AdoptionOutcome: Equatable, Sendable {
        /// Sequences taken over from an instance that is gone, under their
        /// NEW numbers.
        public let adopted: [Int]
        /// Sequences re-applied to the overlay.
        public let restored: [Int]
        /// Sequences the overlay does not carry and this client cannot
        /// reproduce. Left pending; the ack path settles them.
        public let unreproducible: [Int]
        /// Sequences held OFF the overlay until a judgement has run.
        public let deferred: [Int]
    }

    /// Adopt the previous instance's unacknowledged writes and put back the
    /// ones that are still owed (#3437, behavior 6).
    ///
    /// The order is the whole point, and it is the JS binding's:
    ///
    /// 1. settle the catch-up fold, so the merged rows the classification
    ///    reads are the ones the document arrived with;
    /// 2. adopt — re-key every foreign row to this client;
    /// 3. classify each adopted op in SEQUENCE order, carrying each verdict
    ///    forward into the projection (finding 3431-R10);
    /// 4. restore the ones still owed, honouring a `_deferred_replay` note and
    ///    a discontinuity boundary;
    /// 5. refold once, because a restored op wrote overlay keys the merged
    ///    view has not seen.
    ///
    /// Classification before restore, and the whole chain before any of it is
    /// applied: an op weighed against an overlay an earlier op of the same
    /// pass has already changed reads its own predecessor as a stranger's
    /// write and drops the newest edit of all.
    @discardableResult
    public func adoptAndRestore() throws -> AdoptionOutcome {
        // The fold first: the classification's merged-row rule reads rows, and
        // a fold still queued would move them under it.
        settleFolds()
        try writePath.foldPendingUnderOperation()

        var refolded: [String] = []
        // Told after the operation is released: a subscriber is application
        // code, free to read and write the model it was told about, and
        // running it under this document's operation lock would deadlock it
        // against its own read.
        defer { notifyFolded(refolded) }

        return try writePath.withOperation {
            let adopted = try store.adoptOrphanedPendingOps()

            // A note whose span the server has already acknowledged is not a
            // debt: there is nothing left to judge, and holding a write back
            // for it would hold nothing at all (edge E16).
            var note = try store.deferredReplay()

            // A note's `through_seq` names sequences in the space of the
            // instance that WROTE it, and adoption has just re-keyed those
            // rows into this instance's space (#3437, behavior 20a). Left as
            // it was, the note would hold back whichever writes happen to sort
            // below a number from a space that no longer exists — which for
            // two previous instances, or an acknowledged prefix, is the wrong
            // set. Re-mapped onto the sequences adoption gave them.
            if let existing = note, !adopted.isEmpty {
                let covered = adopted
                    .filter { $0.fromSeq <= existing.throughSeq }
                    .map(\.seq)
                    .max()
                if let covered, covered != existing.throughSeq {
                    try store.noteDeferredReplay(
                        throughSeq: covered, fromEpoch: existing.fromEpoch,
                        toEpoch: existing.toEpoch, kind: existing.kind
                    )
                    note = DeferredReplayNote(
                        throughSeq: covered, fromEpoch: existing.fromEpoch,
                        toEpoch: existing.toEpoch, kind: existing.kind
                    )
                    logger?.debug(
                        "[format2] the deferred replay of", documentId,
                        "covers adopted sequences up to", covered,
                        "(was", existing.throughSeq, "in the previous instance's space)"
                    )
                }
            }

            if let existing = note, existing.throughSeq <= (try store.ackedSeq()) {
                try store.clearDeferredReplay()
                logger?.debug(
                    "[format2] the deferred replay of", documentId,
                    "was already acknowledged through", existing.throughSeq,
                    "— cleared without a judgement"
                )
                note = nil
            }

            // The ceiling the session that deferred had set, back where it
            // was (finding 3437-REVIEW-004). The restore below keeps these
            // writes OFF the overlay until the judgement has run, so the
            // whole-state frame the join sends carries none of their content —
            // and an unwithheld claim would get every one of them acknowledged
            // and pruned unsent. Before anything can leave: the withhold is
            // set inside the bind, and the first frame goes out after it.
            if let owed = note {
                withholdOwed?(owed.throughSeq)
                logger?.log(
                    "[format2] holding sequences of", documentId, "up to",
                    owed.throughSeq,
                    "back until the judgement a restart interrupted has run"
                )
            }

            // A discontinuity this document's epoch is already ABOVE is a
            // boundary it followed and has not converged past, so the writes
            // made at or below it are the convergence's to state.
            let held = try store.epoch()
            let discontinuities = try store.discontinuityEpochs()
            let boundary = discontinuities.filter { $0 < held }.max() ?? 0

            var verdicts: [Int: PendingRestoreVerdict] = [:]
            var projection = RestoreProjection()
            for entry in adopted {
                // A model this device does not hold has no merged row to
                // consult and none is asked for (edge E10): a capped load left
                // it out, so what the store holds for it is whatever a later
                // overlay happened to touch — not the model. The key-presence
                // rule owns the op on its own, which is the same rule an op
                // with no recorded row gets.
                let hydrated = (try? store.isHydrated(entry.model)) ?? true
                let verdict: PendingRestoreVerdict
                if hydrated {
                    let row = (try? store.read(
                        model: entry.model, recordId: entry.recordId
                    )) ?? nil
                    verdict = Format2PendingRestore.classifyAdoptedOp(
                        overlay: overlay, op: entry.op, mergedRow: row,
                        projection: projection
                    )
                } else {
                    verdict = Format2PendingRestore.classifyByKeyPresence(
                        overlay: overlay, op: entry.op, projection: projection
                    )
                }
                Format2PendingRestore.projectRestoredKeys(
                    overlay: overlay, op: entry.op, verdict: verdict,
                    projection: &projection
                )
                verdicts[entry.seq] = verdict
                if verdict == .carried || verdict == .superseded {
                    logger?.log(
                        "[format2] adopted write #\(entry.seq) of", documentId,
                        entry.model, entry.recordId,
                        "is not restored —",
                        verdict == .carried
                            ? "the overlay already carries it"
                            : "a later write owns every key it wrote"
                    )
                } else if case .fragment = verdict {
                    logger?.log(
                        "[format2] adopted write #\(entry.seq) of", documentId,
                        entry.model, entry.recordId,
                        "restored in part — a later write owns some of its keys"
                    )
                }
            }

            let result = Format2PendingRestore.restorePendingOverlay(
                overlay: overlay,
                ops: try store.pendingOps(),
                verdicts: verdicts,
                deferAtOrBelowEpoch: boundary,
                deferAtOrBelowSeq: note?.throughSeq ?? 0
            )
            for seq in result.deferred {
                logger?.log(
                    "[format2] adopted write #\(seq) of", documentId,
                    "is deferred — a judgement is owed on it before it may be stated"
                )
            }

            // A restored op wrote overlay keys the merged view has not seen,
            // so the view is refolded once. Only when something was restored:
            // a pass that put nothing back has nothing to fold.
            if !result.restored.isEmpty {
                refolded = try observer.catchUp()
            }

            return AdoptionOutcome(
                adopted: adopted.map(\.seq),
                restored: result.restored,
                unreproducible: result.unreproducible,
                deferred: result.deferred
            )
        }
    }

    // MARK: - The query projection

    /// Project `schema`'s rows into the query tables, unless they are there
    /// already.
    ///
    /// Reports rather than throws: the caller is a model CONNECT, which cannot
    /// fail a document's open over a derived table. What a failure leaves is
    /// no mark — so the next connect projects again, and until then a filtered
    /// read on this model refuses by name rather than answering short.
    func projectModel(_ schema: PrimitiveSchema) {
        do {
            try projection.ensureProjected(schema: schema, store: store)
        } catch {
            logger?.warn(
                "[format2] the query projection of", schema.name, "of", documentId,
                "did not commit:", error.localizedDescription
            )
        }
    }

    /// Whether `model`'s rows are in the query tables, and a filtered read can
    /// therefore be answered from them.
    func isProjected(_ model: String) -> Bool {
        (try? store.hasQueryProjection(model: model)) ?? false
    }
}
