import XCTest
@testable import JsBaoClient

/// `view.presentations(of:names:)` over the session's db3 — #4549 behavior 17
/// (#4884 behavior 11), the Swift half of `tests/unit/workflows/
/// agent-presentation-view-4549.test.ts`, over the same rows.
///
/// A turn whose agent called `lookup` (call 1) in its first round and the
/// presentation `present` (call 3, `show: [1]`) with its answer, a refused
/// presentation (call 2), a user message, and an earlier turn whose call
/// carries no number (a row written before numbering). Each presentation is
/// decoded through the generated acceptance enum `AdvisorAgentPresentation`.
final class AgentPresentationHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var db3s: [SessionDb3] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for db3 in db3s { db3.cleanup() }
        db3s = []
    }

    private static let created = "2026-10-14T12:00:00.000Z"

    /// The session's db3 holding the rows, and a view open over it.
    private func open(_ name: String) async throws -> AgentSessionView {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-presentation-\(name)",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        let db3 = try await SessionDb3.make(id: "s1")
        db3s.append(db3)
        try seed(db3)
        let transport = RecordingTransport(json: agentSessionInfoJSON("s1"))
        let view = try await AgentSessionsAPI(transport: transport, client: client).open(sessionId: "s1", db3: db3)
        XCTAssertEqual(view.messages.count, 6)
        return view
    }

    private func message(_ id: String, seq: Double, turnId: String, author: String) -> (String, [String: JSONValue]) {
        ("Message", ["id": .string(id), "seq": .number(seq), "turnId": .string(turnId), "authorKind": .string(author),
                     "createdAt": .string(Self.created)])
    }

    private func call(
        _ id: String, messageId: String, seq: Double, turnId: String, tool: String, state: String, input: String,
        number: Double?
    ) -> (String, [String: JSONValue]) {
        var row: [String: JSONValue] = [
            "id": .string(id), "messageId": .string(messageId), "seq": .number(seq), "turnId": .string(turnId),
            "state": .string(state), "toolName": .string(tool), "input": .string(input), "createdAt": .string(Self.created),
        ]
        if let number { row["callNumber"] = .number(number) }
        if state == "output-available" { row["output"] = .string(#"{"delivered":true}"#) }
        if state == "output-error" {
            row["errorCode"] = .string("AGENT_PRESENTATION_REFERENCE_INVALID")
            row["errorText"] = .string("show: 9")
        }
        return ("ToolCall", row)
    }

    private func seed(_ db3: SessionDb3) throws {
        try db3.write([
            // An earlier turn whose call was written before numbering.
            message("m0", seq: 1, turnId: "t0", author: "user"),
            message("m0a", seq: 2, turnId: "t0", author: "agent"),
            call("old", messageId: "m0a", seq: 3, turnId: "t0", tool: "lookup", state: "output-available",
                 input: #"{"q":"old"}"#, number: nil),
            // The presenting turn: lookup (1), a refused presentation (2), then the presentation (3).
            message("m1", seq: 4, turnId: "t1", author: "user"),
            message("m2", seq: 5, turnId: "t1", author: "agent"),
            call("lookup", messageId: "m2", seq: 6, turnId: "t1", tool: "lookup", state: "output-available",
                 input: #"{"q":"rent"}"#, number: 1),
            call("refused", messageId: "m2", seq: 7, turnId: "t1", tool: "present", state: "output-error",
                 input: #"{"show":[9]}"#, number: 2),
            message("m3", seq: 8, turnId: "t1", author: "agent"),
            call("present", messageId: "m3", seq: 9, turnId: "t1", tool: "present", state: "output-available",
                 input: #"{"show":[1],"suggestions":["Compare last year"]}"#, number: 3),
            message("m4", seq: 10, turnId: "t2", author: "user"),
        ])
    }

    private func synced(_ view: AgentSessionView, _ id: String) throws -> AgentSessionSyncedMessage {
        try XCTUnwrap(view.syncedMessages.first { $0.messageId == id }, "message \(id) in the window")
    }

    func testAPresentationDecodesThroughTheGeneratedEnumAndResolvesItsReference() async throws {
        let view = try await open("decodes")
        let presentations = view.presentations(of: try synced(view, "m3"), names: AdvisorAgent.presentationNames)
        XCTAssertEqual(presentations.map(\.name), ["present"])
        let presentation = try XCTUnwrap(presentations.first)
        XCTAssertEqual(presentation.part.id, "present")
        XCTAssertEqual(presentation.input["show"], .array([.number(1)]))

        guard case let .present(input) = try XCTUnwrap(AdvisorAgentPresentation(presentation)) else {
            return XCTFail("expected the present case")
        }
        XCTAssertEqual(input.show, [1])
        XCTAssertEqual(input.suggestions, ["Compare last year"])

        let referenced = try XCTUnwrap(presentation.call(input.show[0]))
        XCTAssertEqual(referenced.id, "lookup")
        XCTAssertEqual(referenced.toolName, "lookup")
        // A number of the turn that is not a result still resolves to its call;
        // a number the turn never gave resolves to nothing.
        XCTAssertEqual(presentation.call(2)?.state, .outputError)
        XCTAssertNil(presentation.call(9))
        await view.close()
    }

    func testARefusedPresentationAUserMessageAndAnotherNameYieldNone() async throws {
        let view = try await open("none")
        // The message holding the lookup and the refused presentation.
        XCTAssertEqual(view.presentations(of: try synced(view, "m2"), names: ["present"]), [])
        XCTAssertEqual(view.presentations(of: try synced(view, "m1"), names: ["present"]), [])
        XCTAssertEqual(view.presentations(of: try synced(view, "m3"), names: ["chips"]), [])
        await view.close()
    }

    func testANumberNeverResolvesAcrossTurnsOrToAnUnnumberedRow() async throws {
        let view = try await open("turns")
        let presentation = try XCTUnwrap(
            view.presentations(of: try synced(view, "m3"), names: AdvisorAgent.presentationNames).first
        )
        // The earlier turn's call carries no number, and is another turn's.
        XCTAssertFalse([1, 2, 3].compactMap { presentation.call($0)?.id }.contains("old"))
        await view.close()
    }

    func testTheGeneratedEnumRefusesAnotherNameAndAnInputItsTypeDoesNotDecode() throws {
        let message = try XCTUnwrap(AgentSessionMessageRecord(row: [
            "id": .string("m"), "seq": .number(1), "turnId": .string("t"), "authorKind": .string("agent"),
            "createdAt": .string(Self.created),
        ]))
        let part = { (tool: String, input: String) -> AgentSessionViewPart in
            .toolCall(AgentSessionToolCallRecord(row: [
                "id": .string("p"), "messageId": .string("m"), "seq": .number(2), "turnId": .string("t"),
                "state": .string("output-available"), "toolName": .string(tool), "input": .string(input),
                "callNumber": .number(1), "createdAt": .string(Self.created),
            ])!)
        }
        let other = AgentPresentation.collect(
            message: message, parts: [part("chips", #"{"show":[1]}"#)], turnParts: [], names: ["chips"]
        )
        XCTAssertNil(AdvisorAgentPresentation(try XCTUnwrap(other.first)))
        let malformed = AgentPresentation.collect(
            message: message, parts: [part("present", #"{"show":"one"}"#)], turnParts: [], names: ["present"]
        )
        XCTAssertNil(AdvisorAgentPresentation(try XCTUnwrap(malformed.first)))
        XCTAssertNil(ConciergeAgentPresentation(try XCTUnwrap(malformed.first)))
    }
}
