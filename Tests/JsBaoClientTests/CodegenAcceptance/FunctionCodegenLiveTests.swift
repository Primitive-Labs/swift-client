import XCTest
@testable import JsBaoClient

/// The generated Swift function invokers against the LIVE dev server — #3344
/// behavior 13.
///
/// The hermetic suite proves what a generated invoker puts on the wire. What
/// only the platform can say is that the declared schemas it was generated
/// from are the schemas the server validates against: a pushed request
/// function answers the generated invoker's typed input with its typed output,
/// a pushed task function started through the generated invoker settles with
/// typed output through both `waitFor` and `getStatus`, and a nullable-root
/// input reaches the handler as an explicit `null` rather than as the `{}` an
/// omitted `rootInput` would become.
///
/// The functions are pushed under the acceptance fixtures' own keys
/// (`greet`, `order-sweep`, `nullable-note`) because the generated invokers pin
/// them; a function key is per-app and the app is created fresh here.
final class FunctionCodegenLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-fn-codegen")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    /// A cold sandbox load can exceed the 5 s platform default; the budget
    /// under test is the handler's, not the loader's.
    private let generousTimeout: TimeInterval = 20

    /// `greet.toml`'s schemas, as the fixture declares them.
    func testPushedRequestFunctionAnswersTheGeneratedInvokersTypedInput() async throws {
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: "greet",
            bundle: "export default async (input) => ({ greeting: `hello ${input.name}` });",
            inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["name"],
                "properties": ["name": ["type": "string"]],
            ],
            outputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["greeting"],
                "properties": ["greeting": ["type": "string"]],
            ]
        )

        let result = try await greet(client).invoke(
            input: GreetInput(name: "Ada"), timeout: generousTimeout
        )
        XCTAssertEqual(result.status, "completed", "\(String(describing: result.error))")
        XCTAssertEqual(result.output?.greeting, "hello Ada")
    }

    /// `order-sweep.toml`'s schemas, started and settled through the generated
    /// task verbs.
    func testPushedTaskFunctionSettlesThroughTheGeneratedWaitForAndGetStatus() async throws {
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: "order-sweep",
            bundle: "export default async () => ({ swept: 3 });",
            durable: true,
            inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "properties": ["olderThanDays": ["type": "integer"]],
            ],
            outputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["swept"],
                "properties": ["swept": ["type": "number"]],
            ]
        )
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        let sweep = orderSweep(client)
        let started = try await sweep.start(input: nil, contextDocId: docId)
        XCTAssertFalse(started.runId.isEmpty)

        let settled = try await sweep.waitFor(
            runId: started.runId, options: WaitForWorkflowOptions(timeout: 60)
        )
        XCTAssertEqual(settled.status, "completed", "\(String(describing: settled.error))")
        XCTAssertEqual(settled.output?.swept, 3)

        let status = try await sweep.getStatus(runId: started.runId)
        XCTAssertEqual(status.status, "completed")
        XCTAssertEqual(status.output?.swept, 3)
    }

    /// `nullable-note.toml`: the emitter's explicit-null branch, end to end.
    /// `invoke(input: nil)` must make the handler see `null` — an omitted
    /// `rootInput` would arrive as `{}`, which `type: ["string","null"]`
    /// rejects with a 400.
    func testNullableRootInputReachesTheHandlerAsAnExplicitNull() async throws {
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: "nullable-note",
            bundle: "export default async (input) => ({ seen: input === null ? \"null\" : typeof input });",
            inputSchema: ["type": ["string", "null"]],
            outputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["seen"],
                "properties": ["seen": ["type": "string"]],
            ]
        )

        let note = nullableNote(client)
        let nulled = try await note.invoke(input: nil, timeout: generousTimeout)
        XCTAssertEqual(nulled.status, "completed", "\(String(describing: nulled.error))")
        XCTAssertEqual(nulled.output?.seen, "null")

        let stringed = try await note.invoke(input: "hi", timeout: generousTimeout)
        XCTAssertEqual(stringed.status, "completed", "\(String(describing: stringed.error))")
        XCTAssertEqual(stringed.output?.seen, "string")
    }
}
