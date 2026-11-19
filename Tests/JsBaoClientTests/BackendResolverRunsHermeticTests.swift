import XCTest
@testable import JsBaoClient

/// The backend resolver's runs (#6185, project `client-backend-overrides`,
/// phase 2; intent criteria 5, 6 and 7): the first run, a later run with and
/// without an override, a failed read, the record file beside the client's
/// database, one request to the home app only, the log line, the answer's
/// fields and `applied(to:)`. A loopback HTTP server is the home server; the
/// stores are real SQLite paths in temporary directories.
final class BackendResolverRunsHermeticTests: XCTestCase {
    private var worlds: [ResolverWorld] = []
    private var stores: [ResolverStore] = []
    private var clients: [JsBaoClient] = []
    private var capture: ResolverLogCapture?

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        worlds.forEach { $0.releaseHeld(); $0.stop() }
        worlds = []
        stores.forEach { $0.remove() }
        stores = []
        capture?.uninstall()
        capture = nil
    }

    private func world(_ policy: String = #"{"clients":{}}"#) throws -> ResolverWorld {
        let world = try ResolverWorld()
        world.setPolicy(policy)
        worlds.append(world)
        return world
    }

    private func store() -> ResolverStore {
        let store = ResolverStore()
        stores.append(store)
        return store
    }

    private func resolve(
        _ options: JsBaoClientOptions,
        timeout: TimeInterval = 5,
        bundleVersion: @escaping @Sendable () -> Any? = { nil }
    ) async -> ResolvedBackend {
        await resolveForTest(options, timeout: timeout, bundleVersion: bundleVersion)
    }

    /// `ios` overrides: from 2.0 to `target-b`, with `apiUrl` when given.
    private static func overridePolicy(_ appId: String = "target-b", from: String = "2.0", apiUrl: String? = nil, latest: String? = nil) -> String {
        let url = apiUrl.map { #","apiUrl":"\#($0)""# } ?? ""
        let latestKey = latest.map { #""latest":"\#($0)","# } ?? ""
        return #"{"clients":{"ios":{\#(latestKey)"backendOverrides":[{"from":"\#(from)","appId":"\#(appId)"\#(url)}]}}}"#
    }

    private func build(_ world: ResolverWorld, _ source: ResolvedBackend.Source, apiUrl: String? = nil) -> ResolvedBackend {
        ResolvedBackend(
            appId: world.appId, apiUrl: apiUrl ?? world.apiUrl, wsUrl: "ws://127.0.0.1:\(world.api.port)",
            overridden: false, source: source
        )
    }

    private func target(_ world: ResolverWorld, _ source: ResolvedBackend.Source, appId: String = "target-b") -> ResolvedBackend {
        ResolvedBackend(
            appId: appId, apiUrl: world.apiUrl, wsUrl: "ws://127.0.0.1:\(world.api.port)",
            overridden: true, source: source
        )
    }

    // MARK: - Behavior 7

    func testNoUsableVersionOrPlatformAnswersTheBuildWithNoRequestAndNoFile() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        let cases: [(String, JsBaoClientOptions, @Sendable () -> Any?)] = [
            ("no version", world.options(version: nil, storage: store.storage), { nil }),
            ("an illegal appVersion", world.options(version: "1.0-beta", storage: store.storage), { nil }),
            ("an illegal bundle version", world.options(version: nil, storage: store.storage), { "" }),
            ("an illegal platform", world.options(platform: "iOS", storage: store.storage), { nil }),
        ]
        for (what, options, bundle) in cases {
            let answer = await resolve(options, bundleVersion: bundle)
            XCTAssertEqual(answer, build(world, .build), what)
        }
        XCTAssertEqual(world.api.requests.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.dir.path), [])
    }

    func testTheBundleVersionIsReadWhenNoAppVersionIsGiven() async throws {
        let world = try world(Self.overridePolicy())
        let answer = await resolve(world.options(version: nil), bundleVersion: { "2.0" })
        XCTAssertEqual(answer, target(world, .fresh))
        XCTAssertEqual(world.policyReads.first?.header("X-Primitive-App-Version"), "2.0")
    }

    func testNoTableForThePlatformAnswersTheBuildFromAFreshRead() async throws {
        let world = try world(#"{"clients":{"android":{"backendOverrides":[{"from":"1.0","appId":"target-b"}]}}}"#)
        let answer = await resolve(world.options())
        XCTAssertEqual(answer, build(world, .fresh))
    }

    // MARK: - Behavior 8

    func testAFirstRunWaitsForTheReadAndStoresTheServedPolicyAndTheTarget() async throws {
        let policy = Self.overridePolicy(apiUrl: "https://b.example.com/", latest: "3.0")
        let world = try world(policy)
        let store = store()
        let answer = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(answer, ResolvedBackend(
            appId: "target-b", apiUrl: "https://b.example.com", wsUrl: "wss://b.example.com", overridden: true, source: .fresh
        ))
        let record = try XCTUnwrap(store.record(world.appId))
        let served = try JSONDecoder().decode(JSONValue.self, from: Data(policy.utf8)).objectValue?["clients"]
        XCTAssertEqual(record["clients"], served, "the clients map as served, overrides included")
        XCTAssertNotNil(record["storedAt"]?.numberValue)
        XCTAssertEqual(store.sentTargets(world.appId), ["target-b https://b.example.com"])
    }

    func testAFirstRunWithoutAnOverrideRecordsNoTarget() async throws {
        let world = try world(#"{"clients":{"ios":{"latest":"3.0"}}}"#)
        let store = store()
        let answer = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(answer, build(world, .fresh))
        XCTAssertNotNil(store.record(world.appId)?["clients"])
        XCTAssertEqual(store.sentTargets(world.appId), [])
    }

    // MARK: - Behavior 9

    func testAFirstRunWhoseReadFailsAnswersTheBuildAndStoresNothing() async throws {
        let failures: [(String, LoopbackAPIServer.Response)] = [
            ("500", .status(500, "boom")),
            ("426", LoopbackAPIServer.Response(status: 426, body: #"{"error":"Update required","code":"CLIENT_UPDATE_REQUIRED"}"#)),
            ("a body that is not JSON", LoopbackAPIServer.Response(status: 200, body: "not json")),
            ("a JSON body that is not an object", LoopbackAPIServer.Response(status: 200, body: "[1,2]")),
        ]
        for (what, response) in failures {
            let world = try world()
            world.policy.value = response
            let store = store()
            let answer = await resolve(world.options(storage: store.storage))
            XCTAssertEqual(answer, build(world, .build), what)
            XCTAssertEqual(world.policyReads.count, 1, what)
            XCTAssertFalse(store.recordExists, what)
        }

        let refused = store()
        let unbound = try unboundLoopbackUrl()
        let world = try world()
        let answer = await resolve(world.options(storage: refused.storage, apiUrl: unbound))
        XCTAssertEqual(answer.source, .build, "a refused connection")
        XCTAssertEqual(answer.apiUrl, unbound)
        XCTAssertFalse(refused.recordExists)

        let dropped = try self.world(Self.overridePolicy())
        dropped.hold.value = 1
        let droppedStore = store()
        async let late = resolveForTest(dropped.options(storage: droppedStore.storage))
        try await eventually(description: "the read arrives") { dropped.heldCount == 1 }
        dropped.stop()
        let droppedAnswer = await late
        XCTAssertEqual(droppedAnswer.source, .build, "a dropped connection")
        XCTAssertFalse(droppedStore.recordExists)
    }

    /// A redirect is a non-2xx answer, not a second request: the policy the
    /// redirect names is never read and never stored as the home policy.
    func testARedirectedReadIsAFailedReadAndItsDestinationIsNeverRequested() async throws {
        let elsewhere = try world(Self.overridePolicy("target-c"))
        let redirect = LoopbackAPIServer.Response(
            status: 302, body: "{}",
            headers: ["Location": "\(elsewhere.apiUrl)/app/\(elsewhere.appId)/api/settings/client-versions"]
        )

        let home = try world()
        home.policy.value = redirect
        let firstStore = store()
        let first = await resolve(home.options(storage: firstStore.storage))
        XCTAssertEqual(first, build(home, .build), "a first run whose read is redirected")
        XCTAssertEqual(home.policyReads.count, 1)
        XCTAssertFalse(firstStore.recordExists)
        XCTAssertTrue(elsewhere.api.requests.isEmpty, "the redirect's destination is never requested")

        elsewhere.setPolicy(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let sent = try world(Self.overridePolicy())
        let sentStore = store()
        let fresh = await resolve(sent.options(storage: sentStore.storage))
        XCTAssertEqual(fresh, target(sent, .fresh))
        sent.policy.value = LoopbackAPIServer.Response(
            status: 302, body: "{}",
            headers: ["Location": "\(elsewhere.apiUrl)/app/\(elsewhere.appId)/api/settings/client-versions"]
        )
        let later = await resolve(sent.options(storage: sentStore.storage))
        XCTAssertEqual(later, target(sent, .stored), "a later run answers the stored override, as on any failed read")
        XCTAssertTrue(elsewhere.api.requests.isEmpty, "the redirect's destination is never requested")
    }

    // MARK: - Behavior 10

    func testAFirstRunWhoseReadIsHeldPastTheTimeoutAnswersTheBuildWithinTheBound() async throws {
        let world = try world(Self.overridePolicy())
        world.hold.value = 1
        let store = store()
        let started = Date()
        let answer = await resolve(world.options(storage: store.storage), timeout: 1)
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(answer, build(world, .build))
        XCTAssertGreaterThanOrEqual(took, 0.9)
        XCTAssertLessThan(took, 3)
        world.releaseHeld()
        try await delay(0.5)
        XCTAssertFalse(store.recordExists, "a late answer stores nothing")
    }

    /// Edge case: a timeout that is zero, negative or not finite uses 10 seconds.
    func testATimeoutThatIsNotPositiveAndFiniteUsesTenSeconds() async throws {
        for timeout in [0, -1, Double.nan, Double.infinity] {
            let world = try world(Self.overridePolicy())
            world.hold.value = 1
            let answer = Task { await resolveForTest(world.options(), timeout: timeout) }
            try await eventually(description: "the read arrives") { world.heldCount == 1 }
            try await delay(1.2)
            world.releaseHeld()
            let value = await answer.value
            XCTAssertEqual(value, target(world, .fresh), "\(timeout)")
        }
    }

    /// A large finite timeout answers like any other and never traps (CSO-6185-008).
    func testALargeFiniteTimeoutAnswers() async throws {
        let world = try world(Self.overridePolicy())
        for timeout in [20_000_000_000, 1e300, Double.greatestFiniteMagnitude] {
            let answer = await resolveForTest(world.options(), timeout: timeout)
            XCTAssertEqual(answer, target(world, .fresh), "\(timeout)")
        }
    }

    // MARK: - Behavior 11

    func testALaterRunWithoutAnOverrideAnswersFromTheStoreAndRefreshesBehind() async throws {
        let world = try world(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let store = store()
        let first = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(first, build(world, .fresh))

        world.setPolicy(Self.overridePolicy(latest: "2.0"))
        world.hold.value = 1
        let second = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(second, build(world, .stored), "answered while the read is held")
        XCTAssertFalse(second.overridden)
        try await eventually(description: "the background read arrives") { world.heldCount == 1 }
        world.releaseHeld()
        try await eventually(description: "the refresh is stored") {
            store.record(world.appId)?["clients"]?.objectValue?["ios"]?.objectValue?["backendOverrides"] != nil
        }

        let third = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(third, target(world, .fresh))
    }

    /// Edge case: a failed background read leaves the record as it was.
    func testAFailedBackgroundReadLeavesTheRecordByteIdentical() async throws {
        let world = try world(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let store = store()
        _ = await resolve(world.options(storage: store.storage))
        let before = try XCTUnwrap(store.recordBytes)
        world.policy.value = .status(500)
        let second = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(second.source, .stored)
        try await eventually(description: "the background read") { world.policyReads.count == 2 }
        try await delay(0.3)
        XCTAssertEqual(store.recordBytes, before)
    }

    // MARK: - Behavior 12

    func testALaterRunWithAnOverrideWaitsAndDecidesFromTheFreshPolicy() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        let first = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(first, target(world, .fresh))

        world.hold.value = 1
        let waiting = Task { await resolveForTest(world.options(storage: store.storage)) }
        try await eventually(description: "the read arrives") { world.heldCount == 1 }
        try await delay(0.3)
        world.releaseHeld()
        let same = await waiting.value
        XCTAssertEqual(same, target(world, .fresh), "waited for the read")

        world.setPolicy(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let removed = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(removed, build(world, .fresh), "a removed override answers home at once")
    }

    // MARK: - Behavior 13

    func testOfflineACopyAlreadySentToTheTargetAnswersTheStoredOverride() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        _ = await resolve(world.options(storage: store.storage))
        world.stop()
        let offline = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(offline, target(world, .stored))

        let withUrl = try self.world(Self.overridePolicy(apiUrl: "https://b.example.com/v1/"))
        let urlStore = self.store()
        _ = await resolve(withUrl.options(storage: urlStore.storage))
        withUrl.stop()
        let offlineUrl = await resolve(withUrl.options(storage: urlStore.storage))
        XCTAssertEqual(offlineUrl, ResolvedBackend(
            appId: "target-b", apiUrl: "https://b.example.com/v1", wsUrl: "wss://b.example.com/v1", overridden: true, source: .stored
        ))
    }

    // MARK: - Behavior 14

    func testOfflineAnOverrideStoredAtALowerVersionAnswersTheBuild() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        let below = await resolve(world.options(version: "1.0", storage: store.storage))
        XCTAssertEqual(below, build(world, .fresh))
        world.stop()
        let atV = await resolve(world.options(version: "2.0", storage: store.storage))
        XCTAssertEqual(atV, build(world, .build))
    }

    // MARK: - Behavior 15

    func testOfflineAnOverrideWhoseApiUrlChangedSinceTheCopyWasSentAnswersTheBuild() async throws {
        let world = try world(Self.overridePolicy(apiUrl: "https://one.example.com"))
        let store = store()
        let first = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(first.apiUrl, "https://one.example.com")

        world.setPolicy(Self.overridePolicy(apiUrl: "https://two.example.com"))
        _ = await resolve(world.options(version: "1.0", storage: store.storage))
        try await eventually(description: "the background refresh stores the change") {
            store.record(world.appId)?["clients"].map { "\($0)".contains("two.example.com") } == true
        }
        world.stop()
        let offline = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(offline, build(world, .build))
    }

    // MARK: - Behavior 16

    func testOneCallSendsOneUnauthenticatedRequestToTheHomePolicyRoute() async throws {
        let world = try world(Self.overridePolicy())
        _ = await resolve(world.options(token: makeTestJwt(userId: "home-user")))
        XCTAssertEqual(world.api.requests.count, 1)
        let request = try XCTUnwrap(world.api.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/app/\(world.appId)/api/settings/client-versions")
        XCTAssertEqual(request.header("X-Global-Admin-App-Id"), "global-admin-6185")
        XCTAssertEqual(request.header("X-Primitive-App-Version"), "2.0")
        XCTAssertEqual(request.header("X-Primitive-App-Platform"), "ios")
        XCTAssertNil(request.header("Authorization"))
        XCTAssertFalse(world.api.requests.contains { $0.path.contains("target-b") })
    }

    /// Edge case: a build `apiUrl` with a trailing slash.
    func testABuildApiUrlWithATrailingSlashReadsWithoutItAndComparesTargetsWithoutIt() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        let first = await resolve(world.options(storage: store.storage, apiUrl: world.apiUrl + "/"))
        XCTAssertEqual(first.apiUrl, world.apiUrl + "/")
        XCTAssertEqual(world.policyReads.first?.path, "/app/\(world.appId)/api/settings/client-versions")
        XCTAssertEqual(store.sentTargets(world.appId), ["target-b \(world.apiUrl)"])
        world.stop()
        let offline = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(offline, target(world, .stored))
    }

    // MARK: - Behavior 17

    func testEachSourceSaysWhatItIsAndEachCallLogsOneLine() async throws {
        let capture = ResolverLogCapture()
        self.capture = capture
        let world = try world(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let store = store()
        let home = world.appId
        let fresh = await resolve(world.options(storage: store.storage, logLevel: .warn))
        XCTAssertEqual([fresh.overridden ? "y" : "n", fresh.source.rawValue], ["n", "fresh"])
        let stored = await resolve(world.options(storage: store.storage, logLevel: .warn))
        XCTAssertEqual([stored.overridden ? "y" : "n", stored.source.rawValue], ["n", "stored"])
        try await eventually(description: "the background read") { world.policyReads.count == 2 }
        world.setPolicy(Self.overridePolicy())
        let overridden = await resolve(world.options(version: "3.0", storage: store.storage, logLevel: .warn))
        XCTAssertEqual([overridden.overridden ? "y" : "n", overridden.source.rawValue], ["n", "stored"])
        try await eventually(description: "the background refresh") {
            store.record(home)?["clients"].map { "\($0)".contains("target-b") } == true
        }
        let viaOverride = await resolve(world.options(version: "3.0", storage: store.storage, logLevel: .warn))
        XCTAssertEqual([viaOverride.overridden ? "y" : "n", viaOverride.source.rawValue], ["y", "fresh"])
        world.stop()
        let failed = await resolve(world.options(version: "3.0", platform: "macos", logLevel: .warn))
        XCTAssertEqual([failed.overridden ? "y" : "n", failed.source.rawValue], ["n", "build"])

        let api = world.apiUrl
        let lines = capture.infoLines(home: home)
        XCTAssertEqual(lines.count, 5, "\(lines)")
        guard lines.count == 5 else { return }
        XCTAssertEqual(lines[0], "home=\(home) version=2.0 platform=ios appId=\(home) apiUrl=\(api) overridden=false source=fresh")
        XCTAssertEqual(lines[1], "home=\(home) version=2.0 platform=ios appId=\(home) apiUrl=\(api) overridden=false source=stored")
        XCTAssertEqual(lines[3], "home=\(home) version=3.0 platform=ios appId=target-b apiUrl=\(api) overridden=true source=fresh")
        XCTAssertTrue(lines[4].hasPrefix("home=\(home) version=3.0 platform=macos appId=\(home) apiUrl=\(api) overridden=false source=build (read failed"), lines[4])

        let quiet = try self.world()
        _ = await resolve(quiet.options(logLevel: .none))
        XCTAssertEqual(capture.infoLines(home: quiet.appId), [], "no line at .none")
        _ = await resolve(quiet.options(version: nil, logLevel: .error))
        XCTAssertEqual(capture.infoLines(home: quiet.appId), [
            "home=\(quiet.appId) version=(none) platform=ios appId=\(quiet.appId) apiUrl=\(quiet.apiUrl) overridden=false source=build (no usable version or platform)",
        ])
    }

    func testAReadHeldPastTheTimeoutSaysSoInItsLine() async throws {
        let capture = ResolverLogCapture()
        self.capture = capture
        let world = try world()
        world.hold.value = 1
        _ = await resolve(world.options(logLevel: .warn), timeout: 0.5)
        XCTAssertEqual(capture.infoLines(home: world.appId).count, 1)
        XCTAssertTrue(capture.infoLines(home: world.appId).first?.hasSuffix("source=build (read timed out)") == true,
                      "\(capture.infoLines(home: world.appId))")
    }

    /// Criterion 7: the deadline covers loading the record. A load held past
    /// it answers the build's values without a read.
    func testARecordLoadHeldPastTheTimeoutAnswersTheBuildWithinTheBound() async throws {
        let capture = ResolverLogCapture()
        self.capture = capture
        let world = try world(Self.overridePolicy())
        let store = store()
        await holdRecordLock(for: 2.5)
        let started = Date()
        let answer = await resolve(world.options(storage: store.storage, logLevel: .warn), timeout: 0.5)
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(answer, build(world, .build))
        XCTAssertLessThan(took, 2, "the answer does not wait for the lock")
        XCTAssertEqual(world.api.requests.count, 0, "no read without the record")
        XCTAssertTrue(capture.infoLines(home: world.appId).first?.hasSuffix("source=build (the store did not answer in time)") == true,
                      "\(capture.infoLines(home: world.appId))")
        try await delay(2.5)
        XCTAssertFalse(store.recordExists)
    }

    /// Criterion 7: the deadline covers the awaited write. A write held past it
    /// answers the fresh decision at the deadline and still lands afterwards.
    func testARecordWriteHeldPastTheTimeoutAnswersAtTheDeadlineAndStillLands() async throws {
        let capture = ResolverLogCapture()
        self.capture = capture
        let world = try world(Self.overridePolicy())
        world.hold.value = 1
        let store = store()
        let started = Date()
        async let late = resolveForTest(world.options(storage: store.storage, logLevel: .warn), timeout: 1.5)
        try await eventually(description: "the read arrives") { world.heldCount == 1 }
        await holdRecordLock(for: 2.5)
        world.releaseHeld()
        let answer = await late
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(answer, target(world, .fresh))
        XCTAssertLessThan(took, 2.3, "the answer does not wait for the lock")
        XCTAssertTrue(
            capture.infoLines(home: world.appId).first?.hasSuffix("source=fresh (the store write was still pending at the deadline)") == true,
            "\(capture.infoLines(home: world.appId))"
        )
        try await eventually(timeout: 5, description: "the write lands once the lock is free") {
            store.sentTargets(world.appId) == ["target-b \(world.apiUrl)"]
        }
    }

    // MARK: - Behavior 18 and its edge case

    func testAppliedReplacesTheBackendAndDropsTheTokenOnlyWhenOverridden() throws {
        let given = JsBaoClientOptions(
            apiUrl: "https://home.example.com", wsUrl: "wss://home.example.com", appId: "home-app",
            token: "home-token", offline: false, maxReconnectDelay: 42, globalAdminAppId: "gaa",
            wsHeaders: ["X-A": "1"], blobUploadConcurrency: 3, logLevel: .debug,
            storageConfig: .sqlite(directory: "/tmp/x.sqlite"), auth: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: "ns"),
            autoNetwork: false, appVersion: "2.0", platform: "ios"
        )
        func assertKept(_ options: JsBaoClientOptions, _ what: String) {
            XCTAssertEqual(options.offline, false, what)
            XCTAssertEqual(options.maxReconnectDelay, 42, what)
            XCTAssertEqual(options.globalAdminAppId, "gaa", what)
            XCTAssertEqual(options.wsHeaders, ["X-A": "1"], what)
            XCTAssertEqual(options.blobUploadConcurrency, 3, what)
            XCTAssertEqual(options.logLevel, .debug, what)
            XCTAssertEqual(options.auth.persistJwtInStorage, true, what)
            XCTAssertEqual(options.auth.storageKeyPrefix, "ns", what)
            XCTAssertEqual(options.autoNetwork, false, what)
            XCTAssertEqual(options.appVersion, "2.0", what)
            XCTAssertEqual(options.platform, "ios", what)
        }

        let home = ResolvedBackend(appId: "home-app", apiUrl: "https://home.example.com", wsUrl: "wss://home.example.com", overridden: false, source: .stored)
        let kept = home.applied(to: given)
        XCTAssertEqual([kept.appId, kept.apiUrl, kept.wsUrl], ["home-app", "https://home.example.com", "wss://home.example.com"])
        XCTAssertEqual(kept.token, "home-token")
        assertKept(kept, "not overridden")
        guard case .sqlite(let homePath) = kept.storageConfig else { return XCTFail("not overridden") }
        XCTAssertEqual(homePath, "/tmp/x.sqlite")

        let elsewhere = ResolvedBackend(appId: "target-b", apiUrl: "https://b.example.com", wsUrl: "wss://b.example.com", overridden: true, source: .fresh)
        let moved = elsewhere.applied(to: given)
        XCTAssertEqual([moved.appId, moved.apiUrl, moved.wsUrl], ["target-b", "https://b.example.com", "wss://b.example.com"])
        XCTAssertNil(moved.token)
        assertKept(moved, "overridden")
        // An explicit SQLite file holds one session whatever the app id: the target gets its own file beside it.
        guard case .sqlite(let targetPath) = moved.storageConfig else { return XCTFail("overridden") }
        XCTAssertEqual(targetPath, "/tmp/x.sqlite.target-b.sqlite")
        let odd = ResolvedBackend(appId: "b/../c ä", apiUrl: "https://b.example.com", wsUrl: "wss://b.example.com", overridden: true, source: .fresh)
        guard case .sqlite(let oddPath) = odd.applied(to: given).storageConfig else { return XCTFail("odd app id") }
        XCTAssertEqual(oddPath, "/tmp/x.sqlite.b%2F%2E%2E%2Fc%20%C3%A4.sqlite")
        // Two app ids that differ only in letter case never share a file, also on a case-insensitive volume.
        let upper = ResolvedBackend(appId: "TARGET-B", apiUrl: "https://b.example.com", wsUrl: "wss://b.example.com", overridden: true, source: .fresh)
        guard case .sqlite(let upperPath?) = upper.applied(to: given).storageConfig else { return XCTFail("upper-case app id") }
        XCTAssertEqual(upperPath, "/tmp/x.sqlite.%54%41%52%47%45%54-%42.sqlite")
        XCTAssertNotEqual(upperPath.lowercased(), targetPath?.lowercased())
        func storage(_ config: StorageConfig) -> StorageConfig {
            elsewhere.applied(to: JsBaoClientOptions(apiUrl: "https://home.example.com", wsUrl: "wss://home.example.com", appId: "home-app", storageConfig: config)).storageConfig
        }
        guard case .sqlite(nil) = storage(.sqlite()) else { return XCTFail("the default file is already one per app id") }
        guard case .memory = storage(.memory) else { return XCTFail("memory storage is kept") }

        let sameServer = ResolvedBackend(appId: "target-b", apiUrl: "https://home.example.com", wsUrl: "wss://home.example.com", overridden: true, source: .stored)
        XCTAssertNil(sameServer.applied(to: given).token, "an override with no apiUrl still drops the token")
    }

    func testThePublicFunctionResolves() async throws {
        let world = try world(Self.overridePolicy())
        let answer = await JsBaoClient.resolveBackend(options: world.options())
        XCTAssertEqual(answer, target(world, .fresh))
    }

    // MARK: - Behavior 19

    func testTheRecordLivesBesideTheDatabasePathPerAuthNamespace() async throws {
        let world = try world(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let store = store()
        _ = await resolve(world.options(storage: store.storage))
        XCTAssertTrue(store.recordExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath), "the database file is never created")
        let again = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(again.source, .stored)
        let other = await resolve(world.options(storage: store.storage, prefix: "other"))
        XCTAssertEqual(other.source, .fresh, "another namespace is a first run")
        XCTAssertNotNil(store.record(world.appId, namespace: "other"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
    }

    /// Edge case: an unreadable record, or one for another app, is absent.
    func testARecordThatCannotBeReadOrIsForAnotherAppIsAbsent() async throws {
        for (what, text) in [("empty", ""), ("not JSON", "{oops"),
                             ("another app", #"{"records":{"[\"other-app\",\"default\"]":{"clients":{"ios":{"latest":"2.0"}},"storedAt":1}}}"#)] {
            let world = try world(Self.overridePolicy())
            let store = store()
            try store.writeRecordFile(text)
            let answer = await resolve(world.options(storage: store.storage))
            XCTAssertEqual(answer, target(world, .fresh), what)
            XCTAssertEqual(world.policyReads.count, 1, what)
        }
    }

    /// Edge case: a record that cannot be written changes no answer.
    func testARecordThatCannotBeWrittenStillAnswers() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        let blocker = store.dir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let options = world.options(storage: .sqlite(directory: blocker.appendingPathComponent("store.sqlite").path))
        let first = await resolve(options)
        XCTAssertEqual(first, target(world, .fresh))
        let second = await resolve(options)
        XCTAssertEqual(second, target(world, .fresh))
    }

    /// Edge case: memory storage keeps no record.
    func testMemoryStorageMakesEveryRunAFirstRunAndCreatesNoFile() async throws {
        let world = try world(#"{"clients":{"ios":{"latest":"2.0"}}}"#)
        let first = await resolve(world.options(storage: .memory))
        let second = await resolve(world.options(storage: .memory))
        XCTAssertEqual([first.source, second.source], [.fresh, .fresh])
        XCTAssertEqual(world.policyReads.count, 2)
        let defaultRecord = SQLiteStorageProvider.defaultDatabasePath(appId: world.appId) + ".backend-resolver.json"
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultRecord))
    }

    /// Edge case: an object body with no readable `clients` map is an empty policy.
    func testABodyWithNoClientsMapIsAnEmptyPolicyStored() async throws {
        let world = try world(#"{"other":1}"#)
        let store = store()
        let answer = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(answer, build(world, .fresh))
        XCTAssertEqual(store.record(world.appId)?["clients"], .object([:]))
    }

    // MARK: - Behavior 20

    func testTwoCallsTogetherAgreeAndRecordTheTargetOnce() async throws {
        let world = try world(Self.overridePolicy())
        let store = store()
        async let one = resolveForTest(world.options(storage: store.storage))
        async let two = resolveForTest(world.options(storage: store.storage))
        let (a, b) = await (one, two)
        XCTAssertEqual(a, target(world, .fresh))
        XCTAssertEqual(b, a)
        XCTAssertEqual(store.sentTargets(world.appId), ["target-b \(world.apiUrl)"])
    }

    func testACallHoldingAnOlderRecordDoesNotRemoveATargetAnotherCallRecorded() async throws {
        let policy = #"{"clients":{"ios":{"backendOverrides":[{"from":"2.0","appId":"target-b"},{"from":"3.0","appId":"target-c"}]}}}"#
        let world = try world(policy)
        let store = store()
        _ = await resolve(world.options(version: "2.0", storage: store.storage))
        world.hold.value = 1
        let older = Task { await resolveForTest(world.options(version: "2.0", storage: store.storage)) }
        try await eventually(description: "the older call's read is held") { world.heldCount == 1 }
        let newer = await resolve(world.options(version: "3.0", storage: store.storage))
        XCTAssertEqual(newer.appId, "target-c")
        XCTAssertEqual(store.sentTargets(world.appId), ["target-b \(world.apiUrl)", "target-c \(world.apiUrl)"])
        world.releaseHeld()
        let olderAnswer = await older.value
        XCTAssertEqual(olderAnswer.appId, "target-b")
        XCTAssertEqual(store.sentTargets(world.appId), ["target-b \(world.apiUrl)", "target-c \(world.apiUrl)"])
    }

    func testTheSeventeenthTargetPushesOutTheOldest() async throws {
        let world = try world(Self.overridePolicy("target-17"))
        let store = store()
        var fields: [String] = []
        for index in 1...16 {
            let name = #"sent:["target-\#(index)","https://\#(index).example.com"]"#
            let quoted = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
            fields.append(#"\#(quoted):{"appId":"target-\#(index)","apiUrl":"https://\#(index).example.com","at":\#(index)}"#)
        }
        let key = String(decoding: try JSONEncoder().encode(resolverRecordKey(world.appId, "default")), as: UTF8.self)
        try store.writeRecordFile(#"{"records":{\#(key):{\#(fields.joined(separator: ","))}}}"#)
        let answer = await resolve(world.options(storage: store.storage))
        XCTAssertEqual(answer.appId, "target-17")
        let sent = store.sentTargets(world.appId)
        XCTAssertEqual(sent.count, 16)
        XCTAssertFalse(sent.contains("target-1 https://1.example.com"), "\(sent)")
        XCTAssertTrue(sent.contains("target-17 \(world.apiUrl)"))
        XCTAssertTrue(sent.contains("target-2 https://2.example.com"))
    }

    // MARK: - Behavior 21

    func testAClientNeverTouchesTheRecordAndTheResolverNeverTouchesTheClientsPolicy() async throws {
        let world = try world(Self.overridePolicy(latest: "2.5"))
        let store = store()
        _ = await resolve(world.options(version: "1.0", storage: store.storage))
        let before = try XCTUnwrap(store.recordBytes)

        let clientWorld = try AppVersionWorld(policy: #"{"clients":{"ios":{"latest":"4.0"}}}"#)
        defer { clientWorld.stop() }
        let options = world.options(version: "1.0", storage: store.storage)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: clientWorld.apiUrl, wsUrl: clientWorld.wsUrl, appId: options.appId, offline: false,
            logLevel: .none, storageConfig: store.storage, autoNetwork: false, appVersion: "1.0", platform: "ios"
        ))
        let status = await client.appVersion.getStatus()
        XCTAssertEqual(status, .updateAvailable)
        await client.destroy()
        XCTAssertEqual(store.recordBytes, before, "the client leaves the record alone")

        func storedPolicy() async -> ClientVersionPolicyRecord? {
            let reader = OfflineStore()
            await reader.setAuthStorageProvider(SQLiteStorageProvider(path: store.databasePath))
            let value = await reader.loadClientVersions(appId: options.appId)
            await reader.closeStorage()
            return value
        }
        let row = await storedPolicy()
        XCTAssertEqual(row?.clients["ios"]?.latest, "4.0")
        world.setPolicy(Self.overridePolicy(latest: "9.0"))
        _ = await resolve(world.options(version: "2.0", storage: store.storage))
        let after = await storedPolicy()
        XCTAssertEqual(after, row, "the resolver leaves the client's policy alone")
    }

    // MARK: - Behavior 31

    func testTheHomeTokenNeverReachesTheTarget() async throws {
        let targetWorld = try AppVersionWorld()
        defer { targetWorld.stop() }
        let homeWorld = try world(Self.overridePolicy(apiUrl: targetWorld.apiUrl))
        let store = store()
        let homeToken = makeTestJwt(userId: "home-user")
        let options = homeWorld.options(storage: store.storage, token: homeToken, persistSession: true)
        let answer = await resolve(options)
        XCTAssertEqual(answer.appId, "target-b")
        XCTAssertEqual(answer.apiUrl, targetWorld.apiUrl)

        let client = JsBaoClient(options: answer.applied(to: options))
        clients.append(client)
        await client.waitForStorageReady(timeout: 5)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        try? await client.connect()
        try await delay(0.5)
        XCTAssertGreaterThan(targetWorld.api.requests.count, 0)
        XCTAssertFalse(targetWorld.api.requests.contains { $0.header("Authorization")?.contains(homeToken) == true })
        XCTAssertNil(client.auth.token)
        await client.destroy()
        clients.removeAll()

        let stored = try await persistedSession(at: store.databasePath + ".target-b.sqlite", appId: "target-b")
        XCTAssertNotEqual(stored?.token, homeToken)

        // A session the target app's store already holds is restored as usual.
        let targetToken = makeTestJwt(userId: "target-user")
        let seeding = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: targetWorld.apiUrl, wsUrl: targetWorld.wsUrl, appId: "target-b", token: targetToken, offline: false,
            logLevel: .none, storageConfig: answer.applied(to: options).storageConfig, auth: AuthConfig(persistJwtInStorage: true), autoNetwork: false,
            appVersion: "2.0", platform: "ios"
        ))
        await seeding.waitForStorageReady(timeout: 5)
        try await delay(0.3)
        await seeding.destroy()

        let restored = JsBaoClient(options: answer.applied(to: options))
        clients.append(restored)
        await restored.waitForStorageReady(timeout: 5)
        try await eventually(description: "the target session is restored") { restored.auth.token == targetToken }
        let mark = targetWorld.api.requests.count
        _ = try? await restored.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        let since = targetWorld.api.requests.dropFirst(mark)
        XCTAssertTrue(since.contains { $0.header("Authorization") == "Bearer \(targetToken)" })
        XCTAssertFalse(since.contains { $0.header("Authorization")?.contains(homeToken) == true })
    }

    /// The session stored in the SQLite file at `path`, or `nil`.
    private func persistedSession(at path: String, appId: String) async throws -> PersistedJwtRecord? {
        let reader = OfflineStore()
        await reader.setAuthStorageProvider(SQLiteStorageProvider(path: path))
        let stored = try await reader.loadPersistedJwt(appId: appId, namespace: "default")
        await reader.closeStorage()
        return stored
    }

    /// An explicit SQLite file keeps one session row whatever the app id. A
    /// home session persisted there before the override is not restored into
    /// the target client, and a target session does not overwrite it.
    func testAHomeSessionStoredInAnExplicitFileIsNotRestoredIntoTheTarget() async throws {
        let targetWorld = try AppVersionWorld()
        defer { targetWorld.stop() }
        let homeWorld = try world(Self.overridePolicy(apiUrl: targetWorld.apiUrl))
        let store = store()
        let homeToken = makeTestJwt(userId: "home-user")
        let options = homeWorld.options(storage: store.storage, token: homeToken, persistSession: true)

        let home = JsBaoClient(options: options)
        await home.waitForStorageReady(timeout: 5)
        try await eventually(description: "the home session is stored") {
            (try? await self.persistedSession(at: store.databasePath, appId: homeWorld.appId))?.token == homeToken
        }
        await home.destroy()

        let answer = await resolve(options)
        XCTAssertEqual(answer.appId, "target-b")
        let client = JsBaoClient(options: answer.applied(to: options))
        clients.append(client)
        await client.waitForStorageReady(timeout: 5)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        try? await client.connect()
        try await delay(0.5)
        XCTAssertNotEqual(client.auth.token, homeToken, "the home session is not restored into the target")
        XCTAssertGreaterThan(targetWorld.api.requests.count, 0)
        XCTAssertFalse(targetWorld.api.requests.contains { $0.header("Authorization")?.contains(homeToken) == true })

        let targetToken = makeTestJwt(userId: "target-user")
        client.updateToken(targetToken)
        try await eventually(description: "the target session is stored in its own file") {
            (try? await self.persistedSession(at: store.databasePath + ".target-b.sqlite", appId: "target-b"))?.token == targetToken
        }
        await client.destroy()
        clients.removeAll()
        let homeSession = try await persistedSession(at: store.databasePath, appId: homeWorld.appId)
        XCTAssertEqual(homeSession?.token, homeToken, "the target session does not overwrite the home one")
    }

    /// Two target app ids that differ only in letter case get two files on an
    /// explicit path, so a session stored for one is never restored into a
    /// client of the other, and neither overwrites the other (CSO-6185-006).
    func testTargetAppIdsThatDifferOnlyInLetterCaseNeverShareASession() async throws {
        let lowerWorld = try AppVersionWorld()
        defer { lowerWorld.stop() }
        let upperWorld = try AppVersionWorld()
        defer { upperWorld.stop() }
        let store = store()
        let options = JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "home-app", offline: false, logLevel: .none,
            storageConfig: store.storage, auth: AuthConfig(persistJwtInStorage: true), autoNetwork: false,
            appVersion: "2.0", platform: "ios"
        )
        func answer(_ appId: String, _ world: AppVersionWorld) -> ResolvedBackend {
            ResolvedBackend(appId: appId, apiUrl: world.apiUrl, wsUrl: world.wsUrl, overridden: true, source: .fresh)
        }
        let lower = answer("target-b", lowerWorld).applied(to: options)
        let upper = answer("TARGET-B", upperWorld).applied(to: options)
        guard case .sqlite(let lowerPath?) = lower.storageConfig, case .sqlite(let upperPath?) = upper.storageConfig else {
            return XCTFail("an explicit path gives each target a file")
        }
        XCTAssertNotEqual(lowerPath.lowercased(), upperPath.lowercased())

        let lowerToken = makeTestJwt(userId: "lower-user")
        let seeding = JsBaoClient(options: lower)
        await seeding.waitForStorageReady(timeout: 5)
        seeding.updateToken(lowerToken)
        try await eventually(description: "the target-b session is stored") {
            (try? await self.persistedSession(at: lowerPath, appId: "target-b"))?.token == lowerToken
        }
        await seeding.destroy()

        let client = JsBaoClient(options: upper)
        clients.append(client)
        await client.waitForStorageReady(timeout: 5)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        try await delay(0.3)
        XCTAssertNotEqual(client.auth.token, lowerToken, "the target-b session is not restored into TARGET-B")
        XCTAssertGreaterThan(upperWorld.api.requests.count, 0)
        XCTAssertFalse(upperWorld.api.requests.contains { $0.header("Authorization")?.contains(lowerToken) == true })
        let upperToken = makeTestJwt(userId: "upper-user")
        client.updateToken(upperToken)
        try await eventually(description: "the TARGET-B session is stored in its own file") {
            (try? await self.persistedSession(at: upperPath, appId: "TARGET-B"))?.token == upperToken
        }
        await client.destroy()
        clients.removeAll()
        let kept = try await persistedSession(at: lowerPath, appId: "target-b")
        XCTAssertEqual(kept?.token, lowerToken, "the TARGET-B session does not overwrite target-b's")
    }

    /// The default `.sqlite()` file is one per app id by its path, so a target
    /// app id that names the home app's directory another way (a `.` or `..`
    /// segment, a slash, other letter case on a case-insensitive volume) gets
    /// a file of its own beside the home app's instead (CSO-6185-003).
    func testATargetAppIdThatAliasesTheHomeDefaultFileGetsAFileOfItsOwn() throws {
        let homePath = SQLiteStorageProvider.defaultDatabasePath(appId: "home-app")
        func storage(_ appId: String) -> StorageConfig {
            ResolvedBackend(appId: appId, apiUrl: "https://b.example.com", wsUrl: "wss://b.example.com", overridden: true, source: .fresh)
                .applied(to: JsBaoClientOptions(apiUrl: "https://home.example.com", wsUrl: "wss://home.example.com", appId: "home-app", storageConfig: .sqlite()))
                .storageConfig
        }
        guard case .sqlite(nil) = storage("target-b_2") else { return XCTFail("a plain other app id keeps its own default file") }
        for alias in ["./home-app", "../JsBaoClient/home-app", "home-app/", "HOME-APP", "home-app/."] {
            guard case .sqlite(let path?) = storage(alias) else { XCTFail("\(alias) keeps the default file"); continue }
            XCTAssertTrue(path.hasPrefix(homePath + "."), "\(alias): \(path)")
            XCTAssertTrue(path.hasSuffix(".sqlite"), "\(alias): \(path)")
            XCTAssertNotEqual(
                (path as NSString).standardizingPath.lowercased(), (homePath as NSString).standardizingPath.lowercased(), alias
            )
            XCTAssertFalse(path.dropFirst(homePath.count).contains("/"), "\(alias): \(path)")
        }
    }

    func testAHomeSessionInTheDefaultFileIsNotRestoredIntoATargetAppIdThatAliasesIt() async throws {
        let targetWorld = try AppVersionWorld()
        defer { targetWorld.stop() }
        let homeWorld = try world()
        let homeDir = (SQLiteStorageProvider.defaultDatabasePath(appId: homeWorld.appId) as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: homeDir) }
        homeWorld.setPolicy(Self.overridePolicy("./\(homeWorld.appId)", apiUrl: targetWorld.apiUrl))
        let homeToken = makeTestJwt(userId: "home-user")
        let options = homeWorld.options(storage: .sqlite(), token: homeToken, persistSession: true)

        let home = JsBaoClient(options: options)
        await home.waitForStorageReady(timeout: 5)
        try await eventually(description: "the home session is stored") {
            (try? await self.persistedSession(
                at: SQLiteStorageProvider.defaultDatabasePath(appId: homeWorld.appId), appId: homeWorld.appId
            ))?.token == homeToken
        }
        await home.destroy()

        let answer = await resolve(options)
        XCTAssertEqual(answer.appId, "./\(homeWorld.appId)")
        XCTAssertTrue(answer.overridden)
        let client = JsBaoClient(options: answer.applied(to: options))
        clients.append(client)
        await client.waitForStorageReady(timeout: 5)
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        try? await client.connect()
        try await delay(0.5)
        XCTAssertNotEqual(client.auth.token, homeToken, "the home session is not restored into the target")
        XCTAssertGreaterThan(targetWorld.api.requests.count, 0)
        XCTAssertFalse(targetWorld.api.requests.contains { $0.header("Authorization")?.contains(homeToken) == true })
    }

    // MARK: - The answered apiUrl reaches the client

    /// `applied(to:)` builds the client with the answer's `apiUrl` string as
    /// answered, for an override with an `apiUrl` and without one.
    func testAppliedPassesTheAnsweredApiUrlAsItIs() {
        let options = JsBaoClientOptions(apiUrl: "https://home.example.com/", wsUrl: "wss://home.example.com", appId: "home-app")
        for apiUrl in ["https://b.example.com/api", "https://b.example.com:443/x", "http://127.1:9", "https://home.example.com/"] {
            let answer = ResolvedBackend(appId: "target-b", apiUrl: apiUrl, wsUrl: "wss://b.example.com", overridden: true, source: .fresh)
            XCTAssertEqual(answer.applied(to: options).apiUrl, apiUrl, apiUrl)
        }
    }

    // MARK: - A skipped apiUrl

    func testAnApiUrlTheRuleDoesNotUseFallsBackAndSaysWhyAtDebug() async throws {
        let capture = ResolverLogCapture()
        self.capture = capture
        let policy = #"{"clients":{"ios":{"backendOverrides":[{"from":"1.0","appId":"target-a"},{"from":"2.0","appId":"target-b","apiUrl":"http://b.example.com/"}]}}}"#
        let world = try world(policy)
        let answer = await resolve(world.options(logLevel: .debug))
        XCTAssertEqual(answer, target(world, .fresh, appId: "target-a"))
        let skipped = capture.debugLines.filter { $0.contains("entry 2") }
        XCTAssertEqual(skipped.count, 1, "\(capture.debugLines)")
        XCTAssertTrue(skipped.first?.contains("apiUrl") == true, "\(skipped)")

        let alone = try self.world(#"{"clients":{"ios":{"backendOverrides":[{"from":"2.0","appId":"target-b","apiUrl":"http://b.example.com/"}]}}}"#)
        let home = await resolve(alone.options(logLevel: .debug))
        XCTAssertEqual(home, build(alone, .fresh))
    }
}

/// Take the resolver's record lock on another thread, return once it is
/// held, and let it go after `seconds`.
private func holdRecordLock(for seconds: TimeInterval) async {
    await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            BackendResolver.fileLock.lock()
            held.resume()
            Thread.sleep(forTimeInterval: seconds)
            BackendResolver.fileLock.unlock()
        }
    }
}

/// One resolver call with no bundle version, callable from a child task.
private func resolveForTest(
    _ options: JsBaoClientOptions,
    timeout: TimeInterval = 5,
    bundleVersion: @escaping @Sendable () -> Any? = { nil }
) async -> ResolvedBackend {
    await BackendResolver.resolve(options: options, timeout: timeout, bundleVersion: bundleVersion)
}
