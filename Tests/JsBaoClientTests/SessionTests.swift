import XCTest
@testable import JsBaoClient
import YSwift

final class SessionTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-session")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Get Session

    /// Regression: `client.session.get()` must hit `GET /session`, not
    /// `GET /me`.
    ///
    /// **The test JWT trick.** `TestContext` mints JWTs directly and
    /// bootstraps the user — it does NOT go through the magic-link /
    /// OTP / passkey / OAuth flows that produce a real `Session` DB
    /// row. So calling `GET /session` here returns the server's
    /// "No active session found" 404, while `GET /me` would return
    /// 200 with user info regardless of session presence. **The 404
    /// path is itself the discriminating signal:** if we land on it,
    /// we're calling the right endpoint.
    ///
    /// We accept either outcome:
    ///   - **Success path** (a real session exists, e.g. when this
    ///     suite is later extended to drive a real auth flow): assert
    ///     the response carries `sessionId`, which `/me` never does.
    ///   - **404 path** (current default with bare-JWT bootstrapping):
    ///     assert the error body says "No active session found" —
    ///     proves we hit `/session` and not `/me`.
    ///
    /// If `/me` were called instead, this test would silently succeed
    /// at the user-info shape but fail BOTH branches above.
    func testGetSession_hitsSessionEndpoint() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        do {
            let result = try await client.session.get()
            // If we get here, the server returned 200 — assert the
            // discriminating field from /session's success shape.
            XCTAssertFalse(
                result.sessionId.isEmpty,
                "session.get() returned 200 but with an empty `sessionId`. " +
                "Either SessionAPI is calling /me (which never returns " +
                "sessionId) or the server's /session response shape changed. " +
                "Got: \(result)"
            )
        } catch let error as HttpError where error.status == 404 {
            // Expected with test-JWT bootstrap: no Session row exists.
            // The 404 body MUST mention sessions — otherwise we hit
            // some unrelated 404 (wrong path, etc.).
            let body = error.body ?? ""
            XCTAssertTrue(
                body.lowercased().contains("session"),
                "404 from session.get() must mention 'session' in the body. " +
                "Got: \(body). " +
                "If this test sees a 404 with no session-related body, the " +
                "request likely hit the wrong path entirely."
            )
        } catch {
            XCTFail(
                "session.get() failed unexpectedly: \(type(of: error)) \(error). " +
                "Expected either a 200 with `sessionId` or a 404 'No active session found'."
            )
        }
    }
}
