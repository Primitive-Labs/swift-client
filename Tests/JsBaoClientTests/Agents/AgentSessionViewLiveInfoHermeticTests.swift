import XCTest
@testable import JsBaoClient

/// An open `AgentSessionView`'s live `info` (#4380, behavior 19 and the
/// hermetic halves of 14, 15, 35 and 37; #4884 behavior 20): the session's
/// change frames update it, a reconnect reads it again, and `markRead:
/// .whileOpen` keeps the session read, over the session's db3 subscription.
/// Frames go through the client's own WebSocket dispatch and connection states
/// through its status path; the db3 is a real binding and lifecycle
/// (`SessionDb3`), the session calls a recording transport. The JS client's
/// `sessionView.ts` is the reference.
final class AgentSessionViewLiveInfoHermeticTests: XCTestCase {
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
        private var hooks: [String: [@Sendable () async -> Void]] = [:]

        func on(_ method: HTTPMethod, _ path: String, status: Int = 200, _ body: String) {
            lock.withLock { answers["\(method.rawValue) \(path)", default: []].append((status, body)) }
        }

        func set(_ method: HTTPMethod, _ path: String, status: Int = 200, _ body: String) {
            lock.withLock { answers["\(method.rawValue) \(path)"] = [(status, body)] }
        }

        /// Run `hook` while the next call to this route is in flight, before it answers.
        func during(_ method: HTTPMethod, _ path: String, _ hook: @escaping @Sendable () async -> Void) {
            lock.withLock { hooks["\(method.rawValue) \(path)", default: []].append(hook) }
        }

        func answer(_ request: RecordedRequest) async -> TransportResponse {
            let key = "\(request.method.rawValue) \(request.path)"
            // The answer is read when the request is made, then delivered.
            let (status, body): (Int, String) = lock.withLock {
                guard var queue = answers[key], let first = queue.first else {
                    return (404, #"{"code":"NOT_SCRIPTED","error":"\#(key)"}"#)
                }
                if queue.count > 1 { queue.removeFirst(); answers[key] = queue }
                return first
            }
            let hook: (@Sendable () async -> Void)? = lock.withLock {
                guard var queue = hooks[key], !queue.isEmpty else { return nil }
                let first = queue.removeFirst()
                hooks[key] = queue
                return first
            }
            if let hook { await hook() }
            return TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
    }

    private struct Harness {
        let client: JsBaoClient
        let sessions: AgentSessionsAPI
        let transport: RecordingTransport
        let script: Script
        /// Each session's db3, by session id.
        let db3s: LockedBox<[String: SessionDb3]>
    }

    private func harness(_ name: String) -> Harness {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-live-info-\(name)",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let script = Script()
        let transport = RecordingTransport { await script.answer($0) }
        return Harness(
            client: client, sessions: AgentSessionsAPI(transport: transport, client: client),
            transport: transport, script: script, db3s: LockedBox([:])
        )
    }

    private static func info(
        _ sessionId: String, role: String = "participant", hasUnread: Bool = true,
        lastActivityAt: String = "2026-10-12T12:00:00.000Z", title: String = "Budget"
    ) -> String {
        #"""
        {"sessionId":"\#(sessionId)","agentKey":"advisor","ownerUserId":"u1",
         "createdAt":"2026-10-12T11:00:00.000Z","title":"\#(title)","scope":null,"lastActivityAt":"\#(lastActivityAt)",
         "hasUnread":\#(hasUnread),"lastReadAt":null,
         "members":{"viewers":[],"participants":["u2"]},"role":"\#(role)","status":"idle","turn":null}
        """#
    }

    private static func frame(
        _ sessionId: String, at: String, change: String = "activity",
        title: String = "Budget", lastActivityAt: String, hasUnread: Bool = true, lastReadAt: String? = nil,
        status: String = "thinking", participants: [String] = ["u2", "u3"]
    ) -> String {
        let read = lastReadAt.map { "\"\($0)\"" } ?? "null"
        let members = participants.map { "\"\($0)\"" }.joined(separator: ",")
        return #"""
        {"type":"agentSession","action":"upsert","change":"\#(change)","at":"\#(at)","sessionId":"\#(sessionId)",
         "item":{"sessionId":"\#(sessionId)","agentKey":"advisor","ownerUserId":"u1",
                 "createdAt":"2026-10-12T11:00:00.000Z","scope":null,"title":"\#(title)","lastActivityAt":"\#(lastActivityAt)",
                 "status":"\#(status)","role":"participant","hasUnread":\#(hasUnread),"lastReadAt":\#(read)},
         "members":{"viewers":[],"participants":[\#(members)]}}
        """#
    }

    private static func removedFrame(_ sessionId: String, at: String) -> String {
        #"{"type":"agentSession","action":"removed","change":"removed","at":"\#(at)","sessionId":"\#(sessionId)","item":null,"members":null}"#
    }

    /// The session's db3 on this device, and `get` scripted to answer the session.
    private func session(
        _ h: Harness, _ sessionId: String, role: String = "participant", scripted: Bool = true
    ) async throws {
        let db3 = try await SessionDb3.make(id: sessionId)
        db3s.append(db3)
        h.db3s.withValue { $0[sessionId] = db3 }
        if scripted {
            h.script.on(.get, "/agent-sessions/\(sessionId)", Self.info(sessionId, role: role))
        }
    }

    private func open(_ h: Harness, _ sessionId: String, markRead: AgentSessionMarkRead? = nil) async throws -> AgentSessionView {
        let db3 = try XCTUnwrap(h.db3s.value[sessionId])
        return try await h.sessions.open(sessionId: sessionId, options: OpenAgentSessionOptions(markRead: markRead), db3: db3)
    }

    private func reads(_ h: Harness, _ sessionId: String) -> Int {
        h.transport.calls.filter { $0.method == .post && $0.path == "/agent-sessions/\(sessionId)/read" }.count
    }

    private func gets(_ h: Harness, _ sessionId: String) -> Int {
        h.transport.calls.filter { $0.method == .get && $0.path == "/agent-sessions/\(sessionId)" }.count
    }

    private func eventually(timeout: TimeInterval = 5, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - Behavior 14 on Swift

    func testFramesUpdateInfoAndARemovedFrameChangesNothing() async throws {
        let h = harness("frames")
        try await session(h, "s1")
        let view = try await open(h, "s1")
        let changes = LockedBox(0)
        view.onChange { changes.add(1) }
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:20.000Z", lastActivityAt: "2026-10-12T12:00:20.000Z"
        ))
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:21.000Z", change: "title", title: "Rent",
            lastActivityAt: "2026-10-12T12:00:20.000Z"
        ))
        try await eventually { view.info.title == "Rent" }
        XCTAssertEqual(view.info.lastActivityAt, "2026-10-12T12:00:20.000Z")
        XCTAssertTrue(view.info.hasUnread)
        XCTAssertEqual(view.info.status, .thinking)
        XCTAssertEqual(view.info.members, AgentSessionMembers(viewers: [], participants: ["u2", "u3"]))
        XCTAssertGreaterThanOrEqual(changes.value, 1)
        let before = view.info
        // Another session's frame, a removal, and an upsert older than the removal change nothing.
        await h.client.handleWebSocketMessage(Self.frame(
            "s2", at: "2026-10-12T12:01:30.000Z", title: "Other", lastActivityAt: "2026-10-12T12:01:30.000Z"
        ))
        await h.client.handleWebSocketMessage(Self.removedFrame("s1", at: "2026-10-12T12:01:35.000Z"))
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:01:34.000Z", title: "Stale", lastActivityAt: "2026-10-12T12:01:34.000Z"
        ))
        try await settle()
        XCTAssertEqual(view.info, before)
        await view.close()
    }

    // MARK: - CSO-4380-007 on Swift

    func testAMarkReadAnswerKeepsActivityThatArrivedAfterItsMarker() async throws {
        let h = harness("late-read")
        try await session(h, "s1")
        let client = h.client
        let view = try await open(h, "s1")
        h.script.set(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-12T12:00:05.000Z"}"#)
        // Activity after the marker is heard, and applied, while the call answers.
        let frame = Self.frame(
            "s1", at: "2026-10-12T12:00:20.000Z", lastActivityAt: "2026-10-12T12:00:20.000Z"
        )
        h.script.during(.post, "/agent-sessions/s1/read") {
            await client.handleWebSocketMessage(frame)
            let deadline = Date().addingTimeInterval(5)
            while view.info.lastActivityAt != "2026-10-12T12:00:20.000Z", Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let marked = try await view.markRead()
        XCTAssertEqual(marked.lastReadAt, "2026-10-12T12:00:05.000Z")
        XCTAssertTrue(view.info.hasUnread)
        XCTAssertEqual(view.info.lastActivityAt, "2026-10-12T12:00:20.000Z")
        XCTAssertEqual(view.info.lastReadAt, "2026-10-12T12:00:05.000Z")

        // A marker after the activity clears the dot.
        h.script.set(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-12T12:00:30.000Z"}"#)
        try await view.markRead()
        XCTAssertFalse(view.info.hasUnread)
        XCTAssertEqual(view.info.lastReadAt, "2026-10-12T12:00:30.000Z")
        await view.close()
    }

    // MARK: - Behaviors 35 and 37 on Swift

    func testAViewOpenedBeforeTheSocketReadsInfoAgainOnTheFirstConnected() async throws {
        let h = harness("reconnect")
        try await session(h, "s1")
        let view = try await open(h, "s1")
        XCTAssertEqual(gets(h, "s1"), 1)
        h.script.set(.get, "/agent-sessions/s1", Self.info(
            "s1", lastActivityAt: "2026-10-12T12:05:00.000Z", title: "Done offline"
        ))
        h.client.webSocketManagerOnStatusChange(.connected)
        h.client.webSocketManagerOnStatusChange(.connected)
        try await eventually { view.info.title == "Done offline" }
        try await settle()
        XCTAssertEqual(gets(h, "s1"), 2)
        XCTAssertEqual(view.info.lastActivityAt, "2026-10-12T12:05:00.000Z")
        // A drop and a return read it again.
        h.client.webSocketManagerOnStatusChange(.disconnected)
        h.client.webSocketManagerOnStatusChange(.connected)
        try await eventually { self.gets(h, "s1") == 3 }
        await view.close()
    }

    // MARK: - CSO-4380-001 and 002 on Swift

    func testAChangeThatArrivesWhileTheViewOpensReachesInfo() async throws {
        let h = harness("during-open")
        try await session(h, "s1")
        let client = h.client
        let frame = Self.frame(
            "s1", at: "2026-10-12T12:00:30.000Z", change: "title", title: "Rent",
            lastActivityAt: "2026-10-12T12:00:30.000Z"
        )
        h.script.during(.get, "/agent-sessions/s1") { await client.handleWebSocketMessage(frame) }
        let view = try await open(h, "s1")
        try await eventually { view.info.title == "Rent" }
        XCTAssertEqual(view.info.lastActivityAt, "2026-10-12T12:00:30.000Z")
        XCTAssertEqual(gets(h, "s1"), 1)
        await view.close()
    }

    func testAFirstConnectionWhileTheViewOpensReadsInfoAgain() async throws {
        let h = harness("connect-during-open")
        try await session(h, "s1", scripted: false)
        let client = h.client
        h.script.on(.get, "/agent-sessions/s1", Self.info("s1"))
        h.script.on(.get, "/agent-sessions/s1", Self.info(
            "s1", lastActivityAt: "2026-10-12T12:05:00.000Z", title: "Done offline"
        ))
        h.script.during(.get, "/agent-sessions/s1") { client.webSocketManagerOnStatusChange(.connected) }
        let view = try await open(h, "s1")
        try await eventually { view.info.title == "Done offline" }
        XCTAssertEqual(gets(h, "s1"), 2)
        await view.close()
    }

    func testAReconnectReadNeverUndoesAFrameThatArrivedDuringIt() async throws {
        let h = harness("frame-during-get")
        try await session(h, "s1")
        let view = try await open(h, "s1")
        let client = h.client
        let frame = Self.frame(
            "s1", at: "2026-10-12T12:00:40.000Z", change: "title", title: "Rent",
            lastActivityAt: "2026-10-12T12:00:40.000Z"
        )
        // The reconnect read answers the info as it was before this rename,
        // which the view has applied by the time the answer arrives.
        h.script.during(.get, "/agent-sessions/s1") {
            await client.handleWebSocketMessage(frame)
            let deadline = Date().addingTimeInterval(5)
            while view.info.title != "Rent" && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        h.client.webSocketManagerOnStatusChange(.connected)
        try await eventually { self.gets(h, "s1") == 2 }
        try await settle()
        XCTAssertEqual(view.info.title, "Rent")
        XCTAssertEqual(view.info.lastActivityAt, "2026-10-12T12:00:40.000Z")
        XCTAssertEqual(view.info.status, .thinking)
        XCTAssertTrue(view.info.hasUnread)
        await view.close()
    }

    // MARK: - CSO-4380-015 on Swift

    func testAReconnectReadAnsweringAfterCloseChangesNothingAndNoReadFollows() async throws {
        let h = harness("reconnect-close")
        try await session(h, "s1")
        let view = try await open(h, "s1")
        let before = view.info
        h.script.set(.get, "/agent-sessions/s1", Self.info(
            "s1", lastActivityAt: "2026-10-12T12:05:00.000Z", title: "After close"
        ))
        let inFlight = LockedBox(0)
        let release = LockedBox(0)
        h.script.during(.get, "/agent-sessions/s1") {
            inFlight.add(1)
            let deadline = Date().addingTimeInterval(5)
            while release.value == 0 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        h.client.webSocketManagerOnStatusChange(.connected)
        try await eventually { inFlight.value == 1 }
        // A drop and a return while the read is held queue one more read.
        h.client.webSocketManagerOnStatusChange(.disconnected)
        h.client.webSocketManagerOnStatusChange(.connected)
        try await settle()
        await view.close()
        release.add(1)
        try await settle()
        XCTAssertEqual(view.info, before)
        XCTAssertEqual(gets(h, "s1"), 2)
        // A reconnect after close reads nothing.
        h.client.webSocketManagerOnStatusChange(.disconnected)
        h.client.webSocketManagerOnStatusChange(.connected)
        try await settle()
        XCTAssertEqual(gets(h, "s1"), 2)
        XCTAssertEqual(view.info, before)
    }

    // MARK: - Behavior 15 on Swift

    func testWhileOpenMarksReadAtOpenAfterAnUnreadFrameAndAfterAReconnect() async throws {
        let h = harness("while-open")
        try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-12T12:00:01.000Z"}"#)
        h.script.on(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-12T12:00:31.000Z"}"#)
        h.script.on(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-12T12:06:00.000Z"}"#)
        let view = try await open(h, "s1", markRead: .whileOpen)
        try await eventually { self.reads(h, "s1") == 1 }
        try await eventually { !view.info.hasUnread }
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:30.000Z", lastActivityAt: "2026-10-12T12:00:30.000Z",
            lastReadAt: "2026-10-12T12:00:01.000Z"
        ))
        try await eventually { self.reads(h, "s1") == 2 }
        // A frame already read sends nothing.
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:32.000Z", change: "read", lastActivityAt: "2026-10-12T12:00:30.000Z",
            hasUnread: false, lastReadAt: "2026-10-12T12:00:31.000Z"
        ))
        try await settle()
        XCTAssertEqual(reads(h, "s1"), 2)
        // A reconnect that finds it unread marks it again.
        h.script.set(.get, "/agent-sessions/s1", Self.info("s1", lastActivityAt: "2026-10-12T12:05:00.000Z"))
        h.client.webSocketManagerOnStatusChange(.connected)
        try await eventually { self.reads(h, "s1") == 3 }
        try await eventually { !view.info.hasUnread }
        await view.close()
    }

    func testWhileOpenStopsOnNotFoundAndSendsNothingAfterCloseOrForAnAdmin() async throws {
        let h = harness("while-open-stop")
        try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/read", status: 404, #"{"code":"AGENT_SESSION_NOT_FOUND","error":"No such agent session in this app"}"#)
        let view = try await open(h, "s1", markRead: .whileOpen)
        try await eventually { self.reads(h, "s1") == 1 }
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:30.000Z", lastActivityAt: "2026-10-12T12:00:30.000Z"
        ))
        try await settle()
        XCTAssertEqual(reads(h, "s1"), 1)
        await view.close()
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:40.000Z", lastActivityAt: "2026-10-12T12:00:40.000Z"
        ))
        try await settle()
        XCTAssertEqual(reads(h, "s1"), 1)

        let a = harness("while-open-admin")
        try await session(a, "s9", role: "admin")
        let admin = try await open(a, "s9", markRead: .whileOpen)
        await a.client.handleWebSocketMessage(Self.frame(
            "s9", at: "2026-10-12T12:00:30.000Z", lastActivityAt: "2026-10-12T12:00:30.000Z"
        ))
        try await settle()
        XCTAssertEqual(reads(a, "s9"), 0)
        await admin.close()
    }

    func testAFailedMarkIsRetriedOnTheNextFrame() async throws {
        let h = harness("while-open-retry")
        try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/read", status: 503, #"{"code":"AGENT_SESSION_UNAVAILABLE","error":"try again"}"#)
        h.script.on(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-12T12:00:31.000Z"}"#)
        let view = try await open(h, "s1", markRead: .whileOpen)
        try await eventually { self.reads(h, "s1") == 1 }
        await h.client.handleWebSocketMessage(Self.frame(
            "s1", at: "2026-10-12T12:00:30.000Z", lastActivityAt: "2026-10-12T12:00:30.000Z"
        ))
        try await eventually { self.reads(h, "s1") == 2 }
        try await eventually { !view.info.hasUnread }
        await view.close()
    }
}
