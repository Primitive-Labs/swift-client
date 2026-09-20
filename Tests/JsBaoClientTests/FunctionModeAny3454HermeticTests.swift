import XCTest
@testable import JsBaoClient

/// The Swift client states the runtime it means with the ROUTE — #3454
/// behavior 17, RETARGETED by #3482 (behavior 22) at the facts that replaced
/// it.
///
/// #3454 had every call NAME a runner in its body, because a version's mode
/// decided what the one route answered. #3482 makes the ROUTE the selector:
/// `invoke` posts to `functions/{key}` and `start` to
/// `functions/{key}/start`, and neither sends a `mode` — a function's config
/// says nothing about how it runs, so there is nothing for a body field to be
/// checked against and nothing for the server to refuse.
///
/// So DSO3454-002's translation goes with the refusal it translated: a 409
/// carrying `FUNCTION_MODE_MISMATCH` is not something a current server sends,
/// and turning one into a `JsBaoError` would be inventing a refusal. What
/// SURVIVES is the envelope-shape backstop, and it survives for exactly the
/// reason it was built: against a server that predates the routes the one
/// invoke route answers whichever envelope its body field asked for, so a
/// `start` can still be handed a result (D3482-008).
///
/// Server-free: what is asserted is the route and the body Swift composes and
/// the error it raises, all of which are entirely client-side.
final class FunctionModeAny3454HermeticTests: XCTestCase {

    private func api(
        responder: @escaping @Sendable (RecordedRequest) async throws -> TransportResponse
    ) -> (FunctionsAPI, RecordingTransport) {
        let transport = RecordingTransport(responder: responder)
        return (FunctionsAPI(transport: transport), transport)
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

    func testInvokeTakesTheInvokeRouteAndStartTakesTheStartRoute() async throws {
        let (invokeApi, invokeTransport) = api(
            status: 200, json: #"{"status":"completed","output":{"ok":true}}"#
        )
        _ = try await invokeApi.invoke(
            "either", input: nil as JSONValue?
        ) as FunctionResult<JSONValue>
        let invoked = try bodyOf(invokeTransport.lastCall(to: "/functions/either"))
        XCTAssertNil(invoked["mode"])

        let (startApi, startTransport) = api(
            status: 201, json: #"{"runId":"r1","runKey":"r1","status":"running"}"#
        )
        _ = try await startApi.start("either", input: nil as JSONValue?)
        let startCall = try XCTUnwrap(startTransport.lastCall(to: "/functions/either/start"))
        XCTAssertEqual(startCall.path, "/functions/either/start")
        XCTAssertNil(try bodyOf(startCall)["mode"])
    }

    func testEveryOtherFieldTheCallerGaveStillRides() async throws {
        let (startApi, transport) = api(
            status: 201, json: #"{"runId":"r1","runKey":"k1","status":"running"}"#
        )
        _ = try await startApi.start(
            "either",
            input: JSONValue.object(["n": .number(1)]),
            runKey: "k1",
            contextDocId: "doc-1"
        )
        let body = try bodyOf(transport.lastCall(to: "/functions/either/start"))
        XCTAssertNil(body["mode"])
        XCTAssertEqual(body["runKey"] as? String, "k1")
        XCTAssertEqual(body["contextDocId"] as? String, "doc-1")
        XCTAssertNotNil(body["rootInput"])
    }

    func testTheKeyIsEncodedAsOneSegmentOnTheStartRouteToo() async throws {
        let (startApi, transport) = api(
            status: 201, json: #"{"runId":"r1","runKey":"r1","status":"running"}"#
        )
        _ = try await startApi.start("orders/sync it", input: nil as JSONValue?)
        XCTAssertEqual(transport.lastCall?.path, "/functions/orders%2Fsync%20it/start")
    }

    // MARK: - Nothing is translated any more (#3482)

    func testAMismatch409StaysAnHttpErrorLikeEveryOther409() async throws {
        // DSO3454-002 translated exactly this code back into
        // `JsBaoError(.functionModeMismatch)`, because the SERVER refused the
        // wrong verb on a lock. There are no locks and no such refusal, so a
        // 409 carrying the code can only come from somewhere this client does
        // not model — and inventing a mode mismatch out of it would be worse
        // than handing back what arrived.
        let body = #"""
        {"error":"something conflicted","errorCode":"FUNCTION_MODE_MISMATCH"}
        """#
        let (invokeApi, _) = api(status: 409, json: body)
        do {
            _ = try await invokeApi.invoke(
                "locked", input: nil as JSONValue?
            ) as FunctionResult<JSONValue>
            XCTFail("a 409 must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.serverCode, "FUNCTION_MODE_MISMATCH")
        } catch let error as JsBaoError {
            XCTFail("a 409 must stay an HttpError, got \(error)")
        }
    }

    func testAnyOther409StaysAnHttpError() async throws {
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

    // MARK: - The envelope backstop stands (a server that predates the routes)

    func testAStartAnsweredWithAResultEnvelopeStillThrowsTheSameError() async throws {
        // A server that predates #3482 has one route whose body field decided
        // what it answered, so a `start` reaching it can still be handed a
        // result. The shape check is what catches that, and it has to keep
        // catching it (D3482-008).
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
