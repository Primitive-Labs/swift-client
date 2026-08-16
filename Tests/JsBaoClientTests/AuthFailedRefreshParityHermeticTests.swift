import XCTest
@testable import JsBaoClient

/// Server-free mirrors of the JS reference pins in
/// `tests/client/js-bao-client-auth-failed-parity.test.ts` (issue #2723): the
/// `authFailed` events an app observes when the server rejects a refresh must
/// be the same on both clients, per rejection cause.
///
/// JS spreads the decision over two emit sites — `handleRefreshOutcome`
/// suppresses the HTTP 401-retry cause, and `JsBaoClient`'s `onRefreshOutcome`
/// wiring emits for exactly that cause — so no single Swift call site can be
/// read against a single JS one. The table the JS pins establish, which these
/// tests assert this client delivers:
///
///   | refresh cause                            | app sees                       |
///   |------------------------------------------|--------------------------------|
///   | 401-retry on an HTTP request (`"http"`)  | `{ reason: "refresh_failed" }` |
///   | manual/background (`"networkMode:online"`, `"auto-network:online"`) | `{ reason: <cause> }` |
///   | launch-time bootstrap (`"startup"`)      | nothing                        |
///
/// The 401-retry row runs through the real `HttpClient` → `AuthController`
/// wiring `JsBaoClient` builds (`makeWiredClients`, which passes the production
/// `cause: "http"`), against the stubbed `URLSession` the other refresh suites
/// use. The background row is asserted twice: once with the cause its explicit
/// call site passes, and once end to end through a real `JsBaoClient` whose
/// reachability comes back — the two entry points carry different causes in JS,
/// so the reason an app sees differs too.
final class AuthFailedRefreshParityHermeticTests: XCTestCase {

    /// Thread-safe event log.
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    override func tearDown() {
        RefreshStubURLProtocol.reset()
        super.tearDown()
    }

    private func describe(_ events: [AuthFailedEvent]) -> String {
        events
            .map { "(reason: \($0.reason ?? "nil"), message: \($0.message ?? "nil"))" }
            .joined(separator: ", ")
    }

    // MARK: - Behavior 1: the 401-retry refresh on an authenticated request

    /// A rejected 401-retry refresh delivers exactly one `authFailed`, carrying
    /// the reason JS's second emit site uses (`refresh_failed`) and no message
    /// — JS emits the bare `{ reason: "refresh_failed" }` payload there.
    func testRejected401RetryRefreshEmitsRefreshFailed() async throws {
        RefreshStubURLProtocol.configure(
            refreshedToken: makeTestJwt(userId: "u1"),
            refreshDelay: 0,
            refreshStatus: 401
        )

        let emitter = EventEmitter()
        let failures = Recorder<AuthFailedEvent>()
        let sub = emitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
        defer { sub.cancel() }

        let (auth, http) = makeWiredClients(
            initialToken: makeTestJwt(userId: "u1-stale"),
            emitter: emitter
        )

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("a rejected refresh must surface the 401 to the caller")
        } catch {
            // The request outcome is pinned by the sign-out suites (#2655);
            // this one is about the events.
        }

        // #2723 changes which events fire, not whether the session ends: the
        // rejected refresh still signs the user out (#2655).
        XCTAssertNil(auth.getToken(), "a rejected refresh still ends the session")

        let observed = failures.all
        XCTAssertEqual(
            observed.count, 1,
            "JS delivers exactly one auth-failed for the HTTP 401-retry refresh; got: \(describe(observed))"
        )
        XCTAssertEqual(
            observed.first?.reason, "refresh_failed",
            "JS emits { reason: \"refresh_failed\" } for this cause (JsBaoClient.onRefreshOutcome)"
        )
        XCTAssertNil(
            observed.first?.message,
            "JS's payload for this cause carries a reason only"
        )
    }

    /// Edge case: a 2xx refresh body carrying no token is the same "invalid
    /// session" as a 401 (#2655), so it reaches the app through the same event.
    func testRefreshWithoutTokenOnRequestPathEmitsRefreshFailed() async throws {
        // An empty `token` is the no-token body: `refreshDirect` throws
        // `RefreshTokenMissingError`, and every other request keeps 401ing.
        RefreshStubURLProtocol.configure(
            refreshedToken: "",
            refreshDelay: 0,
            refreshStatus: 200
        )

        let emitter = EventEmitter()
        let failures = Recorder<AuthFailedEvent>()
        let sub = emitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
        defer { sub.cancel() }

        let (_, http) = makeWiredClients(
            initialToken: makeTestJwt(userId: "u1-stale"),
            emitter: emitter
        )

        _ = try? await http.request(method: "GET", path: "/me")

        let observed = failures.all
        XCTAssertEqual(
            observed.count, 1,
            "a 2xx-without-token refresh is the same invalid session; got: \(describe(observed))"
        )
        XCTAssertEqual(observed.first?.reason, "refresh_failed")
        XCTAssertNil(observed.first?.message)
    }

    // MARK: - Behavior 2: a manual/background refresh

    /// A refresh the app drives outside any request reaches the JS
    /// `handleRefreshOutcome` emit site, which reports the CAUSE as the reason.
    func testRejectedBackgroundRefreshEmitsTheCause() async throws {
        RefreshStubURLProtocol.configure(
            refreshedToken: makeTestJwt(userId: "u1"),
            refreshDelay: 0,
            refreshStatus: 401
        )

        let emitter = EventEmitter()
        let failures = Recorder<AuthFailedEvent>()
        let sub = emitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
        defer { sub.cancel() }

        let (auth, _) = makeWiredClients(
            initialToken: makeTestJwt(userId: "u1"),
            emitter: emitter
        )

        // The cause `JsBaoClient`'s online handoff passes when the USER pins
        // online; the automatic restore has its own (asserted below).
        let outcome = await auth.refreshAccessToken(
            cause: JsBaoClient.OnlineHandoffCause.explicitOnline
        )
        guard case .invalid = outcome else {
            return XCTFail("a 401 refresh must classify as .invalid, got \(outcome)")
        }

        let observed = failures.all
        XCTAssertEqual(
            observed.count, 1,
            "JS delivers exactly one auth-failed for a background refresh; got: \(describe(observed))"
        )
        XCTAssertEqual(
            observed.first?.reason, "networkMode:online",
            "JS reports the refresh cause as the reason for this site"
        )
        XCTAssertEqual(
            observed.first?.message, "Authentication refresh failed",
            "JS's default message when the rejection carries no error"
        )
    }

    /// The background row again, this time through the production path that
    /// produces it without anybody asking: reachability returns and the client
    /// refreshes on its own. JS runs that entry point from
    /// `runReachabilityRestore`, whose cause is `auto-network:online` — a
    /// DIFFERENT string from the explicit `setNetworkMode("online")` one — and
    /// since the reason IS the cause, one shared cause here would hand a Swift
    /// app a reason no JS app ever sees.
    func testRejectedReachabilityRestoreRefreshEmitsTheAutoNetworkCause() async throws {
        let monitor = FakeConnectivityMonitor()
        // Port 1 is nothing: the socket never connects and the startup refresh
        // fails at the transport before the stub below is installed.
        let client = JsBaoClient(
            options: JsBaoClientOptions(
                apiUrl: "http://127.0.0.1:1",
                wsUrl: "ws://127.0.0.1:1",
                appId: "test-app",
                token: nil,
                logLevel: .error,
                storageConfig: .memory,
                autoNetwork: true
            ),
            connectivityMonitor: monitor
        )
        defer { Task { await client.destroy() } }

        // Every refresh from here on is a server rejection, not an outage.
        client.authController.replaceTransportForTesting(RecordingTransport(
            status: 401,
            json: #"{"error":"invalid_refresh"}"#
        ))
        // Let the token-less startup refresh (#2656) settle first, so what the
        // recorder holds below is the restore's own rejection.
        await client.authController.waitForAuthReady()

        let failures = Recorder<AuthFailedEvent>()
        let sub = client.eventEmitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
        defer { sub.cancel() }

        try await eventually(timeout: 3, description: "monitor started") {
            monitor.isStarted
        }
        // Lose the network first so the restore is a real transition, then
        // bring it back: `.auto` + reachable + no token runs the handoff.
        monitor.push(false)
        try await eventually(timeout: 3, description: "gate closed after loss") {
            client.networkingAllowed() == false
        }
        monitor.push(true)

        try await eventually(timeout: 5, description: "restore's rejected refresh reported") {
            failures.all.count >= 1
        }
        try await delay(0.3) // let any second emit land before counting

        let observed = failures.all
        XCTAssertEqual(
            observed.count, 1,
            "one rejected refresh, one event; got: \(describe(observed))"
        )
        XCTAssertEqual(
            observed.first?.reason, "auto-network:online",
            "JS's reachability restore refreshes with cause auto-network:online, and this site reports the cause"
        )
        XCTAssertEqual(observed.first?.message, "Authentication refresh failed")
        XCTAssertEqual(client.networkMode, .auto, "the monitor never writes the mode (#2669)")
    }

    // MARK: - Behavior 3: the launch-time bootstrap refresh

    /// A signed-out start is not an auth failure — no event, on either client
    /// (also pinned by #2656 A9; restated so the whole table lives in one place).
    func testRejectedBootstrapRefreshEmitsNothing() async throws {
        RefreshStubURLProtocol.configure(
            refreshedToken: makeTestJwt(userId: "u1"),
            refreshDelay: 0,
            refreshStatus: 401
        )

        let emitter = EventEmitter()
        let failures = Recorder<AuthFailedEvent>()
        let sub = emitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
        defer { sub.cancel() }

        let (auth, _) = makeWiredClients(initialToken: "", emitter: emitter)

        let outcome = await auth.refreshAccessToken(cause: "startup")
        guard case .invalid = outcome else {
            return XCTFail("a 401 refresh must classify as .invalid, got \(outcome)")
        }

        XCTAssertEqual(
            failures.all.count, 0,
            "the launch-time refresh starts the app signed out silently; got: \(describe(failures.all))"
        )
    }
}
