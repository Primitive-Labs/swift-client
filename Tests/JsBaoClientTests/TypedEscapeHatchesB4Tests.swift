import XCTest
@testable import JsBaoClient

/// #1991 Phase B4 — the public escape hatches on `JsBaoClient` (behavior 7).
///
/// `makeRequest` / `makeRawRequest` were removed by #2367 at the end of their
/// deprecation cycle. The supported replacements — `request` (typed),
/// `requestJSON` (dynamic), `requestData` (bytes) — are thin forwards onto the
/// same `Transport` spine every wrapped API uses.
///
/// Every test here runs against the local dev server (`setUp` creates an
/// app). The server-free source assertions live in `TransportSpineTests`.
final class TypedEscapeHatchesB4Tests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-b4-hatches")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    // MARK: - Typed `request`

    struct MeResponse: Decodable, Sendable {
        let userId: String
    }

    /// The headline of the phase: an unwrapped endpoint decodes straight into
    /// the caller's own type, with no `Any` cast anywhere in the call.
    func testTypedRequestDecodesIntoTheCallersOwnType() async throws {
        let me: MeResponse = try await client.request(method: .get, path: "/me")
        XCTAssertFalse(me.userId.isEmpty)
    }

    /// A request body is an `Encodable` value, not a dictionary — and the
    /// response still decodes typed.
    func testTypedRequestSendsAnEncodableBody() async throws {
        struct CreateDocument: Encodable, Sendable {
            let title: String
        }
        struct CreatedDocument: Decodable, Sendable {
            let documentId: String
        }

        let created: CreatedDocument = try await client.request(
            method: .post,
            path: "/documents",
            body: CreateDocument(title: "B4 typed escape hatch")
        )
        XCTAssertFalse(created.documentId.isEmpty)
    }

    /// Non-2xx surfaces as `HttpError` with the status — the same policy the
    /// wrapped APIs get, because it is the same single primitive.
    func testTypedRequestThrowsHttpErrorOnNonSuccess() async throws {
        do {
            let _: MeResponse = try await client.request(
                method: .get, path: "/nonexistent-endpoint"
            )
            XCTFail("Expected a non-2xx status to throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }

    // MARK: - Dynamic `requestJSON`

    /// The direct replacement for `makeRequest` when the shape really is
    /// dynamic: a `JSONValue` rather than an `Any` graph, navigable without a
    /// cast.
    func testRequestJSONReturnsANavigableJsonValue() async throws {
        let me = try await client.requestJSON(method: .get, path: "/me")
        let userId = try XCTUnwrap(me?["userId"]?.stringValue)
        XCTAssertFalse(userId.isEmpty)
    }

    /// A dynamic body goes out as `[String: JSONValue]` — still `Encodable`,
    /// still `Sendable`, no `JSONSerialization` graph.
    func testRequestJSONSendsADynamicBody() async throws {
        let body: [String: JSONValue] = ["title": .string("B4 dynamic body")]
        let created = try await client.requestJSON(
            method: .post, path: "/documents", body: body
        )
        XCTAssertNotNil(created?["documentId"]?.stringValue)
    }

    // MARK: - Raw `requestData`

    /// `requestData` hands back the response bytes with the status and does
    /// **not** throw on a non-2xx — the contract the deprecated
    /// `makeRawRequest` had, minus its UTF-8 reconstruction.
    func testRequestDataReturnsBytesAndStatusWithoutThrowing() async throws {
        let (data, status) = try await client.requestData(
            method: .get, path: "/nonexistent-endpoint"
        )
        XCTAssertEqual(status, 404)
        XCTAssertFalse(data.isEmpty, "the error body should reach the caller as bytes")
    }

    /// On a 2xx the bytes are the response body verbatim — the contract the
    /// removed `makeRawRequest` had, minus its UTF-8 reconstruction. Kept from
    /// that method's test, retargeted at its replacement.
    func testRequestDataReturnsTheResponseBytesVerbatimOnSuccess() async throws {
        let (data, status) = try await client.requestData(method: .get, path: "/me")
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the raw bytes should be the response body verbatim"
        )
        XCTAssertNotNil(json["userId"])
    }

    // The two source assertions that used to live here (both legacy entry
    // points stay deprecated, and the client never calls its own deprecated
    // surface) moved to `TransportSpineTests`: this class's `setUp` creates a
    // live app, and XCTest runs `setUp` before every test method, so a
    // server-free grep parked here never ran in a server-free lane.
}
