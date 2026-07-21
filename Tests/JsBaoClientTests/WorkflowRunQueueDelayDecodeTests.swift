import XCTest
@testable import JsBaoClient

/// Pure-decode coverage for the #1367 scheduling-latency fields on
/// `WorkflowRunInfo`. The server run serializers (admin `serializeWorkflowRun`,
/// app `serializeRun` / `listRuns`) now emit `executionStartedAt`,
/// `queueDelayMs`, and `createCallDurationMs`. These tests pin that the Swift
/// decoder surfaces them when present, and that their absence leaves them `nil`
/// (so pre-existing run fixtures without the fields still decode).
final class WorkflowRunQueueDelayDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> WorkflowRunInfo {
        try JSONDecoder().decode(WorkflowRunInfo.self, from: Data(json.utf8))
    }

    /// All three #1367 fields present → decoded onto the struct.
    func testDecodesQueueDelayFieldsWhenPresent() throws {
        let run = try decode(#"""
        {
            "runId": "run_1",
            "runKey": "key_1",
            "status": "completed",
            "startedAt": "2026-07-14T00:00:00.000Z",
            "executionStartedAt": "2026-07-14T00:00:12.500Z",
            "queueDelayMs": 12500,
            "createCallDurationMs": 42,
            "endedAt": "2026-07-14T00:00:20.000Z"
        }
        """#)

        XCTAssertEqual(run.startedAt, "2026-07-14T00:00:00.000Z")
        XCTAssertEqual(run.executionStartedAt, "2026-07-14T00:00:12.500Z")
        XCTAssertEqual(run.queueDelayMs, 12500)
        XCTAssertEqual(run.createCallDurationMs, 42)
    }

    /// Still-queued run: server emits `executionStartedAt`/`queueDelayMs` as
    /// `null`. Nulls decode to `nil`, not a throw.
    func testDecodesNullQueueDelayFields() throws {
        let run = try decode(#"""
        {
            "runId": "run_2",
            "runKey": "key_2",
            "status": "running",
            "startedAt": "2026-07-14T00:00:00.000Z",
            "executionStartedAt": null,
            "queueDelayMs": null,
            "createCallDurationMs": null
        }
        """#)

        XCTAssertNil(run.executionStartedAt)
        XCTAssertNil(run.queueDelayMs)
        XCTAssertNil(run.createCallDurationMs)
    }

    /// Legacy fixture without the #1367 keys still decodes; new fields are
    /// `nil`. This is what keeps older run payloads valid.
    func testDecodesLegacyRunWithoutQueueDelayFields() throws {
        let run = try decode(#"""
        {
            "runId": "run_3",
            "runKey": "key_3",
            "status": "completed",
            "startedAt": "2026-07-14T00:00:00.000Z"
        }
        """#)

        XCTAssertEqual(run.runId, "run_3")
        XCTAssertNil(run.executionStartedAt)
        XCTAssertNil(run.queueDelayMs)
        XCTAssertNil(run.createCallDurationMs)
    }
}
