import XCTest
@testable import JsBaoClient

/// Build the `{ status: <status obj>, run }` envelope the status endpoint
/// returns, matching `resolveRunStatus` in workflows-controller.ts.
///
/// #2348: `status.status` is the server's single canonical, already-reconciled
/// run status — one of `queued`, `running`, `apply_pending`, `apply_claimed`,
/// `completed`, `failed`, `terminated`, `missing`. Raw Cloudflare spellings
/// (`complete`, `errored`) are no longer produced, so tests use the canonical
/// vocabulary here.
private func statusEnvelope(
    status: String,
    output: Any? = nil,
    error: String? = nil,
    runId: String,
    runStatus: String? = nil,
    endedAt: String? = nil,
    errorMessage: String? = nil
) -> [String: Any] {
    var statusObj: [String: Any] = ["status": status]
    if let output { statusObj["output"] = output }
    if let error { statusObj["error"] = error }
    var run: [String: Any] = ["runId": runId, "runKey": "rk-\(runId)"]
    if let runStatus { run["status"] = runStatus }
    if let endedAt { run["endedAt"] = endedAt }
    if let errorMessage { run["errorMessage"] = errorMessage }
    return ["status": statusObj, "run": run]
}

/// Server-free tests for `workflows.waitFor` (#1975 / #1582 — port of JS #1443).
///
/// The bug: the Swift client's only workflow-completion surface was the single,
/// never-replayed `.workflowStatus` WS frame. Its recovery machinery
/// (`perRunWaiters` / `handleTerminalEvent` / `recheckPendingRuns`) was dead
/// code — `perRunWaiters` had no writer after `678d529e`, so a completion that
/// occurred while the socket was down (iOS backgrounding) was lost permanently.
///
/// These tests exercise the fix directly on `WorkflowsAPI`, driven through its
/// injected `Transport` (the runId-keyed reconcile fetch) and a real
/// `EventEmitter` (the `.workflowStatus` terminal frame and the `.status`
/// reconnect event) — no dev server, no network. That is the same dependency
/// injection `JsBaoClient` uses to construct `WorkflowsAPI`.
final class WorkflowWaitForTests: XCTestCase {

    /// Controllable stand-in for the client's HTTP transport. Every
    /// `getStatusByRunId` call routes through `execute`; the test swaps
    /// `responder` to model the run's server-side state changing over time
    /// (e.g. terminating while the socket is down).
    ///
    /// The responders still speak the loose `Any` JSON graph the test bodies
    /// build; `execute` serializes that graph into the response bytes the
    /// `Transport` protocol requires (#2367).
    private final class StubTransport: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var responder: (@Sendable (String, String, Any?) throws -> Any)?
        // Async variant, given the 1-based call index. When set it takes
        // precedence — lets a test hold a fetch in flight (e.g. to force the
        // reconcile-overlap race) and return different snapshots per call.
        private var asyncResponder: (@Sendable (String, String, Any?, Int) async throws -> Any)?
        private var _callCount = 0

        var callCount: Int { lock.withLock { _callCount } }

        func setResponder(_ r: @escaping @Sendable (String, String, Any?) throws -> Any) {
            lock.withLock { responder = r }
        }

        func setAsyncResponder(_ r: @escaping @Sendable (String, String, Any?, Int) async throws -> Any) {
            lock.withLock { asyncResponder = r }
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            let (idx, ar, r) = lock.withLock {
                _callCount += 1
                return (_callCount, asyncResponder, responder)
            }
            let parsedBody = body.flatMap {
                try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed)
            }
            do {
                let value: Any
                if let ar {
                    value = try await ar(method.rawValue, path, parsedBody, idx)
                } else if let r {
                    value = try r(method.rawValue, path, parsedBody)
                } else {
                    throw HttpError(status: 500, message: "no responder configured")
                }
                return Self.jsonResponse(status: 200, value: value)
            } catch let error as HttpError {
                // `Transport.execute` reports a non-2xx status instead of
                // throwing — the protocol extension is what turns it into an
                // `HttpError`. Mapping a responder's `HttpError` back into a
                // response keeps the real status-handling path under test.
                return Self.jsonResponse(
                    status: error.status,
                    value: ["error": error.message]
                )
            }
        }

        private static func jsonResponse(status: Int, value: Any) -> TransportResponse {
            let data =
                (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                ?? Data()
            return TransportResponse(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }

    /// One-shot async gate: a synchronous fetch responder can `await open()` to
    /// stay in flight until the test calls `unlock()`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        func unlock() { lock.withLock { isOpen = true } }
        func open() async {
            while true {
                if lock.withLock({ isOpen }) { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    private func makeApi(_ stub: StubTransport, _ emitter: EventEmitter) -> WorkflowsAPI {
        WorkflowsAPI(transport: stub, getConnectionId: { "conn-test" }, events: emitter)
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r1", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 5)) }
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r2", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r2", options: WaitForWorkflowOptions(timeout: 5)) }
        await settle()

        // The run terminated during the outage; the terminal frame was never
        // replayed. Only a reconcile can recover it.
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "completed", output: ["done": true], runId: "r2", runStatus: "completed", endedAt: "2026-07-23T00:00:00Z")
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r3", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let start = Date()
        do {
            _ = try await api.waitFor(runId: "r3", options: WaitForWorkflowOptions(timeout: 0.25))
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r4", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r4", options: WaitForWorkflowOptions(timeout: 5)) }
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r5", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r5", options: WaitForWorkflowOptions(timeout: 5)) }
        await settle()
        emitter.emit(wfEvent(runId: "r5", status: "failed", error: "boom"))

        let result = try await task.value
        XCTAssertEqual(result.status, "failed")
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.error, "boom")
    }

    func testTerminatedRunResolves() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r6", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r6", options: WaitForWorkflowOptions(timeout: 5)) }
        await settle()
        emitter.emit(wfEvent(runId: "r6", status: "terminated"))

        let result = try await task.value
        XCTAssertEqual(result.status, "terminated")
    }

    func testApplyRequiredFrameResolvesAsApplyPending() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r7", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "r7", options: WaitForWorkflowOptions(timeout: 5)) }
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
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "completed", output: ["x": "y"], runId: "r8", runStatus: "completed", endedAt: "2026-07-23T00:00:00Z")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "r8", options: WaitForWorkflowOptions(timeout: 5))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["x"]?.stringValue, "y")
    }

    // MARK: - endedAt no longer implies terminal (was #1388, removed by #2348)
    //
    // The client used to treat `run.endedAt` as a terminal signal on its own and
    // then guess WHICH terminal state it was from `run.errorMessage`. The server
    // now reconciles the run before responding and never reports a terminal run
    // as `running`, so both of those inferences are gone: a non-terminal status
    // stays non-terminal no matter what the run row carries.

    func testEndedAtSetWithNonTerminalStatusDoesNotSettle() async throws {
        let stub = StubTransport()
        // A non-terminal server status with endedAt set must NOT settle the wait
        // — the endedAt fallback was removed. The wait runs to its timeout.
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "running", runId: "r9", runStatus: "running", endedAt: "2026-07-23T00:00:00Z")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        do {
            _ = try await api.waitFor(runId: "r9", options: WaitForWorkflowOptions(timeout: 0.3))
            XCTFail("endedAt alone must not settle waitFor")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
    }

    func testEndedAtWithErrorMessageDoesNotInferFailed() async throws {
        let stub = StubTransport()
        // An errorMessage on the run row is not a terminal signal either — the
        // status is what decides, and it says `running`.
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "running", runId: "r10", runStatus: "running", endedAt: "2026-07-23T00:00:00Z", errorMessage: "kaboom")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        do {
            _ = try await api.waitFor(runId: "r10", options: WaitForWorkflowOptions(timeout: 0.3))
            XCTFail("an errorMessage must not be inferred as a terminal 'failed'")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
    }

    /// A server-declared `terminated` run settles as `terminated` — never
    /// collapsed to `completed` by the removed errorMessage-based inference
    /// (a terminated run carries no errorMessage).
    func testTerminatedRunFromReconcileResolvesAsTerminated() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "terminated", runId: "r9b", runStatus: "terminated", endedAt: "2026-07-23T00:00:00Z")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "r9b", options: WaitForWorkflowOptions(timeout: 5))
        XCTAssertEqual(result.status, "terminated", "a terminated run must not resolve as completed")
        XCTAssertTrue(result.isTerminal)
        XCTAssertFalse(result.isFailure)
    }

    // MARK: - NOT_FOUND rejects immediately

    func testUnknownRunRejectsWithNotFound() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in throw HttpError(status: 404, message: "Run not found") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        do {
            _ = try await api.waitFor(runId: "missing", options: WaitForWorkflowOptions(timeout: 5))
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "any", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let taskA = Task { try await api.waitFor(runId: "A", options: WaitForWorkflowOptions(timeout: 5)) }
        let taskB = Task { try await api.waitFor(runId: "B", options: WaitForWorkflowOptions(timeout: 5)) }
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "r11", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task {
            try await api.waitFor(runId: "r11", as: Payload.self, options: WaitForWorkflowOptions(timeout: 5))
        }
        await settle()
        emitter.emit(wfEvent(runId: "r11", status: "completed", output: ["answer": 7]))

        let result = try await task.value
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output, Payload(answer: 7))
    }

    // MARK: - Server status is passed through verbatim (#2348)
    //
    // The server now reconciles the run and returns ONE canonical status —
    // `queued`, `running`, `apply_pending`, `apply_claimed`, `completed`,
    // `failed`, `terminated`, `missing`. The client's own reconciliation is
    // gone: no raw-spelling mapper, no run-row terminal fallback, no
    // endedAt/errorMessage inference. `getStatus` and `getStatusByRunId` report
    // exactly what the wire said.

    func testGetStatusPassesCanonicalStatusThroughVerbatim() async throws {
        for canonical in [
            "queued", "running", "apply_pending", "apply_claimed",
            "completed", "failed", "terminated", "missing",
        ] {
            let stub = StubTransport()
            stub.setResponder { _, _, _ in statusEnvelope(status: canonical, runId: "n1", runStatus: canonical) }
            let emitter = EventEmitter()
            let api = makeApi(stub, emitter)

            let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
            XCTAssertEqual(result.status, canonical, "getStatus must report the server's status verbatim")
        }
    }

    /// The run row is no longer consulted at all: whatever `run.status` says, the
    /// reported status is the server's top-level `status`. (The server keeps the
    /// two in agreement; this pins that the client does not re-derive.)
    func testGetStatusIgnoresRunRowStatus() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "running", error: "nope", runId: "n4", runStatus: "failed")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "running", "the run row must not override the server's status")
    }

    func testGetStatusReportsApplyPendingFromTheServer() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in statusEnvelope(status: "apply_pending", runId: "n3", runStatus: "apply_pending") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "apply_pending")
    }

    /// The reconcile fetch settles on the server's terminal status with no
    /// `endedAt` needed — the status alone is the terminal signal.
    func testReconcileSettlesOnServerTerminalStatusWithoutEndedAt() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "failed", error: "boom", runId: "n5", runStatus: "failed")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(runId: "n5", options: WaitForWorkflowOptions(timeout: 5))
        XCTAssertEqual(result.status, "failed")
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.error, "boom")
    }

    /// `queued` is a canonical non-terminal status — it must leave the wait
    /// pending rather than collapse to anything terminal.
    func testQueuedStatusLeavesTheWaitPending() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "queued", runId: "n4e", runStatus: "queued")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.getStatus(workflowKey: "wf", runKey: "rk")
        XCTAssertEqual(result.status, "queued")

        do {
            _ = try await api.waitFor(runId: "n4e", options: WaitForWorkflowOptions(timeout: 0.3))
            XCTFail("a queued run must not settle waitFor")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
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
        stub.setAsyncResponder { _, _, _, idx in
            if idx == 1 {
                // Hold the subscribe-time reconcile in flight until the test has
                // fired the reconnect, then return a pre-completion snapshot.
                await gate.open()
                return statusEnvelope(status: "running", runId: "rq", runStatus: "running")
            }
            // The queued reconnect reconcile sees the now-terminated run.
            return statusEnvelope(
                status: "completed", output: ["done": true],
                runId: "rq", runStatus: "completed", endedAt: "2026-07-23T00:00:00Z"
            )
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "rq", options: WaitForWorkflowOptions(timeout: 5)) }

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
    /// `timeout <= 0` disables the timer, which is the case that would
    /// otherwise leak the listeners indefinitely.
    func testCancellationThrowsAndTearsDownWithNoTimeout() async throws {
        let stub = StubTransport()
        // Never terminal — only cancellation can settle this wait.
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "rc", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        // timeout = 0 disables the timeout: without cancellation support the
        // listeners would live forever.
        let task = Task { try await api.waitFor(runId: "rc", options: WaitForWorkflowOptions(timeout: 0)) }
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
        stub.setResponder { _, _, _ in statusEnvelope(status: "running", runId: "rc2", runStatus: "running") }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let task = Task { try await api.waitFor(runId: "rc2", options: WaitForWorkflowOptions(timeout: 0)) }
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

    // MARK: - (g) The finalization window (#2348)

    /// The server reports the EXECUTION's status while a run whose row is
    /// already terminal finishes finalizing, so a status read never carries
    /// `completed` with a `nil` output. The terminal frame fires at the start of
    /// that window and is never replayed — a caller that missed it and
    /// reconciles inside the window has nothing left to wake it, and used to
    /// wait out the whole timeout.
    func testSettlesThroughTheFinalizationWindow() async throws {
        let stub = StubTransport()
        stub.setAsyncResponder { _, _, _, idx in
            if idx == 1 {
                // Inside the window: reported status is the execution's, while
                // the run record already carries the terminal status.
                return statusEnvelope(
                    status: "running",
                    runId: "fw1",
                    runStatus: "completed",
                    endedAt: "2026-08-05T00:00:00Z"
                )
            }
            return statusEnvelope(
                status: "completed",
                output: ["done": true],
                runId: "fw1",
                runStatus: "completed",
                endedAt: "2026-08-05T00:00:00Z"
            )
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(
            runId: "fw1",
            options: WaitForWorkflowOptions(timeout: 20)
        )
        XCTAssertEqual(result.status, "completed")
        // Settled with the real output, not an empty terminal read off the row.
        XCTAssertEqual(result.output?["done"]?.boolValue, true)
        XCTAssertGreaterThanOrEqual(stub.callCount, 2, "it took a re-check to get there")
    }

    /// A transient failure on a re-check inside the window must not abandon the
    /// re-check. The caller swallows anything that isn't `.notFound` and leaves
    /// its loop, and inside the window nothing else would wake the wait — so a
    /// single failed GET used to re-open the full-timeout hang.
    func testTransientFailureInsideTheWindowKeepsRechecking() async throws {
        let stub = StubTransport()
        stub.setAsyncResponder { _, _, _, idx in
            if idx == 1 {
                return statusEnvelope(
                    status: "running",
                    runId: "fw4",
                    runStatus: "completed",
                    endedAt: "2026-08-05T00:00:00Z"
                )
            }
            if idx == 2 {
                // The first re-check fails transiently.
                throw HttpError(status: 503, message: "service unavailable")
            }
            return statusEnvelope(
                status: "completed",
                output: ["done": true],
                runId: "fw4",
                runStatus: "completed",
                endedAt: "2026-08-05T00:00:00Z"
            )
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let result = try await api.waitFor(
            runId: "fw4",
            options: WaitForWorkflowOptions(timeout: 20)
        )
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["done"]?.boolValue, true)
        XCTAssertGreaterThanOrEqual(stub.callCount, 3, "the failed re-check must be retried")
    }

    /// A `.notFound` on a re-check still propagates — only transient errors are
    /// retried inside the window.
    func testNotFoundOnARecheckStillPropagates() async throws {
        let stub = StubTransport()
        stub.setAsyncResponder { _, _, _, idx in
            if idx == 1 {
                return statusEnvelope(
                    status: "running",
                    runId: "fw5",
                    runStatus: "completed",
                    endedAt: "2026-08-05T00:00:00Z"
                )
            }
            throw HttpError(status: 404, message: "not found")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        do {
            _ = try await api.waitFor(
                runId: "fw5",
                options: WaitForWorkflowOptions(timeout: 20)
            )
            XCTFail("expected .notFound")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    /// A contradictory row (in-flight record status with `endedAt` set) is NOT
    /// the finalization window and must not settle the wait — that inference is
    /// the #2119 guess this client no longer makes.
    func testEndedAtAloneDoesNotSettleTheWait() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in
            statusEnvelope(
                status: "running",
                runId: "fw2",
                runStatus: "running",
                endedAt: "2026-08-05T00:00:00Z"
            )
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        do {
            _ = try await api.waitFor(
                runId: "fw2",
                options: WaitForWorkflowOptions(timeout: 0.4)
            )
            XCTFail("waitFor should have timed out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
    }

    /// `missing` is a settled status the server answers 200 for. Waiting for it
    /// to become terminal is waiting forever, so it throws `.notFound` — the way
    /// those rows' 404 used to. The CLI stops on `missing` too.
    func testMissingStatusThrowsNotFound() async throws {
        let stub = StubTransport()
        stub.setResponder { _, _, _ in
            statusEnvelope(status: "missing", runId: "fw3", runStatus: "missing")
        }
        let emitter = EventEmitter()
        let api = makeApi(stub, emitter)

        let start = Date()
        do {
            _ = try await api.waitFor(
                runId: "fw3",
                options: WaitForWorkflowOptions(timeout: 60)
            )
            XCTFail("expected .notFound")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "must not wait for the timeout")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(emitter.activeHandlerCount, 0)
    }
}
