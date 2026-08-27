import XCTest
@testable import JsBaoClient

/// The `{ status: { status, skipReason }, run }` envelope the run-status
/// endpoint returns for an elided run: a terminal status, a reason, and no
/// error anywhere.
private func skippedEnvelope(runId: String) -> [String: Any] {
    [
        "status": ["status": "skipped", "skipReason": "LOCK_CONTENTION"],
        "run": [
            "runId": runId,
            "runKey": "rk-\(runId)",
            "status": "skipped",
            "skipReason": "LOCK_CONTENTION",
            "endedAt": "2026-08-12T19:04:21.881Z",
        ],
    ]
}

private func runningEnvelope(runId: String) -> [String: Any] {
    [
        "status": ["status": "running"],
        "run": ["runId": runId, "runKey": "rk-\(runId)", "status": "running"],
    ]
}

/// #2636 — a `skipped` run settles `workflows.waitFor` on BOTH paths.
///
/// `skipped` is a new value on an existing wire enum, so the cost of the Swift
/// client not recognising it is not a missing feature: the wait never matches
/// its terminal set and hangs until its own timeout (the #2011 bug shape). The
/// server-side parity test (`tests/unit/workflows/run-status-mirrors.test.ts`)
/// pins the vocabulary; these drive the behavior the vocabulary exists for,
/// through the same injected `Transport` + `EventEmitter` the rest of
/// `WorkflowWaitForTests` uses — no dev server, no network.
final class WorkflowSkippedWaitForHermeticTests: XCTestCase {

    /// Minimal stand-in for the client's HTTP transport: every
    /// `getStatusByRunId` call gets the same JSON graph back.
    private final class StubTransport: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var responder: @Sendable () -> Any = { [:] }

        func setResponder(_ fn: @escaping @Sendable () -> Any) {
            lock.withLock { responder = fn }
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            let value = lock.withLock { responder }()
            let data =
                (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                ?? Data()
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }

    private func makeApi(_ stub: StubTransport, _ emitter: EventEmitter) -> WorkflowsAPI {
        WorkflowsAPI(transport: stub, getConnectionId: { "conn-test" }, events: emitter)
    }

    /// Let a launched waitFor register its subscriptions and finish its
    /// subscribe-time reconcile before the test drives events.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - The reconcile poll

    func testSkippedRunSettlesFromTheReconcilePoll() async throws {
        let stub = StubTransport()
        stub.setResponder { skippedEnvelope(runId: "r-skip") }
        let api = makeApi(stub, EventEmitter())

        // Already elided when the wait starts: the subscribe-time reconcile is
        // the only thing that can settle it — no frame is ever emitted.
        let result = try await api.waitFor(
            runId: "r-skip",
            options: WaitForWorkflowOptions(timeout: 5)
        )

        XCTAssertEqual(result.status, "skipped")
        XCTAssertEqual(result.skipReason, "LOCK_CONTENTION")
        XCTAssertTrue(result.isTerminal)
        // An elided run is not a failure — that is the whole point of `ignore`.
        XCTAssertFalse(result.isFailure)
        XCTAssertNil(result.error)
        XCTAssertNil(result.output)
    }

    // MARK: - The workflowStatus frame

    func testSkippedFrameSettlesTheWait() async throws {
        let stub = StubTransport()
        // Still running at subscribe time, so the frame is what settles it.
        stub.setResponder { runningEnvelope(runId: "r-frame") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task {
            try await api.waitFor(runId: "r-frame", options: WaitForWorkflowOptions(timeout: 5))
        }
        await settle()
        emitter.emit(
            WorkflowStatusEvent(
                workflowKey: "clear-imports",
                workflowId: "",
                runKey: "rk-r-frame",
                runId: "r-frame",
                status: "skipped",
                skipReason: "LOCK_CONTENTION"
            )
        )

        let result = try await task.value
        XCTAssertEqual(result.status, "skipped")
        XCTAssertEqual(result.skipReason, "LOCK_CONTENTION")
        XCTAssertTrue(result.isTerminal)
        XCTAssertFalse(result.isFailure)
        XCTAssertNil(result.error)
    }

    // MARK: - The vocabulary the two paths share

    func testSkippedIsTerminalForBothReconcileHelpers() {
        XCTAssertTrue(WaitForWorkflowResult.terminalStatuses.contains("skipped"))

        // The direct reconcile map: a skipped status endpoint response is a
        // terminal result carrying its reason.
        let terminal = WorkflowsAPI.terminalFromReconcile(
            WorkflowStatusResult(
                status: "skipped",
                output: nil,
                error: nil,
                run: nil,
                skipReason: "LOCK_CONTENTION"
            )
        )
        XCTAssertEqual(terminal?.status, "skipped")
        XCTAssertEqual(terminal?.skipReason, "LOCK_CONTENTION")

        // The finalization window: a run row that already reads `skipped` while
        // the endpoint still reports an in-flight status settles as `skipped`
        // rather than waiting the window out. Decoded from the wire shape, so
        // this covers `skipReason` arriving on the run record too.
        let json = """
        {"status":{"status":"running"},
         "run":{"runId":"r1","runKey":"rk","status":"skipped",
                "skipReason":"LOCK_CONTENTION"}}
        """
        let decoded = try! JSONDecoder().decode(
            WorkflowStatusResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.run?.skipReason, "LOCK_CONTENTION")
        XCTAssertEqual(WorkflowsAPI.finalizingTerminalStatus(decoded), "skipped")
    }
}
