import XCTest
@testable import JsBaoClient

/// Acceptance tests for the CLI-generated Swift AGENT codegen — #3798
/// behavior 19.
///
/// The committed `.agent.generated.swift` files under `GeneratedAgents/` are
/// emitted by `primitive functions codegen --lang swift` from the fixture
/// TOMLs in `cli/tests/fixtures/swift-agent-acceptance/prompts/` (a tree with
/// no `functions/`) and byte-locked to the emitter by
/// `cli/tests/unit/swift-codegen-agent-acceptance-golden-3798.test.ts`, so
/// compiling this target IS the proof the generated Swift builds under the
/// Swift 6 language mode. These tests pin that the types carry the JSON the
/// declaration describes.
final class AgentCodegenAcceptanceHermeticTests: XCTestCase {

    func testTheAgentKeyIsTheDeclaredOne() {
        XCTAssertEqual(AdvisorAgent.key, "advisor")
        XCTAssertEqual(AdvisorAgent.clientToolNames, ["propose_budget_change"])
        XCTAssertEqual(AdvisorAgent.presentationNames, ["present"])
        XCTAssertEqual(AdvisorAgent.eventNames, ["applied"])
        XCTAssertEqual(ConciergeAgent.key, "concierge")
        XCTAssertEqual(ConciergeAgent.clientToolNames, [])
        XCTAssertEqual(ConciergeAgent.presentationNames, [])
    }

    /// #4549 — a presentation row decodes through the generated enum, its
    /// struct carrying the input the model sent.
    func testAPresentationRowDecodesThroughTheGeneratedEnum() throws {
        let message = try XCTUnwrap(PrimitiveMessage(row: [
            "id": .string("m1"), "seq": .number(4), "turnId": .string("t1"), "authorKind": .string("agent"),
            "createdAt": .string("2026-10-14T12:00:00.000Z"),
        ]))
        let row: [String: JSONValue] = [
            "id": .string("p1"), "messageId": .string("m1"), "seq": .number(5), "kind": .string("tool_call"),
            "state": .string("output-available"), "toolCallId": .string("call_1"), "toolName": .string("present"),
            "input": .string(#"{"show":[1,2],"suggestions":["Compare last year"]}"#),
            "output": .string(#"{"delivered":true}"#), "callNumber": .number(3),
            "createdAt": .string("2026-10-14T12:00:00.000Z"),
        ]
        let part = try XCTUnwrap(PrimitivePart(row: row))
        let presentation = try XCTUnwrap(
            AgentPresentation.collect(message: message, parts: [part], turnParts: [part], names: AdvisorAgent.presentationNames).first
        )
        guard case let .present(input) = try XCTUnwrap(AdvisorAgentPresentation(presentation)) else {
            return XCTFail("expected the present case")
        }
        XCTAssertEqual(input, AdvisorPresentationPresent(show: [1, 2], suggestions: ["Compare last year"]))
        XCTAssertEqual(presentation.call(3)?.id, "p1")
    }

    /// The `scribe` presentation named `name` with `input`, read off one agent message.
    private func scribePresentation(_ name: String, input: String) throws -> AgentPresentation {
        let message = try XCTUnwrap(PrimitiveMessage(row: [
            "id": .string("m1"), "seq": .number(4), "turnId": .string("t1"), "authorKind": .string("agent"),
            "createdAt": .string("2026-10-14T12:00:00.000Z"),
        ]))
        let part = try XCTUnwrap(PrimitivePart(row: [
            "id": .string("p1"), "messageId": .string("m1"), "seq": .number(5), "kind": .string("tool_call"),
            "state": .string("output-available"), "toolCallId": .string("call_1"), "toolName": .string(name),
            "input": .string(input), "output": .string(#"{"delivered":true}"#), "callNumber": .number(2),
            "createdAt": .string("2026-10-14T12:00:00.000Z"),
        ]))
        return try XCTUnwrap(
            AgentPresentation.collect(message: message, parts: [part], turnParts: [part], names: ScribeAgent.presentationNames).first
        )
    }

    /// CSO-4549-002 — a presentation named `_` compiles as an escaped case and decodes.
    func testAPresentationNamedUnderscoreDecodes() throws {
        XCTAssertEqual(ScribeAgent.presentationNames, ["_", "note"])
        XCTAssertEqual(ScribeAgent.clientToolNames, [])
        let presentation = try scribePresentation("_", input: #"{"show":[1]}"#)
        guard case let .`_`(input) = try XCTUnwrap(ScribeAgentPresentation(presentation)) else {
            return XCTFail("expected the _ case")
        }
        XCTAssertEqual(input, ScribePresentation_(show: [1]))
    }

    /// CSO-4549-001 — a null input the schema admits is a presentation, not a failure.
    func testANullPresentationInputDecodesAsNil() throws {
        guard case let .note(note) = try XCTUnwrap(ScribeAgentPresentation(try scribePresentation("note", input: "null"))) else {
            return XCTFail("expected the note case")
        }
        XCTAssertNil(note)
        guard case let .note(text) = try XCTUnwrap(ScribeAgentPresentation(try scribePresentation("note", input: #""Due Friday""#))) else {
            return XCTFail("expected the note case")
        }
        XCTAssertEqual(text, "Due Friday")
        XCTAssertNil(ScribeAgentPresentation(try scribePresentation("note", input: "42")))
    }

    func testTheSessionVariablesRoundTrip() throws {
        let variables = AdvisorAgentVariables(householdId: "h1")
        let decoded = try JSONDecoder().decode(
            AdvisorAgentVariables.self, from: try JSONEncoder().encode(variables)
        )
        XCTAssertEqual(decoded, variables)
    }

    func testAClientToolCallDecodesAndItsAnswerEncodes() throws {
        let call = try JSONDecoder().decode(
            AdvisorToolProposeBudgetChangeInput.self,
            from: Data(#"{"category":"groceries","delta":-40.5}"#.utf8)
        )
        XCTAssertEqual(call.category, "groceries")
        XCTAssertEqual(call.delta, -40.5)

        let answer = AdvisorToolProposeBudgetChangeOutput(accepted: true)
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(answer))
        XCTAssertEqual((json as? [String: Any])?["accepted"] as? Bool, true)
    }

    func testAnEventPayloadRoundTrips() throws {
        let event = AdvisorEventApplied(callId: "call_01")
        let decoded = try JSONDecoder().decode(
            AdvisorEventApplied.self, from: try JSONEncoder().encode(event)
        )
        XCTAssertEqual(decoded, event)
    }
}
