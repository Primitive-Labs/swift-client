import XCTest
@testable import JsBaoClient

/// A session view loses its session (#4884 behavior 13's hermetic half, edges
/// E1, E2 and E3; intent criterion 2): when the room refuses the open
/// subscription (the release frame, `ACCESS_DENIED` on `record.open`), or the
/// session's `removed` change frame arrives first, running client-tool
/// handlers stop, the view empties, the subscription is disposed, the local
/// copy is evicted and `gone` says so; a read in flight at the loss takes
/// nothing in. A sync-off or outdated db3 sets `gone` and keeps the copy.
///
/// The db3 is a real record-log binding on SQLite with a real `Db3Lifecycle`
/// (`SessionDb3`), the room's refusal reaching it as the client's session
/// reports it; frames go through the client's WebSocket dispatch.
final class AgentSessionViewLossHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var db3s: [SessionDb3] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for db3 in db3s { db3.cleanup() }
        db3s = []
    }

    private struct Fixture {
        let client: JsBaoClient
        let transport: RecordingTransport
        let db3: SessionDb3
        let view: AgentSessionView
    }

    /// A session with one turn of the current user (`u1`) paused on a call,
    /// its members and its queue; the view open over it.
    private func open(_ name: String, options: OpenAgentSessionOptions = OpenAgentSessionOptions()) async throws -> Fixture {
        let f = try await begin(name, options: options)
        let view = try await f.open()
        XCTAssertEqual(view.syncedMessages.count, min(3, options.pageSize))
        return Fixture(client: f.client, transport: f.transport, db3: f.db3, view: view)
    }

    /// The session `open(_:options:)` opens, before it is opened.
    private func begin(
        _ name: String, options: OpenAgentSessionOptions = OpenAgentSessionOptions()
    ) async throws -> (client: JsBaoClient, transport: RecordingTransport, db3: SessionDb3, open: @Sendable () async throws -> AgentSessionView) {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-loss-\(name)",
            token: makeTestJwt(userId: "u1"), offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        let db3 = try await SessionDb3.make(id: "s1")
        db3s.append(db3)
        try db3.write([
            ("Session", SessionRows.session(status: "awaiting_answer", activeTurnId: "t1")),
            ("Member", SessionRows.member("u1", role: "owner")),
            ("Member", SessionRows.member("u2", addedAt: "2026-10-01T00:00:01.000Z")),
            ("Turn", SessionRows.turn("t1", seq: 1)),
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1")),
            ("Message", SessionRows.message("m2", seq: 2, turnId: "t1", authorKind: "agent")),
            ("ToolCall", SessionRows.call("call-1", messageId: "m2", seq: 1, turnId: "t1")),
            ("Message", SessionRows.message("m3", seq: 3, authorUserId: "u2", queueSeq: 1)),
        ])
        let transport = RecordingTransport { request in
            if request.path == "/agent-sessions/s1" {
                return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(agentSessionInfoJSON("s1").utf8))
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"callId":"call-1","state":"output-available"}"#.utf8))
        }
        let sessions = AgentSessionsAPI(transport: transport, client: client)
        return (client, transport, db3, { try await sessions.open(sessionId: "s1", options: options, db3: db3) })
    }

    private func answers(_ f: Fixture) -> [RecordedRequest] {
        f.transport.calls.filter { $0.path.hasSuffix("/answer") }
    }

    /// The view as a lost session leaves it: nothing of the session shown, the
    /// subscription given up, the copy evicted.
    private func assertLost(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(f.view.gone, Db3GoneEvent(id: "s1", reason: .permission), file: file, line: line)
        XCTAssertEqual(f.view.gone?.code, "DB3_ACCESS_REFUSED", file: file, line: line)
        XCTAssertEqual(f.view.syncedMessages, [], "the view shows nothing", file: file, line: line)
        XCTAssertEqual(f.view.members, [], file: file, line: line)
        XCTAssertEqual(f.view.queue, [], file: file, line: line)
        XCTAssertNil(f.view.session, file: file, line: line)
        XCTAssertFalse(f.view.hasOlder, file: file, line: line)
        XCTAssertEqual(f.view.runningClientToolCalls, [], file: file, line: line)
        try await eventually(description: "the copy is evicted") {
            guard let state = try? await f.db3.state() else { return false }
            return !state.resident && state.rows == 0 && !state.subscribed
        }
        XCTAssertEqual(f.db3.evictionCount, 1, "evicted once", file: file, line: line)
    }

    private static func removedFrame(at: String) -> String {
        #"{"type":"agentSession","action":"removed","change":"removed","at":"\#(at)","sessionId":"s1","item":null,"members":null}"#
    }

    private static func upsertFrame(at: String) -> String {
        #"""
        {"type":"agentSession","action":"upsert","change":"title","at":"\#(at)","sessionId":"s1",
         "item":{"sessionId":"s1","agentKey":"helper","ownerUserId":"u1","createdAt":"2026-10-01T00:00:00.000Z",
                 "scope":null,"title":"Renamed","lastActivityAt":"\#(at)","status":"idle","role":"participant",
                 "hasUnread":true,"lastReadAt":null},
         "members":{"viewers":[],"participants":["u2"]}}
        """#
    }

    // MARK: - The room's refusal while open

    func testTheRoomsRefusalStopsHandlersEmptiesTheViewDisposesAndEvictsTheCopy() async throws {
        let f = try await open("refused")
        let gate = AsyncGate()
        let cancelled = Recorder<Bool>()
        try f.view.handleClientTools(["pick": AgentClientToolHandler { _ in
            await gate.wait()
            cancelled.append(Task.isCancelled)
            return AgentClientToolResult(output: ["count": 1])
        }])
        try await eventually(description: "the handler runs") { f.view.runningClientToolCalls == ["call-1"] }
        let changes = Recorder<Int>()
        f.view.onChange { changes.append(1) }

        try f.db3.refuse()
        try await eventually(description: "the view loses the session") { f.view.gone != nil }
        try await assertLost(f)
        XCTAssertFalse(changes.all.isEmpty, "the loss is heard")
        await gate.open()
        try await eventually(description: "the handler returns") { !cancelled.all.isEmpty }
        XCTAssertEqual(cancelled.all, [true], "the running handler is cancelled")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(answers(f).count, 0, "its answer is never sent")
        await f.view.close()
    }

    func testAPendingSendSurvivesTheLossAndFailsOnItsOwnAnswer() async throws {
        let f = try await open("pending")
        let gate = AsyncGate()
        let transport = RecordingTransport { request in
            if request.path == "/agent-sessions/s1/messages" {
                await gate.wait()
                return TransportResponse(status: 404, headers: ["Content-Type": "application/json"],
                                         body: Data(#"{"code":"AGENT_SESSION_NOT_FOUND","error":"gone"}"#.utf8))
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(agentSessionInfoJSON("s1").utf8))
        }
        let view = try await AgentSessionsAPI(transport: transport, client: f.client).open(sessionId: "s1", db3: f.db3)
        let sending = Task { try await view.send(text: "Still mine.", clientMessageId: "c-1") }
        try await eventually(description: "the entry shows") { view.pendingMessages.count == 1 }
        try f.db3.refuse()
        try await eventually(description: "the view loses the session") { view.gone != nil }
        XCTAssertEqual(view.pendingMessages.map(\.clientMessageId), ["c-1"], "your own message stays")
        await gate.open()
        _ = try? await sending.value
        XCTAssertEqual(view.pendingMessages.first?.state, .failed)
        XCTAssertEqual(view.pendingMessages.first?.error?.code, "AGENT_SESSION_NOT_FOUND")
        await view.close()
        await f.view.close()
    }

    // MARK: - The room's refusal while open starts

    /// CSO-4884-001: the refusal lands after `ready()` settled and before the
    /// view observes its subscription (the lifecycle replays nothing): `open`
    /// answers a view that has lost the session, its copy evicted.
    func testARefusalBetweenReadyAndTheViewsObserverStillLosesTheSession() async throws {
        let f = try await begin("refused-at-start")
        // The view's first records call (its model subscriptions) waits, after `ready()` settled.
        f.db3.holdReads()
        let opening = Task { try await f.open() }
        try await eventually(description: "the view starts after ready()") { f.db3.heldReadCount > 0 }
        XCTAssertEqual(f.db3.appliedPhase, .live)
        try f.db3.refuse()
        try await eventually(description: "the lifecycle delivers the loss to no observer") { f.db3.appliedPhase == .gone }
        f.db3.releaseReads()
        let view = try await opening.value
        try await assertLost(Fixture(client: f.client, transport: f.transport, db3: f.db3, view: view))
        await view.close()
    }

    // MARK: - Edge E1: the removed frame

    func testARemovedFrameLosesTheSessionUnlessANewerUpsertWasApplied() async throws {
        let f = try await open("removed")
        await f.client.handleWebSocketMessage(Self.upsertFrame(at: "2026-10-01T00:01:00.000Z"))
        try await eventually(description: "the upsert is applied") { f.view.info.title == "Renamed" }
        // Older than the upsert: the view is as it was.
        await f.client.handleWebSocketMessage(Self.removedFrame(at: "2026-10-01T00:00:30.000Z"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(f.view.gone)
        XCTAssertEqual(f.view.syncedMessages.count, 3)
        XCTAssertEqual(f.db3.evictionCount, 0)
        // At or after it: lost, before any refusal from the room.
        await f.client.handleWebSocketMessage(Self.removedFrame(at: "2026-10-01T00:01:00.000Z"))
        try await eventually(description: "the view loses the session") { f.view.gone != nil }
        try await assertLost(f)
        await f.view.close()
    }

    func testARemovedFrameWithNoUpsertAppliedLosesTheSession() async throws {
        let f = try await open("removed-first")
        await f.client.handleWebSocketMessage(Self.removedFrame(at: "2026-10-01T00:00:01.000Z"))
        try await eventually(description: "the view loses the session") { f.view.gone != nil }
        try await assertLost(f)
        // The room's refusal after it loses nothing more.
        try? f.db3.refuse()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.db3.evictionCount, 1)
        await f.view.close()
    }

    // MARK: - Edge E2: a read in flight at the loss

    func testAReadInFlightAtTheLossTakesNothingInAndLoadOlderAnswersNothing() async throws {
        let f = try await open("in-flight")
        f.db3.holdEvictions()
        f.db3.holdReads()
        // A write schedules a refresh, whose reads are held.
        try f.db3.write("Message", SessionRows.message("m4", seq: 4))
        try await eventually(description: "the refresh's read is held") { f.db3.heldReadCount > 0 }
        let older = Task { try await f.view.loadOlder() }
        await f.client.handleWebSocketMessage(Self.removedFrame(at: "2026-10-01T00:00:01.000Z"))
        try await eventually(description: "the view loses the session") { f.view.gone != nil }
        XCTAssertEqual(f.view.syncedMessages, [])
        // The held read completes over the copy, still there while the eviction waits.
        f.db3.releaseReads()
        let page = try await older.value
        XCTAssertEqual(page, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.view.syncedMessages, [], "the read took nothing into the emptied view")
        XCTAssertEqual(f.view.members, [])
        XCTAssertNil(f.view.session)
        f.db3.releaseEvictions()
        try await assertLost(f)
        await f.view.close()
    }

    /// CSO-4884-002: the eviction finishes while a page read waits, so the
    /// read meets an unbound store: `loadOlder()` answers nothing, not the
    /// store's error.
    func testAPageReadThatMeetsTheFinishedEvictionAnswersNothing() async throws {
        let f = try await open("evicted-under-page", options: OpenAgentSessionOptions(pageSize: 1))
        XCTAssertTrue(f.view.hasOlder)
        f.db3.holdReads()
        let older = Task { try await f.view.loadOlder() }
        try await eventually(description: "the page's read is held") { f.db3.heldReadCount > 0 }
        await f.client.handleWebSocketMessage(Self.removedFrame(at: "2026-10-01T00:00:01.000Z"))
        try await eventually(description: "the copy is evicted") {
            guard let state = try? await f.db3.state() else { return false }
            return !state.resident && state.rows == 0
        }
        f.db3.releaseReads()
        let page = try await older.value
        XCTAssertEqual(page, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false))
        try await assertLost(f)
        await f.view.close()
    }

    // MARK: - Edge E3: sync off, client outdated

    func testSyncOffSetsGoneKeepsTheCopyAndTheSubscriptionAndEvictsNothing() async throws {
        let f = try await open("sync-off")
        try f.db3.turnSyncOff()
        try await eventually(description: "gone") { f.view.gone != nil }
        XCTAssertEqual(f.view.gone, Db3GoneEvent(id: "s1", reason: .syncOff))
        XCTAssertEqual(f.view.gone?.code, "DB3_SYNC_OFF")
        XCTAssertEqual(f.view.syncedMessages.count, 3, "the rows stay")
        XCTAssertEqual(f.view.members.count, 2)
        let state = try await f.db3.state()
        XCTAssertTrue(state.resident)
        XCTAssertTrue(state.subscribed, "the subscription stays")
        XCTAssertEqual(f.db3.evictionCount, 0)
        // Its local copy still refreshes the view.
        try f.db3.write("Message", SessionRows.message("m4", seq: 4))
        try await eventually(description: "the view refreshes") { f.view.syncedMessages.count == 4 }
        await f.view.close()
    }

    func testAClientOutdatedDb3SetsGoneAndKeepsTheCopy() async throws {
        let f = try await open("outdated")
        f.db3.outdate()
        try await eventually(description: "gone") { f.view.gone != nil }
        XCTAssertEqual(f.view.gone, Db3GoneEvent(id: "s1", reason: .clientOutdated))
        XCTAssertEqual(f.view.gone?.code, "DB3_CLIENT_OUTDATED")
        XCTAssertEqual(f.view.syncedMessages.count, 3)
        XCTAssertEqual(f.db3.evictionCount, 0)
        let state = try await f.db3.state()
        XCTAssertTrue(state.resident)
        await f.view.close()
    }
}

/// A one-shot gate an async test opens to let a handler or answer through.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
