import XCTest
@testable import JsBaoClient

/// The structured failure fields on the Swift prompt result — #3663, review
/// round 3.
///
/// `POST /prompts/:key/execute` answers a provider failure in the 200 arm,
/// because the run happened: `success: false` plus `error`. #3663 added the
/// two fields that say WHY without parsing the sentence — `upstreamStatus`,
/// the provider's own HTTP status, and `errorCode`, which names an upstream
/// timeout — and the JS `ExecutePromptResult` carries both. Swift's mirrored
/// it neither, so a Swift caller could not make the retry decision the fields
/// exist for.
///
/// Hermetic: recorded response bodies, decoded. No server, no credentials.
final class PromptFailureFields3663HermeticTests: XCTestCase {
    private func decode(_ json: String) throws -> ExecutePromptResult {
        try JSONDecoder().decode(
            ExecutePromptResult.self, from: Data(json.utf8)
        )
    }

    /// An upstream timeout carries BOTH fields: the status the provider
    /// answered and the code that names the timeout.
    func testUpstreamTimeoutCarriesStatusAndCode() throws {
        let result = try decode(
            """
            {
              "success": false,
              "output": "",
              "error": "The model provider answered HTTP 504 (Gateway Timeout)",
              "upstreamStatus": 504,
              "errorCode": "PROMPT_UPSTREAM_TIMEOUT",
              "metrics": { "durationMs": 125431 },
              "rawResponse": {},
              "configId": "01M37PF5YM4GPR8CZPZV3V8942"
            }
            """
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.upstreamStatus, 504)
        XCTAssertEqual(result.errorCode, "PROMPT_UPSTREAM_TIMEOUT")
    }

    /// A provider failure that is not a timeout carries the status and NO
    /// code — #3330's "refused shape versus failed call" discriminator, which
    /// a Swift caller reads the same way a JS one does.
    func testNonTimeoutProviderFailureCarriesStatusOnly() throws {
        let result = try decode(
            """
            {
              "success": false,
              "output": "",
              "error": "The model provider answered HTTP 429 (Too Many Requests)",
              "upstreamStatus": 429,
              "metrics": { "durationMs": 318 },
              "rawResponse": {},
              "configId": "cfg_1"
            }
            """
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.upstreamStatus, 429)
        XCTAssertNil(result.errorCode)
    }

    /// A successful run gained no key: both fields are absent, and the body a
    /// caller has always decoded still decodes.
    func testSuccessCarriesNeitherField() throws {
        let result = try decode(
            """
            {
              "success": true,
              "output": "OK",
              "metrics": {
                "durationMs": 812,
                "inputTokens": 12,
                "outputTokens": 2,
                "totalTokens": 14
              },
              "rawResponse": {},
              "configId": "cfg_1"
            }
            """
        )
        XCTAssertTrue(result.success)
        XCTAssertNil(result.upstreamStatus)
        XCTAssertNil(result.errorCode)
    }

    /// Both fields are optional in the memberwise initializer, so a caller
    /// building a result in a test or a stub is unaffected.
    func testInitializerDefaultsBothFieldsToNil() {
        let result = ExecutePromptResult(
            success: true,
            output: "OK",
            metrics: .init(durationMs: 1),
            configId: "cfg_1"
        )
        XCTAssertNil(result.upstreamStatus)
        XCTAssertNil(result.errorCode)
        let failed = ExecutePromptResult(
            success: false,
            output: "",
            error: "timed out",
            upstreamStatus: 408,
            errorCode: "PROMPT_UPSTREAM_TIMEOUT",
            metrics: .init(durationMs: 2),
            configId: "cfg_1"
        )
        XCTAssertEqual(failed.upstreamStatus, 408)
        XCTAssertEqual(failed.errorCode, "PROMPT_UPSTREAM_TIMEOUT")
    }
}
