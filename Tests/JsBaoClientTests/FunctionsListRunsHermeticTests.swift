import XCTest
@testable import JsBaoClient

/// `client.functions.listRuns(options:)` and `listRunSteps(runId:)` — #4145
/// behaviors 15 and 16, server-free.
///
/// Every call runs over a `RecordingTransport`, so what is pinned is the exact
/// request each method builds (the same query, in the same order, with the
/// same encoding as the JS client) and how the routes' answers decode onto the
/// function-native types. The live half is `FunctionsLiveTests`.
final class FunctionsListRunsHermeticTests: XCTestCase {

    private func makeApi(json: String, status: Int = 200) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (FunctionsAPI(transport: transport), transport)
    }

    private static let emptyPage = #"{"items":[],"hasMore":false}"#

    /// One item as `GET functions/runs` sends it for a function run.
    private static let wireRun = """
    {"runId":"run-1","runKey":"run-1","instanceId":"inst-1","workflowId":null,
     "workflowKey":"fn-a","revisionId":null,"contextDocId":"doc-1","status":"completed",
     "runKind":"function","functionId":"fid-1","functionKey":"fn-a","runtime":"task",
     "executionPrincipal":"sys:app","parentFunctionKey":null,"parentRunId":null,"nestDepth":0,
     "errorMessage":null,"errorCode":null,"errorTitle":null,
     "startedAt":"2026-10-03T00:00:00.000Z","executionStartedAt":"2026-10-03T00:00:00.100Z",
     "queueDelayMs":100,"createCallDurationMs":12,"endedAt":"2026-10-03T00:00:01.000Z",
     "meta":{"source":"test"}}
    """

    // MARK: - Behavior 15: listRuns

    func testListRunsBuildsTheJsQueryInItsFixedOrder() async throws {
        let (api, transport) = makeApi(json: Self.emptyPage)
        _ = try await api.listRuns(options: FunctionRunListOptions(
            functionKey: "fn a",
            contextDocId: "doc/1",
            status: "running",
            limit: 10,
            cursor: #"{"_pk":"x#y"}"#,
            forward: true
        ))
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .get)
        XCTAssertEqual(
            call.path,
            "/functions/runs?functionKey=fn%20a&contextDocId=doc%2F1&status=running"
                + "&limit=10&cursor=%7B%22_pk%22%3A%22x%23y%22%7D&forward=true"
        )
    }

    func testListRunsOmitsAbsentOptionsAndAFalseForward() async throws {
        let (api, transport) = makeApi(json: Self.emptyPage)
        _ = try await api.listRuns()
        XCTAssertEqual(transport.lastCall?.path, "/functions/runs")
        _ = try await api.listRuns(options: .init(contextDocId: "doc-1", forward: false))
        XCTAssertEqual(transport.lastCall?.path, "/functions/runs?contextDocId=doc-1")
    }

    func testListRunsDecodesAPageOfFunctionRuns() async throws {
        let (api, _) = makeApi(json: """
        {"items":[\(Self.wireRun)],"hasMore":true,"nextCursor":"c1","scanned":7}
        """)
        let page = try await api.listRuns()
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "c1")
        XCTAssertEqual(page.scanned, 7)
        let run: FunctionRunInfo = try XCTUnwrap(page.items.first)
        XCTAssertEqual(run.runId, "run-1")
        XCTAssertEqual(run.functionKey, "fn-a")
        XCTAssertEqual(run.functionId, "fid-1")
        XCTAssertEqual(run.contextDocId, "doc-1")
        XCTAssertEqual(run.status, "completed")
        XCTAssertEqual(run.nestDepth, 0)
        XCTAssertEqual(run.meta, ["source": "test"])
    }

    /// #3190 CR3190-104: the run block's `runtime` (`request` | `task`) is
    /// the discriminator that replaced `executionMode`, and it must reach a
    /// caller on the listing and on a status read alike. A block from a
    /// server that sends none decodes it as `nil`, never as a guess.
    func testListRunsAndStatusReadsKeepTheRuntime() async throws {
        let requestRun = Self.wireRun.replacingOccurrences(
            of: #""runtime":"task""#, with: #""runtime":"request""#)
        let (api, _) = makeApi(json: """
        {"items":[\(requestRun),\(Self.wireRun)],"hasMore":false}
        """)
        let page = try await api.listRuns()
        XCTAssertEqual(page.items.map(\.runtime), ["request", "task"])

        let status = try JSONDecoder().decode(
            FunctionRunStatus.self,
            from: Data(#"{"status":{"status":"completed"},"run":\#(requestRun)}"#.utf8))
        XCTAssertEqual(status.run?.runtime, "request")

        let withoutRuntime = Self.wireRun.replacingOccurrences(
            of: #""runtime":"task","#, with: "")
        let bare = try JSONDecoder().decode(FunctionRunInfo.self, from: Data(withoutRuntime.utf8))
        XCTAssertNil(bare.runtime)
    }

    func testHasMoreFollowsTheCursorWhenAbsentAndScannedIsOptional() async throws {
        let (withCursor, _) = makeApi(json: #"{"items":[],"nextCursor":"c2"}"#)
        let more = try await withCursor.listRuns()
        XCTAssertTrue(more.hasMore)
        XCTAssertEqual(more.nextCursor, "c2")
        XCTAssertNil(more.scanned)

        let (without, _) = makeApi(json: #"{"items":[]}"#)
        let done = try await without.listRuns()
        XCTAssertFalse(done.hasMore)
        XCTAssertNil(done.nextCursor)
        XCTAssertEqual(done.items, [])
    }

    /// Edge case: an item this client cannot decode costs that item, never
    /// the rest of the page.
    func testAnUndecodableItemKeepsTheRestOfThePage() async throws {
        let (api, _) = makeApi(json: """
        {"items":[{"runId":"bad","runKey":"bad","status":"completed","nestDepth":"2"},
                  \(Self.wireRun)],"hasMore":false}
        """)
        let page = try await api.listRuns()
        XCTAssertEqual(page.items.map(\.runId), ["run-1"])
    }

    // MARK: - Behavior 16: listRunSteps

    private static let wireStep = """
    {"stepRunId":"sr-1","runId":"run/1","stepIndex":0,"stepId":"one","stepKind":"function.step",
     "status":"completed","config":{"kind":"x"},"rawConfig":{"kind":"x"},"input":null,"output":1,
     "error":null,"errorDetails":null,"startedAt":"2026-10-03T00:00:00.000Z",
     "endedAt":"2026-10-03T00:00:00.010Z","durationMs":10,"inputTokens":null,
     "outputTokens":null,"totalTokens":null,"retryCount":0,"context":{"a":1},"templateWarnings":[]}
    """

    func testListRunStepsGetsTheEncodedStepsRouteAndDecodesTheSteps() async throws {
        let (api, transport) = makeApi(json: #"{"items":[\#(Self.wireStep)]}"#)
        let steps = try await api.listRunSteps(runId: "run/1")
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/functions/runs/run%2F1/steps")
        let step: FunctionStepRun = try XCTUnwrap(steps.items.first)
        XCTAssertEqual(step.stepRunId, "sr-1")
        XCTAssertEqual(step.runId, "run/1")
        XCTAssertEqual(step.stepIndex, 0)
        XCTAssertEqual(step.stepId, "one")
        XCTAssertEqual(step.stepKind, "function.step")
        XCTAssertEqual(step.status, "completed")
        XCTAssertEqual(step.output, 1)
        XCTAssertEqual(step.durationMs, 10)
        XCTAssertEqual(step.retryCount, 0)
    }

    func testARunWithNoStepsAnswersAnEmptyList() async throws {
        let (api, _) = makeApi(json: #"{"items":[]}"#)
        let steps = try await api.listRunSteps(runId: "run-1")
        XCTAssertEqual(steps.items, [])
    }

    func testANotFoundIsAFunctionWordedNotFound() async throws {
        let (api, _) = makeApi(json: #"{"error":"Run not found"}"#, status: 404)
        do {
            _ = try await api.listRunSteps(runId: "run-1")
            XCTFail("a 404 must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "Function run run-1 not found")
        }
    }

    func testAnEmptyRunIdIsInvalidBeforeAnyRequest() async throws {
        let (api, transport) = makeApi(json: #"{"items":[]}"#)
        do {
            _ = try await api.listRunSteps(runId: "")
            XCTFail("an empty runId must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.message, "runId is required for functions.listRunSteps")
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }
}
