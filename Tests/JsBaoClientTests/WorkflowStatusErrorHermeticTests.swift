import XCTest
@testable import JsBaoClient

/// A failed run's structured error — #3449, project `server-functions` phase 4.
///
/// The status routes answer `status.error` as an OBJECT for every failed
/// durable run, DSL or function. `CFWorkflowStatus.error` was declared
/// `String?`, so the nested decode failed, the whole-block `try?` fell through
/// to the bare-string branch, and `decodeIfPresent(String.self, forKey:
/// .status)` threw `typeMismatch` on the dictionary — the exact text the issue
/// quotes. `functions.getStatus` threw instead of returning `failed`, and
/// `functions.waitFor` retried the throw as transient until its whole budget
/// was gone.
///
/// So the subject here is a DECODE, and the tests are written as one:
/// `decodeStatusBytes(_:)` takes the route's exact bytes and returns the
/// result. That helper is also the one D3449-005 names for the by-hand decode
/// of a real agent response captured by the hosted twin
/// (`tests/api/http/server-function-status-error-agent-3449.test.ts` prints it
/// under `#3449 agent status body:`), so it is `static` and takes a string on
/// purpose.
///
/// Server-free throughout: every method runs over a `RecordingTransport`.
final class WorkflowStatusErrorHermeticTests: XCTestCase {

    // MARK: - The vehicle

    /// Decode a status response from exactly the bytes the route sent.
    ///
    /// THE helper of D3449-005: paste the body the hosted twin logged and this
    /// answers whether Swift decodes it, with no server and no client.
    static func decodeStatusBytes(_ json: String) throws -> WorkflowStatusResult {
        try JSONDecoder().decode(WorkflowStatusResult.self, from: Data(json.utf8))
    }

    /// The same helper for the FUNCTION type — #3565. The two surfaces read
    /// one wire and answer different shapes, so a body a hosted twin logged is
    /// worth asking both questions of.
    static func decodeFunctionRunStatusBytes(_ json: String) throws -> FunctionRunStatus {
        try JSONDecoder().decode(FunctionRunStatus.self, from: Data(json.utf8))
    }

    private func makeApi(json: String, status: Int = 200) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (
            FunctionsAPI(transport: transport),
            transport
        )
    }

    private func makeWorkflows(json: String, status: Int = 200) -> WorkflowsAPI {
        WorkflowsAPI(transport: RecordingTransport(status: status, json: json))
    }

    // MARK: - Fixtures, as the routes really answer

    /// A task function refused by its own `outputSchema`, byte for byte as the
    /// engine records it: the CODE is the message's prefix, and `name` is the
    /// thrown error's own name. Measured against the live engine 2026-09-15 —
    /// an earlier reading of this issue had `name` carrying the code, and it
    /// does not.
    private static let failedTask = """
    {"status":{"status":"failed","output":null,
      "error":{"name":"Error",
               "message":"OUTPUT_SCHEMA_VIOLATION: Output schema validation failed: value.total must be number"}},
     "run":{"runId":"run-1","runKey":"rk-1","status":"failed"}}
    """

    /// The row-settled path (`settledStatusResponse`) and every failed DSL
    /// durable run (`flattenInstanceStatus` rewraps the nested string) — edge
    /// 26. The platform builds this object itself, so here `name` IS a
    /// platform word.
    private static let workflowError = """
    {"status":{"status":"failed","error":{"name":"WorkflowError","message":"step `charge` failed"}},
     "run":{"runId":"run-2","runKey":"rk-2","status":"failed"}}
    """

    /// What the DEPLOYED engine records when it keeps the message and drops
    /// the name (`server-function-settlement.ts` says so in place).
    private static let namelessError = """
    {"status":{"status":"failed","error":{"message":"boom"}},
     "run":{"runId":"run-3","runKey":"rk-3","status":"failed"}}
    """

    private func statusJSON(_ errorLiteral: String?, status: String = "failed", runId: String = "run-x") -> String {
        let errorPart = errorLiteral.map { ",\"error\":\($0)" } ?? ""
        return """
        {"status":{"status":"\(status)"\(errorPart)},
         "run":{"runId":"\(runId)","runKey":"rk-x","status":"\(status)"}}
        """
    }

    // MARK: - Behavior 6: the failed task decodes, and the read survives

    func testAFailedTaskRunDecodesIntoStatusErrorAndFailure() async throws {
        let (api, transport) = makeApi(json: Self.failedTask)

        let status = try await api.getStatus(runId: "run-1")

        XCTAssertEqual(transport.lastCall?.path, "/workflows/runs/run-1/status")
        XCTAssertEqual(status.status, "failed")
        // #3565 — the FUNCTION surface answers one structured `error`, so
        // this is where the message is and there is no second field beside it.
        let failure = try XCTUnwrap(status.error, "the structured error is the point")
        XCTAssertEqual(
            failure.message,
            "OUTPUT_SCHEMA_VIOLATION: Output schema validation failed: value.total must be number"
        )
        XCTAssertEqual(failure.name, "Error", "a thrown name is NOT the placeholder")
        XCTAssertNil(failure.code, "no code on the wire means no code here")
        XCTAssertNil(failure.details, "nothing beyond name and message was sent")
        // `run` is decoded through `FunctionRunInfo`, so this is also the
        // proof the WHOLE response decodes rather than the one field.
        XCTAssertEqual(status.run?.runId, "run-1")
    }

    /// The helper D3449-005 hands the sponsor. Same bytes, no client at all.
    func testDecodeStatusBytesReadsTheSameResultWithNoClient() throws {
        let status = try Self.decodeStatusBytes(Self.failedTask)

        XCTAssertEqual(status.status, "failed")
        XCTAssertEqual(status.failure?.name, "Error")
        XCTAssertTrue(status.error?.hasPrefix("OUTPUT_SCHEMA_VIOLATION") == true)
        XCTAssertEqual(status.run?.runKey, "rk-1")
    }

    // MARK: - Behavior 7: the remaining keys, and every surface that carries them

    func testExtraKeysBecomeDetailsWithTheirValuesIntact() async throws {
        let json = statusJSON(
            #"{"name":"Error","message":"boom","code":"FUNCTION_THREW","attempts":3,"tags":["a","b"]}"#
        )
        let (api, _) = makeApi(json: json)

        let status = try await api.getStatus(runId: "run-x")
        let failure = try XCTUnwrap(status.error)

        XCTAssertEqual(failure.name, "Error")
        XCTAssertEqual(failure.message, "boom")
        // #3565 — `code` is LIFTED out of the remaining keys into its own
        // field, and the rest stay where they arrived.
        XCTAssertEqual(failure.code, "FUNCTION_THREW")
        let details = try XCTUnwrap(failure.details?.objectValue)
        XCTAssertEqual(Set(details.keys), ["attempts", "tags"])
        XCTAssertEqual(details["attempts"]?.numberValue, 3)
        XCTAssertEqual(details["tags"]?.arrayValue?.compactMap(\.stringValue), ["a", "b"])
    }

    private struct Empty: Decodable, Sendable, Equatable {}

    func testTheTypedOverloadAndTheWorkflowSurfacesCarryAnEqualFailure() async throws {
        let json = statusJSON(#"{"name":"Error","message":"boom","code":"FUNCTION_THREW"}"#)

        let (api, _) = makeApi(json: json)
        let untyped = try await api.getStatus(runId: "run-x")

        let (typedApi, _) = makeApi(json: json)
        let typed: FunctionRunResult<Empty> = try await typedApi.getStatus(runId: "run-x")
        XCTAssertEqual(typed.error, untyped.error)

        // A function run IS a run row: the same wire rides the workflow
        // surfaces the run can also be read through — which is where every
        // failed DSL run has been throwing too, not only function ones. Those
        // surfaces keep their own shape (#3565 moved neither), so the two are
        // compared on the fact they must agree about.
        let viaWorkflows = try await makeWorkflows(json: json)
            .getStatus(workflowKey: "fn", runKey: "rk-x")
        XCTAssertEqual(viaWorkflows.failure?.message, untyped.error?.message)

        let viaTerminate = try await makeWorkflows(json: json)
            .terminate(workflowKey: "fn", runKey: "rk-x")
        XCTAssertEqual(viaTerminate.failure?.message, untyped.error?.message)
    }

    // MARK: - Behavior 8: the string form, and the absent one

    func testTheStringFormStillDecodesVerbatim() async throws {
        let (api, _) = makeApi(json: statusJSON(#""run failed""#))

        let status = try await api.getStatus(runId: "run-x")

        XCTAssertEqual(
            status.error,
            FunctionRunError(name: nil, message: "run failed", code: nil, details: nil)
        )
    }

    func testAnAbsentOrNullErrorReadsAsNoFailure() async throws {
        for literal: String? in [nil, "null"] {
            let (api, _) = makeApi(json: statusJSON(literal, status: "completed"))

            let status = try await api.getStatus(runId: "run-x")

            XCTAssertEqual(status.status, "completed")
            XCTAssertNil(status.error, "error literal \(literal ?? "absent")")
        }
    }

    /// The two non-failed reads the server really answers, unchanged: a queued
    /// run before it starts and a completed one after it ends.
    func testQueuedAndCompletedReadsWithANullErrorAreUnchanged() async throws {
        let (queued, _) = makeApi(json: """
        {"status":{"status":"queued","output":null,"error":null},
         "run":{"runId":"run-q","runKey":"rk-q","status":"queued"}}
        """)
        let queuedStatus = try await queued.getStatus(runId: "run-q")
        XCTAssertEqual(queuedStatus.status, "queued")
        XCTAssertNil(queuedStatus.error)

        let (done, _) = makeApi(json: """
        {"status":{"status":"completed","output":{"ok":true},"error":null},
         "run":{"runId":"run-c","runKey":"rk-c","status":"completed"}}
        """)
        let doneStatus = try await done.getStatus(runId: "run-c")
        XCTAssertEqual(doneStatus.status, "completed")
        XCTAssertEqual(doneStatus.output?.objectValue?["ok"]?.boolValue, true)
        XCTAssertNil(doneStatus.error)
        // #3565 — an untruncated output carries no flag at all.
        XCTAssertNil(doneStatus.outputTruncated)
    }

    // MARK: - Behavior 9: the name-less object

    func testANameLessObjectDecodesWithNoNameAndTheMessageIntact() async throws {
        let (api, _) = makeApi(json: Self.namelessError)

        let status = try await api.getStatus(runId: "run-3")

        XCTAssertEqual(status.status, "failed")
        let failure = try XCTUnwrap(status.error)
        XCTAssertNil(failure.name, "the deployed engine drops the name")
        XCTAssertEqual(failure.message, "boom")
    }

    // MARK: - Behavior 10: waitFor RESOLVES, and forwards

    func testWaitForResolvesAFailedTaskRunWithoutThrowing() async throws {
        let (api, transport) = makeApi(json: Self.failedTask)

        let settled = try await api.waitFor(runId: "run-1")

        XCTAssertEqual(settled.status, "failed")
        XCTAssertTrue(settled.isFailure)
        XCTAssertTrue(settled.isTerminal)
        XCTAssertEqual(
            settled.error?.message,
            "OUTPUT_SCHEMA_VIOLATION: Output schema validation failed: value.total must be number"
        )
        XCTAssertEqual(settled.error?.name, "Error")
        // One poll: the read succeeded, so there was nothing to retry. This is
        // the issue's reported symptom inverted — a thrown poll was retried as
        // transient until the whole budget was gone.
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testTheTypedWaitForForwardsTheSameFailure() async throws {
        let (api, _) = makeApi(json: Self.failedTask)

        let typed = try await api.waitFor(runId: "run-1", as: Empty.self)

        XCTAssertEqual(typed.status, "failed")
        XCTAssertTrue(typed.isFailure)
        XCTAssertEqual(typed.error?.name, "Error")
        XCTAssertTrue(
            typed.error?.message.hasPrefix("OUTPUT_SCHEMA_VIOLATION") == true
        )
    }

    /// `workflows.waitFor(runId:as:)` — the OTHER typed wait, and the one a
    /// failed DSL run settles through.
    ///
    /// Asserted with a structured error carrying extra keys on purpose. The
    /// memberwise init rebuilds a message-only failure out of `error` when the
    /// caller passes none, so a typed overload that forgets to forward still
    /// answers a `failure` with the right MESSAGE — and silently nil for the
    /// name and the details. Only an error with something besides its message
    /// can tell the two apart.
    func testTheTypedWorkflowWaitForwardsTheWholeFailure() async throws {
        let json = statusJSON(
            #"{"name":"WorkflowError","message":"step `charge` failed","stepId":"charge","attempt":3}"#,
            runId: "run-w"
        )
        let transport = RecordingTransport(status: 200, json: json)
        let api = WorkflowsAPI(
            transport: transport,
            getConnectionId: { "conn-test" },
            events: EventEmitter()
        )

        // Already terminal when the wait starts, so the subscribe-time
        // reconcile settles it and no frame is needed.
        let untyped = try await api.waitFor(
            runId: "run-w",
            options: WaitForWorkflowOptions(timeout: 5)
        )
        let typed = try await api.waitFor(
            runId: "run-w",
            as: Empty.self,
            options: WaitForWorkflowOptions(timeout: 5)
        )

        XCTAssertEqual(typed.status, "failed")
        XCTAssertEqual(typed.failure, untyped.failure)
        XCTAssertEqual(typed.failure?.name, "WorkflowError")
        XCTAssertEqual(typed.error, typed.failure?.message)
        XCTAssertEqual(
            typed.failure?.details,
            .object(["stepId": .string("charge"), "attempt": .number(3)])
        )
    }

    /// The finalization window: the record already reads terminal while the
    /// status block still reports the execution in flight. The wait settles
    /// from the record after the bounded re-check, and must carry the failure
    /// its LAST read saw rather than dropping it on the way out.
    func testTheFinalizationWindowSettlesFromTheRecordAndForwardsTheFailure() async throws {
        let inWindow = """
        {"status":{"status":"running","error":{"name":"Error","message":"boom"}},
         "run":{"runId":"run-1","runKey":"rk-1","status":"failed"}}
        """
        let transport = RecordingTransport(status: 200, json: inWindow)
        let api = FunctionsAPI(transport: transport)
        api.sleepForTest = { _ in }

        let settled = try await api.waitFor(runId: "run-1")

        XCTAssertEqual(settled.status, "failed", "settled from the record")
        XCTAssertEqual(settled.error?.message, "boom")
        XCTAssertEqual(settled.error?.name, "Error")
    }

    // MARK: - Behavior 11: the WS-frame path builds a failure by the same rule

    func testTheWorkflowFrameBuildsAFailureFromItsStringError() throws {
        // `workflows.waitFor` settles from the terminal `workflowStatus` frame
        // with zero HTTP, and the frame carries a STRING error. Built by the
        // same rule, the frame path and the poll path report the same thing
        // about the same failed run.
        let fromFrame = WorkflowRunError.read(JSONValue.string("frame failed"))
        XCTAssertEqual(
            fromFrame,
            WorkflowRunError(name: nil, message: "frame failed", details: nil)
        )

        let built = WaitForWorkflowResult(
            status: "failed",
            output: nil,
            error: "frame failed",
            failure: fromFrame
        )
        XCTAssertTrue(built.isFailure)
        XCTAssertEqual(built.error, built.failure?.message)
    }

    // MARK: - Edge 19: a value of another JSON kind

    func testAnErrorOfAnotherJSONKindLeavesBothNilAndKeepsTheStatus() async throws {
        for literal in ["42", "true", #"["boom"]"#, "3.5"] {
            let (api, _) = makeApi(json: statusJSON(literal))

            let status = try await api.getStatus(runId: "run-x")

            XCTAssertEqual(status.status, "failed", "error literal \(literal)")
            XCTAssertNil(status.error, "error literal \(literal)")
            XCTAssertEqual(status.run?.runId, "run-x", "error literal \(literal)")
        }
    }

    // MARK: - Edge 19a: a wire `details` of any kind

    func testAWireDetailsOfAnyKindIsKeptUnderDetailsUnchanged() async throws {
        for literal in [#"["x"]"#, "7", #""text""#, #"{"inner":1}"#] {
            let (api, _) = makeApi(json: statusJSON(#"{"message":"boom","details":\#(literal)}"#))

            let status = try await api.getStatus(runId: "run-x")
            let failure = try XCTUnwrap(status.error, "details \(literal)")

            XCTAssertEqual(failure.message, "boom")
            let details = try XCTUnwrap(failure.details?.objectValue, "details \(literal)")
            // The wire's `details` is a remaining key like any other, so it
            // lands UNDER `details` rather than replacing it. Same rule as the
            // JS client's `failure.details.details` (D3449-SO-003).
            XCTAssertEqual(Set(details.keys), ["details"], "details \(literal)")
            XCTAssertNotNil(details["details"], "details \(literal)")
        }
    }

    // MARK: - Edge 20: a message that is not a string

    func testAnObjectWhoseMessageIsNotAStringIsDroppedWhole() async throws {
        for literal in ["42", "null", #"{"text":"boom"}"#, #"["boom"]"#, "true"] {
            let (api, _) = makeApi(json: statusJSON(#"{"name":"Error","message":\#(literal)}"#))

            let status = try await api.getStatus(runId: "run-x")

            XCTAssertEqual(status.status, "failed", "message \(literal)")
            XCTAssertNil(status.error, "message \(literal)")
        }
    }

    // MARK: - Edge 21: the already-flattened payload

    func testAnAlreadyFlattenedPayloadDecodesByTheSameRule() async throws {
        // `status` as a bare string with a top-level `error` object: what a
        // payload assembled by hand, or a direct construction, carries. The
        // fallback branch must read the object by the same rule rather than
        // re-reading `status` as a string and throwing.
        let (api, _) = makeApi(json: """
        {"status":"failed","error":{"name":"WorkflowError","message":"flat"},
         "run":{"runId":"run-f","runKey":"rk-f","status":"failed"}}
        """)

        let status = try await api.getStatus(runId: "run-f")

        XCTAssertEqual(status.status, "failed")
        XCTAssertEqual(status.error?.message, "flat")
        // #3565 — the placeholder is dropped on the flattened payload by the
        // same rule as the nested one: one reader, one answer.
        XCTAssertNil(status.error?.name)
    }

    // MARK: - Edge 22: the type is Equatable and Sendable

    func testWorkflowRunErrorIsEquatableAndSendable() {
        let a = WorkflowRunError(name: "Error", message: "boom", details: nil)
        let b = WorkflowRunError(name: "Error", message: "boom", details: nil)
        let c = WorkflowRunError(name: nil, message: "boom", details: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        // `Sendable` is a compile-time claim, so it is made at compile time:
        // this closure would not build if the type were not.
        let sendable: @Sendable () -> WorkflowRunError = { a }
        XCTAssertEqual(sendable(), a)
    }

    // MARK: - Edge 24: the 404 bodies still throw .notFound

    func testAMissingRunStillThrowsNotFoundFromWaitFor() async throws {
        // The 404 `{status:"missing", error:"…"}` bodies are thrown by the
        // transport as an `HttpError` before any of this decoding runs, and
        // that is unchanged.
        let (api, _) = makeApi(
            json: #"{"status":"missing","error":"Workflow run not found"}"#,
            status: 404
        )

        do {
            _ = try await api.waitFor(runId: "run-missing")
            XCTFail("a 404 must not resolve")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    /// A 200 body REPORTING `missing` is the other half: it never reaches a
    /// terminal state, so the wait throws rather than waiting it out.
    func testAStatusOfMissingThrowsNotFoundRatherThanResolving() async throws {
        let (api, _) = makeApi(json: statusJSON(#""gone""#, status: "missing"))

        do {
            _ = try await api.waitFor(runId: "run-x")
            XCTFail("a missing run must not resolve")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    // MARK: - Edge 26: the row-settled path

    func testTheRowSettledWorkflowErrorObjectDecodes() async throws {
        // `settledStatusResponse` writes exactly this when the instance cannot
        // be consulted but the row has already settled — the shape a failed
        // DSL durable run and a reclaimed function run both answer.
        let (api, _) = makeApi(json: Self.workflowError)

        let status = try await api.getStatus(runId: "run-2")

        XCTAssertEqual(status.status, "failed")
        XCTAssertEqual(status.error?.message, "step `charge` failed")
        // #3565, D3565-014 — this is the COMMON path for a function failure
        // (the engine sink settles the row before the caller's next poll), and
        // `WorkflowError` is what the platform writes when it has only the
        // message. It is not a thrown name, so the function reader drops it
        // rather than moving it into `details`.
        XCTAssertNil(status.error?.name)
        XCTAssertNil(status.error?.details)
        // …and the WORKFLOW surface still answers it, unchanged.
        let viaWorkflows = try Self.decodeStatusBytes(Self.workflowError)
        XCTAssertEqual(viaWorkflows.failure?.name, "WorkflowError")
    }
}
