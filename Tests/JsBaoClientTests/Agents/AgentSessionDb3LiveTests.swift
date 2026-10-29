import XCTest
@testable import JsBaoClient

/// A session's db3 read live from Swift (#4884, intent criterion 2's Swift
/// half): every member opens the db3 the session's id names and reads a turn
/// from it by model name, with no `documents` request; an app admin reads the
/// session but the room opens the db3 only to members; a non-member or
/// another app's user is refused (behavior 12); a participant removed while
/// subscribed loses the session and its copy within a second (behavior 13);
/// an app with its own
/// `PrimitiveMessage` opens a session; `close()` leaves the local copy; two
/// views of one session on one client each hold their own subscription.
final class AgentSessionDb3LiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-session-db3-swift-4884") }
            slot = created
            return created
        }
        h = try await task.value
    }

    override class func tearDown() {
        guard let task = harnessTask.value else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let harness = try? await task.value { await harness.cleanup() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        super.tearDown()
    }

    /// Until the view holds an agent message after the user message `messageId`.
    private func reply(_ view: AgentSessionView, after messageId: String, timeout: TimeInterval = 120) async throws {
        try await h.poll(timeout: timeout, interval: 0.5, "the agent's reply reaches the view") {
            guard let sent = view.syncedMessages.first(where: { $0.messageId == messageId }) else { return false }
            return view.syncedMessages.contains { $0.message.authorKind == .agent && $0.seq > sent.seq }
        }
    }

    // MARK: - Behavior 12: every member reads the turn, with no documents request

    /// A turn of SERVER's that called its server tools, from `sender`'s send
    /// of `Go.`, sent once more when the model called none (as `watching`
    /// shows it); answers the turn's id.
    private func toolTurn(
        _ s: AgentSessionScenarioHarness.Session, sender: JsBaoClient, watching view: AgentSessionView
    ) async throws -> String {
        for _ in 0..<2 {
            let sent = try await sender.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Go."))
            try await h.settled(s)
            let turnId = try XCTUnwrap(sent.turnId)
            let called: Void? = try? await h.poll(timeout: 15, "the turn's calls reach the view") {
                view.toolCalls.contains { $0.turnId == turnId }
            }
            if called != nil { return turnId }
        }
        throw TestSetupError("the model did not call the server tools")
    }

    func testEveryMemberReadsTheTurnFromTheDb3WithNoDocumentsRequest() async throws {
        let s = try await h.createSession(h.server, participants: [h.part], viewers: [h.viewer], title: "Members")
        let ownerC = try await h.client(h.owner)
        let partC = try await h.client(h.part)
        let viewerC = try await h.client(h.viewer)
        let readers: [(String, JsBaoClient, AgentSessionRole)] = [
            ("owner", ownerC, .owner), ("participant", partC, .participant), ("viewer", viewerC, .viewer),
        ]
        var counted: [(String, AgentSessionScenarioHarness.DocumentsCalls)] = []
        var views: [(String, AgentSessionView, AgentSessionRole)] = []
        for (name, client, role) in readers {
            counted.append((name, h.documentsCalls(of: client)))
            views.append((name, try await h.open(client, s, pageSize: 2), role))
        }
        let turnId = try await toolTurn(s, sender: partC, watching: views[1].1)

        for (name, view, role) in views {
            XCTAssertEqual(view.info.role, role, name)
            try await h.poll(timeout: 60, "\(name) reads the turn") {
                view.status == .idle && view.syncedMessages.contains { $0.message.turnId == turnId && $0.message.authorKind == .agent }
            }
            let reply = try XCTUnwrap(view.syncedMessages.last { $0.message.turnId == turnId && $0.message.authorKind == .agent }, name)
            XCTAssertEqual(reply.parts.map(\.seq), reply.parts.map(\.seq).sorted(), "\(name): parts by seq")
            XCTAssertEqual(reply.turn?.id, turnId, "\(name): the Turn row is the message's turn")
            XCTAssertEqual(reply.turn?.status, .completed, name)
            let calls = view.toolCalls.filter { $0.turnId == turnId }
            XCTAssertFalse(calls.isEmpty, "\(name): the turn's ToolCall rows")
            XCTAssertTrue(calls.allSatisfy { $0.state == .outputAvailable }, "\(name): \(calls.map(\.state))")
            XCTAssertTrue(reply.steps.contains { $0.kind == .toolCall }, "\(name): the turn's tool steps")
            XCTAssertTrue(reply.steps.contains { $0.kind == .modelCall }, "\(name): the turn's model steps")
            XCTAssertEqual(Set(view.members.map(\.id)), [h.owner.userId, h.part.userId, h.viewer.userId], name)
            XCTAssertEqual(view.members.first?.role, .owner, "\(name): the owner was added first")
            XCTAssertEqual(view.session?.id, s.sessionId, name)
            _ = try await view.loadOlder()
        }
        for (_, view, _) in views { await view.close() }
        for (name, calls) in counted {
            XCTAssertEqual(calls.all, [], "\(name) made no documents request across open, send, page and close")
        }

        // An app admin reads the session through `get` (and the db3's REST
        // doors), but the room opens a db3 a resource holds only to its
        // members' sockets: the open is refused there, with nothing left
        // subscribed or on the device.
        let adminC = try await h.client(h.admin)
        let asAdmin = try await adminC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertEqual(asAdmin.role, .admin)
        do {
            _ = try await h.open(adminC, s)
            XCTFail("the room refuses the app admin's open")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3AccessRefused)
        }
        let adminState = try await adminC.db3.state(s.sessionId)
        XCTAssertFalse(adminState.subscribed)
        XCTAssertEqual(adminState.rows, 0)

        // A same-app non-member and a user of another app are refused at get, with nothing subscribed.
        let strangerC = try await h.client(h.stranger)
        let outsiderC = try await h.client(h.outsider, app: h.otherAppId)
        for (name, client) in [("non-member", strangerC), ("other app", outsiderC)] {
            do {
                _ = try await h.open(client, s)
                XCTFail("\(name) is refused")
            } catch let error as HttpError {
                XCTAssertEqual(error.serverCode, "AGENT_SESSION_NOT_FOUND", name)
            }
            let state = try await client.db3.state(s.sessionId)
            XCTAssertFalse(state.subscribed, "\(name): nothing is subscribed")
            XCTAssertFalse(state.resident, "\(name): nothing is on the device")
        }
    }

    // MARK: - Behavior 13: a member removed while subscribed loses the session

    func testAParticipantRemovedWhileSubscribedLosesTheSessionAndItsCopyWithinASecond() async throws {
        let s = try await h.createSession(h.tools, participants: [h.part], viewers: [h.viewer])
        let ownerC = try await h.client(h.owner)
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        // A client-tool handler running at the removal: TOOLS's `Go.` calls `pick`, the participant's turn.
        let runs = Recorder<String>()
        let cancelled = Recorder<Bool>()
        let release = LockedBox(false)
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            while !release.value { try? await Task.sleep(nanoseconds: 20_000_000) }
            cancelled.append(Task.isCancelled)
            return AgentClientToolResult(output: ["count": 2])
        }])
        let (_, turn) = try await h.pausedTurn(s, sender: partC, toolNames: ["sign", "pick"])
        try await h.poll(timeout: 30, "the handler runs the pick") { !runs.all.isEmpty }
        let pickId = try XCTUnwrap(runs.all.first)
        XCTAssertTrue(turn.pause?.callIds.contains(pickId) == true)
        try await h.poll(timeout: 30, "the view holds the session") {
            view.members.count == 3 && !view.syncedMessages.isEmpty && view.runningClientToolCalls == [pickId]
        }

        _ = try await ownerC.agents.sessions.removeMember(sessionId: s.sessionId, userId: h.part.userId)
        let answered = Date()
        try await h.poll(timeout: 1, interval: 0.02, "gone within a second of the removal answering") {
            view.gone?.reason == .permission
        }
        XCTAssertLessThan(Date().timeIntervalSince(answered), 1.0)
        XCTAssertEqual(view.gone?.code, "DB3_ACCESS_REFUSED")
        XCTAssertEqual(view.syncedMessages, [], "the view shows nothing")
        XCTAssertEqual(view.members, [])
        XCTAssertEqual(view.queue, [])
        XCTAssertNil(view.session)
        XCTAssertEqual(view.runningClientToolCalls, [], "the running handler is stopped")
        try await h.poll(timeout: 10, "the copy is evicted") {
            let state = try await partC.db3.state(s.sessionId)
            return !state.resident && state.rows == 0 && !state.subscribed
        }
        release.value = true
        try await h.poll(timeout: 10, "the handler returns") { !cancelled.all.isEmpty }
        XCTAssertEqual(cancelled.all, [true], "cancelled")
        // Its answer was never sent: the call still takes the owner's.
        try await Task.sleep(nanoseconds: 500_000_000)
        let accepted = try await ownerC.agents.sessions.answer(sessionId: s.sessionId, callId: pickId, .output(["count": 3]))
        XCTAssertEqual(accepted.state, .outputAvailable)
        if let signId = turn.pause?.callIds.first(where: { $0 != pickId }) {
            _ = try? await ownerC.agents.sessions.answer(sessionId: s.sessionId, callId: signId, .approval(approved: false))
        }
        try await h.settled(s)

        // Their next open is refused at get.
        do {
            _ = try await h.open(partC, s)
            XCTFail("a removed member's open is refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_NOT_FOUND")
        }
        let after = try await partC.db3.state(s.sessionId)
        XCTAssertFalse(after.subscribed)
        XCTAssertFalse(after.resident)
    }

    // MARK: - Edge E5: an app's own PrimitiveMessage

    func testAClientWithItsOwnPrimitiveMessageModelOpensASessionAndSeesTheReply() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let partC = try await h.client(h.part)
        partC.registerModels([PrimitiveSchema(name: "PrimitiveMessage", fields: [
            "id": FieldDescriptor(type: .id), "body": FieldDescriptor(type: .string), "pinned": FieldDescriptor(type: .boolean),
        ])])
        let view = try await h.open(partC, s)
        let sent = try await view.send(text: "Hi.")
        try await reply(view, after: sent.messageId)
        try await h.settled(s)
        XCTAssertEqual(partC.sharedModel("PrimitiveMessage")?.schema.fields["body"], FieldDescriptor(type: .string),
                       "the app's own model is left as it registered it")
    }

    // MARK: - Edge E7: close() keeps the local copy

    func testCloseDisposesTheSubscriptionAndLeavesTheLocalCopy() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let partC = try await h.client(h.part)
        _ = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Kept."))
        let view = try await h.open(partC, s)
        try await h.poll(timeout: 30, "the message syncs") { !view.syncedMessages.isEmpty }
        let before = try await partC.db3.state(s.sessionId)
        XCTAssertTrue(before.subscribed)
        await view.close()
        try await h.poll(timeout: 10, "the subscription is given up") {
            try await !partC.db3.state(s.sessionId).subscribed
        }
        let after = try await partC.db3.state(s.sessionId)
        XCTAssertTrue(after.resident, "the local copy stays")
        XCTAssertGreaterThan(after.rows, 0, "with its rows")
        XCTAssertFalse(after.subscribed)
        try await h.settled(s)
    }

    // MARK: - Edge E8: two views on one client

    func testTwoViewsOfOneSessionOnOneClientEachHoldTheirOwnSubscription() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let partC = try await h.client(h.part)
        let first = try await h.open(partC, s)
        let second = try await h.open(partC, s)
        await first.close()
        let state = try await partC.db3.state(s.sessionId)
        XCTAssertTrue(state.subscribed, "the other view's subscription holds the db3 live")
        let sent = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Still here?"))
        try await reply(second, after: sent.messageId)
        XCTAssertTrue(first.syncedMessages.isEmpty, "the closed view reads nothing more")
        try await h.settled(s)
        await second.close()
    }
}
