import XCTest
@testable import JsBaoClient

/// Server functions against the live dev server (#3278).
///
/// Phase 0 first: no Swift test had ever pushed a server function, so the
/// smoke test proves the vehicle — `TestContext.pushFunction` (the two admin
/// calls the JS `pushTestFunction` helper makes) followed by one raw
/// `POST /functions/{key}` that answers `completed` — before any behavior is
/// built on it. The behaviors themselves (13–15) run through
/// `client.functions` once Phase 1 lands.
final class FunctionsLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-functions")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    private var counter = 0
    private func key(_ label: String) -> String {
        counter += 1
        return "swift-fn-\(label)-\(Int(Date().timeIntervalSince1970))-\(counter)"
    }

    // MARK: - Phase 0: the vehicle

    /// A function pushed through the admin API answers a raw invoke with the
    /// `completed` envelope. Nothing from `client.functions` is involved: this
    /// is the proof that the harness can push and the server can run what it
    /// pushed, which every live behavior below assumes.
    func testPhaseZeroSmokePushedFunctionAnswersARawInvoke() async throws {
        let functionKey = key("smoke")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: "export default async function (input) { return { echoed: input }; }"
        )

        let response = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/functions/\(functionKey)",
            body: ["rootInput": ["a": 1], "timeoutMs": 20_000],
            jwt: testApp.ownerJWT
        )
        XCTAssertEqual(response["status"] as? String, "completed", "\(response)")
        let output = response["output"] as? [String: Any]
        XCTAssertEqual((output?["echoed"] as? [String: Any])?["a"] as? Int, 1, "\(response)")
    }

    // MARK: - Behavior 13: request functions through client.functions.invoke

    /// The platform default budget is 5 s, which a cold sandbox load can
    /// exceed; the budget under test is the handler's, not the loader's.
    private let generousTimeout: TimeInterval = 20

    func testInvokeAnswersCompletedFailedAndTimeoutAsSettledEnvelopes() async throws {
        let sum = key("sum")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: sum,
            bundle: "export default async function (input) { return { total: input.a + input.b }; }"
        )
        // #3344 retired the untyped entry points; a dynamic caller names the
        // witness and binds `JSONValue` on the way out.
        let completed: FunctionResult<JSONValue> = try await client.functions.invoke(
            sum, input: ["a": 2, "b": 3], timeout: generousTimeout
        )
        XCTAssertEqual(completed.status, "completed")
        XCTAssertEqual(completed.output?["total"]?.numberValue, 5)
        XCTAssertNotNil(completed.limits, "the sandbox ran, so the ceilings it ran under are reported")
        XCTAssertNil(completed.error)

        let boom = key("boom")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: boom,
            bundle: "export default async () => { throw new Error(\"nope\"); };"
        )
        // A settled invocation, whatever its status — only a platform refusal throws.
        let failed: FunctionResult<JSONValue> = try await client.functions.invoke(
            boom, input: nil as JSONValue?, timeout: generousTimeout
        )
        XCTAssertEqual(failed.status, "failed")
        XCTAssertTrue(failed.error?.contains("nope") == true, "\(String(describing: failed.error))")
        XCTAssertNil(failed.output)

        let slow = key("slow")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: slow,
            bundle: "export default async () => { await new Promise((r) => setTimeout(r, 5000)); return { late: true }; };"
        )
        let timedOut: FunctionResult<JSONValue> = try await client.functions.invoke(
            slow, input: nil as JSONValue?, timeout: 1
        )
        XCTAssertEqual(timedOut.status, "timeout")
        XCTAssertNil(timedOut.output)
    }

    private struct Echo<Value: Decodable & Sendable & Equatable>: Decodable, Sendable, Equatable {
        let echoed: Value
    }

    /// A function whose input schema declares an array root takes a Swift
    /// array through the typed overload and echoes it back; a string root
    /// takes a `String`. The typed input goes as the JSON value it encodes
    /// to — never lowered to `{}`.
    func testTypedInvokeSendsArrayAndStringRootsTheSchemaDeclares() async throws {
        let tags = key("tags")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: tags,
            bundle: "export default async (input) => ({ echoed: input });",
            inputSchema: ["type": "array", "items": ["type": "string"]]
        )
        let arrayResult: FunctionResult<Echo<[String]>> = try await client.functions.invoke(
            tags, input: ["a", "b"], timeout: generousTimeout
        )
        XCTAssertEqual(arrayResult.status, "completed", "\(String(describing: arrayResult.error))")
        XCTAssertEqual(arrayResult.output, Echo(echoed: ["a", "b"]))

        let shout = key("shout")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: shout,
            bundle: "export default async (input) => ({ echoed: input });",
            inputSchema: ["type": "string"]
        )
        let stringResult: FunctionResult<Echo<String>> = try await client.functions.invoke(
            shout, input: "hello", timeout: generousTimeout
        )
        XCTAssertEqual(stringResult.status, "completed", "\(String(describing: stringResult.error))")
        XCTAssertEqual(stringResult.output, Echo(echoed: "hello"))
    }

    // MARK: - Behavior 14: task functions — start, getStatus, waitFor, replay, terminate

    private static let sleeper = """
    export default async function (input, ctx, step) {
      const marked = await step.do("mark", async () => ({ n: (input && input.n) || 1 }));
      await step.sleep("nap", 1500);
      return { doubled: marked.n * 2 };
    }
    """

    private struct Doubled: Decodable, Sendable, Equatable { let doubled: Int }

    func testTaskFunctionStartsPollsWaitsReplaysAndTerminates() async throws {
        let functionKey = key("task")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: Self.sleeper,
            durable: true
        )
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let started = try await client.functions.start(
            functionKey, input: ["n": 21], contextDocId: docId
        )
        XCTAssertFalse(started.runId.isEmpty)
        XCTAssertEqual(started.runKey, started.runId)
        XCTAssertNotNil(started.instanceId)
        XCTAssertEqual(started.status, "running")
        XCTAssertNil(started.existing)

        // Read before the 1.5 s nap ends: a non-terminal status.
        let now = try await client.functions.getStatus(runId: started.runId)
        XCTAssertTrue(
            ["queued", "running", "waiting", "completed"].contains(now.status),
            now.status
        )

        let settled = try await client.functions.waitFor(
            runId: started.runId, as: Doubled.self,
            options: FunctionWaitOptions(timeout: 60)
        )
        XCTAssertEqual(settled.status, "completed")
        XCTAssertEqual(settled.output, Doubled(doubled: 42))

        // A repeated runKey replays the run that already exists.
        let runKey = "swift-rk-\(Int(Date().timeIntervalSince1970))"
        let first = try await client.functions.start(
            functionKey, input: nil as JSONValue?, runKey: runKey, contextDocId: docId
        )
        let second = try await client.functions.start(
            functionKey, input: nil as JSONValue?, runKey: runKey, contextDocId: docId
        )
        XCTAssertEqual(second.runId, first.runId)
        XCTAssertEqual(second.existing, true)

        // Terminate on a running task answers a terminal status under the
        // function key. Started fresh so it is still inside its nap when the
        // terminate lands.
        //
        // #3565 — a DISJUNCTION by design: Cloudflare's LOCAL Workflows engine
        // answers "Not implemented yet" to `instance.terminate()`, while a
        // deployed one stops the run. Either is a correct outcome; what is NOT
        // correct — and what this child fixes — is reporting a run that EXISTS
        // as not found, and throwing the engine's diagnostic away with it.
        let running = try await client.functions.start(functionKey, input: ["n": 2], contextDocId: docId)
        let ref = FunctionRunRef(
            functionKey: functionKey, runKey: running.runKey, contextDocId: docId
        )
        do {
            let stopped = try await client.functions.terminate(ref)
            XCTAssertTrue(
                stopped.isTerminal,
                "terminate must answer a terminal status, got \(stopped.status)"
            )
        } catch let error as JsBaoError {
            XCTAssertEqual(
                error.code, .unavailable,
                "a run that exists is never a not-found, got \(error.code): \(error.message)"
            )
            XCTAssertTrue(
                error.message.hasPrefix(
                    "Function run \(running.runKey) of function \(functionKey) "
                        + "could not be terminated: "
                ),
                "the engine's diagnostic rides the function-worded prefix, got \(error.message)"
            )
        }
    }

    // MARK: - #3388: the task run's slice block, live

    /// One step and a return — long enough to open a slice record, short
    /// enough to settle it inside the wait.
    private static let oneStep = """
    export default async function (input, ctx, step) {
      const one = await step.do("one", async () => 1);
      return { one };
    }
    """

    private struct One: Decodable, Sendable, Equatable { let one: Int }

    /// A settled task run's slice rides `functions.getStatus`, with the seven
    /// fields the JS client's `WorkflowStatusResult.slice?` carries. The run
    /// is waited out first: the block is read AFTER `waitFor` settles, which
    /// is where a caller wants the refresh count and the 12-hour ceiling.
    func testASettledTaskRunsSliceRidesGetStatusAfterTheWait() async throws {
        let functionKey = key("slice")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: Self.oneStep,
            durable: true
        )
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let started = try await client.functions.start(
            functionKey, input: nil as JSONValue?, contextDocId: docId
        )
        let settled = try await client.functions.waitFor(
            runId: started.runId, options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(settled.status, "completed", "\(String(describing: settled.error))")

        // The wrapper settles the record as the run ends, so re-read briefly:
        // the case is about the settled record, not about winning a race with
        // the write that settles it.
        var status = try await client.functions.getStatus(runId: started.runId)
        var attempts = 0
        while status.slice?.settledAt == nil && attempts < 15 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            status = try await client.functions.getStatus(runId: started.runId)
            attempts += 1
        }

        let slice = try XCTUnwrap(status.slice, "a task run has a slice record")
        XCTAssertFalse(slice.sliceId.isEmpty)
        let startedAt = try XCTUnwrap(slice.startedAt)
        let ceilingAt = try XCTUnwrap(slice.ceilingAt)
        // The 12-hour bound, ahead of the slice's start.
        XCTAssertGreaterThan(ceilingAt, startedAt)
        XCTAssertNotNil(slice.settledAt)
        XCTAssertEqual(slice.settledStatus, "completed")
        // Seconds long: nothing to refresh.
        XCTAssertEqual(slice.refreshCount, 0)
        XCTAssertNil(slice.lastRefreshAt)

        // The typed overload reads the same record: binding `output` to a type
        // must not cost the caller the block beside it.
        let typed: FunctionRunResult<One> = try await client.functions.getStatus(runId: started.runId)
        XCTAssertEqual(typed.slice, slice)
    }

    /// The block is additive: a DSL workflow run is not a function run, so its
    /// status carries no `slice` key and the Swift result reads `nil`.
    func testAWorkflowRunsStatusCarriesNoSlice() async throws {
        let workflowKey = "swift-slice-dsl-\(Int(Date().timeIntervalSince1970))"
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: workflowKey,
            steps: [["id": "n", "kind": "noop", "message": "hi", "saveAs": "output"]],
            requiresClientApply: false,
            syncCallable: true
        )
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let run = try await client.workflows.runSync(
            workflowKey: workflowKey,
            runKey: "swift-slice-dsl-run",
            contextDocId: docId
        )
        XCTAssertEqual(run.status, "completed")

        let status = try await client.functions.getStatus(runId: run.runId)
        XCTAssertNil(status.slice, "a DSL run has no slice record")
    }

    // MARK: - #3454: the runner is chosen at call time

    /// An `any` function — the DEFAULT since #3454 — takes both verbs, and
    /// each one gets the runner it names.
    func testBothVerbsReachAnAnyFunction() async throws {
        let either = key("mode-any")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: either,
            bundle: "export default async function () { return { ok: true }; }",
            mode: "any"
        )
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let started = try await client.functions.start(
            either, input: nil as JSONValue?, contextDocId: docId
        )
        XCTAssertFalse(started.runId.isEmpty)
        let settled = try await client.functions.waitFor(
            runId: started.runId, options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(settled.status, "completed")

        // …and the same version, invoked, answers its result inside the call.
        let result: FunctionResult<JSONValue> = try await client.functions.invoke(
            either, input: nil as JSONValue?, contextDocId: docId, timeout: generousTimeout
        )
        XCTAssertEqual(result.status, "completed")
    }

    // MARK: - #3482: there is no lock, and the ROUTE is the runtime

    /// Both doors answer on every version a row can hold.
    ///
    /// Retargeted (#3482). This was
    /// `testInvokeOnATaskAndStartOnARequestFunctionThrowFunctionModeMismatch`,
    /// and it asserted that a LOCK's other door throws `.functionModeMismatch`.
    /// That refusal is gone: a function's config says nothing about how it runs,
    /// the caller picks the runtime at each call, and the ROUTE is how a Swift
    /// caller says which one it means — `invoke` posts to `functions/{key}` and
    /// runs the function inside the request, `start` posts to
    /// `functions/{key}/start` and runs it as a task.
    ///
    /// The subjects are the same two versions, pushed with the same two now
    /// retired keys, so "the other door throws" becomes "the other door
    /// answers": four door-and-version pairs asserted where there were two
    /// refusals. `.functionModeMismatch` stays DECLARED as the backstop against
    /// a server older than this child (D3482-008) — a claim about the public
    /// error type, pinned hermetically rather than against a server that no
    /// longer sends it.
    func testBothVerbsReachAVersionStoredWithEitherRetiredLock() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        // Pushed with the retired `mode = "task"`. INVOKE runs it inside the
        // request, and its `step.sleep` really waits there, because the request
        // budget covers 1.5 s (#3454's request-runtime `step`).
        let task = key("mode-task")
        try await ctx.pushFunction(
            appId: testApp.appId, functionKey: task, bundle: Self.sleeper, mode: "task"
        )
        let invoked: FunctionResult<Doubled> = try await client.functions.invoke(
            task, input: ["n": 3], contextDocId: docId, timeout: generousTimeout
        )
        XCTAssertEqual(invoked.status, "completed")
        XCTAssertEqual(invoked.output, Doubled(doubled: 6))

        // …and the same version still starts a task run.
        let startedTask = try await client.functions.start(
            task, input: ["n": 4], contextDocId: docId
        )
        XCTAssertFalse(startedTask.runId.isEmpty)
        let settledTask = try await client.functions.waitFor(
            runId: startedTask.runId, as: Doubled.self,
            options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(settledTask.status, "completed")
        XCTAssertEqual(settledTask.output, Doubled(doubled: 8))

        // Pushed with the retired `mode = "request"`: START takes it, because
        // the route is the runtime and no stored key refuses a door.
        let request = key("mode-request")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: request,
            bundle: "export default async function () { return { ok: true }; }",
            mode: "request"
        )
        let started = try await client.functions.start(
            request, input: nil as JSONValue?, contextDocId: docId
        )
        XCTAssertFalse(started.runId.isEmpty)
        let settled = try await client.functions.waitFor(
            runId: started.runId, options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(settled.status, "completed")

        // …and invoking it still answers inside the call.
        let result: FunctionResult<JSONValue> = try await client.functions.invoke(
            request, input: nil as JSONValue?, contextDocId: docId, timeout: generousTimeout
        )
        XCTAssertEqual(result.status, "completed")
    }
}
