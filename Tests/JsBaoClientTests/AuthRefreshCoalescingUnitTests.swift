import XCTest
@testable import JsBaoClient

/// Server-free unit tests for `AuthController.refreshAccessToken()`
/// single-flight coalescing, added with the `NSLock.lock()/unlock()` →
/// scoped `withLock` conversion (issue #1910, Phase 3 / behavior 9).
///
/// The existing `AuthRefreshCoalescingTests` runs against the dev server,
/// which does NOT rotate refresh tokens — so on that server N concurrent
/// refreshes all succeed whether or not coalescing is active, and it cannot
/// actually assert single-flight (noted in that file, and flagged by the
/// codex design review as "can't actually assert coalescing"). These tests
/// use the existing `AuthController.makeRequest` injection seam to count
/// refresh round trips directly, proving the coalescing invariant the
/// `withLock` conversion must preserve: a burst of N concurrent callers
/// produces exactly ONE `POST /auth/refresh`. The check-and-register of the
/// in-flight Task is one atomic `withLock`; the refresh `await` runs OUTSIDE
/// the lock in the escaping Task, so later callers observe the in-flight Task
/// and await it instead of starting their own round trip.
final class AuthRefreshCoalescingUnitTests: XCTestCase {

    /// Thread-safe counter for asserting how many refresh round trips ran.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// A JWT whose payload decodes so `applyToken` parses a userId and the
    /// controller ends up authenticated (parity with a real refresh). Only
    /// the payload segment matters — signature is not verified client-side.
    private func makeJwt(userId: String) -> String {
        let payload: [String: Any] = ["userId": userId, "sub": userId, "exp": 9_999_999_999]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(b64).s"
    }

    private func makeController(
        makeRequest: @escaping (String, String, Any?) async throws -> Any
    ) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: EventEmitter(),
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.makeRequest = makeRequest
        return controller
    }

    /// A burst of N concurrent refreshes must coalesce into exactly one
    /// `POST /auth/refresh`. This is the assertion the server-backed suite
    /// cannot make.
    func testConcurrentRefreshesCoalesceToSingleRoundTrip() async throws {
        let refreshCalls = AtomicCounter()
        let token = makeJwt(userId: "u1")
        let controller = makeController { method, path, _ in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(path, "/auth/refresh")
            refreshCalls.increment()
            // Hold the refresh in flight long enough for every concurrent
            // caller to reach the coalescing check (mirrors the KvCache
            // dedup test's approach).
            try await Task.sleep(nanoseconds: 200_000_000)
            return ["token": token]
        }

        let callerCount = 50
        let outcomes = await withTaskGroup(of: RefreshOutcome.self) { group -> [RefreshOutcome] in
            for _ in 0..<callerCount {
                group.addTask { await controller.refreshAccessToken(cause: "test") }
            }
            var collected: [RefreshOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        XCTAssertEqual(
            refreshCalls.value, 1,
            "N concurrent refreshes must dedupe to exactly one POST /auth/refresh"
        )
        XCTAssertEqual(outcomes.count, callerCount)
        XCTAssertTrue(
            outcomes.allSatisfy { $0 == .success },
            "all coalesced callers observe the shared success outcome"
        )
        XCTAssertTrue(
            controller.isAuthenticated(),
            "controller holds the refreshed token after the burst"
        )
    }

    /// The coalescing window must CLOSE after the in-flight refresh settles:
    /// a later refresh starts a fresh round trip (pendingRefresh is cleared
    /// under the lock in the `.started` branch), rather than being
    /// permanently deduped to the first.
    func testSequentialRefreshesEachStartNewRoundTrip() async throws {
        let refreshCalls = AtomicCounter()
        let token = makeJwt(userId: "u1")
        let controller = makeController { _, _, _ in
            refreshCalls.increment()
            return ["token": token]
        }

        let first = await controller.refreshAccessToken(cause: "first")
        let second = await controller.refreshAccessToken(cause: "second")

        XCTAssertEqual(first, .success)
        XCTAssertEqual(second, .success)
        XCTAssertEqual(
            refreshCalls.value, 2,
            "sequential refreshes each perform their own round trip once the in-flight Task clears"
        )
    }
}
