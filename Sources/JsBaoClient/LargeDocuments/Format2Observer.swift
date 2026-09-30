import Foundation
import YSwift

/// Turns an arriving Yjs update into merged rows (#3436).
///
/// ## Why the fold does not run in the callback
///
/// `YMap.observe` fires SYNCHRONOUSLY inside the commit, under yswift's
/// recursive FFI lock. A callback that folded inline would hold that lock
/// across a SQLite write for the whole fold, and could not open a write
/// transaction on the document at all. So the callback does the one thing it
/// safely can — record which KEYS were touched — and a serial queue
/// materializes their values under a read transaction afterwards and folds
/// them in one store transaction.
///
/// Capturing keys rather than values is also what keeps the fold correct: the
/// value a key holds at FOLD time is the one the merged view should show, and
/// a value captured in the callback would be the one it held at commit time,
/// which a later commit in the same batch may already have replaced.
///
/// ## Fold-broken
///
/// A fold that fails leaves the merged row wrong while Yjs already holds the
/// update — and sync need never send that update again, so nothing will
/// correct it. Continuing would layer later deltas over a row known to be
/// wrong. The state is therefore STICKY: reads and writes are refused with
/// ``JsBaoErrorCode/format2FoldBroken`` until a rebind's whole-overlay
/// catch-up fold commits.
public final class Format2Observer: @unchecked Sendable {

    private let store: Format2RecordStore
    private let overlay: OverlayDocument
    private let logger: Logger?

    private let lock = NSLock()
    /// Keys touched since the last fold, per model. A SET: one key touched
    /// five times in a batch is folded once.
    ///
    /// Keyed by ``ByteKey`` for the reason `OverlayKeys.group` is: two overlay
    /// keys that Swift calls equal because their record ids are canonically
    /// equivalent are two keys to yrs, and collapsing them here would leave one
    /// of the two records unfolded, with nothing pending and nothing to notice.
    private var touched: [String: Set<ByteKey>] = [:]
    private var subscriptions: [String: YSubscription] = [:]
    /// The models a whole-overlay catch-up has covered since this observer was
    /// made. What tells a late registration whether it owes one.
    private var caughtUp: Set<String> = []
    private var brokenBy: Error?
    /// How many folds this observer has committed, drains and catch-ups alike,
    /// and the models the last catch-up covered (#3782). Diagnostic: what a
    /// bind that folded nothing is told apart by.
    private var _foldCount = 0
    private var _lastCatchUpModels: [String]?

    /// `internal`: the observer is wired by the document binding, never
    /// constructed by an app, and `Logger` is not public surface.
    init(
        store: Format2RecordStore,
        overlay: OverlayDocument,
        logger: Logger? = nil
    ) {
        self.store = store
        self.overlay = overlay
        self.logger = logger
    }

    /// Told, once, that this document's merged view has become untrustworthy.
    ///
    /// A fold fails on the fold queue, where there is no caller to hand the
    /// error to: without this the application learns of it only by making a
    /// read and being refused, and a read that answers `nil` (`find`) or a
    /// delete that reports nothing (both non-throwing by their public
    /// signatures) look exactly like an absent record and a completed delete.
    /// The event is what separates the two. Set by the binding, which emits
    /// `ConnectionErrorEvent` with `FORMAT2_FOLD_BROKEN`.
    internal var onFoldBroken: (@Sendable (JsBaoError) -> Void)? {
        get { lock.withLock { _onFoldBroken } }
        set { lock.withLock { _onFoldBroken = newValue } }
    }
    private var _onFoldBroken: (@Sendable (JsBaoError) -> Void)?

    deinit { cancel() }

    // MARK: - Registration

    /// Watch a model's overlay map. Idempotent.
    ///
    /// A model registered AFTER the bind has missed every update so far, so
    /// the caller follows this with a whole-overlay ``catchUp()`` for it —
    /// see `Format2DocumentBinding`.
    public func register(model: String) {
        let subscription: YSubscription? = lock.withLock {
            guard subscriptions[model] == nil else { return nil }
            return overlay.map(for: model).observe { [weak self] changes in
                self?.capture(model: model, changes: changes)
            }
        }
        guard let subscription else { return }
        lock.withLock { subscriptions[model] = subscription }
    }

    /// The models currently watched.
    public func registeredModels() -> [String] {
        lock.withLock { Array(subscriptions.keys) }.sorted()
    }

    /// Stop watching. Called when the document closes, before the store's
    /// handle is released.
    public func cancel() {
        let doomed: [YSubscription] = lock.withLock {
            let all = Array(subscriptions.values)
            subscriptions.removeAll()
            return all
        }
        for subscription in doomed { subscription.cancel() }
    }

    // MARK: - Capture (runs under the FFI lock — do the minimum)

    private func capture(model: String, changes: [YMapChange<JSONValue>]) {
        var keys: Set<ByteKey> = []
        for change in changes {
            switch change {
            case .inserted(let key, _),
                 .removed(let key, _),
                 .insertedNested(let key, _),
                 .removedNested(let key, _):
                keys.insert(ByteKey(key))
            case .updated(let key, _, _), .updatedNested(let key, _, _):
                keys.insert(ByteKey(key))
            }
        }
        guard !keys.isEmpty else { return }
        let scheduler = lock.withLock { () -> (@Sendable () -> Void)? in
            touched[model, default: []].formUnion(keys)
            return _onCaptured
        }
        scheduler?()
    }

    /// How many keys are waiting to be folded. Nonzero between an update
    /// landing and ``drain()``.
    public var pendingKeyCount: Int {
        lock.withLock { touched.values.reduce(0) { $0 + $1.count } }
    }

    // MARK: - Suspension while the document is behind the room

    private var _suspended = false

    /// Whether ``drain()`` is holding off (#3437, behavior 17).
    public var remoteFoldsSuspended: Bool { lock.withLock { _suspended } }

    /// Stop folding captured keys into the merged view.
    ///
    /// Set while this document is behind the room, alongside the inbound gate
    /// that keeps the room's current epoch out of the held overlay in the first
    /// place. Both are needed: the gate goes up at the HANDSHAKE, and whatever
    /// the socket delivered before it — a `syncStep2` answered on the way — is
    /// already captured.
    public func suspendRemoteFolds() { lock.withLock { _suspended = true } }

    /// Fold again. A move installs a fresh observer, so this matters for the
    /// paths that do not swap: a catch-up that was refused, and a cold chain.
    public func resumeRemoteFolds() { lock.withLock { _suspended = false } }

    /// Told that keys have been captured and a fold is owed.
    ///
    /// The observer does not schedule the fold itself: the fold has to run
    /// under the DOCUMENT's operation lock, so that it cannot land between a
    /// local write's commit and its publish, and that lock belongs to the
    /// binding. The binding sets this to its own scheduler; an observer driven
    /// directly — every test that drives a fold by hand — has none and folds
    /// when it is asked to.
    ///
    /// Called from inside the yswift callback, under the FFI lock, so the
    /// implementation must return immediately.
    internal var onCaptured: (@Sendable () -> Void)? {
        get { lock.withLock { _onCaptured } }
        set { lock.withLock { _onCaptured = newValue } }
    }
    private var _onCaptured: (@Sendable () -> Void)?

    // MARK: - Folding

    /// Fold everything captured since the last call, in one store transaction.
    ///
    /// One transaction for the whole batch rather than one per record: a
    /// catch-up of a large overlay is the difference between one commit and
    /// thousands.
    /// - Returns: the models whose rows the fold moved, so the caller can tell
    ///   their subscribers once the operation has been released. Empty when
    ///   there was nothing captured.
    @discardableResult
    public func drain() throws -> [String] {
        if let brokenBy { throw Self.foldBroken(brokenBy) }
        // Suspended while this document is behind the room (#3437, behavior
        // 17). The captured keys are KEPT, not dropped — but they are the
        // room's current epoch, folding them over the view the chain is being
        // applied to would put the far side of the rotation under it, and the
        // observer itself is discarded with the old overlay at the move.
        if remoteFoldsSuspended { return [] }

        // #3782 — the vector this drain certifies is read BEFORE the keys are
        // taken: a transaction committing in between leaves its keys for the
        // next drain and its items above this vector, so the stamp never
        // vouches for an item whose key was not taken.
        let vector = overlay.stateVector()
        // Every key captured before the vector was read is taken below, so
        // every registered model a catch-up (or the bind's stamp) covered is
        // folded through it — and only those (finding 3782-C04).
        let (batch, certified): ([String: Set<ByteKey>], [String]) = lock.withLock {
            let all = touched
            touched.removeAll()
            return (all, Array(caughtUp.intersection(subscriptions.keys)))
        }
        guard !batch.isEmpty else { return [] }

        do {
            try store.transaction {
                for model in batch.keys.sorted() {
                    guard let keys = batch[model] else { continue }
                    try fold(model: model, keys: keys)
                }
                // Inside the fold's own transaction: the stamp and the rows it
                // vouches for commit together or not at all.
                try stamp(FoldedState(vector: vector, models: certified), whole: false)
            }
        } catch {
            markBroken(error)
            throw Self.foldBroken(error)
        }
        lock.withLock { _foldCount += 1 }
        return batch.keys.sorted()
    }

    /// Fold a model's WHOLE overlay — the catch-up a bind runs, and the repair
    /// that clears a fold-broken document.
    ///
    /// Also the only thing that clears ``isFoldBroken``: the merged rows it
    /// writes are computed from the overlay as it stands, so they do not
    /// depend on the delta that failed. A catch-up of SOME models repairs
    /// those models' rows but leaves the document broken — the failed batch
    /// may have been about a model this one did not fold.
    ///
    /// - Returns: the models it folded, for the caller's notifications.
    @discardableResult
    public func catchUp(models: [String]? = nil) throws -> [String] {
        let registered = registeredModels()
        let targets = models ?? registered
        // Take THIS catch-up's models out of the pending batch before the
        // overlay is read, and only those: a catch-up of one model folds that
        // model's whole overlay, which supersedes its captured keys, and says
        // nothing about any other model's. Clearing the rest would leave an
        // arrived update unfolded with no pending work and no refusal to show
        // for it. Taking them BEFORE the read also keeps whatever lands
        // during the catch-up for the next drain — folding it twice is
        // idempotent, folding it never is a permanently stale row.
        lock.withLock { for model in targets { touched.removeValue(forKey: model) } }
        // #3782 — read before any value is: what lands during the catch-up is
        // above this vector, and is the next drain's to fold and vouch for.
        let vector = overlay.stateVector()
        // What this catch-up certifies through `vector`: its own models, and
        // every other caught-up model with no captured key still waiting — a
        // key taken before the read is folded, one still pending is not
        // (finding 3782-C04). A broken observer lost the failed batch's keys,
        // so it vouches for nothing but what it folds here.
        let certified: [String] = lock.withLock {
            var models = Set(targets)
            if brokenBy == nil {
                let pending = Set(touched.keys).subtracting(targets)
                models.formUnion(
                    caughtUp.intersection(subscriptions.keys).subtracting(pending)
                )
            }
            return Array(models)
        }
        do {
            try store.transaction {
                for model in targets {
                    let entries = overlay.entries(model: model)
                    let grouped = OverlayKeys.group(entries)
                    for entry in grouped.values.sorted(by: { $0.id < $1.id }) {
                        try store.applyRemote(model: model, entry: entry)
                    }
                }
                // Whole model maps were folded: the stamp may be the first
                // thing to vouch for these models, in the fold's transaction.
                try stamp(FoldedState(vector: vector, models: certified), whole: true)
            }
        } catch {
            markBroken(error)
            throw Self.foldBroken(error)
        }
        lock.withLock {
            caughtUp.formUnion(targets)
            _foldCount += 1
            _lastCatchUpModels = targets.sorted()
        }
        // The fold-broken state is the DOCUMENT's, so only a catch-up that
        // covered every registered model repaired it. A partial one — the
        // catch-up a model registered after the bind runs — folded its own
        // model whole and knows nothing about the batch that failed.
        guard Set(registered).isSubset(of: Set(targets)) else { return targets }
        lock.withLock { brokenBy = nil }
        return targets
    }

    /// Fold `model`'s whole overlay unless a catch-up has already covered it.
    ///
    /// What a model registered AFTER the bind needs, and only it: the bind's
    /// own catch-up covered every model registered by then, so asking again for
    /// those would re-read the whole overlay of a document this format exists
    /// because it is large. A model the bind never heard of has folded nothing,
    /// and without this its records are absent from the merged view until some
    /// later update happens to touch them.
    public func catchUpIfNeeded(model: String) throws {
        guard lock.withLock({ !caughtUp.contains(model) }) else { return }
        try catchUp(models: [model])
    }

    /// Record that `models` need no catch-up: the store's folded state already
    /// covers them at this overlay's vector (#3782). What lets a bind that
    /// folded nothing stay that way through each model's registration.
    public func markCaughtUp(_ models: [String]) {
        lock.withLock { caughtUp.formUnion(models) }
    }

    /// Whether a catch-up — or a bind that found nothing to fold — has
    /// covered `model`.
    public func hasCaughtUp(_ model: String) -> Bool {
        lock.withLock { caughtUp.contains(model) }
    }

    /// Folds committed so far, drains and catch-ups alike (#3782).
    var foldCount: Int { lock.withLock { _foldCount } }

    /// The models the last catch-up folded whole, or `nil` when none has run.
    var lastCatchUpModels: [String]? { lock.withLock { _lastCatchUpModels } }

    /// Stamp what a fold that has just written its rows certifies. Inside
    /// the fold's transaction.
    ///
    /// - An overlay behind the stored vector on any client has just folded
    ///   older values under keys the stamp vouches for newer ones of: nothing
    ///   is certified any more, and the next bind folds the whole overlay
    ///   (finding 3782-C05). The rows are already written, so the stamp goes
    ///   with them rather than staying to vouch for them.
    /// - A merge that would carry a model this fold did not certify to a newer
    ///   vector is replaced by exactly what it certified (finding 3782-C04).
    /// - Otherwise the store's own merge, under its guard.
    private func stamp(_ offered: FoldedState, whole: Bool) throws {
        let docState = overlay.stateVector()
        if let held = try store.foldedState() {
            guard FoldedState.isAtOrAhead(docState, of: held.vector) else {
                try store.clearFoldedState()
                logger?.warn(
                    "[format2]", store.documentId,
                    "— folded from an overlay behind the store; the next open folds the whole overlay"
                )
                return
            }
            if !held.mergeKeepsEveryModel(offered) {
                if offered.models.isEmpty {
                    try store.clearFoldedState()
                } else {
                    try store.replaceFoldedState(offered)
                }
                return
            }
        }
        try store.noteFoldedState(offered, docState: docState, whole: whole)
    }

    private func fold(model: String, keys: Set<ByteKey>) throws {
        // Values are materialized HERE, at fold time, not in the callback:
        // the value a key holds now is the one the merged view should show.
        //
        // A key the overlay no longer HOLDS is skipped, exactly as
        // `materializeOverlayEntries` skips it. Reading it as a null would
        // make a removed key an explicit unset — a removed `r/title` would
        // clear the field, and a removed member key would drop the member —
        // where the record-level markers are what express a delete. Removing
        // an overlay key is cleanup (a re-create drops the previous
        // lifetime's keys); it carries no meaning of its own.
        var entries: [(String, JSONValue)] = []
        for key in keys {
            guard let value = overlay.value(model: model, key: key.value) else { continue }
            entries.append((key.value, value))
        }
        var grouped = OverlayKeys.group(entries)
        // A `_replace` discards the stored row, so the record has to be
        // rebuilt from every key it currently has — not just the ones this
        // update carried.
        overlay.complete(&grouped, model: model)
        for entry in grouped.values.sorted(by: { $0.id < $1.id }) {
            try store.applyRemote(model: model, entry: entry)
        }
    }

    // MARK: - Fold-broken

    /// Whether the merged view is known to be wrong.
    public var isFoldBroken: Bool { lock.withLock { brokenBy != nil } }

    /// Refuse if the merged view is broken. Called by every read and by the
    /// write path BEFORE its serialized operation starts, so a refused write
    /// leaves no pending op and publishes nothing.
    public func assertWritable() throws {
        if let brokenBy = lock.withLock({ brokenBy }) { throw Self.foldBroken(brokenBy) }
    }

    public func read(model: String, recordId: String) throws -> [String: JSONValue]? {
        try assertWritable()
        return try store.read(model: model, recordId: recordId)
    }

    public func readAll(model: String) throws -> [[String: JSONValue]] {
        try assertWritable()
        return try store.readAll(model: model)
    }

    private func markBroken(_ error: Error) {
        // Only the call that makes the transition reports it: the state is
        // sticky, and a document already broken has already said so.
        let announce = lock.withLock { () -> (@Sendable (JsBaoError) -> Void)?? in
            guard brokenBy == nil else { return nil }
            brokenBy = error
            return .some(_onFoldBroken)
        }
        guard let announce else { return }
        // One line an operator can grep for, naming the document and the
        // reason — the merged view is wrong from here until a rebind.
        logger?.warn(
            "[format2] fold broken for document", store.documentId,
            "— reads and writes are refused until a rebind repairs it:",
            String(describing: error)
        )
        announce?(Self.foldBroken(error))
    }

    private static func foldBroken(_ error: Error) -> JsBaoError {
        JsBaoError(
            code: .format2FoldBroken,
            message: "The local merged view of this large document is out of step "
                + "with its overlay and cannot be trusted. Reopen the document to repair it.",
            details: ["error": .string(String(describing: error))]
        )
    }
}
