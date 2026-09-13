import XCTest
@testable import JsBaoClient

/// Acceptance tests for the CLI-generated Swift FUNCTION codegen — #3344
/// behaviors 12 and 15, edges E5, E6, E7 and E13.
///
/// The committed `.generated.swift` files under `GeneratedFunctions/` are
/// emitted by `primitive functions codegen --lang swift` from the fixture
/// TOMLs in `cli/tests/fixtures/swift-function-invoker-acceptance/functions/`
/// and committed here so that compiling this target IS the proof the generated
/// Swift builds under the Swift 6 language mode (behavior 11) and binds the
/// real client surface.
///
/// Server-free: a `LoopbackAPIServer` answers a real `JsBaoClient`'s requests
/// and records what was sent, so what these tests pin is exactly the body a
/// generated invoker puts on the wire. Every claim about what the PLATFORM
/// does with an invocation is proved live instead
/// (`FunctionCodegenLiveTests.swift`).
final class FunctionCodegenAcceptanceHermeticTests: XCTestCase {

    private var servers: [LoopbackAPIServer] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for server in servers { server.stop() }
        servers = []
    }

    /// A real client whose API requests are answered with one canned body.
    private func makeClient(answering json: String) throws -> (JsBaoClient, LoopbackAPIServer) {
        let server = try LoopbackAPIServer(responder: { _ in .json(json) })
        let baseUrl = try server.start()
        servers.append(server)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "fn-codegen-acceptance",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        return (client, server)
    }

    private static let completedGreet = #"{"status":"completed","output":{"greeting":"hello Ada"}}"#
    private static let started = #"{"runId":"run-1","runKey":"rk-1","status":"running"}"#
    private static let completedSeen = #"{"status":"completed","output":{"seen":"null"}}"#

    private func functionCall(
        _ server: LoopbackAPIServer,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LoopbackAPIServer.Request {
        try XCTUnwrap(
            server.requests.last(where: { $0.apiPathOnly == path }),
            "no request to \(path); saw \(server.paths)",
            file: file, line: line
        )
    }

    // MARK: - Behavior 12: the generated types round-trip

    func testGreetInputRoundTrips() throws {
        let input = GreetInput(name: "Ada")
        let decoded = try JSONDecoder().decode(
            GreetInput.self, from: try JSONEncoder().encode(input)
        )
        XCTAssertEqual(decoded, input)
    }

    func testServerShapedJSONDecodesIntoGreetOutput() throws {
        let out = try JSONDecoder().decode(
            GreetOutput.self, from: Data(#"{"greeting":"hello Ada"}"#.utf8)
        )
        XCTAssertEqual(out.greeting, "hello Ada")
    }

    /// E5 + E7: the `oneOf` output decodes by discriminator into each branch;
    /// a required-nullable property carries an explicit null and an
    /// open-object property keeps the keys the schema does not name.
    func testSettleOutputDecodesByDiscriminatorIntoEachBranch() throws {
        let settled = try JSONDecoder().decode(
            SettleOutput.self, from: Data(#"{"kind":"settled","note":null}"#.utf8)
        )
        guard case let .settled(branch) = settled else {
            return XCTFail("expected the settled branch, got \(settled)")
        }
        XCTAssertEqual(branch.kind, .settled)
        XCTAssertNil(branch.note)
        // Re-encoding keeps the explicit null the schema requires.
        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(branch)
        ) as? [String: Any]
        XCTAssertTrue(reencoded?.keys.contains("note") ?? false)

        let pending = try JSONDecoder().decode(
            SettleOutput.self,
            from: Data(#"{"kind":"pending","details":{"queued":3,"why":"rate"}}"#.utf8)
        )
        guard case let .pending(branch2) = pending else {
            return XCTFail("expected the pending branch, got \(pending)")
        }
        XCTAssertEqual(branch2.kind, .pending)
        XCTAssertEqual(branch2.details["queued"], .number(3))
        XCTAssertEqual(branch2.details["why"], .string("rate"))
    }

    // MARK: - Behavior 12: what a generated invoker puts on the wire

    func testGeneratedInvokePostsTheFunctionsRouteWithTheEncodedInput() async throws {
        let (client, server) = try makeClient(answering: Self.completedGreet)
        let result = try await greet(client).invoke(input: GreetInput(name: "Ada"))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?.greeting, "hello Ada")

        let call = try functionCall(server, path: "/functions/greet")
        XCTAssertEqual(call.method, "POST")
        let body = try XCTUnwrap(call.jsonBody)
        XCTAssertEqual((body["rootInput"] as? [String: Any])?["name"] as? String, "Ada")
        XCTAssertNil(body["contextDocId"])
        XCTAssertNil(body["meta"])
    }

    /// E13: `meta` stays reachable through the generated invoker after the
    /// untyped entry points are gone.
    func testGeneratedInvokeForwardsMetaAndContextDocId() async throws {
        let (client, server) = try makeClient(answering: Self.completedGreet)
        _ = try await greet(client).invoke(
            input: GreetInput(name: "Ada"),
            contextDocId: "doc-1",
            meta: ["source": "codegen"],
            timeout: 10
        )
        let body = try XCTUnwrap(try functionCall(server, path: "/functions/greet").jsonBody)
        XCTAssertEqual(body["contextDocId"] as? String, "doc-1")
        XCTAssertEqual((body["meta"] as? [String: Any])?["source"] as? String, "codegen")
        XCTAssertEqual(body["timeoutMs"] as? Int, 10_000)
    }

    func testGeneratedStartPinsTheKeyAndOmitsAnAbsentRootInput() async throws {
        let (client, server) = try makeClient(answering: Self.started)
        let started = try await orderSweep(client).start(input: nil)
        XCTAssertEqual(started.runId, "run-1")

        let call = try functionCall(server, path: "/functions/order-sweep")
        XCTAssertEqual(call.method, "POST")
        let body = try XCTUnwrap(call.jsonBody)
        XCTAssertNil(body["rootInput"], "an absent optional input omits rootInput")
        XCTAssertNil(body["runKey"])
    }

    /// E6: a nullable root input. A value travels as that value; `nil` travels
    /// as an explicit `rootInput: null` — NOT as an omitted field, which the
    /// server would turn into `{}` and the schema would reject.
    func testNullableRootInputSendsTheValueOrAnExplicitNull() async throws {
        let (client, server) = try makeClient(answering: Self.completedSeen)

        _ = try await nullableNote(client).invoke(input: "hi")
        var body = try XCTUnwrap(try functionCall(server, path: "/functions/nullable-note").jsonBody)
        XCTAssertEqual(body["rootInput"] as? String, "hi")

        _ = try await nullableNote(client).invoke(input: nil)
        body = try XCTUnwrap(try functionCall(server, path: "/functions/nullable-note").jsonBody)
        XCTAssertTrue(
            body.keys.contains("rootInput"),
            "a nil nullable root must still send the field, as an explicit null"
        )
        XCTAssertTrue(body["rootInput"] is NSNull, "\(String(describing: body["rootInput"]))")
    }

    // MARK: - Behavior 15: the supported dynamic pattern

    /// With the untyped entry points gone, a no-input call with a discarded
    /// result names its own witness. This pins the recipe the migration and the
    /// docs use, so it stays a supported pattern.
    func testNoInputDynamicCallThroughThePinnedWitnessRecipe() async throws {
        let (client, server) = try makeClient(answering: Self.completedGreet)
        let result: FunctionResult<JSONValue> = try await client.functions.invoke(
            "greet", input: nil as JSONValue?
        )
        XCTAssertEqual(result.status, "completed")
        let body = try XCTUnwrap(try functionCall(server, path: "/functions/greet").jsonBody)
        XCTAssertNil(body["rootInput"], "a nil witness input omits rootInput; the server supplies {}")
    }

    /// The `start` half of the same recipe.
    func testNoInputDynamicStartThroughThePinnedWitnessRecipe() async throws {
        let (client, server) = try makeClient(answering: Self.started)
        let started: FunctionStartResult = try await client.functions.start(
            "order-sweep", input: nil as JSONValue?
        )
        XCTAssertEqual(started.runKey, "rk-1")
        XCTAssertNotNil(try functionCall(server, path: "/functions/order-sweep").jsonBody)
    }

    // MARK: - Behavior 15: the untyped entry points are gone

    /// The budget test counts `[String: Any]` sites; this says WHICH surface
    /// went away, so a re-introduction fails with the reason rather than an
    /// arithmetic mismatch.
    func testUntypedInvokeAndStartAreAbsentFromTheClientSurface() throws {
        let source = try ClientSourceText.code("API/FunctionsAPI.swift")
        XCTAssertFalse(
            source.contains("input: [String: Any] = [:]"),
            "the untyped invoke/start entry points are retired (#3344): generated "
                + "<Key>Function invokers and the generic overloads are the way in"
        )
        // The typed overloads are exactly what stayed.
        XCTAssertTrue(source.contains("public func invoke<Input: Encodable, Output: Decodable & Sendable>("))
        XCTAssertTrue(source.contains("public func start<Input: Encodable>("))
    }
}

// MARK: - Compile-only binding proof

/// References every generated member of every fixture. It is never called —
/// compiling it is the assertion that each invoker binds the client surface it
/// claims to, with the verb set its mode allows and nothing else.
@available(*, unavailable)
private func _functionInvokerBindingsCompile(_ client: JsBaoClient) async throws {
    // A request function: exactly `invoke`, typed both ways.
    let greetResult: FunctionResult<GreetOutput> =
        try await greet(client).invoke(input: GreetInput(name: "Ada"))
    _ = greetResult.output?.greeting

    // A task function: exactly start / getStatus / waitFor / terminate.
    let sweep = orderSweep(client)
    let startResult: FunctionStartResult = try await sweep.start(
        input: OrderSweepInput(olderThanDays: 30),
        runKey: "rk",
        contextDocId: "doc",
        meta: ["source": "compile"]
    )
    let status: WorkflowStatus<OrderSweepOutput> = try await sweep.getStatus(runId: startResult.runId)
    _ = status.output?.swept
    let settled: WaitForResult<OrderSweepOutput> = try await sweep.waitFor(runId: startResult.runId)
    _ = settled.output?.swept
    let ended: WorkflowStatus<OrderSweepOutput> = try await sweep.terminate(runKey: "rk")
    _ = ended.output?.swept

    // A schema-less function reaches `JSONValue` through the alias, and takes
    // no input at all.
    let echoResult: FunctionResult<EchoOutput> = try await echo(client).invoke()
    _ = echoResult.output

    // A digit-leading key: the mangled factory, type and struct all exist.
    let job = _123Job(client)
    let jobStart: FunctionStartResult = try await job.start(input: _123JobInput.string("go"))
    _ = try await job.waitFor(runId: jobStart.runId) as WaitForResult<_123JobOutput>

    // A nullable root input is REQUIRED and never double-optional: both a
    // value and `nil` type-check at the call site.
    let note = nullableNote(client)
    _ = try await note.invoke(input: "hi") as FunctionResult<NullableNoteOutput>
    _ = try await note.invoke(input: nil) as FunctionResult<NullableNoteOutput>

    // A discriminated `oneOf` output binds as the generated root enum.
    let settleResult: FunctionResult<SettleOutput> =
        try await settle(client).invoke(input: SettleInput(id: "o-1"))
    if case let .settled(branch) = settleResult.output { _ = branch.note }
}
