import Foundation

/// The client's channel memberships (#3278): the grants it holds, the joins
/// waiting for the server's answer, the per-channel generation that a leave
/// bumps, and the per-channel chain that serializes joins. Swift port of the
/// bookkeeping the JS client keeps in `channelGrants` /
/// `pendingChannelSubscribes` / `channelEpochs` / `channelSubscribeChain`
/// (`src/client/JsBaoClient.ts`, #3184).
///
/// Self-contained and synchronous, in the shape of
/// `DatabaseSubscriptionRegistry`: it never touches the network. `JsBaoClient`
/// sends the frames, decides the outcomes, and resumes the continuations this
/// registry hands back — always OUTSIDE the lock, so a resumed caller that
/// subscribes again from its continuation cannot deadlock against the
/// non-recursive `NSLock`.
///
/// Where the JS bookkeeping relies on the event loop to make a sequence of
/// map operations atomic, this registry gives the sequence one method and
/// one critical section (`reserveChain`, `leave`, `destroy`): the Swift
/// client is called from arbitrary tasks, so two `subscribeToChannel` calls
/// for the same channel really can interleave.
///
/// ## `@unchecked Sendable` safety argument
///
/// Every mutable field is `lock`-confined and `private`; there is no second
/// lock and no `await` anywhere, so no lock is ever held across a suspension.
/// The stored values are `Sendable` on their own: `HeldGrant` is a value,
/// `PendingJoin` carries a `CheckedContinuation` over `Sendable` types and a
/// `Task`, and the chains are `Task`s. No registry-owned state escapes by
/// reference — every accessor returns copies, and `take*` hands ownership of
/// the pending joins to the caller, which is the only one that resumes them.
final class ChannelMembershipRegistry: @unchecked Sendable {
    /// A grant the client presents on connect. `expiresAt` is epoch
    /// milliseconds, `0` until the server's ack supplies it.
    struct HeldGrant: Sendable, Equatable {
        let grant: String
        var expiresAt: Int
    }

    /// One `subscribeToChannel` call waiting for the server's answer.
    final class PendingJoin: @unchecked Sendable {
        let id = UUID()
        let grant: String
        let continuation: CheckedContinuation<ChannelSubscription, Error>
        /// Whether this attempt's frame has gone out. A join made while the
        /// socket was down registers and waits; the open flush claims the
        /// send. Guarded by the registry's lock.
        var sent: Bool
        /// The 20 s ack timer. Guarded by the registry's lock.
        var timeoutTask: Task<Void, Never>?

        init(grant: String, continuation: CheckedContinuation<ChannelSubscription, Error>, sent: Bool) {
            self.grant = grant
            self.continuation = continuation
            self.sent = sent
        }
    }

    private let lock = NSLock()
    private var grants: [String: HeldGrant] = [:]
    private var pending: [String: [PendingJoin]] = [:]
    private var epochs: [String: Int] = [:]
    private var chains: [String: Task<Void, Never>] = [:]
    /// Set once by `destroy()` and never cleared: the generation every
    /// channel is in after the client is gone. A queued attempt that wakes
    /// during teardown finds it and gives up, and `addPending` refuses to
    /// park a caller nobody will ever resume (JS: R3184-005, where `destroy`
    /// bumps every channel's epoch).
    private var _isDestroyed = false

    var isDestroyed: Bool {
        lock.withLock { _isDestroyed }
    }

    // MARK: - Grants

    /// No-op once destroyed: a grant registered on the way down would be
    /// re-presented by nobody and would outlive the client that held it.
    func setGrant(_ channel: String, grant: String) {
        lock.withLock {
            guard !_isDestroyed else { return }
            grants[channel] = HeldGrant(grant: grant, expiresAt: 0)
        }
    }

    /// Keep a grant the socket carried away, unless a newer one arrived.
    func setGrantIfAbsent(_ channel: String, grant: String) {
        lock.withLock {
            guard !_isDestroyed else { return }
            if grants[channel] == nil { grants[channel] = HeldGrant(grant: grant, expiresAt: 0) }
        }
    }

    func removeGrant(_ channel: String) {
        lock.withLock { _ = grants.removeValue(forKey: channel) }
    }

    /// The server's ack carries the membership's expiry; store it on the
    /// grant it answered, if that grant is still held.
    func updateExpiresAt(_ channel: String, expiresAt: Int) {
        lock.withLock { grants[channel]?.expiresAt = expiresAt }
    }

    func heldGrant(for channel: String) -> HeldGrant? {
        lock.withLock { grants[channel] }
    }

    /// A snapshot, so the reconnect pass can register as it goes.
    func heldGrants() -> [(channel: String, grant: HeldGrant)] {
        lock.withLock { grants.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 } }
    }

    // MARK: - Epochs and chains

    func epoch(_ channel: String) -> Int {
        lock.withLock { epochs[channel] ?? 0 }
    }

    /// Whether an attempt queued in `epoch` may still run: the channel has
    /// not been left since, and the client has not been destroyed. One read
    /// under the lock, so the two cannot disagree.
    func isCurrent(_ channel: String, epoch: Int) -> Bool {
        lock.withLock { !_isDestroyed && (epochs[channel] ?? 0) == epoch }
    }

    /// Queue one attempt behind the channel's chain, in ONE critical section:
    /// `make` receives the generation and the predecessor and returns the
    /// attempt, and the replacement chain is installed before the lock is
    /// released. Reading the predecessor and installing the replacement
    /// separately would let two concurrent `subscribeToChannel` calls for the
    /// same channel read the same predecessor and both send, so the first
    /// answer would settle both (CSO-001 on #3278).
    ///
    /// `make` only creates a `Task`, which never blocks; the task body takes
    /// this lock again, from another thread, after this section ends.
    func reserveChain<Outcome: Sendable>(
        _ channel: String,
        _ make: (_ epoch: Int, _ previous: Task<Void, Never>?) -> Task<Outcome, Error>
    ) -> Task<Outcome, Error> {
        lock.withLock {
            let attempt = make(epochs[channel] ?? 0, chains[channel])
            chains[channel] = Task { _ = try? await attempt.value }
            return attempt
        }
    }

    /// `unsubscribeFromChannel`'s bookkeeping, in one critical section: the
    /// grant and the chain go, the generation is bumped so a queued attempt
    /// gives up, and every join waiting on the channel is handed back for the
    /// caller to reject. Atomic so a subscribe racing the leave sees either
    /// the old generation with its chain or the new one with none.
    func leave(_ channel: String) -> [PendingJoin] {
        let taken: [PendingJoin] = lock.withLock {
            grants.removeValue(forKey: channel)
            chains.removeValue(forKey: channel)
            epochs[channel] = (epochs[channel] ?? 0) + 1
            return pending.removeValue(forKey: channel) ?? []
        }
        for join in taken { join.timeoutTask?.cancel() }
        return taken
    }

    // MARK: - Pending joins

    /// Park one caller. `false` once destroyed — the caller must resume its
    /// own continuation then, because `destroy()` has already handed out
    /// everything it will ever resume, and a join added afterwards would
    /// hang its caller forever (CSO-003 on #3278).
    func addPending(_ channel: String, _ join: PendingJoin) -> Bool {
        lock.withLock {
            guard !_isDestroyed else { return false }
            pending[channel, default: []].append(join)
            return true
        }
    }

    /// Claim the send for one attempt: `true` exactly once per join, so the
    /// open flush and the caller's own send can race without sending twice.
    func claimSend(_ channel: String, id: UUID) -> Bool {
        lock.withLock {
            guard let join = pending[channel]?.first(where: { $0.id == id }), !join.sent else { return false }
            join.sent = true
            return true
        }
    }

    func setTimeoutTask(_ channel: String, id: UUID, _ task: Task<Void, Never>) {
        lock.withLock {
            guard let join = pending[channel]?.first(where: { $0.id == id }) else {
                task.cancel()
                return
            }
            join.timeoutTask = task
        }
    }

    /// Remove and return every join waiting on one channel; their timers are
    /// cancelled here so the caller only has to resume them.
    func takePending(_ channel: String) -> [PendingJoin] {
        let taken = lock.withLock { pending.removeValue(forKey: channel) ?? [] }
        for join in taken { join.timeoutTask?.cancel() }
        return taken
    }

    /// Remove and return every pending join on every channel, and drop every
    /// chain with them: the socket that would have carried their answers is
    /// gone.
    func takeAllPending() -> [(channel: String, joins: [PendingJoin])] {
        let taken: [(String, [PendingJoin])] = lock.withLock {
            let all = pending.map { ($0.key, $0.value) }
            pending.removeAll()
            chains.removeAll()
            return all
        }
        for (_, joins) in taken {
            for join in joins { join.timeoutTask?.cancel() }
        }
        return taken
    }

    /// Claim the send for every join that never reached the wire, per channel,
    /// returning the newest such grant for each — the one the caller most
    /// recently asked for.
    func claimUnsentSends() -> [(channel: String, grant: String)] {
        lock.withLock {
            var flushed: [(String, String)] = []
            for (channel, joins) in pending.sorted(by: { $0.key < $1.key }) {
                let unsent = joins.filter { !$0.sent }
                guard let newest = unsent.last else { continue }
                for join in unsent { join.sent = true }
                flushed.append((channel, newest.grant))
            }
            return flushed
        }
    }

    var hasPendingJoins: Bool {
        lock.withLock { pending.values.contains { !$0.isEmpty } }
    }

    /// `destroy()`: mark the registry destroyed, take every pending join and
    /// forget everything else, in ONE critical section. Marking and draining
    /// together is what makes the hand-off complete: an attempt that checks
    /// `isCurrent` or calls `addPending` after this section finds the registry
    /// destroyed and rejects its own caller, and one that registered before
    /// it is in the returned list. Every continuation is therefore resumed
    /// exactly once, by exactly one party. Permanent: nothing re-opens it.
    func destroy() -> [(channel: String, joins: [PendingJoin])] {
        let taken: [(String, [PendingJoin])] = lock.withLock {
            _isDestroyed = true
            let all = pending.map { ($0.key, $0.value) }
            pending.removeAll()
            grants.removeAll()
            epochs.removeAll()
            chains.removeAll()
            return all
        }
        for (_, joins) in taken {
            for join in joins { join.timeoutTask?.cancel() }
        }
        return taken
    }
}
