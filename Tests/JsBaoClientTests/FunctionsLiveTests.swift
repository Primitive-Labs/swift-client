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
        let completed = try await client.functions.invoke(
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
        let failed = try await client.functions.invoke(boom, timeout: generousTimeout)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertTrue(failed.error?.contains("nope") == true, "\(String(describing: failed.error))")
        XCTAssertNil(failed.output)

        let slow = key("slow")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: slow,
            bundle: "export default async () => { await new Promise((r) => setTimeout(r, 5000)); return { late: true }; };"
        )
        let timedOut = try await client.functions.invoke(slow, timeout: 1)
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
            options: WaitForWorkflowOptions(timeout: 60)
        )
        XCTAssertEqual(settled.status, "completed")
        XCTAssertEqual(settled.output, Doubled(doubled: 42))

        // A repeated runKey replays the run that already exists.
        let runKey = "swift-rk-\(Int(Date().timeIntervalSince1970))"
        let first = try await client.functions.start(functionKey, runKey: runKey, contextDocId: docId)
        let second = try await client.functions.start(functionKey, runKey: runKey, contextDocId: docId)
        XCTAssertEqual(second.runId, first.runId)
        XCTAssertEqual(second.existing, true)

        // Terminate on a running task answers a terminal status under the
        // function key — that is the alias. Started fresh so it is still
        // inside its nap when the terminate lands.
        let running = try await client.functions.start(functionKey, input: ["n": 2], contextDocId: docId)
        let stopped = try await client.functions.terminate(
            FunctionRunRef(functionKey: functionKey, runKey: running.runKey, contextDocId: docId)
        )
        XCTAssertTrue(
            WaitForWorkflowResult.terminalStatuses.contains(stopped.status),
            "terminate must answer a terminal status, got \(stopped.status)"
        )
    }

    // MARK: - Behavior 15: the mode check, live

    func testInvokeOnATaskAndStartOnARequestFunctionThrowFunctionModeMismatch() async throws {
        let task = key("mode-task")
        try await ctx.pushFunction(appId: testApp.appId, functionKey: task, bundle: Self.sleeper, durable: true)
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)
        do {
            _ = try await client.functions.invoke(task, contextDocId: docId, timeout: generousTimeout)
            XCTFail("invoke on a task function must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertTrue(error.message.contains("is a task function"), error.message)
            XCTAssertNotNil(error.details?["runId"]?.stringValue, "the run was started; its id is in details")
        }

        let request = key("mode-request")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: request,
            bundle: "export default async function () { return { ok: true }; }"
        )
        do {
            _ = try await client.functions.start(request, contextDocId: docId)
            XCTFail("start on a request function must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertTrue(error.message.contains("is a request function"), error.message)
            XCTAssertEqual(error.details?["status"]?.stringValue, "completed")
        }
    }
}
