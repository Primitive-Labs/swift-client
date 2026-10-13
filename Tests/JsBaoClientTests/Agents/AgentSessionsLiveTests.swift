import XCTest
@testable import JsBaoClient

/// `client.agents.sessions` against the dev server, from Swift clients
/// observing and answering (#3810, plan behaviors 19–25 including 22b and
/// 23b, edge cases 31, 32, 36 and 37's live half; intent criterion 23 with
/// criteria 9, 10 and 11).
///
/// Real sessions created by a pushed function and real turns with a live
/// model steered at temperature 0; every assertion is on shape, state and
/// code, never on the model's words.
final class AgentSessionsLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-sessions-swift-3810") }
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

    // MARK: - Helpers

    private func expectServerCode(
        _ code: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async -> HttpError? {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, code, error.body ?? "", file: file, line: line)
            return error
        } catch {
            XCTFail("expected HttpError \(code), got \(error)", file: file, line: line)
        }
        return nil
    }

    private func steps(_ view: AgentSessionView, turn turnId: String) -> [PrimitiveStep] {
        view.allSteps.filter { $0.turnId == turnId }.sorted { $0.seq < $1.seq }
    }

    // MARK: - Behaviors 19 and 20: every operation, and refusals by code

    func testEveryOperationRunsFromSwiftAndRefusalsArriveByCode() async throws {
        let scope = "team-\(h.stamp)"
        let s = try await h.createSession(h.plain, participants: [h.part], viewers: [h.viewer], title: "Ops", scope: scope)
        let other = try await h.createSession(h.tools, participants: [h.part])
        let ownerC = try await h.client(h.owner)
        let partC = try await h.client(h.part)
        let viewerC = try await h.client(h.viewer)
        let strangerC = try await h.client(h.stranger)
        let adminC = try await h.client(h.admin)
        let outsiderC = try await h.client(h.outsider, app: h.otherAppId)

        // list: your own, with roles, filters and pages.
        let mine = try await partC.agents.sessions.list()
        let byId = Dictionary(uniqueKeysWithValues: mine.items.map { ($0.sessionId, $0) })
        XCTAssertEqual(byId[s.sessionId]?.role, .participant)
        XCTAssertEqual(byId[other.sessionId]?.role, .participant)
        XCTAssertEqual(byId[s.sessionId]?.documentId, s.documentId)
        XCTAssertEqual(byId[s.sessionId]?.scope, scope)
        let owned = try await ownerC.agents.sessions.list()
        XCTAssertEqual(owned.items.first { $0.sessionId == s.sessionId }?.role, .owner)
        let byAgent = try await partC.agents.sessions.list(options: ListAgentSessionsOptions(agent: h.plain))
        XCTAssertTrue(byAgent.items.contains { $0.sessionId == s.sessionId })
        XCTAssertFalse(byAgent.items.contains { $0.sessionId == other.sessionId })
        let byScope = try await partC.agents.sessions.list(options: ListAgentSessionsOptions(scope: scope))
        XCTAssertEqual(byScope.items.map(\.sessionId), [s.sessionId])
        let page1 = try await partC.agents.sessions.list(options: ListAgentSessionsOptions(limit: 1))
        XCTAssertEqual(page1.items.count, 1)
        XCTAssertTrue(page1.hasMore)
        let cursor = try XCTUnwrap(page1.nextCursor)
        let page2 = try await partC.agents.sessions.list(options: ListAgentSessionsOptions(limit: 1, cursor: cursor))
        XCTAssertEqual(page2.items.count, 1)
        XCTAssertNotEqual(page2.items.first?.sessionId, page1.items.first?.sessionId)

        // get as a participant, the owner and a tenant admin.
        let asPart = try await partC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertEqual(asPart.role, .participant)
        XCTAssertEqual(asPart.status, .idle)
        XCTAssertEqual(asPart.title, "Ops")
        XCTAssertEqual(asPart.members.participants, [h.part.userId])
        XCTAssertEqual(asPart.members.viewers, [h.viewer.userId])
        XCTAssertNil(asPart.object)
        XCTAssertNil(asPart.turnContexts)
        XCTAssertNil(asPart.lastTurn)
        let asOwner = try await ownerC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertEqual(asOwner.role, .owner)
        XCTAssertNil(asOwner.object)
        let asAdmin = try await adminC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertEqual(asAdmin.role, .admin)
        XCTAssertNotNil(asAdmin.object, "app authority reads the object")

        // rename: the owner may, a participant may not.
        let renamed = try await ownerC.agents.sessions.rename(sessionId: s.sessionId, title: "Renamed")
        XCTAssertEqual(renamed.title, "Renamed")
        _ = await expectServerCode("AGENT_SESSION_OWNER_ONLY") {
            _ = try await partC.agents.sessions.rename(sessionId: s.sessionId, title: "Mine")
        }

        // members.
        let added = try await ownerC.agents.sessions.addMember(sessionId: s.sessionId, userId: h.part2.userId, role: .participant)
        XCTAssertTrue(added.members.participants.contains(h.part2.userId))
        let part2C = try await h.client(h.part2)
        let asPart2 = try await part2C.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertEqual(asPart2.role, .participant)
        let removed = try await ownerC.agents.sessions.removeMember(sessionId: s.sessionId, userId: h.part2.userId)
        XCTAssertFalse(removed.members.participants.contains(h.part2.userId))
        _ = await expectServerCode("AGENT_SESSION_NOT_FOUND") {
            _ = try await part2C.agents.sessions.get(sessionId: s.sessionId)
        }

        // Who is answered as if the session were not there.
        _ = await expectServerCode("AGENT_SESSION_NOT_FOUND") {
            _ = try await strangerC.agents.sessions.get(sessionId: s.sessionId)
        }
        _ = await expectServerCode("AGENT_SESSION_NOT_FOUND") {
            _ = try await outsiderC.agents.sessions.get(sessionId: s.sessionId)
        }
        _ = await expectServerCode("AGENT_SESSION_PARTICIPANT_ONLY") {
            _ = try await viewerC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Hi"))
        }
        _ = await expectServerCode("AGENT_TURN_STALE") {
            _ = try await partC.agents.sessions.cancel(sessionId: s.sessionId, turnId: PrimitiveSchemaRegistry.generateULID())
        }
        // #4142: listing another user's sessions is refused with the shared
        // subject-user code.
        _ = await expectServerCode("SUBJECT_USER_FORBIDDEN") {
            _ = try await partC.agents.sessions.list(options: ListAgentSessionsOptions(userId: h.owner.userId))
        }
        _ = await expectServerCode("AGENT_SESSION_CONTEXT_NOT_ALLOWED") {
            _ = try await partC.agents.sessions.send(
                sessionId: s.sessionId, body: AgentSessionSendBody(text: "hi", context: ["plan": "gold"])
            )
        }

        // send, then cancel the running turn from the sender's view (the
        // row's active turn) while the owner's view observes it end.
        let cancelling = try await h.open(partC, s)
        let observing = try await h.open(ownerC, s)
        try await h.slowRound(s, ms: 20_000)
        let sent = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Hello."))
        XCTAssertFalse(sent.queued)
        let turnId = try XCTUnwrap(sent.turnId)
        try await h.poll(timeout: 20, "the row names the running turn") { cancelling.activeTurnId == turnId }
        let cancelled = try await cancelling.cancel()
        XCTAssertEqual(cancelled.turnId, turnId)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertNil(cancelled.nextTurnId)
        try await h.poll(timeout: 30, "the observer sees the turn cancelled") {
            observing.status == .cancelled && observing.activeTurnId == nil
        }
        XCTAssertEqual(observing.session?.lastErrorCode, "AGENT_TURN_CANCELLED")
        try await h.settled(s)
        await cancelling.close()
        await observing.close()

        // delete twice.
        let deleted = try await ownerC.agents.sessions.delete(sessionId: s.sessionId)
        XCTAssertEqual(deleted, try JSONCoding.decodeData(AgentSessionDeleteResult.self, from: Data(
            #"{"deleted":true,"sessionId":"\#(s.sessionId)","documentId":"\#(s.documentId)"}"#.utf8)))
        let again = try await ownerC.agents.sessions.delete(sessionId: s.sessionId)
        XCTAssertTrue(again.deleted, "a second delete succeeds")
        _ = await expectServerCode("AGENT_SESSION_NOT_FOUND") {
            _ = try await partC.agents.sessions.get(sessionId: s.sessionId)
        }
    }

    // MARK: - Behavior 21: criterion 9

    func testCriterion9ASendersViewAndAnObserversViewSeeTheTurn() async throws {
        let s = try await h.createSession(h.server, participants: [h.part])
        let partC = try await h.client(h.part)
        let ownerC = try await h.client(h.owner)
        let sending = try await h.open(partC, s)
        let observing = try await h.open(ownerC, s)

        let statuses = Recorder<PrimitiveSessionStatus>()
        let stepStates = Recorder<String>()
        let observerPending = Recorder<Int>()
        observing.onChange { [observing] in
            if let status = observing.status { statuses.append(status) }
            for step in observing.allSteps where step.kind == .toolCall { stepStates.append("\(step.id):\(step.status.rawValue)") }
            observerPending.append(observing.pendingMessages.count)
        }
        let senderPending = Recorder<String>()
        sending.onChange { [sending] in
            for entry in sending.pendingMessages { senderPending.append(entry.clientMessageId) }
        }

        var sent: AgentSessionSendResult?
        var visibleAfter: TimeInterval = 0
        for _ in 0..<2 {
            let started = Date()
            let result = try await sending.send(text: "Go.")
            try await h.poll(timeout: 30, "the observer sees the message") {
                observing.syncedMessages.contains { $0.messageId == result.messageId }
            }
            visibleAfter = Date().timeIntervalSince(started)
            try await h.settled(s)
            try await h.poll(timeout: 30, "the observer sees the turn's calls end") {
                let calls = observing.toolCalls.filter { call in
                    observing.syncedMessages.first { $0.messageId == call.messageId }?.message.turnId == result.turnId
                }
                return calls.count == 2 && calls.allSatisfy { $0.state != "input-available" }
                    || observing.syncedMessages.contains { $0.message.turnId == result.turnId && $0.message.authorKind == .agent }
                    && calls.isEmpty
            }
            let calls = observing.toolCalls.filter { call in
                observing.syncedMessages.first { $0.messageId == call.messageId }?.message.turnId == result.turnId
            }
            if calls.count == 2 { sent = result; break }
        }
        let result = try XCTUnwrap(sent, "the model did not call lookup and sweep")
        print("[#3810] send-to-visible across two Swift clients: \(Int(visibleAfter * 1000)) ms")

        // The sending view: its pending entry gave way to the synced row.
        let mine = try XCTUnwrap(sending.syncedMessages.first { $0.messageId == result.messageId })
        XCTAssertTrue(senderPending.all.contains(try XCTUnwrap(mine.clientMessageId)), "the sender saw its pending entry")
        XCTAssertTrue(sending.pendingMessages.isEmpty)
        // The observing view never sees a pending entry, and sees the turn.
        XCTAssertTrue(observerPending.all.allSatisfy { $0 == 0 })
        let theirs = try XCTUnwrap(observing.syncedMessages.first { $0.messageId == result.messageId })
        XCTAssertEqual(theirs.message.authorKind, .user)
        XCTAssertEqual(theirs.message.authorUserId, h.part.userId)
        XCTAssertEqual(theirs.clientMessageId, mine.clientMessageId)
        let seen = statuses.all
        let thinking = seen.firstIndex(of: .thinking)
        let runningTool = seen.firstIndex(of: .runningTool)
        XCTAssertNotNil(thinking, "statuses seen: \(seen)")
        XCTAssertNotNil(runningTool, "statuses seen: \(seen)")
        if let thinking, let runningTool { XCTAssertLessThan(thinking, runningTool) }
        let turnCalls = observing.toolCalls.filter { call in
            observing.syncedMessages.first { $0.messageId == call.messageId }?.message.turnId == result.turnId
        }
        XCTAssertEqual(Set(turnCalls.compactMap(\.toolName)), ["lookup", "sweep"])
        for call in turnCalls {
            XCTAssertEqual(call.state, "output-available", "\(call)")
            guard case let .toolCall(content) = call.content else { return XCTFail("not a tool call: \(call.content)") }
            XCTAssertEqual(content.state, .outputAvailable)
            XCTAssertEqual(content.output?["trigger"], "tool")
        }
        let toolSteps = steps(observing, turn: try XCTUnwrap(result.turnId)).filter { $0.kind == .toolCall }
        XCTAssertEqual(toolSteps.count, 2)
        for step in toolSteps {
            XCTAssertEqual(step.status, .completed)
            XCTAssertTrue(stepStates.all.contains("\(step.id):running"), "step \(step.id) seen running: \(stepStates.all)")
        }
        let final = observing.syncedMessages.filter { $0.message.turnId == result.turnId && $0.message.authorKind == .agent }.last
        XCTAssertNotNil(final?.parts.first { $0.kind == .text }, "the final agent message arrived")

        // The file: an empty text with a PNG uploaded to the document.
        let blobId = try await h.uploadPng(partC, s)
        let withFile = try await sending.send(text: "", files: [AgentSessionFileRef(blobId: blobId)])
        try await h.poll(timeout: 30, "the observer sees the file part") {
            observing.syncedMessages.first { $0.messageId == withFile.messageId }?.parts.contains {
                if case let .file(file) = $0.content { return file.blobId == blobId } else { return false }
            } == true
        }
        try await h.poll(timeout: 30, "the sender's entry gives way") { sending.pendingMessages.isEmpty }
        try await h.settled(s)
    }

    // MARK: - Behaviors 22 and 24: criterion 10 with participants answering, and events

    func testCriterion10AnotherParticipantAnswersInReverseOrderAndEventsAreRecorded() async throws {
        let s = try await h.createSession(h.tools, participants: [h.part, h.part2], viewers: [h.viewer])
        let partC = try await h.client(h.part)
        let part2C = try await h.client(h.part2)
        let viewerC = try await h.client(h.viewer)
        let starting = try await h.open(partC, s)
        let (_, turn) = try await h.pausedTurn(s, sender: partC, toolNames: ["sign", "pick"])
        XCTAssertEqual(turn.phase, .paused)
        XCTAssertEqual(turn.answeredBy, "participants")
        XCTAssertEqual(turn.pause?.callIds.count, 2)
        await starting.close()

        let answering = try await h.open(part2C, s)
        try await h.poll(timeout: 30, "the paused calls reach the second participant") {
            turn.pause?.callIds.allSatisfy { answering.toolCall($0) != nil } == true
        }
        let callIds = try XCTUnwrap(turn.pause?.callIds)
        let pickId = try XCTUnwrap(callIds.first { answering.toolCall($0)?.toolName == "pick" })
        let signId = try XCTUnwrap(callIds.first { answering.toolCall($0)?.toolName == "sign" })
        XCTAssertEqual(answering.toolCall(signId)?.state, "approval-requested")

        _ = await expectServerCode("AGENT_TURN_NOT_ALLOWED") {
            _ = try await viewerC.agents.sessions.answer(sessionId: s.sessionId, callId: pickId, .output(["count": 2]))
        }
        _ = await expectServerCode("AGENT_ANSWER_INVALID") {
            _ = try await answering.answer(callId: pickId, .output(["count": 0]))
        }
        // Reverse order: pick first, then sign's approval and its output.
        let picked = try await answering.answer(callId: pickId, .output(["count": 2]))
        XCTAssertEqual(picked.state, .outputAvailable)
        let approved = try await answering.answer(callId: signId, .approval(approved: true))
        XCTAssertEqual(approved.state, .approvalResponded)
        let signed = try await answering.answer(callId: signId, try .output(encoding: ["signed": true]))
        XCTAssertEqual(signed.state, .outputAvailable)
        _ = await expectServerCode("AGENT_CALL_ANSWERED") {
            _ = try await answering.answer(callId: pickId, .output(["count": 3]))
        }
        try await h.settled(s)
        try await h.poll(timeout: 30, "the answered parts sync") {
            answering.toolCall(pickId)?.state == "output-available" && answering.toolCall(signId)?.state == "output-available"
        }
        XCTAssertEqual(answering.toolCall(pickId)?.resolvedByUserId, h.part2.userId)
        XCTAssertEqual(answering.toolCall(signId)?.approvalApproved, true)

        // Behavior 24: a Swift event, its repeat, and an app-authored one.
        let eventId = "ev-\(h.stamp)"
        let event = AgentSessionEvent(kind: "viewed", data: ["item": "lease"], eventId: eventId, refersTo: signId)
        let recorded = try await answering.recordEvent(event)
        let repeated = try await answering.recordEvent(event)
        XCTAssertEqual(repeated.duplicate, true)
        XCTAssertEqual(repeated.messageId, recorded.messageId)
        let noted = try await h.invokeNote(s, as: h.part, data: ["item": "note"])
        let notedId = try XCTUnwrap(noted["messageId"] as? String)
        try await h.poll(timeout: 30, "both events sync") {
            answering.syncedMessages.contains { $0.messageId == recorded.messageId }
                && answering.syncedMessages.contains { $0.messageId == notedId }
        }
        let userEvent = try XCTUnwrap(answering.syncedMessages.first { $0.messageId == recorded.messageId })
        XCTAssertEqual(userEvent.message.authorKind, .user)
        XCTAssertEqual(userEvent.parts.count, 1)
        guard case let .event(content) = userEvent.parts.first?.content else { return XCTFail("not an event part") }
        XCTAssertEqual(content.eventKind, "viewed")
        XCTAssertEqual(content.refersTo, signId)
        XCTAssertEqual(content.eventId, eventId)
        let appEvent = try XCTUnwrap(answering.syncedMessages.first { $0.messageId == notedId })
        XCTAssertEqual(appEvent.message.authorKind, .app)
        XCTAssertEqual(appEvent.parts.first?.kind, .event)

        // A denial in a later turn ends the part output-denied.
        let (_, later) = try await h.pausedTurn(s, sender: part2C, toolNames: ["sign", "pick"])
        let laterIds = try XCTUnwrap(later.pause?.callIds)
        try await h.poll(timeout: 30, "the later calls sync") { laterIds.allSatisfy { answering.toolCall($0) != nil } }
        let laterSign = try XCTUnwrap(laterIds.first { answering.toolCall($0)?.toolName == "sign" })
        let laterPick = try XCTUnwrap(laterIds.first { answering.toolCall($0)?.toolName == "pick" })
        let denied = try await answering.answer(callId: laterSign, .approval(approved: false, reason: "Not now"))
        XCTAssertEqual(denied.state, .outputDenied)
        let failedPick = try await answering.answer(callId: laterPick, .error(message: "No camera"))
        XCTAssertEqual(failedPick.state, .outputError)
        try await h.settled(s)
        try await h.poll(timeout: 30, "the denial syncs") { answering.toolCall(laterSign)?.state == "output-denied" }
        XCTAssertEqual(answering.toolCall(laterSign)?.approvalReason, "Not now")
        XCTAssertEqual(answering.toolCall(laterSign)?.errorCode, "AGENT_CALL_DENIED")
    }

    // MARK: - Behavior 22b: criterion 10's initiator and expiry branches

    func testCriterion10TheInitiatorAloneAnswersAndAnUnansweredCallExpires() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part, h.part2])
        let partC = try await h.client(h.part)
        let part2C = try await h.client(h.part2)
        let (_, turn) = try await h.pausedTurn(s, sender: partC, toolNames: ["pick"])
        XCTAssertEqual(turn.answeredBy, "initiator")
        let callId = try XCTUnwrap(turn.pause?.callIds.first)
        _ = await expectServerCode("AGENT_TURN_NOT_ALLOWED") {
            _ = try await part2C.agents.sessions.answer(sessionId: s.sessionId, callId: callId, .output(["count": 2]))
        }
        let accepted = try await partC.agents.sessions.answer(sessionId: s.sessionId, callId: callId, .output(["count": 2]))
        XCTAssertEqual(accepted.state, .outputAvailable)
        try await h.settled(s)

        let e = try await h.createSession(h.expires, participants: [h.part])
        let view = try await h.open(partC, e)
        let (paused, expiring) = try await h.pausedTurn(e, sender: partC, toolNames: ["pick"])
        let expiringId = try XCTUnwrap(expiring.pause?.callIds.first)
        try await h.poll(timeout: 30, "the call expires") {
            view.toolCall(expiringId)?.state == "output-error" && view.toolCall(expiringId)?.errorCode == "AGENT_CALL_EXPIRED"
        }
        try await h.poll(timeout: 30, "the session reads expired") { view.status == .expired }
        try await h.settled(e)
        let turnId = try XCTUnwrap(paused.turnId)
        let modelSteps = steps(view, turn: turnId).filter { $0.kind == .modelCall }
        XCTAssertEqual(modelSteps.count, 1, "no model call after the pause: \(modelSteps.map(\.id))")
    }

    // MARK: - Behavior 23: criterion 11's queue, duplicates and title

    func testCriterion11AQueuedSendShowsQueuedThenSyncedAndClientIdsDeduplicate() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        try await h.slowRound(s, ms: 10_000)
        let first = try await view.send(text: "First line\nsecond line")
        try await h.poll(timeout: 20, "the row names the running turn") { view.activeTurnId == first.turnId }
        // Listening before the send: the change that shows the row queued can
        // come before `send` returns, and the next one can show it synced.
        let seen = Recorder<[String: AgentSessionSyncedMessage.State]>()
        view.onChange { [view] in
            seen.append(Dictionary(view.syncedMessages.map { ($0.messageId, $0.state) }, uniquingKeysWith: { _, last in last }))
        }
        let second = try await view.send(text: "Second.")
        XCTAssertTrue(second.queued)
        try await h.poll(timeout: 20, "the second message shows queued") {
            view.queue.flatMap(\.messageIds).contains(second.messageId)
                && view.syncedMessages.first { $0.messageId == second.messageId }?.state == .queued
        }
        try await h.poll(timeout: 120, "the second message runs") {
            view.syncedMessages.first { $0.messageId == second.messageId }?.state == .synced
        }
        XCTAssertTrue(seen.all.contains { $0[second.messageId] == .queued }, "a change showed the second message queued")
        try await h.settled(s)

        // The same client message id: same text answers the first; other text is refused.
        let clientMessageId = "cm-\(h.stamp)"
        let original = try await partC.agents.sessions.send(
            sessionId: s.sessionId, body: AgentSessionSendBody(text: "Again.", clientMessageId: clientMessageId)
        )
        let duplicate = try await partC.agents.sessions.send(
            sessionId: s.sessionId, body: AgentSessionSendBody(text: "Again.", clientMessageId: clientMessageId)
        )
        XCTAssertEqual(duplicate.duplicate, true)
        XCTAssertEqual(duplicate.messageId, original.messageId)
        XCTAssertEqual(duplicate.seq, original.seq)
        do {
            try await view.send(text: "Different.", clientMessageId: clientMessageId)
            XCTFail("a reuse with other text must be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_CLIENT_ID_CONFLICT")
        }
        let failed = try XCTUnwrap(view.pendingMessages.first { $0.clientMessageId == clientMessageId })
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error?.code, "AGENT_CLIENT_ID_CONFLICT")

        // An untitled session takes its first message's first line.
        let info = try await partC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertEqual(info.title, "First line")
        let listed = try await partC.agents.sessions.list()
        XCTAssertEqual(listed.items.first { $0.sessionId == s.sessionId }?.title, "First line")
        try await h.settled(s)
    }

    // MARK: - Behavior 23b: criterion 11's batches and sends during a pause

    func testCriterion11OneTurnPerAuthorInArrivalOrderAndSendsDuringAPause() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part, h.part2])
        let partC = try await h.client(h.part)
        let part2C = try await h.client(h.part2)
        let view = try await h.open(partC, s)
        try await h.slowRound(s, ms: 15_000)
        let running = try await view.send(text: "Start.")
        try await h.poll(timeout: 20, "the turn runs") { view.activeTurnId == running.turnId }
        let q1 = try await part2C.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Q one."))
        let p1 = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "P one."))
        let q2 = try await part2C.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Q two."))
        let p2 = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "P two."))
        XCTAssertTrue([q1, p1, q2, p2].allSatisfy(\.queued))
        try await h.settled(s, timeout: 240)
        let ids = [q1, q2, p1, p2].map(\.messageId)
        try await h.poll(timeout: 30, "every message has its turn") {
            ids.allSatisfy { id in view.syncedMessages.first { $0.messageId == id }?.message.turnId != nil }
        }
        func turnOf(_ id: String) -> String? { view.syncedMessages.first { $0.messageId == id }?.message.turnId }
        let qTurn = try XCTUnwrap(turnOf(q1.messageId))
        let pTurn = try XCTUnwrap(turnOf(p1.messageId))
        XCTAssertEqual(turnOf(q2.messageId), qTurn, "one turn per author")
        XCTAssertEqual(turnOf(p2.messageId), pTurn)
        XCTAssertNotEqual(qTurn, pTurn)
        let runningId = try XCTUnwrap(running.turnId)
        let runningStep = try XCTUnwrap(steps(view, turn: runningId).first { $0.kind == .modelCall })
        XCTAssertTrue((runningStep.historyMessageIds ?? []).isDisjoint(with: ids), "mid-turn messages stay out of the running turn")
        let qStep = try XCTUnwrap(steps(view, turn: qTurn).first { $0.kind == .modelCall })
        let pStep = try XCTUnwrap(steps(view, turn: pTurn).first { $0.kind == .modelCall })
        XCTAssertTrue((qStep.historyMessageIds ?? []).isSuperset(of: [q1.messageId, q2.messageId]))
        XCTAssertTrue((qStep.historyMessageIds ?? []).isDisjoint(with: [p1.messageId, p2.messageId]))
        XCTAssertTrue((pStep.historyMessageIds ?? []).isSuperset(of: [p1.messageId, p2.messageId]))
        XCTAssertLessThan(qStep.seq, pStep.seq, "the author whose first message came first runs first")

        // During a pause on TOOLS, a participant's send sets the paused turn aside.
        let t = try await h.createSession(h.tools, participants: [h.part, h.part2])
        let tView = try await h.open(part2C, t)
        let (_, paused) = try await h.pausedTurn(t, sender: partC, toolNames: ["sign", "pick"])
        let pausedIds = try XCTUnwrap(paused.pause?.callIds)
        let superseding = try await part2C.agents.sessions.send(sessionId: t.sessionId, body: AgentSessionSendBody(text: "Never mind."))
        XCTAssertEqual(superseding.superseded, paused.turnId)
        try await h.poll(timeout: 60, "the unanswered calls end superseded") {
            pausedIds.allSatisfy {
                tView.toolCall($0)?.state == "output-error" && tView.toolCall($0)?.errorCode == "AGENT_CALL_SUPERSEDED"
            }
        }
        try await h.settled(t)

        // During a pause on INITIATOR, the other participant's send waits.
        let i = try await h.createSession(h.initiator, participants: [h.part, h.part2])
        let iView = try await h.open(part2C, i)
        let (_, waiting) = try await h.pausedTurn(i, sender: partC, toolNames: ["pick"])
        let queued = try await part2C.agents.sessions.send(sessionId: i.sessionId, body: AgentSessionSendBody(text: "Me next."))
        XCTAssertTrue(queued.queued)
        XCTAssertNil(queued.superseded)
        let pickId = try XCTUnwrap(waiting.pause?.callIds.first)
        _ = try await partC.agents.sessions.answer(sessionId: i.sessionId, callId: pickId, .output(["count": 2]))
        try await h.settled(i)
        try await h.poll(timeout: 30, "the queued message ran after the answer") {
            guard let turnId = iView.syncedMessages.first(where: { $0.messageId == queued.messageId })?.message.turnId else { return false }
            return turnId != waiting.turnId
        }
    }

    // MARK: - Behaviors 19, 20 and edge 37: turn context

    func testTurnContextIsRequiredValidatedAndShownToAppAuthorityOnly() async throws {
        let s = try await h.createSession(h.context, participants: [h.part])
        let partC = try await h.client(h.part)
        let ownerC = try await h.client(h.owner)
        let adminC = try await h.client(h.admin)
        let view = try await h.open(partC, s)

        do {
            try await view.send(text: "hi")
            XCTFail("a send without the required context must be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_CONTEXT_INVALID")
        }
        XCTAssertEqual(view.pendingMessages.first?.state, .failed)
        XCTAssertEqual(view.pendingMessages.first?.error?.code, "AGENT_SESSION_CONTEXT_INVALID")

        let refused = await expectServerCode("AGENT_SESSION_SEND_INVALID") {
            _ = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(
                text: "hi", context: ["plan": "gold"], timezone: "Mars/Olympus_Mons"
            ))
        }
        let body = try XCTUnwrap(refused?.body.flatMap { try? JSONCoding.decodeData(JSONValue.self, from: Data($0.utf8)) })
        XCTAssertEqual(body["details"]?["field"], "timezone", "\(body)")

        let accepted = try await view.send(text: "hi", context: ["plan": "gold"], timezone: "Europe/Paris", locale: "fr-FR")
        XCTAssertNotNil(accepted.turnId)
        try await h.settled(s)

        let asAdmin = try await adminC.agents.sessions.get(sessionId: s.sessionId)
        let kept = try XCTUnwrap(asAdmin.turnContexts?.arrayValue, "\(String(describing: asAdmin.turnContexts))")
        XCTAssertFalse(kept.isEmpty)
        XCTAssertEqual(kept.last?["context"]?["plan"], "gold")
        XCTAssertEqual(kept.last?["timezone"], "Europe/Paris")
        XCTAssertEqual(kept.last?["locale"], "fr-FR")
        XCTAssertNotNil(asAdmin.lastTurn)
        XCTAssertNotNil(asAdmin.object)
        for c in [partC, ownerC] {
            let member = try await c.agents.sessions.get(sessionId: s.sessionId)
            XCTAssertNil(member.turnContexts)
            XCTAssertNil(member.lastTurn)
            XCTAssertNil(member.object)
        }
    }

    // MARK: - Behavior 25: paging live

    func testPagingWalksASeededSessionAndTwoSessionsStayApart() async throws {
        let big = try await h.createSession(h.plain, participants: [h.part])
        let small = try await h.createSession(h.plain, participants: [h.part])
        let writer = try await h.client(h.owner)
        writer.registerModels(AgentSessionModels.schemas)
        let created = "2026-10-02T12:00:00.000Z"
        func seed(_ s: AgentSessionScenarioHarness.Session, count: Int, firstSeq: Double, step: Double) async throws -> [String] {
            _ = try await writer.documents.open(s.documentId, options: OpenDocumentOptions(waitForLoad: .network))
            var ids: [String] = []
            for n in 0..<count {
                let id = PrimitiveSchemaRegistry.generateULID()
                ids.append(id)
                try writer.codegen.save(PrimitiveMessage.primitiveSchema, id: id, values: [
                    "seq": .number(firstSeq + Double(n) * step), "authorKind": .string("user"),
                    "authorUserId": .string(h.owner.userId), "createdAt": .date(created),
                ], in: s.documentId)
                try writer.codegen.save(PrimitivePart.primitiveSchema, id: PrimitiveSchemaRegistry.generateULID(), values: [
                    "messageId": .string(id), "seq": .number(1), "kind": .string("text"), "state": .string("done"),
                    "text": .string("seeded \(n)"), "createdAt": .date(created),
                ], in: s.documentId)
            }
            return ids
        }
        let bigIds = try await seed(big, count: 120, firstSeq: 1, step: 1)
        let smallIds = try await seed(small, count: 20, firstSeq: 2, step: 2)

        let reader = try await h.client(h.part)
        try await h.poll(timeout: 120, "the seeded rows reach the server") {
            let view = try await reader.agents.sessions.open(sessionId: big.sessionId)
            let ready = view.syncedMessages.count == 50 && view.syncedMessages.first?.seq == 71
            await view.close()
            return ready
        }
        let bigView = try await h.open(reader, big, pageSize: 50)
        XCTAssertEqual(bigView.syncedMessages.map(\.seq), (71...120).map(Double.init))
        XCTAssertTrue(bigView.hasOlder)
        XCTAssertEqual(bigView.syncedMessages.first?.parts.first?.text, "seeded 70")
        let olderA = try await bigView.loadOlder()
        XCTAssertEqual(olderA, AgentSessionLoadOlderResult(loaded: 50, hasOlder: true))
        let olderB = try await bigView.loadOlder()
        XCTAssertEqual(olderB, AgentSessionLoadOlderResult(loaded: 20, hasOlder: false))
        let olderC = try await bigView.loadOlder()
        XCTAssertEqual(olderC, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false))
        XCTAssertEqual(Set(bigView.syncedMessages.map(\.messageId)), Set(bigIds))

        let smallView = try await h.open(reader, small, pageSize: 50)
        try await h.poll(timeout: 60, "the small session's rows") { smallView.syncedMessages.count == 20 }
        XCTAssertEqual(Set(smallView.syncedMessages.map(\.messageId)), Set(smallIds))
        XCTAssertEqual(bigView.syncedMessages.count, 120, "two sessions on one client stay apart")
    }

    // MARK: - Edges 31, 32 and 36

    func testAPendingEntryWaitsForItsOwnRowAndAViewerWatchesWithoutWriting() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part], viewers: [h.viewer])
        let partC = try await h.client(h.part)
        let ownerC = try await h.client(h.owner)
        let viewerC = try await h.client(h.viewer)
        let watching = try await h.open(viewerC, s)
        let view = try await h.open(partC, s)

        // Edge 31: another author's row carries the same client message id.
        let shared = "shared-\(h.stamp)"
        let theirs = try await ownerC.agents.sessions.send(
            sessionId: s.sessionId, body: AgentSessionSendBody(text: "Owner first.", clientMessageId: shared)
        )
        try await h.poll(timeout: 30, "their row syncs") { view.syncedMessages.contains { $0.messageId == theirs.messageId } }
        try await h.settled(s)
        let snapshots = Recorder<(pending: Int, synced: Set<String>)>()
        view.onChange { [view] in snapshots.append((view.pendingMessages.count, Set(view.syncedMessages.map(\.messageId)))) }
        let mine = try await view.send(text: "Mine, same id.", clientMessageId: shared)
        XCTAssertNotEqual(mine.messageId, theirs.messageId)
        try await h.poll(timeout: 30, "my row replaces my entry") {
            view.pendingMessages.isEmpty && view.syncedMessages.contains { $0.messageId == mine.messageId }
        }
        for snapshot in snapshots.all where snapshot.pending == 0 {
            XCTAssertTrue(snapshot.synced.contains(mine.messageId), "the entry left only once its own row was in the window")
        }
        try await h.settled(s)

        // Edge 32: the viewer's view saw the turn's rows, and its socket stayed up.
        try await h.poll(timeout: 30, "the viewer sees the reply") {
            watching.syncedMessages.contains { $0.message.authorKind == .agent && $0.message.turnId == mine.turnId }
        }
        XCTAssertTrue(viewerC.isConnected, "no write refusal closed the viewer's socket")
        XCTAssertEqual(watching.status, .idle)
    }

    func testARateLimitedSendLeavesAFailedEntryWithRetryAfter() async throws {
        let s = try await h.createSession(h.plain)
        let ownerC = try await h.client(h.owner)
        let view = try await h.open(ownerC, s)
        var refusal: HttpError?
        for n in 0..<61 where refusal == nil {
            do {
                try await view.send(text: "Message \(n).")
            } catch let error as HttpError {
                refusal = error
            }
        }
        XCTAssertEqual(refusal?.serverCode, "AGENT_SESSION_RATE_LIMITED")
        let failed = try XCTUnwrap(view.pendingMessages.first { $0.state == .failed })
        XCTAssertEqual(failed.error?.code, "AGENT_SESSION_RATE_LIMITED")
        XCTAssertNotNil(failed.error?.retryAfter)
        _ = try? await view.cancel()
    }

    // MARK: - #4256: the unread dot

    func testMarkReadClearsTheDotInListAndGetForTheCallerAlone() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part], viewers: [h.viewer])
        let partC = try await h.client(h.part)
        let viewerC = try await h.client(h.viewer)
        let adminC = try await h.client(h.admin)
        let options = ListAgentSessionsOptions(limit: 100)

        let before = try await partC.agents.sessions.list(options: options)
        XCTAssertEqual(before.items.first { $0.sessionId == s.sessionId }?.hasUnread, true, "never marked")

        let marked = try await partC.agents.sessions.markRead(sessionId: s.sessionId)
        XCTAssertEqual(marked.sessionId, s.sessionId)
        let after = try await partC.agents.sessions.list(options: options)
        let item = try XCTUnwrap(after.items.first { $0.sessionId == s.sessionId })
        XCTAssertFalse(item.hasUnread)
        XCTAssertEqual(item.lastReadAt, marked.lastReadAt)
        let info = try await partC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertFalse(info.hasUnread)
        XCTAssertEqual(info.lastReadAt, marked.lastReadAt)

        let viewerInfo = try await viewerC.agents.sessions.get(sessionId: s.sessionId)
        XCTAssertTrue(viewerInfo.hasUnread, "another member's dot is theirs")
        _ = await expectServerCode("AGENT_SESSION_MEMBER_ONLY") {
            _ = try await adminC.agents.sessions.markRead(sessionId: s.sessionId)
        }
    }
}
