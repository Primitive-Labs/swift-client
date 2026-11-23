import Foundation

/// When a refusal's fetch runs, on the JavaScript client's schedule. The
/// first refusal fetches at once. A refusal within `window` of the previous
/// one waits `initialDelay`, doubling with each such refusal to at most
/// `maxDelay`; a longer gap starts over.
///
/// The bound exists because the policy route reads the app row directly while
/// the server's refusal reads a cache that can be up to a minute stale: after
/// a minimum is lowered, a refused client can fetch "fine", reconnect, and be
/// refused again, and without a bound it would loop at network speed.
struct RefusalFetchBackoff: Sendable {
    static let window: TimeInterval = 60
    static let initialDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 60

    private var lastRefusalAt: Date?
    private var nextDelay = RefusalFetchBackoff.initialDelay

    /// The delay before the fetch of a refusal that arrives at `now`.
    mutating func delay(forRefusalAt now: Date) -> TimeInterval {
        defer { lastRefusalAt = now }
        guard let lastRefusalAt, now.timeIntervalSince(lastRefusalAt) < Self.window else {
            nextDelay = Self.initialDelay
            return 0
        }
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, Self.maxDelay)
        return delay
    }
}

/// The state behind `client.appVersion`: whether the app has asked, the last
/// policy, whether the server refused this client, the status last reported,
/// and the subscribers. Fetches `GET /settings/client-versions` through the
/// client's gated transport, one at a time.
///
/// Nothing is fetched until the first ask (`status()`, `policy()`, `refresh()`
/// or a subscription) or a refusal. From then on the policy is refetched a
/// random wait (up to `reconnectJitter`) after each socket reconnect, on each
/// return to the foreground and every `periodicInterval`. A refusal sets `updateRequired` at once and holds every
/// automatic connect (`isRefused`) until a fetch computes another status. The
/// refusal is held in memory only; the policy is stored on each successful
/// fetch and read back by the next client on the same store.
final class AppVersionController: @unchecked Sendable {

    typealias Handler = @Sendable (AppVersionStatus) -> Void

    static let defaultPeriodicInterval: TimeInterval = 3600
    /// The longest wait before the fetch that follows a socket reconnect. The
    /// wait is random, so clients that reconnect together (after a deploy,
    /// say) do not all fetch the policy at once.
    static let defaultReconnectJitter: TimeInterval = 30
    /// How long a first ask with no stored policy waits for its fetch.
    static let firstFetchWait: TimeInterval = 10
    static let path = "/settings/client-versions"
    /// The return-to-foreground notifications, by name so the client imports
    /// no UI framework: UIKit's and AppKit's `didBecomeActive`.
    static let foregroundNotifications = [
        Notification.Name("UIApplicationDidBecomeActiveNotification"),
        Notification.Name("NSApplicationDidBecomeActiveNotification"),
    ]

    let identity: ClientIdentity
    private let appId: String
    private let transport: any Transport
    private let offlineStore: OfflineStore
    private let waitForStorage: @Sendable () async -> Void
    private let logger: Logger

    private let lock = NSLock()
    // Guarded by `lock`.
    private var startTask: Task<Void, Never>?
    private var initialFetch: Task<Bool, Never>?
    private var inFlight: Task<Bool, Never>?
    private var periodicTask: Task<Void, Never>?
    private var refusalFetchTask: Task<Void, Never>?
    private var reconnectFetchTask: Task<Void, Never>?
    private var policy: ClientVersionPolicyRecord?
    private var refused = false
    private var status: AppVersionStatus = .unknown
    /// This platform's entry and the refusal as last reported, beside `status`.
    private var reportedEntry: ClientPlatformVersions?
    private var reportedRefused = false
    private var handlers: [UUID: Handler] = [:]
    /// Reported changes not yet delivered, in the order they were committed.
    /// Drained by one thread at a time (`draining`), outside the lock.
    private var pendingChanges: [AppVersionStatus] = []
    private var draining = false
    private var beforeDrain: (@Sendable () -> Void)?
    private var backoff = RefusalFetchBackoff()
    private var refusalFetchDelay: TimeInterval?
    private var destroyed = false
    private var interval = AppVersionController.defaultPeriodicInterval
    private var jitter = AppVersionController.defaultReconnectJitter
    private var draw: @Sendable () -> Double = { Double.random(in: 0..<1) }
    private var now: @Sendable () -> Date = { Date() }
    private var onRelease: (@Sendable () -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// The last storage step (policy load or write), chained so the steps run
    /// one after another. None starts once destroyed, so awaiting this one
    /// drains them all before the client closes its storage.
    private var storageTail: Task<Void, Never>?

    init(
        identity: ClientIdentity,
        appId: String,
        transport: any Transport,
        offlineStore: OfflineStore,
        logger: Logger,
        waitForStorage: @escaping @Sendable () async -> Void
    ) {
        self.identity = identity
        self.appId = appId
        self.transport = transport
        self.offlineStore = offlineStore
        self.logger = logger.forScope(scope: "app-version")
        self.waitForStorage = waitForStorage
        let center = NotificationCenter.default
        let tokens = Self.foregroundNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.refetchIfTracking()
            }
        }
        lock.withLock { observers = tokens }
    }

    // MARK: - Reads

    /// Whether the server refused this client and no fetch has released it.
    /// Synchronous, for the socket manager's connect decision.
    var isRefused: Bool { lock.withLock { refused } }

    /// The status last reported, without asking.
    var reportedStatus: AppVersionStatus { lock.withLock { status } }

    /// The refetch period. Test seam; production keeps the default.
    var periodicInterval: TimeInterval {
        get { lock.withLock { interval } }
        set { lock.withLock { interval = newValue } }
    }

    /// The longest wait before a reconnect's fetch; 0 fetches at once. Test
    /// seam; production keeps the default.
    var reconnectJitter: TimeInterval {
        get { lock.withLock { jitter } }
        set { lock.withLock { jitter = newValue } }
    }

    /// Test seam for the share of `reconnectJitter` a reconnect waits, in 0..<1.
    func setReconnectDrawForTest(_ draw: @escaping @Sendable () -> Double) {
        lock.withLock { self.draw = draw }
    }

    /// The delay the last refusal put before its fetch.
    var lastRefusalFetchDelay: TimeInterval? { lock.withLock { refusalFetchDelay } }

    /// Test seam for the refusal backoff's clock.
    func setClockForTest(_ clock: @escaping @Sendable () -> Date) {
        lock.withLock { now = clock }
    }

    /// Test seam: runs each time a committed change is about to be delivered,
    /// outside the lock, before the delivering thread is chosen.
    func setBeforeDrainForTest(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { beforeDrain = hook }
    }

    /// Called after a fetch releases a refusal; the client reconnects from it.
    func setReleaseHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onRelease = handler }
    }

    // MARK: - Asking

    /// The status. The first call is the first ask: it waits for storage,
    /// reports from the stored policy at once when there is one (the fetch runs
    /// behind it), and otherwise waits up to `firstFetchWait` for one fetch.
    func currentStatus() async -> AppVersionStatus {
        guard let start = startTracking(fetch: true) else { return reportedStatus }
        await start.value
        let pending: Task<Bool, Never>? = lock.withLock {
            guard policy == nil, !refused else { return nil }
            return initialFetch ?? inFlight
        }
        if let pending { await Self.wait(for: pending, atMost: Self.firstFetchWait) }
        return reportedStatus
    }

    /// This client's platform entry in the policy, or `nil`. Also an ask.
    func currentPolicy() async -> ClientPlatformVersions? {
        _ = await currentStatus()
        return lock.withLock { identity.platform.flatMap { policy?.clients[$0] } }
    }

    /// Fetch now and return the status; a failed fetch leaves it unchanged.
    func refresh() async -> AppVersionStatus {
        guard let start = startTracking(fetch: false) else { return reportedStatus }
        await start.value
        _ = await beginFetch()?.value
        return reportedStatus
    }

    /// Call `handler` with the status each time the status, this platform's
    /// entry or the refusal changes. Also an ask.
    func onStatusChange(_ handler: @escaping Handler) -> EventSubscription {
        let id = UUID()
        lock.withLock {
            if !destroyed { handlers[id] = handler }
        }
        startTracking(fetch: true)
        return EventSubscription { [weak self] in
            guard let self else { return }
            // Release the handler only after unlocking: it may hold the last
            // reference to a subscriber whose deinit cancels another
            // subscription here, which takes this lock again.
            let removed = self.lock.withLock { self.handlers.removeValue(forKey: id) }
            _ = removed
        }
    }

    // MARK: - Causes

    /// The server refused this client (an HTTP 426 with `CLIENT_UPDATE_REQUIRED`
    /// or a 4426 close). Sets `updateRequired` at once, asked or not, and
    /// schedules one fetch on the bounded schedule. A refusal while already
    /// refused changes nothing.
    func noteRefusal() {
        let decided: TimeInterval? = lock.withLock {
            guard !destroyed, !refused else { return nil }
            refused = true
            let delay = backoff.delay(forRefusalAt: now())
            refusalFetchDelay = delay
            publishLocked()
            return delay
        }
        guard let delay = decided else { return }
        logger.warn("The server refused this client as outdated; holding automatic connects", identity.version ?? "")
        drainChanges()
        let start = startTracking(fetch: false)
        let task = Task { [weak self] in
            await start?.value
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            _ = await self.beginFetch()?.value
        }
        lock.withLock {
            refusalFetchTask?.cancel()
            refusalFetchTask = destroyed ? nil : task
        }
    }

    /// The socket reconnected: once the app has asked, refetch after a random
    /// wait of up to `reconnectJitter`. Reconnects inside one wait share its
    /// fetch, and a fetch that starts sooner for another reason replaces it.
    func socketReconnected() {
        let wait: TimeInterval? = lock.withLock {
            guard startTask != nil, !destroyed, reconnectFetchTask == nil else { return nil }
            let seconds = max(0, jitter) * draw()
            guard seconds > 0 else { return 0 }
            reconnectFetchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.lock.withLock { self.reconnectFetchTask = nil }
                _ = self.beginFetch()
            }
            return seconds
        }
        if wait == 0 { _ = beginFetch() }
    }

    /// The app came back to the foreground: refetch, once the app has asked.
    func refetchIfTracking() {
        let tracking = lock.withLock { startTask != nil && !destroyed }
        if tracking { _ = beginFetch() }
    }

    /// Stop everything: no fetch, no timer, no handler from here on.
    func destroy() {
        let (fetches, tasks, tokens, released): ([Task<Bool, Never>], [Task<Void, Never>], [NSObjectProtocol], [UUID: Handler]) = lock.withLock {
            destroyed = true
            // Handed out and released after unlocking, as in cancellation.
            let released = handlers
            handlers = [:]
            pendingChanges = []
            let fetches = [inFlight, initialFetch].compactMap { $0 }
            let tasks = [periodicTask, refusalFetchTask, reconnectFetchTask, startTask].compactMap { $0 }
            inFlight = nil
            initialFetch = nil
            periodicTask = nil
            refusalFetchTask = nil
            reconnectFetchTask = nil
            let tokens = observers
            observers = []
            return (fetches, tasks, tokens, released)
        }
        _ = released
        fetches.forEach { $0.cancel() }
        tasks.forEach { $0.cancel() }
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Wait for the storage step under way, if any. After `destroy()` no new
    /// step starts, so the client calls this before it closes its storage: a
    /// write left behind would reopen the store and could overwrite the policy
    /// a later client on the same store has saved.
    func awaitPendingPersistence() async {
        let tail = lock.withLock { storageTail }
        await tail?.value
    }

    deinit {
        let tokens = lock.withLock { observers }
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Tracking

    /// Turn tracking on, once: wait for storage, report from the stored
    /// policy, start the periodic refetch and, when `fetch`, the first fetch.
    @discardableResult
    private func startTracking(fetch: Bool) -> Task<Void, Never>? {
        lock.withLock {
            if destroyed { return nil }
            if let startTask { return startTask }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.waitForStorage()
                let (store, appId) = (self.offlineStore, self.appId)
                let stored = await self.storageStep { await store.loadClientVersions(appId: appId) } ?? nil
                self.lock.withLock {
                    guard !self.destroyed else { return }
                    if self.policy == nil, let stored { self.policy = stored }
                    self.publishLocked()
                }
                self.drainChanges()
                self.startPeriodic()
                if fetch {
                    let first = self.beginFetch()
                    self.lock.withLock { self.initialFetch = first }
                }
            }
            startTask = task
            return task
        }
    }

    private func startPeriodic() {
        lock.withLock {
            guard !destroyed, periodicTask == nil else { return }
            let seconds = max(0.01, interval)
            periodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    _ = await self.beginFetch()?.value
                }
            }
        }
    }

    // MARK: - Fetching

    /// The fetch in flight, or a new one. `nil` once destroyed.
    private func beginFetch() -> Task<Bool, Never>? {
        lock.withLock {
            if destroyed { return nil }
            if let inFlight { return inFlight }
            // This fetch stands in for one a reconnect is still waiting on.
            reconnectFetchTask?.cancel()
            reconnectFetchTask = nil
            let task = Task { [weak self] () -> Bool in
                guard let self else { return false }
                let fetched = await self.fetchOnce()
                self.lock.withLock { self.inFlight = nil }
                return fetched
            }
            inFlight = task
            return task
        }
    }

    /// One fetch. A transport error, a non-2xx answer or a body that is not a
    /// policy changes nothing.
    private func fetchOnce() async -> Bool {
        let response: TransportResponse
        do {
            response = try await transport.execute(method: .get, path: Self.path, body: nil, options: nil)
        } catch {
            logger.debug("Version policy fetch failed:", error.localizedDescription)
            return false
        }
        guard (200..<300).contains(response.status),
              let record = ClientVersionPolicyRecord.decode(from: response.body) else {
            logger.debug("Version policy fetch answered", response.status)
            return false
        }
        guard !Task.isCancelled, apply(record) else { return false }
        // `apply` delivered to subscribers, so the client may have been
        // destroyed since; `storageStep` writes nothing in that case.
        let (store, appId) = (offlineStore, self.appId)
        let written: Void? = await storageStep { await store.persistClientVersions(appId: appId, record: record) }
        return written != nil
    }

    /// Run `body` against storage after the previous step, unless destroyed;
    /// `nil` when it did not run. Registered under the lock that `destroy()`
    /// takes, so `awaitPendingPersistence()` sees every step that started.
    private func storageStep<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
        let step: Task<T, Never>? = lock.withLock {
            guard !destroyed else { return nil }
            let previous = storageTail
            let task = Task { () -> T in
                await previous?.value
                return await body()
            }
            storageTail = Task { _ = await task.value }
            return task
        }
        return await step?.value
    }

    /// Take a fetched policy: report from it, and release a refusal when it
    /// computes anything other than `updateRequired`.
    private func apply(_ record: ClientVersionPolicyRecord) -> Bool {
        let outcome: (applied: Bool, release: (@Sendable () -> Void)?) = lock.withLock {
            guard !destroyed else { return (false, nil) }
            policy = record
            var release: (@Sendable () -> Void)?
            let computed = ClientVersionRules.clientVersionStatus(
                version: identity.version, platform: identity.platform, policy: record
            )
            if refused, computed != .updateRequired {
                refused = false
                release = onRelease ?? {}
            }
            publishLocked()
            return (true, release)
        }
        guard outcome.applied else { return false }
        drainChanges()
        if let release = outcome.release {
            logger.log("The version policy no longer requires an update; automatic connects resume")
            release()
        }
        return true
    }

    // MARK: - Reporting

    /// Commit what to report now (the status, this platform's entry and the
    /// refusal) and, when any of it changed, queue the status for delivery in
    /// this same critical section, so changes reach subscribers in the order
    /// they were committed. The JavaScript client calls its listeners on the
    /// same changes, so a raised `latest` that keeps the status reaches both.
    private func publishLocked() {
        let next: AppVersionStatus = refused
            ? .updateRequired
            : ClientVersionRules.clientVersionStatus(version: identity.version, platform: identity.platform, policy: policy)
        // Without a version there is nothing to compare, so no entry is reported.
        let entry = identity.version == nil ? nil : identity.platform.flatMap { policy?.clients[$0] }
        guard next != status || entry != reportedEntry || refused != reportedRefused else { return }
        status = next
        reportedEntry = entry
        reportedRefused = refused
        pendingChanges.append(next)
    }

    /// Deliver queued changes, oldest first, outside the lock. One thread
    /// drains at a time; a change committed meanwhile is picked up by the
    /// thread already draining. The handlers are read per change, so a
    /// cancelled or destroyed subscription is not called afterwards.
    private func drainChanges() {
        lock.withLock { beforeDrain }?()
        let claimed: Bool = lock.withLock {
            guard !draining, !pendingChanges.isEmpty else { return false }
            draining = true
            return true
        }
        guard claimed else { return }
        while true {
            let next: (status: AppVersionStatus, handlers: [Handler])? = lock.withLock {
                guard !pendingChanges.isEmpty else {
                    draining = false
                    return nil
                }
                return (pendingChanges.removeFirst(), Array(handlers.values))
            }
            guard let next else { return }
            for handler in next.handlers { handler(next.status) }
        }
    }

    /// Wait for `task`, or for `seconds`, whichever ends first.
    private static func wait(for task: Task<Bool, Never>, atMost seconds: TimeInterval) async {
        let resumed = FirstOnly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                _ = await task.value
                if resumed.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if resumed.claim() { continuation.resume() }
            }
        }
    }
}

/// True for the first `claim()` only.
private final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Hands a refusal seen by the transports to the controller, which is built
/// after them.
final class UpdateRequiredRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var controller: AppVersionController?

    func attach(_ controller: AppVersionController) {
        lock.withLock { self.controller = controller }
    }

    func fire() {
        lock.withLock { controller }?.noteRefusal()
    }
}

/// The client's storage readiness, for the controller, which is built before
/// the client can be referenced.
final class StorageReadyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private weak var client: JsBaoClient?

    func attach(_ client: JsBaoClient) {
        lock.withLock { self.client = client }
    }

    func wait() async {
        let client = lock.withLock { self.client }
        _ = await client?.waitForStorageReady(timeout: AppVersionController.firstFetchWait)
    }
}
