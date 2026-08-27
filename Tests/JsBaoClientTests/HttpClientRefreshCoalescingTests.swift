import XCTest
@testable import JsBaoClient

/// Server-free tests for the #1983 fix: `HttpClient` no longer runs its own
/// uncoalesced token refresh. Its 401 path now delegates to
/// `AuthController.refreshAccessToken`, which is single-flight — so a burst of
/// N concurrent 401s produces exactly ONE `POST /auth/refresh` instead of N.
///
/// The network layer is stubbed with a `URLProtocol` (injected via
/// `HttpClientConfig.sessionConfiguration`) so the 401 → refresh → retry cycle
/// runs entirely offline. The stub counts refresh round trips directly, which
/// is the assertion a live dev server cannot make (it does not rotate refresh
/// cookies, so N parallel refreshes all succeed there whether or not
/// coalescing is active).
///
/// The stub (`RefreshStubURLProtocol`) and the client wiring
/// (`makeWiredClients`) are shared with the other refresh suites and live in
/// `Helpers/RefreshTestSupport.swift`.
final class HttpClientRefreshCoalescingTests: XCTestCase {

    override func tearDown() {
        RefreshStubURLProtocol.reset()
        super.tearDown()
    }

    /// Behavior 1 + 2 (and edge case 1): a burst of N concurrent requests that
    /// each get a 401 must coalesce into exactly ONE `POST /auth/refresh`, and
    /// every request must then retry with the refreshed token and succeed.
    func testConcurrentUnauthorizedRequestsCoalesceRefresh() async throws {
        let refreshedJwt = makeTestJwt(userId: "u1")
        RefreshStubURLProtocol.configure(
            refreshedToken: refreshedJwt,
            // Hold the single refresh in flight long enough that every
            // concurrent 401'd caller reaches the coalescing check.
            refreshDelay: 0.2,
            refreshStatus: 200
        )

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        let callerCount = 50
        let results: [Bool] = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<callerCount {
                group.addTask {
                    do {
                        _ = try await http.request(method: "GET", path: "/me")
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var collected: [Bool] = []
            for await ok in group { collected.append(ok) }
            return collected
        }

        XCTAssertEqual(
            RefreshStubURLProtocol.refreshCount, 1,
            "N concurrent 401s must coalesce to exactly one POST /auth/refresh"
        )
        XCTAssertEqual(results.count, callerCount)
        XCTAssertTrue(
            results.allSatisfy { $0 },
            "every request must retry with the refreshed token and succeed"
        )
        XCTAssertTrue(
            RefreshStubURLProtocol.sawAuthorizedRetryWithNewToken,
            "the retry after refresh must carry the refreshed bearer token"
        )
    }

    /// Behavior 3 (and edge case 1): when the refresh itself returns 401
    /// (invalid refresh cookie), the original request surfaces an
    /// `HttpError(status: 401)` — the logout/invalid path is preserved — and
    /// the refresh does not recurse into a second round trip.
    func testInvalidRefreshSurfaces401() async throws {
        RefreshStubURLProtocol.configure(
            refreshedToken: makeTestJwt(userId: "u1"),
            refreshDelay: 0,
            refreshStatus: 401
        )

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("Expected a 401 to be thrown when the refresh is invalid")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401, "invalid refresh must surface as HTTP 401")
        } catch {
            XCTFail("Expected HttpError(401), got: \(error)")
        }

        XCTAssertEqual(
            RefreshStubURLProtocol.refreshCount, 1,
            "an invalid refresh must not recurse into a second POST /auth/refresh"
        )
    }
}
