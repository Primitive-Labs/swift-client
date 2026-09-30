import XCTest
@testable import JsBaoClient

/// `metrics.cost` on the Swift prompt result — #3626 behavior 16.
///
/// The Swift `ExecutePromptResult.Metrics` mirrors the JS one field for field,
/// and a decisions execution reports the price the provider charged. A decoder
/// that does not know the key drops the one number the decision to adopt a
/// decisions model turns on.
///
/// Hermetic: a recorded response body, decoded. No server, no credentials.
final class PromptMetricsCostHermeticTests: XCTestCase {
    private func decode(_ json: String) throws -> ExecutePromptResult {
        try JSONDecoder().decode(
            ExecutePromptResult.self, from: Data(json.utf8)
        )
    }

    /// A decisions execution, as the route answered it on 2026-09-23.
    func testDecodesCostFromADecisionsExecution() throws {
        let result = try decode(
            """
            {
              "success": true,
              "output": "{\\"category\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"gas-and-fuel\\",\\"probabilities\\":{\\"gas-and-fuel\\":1,\\"groceries\\":0},\\"confidence\\":1}}",
              "metrics": {
                "durationMs": 131,
                "inputTokens": 380,
                "outputTokens": 39,
                "totalTokens": 419,
                "cost": 0.00001596
              },
              "rawResponse": {},
              "configId": "01M37PF5YM4GPR8CZPZV3V8942"
            }
            """
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.metrics.cost, 0.00001596)
        XCTAssertEqual(result.metrics.inputTokens, 380)
        XCTAssertEqual(result.metrics.totalTokens, 419)
    }

    /// A chat execution reports no cost, and still decodes.
    func testChatExecutionWithoutCostStillDecodes() throws {
        let result = try decode(
            """
            {
              "success": true,
              "output": "OK",
              "metrics": {
                "durationMs": 812,
                "inputTokens": 12,
                "outputTokens": 2,
                "totalTokens": 14,
                "reasoningTokens": 0
              },
              "rawResponse": {},
              "configId": "cfg_1"
            }
            """
        )
        XCTAssertNil(result.metrics.cost)
        XCTAssertEqual(result.metrics.reasoningTokens, 0)
    }

    /// The memberwise initializer keeps `cost` optional, so a caller building
    /// a result in a test or a stub is unaffected.
    func testMetricsInitializerDefaultsCostToNil() {
        let metrics = ExecutePromptResult.Metrics(durationMs: 1)
        XCTAssertNil(metrics.cost)
        XCTAssertEqual(
            ExecutePromptResult.Metrics(durationMs: 1, cost: 0.5).cost, 0.5
        )
    }
}
