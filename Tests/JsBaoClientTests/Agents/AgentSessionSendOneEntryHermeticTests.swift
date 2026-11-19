import XCTest
@testable import JsBaoClient

/// A sent message is one entry in `messages` at every change: once its own
/// synced row is in the window, no pending entry with its `clientMessageId`
/// is, even while the send's request is still out. Another author's row with
/// the same id never removes the entry, and a refused reuse of an id an
/// earlier row of yours carries stays `failed`. The JS client's
/// `sessionView.ts` is the reference.
@available(*, deprecated)
final class AgentSessionSendOneEntryHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var db3s: [SessionDb3] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for db3 in db3s { db3.cleanup() }
        db3s = []
    }

    /// The send route's answer, held until the test opens its gate.
    private final class HeldSend: @unchecked Sendable {
        let gate = SendGate()
        private let lock = NSLock()
        private var answer: (Int, String) = (200, "{}")
        private var unheld: [(Int, String)] = []

        func set(status: Int = 200, _ body: String) { lock.withLock { answer = (status, body) } }
        /// The next send answers at once with this, without waiting on the gate.
        func answerNextAtOnce(status: Int = 200, _ body: String) { lock.withLock { unheld.append((status, body)) } }

        func respond(_ request: RecordedRequest) async -> TransportResponse {
            if request.path == "/agent-sessions/s1/messages" {
                let atOnce: (Int, String)? = lock.withLock { unheld.isEmpty ? nil : unheld.removeFirst() }
                if atOnce == nil { await gate.wait() }
                let (status, body) = atOnce ?? lock.withLock { answer }
                return TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            return TransportResponse(
                status: 200, headers: ["Content-Type": "application/json"], body: Data(agentSessionInfoJSON("s1").utf8)
            )
        }
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[AgentSessionViewMessage]] = []
        func add(_ messages: [AgentSessionViewMessage]) { lock.withLock { all.append(messages) } }
        var snapshots: [[AgentSessionViewMessage]] { lock.withLock { all } }
    }

    private func open(_ name: String, seed: [[String: JSONValue]] = []) async throws -> (AgentSessionView, SessionDb3, HeldSend) {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-one-entry-\(name)",
            token: makeTestJwt(userId: "u1"), offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        let held = HeldSend()
        let transport = RecordingTransport { await held.respond($0) }
        let db3 = try await SessionDb3.make(id: "s1")
        db3s.append(db3)
        try db3.write("Session", SessionRows.session())
        try db3.write("Message", SessionRows.message("first", seq: 1))
        for row in seed { try db3.write("Message", row) }
        let view = try await AgentSessionsAPI(transport: transport, client: client).open(sessionId: "s1", db3: db3)
        return (view, db3, held)
    }

    private func entries(_ messages: [AgentSessionViewMessage], _ clientMessageId: String) -> [AgentSessionViewMessage] {
        messages.filter { message in
            switch message {
            case .synced(let synced): return synced.clientMessageId == clientMessageId
            case .pending(let pending): return pending.clientMessageId == clientMessageId
            }
        }
    }

    private func isSynced(_ message: AgentSessionViewMessage?, _ messageId: String) -> Bool {
        if case .synced(let synced) = message { return synced.messageId == messageId }
        return false
    }

    func testThePendingEntryLeavesWhenItsOwnRowSyncsBeforeTheSendReturns() async throws {
        let (view, db3, held) = try await open("before-answer")
        held.set(#"{"messageId":"accepted","seq":10,"turnId":"t1","queued":false}"#)
        let seen = Seen()
        let stop = view.onChange { seen.add(view.messages) }
        defer { stop() }

        let sending = Task { try await view.send(text: "Hello", clientMessageId: "c1") }
        try await eventually(description: "the pending entry appears") { self.entries(view.messages, "c1").count == 1 }

        try db3.write("Message", SessionRows.message("accepted", seq: 10, clientMessageId: "c1"))
        try await eventually(description: "the row syncs into the window") {
            view.syncedMessages.contains { $0.messageId == "accepted" }
        }
        let atRow = entries(view.messages, "c1")
        XCTAssertEqual(atRow.count, 1, "the row and its pending entry at once: \(atRow)")
        XCTAssertTrue(isSynced(atRow.first, "accepted"))

        await held.gate.open()
        _ = try await sending.value
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(entries(view.messages, "c1").count, 1)
        XCTAssertTrue(view.pendingMessages.isEmpty)

        XCTAssertFalse(seen.snapshots.isEmpty)
        for (i, messages) in seen.snapshots.enumerated() {
            XCTAssertEqual(entries(messages, "c1").count, 1, "notification \(i): \(entries(messages, "c1"))")
        }
        await view.close()
    }

    func testAFailedEntryLeavesWhenItsRowSyncsAnyway() async throws {
        let (view, db3, held) = try await open("failed-landed")
        held.set(status: 503, #"{"code":"UNAVAILABLE","error":"try later"}"#)
        await held.gate.open()
        _ = try? await view.send(text: "Flaky", clientMessageId: "c3")
        XCTAssertEqual(view.pendingMessages.first?.state, .failed)
        try db3.write("Message", SessionRows.message("landed", seq: 14, clientMessageId: "c3"))
        try await eventually(description: "the failed entry gives way to its row") {
            let mine = self.entries(view.messages, "c3")
            return mine.count == 1 && self.isSynced(mine.first, "landed")
        }
        await view.close()
    }

    func testAnotherAuthorsNewerRowWithTheSameIdKeepsTheEntry() async throws {
        let (view, db3, held) = try await open("other-author")
        held.set(#"{"messageId":"mine","seq":12,"turnId":"t2","queued":false}"#)
        let sending = Task { try await view.send(text: "Mine", clientMessageId: "shared") }
        try await eventually(description: "the pending entry appears") { view.pendingMessages.count == 1 }
        try db3.write("Message", SessionRows.message("theirs", seq: 10, authorUserId: "u2", clientMessageId: "shared"))
        try await eventually(description: "their row syncs") { view.syncedMessages.contains { $0.messageId == "theirs" } }
        XCTAssertEqual(view.pendingMessages.count, 1)
        try db3.write("Message", SessionRows.message("mine", seq: 12, clientMessageId: "shared"))
        try await eventually(description: "my row replaces the entry") {
            view.pendingMessages.isEmpty && view.syncedMessages.contains { $0.messageId == "mine" }
        }
        await held.gate.open()
        _ = try await sending.value
        await view.close()
    }

    func testARefusedReuseStaysFailedAlthoughYourEarlierRowCarriesTheId() async throws {
        let (view, db3, held) = try await open(
            "refused-reuse", seed: [SessionRows.message("earlier", seq: 7, clientMessageId: "c1")]
        )
        held.set(status: 409, #"{"code":"AGENT_CLIENT_ID_CONFLICT","error":"clientMessageId was sent before with other content"}"#)
        await held.gate.open()
        _ = try? await view.send(text: "Different", clientMessageId: "c1")
        try db3.write("Session", SessionRows.session(title: "touched"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(view.pendingMessages.map(\.clientMessageId), ["c1"])
        XCTAssertEqual(view.pendingMessages.first?.state, .failed)
        XCTAssertEqual(view.pendingMessages.first?.error?.code, "AGENT_CLIENT_ID_CONFLICT")
        await view.close()
    }

    /// CSO-6258-001: the earlier send under the id answered before its row
    /// synced, so the reuse's floor is below that row.
    private func reuseBeforeTheOriginalSyncs(
        _ name: String
    ) async throws -> (AgentSessionView, SessionDb3, HeldSend, Task<AgentSessionSendResult, Error>) {
        let (view, db3, held) = try await open(name)
        held.answerNextAtOnce(#"{"messageId":"original","seq":20,"turnId":"t1","queued":false}"#)
        _ = try await view.send(text: "First", clientMessageId: "c9")
        held.set(status: 409, #"{"code":"AGENT_CLIENT_ID_CONFLICT","error":"clientMessageId was sent before with other content"}"#)
        let reuse = Task { try await view.send(text: "Different", clientMessageId: "c9") }
        try await eventually(description: "the reuse is sending") {
            view.pendingMessages.map(\.text) == ["Different"] && view.pendingMessages.first?.state == .sending
        }
        return (view, db3, held, reuse)
    }

    private func assertRefusedReuse(_ view: AgentSessionView, file: StaticString = #filePath, line: UInt = #line) {
        let pending = view.pendingMessages.filter { $0.clientMessageId == "c9" }
        XCTAssertEqual(pending.map(\.text), ["Different"], file: file, line: line)
        XCTAssertEqual(pending.first?.state, .failed, file: file, line: line)
        XCTAssertEqual(pending.first?.error?.code, "AGENT_CLIENT_ID_CONFLICT", file: file, line: line)
        XCTAssertTrue(view.syncedMessages.contains { $0.messageId == "original" }, file: file, line: line)
    }

    func testARefusedReuseStaysFailedWhenTheEarlierRowSyncsAfterTheRefusal() async throws {
        let (view, db3, held, reuse) = try await reuseBeforeTheOriginalSyncs("reuse-row-after")
        await held.gate.open()
        _ = try? await reuse.value
        XCTAssertEqual(view.pendingMessages.first?.state, .failed)
        try db3.write("Message", SessionRows.message("original", seq: 20, clientMessageId: "c9"))
        try await eventually(description: "the earlier row syncs") {
            view.syncedMessages.contains { $0.messageId == "original" }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertRefusedReuse(view)
        await view.close()
    }

    func testARefusedReuseComesBackFailedWhenTheEarlierRowSyncedBeforeTheRefusal() async throws {
        let (view, db3, held, reuse) = try await reuseBeforeTheOriginalSyncs("reuse-row-before")
        try db3.write("Message", SessionRows.message("original", seq: 20, clientMessageId: "c9"))
        try await eventually(description: "the earlier row syncs") {
            view.syncedMessages.contains { $0.messageId == "original" }
        }
        await held.gate.open()
        _ = try? await reuse.value
        assertRefusedReuse(view)
        try db3.write("Session", SessionRows.session(title: "touched"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertRefusedReuse(view)
        await view.close()
    }
}

/// A one-shot gate a test opens to let the held send answer through.
private actor SendGate {
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
