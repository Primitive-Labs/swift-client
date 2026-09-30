import XCTest
@testable import JsBaoClient

/// An engine failure's CODE reaches Swift — #3564, project `server-functions`
/// phase 4.
///
/// The filing requires the codes to be part of the run error vocabulary the
/// clients already surface on `failure`. Swift's `failure` is built from
/// `status.error` alone, so the code has to ride IN that object — which is
/// exactly what #3449 reserved the key for ("keep the object open and put a
/// `code` in its own key rather than in `name`"). The spec pin holds the
/// object's `required` at `["message"]` and leaves it open, so this is a
/// purely additive server field.
///
/// The point of this file is that **no Swift code changed**: the decoder folds
/// every key besides `name` and `message` into `details`, so `code` arrives as
/// `failure.details["code"]` on its own. `WorkflowRun.errorCode` is
/// `String?` and decodes any value, so the run block carries it too.
///
/// Server-free throughout, and deliberately written over
/// `WorkflowStatusErrorHermeticTests.decodeStatusBytes(_:)` — the helper
/// D3449-005 hands a human for pasting a body a hosted twin logged.
final class WorkflowStatusErrorCodeHermeticTests: XCTestCase {

    /// The block the status route really sends for a task run the engine
    /// evicted: the engine's own `{name, message}` untouched, with the
    /// platform's classification beside them. The message is the engine's
    /// verbatim text — the code is NOT prefixed onto it (D3564-003).
    private static let engineEvicted = """
    {"status":{"status":"failed","output":null,
      "error":{"name":"Error",
               "message":"Connection closed: this Durable Object instance is no longer active",
               "code":"ENGINE_ISOLATE_EVICTED"}},
     "run":{"runId":"run-1","runKey":"rk-1","status":"failed",
            "errorCode":"ENGINE_ISOLATE_EVICTED",
            "errorMessage":"Connection closed: this Durable Object instance is no longer active"}}
    """

    /// The same block without a `code`: a DSL run, or a function run the
    /// platform did not classify. It must decode exactly as #3449's own
    /// fixture does.
    private static let noCode = """
    {"status":{"status":"failed","error":{"name":"WorkflowError","message":"step `charge` failed"}},
     "run":{"runId":"run-2","runKey":"rk-2","status":"failed"}}
    """

    private func makeApi(json: String) -> FunctionsAPI {
        let transport = RecordingTransport(status: 200, json: json)
        return FunctionsAPI(transport: transport)
    }

    // MARK: - Behavior 14 — the code arrives under `details`

    func testTheEngineCodeArrivesAsFailureDetailsCode() throws {
        let status = try WorkflowStatusErrorHermeticTests.decodeStatusBytes(Self.engineEvicted)

        XCTAssertEqual(status.status, "failed")
        let failure = try XCTUnwrap(status.failure, "the structured error is the point")
        // The engine's own two keys pass through untouched…
        XCTAssertEqual(failure.name, "Error")
        XCTAssertEqual(
            failure.message,
            "Connection closed: this Durable Object instance is no longer active"
        )
        // …and the platform's classification is the remaining key, which the
        // decoder folds into `details` with no client change at all.
        let details = try XCTUnwrap(failure.details?.objectValue)
        XCTAssertEqual(Set(details.keys), ["code"])
        XCTAssertEqual(details["code"]?.stringValue, "ENGINE_ISOLATE_EVICTED")
        // `error` keeps its `String?` type and stays the MESSAGE: the code is
        // not in the message's prefix for an engine failure, which is the one
        // thing the guide's `failure.message` paragraph has to say.
        XCTAssertEqual(status.error, failure.message)
        XCTAssertFalse(status.error?.hasPrefix("ENGINE_") == true)
    }

    func testTheRunBlockCarriesTheSameCode() async throws {
        let status = try await makeApi(json: Self.engineEvicted).getStatus(runId: "run-1")

        // #3565 — the FUNCTION surface lifts the wire's `code` out of the
        // remaining keys into its own field, which is where a caller reads it.
        XCTAssertEqual(status.error?.code, "ENGINE_ISOLATE_EVICTED")
        // `FunctionRunInfo.errorCode` is `String?` and decodes anything, so a
        // spelling the server adds still reaches a caller.
        XCTAssertEqual(status.run?.errorCode, "ENGINE_ISOLATE_EVICTED")
        XCTAssertEqual(status.run?.runId, "run-1")
    }

    func testWaitForResolvesWithTheCodeRatherThanThrowing() async throws {
        let settled = try await makeApi(json: Self.engineEvicted).waitFor(runId: "run-1")

        XCTAssertEqual(settled.status, "failed")
        XCTAssertTrue(settled.isFailure)
        XCTAssertEqual(settled.error?.code, "ENGINE_ISOLATE_EVICTED")
    }

    /// Every member of the family decodes the same way — the point of the
    /// prefix (D3564-001) is that a caller can branch on the FAMILY.
    func testEveryEngineCodeDecodesTheSameWay() throws {
        for code in [
            "ENGINE_ISOLATE_EVICTED",
            "ENGINE_CODE_UPDATED",
            "ENGINE_SLICE_DEADLINE",
            "ENGINE_STORAGE_ERROR",
            "ENGINE_INTERNAL_ERROR",
            "ENGINE_INSTANCE_LOST",
        ] {
            let json = """
            {"status":{"status":"failed","error":{"message":"boom","code":"\(code)"}},
             "run":{"runId":"run-e","runKey":"rk-e","status":"failed","errorCode":"\(code)"}}
            """
            let status = try WorkflowStatusErrorHermeticTests.decodeStatusBytes(json)
            XCTAssertEqual(
                status.failure?.details?.objectValue?["code"]?.stringValue, code, code
            )
            XCTAssertEqual(status.run?.errorCode, code, code)
            XCTAssertTrue(status.failure?.details?.objectValue?["code"]?.stringValue?
                .hasPrefix("ENGINE_") == true, code)
            // #3565 — and the FUNCTION type reads the same bytes into its own
            // `code`, so a caller on either surface can branch on the family.
            let asFunction =
                try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes(json)
            XCTAssertEqual(asFunction.error?.code, code, code)
            XCTAssertEqual(asFunction.run?.errorCode, code, code)
        }
    }

    // MARK: - A block with no code is unchanged

    func testABlockWithoutACodeDecodesExactlyAsBefore() async throws {
        let status = try await makeApi(json: Self.noCode).getStatus(runId: "run-2")

        XCTAssertEqual(status.status, "failed")
        // #3565 — one structured error, and the platform's `WorkflowError`
        // placeholder dropped: it is what the row-settled path writes when it
        // has only the message, so it says nothing about the function.
        XCTAssertEqual(
            status.error,
            FunctionRunError(name: nil, message: "step `charge` failed", code: nil, details: nil)
        )
        XCTAssertNil(status.error?.code, "no code on the wire means no code here")
        XCTAssertNil(status.error?.details, "no extra key means no details at all")
        XCTAssertNil(status.run?.errorCode)
    }
}
