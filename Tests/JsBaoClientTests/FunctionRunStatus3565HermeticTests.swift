import Foundation
import XCTest

@testable import JsBaoClient

/// The function-native run status on the Swift client — #3565, project
/// `server-functions` phase 4.
///
/// `client.functions` answered the WORKFLOW types, so a caller polling a
/// function run read a `skipReason` and a `run.workflowId` the server can
/// never set for a function, and a missing run reported itself as a missing
/// WORKFLOW run. Polling the workflow run routes stays an implementation
/// choice; these pin that it no longer reaches the caller as vocabulary.
///
/// Server-free throughout: the readers are pure and the API runs over a
/// recording transport, so what is asserted is the client's reading of exactly
/// the bytes the route sends.
final class FunctionRunStatus3565HermeticTests: XCTestCase {

    private func makeApi(status: Int = 200, json: String) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (FunctionsAPI(transport: transport), transport)
    }

    // MARK: - Behavior 12: FunctionRunError.read

    func testReadsTheWireObjectIntoMessageCodeNameAndDetails() throws {
        let read = try XCTUnwrap(
            FunctionRunError.read(
                .object([
                    "name": .string("TypeError"),
                    "message": .string("boom"),
                    "code": .string("FUNCTION_THREW"),
                    "x": .number(1),
                ])
            )
        )
        XCTAssertEqual(read.name, "TypeError")
        XCTAssertEqual(read.message, "boom")
        XCTAssertEqual(read.code, "FUNCTION_THREW")
        XCTAssertEqual(read.details, .object(["x": .number(1)]))
    }

    func testOmitsDetailsWhenCodeWasTheOnlyRemainingKey() throws {
        let read = try XCTUnwrap(
            FunctionRunError.read(
                .object(["message": .string("boom"), "code": .string("FUNCTION_TIMEOUT")])
            )
        )
        XCTAssertEqual(read.code, "FUNCTION_TIMEOUT")
        XCTAssertNil(read.details)
    }

    func testReadsTheOlderStringFormAsAMessageAlone() throws {
        let read = try XCTUnwrap(FunctionRunError.read(.string("just words")))
        XCTAssertEqual(read, FunctionRunError(name: nil, message: "just words"))
    }

    /// D3565-014 — the platform's placeholder is dropped, and NOT moved into
    /// `details`: it carries no information about the function.
    func testDropsThePlatformPlaceholderNameWithoutMovingIt() throws {
        let read = try XCTUnwrap(
            FunctionRunError.read(
                .object([
                    "name": .string("WorkflowError"),
                    "message": .string("the row remembered only this"),
                ])
            )
        )
        XCTAssertNil(read.name)
        XCTAssertNil(read.details)
        XCTAssertEqual(read.message, "the row remembered only this")
    }

    func testPassesEveryOtherNameThrough() throws {
        for name in ["Error", "TypeError", "OrderRejected"] {
            let read = FunctionRunError.read(
                .object(["name": .string(name), "message": .string("m")])
            )
            XCTAssertEqual(read?.name, name, name)
        }
    }

    func testAnswersNilForEveryValueItCannotDescribe() {
        XCTAssertNil(FunctionRunError.read(nil))
        XCTAssertNil(FunctionRunError.read(.null))
        XCTAssertNil(FunctionRunError.read(.number(42)))
        XCTAssertNil(FunctionRunError.read(.array([.string("x")])))
        XCTAssertNil(FunctionRunError.read(.object(["message": .number(7)])))
    }

    /// Edge 25 — a `code` of another JSON kind is not the platform's
    /// classification, so it stays where it arrived.
    func testLiftsOnlyAStringCode() throws {
        let read = try XCTUnwrap(
            FunctionRunError.read(.object(["message": .string("m"), "code": .number(7)]))
        )
        XCTAssertNil(read.code)
        XCTAssertEqual(read.details, .object(["code": .number(7)]))
    }

    /// Edge 26 — a wire `details` is one remaining key like any other.
    func testKeepsAWireDetailsArrayUnderDetailsWhileLiftingCode() throws {
        let read = try XCTUnwrap(
            FunctionRunError.read(
                .object([
                    "message": .string("m"),
                    "code": .string("FUNCTION_THREW"),
                    "details": .array([.string("x")]),
                ])
            )
        )
        XCTAssertEqual(read.code, "FUNCTION_THREW")
        XCTAssertEqual(read.details, .object(["details": .array([.string("x")])]))
    }

    /// Edge 28 — the closed set is a declaration, not a filter; Swift's own
    /// convention is that a spelling the server adds never fails a decode.
    func testPassesACodeOutsideTheClosedSetThrough() throws {
        let read = try XCTUnwrap(
            FunctionRunError.read(
                .object(["message": .string("m"), "code": .string("ENGINE_FROM_THE_FUTURE")])
            )
        )
        XCTAssertEqual(read.code, "ENGINE_FROM_THE_FUTURE")
    }

    // MARK: - Behavior 13: the decode

    private static let rowSettledFailure = """
    {"status":{"status":"failed",
      "error":{"name":"WorkflowError",
               "message":"OUTPUT_SCHEMA_VIOLATION: output did not match",
               "code":"OUTPUT_SCHEMA_VIOLATION"}},
     "run":{"runId":"run-f","runKey":"rk-f","status":"failed",
            "functionId":"fn-1","functionKey":"ship-order",
            "executionPrincipal":"u-1","parentFunctionKey":null,
            "parentRunId":null,"nestDepth":0,
            "errorCode":"OUTPUT_SCHEMA_VIOLATION",
            "workflowId":null,"workflowKey":"ship-order","revisionId":null,
            "skipReason":null,"failedStepId":null,"executionMode":"durable"},
     "slice":{"sliceId":"slice-1","startedAt":1,"ceilingAt":2,"settledAt":3,
              "settledStatus":"failed","lastRefreshAt":null,"refreshCount":0}}
    """

    func testDecodesTheRowSettledFailureWithNoPlaceholderName() throws {
        let status = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes(
            Self.rowSettledFailure
        )
        XCTAssertEqual(status.status, "failed")
        XCTAssertNil(status.error?.name)
        XCTAssertEqual(status.error?.message, "OUTPUT_SCHEMA_VIOLATION: output did not match")
        XCTAssertEqual(status.error?.code, "OUTPUT_SCHEMA_VIOLATION")
        XCTAssertEqual(status.run?.functionKey, "ship-order")
        XCTAssertEqual(status.run?.functionId, "fn-1")
        XCTAssertEqual(status.run?.executionPrincipal, "u-1")
        XCTAssertEqual(status.run?.nestDepth, 0)
        XCTAssertEqual(status.run?.errorCode, "OUTPUT_SCHEMA_VIOLATION")
        XCTAssertEqual(status.slice?.settledStatus, "failed")
        XCTAssertTrue(status.isTerminal)
        XCTAssertTrue(status.isFailure)
    }

    func testTheOutputTruncatedFlagRidesTheStatusBlock() throws {
        let truncated = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":{"status":"completed","output":{"preview":true},"outputTruncated":true},
         "run":{"runId":"r","runKey":"k","status":"completed"}}
        """)
        XCTAssertEqual(truncated.outputTruncated, true)

        // Edge 27 — absent reads nil, so a caller reading a whole value sees
        // no new key at all.
        let whole = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":{"status":"completed","output":{"ok":true},"error":null},
         "run":{"runId":"r","runKey":"k","status":"completed"}}
        """)
        XCTAssertNil(whole.outputTruncated)
        XCTAssertNil(whole.error)
    }

    /// Edge 29 — a body with no run block still answers its status.
    func testARunBlockWithNoFunctionIdentityAndNoRunBlockAtAll() throws {
        let noIdentity = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":{"status":"failed"},"run":{"runId":"r","runKey":"k","status":"failed"}}
        """)
        XCTAssertNil(noIdentity.run?.functionKey)
        XCTAssertNil(noIdentity.run?.nestDepth)

        let noRun = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":{"status":"running"}}
        """)
        XCTAssertEqual(noRun.status, "running")
        XCTAssertNil(noRun.run)
    }

    /// Edge 38 — observability is never the answer: a block the client cannot
    /// read drops, and the status still decodes.
    func testAMalformedSliceOrErrorDropsAndKeepsTheStatus() throws {
        let badSlice = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":{"status":"completed"},"run":{"runId":"r","runKey":"k","status":"completed"},
         "slice":{"startedAt":"three"}}
        """)
        XCTAssertEqual(badSlice.status, "completed")
        XCTAssertNil(badSlice.slice)

        let badError = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":{"status":"failed","error":42},
         "run":{"runId":"r","runKey":"k","status":"failed"}}
        """)
        XCTAssertEqual(badError.status, "failed")
        XCTAssertNil(badError.error)
    }

    func testAnAlreadyFlattenedPayloadDecodesByTheSameRule() throws {
        let flat = try WorkflowStatusErrorHermeticTests.decodeFunctionRunStatusBytes("""
        {"status":"failed","error":{"name":"WorkflowError","message":"flat"},
         "run":{"runId":"run-f","runKey":"rk-f","status":"failed"}}
        """)
        XCTAssertEqual(flat.status, "failed")
        XCTAssertEqual(flat.error?.message, "flat")
        XCTAssertNil(flat.error?.name)
    }

    func testIsTerminalIsExactlyTheThreeSettledStatuses() {
        for terminal in ["completed", "failed", "terminated"] {
            XCTAssertTrue(FunctionRunStatus(status: terminal).isTerminal, terminal)
        }
        for open in ["queued", "running", "missing", "skipped", "apply_pending", "apply_claimed"] {
            XCTAssertFalse(FunctionRunStatus(status: open).isTerminal, open)
        }
        XCTAssertTrue(FunctionRunStatus(status: "failed").isFailure)
        XCTAssertFalse(FunctionRunStatus(status: "completed").isFailure)
    }

    func testTheStatusVocabularyIsSixWords() {
        XCTAssertEqual(
            FunctionRunStatus.statusValues,
            ["queued", "running", "completed", "failed", "terminated", "missing"]
        )
    }

    // MARK: - Behavior 14: the class holds no workflow surface

    /// The source guard. `FunctionsAPI` used to hold a private `WorkflowsAPI`
    /// and delegate two of its three control methods to it, which is where
    /// every workflow-worded refusal a function caller met came from.
    func testTheFunctionsApiNamesNoWorkflowType() throws {
        let source = try ClientSourceText.code("API/FunctionsAPI.swift")
        // CODE, not prose: a doc comment saying which workflow type a method
        // replaced is what principle 3 asks a new abstraction to say.
        let code = source
            .replacingOccurrences(
                of: #"///[^\n]*"#, with: "", options: .regularExpression
            )
            .replacingOccurrences(
                of: #"//[^\n]*"#, with: "", options: .regularExpression
            )
        for name in [
            "WorkflowsAPI",
            "WorkflowStatusResult",
            "WorkflowStatus<",
            "WaitForWorkflowResult",
            "WaitForResult<",
            "WaitForWorkflowOptions",
        ] {
            XCTAssertFalse(code.contains(name), "\(name) must not reach the functions surface")
        }
        XCTAssertTrue(code.contains("public convenience init(transport: any Transport)"))
    }

    func testGetStatusGetsTheRunRouteAndAnswersTheFunctionShape() async throws {
        let (api, transport) = makeApi(json: Self.rowSettledFailure)
        let status = try await api.getStatus(runId: "run f")
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/workflows/runs/run%20f/status")
        XCTAssertEqual(status.error?.code, "OUTPUT_SCHEMA_VIOLATION")

        let typed: FunctionRunResult<[String: String]> = try await makeApi(
            json: Self.rowSettledFailure
        ).0.getStatus(runId: "run-f")
        XCTAssertEqual(typed.error, status.error)
        XCTAssertEqual(typed.run, status.run)
        XCTAssertTrue(typed.isFailure)
    }

    func testAMissingRunIsReportedInFunctionVocabulary() async throws {
        let (api, _) = makeApi(status: 404, json: #"{"error":"Run not found"}"#)
        do {
            _ = try await api.getStatus(runId: "rid")
            XCTFail("a 404 must be refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "Function run rid not found")
            XCTAssertFalse(error.message.contains("Workflow"))
        }
    }

    /// Edge 32 — the boundary refusals name the method and make no request.
    func testAnEmptyRunIdIsRefusedBeforeAnyRequest() async throws {
        let (api, transport) = makeApi(json: "{}")
        for probe in [("getStatus", { try await api.getStatus(runId: "") })] {
            do {
                _ = try await probe.1()
                XCTFail("\(probe.0) must refuse an empty run id")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .invalidArgument)
                XCTAssertEqual(error.message, "runId is required for functions.\(probe.0)")
            }
        }
        do {
            _ = try await api.waitFor(runId: "")
            XCTFail("waitFor must refuse an empty run id")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.message, "runId is required for functions.waitFor")
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testA403PropagatesUnchanged() async throws {
        let (api, _) = makeApi(status: 403, json: #"{"error":"nope"}"#)
        do {
            _ = try await api.getStatus(runId: "rid")
            XCTFail("a 403 must not be swallowed")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
    }

    // MARK: - Behavior 16: terminate's three different 404s

    func testTerminateRefusesAnEmptyKeyNamingTheField() async throws {
        let (api, transport) = makeApi(json: "{}")
        for (ref, field) in [
            (FunctionRunRef(functionKey: "", runKey: "rk"), "functionKey"),
            (FunctionRunRef(functionKey: "f", runKey: ""), "runKey"),
        ] {
            do {
                _ = try await api.terminate(ref)
                XCTFail("an empty \(field) must be refused")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .invalidArgument)
                XCTAssertEqual(error.message, "\(field) is required for functions.terminate")
            }
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testTerminateClassifiesTheTwoMissingSentencesAsNotFound() async throws {
        for sentence in FunctionTerminateClassifier.missingSentences {
            let (api, _) = makeApi(
                status: 404, json: #"{"status":"missing","error":"\#(sentence)"}"#
            )
            do {
                _ = try await api.terminate(FunctionRunRef(functionKey: "f", runKey: "rk"))
                XCTFail("a missing run must be refused")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .notFound, sentence)
                XCTAssertEqual(
                    error.message, "Function run rk of function f not found", sentence
                )
            }
        }
    }

    /// Edge 37 — the engine's own words survive, after the function-worded
    /// prefix. A diagnostic that happens to name a workflow is the ENGINE's
    /// sentence, not the client's.
    func testTerminateKeepsAnEngineDiagnosticUnderUnavailable() async throws {
        for diagnostic in ["Not implemented yet", "Workflow engine refused: instance busy"] {
            let (api, _) = makeApi(
                status: 404, json: #"{"status":"missing","error":"\#(diagnostic)"}"#
            )
            do {
                _ = try await api.terminate(FunctionRunRef(functionKey: "f", runKey: "rk"))
                XCTFail("an engine failure must be refused")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .unavailable, diagnostic)
                XCTAssertEqual(
                    error.message,
                    "Function run rk of function f could not be terminated: \(diagnostic)",
                    diagnostic
                )
            }
        }
    }

    /// Edge 39 — a body the classifier cannot read is a not-found: that is the
    /// answer the route gave before any of this existed.
    func testTerminateReadsAnUnclassifiableBodyAsNotFound() async throws {
        for body in [
            "not json at all",
            #"{"error":"Run not found"}"#,
            #"{"status":"missing"}"#,
            "null",
        ] {
            let (api, _) = makeApi(status: 404, json: body)
            do {
                _ = try await api.terminate(FunctionRunRef(functionKey: "f", runKey: "rk"))
                XCTFail("a 404 must be refused: \(body)")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .notFound, body)
            }
        }
    }

    func testTheClassifierIsPure() {
        for body in [
            nil,
            "text",
            "[]",
            "{}",
            #"{"status":"missing"}"#,
            #"{"status":"missing","error":""}"#,
            #"{"status":"missing","error":7}"#,
            #"{"error":"Not implemented yet"}"#,
            #"{"status":"missing","error":"Workflow run not found"}"#,
            #"{"status":"missing","error":"Workflow instance not found"}"#,
        ] {
            XCTAssertEqual(
                FunctionTerminateClassifier.classify(body: body), .notFound, body ?? "nil"
            )
        }
        XCTAssertEqual(
            FunctionTerminateClassifier.classify(
                body: #"{"status":"missing","error":"Not implemented yet"}"#
            ),
            .engineFailure(diagnostic: "Not implemented yet")
        )
    }

    /// Behavior 24's Swift half — the classifier's list is exactly the two
    /// sentences the controller answers, with no third.
    func testTheClassifierSentenceListIsExactlyTheTwo() {
        XCTAssertEqual(
            FunctionTerminateClassifier.missingSentences,
            ["Workflow run not found", "Workflow instance not found"]
        )
    }

    // MARK: - Behavior 15: waitFor's own vocabulary

    func testWaitForRefusesAMissingReadInFunctionWords() async throws {
        let (api, transport) = makeApi(json: #"{"status":{"status":"missing"}}"#)
        do {
            _ = try await api.waitFor(runId: "rid", options: FunctionWaitOptions(timeout: 30))
            XCTFail("a missing run never settles")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(
                error.message,
                "Function run rid is no longer resolvable (status: missing)"
            )
        }
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testWaitForTimesOutWithTheFunctionWordedMessage() async throws {
        let (api, _) = makeApi(json: #"{"status":{"status":"running"}}"#)
        api.sleepForTest = { _ in }
        do {
            _ = try await api.waitFor(
                runId: "rid", options: FunctionWaitOptions(timeout: 0.001)
            )
            XCTFail("the wait must time out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
            XCTAssertTrue(
                error.message.contains("waiting for function run rid"),
                "got \(error.message)"
            )
        }
    }
}
