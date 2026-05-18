import XCTest
@testable import JsBaoClient

/// Proves that a workflow started in one client session can be applied by
/// a subsequent session, covering the "start a workflow, close the app,
/// reopen, pick up where we left off" pattern.
///
/// Client A starts a workflow with `runAndApply` (which persists a
/// waiter + begins the apply flow on completion). Client A is destroyed
/// BEFORE the run finishes — the runKey survives on the caller side (in
/// production, pinned to a domain record). Client B, a fresh client for
/// the same user/app, calls `awaitRun(runKey:)` and must receive the
/// same output client A would have received, regardless of server-side
/// state at reconnect (running / apply_pending / completed).
///
/// Requires TEST_SUPERADMIN_JWT to be set (see TestConfig) so the test
/// can provision a disposable app + workflow against a local dev server.
final class WorkflowRecoveryTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        try XCTSkipIf(
            TestConfig.superAdminJwt == nil,
            "TEST_SUPERADMIN_JWT not set — skipping integration test"
        )
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-workflow-recovery")
    }

    override func tearDown() async throws {
        await ctx?.cleanup()
    }

    // MARK: - Steps helpers

    /// A workflow that sleeps for `ms` milliseconds, then emits an
    /// `output` object carrying the caller's input name. Long enough that
    /// we can kill the first client mid-flight and still observe the
    /// run complete on the server.
    private func delaySteps(ms: Int, marker: String) -> [[String: Any]] {
        [
            [
                "id": "sleep",
                "kind": "delay",
                "ms": ms,
                "saveAs": "delayed",
            ],
            [
                "id": "emit",
                "kind": "transform",
                "output": ["marker": marker],
                "saveAs": "output",
            ],
        ]
    }

    // MARK: - The core recovery test

    /// App-restart scenario: start a run in client A, destroy A before
    /// the server completes it, then let client B recover the output via
    /// `awaitRun`. Covers the typical "workflow still running when app
    /// was killed" path.
    func testAwaitRunRecoversRunKilledMidFlight() async throws {
        let workflowKey = "wf-recovery-midflight-\(UUID().uuidString.prefix(6))"
        _ = try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: workflowKey,
            steps: delaySteps(ms: 4_000, marker: "midflight"),
            requiresClientApply: true
        )

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "recovery-doc"
        )

        let runKey = "recovery-\(UUID().uuidString.prefix(8))"

        // --- Client A: start the run, then die ---
        do {
            let clientA = createTestClient(
                appId: testApp.appId,
                token: testApp.ownerJWT,
                autoNetwork: false
            )
            try await clientA.connect()
            try await waitForConnection(client: clientA)

            _ = try await clientA.workflows.start(
                workflowKey: workflowKey,
                input: ["name": "test"],
                options: StartWorkflowOptions(
                    runKey: runKey,
                    contextDocId: docId
                )
            )
            // Intentionally DO NOT await completion. Simulate app kill
            // by destroying the client while the workflow is still
            // executing server-side.
            await clientA.destroy()
        }

        // Give the server a moment to process the start + begin the
        // delay step. Not required for correctness (awaitRun handles
        // running/queued), just tightens the race window.
        try await delay(0.25)

        // --- Client B: fresh client, same user, reconnect + recover ---
        let clientB = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            autoNetwork: false
        )
        try await clientB.connect()
        try await waitForConnection(client: clientB)
        defer { Task { await clientB.destroy() } }

        let ctx2 = try await clientB.workflows.awaitRun(
            workflowKey: workflowKey,
            runKey: runKey,
            contextDocId: docId,
            timeout: 30
        )

        let output = ctx2.output as? [String: Any]
        XCTAssertEqual(output?["marker"] as? String, "midflight",
                       "awaitRun should return the same output the original run would have")
    }

    /// apply_pending scenario: the run has already completed on the
    /// server and is parked waiting for a client to claim+apply. A fresh
    /// client's `awaitRun` should trigger the claim flow and return the
    /// output.
    func testAwaitRunRecoversRunInApplyPending() async throws {
        let workflowKey = "wf-recovery-pending-\(UUID().uuidString.prefix(6))"
        _ = try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: workflowKey,
            steps: delaySteps(ms: 100, marker: "apply-pending"),
            requiresClientApply: true
        )

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "pending-doc"
        )

        let runKey = "pending-\(UUID().uuidString.prefix(8))"

        // Client A: start the run but never install an apply handler.
        // Workflow completes quickly and parks in apply_pending.
        let clientA = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            autoNetwork: false
        )
        try await clientA.connect()
        try await waitForConnection(client: clientA)
        _ = try await clientA.workflows.start(
            workflowKey: workflowKey,
            input: ["name": "pending"],
            options: StartWorkflowOptions(
                runKey: runKey,
                contextDocId: docId
            )
        )
        // Ensure we actually enter the apply_pending state before
        // destroying client A; a fixed sleep makes this scenario flaky
        // under slower local workers.
        try await eventually(timeout: 15, description: "workflow to reach apply_pending") {
            let status = try await clientA.workflows.getStatus(
                workflowKey: workflowKey,
                runKey: runKey,
                contextDocId: docId
            )
            let run = status["run"] as? [String: Any]
            return (run?["status"] as? String)?.lowercased() == "apply_pending"
        }
        await clientA.destroy()

        // Client B: fresh client recovers via awaitRun — should trigger
        // the claim → getStatus → handler → confirm sequence inside.
        let clientB = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            autoNetwork: false
        )
        try await clientB.connect()
        try await waitForConnection(client: clientB)
        defer { Task { await clientB.destroy() } }

        let ctx2 = try await clientB.workflows.awaitRun(
            workflowKey: workflowKey,
            runKey: runKey,
            contextDocId: docId,
            timeout: 30
        )

        let output = ctx2.output as? [String: Any]
        XCTAssertEqual(output?["marker"] as? String, "apply-pending")
    }

    /// completed scenario: a prior client already applied the run. A
    /// later `awaitRun` should still return the stored output without
    /// hanging. Exercises `reconcileRun` → "completed" branch.
    func testAwaitRunRecoversCompletedRun() async throws {
        let workflowKey = "wf-recovery-completed-\(UUID().uuidString.prefix(6))"
        _ = try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: workflowKey,
            steps: delaySteps(ms: 100, marker: "completed"),
            // requiresClientApply=false so the server transitions
            // straight to "completed" without a client apply step.
            requiresClientApply: false
        )

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "completed-doc"
        )

        let runKey = "completed-\(UUID().uuidString.prefix(8))"

        let clientA = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            autoNetwork: false
        )
        try await clientA.connect()
        try await waitForConnection(client: clientA)
        _ = try await clientA.workflows.start(
            workflowKey: workflowKey,
            input: ["name": "done"],
            options: StartWorkflowOptions(
                runKey: runKey,
                contextDocId: docId
            )
        )
        try await delay(2.0)
        await clientA.destroy()

        let clientB = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            autoNetwork: false
        )
        try await clientB.connect()
        try await waitForConnection(client: clientB)
        defer { Task { await clientB.destroy() } }

        let ctx2 = try await clientB.workflows.awaitRun(
            workflowKey: workflowKey,
            runKey: runKey,
            contextDocId: docId,
            timeout: 15
        )

        let output = ctx2.output as? [String: Any]
        XCTAssertEqual(output?["marker"] as? String, "completed")
    }

    /// not_found scenario: awaitRun on a runKey that was never started
    /// should throw `.terminalFailure(status: "not_found", ...)`. Callers
    /// rely on this to distinguish "run is missing, start a new one"
    /// from "run is still running, keep waiting".
    func testAwaitRunThrowsForMissingRunKey() async throws {
        let workflowKey = "wf-recovery-missing-\(UUID().uuidString.prefix(6))"
        _ = try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: workflowKey,
            steps: delaySteps(ms: 10, marker: "wont-fire"),
            requiresClientApply: true
        )

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "missing-doc"
        )

        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            autoNetwork: false
        )
        try await client.connect()
        try await waitForConnection(client: client)
        defer { Task { await client.destroy() } }

        do {
            _ = try await client.workflows.awaitRun(
                workflowKey: workflowKey,
                runKey: "never-started-\(UUID().uuidString.prefix(8))",
                contextDocId: docId,
                timeout: 10
            )
            XCTFail("awaitRun should have thrown for a runKey that was never started")
        } catch let err as WorkflowsAPI.WorkflowRunError {
            switch err {
            case .terminalFailure(let status, _):
                XCTAssertEqual(
                    status.lowercased(), "not_found",
                    "Expected not_found status, got \(status)"
                )
            default:
                XCTFail("Expected terminalFailure, got \(err)")
            }
        }
    }
}
