import XCTest
@testable import JsBaoClient

/// Server-free unit tests for `JsBaoClient.runOnlineAuthHandoff()` single-flight
/// coalescing, added with the `NSLock.lock()/unlock()` → scoped `withLock`
/// conversion (issue #1910, Phase 5 / `JsBaoClient`).
///
/// A burst of concurrent `goOnline()` calls with no usable token must run the
/// online-auth handoff exactly ONCE — every caller coalesces onto the shared
/// `pendingOnlineHandoff` Task — so `auth:onlineAuthRequired` fires a single
/// time, not once per caller. This is the exact hazard the source comment
/// warns about ("a doubled *failed* handoff would emit `.authOnlineRequired`
/// twice"), and the coalescing the `withLock` conversion must preserve: the
/// check-and-register of `pendingOnlineHandoff` is one atomic `withLock`, and
/// only the `.started` caller clears it after awaiting — outside the lock.
///
/// The token-refresh round trip is itself single-flight inside `AuthController`,
/// so the JsBaoClient-level coalescing signal is the number of handoff runs =
/// the number of `.authOnlineRequired` emissions (a broken coalescer would run
/// N handoffs and emit N times even though the refresh dedupes to one). That
/// emission count is the load-bearing assertion here.
final class OnlineHandoffCoalescingTests: XCTestCase {

    /// Thread-safe counter for asserting emission / round-trip counts.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    private struct RefreshUnavailable: Error {}

    /// Resume the awaiting continuation exactly once (timeout vs. body race).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
        func resume(_ value: Bool) {
            let taken: CheckedContinuation<Bool, Never>? = lock.withLock {
                let c = cont; cont = nil; return c
            }
            taken?.resume(returning: value)
        }
    }

    /// Fails (rather than hanging the suite) if `body` does not finish within
    /// `timeout`. A coalesced `goOnline()` caller stranded by a broken split
    /// would never return, hanging `withTaskGroup` forever; the timeout resumes
    /// and the stuck task is leaked — acceptable, it only happens on a genuine
    /// regression (mirrors `WebSocketManagerDisconnectTests.assertAsyncCompletes`).
    private func assertAsyncCompletes(
        within timeout: TimeInterval = 8,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping @Sendable () async -> Void
    ) async {
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            Task { await body(); gate.resume(true) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume(false)
            }
        }
        if !finished {
            XCTFail("Coalescing watchdog: \(description) did not complete within \(timeout)s — a goOnline() caller was likely stranded.",
                    file: file, line: line)
        }
    }

    /// Build an offline client (no token, no auto-connect, in-memory storage)
    /// whose refresh round trip is stubbed to hold in flight for `holdMs` then
    /// fail — so the handoff always reaches the `.authOnlineRequired` +
    /// offline-revert branch without any server.
    private func makeOfflineClient(
        refreshCalls: AtomicCounter,
        holdMs: UInt64
    ) -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: nil,
            storageConfig: .memory,
            autoNetwork: false
        ))
        client.authController.makeRequest = { _, _, _ in
            refreshCalls.increment()
            if holdMs > 0 { try await Task.sleep(nanoseconds: holdMs * 1_000_000) }
            throw RefreshUnavailable()
        }
        return client
    }

    /// A burst of N concurrent `goOnline()` with no token must coalesce into
    /// ONE handoff run → exactly one `auth:onlineAuthRequired`. A broken
    /// coalescer would run N handoffs and emit N times.
    func testConcurrentGoOnlineCoalescesToSingleHandoff() async throws {
        let refreshCalls = AtomicCounter()
        let onlineAuthRequired = AtomicCounter()
        // 200ms in-flight hold lets every concurrent caller reach the
        // coalescing check before the leader's handoff settles.
        let client = makeOfflineClient(refreshCalls: refreshCalls, holdMs: 200)
        defer { Task { await client.destroy() } }

        let sub = client.events.on(.authOnlineRequired) { (_: AuthOnlineRequiredEvent) in
            onlineAuthRequired.increment()
        }
        defer { sub.cancel() }

        let callers = 50
        await assertAsyncCompletes(within: 8, "\(callers) concurrent goOnline() callers") {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<callers {
                    group.addTask { await client.goOnline() }
                }
                await group.waitForAll()
            }
        }

        // Let the trailing applyNetworkMode(.offline) revert + any late emit settle.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            onlineAuthRequired.value, 1,
            "N concurrent goOnline() with no token must coalesce to ONE handoff → one auth:onlineAuthRequired (got \(onlineAuthRequired.value))"
        )
        XCTAssertEqual(
            refreshCalls.value, 1,
            "the single coalesced handoff performs exactly one refresh round trip"
        )
        XCTAssertEqual(
            client.getNetworkMode(), .offline,
            "the failed handoff reverts the client to offline mode"
        )
    }

    /// The coalescing window must CLOSE after the in-flight handoff settles: a
    /// later `goOnline()` starts a fresh handoff (`pendingOnlineHandoff` is
    /// cleared under the lock in the `.started` branch), rather than being
    /// permanently deduped to the first.
    func testSequentialGoOnlineEachRunsHandoff() async throws {
        let refreshCalls = AtomicCounter()
        let onlineAuthRequired = AtomicCounter()
        let client = makeOfflineClient(refreshCalls: refreshCalls, holdMs: 0)
        defer { Task { await client.destroy() } }

        let sub = client.events.on(.authOnlineRequired) { (_: AuthOnlineRequiredEvent) in
            onlineAuthRequired.increment()
        }
        defer { sub.cancel() }

        await client.goOnline()
        await client.goOnline()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            refreshCalls.value, 2,
            "two sequential goOnline() calls each run their own handoff once the in-flight Task clears"
        )
        XCTAssertEqual(
            onlineAuthRequired.value, 2,
            "each sequential handoff emits its own auth:onlineAuthRequired"
        )
    }
}
