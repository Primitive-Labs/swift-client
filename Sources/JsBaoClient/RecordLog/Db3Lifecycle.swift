import Foundation

// A client's db3s on this device: which are resident (their store bound and
// holding a readable copy) and which are subscribed (this client holds a
// `Db3Subscription`, so the db3 is open on the socket and kept up to date by
// its room). A port of js-bao's `src/client/internal/db3Lifecycle.ts`, rule
// for rule.
//
// The first subscription of a db3 opens it on the socket; the last one's
// dispose closes it there and leaves the store bound, so the db3 still
// answers queries and takes writes, which the next subscription sends.
//
// The state of a db3 (`Db3State`) is read from its store and its session: the
// store's marks and stored state for residency, the cursor, the rows and the
// unjudged writes; the session's status for the phase and progress; the
// socket for `reconnecting`. It is read again whenever any of them may have
// changed, and `Db3StateEvent` is emitted only when the snapshot changed.

/// What the lifecycle reads of a bound db3's store marks.
struct Db3SyncMarks: Sendable, Equatable {
    var cursor: Int
    var permission: String?
    var lastCatchUpAt: Int64?
    var replacing: Bool
    var staged: Bool
    /// The db3 was created on this device and bound before its room's copy loaded.
    var createdLocally = false

    /// js-bao's `isRecordLogResident`: created here, or a load completed and
    /// no unstaged replacement is in progress.
    var resident: Bool {
        if createdLocally { return true }
        guard lastCatchUpAt != nil else { return false }
        return !replacing || staged
    }
}

/// What a purge of a db3's store answered.
struct Db3PurgeOutcome: Sendable, Equatable {
    var purged: Bool
}

/// What the lifecycle needs of its client: js-bao's `Db3LifecycleDeps`. Every
/// member has a default, so a test names only what its world answers.
struct Db3LifecycleDeps: Sendable {
    /// Emit one of the client's `db3:*` events.
    var emit: @Sendable (any JsBaoEventPayload) -> Void = { _ in }
    /// Whether the socket is open and the client may use the network.
    var socketUp: @Sendable () -> Bool = { false }
    /// Whether the client was destroyed.
    var destroyed: @Sendable () -> Bool = { false }
    /// The document's format as this client knows or can learn it now; `nil` when it cannot.
    var resolveFormat: @Sendable (String) async -> Int? = { _ in nil }
    /// Why this client's storage cannot hold a db3, or `nil` when it can.
    var storageRefusal: @Sendable (String) async -> JsBaoError? = { _ in nil }
    /// Open the db3 on the socket for its subscriptions: bind its store, register it, start its sync.
    var open: @Sendable (String) async throws -> Void = { _ in }
    /// Close the db3 on the socket (the room stops its updates); its store stays bound.
    var close: @Sendable (String) async throws -> Void = { _ in }
    /// Bind a stored db3's store without subscribing to it.
    var bind: @Sendable (String) async throws -> Void = { _ in }
    /// Ask the room again for a db3 open here whose session is idle.
    var resync: @Sendable (String) -> Void = { _ in }
    /// Unbind a db3's store.
    var unbind: @Sendable (String) async -> Void = { _ in }
    /// Whether the client has the db3 open (registered with its document manager).
    var isOpen: @Sendable (String) -> Bool = { _ in false }
    /// The db3s created on this device and not yet committed to the server.
    var pendingCreates: @Sendable () -> [String] = { [] }
    /// Whether the db3 was created on this device and not yet committed.
    var isPendingCreate: @Sendable (String) -> Bool = { _ in false }
    /// Why the server refused committing a db3 created on this device (#4921), or `nil`.
    var createRefusal: @Sendable (String) -> Db3StateError? = { _ in nil }
    /// The last permission the client learned for the document, in `Db3State`'s names.
    var knownPermission: @Sendable (String) -> Db3Permission? = { _ in nil }
    /// Remove the db3's metadata and local persistence once its store was purged.
    var forget: @Sendable (String) async -> Void = { _ in }
    /// Set the client's retention policy.
    var setRetentionPolicy: @Sendable (RetentionPolicy) -> Void = { _ in }
    /// Whether the db3's store is bound here.
    var isBound: @Sendable (String) -> Bool = { _ in false }
    /// The bound db3's store marks, read now; `nil` when it is not bound.
    var syncMarks: @Sendable (String) -> Db3SyncMarks? = { _ in nil }
    /// What the store holds of the db3, bound or not; `nil` when it holds nothing.
    var storedState: @Sendable (String) async throws -> RecordLogStoredState? = { _ in nil }
    /// Every db3 the store holds a state for.
    var storedIds: @Sendable () async throws -> [String] = { [] }
    /// Purge the db3's store; `force` drops writes the room has not judged.
    var purge: @Sendable (String, Bool) async -> Db3PurgeOutcome = { _, _ in Db3PurgeOutcome(purged: true) }
    /// Unbind every db3.
    var unbindAll: @Sendable () async -> Void = {}
    var logger: Logger?
}

extension Db3State {
    /// This state with its subscription, phase and progress replaced.
    func with(subscribed: Bool? = nil, phase: Db3Phase? = nil, progress: Db3Progress?? = nil) -> Db3State {
        Db3State(
            id: id, resident: resident, subscribed: subscribed ?? self.subscribed, phase: phase ?? self.phase,
            progress: progress ?? self.progress, cursor: cursor, rows: rows, lastSyncAt: lastSyncAt,
            pendingWrites: pendingWrites, permission: permission, error: error, pendingCreate: pendingCreate
        )
    }
}

/// The client's db3 lifecycle; `client.db3`'s members are its surface.
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// `lock`, which is never held across a call out of this class (a dep, a
/// handle's settlement or a listener).
final class Db3Lifecycle: @unchecked Sendable {

    /// How long `ready()` waits without progress when no `readyTimeout` is given.
    static let defaultReadyTimeout: TimeInterval = 30

    /// A subscription and what settles it. `@unchecked Sendable`: its timer
    /// fields are read and written under the lifecycle's `lock`.
    private final class Handle: @unchecked Sendable {
        let subscription: Db3Subscription
        let timeout: TimeInterval
        var timer: Task<Void, Never>?
        var timerGeneration = 0
        /// `ready()` was claimed by `settleReady`: it fires once.
        var readyClaimed = false

        init(subscription: Db3Subscription, timeout: TimeInterval) {
            self.subscription = subscription
            self.timeout = timeout
        }
    }

    private struct Chain {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// Whether another read is owed. `@unchecked Sendable`: `again` is read
    /// and written under the lifecycle's `lock`.
    private final class ReadMark: @unchecked Sendable {
        var again = false
    }

    private let deps: Db3LifecycleDeps
    private let lock = NSLock()
    private var handles: [String: [Handle]] = [:]
    /// The db3s open on the socket for their subscriptions.
    private var active: Set<String> = []
    /// Each db3's start and stop, one after another.
    private var chains: [String: Chain] = [:]
    /// The last state emitted for each db3.
    private var last: [String: Db3State] = [:]
    /// A db3's last failed open, cleared once it is live.
    private var errors: [String: Db3StateError] = [:]
    /// Each db3's session status, as the session last reported it.
    private var statuses: [String: RecordLogSessionStatus] = [:]
    /// Reads of a db3's state in progress, and whether another is owed after.
    private var reading: [String: ReadMark] = [:]
    /// The db3s a document door (`documents.open`, `openDocument`) holds open:
    /// the last subscription's dispose leaves them open on the socket.
    private var doorHeld: Set<String> = []
    /// The db3s whose room refused this client since their refusal was last
    /// lifted: a `gone` read from a mark the store kept from before (another
    /// launch, another sign-in) is told, but rejects no subscription until
    /// the room answers it.
    private var roomRefused: Set<String> = []
    /// The db3s whose room refused this client's wire version: gone for the client's lifetime.
    private var outdated: Set<String> = []
    /// The db3s whose room refused them because their sync is off (#4806):
    /// when such a db3 turns gone, it is for that reason. Cleared once it is
    /// live, or refused for access instead.
    private var syncOff: Set<String> = []
    /// Removals of a db3's store in progress: a second door joins the first.
    private var removals: [String: Task<Void, Error>] = [:]
    /// Bumped when the user changes: a binding of the stored db3s started
    /// before it is undone when it finishes.
    private var identity = 0
    private var destroyedFlag = false

    init(deps: Db3LifecycleDeps) {
        self.deps = deps
    }

    // MARK: - The surface

    func subscribe(_ db3Id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) throws -> Db3Subscription {
        if lock.withLock({ destroyedFlag }) || deps.destroyed() {
            throw JsBaoError(
                code: .db3Disposed, message: "client.db3.subscribe('\(db3Id)'): the client was destroyed",
                details: ["db3Id": .string(db3Id)]
            )
        }
        guard !db3Id.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "client.db3.subscribe: a db3 id is a non-empty string")
        }
        let subscription = Db3Subscription(id: db3Id, owner: self)
        let handle = Handle(subscription: subscription, timeout: options.readyTimeout)
        lock.withLock { handles[db3Id, default: []].append(handle) }
        let state = provisional(db3Id)
        let live = state.phase == .live && isActive(db3Id)
        if live {
            Task { [weak self] in self?.settleReady(handle) }
        } else {
            if isResidentNow(db3Id) { subscription.resolveAvailable() }
            if handle.timeout <= 0 {
                Task { [weak self] in
                    guard let self, self.isAttached(handle), !subscription.readySettled else { return }
                    self.timedOut(handle)
                }
            } else {
                arm(handle)
            }
        }
        // A db3 already open here whose session stopped (the room refused it,
        // or an open attempt ended) is asked of the room again by a new subscribe.
        if isActive(db3Id), statusFor(db3Id).phase == .idle, deps.socketUp() { deps.resync(db3Id) }
        reconcile(db3Id)
        kick(db3Id)
        return subscription
    }

    func unsubscribe(_ db3Id: String) {
        for handle in lock.withLock({ handles[db3Id] ?? [] }) { handle.subscription.dispose() }
    }

    func refresh(_ db3Id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) async throws -> Db3State {
        let subscription = try subscribe(db3Id, options: options)
        do {
            try await subscription.ready()
        } catch {
            subscription.dispose()
            throw error
        }
        subscription.dispose()
        await settled(db3Id)
        return try await state(db3Id)
    }

    func evict(_ db3Id: String, options: Db3EvictOptions = Db3EvictOptions()) async throws {
        let bound = deps.isBound(db3Id)
        let stored = try await deps.storedState(db3Id)
        guard bound || stored != nil || deps.isPendingCreate(db3Id) else { return }
        let pending = stored?.writers.reduce(0) { $0 + $1.pending } ?? 0
        if pending > 0 && !options.force {
            throw JsBaoError(
                code: .db3PendingWrites,
                message: "client.db3.evict('\(db3Id)'): it holds \(pending) write(s) the room has not judged; "
                    + "pass Db3EvictOptions(force: true) to drop them",
                details: ["db3Id": .string(db3Id), "pendingWrites": .number(Double(pending))]
            )
        }
        try await removeStore(db3Id, force: options.force, reason: .explicit)
    }

    /// Remove a db3's store: its subscriptions are disposed (each hears
    /// `evicted`), it is closed on the socket and unbound here, then purged.
    /// One removal of a db3 at a time: a second joins the first.
    func removeStore(_ db3Id: String, force: Bool, reason: Db3EvictedEvent.Reason) async throws {
        let (task, started) = lock.withLock { () -> (Task<Void, Error>, Bool) in
            if let running = removals[db3Id] { return (running, false) }
            let task = Task { [weak self] in
                guard let self else { return }
                try await self.removeStoreOnce(db3Id, force: force, reason: reason)
            }
            removals[db3Id] = task
            return (task, true)
        }
        defer {
            if started { lock.withLock { removals[db3Id] = nil } }
        }
        try await task.value
    }

    private func removeStoreOnce(_ db3Id: String, force: Bool, reason: Db3EvictedEvent.Reason) async throws {
        let event = Db3EvictedEvent(id: db3Id, reason: reason)
        // The eviction ends a door's open of it too.
        lock.withLock { _ = doorHeld.remove(db3Id) }
        for handle in handlesOf(db3Id) {
            handle.subscription.deliver(.evicted(event))
            handle.subscription.reject(JsBaoError(
                code: .db3Disposed, message: "the db3 '\(db3Id)' was evicted", details: ["db3Id": .string(db3Id)]
            ))
            releaseHandle(handle, reconcile: false)
        }
        reconcile(db3Id)
        await settled(db3Id)
        // Open through a document door only: closed on the socket here, so the
        // room stops counting this client and no member keeps the closed binding.
        if deps.isOpen(db3Id) {
            do {
                try await deps.close(db3Id)
            } catch {
                deps.logger?.warn("[db3] \(db3Id): closing it on the socket failed:", error.localizedDescription)
            }
        }
        let wasBound = deps.isBound(db3Id)
        if wasBound { await deps.unbind(db3Id) }
        let outcome = await deps.purge(db3Id, force)
        guard outcome.purged else {
            if wasBound { try? await deps.bind(db3Id) }
            await refreshState(db3Id)
            throw JsBaoError(
                code: .db3PendingWrites,
                message: "client.db3.evict('\(db3Id)'): it holds writes the room has not judged",
                details: ["db3Id": .string(db3Id)]
            )
        }
        await deps.forget(db3Id)
        lock.withLock {
            last[db3Id] = nil
            errors[db3Id] = nil
            roomRefused.remove(db3Id)
            syncOff.remove(db3Id)
        }
        deps.emit(event)
        await refreshState(db3Id)
    }

    /// The retention policy's door for a db3: removed unforced, so one holding
    /// writes the room has not judged, or one subscribed here, is kept (and the
    /// skip logged). Answers whether it was removed.
    func retentionEvict(_ db3Id: String) async -> Bool {
        if lock.withLock({ removals[db3Id] != nil }) { return false }
        if isSubscribed(db3Id) {
            deps.logger?.debug("[db3] \(db3Id): kept by the retention policy: it is subscribed")
            return false
        }
        let pending = ((try? await deps.storedState(db3Id)) ?? nil)?.writers.reduce(0) { $0 + $1.pending } ?? 0
        if pending > 0 {
            deps.logger?.warn("[db3] \(db3Id): kept by the retention policy: \(pending) write(s) the room has not judged")
            return false
        }
        do {
            try await removeStore(db3Id, force: false, reason: .retention)
            return true
        } catch {
            deps.logger?.warn("[db3] \(db3Id): the retention policy could not remove it:", error.localizedDescription)
            return false
        }
    }

    func stored() async throws -> [Db3StoredEntry] {
        var ids = Set(try await deps.storedIds())
        ids.formUnion(deps.pendingCreates())
        var out: [Db3StoredEntry] = []
        for id in ids {
            let state = try await read(id)
            out.append(Db3StoredEntry(
                id: id, rows: state.rows, cursor: state.cursor, pendingWrites: state.pendingWrites,
                lastSyncAt: state.lastSyncAt, resident: state.resident
            ))
        }
        return out.sorted { $0.id < $1.id }
    }

    func state(_ db3Id: String) async throws -> Db3State {
        try await read(db3Id)
    }

    func setRetentionPolicy(_ policy: RetentionPolicy) {
        deps.setRetentionPolicy(policy)
    }

    // MARK: - Subscriptions

    /// The db3's latest state, as the lifecycle last read it.
    func current(_ db3Id: String) -> Db3State {
        let known = lock.withLock { () -> (Db3State, Bool)? in
            guard let state = last[db3Id] else { return nil }
            return (state, !(handles[db3Id] ?? []).isEmpty)
        }
        guard let (state, subscribed) = known else { return provisional(db3Id) }
        return state.subscribed == subscribed ? state : state.with(subscribed: subscribed)
    }

    /// The subscription was disposed.
    func release(_ subscription: Db3Subscription) {
        guard let handle = handle(of: subscription) else { return }
        subscription.reject(JsBaoError(
            code: .db3Disposed, message: "the subscription to '\(subscription.id)' was disposed",
            details: ["db3Id": .string(subscription.id)]
        ))
        releaseHandle(handle, reconcile: true)
    }

    private func handle(of subscription: Db3Subscription) -> Handle? {
        lock.withLock { handles[subscription.id]?.first { $0.subscription === subscription } }
    }

    private func isAttached(_ handle: Handle) -> Bool {
        lock.withLock { handles[handle.subscription.id]?.contains { $0 === handle } ?? false }
    }

    private func isActive(_ db3Id: String) -> Bool { lock.withLock { active.contains(db3Id) } }

    /// Whether this client holds a subscription to the db3.
    func isSubscribed(_ db3Id: String) -> Bool { lock.withLock { !(handles[db3Id] ?? []).isEmpty } }

    private func handlesOf(_ db3Id: String) -> [Handle] { lock.withLock { handles[db3Id] ?? [] } }

    private func releaseHandle(_ handle: Handle, reconcile again: Bool) {
        let db3Id = handle.subscription.id
        lock.withLock {
            handle.timer?.cancel()
            handle.timer = nil
            handle.timerGeneration += 1
            handles[db3Id]?.removeAll { $0 === handle }
            if handles[db3Id]?.isEmpty == true { handles[db3Id] = nil }
        }
        if again {
            reconcile(db3Id)
            kick(db3Id)
        }
    }

    /// (Re)start the wait of a handle's `ready()`.
    private func arm(_ handle: Handle) {
        let settled = handle.subscription.readySettled
        lock.withLock {
            handle.timer?.cancel()
            handle.timer = nil
            handle.timerGeneration += 1
            guard handle.timeout.isFinite, handle.timeout > 0, !settled else { return }
            let generation = handle.timerGeneration
            let nanoseconds = UInt64(handle.timeout * 1_000_000_000)
            handle.timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self else { return }
                let current = self.lock.withLock { () -> Bool in
                    guard handle.timerGeneration == generation else { return false }
                    handle.timer = nil
                    return true
                }
                if current { self.timedOut(handle) }
            }
        }
    }

    private func timedOut(_ handle: Handle) {
        guard !handle.subscription.readySettled else { return }
        let db3Id = handle.subscription.id
        let ms = Int((handle.timeout * 1000).rounded())
        handle.subscription.reject(JsBaoError(
            code: .db3ReadyTimeout,
            message: "the db3 '\(db3Id)' made no progress for \(ms) ms; it is still being retried",
            details: ["db3Id": .string(db3Id), "readyTimeoutMs": .number(Double(ms))]
        ))
    }

    private func settleReady(_ handle: Handle) {
        guard !handle.subscription.readySettled else { return }
        let claimed = lock.withLock { () -> Bool in
            guard handles[handle.subscription.id]?.contains(where: { $0 === handle }) == true, !handle.readyClaimed else { return false }
            handle.readyClaimed = true
            handle.timer?.cancel()
            handle.timer = nil
            handle.timerGeneration += 1
            return true
        }
        guard claimed else { return }
        // Told before `ready()` returns, so code after the await has heard it.
        let event = Db3ReadyEvent(id: handle.subscription.id)
        handle.subscription.deliver(.ready(event))
        deps.emit(event)
        handle.subscription.resolveReady()
    }

    /// Bring the socket in line with the db3's subscriptions: open while any
    /// is held, closed once none is. One change of a db3 at a time.
    private func reconcile(_ db3Id: String) {
        let token = UUID()
        lock.withLock {
            let previous = chains[db3Id]?.task
            let task = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await self.reconcileStep(db3Id)
                self.lock.withLock {
                    if self.chains[db3Id]?.token == token { self.chains[db3Id] = nil }
                }
            }
            chains[db3Id] = Chain(token: token, task: task)
        }
    }

    private func reconcileStep(_ db3Id: String) async {
        let (wanted, opened) = lock.withLock { (!(handles[db3Id] ?? []).isEmpty && !destroyedFlag, active.contains(db3Id)) }
        if wanted && !opened {
            await start(db3Id)
        } else if !wanted && opened {
            await stop(db3Id)
        }
    }

    /// Wait for the db3's subscription changes in progress.
    private func settled(_ db3Id: String) async {
        while let task = lock.withLock({ chains[db3Id]?.task }) {
            await task.value
        }
    }

    private func start(_ db3Id: String) async {
        var format: Int?
        if deps.isBound(db3Id) || deps.isPendingCreate(db3Id) {
            format = RecordLogTransport.documentFormat
        } else {
            format = await deps.resolveFormat(db3Id)
            if format == nil || format == RecordLogTransport.documentFormat, let refusal = await deps.storageRefusal(db3Id) {
                failOpen(db3Id, refusal)
                return
            }
            if format == nil { format = await waitForFormat(db3Id) }
        }
        guard format == RecordLogTransport.documentFormat else {
            let shown = format.map { "\($0)" } ?? "unknown"
            let error = JsBaoError(
                code: .notADb3, message: "'\(db3Id)' is not a db3 (its documentFormat is \(shown))",
                details: ["db3Id": .string(db3Id), "documentFormat": format.map { .number(Double($0)) } ?? .null]
            )
            for handle in handlesOf(db3Id) {
                handle.subscription.reject(error)
                releaseHandle(handle, reconcile: false)
            }
            return
        }
        guard !handlesOf(db3Id).isEmpty else { return }
        lock.withLock { _ = active.insert(db3Id) }
        do {
            try await deps.open(db3Id)
        } catch {
            lock.withLock { _ = active.remove(db3Id) }
            failOpen(db3Id, error)
        }
        await refreshState(db3Id)
    }

    /// An open of the db3 failed: it is told as `Db3ErrorEvent`, and every subscription fails with it.
    private func failOpen(_ db3Id: String, _ error: Error) {
        let typed = error as? JsBaoError
        let code = typed?.code.rawValue ?? "DB3_OPEN_FAILED"
        let message = typed?.message ?? error.localizedDescription
        lock.withLock { errors[db3Id] = Db3StateError(code: code, message: message) }
        deps.emit(Db3ErrorEvent(id: db3Id, code: code, message: message))
        for handle in handlesOf(db3Id) {
            handle.subscription.reject(error)
            releaseHandle(handle, reconcile: false)
        }
    }

    private func stop(_ db3Id: String) async {
        let held = lock.withLock { () -> Bool in
            active.remove(db3Id)
            return doorHeld.contains(db3Id)
        }
        // Open through a document door as well: it stays open for the door.
        if held && deps.isOpen(db3Id) {
            await refreshState(db3Id)
            return
        }
        do {
            try await deps.close(db3Id)
        } catch {
            deps.logger?.warn("[db3] \(db3Id): closing it on the socket failed:", error.localizedDescription)
        }
        await refreshState(db3Id)
    }

    /// The document's format, waiting for the network when nothing local can
    /// say, asked again less often each time.
    private func waitForFormat(_ db3Id: String) async -> Int? {
        var delay: TimeInterval = 0.25
        while true {
            if lock.withLock({ destroyedFlag }) { return nil }
            if let format = await deps.resolveFormat(db3Id) { return format }
            if handlesOf(db3Id).isEmpty { return nil }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, 5)
        }
    }

    // MARK: - What changed

    /// The db3's session reported a status (a phase, or a progress step).
    func statusChanged(_ db3Id: String, _ status: RecordLogSessionStatus) {
        lock.withLock { statuses[db3Id] = status }
        if status.progress != nil || status.phase != .idle { progressed(db3Id) }
        // The phase and progress step are told at once, over the last numbers
        // read; the store's numbers follow.
        let known = current(db3Id)
        let subscribed = isSubscribed(db3Id)
        let phase = phaseOf(db3Id, subscribed: subscribed, marks: deps.syncMarks(db3Id))
        let progress = (phase == .loading || phase == .catchingUp) ? status.progress.map(Self.progress) : nil
        apply(db3Id, known.with(subscribed: subscribed, phase: phase, progress: .some(progress)))
        kick(db3Id)
    }

    /// A chunk or page made progress: the waits of the db3's subscriptions start again.
    func progressed(_ db3Id: String) {
        for handle in handlesOf(db3Id) { arm(handle) }
    }

    /// The socket opened or closed, or networking was allowed or stopped:
    /// every subscribed db3's state may have changed, and one open here whose
    /// session is idle is asked of the room again once it can be (Swift's
    /// offline mode can leave the socket open, so no reconnect does it).
    func connectionChanged() {
        let (ids, open) = lock.withLock { (Set(handles.keys).union(active), active) }
        let up = deps.socketUp()
        let outdated = lock.withLock { self.outdated }
        for db3Id in ids {
            // A db3 whose room needs a newer client is not asked of it again.
            if up, open.contains(db3Id), !outdated.contains(db3Id), statusFor(db3Id).phase == .idle { deps.resync(db3Id) }
            kick(db3Id)
        }
    }

    /// An open attempt of the db3 ended without a handshake.
    func syncFailed(_ db3Id: String, _ reason: String) {
        if reason == JsBaoErrorCode.db3ClientOutdated.rawValue {
            // The room needs a newer client: the db3 is gone for this client's
            // lifetime, its rows kept; nothing retries it.
            lock.withLock { _ = outdated.insert(db3Id) }
            kick(db3Id)
            return
        }
        // A terminal refusal: a revoked grant, or the db3's sync turned off.
        let refused = reason == JsBaoErrorCode.accessDenied.rawValue || reason == JsBaoErrorCode.db3SyncOff.rawValue
        lock.withLock {
            if reason == JsBaoErrorCode.db3SyncOff.rawValue {
                _ = syncOff.insert(db3Id)
            } else if reason == JsBaoErrorCode.accessDenied.rawValue {
                syncOff.remove(db3Id)
            }
        }
        if reason != "not connected", !refused, isSubscribed(db3Id) {
            let error = Db3StateError(code: reason, message: "the open of '\(db3Id)' failed (\(reason)); the client retries")
            lock.withLock { errors[db3Id] = error }
            let event = Db3ErrorEvent(id: db3Id, code: error.code, message: error.message)
            deps.emit(event)
            for handle in handlesOf(db3Id) { handle.subscription.deliver(.error(event)) }
        }
        // Refused while already gone (again, or for the first time since a
        // mark the store kept): no transition fires, but this contact is the
        // room's answer to every subscription waiting now.
        if refused, lock.withLock({ () -> Bool in
            roomRefused.insert(db3Id)
            return last[db3Id]?.phase == .gone
        }) {
            let error = goneError(db3Id)
            for handle in handlesOf(db3Id) { handle.subscription.reject(error) }
        }
        kick(db3Id)
    }

    /// The room refused the db3 because its sync is off (#4806): heard by the
    /// client before the session marks the store refused, so the gone a state
    /// read may report first is for that reason too.
    func syncOffHeard(_ db3Id: String) {
        lock.withLock { _ = syncOff.insert(db3Id) }
    }

    /// The db3's local rows changed.
    func rowsChanged(_ db3Id: String, changes: [Db3RowChange], origin: Db3RowsEvent.Origin, models: [String]) {
        let event = Db3RowsEvent(id: db3Id, changes: changes, origin: origin, models: models.isEmpty ? nil : models)
        deps.emit(event)
        for handle in handlesOf(db3Id) { handle.subscription.deliver(.rows(event)) }
        kick(db3Id)
    }

    /// The db3's unacknowledged writes changed, whether or not a row did.
    func pendingChanged(_ db3Id: String) {
        kick(db3Id)
    }

    /// A db3 the server created was adopted here (#4806): its state is read again.
    func adopted(_ db3Id: String) {
        kick(db3Id)
    }

    /// A db3 created on this device committed, or was refused (#4921): its state is read again.
    func createChanged(_ db3Id: String) {
        kick(db3Id)
    }

    /// Writes to the db3 were handed back.
    func writeRefused(_ refusal: DocumentWriteRefusedEvent) {
        let event = Db3WriteRefusedEvent(refusal)
        deps.emit(event)
        for handle in handlesOf(refusal.documentId) { handle.subscription.deliver(.writeRefused(event)) }
        kick(refusal.documentId)
    }

    // MARK: - Residency

    /// Bind every db3 the store holds for the current user that is not bound
    /// yet: each is resident or loads on its next subscribe, and answers
    /// queries meanwhile when it is. A db3 created here is in the store from
    /// its create (its writer is minted when it is bound), and the store is
    /// reset for another user, so the store's list is the user's.
    func bindStored() async {
        let identity = lock.withLock { self.identity }
        let current = { [self] in lock.withLock { !destroyedFlag && self.identity == identity } }
        let ids: [String]
        do {
            ids = try await deps.storedIds()
        } catch {
            deps.logger?.warn("[db3] the stored db3s could not be listed:", error.localizedDescription)
            return
        }
        for db3Id in ids {
            // The user changed: these are the previous user's db3s.
            guard current() else { return }
            if deps.isBound(db3Id) || deps.isOpen(db3Id) { continue }
            do {
                try await deps.bind(db3Id)
            } catch {
                deps.logger?.warn("[db3] \(db3Id): binding its stored copy failed:", error.localizedDescription)
            }
            // A logout or another user's sign-in raced this binding: undone.
            guard current() else {
                await deps.unbind(db3Id)
                return
            }
        }
    }

    /// Give up every subscription (`ready()` throws `DB3_DISPOSED`) and close
    /// each db3 on the socket; with `unbind`, unbind every db3 too (a logout,
    /// or the user is changing).
    func releaseAll(unbind: Bool) async {
        for (db3Id, list) in lock.withLock({ handles }) {
            for handle in list {
                handle.subscription.reject(JsBaoError(
                    code: .db3Disposed, message: "the subscription to '\(db3Id)' ended", details: ["db3Id": .string(db3Id)]
                ))
                releaseHandle(handle, reconcile: false)
            }
            reconcile(db3Id)
        }
        for db3Id in lock.withLock({ Array(chains.keys) }) { await settled(db3Id) }
        guard unbind else { return }
        await deps.unbindAll()
        lock.withLock {
            last = [:]
            errors = [:]
            doorHeld = []
            roomRefused = []
            outdated = []
            syncOff = []
        }
    }

    /// Forget every db3's last state, error and status (the user changed); a
    /// binding of the stored db3s under way is undone.
    func forgetStates() {
        lock.withLock {
            identity += 1
            last = [:]
            errors = [:]
            statuses = [:]
            roomRefused = []
            outdated = []
            syncOff = []
        }
    }

    /// The db3 was closed through a document door: this client's subscriptions
    /// to it end (a pending `ready()` throws `DB3_DISPOSED`) and the close
    /// itself takes it off the socket.
    func closedByDoor(_ db3Id: String) {
        lock.withLock { _ = doorHeld.remove(db3Id) }
        for handle in handlesOf(db3Id) {
            handle.subscription.reject(JsBaoError(
                code: .db3Disposed, message: "'\(db3Id)' was closed", details: ["db3Id": .string(db3Id)]
            ))
            releaseHandle(handle, reconcile: false)
        }
        lock.withLock { _ = active.remove(db3Id) }
        kick(db3Id)
    }

    /// The db3 was opened through a document door: a subscription's last
    /// dispose leaves it open.
    func openedByDoor(_ db3Id: String) {
        lock.withLock { _ = doorHeld.insert(db3Id) }
    }

    /// A db3's store was removed through another door (`documents.evict`).
    func evictedElsewhere(_ db3Id: String) {
        lock.withLock {
            last[db3Id] = nil
            errors[db3Id] = nil
            roomRefused.remove(db3Id)
            syncOff.remove(db3Id)
        }
        deps.emit(Db3EvictedEvent(id: db3Id, reason: .explicit))
        kick(db3Id)
    }

    /// The client is being destroyed: every subscription ends.
    func destroy() async {
        guard !lock.withLock({ destroyedFlag }) else { return }
        let held = lock.withLock { handles }
        for (db3Id, list) in held {
            for handle in list {
                handle.subscription.reject(JsBaoError(
                    code: .db3Disposed, message: "the client holding '\(db3Id)' was destroyed", details: ["db3Id": .string(db3Id)]
                ))
                releaseHandle(handle, reconcile: false)
            }
            reconcile(db3Id)
        }
        for db3Id in lock.withLock({ Array(chains.keys) }) { await settled(db3Id) }
        lock.withLock { destroyedFlag = true }
    }

    // MARK: - State

    private static func progress(_ progress: RecordLogSessionProgress) -> Db3Progress {
        Db3Progress(done: progress.done, total: progress.total, unit: progress.unit == .chunks ? .chunks : .entries)
    }

    private static func phase(_ phase: RecordLogSessionPhase) -> Db3Phase {
        switch phase {
        case .idle: return .idle
        case .opening: return .opening
        case .loading: return .loading
        case .catchingUp: return .catchingUp
        case .live: return .live
        }
    }

    private static func accessRefused(_ db3Id: String) -> JsBaoError {
        JsBaoError(
            code: .db3AccessRefused, message: "the room refused this user access to '\(db3Id)'",
            details: ["db3Id": .string(db3Id)]
        )
    }

    private static func syncOffRefused(_ db3Id: String) -> JsBaoError {
        JsBaoError(
            code: .db3SyncOff, message: "the db3 '\(db3Id)' has its sync off: no socket reaches it",
            details: ["db3Id": .string(db3Id)]
        )
    }

    /// Why a gone db3 is gone, as the error a waiting `ready()` throws:
    /// outdated first, then sync off, else a refused grant.
    private func goneError(_ db3Id: String) -> JsBaoError {
        if isOutdated(db3Id) { return Self.clientOutdated(db3Id) }
        return lock.withLock { syncOff.contains(db3Id) } ? Self.syncOffRefused(db3Id) : Self.accessRefused(db3Id)
    }

    /// `goneError`'s reason, as `Db3GoneEvent` names it.
    private func goneReason(_ db3Id: String) -> Db3GoneEvent.Reason {
        if isOutdated(db3Id) { return .clientOutdated }
        return lock.withLock { syncOff.contains(db3Id) } ? .syncOff : .permission
    }

    private static func clientOutdated(_ db3Id: String) -> JsBaoError {
        JsBaoError(
            code: .db3ClientOutdated,
            message: "the room needs a newer client to sync '\(db3Id)'; update the client (its rows stay readable)",
            details: ["db3Id": .string(db3Id)]
        )
    }

    /// Whether the room refused this client's wire version for the db3.
    private func isOutdated(_ db3Id: String) -> Bool {
        lock.withLock { outdated.contains(db3Id) }
    }

    private static func date(_ ms: Int64?) -> Date? {
        ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// The db3's session status, as last reported.
    private func statusFor(_ db3Id: String) -> RecordLogSessionStatus {
        lock.withLock { statuses[db3Id] } ?? RecordLogSessionStatus(phase: .idle)
    }

    /// Whether the db3 is resident, read synchronously from its bound store.
    private func isResidentNow(_ db3Id: String) -> Bool {
        guard deps.isBound(db3Id), var marks = deps.syncMarks(db3Id) else { return false }
        if deps.isPendingCreate(db3Id) { marks.createdLocally = true }
        return marks.resident
    }

    /// A state to answer synchronously before the store is read: the last one, else what is known now.
    private func provisional(_ db3Id: String) -> Db3State {
        let (known, subscribed) = lock.withLock { (last[db3Id], !(handles[db3Id] ?? []).isEmpty) }
        let marks = deps.syncMarks(db3Id)
        let base = known ?? Db3State(
            id: db3Id, resident: isResidentNow(db3Id), subscribed: subscribed, phase: .idle, progress: nil,
            cursor: marks?.cursor ?? 0, rows: 0, lastSyncAt: Self.date(marks?.lastCatchUpAt), pendingWrites: 0,
            permission: deps.knownPermission(db3Id), error: nil, pendingCreate: deps.isPendingCreate(db3Id)
        )
        return base.with(subscribed: subscribed, phase: phaseOf(db3Id, subscribed: subscribed, marks: marks))
    }

    private func phaseOf(_ db3Id: String, subscribed: Bool, marks: Db3SyncMarks?) -> Db3Phase {
        if marks?.permission == RecordLogPermission.refused || isOutdated(db3Id) { return .gone }
        // Subscribed with the socket down, or networking not allowed: the room
        // cannot keep it up to date, whatever the session last said. (Swift's
        // offline mode can leave the socket open with the session still live,
        // where the JS client's closes it and the session goes idle.)
        if subscribed && !deps.socketUp() { return .reconnecting }
        let status = statusFor(db3Id)
        if status.phase != .idle, isActive(db3Id) { return Self.phase(status.phase) }
        return subscribed ? .opening : .idle
    }

    /// Read the db3's state from its store and session.
    private func read(_ db3Id: String) async throws -> Db3State {
        let bound = deps.isBound(db3Id)
        let stored = try await deps.storedState(db3Id)
        var marks = bound ? deps.syncMarks(db3Id) : nil
        let subscribed = isSubscribed(db3Id)
        let pendingCreate = deps.isPendingCreate(db3Id)
        if pendingCreate { marks?.createdLocally = true }
        let lastSyncAt = stored?.lastCatchUpAt ?? marks?.lastCatchUpAt
        let resident: Bool
        if bound {
            resident = marks?.resident ?? false
        } else {
            resident = pendingCreate || (lastSyncAt != nil && (!(stored?.replacing ?? false) || stored?.staged == true))
        }
        let phase = phaseOf(db3Id, subscribed: subscribed, marks: marks)
        let status = statusFor(db3Id)
        let progress = (phase == .loading || phase == .catchingUp) ? status.progress.map(Self.progress) : nil
        let permission: Db3Permission?
        switch marks?.permission {
        case RecordLogPermission.refused: permission = .refused
        case RecordLogPermission.read: permission = .reader
        default: permission = deps.knownPermission(db3Id)
        }
        let gone = goneError(db3Id)
        let openError = lock.withLock { errors[db3Id] }
        let error: Db3StateError? = phase == .gone
            ? Db3StateError(code: gone.code.rawValue, message: gone.message)
            : openError ?? (pendingCreate ? deps.createRefusal(db3Id) : nil)
        return Db3State(
            id: db3Id, resident: resident, subscribed: subscribed, phase: phase, progress: progress,
            cursor: stored?.cursor ?? marks?.cursor ?? 0, rows: stored?.rows ?? 0, lastSyncAt: Self.date(lastSyncAt),
            pendingWrites: stored?.writers.reduce(0) { $0 + $1.pending } ?? 0, permission: permission, error: error,
            pendingCreate: pendingCreate
        )
    }

    /// Read the db3's state again, off the caller.
    private func kick(_ db3Id: String) {
        Task { [weak self] in await self?.refreshState(db3Id) }
    }

    /// Read the db3's state again; emit it, and settle its subscriptions, when
    /// it changed. A change heard while a read is in progress is read once more.
    private func refreshState(_ db3Id: String) async {
        let mark = ReadMark()
        let started = lock.withLock { () -> Bool in
            if let running = reading[db3Id] {
                running.again = true
                return false
            }
            reading[db3Id] = mark
            return true
        }
        guard started else { return }
        while true {
            do {
                apply(db3Id, try await read(db3Id))
            } catch {
                deps.logger?.debug("[db3] \(db3Id): reading its state failed:", error.localizedDescription)
                lock.withLock { reading[db3Id] = nil }
                return
            }
            let again = lock.withLock { () -> Bool in
                if mark.again {
                    mark.again = false
                    return true
                }
                reading[db3Id] = nil
                return false
            }
            if !again { return }
        }
    }

    private func apply(_ db3Id: String, _ state: Db3State) {
        let (previous, changed, list, open, refusedByRoom) = lock.withLock {
            () -> (Db3State?, Bool, [Handle], Bool, Bool) in
            if state.phase == .live {
                errors[db3Id] = nil
                syncOff.remove(db3Id)
            }
            let previous = last[db3Id]
            let changed = previous != state
            if changed { last[db3Id] = state }
            // The refusal was lifted: the next one is the room's anew.
            if previous?.phase == .gone && state.phase != .gone { roomRefused.remove(db3Id) }
            return (previous, changed, handles[db3Id] ?? [], active.contains(db3Id), roomRefused.contains(db3Id))
        }
        if changed {
            deps.emit(Db3StateEvent(state: state))
            for handle in list { handle.subscription.deliver(.state(state)) }
        }
        let outdated = isOutdated(db3Id)
        if state.phase == .gone && previous?.phase != .gone {
            let event = Db3GoneEvent(id: db3Id, reason: goneReason(db3Id))
            let error = goneError(db3Id)
            deps.emit(event)
            for handle in list {
                handle.subscription.deliver(.gone(event))
                // A mark the store kept from before is no answer of the room's
                // to these subscriptions: the open's own answer settles them.
                if outdated || refusedByRoom { handle.subscription.reject(error) }
            }
        } else if state.phase == .gone && outdated {
            // Subscribed again since: the room's answer is the same.
            for handle in list { handle.subscription.reject(Self.clientOutdated(db3Id)) }
        }
        if state.resident { for handle in list { handle.subscription.resolveAvailable() } }
        if state.phase == .live && open { for handle in list { settleReady(handle) } }
    }
}
