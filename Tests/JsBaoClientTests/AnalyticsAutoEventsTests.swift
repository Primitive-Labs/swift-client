import XCTest
@testable import JsBaoClient

/// Live integration coverage for the typed `client.analytics` namespace
/// (#951) and the `analyticsAutoEvents` gating (#963) — #1058 bucket 1.
///
/// Observability: events are captured via `AnalyticsQueue.onEventLogged`
/// (internal, `@testable`-only) — the Swift analog of the JS tests poking
/// `client.analyticsQueue`. The queue itself, the WS transport, and the dev
/// server are all real.
final class AnalyticsAutoEventsTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-analytics-auto")
    }

    override func tearDown() async throws {
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    /// Thread-safe captured-events box.
    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [[String: Any]] = []
        func append(_ e: [String: Any]) { lock.lock(); events.append(e); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return events }
        func actions() -> [String] { all.compactMap { $0["action"] as? String } }
    }

    // MARK: - Typed namespace (#951)

    /// Happy path: `client.analytics.logEvent` (typed input), `logSnapshot`,
    /// the overrides, and `flush` all funnel through the real queue and the
    /// live WS without error. The prepared event carries the queue-stamped
    /// `user_ulid` / `timestamp` and the plan/app-version overrides.
    func testTypedNamespaceLogEventAndOverrides() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let box = EventBox()
        client.analyticsQueue.onEventLogged = { box.append($0) }

        client.analytics.setPlanOverride("pro")
        client.analytics.setAppVersionOverride("9.9.9-test")
        client.analytics.logEvent(AnalyticsEventInput(
            action: "button_click",
            feature: "cta",
            context_json: .object(["marker": .string("typed-namespace-test")])
        ))
        client.analytics.logSnapshot(context: .object(["screen": .string("home")]))

        try await eventually(timeout: 5, description: "typed events captured") {
            box.actions().contains("button_click") && box.actions().contains("_snapshot")
        }

        guard let click = box.all.first(where: { $0["action"] as? String == "button_click" }) else {
            XCTFail("button_click event not captured")
            return
        }
        XCTAssertEqual(click["feature"] as? String, "cta")
        XCTAssertEqual(click["plan"] as? String, "pro")
        XCTAssertEqual(click["app_version"] as? String, "9.9.9-test")
        XCTAssertEqual(click["user_ulid"] as? String, testApp.ownerUserId)
        XCTAssertNotNil(click["timestamp"], "queue must stamp a timestamp")

        let snapshot = box.all.first { $0["action"] as? String == "_snapshot" }
        XCTAssertEqual(snapshot?["feature"] as? String, "_state")

        // Drain over the live socket — flush must not error or kill the
        // connection (the server accepts the analytics.batch frame).
        try await client.connect()
        try await waitForConnection(client: client)
        client.analytics.flush()
        try await delay(1)
        XCTAssertTrue(client.isConnected, "connection must survive an analytics.batch flush")
    }

    /// Edge: `logSnapshot` no-ops when there is no authenticated user
    /// (mirrors JS `analytics.logSnapshot` bailing when the user ulid
    /// resolver returns null).
    func testLogSnapshotNoOpsWithoutUser() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: testApp.appId,
            token: nil,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let box = EventBox()
        client.analyticsQueue.onEventLogged = { box.append($0) }

        client.analytics.logSnapshot(context: .object(["screen": .string("home")]))
        try await delay(0.5)
        XCTAssertTrue(
            box.actions().isEmpty,
            "logSnapshot must no-op without an authenticated user, got: \(box.actions())"
        )
    }

    // MARK: - analyticsAutoEvents gating (#963)

    /// Happy path: with the default config (`dailyAuth: true`), the first
    /// successful auth of the day emits the `user_active_daily` auto-event
    /// (feature `session`).
    func testDailyAuthAutoEventEmittedByDefault() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let box = EventBox()
        client.analyticsQueue.onEventLogged = { box.append($0) }

        // Re-apply the token — emits `.authSuccess`, which drives the
        // dailyAuth auto-event (fresh in-memory store, so no prior
        // `lastDailyAuthDate` suppresses it).
        client.updateToken(testApp.ownerJWT, cause: "login")

        try await eventually(timeout: 5, description: "user_active_daily auto-event") {
            box.all.contains {
                $0["action"] as? String == "user_active_daily"
                    && $0["feature"] as? String == "session"
            }
        }
    }

    /// Edge (the actual #963 gate): with `analyticsAutoEvents.dailyAuth =
    /// false` the same auth flow must NOT emit `user_active_daily`.
    func testDailyAuthAutoEventGatedOff() async throws {
        var config = AnalyticsAutoEventsConfig()
        config.dailyAuth = false
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            analyticsAutoEvents: config
        )
        defer { Task { await client.destroy() } }

        let box = EventBox()
        client.analyticsQueue.onEventLogged = { box.append($0) }

        client.updateToken(testApp.ownerJWT, cause: "login")
        try await delay(2)

        XCTAssertFalse(
            box.actions().contains("user_active_daily"),
            "dailyAuth=false must suppress user_active_daily; got actions: \(box.actions())"
        )
    }

    /// dailyAuth dedupes within a calendar day: a second auth on the same
    /// (in-memory) metadata store does not emit a second `user_active_daily`.
    func testDailyAuthAutoEventOncePerDay() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let box = EventBox()
        client.analyticsQueue.onEventLogged = { box.append($0) }

        client.updateToken(testApp.ownerJWT, cause: "login")
        try await eventually(timeout: 5, description: "first user_active_daily") {
            box.actions().contains("user_active_daily")
        }

        client.updateToken(testApp.ownerJWT, cause: "login")
        try await delay(2)

        let count = box.actions().filter { $0 == "user_active_daily" }.count
        XCTAssertEqual(count, 1, "user_active_daily must emit at most once per day per user")
    }

    /// blobUploads.success auto-event: a real blob upload through the live
    /// server emits `blob_upload_succeeded` (feature `blobs`) exactly once —
    /// and is suppressed when `blobUploadsSuccess` is gated off.
    func testBlobUploadSuccessAutoEventAndGate() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Analytics Blob Doc"
        )

        // Default config: event fires on a successful upload.
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }
        let box = EventBox()
        client.analyticsQueue.onEventLogged = { box.append($0) }

        let blobs = client.documents.blobs(documentId: docId)
        let upload = try await blobs.upload(
            data: "auto-event payload".data(using: .utf8)!,
            options: BlobUploadSourceOptions(filename: "auto.txt", contentType: "text/plain")
        )
        try await eventually(timeout: 8, description: "blob_upload_succeeded auto-event") {
            box.all.contains {
                $0["action"] as? String == "blob_upload_succeeded"
                    && $0["feature"] as? String == "blobs"
            }
        }

        // Gated client: same upload path, no auto-event.
        var config = AnalyticsAutoEventsConfig()
        config.blobUploadsSuccess = false
        let gated = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            analyticsAutoEvents: config
        )
        defer { Task { await gated.destroy() } }
        let gatedBox = EventBox()
        gated.analyticsQueue.onEventLogged = { gatedBox.append($0) }

        _ = try await gated.documents.blobs(documentId: docId).upload(
            data: "gated payload".data(using: .utf8)!,
            options: BlobUploadSourceOptions(filename: "gated.txt", contentType: "text/plain")
        )
        try await delay(2)
        XCTAssertFalse(
            gatedBox.actions().contains("blob_upload_succeeded"),
            "blobUploadsSuccess=false must suppress the auto-event"
        )

        _ = upload // keep the happy-path result alive for clarity
    }
}
