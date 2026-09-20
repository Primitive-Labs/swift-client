import XCTest
@testable import JsBaoClient

/// A failed run, decoded in Swift against a live server — #3449 behaviors 12
/// and 13, project `server-functions` phase 4.
///
/// The issue reports `getStatus` and `waitFor` THROWING on a real failed task
/// run, so the claim that matters is about a real one. The hermetic suite
/// (`WorkflowStatusErrorHermeticTests`) pins the decode against bytes chosen
/// by hand; this pins it against bytes the server chose.
///
/// D3449-005 makes this the SPONSOR'S ONE COMMAND for the outstanding
/// agent-environment evidence. It targets whatever `TEST_HTTP_URL` /
/// `TEST_WS_URL` name and self-skips when the target will not mint a test app,
/// so
///
///     TEST_HTTP_URL=<agent host> TEST_WS_URL=<agent ws> \
///       swift test --package-path swift-client \
///       --filter FunctionsFailedStatusLiveTests/testFailedTaskRunDecodes
///
/// is the whole of it, and the runbook in
/// `projects/server-functions/swift-status-error-check-2026-09-15.md` says so.
///
/// The cases live in their own suite rather than inside `FunctionsLiveTests`
/// because that suite's `setUp` THROWS when a target will not take its
/// credentials, and a throw there is a failure rather than a skip — which is
/// exactly what a one-command run against an arbitrary host must not do.
final class FunctionsFailedStatusLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!
    private var client: JsBaoClient!
    /// Why the target could not be provisioned, when it could not be.
    private var unavailable: String?

    override func setUp() async throws {
        do {
            let context = TestContext()
            try await context.initialize()
            testApp = try await context.createTestApp(name: "swift-failed-status")
            ctx = context
            client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        } catch {
            // A target that will not take this suite's test credentials is not
            // a failure of the client: it is a target the case cannot run
            // against. Skipping says so, and is what lets the same command
            // point at the agent host, at a local dev server, or at nothing.
            unavailable =
                "target \(TestConfig.httpUrl) refused test setup: \(error)"
        }
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx?.cleanup()
    }

    private func requireTarget() throws {
        if let unavailable { throw XCTSkip(unavailable) }
    }

    private var counter = 0
    private func key(_ label: String) -> String {
        counter += 1
        return "swift-3449-\(label)-\(Int(Date().timeIntervalSince1970))-\(counter)"
    }

    private struct NoOutput: Decodable, Sendable, Equatable {}

    // MARK: - Behavior 12: a failed task run resolves rather than throwing

    /// The case the issue is about, end to end: a pushed task function whose
    /// handler throws, started with `functions.start`, waited with `waitFor`.
    ///
    /// Before this child every one of these calls threw
    /// `typeMismatch(Swift.String, … "Expected to decode String but found a
    /// dictionary instead.")` — the nested decode failed on the object, the
    /// whole-block `try?` fell through, and the fallback re-read `status` as a
    /// string. `waitFor` retried that throw as transient and burned its whole
    /// budget, which is Compound's report of a run stuck `running`.
    func testFailedTaskRunDecodes() async throws {
        try requireTarget()

        let functionKey = key("boom")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: #"export default async function () { throw new Error("boom from swift"); }"#,
            durable: true
        )
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT
        )

        let started = try await client.functions.start(
            functionKey, input: nil as JSONValue?, contextDocId: docId
        )
        XCTAssertFalse(started.runId.isEmpty)

        // Resolves. Does not throw — that IS behavior 12.
        let settled = try await client.functions.waitFor(
            runId: started.runId,
            options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(settled.status, "failed")
        XCTAssertTrue(settled.isFailure)
        // #3565 — ONE structured error on the function type, so `error` IS the
        // value rather than a message beside a `failure`.
        let waitMessage = try XCTUnwrap(
            settled.error?.message,
            "a failed run carries its structured error"
        )
        XCTAssertTrue(
            waitMessage.contains("boom from swift"),
            "the thrown text should survive to the client, got \(waitMessage)"
        )

        // `getStatus` on the same run agrees, and so does the typed overload.
        let status = try await client.functions.getStatus(runId: started.runId)
        XCTAssertEqual(status.status, "failed")
        XCTAssertEqual(status.error?.message, waitMessage)
        // `run` decodes through `FunctionRunInfo`, so a status that came back
        // at all is the whole response decoding, not one field.
        XCTAssertEqual(status.run?.runId, started.runId)
        XCTAssertEqual(status.run?.functionKey, functionKey)

        let typed: FunctionRunResult<NoOutput> = try await client.functions.getStatus(
            runId: started.runId
        )
        XCTAssertEqual(typed.status, "failed")
        XCTAssertEqual(typed.error, status.error)

        let typedWait = try await client.functions.waitFor(
            runId: started.runId,
            as: NoOutput.self,
            options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(typedWait.status, "failed")
        XCTAssertEqual(typedWait.error, settled.error)
    }

    // MARK: - Behavior 13: a failed DSL durable run, through both surfaces

    /// The object form is NOT a function-run quirk: `flattenInstanceStatus`
    /// rewraps a failed DSL run's nested string as
    /// `{ name: "WorkflowError", message }`, so `workflows.getStatus` has been
    /// throwing for every failed durable run since long before functions
    /// existed.
    func testFailedWorkflowRunDecodesWithTheWorkflowErrorName() async throws {
        try requireTarget()

        let workflowKey = key("wf")
        let runKey = "rk-\(Int(Date().timeIntervalSince1970))"

        // A run that reliably ends FAILED: the step succeeds and its output
        // violates the workflow's declared `outputSchema`, the same mechanism
        // the JS canonical-status suite uses.
        _ = try await ctx.adminPost(
            "/admin/api/apps/\(testApp.appId)/workflows",
            body: [
                "accessRule": "true",
                "workflowKey": workflowKey,
                "name": "Swift \(workflowKey)",
                "steps": [
                    [
                        "id": "noop",
                        "kind": "noop",
                        "message": "wrong-type",
                        "saveAs": "output",
                    ]
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": ["message": ["type": "number"]],
                    "required": ["message"],
                    "additionalProperties": false,
                ],
                "requiresClientApply": false,
                "syncCallable": false,
            ]
        )

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT
        )
        let started = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/workflows/\(workflowKey)/start",
            body: ["rootInput": [:], "runKey": runKey, "contextDocId": docId],
            jwt: testApp.ownerJWT
        )
        let runId = try XCTUnwrap(started["runId"] as? String, "\(started)")

        // Poll through the CLIENT, which is the surface under test: before
        // this child each of these reads threw.
        var byRunId: FunctionRunStatus?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let read = try await client.functions.getStatus(runId: runId)
            if read.isTerminal {
                byRunId = read
                break
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        let settled = try XCTUnwrap(byRunId, "the DSL run never settled")
        XCTAssertEqual(settled.status, "failed")
        // #3565, D3565-014 — `WorkflowError` is the PLATFORM's placeholder for
        // a failure it has only the message of, not a thrown name, so the
        // function reader drops it. A DSL run read through this surface is not
        // refused (the route is shared by design), and it answers the function
        // shape: no placeholder name, and no function identity either.
        XCTAssertNil(settled.error?.name)
        XCTAssertNil(settled.run?.functionKey)

        // The same run through the workflow surface it can also be read on.
        let viaWorkflows = try await client.workflows.getStatus(
            workflowKey: workflowKey, runKey: runKey, contextDocId: docId
        )
        XCTAssertEqual(viaWorkflows.status, "failed")
        // …and the WORKFLOW surface does NOT move: the same run still answers
        // the placeholder there, because principle 5 forbids changing what a
        // published field carries. The two surfaces agree on the MESSAGE.
        XCTAssertEqual(viaWorkflows.failure?.name, "WorkflowError")
        XCTAssertEqual(viaWorkflows.failure?.message, settled.error?.message)

        // #3565 edge 34 — and the WAIT settles such a run normally rather
        // than refusing it. `functions.waitFor` is not told which kind of run
        // it is polling (the route is shared by design until phase 7), and a
        // DSL run that ends in one of the three terminal statuses is one it
        // can answer. The run is already terminal here, so this is one poll.
        let waited = try await client.functions.waitFor(
            runId: runId, options: FunctionWaitOptions(timeout: 30)
        )
        XCTAssertEqual(waited.status, settled.status)
        XCTAssertTrue(waited.isTerminal)
        XCTAssertNil(waited.run?.functionKey)
    }
}
