import XCTest
@testable import JsBaoClient

/// Wire-shape tests for the `timing` option on
/// `databases.executeOperation` (issue #2359).
///
/// The server reads the flag from the `X-Timing` request header
/// (`src/app-api/controllers/database-operations-controller.ts`), not from the
/// request body, so `timing` has to leave the client as a header. The JS
/// client destructures it out of the options object and turns it into
/// `headers: { "X-Timing": "true" }` (`src/client/api/databasesApi.ts`); these
/// tests pin the Swift client to the same behavior on both the untyped and the
/// typed-generic overload.
///
/// `RecordingTransport` scripts the response bytes and records the request, so
/// these run without a server and still exercise the real encode path.
final class DatabasesExecuteOperationTimingTests: XCTestCase {

    private func makeTransport() -> RecordingTransport {
        RecordingTransport(json: #"{"records":[]}"#)
    }

    private func header(_ transport: RecordingTransport, _ name: String) -> String? {
        transport.lastCall?.options?.customHeaders[name]
    }

    // MARK: - Untyped overload

    func test_executeOperation_timingTrue_sendsXTimingHeader() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        _ = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            options: ExecuteOperationOptions(timing: true)
        )

        XCTAssertEqual(header(transport, "X-Timing"), "true")
    }

    /// The header replaces the body field — an unknown `timing` key in the body
    /// is dead weight the server never reads.
    func test_executeOperation_timingTrue_omitsTimingFromBody() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        _ = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            options: ExecuteOperationOptions(timing: true)
        )

        XCTAssertNil(
            transport.lastCall?.jsonBody?["timing"],
            "timing must not be encoded into the request body"
        )
    }

    /// Everything else on the options object still travels in the body.
    func test_executeOperation_keepsOtherOptionsInBody() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        _ = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            options: ExecuteOperationOptions(
                params: .object(["q": .string("x")]),
                limit: 25,
                cursor: "cur-1",
                direction: .descending,
                timing: true
            )
        )

        let body = transport.lastCall?.jsonBody
        XCTAssertEqual(body?["params"]?["q"]?.stringValue, "x")
        XCTAssertEqual(body?["limit"]?.numberValue, 25)
        XCTAssertEqual(body?["cursor"]?.stringValue, "cur-1")
        XCTAssertEqual(body?["direction"]?.numberValue, -1)
        XCTAssertNil(body?["timing"])
    }

    /// `timing: false` is the JS client's falsy branch — no header at all,
    /// rather than `X-Timing: false`. (The server tests `=== "true"`, so both
    /// suppress the timing block; sending nothing keeps the two clients
    /// byte-identical on the wire.)
    func test_executeOperation_timingFalse_sendsNoHeader() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        _ = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            options: ExecuteOperationOptions(timing: false)
        )

        XCTAssertNil(header(transport, "X-Timing"))
    }

    func test_executeOperation_timingOmitted_sendsNoHeader() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        _ = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            options: ExecuteOperationOptions(limit: 5)
        )

        XCTAssertNil(header(transport, "X-Timing"))
    }

    /// A `nil` options object keeps sending `{}` with no custom headers.
    func test_executeOperation_nilOptions_sendsEmptyBodyAndNoHeader() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        _ = try await api.executeOperation(databaseId: "db1", name: "getThings")

        XCTAssertEqual(transport.lastCall?.jsonBody, .object([:]))
        XCTAssertNil(header(transport, "X-Timing"))
    }

    // MARK: - Typed generic overload (the CLI-generated `<Type>Ops` path)

    private struct EmptyParams: Encodable {}
    private struct EmptyResult: Decodable, Sendable {}

    func test_typedExecuteOperation_timingTrue_sendsXTimingHeader() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        let _: EmptyResult = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            params: EmptyParams(),
            timing: true
        )

        XCTAssertEqual(header(transport, "X-Timing"), "true")
        XCTAssertNil(transport.lastCall?.jsonBody?["timing"])
    }

    func test_typedExecuteOperation_timingOmitted_sendsNoHeader() async throws {
        let transport = makeTransport()
        let api = DatabasesAPI(transport: transport)

        let _: EmptyResult = try await api.executeOperation(
            databaseId: "db1",
            name: "getThings",
            params: EmptyParams(),
            limit: 10
        )

        XCTAssertNil(header(transport, "X-Timing"))
        XCTAssertEqual(transport.lastCall?.jsonBody?["limit"]?.numberValue, 10)
    }
}
