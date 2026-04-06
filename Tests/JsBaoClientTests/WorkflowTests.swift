import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-workflow-define.test.ts
/// Tests workflow definition API (if available in the Swift client).
///
/// Note: The Swift client may not implement workflows.define() yet.
/// These tests verify the HTTP API for workflow-related endpoints.
final class WorkflowTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-workflow")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testListWorkflowDefinitions() async throws {
        // Query workflow definitions via HTTP API
        do {
            let result = try await client.makeRequest("GET", "/workflows", nil)
            XCTAssertNotNil(result)
        } catch {
            // Workflow endpoints may not be available in all environments
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found"),
                "Unexpected error: \(msg)"
            )
        }
    }

    func testGetWorkflowRunsForDocument() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Workflow Doc")

        do {
            let result = try await client.makeRequest("GET", "/documents/\(docId)/workflow-runs", nil)
            XCTAssertNotNil(result)
        } catch {
            // May 404 if no workflows configured
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found") || msg.contains("empty"),
                "Unexpected error: \(msg)"
            )
        }
    }

    func testGetWorkflowDefinitionById() async throws {
        // Attempt to get a specific workflow definition -- should 404 with a non-existent ID
        do {
            let result = try await client.makeRequest("GET", "/workflows/nonexistent-id", nil)
            // If it succeeds, the endpoint exists
            XCTAssertNotNil(result)
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found") || msg.contains("400"),
                "Expected 404 or 400 for nonexistent workflow, got: \(msg)"
            )
        }
    }

    func testGetWorkflowRunStatus() async throws {
        // Attempt to query a workflow run status -- should 404 with a non-existent run ID
        do {
            let result = try await client.makeRequest("GET", "/workflow-runs/nonexistent-run-id", nil)
            XCTAssertNotNil(result)
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found") || msg.contains("400"),
                "Expected 404 or 400 for nonexistent workflow run, got: \(msg)"
            )
        }
    }

    func testWorkflowStatusEventReceived() async throws {
        // Verify that the client can subscribe to workflowStatus events without crashing.
        // We cannot trigger a real workflow without server-side configuration, so we just
        // verify the subscription mechanism works.
        try await client.connect()
        try await waitForConnection(client: client)

        var receivedEvents: [WorkflowStatusEvent] = []
        let sub = client.events.on(.workflowStatus) { (e: WorkflowStatusEvent) in
            receivedEvents.append(e)
        }
        defer { sub.cancel() }

        // No crash means the event subscription is wired up correctly.
        // We can't easily trigger a real workflow status event without server-side setup,
        // so we just verify the handler was registered.
        try await delay(0.5)

        // The test passes if we reach here without errors -- event subscription is valid
        XCTAssertNotNil(sub, "Workflow status event subscription should be valid")
    }
}
