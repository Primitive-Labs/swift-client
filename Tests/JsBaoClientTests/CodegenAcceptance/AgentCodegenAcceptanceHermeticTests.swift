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
        XCTAssertEqual(AdvisorAgent.eventNames, ["applied"])
        XCTAssertEqual(ConciergeAgent.key, "concierge")
        XCTAssertEqual(ConciergeAgent.clientToolNames, [])
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
