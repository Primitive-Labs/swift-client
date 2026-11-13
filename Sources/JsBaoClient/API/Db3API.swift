import Foundation

/// The options of `client.db3.subscribe(_:options:)` and `client.db3.refresh(_:options:)`.
public struct Db3SubscribeOptions: Sendable {
    /// How long `ready()` waits without progress before it throws
    /// `DB3_READY_TIMEOUT`, in seconds (30 by default). Each chunk or page that
    /// arrives starts the wait again; `.infinity` waits for as long as it
    /// takes, and `0` throws at once unless the db3 is already live here.
    /// - Stability: beta
    public var readyTimeout: TimeInterval

    public init(readyTimeout: TimeInterval = 30) {
        self.readyTimeout = readyTimeout
    }
}

/// The options of `client.db3.evict(_:options:)`.
public struct Db3EvictOptions: Sendable {
    /// Remove the db3 even while it holds writes the room has not judged. They
    /// are handed back through `Db3WriteRefusedEvent` as `DOCUMENT_STORE_PURGED`.
    /// - Stability: beta
    public var force: Bool

    public init(force: Bool = false) {
        self.force = force
    }
}

/// One db3 this device holds, as `client.db3.stored()` lists it.
public struct Db3StoredEntry: Sendable, Equatable {
    /// - Stability: beta
    public let id: String
    /// How many records the local copy holds.
    /// - Stability: beta
    public let rows: Int
    /// The room's log number the copy has caught up to.
    /// - Stability: beta
    public let cursor: Int
    /// Writes made here the room has not judged yet.
    /// - Stability: beta
    public let pendingWrites: Int
    /// When a load or catch-up last completed here, or `nil`.
    /// - Stability: beta
    public let lastSyncAt: Date?
    /// Whether the copy is readable (see ``Db3State/resident``).
    /// - Stability: beta
    public let resident: Bool
    /// Whether it lives only on this device (see ``Db3State/localOnly``).
    /// - Stability: beta
    public let localOnly: Bool
    /// Its title as this device last heard it: from its create here, a rename
    /// (``Db3API/update(_:title:)`` here, or another device's, heard while
    /// connected with a direct grant), or a read; `nil` when the device holds none.
    /// - Stability: beta
    public let title: String?

    public init(
        id: String, rows: Int, cursor: Int, pendingWrites: Int, lastSyncAt: Date?, resident: Bool, localOnly: Bool = false,
        title: String? = nil
    ) {
        self.id = id
        self.rows = rows
        self.cursor = cursor
        self.pendingWrites = pendingWrites
        self.lastSyncAt = lastSyncAt
        self.resident = resident
        self.localOnly = localOnly
        self.title = title
    }
}

/// One event of a ``Db3Subscription``: the client's `db3:*` event of its db3.
public enum Db3SubscriptionEvent: Sendable {
    case state(Db3State)
    case ready(Db3ReadyEvent)
    case rows(Db3RowsEvent)
    case writeRefused(Db3WriteRefusedEvent)
    case evicted(Db3EvictedEvent)
    case gone(Db3GoneEvent)
    case error(Db3ErrorEvent)
}

/// A one-shot outcome any number of callers wait for: settled once, and every
/// later wait answers the same. `@unchecked Sendable`: its outcome and waiters
/// are read and written under `lock`, released before a waiter is resumed.
final class Db3Settlement: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// The outcome, or `nil` while unsettled.
    var result: Result<Void, Error>? { lock.withLock { outcome } }
    var isSettled: Bool { result != nil }

    /// Settle it; answers whether this call did (a settled one keeps its outcome).
    @discardableResult
    func settle(_ result: Result<Void, Error>) -> Bool {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Error>]? in
            guard outcome == nil else { return nil }
            outcome = result
            let all = waiters
            waiters = []
            return all
        }
        guard let woken else { return false }
        for waiter in woken { waiter.resume(with: result) }
        return true
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let now = lock.withLock { () -> Result<Void, Error>? in
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let now { continuation.resume(with: now) }
        }
    }
}

/// One caller's subscription to a db3, from `client.db3.subscribe(_:options:)`.
/// While any subscription of a db3 is held, this client keeps it up to date
/// with its room; `dispose()` gives this one up (the last one ends the room's
/// updates, and the local copy stays readable).
///
/// ```swift
/// let sub = try client.db3.subscribe(db3Id)
/// try await sub.available()   // a readable copy: the stored one, or the first load
/// let notes = try Note.query(nil, options: QueryOptions(documents: [db3Id]))
/// let watching = sub.observe { event in
///     if case .state(let state) = event { print(state.phase) }
/// }
/// sub.dispose()
/// ```
public final class Db3Subscription: @unchecked Sendable {
    // `@unchecked Sendable`: `disposed` and `listeners` are read and written
    // under `lock`; the settlements guard themselves.

    /// The db3.
    /// - Stability: beta
    public let id: String
    private let owner: Db3Lifecycle
    private let readySettlement = Db3Settlement()
    private let availableSettlement = Db3Settlement()
    private let lock = NSLock()
    private var disposed = false
    private var listeners: [UUID: @Sendable (Db3SubscriptionEvent) -> Void] = [:]

    init(id: String, owner: Db3Lifecycle) {
        self.id = id
        self.owner = owner
    }

    /// Returns when the db3 is first `live` after this subscribe. Throws
    /// `DB3_READY_TIMEOUT` (no progress within `readyTimeout`),
    /// `DB3_ACCESS_REFUSED` (the room refused access), `DB3_DISPOSED` (the
    /// subscription ended first) or `NOT_A_DB3` (the id is not a db3). A
    /// `DB3_DISPOSED` error says why in `details["reason"]`: `disposed`
    /// (`dispose()`), `destroyed` (the client was destroyed), `closed` (a
    /// document door closed the db3), `evicted` (its local copy was removed)
    /// or `identity-changed` (a sign-out, or another user's sign-in). Settles
    /// once: every later call answers the same.
    /// - Stability: beta
    public func ready() async throws {
        try await readySettlement.wait()
    }

    /// Returns as soon as a readable copy is on the device: at once for a
    /// resident db3 (an empty one that synced included), else when `ready()`
    /// does. Throws as `ready()` does until then.
    /// - Stability: beta
    public func available() async throws {
        try await availableSettlement.wait()
    }

    /// The db3's latest state, as this client last read it.
    /// - Stability: beta
    public var state: Db3State { owner.current(id) }

    /// This db3's events, from now on: each call answers a new stream,
    /// finished when its consumer stops iterating.
    /// - Stability: beta
    public func stream() -> AsyncStream<Db3SubscriptionEvent> {
        AsyncStream { continuation in
            let observation = observe { event in continuation.yield(event) }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    /// Hear this db3's events; cancel the answered subscription to stop.
    /// - Parameter handler: Called with each event, on the thread that emitted it.
    /// - Stability: beta
    public func observe(_ handler: @escaping @Sendable (Db3SubscriptionEvent) -> Void) -> EventSubscription {
        let token = UUID()
        lock.withLock { listeners[token] = handler }
        return EventSubscription { [weak self] in
            self?.lock.withLock { _ = self?.listeners.removeValue(forKey: token) }
        }
    }

    /// Give this subscription up. Disposing twice is disposing once.
    /// - Stability: beta
    public func dispose() {
        let first = lock.withLock { () -> Bool in
            guard !disposed else { return false }
            disposed = true
            return true
        }
        if first { owner.release(self) }
    }

    // MARK: - What the lifecycle settles it with

    /// `ready()`'s outcome, or `nil` while it waits.
    var readyResult: Result<Void, Error>? { readySettlement.result }
    /// `available()`'s outcome, or `nil` while it waits.
    var availableResult: Result<Void, Error>? { availableSettlement.result }
    var readySettled: Bool { readySettlement.isSettled }

    /// Resolve `ready()`, and `available()` if it has not settled.
    func resolveReady() {
        availableSettlement.settle(.success(()))
        readySettlement.settle(.success(()))
    }

    func resolveAvailable() {
        availableSettlement.settle(.success(()))
    }

    /// Fail whichever of `ready()` and `available()` has not settled.
    func reject(_ error: Error) {
        availableSettlement.settle(.failure(error))
        readySettlement.settle(.failure(error))
    }

    func deliver(_ event: Db3SubscriptionEvent) {
        let handlers = lock.withLock { Array(listeners.values) }
        for handler in handlers { handler(event) }
    }
}

/// The db3 API, as `client.db3`: a db3's lifecycle (create, get, delete, its
/// alias, sync, type, app access and custody), its sharing and blobs,
/// subscribing to it, and its copy on this device.
///
/// A db3 you create is on this device before the server has it. A call that
/// asks the server about it by its id (`get`, the sync, type, app-access and
/// custody calls, sharing, indexes and bulk loads) waits for that commit
/// first, so it can follow `create` at once. The wait throws the create's
/// refusal (its `HttpError`, `details.db3Id` in the body) when the server
/// refused it, and `JsBaoError(.pendingCreate)` (`details["db3Id"]`) instead
/// of waiting when the network mode is `.offline`, becomes `.offline`, or the
/// commit has not landed within 30 seconds. `subscribe(_:)`, `state(_:)`,
/// `evict(_:)`, `blobs(_:)` and `delete(_:)` do not wait; an upload made
/// before the commit lands stays queued until it does.
///
/// ```swift
/// let created = try await client.db3.create(title: "Orders", type: "orders")
/// let sub = try client.db3.subscribe(created.id)
/// try await sub.ready()
/// let state = try await client.db3.state(created.id)
/// sub.dispose()
/// ```
public final class Db3API: @unchecked Sendable {
    /// A db3's indexes: list, register and drop.
    /// - Stability: beta
    public let indexes: Db3IndexesAPI
    /// A db3's bulk loads: build, create, upload, commit, follow, abort and list.
    /// - Stability: beta
    public let ingests: Db3IngestsAPI
    /// A user's aliases for db3s: set, resolve and delete.
    /// - Stability: beta
    public let aliases: Db3AliasesAPI
    private let lifecycle: Db3Lifecycle
    private let transport: any Transport
    /// The client a created db3 is adopted into (#4806); `nil` adopts nothing.
    private weak var client: JsBaoClient?
    /// The client's upload queue and local blob copies, which `blobs(_:)`
    /// reaches the db3's blobs through.
    private let blobManager: BlobManager

    /// `blobManager` is the client's; without one, `blobs(_:)` uses a
    /// manager of this transport alone, with no storage.
    init(lifecycle: Db3Lifecycle, transport: any Transport, client: JsBaoClient? = nil, blobManager: BlobManager? = nil) {
        self.lifecycle = lifecycle
        self.transport = transport
        self.client = client
        self.blobManager = blobManager ?? BlobManager(logger: createLogger(level: .error, scope: "db3"), transport: transport)
        let awaitCreate: @Sendable (String) async throws -> Void = { [weak client] db3Id in
            try await client?.awaitPendingDb3Create(db3Id)
        }
        self.indexes = Db3IndexesAPI(
            transport: transport, awaitCreate: awaitCreate,
            applyLocally: { [weak client] db3Id in try await client?.refreshDb3IndexesIfHeldOpen(db3Id) },
            local: Db3LocalIndexDoor(
                isLocalOnly: { [weak client] db3Id in await client?.isLocalOnlyDb3(db3Id) ?? false },
                list: { [weak client] db3Id in try await client?.localDb3Indexes(db3Id) ?? [] },
                register: { [weak client] db3Id, registration in
                    guard let client else { throw JsBaoError(code: .db3NotResident, message: "the db3 '\(db3Id)' is not on this device") }
                    return try await client.registerLocalDb3Index(db3Id, registration)
                },
                drop: { [weak client] db3Id, name in try await client?.dropLocalDb3Index(db3Id, name: name) }
            ),
            device: Db3DeviceIndexDoor(
                list: { [weak client] db3Id in
                    guard let client else { throw db3NotResidentError([db3Id]) }
                    return try await client.deviceDb3Indexes(db3Id)
                },
                skipped: { [weak client] db3Id in
                    guard let client else { throw db3NotResidentError([db3Id]) }
                    return try await client.deviceDb3IndexSkips(db3Id)
                },
                change: { [weak client] db3Id, name, decline in
                    guard let client else { throw db3NotResidentError([db3Id]) }
                    return try await client.changeDeviceDb3Index(db3Id, name: name, decline: decline)
                }
            )
        )
        self.ingests = Db3IngestsAPI(transport: transport, awaitCreate: awaitCreate)
        self.aliases = Db3AliasesAPI(transport: transport, awaitCreate: awaitCreate)
    }

    /// #5000 — before a request naming `db3Id`, wait for a pending create of
    /// it to commit (`JsBaoClient.awaitPendingDb3Create`); a `Db3API` with no
    /// wired client has none to wait for.
    private func awaitCreate(_ db3Id: String) async throws {
        try await client?.awaitPendingDb3Create(db3Id)
    }

    /// Subscribe to a db3: this client keeps it up to date with its room
    /// while any subscription is held. Answers at once; await `ready()` for
    /// `live`, or `available()` for a readable copy. A db3 not yet on the
    /// device is loaded (a cold load); one already here catches up from where
    /// it left off.
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - options: How long `ready()` waits without progress.
    /// - Throws: `DB3_DISPOSED` once the client was destroyed;
    ///   `INVALID_ARGUMENT` for an empty id.
    /// - Stability: beta
    public func subscribe(_ db3Id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) throws -> Db3Subscription {
        try lifecycle.subscribe(db3Id, options: options)
    }

    /// Dispose every subscription this client holds to a db3. The local copy stays readable.
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func unsubscribe(_ db3Id: String) {
        lifecycle.unsubscribe(db3Id)
    }

    /// Bring a db3's local copy up to date once: subscribe, wait for `live`,
    /// dispose. Another caller's subscription is left as it is. Answers the
    /// db3's state afterwards.
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - options: How long it waits without progress.
    /// - Stability: beta
    public func refresh(_ db3Id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) async throws -> Db3State {
        try await lifecycle.refresh(db3Id, options: options)
    }

    /// Remove a db3's local copy from this device, disposing this client's
    /// subscriptions to it (each hears `evicted`). A db3 never stored here
    /// returns with nothing to do.
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - options: `force` to drop writes the room has not judged; they are
    ///     handed back as `DOCUMENT_STORE_PURGED`.
    /// - Throws: `DB3_PENDING_WRITES` while it holds unjudged writes, unless `force`.
    /// - Stability: beta
    public func evict(_ db3Id: String, options: Db3EvictOptions = Db3EvictOptions()) async throws {
        try await lifecycle.evict(db3Id, options: options)
    }

    /// Every db3 this device holds for the signed-in user, with its size and sync state, sorted by id.
    /// - Stability: beta
    public func stored() async throws -> [Db3StoredEntry] {
        try await lifecycle.stored()
    }

    /// A db3's state on this device, without subscribing. A db3 never seen
    /// here answers `idle`, not resident, with nothing stored.
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func state(_ db3Id: String) async throws -> Db3State {
        try await lifecycle.state(db3Id)
    }

    /// Set the client's retention policy (the one `client.retentionPolicy`
    /// holds): what the device keeps, and for how long. A db3 holding
    /// unjudged writes, or one subscribed here, is never removed by it.
    /// - Parameter policy: The policy.
    /// - Throws: `JsBaoError` `.invalidArgument` when `maxDocs` is `0` or a
    ///   negative (pass `nil` for no cap), or `ttl` is `0`, a negative or not
    ///   finite (pass `nil` for no TTL); the policy stays as it was.
    /// - Stability: beta
    public func setRetentionPolicy(_ policy: RetentionPolicy) throws {
        if let refusal = policy.refusal(call: "client.db3.setRetentionPolicy") { throw refusal }
        lifecycle.setRetentionPolicy(policy)
    }

    // MARK: - Lifecycle

    private static func path(_ db3Id: String, _ rest: String = "") -> String {
        "/db3/\(URLEncoding.encodeComponent(db3Id))\(rest)"
    }

    /// Create a db3 and answer it.
    ///
    /// A db3 you hold with sync on and no `custodian` is created on this
    /// device: the client mints its id and the call returns at once, with
    /// networking on or off, `state.pendingCreate` true. Its models save and
    /// query right away, `stored()` lists it, and the first `subscribe(_:)`
    /// sends those writes. The client commits it to the server in the
    /// background (at once with networking on, otherwise when it is back),
    /// retried with backoff, and `Db3CreatedEvent` fires once the server has
    /// it; with `type`, the type's current revision is installed then. A
    /// refusal only the server can decide (`DB3_TYPE_NOT_FOUND`,
    /// `DB3_TYPE_REFUSED`, a quota, a taken id) does not throw: it arrives as
    /// `Db3CreateFailedEvent` naming the db3's `id`, and the rows stay
    /// readable until `commitOfflineCreate(documentId:)` succeeds or a forced
    /// evict removes them.
    ///
    /// To wait for the server's answer, call
    /// `client.documents.commitOfflineCreate(documentId:)`. It answers
    /// `created: true` once the server has the db3, `refused: true` with the
    /// `reason` when the server refused it, and `reason: "not_pending"` when
    /// the commit had already landed; a failure the client keeps retrying
    /// throws. `client.isPendingCreate(_:)` tells whether it has landed. The
    /// `client.db3` calls that ask the server about the db3 wait for the
    /// commit on their own.
    ///
    /// A sync-off create (an app owner or admin) or one naming a `custodian`
    /// waits for the server: it answers the route's db3, fires
    /// `Db3CreatedEvent` before it returns, and a refusal throws the route's
    /// `HttpError` and fires `Db3CreateFailedEvent`. A sync-off db3 is never
    /// stored here.
    ///
    /// With `localOnly: true` (``create(title:type:sync:custodian:tags:metadata:localOnly:)``)
    /// the db3 lives only on this device: it is created here under an id
    /// minted here and answered at once with `localOnly` true and `sync`
    /// false, and nothing of it is ever sent to the server, in this session or
    /// a later one. Its writes are judged and confirmed on the device with the
    /// codes the server would use. `Db3CreatedEvent` fires once.
    ///
    /// ```swift
    /// let orders = try await client.db3.create(title: "Orders", type: "orders")
    /// let answer = try await client.documents.commitOfflineCreate(documentId: orders.id)
    /// let archive = try await client.db3.create(title: "Archive", sync: false) // an app owner or admin only
    /// let scratch = try await client.db3.create(title: "Scratch", localOnly: true) // never leaves the device
    /// ```
    ///
    /// - Parameters:
    ///   - title: The db3's title.
    ///   - type: A db3 type of this app (`db3-types/<name>.toml`).
    ///   - sync: `false` for a db3 no client opens over a socket (an app owner
    ///     or admin only); omitted means on.
    ///   - custodian: Who holds it, `app` or `user:<userId>` (an app owner or
    ///     admin only); omitted means the caller.
    ///   - tags: Its tags.
    ///   - metadata: An opaque metadata blob (at most 4 KB).
    /// - Throws: `JsBaoError(.invalidArgument)` with no signed-in user, or
    ///   with `details.reason` `identity-changed` when the caller is signed
    ///   out, or another user signed in, while the create waits for an
    ///   identity change in progress. A sync-off or custodian-naming create
    ///   throws the route's `HttpError`, its `serverCode` naming why: 403 for
    ///   a member's sync-off create, 404 `DB3_TYPE_NOT_FOUND`, 409
    ///   `DB3_TYPE_REFUSED` or `DB3_TYPE_REVISION_CONFLICT`.
    /// - Stability: beta
    public func create(
        title: String,
        type: String? = nil,
        sync: Bool? = nil,
        custodian: String? = nil,
        tags: [String]? = nil,
        metadata: JSONValue? = nil
    ) async throws -> Db3Info {
        if custodian == nil && sync != false {
            return try await createLocalFirst(title: title, type: type, tags: tags, metadata: metadata)
        }
        var body: [String: JSONValue] = ["title": .string(title)]
        if let type { body["type"] = .string(type) }
        if let sync { body["sync"] = .bool(sync) }
        if let custodian { body["custodian"] = .string(custodian) }
        if let tags { body["tags"] = .array(tags.map(JSONValue.string)) }
        if let metadata { body["metadata"] = metadata }
        let session = client?.metadataSessionToken
        let info: Db3Info
        do {
            info = try await transport.request(method: .post, path: "/db3", body: JSONValue.object(body))
        } catch {
            createFailed(error, title: title, type: type, id: nil)
            throw error
        }
        await adopt(info, session: session)
        client?.eventEmitter.emit(Db3CreatedEvent(id: info.id))
        return info
    }

    /// A create of the caller's own synced db3 (#4921, #5000): kept here under
    /// an id minted here as a pending create, networking on or off, and
    /// answered at once. Its `POST db3` starts now when networking is allowed,
    /// otherwise when it is back, and retries with backoff. A `Db3API` with no
    /// wired client has nowhere to keep it: it sends the `POST db3` under the
    /// minted id and answers as `create` answers.
    private func createLocalFirst(title: String, type: String?, tags: [String]?, metadata: JSONValue?) async throws -> Db3Info {
        let id = ULID.generate()
        if let client {
            if (client.authController.getUserId() ?? "").isEmpty {
                throw JsBaoError(code: .invalidArgument, message: "client.db3.create: there is no signed-in user to hold the db3")
            }
            return try await client.createPendingDb3(id, title: title, type: type, tags: tags, metadata: metadata, commitNow: true)
        }
        var body: [String: JSONValue] = ["title": .string(title), "id": .string(id)]
        if let type { body["type"] = .string(type) }
        if let tags { body["tags"] = .array(tags.map(JSONValue.string)) }
        if let metadata { body["metadata"] = metadata }
        do {
            return try await transport.request(method: .post, path: "/db3", body: JSONValue.object(body))
        } catch {
            createFailed(error, title: title, type: type, id: id)
            throw error
        }
    }

    /// ``create(title:type:sync:custodian:tags:metadata:)`` with `localOnly`:
    /// `true` keeps the db3 on this device only, `false` creates it as that
    /// call does.
    ///
    /// ```swift
    /// let scratch = try await client.db3.create(title: "Scratch", localOnly: true)
    /// ```
    ///
    /// - Parameters:
    ///   - title: The db3's title.
    ///   - type: A db3 type of this app; refused with `localOnly`.
    ///   - sync: `false` for a server-only db3; refused with `localOnly`.
    ///   - custodian: Who holds it; refused with `localOnly`.
    ///   - tags: Its tags.
    ///   - metadata: An opaque metadata blob (at most 4 KB).
    ///   - localOnly: Keep the db3 on this device only.
    /// - Throws: `.localOnlyUnsupportedOption` for `localOnly` with `type`,
    ///   `sync: false` or `custodian`, before anything is created;
    ///   `.invalidArgument` with no signed-in user, or `identity-changed` as
    ///   for the synced create; `.format2StorageUnavailable`
    ///   on a client whose storage cannot keep a db3 (an in-memory provider).
    /// - Stability: beta
    public func create(
        title: String,
        type: String? = nil,
        sync: Bool? = nil,
        custodian: String? = nil,
        tags: [String]? = nil,
        metadata: JSONValue? = nil,
        localOnly: Bool
    ) async throws -> Db3Info {
        guard localOnly else {
            return try await create(title: title, type: type, sync: sync, custodian: custodian, tags: tags, metadata: metadata)
        }
        return try await createLocalOnly(title: title, type: type, sync: sync, custodian: custodian, tags: tags, metadata: metadata)
    }

    /// A db3 kept on this device only (#5155): created under an id minted
    /// here, answered at once, and never sent to the server. What only the
    /// server can hold (a type, sync off, a custodian) is refused before
    /// anything is created.
    private func createLocalOnly(
        title: String, type: String?, sync: Bool?, custodian: String?, tags: [String]?, metadata: JSONValue?
    ) async throws -> Db3Info {
        var unsupported: [String] = []
        if type != nil { unsupported.append("type") }
        if sync == false { unsupported.append("sync: false") }
        if custodian != nil { unsupported.append("custodian") }
        guard unsupported.isEmpty else {
            throw JsBaoError(
                code: .localOnlyUnsupportedOption,
                message: "client.db3.create: localOnly: true cannot be combined with \(unsupported.joined(separator: ", ")) — "
                    + "a db3 that lives only on this device has no server record to hold it",
                details: ["options": .array(unsupported.map { .string($0) })]
            )
        }
        guard let client, !(client.authController.getUserId() ?? "").isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "client.db3.create: there is no signed-in user to hold the db3")
        }
        return try await client.createLocalOnlyDb3(ULID.generate(), title: title, tags: tags, metadata: metadata)
    }

    /// A refused create's `Db3CreateFailedEvent`; `id` names a client-minted id.
    private func createFailed(_ error: Error, title: String?, type: String?, id: String?) {
        let code: String
        let message: String
        if let http = error as? HttpError {
            code = http.serverCode ?? "DB3_CREATE_FAILED"
            message = http.serverMessage ?? http.message
        } else if let failure = error as? JsBaoError {
            code = failure.code.rawValue
            message = failure.message
        } else {
            code = "DB3_CREATE_FAILED"
            message = error.localizedDescription
        }
        client?.eventEmitter.emit(Db3CreateFailedEvent(code: code, message: message, title: title, type: type, id: id))
    }

    /// Adopt a db3 the server created into this client at the level it was
    /// created with, under the metadata session its request was made in (a
    /// sync-off one, or one another holder holds, only has its format noted).
    private func adopt(_ info: Db3Info, session: UInt64?, permission: Db3AliasPermission = .owner) async {
        guard let client, let session else { return }
        await client.adoptServerCreatedDb3(info.id, info: info, session: session, permission: permission)
    }

    /// A db3, with the caller's `permission`, `accessSource` and `grantedAt`
    /// when they hold it through a grant.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let info = try await client.db3.get(db3Id)
    /// if info.accessSource == .app { print("shared with every member") }
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Throws: `HttpError` 404 for no db3 of this app, 409 `NOT_A_DB3` for a
    ///   document that is not a db3, 403 `DOC_ACCESS_DENIED`.
    /// - Stability: beta
    public func get(_ db3Id: String) async throws -> Db3Info {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: Self.path(db3Id))
    }

    /// Rename a db3 and answer it as ``get(_:)`` does, with the new title and
    /// `modifiedAt`. Its owner, a `read-write` grant or link, and an app owner
    /// or admin rename it. The title is stored trimmed. On success this
    /// device's stored copy takes the new title (``stored()``); on a refusal
    /// nothing here changes. Connected devices of users who hold a direct
    /// grant hear the new title; anyone else reads it at their next ``get(_:)``
    /// or ``listMine(_:)``.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// A db3 that lives only on this device is renamed here with nothing
    /// sent, and stays renamed after a restart.
    ///
    /// ```swift
    /// let renamed = try await client.db3.update(db3Id, title: "Rivera household")
    /// print(renamed.title, renamed.modifiedAt)
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - title: The new title.
    /// - Throws: `HttpError` 403 `DOC_ACCESS_DENIED` for a caller who may not
    ///   write the db3, 400 for a blank title or one over 255 characters, 404
    ///   for no db3 of this app; `.invalidArgument` for such a title on a db3
    ///   that lives only on this device.
    /// - Stability: beta
    public func update(_ db3Id: String, title: String) async throws -> Db3Info {
        if let client, await client.isLocalOnlyDb3(db3Id) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw JsBaoError(code: .invalidArgument, message: "client.db3.update: title is required", details: ["db3Id": .string(db3Id)])
            }
            guard title.utf16.count <= Self.titleMax else {
                throw JsBaoError(
                    code: .invalidArgument, message: "client.db3.update: title is over \(Self.titleMax) characters",
                    details: ["db3Id": .string(db3Id)]
                )
            }
            return await client.renameLocalOnlyDb3(db3Id, title: trimmed)
        }
        try await awaitCreate(db3Id)
        let info: Db3Info = try await transport.request(
            method: .put, path: Self.path(db3Id), body: JSONValue.object(["title": .string(title)])
        )
        await client?.noteDb3Title(db3Id, title: info.title)
        return info
    }

    /// The longest title a db3 takes, as the server judges it: in UTF-16
    /// code units, as the server and the JS client count a string.
    private static let titleMax = 255

    /// Delete a db3 with its records, grants and blobs. Its owner deletes it,
    /// and so does an app owner or admin.
    ///
    /// A db3 that lives only on this device is removed here with nothing
    /// sent: its subscriptions end as evicted and `Db3EvictedEvent` fires
    /// once (`explicit`) once its copy is gone; `.db3Held` while another
    /// holder keeps its store, nothing removed. Either way this device's
    /// index policy for the db3 (``Db3IndexesAPI/decline(_:name:)``) is cleared.
    ///
    /// ```swift
    /// _ = try await client.db3.delete(db3Id)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func delete(_ db3Id: String) async throws -> SuccessResult {
        if let client, await client.isLocalOnlyDb3(db3Id) {
            try await lifecycle.deleteLocalOnly(db3Id)
            return SuccessResult(success: true)
        }
        let deleted: SuccessResult = try await transport.request(method: .delete, path: Self.path(db3Id))
        // The device's index policy for it goes with it (#5322); an evict keeps it.
        await client?.clearDb3IndexPolicy(db3Id)
        return deleted
    }

    /// The listings `listMine(_:)` reads, in its order.
    private static let listings: [(via: Db3Via, path: String)] = [
        (.held, "/me/db3"), (.shared, "/me/shared-db3"), (.app, "/me/app-db3"),
    ]

    /// One page of the db3s you hold, those shared with you by a grant, and
    /// those granted to every user of the app, in that order (one request per
    /// call). Each row names its listing as `via`, with that listing's level
    /// as `permission` (and `grantedAt`, `grantedBy` where the listing has
    /// them). A db3 whose sync is off is not listed. Follow `nextCursor` to
    /// the end; `via` reads only some listings. A `cursor` this call did not
    /// issue throws `.invalidArgument` before any request.
    ///
    /// ```swift
    /// var page = try await client.db3.listMine()
    /// while true {
    ///     for db3 in page.items { print(db3.via ?? .held, db3.id, db3.permission ?? .reader) }
    ///     if !page.hasMore { break }
    ///     page = try await client.db3.listMine(Db3ListMineOptions(cursor: page.nextCursor))
    /// }
    /// ```
    ///
    /// - Parameter options: The listings, the page size and a cursor.
    /// - Stability: beta
    public func listMine(_ options: Db3ListMineOptions = Db3ListMineOptions()) async throws -> PaginatedResult<Db3Info> {
        let sources = Self.listings.filter { options.via.contains($0.via) }
        let at: Db3ListMineCursor
        if let cursor = options.cursor {
            guard let read = Db3ListMineCursor.decode(cursor), sources.contains(where: { $0.via == read.via }) else {
                throw JsBaoError(
                    code: .invalidArgument,
                    message: "client.db3.listMine: the cursor is not one listMine issued for these listings"
                )
            }
            at = read
        } else if let first = sources.first {
            at = Db3ListMineCursor(via: first.via, cursor: nil)
        } else {
            return PaginatedResult(items: [], nextCursor: nil, hasMore: false)
        }
        guard let index = sources.firstIndex(where: { $0.via == at.via }) else {
            return PaginatedResult(items: [], nextCursor: nil, hasMore: false)
        }
        let page: Db3Page = try await transport.request(
            method: .get, path: Self.listingPath(sources[index].path, limit: options.limit, cursor: at.cursor)
        )
        let items = page.items.map { $0.listed(via: at.via) }
        let next: Db3ListMineCursor?
        if page.hasMore == true, let cursor = page.nextCursor {
            next = Db3ListMineCursor(via: at.via, cursor: cursor)
        } else if index + 1 < sources.count {
            next = Db3ListMineCursor(via: sources[index + 1].via, cursor: nil)
        } else {
            next = nil
        }
        return PaginatedResult(items: items, nextCursor: next?.encoded, hasMore: next != nil)
    }

    /// One page of the db3s the signed-in user holds, oldest first, each with
    /// the level of the user's own row (`nil` when an admin removed it).
    /// `listMine(_:)` is the full form, which also lists the db3s shared with
    /// you and those granted to the app.
    ///
    /// The loop below continues either form: given a cursor `listMine(_:)`
    /// issued, this call continues that listing.
    ///
    /// ```swift
    /// var page = try await client.db3.listMine()
    /// while page.hasMore {
    ///     page = try await client.db3.listMine(options: PaginationOptions(cursor: page.nextCursor))
    /// }
    /// ```
    ///
    /// - Parameter options: The page size and the cursor of the page before.
    /// - Stability: beta
    public func listMine(options: PaginationOptions) async throws -> PaginatedResult<Db3Info> {
        if let cursor = options.cursor, Db3ListMineCursor.decode(cursor) != nil {
            return try await listMine(Db3ListMineOptions(limit: options.limit, cursor: cursor))
        }
        var query: [String] = []
        if let limit = options.limit { query.append("limit=\(limit)") }
        if let cursor = options.cursor { query.append("cursor=\(URLEncoding.encodeComponent(cursor))") }
        let path = "/me/db3" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        let page: Db3Page = try await transport.request(method: .get, path: path)
        return PaginatedResult(items: page.items, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    private struct Db3Page: Decodable, Sendable {
        let items: [Db3Info]
        let hasMore: Bool?
        let nextCursor: String?
    }

    /// A listing's path with its `limit` and `cursor`.
    private static func listingPath(_ path: String, limit: Int?, cursor: String?) -> String {
        var query: [String] = []
        if let limit { query.append("limit=\(limit)") }
        if let cursor { query.append("cursor=\(URLEncoding.encodeComponent(cursor))") }
        return path + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    /// The db3 an alias names, created for it when the alias names nothing.
    /// A created db3 is answered whole (`db3`) and, when you hold it, stored
    /// here as `create` stores one; an existing one is a reference
    /// (`created == false`, `db3 == nil`).
    ///
    /// `permission` sets the alias user's level on a db3 this call creates:
    /// `.owner` (the default), `.readWrite` or `.reader`, which writes no owner
    /// row and one grant at that level. A level other than `.owner` needs an
    /// app owner or admin; a member is refused 403. A `.reader` db3 you create
    /// for yourself is read-only here at once: a save throws `.writeAccessDenied`
    /// and nothing is sent. One created for another user is not stored here.
    ///
    /// ```swift
    /// let home = try await client.db3.getOrCreateWithAlias(
    ///     Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "home"), title: "Home", type: "notes")
    /// )
    /// let inbox = try await client.db3.getOrCreateWithAlias(  // an app owner or admin
    ///     Db3GetOrCreateWithAliasOptions(
    ///         alias: AliasRef(scope: .user, aliasKey: "inbox", userId: memberId), title: "Inbox", permission: .reader
    ///     )
    /// )
    /// ```
    ///
    /// - Parameter options: The alias, and what a created db3 starts with.
    /// - Throws: `HttpError` 409 `DB3_TYPE_MISMATCH` when the alias names a
    ///   db3 of another type, 404 `DB3_TYPE_NOT_FOUND`, 403 for a member
    ///   passing a `permission` other than `.owner`.
    /// - Stability: beta
    public func getOrCreateWithAlias(_ options: Db3GetOrCreateWithAliasOptions) async throws -> Db3GetOrCreateWithAliasResult {
        var alias: [String: JSONValue] = [
            "scope": .string(options.alias.scope.rawValue), "aliasKey": .string(options.alias.aliasKey),
        ]
        if let userId = options.alias.userId { alias["userId"] = .string(userId) }
        var body: [String: JSONValue] = ["alias": .object(alias)]
        if let title = options.title { body["title"] = .string(title) }
        if let tags = options.tags { body["tags"] = .array(tags.map(JSONValue.string)) }
        if let metadata = options.metadata { body["metadata"] = metadata }
        if let type = options.type { body["type"] = .string(type) }
        if let permission = options.permission { body["permission"] = .string(permission.rawValue) }
        let session = client?.metadataSessionToken
        let result: Db3GetOrCreateWithAliasResult
        do {
            result = try await transport.request(method: .post, path: "/db3/get-or-create-with-alias", body: JSONValue.object(body))
        } catch {
            createFailed(error, title: options.title, type: options.type, id: nil)
            throw error
        }
        if let created = result.db3 {
            await adopt(created, session: session, permission: options.permission ?? .owner)
            client?.eventEmitter.emit(Db3CreatedEvent(id: created.id))
        } else {
            // An alias that already names a db3: known as one at once, so its
            // subscribe asks the documents API nothing.
            client?.noteDb3(result.id)
        }
        return result
    }

    /// Whether a db3 syncs over a socket.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let state = try await client.db3.getSync(db3Id)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func getSync(_ db3Id: String) async throws -> Db3SyncState {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: Self.path(db3Id, "/sync"))
    }

    /// Turn a db3's sync on or off. Off, every subscribed client hears the db3
    /// gone (`Db3GoneEvent` with `.syncOff`) and only its records routes reach
    /// it; on again, clients subscribe as before. An app owner or admin only.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let change = try await client.db3.setSync(db3Id, sync: false)
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - sync: The state to set.
    /// - Stability: beta
    public func setSync(_ db3Id: String, sync: Bool) async throws -> Db3SyncChange {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .put, path: Self.path(db3Id, "/sync"), body: JSONValue.object(["sync": .bool(sync)]))
    }

    /// A db3's type: the type its row names with that type's current
    /// revision, and the revision its room holds.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let type = try await client.db3.getType(db3Id)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func getType(_ db3Id: String) async throws -> Db3TypeState {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: Self.path(db3Id, "/type"))
    }

    /// Attach a type to a db3, installing its current revision whole or not
    /// at all. An app owner or admin only; a type is never detached.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let change = try await client.db3.setType(db3Id, type: "orders")
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - type: A db3 type of this app.
    /// - Throws: `HttpError` 409 `DB3_TYPE_REFUSED` (`details.reasons`) when
    ///   the db3's records break the type, `DB3_TYPED` when it has another type.
    /// - Stability: beta
    public func setType(_ db3Id: String, type: String) async throws -> Db3TypeChange {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .put, path: Self.path(db3Id, "/type"), body: JSONValue.object(["type": .string(type)]))
    }

    /// The level a db3's app access grants every member of the app, or `nil`.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let access = try await client.db3.getAppAccess(db3Id)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func getAppAccess(_ db3Id: String) async throws -> Db3AppAccess {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: Self.path(db3Id, "/app-access"))
    }

    /// Grant every current and future member of the app a level on a db3, or
    /// remove that grant with `nil`. An app owner or admin only; refused on a
    /// sync-off db3 (`DB3_SYNC_OFF_NO_SHARING`).
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// _ = try await client.db3.setAppAccess(db3Id, level: .readWrite)
    /// _ = try await client.db3.setAppAccess(db3Id, level: nil)
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - level: The level, or `nil` to remove the grant.
    /// - Stability: beta
    public func setAppAccess(_ db3Id: String, level: Db3AppAccessLevel?) async throws -> Db3AppAccessChange {
        try await awaitCreate(db3Id)
        let value: JSONValue = level.map { .string($0.rawValue) } ?? .null
        return try await transport.request(method: .put, path: Self.path(db3Id, "/app-access"), body: JSONValue.object(["level": value]))
    }

    /// Move who holds a db3: to `app`, or to `user:<userId>`. Its owner row
    /// moves with it; the answer is the db3 as it now is.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let moved = try await client.db3.transfer(db3Id, to: "app")
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - custodian: `app` or `user:<userId>`.
    /// - Stability: beta
    public func transfer(_ db3Id: String, to custodian: String) async throws -> Db3Info {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .post, path: Self.path(db3Id, "/transfer"), body: JSONValue.object(["to": .string(custodian)]))
    }

    // MARK: - Records

    /// A db3's records by model name, with no model class: put, patch,
    /// delete, get, query, count, subscribe and explain any model, declared
    /// or not, answered from this device's copy online and offline. Every call
    /// of the handle resolves the db3 when it runs, so the handle may be kept:
    /// it throws `.notFound` while the db3 is not open here, and
    /// `.db3NotResident` for a read before its rows have loaded.
    ///
    /// ```swift
    /// let records = client.db3.records(db3Id)
    /// try records.put("Note", ["title": "Groceries", "tags": ["home"]])
    /// let open = try records.query("Note", ["done": false])
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func records(_ db3Id: String) -> DocumentRecords {
        JsBaoClient.modelFreeRecords(db3Id, client: client, logger: client?.logger.forScope(scope: "db3"))
    }

    /// What a db3 holds, model by model: each model's declaration and what
    /// the room observed written (`schema.models[name]["observed"]`: each
    /// field's kinds, and per-kind counts after a segment export).
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let answer = try await client.db3.schema(db3Id)
    /// print(answer.modelNames)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Throws: `HttpError` 404 for no db3 of this app, 409 `NOT_A_DB3` for a
    ///   document that is not a db3, 403 `DOC_ACCESS_DENIED`.
    /// - Stability: beta
    public func schema(_ db3Id: String) async throws -> DocumentSchemaAnswer {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: Self.path(db3Id, "/schema"))
    }

    // MARK: - Access

    /// A db3's effective access: the caller's, or with `userId` that member's
    /// (an app owner or admin may name anyone, a member only themselves). A
    /// member reached by the db3's app access reads `accessSource` `"app"`.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let mine = try await client.db3.validateAccess(db3Id)
    /// let theirs = try await client.db3.validateAccess(db3Id, userId: memberId)
    /// if theirs.permission == .readWrite { print("they may write") }
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - userId: The member to ask about instead of the caller.
    /// - Throws: `HttpError` 404 for no db3 of this app, 409 `NOT_A_DB3` for a
    ///   document that is not a db3, 403 when a member names someone else.
    /// - Stability: beta
    public func validateAccess(_ db3Id: String, userId: String? = nil) async throws -> DocumentAccessResult {
        try await awaitCreate(db3Id)
        guard let userId else {
            return try await transport.request(method: .post, path: Self.path(db3Id, "/validate-access"))
        }
        return try await transport.request(
            method: .post, path: Self.path(db3Id, "/validate-access"), body: ValidateAccessSubjectParams(userId: userId)
        )
    }

    // MARK: - Sharing

    /// A db3's sharing: its users' and groups' grants, pending invitations,
    /// link access and access requests.
    ///
    /// ```swift
    /// let sharing = client.db3.permissions(db3Id)
    /// _ = try await sharing.set(.email("colleague@example.com", permission: "read-write"))
    /// let people = try await sharing.list()
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func permissions(_ db3Id: String) -> Db3PermissionsAPI {
        Db3PermissionsAPI(db3Id: db3Id, transport: transport) { [weak self] id in try await self?.awaitCreate(id) }
    }

    // MARK: - Blobs

    /// A db3's blobs: upload, list, read, download URLs, delete, and its
    /// upload queue. An upload made offline, or to a db3 created here whose
    /// create the server does not have yet, is queued and answered at once
    /// (`bytesTransferred == 0`), and sent once the client is online and the
    /// server has the db3. On a db3 that lives only on this device every call
    /// that would reach the server throws `.db3LocalOnly`.
    ///
    /// ```swift
    /// let blobs = client.db3.blobs(db3Id)
    /// let uploaded = try await blobs.upload(data: data, options: BlobUploadSourceOptions(filename: "notes.txt"))
    /// let url = blobs.downloadUrl(blobId: uploaded.blobId, disposition: .inline)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func blobs(_ db3Id: String) -> Db3BlobContext {
        Db3BlobContext(db3Id: db3Id, transport: transport, blobManager: blobManager) { [weak client] in
            // #5155 — a db3 that lives only on this device holds no blobs.
            guard let client, await client.isLocalOnlyDb3(db3Id) else { return nil }
            return JsBaoClient.db3LocalOnlyError(db3Id, call: "client.db3.blobs", instead: "it holds no blobs")
        }
    }

    /// Remove or restore the owner row of a db3 a user holds, while they stay
    /// its custodian. An app owner or admin only.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// _ = try await client.db3.setOwnerRow(db3Id, present: false)
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - present: Whether the owner row should exist.
    /// - Stability: beta
    public func setOwnerRow(_ db3Id: String, present: Bool) async throws -> Db3OwnerRowChange {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .put, path: Self.path(db3Id, "/owner-row"), body: JSONValue.object(["present": .bool(present)]))
    }

    private struct BatchBody: Encodable, Sendable {
        let operations: [Db3BatchOperation]
        let atomic: Bool?
        let requestId: String?
    }

    private struct BatchReadBody: Encodable, Sendable {
        let operations: [Db3BatchReadOperation]
        let atomic: Bool?
    }

    /// Apply creates, patches, deletes, upserts and increments across models,
    /// with reads among them, in one request: in order, in one transaction,
    /// all of them or none (at most 100 operations). A read sees the writes
    /// before it and not those after it, and is answered in `reads` at its
    /// index. With `atomic: false` each operation is applied on its own,
    /// `results` reports each write and a refused read is `.refused`. Needs
    /// write access; a caller who may only read uses ``batchRead(_:_:atomic:)``.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let result = try await client.db3.batch(db3Id, [
    ///     .create(model: "Task", data: ["title": "Plan"]),
    ///     .count(model: "Task"),
    /// ])
    /// if case .count(let total)? = result.reads?.first?.answer { print(total) }
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - operations: The operations, in order.
    ///   - options: `atomic`, and a `requestId` naming the whole request.
    /// - Throws: `HttpError` with the refusal's code (`BATCH_TOO_LARGE` past 100 operations,
    ///   `DB3_CONDITION_NOT_MET`, `DB3_PAGE_TOO_LARGE`, …) and `details.index` naming the operation.
    /// - Stability: beta
    public func batch(_ db3Id: String, _ operations: [Db3BatchOperation], options: Db3BatchOptions = Db3BatchOptions()) async throws -> Db3BatchResult {
        try await awaitCreate(db3Id)
        return try await transport.request(
            method: .post,
            path: Self.path(db3Id, "/records/batch"),
            body: BatchBody(operations: operations, atomic: options.atomic, requestId: options.requestId)
        )
    }

    /// Run several reads (queries, counts, aggregates, across models) in one
    /// request, all answered from one state of the db3, each at its index (at
    /// most 100). By default the first refused read throws with its code and
    /// `details.index`; with `atomic: false` it is answered `.refused` in its
    /// place. Needs read access only.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// ```swift
    /// let answer = try await client.db3.batchRead(db3Id, [
    ///     .query(model: "Project", limit: 20),
    ///     .count(model: "Task", filter: ["done": false]),
    /// ])
    /// for result in answer.results { print(result.index, result.answer) }
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - operations: The reads, in order.
    ///   - atomic: `false` answers each read on its own; omitted, the first refusal throws.
    /// - Stability: beta
    public func batchRead(_ db3Id: String, _ operations: [Db3BatchReadOperation], atomic: Bool? = nil) async throws -> Db3BatchReadResponse {
        try await awaitCreate(db3Id)
        return try await transport.request(
            method: .post,
            path: Self.path(db3Id, "/records/batch-read"),
            body: BatchReadBody(operations: operations, atomic: atomic)
        )
    }
}

// MARK: - Indexes

/// Why an index exists: a model declaration that marks the field `indexed` or
/// `unique`, or a registration made through `client.db3.indexes.register`.
public struct Db3IndexOrigin: Sendable, Equatable, Decodable {
    /// `declaration` for a declared field or constraint, `named` for a registration.
    public enum Kind: String, Sendable, Equatable, Decodable {
        case declaration
        case named
    }

    /// - Stability: beta
    public let kind: Kind
    /// Whether this origin asks for the index's fields to be unique.
    /// - Stability: beta
    public let unique: Bool

    public init(kind: Kind, unique: Bool) {
        self.kind = kind
        self.unique = unique
    }
}

/// What a db3 index is: `.scalar` for a field index (or a unique constraint
/// over several fields), `.members` for a string-set field's member index,
/// `.text` for a full-text index that answers `$search`. A kind no side of the
/// db3 builds is refused with `DB3_INDEX_PLACEMENT_UNSUPPORTED`.
public enum Db3IndexKind: String, Sendable, Equatable, Codable, CaseIterable {
    case scalar
    case members
    case text
    case vector
}

/// Where a db3 index lives: `server` (the db3's server-side reads use it),
/// `device` (each device holding the db3 builds it for its local queries) or
/// `both`. A db3 that lives only on this device keeps every index on the device.
public enum Db3IndexPlacement: String, Sendable, Equatable, Codable, CaseIterable {
    case server
    case device
    case both
}

/// How an index a synced db3's room places on this device stands here:
/// `built` (this device holds it and device queries use it), `building` (it
/// is being built in the background; queries answer meanwhile), `unbuilt`
/// (this device holds none: its build failed, for one when the disk was full,
/// or this device builds no index of its kind; ``Db3LocalIndex/reason`` says
/// why, and every later sync tries again), `declined` (this device does not
/// build it: ``Db3IndexesAPI/decline(_:name:)`` or the client's
/// ``JsBaoClientOptions/deviceIndexes``).
public enum Db3LocalIndexStatus: String, Sendable, Equatable, CaseIterable {
    case built
    case building
    case unbuilt
    case declined
}

/// An index placed on this device, with how it stands here, as
/// `client.db3.indexes.local(_:)` lists it.
public struct Db3LocalIndex: Sendable, Equatable {
    /// The index's name, as `client.db3.indexes.list(_:)` names it.
    /// - Stability: beta
    public let name: String
    /// - Stability: beta
    public let model: String
    /// The fields, in index order.
    /// - Stability: beta
    public let fields: [String]
    /// - Stability: beta
    public let kind: Db3IndexKind
    /// `device` or `both`: an index placed on the server only is not listed.
    /// - Stability: beta
    public let on: Db3IndexPlacement
    /// - Stability: beta
    public let status: Db3LocalIndexStatus
    /// Why it is not built: `declined on this device`, the `deviceIndexes` option, or its build's failure.
    /// - Stability: beta
    public let reason: String?
    /// How a built vector index answers `$near` now: `.exact` from every
    /// vector, or `.ann` from its approximate index once this device has
    /// installed the shared model and finished filling it. `.exact` while
    /// `.building`; `nil` for every other kind and for a vector index that is
    /// not built.
    /// - Stability: beta
    public let mode: Db3LocalIndexMode?

    public init(
        name: String, model: String, fields: [String], kind: Db3IndexKind, on: Db3IndexPlacement, status: Db3LocalIndexStatus,
        reason: String? = nil, mode: Db3LocalIndexMode? = nil
    ) {
        self.name = name
        self.model = model
        self.fields = fields
        self.kind = kind
        self.on = on
        self.status = status
        self.reason = reason
        self.mode = mode
    }
}

/// An entry of a db3's index list this device's copy built nothing for, as
/// `client.db3.indexes.skipped(_:)` lists it: one placed on the server only,
/// or one the device cannot build (a name that is not an identifier, an `id`
/// field the primary key already serves, a member or vector index over more
/// than one field, text options it cannot read).
public struct Db3SkippedIndex: Sendable, Equatable {
    /// The index's name, as `client.db3.indexes.list(_:)` names it.
    /// - Stability: beta
    public let name: String
    /// - Stability: beta
    public let model: String
    /// The fields, in index order.
    /// - Stability: beta
    public let fields: [String]
    /// - Stability: beta
    public let kind: Db3IndexKind
    /// Where the index list places it: `.server` only here, never in `local(_:)`.
    /// - Stability: beta
    public let on: Db3IndexPlacement
    /// Why this device builds nothing for it, e.g. `placed on the server only; this device builds nothing for it`.
    /// - Stability: beta
    public let reason: String

    public init(name: String, model: String, fields: [String], kind: Db3IndexKind, on: Db3IndexPlacement, reason: String) {
        self.name = name
        self.model = model
        self.fields = fields
        self.kind = kind
        self.on = on
        self.reason = reason
    }
}

/// How a vector index built on this device answers `$near`: `.exact` (every
/// vector compared) or `.ann` (its approximate index, reranked on the full
/// vectors, so `_distance` stays exact).
public enum Db3LocalIndexMode: String, Sendable, Equatable, CaseIterable {
    case exact
    case ann
}

/// Which of the indexes a db3's room places on this device the client builds
/// when it has not built them yet: `.all` (the default), `.none`, or the kinds
/// to build. An index already built stays built, and
/// ``Db3IndexesAPI/decline(_:name:)`` and ``Db3IndexesAPI/accept(_:name:)``
/// decide one index whatever this says.
///
/// ```swift
/// let options = JsBaoClientOptions(apiUrl: api, wsUrl: ws, appId: appId, deviceIndexes: .kinds([.scalar]))
/// ```
public enum Db3DeviceIndexes: Sendable, Equatable {
    case all
    case none
    case kinds([Db3IndexKind])
}

/// One index on a db3's records, as `client.db3.indexes.list(_:)` answers it.
public struct Db3Index: Sendable, Equatable, Decodable {
    /// `idx_records_<model>_<field>` for a field's shared index,
    /// `idx_uc_<model>_<constraint>` for a declared compound constraint,
    /// `idx_named_<model>_<name>` for one registered with a name,
    /// `idx_members_<model>_<field>` for a string-set field's member index.
    /// - Stability: beta
    public let name: String
    /// The model whose records the index covers.
    /// - Stability: beta
    public let model: String
    /// The fields, in index order.
    /// - Stability: beta
    public let fields: [String]
    /// Whether uniqueness is enforced: true while any origin asks for it.
    /// - Stability: beta
    public let unique: Bool
    /// Whether this is a string-set field's member index, which serves
    /// `$contains`, any-of, membership levels and unfiltered facets on the
    /// field in the db3. `false` for every other index.
    /// - Stability: beta
    public let members: Bool
    /// Every origin keeping the index. It is dropped when the last one goes.
    /// - Stability: beta
    public let origins: [Db3IndexOrigin]
    /// What the index is: `.members` exactly when `members` is true.
    /// - Stability: beta
    public let kind: Db3IndexKind
    /// Where the index lives. A declared field's index is on `.both`; every
    /// index of a db3 that lives only on this device is on `.device`.
    /// - Stability: beta
    public let on: Db3IndexPlacement
    /// A text index's options, every one filled in; `nil` for any other kind.
    /// - Stability: beta
    public let text: Db3TextIndex?
    /// A vector index's options and its field's encoding; `nil` for any other
    /// kind, and from a server that does not list them.
    /// - Stability: beta
    public let vector: Db3VectorIndex?
    /// A vector index's generation: it changes when the index is dropped and
    /// registered again, so no model of the old index is used. `nil` for any other kind.
    /// - Stability: beta
    public let generation: Int?
    /// A vector index's model revision: it moves when the model is deleted,
    /// so every device drops its copy. `nil` for any other kind.
    /// - Stability: beta
    public let revision: Int?
    /// An `ann` vector index's shared model, once a device (or the app)
    /// uploaded one; `nil` before, and for any other index.
    /// - Stability: beta
    public let annModel: Db3IndexAnnModel?

    private enum CodingKeys: String, CodingKey {
        case name, model, fields, unique, members, origins, kind, on, text, vector, generation, revision, annModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decode(String.self, forKey: .model)
        fields = try container.decode([String].self, forKey: .fields)
        unique = try container.decode(Bool.self, forKey: .unique)
        // Only a member index's row carries `members`.
        members = try container.decodeIfPresent(Bool.self, forKey: .members) ?? false
        origins = try container.decode([Db3IndexOrigin].self, forKey: .origins)
        // A server from before kinds and placements lists neither: a member
        // index lived on the server, every other index on both sides.
        kind = try container.decodeIfPresent(Db3IndexKind.self, forKey: .kind) ?? (members ? .members : .scalar)
        on = try container.decodeIfPresent(Db3IndexPlacement.self, forKey: .on) ?? (kind == .members ? .server : .both)
        text = try container.decodeIfPresent(Db3TextIndex.self, forKey: .text)
        vector = try container.decodeIfPresent(Db3VectorIndex.self, forKey: .vector)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        annModel = try container.decodeIfPresent(Db3IndexAnnModel.self, forKey: .annModel)
    }
}

/// A vector index's options as `client.db3.indexes.list(_:)` answers them:
/// the registration's `distance` and `index`, filled in, and the field's
/// encoding.
public struct Db3VectorIndex: Sendable, Equatable, Decodable {
    /// - Stability: beta
    public let distance: Db3VectorIndexOptions.Distance
    /// - Stability: beta
    public let index: Db3VectorIndexOptions.Mode
    /// How many numbers the field holds; `nil` when the room does not know the field's encoding.
    /// - Stability: beta
    public let dims: Int?
    /// How each number is stored; `nil` when the room does not know the field's encoding.
    /// - Stability: beta
    public let element: VectorElement?

    public init(distance: Db3VectorIndexOptions.Distance, index: Db3VectorIndexOptions.Mode, dims: Int?, element: VectorElement?) {
        self.distance = distance
        self.index = index
        self.dims = dims
        self.element = element
    }
}

/// An `ann` vector index's shared model as `client.db3.indexes.list(_:)`
/// lists it: its revision, when and over how many records it was trained,
/// its size and its envelope's format (`pvm1`).
public struct Db3IndexAnnModel: Sendable, Equatable, Decodable {
    /// - Stability: beta
    public let revision: Int
    /// - Stability: beta
    public let trainedAt: Date
    /// - Stability: beta
    public let rows: Int
    /// - Stability: beta
    public let bytes: Int
    /// - Stability: beta
    public let format: String

    private enum CodingKeys: String, CodingKey { case revision, trainedAt, rows, bytes, format }

    public init(revision: Int, trainedAt: Date, rows: Int, bytes: Int, format: String) {
        self.revision = revision
        self.trainedAt = trainedAt
        self.rows = rows
        self.bytes = bytes
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        let text = try container.decode(String.self, forKey: .trainedAt)
        guard let date = RecordLogVectorModelCheck.date(text) else {
            throw DecodingError.dataCorruptedError(forKey: .trainedAt, in: container, debugDescription: "not an ISO 8601 date: \(text)")
        }
        trainedAt = date
        rows = try container.decode(Int.self, forKey: .rows)
        bytes = try container.decode(Int.self, forKey: .bytes)
        format = try container.decode(String.self, forKey: .format)
    }
}

/// An `ann` vector index's shared model as `client.db3.indexes.fetchModel`
/// answers it: its bytes (the model in its `pvm1` envelope) and what it was
/// uploaded with.
public struct Db3IndexModel: Sendable, Equatable {
    /// - Stability: beta
    public let bytes: Data
    /// The index's generation it was uploaded for.
    /// - Stability: beta
    public let generation: Int
    /// The revision it was uploaded under.
    /// - Stability: beta
    public let revision: Int
    /// How many records it was trained over.
    /// - Stability: beta
    public let rows: Int
    /// - Stability: beta
    public let trainedAt: Date
    /// Its envelope's format, `pvm1`.
    /// - Stability: beta
    public let format: String

    public init(bytes: Data, generation: Int, revision: Int, rows: Int, trainedAt: Date, format: String) {
        self.bytes = bytes
        self.generation = generation
        self.revision = revision
        self.rows = rows
        self.trainedAt = trainedAt
        self.format = format
    }
}

/// What `client.db3.indexes.uploadModel` sends beside the bytes: the index's
/// `generation` and `revision` as `list` answers them, and how the model was
/// trained.
public struct Db3IndexModelUpload: Sendable, Equatable {
    /// - Stability: beta
    public let generation: Int
    /// - Stability: beta
    public let revision: Int
    /// How many records the model was trained over.
    /// - Stability: beta
    public let rows: Int
    /// - Stability: beta
    public let trainedAt: Date
    /// Its envelope's format: `pvm1`.
    /// - Stability: beta
    public let format: String

    public init(generation: Int, revision: Int, rows: Int, trainedAt: Date, format: String = "pvm1") {
        self.generation = generation
        self.revision = revision
        self.rows = rows
        self.trainedAt = trainedAt
        self.format = format
    }
}

/// What `client.db3.indexes.deleteModel` answers: the index's new revision.
public struct Db3IndexModelDeletion: Sendable, Equatable {
    /// - Stability: beta
    public let ok: Bool
    /// - Stability: beta
    public let name: String
    /// - Stability: beta
    public let revision: Int

    public init(ok: Bool, name: String, revision: Int) {
        self.ok = ok
        self.name = name
        self.revision = revision
    }
}

/// How a text index splits and folds words: `.unicode61` (the default: Unicode
/// words, case and diacritics folded, so `cafe` finds `Café`) or `.porter`
/// (the same, with English stemming, so `run` finds `running`).
public enum Db3TextTokenizer: String, Sendable, Equatable, Codable, CaseIterable {
    case unicode61
    case porter
}

/// A text index's options on a registration, each optional: the tokenizer
/// (`.unicode61` when `nil`), prefix-index lengths (each 1 to 32, at most 8;
/// they speed up `prefix: true` searches of those lengths) and a positive
/// weight per covered field (1 for each field left out; a match in a heavier
/// field ranks higher).
///
/// ```swift
/// Db3TextIndexOptions(tokenizer: .porter, weights: ["title": 3])
/// ```
public struct Db3TextIndexOptions: Sendable, Equatable, Encodable {
    /// - Stability: beta
    public let tokenizer: Db3TextTokenizer?
    /// - Stability: beta
    public let prefix: [Int]?
    /// - Stability: beta
    public let weights: [String: Double]?

    public init(tokenizer: Db3TextTokenizer? = nil, prefix: [Int]? = nil, weights: [String: Double]? = nil) {
        self.tokenizer = tokenizer
        self.prefix = prefix
        self.weights = weights
    }
}

/// A text index's options as `client.db3.indexes.list(_:)` answers them, every
/// one filled in: the tokenizer, the prefix-index lengths (none by default)
/// and a weight per covered field.
public struct Db3TextIndex: Sendable, Equatable, Decodable {
    /// - Stability: beta
    public let tokenizer: Db3TextTokenizer
    /// - Stability: beta
    public let prefix: [Int]
    /// - Stability: beta
    public let weights: [String: Double]

    public init(tokenizer: Db3TextTokenizer, prefix: [Int], weights: [String: Double]) {
        self.tokenizer = tokenizer
        self.prefix = prefix
        self.weights = weights
    }
}

/// What `client.db3.indexes.register(_:_:)` registers: a model and one field,
/// or a composite (a unique constraint, which also needs `unique: true` and a
/// `name`). `unique: true` refuses the registration while two records share a key.
/// `members: true` (or `kind: .members`) on a string-set field registers its
/// member index instead, and `kind: .text` a full-text index over one or more
/// string fields, with its options under `text`. `on` places the index:
/// `.both` (the default for a field index), `.server` (the default for a
/// member index) or `.device`; a `unique` index needs `.server` or `.both`, a
/// text index `.device`, and on a db3 that lives only on this device every
/// index is on the device. A placement changes by dropping the index and
/// registering it again.
///
/// ```swift
/// try await client.db3.indexes.register(db3Id, Db3IndexRegistration(model: "Note", field: "email"))
/// try await client.db3.indexes.register(
///     db3Id, Db3IndexRegistration(model: "Note", fields: ["ownerId", "slug"], unique: true, name: "owner_slug")
/// )
/// try await client.db3.indexes.register(db3Id, Db3IndexRegistration(model: "Note", field: "tags", members: true))
/// try await client.db3.indexes.register(db3Id, Db3IndexRegistration(model: "Note", field: "status", on: .device))
/// try await client.db3.indexes.register(db3Id, Db3IndexRegistration(
///     model: "Note", field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(distance: .cos, index: .ann(nbucket: 64))
/// ))
/// try await client.db3.indexes.register(
///     db3Id, Db3IndexRegistration(model: "Note", fields: ["title", "body"], kind: .text, on: .device,
///                                 text: Db3TextIndexOptions(weights: ["title": 3]))
/// )
/// ```
public struct Db3IndexRegistration: Sendable, Encodable {
    /// - Stability: beta
    public let model: String
    /// - Stability: beta
    public let field: String?
    /// - Stability: beta
    public let fields: [String]?
    /// - Stability: beta
    public let unique: Bool?
    /// - Stability: beta
    public let name: String?
    /// `true` for a string-set field's member index; `nil` for any other index.
    /// - Stability: beta
    public let members: Bool?
    /// What the index is; `nil` sends none (`.scalar`, or `.members` with `members: true`).
    /// - Stability: beta
    public let kind: Db3IndexKind?
    /// Where the index lives; `nil` sends none (`.both` for a field index, `.server` for a member index).
    /// - Stability: beta
    public let on: Db3IndexPlacement?
    /// A text index's options (`kind: .text` only); `nil` sends none, the defaults.
    /// - Stability: beta
    public let text: Db3TextIndexOptions?
    /// A `.vector` index's options (#5225); `nil` sends none, and on any other kind.
    /// - Stability: beta
    public let vector: Db3VectorIndexOptions?

    /// An index on one field.
    public init(
        model: String, field: String, unique: Bool? = nil, name: String? = nil, kind: Db3IndexKind? = nil, on: Db3IndexPlacement? = nil,
        text: Db3TextIndexOptions? = nil
    ) {
        self.model = model
        self.field = field
        self.fields = nil
        self.unique = unique
        self.name = name
        self.members = nil
        self.kind = kind
        self.on = on
        self.text = text
        self.vector = nil
    }

    /// A composite index over `fields`, in order; with `kind: .text`, a text index over them.
    public init(
        model: String, fields: [String], unique: Bool? = nil, name: String? = nil, kind: Db3IndexKind? = nil,
        on: Db3IndexPlacement? = nil, text: Db3TextIndexOptions? = nil
    ) {
        self.model = model
        self.field = nil
        self.fields = fields
        self.unique = unique
        self.name = name
        self.members = nil
        self.kind = kind
        self.on = on
        self.text = text
        self.vector = nil
    }

    /// A member index on the string-set `field`: the db3 builds it from its
    /// records in one request and keeps it on every write, so `$contains`,
    /// any-of, membership levels and unfiltered facets on the field read it.
    /// A synced db3's copy on this device builds nothing for it; a db3 that
    /// lives only on this device builds it here. It takes no `unique` or `name`.
    public init(model: String, field: String, members: Bool, kind: Db3IndexKind? = nil, on: Db3IndexPlacement? = nil) {
        self.model = model
        self.field = field
        self.fields = nil
        self.unique = nil
        self.name = nil
        self.members = members
        self.kind = kind
        self.on = on
        self.text = nil
        self.vector = nil
    }

    /// A vector index on the vector field `field` (#5225), searched as
    /// `vector` says; a vector index lives on the device. It takes no
    /// `unique` or `name`. The field's `dims` and `element` come from its
    /// declaration.
    public init(model: String, field: String, kind: Db3IndexKind, vector: Db3VectorIndexOptions?, on: Db3IndexPlacement? = nil) {
        self.model = model
        self.field = field
        self.fields = nil
        self.unique = nil
        self.name = nil
        self.members = nil
        self.kind = kind
        self.on = on
        self.text = nil
        self.vector = vector
    }
}

/// A `vector` index's options (#5225): how a device searches a vector field.
public struct Db3VectorIndexOptions: Sendable, Encodable, Equatable {
    /// How nearness is measured.
    public enum Distance: String, Sendable, Codable, Equatable, CaseIterable {
        /// Cosine distance.
        case cos
        /// Euclidean distance.
        case l2
    }

    /// How each vector of an approximate index is quantized.
    public enum Quantizer: String, Sendable, Codable, Equatable, CaseIterable {
        case pq
        case opq
        case bq
    }

    /// How the index searches: every vector, or an approximate index. A
    /// listing decodes it from `"exact"` or `{ mode: "ann", … }`.
    public enum Mode: Sendable, Codable, Equatable {
        /// Compare every vector (the default).
        case exact
        /// Keep an approximate index: `nbucket` buckets the vectors are
        /// partitioned into, `codesize` bytes per quantized vector, and how
        /// each is quantized.
        case ann(nbucket: Int? = nil, codesize: Int? = nil, quantizer: Quantizer? = nil)

        private enum Keys: String, CodingKey { case mode, nbucket, codesize, quantizer }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                guard text == "exact" else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an index mode is exact or { mode: ann }"))
                }
                self = .exact
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            guard try container.decode(String.self, forKey: .mode) == "ann" else {
                self = .exact
                return
            }
            self = .ann(
                nbucket: try container.decodeIfPresent(Int.self, forKey: .nbucket), codesize: try container.decodeIfPresent(Int.self, forKey: .codesize),
                // A quantizer this build has no case for (`none`) reads as none given.
                quantizer: (try? container.decodeIfPresent(String.self, forKey: .quantizer)).flatMap { $0.flatMap(Quantizer.init(rawValue:)) }
            )
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .exact:
                var container = encoder.singleValueContainer()
                try container.encode("exact")
            case .ann(let nbucket, let codesize, let quantizer):
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode("ann", forKey: .mode)
                try container.encodeIfPresent(nbucket, forKey: .nbucket)
                try container.encodeIfPresent(codesize, forKey: .codesize)
                try container.encodeIfPresent(quantizer, forKey: .quantizer)
            }
        }
    }

    /// `nil` sends none: the room's default.
    /// - Stability: beta
    public var distance: Distance?
    /// `nil` sends none: `.exact`.
    /// - Stability: beta
    public var index: Mode?

    public init(distance: Distance? = nil, index: Mode? = nil) {
        self.distance = distance
        self.index = index
    }
}

/// The indexes a db3's room places on this device (#5322): their statuses
/// here, and this device's decline or accept of one.
struct Db3DeviceIndexDoor: Sendable {
    var list: @Sendable (String) async throws -> [Db3LocalIndex]
    var skipped: @Sendable (String) async throws -> [Db3SkippedIndex] = { db3Id in throw db3NotResidentError([db3Id]) }
    var change: @Sendable (_ db3Id: String, _ name: String, _ decline: Bool) async throws -> Db3LocalIndex
}

/// The indexes of a db3 that lives only on this device (#5155): its list,
/// registrations and drops, kept on the device by the room's rules.
struct Db3LocalIndexDoor: Sendable {
    var isLocalOnly: @Sendable (String) async -> Bool
    var list: @Sendable (String) async throws -> [Db3Index]
    var register: @Sendable (String, Db3IndexRegistration) async throws -> Db3Index
    var drop: @Sendable (String, String) async throws -> Void
}

/// A db3's indexes, as `client.db3.indexes`. A declared `indexed` or `unique`
/// field has its index already; register one for a field you query without
/// declaring it, or for a composite unique key. A refusal throws the route's
/// `HttpError`, its `serverCode` naming why (`DB3_INDEX_NOT_UNIQUE`,
/// `DB3_INDEX_IN_USE`, `NOT_A_DB3`, …).
///
/// On a db3 that lives only on this device the list, registrations and drops
/// are the device's own, under the same names and origins and by the same
/// rules, and nothing is sent: a refusal is a `JsBaoError` with the room's
/// code and details (`details["db3Id"]` naming the db3), a unique
/// registration is enforced on the device until it is dropped, and a member
/// index (`members: true`) is built on the device and kept on every write.
///
/// ```swift
/// let index = try await client.db3.indexes.register(db3Id, Db3IndexRegistration(model: "Note", field: "email"))
/// let all = try await client.db3.indexes.list(db3Id)
/// try await client.db3.indexes.drop(db3Id, name: index.name)
/// ```
public final class Db3IndexesAPI: Sendable {
    private let transport: any Transport
    /// The wait for a pending create of the db3 a call names (#5000).
    private let awaitCreate: @Sendable (String) async throws -> Void
    /// Read the db3's list again into its local store when this client holds
    /// it open (#5101), after a registration, a drop or a model upload or
    /// delete the route answered.
    private let applyLocally: @Sendable (String) async throws -> Void
    /// The indexes of a db3 that lives only on this device, kept there (#5155).
    private let local: Db3LocalIndexDoor?
    /// The indexes placed on this device, and this device's policy over them (#5322).
    private let device: Db3DeviceIndexDoor?

    init(
        transport: any Transport, awaitCreate: @escaping @Sendable (String) async throws -> Void = { _ in },
        applyLocally: @escaping @Sendable (String) async throws -> Void = { _ in },
        local: Db3LocalIndexDoor? = nil, device: Db3DeviceIndexDoor? = nil
    ) {
        self.transport = transport
        self.awaitCreate = awaitCreate
        self.applyLocally = applyLocally
        self.local = local
        self.device = device
    }

    /// The local door, when `db3Id` lives only on this device.
    private func localDoor(_ db3Id: String) async -> Db3LocalIndexDoor? {
        guard let local, await local.isLocalOnly(db3Id) else { return nil }
        return local
    }

    private struct Listed: Decodable, Sendable { let indexes: [Db3Index] }
    private struct Registered: Decodable, Sendable { let index: Db3Index }

    private static func path(_ db3Id: String) -> String {
        "/db3/\(URLEncoding.encodeComponent(db3Id))/indexes"
    }

    /// Every index on the db3's records, sorted by name. Needs read access.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter db3Id: The db3.
    /// - Stability: beta
    public func list(_ db3Id: String) async throws -> [Db3Index] {
        if let local = await localDoor(db3Id) { return try await local.list(db3Id) }
        try await awaitCreate(db3Id)
        let listed: Listed = try await transport.request(method: .get, path: Self.path(db3Id))
        return listed.indexes
    }

    /// Register an index and answer it as it now is. Registering an index a
    /// declaration already keeps adds your origin to it. Needs the db3's
    /// owner, or an app owner or admin. On a db3 this client has subscribed
    /// (or opened), the local copy holds the index before this returns, so a
    /// query on the field right after uses it; another copy takes it at its
    /// next subscribe, before `ready()` returns.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - registration: The model and its field or fields.
    /// - Stability: beta
    public func register(_ db3Id: String, _ registration: Db3IndexRegistration) async throws -> Db3Index {
        if let local = await localDoor(db3Id) { return try await local.register(db3Id, registration) }
        try await awaitCreate(db3Id)
        let registered: Registered = try await transport.request(method: .post, path: Self.path(db3Id), body: registration)
        try await applyLocally(db3Id)
        return registered.index
    }

    /// Remove your registration of an index. The index is dropped when no
    /// origin keeps it; one a declaration still keeps is refused
    /// `DB3_INDEX_IN_USE`. On a db3 this client has subscribed (or opened),
    /// the local copy drops it before this returns.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The index's name, as `list(_:)` answers it.
    /// - Stability: beta
    public func drop(_ db3Id: String, name: String) async throws {
        if let local = await localDoor(db3Id) { return try await local.drop(db3Id, name) }
        try await awaitCreate(db3Id)
        try await transport.send(method: .delete, path: "\(Self.path(db3Id))/\(URLEncoding.encodeComponent(name))")
        try await applyLocally(db3Id)
    }

    /// The indexes the db3's room places on this device, sorted by name, each
    /// with how it stands here: `.built`, `.unbuilt` (with why) or `.declined`.
    /// An index placed on the server only is left out. Read from this device's
    /// copy, so nothing is sent; the copy must be bound here (subscribe to it
    /// first). On a db3 that lives only on this device every index is listed,
    /// never `.declined`.
    ///
    /// ```swift
    /// for index in try await client.db3.indexes.local(db3Id) where index.status != .built {
    ///     print(index.name, index.status, index.reason ?? "")
    /// }
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Throws: `.db3NotResident` for a db3 whose copy is not bound here.
    /// - Stability: beta
    public func local(_ db3Id: String) async throws -> [Db3LocalIndex] {
        guard let device else { throw db3NotResidentError([db3Id]) }
        return try await device.list(db3Id)
    }

    /// The entries of the db3's index list this device built nothing for,
    /// sorted by name, each with why: an index placed on the server only, and
    /// one the device cannot build (a name that is not an identifier, an index
    /// on `id`, which the primary key serves, a member or vector index over
    /// more than one field, text options it cannot read). ``local(_:)`` lists
    /// none of them. Read from this device's copy, so nothing is sent and it
    /// answers offline; the copy must be bound here (subscribe to it first).
    ///
    /// ```swift
    /// for index in try await client.db3.indexes.skipped(db3Id) {
    ///     print(index.name, index.model, index.reason)
    /// }
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    /// - Throws: `.db3NotResident` for a db3 whose copy is not bound here.
    /// - Stability: beta
    public func skipped(_ db3Id: String) async throws -> [Db3SkippedIndex] {
        guard let device else { throw db3NotResidentError([db3Id]) }
        return try await device.skipped(db3Id)
    }

    /// Stop building an index on this device: its local table or index is
    /// dropped before this returns, and it stays unbuilt across restarts,
    /// index-list refreshes, a drop and re-registration of the same index and
    /// an evict, until ``accept(_:name:)`` (or `client.db3.delete`). The room's
    /// index list is not changed, and other devices and the server keep the
    /// index. On this device a `$search` that needs a declined text index is
    /// refused `.db3IndexDeclinedOnDevice`; a query a declined scalar or
    /// member index only speeds answers by a scan. Nothing is sent.
    ///
    /// ```swift
    /// try await client.db3.indexes.decline(db3Id, name: "idx_text_note")
    /// ```
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The index's name, as ``local(_:)`` lists it.
    /// - Returns: Its status here: `.declined`.
    /// - Throws: `.db3IndexNotFound` for a name placed on no device;
    ///   `.db3LocalOnly` on a db3 that lives only on this device (drop its index instead).
    /// - Stability: beta
    @discardableResult
    public func decline(_ db3Id: String, name: String) async throws -> Db3LocalIndex {
        if await localDoor(db3Id) != nil {
            throw JsBaoError(
                code: .db3LocalOnly,
                message: "client.db3.indexes.decline: the db3 '\(db3Id)' lives only on this device, whose indexes are its own: "
                    + "remove one with client.db3.indexes.drop(db3Id, name:)",
                details: ["db3Id": .string(db3Id)]
            )
        }
        guard let device else { throw db3NotResidentError([db3Id]) }
        return try await device.change(db3Id, name, true)
    }

    /// Build an index on this device again: one declined, one the client's
    /// `deviceIndexes` option leaves out, or one whose build failed. It is
    /// built before this returns, from the copy's rows; when the build fails
    /// again the answer is `.unbuilt` with why, and every later sync retries.
    /// An index already built answers `.built` and is not rebuilt. Nothing is
    /// sent. Throws as ``decline(_:name:)`` does.
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The index's name, as ``local(_:)`` lists it.
    /// - Returns: Its status here.
    /// - Stability: beta
    @discardableResult
    public func accept(_ db3Id: String, name: String) async throws -> Db3LocalIndex {
        if await localDoor(db3Id) != nil {
            throw JsBaoError(
                code: .db3LocalOnly,
                message: "client.db3.indexes.accept: the db3 '\(db3Id)' lives only on this device, whose indexes are its own: "
                    + "register or drop them with client.db3.indexes.register and client.db3.indexes.drop(db3Id, name:)",
                details: ["db3Id": .string(db3Id)]
            )
        }
        guard let device else { throw db3NotResidentError([db3Id]) }
        return try await device.change(db3Id, name, false)
    }
    /// The model refusal of a db3 that lives only on this device: its vector
    /// indexes train and keep their models on the device.
    private func refuseLocalOnlyModel(_ db3Id: String, _ call: String) async throws {
        guard await localDoor(db3Id) != nil else { return }
        throw JsBaoError(
            code: .db3LocalOnly,
            message: "\(call): the db3 '\(db3Id)' lives only on this device, whose vector indexes train and keep their models on this device",
            details: ["db3Id": .string(db3Id)]
        )
    }

    private var models: Db3IndexModelHttp { Db3IndexModelHttp(transport: transport) }

    /// Read an `ann` vector index's shared model: its bytes (the model in its
    /// `pvm1` envelope) and what it was uploaded with. Devices fetch and
    /// install the model on their own, so most apps never call this. Needs
    /// read access. Refused `DB3_INDEX_MODEL_NOT_FOUND` while the index has
    /// none.
    ///
    /// ```swift
    /// let model = try await client.db3.indexes.fetchModel(db3Id, name: "idx_vec_note_embedding")
    /// print(model.revision, model.rows, model.bytes.count)
    /// ```
    ///
    /// - Stability: beta
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The vector index's name, as ``list(_:)`` answers it.
    public func fetchModel(_ db3Id: String, name: String) async throws -> Db3IndexModel {
        try await refuseLocalOnlyModel(db3Id, "client.db3.indexes.fetchModel")
        try await awaitCreate(db3Id)
        let fetched = try await models.fetch(db3Id, name)
        guard let trainedAt = RecordLogVectorModelCheck.date(fetched.trainedAt) else {
            throw Db3IndexModelHttp.Malformed(message: "the model's trained-at header is not a date: \(fetched.trainedAt)")
        }
        return Db3IndexModel(
            bytes: fetched.bytes, generation: fetched.generation, revision: fetched.revision, rows: fetched.rows, trainedAt: trainedAt,
            format: fetched.format
        )
    }

    /// Upload an `ann` vector index's model trained elsewhere: every device
    /// holding the db3 checks it against its registration and installs it.
    /// The bytes are a model in its `pvm1` envelope, at most 64 MiB; the
    /// server stores them as they are. Devices train and upload a model on
    /// their own when none is listed, so most apps never call this. Needs
    /// read-write access. Refused `DB3_INDEX_MODEL_EXISTS` once a model is
    /// uploaded (or while a device's upload is under way),
    /// `DB3_INDEX_GENERATION_STALE` and `DB3_INDEX_MODEL_STALE` when the
    /// index moved on since `upload`'s values were listed,
    /// `DB3_INDEX_MODEL_TOO_LARGE` past 64 MiB, `DB3_INDEX_MODEL_INVALID` for
    /// an empty body. On a db3 this client has subscribed (or opened), the
    /// local copy reads the index list again before this returns.
    ///
    /// - Stability: beta
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The vector index's name, as ``list(_:)`` answers it.
    ///   - bytes: The model in its `pvm1` envelope.
    ///   - upload: The index's generation and revision as ``list(_:)`` answers them, and how the model was trained.
    /// - Returns: The index as it now is, listing its `annModel`.
    public func uploadModel(_ db3Id: String, name: String, bytes: Data, upload: Db3IndexModelUpload) async throws -> Db3Index {
        try await refuseLocalOnlyModel(db3Id, "client.db3.indexes.uploadModel")
        try await awaitCreate(db3Id)
        let index = try await models.upload(db3Id, name, bytes: bytes, Db3IndexModelHttp.Metadata(
            generation: upload.generation, revision: upload.revision, rows: upload.rows,
            trainedAt: Self.isoDate(upload.trainedAt), format: upload.format
        ))
        try await applyLocally(db3Id)
        return try JSONDecoder().decode(Db3Index.self, from: Data(RecordLogJSON.text(index).utf8))
    }

    /// Delete an `ann` vector index's shared model, or a device's upload
    /// under way, so a device trains it again: every device drops its copy
    /// and answers `$near` exactly until a new model is installed, and an
    /// upload naming the old revision is refused. Needs the db3's owner (or
    /// an app owner or admin). Refused `DB3_INDEX_MODEL_NOT_FOUND` when there
    /// is neither. On a db3 this client has subscribed (or opened), the local
    /// copy reads the index list again before this returns.
    ///
    /// ```swift
    /// let deleted = try await client.db3.indexes.deleteModel(db3Id, name: "idx_vec_note_embedding")
    /// print(deleted.revision)
    /// ```
    ///
    /// - Stability: beta
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The vector index's name, as ``list(_:)`` answers it.
    /// - Returns: The index's new revision.
    @discardableResult
    public func deleteModel(_ db3Id: String, name: String) async throws -> Db3IndexModelDeletion {
        try await refuseLocalOnlyModel(db3Id, "client.db3.indexes.deleteModel")
        try await awaitCreate(db3Id)
        let deleted = try await models.delete(db3Id, name)
        try await applyLocally(db3Id)
        return Db3IndexModelDeletion(ok: deleted.ok, name: deleted.name, revision: deleted.revision)
    }

    /// `date` as the model routes carry it: ISO 8601 with milliseconds, in UTC, as JavaScript's `toISOString()` writes it.
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

}

// MARK: - Db3AliasesAPI

/// A user's aliases for db3s, as `client.db3.aliases`: stable keys that name
/// a db3, bound with `set(_:)`, read with `resolve(_:)` and removed with
/// `delete(_:)`, mirroring `client.documents.aliases` over the db3 alias
/// routes. Only `.user` scope exists; `userId` defaults to the caller, and
/// only an app owner or admin may name another member. A document that is
/// not a db3 is refused `HttpError` status 409, `serverCode` `"NOT_A_DB3"`;
/// an id that is no db3 of the app, 404 `"DB3_NOT_FOUND"`.
///
/// ```swift
/// let created = try await client.db3.create(title: "Inbox")
/// _ = try await client.db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "inbox", documentId: created.id))
/// let inbox = try await client.db3.aliases.resolve(AliasRef(scope: .user, aliasKey: "inbox"))
/// try await client.db3.aliases.delete(AliasRef(scope: .user, aliasKey: "inbox"))
/// ```
public final class Db3AliasesAPI: @unchecked Sendable {
    private let transport: any Transport
    /// The wait for a pending create of the db3 `set` names (#5000), which
    /// also refuses a db3 that lives only on this device (#5155).
    private let awaitCreate: @Sendable (String) async throws -> Void

    /// `client.db3.aliases`: `set` waits first for a pending create of its db3.
    init(transport: any Transport, awaitCreate: @escaping @Sendable (String) async throws -> Void) {
        self.transport = transport
        self.awaitCreate = awaitCreate
    }

    /// Bind a user alias to a db3, or re-point it. With `mustNotExist`, an
    /// existing alias is refused 409 `alias_exists` instead.
    ///
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameter params: The alias, the db3 as `documentId`, and `mustNotExist`.
    /// - Throws: `.db3LocalOnly` before any request for a db3 that lives only
    ///   on this device; `HttpError` 409 `NOT_A_DB3`, 404 `DB3_NOT_FOUND`.
    /// - Stability: beta
    public func set(_ params: SetAliasParams) async throws -> DocumentAliasInfo {
        try await awaitCreate(params.documentId)
        let encodedKey = URLEncoding.encodeComponent(params.aliasKey)
        var body: [String: JSONValue] = ["documentId": .string(params.documentId)]
        if let userId = params.userId { body["userId"] = .string(userId) }
        if params.mustNotExist == true { body["mustNotExist"] = .bool(true) }
        return try await transport.request(
            method: .put,
            path: "/db3-aliases/\(params.scope.rawValue)/\(encodedKey)",
            body: JSONValue.object(body)
        )
    }

    /// The db3 a user alias names, with the alias, or `nil` when the alias
    /// names nothing.
    ///
    /// - Parameter params: The alias; `userId` names another member's.
    /// - Throws: `HttpError` 409 `NOT_A_DB3` for an alias naming a document
    ///   that is not a db3, 403 `DOC_ACCESS_DENIED` when the caller cannot read it.
    /// - Stability: beta
    public func resolve(_ params: AliasRef) async throws -> Db3AliasResolution? {
        let encodedKey = URLEncoding.encodeComponent(params.aliasKey)
        var path = "/db3-aliases/\(params.scope.rawValue)/\(encodedKey)"
        if params.scope == .user, let userId = params.userId {
            var query = URLQuery()
            query.append("userId", userId)
            path += query.queryString
        }
        do {
            let resolved: Db3AliasResolution = try await transport.request(method: .get, path: path)
            return resolved
        } catch let error as HttpError where error.status == 404 {
            return nil
        }
    }

    /// Delete a user alias; an alias that names nothing returns quietly.
    ///
    /// - Parameter params: The alias; `userId` names another member's.
    /// - Throws: `HttpError` 409 `NOT_A_DB3` for an alias naming a document
    ///   that is not a db3, which is kept.
    /// - Stability: beta
    public func delete(_ params: AliasRef) async throws {
        let encodedKey = URLEncoding.encodeComponent(params.aliasKey)
        var path = "/db3-aliases/\(params.scope.rawValue)/\(encodedKey)"
        if params.scope == .user, let userId = params.userId {
            var query = URLQuery()
            query.append("userId", userId)
            path += query.queryString
        }
        do {
            let _: SuccessResult = try await transport.request(method: .delete, path: path)
        } catch let error as HttpError where error.status == 404 {
            return
        }
    }
}
