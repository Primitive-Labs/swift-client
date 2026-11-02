import Foundation

/// One index of a db3's list, as the room answers `GET db3/:id/indexes`.
struct RecordLogIndexEntry: Equatable, Sendable {
    /// The room's name for it; the store names its own index its own way.
    var name: String
    var model: String
    var fields: [String]
    var unique: Bool
    /// A string-set field's member index: a table of the room's own that the
    /// store has no counterpart for, so it caches and builds nothing.
    var members: Bool

    init(name: String, model: String, fields: [String], unique: Bool, members: Bool = false) {
        self.name = name
        self.model = model
        self.fields = fields
        self.unique = unique
        self.members = members
    }

    /// One entry of the room's `indexes` array, or `nil` when it names no model or fields.
    init?(json: JSONValue) {
        guard let model = json["model"]?.stringValue, let fields = json["fields"]?.arrayValue else { return nil }
        self.init(
            name: json["name"]?.stringValue ?? "", model: model, fields: fields.compactMap(\.stringValue),
            unique: json["unique"]?.boolValue ?? false, members: json["members"]?.boolValue ?? false
        )
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

    /// Replace `documentId`'s cached list with `entries`, then reconcile the
    /// store's indexes; with no list, reconcile from what is cached (a db3
    /// opened offline keeps its indexes). An entry whose model or field is not
    /// an identifier is skipped with a warning; one on `id` alone needs no index
    /// of its own; a member index is skipped, the view's `$contains` reading
    /// each record's own array. The caller runs it as one transaction.
    static func sync(
        _ sql: RecordLogSql, documentId: String, _ entries: [RecordLogIndexEntry]?, logger: Logger?
    ) throws -> RecordLogIndexSync {
        if let entries {
            try sql.exec("DELETE FROM record_log_indexes WHERE doc_id = ?", [.text(documentId)])
            for entry in entries {
                if entry.members { continue }
                if let refusal = unusable(entry) {
                    logger?.warn("[record-log] \(documentId): index '\(entry.name)' skipped: \(refusal); queries on it scan.")
                    continue
                }
                if entry.fields == ["id"] { continue }
                try sql.exec(
                    """
                    INSERT INTO record_log_indexes (doc_id, model, fields, is_unique, room_name) VALUES (?, ?, ?, ?, ?)
                      ON CONFLICT (doc_id, model, fields) DO UPDATE SET \
                    is_unique = MAX(is_unique, excluded.is_unique), room_name = excluded.room_name
                    """,
                    [
                        .text(documentId), .text(entry.model), .text(RecordLogJSON.text(.array(entry.fields.map { .string($0) }))),
                        .integer(entry.unique ? 1 : 0), .text(entry.name),
                    ]
                )
            }
        }
        return try reconcile(sql)
    }

    /// Every cached `(model, fields)` with whether any list marks it unique.
    private static func cached(_ sql: RecordLogSql) throws -> [(model: String, fields: [String], unique: Bool)] {
        try sql.rows("SELECT model, fields, MAX(is_unique) AS is_unique FROM record_log_indexes GROUP BY model, fields").map { row in
            let fields = (row["fields"].stringValue.flatMap(RecordLogJSON.parse)?.arrayValue ?? []).compactMap(\.stringValue)
            return (row["model"].stringValue ?? "", fields, row["is_unique"].intValue == 1)
        }
    }

    /// Make the store's family of indexes the set the cached lists want.
    private static func reconcile(_ sql: RecordLogSql) throws -> RecordLogIndexSync {
        var wanted: [(table: String, definition: String, canonical: String)] = []
        var wantedDefinitions = Set<String>()
        for (model, fields, unique) in try cached(sql) {
            let view = definition("record_log_view", model, fields)
            if wantedDefinitions.insert(view).inserted {
                wanted.append(("record_log_view", view, name("view", model, fields)))
            }
            if unique && fields.count == 1 {
                let rows = definition("record_log_rows", model, fields)
                if wantedDefinitions.insert(rows).inserted {
                    wanted.append(("record_log_rows", rows, name("rows", model, fields)))
                }
            }
        }
        var held = Set<String>()
        var taken = Set<String>()
        var dropped = 0
        for row in try sql.rows("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL") {
            let indexName = row["name"].stringValue ?? ""
            let table = row["tbl_name"].stringValue ?? ""
            taken.insert(indexName)
            guard family.contains(where: { $0.table == table && indexName.hasPrefix($0.prefix) }) else { continue }
            if let found = row["sql"].stringValue.flatMap(definition(inSql:)), wantedDefinitions.contains(found),
               held.insert(found).inserted {
                continue
            }
            try sql.connection.executeScript("DROP INDEX IF EXISTS \(quoted(indexName))")
            taken.remove(indexName)
            dropped += 1
        }
        var created = 0
        for index in wanted where !held.contains(index.definition) {
            var indexName = index.canonical
            var n = 2
            while taken.contains(indexName) {
                indexName = "\(index.canonical)_\(n)"
                n += 1
            }
            try sql.connection.executeScript("CREATE INDEX \(quoted(indexName)) ON \(index.definition)")
            taken.insert(indexName)
            created += 1
        }
        return RecordLogIndexSync(created: created, dropped: dropped)
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
