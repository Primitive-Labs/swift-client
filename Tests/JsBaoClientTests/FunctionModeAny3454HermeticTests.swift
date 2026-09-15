import XCTest
@testable import JsBaoClient

/// The Swift client states the runner it means — #3454 behavior 17, project
/// `server-functions` phase 4.
///
/// The intent's decision ("Mode vocabulary?", amended 2026-09-14): the runner
/// is chosen at CALL time. `invoke` means the request runner and `start` means
/// the task one, and a version whose mode is `any` takes either — but only if
/// the CALL says which. Swift composed both bodies without a `mode`, so
/// against an `any` version `start` would have been handed the request runner
/// (an absent mode is the request runner) and then thrown its own
/// envelope-shape mismatch at a function that was perfectly willing to start.
///
/// The second half is DSO3454-002's finding: once the call states a mode, the
/// SERVER refuses the wrong verb on a lock with a 409, and `Transport` throws
/// `HttpError` on any 409 — so the public error type on a wrong verb would
/// have silently changed from `JsBaoError(.functionModeMismatch)` to
/// `HttpError`, breaking every existing catch. Exactly that one code is
/// translated back; every other 409 stays an `HttpError`, and the
/// envelope-shape checks stay as the backstop for a server that predates the
/// field.
///
/// Server-free: what is asserted is the body Swift composes and the error it
/// raises, both of which are entirely client-side.
final class FunctionModeAny3454HermeticTests: XCTestCase {

    private func api(
        responder: @escaping @Sendable (RecordedRequest) async throws -> TransportResponse
    ) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(responder: responder)
        let workflows = WorkflowsAPI(transport: transport)
        return (FunctionsAPI(transport: transport, workflows: workflows), transport)
    }

    /// `static` and free of `self`, so a responder closure stays `@Sendable`.
    private static func json(_ status: Int, _ body: String) -> TransportResponse {
        TransportResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }

    /// The commonest responder: one canned answer whatever was asked.
    private func api(status: Int, json body: String) -> (FunctionsAPI, RecordingTransport) {
        api { _ in Self.json(status, body) }
    }

    private func bodyOf(_ call: RecordedRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(call?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The body each verb composes

    func testInvokeStatesTheRequestRunnerAndStartStatesTheTaskOne() async throws {
        let (invokeApi, invokeTransport) = api(
            status: 200, json: #"{"status":"completed","output":{"ok":true}}"#
        )
        _ = try await invokeApi.invoke(
            "either", input: nil as JSONValue?
        ) as FunctionResult<JSONValue>
        let invoked = try bodyOf(invokeTransport.lastCall(to: "/functions/either"))
        XCTAssertEqual(invoked["mode"] as? String, "request")

        let (startApi, startTransport) = api(
            status: 201, json: #"{"runId":"r1","runKey":"r1","status":"running"}"#
        )
        _ = try await startApi.start("either", input: nil as JSONValue?)
        let started = try bodyOf(startTransport.lastCall(to: "/functions/either"))
        XCTAssertEqual(started["mode"] as? String, "task")
    }

    func testTheStatedModeRidesBesideEveryOtherFieldTheCallerGave() async throws {
        let (startApi, transport) = api(
            status: 201, json: #"{"runId":"r1","runKey":"k1","status":"running"}"#
        )
        _ = try await startApi.start(
            "either",
            input: JSONValue.object(["n": .number(1)]),
            runKey: "k1",
            contextDocId: "doc-1"
        )
        let body = try bodyOf(transport.lastCall(to: "/functions/either"))
        XCTAssertEqual(body["mode"] as? String, "task")
        XCTAssertEqual(body["runKey"] as? String, "k1")
        XCTAssertEqual(body["contextDocId"] as? String, "doc-1")
        XCTAssertNotNil(body["rootInput"])
    }

    // MARK: - The server's 409, translated (DSO3454-002)

    private static let mismatch409 = #"""
    {"error":"Function 'locked' is a task function: this call asked for the request runner. Use 'primitive functions start locked'.","errorCode":"FUNCTION_MODE_MISMATCH","mode":"task"}
    """#

    func testInvokeTranslatesTheServersModeMismatchIntoTheDocumentedError() async throws {
        let (invokeApi, _) = api(status: 409, json: Self.mismatch409)
        do {
            _ = try await invokeApi.invoke(
                "locked", input: nil as JSONValue?
            ) as FunctionResult<JSONValue>
            XCTFail("invoke on a task lock must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertTrue(error.message.contains("task function"), error.message)
            XCTAssertTrue(error.message.contains("locked"), error.message)
        }
    }

    func testStartTranslatesItToo() async throws {
        let body = #"""
        {"error":"Function 'greet' is a request function: this call asked for the task runner. Use 'primitive functions invoke greet'.","errorCode":"FUNCTION_MODE_MISMATCH","mode":"request"}
        """#
        let (startApi, _) = api(status: 409, json: body)
        do {
            _ = try await startApi.start("greet", input: nil as JSONValue?)
            XCTFail("start on a request lock must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertTrue(error.message.contains("request function"), error.message)
        }
    }

    func testAnyOther409StaysAnHttpError() async throws {
        // Only this one code is translated. A 409 about anything else — an
        // unpushed function, say — is what it always was, and turning every
        // conflict into a mode mismatch would be worse than the bug.
        let body = #"""
        {"error":"Function 'fresh' has no pushed code.","errorCode":"FUNCTION_NOT_PUSHED"}
        """#
        let (invokeApi, _) = api(status: 409, json: body)
        do {
            _ = try await invokeApi.invoke(
                "fresh", input: nil as JSONValue?
            ) as FunctionResult<JSONValue>
            XCTFail("an unpushed function must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.serverCode, "FUNCTION_NOT_PUSHED")
        } catch let error as JsBaoError {
            XCTFail("a FUNCTION_NOT_PUSHED 409 must stay an HttpError, got \(error)")
        }
    }

    // MARK: - The envelope backstop stands (a server that predates `mode`)

    func testAStartAnsweredWithAResultEnvelopeStillThrowsTheSameError() async throws {
        // A server older than #3448 ignores the stated mode and answers from
        // the stored config. The shape check is what catches that, and it has
        // to keep catching it: the two halves are one contract.
        let (startApi, _) = api(
            status: 200, json: #"{"status":"completed","output":{"ok":true}}"#
        )
        do {
            _ = try await startApi.start("greet", input: nil as JSONValue?)
            XCTFail("a result envelope from `start` must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertTrue(error.message.contains("is a request function"), error.message)
        }
    }

    func testAnInvokeAnsweredWithAStartEnvelopeStillThrowsTheSameError() async throws {
        let (invokeApi, _) = api(
            status: 201, json: #"{"runId":"r1","runKey":"r1","status":"running"}"#
        )
        do {
            _ = try await invokeApi.invoke(
                "sweep", input: nil as JSONValue?
            ) as FunctionResult<JSONValue>
            XCTFail("a start envelope from `invoke` must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .functionModeMismatch)
            XCTAssertTrue(error.message.contains("is a task function"), error.message)
        }
    }
}
