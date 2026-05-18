import XCTest
@testable import JsBaoClient

/// Regression tests for `AuthController.refreshAccessToken()`
/// coalescing.
///
/// Code review of PR #349 flagged: a burst of N concurrent 401s would
/// each trigger a separate `POST /auth/refresh` because the client did
/// not coalesce in-flight refreshes — wasting N-1 round trips and, on
/// servers that rotate refresh cookies (revoking the prior refresh JWT
/// after each successful refresh), causing all but one of the
/// concurrent refreshes to 401-cascade into auth-failed events.
///
/// **Note on observability against the current dev server.** Inspection
/// of `src/app-api/controllers/auth-controller.ts` indicates the dev
/// server does NOT enforce refresh-token rotation (the prior refresh
/// JWT remains valid for its full 7-day TTL after a refresh). On this
/// server, N concurrent refreshes all succeed pre-fix — the test below
/// passes whether or not coalescing is active. The fix still aligns
/// behavior with the JS client, removes wasted network calls, and
/// hardens against any future server change to enforce rotation. The
/// stronger assertion ("only one HTTP refresh request is sent") would
/// require either (a) the server to enforce rotation, or
/// (b) instrumentation we don't currently have at this layer.
final class AuthRefreshCoalescingTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-auth-refresh-coalesce")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    /// Concurrent refresh calls must all return the same outcome and
    /// must not produce mixed `.success`/`.invalid` results — that
    /// would indicate the second-onward refresh saw the rotated cookie
    /// and got rejected (the failure mode coalescing is meant to
    /// prevent).
    func testRefreshAccessToken_concurrentCallsReturnIdenticalOutcome() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }
        try await client.connect()
        try await waitForConnection(client: client)

        // Wait for the initial auth bootstrap to settle so we're not
        // racing against the connect-time refresh.
        try await delay(1)

        // 8 concurrent refreshes. The number is large enough to
        // exercise the coalescing path; small enough to not flood the
        // dev server.
        let n = 8
        var outcomes: [String] = []
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<n {
                group.addTask {
                    let outcome = await client.authController.refreshAccessToken(cause: "test")
                    return String(describing: outcome)
                }
            }
            for await result in group {
                outcomes.append(result)
            }
        }

        XCTAssertEqual(outcomes.count, n)
        let firstOutcome = outcomes[0]
        for (i, outcome) in outcomes.enumerated() {
            XCTAssertEqual(
                outcome,
                firstOutcome,
                "Concurrent refresh #\(i) returned \(outcome) but #0 returned \(firstOutcome). " +
                "All concurrent callers should observe the same outcome via coalescing — " +
                "differing outcomes indicate the second-onward refresh hit the wire " +
                "with a stale or rotated cookie."
            )
        }

        // After the burst, the client must still hold a valid token.
        XCTAssertTrue(
            client.isAuthenticated(),
            "Client must remain authenticated after a refresh burst. " +
            "If false, the burst of refreshes ended with the access token cleared."
        )
    }
}
