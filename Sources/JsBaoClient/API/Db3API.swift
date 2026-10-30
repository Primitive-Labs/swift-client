import Foundation

/// The options of `client.db3.subscribe(_:options:)` and `client.db3.refresh(_:options:)`.
public struct Db3SubscribeOptions: Sendable {
    /// How long `ready()` waits without progress before it throws
    /// `DB3_READY_TIMEOUT`, in seconds (30 by default). Each chunk or page that
    /// arrives starts the wait again; `.infinity` waits for as long as it
    /// takes, and `0` throws at once unless the db3 is already live here.
    public var readyTimeout: TimeInterval

    public init(readyTimeout: TimeInterval = 30) {
        self.readyTimeout = readyTimeout
    }
}

/// The options of `client.db3.evict(_:options:)`.
public struct Db3EvictOptions: Sendable {
    /// Remove the db3 even while it holds writes the room has not judged. They
    /// are handed back through `Db3WriteRefusedEvent` as `DOCUMENT_STORE_PURGED`.
    public var force: Bool

    public init(force: Bool = false) {
        self.force = force
    }
}

/// One db3 this device holds, as `client.db3.stored()` lists it.
public struct Db3StoredEntry: Sendable, Equatable {
    public let id: String
    /// How many records the local copy holds.
    public let rows: Int
    /// The room's log number the copy has caught up to.
    public let cursor: Int
    /// Writes made here the room has not judged yet.
    public let pendingWrites: Int
    /// When a load or catch-up last completed here, or `nil`.
    public let lastSyncAt: Date?
    /// Whether the copy is readable (see ``Db3State/resident``).
    public let resident: Bool

    public init(id: String, rows: Int, cursor: Int, pendingWrites: Int, lastSyncAt: Date?, resident: Bool) {
        self.id = id
        self.rows = rows
        self.cursor = cursor
        self.pendingWrites = pendingWrites
        self.lastSyncAt = lastSyncAt
        self.resident = resident
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
    public func ready() async throws {
        try await readySettlement.wait()
    }

    /// Returns as soon as a readable copy is on the device: at once for a
    /// resident db3 (an empty one that synced included), else when `ready()`
    /// does. Throws as `ready()` does until then.
    public func available() async throws {
        try await availableSettlement.wait()
    }

    /// The db3's latest state, as this client last read it.
    public var state: Db3State { owner.current(id) }

    /// This db3's events, from now on: each call answers a new stream,
    /// finished when its consumer stops iterating.
    public func stream() -> AsyncStream<Db3SubscriptionEvent> {
        AsyncStream { continuation in
            let observation = observe { event in continuation.yield(event) }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    /// Hear this db3's events; cancel the answered subscription to stop.
    /// - Parameter handler: Called with each event, on the thread that emitted it.
    public func observe(_ handler: @escaping @Sendable (Db3SubscriptionEvent) -> Void) -> EventSubscription {
        let token = UUID()
        lock.withLock { listeners[token] = handler }
        return EventSubscription { [weak self] in
            self?.lock.withLock { _ = self?.listeners.removeValue(forKey: token) }
        }
    }

    /// Give this subscription up. Disposing twice is disposing once.
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
    public let indexes: Db3IndexesAPI
    /// A db3's bulk loads: build, create, upload, commit, follow, abort and list.
    public let ingests: Db3IngestsAPI
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
        self.indexes = Db3IndexesAPI(transport: transport, awaitCreate: awaitCreate)
        self.ingests = Db3IngestsAPI(transport: transport, awaitCreate: awaitCreate)
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
    public func subscribe(_ db3Id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) throws -> Db3Subscription {
        try lifecycle.subscribe(db3Id, options: options)
    }

    /// Dispose every subscription this client holds to a db3. The local copy stays readable.
    /// - Parameter db3Id: The db3.
    public func unsubscribe(_ db3Id: String) {
        lifecycle.unsubscribe(db3Id)
    }

    /// Bring a db3's local copy up to date once: subscribe, wait for `live`,
    /// dispose. Another caller's subscription is left as it is. Answers the
    /// db3's state afterwards.
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - options: How long it waits without progress.
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
    public func evict(_ db3Id: String, options: Db3EvictOptions = Db3EvictOptions()) async throws {
        try await lifecycle.evict(db3Id, options: options)
    }

    /// Every db3 this device holds for the signed-in user, with its size and sync state, sorted by id.
    public func stored() async throws -> [Db3StoredEntry] {
        try await lifecycle.stored()
    }

    /// A db3's state on this device, without subscribing. A db3 never seen
    /// here answers `idle`, not resident, with nothing stored.
    /// - Parameter db3Id: The db3.
    public func state(_ db3Id: String) async throws -> Db3State {
        try await lifecycle.state(db3Id)
    }

    /// Set the client's retention policy (the one `client.retentionPolicy`
    /// holds): what the device keeps, and for how long. A db3 holding
    /// unjudged writes, or one subscribed here, is never removed by it.
    /// - Parameter policy: The policy.
    public func setRetentionPolicy(_ policy: RetentionPolicy) {
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
    /// ```swift
    /// let orders = try await client.db3.create(title: "Orders", type: "orders")
    /// let answer = try await client.documents.commitOfflineCreate(documentId: orders.id)
    /// let archive = try await client.db3.create(title: "Archive", sync: false) // an app owner or admin only
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
    /// - Throws: `JsBaoError(.invalidArgument)` with no signed-in user. A
    ///   sync-off or custodian-naming create throws the route's `HttpError`,
    ///   its `serverCode` naming why: 403 for a member's sync-off create, 404
    ///   `DB3_TYPE_NOT_FOUND`, 409 `DB3_TYPE_REFUSED` or
    ///   `DB3_TYPE_REVISION_CONFLICT`.
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
    public func get(_ db3Id: String) async throws -> Db3Info {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .get, path: Self.path(db3Id))
    }

    /// Delete a db3 with its records, grants and blobs. Its owner deletes it,
    /// and so does an app owner or admin.
    ///
    /// ```swift
    /// _ = try await client.db3.delete(db3Id)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    public func delete(_ db3Id: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: Self.path(db3Id))
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
    /// for yourself is read-only here at once: a save throws `.accessDenied`
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
    public func transfer(_ db3Id: String, to custodian: String) async throws -> Db3Info {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .post, path: Self.path(db3Id, "/transfer"), body: JSONValue.object(["to": .string(custodian)]))
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
    public func permissions(_ db3Id: String) -> Db3PermissionsAPI {
        Db3PermissionsAPI(db3Id: db3Id, transport: transport) { [weak self] id in try await self?.awaitCreate(id) }
    }

    // MARK: - Blobs

    /// A db3's blobs: upload, list, read, download URLs, delete, and its
    /// upload queue. An upload made offline, or to a db3 created here whose
    /// create the server does not have yet, is queued and answered at once
    /// (`bytesTransferred == 0`), and sent once the client is online and the
    /// server has the db3.
    ///
    /// ```swift
    /// let blobs = client.db3.blobs(db3Id)
    /// let uploaded = try await blobs.upload(data: data, options: BlobUploadSourceOptions(filename: "notes.txt"))
    /// let url = blobs.downloadUrl(blobId: uploaded.blobId, disposition: .inline)
    /// ```
    ///
    /// - Parameter db3Id: The db3.
    public func blobs(_ db3Id: String) -> Db3BlobContext {
        Db3BlobContext(db3Id: db3Id, transport: transport, blobManager: blobManager)
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
    public func setOwnerRow(_ db3Id: String, present: Bool) async throws -> Db3OwnerRowChange {
        try await awaitCreate(db3Id)
        return try await transport.request(method: .put, path: Self.path(db3Id, "/owner-row"), body: JSONValue.object(["present": .bool(present)]))
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

    public let kind: Kind
    /// Whether this origin asks for the index's fields to be unique.
    public let unique: Bool

    public init(kind: Kind, unique: Bool) {
        self.kind = kind
        self.unique = unique
    }
}

/// One index on a db3's records, as `client.db3.indexes.list(_:)` answers it.
public struct Db3Index: Sendable, Equatable, Decodable {
    /// `idx_records_<model>_<field>` for a field's shared index,
    /// `idx_uc_<model>_<constraint>` for a declared compound constraint,
    /// `idx_named_<model>_<name>` for one registered with a name.
    public let name: String
    /// The model whose records the index covers.
    public let model: String
    /// The fields, in index order.
    public let fields: [String]
    /// Whether uniqueness is enforced: true while any origin asks for it.
    public let unique: Bool
    /// Every origin keeping the index. It is dropped when the last one goes.
    public let origins: [Db3IndexOrigin]
}

/// What `client.db3.indexes.register(_:_:)` registers: a model and one field,
/// or a composite (a unique constraint, which also needs `unique: true` and a
/// `name`). `unique: true` refuses the registration while two records share a key.
///
/// ```swift
/// try await client.db3.indexes.register(db3Id, Db3IndexRegistration(model: "Note", field: "email"))
/// try await client.db3.indexes.register(
///     db3Id, Db3IndexRegistration(model: "Note", fields: ["ownerId", "slug"], unique: true, name: "owner_slug")
/// )
/// ```
public struct Db3IndexRegistration: Sendable, Encodable {
    public let model: String
    public let field: String?
    public let fields: [String]?
    public let unique: Bool?
    public let name: String?

    /// An index on one field.
    public init(model: String, field: String, unique: Bool? = nil, name: String? = nil) {
        self.model = model
        self.field = field
        self.fields = nil
        self.unique = unique
        self.name = name
    }

    /// A composite index over `fields`, in order.
    public init(model: String, fields: [String], unique: Bool? = nil, name: String? = nil) {
        self.model = model
        self.field = nil
        self.fields = fields
        self.unique = unique
        self.name = name
    }
}

/// A db3's indexes, as `client.db3.indexes`. A declared `indexed` or `unique`
/// field has its index already; register one for a field you query without
/// declaring it, or for a composite unique key. A refusal throws the route's
/// `HttpError`, its `serverCode` naming why (`DB3_INDEX_NOT_UNIQUE`,
/// `DB3_INDEX_IN_USE`, `NOT_A_DB3`, …).
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

    init(transport: any Transport, awaitCreate: @escaping @Sendable (String) async throws -> Void = { _ in }) {
        self.transport = transport
        self.awaitCreate = awaitCreate
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
    public func list(_ db3Id: String) async throws -> [Db3Index] {
        try await awaitCreate(db3Id)
        let listed: Listed = try await transport.request(method: .get, path: Self.path(db3Id))
        return listed.indexes
    }

    /// Register an index and answer it as it now is. Registering an index a
    /// declaration already keeps adds your origin to it. Needs the db3's
    /// owner, or an app owner or admin.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - registration: The model and its field or fields.
    public func register(_ db3Id: String, _ registration: Db3IndexRegistration) async throws -> Db3Index {
        try await awaitCreate(db3Id)
        let registered: Registered = try await transport.request(method: .post, path: Self.path(db3Id), body: registration)
        return registered.index
    }

    /// Remove your registration of an index. The index is dropped when no
    /// origin keeps it; one a declaration still keeps is refused
    /// `DB3_INDEX_IN_USE`.
    /// Waits first for a pending create of the db3 to commit: throws `.pendingCreate`
    /// offline or after 30 seconds, or the create's refusal (see ``Db3API``).
    ///
    /// - Parameters:
    ///   - db3Id: The db3.
    ///   - name: The index's name, as `list(_:)` answers it.
    public func drop(_ db3Id: String, name: String) async throws {
        try await awaitCreate(db3Id)
        return try await transport.send(method: .delete, path: "\(Self.path(db3Id))/\(URLEncoding.encodeComponent(name))")
    }
}
