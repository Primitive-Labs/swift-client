import XCTest
@testable import JsBaoClient

/// Pure-decode coverage for the #2074 failure block on `WorkflowRunInfo`
/// (#2160 — Swift parity).
///
/// Every server run serializer now spreads `serializeRunFailure`
/// (`src/workflows/failed-step.ts`): the app `serializeRun` / `listRuns` /
/// `getRunRecord` serializers and the admin `serializeWorkflowRun`. So a run
/// payload always carries five failure keys — `errorMessage` (already
/// decoded), plus `errorTitle`, `failedStepId`, `failedStepKind` and
/// `failedStepErrorTitle` — each explicitly `null` when there is nothing to
/// name. These tests pin that the Swift decoder surfaces the four new ones,
/// tolerates explicit nulls, and leaves them `nil` on a payload that predates
/// the block (so existing run fixtures still decode).
final class WorkflowRunFailureBlockDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> WorkflowRunInfo {
        try JSONDecoder().decode(WorkflowRunInfo.self, from: Data(json.utf8))
    }

    // MARK: Behaviors 1 & 2 — the block decodes when present

    func testDecodesFailureBlockWhenPresent() throws {
        let run = try decode(#"""
        {
            "runId": "01KYA6T5W7EMMRY8Q4B9QBKQ66",
            "runKey": "nightly#2026-07-24",
            "status": "failed",
            "startedAt": "2026-07-24T14:00:05.000Z",
            "endedAt": "2026-07-24T14:05:25.000Z",
            "errorMessage": "EvaluationError: No such key: status",
            "errorTitle": "EvaluationError: No such key: status",
            "failedStepId": "send-decision",
            "failedStepKind": "switch",
            "failedStepErrorTitle": "EvaluationError: No such key: status"
        }
        """#)

        XCTAssertEqual(run.status, "failed")
        XCTAssertEqual(run.errorMessage, "EvaluationError: No such key: status")
        XCTAssertEqual(run.errorTitle, "EvaluationError: No such key: status")
        XCTAssertEqual(run.failedStepId, "send-decision")
        XCTAssertEqual(run.failedStepKind, "switch")
        XCTAssertEqual(run.failedStepErrorTitle, "EvaluationError: No such key: status")
    }

    /// `errorTitle` is the normalized form of `errorMessage` — ids, numbers,
    /// URLs and quoted literals replaced by placeholder tokens. The client
    /// does not derive it; it carries whatever the server sent, so the two
    /// differ on the wire and both must survive decode.
    func testDecodesErrorTitleDistinctFromErrorMessage() throws {
        let run = try decode(#"""
        {
            "runId": "run_norm",
            "runKey": "key_norm",
            "status": "failed",
            "errorMessage": "Record 01KYA6T5W7EMMRY8Q4B9QBKQ66 not found in \"orders\"",
            "errorTitle": "Record <id> not found in <str>",
            "failedStepId": "load-order",
            "failedStepKind": "database.query",
            "failedStepErrorTitle": "Record <id> not found in <str>"
        }
        """#)

        XCTAssertEqual(
            run.errorMessage,
            "Record 01KYA6T5W7EMMRY8Q4B9QBKQ66 not found in \"orders\""
        )
        XCTAssertEqual(run.errorTitle, "Record <id> not found in <str>")
        XCTAssertNotEqual(run.errorMessage, run.errorTitle)
    }

    // MARK: Behavior 3 — explicit nulls

    /// A run that did not fail: the server still sends all five keys, each
    /// explicitly `null`. Nulls decode to `nil`, not a throw.
    func testDecodesNullFailureBlock() throws {
        let run = try decode(#"""
        {
            "runId": "run_ok",
            "runKey": "key_ok",
            "status": "completed",
            "startedAt": "2026-07-24T14:00:05.000Z",
            "endedAt": "2026-07-24T14:00:09.000Z",
            "errorMessage": null,
            "errorTitle": null,
            "failedStepId": null,
            "failedStepKind": null,
            "failedStepErrorTitle": null
        }
        """#)

        XCTAssertEqual(run.status, "completed")
        XCTAssertNil(run.errorMessage)
        XCTAssertNil(run.errorTitle)
        XCTAssertNil(run.failedStepId)
        XCTAssertNil(run.failedStepKind)
        XCTAssertNil(run.failedStepErrorTitle)
    }

    // MARK: Behavior 4 — backward compatibility

    /// A run serialized before #2074 shipped (and every hand-written fixture)
    /// omits the four keys entirely. It must still decode, with the new
    /// properties `nil`.
    func testDecodesLegacyRunWithoutFailureBlock() throws {
        let run = try decode(#"""
        {
            "runId": "run_legacy",
            "runKey": "key_legacy",
            "status": "failed",
            "startedAt": "2026-05-01T00:00:00.000Z",
            "errorMessage": "boom"
        }
        """#)

        XCTAssertEqual(run.runId, "run_legacy")
        XCTAssertEqual(run.errorMessage, "boom")
        XCTAssertNil(run.errorTitle)
        XCTAssertNil(run.failedStepId)
        XCTAssertNil(run.failedStepKind)
        XCTAssertNil(run.failedStepErrorTitle)
    }

    // MARK: Behavior 5 — failed with no attributable step

    /// A launch-time abort, a run reclaimed after its executor died, or one
    /// whose output failed schema validation after every step completed: the
    /// run failed but holds no failed step result, so the three `failedStep*`
    /// keys are `null` while the message and its title are present.
    func testDecodesFailedRunWithNoAttributableStep() throws {
        let run = try decode(#"""
        {
            "runId": "run_no_step",
            "runKey": "key_no_step",
            "status": "failed",
            "errorMessage": "Workflow output failed schema validation",
            "errorTitle": "Workflow output failed schema validation",
            "failedStepId": null,
            "failedStepKind": null,
            "failedStepErrorTitle": null
        }
        """#)

        XCTAssertEqual(run.errorMessage, "Workflow output failed schema validation")
        XCTAssertEqual(run.errorTitle, "Workflow output failed schema validation")
        XCTAssertNil(run.failedStepId)
        XCTAssertNil(run.failedStepKind)
        XCTAssertNil(run.failedStepErrorTitle)
    }

    // MARK: Behavior 6 — the nested run envelopes

    /// `getStatus` / `terminate` return `WorkflowStatusResult`, which nests the
    /// persisted run row under `run`.
    func testDecodesFailureBlockInsideStatusEnvelope() throws {
        let result = try JSONDecoder().decode(WorkflowStatusResult.self, from: Data(#"""
        {
            "status": "failed",
            "error": "EvaluationError: No such key: status",
            "run": {
                "runId": "run_status",
                "runKey": "key_status",
                "status": "failed",
                "errorMessage": "EvaluationError: No such key: status",
                "errorTitle": "EvaluationError: No such key: status",
                "failedStepId": "send-decision",
                "failedStepKind": "switch",
                "failedStepErrorTitle": "EvaluationError: No such key: status"
            }
        }
        """#.utf8))

        XCTAssertEqual(result.run?.errorTitle, "EvaluationError: No such key: status")
        XCTAssertEqual(result.run?.failedStepId, "send-decision")
        XCTAssertEqual(result.run?.failedStepKind, "switch")
        XCTAssertEqual(
            result.run?.failedStepErrorTitle,
            "EvaluationError: No such key: status"
        )
    }

    /// `listRuns` returns `ListWorkflowRunsResult`, whose `items` are
    /// `WorkflowRunInfo` values — the triage surface the CLI's
    /// `runs failures` view is built on.
    func testDecodesFailureBlockInsideListRunsEnvelope() throws {
        let result = try JSONDecoder().decode(ListWorkflowRunsResult.self, from: Data(#"""
        {
            "items": [
                {
                    "runId": "run_a",
                    "runKey": "key_a",
                    "status": "failed",
                    "errorMessage": "Timed out after 30000ms",
                    "errorTitle": "Timed out after <num>ms",
                    "failedStepId": "call-model",
                    "failedStepKind": "llm",
                    "failedStepErrorTitle": "Timed out after <num>ms"
                },
                {
                    "runId": "run_b",
                    "runKey": "key_b",
                    "status": "completed",
                    "errorMessage": null,
                    "errorTitle": null,
                    "failedStepId": null,
                    "failedStepKind": null,
                    "failedStepErrorTitle": null
                }
            ],
            "cursor": null
        }
        """#.utf8))

        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].errorTitle, "Timed out after <num>ms")
        XCTAssertEqual(result.items[0].failedStepId, "call-model")
        XCTAssertEqual(result.items[0].failedStepKind, "llm")
        XCTAssertEqual(result.items[0].failedStepErrorTitle, "Timed out after <num>ms")
        XCTAssertNil(result.items[1].errorTitle)
        XCTAssertNil(result.items[1].failedStepId)
    }

    // MARK: Edge case a — the synthetic setup step

    /// A durable run that aborted during setup, before any author-defined step
    /// ran, records the synthetic `__setup__` / `setup` pair. It is a plain
    /// string on the wire and must pass through verbatim — nothing may reject
    /// a step id that is absent from the workflow definition.
    func testDecodesSyntheticSetupStepSentinel() throws {
        let run = try decode(#"""
        {
            "runId": "run_setup",
            "runKey": "key_setup",
            "status": "failed",
            "errorMessage": "Input failed schema validation: missing required field \"userId\"",
            "errorTitle": "Input failed schema validation: missing required field <str>",
            "failedStepId": "__setup__",
            "failedStepKind": "setup",
            "failedStepErrorTitle": "Input failed schema validation: missing required field <str>"
        }
        """#)

        XCTAssertEqual(run.failedStepId, "__setup__")
        XCTAssertEqual(run.failedStepKind, "setup")
    }

    // MARK: Edge case b — mixed presence

    /// The four keys decode independently: a payload with `errorTitle` and no
    /// `failedStep*` keys is valid.
    func testDecodesErrorTitleWithoutFailedStepKeys() throws {
        let run = try decode(#"""
        {
            "runId": "run_partial_a",
            "runKey": "key_partial_a",
            "status": "failed",
            "errorMessage": "aborted",
            "errorTitle": "aborted"
        }
        """#)

        XCTAssertEqual(run.errorTitle, "aborted")
        XCTAssertNil(run.failedStepId)
        XCTAssertNil(run.failedStepKind)
        XCTAssertNil(run.failedStepErrorTitle)
    }

    /// ...and the reverse: `failedStep*` present with no `errorTitle`.
    func testDecodesFailedStepKeysWithoutErrorTitle() throws {
        let run = try decode(#"""
        {
            "runId": "run_partial_b",
            "runKey": "key_partial_b",
            "status": "failed",
            "failedStepId": "load-order",
            "failedStepKind": "database.query",
            "failedStepErrorTitle": "Record <id> not found"
        }
        """#)

        XCTAssertNil(run.errorTitle)
        XCTAssertEqual(run.failedStepId, "load-order")
        XCTAssertEqual(run.failedStepKind, "database.query")
        XCTAssertEqual(run.failedStepErrorTitle, "Record <id> not found")
    }

    // MARK: Edge case c — empty strings are values, not absence

    /// `decodeIfPresent` must not coerce `""` to `nil`. The server maps empty
    /// to `null` before serializing, so an empty string on the wire means a
    /// different producer and should reach the caller unchanged.
    func testDecodesEmptyStringFailureValues() throws {
        let run = try decode(#"""
        {
            "runId": "run_empty",
            "runKey": "key_empty",
            "status": "failed",
            "errorMessage": "",
            "errorTitle": "",
            "failedStepId": "",
            "failedStepKind": "",
            "failedStepErrorTitle": ""
        }
        """#)

        XCTAssertEqual(run.errorTitle, "")
        XCTAssertEqual(run.failedStepId, "")
        XCTAssertEqual(run.failedStepKind, "")
        XCTAssertEqual(run.failedStepErrorTitle, "")
    }

    // MARK: Edge case d — conformances still hold

    /// `WorkflowRunInfo` stays `Equatable`, and the new properties take part in
    /// equality: two runs that differ only in a failure field are not equal,
    /// and identical payloads are.
    func testEquatableConformanceCoversFailureBlock() throws {
        let base = #"""
        {
            "runId": "run_eq",
            "runKey": "key_eq",
            "status": "failed",
            "errorMessage": "boom",
            "errorTitle": "boom",
            "failedStepId": "%@",
            "failedStepKind": "switch",
            "failedStepErrorTitle": "boom"
        }
        """#

        let a = try decode(base.replacingOccurrences(of: "%@", with: "step-one"))
        let sameAsA = try decode(base.replacingOccurrences(of: "%@", with: "step-one"))
        let b = try decode(base.replacingOccurrences(of: "%@", with: "step-two"))

        XCTAssertEqual(a, sameAsA)
        XCTAssertNotEqual(a, b)
    }

    /// The struct is `Sendable`; crossing an isolation boundary must stay
    /// legal after the new stored properties are added.
    func testSendableConformanceHolds() async throws {
        let run = try decode(#"""
        {
            "runId": "run_sendable",
            "runKey": "key_sendable",
            "status": "failed",
            "errorTitle": "boom",
            "failedStepId": "step-one",
            "failedStepKind": "switch",
            "failedStepErrorTitle": "boom"
        }
        """#)

        let echoed = await Task { run }.value
        XCTAssertEqual(echoed.failedStepId, "step-one")
    }
}
