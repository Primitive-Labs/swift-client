import Foundation

/// One index of a db3's list, as the room answers `GET db3/:id/indexes`.
struct RecordLogIndexEntry: Equatable, Sendable {
    /// The room's name for it; the store names its own index its own way.
    var name: String
    var model: String
    var fields: [String]
    var unique: Bool
    /// A string-set field's member index: a table of the room's own when
    /// placed `.server`, and of each device's when placed `.device` or
    /// `.both` (#5223); a local-only db3's store keeps one of its own (#5156).
    var members: Bool
    /// What the index is (#5220): `.members` for a member index.
    var kind: Db3IndexKind
    /// Where it lives (#5220): a synced db3's store builds an entry placed
    /// `.device` or `.both` and skips one placed `.server`.
    var on: Db3IndexPlacement
    /// A text index's options (#5223), as the room lists them; absent reads as the defaults.
    var text: JSONValue?
    /// A vector index's options and its field's encoding (#5230), as the room
    /// lists them (`distance`, `index`, `dims`, `element`); absent when the
    /// room does not say how to build it.
    var vector: JSONValue?
    /// A vector index's generation (#5230): a model of another generation is never this index's.
    var generation: Int?
    /// A vector index's model revision (#5230): a model of another revision is dropped.
    var revision: Int?
    /// A vector index's shared ANN model, when one is uploaded (#5230):
    /// `{ revision, trainedAt, rows, bytes, format }` as the room lists it.
    var annModel: JSONValue?

    init(
        name: String, model: String, fields: [String], unique: Bool, members: Bool = false, kind: Db3IndexKind? = nil,
        on: Db3IndexPlacement? = nil, text: JSONValue? = nil, vector: JSONValue? = nil, generation: Int? = nil, revision: Int? = nil,
        annModel: JSONValue? = nil
    ) {
        self.name = name
        self.model = model
        self.fields = fields
        self.unique = unique
        self.members = members
        self.kind = kind ?? (members ? .members : .scalar)
        // A member entry without `on` is the room's; a vector entry's is on the device (#5230); any other kind's is on both.
        self.on = on ?? (self.kind == .members ? .server : self.kind == .vector ? .device : .both)
        self.text = text
        self.vector = vector
        self.generation = generation
        self.revision = revision
        self.annModel = annModel
    }

    /// One entry of the room's `indexes` array, or `nil` when it names no model
    /// or fields. A room from before #5220 lists no `kind` or `on`: its entry
    /// reads as a scalar index on both (a member index on the server).
    init?(json: JSONValue) {
        guard let model = json["model"]?.stringValue, let fields = json["fields"]?.arrayValue else { return nil }
        self.init(
            name: json["name"]?.stringValue ?? "", model: model, fields: fields.compactMap(\.stringValue),
            unique: json["unique"]?.boolValue ?? false, members: json["members"]?.boolValue ?? false,
            kind: json["kind"]?.stringValue.flatMap(Db3IndexKind.init(rawValue:)),
            on: json["on"]?.stringValue.flatMap(Db3IndexPlacement.init(rawValue:)),
            text: json["text"], vector: json["vector"]?.objectValue.map(JSONValue.object),
            generation: RecordLogVectorIndex.integer(json["generation"]), revision: RecordLogVectorIndex.integer(json["revision"]),
            annModel: json["annModel"]?.objectValue.map(JSONValue.object)
        )
    }

    /// A text entry's options over its fields, filled in (#5223).
    ///
    /// - Throws: `JsBaoError(.db3IndexInvalid)` as ``RecordLogTextIndexOptions/parse(fields:raw:)``.
    func textOptions() throws -> RecordLogTextIndexOptions {
        try RecordLogTextIndexOptions.parse(fields: fields, raw: text)
    }
}

/// One view index of a store, as the room lists one: `(model, fields, unique)`.
struct RecordLogIndexTuple: Equatable, Sendable {
    var model: String
    var fields: [String]
    var unique: Bool
}

/// What a reconcile did.
struct RecordLogIndexSync: Equatable, Sendable {
    var created: Int
    var dropped: Int
}

/// The order a db3's index-list reads are applied in. Reads may answer out of
/// order (the open's read and the read on the room's `record.declared` run side
/// by side) and the store replaces its cached list with each one it is handed,
/// so a read answered after a later one was applied is dropped. js-bao's
/// `Db3IndexReadOrder`.
///
/// `@unchecked Sendable`: its one mutable property, `reads`, is read and
/// written only under `lock`, a leaf lock held for the lookup alone.
/// `applying` serializes the applications themselves (the check, the store's
/// sync and the mark), so two answers in flight never apply out of order.
final class RecordLogIndexReadOrder: @unchecked Sendable {
    private let lock = NSLock()
    private let applying = NSLock()
    private var reads: [String: (issued: Int, applied: Int)] = [:]
    /// The reads of each binding of a db3's store (#5101), numbered apart
    /// from `issue`/`apply`'s: what the refresher issues and accepts.
    private var bindings: [String: RecordLogIndexReads] = [:]
    private var generations: [String: Int] = [:]

    /// Number a new read of `documentId`'s list.
    func issue(_ documentId: String) -> Int {
        lock.withLock {
            var current = reads[documentId] ?? (0, 0)
            current.issued += 1
            reads[documentId] = current
            return current.issued
        }
    }

    /// Apply read `read` of `documentId`'s list with `body`, unless a later
    /// read's list was applied already. The check, `body` and the mark run as
    /// one step, one application at a time, so of two answers in flight the
    /// later-issued one is applied last or the older one not at all. The read
    /// counts as applied once `body` returns; a `body` that throws marks
    /// nothing. Answers whether `body` ran.
    @discardableResult
    func apply(_ documentId: String, _ read: Int, _ body: () throws -> Void) throws -> Bool {
        applying.lock()
        defer { applying.unlock() }
        guard lock.withLock({ read >= (reads[documentId]?.applied ?? 0) }) else { return false }
        try body()
        lock.withLock {
            var current = reads[documentId] ?? (read, 0)
            current.applied = max(current.applied, read)
            reads[documentId] = current
        }
        return true
    }

    // MARK: - Per binding (#5101)

    private func readsLocked(_ documentId: String) -> RecordLogIndexReads {
        if let reads = bindings[documentId] { return reads }
        let fresh = RecordLogIndexReads(generation: generations[documentId] ?? 0)
        bindings[documentId] = fresh
        return fresh
    }

    private func update<T>(_ documentId: String, _ body: (inout RecordLogIndexReads) -> T) -> T {
        lock.withLock {
            var reads = readsLocked(documentId)
            defer { bindings[documentId] = reads }
            return body(&reads)
        }
    }

    /// The store of `documentId` was bound anew (or unbound): reads issued
    /// before are dropped, and nothing is owed or awaited.
    func rebind(_ documentId: String) {
        lock.withLock {
            let generation = (generations[documentId] ?? 0) + 1
            generations[documentId] = generation
            bindings[documentId] = RecordLogIndexReads(generation: generation)
        }
    }

    /// Number a new read of `documentId`'s list under its current binding.
    func issueRead(_ documentId: String) -> RecordLogIndexReadToken {
        update(documentId) { reads in
            reads.issued += 1
            return RecordLogIndexReadToken(generation: reads.generation, read: reads.issued)
        }
    }

    /// Whether `token` was issued under the current binding of `documentId`.
    func current(_ documentId: String, _ token: RecordLogIndexReadToken) -> Bool {
        update(documentId) { $0.generation == token.generation }
    }

    /// Whether the read `token` names is applied; marks it applied when it is.
    func accept(_ documentId: String, _ token: RecordLogIndexReadToken) -> Bool {
        update(documentId) { reads in
            guard token.generation == reads.generation, token.read >= reads.applied else { return false }
            reads.applied = token.read
            if token.read > reads.failed { reads.owed = false }
            return true
        }
    }

    /// Whether `token` names the latest read of the binding that was accepted.
    func latest(_ documentId: String, _ token: RecordLogIndexReadToken) -> Bool {
        update(documentId) { $0.generation == token.generation && $0.applied == token.read }
    }

    /// The read `token` names failed: the list is owed unless a later read of the binding applied.
    func fail(_ documentId: String, _ token: RecordLogIndexReadToken) {
        update(documentId) { reads in
            guard token.generation == reads.generation, token.read > reads.applied else { return }
            reads.failed = max(reads.failed, token.read)
            reads.owed = true
        }
    }

    /// The list the accepted read `token` names could not be handed to the
    /// store: it is owed as a failed read is, unless a later read was accepted.
    func applyFailed(_ documentId: String, _ token: RecordLogIndexReadToken) {
        update(documentId) { reads in
            guard token.generation == reads.generation, token.read >= reads.applied else { return }
            reads.failed = max(reads.failed, token.read)
            reads.owed = true
        }
    }

    /// The open's declaration acknowledgment is awaited.
    func expectDeclared(_ documentId: String) {
        update(documentId) { $0.declarationPending = true }
    }

    /// The room acknowledged the declarations (or the wait for it ended).
    func declared(_ documentId: String) {
        update(documentId) { $0.declarationPending = false }
    }

    /// Whether the open's declaration acknowledgment is awaited.
    func declarationPending(_ documentId: String) -> Bool {
        lock.withLock { bindings[documentId]?.declarationPending ?? false }
    }

    /// Whether the latest read of the binding has neither applied nor failed.
    func outstanding(_ documentId: String) -> Bool {
        lock.withLock { bindings[documentId]?.outstanding ?? false }
    }

    /// Whether any read of the binding was issued.
    func issuedAny(_ documentId: String) -> Bool {
        lock.withLock { (bindings[documentId]?.issued ?? 0) > 0 }
    }

    /// Whether the list is owed: the last read to settle failed and none applied after it.
    func owed(_ documentId: String) -> Bool {
        lock.withLock { bindings[documentId]?.owed ?? false }
    }

    /// Whether the binding's list is as the room answered it: a read applied,
    /// none outstanding, nothing owed and no acknowledgment awaited. A
    /// document never read is settled: nothing is expected of it.
    func settled(_ documentId: String) -> Bool {
        lock.withLock {
            guard let reads = bindings[documentId], reads.issued > 0 else { return true }
            if reads.declarationPending || reads.outstanding || reads.owed { return false }
            return reads.applied > 0
        }
    }

    /// The documents with reads recorded per binding.
    func documents() -> [String] {
        lock.withLock { Array(bindings.keys) }
    }
}

/// A read of a db3's list: the binding it was issued under, and its number there.
struct RecordLogIndexReadToken: Equatable, Sendable {
    var generation: Int
    var read: Int
}

/// The reads of one binding of a db3's store.
struct RecordLogIndexReads: Sendable {
    var generation: Int
    var issued = 0
    var applied = 0
    /// The highest read of this binding that failed.
    var failed = 0
    /// The last read to settle failed, and no later read applied.
    var owed = false
    /// The open's declaration acknowledgment is awaited (`record.declared`).
    var declarationPending = false

    var outstanding: Bool { issued > applied && issued > failed }
}

/// How a db3's index-list read settled: `applied` when its list is in the
/// store, `failed` when it failed with no retry possible now (the socket
/// down, networking not allowed, or the server's final refusal).
enum RecordLogIndexOutcome: Sendable, Equatable {
    case applied
    case failed
}

/// A wait the refresher armed: a retry, or the open's declaration wait.
protocol RecordLogIndexTimer: AnyObject, Sendable {
    func cancel()
}

/// A timer on a task's sleep.
final class RecordLogIndexTaskTimer: RecordLogIndexTimer {
    private let task: Task<Void, Never>

    init(after delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func cancel() { task.cancel() }
}

/// Runs a store's write of an index list only while the read it hands is
/// still the binding's latest, with no rebind between the check and the
/// write; answers whether the write ran.
typealias RecordLogIndexApplyGuard = @Sendable (() throws -> Void) throws -> Bool

/// What a ``RecordLogIndexRefresher`` needs of its client: js-bao's
/// `Db3IndexRefresherDeps`. Every member has a default, so a test names only
/// what its world answers.
struct RecordLogIndexRefresherDeps: Sendable {
    /// Read the db3's list from its room (`GET db3/:id/indexes`, bounded).
    var read: @Sendable (String) async throws -> [RecordLogIndexEntry] = { _ in [] }
    /// Hand the list to the db3's bound store: the store's write runs inside
    /// the guard, so a list of an earlier binding never reaches a later one.
    var apply: @Sendable (String, [RecordLogIndexEntry], RecordLogIndexApplyGuard) async throws -> Void = { _, _, write in
        _ = try write {}
    }
    /// Whether the db3's store is bound on this client.
    var bound: @Sendable (String) -> Bool = { _ in true }
    /// Whether the socket is open and the client may use the network.
    var socketUp: @Sendable () -> Bool = { true }
    /// Whether the db3's open sends a declaration the room acknowledges: not
    /// a typed db3 (acknowledged before it is live) nor a read-only one
    /// (whose declaration the room refuses). Without it, every open is waited for.
    var declares: (@Sendable (String) -> Bool)?
    /// A read settled (see ``RecordLogIndexOutcome``).
    var settled: @Sendable (String, RecordLogIndexOutcome) -> Void = { _, _ in }
    /// Arm a timer firing once after the delay.
    var setTimer: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> any RecordLogIndexTimer = { delay, fire in
        RecordLogIndexTaskTimer(after: delay, fire)
    }
    var logger: Logger?
}

/// A db3's index-list reads on this client (#5101), the port of js-bao's
/// `Db3IndexRefresher` (#5070): reads numbered per binding
/// (``RecordLogIndexReadOrder``), a failed read asked again on a backoff while
/// the store is bound and the socket up (1 s, doubling, 10 s at most), an
/// owed read asked again at the socket's open and when networking is allowed
/// again, and each open's declaration acknowledgment awaited from the db3's
/// live. Lists reach the store in the order their reads were accepted, and a
/// read is answered once a list at least as recent is in the store.
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// `lock`, which is never held across a call out of this class. A read is
/// accepted and its application registered under `lock` in one step, so
/// applications queue in the order their reads were accepted and `settled`
/// never sees an accepted read whose list is not on its way. `storeWrite`
/// is held across a store's write of a list and across a rebind, so a list
/// checked as current is written before the binding changes, or not at all.
final class RecordLogIndexRefresher: @unchecked Sendable {

    /// How long the read of a db3's index list may take before it is
    /// abandoned (the cached list stands), and how long a live open waits
    /// before looking at its declaration wait again.
    static let listTimeout: TimeInterval = 10
    /// The first wait before a failed read is asked again; it doubles up to ``retryMax``.
    static let retryInitial: TimeInterval = 1
    /// The longest wait between two attempts of a failed read.
    static let retryMax: TimeInterval = 10

    private struct Retry {
        var timer: (any RecordLogIndexTimer)?
        var delay: TimeInterval = RecordLogIndexRefresher.retryInitial
        var warned = false
    }

    /// A list being handed to a db3's store. `@unchecked Sendable`: `task`
    /// is set once, under the refresher's `lock`, before anyone reads it.
    private final class Application: @unchecked Sendable {
        var task: Task<Void, Error>?
    }

    /// The timer a closure armed, for its identity check when it fires.
    /// `@unchecked Sendable`: `_timer` is read and written under `lock`, a
    /// leaf lock held for the access alone.
    private final class TimerRef: @unchecked Sendable {
        private let lock = NSLock()
        private var _timer: (any RecordLogIndexTimer)?
        var timer: (any RecordLogIndexTimer)? {
            get { lock.withLock { _timer } }
            set { lock.withLock { _timer = newValue } }
        }
    }

    private let deps: RecordLogIndexRefresherDeps
    private let order = RecordLogIndexReadOrder()
    private let lock = NSLock()
    /// Taken before `lock` when both are held.
    private let storeWrite = NSLock()
    private var retries: [String: Retry] = [:]
    private var declarationTimers: [String: any RecordLogIndexTimer] = [:]
    /// The bindings whose open's declaration was acknowledged.
    private var acknowledged: Set<String> = []
    /// The last list being handed to each db3's store: the next waits for it.
    private var applications: [String: Application] = [:]
    /// The bindings that were live since they were bound.
    private var wasLive: Set<String> = []
    /// The bindings opened again since they were live (a reconnect, a reopen): the next live reads the list.
    private var reopened: Set<String> = []
    /// The db3s being opened whose store is not bound yet.
    private var binding: Set<String> = []
    /// The bindings a notice came for while a read was on its way: one more read once it settles (#5322).
    private var followUps: Set<String> = []
    private var destroyed = false

    init(deps: RecordLogIndexRefresherDeps) {
        self.deps = deps
    }

    // MARK: - The open

    /// The db3 is being opened here: a new binding, its list on its way from
    /// now, though the read waits for the store to be bound (``opened(_:)``).
    func opening(_ documentId: String) {
        rebind(documentId)
        lock.withLock { _ = binding.insert(documentId) }
    }

    /// The db3 was opened here (its store bound for the open): its list is read at once.
    @discardableResult
    func opened(_ documentId: String) -> Task<Void, Error> {
        if !lock.withLock({ binding.contains(documentId) }) { rebind(documentId) }
        // The bind's mark ends in the step that issues the read, so `settled`
        // never sees the bind done with no read out.
        return start(documentId, opened: true)
    }

    /// The db3's open failed before its store was bound: no read is on its way.
    func openFailed(_ documentId: String) {
        if lock.withLock({ binding.remove(documentId) != nil }) { deps.settled(documentId, .failed) }
    }

    /// The room acknowledged the open's declarations: an index they created is in its list from now.
    @discardableResult
    func declared(_ documentId: String) -> Task<Void, Error> {
        lock.withLock { _ = acknowledged.insert(documentId) }
        order.declared(documentId)
        clearDeclarationTimer(documentId)
        return start(documentId)
    }

    /// The room said the db3's index list changed (`record.indexes`, #5322,
    /// js-bao's `Db3IndexRefresher.noticed`). With no read of the binding on
    /// its way the list is read now; with one, one more read is issued once it
    /// settles, however many notices come meanwhile. A notice for a db3 not
    /// bound here, or heard with the socket down, reads nothing: the next open
    /// reads the list. The read is an ordinary one: `settled` and `pending` count it.
    func noticed(_ documentId: String) {
        guard !isDestroyed, deps.bound(documentId), deps.socketUp() else {
            deps.logger?.debug("[db3] \(documentId): the index list changed in the room; not read now (the next open reads it)")
            return
        }
        let waiting = lock.withLock { () -> Bool in
            guard applications[documentId] != nil || order.outstanding(documentId) else { return false }
            followUps.insert(documentId)
            return true
        }
        guard !waiting else { return }
        deps.logger?.debug("[db3] \(documentId): the index list changed in the room; reading it again")
        start(documentId)
    }

    /// A read settled: a notice that came while it was on its way is read now, once nothing else is.
    private func followUp(_ documentId: String) {
        let due = lock.withLock { () -> Bool in
            guard followUps.contains(documentId), applications[documentId] == nil, !order.outstanding(documentId) else { return false }
            followUps.remove(documentId)
            return true
        }
        if due { noticed(documentId) }
    }

    /// The db3's session reported a phase: `live` is ``live(_:)``; going idle
    /// or opening again after it was live starts a new open, whose list and
    /// declaration acknowledgment are awaited at its live.
    func statusChanged(_ documentId: String, _ phase: RecordLogSessionPhase) {
        if phase == .live { return live(documentId) }
        guard phase == .idle || phase == .opening else { return }
        let reopen = lock.withLock { () -> Bool in
            guard wasLive.remove(documentId) != nil else { return false }
            reopened.insert(documentId)
            acknowledged.remove(documentId)
            return true
        }
        guard reopen else { return }
        clearDeclarationTimer(documentId)
        order.declared(documentId)
    }

    /// The db3 went live: a declaration the room acknowledges and has not yet
    /// acknowledged is awaited (the room answers every declaration of a db3 it
    /// serves; `ready()`'s own timeout bounds the wait). Opened again, the list
    /// is read for this open: by the acknowledgment's read when the open
    /// declares. A list owed and not being asked for is asked for at once.
    func live(_ documentId: String) {
        if lock.withLock({ destroyed }) { return }
        let declares = self.declares(documentId)
        let (reread, owed) = lock.withLock { () -> (Bool, Bool) in
            wasLive.insert(documentId)
            let reread = reopened.remove(documentId) != nil && !declares
            let owed = order.owed(documentId) && !order.outstanding(documentId) && retries[documentId]?.timer == nil
            return (reread, owed)
        }
        if reread || owed, deps.bound(documentId) { start(documentId) }
        guard declares, !lock.withLock({ acknowledged.contains(documentId) }), !order.declarationPending(documentId) else { return }
        order.expectDeclared(documentId)
        // A store turned read-only after its live: its declaration is
        // refused, not acknowledged, so the wait is looked at again.
        let ref = TimerRef()
        let timer = deps.setTimer(Self.listTimeout) { [weak self] in self?.declarationTimerFired(documentId, ref) }
        ref.timer = timer
        let replaced = lock.withLock { () -> (any RecordLogIndexTimer)? in
            defer { declarationTimers[documentId] = timer }
            return declarationTimers[documentId]
        }
        replaced?.cancel()
    }

    private func declarationTimerFired(_ documentId: String, _ ref: TimerRef) {
        let current = lock.withLock { () -> Bool in
            guard let armed = declarationTimers[documentId], armed === ref.timer else { return false }
            declarationTimers[documentId] = nil
            return true
        }
        guard current, order.declarationPending(documentId), !declares(documentId) else { return }
        if settled(documentId) { deps.settled(documentId, .applied) }
    }

    // MARK: - Bindings

    /// The db3's store was unbound, or bound anew: its reads in flight are dropped, its retry and waits end.
    func rebind(_ documentId: String) {
        storeWrite.withLock {
            lock.withLock {
                order.rebind(documentId)
                binding.remove(documentId)
                acknowledged.remove(documentId)
                applications[documentId] = nil
                wasLive.remove(documentId)
                reopened.remove(documentId)
                followUps.remove(documentId)
            }
        }
        clearRetry(documentId)
        clearDeclarationTimer(documentId)
    }

    /// Every db3's store was unbound (the user changed).
    func rebindAll() {
        for documentId in order.documents() { rebind(documentId) }
    }

    // MARK: - Reads

    /// Read the db3's list and apply it. Returns once it applied, or a list at
    /// least as recent did (a later read), or the store was bound anew; throws
    /// when it failed, the list then owed and asked again as the socket allows.
    func refresh(_ documentId: String) async throws {
        try await start(documentId).value
    }

    /// Issue a read now (its number taken before this returns) and run it.
    @discardableResult
    private func start(_ documentId: String, opened: Bool = false) -> Task<Void, Error> {
        let (token, waiting) = lock.withLock { () -> (RecordLogIndexReadToken?, (any RecordLogIndexTimer)?) in
            if opened { binding.remove(documentId) }
            guard !destroyed else { return (nil, nil) }
            let waiting = retries[documentId]?.timer
            retries[documentId]?.timer = nil
            return (order.issueRead(documentId), waiting)
        }
        waiting?.cancel()
        guard let token else { return Task {} }
        return Task { [weak self] in
            guard let self else { return }
            // A notice heard while this read was on its way is read once it settles (#5322).
            defer { if self.order.current(documentId, token) { self.followUp(documentId) } }
            let entries: [RecordLogIndexEntry]
            do {
                entries = try await self.deps.read(documentId)
            } catch {
                // A read of an earlier binding: nothing of it is owed.
                guard !self.isDestroyed, self.order.current(documentId, token) else { return }
                self.order.fail(documentId, token)
                guard self.order.owed(documentId) else {
                    // A later read was accepted: answered once its list is in the store.
                    try await self.untilApplied(documentId)
                    return
                }
                self.failed(documentId, error, final: Self.finalRefusal(error))
                throw error
            }
            try await self.take(documentId, token, entries)
        }
    }

    private var isDestroyed: Bool { lock.withLock { destroyed } }

    /// A read answered: its list goes to the store after the lists accepted before it.
    private func take(_ documentId: String, _ token: RecordLogIndexReadToken, _ entries: [RecordLogIndexEntry]) async throws {
        let application = Application()
        let accepted = lock.withLock { () -> Bool in
            guard order.accept(documentId, token) else { return false }
            let previous = applications[documentId]?.task
            applications[documentId] = application
            application.task = Task { [weak self] in
                _ = try? await previous?.value
                guard let self else { return }
                try await self.applyList(documentId, token, entries, application)
            }
            return true
        }
        guard accepted else {
            // A later read of the binding was accepted: answered once its list is in the store.
            if order.current(documentId, token) { try await untilApplied(documentId) }
            return
        }
        try await application.task?.value
        // Superseded while it waited: answered once the later list is in the store.
        if lock.withLock({ applications[documentId] !== application }), order.current(documentId, token) {
            try await untilApplied(documentId)
        }
    }

    /// Run `write` only while `token` is the binding's latest accepted read,
    /// with no rebind between the check and the write.
    private func whileLatest(_ documentId: String, _ token: RecordLogIndexReadToken, _ write: () throws -> Void) throws -> Bool {
        try storeWrite.withLock {
            guard lock.withLock({ !destroyed && order.latest(documentId, token) }) else { return false }
            try write()
            return true
        }
    }

    private func applyList(
        _ documentId: String, _ token: RecordLogIndexReadToken, _ entries: [RecordLogIndexEntry], _ application: Application
    ) async throws {
        // A read accepted meanwhile hands its own, later list to the store.
        guard order.latest(documentId, token) else { return }
        do {
            try await deps.apply(documentId, entries) { [weak self] write in
                try self?.whileLatest(documentId, token, write) ?? false
            }
        } catch {
            // Not in the store: owed as a failed read is, in the step that
            // ends the application, so `settled` never sees it applied.
            let owed = lock.withLock { () -> Bool? in
                if applications[documentId] === application { applications[documentId] = nil }
                guard !destroyed, order.current(documentId, token) else { return nil }
                order.applyFailed(documentId, token)
                return order.owed(documentId)
            }
            guard let owed else { return }
            if owed { failed(documentId, error, final: false) }
            throw error
        }
        let last = lock.withLock { () -> Bool in
            guard applications[documentId] === application else { return false }
            applications[documentId] = nil
            return true
        }
        // A later list is on its way, or a later read failed: its obligation (and retry) stands.
        guard last, !isDestroyed, order.current(documentId, token), !order.owed(documentId) else { return }
        clearRetry(documentId)
        deps.settled(documentId, .applied)
    }

    /// Returns once the latest list accepted for the binding is in the store:
    /// each application waited for may itself be superseded by a later one.
    /// Throws when the application waited for could not hand its list to the store.
    private func untilApplied(_ documentId: String) async throws {
        var entry = lock.withLock { applications[documentId] }
        while let current = entry {
            try await current.task?.value
            let next = lock.withLock { applications[documentId] }
            if next === current { return }
            entry = next
        }
    }

    /// Whether a failed read was the server's final answer (a 4xx but a
    /// timeout or a rate limit): it is not asked again on a backoff.
    static func finalRefusal(_ error: Error) -> Bool {
        guard let status = (error as? HttpError)?.status else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }

    private func failed(_ documentId: String, _ error: Error, final: Bool) {
        let warned = lock.withLock { () -> Bool in
            var retry = retries[documentId] ?? Retry()
            defer {
                retry.warned = true
                retries[documentId] = retry
            }
            return retry.warned
        }
        let status = (error as? HttpError).map { " (\($0.status))" } ?? ""
        let line = "[db3] \(documentId): the index list could not be read\(status): \(error.localizedDescription);"
            + " the store keeps its cached indexes until it is read."
        if warned { deps.logger?.debug(line) } else { deps.logger?.warn(line) }
        if !final, deps.bound(documentId), deps.socketUp() {
            let delay = lock.withLock { () -> TimeInterval in
                let delay = retries[documentId]?.delay ?? Self.retryInitial
                retries[documentId]?.delay = min(delay * 2, Self.retryMax)
                return delay
            }
            let ref = TimerRef()
            let timer = deps.setTimer(delay) { [weak self] in self?.retryFired(documentId, ref) }
            ref.timer = timer
            lock.withLock { retries[documentId]?.timer = timer }
            return
        }
        if !deps.bound(documentId) { clearRetry(documentId) }
        deps.settled(documentId, .failed)
    }

    private func retryFired(_ documentId: String, _ ref: TimerRef) {
        let current = lock.withLock { () -> Bool in
            guard let armed = retries[documentId]?.timer, armed === ref.timer else { return false }
            retries[documentId]?.timer = nil
            return true
        }
        guard current else { return }
        if isDestroyed || !deps.bound(documentId) {
            clearRetry(documentId)
            return
        }
        guard deps.socketUp() else {
            // Asked again at the socket's open, or when networking returns.
            deps.settled(documentId, .failed)
            return
        }
        deps.logger?.debug("[db3] \(documentId): reading the index list again")
        start(documentId)
    }

    /// The socket opened, or networking was allowed again on the same socket:
    /// every bound db3 whose list is owed is read again.
    func socketOpened() {
        guard !isDestroyed else { return }
        for documentId in order.documents() {
            guard order.owed(documentId), !order.outstanding(documentId) else { continue }
            if lock.withLock({ retries[documentId]?.timer != nil }) || !deps.bound(documentId) { continue }
            start(documentId)
        }
    }

    // MARK: - What a subscription's `ready()` waits for

    /// Whether the db3's list is applied for its binding and its open: `ready()` waits while it is not.
    func settled(_ documentId: String) -> Bool {
        // A store turned read-only meanwhile: its declaration is refused, not acknowledged.
        if order.declarationPending(documentId), !declares(documentId) {
            order.declared(documentId)
            clearDeclarationTimer(documentId)
        }
        // One snapshot of the applications and the reads: a read accepted
        // has its application registered in the same step.
        return lock.withLock {
            if applications[documentId] != nil || binding.contains(documentId) { return false }
            return order.settled(documentId)
        }
    }

    /// Whether a list is on its way: a read in flight or being applied, a
    /// retry waiting, or an acknowledgment awaited online.
    func pending(_ documentId: String) -> Bool {
        let held = lock.withLock {
            binding.contains(documentId) || applications[documentId] != nil || retries[documentId]?.timer != nil
                || order.outstanding(documentId)
        }
        if held { return true }
        return order.declarationPending(documentId) && declares(documentId) && deps.socketUp()
    }

    /// Whether the db3's list is owed (its last read failed).
    func owed(_ documentId: String) -> Bool {
        order.owed(documentId)
    }

    /// The client was destroyed: every retry and wait ends.
    func destroy() {
        let timers = lock.withLock { () -> [any RecordLogIndexTimer] in
            destroyed = true
            let all = retries.values.compactMap(\.timer) + Array(declarationTimers.values)
            retries = [:]
            declarationTimers = [:]
            return all
        }
        for timer in timers { timer.cancel() }
    }

    private func declares(_ documentId: String) -> Bool {
        deps.declares?(documentId) ?? true
    }

    private func clearRetry(_ documentId: String) {
        let timer = lock.withLock { retries.removeValue(forKey: documentId)?.timer }
        timer?.cancel()
    }

    private func clearDeclarationTimer(_ documentId: String) {
        let timer = lock.withLock { declarationTimers.removeValue(forKey: documentId) }
        timer?.cancel()
    }
}

/// A store's lookup indexes on its db3s' views, built from the room's index
/// lists rather than from model declarations. The Swift port of js-bao's
/// `record-log-client/indexes.ts`, names and all.
///
/// The list is cached per document in `record_log_indexes`; the indexes are
/// reconciled per store, over every cached document, by definition:
///
/// - one partial index on `record_log_view` per distinct `(model, fields)`,
///   with the columns `doc_id, json_extract(_data, '$.<field>')…, _id` and
///   `WHERE _type = '<model>'`, never SQL `UNIQUE` (uniqueness is the room's);
/// - one on `record_log_rows` for each unique single-field entry, where an
///   upsert's guess looks for the record holding its value;
/// - an existing index is matched by its definition, not its name; a new one
///   takes the canonical name, or `<canonical>_<n>` when another index holds
///   that name, so `(Note, [title])` and `(note, [title])` are two indexes;
/// - an index of the store's family (`idx_record_log_view_…`,
///   `idx_record_log_rows_…`) whose definition no cached entry wants is dropped.
///
/// A member index placed on the device (a local-only db3's, #5156, or a
/// synced db3's placed `.device` or `.both`, #5223) is a table of its own per
/// `(db3, model, field)`, in the room's shape (`(value, rid)` keyed by the
/// record's view rowid), named in the entry's cached row and kept equal to the
/// view's arrays by three triggers on `record_log_view`, so every write that
/// touches the view keeps it. A table or trigger of that family no cached row
/// names is dropped. A store holding a member table gathers SQLite's
/// statistics for the view and its member tables, as the room does (#5150).
enum RecordLogIndexes {

    /// The tables a store's lookup indexes are on, with the prefix of their names.
    private static let family: [(table: String, prefix: String)] = [
        ("record_log_view", "idx_record_log_view_"),
        ("record_log_rows", "idx_record_log_rows_"),
    ]

    /// The definition of an index on `table` over `model`'s `fields`, as the store writes it.
    static func definition(_ table: String, _ model: String, _ fields: [String]) -> String {
        let columns = (["doc_id"] + fields.map { "json_extract(_data, '$.\($0)')" } + ["_id"]).joined(separator: ", ")
        return "\(table)(\(columns)) WHERE _type = \(RecordLogSchema.quoteLiteral(model))"
    }

    /// The canonical name of the store's index on `table` (`view` or `rows`)
    /// over `model`'s `fields`: `idx_record_log_<table>_<len>_<model>` then
    /// `_<len>_<field>` per field, names lowercased.
    static func name(_ table: String, _ model: String, _ fields: [String]) -> String {
        let part = { (name: String) in "\(name.utf16.count)_\(name.lowercased())" }
        return (["idx_record_log_\(table)", part(model)] + fields.map(part)).joined(separator: "_")
    }

    /// A `CREATE INDEX` statement's definition: the text after `ON`, whitespace collapsed.
    static func definition(inSql sql: String) -> String? {
        guard let on = sql.range(of: #"\bON\s+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(sql[on.upperBound...])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\)"#, with: ")", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Why the store cannot index `entry`, or `nil`.
    private static func unusable(_ entry: RecordLogIndexEntry) -> String? {
        if !RecordLogSchema.isValidIdentifier(entry.model) { return "model '\(entry.model)' is not an identifier" }
        if let bad = entry.fields.first(where: { !RecordLogSchema.isValidIdentifier($0) }) {
            return "field '\(bad)' is not an identifier"
        }
        if entry.fields.isEmpty { return "it names no field" }
        return nil
    }

    /// Why a vector entry is not built while its room's list does not say how (#5230): ``RecordLogVectorIndex/unbuilt``.
    static let vectorUnbuilt = RecordLogVectorIndex.unbuilt

    /// What the store does with a cached entry (#5322): `build` it (no
    /// verdict, or `accepted`), `keep` it only when built (the client's
    /// `deviceIndexes` default leaves its kind out and no verdict says
    /// otherwise), or `decline` it (drop what is built). A db3 that lives only
    /// here has no policy: every one of its entries is built.
    enum Disposition: Equatable {
        case build
        case keep
        case decline
    }

    static func disposition(_ row: Format2SqlRow, _ deviceIndexes: Db3DeviceIndexes) -> Disposition {
        if row["local_only"].intValue == 1 { return .build }
        switch row["verdict"].stringValue {
        case "declined": return .decline
        case "accepted": return .build
        default:
            let kind = row["kind"].stringValue.flatMap(Db3IndexKind.init(rawValue:)) ?? .scalar
            return deviceIndexes.excludes(kind) ? .keep : .build
        }
    }

    /// Every cached row with its device's verdict and its db3's local-only
    /// mark, `filter` narrowing them (`i.` the cache).
    static func cachedRows(_ sql: RecordLogSql, _ filter: String = "", _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try sql.rows(
            """
            SELECT i.doc_id, i.model, i.fields, i.kind, i.is_unique, i.room_name, i.members, i.text, i.vector, i.options, p.verdict, s.local_only
              FROM record_log_indexes i
              LEFT JOIN record_log_index_policy p ON p.doc_id = i.doc_id AND p.model = i.model AND p.fields = i.fields AND p.kind = i.kind
              LEFT JOIN record_log_state s ON s.doc_id = i.doc_id
             \(filter)
             ORDER BY i.doc_id, i.model, i.fields, i.kind
            """,
            bindings
        )
    }

    static func fieldsOf(_ row: Format2SqlRow) -> [String] {
        (row["fields"].stringValue.flatMap(RecordLogJSON.parse)?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// A row's cached options as an object, or empty.
    static func optionsOf(_ row: Format2SqlRow) -> [String: JSONValue] {
        row["options"].stringValue.flatMap(RecordLogJSON.parse)?.objectValue ?? [:]
    }

    /// A scalar or member entry's options as cached (#5322): its placement
    /// when not `both`, and why it is not built; NULL when it has neither.
    private static func entryOptions(on: Db3IndexPlacement?, unbuilt: String?) -> Format2SqlValue {
        var object: [String: JSONValue] = [:]
        if let on { object["on"] = .string(on.rawValue) }
        if let unbuilt { object["unbuilt"] = .string(unbuilt) }
        return object.isEmpty ? .null : .text(RecordLogJSON.text(.object(object)))
    }

    /// The identity a cached row is found under across a replacement.
    private static func identity(_ model: String, _ fields: String, _ kind: String) -> String { "\(kind)\u{0}\(model)\u{0}\(fields)" }

    /// Replace `documentId`'s cached list with `entries` (when given), then
    /// reconcile the store's indexes (#5322, js-bao's `syncRecordLogIndexes`):
    /// the cache is replaced and every index no entry wants is dropped in one
    /// transaction; then each index to build is built in a transaction of its
    /// own (a scalar definition's view index and a unique one's rows index, a
    /// member table with its triggers, a text table with its triggers, a
    /// vector index's vec1 flat table with its triggers, #5230), which
    /// writes its table's name on the entry's row, so a row names a table only
    /// while the device holds it. A build that fails (a full disk) rolls back
    /// with nothing of it left, the entry is kept unbuilt with the reason
    /// (`options.unbuilt`), warned about when the reason is new and at debug
    /// while it stays, and the next build goes on; the next sync tries again.
    /// What is built follows the device's policy (`record_log_index_policy`)
    /// and the client's `deviceIndexes` default (``disposition(_:_:)``).
    ///
    /// An entry whose model or field is not an identifier is skipped with a
    /// warning; one on `id` alone needs no index of its own. A synced db3's
    /// entry placed `.server` is skipped, whatever its kind; a vector entry
    /// whose list gives no options is cached unbuilt
    /// (``RecordLogVectorIndex/unbuilt``). A member entry without `on` is the
    /// room's.
    ///
    /// - Parameter transaction: Runs its body as one transaction on the store's connection.
    /// - Returns: What the reconcile did, and whether it built a member table.
    static func sync(
        documentId: String, _ entries: [RecordLogIndexEntry]?, deviceIndexes: Db3DeviceIndexes, logger: Logger?,
        transaction: ((RecordLogSql) throws -> Void) throws -> Void
    ) throws -> (sync: RecordLogIndexSync, builtMembers: Bool) {
        var dropped = 0
        var rebuilding: [String: String] = [:]
        try transaction { sql in
            if let entries { try replace(sql, documentId: documentId, entries, logger: logger) }
            (dropped, rebuilding) = try dropUnwanted(sql, deviceIndexes)
        }
        let built = try buildWanted(deviceIndexes: deviceIndexes, rebuilding: rebuilding, logger: logger, transaction: transaction)
        return (RecordLogIndexSync(created: built.created, dropped: dropped), built.members > 0)
    }

    /// Why the store skips a synced db3's entry placed `.server` (#5241).
    static let skipServerOnly = "placed on the server only; this device builds nothing for it"

    /// Why the store skips an entry on `id` alone (#5241).
    static let skipIdOnly = "the primary key serves id; no index of its own is built"

    /// Why the store builds nothing for `entry` (#5241, js-bao's `judgeEntry`),
    /// one rule after another, or `nil` when it caches it: a synced db3's entry
    /// placed `.server`; a model or field that is not an identifier, or no
    /// field (warned about); a vector entry over other than one field; a text
    /// entry whose options do not parse (warned about); an entry on `id` alone;
    /// a member entry over other than one field.
    private static func skipReason(_ entry: RecordLogIndexEntry, localOnly: Bool, documentId: String, logger: Logger?) -> String? {
        // A synced db3's store builds the entries placed on devices (#5220, #5223).
        if !localOnly && entry.on == .server { return skipServerOnly }
        if let refusal = unusable(entry) {
            logger?.warn("[record-log] \(documentId): index '\(entry.name)' skipped: \(refusal); queries on it scan.")
            return refusal
        }
        switch entry.kind {
        case .vector:
            return entry.fields.count == 1 ? nil : "a vector index covers one field"
        case .text:
            do {
                _ = try entry.textOptions()
                return nil
            } catch {
                logger?.warn("[record-log] \(documentId): text index '\(entry.name)' skipped: \(Self.message(error)).")
                return Self.message(error)
            }
        case .members, .scalar:
            if entry.fields == ["id"] { return skipIdOnly }
            if entry.kind == .members && entry.fields.count != 1 { return "a member index covers one field" }
            return nil
        }
    }

    /// Replace `documentId`'s cached rows with `entries`, and its skipped
    /// entries with those ``skipReason(_:localOnly:documentId:logger:)``
    /// skips (#5241), in the caller's transaction.
    private static func replace(_ sql: RecordLogSql, documentId: String, _ entries: [RecordLogIndexEntry], logger: Logger?) throws {
        let localOnly = try sql.first("SELECT local_only FROM record_log_state WHERE doc_id = ?", [.text(documentId)])?["local_only"].intValue == 1
        // What each entry's row held before: its table (kept while the device holds it) and why it was not built.
        var previous: [String: (members: String?, text: String?, vector: String?, unbuilt: String?, options: [String: JSONValue])] = [:]
        for row in try sql.rows(
            "SELECT model, fields, kind, members, text, vector, options FROM record_log_indexes WHERE doc_id = ?", [.text(documentId)]
        ) {
            let options = optionsOf(row)
            previous[identity(row["model"].stringValue ?? "", row["fields"].stringValue ?? "", row["kind"].stringValue ?? "")] = (
                row["members"].stringValue, row["text"].stringValue, row["vector"].stringValue, options["unbuilt"]?.stringValue, options
            )
        }
        try sql.exec("DELETE FROM record_log_indexes WHERE doc_id = ?", [.text(documentId)])
        try sql.exec("DELETE FROM record_log_index_skips WHERE doc_id = ?", [.text(documentId)])
        for entry in entries {
            if let reason = skipReason(entry, localOnly: localOnly, documentId: documentId, logger: logger) {
                try sql.exec(
                    #"INSERT INTO record_log_index_skips (doc_id, room_name, model, fields, kind, "on", reason) VALUES (?, ?, ?, ?, ?, ?, ?)"#,
                    [.text(documentId), .text(entry.name), .text(entry.model), .text(RecordLogJSON.text(.array(entry.fields.map { .string($0) }))),
                     .text(entry.kind.rawValue), .text(entry.on.rawValue), .text(reason)]
                )
                continue
            }
            let fieldsText = RecordLogJSON.text(.array(entry.fields.map { .string($0) }))
            let fields = Format2SqlValue.text(fieldsText)
            let before = previous[identity(entry.model, fieldsText, entry.kind.rawValue)]
            switch entry.kind {
            case .vector:
                // The listing's facts, replaced; the device's state, kept (#5230).
                let vector = RecordLogVectorOptions(cached: entry.vector)
                var cached: [String: JSONValue] = ["on": .string(entry.on.rawValue)]
                if let vector { cached["vector"] = vector.json }
                if let generation = entry.generation { cached["generation"] = .number(Double(generation)) }
                if let revision = entry.revision { cached["revision"] = .number(Double(revision)) }
                if let annModel = entry.annModel { cached["annModel"] = annModel }
                for key in vectorDeviceState { if let held = before?.options[key] { cached[key] = held } }
                if vector == nil { cached["unbuilt"] = .string(RecordLogVectorOptions.unbuiltReason(entry.vector)) }
                try sql.exec(
                    """
                    INSERT INTO record_log_indexes (doc_id, model, fields, kind, is_unique, room_name, vector, options) VALUES (?, ?, ?, 'vector', 0, ?, ?, ?)
                      ON CONFLICT (doc_id, model, fields, kind) DO UPDATE SET \
                    room_name = excluded.room_name, vector = excluded.vector, options = excluded.options
                    """,
                    [.text(documentId), .text(entry.model), fields, .text(entry.name), before?.vector.map { .text($0) } ?? .null,
                     .text(RecordLogJSON.text(.object(cached)))]
                )
            case .text:
                // Its options parse: an entry whose do not was skipped above.
                guard var options = try? entry.textOptions() else { continue }
                options.on = entry.on
                options.unbuilt = before?.unbuilt
                try sql.exec(
                    """
                    INSERT INTO record_log_indexes (doc_id, model, fields, kind, is_unique, room_name, text, options) VALUES (?, ?, ?, 'text', 0, ?, ?, ?)
                      ON CONFLICT (doc_id, model, fields, kind) DO UPDATE SET \
                    room_name = excluded.room_name, text = excluded.text, options = excluded.options
                    """,
                    [.text(documentId), .text(entry.model), fields, .text(entry.name), before?.text.map { .text($0) } ?? .null,
                     .text(RecordLogJSON.text(options.json))]
                )
            case .members:
                try sql.exec(
                    """
                    INSERT INTO record_log_indexes (doc_id, model, fields, kind, is_unique, room_name, members, options) VALUES (?, ?, ?, 'members', 0, ?, ?, ?)
                      ON CONFLICT (doc_id, model, fields, kind) DO UPDATE SET \
                    room_name = excluded.room_name, members = excluded.members, is_unique = 0, options = excluded.options
                    """,
                    [.text(documentId), .text(entry.model), fields, .text(entry.name), before?.members.map { .text($0) } ?? .null,
                     entryOptions(on: entry.on == .both ? nil : entry.on, unbuilt: before?.unbuilt)]
                )
            case .scalar:
                try sql.exec(
                    """
                    INSERT INTO record_log_indexes (doc_id, model, fields, kind, is_unique, room_name, options) VALUES (?, ?, ?, 'scalar', ?, ?, ?)
                      ON CONFLICT (doc_id, model, fields, kind) DO UPDATE SET \
                    is_unique = MAX(is_unique, excluded.is_unique), room_name = excluded.room_name, options = excluded.options
                    """,
                    [.text(documentId), .text(entry.model), fields, .integer(entry.unique ? 1 : 0), .text(entry.name),
                     entryOptions(on: entry.on == .both ? nil : entry.on, unbuilt: before?.unbuilt)]
                )
            }
        }
    }

    /// An error as its SQLite message, as js-bao's `error.message` reads it.
    static func message(_ error: Error) -> String {
        switch error {
        case Format2SqlError.prepareFailed(_, let message), Format2SqlError.executionFailed(_, let message): return message
        case let error as JsBaoError: return error.message
        default: return error.localizedDescription
        }
    }

    /// Every cached scalar `(model, fields)`, with whether any list marks it unique.
    private static func cached(_ sql: RecordLogSql) throws -> [(model: String, fields: [String], unique: Bool)] {
        try sql.rows(
            "SELECT model, fields, MAX(is_unique) AS is_unique FROM record_log_indexes WHERE kind = 'scalar' GROUP BY model, fields"
        ).map { row in (row["model"].stringValue ?? "", fieldsOf(row), row["is_unique"].intValue == 1) }
    }

    /// The store's view-index definitions held, each with its index's name.
    static func heldDefinitions(_ sql: RecordLogSql) throws -> [String: String] {
        var held: [String: String] = [:]
        for row in try sql.rows("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name") {
            let indexName = row["name"].stringValue ?? ""
            let table = row["tbl_name"].stringValue ?? ""
            guard family.contains(where: { $0.table == table && indexName.hasPrefix($0.prefix) }),
                  let found = row["sql"].stringValue.flatMap(definition(inSql:)), held[found] == nil
            else { continue }
            held[found] = indexName
        }
        return held
    }

    /// One scalar definition the cached rows want: its view index and, for a unique one, its rows index.
    private struct WantedScalar {
        var model: String
        var fields: [String]
        var indexes: [(table: String, definition: String, canonical: String)]
        /// Some row wants it built (not merely kept when built).
        var build: Bool
    }

    /// Every scalar definition the cached rows want (#5322): a row to build
    /// wants its definition built; a row the default leaves out wants it kept
    /// only when its view index is held; a declined row wants nothing.
    private static func wantedScalars(_ sql: RecordLogSql, _ deviceIndexes: Db3DeviceIndexes, held: [String: String]) throws -> RecordLogOrderedMap<String, WantedScalar> {
        var out = RecordLogOrderedMap<String, WantedScalar>()
        for row in try cachedRows(sql, "WHERE i.kind = 'scalar'") {
            let disposition = disposition(row, deviceIndexes)
            if disposition == .decline { continue }
            let model = row["model"].stringValue ?? ""
            let fields = fieldsOf(row)
            let view = definition("record_log_view", model, fields)
            if disposition == .keep && held[view] == nil { continue }
            var wanted = out[view] ?? WantedScalar(model: model, fields: fields, indexes: [("record_log_view", view, name("view", model, fields))], build: false)
            if disposition == .build { wanted.build = true }
            if row["is_unique"].intValue == 1 && fields.count == 1 && wanted.indexes.count == 1 {
                wanted.indexes.append(("record_log_rows", definition("record_log_rows", model, fields), name("rows", model, fields)))
            }
            out[view] = wanted
        }
        return out
    }

    /// Whether a member table and its three triggers are held.
    private static func memberTableHeld(_ tables: Set<String>, _ triggers: Set<String>, _ table: String) -> Bool {
        tables.contains(table) && memberTriggerSuffixes.allSatisfy { triggers.contains("\(table)\($0)") }
    }

    /// The drop half of a reconcile (#5322), in the cache's transaction: every
    /// index, member table and text table (with its triggers) no cached row
    /// wants is dropped, and a row whose table is not held as wanted, or whose
    /// entry is declined, has its pointer cleared. Answers how many were
    /// dropped (a table dropped to be rebuilt is not counted), and the name of
    /// each table dropped to be rebuilt, by its row's ``rebuildKey(_:_:)``, so
    /// the rebuild keeps it.
    private static func dropUnwanted(
        _ sql: RecordLogSql, _ deviceIndexes: Db3DeviceIndexes
    ) throws -> (dropped: Int, rebuilding: [String: String]) {
        var dropped = 0
        var wanted = Set<String>()
        for scalar in try wantedScalars(sql, deviceIndexes, held: heldDefinitions(sql)).entries.map(\.1) {
            for index in scalar.indexes { wanted.insert(index.definition) }
        }
        var kept = Set<String>()
        for row in try sql.rows("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name") {
            let indexName = row["name"].stringValue ?? ""
            let table = row["tbl_name"].stringValue ?? ""
            guard family.contains(where: { $0.table == table && indexName.hasPrefix($0.prefix) }) else { continue }
            if let found = row["sql"].stringValue.flatMap(definition(inSql:)), wanted.contains(found), kept.insert(found).inserted { continue }
            try sql.connection.executeScript("DROP INDEX IF EXISTS \(quoted(indexName))")
            dropped += 1
        }
        // Members: a pointer stands only for a table held with its triggers, of an entry not declined.
        let memberTables = Set(try familyNames(sql, "table"))
        let memberTriggers = Set(try familyNames(sql, "trigger"))
        var named = Set<String>()
        var rebuilt = Set<String>()
        var rebuilding: [String: String] = [:]
        for row in try cachedRows(sql, "WHERE i.kind = 'members' AND i.members IS NOT NULL") {
            guard let table = row["members"].stringValue else { continue }
            let declined = disposition(row, deviceIndexes) == .decline
            if !declined && memberTableHeld(memberTables, memberTriggers, table) && named.insert(table).inserted { continue }
            if !declined {
                rebuilt.insert(table)
                rebuilding[rebuildKey(row, memberKey(row["model"].stringValue ?? "", fieldsOf(row).first ?? ""))] = table
            }
            try sql.exec(
                "UPDATE record_log_indexes SET members = NULL WHERE doc_id = ? AND model = ? AND fields = ? AND kind = 'members'",
                [row["doc_id"], row["model"], row["fields"]]
            )
        }
        for trigger in memberTriggers.sorted() {
            let table = trigger.replacingOccurrences(of: #"__[iud]$"#, with: "", options: .regularExpression)
            if !named.contains(table) { try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(quotedName(trigger))") }
        }
        for table in memberTables.sorted() where !named.contains(table) {
            try dropMemberTable(sql, table)
            if !rebuilt.contains(table) { dropped += 1 }
        }
        // Text: a pointer stands only for a table held as its definition asks, with its three triggers.
        var tables: [String: String] = [:]
        for row in try sql.rows(
            #"SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\' AND sql LIKE 'CREATE VIRTUAL TABLE%'"#
        ) {
            if let name = row["name"].stringValue { tables[name] = row["sql"].stringValue ?? "" }
        }
        var triggers: [String: String] = [:]
        for row in try sql.rows(#"SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\'"#) {
            if let name = row["name"].stringValue { triggers[name] = row["sql"].stringValue ?? "" }
        }
        var texts = Set<String>()
        for row in try cachedRows(sql, "WHERE i.kind = 'text' AND i.text IS NOT NULL") {
            guard let table = row["text"].stringValue, let wanted = wantedText(row) else { continue }
            let bodies = textTriggersDDL(table, wanted)
            let held = tables[table] == textTableDDL(table, wanted) && zip(textTriggerSuffixes, bodies).allSatisfy { triggers["\(table)\($0)"] == $1 }
            let declined = disposition(row, deviceIndexes) == .decline
            if !declined && held && texts.insert(table).inserted {
                if wanted.options.unbuilt != nil { try markUnbuilt(sql, wanted, nil) }
                continue
            }
            if !declined {
                rebuilt.insert(table)
                rebuilding[rebuildKey(row, textKey(wanted.model))] = table
            }
            try sql.exec(
                "UPDATE record_log_indexes SET text = NULL WHERE doc_id = ? AND model = ? AND fields = ? AND kind = 'text'",
                [row["doc_id"], row["model"], row["fields"]]
            )
        }
        for trigger in triggers.keys.sorted() {
            let table = trigger.replacingOccurrences(of: #"__[iud]$"#, with: "", options: .regularExpression)
            if !texts.contains(table) { try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(quotedName(trigger))") }
        }
        for table in tables.keys.sorted() where !texts.contains(table) {
            try dropTextTable(sql, table)
            if !rebuilt.contains(table) { dropped += 1 }
        }
        dropped += try dropUnwantedVectors(sql, deviceIndexes)
        return (dropped, rebuilding)
    }

    /// The key a cached row's table dropped to be rebuilt is found under: its db3 and ``memberKey(_:_:)`` or ``textKey(_:)``.
    private static func rebuildKey(_ row: Format2SqlRow, _ key: String) -> String {
        "\(row["doc_id"].stringValue ?? "")\u{0}\(key)"
    }

    /// What a query needing an unbuilt index of each kind does.
    private static func consequence(_ kind: String) -> String {
        switch kind {
        case "members": return "membership queries on its field scan, every query answers."
        case "text": return "$search on it is refused, every other query answers."
        case "vector": return "$near on it is refused, every other query answers."
        default: return "queries on its fields scan, every query answers."
        }
    }

    /// Log that a build failed: a warning when the reason is new, at debug while it stays (#5322).
    static func reportUnbuilt(_ row: Format2SqlRow, kind: String, reason: String, logger: Logger?) {
        let line = "[record-log] \(row["doc_id"].stringValue ?? ""): \(kind) index \(row["room_name"].stringValue ?? "") on "
            + "\(row["model"].stringValue ?? "") is not built: \(reason); \(consequence(kind))"
        if optionsOf(row)["unbuilt"]?.stringValue == reason { logger?.debug(line) } else { logger?.warn(line) }
    }

    /// Set (or, with `nil`, clear) the unbuilt mark on `row`'s options, whatever its kind.
    private static func setUnbuilt(_ sql: RecordLogSql, _ row: Format2SqlRow, _ reason: String?) throws {
        var options = optionsOf(row)
        options["unbuilt"] = reason.map { .string($0) }
        if reason == nil { options.removeValue(forKey: "unbuilt") }
        let kind = row["kind"].stringValue ?? "scalar"
        try sql.exec(
            "UPDATE record_log_indexes SET options = ? WHERE doc_id = ? AND model = ? AND fields = ? AND kind = ?",
            [kind == "text" || !options.isEmpty ? .text(RecordLogJSON.text(.object(options))) : .null, row["doc_id"], row["model"], row["fields"], row["kind"]]
        )
    }

    /// One build the cached rows want, as ``buildWanted(deviceIndexes:rebuilding:logger:transaction:)`` runs it.
    private enum Build {
        case scalar(WantedScalar)
        case members(Format2SqlRow)
        case text(Format2SqlRow)
        case vector(Format2SqlRow)
    }

    /// The build half of a reconcile (#5322): each index to build that the
    /// store does not hold, in a transaction of its own; a failure recorded on
    /// its rows in a small transaction after, and the next build goes on.
    private static func buildWanted(
        deviceIndexes: Db3DeviceIndexes, rebuilding: [String: String], logger: Logger?, transaction: ((RecordLogSql) throws -> Void) throws -> Void
    ) throws -> (created: Int, members: Int) {
        var builds: [Build] = []
        var held: [String: String] = [:]
        var taken = Set<String>()
        try transaction { sql in
            held = try heldDefinitions(sql)
            taken = Set(try sql.rows("SELECT name FROM sqlite_master WHERE type = 'index'").compactMap { $0["name"].stringValue })
            for scalar in try wantedScalars(sql, deviceIndexes, held: held).entries.map(\.1) { builds.append(.scalar(scalar)) }
            for row in try cachedRows(sql, "WHERE i.kind = 'members' AND i.members IS NULL") where disposition(row, deviceIndexes) == .build {
                builds.append(.members(row))
            }
            for row in try cachedRows(sql, "WHERE i.kind = 'text' AND i.text IS NULL") where disposition(row, deviceIndexes) == .build {
                builds.append(.text(row))
            }
            for row in try cachedRows(sql, "WHERE i.kind = 'vector' AND i.vector IS NULL") where disposition(row, deviceIndexes) == .build {
                builds.append(.vector(row))
            }
        }
        var created = 0
        var members = 0
        for build in builds {
            switch build {
            case .scalar(let scalar):
                let rows = { (sql: RecordLogSql) throws -> [Format2SqlRow] in
                    try cachedRows(sql, "WHERE i.kind = 'scalar' AND i.model = ? AND i.fields = ?", [
                        .text(scalar.model), .text(RecordLogJSON.text(.array(scalar.fields.map { .string($0) }))),
                    ]).filter { disposition($0, deviceIndexes) == .build }
                }
                let missing = scalar.indexes.filter { held[$0.definition] == nil }
                if missing.isEmpty || !scalar.build {
                    try transaction { sql in for row in try rows(sql) where optionsOf(row)["unbuilt"] != nil { try setUnbuilt(sql, row, nil) } }
                    continue
                }
                var names: [String] = []
                do {
                    try transaction { sql in
                        names = []
                        for index in missing {
                            var indexName = index.canonical
                            var n = 2
                            while taken.contains(indexName) {
                                indexName = "\(index.canonical)_\(n)"
                                n += 1
                            }
                            try sql.connection.executeScript("CREATE INDEX \(quoted(indexName)) ON \(index.definition)")
                            names.append(indexName)
                        }
                        for row in try rows(sql) where optionsOf(row)["unbuilt"] != nil { try setUnbuilt(sql, row, nil) }
                    }
                    for indexName in names { taken.insert(indexName) }
                    created += names.count
                } catch {
                    let reason = "the index could not be built: \(message(error))"
                    record(reason: reason, kind: "scalar", logger: logger, transaction: transaction, rows: rows)
                }
            case .members(let row):
                let documentId = row["doc_id"].stringValue ?? ""
                let model = row["model"].stringValue ?? ""
                let field = fieldsOf(row).first ?? ""
                do {
                    try transaction { sql in
                        let key = memberKey(model, field)
                        let table = try deviceTable(
                            sql, key: key, canonical: memberTableName(documentId: documentId, model: model, field: field),
                            previous: rebuilding[rebuildKey(row, key)].map { [key: $0] } ?? [:]
                        )
                        try sql.connection.executeScript(
                            "CREATE TABLE \(quotedName(table)) (value TEXT NOT NULL, rid INTEGER NOT NULL, PRIMARY KEY (value, rid)) WITHOUT ROWID"
                        )
                        try sql.exec(
                            """
                            INSERT OR IGNORE INTO \(quotedName(table)) (value, rid)
                              SELECT m.value, v.rowid FROM record_log_view v, json_each(v._data, ?) m
                               WHERE v.doc_id = ? AND v._type = ? AND json_type(v._data, ?) = 'array' AND m.type = 'text'
                            """,
                            [.text("$.\(field)"), .text(documentId), .text(model), .text("$.\(field)")]
                        )
                        for statement in memberTriggersDDL(table, documentId: documentId, model: model, field: field) {
                            try sql.connection.executeScript(statement)
                        }
                        let on = optionsOf(row)["on"]?.stringValue.flatMap(Db3IndexPlacement.init(rawValue:))
                        try sql.exec(
                            "UPDATE record_log_indexes SET members = ?, options = ? WHERE doc_id = ? AND model = ? AND fields = ? AND kind = 'members'",
                            [.text(table), entryOptions(on: on, unbuilt: nil), row["doc_id"], row["model"], row["fields"]]
                        )
                    }
                    created += 1
                    members += 1
                } catch {
                    let reason = "the member index could not be built: \(message(error))"
                    record(reason: reason, kind: "members", logger: logger, transaction: transaction, rows: { _ in [row] })
                }
            case .text(let row):
                guard let wanted = wantedText(row) else { continue }
                // Placed on the server only, a synced db3's text entry has no table.
                if wanted.options.on == .server && row["local_only"].intValue != 1 { continue }
                let started = Date()
                do {
                    try transaction { sql in
                        let key = textKey(wanted.model)
                        let table = try deviceTable(
                            sql, key: key, canonical: textTableName(documentId: wanted.documentId, model: wanted.model),
                            previous: rebuilding[rebuildKey(row, key)].map { [key: $0] } ?? [:]
                        )
                        try sql.connection.executeScript(textTableDDL(table, wanted))
                        try sql.exec(
                            """
                            INSERT INTO \(quotedName(table)) (rowid, \(wanted.fields.indices.map(textColumn).joined(separator: ", ")))
                              SELECT v.rowid, \(textValues("v", wanted.fields).joined(separator: ", ")) FROM record_log_view v WHERE v.doc_id = ? AND v._type = ?
                            """,
                            [.text(wanted.documentId), .text(wanted.model)]
                        )
                        for statement in textTriggersDDL(table, wanted) { try sql.connection.executeScript(statement) }
                        var options = wanted.options
                        options.unbuilt = nil
                        try sql.exec(
                            "UPDATE record_log_indexes SET text = ?, options = ? WHERE doc_id = ? AND model = ? AND fields = ? AND kind = 'text'",
                            [.text(table), .text(RecordLogJSON.text(options.json)), row["doc_id"], row["model"], row["fields"]]
                        )
                        let count = try sql.first(
                            "SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = ? AND _type = ?", [.text(wanted.documentId), .text(wanted.model)]
                        )?["n"].intValue ?? 0
                        let ms = Date().timeIntervalSince(started) * 1000
                        logger?.log(
                            "[record-log] \(wanted.documentId): text index \(wanted.roomName) on \(wanted.model) built from \(count) rows in \(String(format: "%.1f", ms)) ms."
                        )
                    }
                    created += 1
                } catch {
                    let reason = "the text index could not be built: \(message(error))"
                    record(reason: reason, kind: "text", logger: logger, transaction: transaction, rows: { _ in [row] })
                }
            case .vector(let row):
                if try buildVector(row, logger: logger, transaction: transaction) { created += 1 }
            }
        }
        return (created, members)
    }

    /// Write `reason` as why the rows' entry is not built, in a transaction of its own; a store that cannot even write that says so.
    static func record(
        reason: String, kind: String, logger: Logger?, transaction: ((RecordLogSql) throws -> Void) throws -> Void,
        rows: (RecordLogSql) throws -> [Format2SqlRow]
    ) {
        do {
            try withoutActuallyEscaping(rows) { rows in
                try transaction { sql in
                    for row in try rows(sql) {
                        reportUnbuilt(row, kind: kind, reason: reason, logger: logger)
                        try setUnbuilt(sql, row, reason)
                    }
                }
            }
        } catch {
            logger?.warn("[record-log] why a \(kind) index is not built could not be recorded: \(message(error))")
        }
    }

    /// The store's view indexes as the room lists its own: `(model, fields,
    /// unique)`, read from `sqlite_master` with `unique` from the cached lists,
    /// sorted by model, then fields.
    static func tuples(_ sql: RecordLogSql) throws -> [RecordLogIndexTuple] {
        var unique: [String: Bool] = [:]
        for (model, fields, isUnique) in try cached(sql) {
            unique[definition("record_log_view", model, fields)] = isUnique
        }
        var tuples: [RecordLogIndexTuple] = []
        let rows = try sql.rows(
            #"SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'record_log_view' AND name LIKE 'idx\_record\_log\_view\_%' ESCAPE '\'"#
        )
        for row in rows {
            guard let found = row["sql"].stringValue.flatMap(definition(inSql:)),
                  let model = firstMatch(#"WHERE _type = '((?:[^']|'')*)'$"#, in: found)?.replacingOccurrences(of: "''", with: "'")
            else { continue }
            let fields = allMatches(#"json_extract\(_data, '\$\.([A-Za-z_][A-Za-z0-9_]*)'\)"#, in: found)
            tuples.append(RecordLogIndexTuple(model: model, fields: fields, unique: unique[found] ?? false))
        }
        let key = { (tuple: RecordLogIndexTuple) in
            Array(RecordLogJSON.text(.array([.string(tuple.model), .array(tuple.fields.map { .string($0) })])).utf8)
        }
        return tuples.sorted { key($0).lexicographicallyPrecedes(key($1)) }
    }

    private static func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    /// The first capture group of every match of `pattern` in `text`.
    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }
}

// MARK: - Member indexes (#5156)

extension RecordLogIndexes {

    /// The suffixes of a member table's three triggers on the view: insert, update of `_data`, delete.
    private static let memberTriggerSuffixes = ["__i", "__u", "__d"]

    private static func quotedName(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// The canonical name of the table a member index on `model.field` is
    /// kept in on this device:
    /// `idx_record_log_members_<len>_<doc id>_<len>_<model>_<len>_<field>`,
    /// names lowercased. js-bao's `recordLogMemberTableName`.
    static func memberTableName(documentId: String, model: String, field: String) -> String {
        let part = { (name: String) in "\(name.utf16.count)_\(name.lowercased())" }
        return ["idx_record_log_members", part(documentId), part(model), part(field)].joined(separator: "_")
    }

    /// The key a member entry's previous table is found under.
    static func memberKey(_ model: String, _ field: String) -> String { "members\u{0}\(model)\u{0}\(field)" }

    /// The key a text entry's previous table is found under: one text index per model.
    static func textKey(_ model: String) -> String { "text\u{0}\(model)" }

    /// The table a device entry of `documentId` is kept in: the one its cached
    /// row named before (`previous`, keyed by `key`), else `canonical`, `_<n>`
    /// while a schema object or another cached row holds it, compared without
    /// case. js-bao's `deviceTableFor`.
    static func deviceTable(
        _ sql: RecordLogSql, key: String, canonical: String, previous: [String: String]
    ) throws -> String {
        if let held = previous[key] { return held }
        func taken(_ name: String) throws -> Bool {
            try sql.first("SELECT 1 AS hit FROM sqlite_master WHERE name = ? COLLATE NOCASE", [.text(name)]) != nil
                || sql.first(
                    "SELECT 1 AS hit FROM record_log_indexes WHERE members = ? COLLATE NOCASE OR text = ? COLLATE NOCASE OR vector = ? COLLATE NOCASE",
                    [.text(name), .text(name), .text(name)]
                ) != nil
                || previous.values.contains { $0.lowercased() == name.lowercased() }
        }
        if try !taken(canonical) { return canonical }
        var n = 2
        while try taken("\(canonical)_\(n)") { n += 1 }
        return "\(canonical)_\(n)"
    }

    private static func familyNames(_ sql: RecordLogSql, _ type: String) throws -> [String] {
        try sql.rows(
            #"SELECT name FROM sqlite_master WHERE type = ? AND name LIKE 'idx\_record\_log\_members\_%' ESCAPE '\'"#, [.text(type)]
        ).compactMap { $0["name"].stringValue }
    }

    /// The statements that create a member table's triggers on the view, each
    /// scoped to its db3 and model. Every statement on the table seeks its
    /// `(value, rid)` key: a removal names each member the old row held, never
    /// the rowid alone. An insertion adds only the members the table does not
    /// hold, since a trigger's `OR IGNORE` gives way to the conflict handling
    /// of the statement that fired it. Only a string member of an array is a
    /// member, as `$contains` on the record's own array finds no other.
    private static func memberTriggersDDL(_ table: String, documentId: String, model: String, field: String) -> [String] {
        let t = quotedName(table)
        let path = RecordLogSchema.quoteLiteral("$.\(field)")
        let scope = { (row: String) in
            "\(row).doc_id = \(RecordLogSchema.quoteLiteral(documentId)) AND \(row)._type = \(RecordLogSchema.quoteLiteral(model))"
        }
        let members = { (row: String) in
            "SELECT value FROM json_each(CASE WHEN json_type(\(row)._data, \(path)) = 'array' THEN \(row)._data END, \(path)) WHERE type = 'text'"
        }
        let insertNew = "INSERT INTO \(t) (value, rid) SELECT DISTINCT m.value, NEW.rowid FROM (\(members("NEW"))) AS m"
            + " WHERE NOT EXISTS (SELECT 1 FROM \(t) AS held WHERE held.value = m.value AND held.rid = NEW.rowid)"
        return [
            "CREATE TRIGGER \(quotedName("\(table)__i")) AFTER INSERT ON record_log_view WHEN \(scope("NEW"))\nBEGIN\n  \(insertNew);\nEND",
            "CREATE TRIGGER \(quotedName("\(table)__u")) AFTER UPDATE OF _data ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n"
                + "  DELETE FROM \(t) WHERE rid = OLD.rowid AND value IN (\(members("OLD")) EXCEPT \(members("NEW")));\n"
                + "  \(insertNew);\nEND",
            "CREATE TRIGGER \(quotedName("\(table)__d")) AFTER DELETE ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n"
                + "  DELETE FROM \(t) WHERE rid = OLD.rowid AND value IN (\(members("OLD")));\nEND",
        ]
    }

    /// Drop a member table and its triggers.
    private static func dropMemberTable(_ sql: RecordLogSql, _ table: String) throws {
        for suffix in memberTriggerSuffixes { try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(quotedName("\(table)\(suffix)"))") }
        try sql.connection.executeScript("DROP TABLE IF EXISTS \(quotedName(table))")
    }

    /// Drop `documentId`'s device tables, member, text and vector, and their
    /// triggers (#5156, #5223, #5230), before a purge deletes its view rows
    /// and cached rows. A store whose cache has no `members` column holds no
    /// member table; one with no `text` column no text table; one with no
    /// `vector` column no vector table.
    static func dropDeviceTables(_ sql: RecordLogSql, documentId: String) throws {
        let columns = Set(try sql.rows("SELECT name FROM pragma_table_info('record_log_indexes')").compactMap { $0["name"].stringValue })
        if columns.contains("members") {
            for row in try sql.rows("SELECT members FROM record_log_indexes WHERE doc_id = ? AND members IS NOT NULL", [.text(documentId)]) {
                if let table = row["members"].stringValue { try dropMemberTable(sql, table) }
            }
        }
        if columns.contains("text") {
            for row in try sql.rows("SELECT text FROM record_log_indexes WHERE doc_id = ? AND text IS NOT NULL", [.text(documentId)]) {
                if let table = row["text"].stringValue { try dropTextTable(sql, table) }
            }
        }
        if columns.contains("vector") {
            for row in try sql.rows("SELECT vector FROM record_log_indexes WHERE doc_id = ? AND vector IS NOT NULL", [.text(documentId)]) {
                if let table = row["vector"].stringValue { try dropVectorTables(sql, table) }
            }
        }
    }

    /// The table a member index on `model.field` is kept in on this device,
    /// as `documentId`'s cached row names it, or `nil` when it has none.
    static func memberTable(_ sql: RecordLogSql, documentId: String, model: String, field: String) throws -> String? {
        try sql.first(
            "SELECT members FROM record_log_indexes WHERE doc_id = ? AND model = ? AND fields = ? AND members IS NOT NULL",
            [.text(documentId), .text(model), .text(RecordLogJSON.text(.array([.string(field)])))]
        )?["members"].stringValue
    }

    /// The `record_log_meta` key of the view's highest rowid when the store last gathered statistics.
    static let statisticsRowidMeta = "statistics_rowid"

    /// The fewest view rows a store holding a member table gathers statistics at by growth, as the room's (#5150).
    static let growthStatisticsMinRows = 1000

    /// How many times its rowid mark the view must grow to before statistics are due again, as the room's (#5150).
    static let growthStatisticsFactor = 10

    private static func highestViewRowid(_ sql: RecordLogSql) throws -> Int {
        try sql.first("SELECT MAX(rowid) AS n FROM record_log_view")?["n"].intValue ?? 0
    }

    /// Whether the view holds a row: an `ANALYZE` of an empty table writes no statistics.
    static func populated(_ sql: RecordLogSql) throws -> Bool {
        try sql.first("SELECT 1 AS present FROM record_log_view LIMIT 1") != nil
    }

    /// Whether statistics are due by growth: in a store holding a member table,
    /// once the view's highest rowid is at least ``growthStatisticsMinRows``
    /// and at least ``growthStatisticsFactor`` times the mark. A store with no
    /// member table reads one row of its cache.
    static func statisticsDue(_ sql: RecordLogSql) throws -> Bool {
        guard try sql.first("SELECT 1 AS present FROM record_log_indexes WHERE members IS NOT NULL LIMIT 1") != nil else { return false }
        let marked = try sql.first("SELECT value FROM record_log_meta WHERE key = ?", [.text(statisticsRowidMeta)])?["value"].intValue ?? 0
        return try highestViewRowid(sql) >= max(growthStatisticsMinRows, growthStatisticsFactor * marked)
    }

    /// Gather SQLite's statistics for the view and every member table the
    /// store holds, and write the view's highest rowid to `record_log_meta` as
    /// the mark growth is measured from (the room's `runAnalyze`). Without
    /// them the planner weighs the view's `(doc_id, _type, _id)` key against a
    /// member table's rowid probe blind. A store holding no member table
    /// gathers nothing. Never throws: a refusal is logged, undone, and the
    /// index stands. Run in a command of its own, never inside a save.
    @discardableResult
    static func gatherStatistics(_ sql: RecordLogSql, logger: Logger?) -> Bool {
        do {
            let held = Set(try familyNames(sql, "table"))
            let tables = try sql.rows("SELECT DISTINCT members FROM record_log_indexes WHERE members IS NOT NULL ORDER BY members")
                .compactMap { $0["members"].stringValue }
                .filter { held.contains($0) }
            guard !tables.isEmpty else { return false }
            try sql.connection.executeScript("SAVEPOINT record_log_statistics")
            do {
                try sql.connection.executeScript("ANALYZE record_log_view")
                for table in tables { try sql.connection.executeScript("ANALYZE \(quotedName(table))") }
                try sql.exec(
                    "INSERT INTO record_log_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                    [.text(statisticsRowidMeta), .text(String(try highestViewRowid(sql)))]
                )
                try sql.connection.executeScript("RELEASE record_log_statistics")
            } catch {
                try? sql.connection.executeScript("ROLLBACK TO record_log_statistics")
                try? sql.connection.executeScript("RELEASE record_log_statistics")
                throw error
            }
            return true
        } catch {
            logger?.warn("[record-log] statistics for the member indexes were not gathered: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Text indexes (#5223)

/// A db3's text index on a model as a read uses it (#5223): its table when
/// built, and what its refusal names when not. js-bao's `RecordLogTextIndexOf`.
struct RecordLogTextIndexOf: Equatable, Sendable {
    /// The FTS5 table, or `nil` when the store holds none for it.
    var table: String?
    var fields: [String]
    var options: RecordLogTextIndexOptions
    /// The room's name for the index, which a refusal names.
    var roomName: String = ""
    /// Why this device does not build it (#5322): declined here, or left out by the `deviceIndexes` default with nothing built.
    var declined: String? = nil
}

extension RecordLogIndexes {

    /// The suffixes of a text index's three triggers on the view: insert, update of `_data`, delete.
    private static let textTriggerSuffixes = ["__i", "__u", "__d"]

    /// The canonical name of the FTS5 table a db3's text index on `model` is
    /// kept in: `idx_record_log_text_<len>_<doc id>_<len>_<model>`, names
    /// lowercased. js-bao's `recordLogTextTableName`.
    static func textTableName(documentId: String, model: String) -> String {
        let part = { (name: String) in "\(name.utf16.count)_\(name.lowercased())" }
        return ["idx_record_log_text", part(documentId), part(model)].joined(separator: "_")
    }

    /// The FTS5 column a text index keeps its `index`-th field in: `f<index>`.
    static func textColumn(_ index: Int) -> String { "f\(index)" }

    /// A text index a cached row names: its db3, model, fields and options.
    fileprivate struct WantedText {
        var documentId: String
        var model: String
        var fields: [String]
        var roomName: String
        var options: RecordLogTextIndexOptions
    }

    /// A text index's table, js-bao's `textTableDDL` (#5224): contentless,
    /// one column per field named by its alias, its tokenizer and prefix
    /// lengths. Rows leave it only through FTS5's `'delete'` command with the
    /// values they were indexed with (``textDeleteSQL(_:_:)``), which keeps
    /// the totals `bm25` reads exact, so a table kept through any writes
    /// ranks as one built fresh over the same rows. The exact text is what
    /// `sqlite_master` keeps, so a held table is matched by it.
    private static func textTableDDL(_ table: String, _ wanted: WantedText) -> String {
        let columns = wanted.fields.indices.map(textColumn)
        let prefix = wanted.options.prefix.isEmpty ? "" : ", prefix='\(wanted.options.prefix.map(String.init).joined(separator: " "))'"
        return "CREATE VIRTUAL TABLE \(quotedName(table)) USING fts5(\(columns.joined(separator: ", ")), content='',"
            + " tokenize='\(wanted.options.tokenizer.tokenize)'\(prefix))"
    }

    /// Each covered field of `row` as its column's value: the string it holds, or NULL for any other value or none.
    private static func textValues(_ row: String, _ fields: [String]) -> [String] {
        fields.map { field in
            let path = RecordLogSchema.quoteLiteral("$.\(field)")
            return "CASE WHEN json_type(\(row)._data, \(path)) = 'text' THEN json_extract(\(row)._data, \(path)) END"
        }
    }

    /// `INSERT INTO <table> (<table>, rowid, f0, …)`: what a statement
    /// removing a row starts with, followed by `VALUES ('delete', <rowid>,
    /// <values>)`, the values exactly those the row was indexed with.
    /// js-bao's `textDeleteSql`.
    private static func textDeleteSQL(_ table: String, _ fields: [String]) -> String {
        "INSERT INTO \(quotedName(table)) (\(([quotedName(table), "rowid"] + fields.indices.map(textColumn)).joined(separator: ", ")))"
    }

    /// The statements that create a text index's triggers on the view, each
    /// scoped to its db3 and model: an insertion indexes the row's values, an
    /// update of `_data` removes the old row's values through FTS5's
    /// `'delete'` command and indexes the new, a deletion removes the row's
    /// the same way (#5224), so the totals `bm25` reads stay those of the
    /// view's rows. js-bao's `textTriggersDDL`, text for text.
    private static func textTriggersDDL(_ table: String, _ wanted: WantedText) -> [String] {
        let t = quotedName(table)
        let columns = (["rowid"] + wanted.fields.indices.map(textColumn)).joined(separator: ", ")
        let scope = { (row: String) in
            "\(row).doc_id = \(RecordLogSchema.quoteLiteral(wanted.documentId)) AND \(row)._type = \(RecordLogSchema.quoteLiteral(wanted.model))"
        }
        let insertNew = "INSERT INTO \(t) (\(columns)) VALUES (NEW.rowid, \(textValues("NEW", wanted.fields).joined(separator: ", ")))"
        let deleteOld = "\(textDeleteSQL(table, wanted.fields)) VALUES ('delete', OLD.rowid, \(textValues("OLD", wanted.fields).joined(separator: ", ")))"
        return [
            "CREATE TRIGGER \(quotedName("\(table)__i")) AFTER INSERT ON record_log_view WHEN \(scope("NEW"))\nBEGIN\n  \(insertNew);\nEND",
            "CREATE TRIGGER \(quotedName("\(table)__u")) AFTER UPDATE OF _data ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n"
                + "  \(deleteOld);\n  \(insertNew);\nEND",
            "CREATE TRIGGER \(quotedName("\(table)__d")) AFTER DELETE ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n"
                + "  \(deleteOld);\nEND",
        ]
    }

    /// Drop a text index's table and its triggers.
    static func dropTextTable(_ sql: RecordLogSql, _ table: String) throws {
        for suffix in textTriggerSuffixes { try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(quotedName("\(table)\(suffix)"))") }
        try sql.connection.executeScript("DROP TABLE IF EXISTS \(quotedName(table))")
    }

    /// A text entry's wanted table as its cached row names it, or `nil` when its options are not readable.
    fileprivate static func wantedText(_ row: Format2SqlRow) -> WantedText? {
        guard let options = RecordLogTextIndexOptions(cached: row["options"].stringValue.flatMap(RecordLogJSON.parse)) else { return nil }
        return WantedText(
            documentId: row["doc_id"].stringValue ?? "", model: row["model"].stringValue ?? "", fields: fieldsOf(row),
            roomName: row["room_name"].stringValue ?? "", options: options
        )
    }

    /// Mark a text entry's cached row with why its table is not built, or clear the mark.
    private static func markUnbuilt(_ sql: RecordLogSql, _ wanted: WantedText, _ unbuilt: String?) throws {
        var options = wanted.options
        options.unbuilt = unbuilt
        try sql.exec(
            "UPDATE record_log_indexes SET options = ? WHERE doc_id = ? AND model = ? AND fields = ? AND kind = 'text'",
            [.text(RecordLogJSON.text(options.json)), .text(wanted.documentId), .text(wanted.model),
             .text(RecordLogJSON.text(.array(wanted.fields.map { .string($0) })))]
        )
    }

    /// `documentId`'s text index on `model`, as its cached row names it, with
    /// this device's verdict on it read in the same statement, or `nil` when
    /// the cache holds none (#5223, #5322). Its `table` is `nil` when the store
    /// holds no table for it (unbuilt, declined, or its table gone); `declined`
    /// says why this device does not build it, when it does not.
    static func textIndex(
        _ sql: RecordLogSql, documentId: String, model: String, deviceIndexes: Db3DeviceIndexes = .all
    ) throws -> RecordLogTextIndexOf? {
        guard let row = try cachedRows(sql, "WHERE i.doc_id = ? AND i.model = ? AND i.kind = 'text'", [.text(documentId), .text(model)]).first,
              let options = RecordLogTextIndexOptions(cached: row["options"].stringValue.flatMap(RecordLogJSON.parse))
        else { return nil }
        let table = row["text"].stringValue
        let held = try table.map { table in
            try options.unbuilt == nil && sql.first("SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) != nil
        } ?? false
        let declined: String?
        switch disposition(row, deviceIndexes) {
        case .decline: declined = declinedHere
        case .keep where !held: declined = excludedByOption(.text)
        default: declined = nil
        }
        return RecordLogTextIndexOf(
            table: held ? table : nil, fields: fieldsOf(row), options: options, roomName: row["room_name"].stringValue ?? "", declined: declined
        )
    }
}

// MARK: - The device's policy (#5322)

extension Db3DeviceIndexes {
    /// Whether this default leaves `kind` out of what the client builds.
    func excludes(_ kind: Db3IndexKind) -> Bool {
        switch self {
        case .all: return false
        case .none: return true
        case .kinds(let kinds): return !kinds.contains(kind)
        }
    }
}

extension RecordLogIndexes {

    /// Why a declined index is not built (#5322).
    static let declinedHere = "declined on this device"

    /// Why an index the client's `deviceIndexes` default leaves out is not built (#5322).
    static func excludedByOption(_ kind: Db3IndexKind) -> String { "the client's deviceIndexes option excludes \(kind.rawValue)" }

    /// Where a cached row's index lives: a local-only db3's are on the device;
    /// the rest's placement is in its options, left out when it is `both`. A
    /// synced db3 caches no entry placed `.server`, so a row naming none is on
    /// both, whatever its kind.
    private static func placement(_ row: Format2SqlRow) -> Db3IndexPlacement {
        if row["local_only"].intValue == 1 { return .device }
        return optionsOf(row)["on"]?.stringValue.flatMap(Db3IndexPlacement.init(rawValue:)) ?? .both
    }

    /// What the store holds of the device families, for ``status(_:_:held:)``.
    private struct Held {
        var definitions: [String: String]
        var memberTables: Set<String>
        var memberTriggers: Set<String>
        var texts: Set<String>
        /// A flat table with its triggers, and each ANN table beside one (#5230).
        var vectors: Set<String>
    }

    private static func held(_ sql: RecordLogSql) throws -> Held {
        let triggers = Set(try sql.rows(#"SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\'"#)
            .compactMap { $0["name"].stringValue })
        let texts = try sql.rows(
            #"SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'idx\_record\_log\_text\_%' ESCAPE '\' AND sql LIKE 'CREATE VIRTUAL TABLE%'"#
        ).compactMap { $0["name"].stringValue }.filter { table in textTriggerSuffixes.allSatisfy { triggers.contains("\(table)\($0)") } }
        let vectorTriggers = Set(try vectorTriggers(sql).keys)
        let vectors = try vectorTables(sql).filter { table in
            triggerSuffixesOfVectors.allSatisfy { vectorTriggers.contains("\(table)\($0)") }
                || (table.hasSuffix("_ann") && triggerSuffixesOfVectors.allSatisfy { vectorTriggers.contains("\(table.dropLast(4))\($0)") })
        }
        return Held(
            definitions: try heldDefinitions(sql), memberTables: Set(try familyNames(sql, "table")),
            memberTriggers: Set(try familyNames(sql, "trigger")), texts: Set(texts), vectors: vectors
        )
    }

    /// How `row`'s index stands on this device, given what the store holds.
    private static func status(_ row: Format2SqlRow, _ deviceIndexes: Db3DeviceIndexes, held: Held) -> Db3LocalIndex {
        let kind = row["kind"].stringValue.flatMap(Db3IndexKind.init(rawValue:)) ?? .scalar
        let model = row["model"].stringValue ?? ""
        let fields = fieldsOf(row)
        let make = { (status: Db3LocalIndexStatus, reason: String?, mode: Db3LocalIndexMode?) in
            Db3LocalIndex(
                name: row["room_name"].stringValue ?? "", model: model, fields: fields, kind: kind, on: placement(row), status: status, reason: reason,
                mode: mode
            )
        }
        let disposition = disposition(row, deviceIndexes)
        if disposition == .decline { return make(.declined, declinedHere, nil) }
        let unbuilt = optionsOf(row)["unbuilt"]?.stringValue
        let built: Bool
        switch kind {
        case .scalar: built = held.definitions[definition("record_log_view", model, fields)] != nil
        case .members: built = row["members"].stringValue.map { memberTableHeld(held.memberTables, held.memberTriggers, $0) } ?? false
        case .text: built = unbuilt == nil && (row["text"].stringValue.map { held.texts.contains($0) } ?? false)
        case .vector: built = unbuilt == nil && (row["vector"].stringValue.map { held.vectors.contains($0) } ?? false)
        }
        if built, kind == .vector, let flat = row["vector"].stringValue {
            // How it answers `$near` now (#5230): from its ANN table once a model's fill finished.
            let options = optionsOf(row)
            let installed = options["ann"] != nil && held.vectors.contains(RecordLogVectorIndex.annTable(flat))
            if installed && options["fill"] != nil { return make(.building, nil, .exact) }
            return make(.built, nil, installed ? .ann : .exact)
        }
        if built { return make(.built, nil, nil) }
        if disposition == .keep { return make(.declined, excludedByOption(kind), nil) }
        return make(.unbuilt, unbuilt ?? "it is not built on this device yet", nil)
    }

    /// Each index `documentId`'s room places on this device, by name, with how
    /// it stands here (#5322, js-bao's `recordLogIndexStatuses`): `declined`
    /// (declined on this device, or left out by the `deviceIndexes` default and
    /// not built), `built`, or `unbuilt` with why. An entry placed on the
    /// server only is not cached, so not listed; a local-only db3's are all
    /// listed, never `declined`. A vector index is `.building` while a model's
    /// ANN table is being filled, and names its `mode` (#5230): `.exact` until
    /// a fill finished, then `.ann`. Every other build runs within the list's
    /// reconcile.
    static func statuses(_ sql: RecordLogSql, documentId: String, deviceIndexes: Db3DeviceIndexes) throws -> [Db3LocalIndex] {
        let held = try held(sql)
        return try cachedRows(sql, "WHERE i.doc_id = ?", [.text(documentId)])
            .filter { placement($0) != .server }
            .map { status($0, deviceIndexes, held: held) }
            .sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
    }

    /// Each entry of `documentId`'s room's list the copy skipped when it last
    /// applied it (#5241, js-bao's `recordLogIndexSkips`), sorted by name:
    /// what ``statuses(_:documentId:deviceIndexes:)`` does not list.
    static func skips(_ sql: RecordLogSql, documentId: String) throws -> [Db3SkippedIndex] {
        try sql.rows(
            #"SELECT room_name, model, fields, kind, "on" AS placement, reason FROM record_log_index_skips WHERE doc_id = ? ORDER BY room_name, rowid"#,
            [.text(documentId)]
        ).map { row in
            Db3SkippedIndex(
                name: row["room_name"].stringValue ?? "", model: row["model"].stringValue ?? "", fields: fieldsOf(row),
                kind: row["kind"].stringValue.flatMap(Db3IndexKind.init(rawValue:)) ?? .scalar,
                on: row["placement"].stringValue.flatMap(Db3IndexPlacement.init(rawValue:)) ?? .both,
                reason: row["reason"].stringValue ?? ""
            )
        }
    }

    /// The cached row `name` names in `documentId`'s list, refused when it is
    /// not one this device can decline or accept: no such index
    /// `.db3IndexNotFound` (`details.index`), a db3 that lives only here
    /// `.db3LocalOnly` (its indexes are registered and dropped on the device).
    private static func placedRow(_ sql: RecordLogSql, documentId: String, name: String) throws -> Format2SqlRow {
        guard let row = try cachedRows(sql, "WHERE i.doc_id = ? AND i.room_name = ?", [.text(documentId), .text(name)]).first else {
            throw JsBaoError(
                code: .db3IndexNotFound,
                message: "\(documentId) has no index named \(name) placed on this device: client.db3.indexes.local(db3Id) lists the indexes placed here",
                details: ["index": .string(name)]
            )
        }
        if row["local_only"].intValue == 1 {
            throw JsBaoError(
                code: .db3LocalOnly,
                message: "\(documentId) lives only on this device, whose indexes are its own: drop \(name) with client.db3.indexes.drop(db3Id, name:) rather than declining it",
                details: ["index": .string(name)]
            )
        }
        return row
    }

    /// The index `documentId`'s cached list names `name` (#5241), with how it
    /// stands here and the device object a statement reads it through (the
    /// view index of a scalar entry, the table of a member entry, when built),
    /// or `nil` when the cache holds none of that name.
    static func namedIndex(
        _ sql: RecordLogSql, documentId: String, name: String, deviceIndexes: Db3DeviceIndexes
    ) throws -> (status: Db3LocalIndex, object: String?)? {
        guard let row = try cachedRows(sql, "WHERE i.doc_id = ? AND i.room_name = ?", [.text(documentId), .text(name)]).first else { return nil }
        let held = try held(sql)
        let status = status(row, deviceIndexes, held: held)
        guard status.status == .built else { return (status, nil) }
        switch status.kind {
        case .scalar: return (status, held.definitions[definition("record_log_view", status.model, status.fields)])
        case .members: return (status, row["members"].stringValue)
        case .text, .vector: return (status, nil)
        }
    }

    /// Every device object `documentId`'s cached list names, each with the
    /// registry name this db3 gives it (#5241): a view index by the definition
    /// a scalar row wants (one physical index may serve several db3s, each
    /// naming it its own way), a member, text or vector table (and a vector
    /// index's ANN table) by the row that points at it.
    static func registryNames(_ sql: RecordLogSql, documentId: String) throws -> [String: String] {
        let held = try heldDefinitions(sql)
        var names: [String: String] = [:]
        for row in try cachedRows(sql, "WHERE i.doc_id = ?", [.text(documentId)]) {
            let name = row["room_name"].stringValue ?? ""
            if row["kind"].stringValue == "scalar", let object = held[definition("record_log_view", row["model"].stringValue ?? "", fieldsOf(row))] {
                names[object] = name
            }
            for column in ["members", "text", "vector"] {
                guard let table = row[column].stringValue else { continue }
                names[table] = name
                if column == "vector" { names[RecordLogVectorIndex.annTable(table)] = name }
            }
        }
        return names
    }

    /// The model the entry `documentId`'s list (cached or skipped) names `name` is on, or `nil` (#5241).
    static func registryModel(_ sql: RecordLogSql, documentId: String, name: String) throws -> String? {
        try sql.first(
            "SELECT model FROM record_log_indexes WHERE doc_id = ? AND room_name = ? UNION ALL SELECT model FROM record_log_index_skips WHERE doc_id = ? AND room_name = ?",
            [.text(documentId), .text(name), .text(documentId), .text(name)]
        )?["model"].stringValue
    }

    /// The status of `name` in `documentId`'s list.
    static func status(_ sql: RecordLogSql, documentId: String, name: String, deviceIndexes: Db3DeviceIndexes) throws -> Db3LocalIndex {
        status(try placedRow(sql, documentId: documentId, name: name), deviceIndexes, held: try held(sql))
    }

    /// The verdict this device holds for `name` (`declined`, `accepted` or none),
    /// refused as ``placedRow(_:documentId:name:)`` refuses.
    static func verdict(_ sql: RecordLogSql, documentId: String, name: String) throws -> String? {
        try placedRow(sql, documentId: documentId, name: name)["verdict"].stringValue
    }

    /// Write `verdict` for `name`'s index identity in the device's policy.
    static func writeVerdict(_ sql: RecordLogSql, documentId: String, name: String, verdict: String) throws {
        let row = try placedRow(sql, documentId: documentId, name: name)
        try sql.exec(
            """
            INSERT INTO record_log_index_policy (doc_id, model, fields, kind, verdict, at) VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT (doc_id, model, fields, kind) DO UPDATE SET verdict = excluded.verdict, at = excluded.at
            """,
            [row["doc_id"], row["model"], row["fields"], row["kind"], .text(verdict), .integer(Int64(Date().timeIntervalSince1970 * 1000))]
        )
    }
}
