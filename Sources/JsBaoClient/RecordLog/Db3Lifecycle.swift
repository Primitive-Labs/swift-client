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
    /// The db3 lives only on this device (#5155).
    var localOnly = false
    /// The room's head as the store last heard it (#5221), or `nil`.
    var knownHead: Int? = nil
    /// When ``knownHead`` was heard (epoch ms), or `nil`.
    var knownHeadAt: Int64? = nil

    /// js-bao's `isRecordLogResident`: it lives only on this device, or it
    /// was created here, or a load completed and no unstaged replacement is
    /// in progress.
    var resident: Bool {
        if createdLocally || localOnly { return true }
        guard lastCatchUpAt != nil else { return false }
        return !replacing || staged
    }
}

/// What a purge of a db3's store answered.
struct Db3PurgeOutcome: Sendable, Equatable {
    var purged: Bool
}

/// Why a subscription ended, as a `DB3_DISPOSED` error's `details["reason"]`
/// names it: the web client's strings, verbatim.
enum Db3DisposedReason: String, CaseIterable, Sendable {
    /// A sign-out, or another user's sign-in.
    case identityChanged = "identity-changed"
    /// The subscription's own `dispose()`.
    case disposed
    /// The client was destroyed.
    case destroyed
    /// A document door (`closeDocument`, `documents.close`) closed the db3.
    case closed
    /// The db3's local copy was removed (`evict`, the retention policy).
    case evicted
}

/// A `DB3_DISPOSED` error for `db3Id`, saying why in `details`.
func db3DisposedError(_ db3Id: String, _ reason: Db3DisposedReason, message: String) -> JsBaoError {
    JsBaoError(code: .db3Disposed, message: message, details: ["db3Id": .string(db3Id), "reason": .string(reason.rawValue)])
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
    /// The server's final refusal of the db3's last format lookup (a 403, a
    /// 404, another 4xx but 401 and 429), or `nil`: read after `resolveFormat`
    /// answered `nil`, and a subscription waiting for the format fails with it.
    var formatRefusal: @Sendable (String) async -> Error? = { _ in nil }
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
    /// Whether the db3 lives only on this device (#5155), as the client knows
    /// now (its metadata row, or its bound store's mark). A store not bound
    /// yet that says so in its stored state counts too.
    var isLocalOnly: @Sendable (String) -> Bool = { _ in false }
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
    /// Clear the device's index policy for a db3 deleted here (#5322); an evict keeps it.
    var clearIndexPolicy: @Sendable (String) async -> Void = { _ in }
    /// Each index a bound db3's room places on this device, with how it stands here (#5322); `nil` when not bound.
    var indexStatuses: @Sendable (String) async throws -> [Db3LocalIndex]? = { _ in nil }
    /// Unbind every db3.
    var unbindAll: @Sendable () async -> Void = {}
    /// Every db3 bound here now.
    var boundIds: @Sendable () -> [String] = { [] }
    /// Whether another user's token was applied and the previous user's db3s
    /// are not released yet: their opens are no answer to a subscription.
    var identityPending: @Sendable () -> Bool = { false }
    /// Whether the db3's index list is applied to its store for this open
    /// (#5101): `ready()` waits while it answers `false`. Without it,
    /// `ready()` settles on `live`.
    var indexesSettled: (@Sendable (String) -> Bool)?
    /// When the db3 was last used here, in epoch ms (its metadata row's
    /// `lastOpenedAt`: the later of its last open and the end of its last
    /// subscription), or `nil` when no row says. The retention sweep ranks
    /// the stored copies by it.
    var lastUsedAt: @Sendable (String) -> Int64? = { _ in nil }
    var logger: Logger?
}

/// Why the retention sweep kept a copy it would have removed.
enum Db3RetentionKeep: String, Sendable {
    case subscribed
    case open
    case pendingCreate = "pending create"
    case unjudgedWrites = "unjudged writes"
    case held
    /// It lives only on this device (#5155): nothing could fetch it again.
    case localOnly = "local-only"
}

/// `DB3_LOCAL_ONLY` for an evict of a db3 that lives only on this device (#5155).
func db3LocalOnlyEvictError(_ db3Id: String) -> JsBaoError {
    JsBaoError(
        code: .db3LocalOnly,
        message: "client.db3.evict('\(db3Id)'): it lives only on this device, so this copy is its only one; "
            + "remove it with client.db3.delete",
        details: ["db3Id": .string(db3Id)]
    )
}

extension Db3State {
    /// This state with its subscription, phase, progress and permission
    /// replaced; its drift, when it has one, `live` exactly when the phase is (#5221).
    func with(
        subscribed: Bool? = nil, phase: Db3Phase? = nil, progress: Db3Progress?? = nil, permission: Db3Permission?? = nil
    ) -> Db3State {
        let phase = phase ?? self.phase
        return Db3State(
            id: id, resident: resident, subscribed: subscribed ?? self.subscribed, phase: phase,
            progress: progress ?? self.progress, cursor: cursor, rows: rows, lastSyncAt: lastSyncAt,
            pendingWrites: pendingWrites, permission: permission ?? self.permission, error: error, pendingCreate: pendingCreate,
            localOnly: localOnly,
            drift: drift.map { Db3Drift(entriesBehind: $0.entriesBehind, asOf: $0.asOf, live: phase == .live, pendingWrites: $0.pendingWrites) },
            indexes: phase == .gone ? nil : indexes
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
        /// The lifecycle's `identity` when it was made: a release ends the
        /// handles made before the user changed, not one made during it.
        let identity: Int
        var timer: Task<Void, Never>?
        var timerGeneration = 0
        /// `ready()` was claimed by `settleReady`: it fires once.
        var readyClaimed = false
        /// The db3 was live for it, whatever its `ready()` answered (#5101):
        /// a grant asks the room again for it after a refusal.
        var wasLive = false

        init(subscription: Db3Subscription, timeout: TimeInterval, identity: Int) {
            self.subscription = subscription
            self.timeout = timeout
            self.identity = identity
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
    /// The db3s whose open is in flight, by the identity its step started
    /// under: one started before the user changed is the outgoing user's.
    private var opening: [String: Int] = [:]
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
    /// The refused db3s a readable grant was heard for since the refusal,
    /// until the room answers (#5101): the room's refusal no longer stands.
    private var granted: Set<String> = []
    /// The refused db3s asked of the room again on a grant, until the room answers.
    private var reopening: Set<String> = []
    /// The db3s whose room refused them because their sync is off (#4806):
    /// when such a db3 turns gone, it is for that reason. Cleared once it is
    /// live, or refused for access instead.
    private var syncOff: Set<String> = []
    /// The db3s refused because they were deleted (#5049): when such a db3
    /// turns gone, it is for that reason, whatever refusal follows. Cleared
    /// once it is live, or its copy is removed.
    private var deleted: Set<String> = []
    /// The db3s heard deleted whose session has not yet taken the refusal
    /// (#5049): a live state read meanwhile predates it, so it keeps the reason.
    private var deletedUnapplied: Set<String> = []
    /// The reason the last gone event named for each db3 while it stays gone
    /// (#5091): a db3 gone for another reason that is then deleted announces
    /// `.deleted` once more, and only once.
    private var announced: [String: Db3GoneEvent.Reason] = [:]
    /// Removals of a db3's store in progress: a second door joins the first.
    private var removals: [String: Task<Void, Error>] = [:]
    /// Bumped when the user changes: a binding of the stored db3s started
    /// before it is undone when it finishes.
    private var identity = 0
    /// The user changed (`forgetStates`) and no release has run since: a
    /// reconcile does nothing, the release reconciles every db3 it covers.
    private var identityChanged = false
    /// Bumped by `releaseAll`: a reconcile queued before it does nothing (the
    /// release queues its own after the close).
    private var releases = 0
    /// The db3s each release in progress is releasing, by its generation:
    /// their bindings are the previous user's, and none is resident.
    private var releasing: [Int: Set<String>] = [:]
    private var destroyedFlag = false
    /// The db3s whose stored state said they live only on this device (#5155).
    private var localOnlyIds: Set<String> = []

    init(deps: Db3LifecycleDeps) {
        self.deps = deps
    }

    // MARK: - The surface

    func subscribe(_ db3Id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) throws -> Db3Subscription {
        if lock.withLock({ destroyedFlag }) || deps.destroyed() {
            throw db3DisposedError(db3Id, .destroyed, message: "client.db3.subscribe('\(db3Id)'): the client was destroyed")
        }
        guard !db3Id.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "client.db3.subscribe: a db3 id is a non-empty string")
        }
        let subscription = Db3Subscription(id: db3Id, owner: self)
        let handle = lock.withLock { () -> Handle in
            let handle = Handle(subscription: subscription, timeout: options.readyTimeout, identity: identity)
            handles[db3Id, default: []].append(handle)
            return handle
        }
        let state = provisional(db3Id)
        // A bound db3 that lives only on this device has no room to wait for.
        let local = isLocalOnly(db3Id) && deps.isBound(db3Id)
        let live = (state.phase == .live && isActive(db3Id) || local) && !deps.identityPending()
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
        // or an open attempt ended) is asked of the room again by a new
        // subscribe, unless a grant is asking it already.
        if isActive(db3Id), !isLocalOnly(db3Id), statusFor(db3Id).phase == .idle, deps.socketUp(),
           !lock.withLock({ reopening.contains(db3Id) }) {
            deps.resync(db3Id)
        }
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
        // A db3 that lives only on this device has no copy elsewhere to fetch
        // again: it is removed by `client.db3.delete`, never evicted.
        if isLocalOnly(db3Id) { throw db3LocalOnlyEvictError(db3Id) }
        let bound = deps.isBound(db3Id)
        let stored = try await deps.storedState(db3Id)
        // Asked again of the store's own mark: one not bound, or whose row is
        // gone, is still the device's only copy.
        if stored?.localOnly == true || isLocalOnly(db3Id) { throw db3LocalOnlyEvictError(db3Id) }
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

    /// Delete a db3 that lives only on this device (`client.db3.delete`,
    /// #5155): its copy is removed here and nothing is sent. Its subscriptions
    /// end as evicted (`DB3_DISPOSED`, `reason: "evicted"`) and
    /// `Db3EvictedEvent` fires once (`explicit`), only once the copy is gone;
    /// when another holder keeps the store it throws `.db3Held` and changes
    /// nothing.
    func deleteLocalOnly(_ db3Id: String) async throws {
        try await removeStore(db3Id, force: true, reason: .explicit, localDelete: true)
    }

    /// Remove a db3's store: its subscriptions are disposed (each hears
    /// `evicted`), it is closed on the socket and unbound here, then purged.
    /// One removal of a db3 at a time: a second joins the first. A
    /// `localDelete` ends the subscriptions only once the copy is gone, and a
    /// purge another holder refuses throws `.db3Held`.
    func removeStore(_ db3Id: String, force: Bool, reason: Db3EvictedEvent.Reason, localDelete: Bool = false) async throws {
        let (task, started) = lock.withLock { () -> (Task<Void, Error>, Bool) in
            if let running = removals[db3Id] { return (running, false) }
            let task = Task { [weak self] in
                guard let self else { return }
                try await self.removeStoreOnce(db3Id, force: force, reason: reason, localDelete: localDelete)
            }
            removals[db3Id] = task
            return (task, true)
        }
        defer {
            if started { lock.withLock { removals[db3Id] = nil } }
        }
        try await task.value
    }

    private func removeStoreOnce(_ db3Id: String, force: Bool, reason: Db3EvictedEvent.Reason, localDelete: Bool) async throws {
        let event = Db3EvictedEvent(id: db3Id, reason: reason)
        let endSubscriptions = { [self] in
            // The eviction ends a door's open of it too.
            lock.withLock { _ = doorHeld.remove(db3Id) }
            for handle in handlesOf(db3Id) {
                handle.subscription.deliver(.evicted(event))
                handle.subscription.reject(db3DisposedError(db3Id, .evicted, message: "the db3 '\(db3Id)' was evicted"))
                releaseHandle(handle, reconcile: false)
            }
            reconcile(db3Id)
        }
        // A local-only db3's delete ends its subscriptions once its copy is
        // gone (no socket open to close first): a refusal leaves them as they were.
        if !localDelete { endSubscriptions() }
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
            if localDelete {
                throw JsBaoError(
                    code: .db3Held,
                    message: "client.db3.delete('\(db3Id)'): another holder keeps its store; nothing was removed",
                    details: ["db3Id": .string(db3Id)]
                )
            }
            throw JsBaoError(
                code: .db3PendingWrites,
                message: "client.db3.evict('\(db3Id)'): it holds writes the room has not judged",
                details: ["db3Id": .string(db3Id)]
            )
        }
        if localDelete {
            endSubscriptions()
            lock.withLock { _ = active.remove(db3Id) }
            // Only the db3's deletion clears the device's index policy for it (#5322).
            await deps.clearIndexPolicy(db3Id)
        }
        await deps.forget(db3Id)
        lock.withLock {
            localOnlyIds.remove(db3Id)
            last[db3Id] = nil
            announced[db3Id] = nil
            errors[db3Id] = nil
            roomRefused.remove(db3Id)
            syncOff.remove(db3Id)
            deleted.remove(db3Id)
            deletedUnapplied.remove(db3Id)
            granted.remove(db3Id)
            reopening.remove(db3Id)
        }
        deps.emit(event)
        await refreshState(db3Id)
    }

    /// The keep verdict the format-1 retention pass asks of a db3 row
    /// (`DocumentManager.evictDb3ForRetention`): whether the retention sweep
    /// would remove the copy now. Kept: one being removed, subscribed, held
    /// open by a document door, a pending create, or holding writes the room
    /// has not judged. Removes nothing: `enforceRetention` removes.
    func retentionWouldRemove(_ db3Id: String) async -> Bool {
        if lock.withLock({ removals[db3Id] != nil }) { return false }
        return await retentionKeep(db3Id, logged: false) == nil
    }

    /// Why the retention policy keeps the copy now (the skip logged when
    /// `logged`), or `nil` when it may go. Judged with no wait after the store
    /// is read, so a subscription made meanwhile is seen.
    private func retentionKeep(_ db3Id: String, logged: Bool) async -> Db3RetentionKeep? {
        let stored = (try? await deps.storedState(db3Id)) ?? nil
        let pending = stored?.writers.reduce(0) { $0 + $1.pending } ?? 0
        let keep: Db3RetentionKeep?
        if stored?.localOnly == true || isLocalOnly(db3Id) {
            keep = .localOnly
        } else if isSubscribed(db3Id) || isActive(db3Id) {
            keep = .subscribed
        } else if deps.isOpen(db3Id) {
            keep = .open
        } else if deps.isPendingCreate(db3Id) {
            keep = .pendingCreate
        } else if pending > 0 {
            keep = .unjudgedWrites
        } else {
            keep = nil
        }
        guard logged, let keep else { return keep }
        switch keep {
        case .subscribed: deps.logger?.debug("[db3] \(db3Id): kept by the retention policy: it is subscribed")
        case .open: deps.logger?.debug("[db3] \(db3Id): kept by the retention policy: a document door holds it open")
        case .pendingCreate: deps.logger?.debug("[db3] \(db3Id): kept by the retention policy: it is a create not yet committed")
        case .unjudgedWrites:
            deps.logger?.warn("[db3] \(db3Id): kept by the retention policy: \(pending) write(s) the room has not judged")
        case .localOnly: deps.logger?.debug("[db3] \(db3Id): kept by the retention policy: it lives only on this device")
        case .held: break
        }
        return keep
    }

    private enum RetentionOutcome: Equatable {
        case evicted
        case gone
        case kept(Db3RetentionKeep)
    }

    /// The retention policy's door for a stored copy: removed unforced
    /// unless `retentionKeep` keeps it. A removal another door started is
    /// waited for: `gone` when it took the copy.
    private func retentionRemove(_ db3Id: String) async -> RetentionOutcome {
        if let running = lock.withLock({ removals[db3Id] }) {
            _ = try? await running.value
            let listed = (try? await deps.storedIds()) ?? []
            if !deps.isPendingCreate(db3Id) && !listed.contains(db3Id) { return .gone }
        }
        if let keep = await retentionKeep(db3Id, logged: true) { return .kept(keep) }
        do {
            try await removeStore(db3Id, force: false, reason: .retention)
            return .evicted
        } catch {
            deps.logger?.warn("[db3] \(db3Id): the retention policy could not remove it:", error.localizedDescription)
            return .kept(.held)
        }
    }

    /// The db3 rows the format-1 pass's `ttl` would hand this lifecycle
    /// (`db3RowsPastTtl`), removed ahead of that pass as its door removed them
    /// before the sweep took the db3 half (5085-C002): that pass's `maxDocs`
    /// count is then taken without them, as it always was. One `retentionKeep`
    /// keeps stays; a stored copy is evicted (one `Db3EvictedEvent`, reason
    /// `retention`); a row with no copy is forgotten with no event.
    func retentionExpire(_ db3Ids: [String]) async {
        guard !db3Ids.isEmpty else { return }
        let listed: [String]
        do {
            listed = try await deps.storedIds()
        } catch {
            deps.logger?.warn("[db3] retention: the stored db3s could not be listed:", error.localizedDescription)
            return
        }
        for id in db3Ids {
            if lock.withLock({ removals[id] != nil }) { continue }
            if await retentionKeep(id, logged: true) != nil { continue }
            guard listed.contains(id) else {
                await deps.forget(id)
                continue
            }
            do {
                try await removeStore(id, force: false, reason: .retention)
            } catch {
                deps.logger?.warn("[db3] \(id): the retention policy could not remove it:", error.localizedDescription)
            }
        }
    }

    /// The retention sweep running, which the next one waits for.
    private var sweep: Task<Void, Never>?

    /// Apply the retention policy to the db3 copies stored on this device
    /// (what `stored()` lists), ranked by last use: the metadata row's
    /// `lastUsedAt`, else the store's last catch-up, else oldest. `ttlMs`
    /// removes every copy not used for that long; `maxDocs` removes the least
    /// recently used copies until at most that many remain (`nil` is no cap,
    /// `0` keeps no copy it may remove). A subscribed copy, one a document
    /// door holds open, a pending create and one holding writes the room has
    /// not judged are kept and still count, so the count may stay above
    /// `maxDocs`. Sweeps run one at a time, in the order they were asked for;
    /// each writes one `[db3] retention: …` line.
    func enforceRetention(ttlMs: Int64?, maxDocs: Int?) async {
        let run = lock.withLock { () -> Task<Void, Never> in
            let previous = sweep
            let run = Task { [weak self] in
                await previous?.value
                await self?.sweepOnce(ttlMs: ttlMs, maxDocs: maxDocs)
            }
            sweep = run
            return run
        }
        await run.value
    }

    private func sweepOnce(ttlMs: Int64?, maxDocs: Int?) async {
        guard ttlMs != nil || maxDocs != nil else { return }
        // Removals in progress settle first, so the listing is the store's.
        for removal in lock.withLock({ Array(removals.values) }) { _ = try? await removal.value }
        let ids: [String]
        do {
            var listed = try await deps.storedIds()
            for id in deps.pendingCreates() where !listed.contains(id) { listed.append(id) }
            ids = listed
        } catch {
            deps.logger?.warn("[db3] retention: the stored db3s could not be listed:", error.localizedDescription)
            return
        }
        var copies: [(id: String, lastUsed: Int64)] = []
        // A db3 that lives only here is never removed by a sweep and counts
        // toward no cap: the cap is on the copies that can be fetched again (#5155).
        var localOnly: [String] = []
        for id in ids {
            // A subscription change in progress (a dispose's close) settles first.
            await settled(id)
            let stored = (try? await deps.storedState(id)) ?? nil
            if stored?.localOnly == true || isLocalOnly(id) {
                localOnly.append(id)
                continue
            }
            // A copy nothing dates is the oldest, for the cap and the TTL alike.
            copies.append((id, deps.lastUsedAt(id) ?? stored?.lastCatchUpAt ?? 0))
        }
        let counted = ids.count - localOnly.count
        // The least recently used first; a tie keeps the listing's order.
        copies = copies.enumerated()
            .sorted { ($0.element.lastUsed, $0.offset) < ($1.element.lastUsed, $1.offset) }
            .map(\.element)

        // Why each kept copy stays, by copy, in the order first kept: one
        // judged by both passes counts once.
        var keptOrder: [String] = []
        var kept: [String: Db3RetentionKeep] = [:]
        var left: Set<String> = []
        var evicted = 0
        var elsewhere = 0
        func record(_ id: String, _ outcome: RetentionOutcome) {
            switch outcome {
            case .evicted, .gone:
                left.insert(id)
                kept[id] = nil
                keptOrder.removeAll { $0 == id }
                if outcome == .evicted { evicted += 1 } else { elsewhere += 1 }
            case .kept(let reason):
                if kept[id] == nil { keptOrder.append(id) }
                kept[id] = reason
            }
        }

        if let ttlMs {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for copy in copies where now - copy.lastUsed > ttlMs {
                record(copy.id, await retentionRemove(copy.id))
            }
        }
        if let maxDocs {
            for copy in copies {
                if counted - left.count <= maxDocs { break }
                if left.contains(copy.id) { continue }
                record(copy.id, await retentionRemove(copy.id))
            }
        }

        for id in localOnly {
            deps.logger?.debug("[db3] \(id): kept by the retention policy: it lives only on this device")
            record(id, .kept(.localOnly))
        }
        var counts: [(Db3RetentionKeep, Int)] = []
        for id in keptOrder {
            guard let reason = kept[id] else { continue }
            if let at = counts.firstIndex(where: { $0.0 == reason }) { counts[at].1 += 1 } else { counts.append((reason, 1)) }
        }
        let reasons = counts.map { "\($0.1) \($0.0.rawValue)" }.joined(separator: ", ")
        let remaining = counted - left.count
        var line = "[db3] retention: \(ids.count) stored, \(keptOrder.count) kept\(keptOrder.isEmpty ? "" : " (\(reasons))"), \(evicted) evicted"
        if elsewhere > 0 { line += ", \(elsewhere) removed elsewhere" }
        if let maxDocs, remaining > maxDocs { line += "; \(remaining) remain, above maxDocs \(maxDocs)" }
        deps.logger?.debug(line)
    }

    func stored() async throws -> [Db3StoredEntry] {
        var ids = Set(try await deps.storedIds())
        ids.formUnion(deps.pendingCreates())
        var out: [Db3StoredEntry] = []
        for id in ids {
            let state = try await read(id)
            out.append(Db3StoredEntry(
                id: id, rows: state.rows, cursor: state.cursor, pendingWrites: state.pendingWrites,
                lastSyncAt: state.lastSyncAt, resident: state.resident, localOnly: state.localOnly
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
        // A db3 that lives only here is live exactly while it is subscribed,
        // whether or not its state was read since.
        let phase = isLocalOnly(db3Id) ? (subscribed ? Db3Phase.live : .idle) : state.phase
        return state.subscribed == subscribed && state.phase == phase ? state : state.with(subscribed: subscribed, phase: phase)
    }

    /// The subscription was disposed.
    func release(_ subscription: Db3Subscription) {
        guard let handle = handle(of: subscription) else { return }
        subscription.reject(db3DisposedError(
            subscription.id, .disposed, message: "the subscription to '\(subscription.id)' was disposed"
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

    /// Whether this client holds the db3 open (#5101): a subscription holds
    /// it, or a document door does. A copy whose last subscription was
    /// disposed is not held, whether or not its close has run yet.
    func holdsOpen(_ db3Id: String) -> Bool {
        let (subscribed, door) = lock.withLock { (!(handles[db3Id] ?? []).isEmpty, doorHeld.contains(db3Id)) }
        return subscribed || (door && deps.isOpen(db3Id))
    }

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
        // Called only while the db3 is live for it: a grant reopens it after a refusal.
        lock.withLock {
            if handles[handle.subscription.id]?.contains(where: { $0 === handle }) == true { handle.wasLive = true }
        }
        guard !handle.subscription.readySettled else { return }
        // The db3's index list is not applied yet (#5101): `ready()` waits for
        // it, bounded by its timeout on every path, the already-live attach included.
        if !isLocalOnly(handle.subscription.id), deps.indexesSettled?(handle.subscription.id) == false {
            guard isAttached(handle), lock.withLock({ handle.timer == nil }) else { return }
            if handle.timeout <= 0 { timedOut(handle) } else { arm(handle) }
            return
        }
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
        let release = lock.withLock { releases }
        enqueue(db3Id) { [weak self] in
            guard let self else { return }
            // Queued before a user change, or run after it but before its
            // release began: the release's own reconcile, queued behind its
            // close, decides instead. Starting an open here, ahead of that
            // close, would wait for the release that waits for it.
            let identity = self.lock.withLock { self.releases == release && !self.identityChanged ? self.identity : nil }
            guard let identity else { return }
            await self.reconcileStep(db3Id, identity: identity)
        }
    }

    /// Run `step` on the db3's chain, after its earlier starts and stops.
    @discardableResult
    private func enqueue(_ db3Id: String, _ step: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock { enqueueLocked(db3Id, step) }
    }

    /// `enqueue`, with `lock` held.
    private func enqueueLocked(_ db3Id: String, _ step: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let previous = chains[db3Id]?.task
        let task = Task { [weak self] in
            await previous?.value
            await step()
            guard let self else { return }
            self.lock.withLock {
                if self.chains[db3Id]?.token == token { self.chains[db3Id] = nil }
            }
        }
        chains[db3Id] = Chain(token: token, task: task)
        return task
    }

    private func reconcileStep(_ db3Id: String, identity: Int) async {
        let (wanted, opened) = lock.withLock { (!(handles[db3Id] ?? []).isEmpty && !destroyedFlag, active.contains(db3Id)) }
        if wanted && !opened {
            await start(db3Id, identity: identity)
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

    /// Open the db3 for its subscriptions; `identity` is the one the step
    /// started under (`openIdentity` answers it while the open is in flight).
    private func start(_ db3Id: String, identity: Int) async {
        if isLocalOnly(db3Id) { return await startLocal(db3Id) }
        var format: Int?
        if deps.isBound(db3Id) || deps.isPendingCreate(db3Id) {
            format = RecordLogTransport.documentFormat
        } else {
            format = await deps.resolveFormat(db3Id)
            if format == nil || format == RecordLogTransport.documentFormat, let refusal = await deps.storageRefusal(db3Id) {
                failOpen(db3Id, refusal)
                return
            }
            if format == nil {
                let waited = await waitForFormat(db3Id)
                if let refusal = waited.refusal {
                    // The server's final answer about the document: nothing is opened.
                    failOpen(db3Id, refusal)
                    await refreshState(db3Id)
                    return
                }
                format = waited.format
            }
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
        lock.withLock {
            active.insert(db3Id)
            opening[db3Id] = identity
        }
        do {
            defer { lock.withLock { _ = opening.removeValue(forKey: db3Id) } }
            try await deps.open(db3Id)
        } catch is CancellationError {
            // Retired while it waited for an identity change: the user changed
            // since it started, or a further change began, and that release
            // settles the handles. No error is kept.
            lock.withLock { _ = active.remove(db3Id) }
            return
        } catch {
            lock.withLock { _ = active.remove(db3Id) }
            failOpen(db3Id, error)
        }
        await refreshState(db3Id)
    }

    /// A db3 that lives only on this device takes its subscriptions with no
    /// open (#5155): its store is bound when it is not, and it is live at once.
    private func startLocal(_ db3Id: String) async {
        guard !handlesOf(db3Id).isEmpty else { return }
        if !deps.isBound(db3Id) {
            do {
                try await deps.bind(db3Id)
            } catch {
                failOpen(db3Id, error)
                await refreshState(db3Id)
                return
            }
        }
        lock.withLock { _ = active.insert(db3Id) }
        await refreshState(db3Id)
    }

    /// The identity the db3's open in flight started under; `nil` when no
    /// open of it is in flight.
    func openIdentity(_ db3Id: String) -> Int? {
        lock.withLock { opening[db3Id] }
    }

    /// Close an outgoing user's open on the socket; one a document door holds
    /// is left for the door, as `stop` leaves it, and one already closed (the
    /// logout's sweep got there first) is left alone.
    private func closeOutgoing(_ db3Id: String) async {
        guard deps.isOpen(db3Id) else { return }
        if lock.withLock({ doorHeld.contains(db3Id) }) { return }
        do {
            try await deps.close(db3Id)
        } catch {
            deps.logger?.warn("[db3] \(db3Id): closing it on the socket failed:", error.localizedDescription)
        }
    }

    /// An open of the db3 failed: it is told as `Db3ErrorEvent`, and every subscription fails with it.
    private func failOpen(_ db3Id: String, _ error: Error) {
        let typed = error as? JsBaoError
        let http = error as? HttpError
        let code = typed?.code.rawValue ?? http?.serverCode ?? "DB3_OPEN_FAILED"
        let message = typed?.message ?? http?.serverMessage ?? http?.message ?? error.localizedDescription
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
        // Nothing was opened on the socket for a db3 that lives only here.
        if isLocalOnly(db3Id) {
            await refreshState(db3Id)
            return
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
    /// say, asked again less often each time. A final refusal of the lookup
    /// (403, 404, another 4xx) is answered as the error the subscriptions
    /// fail with. The caller has already asked once and heard no format, so
    /// that lookup's refusal is read before any second lookup can clear it.
    private func waitForFormat(_ db3Id: String) async -> (format: Int?, refusal: Error?) {
        var delay: TimeInterval = 0.25
        var asked = true
        while true {
            if lock.withLock({ destroyedFlag }) { return (nil, nil) }
            if !asked, let format = await deps.resolveFormat(db3Id) { return (format, nil) }
            asked = false
            if let refusal = await deps.formatRefusal(db3Id) { return (nil, refusal) }
            if handlesOf(db3Id).isEmpty { return (nil, nil) }
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
        let marks = deps.syncMarks(db3Id)
        let phase = phaseOf(db3Id, subscribed: subscribed, marks: marks)
        let progress = (phase == .loading || phase == .catchingUp) ? status.progress.map(Self.progress) : nil
        // The level is the marks' now too: a reopen's `live` after a grant is
        // told with the grant's level, not the refusal last read (#5101).
        apply(db3Id, known.with(
            subscribed: subscribed, phase: phase, progress: .some(progress), permission: .some(permissionOf(db3Id, marks))
        ))
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
            if up, open.contains(db3Id), !outdated.contains(db3Id), !isLocalOnly(db3Id), statusFor(db3Id).phase == .idle {
                deps.resync(db3Id)
            }
            kick(db3Id)
        }
    }

    /// An open attempt of the db3 ended without a handshake.
    func syncFailed(_ db3Id: String, _ reason: String) {
        // A reopen on a grant ended: the next grant may ask again.
        lock.withLock { _ = reopening.remove(db3Id) }
        if reason == JsBaoErrorCode.db3ClientOutdated.rawValue {
            // The room needs a newer client: the db3 is gone for this client's
            // lifetime, its rows kept; nothing retries it.
            lock.withLock { _ = outdated.insert(db3Id) }
            kick(db3Id)
            return
        }
        // A terminal refusal: a revoked grant, the db3's sync turned off, or
        // the db3 deleted (which stays the reason whatever follows).
        let refused = reason == JsBaoErrorCode.accessDenied.rawValue || reason == JsBaoErrorCode.db3SyncOff.rawValue
            || reason == Self.documentDeleted
        lock.withLock {
            if reason == Self.documentDeleted {
                _ = deleted.insert(db3Id)
                deletedUnapplied.remove(db3Id)
            } else if reason == JsBaoErrorCode.db3SyncOff.rawValue {
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
        // A grant heard before the refusal no longer stands.
        if refused, lock.withLock({ () -> Bool in
            roomRefused.insert(db3Id)
            granted.remove(db3Id)
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

    /// The room or the connection refused the db3 because it was deleted
    /// (#5049): heard by the client before the session marks the store
    /// refused, so the gone a state read may report first is for that reason.
    /// A live state read before the session takes the refusal does not clear it.
    func deletedHeard(_ db3Id: String) {
        lock.withLock {
            _ = deleted.insert(db3Id)
            _ = deletedUnapplied.insert(db3Id)
        }
    }

    /// The reason the client heard for a refusal of the db3 (`deletedHeard`,
    /// `syncOffHeard`, or the session's report), or `nil`.
    func goneReasonHeard(_ db3Id: String) -> Db3GoneEvent.Reason? {
        lock.withLock { deleted.contains(db3Id) ? .deleted : syncOff.contains(db3Id) ? .syncOff : nil }
    }

    /// The code the room and the connection refuse a deleted db3's frames with.
    private static let documentDeleted = "DOCUMENT_DELETED"

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

    /// Give up every subscription made before the user changed (`ready()`
    /// throws `DB3_DISPOSED`, `identity-changed`) and close each db3 on the
    /// socket; with `unbind`, unbind every db3 too (a logout, or the user is
    /// changing).
    ///
    /// Every open of the outgoing user is retired at once and closed on the
    /// socket, whether or not a subscription was made since; such a
    /// subscription opens after the close. While the release runs, no db3 it
    /// releases reads resident. Returns once those closes ran, never waiting
    /// for a later open, which may itself wait for this release.
    func releaseAll(unbind: Bool) async {
        let bound = deps.boundIds()
        // Every outgoing open is retired and its close queued in the same hold
        // that moves the generation on: a reconcile queued before it does
        // nothing, and one queued after it runs behind the close, so no open
        // of the new user starts ahead of a close this release waits for.
        let (generation, ids, now, changed, closes) = lock.withLock { () -> (Int, [String], Int, Bool, [Task<Void, Never>]) in
            releases += 1
            let changed = identityChanged
            identityChanged = false
            let ids = Set(handles.keys).union(active)
            releasing[releases] = ids.union(bound)
            let closes = active.map { db3Id in
                enqueueLocked(db3Id) { [weak self] in await self?.closeOutgoing(db3Id) }
            }
            active = []
            return (releases, Array(ids), identity, changed, closes)
        }
        for db3Id in ids {
            // A subscription made since the user changed is the new user's.
            for handle in handlesOf(db3Id) where !changed || handle.identity < now {
                handle.subscription.reject(db3DisposedError(
                    db3Id, .identityChanged, message: "the subscription to '\(db3Id)' ended: the signed-in user changed"
                ))
                releaseHandle(handle, reconcile: false)
            }
            reconcile(db3Id)
        }
        for close in closes { await close.value }
        if unbind {
            await deps.unbindAll()
            lock.withLock {
                last = [:]
                announced = [:]
                errors = [:]
                doorHeld = []
                roomRefused = []
                outdated = []
                syncOff = []
                deleted = []
                deletedUnapplied = []
                granted = []
                reopening = []
            }
        }
        let released = lock.withLock { releasing.removeValue(forKey: generation) ?? [] }
        for db3Id in released { kick(db3Id) }
    }

    /// Whether a release in progress is releasing the db3.
    private func isReleasing(_ db3Id: String) -> Bool {
        lock.withLock { releasing.values.contains { $0.contains(db3Id) } }
    }

    /// Forget every db3's last state, error and status (the user changed); a
    /// binding of the stored db3s under way is undone. Answers the new
    /// identity: an open in flight under an earlier one is the outgoing user's.
    @discardableResult
    func forgetStates() -> Int {
        lock.withLock {
            identity += 1
            identityChanged = true
            localOnlyIds = []
            last = [:]
            announced = [:]
            errors = [:]
            statuses = [:]
            roomRefused = []
            outdated = []
            syncOff = []
            deleted = []
            deletedUnapplied = []
            granted = []
            reopening = []
            return identity
        }
    }

    /// The db3 was closed through a document door: this client's subscriptions
    /// to it end (a pending `ready()` throws `DB3_DISPOSED`) and the close
    /// itself takes it off the socket.
    func closedByDoor(_ db3Id: String) {
        lock.withLock { _ = doorHeld.remove(db3Id) }
        for handle in handlesOf(db3Id) {
            handle.subscription.reject(db3DisposedError(db3Id, .closed, message: "'\(db3Id)' was closed"))
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
            announced[db3Id] = nil
            errors[db3Id] = nil
            roomRefused.remove(db3Id)
            syncOff.remove(db3Id)
            deleted.remove(db3Id)
            deletedUnapplied.remove(db3Id)
            granted.remove(db3Id)
            reopening.remove(db3Id)
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
                handle.subscription.reject(db3DisposedError(
                    db3Id, .destroyed, message: "the client holding '\(db3Id)' was destroyed"
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
    /// outdated first, then deleted, then sync off, else a refused grant.
    private func goneError(_ db3Id: String) -> JsBaoError {
        Self.goneError(db3Id, goneReason(db3Id))
    }

    private static func goneError(_ db3Id: String, _ reason: Db3GoneEvent.Reason) -> JsBaoError {
        switch reason {
        case .clientOutdated: return Self.clientOutdated(db3Id)
        case .deleted: return Self.deletedRefused(db3Id)
        case .syncOff: return Self.syncOffRefused(db3Id)
        case .permission: return Self.accessRefused(db3Id)
        }
    }

    /// `goneError`'s reason, as `Db3GoneEvent` names it.
    private func goneReason(_ db3Id: String) -> Db3GoneEvent.Reason {
        lock.withLock { goneReasonHeld(db3Id) }
    }

    /// `goneReason`, read with the lock held.
    private func goneReasonHeld(_ db3Id: String) -> Db3GoneEvent.Reason {
        if outdated.contains(db3Id) { return .clientOutdated }
        return deleted.contains(db3Id) ? .deleted : syncOff.contains(db3Id) ? .syncOff : .permission
    }

    private static func deletedRefused(_ db3Id: String) -> JsBaoError {
        JsBaoError(
            code: .db3Deleted, message: "the db3 '\(db3Id)' was deleted; its rows stay readable until it is evicted",
            details: ["db3Id": .string(db3Id)]
        )
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
        guard !isReleasing(db3Id), deps.isBound(db3Id), var marks = deps.syncMarks(db3Id) else { return false }
        if deps.isPendingCreate(db3Id) { marks.createdLocally = true }
        return marks.resident
    }

    /// A state to answer synchronously before the store is read: the last one, else what is known now.
    private func provisional(_ db3Id: String) -> Db3State {
        let (known, subscribed) = lock.withLock { (last[db3Id], !(handles[db3Id] ?? []).isEmpty) }
        let marks = deps.syncMarks(db3Id)
        let localOnly = isLocalOnly(db3Id)
        let base = known ?? Db3State(
            id: db3Id, resident: isResidentNow(db3Id), subscribed: subscribed, phase: .idle, progress: nil,
            cursor: marks?.cursor ?? 0, rows: 0, lastSyncAt: Self.date(marks?.lastCatchUpAt), pendingWrites: 0,
            permission: localOnly ? .owner : deps.knownPermission(db3Id), error: nil,
            pendingCreate: !localOnly && deps.isPendingCreate(db3Id), localOnly: localOnly
        )
        return base.with(subscribed: subscribed, phase: phaseOf(db3Id, subscribed: subscribed, marks: marks))
    }

    private func phaseOf(_ db3Id: String, subscribed: Bool, marks: Db3SyncMarks?) -> Db3Phase {
        // A db3 that lives only here has no room to wait for.
        if isLocalOnly(db3Id) { return subscribed ? .live : .idle }
        if refusedNow(db3Id, marks) || isOutdated(db3Id) { return .gone }
        // Granted since the room refused it, and not asked again yet (#5101).
        if marks?.permission == RecordLogPermission.refused, statusFor(db3Id).phase == .idle,
           lock.withLock({ granted.contains(db3Id) && !reopening.contains(db3Id) }) {
            return .idle
        }
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
        if stored?.localOnly == true { lock.withLock { _ = localOnlyIds.insert(db3Id) } }
        var marks = bound ? deps.syncMarks(db3Id) : nil
        let subscribed = isSubscribed(db3Id)
        let localOnly = isLocalOnly(db3Id)
        let pendingCreate = !localOnly && deps.isPendingCreate(db3Id)
        if pendingCreate { marks?.createdLocally = true }
        let lastSyncAt = stored?.lastCatchUpAt ?? marks?.lastCatchUpAt
        // Resident means a model query answers now: the store is bound to
        // this client with its models attached (its marks read), and holds a
        // readable copy. A stored copy nothing binds answers no query.
        let resident = bound && (marks?.resident ?? false) && !isReleasing(db3Id)
        let phase = phaseOf(db3Id, subscribed: subscribed, marks: marks)
        let status = statusFor(db3Id)
        let progress = (phase == .loading || phase == .catchingUp) ? status.progress.map(Self.progress) : nil
        let permission = localOnly ? .owner : permissionOf(db3Id, marks)
        let gone = goneError(db3Id)
        let openError = lock.withLock { errors[db3Id] }
        let error: Db3StateError? = phase == .gone
            ? Db3StateError(code: gone.code.rawValue, message: gone.message)
            : openError ?? (pendingCreate ? deps.createRefusal(db3Id) : nil)
        let cursor = stored?.cursor ?? marks?.cursor ?? 0
        let pendingWrites = stored?.writers.reduce(0) { $0 + $1.pending } ?? 0
        // How far behind the copy is (#5221), once the server's position was heard.
        let knownHead = stored?.knownHead ?? marks?.knownHead
        let knownHeadAt = stored?.knownHead != nil ? stored?.knownHeadAt : marks?.knownHeadAt
        let drift = localOnly ? nil : knownHead.map { head in
            Db3Drift(
                entriesBehind: max(0, head - cursor), asOf: Date(timeIntervalSince1970: Double(knownHeadAt ?? 0) / 1000),
                live: phase == .live, pendingWrites: pendingWrites
            )
        }
        // The indexes placed on this device and how each stands (#5322), while the copy is bound here.
        let indexes = bound && phase != .gone ? try await deps.indexStatuses(db3Id) : nil
        return Db3State(
            id: db3Id, resident: resident, subscribed: subscribed, phase: phase, progress: progress,
            cursor: cursor, rows: stored?.rows ?? 0, lastSyncAt: Self.date(lastSyncAt),
            pendingWrites: pendingWrites, permission: permission, error: error,
            pendingCreate: pendingCreate, localOnly: localOnly, drift: drift, indexes: indexes
        )
    }

    /// Whether the db3 lives only on this device (#5155): no room serves it,
    /// so it is never opened on the socket, its subscriptions are live at
    /// once, and it has no state to wait for.
    func isLocalOnly(_ db3Id: String) -> Bool {
        lock.withLock { localOnlyIds.contains(db3Id) } || deps.isLocalOnly(db3Id) || deps.syncMarks(db3Id)?.localOnly == true
    }

    /// A permission was heard for the db3 and its store took it (#5070): its
    /// state is read again, so a `Db3StateEvent` carries the new level.
    ///
    /// A readable level the server sent just now (`heard`, #5101) for a db3
    /// the room refused for this user (not one gone because it was deleted,
    /// its sync went off or the room needs a newer client) is a grant: the db3
    /// is no longer `gone`, and its state answers the level until the room
    /// answers. One this client holds open (a subscription that was live, one
    /// whose `ready()` is still pending, or a document door) is asked of the
    /// room again at once, once while that ask runs; any other is asked at
    /// its next subscribe. The room's `record.opened` lifts the store's
    /// refused mark; a refusal again turns it `gone` again.
    ///
    /// - Parameter heard: The level the server sent; `nil` for one the client
    ///   learned at its own open or replayed from its cache, which only
    ///   re-reads the state.
    func permissionChanged(_ db3Id: String, heard: Db3Permission? = nil) {
        if let heard, heard != .refused, deps.isBound(db3Id),
           deps.syncMarks(db3Id)?.permission == RecordLogPermission.refused {
            let grantable = lock.withLock { () -> Bool in
                guard !outdated.contains(db3Id), !deleted.contains(db3Id), !syncOff.contains(db3Id) else { return false }
                granted.insert(db3Id)
                return true
            }
            if grantable, wantsReopen(db3Id), lock.withLock({ reopening.insert(db3Id).inserted }) {
                deps.logger?.debug("[db3] \(db3Id): a grant was heard for a refused db3; asking the room again")
                deps.resync(db3Id)
            }
        }
        kick(db3Id)
    }

    /// Whether a grant asks the room again for the refused db3 at once: a
    /// subscription that was live holds it, or one still waiting for the
    /// room, or a document door. A subscription the refusal answered before
    /// the db3 was ever live for it (its `ready()` rejected) does not: a new
    /// subscribe asks again.
    private func wantsReopen(_ db3Id: String) -> Bool {
        let (list, door) = lock.withLock { (handles[db3Id] ?? [], doorHeld.contains(db3Id)) }
        let wasLive = lock.withLock { list.contains { $0.wasLive } }
        if wasLive || list.contains(where: { !$0.subscription.readySettled }) { return true }
        return door && deps.isOpen(db3Id)
    }

    /// The level a db3's state reports: `refused` while the room's refusal
    /// stands, `reader` on a store marked read-only, else the client's record.
    private func permissionOf(_ db3Id: String, _ marks: Db3SyncMarks?) -> Db3Permission? {
        if refusedNow(db3Id, marks) { return .refused }
        if marks?.permission == RecordLogPermission.read { return .reader }
        return deps.knownPermission(db3Id)
    }

    /// Whether the room's refusal of the db3 stands: its store is marked
    /// refused and no grant was heard since.
    private func refusedNow(_ db3Id: String, _ marks: Db3SyncMarks?) -> Bool {
        marks?.permission == RecordLogPermission.refused && !lock.withLock { granted.contains(db3Id) }
    }

    /// The db3's index list was applied to its store, or its read settled
    /// (#5101): a waiting `ready()` may settle.
    func indexesChanged(_ db3Id: String) {
        kick(db3Id)
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
        let (previous, changed, list, open, refusedByRoom, announce) = lock.withLock {
            () -> (Db3State?, Bool, [Handle], Bool, Bool, Db3GoneEvent.Reason?) in
            if state.phase == .live {
                errors[db3Id] = nil
                granted.remove(db3Id)
                reopening.remove(db3Id)
                syncOff.remove(db3Id)
                if !deletedUnapplied.contains(db3Id) { deleted.remove(db3Id) }
            }
            let previous = last[db3Id]
            let changed = previous != state
            if changed { last[db3Id] = state }
            // What this read announces is decided with `last`, so a read
            // applied meanwhile finds it told (#5091-C001): the transition's
            // reason, or `.deleted` once more for a db3 gone for another reason.
            var announce: Db3GoneEvent.Reason?
            if state.phase != .gone {
                announced[db3Id] = nil
            } else {
                let reason = goneReasonHeld(db3Id)
                if previous?.phase != .gone || (reason == .deleted && announced[db3Id] != .deleted) {
                    announce = reason
                    announced[db3Id] = reason
                }
            }
            // The refusal was lifted: the next one is the room's anew.
            if previous?.phase == .gone && state.phase != .gone { roomRefused.remove(db3Id) }
            return (previous, changed, handles[db3Id] ?? [], active.contains(db3Id), roomRefused.contains(db3Id), announce)
        }
        if changed {
            deps.emit(Db3StateEvent(state: state))
            for handle in list { handle.subscription.deliver(.state(state)) }
        }
        let outdated = isOutdated(db3Id)
        if let reason = announce, previous?.phase != .gone {
            let event = Db3GoneEvent(id: db3Id, reason: reason)
            let error = Self.goneError(db3Id, reason)
            deps.emit(event)
            for handle in list {
                handle.subscription.deliver(.gone(event))
                // A mark the store kept from before is no answer of the room's
                // to these subscriptions: the open's own answer settles them.
                if outdated || refusedByRoom { handle.subscription.reject(error) }
            }
        } else if announce != nil {
            // Gone for another reason, then deleted: announced once more (#5091).
            let event = Db3GoneEvent(id: db3Id, reason: .deleted)
            deps.emit(event)
            for handle in list {
                handle.subscription.deliver(.gone(event))
                if refusedByRoom { handle.subscription.reject(Self.deletedRefused(db3Id)) }
            }
        } else if state.phase == .gone && outdated {
            // Subscribed again since: the room's answer is the same.
            for handle in list { handle.subscription.reject(Self.clientOutdated(db3Id)) }
        }
        // Read again now: a state read before the user changed, or before a
        // release began, is no answer to a subscription made since.
        if state.resident, isResidentNow(db3Id) { for handle in list { handle.subscription.resolveAvailable() } }
        if state.phase == .live && open && !deps.identityPending() { for handle in list { settleReady(handle) } }
    }
}
