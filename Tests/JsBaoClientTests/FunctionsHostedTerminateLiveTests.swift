import XCTest
@testable import JsBaoClient

/// `client.functions.terminate` STOPS a running task run on a deployed engine
/// (#3190 behavior 35).
///
/// The local Workflows engine answers "Not implemented yet" to
/// `instance.terminate()`, so `FunctionsLiveTests` accepts either a terminal
/// status or `.unavailable` there. This case accepts only success, so it runs
/// only against a hosted environment: set `TEST_HOSTED_TERMINATE=1` beside
/// `TEST_HTTP_URL`, `TEST_WS_URL`, `TEST_SUPERADMIN_JWT` and
/// `TEST_GLOBAL_ADMIN_APP_ID` from the environment's env file. Anywhere else it
/// is skipped.
final class FunctionsHostedTerminateLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    private static let sleeper = """
    export default async function (input, ctx, step) {
      await step.do("mark", async () => ({ at: Date.now() }));
      await step.sleep("nap", 120000);
      return { slept: true };
    }
    """

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["TEST_HOSTED_TERMINATE"] == "1" else {
            throw XCTSkip("terminate success needs a deployed engine (TEST_HOSTED_TERMINATE=1)")
        }
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-hosted-terminate")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx?.cleanup()
    }

    func testTerminateStopsARunningTaskRunOnADeployedEngine() async throws {
        let functionKey = "swift-hosted-terminate-\(Int(Date().timeIntervalSince1970))"
        try await ctx.pushFunction(
            appId: testApp.appId, functionKey: functionKey, bundle: Self.sleeper
        )
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let running = try await client.functions.start(
            functionKey, input: nil as JSONValue?, contextDocId: docId
        )
        let stopped = try await client.functions.terminate(
            FunctionRunRef(functionKey: functionKey, runKey: running.runKey, contextDocId: docId)
        )
        XCTAssertEqual(stopped.status, "terminated")

        let read = try await client.functions.getStatus(runId: running.runId)
        XCTAssertEqual(read.status, "terminated")
    }
}
