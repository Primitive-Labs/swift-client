import XCTest
@testable import JsBaoClient

/// `client.agents.sessions.open` and the `AgentSessionView` it answers (#3810
/// plan behaviors 10–18; #4884 behaviors 5 and 7–10, edges E6, E9 and E10),
/// over the session's db3 on this device and a recording transport. The db3
/// is a real record-log binding on SQLite with a real `Db3Lifecycle`
/// (`SessionDb3`); the room's writes reach it as the session applies them.
/// The JS client's `sessionView.ts` is the reference.
final class AgentSessionViewHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var db3s: [SessionDb3] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for db3 in db3s { db3.cleanup() }
        db3s = []
    }

    // MARK: - Fixture

    /// Scripted answers by route; the transport records every call.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: [(Int, String)]] = [:]

        /// Answer `method path` with each body in turn; the last one repeats.
        func on(_ method: HTTPMethod, _ path: String, status: Int = 200, _ body: String) {
            lock.withLock { answers["\(method.rawValue) \(path)", default: []].append((status, body)) }
        }

        /// Answer `method path` with `body` from now on.
        func set(_ method: HTTPMethod, _ path: String, status: Int = 200, _ body: String) {
            lock.withLock { answers["\(method.rawValue) \(path)"] = [(status, body)] }
        }

        func answer(_ request: RecordedRequest) -> TransportResponse {
            let key = "\(request.method.rawValue) \(request.path)"
            let (status, body): (Int, String) = lock.withLock {
                guard var queue = answers[key], let first = queue.first else {
                    return (404, #"{"code":"NOT_SCRIPTED","error":"\#(key)"}"#)
                }
                if queue.count > 1 { queue.removeFirst(); answers[key] = queue }
                return first
            }
            return TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
    }

    private struct Harness {
        let client: JsBaoClient
        let sessions: AgentSessionsAPI
        let transport: RecordingTransport
        let script: Script
        let db3: SessionDb3
    }

    private func harness(_ name: String, sessionId: String = "s1") async throws -> Harness {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-view-\(name)",
            token: makeTestJwt(userId: "u1"), offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        let script = Script()
        let transport = RecordingTransport { script.answer($0) }
        let db3 = try await SessionDb3.make(id: sessionId)
        db3s.append(db3)
        return Harness(
            client: client, sessions: AgentSessionsAPI(transport: transport, client: client), transport: transport,
            script: script, db3: db3
        )
    }

    /// `get` scripted to answer the session.
    private func session(_ h: Harness, _ sessionId: String = "s1", turnId: String? = nil, hasUnread: Bool = false) {
        h.script.on(.get, "/agent-sessions/\(sessionId)", agentSessionInfoJSON(sessionId, turnId: turnId, hasUnread: hasUnread))
    }

    private func open(_ h: Harness, _ sessionId: String = "s1", pageSize: Int = 50) async throws -> AgentSessionView {
        try await h.sessions.open(sessionId: sessionId, options: OpenAgentSessionOptions(pageSize: pageSize), db3: h.db3)
    }

    private func synced(_ view: AgentSessionView) -> [AgentSessionSyncedMessage] { view.syncedMessages }
    private func pending(_ view: AgentSessionView) -> [AgentSessionPendingMessage] { view.pendingMessages }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func assertCode(
        _ expected: JsBaoErrorCode, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, expected, file: file, line: line)
        } catch {
            XCTFail("expected JsBaoError(\(expected)), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Behavior 10 (#3810): open order

    func testARefusedGetThrowsBeforeAnythingIsSubscribed() async throws {
        let h = try await harness("refused", sessionId: "gone")
        h.script.on(.get, "/agent-sessions/gone", status: 404, #"{"code":"AGENT_SESSION_NOT_FOUND","error":"no"}"#)
        do {
            _ = try await open(h, "gone")
            XCTFail("open should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_NOT_FOUND")
        }
        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/gone"])
        XCTAssertEqual(h.db3.opens, [], "nothing is subscribed")
        let state = try await h.db3.state()
        XCTAssertFalse(state.subscribed)
    }

    // MARK: - Behavior 5: the session's db3, read by model name

    /// A session with one turn: a user message, an agent message with a text
    /// part and a call, a step, the turn, two members and the session row.
    private func seedTurn(_ db3: SessionDb3) throws {
        try db3.write([
            ("Session", SessionRows.session(status: "thinking", activeTurnId: "t1")),
            ("Member", SessionRows.member("u1", role: "owner")),
            ("Member", SessionRows.member("u2", addedAt: "2026-10-01T00:00:01.000Z")),
            ("Turn", SessionRows.turn("t1", seq: 1)),
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1")),
            ("Message", SessionRows.message("m2", seq: 2, turnId: "t1", authorKind: "agent")),
            ("Part", SessionRows.text("m1-p", messageId: "m1", seq: 1)),
            ("Part", SessionRows.text("m2-p", messageId: "m2", seq: 2, text: "Here.")),
            ("ToolCall", SessionRows.call("call-1", messageId: "m2", seq: 1, turnId: "t1")),
            ("Step", SessionRows.step("s1", turnId: "t1", seq: 1)),
        ])
    }

    func testOpenSubscribesToTheSessionsDb3AndReadsItsSevenModels() async throws {
        let h = try await harness("opens")
        session(h)
        try seedTurn(h.db3)
        let view = try await open(h)

        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/s1"], "get, and no other request")
        XCTAssertEqual(h.db3.opens, ["s1"], "the db3 the session's id names is subscribed")
        let state = try await h.db3.state()
        XCTAssertTrue(state.subscribed)
        XCTAssertNil(h.client.sharedModel("Message"), "no model is registered on the client")
        XCTAssertFalse(h.client.isDocumentOpen("s1"), "no document is opened")

        XCTAssertEqual(view.session?.id, "s1")
        XCTAssertEqual(view.members.map(\.id), ["u1", "u2"])
        let messages = synced(view)
        XCTAssertEqual(messages.map(\.messageId), ["m1", "m2"])
        guard messages.count == 2 else { return await view.close() }
        XCTAssertEqual(messages[1].parts.map(\.id), ["call-1", "m2-p"])
        XCTAssertEqual(messages[1].steps.map(\.id), ["s1"])
        XCTAssertEqual(messages[1].turn?.id, "t1")
        await view.close()
    }

    // MARK: - Behavior 7: a synced message

    func testASyncedMessageCarriesItsPartsAndCallsBySeqItsStepsItsTurnAndItsQueuedState() async throws {
        let h = try await harness("message")
        session(h)
        try h.db3.write([
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1", authorKind: "agent")),
            ("Part", SessionRows.text("p-b", messageId: "m1", seq: 3)),
            ("ToolCall", SessionRows.call("call-a", messageId: "m1", seq: 2, turnId: "t1")),
            ("Part", SessionRows.text("p-a", messageId: "m1", seq: 2)),
            ("Part", SessionRows.text("p-first", messageId: "m1", seq: 1)),
            ("Step", SessionRows.step("s2", turnId: "t1", seq: 2)),
            ("Step", SessionRows.step("s1", turnId: "t1", seq: 1)),
            ("Step", SessionRows.step("s-other", turnId: "t9", seq: 1)),
            ("Message", SessionRows.message("m2", seq: 2, queueSeq: 1)),
        ])
        let view = try await open(h)
        let first = try XCTUnwrap(synced(view).first)
        XCTAssertEqual(first.parts.map(\.id), ["p-first", "call-a", "p-a", "p-b"], "parts and calls in one list by seq, then id")
        guard first.parts.count == 4 else { return await view.close() }
        guard case let .toolCall(call) = first.parts[1] else { return XCTFail("\(first.parts[1])") }
        XCTAssertEqual(call.state, .inputAvailable)
        XCTAssertEqual(call.input, ["question": "How many?"])
        guard case let .part(text) = first.parts[0], case let .text(content) = text.content else {
            return XCTFail("\(first.parts[0])")
        }
        XCTAssertEqual(content.text, "hello")
        XCTAssertEqual(first.steps.map(\.id), ["s1", "s2"], "the turn's steps by seq")
        XCTAssertNil(first.turn, "no turn until its row syncs")
        XCTAssertEqual(first.state, .synced)
        XCTAssertEqual(synced(view).last?.state, .queued, "queued while its queueSeq is set")

        try h.db3.write([("Turn", SessionRows.turn("t1", seq: 1, status: "completed"))])
        try await eventually(description: "the turn arrives") { self.synced(view).first?.turn?.status == .completed }
        try h.db3.write([("Message", SessionRows.message("m2", seq: 2, turnId: "t2", queueSeq: .null))])
        try await eventually(description: "m2 is taken") { self.synced(view).last?.state == .synced }
        await view.close()
    }

    // MARK: - Behavior 8 and edges E9, E10: queue, members, status

    func testQueueMembersStatusAndActiveTurnComeFromTheRows() async throws {
        let h = try await harness("rows")
        session(h)
        try h.db3.write([
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1")),
            ("Message", SessionRows.message("m2", seq: 2, authorUserId: "u2", queueSeq: 2)),
            ("Message", SessionRows.message("m3", seq: 3, authorUserId: "u3", queueSeq: 1)),
            ("Message", SessionRows.message("m4", seq: 4, authorUserId: "u2", queueSeq: 3)),
        ])
        let view = try await open(h)
        XCTAssertNil(view.session)
        XCTAssertNil(view.status, "nil until the row has synced")
        XCTAssertNil(view.activeTurnId)
        XCTAssertEqual(view.members, [])
        XCTAssertEqual(view.queue, [
            PrimitiveQueueEntry(userId: "u3", messageIds: ["m3"]),
            PrimitiveQueueEntry(userId: "u2", messageIds: ["m2", "m4"]),
        ], "one entry per author in the order of each author's first waiting message")

        try h.db3.write([
            ("Session", SessionRows.session(status: "thinking", activeTurnId: "t1")),
            ("Member", SessionRows.member("u2", role: "participant", addedAt: "2026-10-01T00:00:02.000Z")),
            ("Member", SessionRows.member("u1", role: "owner", addedAt: "2026-10-01T00:00:01.000Z")),
            ("Member", SessionRows.member("u0", role: "viewer", addedAt: "2026-10-01T00:00:02.000Z")),
        ])
        try await eventually(description: "the rows are read") { view.status == .thinking && view.members.count == 3 }
        XCTAssertEqual(view.activeTurnId, "t1")
        XCTAssertEqual(view.session?.agentKey, "helper")
        XCTAssertEqual(view.members.map(\.id), ["u1", "u0", "u2"], "by addedAt, then id")
        XCTAssertEqual(view.members.map(\.role), [.owner, .viewer, .participant])

        // A cleared queueSeq drops the message from the queue.
        try h.db3.write([("Message", SessionRows.message("m3", seq: 3, turnId: "t2", authorUserId: "u3", queueSeq: .null))])
        try await eventually(description: "m3 leaves the queue") { view.queue.map(\.userId) == ["u2"] }
        // E10: a status outside the vocabulary.
        try h.db3.write([("Session", SessionRows.session(status: "musing"))])
        try await eventually(description: "the status changes") { view.status == .unknown("musing") }
        XCTAssertNil(view.activeTurnId)
        await view.close()
    }

    func testAnAppMessagesQueueEntryIsItsAuthorAndOneWithNoneGroupsUnderTheEmptyId() async throws {
        let h = try await harness("queue-app")
        session(h)
        try h.db3.write([
            ("Message", SessionRows.message("m1", seq: 1, authorKind: "app", authorUserId: "u5", queueSeq: 1)),
            ("Message", SessionRows.message("m2", seq: 2, authorKind: "app", authorUserId: nil, queueSeq: 2)),
            ("Message", SessionRows.message("m3", seq: 3, authorKind: "user", authorUserId: "u5", queueSeq: 3)),
        ])
        let view = try await open(h)
        XCTAssertEqual(view.queue, [
            PrimitiveQueueEntry(userId: "u5", messageIds: ["m1", "m3"]),
            PrimitiveQueueEntry(userId: "", messageIds: ["m2"]),
        ])
        await view.close()
    }

    func testAnUnknownStatusReadsUnknownOnTheViewAndOnInfo() async throws {
        let h = try await harness("unknown-status")
        h.script.on(.get, "/agent-sessions/s1", agentSessionInfoJSON("s1").replacingOccurrences(
            of: #""status":"idle""#, with: #""status":"hibernating""#
        ))
        try h.db3.write([("Session", SessionRows.session(status: "hibernating"))])
        let view = try await open(h)
        XCTAssertEqual(view.status, .unknown("hibernating"))
        XCTAssertEqual(view.info.status, .unknown("hibernating"))
        await view.close()
    }

    func testARowWriteToAnyOfTheSevenModelsRefreshesOnceAndNotifiesOnce() async throws {
        let h = try await harness("refresh")
        session(h)
        try seedTurn(h.db3)
        let view = try await open(h)
        let counter = Counter()
        let removedCounter = Counter()
        let remove = view.onChange { [view] in
            // Reading state from a listener would deadlock if it ran under the lock.
            _ = view.messages
            counter.increment()
        }
        let removeOther = view.onChange { removedCounter.increment() }
        removeOther()
        let writes: [(String, [String: JSONValue], () -> Bool)] = [
            ("Session", SessionRows.session(status: "idle"), { view.status == .idle }),
            ("Member", SessionRows.member("u3", role: "viewer", addedAt: "2026-10-01T00:00:03.000Z"), { view.members.count == 3 }),
            ("Turn", SessionRows.turn("t1", seq: 1, status: "completed"), { self.synced(view).last?.turn?.status == .completed }),
            ("Message", SessionRows.message("m3", seq: 3, turnId: "t1"), { self.synced(view).count == 3 }),
            ("Part", SessionRows.text("m3-p", messageId: "m3", seq: 1), { self.synced(view).last?.parts.count == 1 }),
            ("ToolCall", SessionRows.call("call-2", messageId: "m3", seq: 2, turnId: "t1"), { self.synced(view).last?.parts.count == 2 }),
            ("Step", SessionRows.step("s2", turnId: "t1", seq: 2), { self.synced(view).last?.steps.count == 2 }),
        ]
        for (model, row, landed) in writes {
            let before = counter.count
            try h.db3.write(model, row)
            try await eventually(description: "a \(model) write is read") { landed() }
            await settle()
            XCTAssertEqual(counter.count, before + 1, "a \(model) write notifies once")
        }
        XCTAssertEqual(removedCounter.count, 0, "a removed listener is not called")

        let burst = 40
        let beforeBurst = counter.count
        try h.db3.write((0..<burst).map { n in ("Session", SessionRows.session(status: "thinking", activeTurnId: "t\(n)")) })
        try await eventually(description: "the burst is read") { view.activeTurnId == "t\(burst - 1)" }
        await settle()
        XCTAssertLessThan(counter.count - beforeBurst, burst, "a burst of writes notifies fewer times than it writes")

        remove()
        let afterRemove = counter.count
        try h.db3.write("Message", SessionRows.message("m4", seq: 4))
        try await eventually(description: "m4 arrives") { self.synced(view).count == 4 }
        XCTAssertEqual(counter.count, afterRemove)

        let late = Counter()
        view.onChange { late.increment() }
        await view.close()
        try h.db3.write("Message", SessionRows.message("m5", seq: 5))
        await settle()
        XCTAssertEqual(late.count, 0, "nothing fires after close")
        XCTAssertEqual(synced(view).count, 4, "nothing is read after close")
    }

    func testAnUndecodableSessionRowLeavesSessionNilAndAnUnknownPartKindIsListed() async throws {
        let h = try await harness("undecodable")
        session(h)
        try h.db3.write([
            ("Session", ["id": "s1", "status": "thinking"]),
            ("Message", SessionRows.message("m1", seq: 1)),
            ("Part", ["id": "m1-p", "messageId": "m1", "seq": 1, "kind": "hologram"]),
            ("Message", ["id": "m-bad", "seq": "2", "authorKind": "user", "createdAt": .string(SessionRows.at)]),
        ])
        let view = try await open(h)
        XCTAssertNil(view.session, "a session row missing a required column does not decode")
        XCTAssertNil(view.status)
        XCTAssertEqual(synced(view).map(\.messageId), ["m1"], "a message that does not decode is left out")
        guard case let .part(part) = synced(view).first?.parts.first else { return XCTFail("no part") }
        XCTAssertEqual(part.content, .unknown(kind: "hologram"))
        await view.close()
    }

    func testAPendingEntryLeavesWhenItsRowArrives() async throws {
        let h = try await harness("pending-leaves")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/messages", #"{"messageId":"m-accepted","seq":5,"turnId":"t1","queued":false}"#)
        let view = try await open(h)
        _ = try await view.send(text: "hello")
        let entry = try XCTUnwrap(pending(view).first)
        try h.db3.write("Message", SessionRows.message("m-accepted", seq: 5, clientMessageId: entry.clientMessageId))
        try await eventually(description: "the pending entry gives way to its row") {
            self.pending(view).isEmpty && self.synced(view).map(\.messageId) == ["m-accepted"]
        }
        XCTAssertEqual(synced(view).first?.clientMessageId, entry.clientMessageId)
        await view.close()
    }

    func testCancelResolvesItsTurnFromTheSessionRow() async throws {
        let h = try await harness("cancel-row")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/cancel", #"{"turnId":"x","cancelled":true,"nextTurnId":null}"#)
        try h.db3.write("Session", SessionRows.session(status: "thinking", activeTurnId: "t-row"))
        let view = try await open(h)
        XCTAssertEqual(view.activeTurnId, "t-row")
        _ = try await view.cancel()
        XCTAssertEqual(h.transport.lastCall?.jsonBody, ["turnId": "t-row"])
        XCTAssertEqual(h.transport.calls.map(\.method), [.get, .post], "no get: the row names the turn")
        await view.close()
    }

    // MARK: - Behavior 9: paging

    /// `count` messages with seq 1…count, each with one part, one call and
    /// its own turn with one step: message n is `m<nnn>` of turn `t<n>`.
    private func seedMessages(_ db3: SessionDb3, count: Int) throws {
        var rows: [(model: String, row: [String: JSONValue])] = []
        for n in 1...count {
            let id = "m\(String(format: "%03d", n))"
            rows.append(("Message", SessionRows.message(id, seq: Double(n), turnId: "t\(n)")))
            rows.append(("Part", SessionRows.text("\(id)-p", messageId: id, seq: 1)))
            rows.append(("ToolCall", SessionRows.call("\(id)-c", messageId: id, seq: 2, turnId: "t\(n)", state: "output-available")))
            rows.append(("Step", SessionRows.step("\(id)-s", turnId: "t\(n)", seq: 1)))
            rows.append(("Turn", SessionRows.turn("t\(n)", seq: Double(n), status: "completed")))
        }
        try db3.write(rows)
    }

    func testLoadOlderPagesBackWithEachMessagesRowsToTheStartThenAnswersNothing() async throws {
        let h = try await harness("older")
        session(h)
        try seedMessages(h.db3, count: 120)
        let view = try await open(h)
        XCTAssertEqual(synced(view).map(\.seq), (71...120).map(Double.init), "the latest 50 by seq, oldest first")
        XCTAssertTrue(view.hasOlder)

        async let a = view.loadOlder()
        async let b = view.loadOlder()
        let (pageA, pageB) = try await (a, b)
        XCTAssertEqual(pageA, AgentSessionLoadOlderResult(loaded: 50, hasOlder: true))
        XCTAssertEqual(pageB, pageA, "concurrent calls share one page")
        XCTAssertEqual(synced(view).count, 100)
        XCTAssertEqual(synced(view).first?.seq, 21)

        let last = try await view.loadOlder()
        XCTAssertEqual(last, AgentSessionLoadOlderResult(loaded: 20, hasOlder: false))
        XCTAssertEqual(synced(view).map(\.seq), (1...120).map(Double.init))
        XCTAssertFalse(view.hasOlder)
        let first = try XCTUnwrap(synced(view).first)
        XCTAssertEqual(first.parts.map(\.id), ["m001-p", "m001-c"], "the page's parts and calls")
        XCTAssertEqual(first.steps.map(\.id), ["m001-s"], "its turn's steps")
        XCTAssertEqual(first.turn?.id, "t1", "its turn")

        let none = try await view.loadOlder()
        XCTAssertEqual(none, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false), "at the start of the session")

        await view.close()
        let closed = try await view.loadOlder()
        XCTAssertEqual(closed, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false), "after close")
    }

    // MARK: - Behavior 10: client tools over the active turn's calls

    /// A turn `t1` of `initiator`, active, with an agent message carrying `calls`.
    private func seedToolTurn(_ db3: SessionDb3, initiator: String, calls: [[String: JSONValue]]) throws {
        var rows: [(model: String, row: [String: JSONValue])] = [
            ("Session", SessionRows.session(status: "awaiting_answer", activeTurnId: "t1")),
            ("Turn", SessionRows.turn("t1", seq: 1, initiatorUserId: initiator)),
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1", authorKind: "agent")),
        ]
        rows += calls.map { ("ToolCall", $0) }
        try db3.write(rows)
    }

    private func answers(_ h: Harness) -> [RecordedRequest] {
        h.transport.calls.filter { $0.path.hasSuffix("/answer") }
    }

    func testAClientToolRunsOnlyWhenTheActiveTurnNamesTheCurrentUserAndOnlyOnceWhileAnswered() async throws {
        let h = try await harness("tools-initiator")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/calls/call-1/answer", #"{"callId":"call-1","state":"output-available"}"#)
        try seedToolTurn(h.db3, initiator: "u2", calls: [SessionRows.call("call-1", messageId: "m1", seq: 1, turnId: "t1")])
        let view = try await open(h)
        let runs = Recorder<AgentClientToolCall<JSONValue>>()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call)
            return AgentClientToolResult(output: ["count": 2])
        }])
        await settle()
        XCTAssertEqual(runs.all.count, 0, "another member's turn runs nothing here")

        try h.db3.write("Turn", SessionRows.turn("t1", seq: 1, initiatorUserId: "u1"))
        try await eventually(description: "the initiator's handler runs") { runs.all.count == 1 }
        try await eventually(description: "its answer is sent") { self.answers(h).count == 1 }
        let call = try XCTUnwrap(runs.all.first)
        XCTAssertEqual(call.callId, "call-1")
        XCTAssertEqual(call.partId, "call-1", "the call's row id")
        XCTAssertEqual(call.turnId, "t1")
        XCTAssertEqual(call.messageId, "m1")
        XCTAssertEqual(call.input, ["question": "How many?"])
        XCTAssertEqual(answers(h).first?.path, "/agent-sessions/s1/calls/call-1/answer")
        XCTAssertEqual(answers(h).first?.jsonBody, ["output": ["count": 2]])
        try await eventually(description: "the run settles") { view.runningClientToolCalls.isEmpty }

        // Answered: not run again while its state is unchanged.
        try h.db3.write("Message", SessionRows.message("m2", seq: 2))
        try await eventually(description: "the write is read") { self.synced(view).count == 2 }
        await settle()
        XCTAssertEqual(runs.all.count, 1)
        await view.close()
    }

    func testALostOrRefusedAnswerIsNotRunAgainUntilTheCallChanges() async throws {
        let h = try await harness("tools-refused")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/calls/call-lost/answer", status: 409,
                    #"{"code":"AGENT_CALL_ANSWERED","error":"answered"}"#)
        h.script.on(.post, "/agent-sessions/s1/calls/call-refused/answer", status: 400,
                    #"{"code":"AGENT_ANSWER_INVALID","error":"count must be at least 1"}"#)
        h.script.on(.post, "/agent-sessions/s1/calls/call-refused/answer", #"{"callId":"call-refused","state":"output-available"}"#)
        try seedToolTurn(h.db3, initiator: "u1", calls: [
            SessionRows.call("call-lost", messageId: "m1", seq: 1, turnId: "t1"),
            SessionRows.call("call-refused", messageId: "m1", seq: 2, turnId: "t1"),
        ])
        let view = try await open(h)
        let runs = Recorder<String>()
        let errors = Recorder<AgentClientToolError>()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            return AgentClientToolResult(output: ["count": 0])
        }], options: HandleClientToolsOptions(onError: { errors.append($0) }))
        try await eventually(description: "both run, one refused") { runs.all.count == 2 && errors.all.count == 1 }
        XCTAssertEqual(Set(runs.all), ["call-lost", "call-refused"])
        XCTAssertEqual(errors.all.first?.callId, "call-refused")
        XCTAssertEqual(errors.all.first?.code, "AGENT_ANSWER_INVALID", "a lost answer is no error")
        try await eventually(description: "the runs settle") { view.runningClientToolCalls.isEmpty }

        try h.db3.write("Message", SessionRows.message("m2", seq: 2))
        try await eventually(description: "the write is read") { self.synced(view).count == 2 }
        await settle()
        XCTAssertEqual(runs.all.count, 2, "neither is run again while its call is unchanged")

        // The refused call's state changes (approved after an approval): it runs again.
        try h.db3.write("ToolCall", SessionRows.call(
            "call-refused", messageId: "m1", seq: 2, turnId: "t1", state: "approval-responded", approvalApproved: true
        ))
        try await eventually(description: "the changed call runs again") { runs.all.count == 3 }
        XCTAssertEqual(runs.all.last, "call-refused")
        XCTAssertEqual(errors.all.count, 1)
        await view.close()
    }

    func testATransportFailureRunsAgainOnceTheDb3IsLiveAfterAReconnect() async throws {
        let h = try await harness("tools-live")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/calls/call-1/answer", status: 502, "<html>bad gateway</html>")
        h.script.on(.post, "/agent-sessions/s1/calls/call-1/answer", #"{"callId":"call-1","state":"output-available"}"#)
        try seedToolTurn(h.db3, initiator: "u1", calls: [SessionRows.call("call-1", messageId: "m1", seq: 1, turnId: "t1")])
        let view = try await open(h)
        let runs = Recorder<String>()
        let errors = Recorder<AgentClientToolError>()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            return AgentClientToolResult(output: ["count": 3])
        }], options: HandleClientToolsOptions(onError: { errors.append($0) }))
        try await eventually(description: "the transport failure is heard") { errors.all.count == 1 }
        XCTAssertNil(errors.all.first?.code, "no server code: a transport failure")
        try await eventually(description: "the run settles") { view.runningClientToolCalls.isEmpty }
        XCTAssertEqual(runs.all.count, 1)

        // The socket drops and returns: live again, the call is evaluated again.
        h.db3.setSocket(false)
        try await eventually(description: "reconnecting, as the subscription hears it") { h.db3.appliedPhase == .reconnecting }
        h.db3.setSocket(true)
        h.db3.report(.live)
        try await eventually(description: "the call runs again") { runs.all.count == 2 }
        try await eventually(description: "its answer lands") { self.answers(h).count == 2 }
        await view.close()
    }

    func testCloseCancelsARunningHandlerAndItsAnswerIsNeverSent() async throws {
        let h = try await harness("tools-close")
        session(h)
        try seedToolTurn(h.db3, initiator: "u1", calls: [SessionRows.call("call-1", messageId: "m1", seq: 1, turnId: "t1")])
        let view = try await open(h)
        let gate = AsyncGate()
        let cancelled = Recorder<Bool>()
        try view.handleClientTools(["pick": AgentClientToolHandler { _ in
            await gate.wait()
            cancelled.append(Task.isCancelled)
            return AgentClientToolResult(output: ["count": 1])
        }])
        try await eventually(description: "the handler runs") { view.runningClientToolCalls == ["call-1"] }
        await view.close()
        XCTAssertEqual(view.runningClientToolCalls, [])
        await gate.open()
        try await eventually(description: "the handler returns") { !cancelled.all.isEmpty }
        XCTAssertEqual(cancelled.all, [true])
        await settle()
        XCTAssertEqual(answers(h).count, 0, "no answer is sent")
    }

    // MARK: - Edge E8 (the hermetic half): two views of one session

    func testTwoViewsOfOneSessionEachHoldTheirOwnSubscription() async throws {
        let h = try await harness("twice")
        session(h)
        try h.db3.write("Message", SessionRows.message("m1", seq: 1))
        let first = try await open(h)
        let second = try await open(h)
        XCTAssertEqual(synced(first).map(\.messageId), ["m1"])
        XCTAssertEqual(synced(second).map(\.messageId), ["m1"])
        await first.close()
        let state = try await h.db3.state()
        XCTAssertTrue(state.subscribed, "the other view's subscription holds")
        try h.db3.write("Message", SessionRows.message("m2", seq: 2))
        try await eventually(description: "the other view still refreshes") { self.synced(second).count == 2 }
        XCTAssertEqual(synced(first).count, 1, "the closed view reads nothing more")
        await second.close()
        try await eventually(description: "nothing is subscribed") { (try? await h.db3.state().subscribed) == false }
    }

    // MARK: - #4466: a call's artifact, view-local rules

    /// No blob content is scripted: a read would go to the client's
    /// unreachable API and throw, so an answer proves none was made.
    func testArtifactAnswersTheInlineValueNullAndNilWithoutReadingABlob() async throws {
        let h = try await harness("artifact-inline")
        session(h)
        try h.db3.write([
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1", authorKind: "agent")),
            ("ToolCall", SessionRows.call("inline", messageId: "m1", seq: 1, turnId: "t1", state: "output-available", artifact: #"{"rows":[1,2,3]}"#)),
            ("ToolCall", SessionRows.call("null", messageId: "m1", seq: 2, turnId: "t1", state: "output-available", artifact: "null")),
            ("ToolCall", SessionRows.call("none", messageId: "m1", seq: 3, turnId: "t1", state: "output-available")),
            ("ToolCall", SessionRows.call("empty-id", messageId: "m1", seq: 4, turnId: "t1", state: "output-available", artifact: #"{"a":1}"#, artifactBlobId: "")),
        ])
        let view = try await open(h)
        func call(_ id: String) throws -> AgentSessionToolCallRecord { try XCTUnwrap(view.toolCall(id), id) }
        let inline = try await view.artifact(of: call("inline"))
        XCTAssertEqual(inline, ["rows": [1, 2, 3]])
        let null = try await view.artifact(of: call("null"))
        XCTAssertEqual(null, .null, "a stored JSON null answers .null, not nil")
        let none = try await view.artifact(of: call("none"))
        XCTAssertNil(none)
        let emptyId = try await view.artifact(of: call("empty-id"))
        XCTAssertEqual(emptyId, ["a": 1], "an empty blob id is no blob id")
        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/s1"])
        await view.close()
    }

    func testArtifactOnAClosedViewThrowsInvalidArgumentWithoutReading() async throws {
        let h = try await harness("artifact-closed")
        session(h)
        try h.db3.write([
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1", authorKind: "agent")),
            ("ToolCall", SessionRows.call("blob", messageId: "m1", seq: 1, turnId: "t1", state: "output-available", artifactBlobId: "blob-1")),
            ("ToolCall", SessionRows.call("inline", messageId: "m1", seq: 2, turnId: "t1", state: "output-available", artifact: #"{"a":1}"#)),
        ])
        let view = try await open(h)
        let calls = view.toolCalls
        XCTAssertEqual(calls.count, 2)
        await view.close()
        for call in calls {
            await assertCode(.invalidArgument) { _ = try await view.artifact(of: call) }
        }
        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/s1"])
    }

    // MARK: - Edge E6: page size and a sessions API with no client

    func testAPageSizeOutsideTheRangeThrowsBeforeAnyRequest() async throws {
        let h = try await harness("page-size")
        for size in [0, 501] {
            await assertCode(.invalidArgument) { _ = try await self.open(h, pageSize: size) }
        }
        XCTAssertTrue(h.transport.calls.isEmpty)
        XCTAssertEqual(h.db3.opens, [])
    }

    func testOpenOnASessionsApiWithNoClientThrowsUnavailable() async throws {
        let transport = RecordingTransport(json: agentSessionInfoJSON("s1"))
        let sessions = AgentSessionsAPI(transport: transport)
        await assertCode(.unavailable) { _ = try await sessions.open(sessionId: "s1") }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - Behavior 14 (#3810): pending entries

    func testSendShowsAPendingEntryCarryingItsBody() async throws {
        let h = try await harness("pending")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/messages", #"{"messageId":"m-accepted","seq":5,"turnId":"t1","queued":false}"#)
        let view = try await open(h)

        let result = try await view.send(
            text: "hello", files: [AgentSessionFileRef(blobId: "b1")],
            context: ["plan": "pro"], timezone: "Europe/Paris", locale: "fr-FR"
        )
        XCTAssertEqual(result.messageId, "m-accepted")
        let entry = try XCTUnwrap(pending(view).first)
        XCTAssertEqual(entry.state, .sending)
        XCTAssertEqual(entry.text, "hello")
        XCTAssertEqual(entry.files, [AgentSessionFileRef(blobId: "b1")])
        XCTAssertEqual(entry.context, ["plan": "pro"])
        XCTAssertEqual(entry.timezone, "Europe/Paris")
        XCTAssertEqual(entry.locale, "fr-FR")
        XCTAssertEqual(entry.messageId, "m-accepted")
        XCTAssertEqual(entry.clientMessageId.count, 26, "a generated ULID")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, [
            "text": "hello", "files": [["blobId": "b1"]], "clientMessageId": .string(entry.clientMessageId),
            "context": ["plan": "pro"], "timezone": "Europe/Paris", "locale": "fr-FR",
        ])
        await view.close()
    }

    func testAPendingEntryIsVisibleWhileTheSendIsInFlight() async throws {
        let h = try await harness("pending-in-flight")
        let gate = AsyncGate()
        let transport = RecordingTransport { request in
            if request.path == "/agent-sessions/s1/messages" {
                await gate.wait()
                return TransportResponse(status: 200, headers: [:], body: Data(#"{"messageId":"m9","seq":9,"turnId":null,"queued":true}"#.utf8))
            }
            return TransportResponse(status: 200, headers: [:], body: Data(agentSessionInfoJSON("s1").utf8))
        }
        let sessions = AgentSessionsAPI(transport: transport, client: h.client)
        let view = try await sessions.open(sessionId: "s1", db3: h.db3)

        let sending = Task { try await view.send(text: "first", clientMessageId: "cm-1") }
        try await eventually(description: "the entry appears before the answer") { self.pending(view).count == 1 }
        XCTAssertEqual(pending(view).first?.state, .sending)
        XCTAssertNil(pending(view).first?.messageId)
        await gate.open()
        _ = try await sending.value
        XCTAssertEqual(pending(view).first?.messageId, "m9")
        await view.close()
    }

    func testARefusedSendFailsTheEntryAndRetryResendsTheSameBody() async throws {
        let h = try await harness("failed")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/messages", status: 429,
                    #"{"code":"AGENT_SESSION_RATE_LIMITED","error":"Slow down","details":{"retryAfter":12}}"#)
        h.script.on(.post, "/agent-sessions/s1/messages", #"{"messageId":"m2","seq":2,"turnId":"t2","queued":false}"#)
        let view = try await open(h)

        do {
            try await view.send(text: "hi", files: [AgentSessionFileRef(blobId: "b")], clientMessageId: "cm-x",
                                context: ["k": 1], timezone: "UTC", locale: "en")
            XCTFail("the send should rethrow")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_RATE_LIMITED")
        }
        let failed = try XCTUnwrap(pending(view).first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, AgentSessionSendError(code: "AGENT_SESSION_RATE_LIMITED", message: "Slow down", retryAfter: 12))
        let firstBody = h.transport.lastCall?.jsonBody

        let retried = try await view.retry(clientMessageId: "cm-x")
        XCTAssertEqual(retried.messageId, "m2")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, firstBody, "retry resends an identical body")
        XCTAssertEqual(pending(view).first?.state, .sending)
        XCTAssertNil(pending(view).first?.error)

        await assertCode(.invalidArgument) { _ = try await view.retry(clientMessageId: "cm-unknown") }
        await view.close()
    }

    func testDismissRemovesOnlyAFailedEntryAndASecondSendReplacesTheFirst() async throws {
        let h = try await harness("dismiss")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/messages", status: 409, #"{"code":"AGENT_CLIENT_ID_CONFLICT","error":"conflict"}"#)
        let view = try await open(h)

        _ = try? await view.send(text: "one", clientMessageId: "cm-1")
        _ = try? await view.send(text: "two", clientMessageId: "cm-1")
        XCTAssertEqual(pending(view).map(\.text), ["two"], "an earlier entry under the same id gives way")
        XCTAssertEqual(pending(view).first?.error?.code, "AGENT_CLIENT_ID_CONFLICT")

        XCTAssertFalse(view.dismiss(clientMessageId: "cm-unknown"))
        XCTAssertTrue(view.dismiss(clientMessageId: "cm-1"))
        XCTAssertTrue(pending(view).isEmpty)
        XCTAssertFalse(view.dismiss(clientMessageId: "cm-1"))
        await view.close()
    }

    // MARK: - Behavior 17 (#3810): cancel, refreshInfo, markRead

    func testCancelResolvesItsTurnFromTheArgumentOrGet() async throws {
        let h = try await harness("cancel")
        session(h)
        h.script.on(.post, "/agent-sessions/s1/cancel", #"{"turnId":"x","cancelled":true,"nextTurnId":null}"#)
        let view = try await open(h)

        // Neither an argument, a row nor a turn from get: nothing is sent.
        await assertCode(.agentSessionNoActiveTurn) { _ = try await view.cancel() }
        XCTAssertFalse(h.transport.calls.contains { $0.path.hasSuffix("/cancel") })

        _ = try await view.cancel(turnId: "t-given")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, ["turnId": "t-given"])

        h.script.set(.get, "/agent-sessions/s1", agentSessionInfoJSON("s1", turnId: "t-from-get"))
        _ = try await view.cancel()
        XCTAssertEqual(h.transport.lastCall?.jsonBody, ["turnId": "t-from-get"])
        XCTAssertEqual(h.transport.calls.suffix(2).map(\.method), [.get, .post])
        await view.close()
    }

    func testRefreshInfoReReadsGetAndNotifies() async throws {
        let h = try await harness("refresh-info")
        session(h)
        let view = try await open(h)
        let counter = Counter()
        view.onChange { counter.increment() }
        XCTAssertNil(view.info.turn)
        h.script.set(.get, "/agent-sessions/s1", agentSessionInfoJSON("s1", turnId: "t9"))
        let info = try await view.refreshInfo()
        XCTAssertEqual(info.turn?.turnId, "t9")
        XCTAssertEqual(view.info.turn?.turnId, "t9")
        XCTAssertEqual(counter.count, 1)

        h.script.on(.post, "/agent-sessions/s1/calls/c1/answer", #"{"callId":"c1","state":"output-available"}"#)
        let answered = try await view.answer(callId: "c1", .output(["ok": true]))
        XCTAssertEqual(answered.state, .outputAvailable)
        h.script.on(.post, "/agent-sessions/s1/events", #"{"messageId":"e1","seq":3}"#)
        let event = try await view.recordEvent(AgentSessionEvent(kind: "viewed", data: ["at": 1]))
        XCTAssertEqual(event.messageId, "e1")
        await view.close()
    }

    func testMarkReadMarksTheSessionClearsTheDotAndNotifies() async throws {
        let h = try await harness("mark-read")
        session(h, hasUnread: true)
        let view = try await open(h)
        XCTAssertTrue(view.info.hasUnread)
        let counter = Counter()
        view.onChange { counter.increment() }
        h.script.on(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-02T00:00:09.000Z"}"#)
        let marked = try await view.markRead()
        XCTAssertEqual(marked.lastReadAt, "2026-10-02T00:00:09.000Z")
        XCTAssertEqual(h.transport.lastCall?.path, "/agent-sessions/s1/read")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, [:])
        XCTAssertFalse(view.info.hasUnread)
        XCTAssertEqual(view.info.lastReadAt, "2026-10-02T00:00:09.000Z")
        XCTAssertEqual(view.info.sessionId, "s1", "the rest of info is kept")
        XCTAssertEqual(counter.count, 1)
        await view.close()
    }
}

/// A one-shot gate an async test opens to let a scripted answer through.
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
