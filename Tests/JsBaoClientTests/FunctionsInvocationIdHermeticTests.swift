import XCTest
@testable import JsBaoClient

/// `invocationId` on the invoke envelope — #3448 behavior 7 (project
/// `server-functions` phase 4).
///
/// The field is what an operator hands to `primitive functions logs
/// <functionId> --invocation <id>` to read what an invocation printed. It is
/// additive on the wire, and additive here.
///
/// The decode is the part worth pinning (D3448-SO-005). `FunctionsAPI` does
/// NOT decode into the public structs: it decodes a private
/// `FunctionRouteEnvelope` with an explicit `CodingKeys` list and a
/// hand-written `init(from:)`, then hand-constructs `FunctionInvokeResult`
/// and `FunctionResult` from it. A field added only to the public structs
/// would compile, would be published in the type, and would be `nil` on every
/// real call. So BOTH forwarding sites are driven end to end over a recording
/// transport, with the field present and with it absent.
///
/// The research report's "public typed and untyped invoke paths" describes the
/// client before #3344: the untyped `[String: Any]` twin went with the reason
/// for it, and the one public way in is the generic `invoke`. The two shapes a
/// caller writes are therefore a declared `Decodable` output and the dynamic
/// `JSONValue` witness the method's own documentation names — and both run
/// through `FunctionInvokeResult` and then `FunctionResult`, which are the two
/// hand-written constructors at issue.
final class FunctionsInvocationIdHermeticTests: XCTestCase {

    private func makeApi(json: String, status: Int = 200) -> FunctionsAPI {
        let transport = RecordingTransport(status: status, json: json)
        return FunctionsAPI(transport: transport, workflows: WorkflowsAPI(transport: transport))
    }

    private struct Sum: Decodable, Sendable, Equatable {
        let total: Int
    }

    // MARK: - the dynamic (`JSONValue`) shape

    func testDynamicInvokeCarriesTheInvocationId() async throws {
        let api = makeApi(json: """
        {"status":"completed","output":{"total":7},
         "invocationId":"01K4ANRRG0ZZZZZZZZZZZZZZZZ"}
        """)

        let result: FunctionResult<JSONValue> = try await api.invoke(
            "sum",
            input: Optional<JSONValue>.none
        )

        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.invocationId, "01K4ANRRG0ZZZZZZZZZZZZZZZZ")
    }

    func testDynamicInvokeLeavesItNilWhenTheServerSendsNone() async throws {
        // A gate refusal records nothing, and a server older than #3448 sends
        // nothing: both read as "there is no record to look up", not as a
        // decode failure.
        let api = makeApi(json: #"{"status":"completed","output":{"total":7}}"#)

        let result: FunctionResult<JSONValue> = try await api.invoke(
            "sum",
            input: Optional<JSONValue>.none
        )

        XCTAssertEqual(result.status, "completed")
        XCTAssertNil(result.invocationId)
    }

    func testDynamicInvokeCarriesItOnAFailedInvocation() async throws {
        // The failing invocation is the one an operator follows the id for.
        let api = makeApi(json: """
        {"status":"failed","error":"boom","errorCode":"FUNCTION_THREW",
         "invocationId":"01K4ANRRG1ZZZZZZZZZZZZZZZZ"}
        """)

        let result: FunctionResult<JSONValue> = try await api.invoke(
            "sum",
            input: Optional<JSONValue>.none
        )

        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.errorCode, "FUNCTION_THREW")
        XCTAssertEqual(result.invocationId, "01K4ANRRG1ZZZZZZZZZZZZZZZZ")
    }

    func testDynamicInvokeCarriesItOnATimeout() async throws {
        // #3448 D3448-002: a timeout now names its message and its code too.
        let api = makeApi(json: """
        {"status":"timeout","error":"Function 'sum' did not finish within 1000 ms",
         "errorCode":"FUNCTION_TIMEOUT","invocationId":"01K4ANRRG2ZZZZZZZZZZZZZZZZ"}
        """)

        let result: FunctionResult<JSONValue> = try await api.invoke(
            "sum",
            input: Optional<JSONValue>.none
        )

        XCTAssertEqual(result.status, "timeout")
        XCTAssertEqual(result.errorCode, "FUNCTION_TIMEOUT")
        XCTAssertEqual(result.error, "Function 'sum' did not finish within 1000 ms")
        XCTAssertEqual(result.invocationId, "01K4ANRRG2ZZZZZZZZZZZZZZZZ")
    }

    // MARK: - the declared-output shape

    func testDeclaredOutputInvokeForwardsTheInvocationId() async throws {
        // `FunctionResult` is not `Decodable`: it is built by hand from the
        // envelope, so this is a second forwarding site and a second way for
        // the field to be silently dropped.
        let api = makeApi(json: """
        {"status":"completed","output":{"total":7},
         "invocationId":"01K4ANRRG3ZZZZZZZZZZZZZZZZ"}
        """)

        let result: FunctionResult<Sum> = try await api.invoke(
            "sum",
            input: Optional<JSONValue>.none
        )

        XCTAssertEqual(result.output, Sum(total: 7))
        XCTAssertEqual(result.invocationId, "01K4ANRRG3ZZZZZZZZZZZZZZZZ")
    }

    func testDeclaredOutputInvokeLeavesItNilWhenTheServerSendsNone() async throws {
        let api = makeApi(json: #"{"status":"completed","output":{"total":7}}"#)

        let result: FunctionResult<Sum> = try await api.invoke(
            "sum",
            input: Optional<JSONValue>.none
        )

        XCTAssertEqual(result.output, Sum(total: 7))
        XCTAssertNil(result.invocationId)
    }
}
