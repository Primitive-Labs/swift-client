import Foundation
import XCTest
@testable import JsBaoClient

/// `view.handleClientTools` on live Swift clients (#4263, plan behavior 13):
/// the JS client's rules, verified against the dev server with real turns
/// (the model steered at temperature 0; shapes and codes asserted, never
/// words). INITIATOR's `Go.` calls `pick`; TOOLS's `Go.` calls `sign` (with
/// approval) and `pick` together under `answeredBy: participants`.
///
/// Sync is paused with `setShouldConnect(false)` (HTTP stays up) and the
/// client taken offline with `goOffline()`; nothing is doubled.
final class AgentClientToolsLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-client-tools-swift-4263") }
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

    /// A gate a handler waits on until the test opens it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resume: Bool = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in waiting { waiter.resume() }
        }
    }

    private struct Question: Codable, Sendable { let question: String }
    private struct Count: Codable, Sendable { let count: Int }
    private struct Topic: Codable, Sendable { let topic: String }
    private struct Unencodable: Encodable, Sendable {
        struct Refused: Error {}
        func encode(to encoder: Encoder) throws { throw Refused() }
    }
    private struct Failed: LocalizedError {
        let errorDescription: String?
    }

    /// Send `Go.` through `view` until `called()` holds; a turn that ends
    /// without the call is sent once more.
    private func goUntilCalled(
        _ s: AgentSessionScenarioHarness.Session, _ view: AgentSessionView, _ called: @escaping () -> Bool
    ) async throws {
        for _ in 0..<2 {
            _ = try await view.send(text: "Go.")
            var settledFirst = false
            try await h.poll(timeout: 120, interval: 0.3, "the handler runs or the turn ends") {
                if called() { return true }
                let turn = try await self.h.probe(s, "state")["turn"]
                settledFirst = turn == nil || turn is NSNull
                return settledFirst
            }
            if called() { return }
        }
        throw TestSetupError("the model did not call the tool")
    }

    private func pick(_ view: AgentSessionView, _ callId: String) -> AgentSessionToolCallRecord? {
        view.toolCall(callId)
    }

    private func newestPick(_ view: AgentSessionView) -> AgentSessionToolCallRecord? {
        view.toolCalls.filter { $0.toolName == "pick" }.last
    }

    private func expectInvalidArgument(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("\(what) is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument, what)
        } catch {
            XCTFail("\(what): expected .invalidArgument, got \(error)")
        }
    }

    // MARK: - Registration (behavior 1)

    func testRegistrationRefusesTakenNamesAndAClosedViewAndUnsubscribeLetsARunFinish() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let noop = AgentClientToolHandler { _ in AgentClientToolResult(output: ["count": 1]) }

        let offOther = try view.handleClientTools(["other": noop])
        expectInvalidArgument("a taken name") { try view.handleClientTools(["other": noop]) }
        expectInvalidArgument("a registration naming a taken name") {
            try view.handleClientTools(["pick": noop, "other": noop])
        }
        try view.handleClientTools([:])()

        // A run in flight at unsubscribe still answers.
        let runs = Recorder<String>()
        let gate = Gate()
        let offPick = try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            await gate.wait()
            return AgentClientToolResult(output: ["count": 2])
        }])
        try await goUntilCalled(s, view) { !runs.all.isEmpty }
        let callId = try XCTUnwrap(runs.all.first)
        offPick()
        gate.open()
        try await h.poll(timeout: 30, "the call is answered") {
            self.pick(view, callId)?.state == .outputAvailable
        }
        XCTAssertEqual(pick(view, callId)?.output, ["count": 2])
        try await h.settled(s)
        expectInvalidArgument("the other registration's name") { try view.handleClientTools(["other": noop]) }

        // After unsubscribe, a later call is never run by the view.
        let (_, turn) = try await h.pausedTurn(s, sender: partC, toolNames: ["pick"])
        let later = try XCTUnwrap(turn.pause?.callIds.first)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(runs.all.count, 1)
        _ = try await view.answer(callId: later, .output(["count": 5]))
        try await h.settled(s)
        XCTAssertEqual(runs.all.count, 1)
        offOther()
        try view.handleClientTools(["other": noop])()

        await view.close()
        expectInvalidArgument("a closed view") { try view.handleClientTools(["pick": noop]) }
        XCTAssertEqual(view.runningClientToolCalls, [])
    }

    // MARK: - The handler contract (behavior 2)

    func testAnUntypedAndATypedHandlerAnswerTheInitiatorsCall() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let changes = Recorder<Int>()
        view.onChange { changes.append(1) }
        let calls = Recorder<AgentClientToolCall<JSONValue>>()
        let gate = Gate()
        let off = try view.handleClientTools(["pick": AgentClientToolHandler { call in
            calls.append(call)
            await gate.wait()
            return AgentClientToolResult(output: ["count": 3], artifact: ["note": "first"])
        }])
        try await goUntilCalled(s, view) { !calls.all.isEmpty }
        let call = try XCTUnwrap(calls.all.first)
        XCTAssertEqual(call.sessionId, s.sessionId)
        XCTAssertEqual(call.toolName, "pick")
        XCTAssertEqual(call.input, ["question": "How many?"])
        try await h.poll(timeout: 30, "the call's part syncs") { self.pick(view, call.callId) != nil }
        let part = try XCTUnwrap(pick(view, call.callId))
        XCTAssertEqual(part.id, call.partId)
        XCTAssertEqual(part.messageId, call.messageId)
        XCTAssertEqual(part.input, call.input)
        XCTAssertEqual(view.syncedMessages.first { $0.messageId == call.messageId }?.message.turnId, call.turnId)
        XCTAssertEqual(view.runningClientToolCalls, [call.callId])
        try await h.poll(timeout: 10, "running is heard") { !changes.all.isEmpty }
        let heard = changes.all.count

        gate.open()
        try await h.poll(timeout: 30, "the output lands") { self.pick(view, call.callId)?.state == .outputAvailable }
        let landed = try XCTUnwrap(pick(view, call.callId))
        XCTAssertEqual(landed.output, ["count": 3])
        XCTAssertEqual(landed.artifact, ["note": "first"])
        XCTAssertEqual(landed.resolvedByUserId, h.part.userId)
        // The part can sync before the answer's response returns.
        try await h.poll(timeout: 10, "the run ends") { view.runningClientToolCalls.isEmpty }
        try await h.poll(timeout: 10, "done is heard") { changes.all.count > heard }
        try await h.settled(s)
        off()

        // A typed handler over local Codable types; no artifact stays none.
        let typedCalls = Recorder<String>()
        try view.handleClientTools(["pick": .typed { (call: AgentClientToolCall<Question>) in
            typedCalls.append(call.callId)
            return AgentClientToolResult(output: Count(count: call.input.question.count))
        }])
        try await goUntilCalled(s, view) { !typedCalls.all.isEmpty }
        let typedId = try XCTUnwrap(typedCalls.all.first)
        try await h.poll(timeout: 30, "the typed output lands") { self.pick(view, typedId)?.state == .outputAvailable }
        XCTAssertEqual(pick(view, typedId)?.output, ["count": .number(Double("How many?".count))])
        XCTAssertNil(pick(view, typedId)?.artifact)
        try await h.settled(s)
    }

    // MARK: - Error answers (behavior 3)

    func testAThrownErrorAnUndecodableInputAndAFailingEncodableLandAsOutputError() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let errors = Recorder<AgentClientToolError>()
        let options = HandleClientToolsOptions(onError: { errors.append($0) })
        let cases: [(AgentClientToolHandler, (String?) -> Bool)] = [
            (AgentClientToolHandler { _ in throw Failed(errorDescription: "no stock") }, { $0 == "no stock" }),
            (.typed { (call: AgentClientToolCall<Topic>) in AgentClientToolResult(output: Count(count: call.input.topic.count)) },
             { !($0 ?? "").isEmpty }),
            (.typed { (_: AgentClientToolCall<Question>) in AgentClientToolResult(output: Unencodable()) },
             { !($0 ?? "").isEmpty }),
        ]
        var seen = Set<String>()
        for (index, (handler, matches)) in cases.enumerated() {
            let off = try view.handleClientTools(["pick": handler], options: options)
            let before = seen
            let failedPick = {
                view.toolCalls.first {
                    $0.toolName == "pick" && $0.state == .outputError && !before.contains($0.id)
                }
            }
            // The undecodable case never reaches its closure: watch the part.
            try await goUntilCalled(s, view) { failedPick() != nil }
            let landed = try XCTUnwrap(failedPick())
            seen.insert(landed.id)
            XCTAssertEqual(landed.errorCode, "AGENT_CLIENT_TOOL_FAILED", "case \(index)")
            XCTAssertTrue(matches(landed.errorText), "case \(index): \(landed.errorText ?? "nil")")
            XCTAssertEqual(landed.resolvedByUserId, h.part.userId)
            try await h.settled(s)
            off()
        }
        XCTAssertTrue(errors.all.isEmpty, "\(errors.all.map(\.message))")
    }

    // MARK: - Approval, unregistered names and the initiator rule (behaviors 4 and 5)

    func testSignWaitsForItsApprovalAnUnhandledCallIsLeftAndOnlyTheInitiatorRuns() async throws {
        let s = try await h.createSession(h.tools, participants: [h.part, h.part2])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let other = try await h.open(try await h.client(h.part2), s)
        let owner = try await h.open(try await h.client(h.owner), s)
        let signs = Recorder<String>()
        let strangers = Recorder<String>()
        try view.handleClientTools(["sign": AgentClientToolHandler { call in
            signs.append(call.callId)
            XCTAssertEqual(call.input, ["what": "lease"])
            return AgentClientToolResult(output: ["signed": true])
        }])
        let elsewhere = AgentClientToolHandler { call in
            strangers.append(call.callId)
            return AgentClientToolResult(output: ["count": 9, "signed": true])
        }
        try other.handleClientTools(["sign": elsewhere, "pick": elsewhere])
        try owner.handleClientTools(["sign": elsewhere, "pick": elsewhere])

        let (_, turn) = try await h.pausedTurn(s, sender: partC, toolNames: ["sign", "pick"])
        try await h.poll(timeout: 30, "both calls sync") { view.toolCalls.count >= 2 }
        let sign = try XCTUnwrap(view.toolCalls.first { $0.toolName == "sign" })
        let pickCall = try XCTUnwrap(view.toolCalls.first { $0.toolName == "pick" })
        XCTAssertTrue(turn.pause?.callIds.contains(sign.id) == true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(signs.all, [])
        XCTAssertEqual(view.toolCall(sign.id)?.state, .approvalRequested)
        XCTAssertEqual(view.toolCall(pickCall.id)?.state, .inputAvailable)

        _ = try await view.answer(callId: sign.id, .approval(approved: true))
        try await h.poll(timeout: 30, "the approved call runs") {
            view.toolCall(sign.id)?.state == .outputAvailable
        }
        XCTAssertEqual(signs.all, [sign.id])
        XCTAssertEqual(view.toolCall(sign.id)?.output, ["signed": true])
        XCTAssertEqual(view.toolCall(pickCall.id)?.state, .inputAvailable)
        _ = try await view.answer(callId: pickCall.id, .output(["count": 2]))
        try await h.settled(s)
        XCTAssertEqual(strangers.all, [], "only the initiator's views run")
    }

    // MARK: - Two of the initiator's views (behavior 6)

    func testTwoOfTheInitiatorsViewsBothRunAndOneAnswerIsRecordedSilently() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let a = try await h.open(try await h.client(h.part), s)
        let b = try await h.open(try await h.client(h.part), s)
        let errors = Recorder<AgentClientToolError>()
        let options = HandleClientToolsOptions(onError: { errors.append($0) })
        let runsA = Recorder<String>()
        let runsB = Recorder<String>()
        let gateA = Gate()
        let gateB = Gate()
        try a.handleClientTools(["pick": AgentClientToolHandler { call in
            runsA.append(call.callId)
            await gateA.wait()
            return AgentClientToolResult(output: ["count": 1])
        }], options: options)
        try b.handleClientTools(["pick": AgentClientToolHandler { call in
            runsB.append(call.callId)
            await gateB.wait()
            return AgentClientToolResult(output: ["count": 2])
        }], options: options)
        try await goUntilCalled(s, a) { !runsA.all.isEmpty }
        try await h.poll(timeout: 30, "the second view runs it too") { !runsB.all.isEmpty }
        let callId = try XCTUnwrap(runsA.all.first)
        XCTAssertEqual(runsB.all, [callId])
        gateA.open()
        gateB.open()
        try await h.settled(s)
        try await h.poll(timeout: 30, "both views see one answer") {
            a.toolCall(callId)?.state == .outputAvailable && b.toolCall(callId)?.state == .outputAvailable
                && a.runningClientToolCalls.isEmpty && b.runningClientToolCalls.isEmpty
        }
        let output = try XCTUnwrap(a.toolCall(callId)?.output)
        XCTAssertTrue(output == ["count": 1] || output == ["count": 2], "\(output)")
        XCTAssertEqual(b.toolCall(callId)?.output, output)
        XCTAssertEqual(a.toolCall(callId)?.resolvedByUserId, h.part.userId)
        XCTAssertEqual(errors.all.count, 0)
    }

    // MARK: - One answer per view (behavior 7)

    func testAViewNeverRunsACallTwiceWhileItsAcceptedAnswerHasNotSynced() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let errors = Recorder<AgentClientToolError>()
        let runs = Recorder<String>()
        let gate = Gate()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            await gate.wait()
            return AgentClientToolResult(output: ["count": 7])
        }], options: HandleClientToolsOptions(onError: { errors.append($0) }))
        try await goUntilCalled(s, view) { !runs.all.isEmpty }
        let callId = try XCTUnwrap(runs.all.first)
        try await h.poll(timeout: 30, "the part syncs") { view.toolCall(callId) != nil }
        // Sync paused, HTTP up.
        await partC.setShouldConnect(false)
        gate.open()
        try await h.poll(timeout: 30, "the answer returns") { view.runningClientToolCalls.isEmpty }
        XCTAssertEqual(errors.all.count, 0)
        try await h.poll(timeout: 30, "the server has the answer") {
            let turn = try await partC.agents.sessions.get(sessionId: s.sessionId).turn
            return !(turn?.pause?.callIds.contains(callId) ?? false)
        }
        XCTAssertEqual(view.toolCall(callId)?.state, .inputAvailable)
        // Force an evaluation over the unsynced part.
        try view.handleClientTools(["sign": AgentClientToolHandler { _ in AgentClientToolResult(output: ["signed": true]) }])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(view.toolCall(callId)?.state, .inputAvailable)
        XCTAssertEqual(runs.all.count, 1)
        XCTAssertEqual(view.runningClientToolCalls, [])
        await partC.setShouldConnect(true)
        try await h.poll(timeout: 60, "the answer syncs") { view.toolCall(callId)?.state == .outputAvailable }
        XCTAssertEqual(view.toolCall(callId)?.output, ["count": 7])
        try await h.settled(s)
        XCTAssertEqual(runs.all.count, 1)
    }

    // MARK: - A refused output (behavior 8)

    func testARefusedOutputReachesOnErrorOnceAndIsNotRunAgainWhileUnchanged() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let errors = Recorder<AgentClientToolError>()
        let runs = Recorder<String>()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            return AgentClientToolResult(output: ["count": 0])
        }], options: HandleClientToolsOptions(onError: { errors.append($0) }))
        try await goUntilCalled(s, view) { !runs.all.isEmpty }
        try await h.poll(timeout: 30, "the refusal is heard") { errors.all.count == 1 }
        let refused = try XCTUnwrap(errors.all.first)
        XCTAssertEqual(refused.code, "AGENT_ANSWER_INVALID")
        XCTAssertEqual(refused.toolName, "pick")
        XCTAssertFalse(refused.message.isEmpty)
        XCTAssertTrue(refused.error is HttpError)
        try await h.poll(timeout: 30, "the part syncs") { view.toolCall(refused.callId) != nil }
        XCTAssertEqual(view.toolCall(refused.callId)?.state, .inputAvailable)
        try view.handleClientTools(["other": AgentClientToolHandler { _ in AgentClientToolResult(output: [:]) }])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(runs.all.count, 1)
        XCTAssertEqual(errors.all.count, 1)
        _ = try await view.answer(callId: refused.callId, .output(["count": 2]))
        try await h.settled(s)
    }

    // MARK: - Offline, and the quiet re-sync (behavior 9)

    func testAnOfflineAnswerReachesOnErrorWithoutACodeAndRunsAgainOnTheReSync() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let errors = Recorder<AgentClientToolError>()
        let runs = Recorder<String>()
        let gate = Gate()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            if runs.all.count == 1 { await gate.wait() }
            return AgentClientToolResult(output: ["count": 8])
        }], options: HandleClientToolsOptions(onError: { errors.append($0) }))
        try await goUntilCalled(s, view) { !runs.all.isEmpty }
        let callId = try XCTUnwrap(runs.all.first)
        // Nothing more changes on the server while the turn waits.
        try await h.poll(timeout: 30, "the row reads awaiting") { view.status == .awaitingAnswer }
        await partC.goOffline()
        gate.open()
        try await h.poll(timeout: 30, "the offline failure is heard") { errors.all.count == 1 }
        let failure = try XCTUnwrap(errors.all.first)
        XCTAssertEqual(failure.callId, callId)
        XCTAssertNil(failure.code)
        XCTAssertEqual((failure.error as? JsBaoError)?.code, .offline)
        XCTAssertEqual(view.runningClientToolCalls, [])
        XCTAssertEqual(runs.all.count, 1)
        await partC.goOnline()
        try await h.poll(timeout: 60, "the re-sync runs it again") { runs.all.count == 2 }
        try await h.poll(timeout: 60, "the output lands") { view.toolCall(callId)?.state == .outputAvailable }
        XCTAssertEqual(view.toolCall(callId)?.output, ["count": 8])
        try await h.settled(s)
        XCTAssertEqual(errors.all.count, 1)
    }

    // MARK: - Close (behavior 10)

    func testCloseCancelsARunningHandlerAndPostsNothing() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let runs = Recorder<String>()
        let cancelled = Recorder<Bool>()
        let gate = Gate()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            await gate.wait()
            cancelled.append(Task.isCancelled)
            return AgentClientToolResult(output: ["count": 9])
        }])
        try await goUntilCalled(s, view) { !runs.all.isEmpty }
        let callId = try XCTUnwrap(runs.all.first)
        XCTAssertEqual(view.runningClientToolCalls, [callId])
        await view.close()
        XCTAssertEqual(view.runningClientToolCalls, [])
        gate.open()
        try await h.poll(timeout: 10, "the handler returns") { !cancelled.all.isEmpty }
        XCTAssertEqual(cancelled.all, [true])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let other = try await h.client(h.part)
        let accepted = try await other.agents.sessions.answer(sessionId: s.sessionId, callId: callId, .output(["count": 10]))
        XCTAssertEqual(accepted.state, .outputAvailable)
        try await h.settled(s)
        XCTAssertEqual(runs.all.count, 1)
    }

    // MARK: - Resume (behavior 11)

    func testACallPendingAtRegistrationRunsFoundInTheDb3NotTheWindow() async throws {
        let s = try await h.createSession(h.tools, participants: [h.part])
        let partC = try await h.client(h.part)
        let (_, turn) = try await h.pausedTurn(s, sender: partC, toolNames: ["sign", "pick"])
        XCTAssertEqual(turn.pause?.callIds.count, 2)
        _ = try await partC.agents.sessions.recordEvent(
            sessionId: s.sessionId, event: AgentSessionEvent(kind: "viewed", data: ["item": "lease"])
        )
        let view = try await h.open(partC, s, pageSize: 1)
        try await h.poll(timeout: 30, "the window holds the event") {
            view.syncedMessages.count == 1 && view.syncedMessages[0].parts.map { $0.eventPart != nil } == [true]
        }
        let runs = Recorder<String>()
        try view.handleClientTools(["pick": AgentClientToolHandler { call in
            runs.append(call.callId)
            return AgentClientToolResult(output: ["count": 11])
        }])
        try await h.poll(timeout: 30, "the pending call runs") { runs.all.count == 1 }
        let callId = try XCTUnwrap(runs.all.first)
        XCTAssertTrue(turn.pause?.callIds.contains(callId) == true)
        let sign = try XCTUnwrap(turn.pause?.callIds.first { $0 != callId })
        _ = try await view.answer(callId: sign, .approval(approved: false))
        try await h.settled(s)
        do {
            _ = try await partC.agents.sessions.answer(sessionId: s.sessionId, callId: callId, .output(["count": 12]))
            XCTFail("the handler's answer was recorded first")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_CALL_ANSWERED")
        }
    }
}
