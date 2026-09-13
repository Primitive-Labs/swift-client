import XCTest
@testable import JsBaoClient

/// The task run's `slice` block on the status envelope — #3388.
///
/// `GET /workflows/runs/{runId}/status` carries `slice` beside `status` and
/// `run` for a task run that has a record (#3381). The JS client publishes it
/// as `WorkflowStatusResult.slice?`; these pin the same block, field for
/// field, on the Swift result.
///
/// Server-free: every method runs over a `RecordingTransport`, so what is
/// asserted is the decode of exactly the bytes the route sends.
final class FunctionsSliceHermeticTests: XCTestCase {

    private func makeApi(json: String, status: Int = 200) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (FunctionsAPI(transport: transport, workflows: WorkflowsAPI(transport: transport)), transport)
    }

    private func makeWorkflows(json: String) -> WorkflowsAPI {
        WorkflowsAPI(transport: RecordingTransport(status: 200, json: json))
    }

    /// A settled task run, as the route answers it: the seven fields of the
    /// record, with the ones a never-refreshed slice leaves null left null.
    private static let settledTaskRun = """
    {"status":{"status":"completed","output":{"one":1}},
     "run":{"runId":"run-1","runKey":"rk-1","status":"completed"},
     "slice":{"sliceId":"slice-abc","startedAt":1757000000000,
              "ceilingAt":1757043200000,"settledAt":1757000004000,
              "settledStatus":"completed","lastRefreshAt":null,"refreshCount":0}}
    """

    /// A refreshed slice still running: no settlement yet, a refresh on record.
    private static let refreshedTaskRun = """
    {"status":{"status":"running"},
     "run":{"runId":"run-2","runKey":"rk-2","status":"running"},
     "slice":{"sliceId":"slice-def","startedAt":1757000000000,
              "ceilingAt":1757043200000,"settledAt":null,"settledStatus":null,
              "lastRefreshAt":1757000300000,"refreshCount":3}}
    """

    // MARK: - Behavior: the seven fields reach the caller

    func testGetStatusCarriesEverySliceFieldOfASettledTaskRun() async throws {
        let (api, transport) = makeApi(json: Self.settledTaskRun)

        let status = try await api.getStatus(runId: "run-1")

        XCTAssertEqual(transport.lastCall?.path, "/workflows/runs/run-1/status")
        XCTAssertEqual(status.status, "completed")
        let slice = try XCTUnwrap(status.slice, "a task run with a record carries the block")
        XCTAssertEqual(slice.sliceId, "slice-abc")
        XCTAssertEqual(slice.startedAt, 1_757_000_000_000)
        XCTAssertEqual(slice.ceilingAt, 1_757_043_200_000)
        XCTAssertEqual(slice.settledAt, 1_757_000_004_000)
        XCTAssertEqual(slice.settledStatus, "completed")
        XCTAssertNil(slice.lastRefreshAt)
        XCTAssertEqual(slice.refreshCount, 0)
    }

    /// The refresh count is what a caller reads to see the gateway refreshes
    /// a long task run took instead of yielding — the `REFRESHES` column of
    /// `primitive functions runs`, from Swift.
    func testGetStatusCarriesTheRefreshCountAndLastRefreshOfALiveSlice() async throws {
        let (api, _) = makeApi(json: Self.refreshedTaskRun)

        let status = try await api.getStatus(runId: "run-2")
        let slice = try XCTUnwrap(status.slice)

        XCTAssertEqual(slice.refreshCount, 3)
        XCTAssertEqual(slice.lastRefreshAt, 1_757_000_300_000)
        XCTAssertNil(slice.settledAt)
        XCTAssertNil(slice.settledStatus)
    }

    private struct One: Decodable, Sendable, Equatable { let one: Int }

    /// The typed overload is the same read with `output` bound: it must not
    /// drop the block the untyped one carries.
    func testTypedGetStatusForwardsTheSameSliceBlock() async throws {
        let (api, _) = makeApi(json: Self.settledTaskRun)

        let typed: WorkflowStatus<One> = try await api.getStatus(runId: "run-1")

        XCTAssertEqual(typed.output, One(one: 1))
        XCTAssertEqual(typed.slice?.sliceId, "slice-abc")
        XCTAssertEqual(typed.slice?.refreshCount, 0)
    }

    /// A function run IS a run row: the same block rides the workflow status
    /// routes the run can also be read through.
    func testWorkflowsGetStatusCarriesTheBlockTypedAndUntyped() async throws {
        let untyped = try await makeWorkflows(json: Self.settledTaskRun)
            .getStatus(workflowKey: "fn", runKey: "rk-1")
        XCTAssertEqual(untyped.slice?.sliceId, "slice-abc")

        let typed: WorkflowStatus<One> = try await makeWorkflows(json: Self.settledTaskRun)
            .getStatus(workflowKey: "fn", runKey: "rk-1")
        XCTAssertEqual(typed.slice, untyped.slice)
    }

    // MARK: - Edge cases

    /// The block is ADDITIVE: a request invocation's run and a DSL run carry
    /// no `slice` key, and that is a `nil` — not a decode failure and not an
    /// empty record.
    func testAStatusWithNoSliceKeyDecodesToNil() async throws {
        let (api, _) = makeApi(json: """
        {"status":{"status":"completed"},"run":{"runId":"run-3","runKey":"rk-3","status":"completed"}}
        """)

        let status = try await api.getStatus(runId: "run-3")

        XCTAssertEqual(status.status, "completed")
        XCTAssertNil(status.slice)
    }

    /// A block whose shape surprises the client must not turn a status read
    /// into a failure: the slice is observability, never the answer. Same
    /// reading the server takes, where an unreadable record is dropped rather
    /// than 500ing the route.
    func testAMalformedSliceBlockIsDroppedRatherThanFailingTheRead() async throws {
        for malformed in ["\"slice-abc\"", "[1,2]", "{\"refreshCount\":\"three\"}"] {
            let (api, _) = makeApi(json: """
            {"status":{"status":"completed"},
             "run":{"runId":"run-4","runKey":"rk-4","status":"completed"},
             "slice":\(malformed)}
            """)

            let status = try await api.getStatus(runId: "run-4")

            XCTAssertEqual(status.status, "completed", "slice \(malformed) must not break the read")
            XCTAssertNil(status.slice, "slice \(malformed) is not a record")
        }
    }

    /// A record whose `sliceId` reads but whose numbers do not is still a
    /// block the client cannot publish: a `refreshCount` reported as `0` or a
    /// missing `startedAt` would be telemetry the client invented. The read
    /// survives; the block does not.
    func testASliceWithAValidIdButMalformedNumbersIsDroppedWhole() async throws {
        let malformedFields = [
            #""refreshCount":"three""#,
            #""refreshCount":{"count":1}"#,
            #""startedAt":"soon""#,
            #""ceilingAt":[1757043200000]"#,
            #""settledAt":"1757000004000""#,
            #""lastRefreshAt":true"#,
        ]
        for field in malformedFields {
            let (api, _) = makeApi(json: """
            {"status":{"status":"completed"},
             "run":{"runId":"run-6","runKey":"rk-6","status":"completed"},
             "slice":{"sliceId":"slice-abc",\(field)}}
            """)

            let status = try await api.getStatus(runId: "run-6")

            XCTAssertEqual(status.status, "completed", "slice \(field) must not break the read")
            XCTAssertNil(status.slice, "slice \(field) is not a record the client can publish")
        }
    }

    /// The tolerance that stays: the count the server always sends may be
    /// absent or `null` on a payload that predates it, and that reads `0`
    /// without costing the caller the rest of the record.
    func testAnAbsentOrNullRefreshCountReadsZeroAndKeepsTheBlock() async throws {
        for count in ["", #","refreshCount":null"#] {
            let (api, _) = makeApi(json: """
            {"status":{"status":"running"},
             "run":{"runId":"run-7","runKey":"rk-7","status":"running"},
             "slice":{"sliceId":"slice-jkl","startedAt":1757000000000\(count)}}
            """)

            let status = try await api.getStatus(runId: "run-7")
            let slice = try XCTUnwrap(status.slice)

            XCTAssertEqual(slice.sliceId, "slice-jkl")
            XCTAssertEqual(slice.startedAt, 1_757_000_000_000)
            XCTAssertEqual(slice.refreshCount, 0)
        }
    }

    /// A slice opened but never settled sends `null` for four of the seven
    /// fields — `null` is `nil`, and the record is still a record.
    func testNullTimestampsDecodeToNilWithoutDroppingTheBlock() async throws {
        let (api, _) = makeApi(json: """
        {"status":{"status":"running"},
         "run":{"runId":"run-5","runKey":"rk-5","status":"running"},
         "slice":{"sliceId":"slice-ghi","startedAt":null,"ceilingAt":null,
                  "settledAt":null,"settledStatus":null,"lastRefreshAt":null,
                  "refreshCount":0}}
        """)

        let status = try await api.getStatus(runId: "run-5")
        let slice = try XCTUnwrap(status.slice)

        XCTAssertEqual(slice.sliceId, "slice-ghi")
        XCTAssertNil(slice.startedAt)
        XCTAssertNil(slice.ceilingAt)
        XCTAssertNil(slice.settledAt)
        XCTAssertNil(slice.settledStatus)
        XCTAssertNil(slice.lastRefreshAt)
        XCTAssertEqual(slice.refreshCount, 0)
    }
}
