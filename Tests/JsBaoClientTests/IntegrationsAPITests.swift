import XCTest
@testable import JsBaoClient

/// Regression tests for `IntegrationsAPI`.
///
/// Code review of PR #349 flagged the previous Swift `IntegrationsAPI`
/// as too thin: it accepted a flat `[String: Any]` `params` and
/// returned the raw response dict, **without** the structured
/// `IntegrationCallRequest` envelope (method/path/query/headers/body),
/// without unwrapping the proxy response into `(status, headers, body,
/// traceId, durationMs, errorCode)`, and without typed error throwing
/// on non-OK responses. The JS client (`callIntegration` in
/// `JsBaoClient.ts`) does all three. This file exercises the post-fix
/// shape end-to-end.
///
/// Tests run against the dev server. They don't require a configured
/// upstream integration — every assertion below is on the *contract*
/// of the request and the error mapping.
final class IntegrationsAPITests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-integrations-api")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    /// `integrationKey` is required. Passing an empty string must
    /// throw `JsBaoError(.invalidArgument)` synchronously without
    /// hitting the network — matches JS's argument validation.
    func testCall_emptyIntegrationKey_throwsInvalidArgument() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let request = IntegrationCallRequest(
            integrationKey: "",
            method: "GET",
            path: "/anything"
        )

        do {
            _ = try await client.integrations.call(request)
            XCTFail("Expected invalidArgument error for empty integrationKey")
        } catch let error as JsBaoError {
            XCTAssertEqual(
                error.code,
                .invalidArgument,
                "Expected .invalidArgument; got \(error.code) (\(error.message ?? ""))"
            )
        } catch {
            XCTFail("Expected JsBaoError, got \(type(of: error)): \(error)")
        }
    }

    /// Calling a non-existent integration must throw a typed
    /// `JsBaoError` with an integration-specific code (most commonly
    /// `.integrationNotFound` for a 404, possibly `.accessDenied`
    /// depending on how the dev server maps unknown integrations).
    /// Pre-fix the call would have returned a raw dict with no error
    /// thrown — this test catches the contract regression.
    func testCall_unknownIntegration_throwsTypedJsBaoError() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let request = IntegrationCallRequest(
            integrationKey: "nonexistent-integration-\(UUID().uuidString)",
            method: "GET",
            path: "/some/path"
        )

        do {
            _ = try await client.integrations.call(request)
            XCTFail("Expected JsBaoError for unknown integration; call returned successfully instead")
        } catch let error as JsBaoError {
            // Acceptable codes per the JS error mapping in
            // JsBaoClient.callIntegration. The exact code depends on
            // server semantics for "no such integration" (404 vs
            // 401/403 if auth gates list visibility).
            let acceptable: Set<JsBaoErrorCode> = [
                .integrationNotFound,
                .integrationProxyFailed,
                .accessDenied,
            ]
            XCTAssertTrue(
                acceptable.contains(error.code),
                "Expected one of \(acceptable.map(\.rawValue)); got \(error.code.rawValue) (\(error.message ?? ""))"
            )
        } catch {
            XCTFail(
                "Expected JsBaoError, got \(type(of: error)): \(error). " +
                "If this is a raw [String: Any] return value, IntegrationsAPI " +
                "regressed to the pre-fix flat shape — it must throw a typed " +
                "JsBaoError on non-OK proxy responses."
            )
        }
    }

    /// Compile-time shape check: `IntegrationCallRequest` and
    /// `IntegrationCallResponse` must exist with the expected fields.
    /// If any of these field accesses break, the JS-parity contract
    /// has regressed.
    func testTypeShape_compileTimeOnly() {
        let req = IntegrationCallRequest(
            integrationKey: "k",
            method: "POST",
            path: "/v1/x",
            query: ["a": "b"],
            headers: ["X-Foo": "bar"],
            body: ["payload": 1]
        )
        XCTAssertEqual(req.integrationKey, "k")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/x")
        XCTAssertEqual(req.query?["a"], "b")
        XCTAssertEqual(req.headers?["X-Foo"], "bar")

        let resp = IntegrationCallResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: ["k": "v"],
            traceId: "trace-1",
            durationMs: 12.3,
            errorCode: nil
        )
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "application/json")
        XCTAssertEqual(resp.traceId, "trace-1")
        XCTAssertEqual(resp.durationMs, 12.3)
        XCTAssertNil(resp.errorCode)
    }
}
