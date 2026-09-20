import Foundation

/// The local write path of a large document (#3436, decision 3436-SO-01).
///
/// ## Commit, then publish, inside one serialized operation
///
/// A write is three things that have to happen in one order:
///
/// 1. capture what the overlay held for the keys the mutation will write;
/// 2. commit the merged row AND the pending op in one SQLite transaction;
/// 3. apply the mutation to the epoch doc — which is what sends it.
///
/// The order is not a preference. A Yjs mutation cannot be rolled back, so
/// publishing before committing means a SQLite failure leaves a rejected save
/// on its way to every peer with no durable record that it ever happened. The
/// JS `BaseModel` commits first for exactly this reason.
///
/// All three run under ONE operation lock per document, because the fold queue
/// works on the same store: a batch that materialized between the commit and
/// the publish would read the PRE-save overlay and fold it over the row just
/// committed, silently undoing the save. That is #3429's finding arriving
/// through the Swift door, and the boundary is commit-AND-publish, not commit.
///
/// Read-your-writes holds because the commit precedes the return.
public final class Format2WritePath: @unchecked Sendable {

    public let store: Format2RecordStore

    /// The epoch overlay and its observer.
    ///
    /// REPLACED at an epoch move (#3437, behavior 10): for a large document
    /// the Y.Doc is the current epoch's overlay, so following a seal means
    /// putting a fresh one here. The write path itself is NOT replaced,
    /// because its operation lock is what excludes a local write from the
    /// move — a new lock per epoch would exclude nothing at the one moment it
    /// matters (edge E5).
    private let bindLock = NSLock()
    private var _overlay: OverlayDocument
    private var _observer: Format2Observer

    public var overlay: OverlayDocument { bindLock.withLock { _overlay } }
    public var observer: Format2Observer { bindLock.withLock { _observer } }

    /// Point this write path at a fresh epoch overlay.
    ///
    /// Only ever called from inside an operation, so no write can be between
    /// its commit and its publish while the pair is swapped.
    func rebind(overlay: OverlayDocument, observer: Format2Observer) {
        bindLock.withLock {
            _overlay = overlay
            _observer = observer
        }
    }

    /// One logical operation at a time, per document. A plain recursive lock:
    /// the operation is short, entirely synchronous, and the thing it excludes
    /// is the fold queue, which is synchronous too.
    private let operationLock = NSRecursiveLock()

    /// Where this document's operation depth is recorded for the CALLING
    /// thread. The lock says "somebody is inside an operation"; this says
    /// "*you* are", which is what a read has to know before it waits on the
    /// fold queue — see ``isInsideOperation``.
    private let operationDepthKey: String

    public init(
        store: Format2RecordStore,
        overlay: OverlayDocument,
        observer: Format2Observer
    ) {
        self.store = store
        self._overlay = overlay
        self._observer = observer
        self.operationDepthKey =
            "format2.operation.\(store.documentId).\(ObjectIdentifier(store).hashValue)"
    }

    /// Commit and publish one mutation.
    ///
    /// - Returns: the sequence the write claimed, which an `update.ack` later
    ///   prunes against.
    @discardableResult
    public func write(
        model: String,
        mutation: OverlayMutation,
        fields: [String],
        at now: Int? = nil
    ) throws -> Int {
        // Refused BEFORE the operation starts, so a write on a document whose
        // merged view is known to be wrong — or whose epoch the room has
        // replaced under it — leaves no pending op and publishes nothing
        // (edge E15, behavior 30).
        if let stopped = stoppedReason { throw stopped }
        try observer.assertWritable()
        // And past the window, before the operation is taken. The gate at the
        // commit boundary below is the one that MATTERS — every door runs
        // through it — but a document that is read-only should not have to
        // queue behind a fold to be told so.
        try assertWithinOfflineWindow()
        return try withOperation {
            try commitInsideOperation(
                model: model, mutation: mutation, fields: fields, at: now
            )
        }
    }

    // MARK: - The offline write window

    /// Refuse a local write on a document that has not synced for longer than
    /// its offline window (#3437, behavior 2).
    ///
    /// Reads the store's in-memory mirror, so it costs no SQL on a path that
    /// runs once per write.
    ///
    /// Measured on THIS CLIENT's wall clock, deliberately not the
    /// server-corrected one a pending op is stamped with: the mark it is
    /// compared against was written from the same uncorrected clock, and
    /// mixing the two would offset the boundary by the measured skew.
    func assertWithinOfflineWindow(at now: Int? = nil) throws {
        let at = now ?? Int(Date().timeIntervalSince1970 * 1000)
        let status = store.offlineWindowStatus(now: at)
        guard !status.writable else { return }
        throw Format2OfflineWindow.expired(
            documentId: store.documentId, status: status
        )
    }

    // MARK: - Stopped

    private let stopLock = NSLock()
    private var _stopped: JsBaoError?

    /// Why this document's writes are refused, or `nil` while it is writable.
    ///
    /// Set when the room rotates or replaces the epoch this client's overlay
    /// belongs to and the client cannot follow it in place — a seal, a resync,
    /// or a handshake whose plan needs the sealed chain (#3437's seam). READS
    /// keep answering from the merged view, and the pending log is kept: the
    /// writes this client owes are still owed, and a document that is stopped
    /// is not a document that has lost anything.
    public var stoppedReason: JsBaoError? { stopLock.withLock { _stopped } }

    public func stop(_ error: JsBaoError) { stopLock.withLock { _stopped = error } }

    public func resume() { stopLock.withLock { _stopped = nil } }

    /// Run `body` as one operation on this document.
    ///
    /// Public because the handshake and the fold queue take the same lock:
    /// "one logical operation at a time" is a property of the document, not of
    /// the write path.
    @discardableResult
    public func withOperation<T>(_ body: () throws -> T) throws -> T {
        operationLock.lock()
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[operationDepthKey] as? Int) ?? 0
        dictionary[operationDepthKey] = depth + 1
        defer {
            if depth == 0 {
                dictionary.removeObject(forKey: operationDepthKey)
            } else {
                dictionary[operationDepthKey] = depth
            }
            operationLock.unlock()
        }
        return try body()
    }

    /// Whether the CALLING thread is already inside this document's operation.
    ///
    /// A read that would otherwise wait for the fold queue has to ask: a fold
    /// takes this same lock, so one scheduled while this thread holds it is
    /// blocked on this thread, and waiting for the queue to drain would be
    /// waiting for work that cannot start. There is nothing to wait for anyway
    /// — no fold can have landed since the operation began.
    var isInsideOperation: Bool {
        ((Thread.current.threadDictionary[operationDepthKey] as? Int) ?? 0) > 0
    }

    /// Fold whatever the observer has captured, under the operation lock.
    ///
    /// This is how the fold queue is kept out from between a write's commit
    /// and its publish: it asks for the same lock, so a drain that arrives
    /// mid-write waits for the write to finish rather than interleaving.
    ///
    /// - Returns: the models the fold moved, so the caller can tell their
    ///   subscribers AFTER the operation is released — a listener is
    ///   application code and must never run under this lock.
    @discardableResult
    public func foldPendingUnderOperation() throws -> [String] {
        try withOperation { try observer.drain() }
    }

    /// The commit-then-publish itself, for a caller that already holds the
    /// operation — the handshake's catch-up and the tests that drive the
    /// boundary directly.
    @discardableResult
    public func commitInsideOperation(
        model: String,
        mutation: OverlayMutation,
        fields: [String],
        at now: Int? = nil
    ) throws -> Int {
        // (0) Broken again, now that the operation is ours. The check in
        // `write` refuses early, before anything is taken; this one refuses
        // the write that was WAITING for the lock a fold held while it failed.
        // Without it a write committed and published on a document whose
        // merged view had just been declared wrong.
        try observer.assertWritable()

        // (0b) And past the offline window, BEFORE the first statement, so a
        // refused write leaves no merged row, no pending op and no projected
        // row — and publishes nothing, so the refusal cannot itself become a
        // write that replays later. Here rather than in `write` alone because
        // `addMember` and `removeMember` reach this boundary directly
        // (finding 3437-SO-07); every door this document has runs through it.
        try assertWithinOfflineWindow()

        // (1) What the overlay held for the keys this write is about to touch.
        // Taken before the commit and before the publish, so it describes the
        // overlay the write is layered over.
        let prior = overlay.priorValues(model: model, mutation: mutation)

        // (2) The merged row and the pending op, together or not at all.
        let seq = try store.commitLocalWrite(
            model: model,
            mutation: mutation,
            pending: PendingOpInput(
                model: model,
                recordId: mutation.id,
                op: PendingOp.Kind(rawValue: mutation.kind.rawValue) ?? .patch,
                fields: fields,
                baseEpoch: try store.epoch(),
                ts: try now ?? store.correctedNow(),
                priorOverlay: prior
            )
        )

        // (3) And only now the overlay, which is what sends it. yswift carries
        // no transaction origin, so the observer will fold this write a second
        // time; the fold is idempotent (an overlay entry is state, not a
        // delta), so the second fold changes nothing.
        overlay.apply(mutation, model: model)
        return seq
    }
}

/// Which documents may not send anything right now, and what they owe
/// (#3436, behavior 33, decision 3436-SO-02).
///
/// Every path that carries LOCAL state to the server has to ask this: the
/// ws-open flush, the debounced local-update queue, and the `syncStep2` answer
/// built from the local doc. A large document is held from the socket's open
/// (or the document's bind, whichever comes first) until its `epoch.info` has
/// been handled, and again by any reload-required state.
///
/// Frames are KEPT, not dropped: the writes behind them are the user's, and
/// the queue flushes when the hold releases. A format-1 document is never
/// held, which is what keeps an ordinary document on the same socket unchanged.
public final class Format2OutboundHold: @unchecked Sendable {

    private let lock = NSLock()
    private var held: [String: String] = [:]
    private var queued: [String: [String]] = [:]

    public init() {}

    /// Hold `documentId`, recording why. Setting a hold that is already set
    /// only updates the reason — the release is ONE release, on the handshake,
    /// not one per hold (edge E16). Anything else would leave a document held
    /// by a seal that a reconnect also held, owing a second release nobody
    /// sends.
    public func hold(_ documentId: String, reason: String) {
        lock.withLock { held[documentId] = reason }
    }

    public func isHeld(_ documentId: String) -> Bool {
        lock.withLock { held[documentId] != nil }
    }

    /// Why the document is held, for the log line and for a typed refusal.
    public func reason(_ documentId: String) -> String? {
        lock.withLock { held[documentId] }
    }

    /// Keep a frame the hold stopped. Frames for a document that is NOT held
    /// are not queued — the caller sends those.
    public func enqueue(_ documentId: String, frame: String) {
        lock.withLock {
            guard held[documentId] != nil else { return }
            queued[documentId, default: []].append(frame)
        }
    }

    public func queuedCount(_ documentId: String) -> Int {
        lock.withLock { queued[documentId]?.count ?? 0 }
    }

    /// Release the hold and hand back everything it kept, in the order it was
    /// queued. An empty queue releases and sends nothing.
    @discardableResult
    public func release(_ documentId: String, reason: String) -> [String] {
        lock.withLock {
            held.removeValue(forKey: documentId)
            return queued.removeValue(forKey: documentId) ?? []
        }
    }

    /// Forget a document entirely — it closed, or was purged.
    public func forget(_ documentId: String) {
        lock.withLock {
            held.removeValue(forKey: documentId)
            queued.removeValue(forKey: documentId)
        }
    }
}
