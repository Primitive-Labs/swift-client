import XCTest
@testable import JsBaoClient

/// Server-free tests for `workflows.waitFor` (#1975 / #1582 — port of JS #1443).
///
/// The bug: the Swift client's only workflow-completion surface was the single,
/// never-replayed `.workflowStatus` WS frame. Its recovery machinery
/// (`perRunWaiters` / `handleTerminalEvent` / `recheckPendingRuns`) was dead
/// code — `perRunWaiters` had no writer after `678d529e`, so a completion that
/// occurred while the socket was down (iOS backgrounding) was lost permanently.
///
/// These tests exercise the fix directly on `WorkflowsAPI`, driven through its
/// injected `makeRequest` transport (the runId-keyed reconcile fetch) and a real
/// `EventEmitter` (the `.workflowStatus` terminal frame and the `.status`
/// reconnect event) — no dev server, no network. That is the same dependency
/// injection `JsBaoClient` uses to construct `WorkflowsAPI`.
final class WorkflowWaitForTests: XCTestCase {

    /// Controllable stand-in for the client's HTTP transport. Every
    /// `getStatusByRunId` call routes through `make`; the test swaps `responder`
    /// to model the run's server-side state changing over time (e.g. terminating
    /// while the socket is down).
    private final class StubTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var responder: (@Sendable (String, String, Any?) throws -> Any)?
        // Async variant, given the 1-based call index. When set it takes
        // precedence — lets a test hold a fetch in flight (e.g. to force the
        // reconcile-overlap race) and return different snapshots per call.
        private var asyncResponder: (@Sendable (String, String, Any?, Int) async throws -> Any)?
        private var _callCount = 0

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

        func setResponder(_ r: @escaping @Sendable (String, String, Any?) throws -> Any) {
            lock.lock(); responder = r; lock.unlock()
        }

        func setAsyncResponder(_ r: @escaping @Sendable (String, String, Any?, Int) async throws -> Any) {
            lock.lock(); asyncResponder = r; lock.unlock()
        }

        @Sendable
        func make(_ method: String, _ path: String, _ body: Any?) async throws -> Any {
            lock.lock(); _callCount += 1; let idx = _callCount; let ar = asyncResponder; let r = responder; lock.unlock()
            if let ar { return try await ar(method, path, body, idx) }
            guard let r else { throw HttpError(status: 500, message: "no responder configured") }
            return try r(method, path, body)
        }
    }

    /// One-shot async gate: a synchronous fetch responder can `await open()` to
    /// stay in flight until the test calls `unlock()`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        func unlock() { lock.lock(); isOpen = true; lock.unlock() }
        func open() async {
            while true {
                lock.lock(); let o = isOpen; lock.unlock()
                if o { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    /// Build the `{ status: <CF status obj>, run }` envelope the status endpoint
    /// returns, matching `resolveRunStatus` in workflows-controller.ts.
    private func statusEnvelope(
        cfStatus: String,
        output: Any? = nil,
        error: String? = nil,
        runId: String,
        runStatus: String? = nil,
        endedAt: String? = nil,
        errorMessage: String? = nil
    ) -> [String: Any] {
        var statusObj: [String: Any] = ["status": cfStatus]
        if let output { statusObj["output"] = output }
        if let error { statusObj["error"] = error }
        var run: [String: Any] = ["runId": runId, "runKey": "rk-\(runId)"]
        if let runStatus { run["status"] = runStatus }
        if let endedAt { run["endedAt"] = endedAt }
        if let errorMessage { run["errorMessage"] = errorMessage }
        return ["status": statusObj, "run": run]
    }

    private func makeApi(_ stub: StubTransport, _ emitter: EventEmitter) -> WorkflowsAPI {
        WorkflowsAPI(makeRequest: stub.make, getConnectionId: { "conn-test" }, logger: nil, events: emitter)
    }

    private func wfEvent(
        runId: String,
        status: String,
        output: Any? = nil,
        error: String? = nil,
        needsApply: Bool = false
    ) -> WorkflowStatusEvent {
        WorkflowStatusEvent(
            workflowKey: "wf",
            workflowId: "",
            runKey: "rk-\(runId)",
            runId: runId,
            status: status,
            output: output,
            error: error,
            needsApply: needsApply
        )
    }

    // Let a launched waitFor register its .workflowStatus/.status subscriptions
    // and run (and finish) its subscribe-time reconcile before the test drives
    // events.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - (a) Terminal frame while subscribed resolves the waiter

    func testTerminalFrameResolvesWhileConnected() async throws {
        let stub = StubTransport()
        // Not-yet-terminal at subscribe time, so the subscribe-time reconcile
        // keeps waiting and the frame is what resolves it.
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r1", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()
        emitter.emit(wfEvent(runId: "r1", status: "completed", output: ["answer": 42]))

        let result = try await task.value
        XCTAssertEqual(result.status, "completed")
        XCTAssertTrue(result.isTerminal)
        XCTAssertFalse(result.isFailure)
        XCTAssertEqual(result.output?["answer"]?.numberValue, 42)
    }

    // MARK: - (b) THE BUG: terminal reached while socket DOWN, recovered on reconnect

    /// Core iOS regression. No `.workflowStatus` frame is ever delivered — it
    /// fired while the socket was down. On reconnect the `.status` connected
    /// event drives a reconcile fetch that finds the now-terminal run and
    /// settles the waiter. On `main` this could not work: `perRunWaiters` had no
    /// writer, so nothing was ever registered to recover.
    func testReconnectReconcileRecoversCompletionMissedWhileOffline() async throws {
        let stub = StubTransport()
        // While "offline" the run is still executing as far as the last fetch saw.
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r2", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r2", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()

        // The run terminated during the outage; the terminal frame was never
        // replayed. Only a reconcile can recover it.
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "complete", output: ["done": true], runId: "r2", runStatus: "completed", endedAt: "2026-07-23T00:00:00Z")
        }
        // Socket comes back.
        emitter.emit(StatusChangedEvent(status: .connected))

        let result = try await task.value
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["done"]?.boolValue, true)
    }

    // MARK: - (c) Timeout backstop

    func testTimeoutFiresWhenNeitherFrameNorReconcileCompletes() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r3", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let start = Date()
        do {
            _ = try await api.waitFor(runId: "r3", options: WaitForWorkflowOptions(timeoutMs: 250))
            XCTFail("waitFor should have timed out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "timeout should fire near its 250ms budget, not hang")
    }

    // MARK: - (d) No regression: already-connected completion path (repeat of a,
    // asserting nothing else fires)

    func testNormalCompletionPathResolvesExactlyOnce() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r4", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r4", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()
        emitter.emit(wfEvent(runId: "r4", status: "completed", output: ["v": 1]))
        let result = try await task.value
        XCTAssertEqual(result.status, "completed")

        // A late reconnect after settling must be a harmless no-op (guarded
        // cleanup): it must not crash or double-resume.
        emitter.emit(StatusChangedEvent(status: .connected))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Failure / terminal-state variants (resolve, do not throw)

    func testFailedRunResolvesWithStatusAndError() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r5", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r5", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()
        emitter.emit(wfEvent(runId: "r5", status: "failed", error: "boom"))

        let result = try await task.value
        XCTAssertEqual(result.status, "failed")
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.error, "boom")
    }

    func testTerminatedRunResolves() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r6", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r6", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()
        emitter.emit(wfEvent(runId: "r6", status: "terminated"))

        let result = try await task.value
        XCTAssertEqual(result.status, "terminated")
    }

    func testApplyRequiredFrameResolvesAsApplyPending() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r7", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r7", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()
        // The server broadcasts status "completed" with needsApply true while the
        // run row is apply_pending.
        emitter.emit(wfEvent(runId: "r7", status: "completed", needsApply: true))

        let result = try await task.value
        XCTAssertEqual(result.status, "apply_pending")
        XCTAssertTrue(result.isTerminal)
    }

    // MARK: - Started-before-subscribed race (subscribe-time reconcile)

    func testResolvesFromSubscribeTimeReconcileWhenAlreadyTerminal() async throws {
        let stub = StubTransport()
        // Already terminal before waitFor even subscribes — no frame will come.
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "complete", output: ["x": "y"], runId: "r8", runStatus: "completed", endedAt: "2026-07-23T00:00:00Z")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "r8", options: WaitForWorkflowOptions(timeoutMs: 5_000))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["x"]?.stringValue, "y")
    }

    // MARK: - endedAt-only terminal (#1388)

    func testEndedAtSetWithNonTerminalStatusResolves() async throws {
        let stub = StubTransport()
        // status is still "running" but endedAt is set — stale-status bug (#1388).
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", runId: "r9", runStatus: "running", endedAt: "2026-07-23T00:00:00Z")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "r9", options: WaitForWorkflowOptions(timeoutMs: 5_000))
        // No errorMessage → completed.
        XCTAssertEqual(result.status, "completed")
    }

    func testEndedAtSetWithErrorMessageResolvesFailed() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", runId: "r10", runStatus: "running", endedAt: "2026-07-23T00:00:00Z", errorMessage: "kaboom")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "r10", options: WaitForWorkflowOptions(timeoutMs: 5_000))
        XCTAssertEqual(result.status, "failed")
    }

    // MARK: - NOT_FOUND rejects immediately

    func testUnknownRunRejectsWithNotFound() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in throw HttpError(status: 404, message: "Run not found") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        do {
            _ = try await api.waitFor(runId: "missing", options: WaitForWorkflowOptions(timeoutMs: 5_000))
            XCTFail("expected NOT_FOUND")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    // MARK: - Empty runId argument validation

    func testEmptyRunIdThrowsInvalidArgument() async throws {
        let stub = StubTransport()
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)
        do {
            _ = try await api.waitFor(runId: "")
            XCTFail("expected INVALID_ARGUMENT")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - Overlapping waiters for different runIds settle independently

    func testTwoWaitersForDifferentRunsSettleIndependently() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "any", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let taskA = Task { try await api.waitFor(runId: "A", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        let taskB = Task { try await api.waitFor(runId: "B", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }
        await settle()

        emitter.emit(wfEvent(runId: "A", status: "completed", output: ["who": "A"]))
        let resultA = try await taskA.value
        XCTAssertEqual(resultA.output?["who"]?.stringValue, "A")

        emitter.emit(wfEvent(runId: "B", status: "failed", error: "onlyB"))
        let resultB = try await taskB.value
        XCTAssertEqual(resultB.status, "failed")
        XCTAssertEqual(resultB.error, "onlyB")
    }

    // MARK: - Typed generic overload

    private struct Payload: Codable, Equatable { let answer: Int }

    func testTypedOverloadDecodesOutput() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "r11", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task {
            try await api.waitFor(runId: "r11", as: Payload.self, options: WaitForWorkflowOptions(timeoutMs: 5_000))
        }
        await settle()
        emitter.emit(wfEvent(runId: "r11", status: "completed", output: ["answer": 7]))

        let result = try await task.value
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output, Payload(answer: 7))
    }

    // MARK: - Shared status normalizer (used by getStatus + getStatusByRunId)

    func testGetStatusNormalizesCompleteToCompleted() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "complete", runId: "n1", runStatus: "completed") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "completed", "raw Cloudflare 'complete' must normalize to 'completed'")
    }

    func testGetStatusNormalizesErroredToFailed() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "errored", error: "nope", runId: "n2", runStatus: "failed") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "failed")
    }

    // MARK: - Terminal run-row status (#2011)
    //
    // The server responds `{ status: <raw CF status obj>, run }` — `status`
    // carries Cloudflare's spellings, `run.status` carries the mapped set
    // (`completed`/`failed`/`terminated`, plus the apply-flow states and the
    // legacy `error`). The `waitFor` port read the run row only for the
    // apply-flow states, so a terminal run row whose `endedAt` is unset
    // normalized to `running` and the wait ran to its timeout. Every test below
    // holds the CF field non-terminal so the run row is the only terminal
    // signal, and leaves `endedAt` unset so the #1388 endedAt path can't settle
    // it either.

    func testGetStatusNormalizesTerminalRunRowFailedToFailed() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", error: "nope", runId: "n4", runStatus: "failed")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "failed", "a terminal run row must normalize to its terminal status")
    }

    func testGetStatusNormalizesTerminalRunRowTerminatedToTerminated() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", runId: "n4b", runStatus: "terminated")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "terminated")
    }

    func testGetStatusNormalizesTerminalRunRowCompletedToCompleted() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", runId: "n4c", runStatus: "completed")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "completed")
    }

    // Legacy failure spelling: the removed `reconcileRun` had
    // `case "failed", "terminated", "error":` on the RUN ROW, so `error` is
    // tolerated on that field too.
    func testGetStatusNormalizesLegacyErrorRunRowToFailed() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", error: "nope", runId: "n4d", runStatus: "error")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "failed", "legacy 'error' spelling must normalize to 'failed'")
    }

    /// The hang #2011 describes, end to end: the reconcile fetch sees a terminal
    /// run row with no `endedAt`, and the only thing that can settle the wait is
    /// the normalizer reading `run.status`. Without the fix this runs the full
    /// 5s timeout and settles as `timeout`.
    func testReconcileSettlesOnTerminalRunRowWithoutEndedAt() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", error: "boom", runId: "n5", runStatus: "failed")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "n5", options: WaitForWorkflowOptions(timeoutMs: 5_000))
        XCTAssertEqual(result.status, "failed")
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.error, "boom")
    }

    func testReconcileSettlesOnLegacyErrorRunRowWithoutEndedAt() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "running", error: "boom", runId: "n5b", runStatus: "error")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "n5b", options: WaitForWorkflowOptions(timeoutMs: 5_000))
        XCTAssertEqual(result.status, "failed")
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.error, "boom")
    }

    /// A non-terminal run row must still leave the wait pending — the run-row
    /// fallback must not swallow the `running` case.
    func testNonTerminalRunRowStillNormalizesToRunning() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in
            statusEnvelope(cfStatus: "queued", runId: "n4e", runStatus: "running")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "running")
    }

    func testNormalizerPrefersApplyFlowStatusOverCloudflareComplete() async throws {
        let stub = StubTransport()
        // CF says complete, but the DB run row is apply_pending — prefer the DB.
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "complete", runId: "n3", runStatus: "apply_pending") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "apply_pending")
    }

    // MARK: - [P2] #1 regression: queued reconnect reconcile (overlap race)

    /// The subscribe-time reconcile is still in flight (and will return a
    /// PRE-completion snapshot) when a `.connected` reconnect fires. The run has
    /// since terminated, but its terminal frame was never replayed. Under the old
    /// "drop the reconcile if one is already in flight" guard, the reconnect
    /// reconcile was discarded and nothing else re-fetched, so `waitFor` hung to
    /// its timeout. The fix QUEUES the reconnect reconcile: when the in-flight
    /// fetch finishes without settling, exactly one more fetch runs and finds the
    /// terminal run.
    func testQueuedReconnectReconcileRunsAfterInFlightPreCompletionSnapshot() async throws {
        let stub = StubTransport()
        let gate = Gate()
        stub.setAsyncResponder { [self] _, _, _, idx in
            if idx == 1 {
                // Hold the subscribe-time reconcile in flight until the test has
                // fired the reconnect, then return a pre-completion snapshot.
                await gate.open()
                return statusEnvelope(cfStatus: "running", runId: "rq", runStatus: "running")
            }
            // The queued reconnect reconcile sees the now-terminated run.
            return statusEnvelope(
                cfStatus: "complete", output: ["done": true],
                runId: "rq", runStatus: "completed", endedAt: "2026-07-23T00:00:00Z"
            )
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "rq", options: WaitForWorkflowOptions(timeoutMs: 5_000)) }

        // Wait until the subscribe-time reconcile fetch is in flight.
        while stub.callCount < 1 { try? await Task.sleep(nanoseconds: 5_000_000) }
        // Fire the reconnect WHILE call #1 is still in flight → the overlap guard
        // must QUEUE this reconcile, not drop it.
        emitter.emit(StatusChangedEvent(status: .connected))
        // Let the queued flag settle, then release the in-flight fetch.
        try? await Task.sleep(nanoseconds: 40_000_000)
        gate.unlock()

        let result = try await task.value
        XCTAssertEqual(result.status, "completed", "queued reconnect reconcile must run and settle the waiter")
        XCTAssertEqual(result.output?["done"]?.boolValue, true)
        // Coalesced to exactly one extra fetch (the in-flight one + one re-run),
        // not an unbounded stack.
        XCTAssertEqual(stub.callCount, 2, "the queued reconcile should collapse to a single re-run")
    }

    // MARK: - [P2] #2 regression: caller cancellation is honored

    /// A cancelled awaiting Task must settle the wait promptly (throwing
    /// `CancellationError`) and tear down both subscriptions — even when
    /// `timeoutMs <= 0` disables the timer, which is the case that would
    /// otherwise leak the listeners indefinitely.
    func testCancellationThrowsAndTearsDownWithNoTimeout() async throws {
        let stub = StubTransport()
        // Never terminal — only cancellation can settle this wait.
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "rc", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        // timeoutMs = 0 disables the timeout: without cancellation support the
        // listeners would live forever.
        let task = Task { try await api.waitFor(runId: "rc", options: WaitForWorkflowOptions(timeoutMs: 0)) }
        await settle()
        // Both the .workflowStatus and .status listeners are registered.
        XCTAssertEqual(emitter.activeHandlerCount, 2, "waitFor should have two active subscriptions while waiting")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        // Subscriptions torn down — no leak.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(emitter.activeHandlerCount, 0, "cancellation must remove both subscriptions")
    }

    /// A caller cancelled before `waitFor` even subscribes returns promptly and
    /// registers nothing (the up-front `Task.isCancelled` check).
    func testCancellationBeforeSubscribeRegistersNothing() async throws {
        let stub = StubTransport()
        stub.setResponder { [self] _, _, _ in statusEnvelope(cfStatus: "running", runId: "rc2", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "rc2", options: WaitForWorkflowOptions(timeoutMs: 0)) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            // Cancellation could also surface after subscribe on some schedules;
            // either way it must not hang or leak.
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(emitter.activeHandlerCount, 0, "a cancelled-before-subscribe caller must leave no subscriptions")
    }
}
