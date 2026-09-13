import XCTest
@testable import JsBaoClient

/// `client.functions` — the wire shape and envelope handling of the Swift
/// port of the JS `FunctionsAPI` (`src/client/api/functionsApi.ts`), #3278
/// behaviors 1–8 and 12 plus the encoding edge cases.
///
/// Server-free: every method runs over a `RecordingTransport`, which records
/// the request it was handed and answers scripted bytes through the real
/// `Transport` decode / non-2xx policy, so what these tests pin is exactly
/// what reaches the wire and exactly how a body comes back.
final class FunctionsAPIHermeticTests: XCTestCase {

    /// #3344 retired the untyped `invoke` / `start` entry points: the
    /// generated `<Key>Function` invokers are the way a Swift app calls a
    /// function, and a caller with no per-key type names the witness instead.
    /// These suites exercise the ENVELOPE rather than any per-key type, so
    /// they take exactly that route — which also keeps the supported dynamic
    /// recipe under test.
    private typealias Dynamic = FunctionResult<JSONValue>
    private static let noInput: JSONValue? = nil

    private func makeApi(_ transport: RecordingTransport) -> FunctionsAPI {
        FunctionsAPI(transport: transport, workflows: WorkflowsAPI(transport: transport))
    }

    private func makeApi(json: String, status: Int = 200) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (makeApi(transport), transport)
    }

    /// The raw request body, parsed with `JSONSerialization` so an exact
    /// integer can be read back as the `NSNumber` it was written as.
    private func rawBody(_ call: RecordedRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(call?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let completedEnvelope = """
    {"status":"completed","output":{"message":"hello Ada"},
     "limits":{"cpuMs":5000,"subRequests":64,"ratePerMinute":1200}}
    """

    private static let startEnvelope = """
    {"runId":"run-1","runKey":"rk-1","instanceId":"app-doc-run-1","status":"running"}
    """

    // MARK: - Behavior 1: the invoke request

    func testInvokePostsTheFunctionsRouteWithEveryBodyField() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)

        _ = try await api.invoke(
            "greet",
            input: ["name": "Ada"],
            contextDocId: "doc-1",
            meta: ["source": "test"],
            timeout: 10
        ) as Dynamic

        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.path, "/functions/greet")
        let body = try XCTUnwrap(call.jsonBody)
        XCTAssertEqual(body["rootInput"], ["name": "Ada"])
        XCTAssertEqual(body["contextDocId"], "doc-1")
        XCTAssertEqual(body["meta"], ["source": "test"])
        // Seconds on this side, `timeoutMs` on the wire.
        XCTAssertEqual(body["timeoutMs"], 10000)
    }

    /// Edge case: a key with `/` or spaces is one percent-encoded segment, so
    /// it can never be read as a deeper route and never traps in
    /// `URLComponents`.
    func testInvokeEncodesTheFunctionKeyAsOneSegment() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)
        _ = try await api.invoke("orders/sync it", input: Self.noInput) as Dynamic
        XCTAssertEqual(transport.lastCall?.path, "/functions/orders%2Fsync%20it")
    }

    /// Edge case: `timeout` nil, zero or negative omits `timeoutMs`; a
    /// fractional timeout is sent as whole milliseconds.
    func testInvokeTimeoutIsOmittedUnlessPositiveAndSentAsWholeMilliseconds() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)

        for timeout: TimeInterval? in [nil, 0, -1] {
            _ = try await api.invoke("greet", input: Self.noInput, timeout: timeout) as Dynamic
            let body = try XCTUnwrap(transport.lastCall?.jsonBody)
            XCTAssertNil(body["timeoutMs"], "timeout \(String(describing: timeout)) must omit timeoutMs")
            XCTAssertNil(body["contextDocId"])
            XCTAssertNil(body["meta"])
        }

        _ = try await api.invoke("greet", input: Self.noInput, timeout: 1.5) as Dynamic
        XCTAssertEqual(transport.lastCall?.jsonBody?["timeoutMs"], 1500)
    }

    /// Edge case, restated after #3344: the untyped entry point's `[:]`
    /// default is gone, so "no input" is now the witness recipe's `nil`, which
    /// OMITS `rootInput` and lets the server supply `{}`. A caller that means
    /// the empty object says so, and it reaches the wire as `{}`.
    func testNoInputOmitsRootInputAndAnExplicitEmptyObjectIsSentAsOne() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)
        _ = try await api.invoke("greet", input: Self.noInput) as Dynamic
        XCTAssertNil(transport.lastCall?.jsonBody?["rootInput"])

        _ = try await api.invoke("greet", input: JSONValue.object([:])) as Dynamic
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], [:])
    }

    // MARK: - Behavior 2: the three settled envelopes decode and never throw

    func testCompletedEnvelopeDecodesStatusOutputAndLimits() async throws {
        let (api, _) = makeApi(json: Self.completedEnvelope)
        let result: Dynamic = try await api.invoke("greet", input: Self.noInput)
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["message"]?.stringValue, "hello Ada")
        XCTAssertNil(result.error)
        XCTAssertNil(result.errorCode)
        XCTAssertEqual(
            result.limits,
            FunctionInvokeLimits(cpuMs: 5000, subRequests: 64, ratePerMinute: 1200)
        )
    }

    /// A handler that threw is a settled invocation, not a thrown error. The
    /// sandbox ran, so `limits` is present on it too (edge case).
    func testFailedEnvelopeDecodesErrorAndErrorCodeAndKeepsLimits() async throws {
        let (api, _) = makeApi(json: """
        {"status":"failed","error":"nope","errorCode":"FUNCTION_HANDLER_THREW",
         "limits":{"cpuMs":5000,"subRequests":64,"ratePerMinute":1200}}
        """)
        let result: Dynamic = try await api.invoke("boom", input: Self.noInput)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.error, "nope")
        XCTAssertEqual(result.errorCode, "FUNCTION_HANDLER_THREW")
        XCTAssertNil(result.output)
        XCTAssertEqual(result.limits?.cpuMs, 5000)
    }

    /// A timeout has no output and — the sandbox never reported — no limits.
    func testTimeoutEnvelopeHasNilOutputAndNilLimits() async throws {
        let (api, _) = makeApi(json: #"{"status":"timeout"}"#)
        let result: Dynamic = try await api.invoke("slow", input: Self.noInput, timeout: 1)
        XCTAssertEqual(result.status, "timeout")
        XCTAssertNil(result.output)
        XCTAssertNil(result.limits)
        XCTAssertNil(result.error)
    }

    /// Edge case: an `output` of JSON `null` is an ABSENT output on the typed
    /// surface, whichever witness the caller binds — the dynamic `JSONValue`
    /// one included. (Before #3344 the untyped entry point surfaced it as
    /// `.null`; that entry point is gone, and with it the two spellings.)
    func testNullOutputDecodesToNilUnderEveryWitness() async throws {
        let (api, _) = makeApi(json: #"{"status":"completed","output":null}"#)
        let dynamic: Dynamic = try await api.invoke("nothing", input: Self.noInput)
        XCTAssertEqual(dynamic.status, "completed")
        XCTAssertNil(dynamic.output)

        let typed: FunctionResult<[String: String]> = try await api.invoke("nothing", input: nil as String?)
        XCTAssertEqual(typed.status, "completed")
        XCTAssertNil(typed.output)
    }

    // MARK: - Behavior 3: a refusal is an HttpError carrying the server's code

    func testNon2xxThrowsHttpErrorWithServerCodeFromTheBody() async throws {
        let (api, _) = makeApi(
            json: #"{"error":"Function access denied","errorCode":"FUNCTION_ACCESS_DENIED"}"#,
            status: 403
        )
        do {
            _ = try await api.invoke("private", input: Self.noInput) as Dynamic
            XCTFail("a 403 must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, "FUNCTION_ACCESS_DENIED")
        }
    }

    /// Edge case: `meta` is not validated client-side; the server's
    /// `400 INVALID_META` surfaces as `HttpError`.
    func testOversizedMetaIsSentAsGivenAndTheServersRefusalSurfaces() async throws {
        let (api, transport) = makeApi(
            json: #"{"error":"meta exceeds 1 KB","errorCode":"INVALID_META"}"#,
            status: 400
        )
        let big = String(repeating: "x", count: 2048)
        do {
            _ = try await api.invoke("greet", input: Self.noInput, meta: ["blob": big]) as Dynamic
            XCTFail("a 400 must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverCode, "INVALID_META")
        }
        // The client sent it as-is rather than refusing locally.
        XCTAssertEqual(transport.lastCall?.jsonBody?["meta"]?["blob"]?.stringValue, big)
    }

    // MARK: - Behavior 4: typed input goes as the JSON value it encodes to

    private struct GreetInput: Encodable { let name: String }
    private struct GreetOutput: Decodable, Sendable, Equatable { let message: String }

    func testTypedInvokeSendsAnObjectInputAndDecodesTheTypedOutput() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)
        let result: FunctionResult<GreetOutput> = try await api.invoke(
            "greet",
            input: GreetInput(name: "Ada"),
            timeout: 2
        )
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], ["name": "Ada"])
        XCTAssertEqual(transport.lastCall?.jsonBody?["timeoutMs"], 2000)
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output, GreetOutput(message: "hello Ada"))
        XCTAssertEqual(result.limits?.subRequests, 64)
    }

    /// Edge case: an array, a string, a number or a boolean input is sent as
    /// that JSON value — never wrapped in an object, never replaced by `{}`.
    /// This is where the port deliberately does NOT follow `WorkflowsAPI`,
    /// whose `rootInput` is always an object.
    func testTypedInvokeSendsScalarAndArrayInputsUnchanged() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)

        _ = try await api.invoke("tags", input: ["a", "b"]) as FunctionResult<GreetOutput>
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], ["a", "b"])

        _ = try await api.invoke("shout", input: "hello") as FunctionResult<GreetOutput>
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], "hello")

        _ = try await api.invoke("double", input: 21) as FunctionResult<GreetOutput>
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], 21)

        _ = try await api.invoke("flag", input: true) as FunctionResult<GreetOutput>
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], true)
    }

    /// A nil typed input omits `rootInput` (the server supplies `{}`); an
    /// input that is present but encodes to JSON `null` is sent as `null`.
    func testTypedInvokeNilInputOmitsRootInputAndEncodedNullIsSentAsNull() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)

        _ = try await api.invoke("greet", input: nil as GreetInput?) as FunctionResult<GreetOutput>
        var body = try rawBody(transport.lastCall)
        XCTAssertNil(body["rootInput"], "a nil typed input must omit rootInput")

        // `String??` — the outer optional is the parameter, the inner one is
        // the input value, and `.some(nil)` encodes to a bare JSON `null`.
        let present: String?? = .some(nil)
        _ = try await api.invoke("greet", input: present) as FunctionResult<GreetOutput>
        body = try rawBody(transport.lastCall)
        XCTAssertTrue(body["rootInput"] is NSNull, "an input encoding to null goes as null, got \(String(describing: body["rootInput"]))")
    }

    private struct Unencodable: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Double.infinity)
        }
    }

    func testTypedInvokeWithAnUnencodableInputThrowsInvalidArgumentBeforeAnyRequest() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)
        do {
            _ = try await api.invoke("greet", input: Unencodable()) as FunctionResult<GreetOutput>
            XCTFail("an unencodable input must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        XCTAssertTrue(transport.calls.isEmpty, "no request may be made for an input that failed to encode")
    }

    func testTypedStartSendsTheEncodedInputAsRootInput() async throws {
        let (api, transport) = makeApi(json: Self.startEnvelope)
        let started = try await api.start("order-sync", input: ["x", "y"], runKey: "rk-1")
        XCTAssertEqual(transport.lastCall?.jsonBody?["rootInput"], ["x", "y"])
        XCTAssertEqual(started.runId, "run-1")

        _ = try await api.start("order-sync", input: nil as GreetInput?)
        let body = try rawBody(transport.lastCall)
        XCTAssertNil(body["rootInput"])

        do {
            _ = try await api.start("order-sync", input: Unencodable())
            XCTFail("an unencodable input must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - Behavior 5: an Int64 past 2^53 reaches the wire exactly

    private struct IdInput: Encodable { let id: Int64 }

    /// Retargeted at #3344: the case used to run through the untyped entry
    /// point's `[String: Any]`. A TYPED input keeps the same fidelity, because
    /// `JSONCoding.jsonObject` is `JSONEncoder.encode` →
    /// `JSONSerialization.jsonObject` and an `Int64` round-trips that exactly.
    /// The lossy path is `JSONValue` (whose `.number` is a `Double`), which is
    /// what a dynamic caller opts into either way.
    func testTypedInputKeepsALargeInt64Exact() async throws {
        let (api, transport) = makeApi(json: Self.completedEnvelope)
        let big: Int64 = 9_007_199_254_740_993  // 2^53 + 1
        _ = try await api.invoke("ids", input: IdInput(id: big)) as Dynamic
        let body = try rawBody(transport.lastCall)
        let sent = try XCTUnwrap((body["rootInput"] as? [String: Any])?["id"] as? NSNumber)
        XCTAssertEqual(sent.int64Value, big)
        // The bytes themselves carry the exact digits — no `Double` rounding.
        let text = try XCTUnwrap(transport.lastCall?.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(text.contains("9007199254740993"), text)
    }

    // MARK: - Behavior 6: start

    func testStartPostsTheSameRouteWithRunKeyAndNoTimeoutMsAndDecodesTheStartEnvelope() async throws {
        let (api, transport) = makeApi(json: Self.startEnvelope)
        let started = try await api.start(
            "order-sync",
            input: ["orderId": "o-1"],
            runKey: "order-o-1",
            contextDocId: "doc-1",
            meta: ["source": "test"]
        )
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.path, "/functions/order-sync")
        let body = try XCTUnwrap(call.jsonBody)
        XCTAssertEqual(body["rootInput"], ["orderId": "o-1"])
        XCTAssertEqual(body["runKey"], "order-o-1")
        XCTAssertEqual(body["contextDocId"], "doc-1")
        XCTAssertEqual(body["meta"], ["source": "test"])
        XCTAssertNil(body["timeoutMs"], "a task start carries no timeoutMs")

        XCTAssertEqual(started.runId, "run-1")
        XCTAssertEqual(started.runKey, "rk-1")
        XCTAssertEqual(started.instanceId, "app-doc-run-1")
        XCTAssertEqual(started.status, "running")
        XCTAssertNil(started.existing)
    }

    func testStartDecodesExistingTrueOnAReplay() async throws {
        let (api, _) = makeApi(json: """
        {"runId":"run-1","runKey":"rk-1","instanceId":"i-1","status":"completed",
         "existing":true,"output":{"doubled":42}}
        """)
        let replayed = try await api.start("order-sync", input: Self.noInput, runKey: "rk-1")
        XCTAssertEqual(replayed.existing, true)
        XCTAssertEqual(replayed.output?["doubled"]?.numberValue, 42)
    }

    // MARK: - Behavior 7: the mode check

    func testInvokeOnAStartEnvelopeThrowsFunctionModeMismatchWithTheRunId() async throws {
        let (api, _) = makeApi(json: Self.startEnvelope)
        do {
            _ = try await api.invoke("order-sync", input: Self.noInput) as Dynamic
            XCTFail("a start envelope must be refused by invoke")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertEqual(error.details?["functionKey"]?.stringValue, "order-sync")
            XCTAssertEqual(error.details?["runId"]?.stringValue, "run-1")
            XCTAssertTrue(error.message.contains("is a task function"), error.message)
            XCTAssertTrue(error.message.contains("functions.start"), error.message)
        }
    }

    func testStartOnAResultEnvelopeThrowsFunctionModeMismatchWithTheStatus() async throws {
        let (api, _) = makeApi(json: Self.completedEnvelope)
        do {
            _ = try await api.start("greet", input: Self.noInput)
            XCTFail("a result envelope must be refused by start")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertEqual(error.details?["functionKey"]?.stringValue, "greet")
            XCTAssertEqual(error.details?["status"]?.stringValue, "completed")
            XCTAssertTrue(error.message.contains("is a request function"), error.message)
            XCTAssertTrue(error.message.contains("functions.invoke"), error.message)
        }
    }

    // MARK: - Behavior 8: getStatus by run id

    func testGetStatusGetsTheRunIdRouteAndFlattensTheEnvelope() async throws {
        let (api, transport) = makeApi(json: """
        {"status":{"status":"completed","output":{"doubled":42}},
         "run":{"runId":"run/1","runKey":"rk-1","status":"completed"}}
        """)
        let status = try await api.getStatus(runId: "run/1")
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .get)
        XCTAssertEqual(call.path, "/workflows/runs/run%2F1/status")
        XCTAssertEqual(status.status, "completed")
        XCTAssertEqual(status.output?["doubled"]?.numberValue, 42)
        XCTAssertEqual(status.run?.runKey, "rk-1")

        let typed: WorkflowStatus<[String: Int]> = try await api.getStatus(runId: "run/1")
        XCTAssertEqual(typed.output, ["doubled": 42])
    }

    func testGetStatusWithAnEmptyRunIdThrowsInvalidArgumentWithoutARequest() async throws {
        let (api, transport) = makeApi(json: "{}")
        do {
            _ = try await api.getStatus(runId: "")
            XCTFail("an empty runId must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - Behavior 12: terminate is the workflow route, and the method set is JS's

    func testTerminateHitsTheWorkflowInstanceRouteWithTheFunctionKeyInTheKeySlot() async throws {
        let (api, transport) = makeApi(json: """
        {"status":{"status":"terminated"},"run":{"runId":"run-1","runKey":"rk 1","status":"terminated"}}
        """)
        let result = try await api.terminate(
            FunctionRunRef(functionKey: "order-sync", runKey: "rk 1", contextDocId: "doc/1")
        )
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(
            call.path,
            "/workflows/order-sync/instances/rk%201/terminate?contextDocId=doc%2F1"
        )
        XCTAssertEqual(result.status, "terminated")

        // Without a contextDocId the query is omitted, as workflows.terminate does.
        _ = try await api.terminate(FunctionRunRef(functionKey: "order-sync", runKey: "rk-2"))
        XCTAssertEqual(transport.lastCall?.path, "/workflows/order-sync/instances/rk-2/terminate")

        let typed: WorkflowStatus<[String: Int]> = try await api.terminate(
            FunctionRunRef(functionKey: "order-sync", runKey: "rk-2")
        )
        XCTAssertEqual(typed.status, "terminated")
    }

    /// The whole method set is JS's — invoke, start, getStatus, waitFor,
    /// terminate — and nothing else. The client-apply trio stays on
    /// `workflows`, where both clients keep it.
    func testTheFunctionsSubApiCarriesExactlyTheJsMethodSet() throws {
        let source = try ClientSourceText.code("API/FunctionsAPI.swift")
        let pattern = try NSRegularExpression(pattern: #"public func ([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(source.startIndex..., in: source)
        let names = Set(pattern.matches(in: source, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        })
        XCTAssertEqual(names, ["invoke", "start", "getStatus", "waitFor", "terminate"])
        for removed in ["claimApply", "releaseApply", "confirmApply", "runSync", "listRuns", "define"] {
            XCTAssertFalse(source.contains("func \(removed)"), "\(removed) does not belong on functions")
        }
    }

    /// `client.functions` is registered on the client, over the same transport
    /// as `client.workflows`.
    func testTheClientRegistersTheFunctionsSubApi() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "functions-registration",
            token: "test-token",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        let functions: FunctionsAPI = client.functions
        XCTAssertNotNil(functions)
    }
}
