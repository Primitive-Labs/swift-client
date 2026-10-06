import XCTest
@testable import JsBaoClient

/// `client.agents.sessions`: every operation's path, method, query, body and
/// decode, on a recording transport (#3810, plan behaviors 1–9 and edge cases
/// 28–30, 35, 37). The JS client's `AgentSessionsAPI` is the reference.
final class AgentSessionsAPIHermeticTests: XCTestCase {

    // MARK: - Fixture

    /// A sessions API over a transport that answers `body` with `status` and
    /// records each call.
    private func api(status: Int = 200, _ body: String) -> (AgentSessionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: body)
        return (AgentSessionsAPI(transport: transport), transport)
    }

    private static let memberInfo = #"""
    {"sessionId":"s1","agentKey":"helper","documentId":"d1","ownerUserId":"u-owner",
     "createdAt":"2026-10-01T00:00:00.000Z","title":"Plans","scope":"team",
     "lastActivityAt":"2026-10-02T00:00:00.000Z",
     "members":{"viewers":["u-v"],"participants":["u-p1","u-p2"]},
     "role":"participant","status":"awaiting_answer",
     "turn":{"turnId":"t1","initiatorUserId":"u-p1","startedAt":"2026-10-02T00:00:01.000Z",
             "phase":"paused","rounds":2,"leaseUntil":null,"answeredBy":"participants",
             "pause":{"callIds":["c1","c2"],"since":"2026-10-02T00:00:02.000Z","expiresAt":"2026-10-03T00:00:02.000Z"},
             "pending":{"kind":"answer"}}}
    """#

    private static let adminInfo = #"""
    {"sessionId":"s1","agentKey":"helper","documentId":"d1","ownerUserId":"u-owner",
     "createdAt":"2026-10-01T00:00:00.000Z","title":null,"scope":null,"lastActivityAt":null,
     "members":{"viewers":[],"participants":[]},"role":"admin","status":"warming_up",
     "turn":null,
     "object":{"queue":[],"turn":null,"newKey":{"x":1}},
     "turnContexts":[{"messageId":"m1","context":{"plan":"pro"}}],
     "lastTurn":{"turnId":"t0","outcome":"settled"}}
    """#

    private func assertNoRequest(
        _ transport: RecordingTransport, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(transport.calls.isEmpty, "no request may be made; sent \(transport.calls.map(\.path))", file: file, line: line)
    }

    private func assertInvalidArgument(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected .invalidArgument", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument, file: file, line: line)
        } catch {
            XCTFail("expected JsBaoError(.invalidArgument), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Behavior 1: wiring

    func testAgentsSessionsIsReachableFromTheClientAndGoesThroughItsTransport() async throws {
        let server = try LoopbackAPIServer { request in
            request.apiPathOnly == "/agent-sessions/s1" ? .json(Self.memberInfo) : .status(404, "no")
        }
        let baseUrl = try server.start()
        defer { server.stop() }
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl, wsUrl: "ws://127.0.0.1:1", appId: "agent-sessions-wiring",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let sessions: AgentSessionsAPI = client.agents.sessions
        XCTAssertTrue(sessions === client.agents.sessions, "one sessions API per client")
        let info = try await sessions.get(sessionId: "s1")
        XCTAssertEqual(info.sessionId, "s1")
        XCTAssertTrue(server.paths.contains("/agent-sessions/s1"), "the request went through the client: \(server.paths)")

        // Built in isolation on a recorder, as the other sub-APIs can be.
        let (isolated, transport) = api(Self.memberInfo)
        _ = try await isolated.get(sessionId: "s1")
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions/s1")
        _ = AgentsAPI(transport: transport).sessions
    }

    // MARK: - Behavior 2 and edge 35: list

    func testListSendsTheQueryInTheJsOrderAndDecodesThePage() async throws {
        let body = #"""
        {"items":[{"sessionId":"s1","agentKey":"helper","scope":null,"documentId":"d1","ownerUserId":"u1",
                   "role":"owner","title":"A","lastActivityAt":"2026-10-02T00:00:00.000Z","createdAt":null},
                  {"sessionId":"s2","agentKey":"helper","scope":"x","documentId":"d2","ownerUserId":"u2",
                   "role":"guest","title":null,"lastActivityAt":"2026-10-01T00:00:00.000Z","createdAt":"2026-09-01T00:00:00.000Z"}],
         "hasMore":true,"nextCursor":"cur-2"}
        """#
        let (sessions, transport) = api(body)

        let page = try await sessions.list(options: ListAgentSessionsOptions(
            userId: "u 1", agent: "helper", scope: "a/b", limit: 2, cursor: "c+1"
        ))
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .get)
        XCTAssertEqual(call.path, "/agent-sessions?userId=u%201&agent=helper&scope=a%2Fb&limit=2&cursor=c%2B1")
        XCTAssertEqual(page.items.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(page.items[0].role, .owner)
        XCTAssertEqual(page.items[1].role, .unknown("guest"))
        XCTAssertEqual(page.items[1].role.rawValue, "guest")
        XCTAssertNil(page.items[0].scope)
        XCTAssertEqual(page.items[1].createdAt, "2026-09-01T00:00:00.000Z")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "cur-2")

        _ = try await sessions.list()
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions", "nil options → the bare path")
        _ = try await sessions.list(options: ListAgentSessionsOptions(agent: "helper", limit: 5))
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions?agent=helper&limit=5", "only the options given")
    }

    func testListAcceptsABareArrayAsOnePage() async throws {
        let (sessions, _) = api(#"""
        [{"sessionId":"s1","agentKey":"helper","scope":null,"documentId":"d1","ownerUserId":"u1",
          "role":"viewer","title":null,"lastActivityAt":"2026-10-02T00:00:00.000Z","createdAt":null}]
        """#)
        let page = try await sessions.list()
        XCTAssertEqual(page.items.map(\.sessionId), ["s1"])
        XCTAssertEqual(page.items[0].role, .viewer)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - Behavior 3 and edge 30: get

    func testGetDecodesAMembersInfoWithTheTurnAndNoAdminKeys() async throws {
        let (sessions, transport) = api(Self.memberInfo)
        let info = try await sessions.get(sessionId: "s1")
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions/s1")
        XCTAssertEqual(info.agentKey, "helper")
        XCTAssertEqual(info.documentId, "d1")
        XCTAssertEqual(info.title, "Plans")
        XCTAssertEqual(info.scope, "team")
        XCTAssertEqual(info.members, AgentSessionMembers(viewers: ["u-v"], participants: ["u-p1", "u-p2"]))
        XCTAssertEqual(info.role, .participant)
        XCTAssertEqual(info.status, .awaitingAnswer)
        let turn = try XCTUnwrap(info.turn)
        XCTAssertEqual(turn.turnId, "t1")
        XCTAssertEqual(turn.initiatorUserId, "u-p1")
        XCTAssertEqual(turn.phase, .paused)
        XCTAssertEqual(turn.rounds, 2)
        XCTAssertNil(turn.leaseUntil)
        XCTAssertEqual(turn.answeredBy, "participants")
        XCTAssertEqual(turn.pause?.callIds, ["c1", "c2"])
        XCTAssertEqual(turn.pause?.expiresAt, "2026-10-03T00:00:02.000Z")
        XCTAssertEqual(turn.pending?.kind, "answer")
        XCTAssertNil(info.object, "a member never receives object")
        XCTAssertNil(info.turnContexts)
        XCTAssertNil(info.lastTurn)
    }

    func testGetDecodesAnAdminsInfoWithUnknownStatusAndTheWholeObject() async throws {
        let (sessions, _) = api(Self.adminInfo)
        let info = try await sessions.get(sessionId: "s1")
        XCTAssertEqual(info.role, .admin)
        XCTAssertEqual(info.status, .unknown("warming_up"))
        XCTAssertNil(info.turn, "turn: null reads nil")
        XCTAssertNil(info.title)
        XCTAssertNil(info.lastActivityAt)
        XCTAssertEqual(info.object?["newKey"]?["x"], .number(1), "object is carried whole, unknown keys included")
        XCTAssertEqual(info.turnContexts?.arrayValue?.first?["context"]?["plan"], .string("pro"))
        XCTAssertEqual(info.lastTurn?["outcome"], .string("settled"))
    }

    func testGetDecodesUnknownPhaseRoleAndPendingKinds() async throws {
        let body = Self.memberInfo
            .replacingOccurrences(of: #""phase":"paused""#, with: #""phase":"reflecting""#)
            .replacingOccurrences(of: #""role":"participant""#, with: #""role":"auditor""#)
            .replacingOccurrences(of: #""pending":{"kind":"answer"}"#, with: #""pending":{"kind":"rewind"}"#)
        let (sessions, _) = api(body)
        let info = try await sessions.get(sessionId: "s1")
        XCTAssertEqual(info.turn?.phase, .unknown("reflecting"))
        XCTAssertEqual(info.turn?.phase.rawValue, "reflecting")
        XCTAssertEqual(info.role, .unknown("auditor"))
        XCTAssertEqual(info.role.rawValue, "auditor")
        XCTAssertEqual(info.turn?.pending?.kind, "rewind")

        let (ending, _) = api(Self.memberInfo.replacingOccurrences(
            of: #""pending":{"kind":"answer"}"#, with: #""pending":{"kind":"end"}"#))
        let ended = try await ending.get(sessionId: "s1")
        XCTAssertEqual(ended.turn?.pending?.kind, "end")

        for phase in ["model", "tools", "paused", "draining", "starting"] {
            XCTAssertEqual(AgentTurnPhase(rawValue: phase).rawValue, phase)
            XCTAssertNotEqual(AgentTurnPhase(rawValue: phase), .unknown(phase))
        }
        for role in ["owner", "participant", "viewer", "admin"] {
            XCTAssertEqual(AgentSessionRole(rawValue: role).rawValue, role)
            XCTAssertNotEqual(AgentSessionRole(rawValue: role), .unknown(role))
        }
    }

    // MARK: - Behavior 4: rename, delete, members

    func testRenameDeleteAndMemberCallsHitTheirRoutes() async throws {
        let (renaming, renameTransport) = api(#"{"sessionId":"s1","title":"New"}"#)
        let renamed = try await renaming.rename(sessionId: "s1", title: "New")
        XCTAssertEqual(renameTransport.lastCall?.method, .patch)
        XCTAssertEqual(renameTransport.lastCall?.path, "/agent-sessions/s1")
        XCTAssertEqual(renameTransport.lastCall?.jsonBody, ["title": "New"])
        XCTAssertEqual(renamed.title, "New")

        let (deleting, deleteTransport) = api(#"{"deleted":true,"sessionId":"s1","documentId":"d1"}"#)
        let deleted = try await deleting.delete(sessionId: "s1")
        XCTAssertEqual(deleteTransport.lastCall?.method, .delete)
        XCTAssertEqual(deleteTransport.lastCall?.path, "/agent-sessions/s1")
        XCTAssertNil(deleteTransport.lastCall?.body)
        XCTAssertEqual(deleted, try JSONCoding.decodeData(
            AgentSessionDeleteResult.self, from: Data(#"{"deleted":true,"sessionId":"s1","documentId":"d1"}"#.utf8)))
        XCTAssertTrue(deleted.deleted)

        let members = #"{"members":{"viewers":["u2"],"participants":["u3"]}}"#
        let (adding, addTransport) = api(members)
        let added = try await adding.addMember(sessionId: "s1", userId: "u2", role: .viewer)
        XCTAssertEqual(addTransport.lastCall?.method, .post)
        XCTAssertEqual(addTransport.lastCall?.path, "/agent-sessions/s1/members")
        XCTAssertEqual(addTransport.lastCall?.jsonBody, ["userId": "u2", "role": "viewer"])
        XCTAssertEqual(added.members, AgentSessionMembers(viewers: ["u2"], participants: ["u3"]))

        _ = try await adding.addMember(sessionId: "s1", userId: "u3", role: .participant)
        XCTAssertEqual(addTransport.lastCall?.jsonBody, ["userId": "u3", "role": "participant"])

        let (removing, removeTransport) = api(members)
        let removed = try await removing.removeMember(sessionId: "s1", userId: "u9")
        XCTAssertEqual(removeTransport.lastCall?.method, .delete)
        XCTAssertEqual(removeTransport.lastCall?.path, "/agent-sessions/s1/members/u9")
        XCTAssertEqual(removed.members.participants, ["u3"])
    }

    // MARK: - Behavior 5, edges 28 and 37: send

    func testSendCarriesOnlyTheKeysGivenAndDecodesTheAnswer() async throws {
        let (sessions, transport) = api(#"{"messageId":"m1","seq":7,"turnId":"t1","queued":false}"#)
        let result = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(
            text: "hi", files: [AgentSessionFileRef(blobId: "b1")], clientMessageId: "cm1",
            context: ["plan": "pro", "seats": 3], timezone: "Europe/Paris", locale: "fr-FR"
        ))
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions/s1/messages")
        XCTAssertEqual(transport.lastCall?.jsonBody, [
            "text": "hi", "files": [["blobId": "b1"]], "clientMessageId": "cm1",
            "context": ["plan": "pro", "seats": 3], "timezone": "Europe/Paris", "locale": "fr-FR",
        ])
        XCTAssertEqual(result.messageId, "m1")
        XCTAssertEqual(result.seq, 7)
        XCTAssertEqual(result.turnId, "t1")
        XCTAssertFalse(result.queued)
        XCTAssertNil(result.duplicate)
        XCTAssertNil(result.superseded)

        _ = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(text: "only text"))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["text": "only text"])
    }

    func testSendDecodesDuplicateSupersededAndANullTurn() async throws {
        let (sessions, _) = api(#"{"messageId":"m2","seq":9,"turnId":null,"queued":true,"duplicate":true,"superseded":"t-paused"}"#)
        let result = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(text: "x"))
        XCTAssertNil(result.turnId)
        XCTAssertTrue(result.queued)
        XCTAssertEqual(result.duplicate, true)
        XCTAssertEqual(result.superseded, "t-paused")
    }

    func testSendRefusesAContextThatIsNotAnObjectWithoutARequest() async {
        for context: JSONValue in [.string("pro"), .array([]), .null, .number(1)] {
            let (sessions, transport) = api(#"{"messageId":"m1","seq":1,"turnId":null,"queued":false}"#)
            await assertInvalidArgument {
                _ = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(text: "x", context: context))
            }
            assertNoRequest(transport)
        }
    }

    func testSendWithFilesAndNoTextOmitsTextAndKeepsAnEmptyFilesList() async throws {
        let (sessions, transport) = api(#"{"messageId":"m1","seq":1,"turnId":"t1","queued":false}"#)
        _ = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(files: [AgentSessionFileRef(blobId: "b1")]))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["files": [["blobId": "b1"]]])
        _ = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(text: "x", files: []))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["text": "x", "files": []], "an empty files list goes as given")
    }

    func testSendKeepsAnEmptyContextBesideTimezoneAndLocale() async throws {
        let (sessions, transport) = api(#"{"messageId":"m1","seq":1,"turnId":"t1","queued":false}"#)
        _ = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(
            text: "x", context: .object([:]), timezone: "America/New_York", locale: "en-US"
        ))
        XCTAssertEqual(transport.lastCall?.jsonBody, [
            "text": "x", "context": .object([:]), "timezone": "America/New_York", "locale": "en-US",
        ])
    }

    // MARK: - Behavior 6 and edge 29: answer

    func testAnswerSendsExactlyOneKeyPerCaseAndDecodesTheOpenState() async throws {
        let (sessions, transport) = api(#"{"callId":"c1","state":"approval-responded"}"#)
        let approved = try await sessions.answer(sessionId: "s1", callId: "c1", .approval(approved: true, reason: "ok"))
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions/s1/calls/c1/answer")
        XCTAssertEqual(transport.lastCall?.jsonBody, ["approval": ["approved": true, "reason": "ok"]])
        XCTAssertEqual(approved.callId, "c1")
        XCTAssertEqual(approved.state, .approvalResponded)

        _ = try await sessions.answer(sessionId: "s1", callId: "c1", .approval(approved: false))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["approval": ["approved": false]], "no reason key")

        _ = try await sessions.answer(sessionId: "s1", callId: "c1", .output(["signed": true], artifact: ["pdf": "b9"]))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["output": ["signed": true], "artifact": ["pdf": "b9"]])

        _ = try await sessions.answer(sessionId: "s1", callId: "c1", .output(.null))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["output": .null], "output null is sent as null")
        XCTAssertEqual(String(data: try XCTUnwrap(transport.lastCall?.body), encoding: .utf8), #"{"output":null}"#)

        _ = try await sessions.answer(sessionId: "s1", callId: "c1", .error(message: "camera unavailable"))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["error": ["message": "camera unavailable"]])

        struct Pick: Encodable { let choice: String; let count: Int }
        _ = try await sessions.answer(sessionId: "s1", callId: "c1", try .output(encoding: Pick(choice: "b", count: 2)))
        XCTAssertEqual(transport.lastCall?.jsonBody, ["output": ["choice": "b", "count": 2]])

        let (other, _) = api(#"{"callId":"c1","state":"output-stalled"}"#)
        let unknown = try await other.answer(sessionId: "s1", callId: "c1", .output(.null))
        XCTAssertEqual(unknown.state, .unknown("output-stalled"))
    }

    // MARK: - Behavior 7: cancel and recordEvent

    func testCancelAndRecordEventSendTheirBodiesAndDecodeTheirAnswers() async throws {
        let (cancelling, cancelTransport) = api(#"{"turnId":"t1","cancelled":true,"nextTurnId":"t2"}"#)
        let cancelled = try await cancelling.cancel(sessionId: "s1", turnId: "t1")
        XCTAssertEqual(cancelTransport.lastCall?.method, .post)
        XCTAssertEqual(cancelTransport.lastCall?.path, "/agent-sessions/s1/cancel")
        XCTAssertEqual(cancelTransport.lastCall?.jsonBody, ["turnId": "t1"])
        XCTAssertEqual(cancelled.nextTurnId, "t2")
        XCTAssertTrue(cancelled.cancelled)

        let (lastCancel, _) = api(#"{"turnId":"t1","cancelled":true,"nextTurnId":null}"#)
        let none = try await lastCancel.cancel(sessionId: "s1", turnId: "t1")
        XCTAssertNil(none.nextTurnId)

        let (recording, eventTransport) = api(#"{"messageId":"m5","seq":12}"#)
        let data: JSONValue = ["nested": ["list": [1, "two", .null]], "flag": false, "none": .null]
        let recorded = try await recording.recordEvent(sessionId: "s1", event: AgentSessionEvent(kind: "viewed", data: data))
        XCTAssertEqual(eventTransport.lastCall?.method, .post)
        XCTAssertEqual(eventTransport.lastCall?.path, "/agent-sessions/s1/events")
        XCTAssertEqual(eventTransport.lastCall?.jsonBody, ["kind": "viewed", "data": data], "data verbatim, no ids")
        XCTAssertEqual(recorded.messageId, "m5")
        XCTAssertEqual(recorded.seq, 12)
        XCTAssertNil(recorded.duplicate)

        _ = try await recording.recordEvent(sessionId: "s1", event: AgentSessionEvent(
            kind: "viewed", data: .null, eventId: "e1", refersTo: "c1"
        ))
        XCTAssertEqual(eventTransport.lastCall?.jsonBody, ["kind": "viewed", "data": .null, "eventId": "e1", "refersTo": "c1"])
    }

    // MARK: - Behavior 8: refusals

    func testEveryOperationSurfacesTheServersCodeAndStatus() async {
        let body = #"{"code":"AGENT_SESSION_NOT_FOUND","error":"Session not found"}"#
        let operations: [(String, (AgentSessionsAPI) async throws -> Void)] = [
            ("list", { _ = try await $0.list() }),
            ("get", { _ = try await $0.get(sessionId: "s1") }),
            ("rename", { _ = try await $0.rename(sessionId: "s1", title: "t") }),
            ("delete", { _ = try await $0.delete(sessionId: "s1") }),
            ("addMember", { _ = try await $0.addMember(sessionId: "s1", userId: "u", role: .viewer) }),
            ("removeMember", { _ = try await $0.removeMember(sessionId: "s1", userId: "u") }),
            ("send", { _ = try await $0.send(sessionId: "s1", body: AgentSessionSendBody(text: "x")) }),
            ("answer", { _ = try await $0.answer(sessionId: "s1", callId: "c", .output(.null)) }),
            ("cancel", { _ = try await $0.cancel(sessionId: "s1", turnId: "t") }),
            ("recordEvent", { _ = try await $0.recordEvent(sessionId: "s1", event: AgentSessionEvent(kind: "k", data: .null)) }),
        ]
        for (name, operation) in operations {
            let (sessions, transport) = api(status: 404, body)
            do {
                try await operation(sessions)
                XCTFail("\(name) should throw")
            } catch let error as HttpError {
                XCTAssertEqual(error.serverCode, "AGENT_SESSION_NOT_FOUND", name)
                XCTAssertEqual(error.status, 404, name)
                XCTAssertEqual(error.serverMessage, "Session not found", name)
            } catch {
                XCTFail("\(name) threw \(error), not HttpError")
            }
            XCTAssertEqual(transport.calls.count, 1, "\(name) made one request")
        }
    }

    // MARK: - Behavior 9: path encoding and empty ids

    func testPathSegmentsAreEscapedOneEach() async throws {
        let (sessions, transport) = api(#"{"callId":"c","state":"output-available"}"#)
        _ = try await sessions.answer(sessionId: "s/1+ x", callId: "c/2+ y", .output(.null))
        XCTAssertEqual(transport.lastCall?.path, "/agent-sessions/s%2F1%2B%20x/calls/c%2F2%2B%20y/answer")

        let (members, membersTransport) = api(#"{"members":{"viewers":[],"participants":[]}}"#)
        _ = try await members.removeMember(sessionId: "s/1", userId: "u/3+ z")
        XCTAssertEqual(membersTransport.lastCall?.path, "/agent-sessions/s%2F1/members/u%2F3%2B%20z")
    }

    func testEmptyIdsAndTitlesThrowBeforeAnyRequest() async {
        let (sessions, transport) = api("{}")
        await assertInvalidArgument { _ = try await sessions.get(sessionId: "") }
        await assertInvalidArgument { _ = try await sessions.rename(sessionId: "", title: "t") }
        await assertInvalidArgument { _ = try await sessions.rename(sessionId: "s1", title: "") }
        await assertInvalidArgument { _ = try await sessions.delete(sessionId: "") }
        await assertInvalidArgument { _ = try await sessions.addMember(sessionId: "s1", userId: "", role: .viewer) }
        await assertInvalidArgument { _ = try await sessions.removeMember(sessionId: "s1", userId: "") }
        await assertInvalidArgument { _ = try await sessions.send(sessionId: "", body: AgentSessionSendBody(text: "x")) }
        await assertInvalidArgument { _ = try await sessions.answer(sessionId: "s1", callId: "", .output(.null)) }
        await assertInvalidArgument { _ = try await sessions.cancel(sessionId: "s1", turnId: "") }
        await assertInvalidArgument {
            _ = try await sessions.recordEvent(sessionId: "", event: AgentSessionEvent(kind: "k", data: .null))
        }
        assertNoRequest(transport)
    }
}
