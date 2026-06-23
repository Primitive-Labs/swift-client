import XCTest
@testable import JsBaoClient

/// Live integration coverage for `client.workflows.runSync` (#956 / #1058).
///
/// Port of tests/client/js-bao-client-workflow-runSync.test.ts — the JS
/// client is the source of truth for the wire shape. Each test provisions a
/// `syncCallable` workflow via the admin API (TestContext.setupWorkflow) and
/// invokes it through the typed Swift surface.
final class WorkflowRunSyncTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var contextDocId: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-runsync")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        // A known contextDocId to scope runs against (mirrors the JS test
        // setup — the test owner has no rootDocId fixture).
        contextDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "runSync ctx doc"
        )
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    /// [JS CLIENT.B1] happy path: a successful syncCallable workflow resolves
    /// with `status == "completed"`, the saved output, the echoed runKey, and
    /// the persisted run record.
    func testRunSyncCompletedReturnsOutputAndRun() async throws {
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: "swift-runsync-ok",
            steps: [["id": "n", "kind": "noop", "message": "hi", "saveAs": "output"]],
            requiresClientApply: false,
            syncCallable: true
        )

        let result = try await client.workflows.runSync(
            workflowKey: "swift-runsync-ok",
            input: ["topic": "edge"],
            runKey: "swift-b1-run",
            contextDocId: contextDocId
        )

        XCTAssertEqual(result.status, "completed")
        XCTAssertFalse(result.runId.isEmpty)
        XCTAssertEqual(result.runKey, "swift-b1-run")
        XCTAssertEqual(result.output?["message"]?.stringValue, "hi")
        XCTAssertEqual(result.run?.status, "completed")
    }

    /// [JS CLIENT.B2] edge: an engine failure RESOLVES with
    /// `status == "failed"` + an error string — it must not throw.
    func testRunSyncFailureResolvesWithFailedStatus() async throws {
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: "swift-runsync-fail",
            steps: [[
                "id": "boom",
                "kind": "workflow.call",
                "workflowKey": "no-such-target",
                "input": [String: Any](),
            ]],
            requiresClientApply: false,
            syncCallable: true
        )

        let result = try await client.workflows.runSync(
            workflowKey: "swift-runsync-fail",
            runKey: "swift-b2-run",
            contextDocId: contextDocId
        )

        XCTAssertEqual(result.status, "failed")
        XCTAssertFalse(result.error?.isEmpty ?? true, "failed run must carry an error string")
    }

    /// [JS CLIENT.B8] edge: invoking runSync on a workflow that did NOT opt
    /// into syncCallable surfaces the documented "is not syncCallable" error.
    func testRunSyncNotSyncCallableSurfacesError() async throws {
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: "swift-runsync-notopt",
            steps: [["id": "n", "kind": "noop", "message": "ok"]],
            requiresClientApply: false,
            syncCallable: false
        )

        do {
            _ = try await client.workflows.runSync(
                workflowKey: "swift-runsync-notopt",
                contextDocId: contextDocId
            )
            XCTFail("Expected runSync to throw for a non-syncCallable workflow")
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("not syncCallable"),
                "Expected 'is not syncCallable' in error, got: \(msg)"
            )
        }
    }

    /// [JS CLIENT.B4] idempotency: re-running with the same runKey returns
    /// the prior run (`existing == true`, same runId) instead of re-executing.
    func testRunSyncSameRunKeyReturnsExistingRun() async throws {
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: "swift-runsync-idem",
            steps: [["id": "n", "kind": "noop", "message": "ok", "saveAs": "output"]],
            requiresClientApply: false,
            syncCallable: true
        )

        let first = try await client.workflows.runSync(
            workflowKey: "swift-runsync-idem",
            runKey: "swift-idem",
            contextDocId: contextDocId
        )
        let second = try await client.workflows.runSync(
            workflowKey: "swift-runsync-idem",
            runKey: "swift-idem",
            contextDocId: contextDocId
        )

        XCTAssertEqual(first.runId, second.runId)
        XCTAssertEqual(second.existing, true)
    }

    /// [JS CLIENT.timeoutMs] timeoutMs is forwarded and a fast workflow still
    /// completes well inside it.
    func testRunSyncTimeoutMsForwarded() async throws {
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: "swift-runsync-timeout",
            steps: [["id": "n", "kind": "noop", "message": "ok", "saveAs": "output"]],
            requiresClientApply: false,
            syncCallable: true
        )

        let result = try await client.workflows.runSync(
            workflowKey: "swift-runsync-timeout",
            runKey: "swift-timeout-run",
            contextDocId: contextDocId,
            timeoutMs: 5000
        )
        XCTAssertTrue(
            ["completed", "apply_pending"].contains(result.status),
            "unexpected status: \(result.status)"
        )
    }

    /// #1112: `workflowStarted` must emit exactly once per start, from the
    /// server-pushed WS frame only (JS parity — JS never emits on the local
    /// HTTP start path). Pre-#1112 Swift emitted from both, doubling every
    /// start observed over a live WebSocket.
    func testWorkflowStartedEmitsOnceFromWSFrameOnly() async throws {
        try await ctx.setupWorkflow(
            appId: testApp.appId,
            workflowKey: "swift-started-once",
            steps: [["id": "n", "kind": "noop", "message": "ok"]],
            requiresClientApply: false,
            syncCallable: false
        )

        try await client.connect()
        try await waitForConnection(client: client)

        let recorder = StartedEventRecorder()
        let sub = client.events.on(.workflowStarted) { (e: WorkflowStartedEvent) in
            recorder.append(e)
        }
        defer { sub.cancel() }

        let result = try await client.workflows.start(
            workflowKey: "swift-started-once",
            input: ["topic": "once"],
            options: StartWorkflowOptions(
                runKey: "swift-1112-once",
                contextDocId: contextDocId
            )
        )
        XCTAssertFalse(result.runId.isEmpty)

        // Wait for the WS frame, then linger so a duplicate local emit
        // (the pre-#1112 bug) would have time to land.
        try await eventually(timeout: 8, description: "workflowStarted WS frame") {
            recorder.count >= 1
        }
        try await delay(1.0)

        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 1,
                       "workflowStarted must emit exactly once per start (WS frame only)")
        XCTAssertEqual(events.first?.runId, result.runId)
        XCTAssertEqual(events.first?.workflowKey, "swift-started-once")
        XCTAssertNotNil(events.first?.workflowId,
                        "WS-frame emits carry workflowId; the removed local emit could not")
    }
}

/// Thread-safe recorder for `WorkflowStartedEvent`s.
private final class StartedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WorkflowStartedEvent] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func append(_ e: WorkflowStartedEvent) {
        lock.lock()
        events.append(e)
        lock.unlock()
    }

    func snapshot() -> [WorkflowStartedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
