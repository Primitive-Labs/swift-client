import XCTest
@testable import JsBaoClient

/// `view.presentations(of:names:)` over a local-only session document — #4549
/// behavior 17, the Swift half of `tests/unit/workflows/
/// agent-presentation-view-4549.test.ts`, over the same rows.
///
/// A turn whose agent called `lookup` (call 1) in its first round and the
/// presentation `present` (call 2, `show: [1]`) with its answer, a refused
/// presentation, a user message, and an earlier turn whose call carries no
/// number (a row written before numbering). Each presentation is decoded
/// through the generated acceptance enum `AdvisorAgentPresentation`.
final class AgentPresentationHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
    }

    private static let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
    private static let created = "2026-10-14T12:00:00.000Z"

    private struct Fixture {
        let client: JsBaoClient
        let view: AgentSessionView
        let documentId: String
    }

    /// A local-only session document holding the rows, and a view open over it.
    private func open(_ name: String) async throws -> Fixture {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-presentation-\(name)",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let created = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        client.registerModels(AgentSessionModels.schemas)
        _ = try await client.documents.open(documentId, options: Self.localOpen)
        let info = #"""
        {"sessionId":"s1","agentKey":"advisor","documentId":"\#(documentId)","ownerUserId":"u1",
         "createdAt":"2026-10-14T00:00:00.000Z","title":null,"scope":null,"lastActivityAt":null,
         "members":{"viewers":[],"participants":[]},"role":"owner","status":"idle","turn":null}
        """#
        let transport = RecordingTransport { _ in
            TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(info.utf8))
        }
        try seed(client, in: documentId)
        let view = try await AgentSessionsAPI(transport: transport, client: client).open(
            sessionId: "s1", options: OpenAgentSessionOptions(open: Self.localOpen)
        )
        try await eventually(description: "the window holds the rows") { view.messages.count == 6 }
        return Fixture(client: client, view: view, documentId: documentId)
    }

    private func message(_ client: JsBaoClient, in documentId: String, id: String, seq: Double, turnId: String, author: String) throws {
        try client.codegen.save(PrimitiveMessage.primitiveSchema, id: id, values: [
            "seq": .number(seq), "turnId": .string(turnId), "authorKind": .string(author), "createdAt": .date(Self.created),
        ], in: documentId)
    }

    private func call(
        _ client: JsBaoClient, in documentId: String, id: String, messageId: String, seq: Double,
        tool: String, state: String, input: String, number: Double?
    ) throws {
        var values: [String: PrimitiveValue] = [
            "messageId": .string(messageId), "seq": .number(seq), "kind": .string("tool_call"),
            "state": .string(state), "toolCallId": .string("call_\(id)"), "toolName": .string(tool),
            "input": .string(input), "createdAt": .date(Self.created),
        ]
        if let number { values["callNumber"] = .number(number) }
        if state == "output-available" { values["output"] = .string(#"{"delivered":true}"#) }
        if state == "output-error" {
            values["errorCode"] = .string("AGENT_PRESENTATION_REFERENCE_INVALID")
            values["errorText"] = .string("show: 9")
        }
        try client.codegen.save(PrimitivePart.primitiveSchema, id: id, values: values, in: documentId)
    }

    private func seed(_ client: JsBaoClient, in documentId: String) throws {
        // An earlier turn whose call was written before numbering.
        try message(client, in: documentId, id: "m0", seq: 1, turnId: "t0", author: "user")
        try message(client, in: documentId, id: "m0a", seq: 2, turnId: "t0", author: "agent")
        try call(client, in: documentId, id: "old", messageId: "m0a", seq: 3, tool: "lookup",
                 state: "output-available", input: #"{"q":"old"}"#, number: nil)
        // The presenting turn: lookup (1), a refused presentation (2), then the presentation (3).
        try message(client, in: documentId, id: "m1", seq: 4, turnId: "t1", author: "user")
        try message(client, in: documentId, id: "m2", seq: 5, turnId: "t1", author: "agent")
        try call(client, in: documentId, id: "lookup", messageId: "m2", seq: 6, tool: "lookup",
                 state: "output-available", input: #"{"q":"rent"}"#, number: 1)
        try call(client, in: documentId, id: "refused", messageId: "m2", seq: 7, tool: "present",
                 state: "output-error", input: #"{"show":[9]}"#, number: 2)
        try message(client, in: documentId, id: "m3", seq: 8, turnId: "t1", author: "agent")
        try call(client, in: documentId, id: "present", messageId: "m3", seq: 9, tool: "present",
                 state: "output-available", input: #"{"show":[1],"suggestions":["Compare last year"]}"#, number: 3)
        try message(client, in: documentId, id: "m4", seq: 10, turnId: "t2", author: "user")
    }

    private func synced(_ view: AgentSessionView, _ id: String) throws -> PrimitiveMessage {
        let found = view.messages.compactMap { entry -> PrimitiveMessage? in
            if case let .synced(m) = entry, m.messageId == id { return m.message }
            return nil
        }.first
        return try XCTUnwrap(found, "message \(id) in the window")
    }

    func testAPresentationDecodesThroughTheGeneratedEnumAndResolvesItsReference() async throws {
        let f = try await open("decodes")
        let message = try synced(f.view, "m3")
        let presentations = f.view.presentations(of: message, names: AdvisorAgent.presentationNames)
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
        // A number of the turn that is not a result still resolves to its part;
        // a number the turn never gave resolves to nothing.
        XCTAssertEqual(presentation.call(2)?.state, "output-error")
        XCTAssertNil(presentation.call(9))
        await f.view.close()
    }

    func testARefusedPresentationAUserMessageAndAnotherNameYieldNone() async throws {
        let f = try await open("none")
        // The message holding the lookup and the refused presentation.
        XCTAssertEqual(f.view.presentations(of: try synced(f.view, "m2"), names: ["present"]), [])
        XCTAssertEqual(f.view.presentations(of: try synced(f.view, "m1"), names: ["present"]), [])
        XCTAssertEqual(f.view.presentations(of: try synced(f.view, "m3"), names: ["chips"]), [])
        await f.view.close()
    }

    func testANumberNeverResolvesAcrossTurnsOrToAnUnnumberedRow() async throws {
        let f = try await open("turns")
        let presentation = try XCTUnwrap(
            f.view.presentations(of: try synced(f.view, "m3"), names: AdvisorAgent.presentationNames).first
        )
        // The earlier turn's call carries no number, and is another turn's.
        XCTAssertFalse([1, 2, 3].compactMap { presentation.call($0)?.id }.contains("old"))
        await f.view.close()
    }

    func testTheGeneratedEnumRefusesAnotherNameAndAnInputItsTypeDoesNotDecode() throws {
        let message = try XCTUnwrap(PrimitiveMessage(row: [
            "id": .string("m"), "seq": .number(1), "turnId": .string("t"), "authorKind": .string("agent"),
            "createdAt": .string(Self.created),
        ]))
        let part = { (tool: String, input: String) in
            PrimitivePart(row: [
                "id": .string("p"), "messageId": .string("m"), "seq": .number(2), "kind": .string("tool_call"),
                "state": .string("output-available"), "toolName": .string(tool), "input": .string(input),
                "callNumber": .number(1), "createdAt": .string(Self.created),
            ])!
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
