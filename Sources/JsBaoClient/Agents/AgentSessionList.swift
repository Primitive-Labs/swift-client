import Foundation

// A live list of the signed-in user's agent sessions — the Swift half of the
// JS client's `src/client/agents/sessionList.ts`, rule for rule.
//
// `client.agents.sessions.watch` reads the first page with `list`, then keeps
// its items current from the `AgentSessionChangedEvent`s the server sends for
// every change to one of the user's sessions: activity, a read mark, a status
// change, a rename, a member change, a removal or a delete. Items are ordered
// by last activity, newest first. A reconnect reads the loaded pages again
// and merges them field by field with what the events already said.

/// Filters and page size for `client.agents.sessions.watch`.
public struct WatchAgentSessionsOptions: Sendable, Equatable {
    /// Only this agent's sessions.
    public var agent: String?
    /// Only sessions created with exactly this scope.
    public var scope: String?
    /// Page size for the first page and each `loadMore()`, at most 100 (the
    /// server's default is 50).
    public var limit: Int?
    /// Leave `nil`: a watched list is always the signed-in user's own, and
    /// naming a user throws `.invalidArgument`. An app owner or admin reads
    /// another user's sessions with `list`.
    public var userId: String?

    public init(agent: String? = nil, scope: String? = nil, limit: Int? = nil, userId: String? = nil) {
        self.agent = agent
        self.scope = scope
        self.limit = limit
        self.userId = userId
    }
}

/// An entry of a watched list: the list item, and the members once a change
/// event told them. Reads the item's fields directly (`entry.title`).
@dynamicMemberLookup
public struct AgentSessionWatchedItem: Sendable, Equatable {
    /// The session's list item, kept current.
    public let item: AgentSessionListItem
    /// The session's members, from the latest change event; `nil` until one
    /// arrives.
    public let members: AgentSessionMembers?

    public init(item: AgentSessionListItem, members: AgentSessionMembers?) {
        self.item = item
        self.members = members
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<AgentSessionListItem, T>) -> T {
        item[keyPath: keyPath]
    }
}

/// What a watched list needs of the client: the list call, the change events
/// and the connection state. `client.agents.sessions.watch` builds it.
struct AgentSessionListHost: Sendable {
    let list: @Sendable (ListAgentSessionsOptions) async throws -> PaginatedResult<AgentSessionListItem>
    let changes: @Sendable () -> AsyncStream<AgentSessionChangedEvent>
    let statuses: @Sendable () -> AsyncStream<ConnectionStatus>
    let isConnected: @Sendable () -> Bool
}

/// A live list of your agent sessions, from `client.agents.sessions.watch`.
///
/// Read `items` (kept current, newest activity first), call `onChange` to
/// hear about every change, `loadMore()` for the next page, and `close()`
/// when done.
public final class AgentSessionList: @unchecked Sendable {
    /// How long a change waits for others before listeners hear of it.
    static let notifyCoalesceWindow: DispatchTimeInterval = .milliseconds(15)

    private struct Entry {
        var item: AgentSessionWatchedItem
        /// The `at` of the latest event applied; `nil` when the entry came
        /// from a page.
        var at: Double?
    }

    private let host: AgentSessionListHost
    private let options: WatchAgentSessionsOptions
    private let lock = NSLock()

    // Guarded by `lock`.
    private var entries: [String: Entry] = [:]
    /// When each session was removed for you, by id: an older upsert is ignored.
    private var tombstones: [String: Double] = [:]
    private var view: [AgentSessionWatchedItem] = []
    private var cursor: String?
    private var more = false
    /// `hasMore` as listeners last saw it.
    private var shownMore = false
    /// How many pages are loaded: a refresh reads that many again.
    private var pages = 0
    /// Events that arrived while a page was being read, applied after it.
    private var buffered: [AgentSessionChangedEvent]?
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    private var notifyQueued = false
    private var closed = false
    /// Whether the connection now up has been heard since the pages were read.
    private var live = false
    private var tail: Task<Void, Never>?
    private var refreshing: Task<Void, Error>?
    private var refreshAgain = false
    private var consumers: [Task<Void, Never>] = []

    init(host: AgentSessionListHost, options: WatchAgentSessionsOptions) {
        self.host = host
        self.options = options
    }

    /// Watch your sessions over `host` — what `client.agents.sessions.watch`
    /// runs: subscribe to the change events, then read the first page (events
    /// that arrive meanwhile are applied after it). Throws as `list` does.
    static func watch(host: AgentSessionListHost, options: WatchAgentSessionsOptions) async throws -> AgentSessionList {
        if options.userId != nil {
            throw JsBaoError(
                code: .invalidArgument,
                message: "watch lists your own sessions; it takes no userId",
                details: ["field": .string("userId")]
            )
        }
        let list = AgentSessionList(host: host, options: options)
        do {
            try await list.start()
        } catch {
            list.close()
            throw error
        }
        return list
    }

    // MARK: - State

    /// The loaded sessions, newest activity first.
    public var items: [AgentSessionWatchedItem] { lock.withLock { view } }

    /// Whether a further page remains (`loadMore()`).
    public var hasMore: Bool { lock.withLock { more } }

    /// Listen for changes to `items` or `hasMore`. Calls are coalesced over a
    /// short window, and never made while the list holds its lock.
    ///
    /// - Returns: A function that removes the listener.
    @discardableResult
    public func onChange(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.withLock {
            guard !closed else { return }
            listeners[id] = listener
        }
        return { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.listeners.removeValue(forKey: id) }
        }
    }

    /// Load the next page; returns at once, with no request, when there is none.
    public func loadMore() async throws {
        guard lock.withLock({ !closed && more }) else { return }
        try await serial { [weak self] in
            guard let self else { return }
            let next: String?? = self.lock.withLock { (!self.closed && self.more) ? .some(self.cursor) : .none }
            guard let next else { return }
            try await self.reading {
                let page = try await self.host.list(self.pageOptions(cursor: next))
                self.lock.withLock {
                    guard !self.closed else { return }
                    self.pages += 1
                    self.takePageLocked(page)
                    for item in page.items { self.mergeRowLocked(item) }
                }
            }
        }
    }

    /// Read the loaded pages again and merge each item with what the change
    /// events already said: the later of each instant, the dot recomputed from
    /// them, the status of whichever is newer, and the title, scope and role
    /// as listed. A session no longer in those pages leaves the list. The
    /// list also refreshes itself after every reconnect. A call while a
    /// refresh runs makes one more after it.
    public func refresh() async throws {
        let task: Task<Void, Error>? = lock.withLock {
            guard !closed else { return nil }
            if let refreshing {
                refreshAgain = true
                return refreshing
            }
            let task = Task<Void, Error> { [weak self] in
                while let self {
                    do {
                        try await self.serial { [weak self] in try await self?.refreshNow() }
                    } catch {
                        // A refresh asked for while this one ran still runs (CSO-4380-018).
                        let again: Bool = self.lock.withLock {
                            if self.refreshAgain && !self.closed {
                                self.refreshAgain = false
                                return true
                            }
                            self.refreshing = nil
                            return false
                        }
                        if again { continue }
                        throw error
                    }
                    let again: Bool = self.lock.withLock {
                        if self.refreshAgain && !self.closed {
                            self.refreshAgain = false
                            return true
                        }
                        self.refreshing = nil
                        return false
                    }
                    if !again { break }
                }
            }
            refreshing = task
            return task
        }
        try await task?.value
    }

    /// Stop listening: nothing changes after this and no listener is called.
    public func close() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            listeners.removeAll()
            buffered = nil
            defer { consumers.removeAll() }
            return consumers
        }
        for task in tasks { task.cancel() }
    }

    // MARK: - Internals

    private func start() async throws {
        let changes = host.changes()
        let statuses = host.statuses()
        // A connection already up when the first page is read hears every event since.
        let connected = host.isConnected()
        let tasks = [
            Task { [weak self] in
                for await event in changes { self?.onEvent(event) }
            },
            Task { [weak self] in
                for await status in statuses { self?.onStatus(status) }
            },
        ]
        lock.withLock {
            live = connected
            consumers.append(contentsOf: tasks)
        }
        try await serial { [weak self] in
            guard let self else { return }
            try await self.reading {
                let page = try await self.host.list(self.pageOptions(cursor: nil))
                self.lock.withLock {
                    guard !self.closed else { return }
                    self.pages = 1
                    self.takePageLocked(page)
                    for item in page.items { self.mergeRowLocked(item) }
                }
            }
        }
    }

    private func pageOptions(cursor: String?) -> ListAgentSessionsOptions {
        ListAgentSessionsOptions(agent: options.agent, scope: options.scope, limit: options.limit, cursor: cursor)
    }

    /// One operation at a time, in call order.
    private func serial(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let task: Task<Void, Error> = lock.withLock {
            let previous = tail
            let next = Task<Void, Error> {
                await previous?.value
                try await body()
            }
            tail = Task { _ = try? await next.value }
            return next
        }
        try await task.value
    }

    /// Read pages with events held back, then apply the events in arrival order.
    private func reading(_ body: @escaping @Sendable () async throws -> Void) async throws {
        lock.withLock { buffered = [] }
        var thrown: Error?
        do {
            try await body()
        } catch {
            thrown = error
        }
        let changed: Bool = lock.withLock {
            let held = buffered ?? []
            buffered = nil
            guard !closed else { return false }
            for event in held { _ = applyLocked(event) }
            return rebuildLocked()
        }
        if changed { scheduleNotify() }
        if let thrown { throw thrown }
    }

    private func refreshNow() async throws {
        guard lock.withLock({ !closed }) else { return }
        try await reading { [weak self] in
            guard let self else { return }
            let wanted = max(1, self.lock.withLock { self.pages })
            var rows: [AgentSessionListItem] = []
            var cursor: String?
            var read = 0
            var last: PaginatedResult<AgentSessionListItem>?
            repeat {
                let page = try await self.host.list(self.pageOptions(cursor: cursor))
                // Closed while the page was read: no further page (CSO-4380-012).
                guard self.lock.withLock({ !self.closed }) else { return }
                last = page
                read += 1
                rows.append(contentsOf: page.items)
                cursor = page.hasMore ? page.nextCursor : nil
            } while cursor != nil && read < wanted
            self.lock.withLock {
                guard !self.closed else { return }
                self.pages = read
                self.cursor = last?.nextCursor
                self.more = last?.hasMore == true && last?.nextCursor != nil
                let listed = Set(rows.map(\.sessionId))
                for sessionId in Array(self.entries.keys) where !listed.contains(sessionId) {
                    // Not in the pages: deleted, no longer yours, or older than they reach (CSO-4380-003).
                    self.entries[sessionId] = nil
                }
                for row in rows { self.mergeRowLocked(row) }
            }
        }
    }

    private func takePageLocked(_ page: PaginatedResult<AgentSessionListItem>) {
        cursor = page.nextCursor
        more = page.hasMore && page.nextCursor != nil
    }

    /// A listed row merged into what the list holds, field by field.
    private func mergeRowLocked(_ row: AgentSessionListItem) {
        if let removedAt = tombstones[row.sessionId] {
            // A row is created when its user joins: one older than the removal is
            // a stale read of the deleted row, one newer is a re-addition (CSO-4380-011).
            if (Self.ms(row.createdAt) ?? 0) <= removedAt { return }
            tombstones[row.sessionId] = nil
        }
        guard let held = entries[row.sessionId] else {
            entries[row.sessionId] = Entry(item: AgentSessionWatchedItem(item: row, members: nil), at: nil)
            return
        }
        let lastActivityAt = Self.laterOf(held.item.lastActivityAt, row.lastActivityAt) ?? row.lastActivityAt
        let lastReadAt = Self.laterOf(held.item.lastReadAt, row.lastReadAt)
        let heldNewer = (Self.ms(held.item.lastActivityAt) ?? 0) > (Self.ms(row.lastActivityAt) ?? 0)
        let merged = row.with(
            lastActivityAt: lastActivityAt,
            lastReadAt: lastReadAt,
            hasUnread: Self.unread(lastActivityAt, lastReadAt),
            status: heldNewer ? held.item.status : row.status
        )
        entries[row.sessionId] = Entry(item: AgentSessionWatchedItem(item: merged, members: held.item.members), at: held.at)
    }

    private func matches(_ item: AgentSessionListItem) -> Bool {
        if let agent = options.agent, item.agentKey != agent { return false }
        if let scope = options.scope, item.scope != scope { return false }
        return true
    }

    private func onEvent(_ event: AgentSessionChangedEvent) {
        let changed: Bool = lock.withLock {
            guard !closed else { return false }
            if buffered != nil {
                buffered?.append(event)
                return false
            }
            return applyLocked(event) && rebuildLocked()
        }
        if changed { scheduleNotify() }
    }

    /// One event applied; whether anything changed.
    private func applyLocked(_ event: AgentSessionChangedEvent) -> Bool {
        let at = Self.ms(event.at) ?? 0
        let removedAt = tombstones[event.sessionId]
        switch event.action {
        case .removed:
            tombstones[event.sessionId] = max(at, removedAt ?? 0)
            return entries.removeValue(forKey: event.sessionId) != nil
        case .upsert:
            break
        case .unknown:
            return false
        }
        guard let item = event.item else { return false }
        // An upsert older than the removal it follows is a stale copy.
        if let removedAt, at <= removedAt { return false }
        guard matches(item) else { return false }
        tombstones[event.sessionId] = nil
        let members = event.members ?? entries[event.sessionId]?.item.members
        guard let held = entries[event.sessionId] else {
            entries[event.sessionId] = Entry(item: AgentSessionWatchedItem(item: item, members: members), at: at)
            return true
        }
        let lastActivityAt = Self.laterOf(held.item.lastActivityAt, item.lastActivityAt) ?? held.item.lastActivityAt
        let lastReadAt = Self.laterOf(held.item.lastReadAt, item.lastReadAt)
        // An event older than the last one applied adds only its instants.
        let newer = held.at == nil || at >= held.at!
        let status: PrimitiveSessionStatus? = item.status ?? held.item.status
        let base = newer ? item.with(status: .some(status)) : held.item.item
        let merged = base.with(lastActivityAt: lastActivityAt, lastReadAt: lastReadAt, hasUnread: Self.unread(lastActivityAt, lastReadAt))
        entries[event.sessionId] = Entry(
            item: AgentSessionWatchedItem(item: merged, members: newer ? members : held.item.members),
            at: newer ? at : held.at
        )
        return true
    }

    private func onStatus(_ status: ConnectionStatus) {
        let refresh: Bool = lock.withLock {
            guard !closed else { return false }
            switch status {
            case .disconnected:
                live = false
                return false
            case .connected:
                // A connection that came up after the first page, or after a
                // drop, may have missed events; one already heard needs nothing.
                if live { return false }
                live = true
                return true
            case .connecting:
                return false
            }
        }
        guard refresh else { return }
        Task { [weak self] in try? await self?.refresh() }
    }

    private func rebuildLocked() -> Bool {
        let next = entries.values.map(\.item).sorted { a, b in
            let am = Self.ms(a.lastActivityAt) ?? 0
            let bm = Self.ms(b.lastActivityAt) ?? 0
            if am != bm { return am > bm }
            return a.sessionId > b.sessionId
        }
        // A change to `hasMore` alone is a change too (CSO-4380-008).
        let changed = next != view || more != shownMore
        view = next
        shownMore = more
        return changed
    }

    private func scheduleNotify() {
        let schedule: Bool = lock.withLock {
            guard !closed, !notifyQueued else { return false }
            notifyQueued = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.notifyCoalesceWindow) { [weak self] in
            guard let self else { return }
            let current: [@Sendable () -> Void] = self.lock.withLock {
                self.notifyQueued = false
                return self.closed ? [] : Array(self.listeners.values)
            }
            for listener in current { listener() }
        }
    }

    // MARK: - Instants

    static func ms(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return AgentSessionInstant.parse(value)
    }

    /// The later of two ISO instants; either may be `nil`.
    static func laterOf(_ a: String?, _ b: String?) -> String? {
        guard let am = ms(a) else { return b }
        guard let bm = ms(b) else { return a }
        return bm > am ? b : a
    }

    /// Whether there is activity after the read marker, compared as instants.
    static func unread(_ lastActivityAt: String?, _ lastReadAt: String?) -> Bool {
        guard let activity = ms(lastActivityAt) else { return false }
        guard let read = ms(lastReadAt) else { return true }
        return activity > read
    }
}

/// ISO-8601 instants as milliseconds since the epoch, with or without
/// fractional seconds.
enum AgentSessionInstant {
    static func parse(_ value: String) -> Double? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value).map { $0.timeIntervalSince1970 * 1000 }
    }
}

// MARK: - watch

extension AgentSessionsAPI {
    /// Watch your sessions: the first page of `list`, kept current as sessions
    /// change — new activity and the unread dot, read marks from your other
    /// devices, renames, status, members, removals and deletes — without
    /// opening any document. Items are ordered by last activity, newest
    /// first; `loadMore()` reads the next page, `onChange` hears every
    /// change, and the list reads its pages again after a reconnect. Call
    /// `close()` when done. Throws as `list` does; a `userId` throws
    /// `.invalidArgument` before any request.
    public func watch(options: WatchAgentSessionsOptions = WatchAgentSessionsOptions()) async throws -> AgentSessionList {
        if options.userId != nil {
            throw JsBaoError(
                code: .invalidArgument,
                message: "watch lists your own sessions; it takes no userId",
                details: ["field": .string("userId")]
            )
        }
        guard let client else {
            throw JsBaoError(code: .unavailable, message: "agents.sessions.watch requires a wired JsBaoClient")
        }
        let host = AgentSessionListHost(
            list: { [weak self] options in
                guard let self else {
                    throw JsBaoError(code: .unavailable, message: "The sessions API is gone")
                }
                return try await self.list(options: options)
            },
            changes: { [weak client] in
                client?.stream(for: AgentSessionChangedEvent.self) ?? AsyncStream { $0.finish() }
            },
            statuses: { [weak client] in Self.connectionStatuses(of: client) },
            isConnected: { [weak client] in client?.isConnected ?? false }
        )
        return try await AgentSessionList.watch(host: host, options: options)
    }

    /// The client's connection states, as its `StatusChangedEvent`s report them.
    static func connectionStatuses(of client: JsBaoClient?) -> AsyncStream<ConnectionStatus> {
        guard let client else { return AsyncStream { $0.finish() } }
        let source = client.stream(for: StatusChangedEvent.self)
        return AsyncStream { continuation in
            let task = Task {
                for await event in source { continuation.yield(event.status) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
