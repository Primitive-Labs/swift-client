import XCTest
@testable import JsBaoClient

/// `client.agents.sessions.watch` and the `AgentSessionList` it answers, over
/// a scripted session index and emitters for change events and connection
/// states (#4380, behaviors 17 and 18, the hermetic halves of 34 and 37, and
/// edges 25, 26, 28, 31 and 38). The JS client's `sessionList.ts` is the
/// reference, rule for rule.
final class AgentSessionListHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
    }

    // MARK: - Fixture

    private static let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private static func at(_ ms: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: t0.addingTimeInterval(Double(ms) / 1000))
    }

    private static func row(
        _ sessionId: String, agentKey: String = "advisor", scope: String? = nil, role: AgentSessionRole = .owner,
        title: String? = nil, lastActivityAt: Int = 0, hasUnread: Bool = false, lastReadAt: Int? = 0,
        status: PrimitiveSessionStatus? = .idle, createdAt: Int = 0
    ) -> AgentSessionListItem {
        AgentSessionListItem(
            sessionId: sessionId, agentKey: agentKey, scope: scope, documentId: "doc-\(sessionId)",
            ownerUserId: "u1", role: role, title: title ?? "Title \(sessionId)",
            lastActivityAt: at(lastActivityAt), createdAt: at(createdAt), hasUnread: hasUnread,
            lastReadAt: lastReadAt.map(at), status: status
        )
    }

    private static func upsert(
        _ item: AgentSessionListItem, at ms: Int, change: AgentSessionChange = .activity
    ) -> AgentSessionChangedEvent {
        AgentSessionChangedEvent(
            action: .upsert, change: change, at: at(ms), sessionId: item.sessionId, item: item,
            members: AgentSessionMembers(viewers: [], participants: ["p1"])
        )
    }

    private static func removed(_ sessionId: String, at ms: Int) -> AgentSessionChangedEvent {
        AgentSessionChangedEvent(action: .removed, change: .removed, at: at(ms), sessionId: sessionId, item: nil, members: nil)
    }

    /// A list call held until `open()`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume: Bool = lock.withLock {
                    if opened { return true }
                    waiting.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
                opened = true
                defer { waiting.removeAll() }
                return waiting
            }
            resumed.forEach { $0.resume() }
        }
    }

    /// A fake index answering `list` newest-created first, and the client's emitters.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _rows: [String: AgentSessionListItem]
        private var _calls: [ListAgentSessionsOptions] = []
        private var _connected: Bool
        private var gate: Gate?
        /// A page answered once in place of the index's (CSO-4380-008).
        private var scripted: PaginatedResult<AgentSessionListItem>?
        /// A failure answered once in place of the index's (CSO-4380-018).
        private var failure: Error?
        private var inFlight = 0
        private var _maxInFlight = 0
        private var events: [AsyncStream<AgentSessionChangedEvent>.Continuation] = []
        private var statuses: [AsyncStream<ConnectionStatus>.Continuation] = []

        init(_ rows: [AgentSessionListItem], connected: Bool = true) {
            self._rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0) })
            self._connected = connected
        }

        var calls: [ListAgentSessionsOptions] { lock.withLock { _calls } }
        var maxInFlight: Int { lock.withLock { _maxInFlight } }
        func clearCalls() { lock.withLock { _calls.removeAll() } }
        func set(_ item: AgentSessionListItem) { lock.withLock { _rows[item.sessionId] = item } }
        func remove(_ sessionId: String) { _ = lock.withLock { _rows.removeValue(forKey: sessionId) } }
        func answerNext(_ page: PaginatedResult<AgentSessionListItem>) { lock.withLock { scripted = page } }
        func failNext(_ error: Error) { lock.withLock { failure = error } }
        func hold() -> Gate {
            let gate = Gate()
            lock.withLock { self.gate = gate }
            return gate
        }

        func release(_ gate: Gate) {
            lock.withLock { if self.gate === gate { self.gate = nil } }
            gate.open()
        }

        var host: AgentSessionListHost {
            AgentSessionListHost(
                list: { [self] options in try await self.list(options) },
                changes: { [self] in
                    AsyncStream { continuation in self.lock.withLock { self.events.append(continuation) } }
                },
                statuses: { [self] in
                    AsyncStream { continuation in self.lock.withLock { self.statuses.append(continuation) } }
                },
                isConnected: { [self] in self.lock.withLock { self._connected } }
            )
        }

        private func list(_ options: ListAgentSessionsOptions) async throws -> PaginatedResult<AgentSessionListItem> {
            let gate: Gate? = lock.withLock {
                _calls.append(options)
                inFlight += 1
                _maxInFlight = max(_maxInFlight, inFlight)
                return self.gate
            }
            defer { lock.withLock { inFlight -= 1 } }
            if let gate { await gate.wait() }
            let failed: Error? = lock.withLock {
                defer { failure = nil }
                return failure
            }
            if let failed { throw failed }
            let page: PaginatedResult<AgentSessionListItem>? = lock.withLock {
                defer { scripted = nil }
                return scripted
            }
            if let page { return page }
            if let limit = options.limit, limit < 1 || limit > 100 {
                throw JsBaoError(code: .invalidArgument, message: "limit must be an integer from 1 to 100")
            }
            let all = lock.withLock { Array(_rows.values) }
                .filter { options.agent == nil || $0.agentKey == options.agent }
                .filter { options.scope == nil || $0.scope == options.scope }
                .sorted { $0.sessionId > $1.sessionId }
            let start = options.cursor.flatMap(Int.init) ?? 0
            let limit = options.limit ?? 50
            let items = Array(all.dropFirst(start).prefix(limit))
            let more = start + limit < all.count
            return PaginatedResult(items: items, nextCursor: more ? String(start + limit) : nil, hasMore: more)
        }

        func emit(_ event: AgentSessionChangedEvent) {
            for continuation in lock.withLock({ events }) { continuation.yield(event) }
        }

        func status(_ status: ConnectionStatus) {
            lock.withLock { _connected = status == .connected }
            for continuation in lock.withLock({ statuses }) { continuation.yield(status) }
        }
    }

    private func eventually(
        timeout: TimeInterval = 5, _ message: @autoclosure () -> String = "", _ check: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            if Date() > deadline {
                XCTFail("timed out: \(message())")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func ids(_ list: AgentSessionList) -> [String] { list.items.map(\.sessionId) }

    // MARK: - Behavior 18: the first page, loadMore, ordering

    func testWatchAnswersTheFirstPageByLastActivityAndLoadMoreAppendsTheNext() async throws {
        let w = World([
            Self.row("s1", lastActivityAt: 30), Self.row("s2", lastActivityAt: 10),
            Self.row("s3", lastActivityAt: 10), Self.row("s4", lastActivityAt: 50),
        ])
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(limit: 3))
        defer { list.close() }
        XCTAssertEqual(ids(list), ["s4", "s3", "s2"])
        XCTAssertTrue(list.hasMore)
        XCTAssertNil(list.items[0].members)
        try await list.loadMore()
        XCTAssertEqual(ids(list), ["s4", "s1", "s3", "s2"])
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(w.calls.map(\.cursor), [nil, "3"])
        XCTAssertEqual(w.calls.map(\.limit), [3, 3])
        // Edge 31: no further page, no request.
        try await list.loadMore()
        XCTAssertEqual(w.calls.count, 2)
    }

    // MARK: - CSO-4380-008: a change to hasMore alone is a change

    func testAnEmptyLastPageThatEndsHasMoreFiresOnChange() async throws {
        let w = World([Self.row("s1"), Self.row("s2")])
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(limit: 1))
        defer { list.close() }
        try await settle()
        XCTAssertTrue(list.hasMore)
        let count = LockedBox(0)
        list.onChange { count.add(1) }
        // The session the next page held is gone: that page comes back empty.
        w.remove("s1")
        try await list.loadMore()
        try await eventually { count.value >= 1 }
        try await settle()
        XCTAssertEqual(ids(list), ["s2"])
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(count.value, 1)
    }

    func testARefreshOfAnEmptyListThatFindsAFurtherPageFiresOnChange() async throws {
        let w = World([])
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(scope: "h1"))
        defer { list.close() }
        try await settle()
        XCTAssertFalse(list.hasMore)
        let count = LockedBox(0)
        list.onChange { count.add(1) }
        // A page filtered by scope after it is read can be empty with more behind it.
        w.answerNext(PaginatedResult(items: [], nextCursor: "next", hasMore: true))
        try await list.refresh()
        try await eventually { count.value >= 1 }
        try await settle()
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertTrue(list.hasMore)
        XCTAssertEqual(count.value, 1)
    }

    func testUserIdIsRefusedBeforeAnyRequestAndALimitIsRefusedAsListRefusesIt() async throws {
        let w = World([Self.row("s1")])
        do {
            _ = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(userId: "u2"))
            XCTFail("a userId must be refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        XCTAssertTrue(w.calls.isEmpty)
        // Through the client's own sessions API: refused before the transport is reached.
        let transport = RecordingTransport(json: "{}")
        let sessions = AgentSessionsAPI(transport: transport)
        do {
            _ = try await sessions.watch(options: WatchAgentSessionsOptions(userId: "u2"))
            XCTFail("a userId must be refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        XCTAssertTrue(transport.calls.isEmpty)
        // Edge 31: a limit outside 1…100 fails as the list call fails it.
        do {
            _ = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(limit: 101))
            XCTFail("a limit of 101 must be refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - Behavior 18: the change events; edges 25, 26, 28

    func testUpsertsUpdateAndInsertOtherAgentsAreIgnoredAndRemovedDrops() async throws {
        let w = World([Self.row("s1", lastActivityAt: 20), Self.row("s2", lastActivityAt: 10)])
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(agent: "advisor"))
        defer { list.close() }
        XCTAssertEqual(ids(list), ["s1", "s2"])
        w.emit(Self.upsert(Self.row("s2", lastActivityAt: 40, hasUnread: true, status: .thinking), at: 40))
        try await eventually { self.ids(list) == ["s2", "s1"] }
        XCTAssertEqual(list.items[0].status, .thinking)
        XCTAssertTrue(list.items[0].hasUnread)
        XCTAssertEqual(list.items[0].members, AgentSessionMembers(viewers: [], participants: ["p1"]))
        w.emit(Self.upsert(Self.row("s0", lastActivityAt: 50), at: 50, change: .members))
        w.emit(Self.upsert(Self.row("s9", agentKey: "tutor", lastActivityAt: 60), at: 60))
        w.emit(Self.removed("s1", at: 70))
        try await eventually { self.ids(list) == ["s0", "s2"] }
        // Edge 26: a role change updates the role.
        w.emit(Self.upsert(Self.row("s2", role: .viewer, lastActivityAt: 40), at: 80, change: .members))
        try await eventually { list.items.first { $0.sessionId == "s2" }?.role == .viewer }
    }

    func testOnChangeIsCoalescedAndAnOlderEventAddsOnlyItsInstants() async throws {
        let w = World([Self.row("s1"), Self.row("s2")])
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        let count = LockedBox(0)
        list.onChange { count.add(1) }
        w.emit(Self.upsert(Self.row("s1", title: "Rent", lastActivityAt: 0), at: 20, change: .title))
        w.emit(Self.upsert(Self.row("s1", title: "Old", lastActivityAt: 10, hasUnread: true, status: .thinking), at: 10))
        try await eventually { count.value >= 1 }
        try await settle()
        XCTAssertEqual(count.value, 1)
        let item = try XCTUnwrap(list.items.first { $0.sessionId == "s1" })
        XCTAssertEqual(item.title, "Rent")
        XCTAssertEqual(item.status, .idle)
        XCTAssertEqual(item.lastActivityAt, Self.at(10))
        XCTAssertTrue(item.hasUnread)
    }

    func testEventsDuringTheFirstListAreAppliedAfterIt() async throws {
        let w = World([Self.row("s1", lastActivityAt: 0)])
        let gate = w.hold()
        let watching = Task { try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions()) }
        try await eventually { w.calls.count == 1 }
        w.emit(Self.upsert(Self.row("s1", title: "Live", lastActivityAt: 30, hasUnread: true), at: 30))
        w.emit(Self.upsert(Self.row("s2", lastActivityAt: 20), at: 20))
        try await settle()
        w.release(gate)
        let list = try await watching.value
        defer { list.close() }
        try await eventually { self.ids(list) == ["s1", "s2"] }
        XCTAssertEqual(list.items[0].title, "Live")
        XCTAssertEqual(list.items[0].lastActivityAt, Self.at(30))
    }

    func testARemovedSessionIgnoresAnOlderUpsertAndTakesANewerOne() async throws {
        let w = World([Self.row("s1")])
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        w.emit(Self.removed("s1", at: 50))
        w.emit(Self.upsert(Self.row("s1", lastActivityAt: 40), at: 40))
        try await settle()
        XCTAssertEqual(ids(list), [])
        w.emit(Self.upsert(Self.row("s1", lastActivityAt: 60), at: 60, change: .members))
        try await eventually { self.ids(list) == ["s1"] }
    }

    /// CSO-4380-011: a removal holds against a page that still reads the
    /// deleted row; a row created after the removal is a re-addition.
    func testAStalePageAfterARemovalLeavesTheSessionOutAndARowCreatedLaterListsIt() async throws {
        let w = World([Self.row("s1"), Self.row("s2")], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        w.emit(Self.removed("s1", at: 50))
        try await eventually { self.ids(list) == ["s2"] }
        // The index still answers the deleted row (an eventually consistent read).
        try await list.refresh()
        XCTAssertEqual(ids(list), ["s2"])
        w.status(.disconnected)
        w.status(.connected)
        try await settle()
        XCTAssertEqual(ids(list), ["s2"])
        // Added back while no frame reached this client.
        w.set(Self.row("s1", role: .viewer, createdAt: 80))
        try await list.refresh()
        XCTAssertEqual(ids(list).sorted(), ["s1", "s2"])
        XCTAssertEqual(list.items.first { $0.sessionId == "s1" }?.role, .viewer)
    }

    // MARK: - Behavior 18: refresh and reconnects; 34, 37, edge 38

    func testAReconnectRereadsTheLoadedPagesAndARedundantConnectedDoesNot() async throws {
        let w = World([Self.row("s1"), Self.row("s2"), Self.row("s3")], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(limit: 2))
        defer { list.close() }
        try await list.loadMore()
        w.clearCalls()
        w.status(.connected)
        try await settle()
        XCTAssertTrue(w.calls.isEmpty)
        w.status(.disconnected)
        w.set(Self.row("s2", title: "Renamed offline"))
        w.status(.connected)
        try await eventually { list.items.first { $0.sessionId == "s2" }?.title == "Renamed offline" }
        XCTAssertEqual(w.calls.map(\.cursor), [nil, "2"])
    }

    /// CSO-4380-003: a session not in the refreshed pages leaves the list, an
    /// older one an event added included; its next event adds it again.
    func testAReconnectDropsASessionBeyondThePagesThatWentAwayOffline() async throws {
        // s4 keeps a further page, so s5 stays older than the pages reach.
        let w = World([Self.row("s4"), Self.row("s5"), Self.row("s6")], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(limit: 1))
        defer { list.close() }
        XCTAssertEqual(ids(list), ["s6"])
        w.emit(Self.upsert(Self.row("s5", lastActivityAt: 30), at: 30))
        try await eventually { self.ids(list) == ["s5", "s6"] }
        // Deleted while the client was offline: no frame reaches it.
        w.status(.disconnected)
        w.remove("s5")
        w.status(.connected)
        try await eventually { self.ids(list) == ["s6"] }
        w.set(Self.row("s5"))
        w.emit(Self.upsert(Self.row("s5", lastActivityAt: 40), at: 40))
        try await eventually { self.ids(list) == ["s5", "s6"] }
        try await list.refresh()
        XCTAssertEqual(ids(list), ["s6"])
    }

    func testRefreshMergesFieldByField() async throws {
        let w = World([Self.row("s1", lastActivityAt: 10, lastReadAt: 10)], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        // A coalesced activity: the event carries 20, the row keeps 10.
        w.emit(Self.upsert(Self.row("s1", lastActivityAt: 20, hasUnread: true, lastReadAt: 10, status: .thinking), at: 20))
        try await eventually { list.items.first?.hasUnread == true }
        w.status(.disconnected)
        // Offline: read on another device at 25, renamed by the owner.
        w.set(Self.row("s1", title: "Rent", lastActivityAt: 10, lastReadAt: 25))
        w.status(.connected)
        try await eventually { list.items.first?.title == "Rent" }
        let item = try XCTUnwrap(list.items.first)
        XCTAssertFalse(item.hasUnread)
        XCTAssertEqual(item.lastReadAt, Self.at(25))
        XCTAssertEqual(item.lastActivityAt, Self.at(20))
        XCTAssertEqual(item.status, .thinking)
        XCTAssertEqual(item.members, AgentSessionMembers(viewers: [], participants: ["p1"]))
        // A row later than the item replaces its status and instants.
        w.set(Self.row("s1", lastActivityAt: 40, hasUnread: true, lastReadAt: 0, status: .idle))
        try await list.refresh()
        let later = try XCTUnwrap(list.items.first)
        XCTAssertEqual(later.lastActivityAt, Self.at(40))
        XCTAssertEqual(later.status, .idle)
        XCTAssertTrue(later.hasUnread)
        // A session no longer in the pages leaves the list.
        w.remove("s1")
        try await list.refresh()
        XCTAssertEqual(ids(list), [])
    }

    func testAFirstPageReadBeforeTheSocketWasUpRefreshesOnceOnTheFirstConnected() async throws {
        let w = World([Self.row("s1")], connected: false)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        w.set(Self.row("s2"))
        w.clearCalls()
        w.status(.connected)
        w.status(.connected)
        try await eventually { self.ids(list).sorted() == ["s1", "s2"] }
        try await settle()
        XCTAssertEqual(w.calls.count, 1)
    }

    func testAConnectedDuringARefreshQueuesOneMoreAfterIt() async throws {
        let w = World([Self.row("s1")], connected: false)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        w.clearCalls()
        let gate = w.hold()
        w.status(.connected)
        try await eventually { w.calls.count == 1 }
        w.status(.disconnected)
        w.status(.connected)
        w.status(.connected)
        try await settle()
        XCTAssertEqual(w.calls.count, 1)
        w.release(gate)
        try await eventually { w.calls.count == 2 }
        try await settle()
        XCTAssertEqual(w.calls.count, 2)
        XCTAssertEqual(w.maxInFlight, 1)
    }

    /// CSO-4380-018: a refresh queued behind one that fails still runs.
    func testARefreshQueuedBehindOneThatFailsStillRuns() async throws {
        let w = World([Self.row("s1")], connected: false)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        w.clearCalls()
        let gate = w.hold()
        w.status(.connected)
        try await eventually { w.calls.count == 1 }
        w.status(.disconnected)
        w.set(Self.row("s2"))
        w.status(.connected)
        try await settle()
        XCTAssertEqual(w.calls.count, 1)
        w.failNext(JsBaoError(code: .networkTimeout, message: "network down"))
        w.release(gate)
        try await eventually { w.calls.count == 2 }
        try await eventually { self.ids(list).sorted() == ["s1", "s2"] }
        XCTAssertEqual(w.maxInFlight, 1)
    }

    /// CSO-4380-018: an explicit refresh queued behind one that fails answers its own run;
    /// a failing refresh with nothing queued still throws.
    func testAnExplicitRefreshQueuedBehindOneThatFailsAnswersItsOwnRun() async throws {
        let w = World([Self.row("s1")], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        defer { list.close() }
        w.clearCalls()
        let gate = w.hold()
        let first = Task { try await list.refresh() }
        try await eventually { w.calls.count == 1 }
        w.set(Self.row("s2"))
        let second = Task { try await list.refresh() }
        try await settle()
        w.failNext(JsBaoError(code: .networkTimeout, message: "network down"))
        w.release(gate)
        try await second.value
        try await first.value
        XCTAssertEqual(w.calls.count, 2)
        XCTAssertEqual(ids(list).sorted(), ["s1", "s2"])

        let held = w.hold()
        let lone = Task { try await list.refresh() }
        try await eventually { w.calls.count == 3 }
        w.failNext(JsBaoError(code: .networkTimeout, message: "network down"))
        w.release(held)
        do {
            try await lone.value
            XCTFail("a lone failing refresh throws")
        } catch {}
    }

    /// CSO-4380-012: closing while a refresh reads its first page requests no further page.
    func testClosingDuringARefreshRequestsNoFurtherPage() async throws {
        let w = World([Self.row("s1"), Self.row("s2"), Self.row("s3")], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions(limit: 1))
        try await list.loadMore()
        try await list.loadMore()
        w.clearCalls()
        let gate = w.hold()
        let refreshing = Task { try await list.refresh() }
        try await eventually { w.calls.count == 1 }
        list.close()
        w.release(gate)
        try await refreshing.value
        try await settle()
        XCTAssertEqual(w.calls.count, 1)
    }

    // MARK: - Behavior 18: close

    func testCloseStopsEverything() async throws {
        let w = World([Self.row("s1")], connected: true)
        let list = try await AgentSessionList.watch(host: w.host, options: WatchAgentSessionsOptions())
        let count = LockedBox(0)
        list.onChange { count.add(1) }
        list.close()
        w.emit(Self.upsert(Self.row("s2", lastActivityAt: 9), at: 9))
        w.status(.disconnected)
        w.status(.connected)
        try await list.refresh()
        try await settle()
        XCTAssertEqual(ids(list), ["s1"])
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(w.calls.count, 1)
    }

    // MARK: - Behavior 17: the frame

    func testTheFrameDecodesOpenAndStreamsAndAnUnparseableOneIsDropped() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-list-frame",
            token: "test-token", offline: false, logLevel: .none, storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        let stream = client.stream(for: AgentSessionChangedEvent.self)
        let received = Task { () -> [AgentSessionChangedEvent] in
            var out: [AgentSessionChangedEvent] = []
            for await event in stream {
                out.append(event)
                if out.count == 2 { break }
            }
            return out
        }
        // An upsert without its item does not decode: dropped.
        await client.handleWebSocketMessage(
            #"{"type":"agentSession","action":"upsert","change":"activity","at":"2026-10-12T12:00:00.000Z","sessionId":"s1","item":null,"members":null}"#
        )
        await client.handleWebSocketMessage(#"""
        {"type":"agentSession","action":"upsert","change":"telepathy","at":"2026-10-12T12:00:01.000Z","sessionId":"s1",
         "item":{"sessionId":"s1","agentKey":"advisor","documentId":"d1","ownerUserId":"u1","createdAt":"2026-10-12T11:00:00.000Z",
                 "scope":null,"title":"Budget","lastActivityAt":"2026-10-12T12:00:01.000Z","status":"daydreaming",
                 "role":"co-owner","hasUnread":true,"lastReadAt":null},
         "members":{"viewers":["v1"],"participants":["p1"]}}
        """#)
        await client.handleWebSocketMessage(
            #"{"type":"agentSession","action":"removed","change":"deleted","at":"2026-10-12T12:00:02.000Z","sessionId":"s1","item":null,"members":null}"#
        )
        let events = await received.value
        XCTAssertEqual(events.count, 2)
        let upsert = events[0]
        XCTAssertEqual(upsert.action, .upsert)
        XCTAssertEqual(upsert.change, .unknown("telepathy"))
        XCTAssertEqual(upsert.item?.status, .unknown("daydreaming"))
        XCTAssertEqual(upsert.item?.role, .unknown("co-owner"))
        XCTAssertEqual(upsert.item?.title, "Budget")
        XCTAssertEqual(upsert.members, AgentSessionMembers(viewers: ["v1"], participants: ["p1"]))
        XCTAssertEqual(events[1].action, .removed)
        XCTAssertEqual(events[1].change, .deleted)
        XCTAssertNil(events[1].item)
    }

    func testAListItemDecodesItsStatusOpenAndAnOlderOneAsNil() throws {
        let base = #"{"sessionId":"s1","agentKey":"a","documentId":"d","ownerUserId":"u","role":"owner","title":null,"scope":null,"lastActivityAt":"2026-10-12T12:00:00.000Z","createdAt":null,"hasUnread":false,"lastReadAt":null"#
        let idle = try JSONCoding.decodeData(AgentSessionListItem.self, from: Data((base + #","status":"idle"}"#).utf8))
        XCTAssertEqual(idle.status, .idle)
        let unknown = try JSONCoding.decodeData(AgentSessionListItem.self, from: Data((base + #","status":"pondering"}"#).utf8))
        XCTAssertEqual(unknown.status, .unknown("pondering"))
        let older = try JSONCoding.decodeData(AgentSessionListItem.self, from: Data((base + "}").utf8))
        XCTAssertNil(older.status)
        let none = try JSONCoding.decodeData(AgentSessionListItem.self, from: Data((base + #","status":null}"#).utf8))
        XCTAssertNil(none.status)
    }
}
