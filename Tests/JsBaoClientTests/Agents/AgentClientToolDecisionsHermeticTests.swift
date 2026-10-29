import Foundation
import XCTest
@testable import JsBaoClient

/// The decision rules of `view.handleClientTools` in the Swift client
/// (#4263, plan behavior 14; #4884 behavior 10's rule over call records):
/// which call a handler may run, how a failed answer is classified by error
/// class, an error's message as an answer, and what a handler's result
/// becomes. The same tables as the JS client's `agent-client-tools-4263.test.ts`,
/// fed decoded `ToolCall` rows, refusals parsed from recorded response bodies
/// and the client's own error values; no transport.
final class AgentClientToolDecisionsHermeticTests: XCTestCase {
    private static let createdAt = "2026-10-06T12:00:00.000Z"

    /// A `ToolCall` row of turn `t1`, decoded; its id is the call's.
    private func toolCall(_ fields: [String: JSONValue]) throws -> AgentSessionToolCallRecord {
        var row: [String: JSONValue] = [
            "id": "call-1", "messageId": "msg-1", "seq": 2, "turnId": "t1",
            "toolName": "pick", "input": "{\"question\":\"how many\"}",
            "createdAt": .string(Self.createdAt),
        ]
        for (key, value) in fields { row[key] = value }
        return try XCTUnwrap(AgentSessionToolCallRecord(row: row))
    }

    /// A refusal as the HTTP client reads it from the server's error body.
    private func refusal(_ code: String, _ message: String = "refused") -> HttpError {
        let body = #"{"error":"\#(message)","code":"\#(code)","status":409,"timestamp":"\#(Self.createdAt)"}"#
        return HttpError.fromBytes(status: 409, message: "HTTP 409", body: Data(body.utf8))
    }

    private let registered: Set<String> = ["pick", "sign"]

    // MARK: - eligibleCall (spec rule 3)

    func testTakesAnInputAvailableCallOfARegisteredToolWithItsIdsAndInput() throws {
        let call = AgentClientToolDecisions.eligibleCall(
            call: try toolCall(["state": "input-available"]), registered: registered
        )
        XCTAssertEqual(call, AgentClientToolDecisions.EligibleCall(
            callId: "call-1", toolName: "pick", input: ["question": "how many"],
            messageId: "msg-1", partId: "call-1", state: .inputAvailable
        ))
    }

    func testTakesAnApprovedCallOnly() throws {
        let approved = try toolCall(["state": "approval-responded", "approvalApproved": true])
        XCTAssertEqual(AgentClientToolDecisions.eligibleCall(call: approved, registered: registered)?.state, .approvalResponded)
        let denied = try toolCall(["state": "approval-responded", "approvalApproved": false])
        XCTAssertNil(AgentClientToolDecisions.eligibleCall(call: denied, registered: registered))
        let unsaid = try toolCall(["state": "approval-responded"])
        XCTAssertNil(AgentClientToolDecisions.eligibleCall(call: unsaid, registered: registered))
    }

    func testNeverTakesAWaitingTerminalStreamingOrUnknownState() throws {
        for state: JSONValue in [
            "input-streaming", "approval-requested", "output-available", "output-error", "output-denied", "dreaming",
        ] {
            XCTAssertNil(
                AgentClientToolDecisions.eligibleCall(call: try toolCall(["state": state]), registered: registered),
                "\(state)"
            )
        }
        var stateless = try toolCall(["state": "input-available"]).row
        stateless["state"] = nil
        XCTAssertNil(AgentSessionToolCallRecord(row: stateless), "a call with no state does not decode")
    }

    func testNeverTakesAnUnregisteredNameOrAnEmptyId() throws {
        for fields: [String: JSONValue] in [["toolName": "lookup"], ["toolName": ""], ["id": ""]] {
            var row = fields
            row["state"] = "input-available"
            XCTAssertNil(AgentClientToolDecisions.eligibleCall(call: try toolCall(row), registered: registered), "\(fields)")
        }
    }

    // MARK: - classifyAnswerFailure (spec rule 7)

    func testTheFourLostRaceCodesAreLost() {
        for code in ["AGENT_CALL_ANSWERED", "AGENT_TURN_STALE", "AGENT_CALL_NOT_FOUND", "AGENT_TURN_NOT_ALLOWED"] {
            XCTAssertEqual(AgentClientToolDecisions.classifyAnswerFailure(refusal(code)), .lost(code: code), code)
        }
    }

    func testAnyOtherServerCodeIsARefusalWithTheServersMessage() {
        for code in ["AGENT_ANSWER_INVALID", "AGENT_ANSWER_TOO_LARGE", "AGENT_ANSWER_STAGE"] {
            XCTAssertEqual(
                AgentClientToolDecisions.classifyAnswerFailure(refusal(code, "the server says \(code)")),
                .refused(code: code, message: "the server says \(code)"),
                code
            )
        }
    }

    func testEverythingElseIsATransportFailure() {
        // A proxy's HTML error page: no server code.
        let proxy = HttpError.fromBytes(status: 502, message: "Bad Gateway", body: Data("<html>bad gateway</html>".utf8))
        XCTAssertNil(proxy.serverCode)
        XCTAssertEqual(AgentClientToolDecisions.classifyAnswerFailure(proxy), .transport(message: "HTTP 502: Bad Gateway"))
        let offline = JsBaoError(code: .offline, message: "Client is offline")
        XCTAssertEqual(AgentClientToolDecisions.classifyAnswerFailure(offline), .transport(message: "Client is offline"))
        // Codes the client sets itself on a 2xx it could not read are no refusal.
        for sentinel in [HttpError.emptyBodyCode, HttpError.decodingFailedCode] {
            let local = HttpError(status: 200, message: "unreadable", serverCode: sentinel)
            guard case .transport = AgentClientToolDecisions.classifyAnswerFailure(local) else {
                return XCTFail("\(sentinel) is a transport failure")
            }
        }
        guard case .transport = AgentClientToolDecisions.classifyAnswerFailure(URLError(.notConnectedToInternet)) else {
            return XCTFail("a URLError is a transport failure")
        }
        guard case .transport = AgentClientToolDecisions.classifyAnswerFailure(CancellationError()) else {
            return XCTFail("a cancellation is a transport failure")
        }
    }

    // MARK: - errorMessage (spec rule 5)

    func testAnErrorsMessageIsCappedAndNeverEmpty() {
        XCTAssertEqual(AgentClientToolDecisions.errorMessage(of: JsBaoError(code: .invalidArgument, message: "no stock")), "no stock")
        let long = JsBaoError(code: .invalidArgument, message: String(repeating: "x", count: 5000))
        XCTAssertEqual(AgentClientToolDecisions.errorMessage(of: long), String(repeating: "x", count: 4096))
        XCTAssertEqual(AgentClientToolDecisions.errorMessage(of: JsBaoError(code: .invalidArgument, message: "")), "Client tool failed")
        struct Described: LocalizedError { var errorDescription: String? { "described" } }
        XCTAssertEqual(AgentClientToolDecisions.errorMessage(of: Described()), "described")
        struct Silent: LocalizedError { var errorDescription: String? { "" } }
        XCTAssertEqual(AgentClientToolDecisions.errorMessage(of: Silent()), "Client tool failed")
    }

    // MARK: - What a handler's result becomes (spec rule 5)

    private struct Question: Codable, Sendable { let question: String }
    private struct Count: Codable, Sendable { let count: Int }
    private struct Unencodable: Encodable, Sendable {
        struct Refused: Error {}
        func encode(to encoder: Encoder) throws { throw Refused() }
    }

    private func call(_ input: JSONValue) -> AgentClientToolCall<JSONValue> {
        AgentClientToolCall(
            sessionId: "s", turnId: "t", callId: "call-1", messageId: "msg-1", partId: "part-1",
            toolName: "pick", input: input
        )
    }

    func testAnUntypedHandlersResultIsSentAsGivenTheArtifactOmittedWhenAbsent() async throws {
        let handler = AgentClientToolHandler { call in
            AgentClientToolResult(output: ["echo": call.input], artifact: call.callId == "call-1" ? ["note": "x"] : nil)
        }
        let answer = try await handler.answer(call(["question": "how many"]))
        XCTAssertEqual(answer, .output(["echo": ["question": "how many"]], artifact: ["note": "x"]))
        let bare = AgentClientToolHandler { _ in AgentClientToolResult(output: ["count": 1]) }
        let bareAnswer = try await bare.answer(call(.null))
        XCTAssertEqual(bareAnswer, .output(["count": 1], artifact: nil))
    }

    func testATypedHandlerDecodesItsInputAndEncodesItsOutput() async throws {
        let handler = AgentClientToolHandler.typed { (call: AgentClientToolCall<Question>) in
            AgentClientToolResult(output: Count(count: call.input.question.count))
        }
        let typedAnswer = try await handler.answer(call(["question": "how many"]))
        XCTAssertEqual(typedAnswer, .output(["count": 8], artifact: nil))
    }

    func testAnUndecodableInputOrAFailingEncodableIsAHandlerError() async throws {
        let handler = AgentClientToolHandler.typed { (call: AgentClientToolCall<Question>) in
            AgentClientToolResult(output: Count(count: call.input.question.count))
        }
        do {
            _ = try await handler.answer(call(["topic": "rent"]))
            XCTFail("an input that does not decode throws")
        } catch is DecodingError {}
        let failing = AgentClientToolHandler.typed { (_: AgentClientToolCall<Question>) in
            AgentClientToolResult(output: Unencodable())
        }
        do {
            _ = try await failing.answer(call(["question": "how many"]))
            XCTFail("an output that does not encode throws")
        } catch {}
    }

    /// The whole answer is encoded before it leaves the handler, so a value
    /// the wire cannot carry is the call's error answer, not a failed request
    /// read as a transport failure and re-run on every evaluation.
    func testANonFiniteOutputOrArtifactIsAHandlerErrorInEitherForm() async throws {
        let untypedOutput = AgentClientToolHandler { _ in AgentClientToolResult(output: ["count": .number(.nan)]) }
        let untypedArtifact = AgentClientToolHandler { _ in
            AgentClientToolResult(output: ["count": 1], artifact: ["score": .number(.infinity)])
        }
        let typedArtifact = AgentClientToolHandler.typed { (_: AgentClientToolCall<Question>) in
            AgentClientToolResult(output: Count(count: 1), artifact: ["score": .number(-.infinity)])
        }
        for (label, handler) in [
            ("untyped output", untypedOutput), ("untyped artifact", untypedArtifact),
            ("typed artifact", typedArtifact),
        ] {
            do {
                _ = try await handler.answer(call(["question": "how many"]))
                XCTFail("a non-finite \(label) throws")
            } catch is EncodingError {}
        }
    }
}
