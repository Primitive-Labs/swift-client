import XCTest
@testable import JsBaoClient

/// `client.functions.waitFor` — #3278 behaviors 9–11 plus the finalization
/// window and cancellation edge cases.
///
/// Unlike `workflows.waitFor`, which settles on the terminal `workflowStatus`
/// frame, a function run broadcasts nothing over the socket, so this one
/// POLLS `GET /workflows/runs/{runId}/status` with a backing-off interval
/// (0.4 s doubling to 5 s), exactly as the JS `FunctionsAPI.waitFor` does.
/// Server-free: the status route is a scripted transport whose answers change
/// per poll, and the poll timestamps are what the schedule is asserted on.
final class FunctionsWaitForHermeticTests: XCTestCase {

    /// A transport that answers the status route from a per-call script and
    /// records when each poll arrived.
    private final class ScriptedStatusTransport: Transport, @unchecked Sendable {
        enum Answer {
            case status(String, output: Any? = nil, error: String? = nil, runStatus: String? = nil, skipReason: String? = nil)
            case http(Int, body: String)
        }

        private let lock = NSLock()
        private var script: [Answer]
        private var _polls: [Date] = []
        private var _paths: [String] = []

        /// The answer given once the script is exhausted.
        private let tail: Answer

        var polls: [Date] { lock.withLock { _polls } }
        var paths: [String] { lock.withLock { _paths } }

        init(_ script: [Answer], tail: Answer) {
            self.script = script
            self.tail = tail
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            let answer: Answer = lock.withLock {
                _polls.append(Date())
                _paths.append(path)
                return script.isEmpty ? tail : script.removeFirst()
            }
            switch answer {
            case let .status(status, output, error, runStatus, skipReason):
                var statusObj: [String: Any] = ["status": status]
                if let output { statusObj["output"] = output }
                if let error { statusObj["error"] = error }
                if let skipReason { statusObj["skipReason"] = skipReason }
                var run: [String: Any] = ["runId": "r1", "runKey": "rk-1"]
                if let runStatus { run["status"] = runStatus }
                let data = try JSONSerialization.data(withJSONObject: ["status": statusObj, "run": run])
                return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            case let .http(code, body):
                return TransportResponse(status: code, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
        }
    }

    /// A clock the fake sleep advances, so the schedule runs in no real time
    /// and every requested sleep is on record. The host's `Task.sleep` can
    /// overshoot a short sleep by more than the sleep itself under load, so a
    /// wall-clock assertion would pin the machine, not the arithmetic.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_700_000_000)
        private var _sleeps: [TimeInterval] = []

        var now: Date { lock.withLock { _now } }
        var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

        func advance(_ seconds: TimeInterval) {
            lock.withLock {
                _sleeps.append(seconds)
                _now = _now.addingTimeInterval(seconds)
            }
        }

        func install(on api: FunctionsAPI) {
            api.clockForTest = { [self] in self.now }
            api.sleepForTest = { [self] seconds in self.advance(seconds) }
        }
    }

    private func makeApi(_ transport: ScriptedStatusTransport) -> (FunctionsAPI, FakeClock) {
        let api = FunctionsAPI(transport: transport, workflows: WorkflowsAPI(transport: transport))
        let clock = FakeClock()
        clock.install(on: api)
        return (api, clock)
    }

    // MARK: - Behavior 9: settles on the first terminal status, failed and skipped resolve

    func testWaitForReturnsOnTheFirstTerminalStatus() async throws {
        let transport = ScriptedStatusTransport(
            [.status("queued"), .status("running"), .status("completed", output: ["doubled": 42])],
            tail: .status("completed", output: ["doubled": 42])
        )
        let (api, clock) = makeApi(transport)

        let result = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 30))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["doubled"]?.numberValue, 42)
        XCTAssertEqual(transport.polls.count, 3, "three polls: queued, running, completed")
        XCTAssertEqual(Set(transport.paths), ["/workflows/runs/r1/status"])
        XCTAssertEqual(clock.sleeps, [0.4, 0.8], "no sleep after the terminal poll")
    }

    func testWaitForResolvesRatherThanThrowsForFailedAndSkipped() async throws {
        let failedTransport = ScriptedStatusTransport(
            [.status("failed", error: "nope")], tail: .status("failed", error: "nope")
        )
        let failed = try await makeApi(failedTransport).0.waitFor(runId: "r1")
        XCTAssertEqual(failed.status, "failed")
        XCTAssertTrue(failed.isFailure)
        XCTAssertEqual(failed.error, "nope")

        let skippedTransport = ScriptedStatusTransport(
            [.status("skipped", skipReason: "LOCK_CONTENTION")],
            tail: .status("skipped", skipReason: "LOCK_CONTENTION")
        )
        let skipped = try await makeApi(skippedTransport).0.waitFor(runId: "r1")
        XCTAssertEqual(skipped.status, "skipped")
        XCTAssertEqual(skipped.skipReason, "LOCK_CONTENTION")
    }

    private struct Doubled: Decodable, Sendable, Equatable { let doubled: Int }

    func testTypedWaitForDecodesTheOutput() async throws {
        let transport = ScriptedStatusTransport(
            [.status("running"), .status("completed", output: ["doubled": 42])],
            tail: .status("completed", output: ["doubled": 42])
        )
        let result = try await makeApi(transport).0.waitFor(runId: "r1", as: Doubled.self)
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output, Doubled(doubled: 42))
    }

    // MARK: - Behavior 10: the poll schedule

    /// The defaults are the JS client's: 400 ms doubling to 5 s, a 15-minute
    /// timeout.
    func testThePollScheduleDefaultsMatchTheJsClient() {
        XCTAssertEqual(FunctionsAPI.waitMinInterval, 0.4)
        XCTAssertEqual(FunctionsAPI.waitMaxInterval, 5)
        XCTAssertEqual(FunctionsAPI.waitDefaultTimeout, 15 * 60)
    }

    /// A 1 s budget: poll at 0, sleep 0.4, poll, the next 0.8 s sleep is
    /// CLAMPED to the 0.6 s left, one more poll lands at the deadline, and only
    /// then does the wait throw. Giving up as soon as the next interval would
    /// overshoot would have thrown 0.6 s early, without that last poll.
    func testWaitForClampsTheFinalSleepPollsAtTheDeadlineThenThrowsWorkflowWaitTimeout() async throws {
        let transport = ScriptedStatusTransport([], tail: .status("running"))
        let (api, clock) = makeApi(transport)
        do {
            _ = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 1))
            XCTFail("a run that never settles must time out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
            XCTAssertTrue(error.message.contains("1000ms"), error.message)
        }
        XCTAssertEqual(clock.sleeps.count, 2)
        XCTAssertEqual(clock.sleeps[0], 0.4)
        XCTAssertEqual(clock.sleeps[1], 0.6, accuracy: 1e-6, "the 0.8 s interval is clamped to what is left")
        XCTAssertEqual(transport.polls.count, 3, "polls at 0, 0.4 and the 1.0 deadline")
    }

    /// The interval doubles from 0.4 s and saturates at 5 s; the last sleep
    /// is whatever is left of the budget.
    func testWaitForDoublesTheIntervalAndSaturatesAtTheMaximum() async throws {
        let transport = ScriptedStatusTransport([], tail: .status("running"))
        let (api, clock) = makeApi(transport)
        do {
            _ = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 30))
            XCTFail("must time out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
        let expected: [TimeInterval] = [0.4, 0.8, 1.6, 3.2, 5, 5, 5, 5, 4]
        XCTAssertEqual(clock.sleeps.count, expected.count, "\(clock.sleeps)")
        for (actual, wanted) in zip(clock.sleeps, expected) {
            XCTAssertEqual(actual, wanted, accuracy: 1e-6, "\(clock.sleeps)")
        }
        XCTAssertEqual(transport.polls.count, 10)
    }

    /// A timeout of 0 disables the deadline: the wait never clamps and never
    /// throws; it settles when the run does.
    func testWaitForWithTimeoutZeroHasNoDeadline() async throws {
        var script: [ScriptedStatusTransport.Answer] = Array(repeating: .status("running"), count: 200)
        script.append(.status("completed"))
        let transport = ScriptedStatusTransport(script, tail: .status("completed"))
        let (api, clock) = makeApi(transport)
        // 200 polls at the saturated 5 s interval is ~16 minutes of fake time,
        // past the 15-minute default; with 0 there is no budget to run out.
        let result = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 0))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(transport.polls.count, 201)
        XCTAssertEqual(clock.sleeps.count, 200)
        XCTAssertEqual(clock.sleeps.suffix(3), [5, 5, 5])
        XCTAssertGreaterThan(clock.sleeps.reduce(0, +), 15 * 60)
    }

    // MARK: - Behavior 11: not-found and transient errors

    func testWaitForThrowsNotFoundOnA404() async throws {
        let transport = ScriptedStatusTransport(
            [.http(404, body: #"{"error":"Workflow run not found"}"#)],
            tail: .http(404, body: #"{"error":"Workflow run not found"}"#)
        )
        do {
            _ = try await makeApi(transport).0.waitFor(runId: "r1")
            XCTFail("a 404 must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertEqual(transport.polls.count, 1, "a 404 is final, not polled again")
    }

    /// A run reporting `missing` will never reach a terminal state, so the
    /// Swift surface throws `.notFound` the way `workflows.waitFor` does rather
    /// than polling to the timeout.
    func testWaitForThrowsNotFoundOnAMissingRun() async throws {
        let transport = ScriptedStatusTransport([.status("missing")], tail: .status("missing"))
        do {
            _ = try await makeApi(transport).0.waitFor(runId: "r1")
            XCTFail("a missing run must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertEqual(transport.polls.count, 1)
    }

    func testWaitForRetriesAcrossATransientErrorBetweenPolls() async throws {
        let transport = ScriptedStatusTransport(
            [.status("running"), .http(503, body: #"{"error":"try again"}"#), .status("completed")],
            tail: .status("completed")
        )
        let (api, clock) = makeApi(transport)
        let result = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 5))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(transport.polls.count, 3, "the 503 is retried on the next poll, not surfaced")
        XCTAssertEqual(clock.sleeps, [0.4, 0.8], "the backoff keeps going across the failed poll")
    }

    // MARK: - Edge cases: the finalization window and cancellation

    /// The run row already reads terminal while the status block still reports
    /// the execution in flight (the server withholds `completed` until the
    /// output is published). The wait re-checks on the 1 s timer
    /// `workflows.waitFor` uses and, after its bounded 30 re-checks, settles
    /// from the record instead of polling on.
    func testWaitForSettlesFromTheRunRecordAfterTheBoundedFinalizationRecheck() async throws {
        let transport = ScriptedStatusTransport(
            [], tail: .status("running", output: nil, runStatus: "completed")
        )
        let (api, clock) = makeApi(transport)
        let result = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 120))
        XCTAssertEqual(result.status, "completed")
        // The first poll saw the window, then the bounded re-checks, then the record won.
        XCTAssertEqual(transport.polls.count, 1 + WorkflowsAPI.finalizeMaxRechecks)
        XCTAssertEqual(WorkflowsAPI.finalizeMaxRechecks, 30)
        XCTAssertEqual(
            clock.sleeps,
            Array(repeating: TimeInterval(WorkflowsAPI.finalizeRecheckIntervalMs) / 1000, count: 30),
            "the re-check runs on the workflow wait's 1 s timer, not the poll backoff"
        )
    }

    /// The re-check ends early when the status block catches up.
    func testWaitForSettlesFromTheStatusBlockWhenItCatchesUpInsideTheWindow() async throws {
        let transport = ScriptedStatusTransport(
            [.status("running", runStatus: "completed"), .status("completed", output: ["ok": true])],
            tail: .status("completed", output: ["ok": true])
        )
        let (api, clock) = makeApi(transport)
        let result = try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 10))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["ok"]?.boolValue, true)
        XCTAssertEqual(transport.polls.count, 2)
        XCTAssertEqual(clock.sleeps, [1.0])
    }

    /// Real clock and a real (short) sleep: a cancelled waiting `Task` throws
    /// `CancellationError` promptly and the polling stops.
    func testWaitForCancelledThroughTaskCancelThrowsCancellationErrorPromptlyAndStopsPolling() async throws {
        let transport = ScriptedStatusTransport([], tail: .status("running"))
        let api = FunctionsAPI(transport: transport, workflows: WorkflowsAPI(transport: transport))
        // A real sleep, shortened so the loop is visibly polling; it still
        // throws `CancellationError` when the task is cancelled.
        api.sleepForTest = { _ in try await Task.sleep(nanoseconds: 30_000_000) }

        let waiter = Task { try await api.waitFor(runId: "r1", options: WaitForWorkflowOptions(timeout: 0)) }
        try await eventually(timeout: 5, description: "the wait to be polling") {
            transport.polls.count >= 2
        }
        let pollsAtCancel = transport.polls.count

        let cancelledAt = Date()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("a cancelled wait must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2, "cancellation must be prompt")

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThanOrEqual(transport.polls.count, pollsAtCancel + 1, "polling must stop after cancellation")
    }
}
