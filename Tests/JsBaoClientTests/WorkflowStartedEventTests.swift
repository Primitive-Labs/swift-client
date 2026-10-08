import XCTest
@testable import JsBaoClient

/// Live coverage for the `workflowStarted` event a `client.workflows.start`
/// produces (#1112). The case used to live beside the `runSync` suite, which
/// retired with that client door (#3188).
final class WorkflowStartedEventTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var contextDocId: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-started-event")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        // A known contextDocId to scope runs against (mirrors the JS test
        // setup — the test owner has no rootDocId fixture).
        contextDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "started ctx doc"
        )
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
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
            requiresClientApply: false
        )

        try await client.connect()
        try await waitForConnection(client: client)

        let recorder = StartedEventRecorder()
        let sub = client.eventEmitter.subscribe(WorkflowStartedEvent.self) { e in
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
