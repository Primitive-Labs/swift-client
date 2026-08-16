import XCTest
@testable import JsBaoClient

/// Server-free mirrors of the JS sign-out reference pins in
/// `tests/client/js-bao-client-auth-signout-parity.test.ts` (issue #2655,
/// parity items A1/A2/A6). Each test asserts the same observable outcome the
/// JS client already delivers:
///
/// - A1: a refresh rejected with 401 ends the session — token cleared,
///   `AuthStateEvent(authenticated: false)` emitted, persisted JWT deleted.
/// - A2: `logout()` posts `/auth/logout` best effort and clears the persisted
///   JWT even without `wipeLocal`, so a relaunch stays signed out.
/// - A6: refresh classification — 401 → `.invalid`; 403 and 5xx → `.network`;
///   a 2xx body carrying no `token` → `.invalid`.
///
/// These use the `RecordingTransport` injection seam rather than the dev
/// server: the platform server only ever answers 401 on a bad refresh cookie,
/// so 403 / 5xx / 2xx-without-token are not reachable end to end.
final class AuthSignOutParityTests: XCTestCase {

    /// An in-memory `StorageProvider` that survives repeated `initialize`
    /// calls. `MemoryStorageProvider.initialize` wipes every store, and
    /// `OfflineStore`'s JWT methods each call `initialize` before touching the
    /// record — so with the plain provider nothing written is ever readable
    /// back. The disk-backed providers used in production keep their data
    /// across `initialize`, which is what this models.
    private final class RetainingStorageProvider: StorageProvider, @unchecked Sendable {
        private let inner = MemoryStorageProvider()
        private let lock = NSLock()
        private var initialized = false

        func initialize(namespace: String) async throws {
            let needsInit: Bool = lock.withLock {
                if initialized { return false }
                initialized = true
                return true
            }
            if needsInit { try await inner.initialize(namespace: namespace) }
        }
        func close() async { await inner.close() }
        func isReady() -> Bool { inner.isReady() }
        func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
            try await inner.get(store: store, key: key)
        }
        func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
            try await inner.put(store: store, key: key, value: value, metadata: metadata)
        }
        func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
            try await inner.putBatch(store: store, records: records)
        }
        func delete(store: String, key: String) async throws { try await inner.delete(store: store, key: key) }
        func clear(store: String) async throws { try await inner.clear(store: store) }
        func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
            try await inner.iterate(store: store, callback: callback)
        }
        func keys(store: String) async throws -> [String] { try await inner.keys(store: store) }
        func has(store: String, key: String) async throws -> Bool { try await inner.has(store: store, key: key) }
    }

    /// Thread-safe event log.
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    private struct Fixture {
        let controller: AuthController
        let emitter: EventEmitter
        let store: OfflineStore
        let transport: RecordingTransport
        let namespace: String
        let appId: String
    }

    private func makeFixture(
        namespace: String = "signout-parity",
        store: OfflineStore? = nil,
        responder: @escaping @Sendable (RecordedRequest) async throws -> TransportResponse
    ) async -> Fixture {
        let offlineStore = store ?? OfflineStore()
        if store == nil {
            await offlineStore.setAuthStorageProvider(RetainingStorageProvider())
        }
        let emitter = EventEmitter()
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: offlineStore,
            emitter: emitter,
            refreshProxy: nil,
            persistConfig: AuthConfig(
                persistJwtInStorage: true,
                storageKeyPrefix: namespace
            )
        )
        let transport = RecordingTransport(responder: responder)
        controller.setTransport(transport)
        return Fixture(
            controller: controller,
            emitter: emitter,
            store: offlineStore,
            transport: transport,
            namespace: namespace,
            appId: "test-app"
        )
    }

    private func signIn(_ fixture: Fixture, userId: String = "u1") async {
        fixture.controller.applyToken(
            makeTestJwt(userId: userId),
            previous: nil,
            cause: "google"
        )
        await fixture.controller.awaitPendingPersistence()
    }

    private func persistedJwt(_ fixture: Fixture) async -> PersistedJwtRecord? {
        try? await fixture.store.loadPersistedJwt(
            appId: fixture.appId,
            namespace: fixture.namespace
        )
    }

    private static let refreshRejected = TransportResponse(
        status: 401,
        headers: ["Content-Type": "application/json"],
        body: Data("{\"error\":\"invalid_refresh_token\"}".utf8)
    )

    // MARK: - A1: a rejected refresh ends the session

    /// Behavior 4. A 401 refresh must clear the in-memory token, emit
    /// `AuthStateEvent(authenticated: false)`, and delete the persisted JWT —
    /// the JS `handleRefreshFailure()` → `updateToken(null)` path.
    func testRejectedRefreshSignsTheUserOut() async throws {
        let fixture = await makeFixture(namespace: "invalid-refresh") { _ in
            Self.refreshRejected
        }
        await signIn(fixture)
        XCTAssertNotNil(fixture.controller.getToken())
        let persistedBefore = await persistedJwt(fixture)
        XCTAssertNotNil(persistedBefore, "sign-in should persist the JWT")

        let states = Recorder<AuthStateEvent>()
        let sub = fixture.emitter.subscribe(AuthStateEvent.self) { states.append($0) }
        defer { sub.cancel() }

        let outcome = await fixture.controller.refreshAccessToken(cause: "test")

        guard case .invalid = outcome else {
            return XCTFail("401 refresh must classify as .invalid, got \(outcome)")
        }
        XCTAssertNil(
            fixture.controller.getToken(),
            "a rejected refresh must clear the access token (JS updateToken(null))"
        )
        XCTAssertFalse(
            fixture.controller.isAuthenticated(),
            "isAuthenticated() must be false after a rejected refresh"
        )
        XCTAssertTrue(
            states.all.contains { $0.authenticated == false },
            "a rejected refresh must emit authState{authenticated:false}"
        )

        // The persisted record is deleted asynchronously alongside the clear.
        var persistedAfter = await persistedJwt(fixture)
        for _ in 0..<40 where persistedAfter != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            persistedAfter = await persistedJwt(fixture)
        }
        XCTAssertNil(
            persistedAfter,
            "a rejected refresh must delete the persisted JWT so a relaunch stays signed out"
        )
    }

    // MARK: - A2: logout()

    /// Behavior 5. `logout()` with no `wipeLocal` must post `/auth/logout`
    /// (best effort, clearing the server refresh cookie), clear the persisted
    /// JWT, and leave a later `tryRestoreSession()` signed out.
    func testLogoutRevokesServerSideAndClearsPersistedJwt() async throws {
        let store = OfflineStore()
        await store.setAuthStorageProvider(RetainingStorageProvider())
        let fixture = await makeFixture(namespace: "logout", store: store) { call in
            if call.path.hasSuffix("/auth/logout") {
                return TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data("{\"success\":true}".utf8)
                )
            }
            return Self.refreshRejected
        }
        await signIn(fixture)
        let persistedBefore = await persistedJwt(fixture)
        XCTAssertNotNil(persistedBefore)

        try await fixture.controller.logout()

        XCTAssertNil(fixture.controller.getToken())
        XCTAssertTrue(
            fixture.transport.calls.contains {
                $0.method == .post && $0.path.hasSuffix("/auth/logout")
            },
            "logout() must send a best-effort POST /auth/logout (JS parity)"
        )

        var persistedAfter = await persistedJwt(fixture)
        for _ in 0..<40 where persistedAfter != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            persistedAfter = await persistedJwt(fixture)
        }
        XCTAssertNil(
            persistedAfter,
            "logout() must clear the persisted JWT even without wipeLocal"
        )

        // Relaunch: a fresh controller over the same store must stay signed out.
        let relaunched = await makeFixture(namespace: "logout", store: store) { _ in
            Self.refreshRejected
        }
        await relaunched.controller.tryRestoreSession()
        XCTAssertNil(
            relaunched.controller.getToken(),
            "a relaunch after logout() must not silently sign the user back in"
        )
    }

    /// Edge case: a failing `/auth/logout` must not block local sign-out —
    /// the call is best effort, as in JS.
    func testLogoutStillSignsOutWhenServerLogoutFails() async throws {
        let fixture = await makeFixture(namespace: "logout-failure") { call in
            if call.path.hasSuffix("/auth/logout") {
                throw HttpError(status: 500, message: "boom")
            }
            return Self.refreshRejected
        }
        await signIn(fixture)

        try await fixture.controller.logout()

        XCTAssertNil(fixture.controller.getToken())
        var persistedAfter = await persistedJwt(fixture)
        for _ in 0..<40 where persistedAfter != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            persistedAfter = await persistedJwt(fixture)
        }
        XCTAssertNil(persistedAfter)
    }

    // MARK: - A6: refresh-outcome classification

    /// Behavior 6, part one. 403 and 5xx are connectivity-class failures in
    /// JS (`!res.ok` → `"network"`): they retry on backoff and must not end
    /// the session or emit `authFailed`.
    func testNonAuthErrorStatusesClassifyAsNetwork() async throws {
        for status in [403, 500, 503] {
            let fixture = await makeFixture(namespace: "network-\(status)") { _ in
                throw HttpError(status: status, message: "refresh failed")
            }
            // Keep the backoff retry from firing during the assertions.
            fixture.controller.refreshBackoffBaseMs = 60_000
            await signIn(fixture)
            let token = fixture.controller.getToken()

            let failures = Recorder<AuthFailedEvent>()
            let sub = fixture.emitter.subscribe(AuthFailedEvent.self) { failures.append($0) }
            defer { sub.cancel() }

            let outcome = await fixture.controller.refreshAccessToken(cause: "test")

            guard case .network = outcome else {
                XCTFail("status \(status) must classify as .network, got \(outcome)")
                continue
            }
            XCTAssertEqual(
                fixture.controller.getToken(), token,
                "status \(status) must keep the session (retryable)"
            )
            XCTAssertTrue(
                failures.all.isEmpty,
                "status \(status) must not emit authFailed"
            )
            fixture.controller.destroy()
        }
    }

    /// Behavior 6, part two. A 2xx refresh whose body carries no `token` is a
    /// dead session in JS (`if (!newToken) return "invalid"`), not something to
    /// retry forever on backoff.
    func testSuccessResponseWithoutTokenClassifiesAsInvalid() async throws {
        let fixture = await makeFixture(namespace: "no-token-body") { _ in
            TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"ok\":true}".utf8)
            )
        }
        await signIn(fixture)

        let outcome = await fixture.controller.refreshAccessToken(cause: "test")

        guard case .invalid = outcome else {
            return XCTFail("a 2xx body without a token must be .invalid, got \(outcome)")
        }
        XCTAssertNil(
            fixture.controller.getToken(),
            "a 2xx body without a token ends the session"
        )
    }

    /// Behavior 6, part three. An EMPTY 2xx body carries no token either, so
    /// it ends the session rather than retrying forever: JS reads
    /// `text ? JSON.parse(text) : null` and falls into the same
    /// `if (!newToken) return "invalid"`. A refresh proxy answering 204, or
    /// 200 with no content, is the realistic source.
    func testEmptySuccessBodyClassifiesAsInvalid() async throws {
        for status in [200, 204] {
            let fixture = await makeFixture(namespace: "empty-body-\(status)") { _ in
                TransportResponse(status: status, headers: [:], body: Data())
            }
            await signIn(fixture)

            let outcome = await fixture.controller.refreshAccessToken(cause: "test")

            guard case .invalid = outcome else {
                XCTFail("an empty \(status) refresh body must be .invalid, got \(outcome)")
                continue
            }
            XCTAssertNil(fixture.controller.getToken())
        }
    }

    /// Behavior 6, part four. The refresh-proxy path reads its body itself
    /// (URLSession, not the injected transport), so it needs the same
    /// classification the transport gives the direct path. JS parses one body
    /// for both — `text ? JSON.parse(text) : null; data?.token` — so a bare
    /// `null` is a 2xx carrying no token (session over), not a garbled response.
    /// Mirrors the "a JSON null body" case of the JS pin in
    /// `tests/client/js-bao-client-auth-signout-parity.test.ts`.
    func testRefreshBodyWithoutAUsableTokenIsMissing() throws {
        for body in ["null", "", "   ", "{}", "{\"token\":null}", "{\"token\":\"\"}"] {
            do {
                let token = try AuthController.tokenFromRefreshBody(Data(body.utf8))
                XCTFail("body \(body) must not yield a token, got \(token)")
            } catch is RefreshTokenMissingError {
                // Expected: `.invalid`, the session is over.
            } catch {
                XCTFail("body \(body) must be a missing token, not \(error)")
            }
        }
    }

    /// The other side of the same classification: a body that is not JSON at
    /// all is a garbled response (`JSON.parse` throwing in JS), so it stays on
    /// the retryable `.network` path rather than ending the session.
    func testUnparseableRefreshBodyIsNotAMissingToken() throws {
        XCTAssertThrowsError(try AuthController.tokenFromRefreshBody(Data("not json at all".utf8))) { error in
            XCTAssertFalse(
                error is RefreshTokenMissingError,
                "a malformed body must stay retryable, not end the session"
            )
        }
        XCTAssertEqual(
            try AuthController.tokenFromRefreshBody(Data("{\"token\":\"abc\"}".utf8)),
            "abc"
        )
    }

    // MARK: - Bootstrap carve-out

    /// A rejected STARTUP refresh must not clobber a session the user
    /// established interactively while it was in flight. The success side of
    /// this race is `applyToken(onlyWhenSignedOut:)` (#2656); without the
    /// rejection-side guard, #2655's unconditional sign-out on `.invalid`
    /// would clear the new token and delete the new session's persisted JWT.
    func testBootstrapRejectionKeepsSessionEstablishedWhileInFlight() async throws {
        let releaseRefresh = ReleaseFlag()
        let store = OfflineStore()
        await store.setAuthStorageProvider(RetainingStorageProvider())
        let fixture = await makeFixture(namespace: "bootstrap-race", store: store) { _ in
            // Hold the startup refresh open until the test signals, then
            // reject it: the cookie was stale, but by then the user is in.
            await releaseRefresh.wait()
            return Self.refreshRejected
        }

        let states = Recorder<AuthStateEvent>()
        let sub = fixture.emitter.subscribe(AuthStateEvent.self) { states.append($0) }
        defer { sub.cancel() }

        // No persisted record and no cookie → tryRestoreSession goes straight
        // to the startup refresh, which is now parked in the responder.
        let restore = Task { await fixture.controller.tryRestoreSession() }
        // Wait until the refresh round trip is actually in flight.
        for _ in 0..<200 where fixture.transport.calls.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fixture.transport.calls.isEmpty, "startup refresh never started")

        // Interactive sign-in lands while the startup refresh is in flight.
        await signIn(fixture)
        let interactiveToken = fixture.controller.getToken()
        XCTAssertNotNil(interactiveToken)
        let persistedDuring = await persistedJwt(fixture)
        XCTAssertNotNil(persistedDuring, "sign-in should persist the JWT")

        await releaseRefresh.release()
        await restore.value

        XCTAssertEqual(
            fixture.controller.getToken(), interactiveToken,
            "a rejected startup refresh must not clear a session established while it was in flight"
        )
        let persistedAfter = await persistedJwt(fixture)
        XCTAssertNotNil(
            persistedAfter,
            "the NEW session's persisted JWT must survive the stale cookie's rejection"
        )
        XCTAssertFalse(
            states.all.contains { $0.authenticated == false },
            "no signed-out state may be reported — the user is signed in"
        )
    }

    /// The same race one step later in the session's life: a refresh of an
    /// EXISTING session (cause `"http"`, the 401-retry path) is rejected after
    /// the user has signed in again. The 401 answers for the token the refresh
    /// started from, which nobody holds any more; signing out on it would end a
    /// session the server never rejected, and delete that session's persisted
    /// JWT. The guard is by session identity, not by cause (#2655).
    func testRejectedRefreshKeepsASessionEstablishedWhileInFlight() async throws {
        let releaseRefresh = ReleaseFlag()
        let store = OfflineStore()
        await store.setAuthStorageProvider(RetainingStorageProvider())
        let fixture = await makeFixture(namespace: "refresh-race", store: store) { _ in
            await releaseRefresh.wait()
            return Self.refreshRejected
        }

        await signIn(fixture, userId: "stale-session")
        let staleToken = fixture.controller.getToken()
        XCTAssertNotNil(staleToken)

        let states = Recorder<AuthStateEvent>()
        let sub = fixture.emitter.subscribe(AuthStateEvent.self) { states.append($0) }
        defer { sub.cancel() }

        // Refresh the session the user is holding; park it in the responder.
        let refresh = Task { await fixture.controller.refreshAccessToken(cause: "http") }
        for _ in 0..<200 where fixture.transport.calls.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fixture.transport.calls.isEmpty, "refresh never started")

        // A fresh interactive sign-in lands while that refresh is open.
        await signIn(fixture, userId: "fresh-session")
        let freshToken = fixture.controller.getToken()
        XCTAssertNotNil(freshToken)
        XCTAssertNotEqual(freshToken, staleToken, "the test needs a different session")

        await releaseRefresh.release()
        let outcome = await refresh.value

        guard case .invalid = outcome else {
            return XCTFail("401 refresh must still classify as .invalid, got \(outcome)")
        }
        XCTAssertEqual(
            fixture.controller.getToken(), freshToken,
            "a rejected refresh must only end the session it was refreshing"
        )
        let persistedAfter = await persistedJwt(fixture)
        XCTAssertEqual(
            persistedAfter?.token, freshToken,
            "the new session's persisted JWT must survive the old session's rejection"
        )
        XCTAssertFalse(
            states.all.contains { $0.authenticated == false },
            "no signed-out state may be reported — the user is signed in"
        )
    }

    /// The sign-out paths delete the persisted JWT after draining queued
    /// persistence (`awaitPendingPersistence`). That barrier has to cover EVERY
    /// queued write: with two writes in flight, an earlier, slower one landing
    /// after the delete would put the record back and sign the user in again at
    /// the next launch — the very thing #2655 fixes.
    func testQueuedPersistenceCannotSurviveTheSignOutDelete() async throws {
        let gated = GatedStorageProvider()
        let store = OfflineStore()
        await store.setAuthStorageProvider(gated)
        let fixture = await makeFixture(namespace: "persist-race", store: store) { _ in
            Self.refreshRejected
        }

        // Two token applications: the first write parks inside the provider,
        // the second is registered behind it. Deliberately NOT awaiting
        // persistence here — both are in flight when the refresh is rejected.
        fixture.controller.applyToken(makeTestJwt(userId: "u1"), previous: nil, cause: "google")
        fixture.controller.applyToken(makeTestJwt(userId: "u2"), previous: nil, cause: "google")

        // Fallback release, so the correct implementation — whose drain waits
        // for the parked write — cannot hang. The unfixed one deletes the
        // record long before this fires, and the provider releases the parked
        // write the moment that delete arrives.
        let fallback = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await gated.releaseGate()
        }

        let outcome = await fixture.controller.refreshAccessToken(cause: "test")
        guard case .invalid = outcome else {
            return XCTFail("401 refresh must classify as .invalid, got \(outcome)")
        }
        await fallback.value
        await fixture.controller.awaitPendingPersistence()
        for _ in 0..<200 where gated.completedPuts < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(gated.completedPuts, 2, "both persistence writes should have run")

        let persistedAfter = await persistedJwt(fixture)
        XCTAssertNil(
            persistedAfter,
            "a queued write must not resurrect the record the sign-out deleted"
        )
    }

    /// A storage provider that parks its first `put` until released, and
    /// releases it as soon as a `delete` arrives — so a sign-out that deletes
    /// the record while a write is still queued is followed by that write
    /// landing, which is exactly the ordering under test.
    private final class GatedStorageProvider: StorageProvider, @unchecked Sendable {
        private let inner = RetainingStorageProvider()
        private let gate = ReleaseFlag()
        private let lock = NSLock()
        private var parkNextPut = true
        private var _completedPuts = 0

        var completedPuts: Int { lock.withLock { _completedPuts } }
        func releaseGate() async { await gate.release() }

        func initialize(namespace: String) async throws { try await inner.initialize(namespace: namespace) }
        func close() async { await inner.close() }
        func isReady() -> Bool { inner.isReady() }
        func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
            try await inner.get(store: store, key: key)
        }
        func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
            let park: Bool = lock.withLock {
                let park = parkNextPut
                parkNextPut = false
                return park
            }
            if park { await gate.wait() }
            try await inner.put(store: store, key: key, value: value, metadata: metadata)
            lock.withLock { _completedPuts += 1 }
        }
        func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
            try await inner.putBatch(store: store, records: records)
        }
        func delete(store: String, key: String) async throws {
            await gate.release()
            try await inner.delete(store: store, key: key)
        }
        func clear(store: String) async throws { try await inner.clear(store: store) }
        func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
            try await inner.iterate(store: store, callback: callback)
        }
        func keys(store: String) async throws -> [String] { try await inner.keys(store: store) }
        func has(store: String, key: String) async throws -> Bool { try await inner.has(store: store, key: key) }
    }

    /// One-shot async gate for holding a scripted transport response open.
    private actor ReleaseFlag {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func release() {
            released = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Edge case: a 2xx body that is not decodable JSON stays `.network` in
    /// JS (`JSON.parse` throws → outer catch → `"network"`), so the session
    /// survives a garbled proxy response.
    func testMalformedSuccessBodyClassifiesAsNetwork() async throws {
        let fixture = await makeFixture(namespace: "malformed-body") { _ in
            TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("not json at all".utf8)
            )
        }
        fixture.controller.refreshBackoffBaseMs = 60_000
        await signIn(fixture)
        let token = fixture.controller.getToken()

        let outcome = await fixture.controller.refreshAccessToken(cause: "test")

        guard case .network = outcome else {
            return XCTFail("a malformed 2xx body must be .network, got \(outcome)")
        }
        XCTAssertEqual(fixture.controller.getToken(), token)
        fixture.controller.destroy()
    }
}
