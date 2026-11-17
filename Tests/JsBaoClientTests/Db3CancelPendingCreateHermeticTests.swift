import XCTest
@testable import JsBaoClient

/// #5365 behaviours 29 and 29a, edge case E15 — `client.db3.cancelPendingCreate`,
/// the db3 successor of the deprecated `cancelPendingCreate(_:evictLocal:)`.
///
/// It is local: on a db3 whose create is still pending, with no connection,
/// it sends nothing, the db3 is no longer pending, and no create attempt
/// follows, not even after the client goes back online. The deprecated member
/// runs the same internal implementation and gives the same result. On a db3
/// with no pending create (already committed, or unknown) it sends nothing
/// and leaves the db3 as it is. Called right after a restart, before storage
/// setup has restored a create stored in an earlier session, it waits for it
/// and cancels that create (5365-F4).
final class Db3CancelPendingCreateHermeticTests: XCTestCase {

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    /// Every create the commit hooks were asked for.
    private final class Commits: @unchecked Sendable {
        private let lock = NSLock()
        private var _db3: [String] = []
        private var _documents = 0
        func db3(_ id: String) { lock.withLock { _db3.append(id) } }
        func document() { lock.withLock { _documents += 1 } }
        var db3Ids: [String] { lock.withLock { _db3 } }
        var documents: Int { lock.withLock { _documents } }
    }

    /// A client signed in as `user-a`, networking stopped, whose `POST db3`
    /// commit answers the db3 the server would create.
    private func offlineClient() async throws -> (JsBaoClient, Commits) {
        let directory = NSTemporaryDirectory() + "/db3-cancel-create-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-cancel-create-5365",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels([Self.note])
        client.documentManager.commitRetryBackoff = CommitRetryBackoff(base: 0.02, factor: 2, max: 0.1, jitter: false, maxAttempts: 5)
        let commits = Commits()
        client.documentManager.createRemoteDocument = { _ in
            commits.document()
            throw JsBaoError(code: .unavailable, message: "no documents commit for a db3")
        }
        client.documentManager.createRemoteDb3 = { body in
            let id = body["id"]?.stringValue ?? ""
            commits.db3(id)
            return Db3Info(
                id: id, title: body["title"]?.stringValue ?? "", createdBy: "user-a",
                createdAt: "2026-11-13T00:00:00.000Z", modifiedAt: "2026-11-13T00:00:00.000Z", custodian: "user:user-a",
                sync: true, type: nil, tags: [], metadata: nil, permission: nil, accessSource: nil, grantedAt: nil
            )
        }
        return (client, commits)
    }

    /// A `client.db3` whose own requests are recorded, over `client`.
    private func api(_ client: JsBaoClient, _ transport: RecordingTransport) -> Db3API {
        Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
    }

    private func eventually(_ what: String, timeout: TimeInterval = 3, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Holds a client's storage setup after the provider is attached and
    /// before the user is bound, and says when setup has got there.
    private final class StorageHold: @unchecked Sendable {
        private let lock = NSLock()
        private var _reached = false
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream() }

        var reached: Bool { lock.withLock { _reached } }

        func wait() async {
            lock.withLock { _reached = true }
            for await _ in stream {}
        }

        func release() { continuation.finish() }
    }

    /// The options of a client signed in as `user-a` over `path`.
    private static func options(_ appId: String, path: String) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            autoNetwork: false
        )
    }

    /// A db3 created offline by a first session over a new store, whose
    /// pending create is stored when that session ends: the store's path and
    /// the db3's id.
    private func storedPendingCreate(_ appId: String) async throws -> (path: String, db3Id: String) {
        let directory = NSTemporaryDirectory() + "/\(appId)-restart-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let path = directory + "/store.sqlite"
        let first = JsBaoClient(options: Self.options(appId, path: path))
        _ = await first.waitForStorageReady()
        await first.goOffline()
        first.registerModels([Self.note])
        let draft = try await first.db3.create(title: "Stored in an earlier session")
        XCTAssertTrue(first.documentManager.isPendingCreate(draft.id))
        try await eventually("the pending create to be stored") {
            let row = try await first.offlineStore.readMetadata(appId: appId, userId: "user-a", documentId: draft.id)
            return row.entry?.pendingCreate == true
        }
        await first.destroy()
        return (path, draft.id)
    }

    // MARK: - Behaviour 29

    func testOfflineItSendsNothingLeavesNothingPendingAndNoCreateFollows() async throws {
        let (client, commits) = try await offlineClient()
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = api(client, transport)
        let draft = try await db3.create(title: "Draft")
        let before = try await client.db3.state(draft.id)
        XCTAssertTrue(before.pendingCreate, "the create is pending with networking stopped")

        await db3.cancelPendingCreate(draft.id)

        XCTAssertTrue(transport.calls.isEmpty, "no request: \(transport.calls.map(\.path))")
        XCTAssertFalse(client.documentManager.isPendingCreate(draft.id))
        XCTAssertFalse(client.documentManager.listPendingCreates().contains(draft.id))
        XCTAssertNotEqual(client.documentManager.getLocalMetadata(draft.id)?.pendingCreate, true)

        await client.goOnline()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(commits.db3Ids, [], "no create attempt after reconnecting")
        XCTAssertEqual(commits.documents, 0)
        XCTAssertTrue(transport.calls.isEmpty)
    }

    /// States a subscription heard, in order.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [Db3State] = []
        func add(_ state: Db3State) { lock.withLock { _states.append(state) } }
        var states: [Db3State] { lock.withLock { _states } }
    }

    func testAnOpenSubscriptionHearsTheCreateIsNoLongerPending() async throws {
        let (client, _) = try await offlineClient()
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = api(client, transport)
        let draft = try await db3.create(title: "Subscribed draft")
        let subscription = try db3.subscribe(draft.id)
        defer { subscription.dispose() }
        try await eventually("the subscription to read the pending create") { subscription.state.pendingCreate }
        // Let the subscribe settle, so no read it started is still running.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(subscription.state.pendingCreate)
        let heard = Heard()
        let observation = subscription.observe { event in
            if case .state(let state) = event { heard.add(state) }
        }
        defer { observation.cancel() }

        await db3.cancelPendingCreate(draft.id)

        try await eventually("the subscription's state to drop pendingCreate") { !subscription.state.pendingCreate }
        try await eventually("a state event without pendingCreate") { heard.states.contains { !$0.pendingCreate } }
        XCTAssertTrue(transport.calls.isEmpty, "no request: \(transport.calls.map(\.path))")
    }

    func testEvictLocalAlsoRemovesTheLocalCopy() async throws {
        let (client, commits) = try await offlineClient()
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = api(client, transport)
        let draft = try await db3.create(title: "Draft to drop")
        await db3.cancelPendingCreate(draft.id, evictLocal: true)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertFalse(client.documentManager.isPendingCreate(draft.id))
        XCTAssertFalse(client.documentManager.hasLocalCopy(draft.id))
        await client.goOnline()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(commits.db3Ids, [])
    }

    // MARK: - Behaviour 29a

    @available(*, deprecated, message: "calls the deprecated cancelPendingCreate(_:evictLocal:)")
    func testTheDeprecatedMemberGivesTheSameResult() async throws {
        let (client, commits) = try await offlineClient()
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = api(client, transport)
        let viaDb3 = try await db3.create(title: "Through db3")
        let viaClient = try await db3.create(title: "Through the client")

        await db3.cancelPendingCreate(viaDb3.id)
        await client.cancelPendingCreate(viaClient.id)

        let manager = client.documentManager
        XCTAssertFalse(manager.isPendingCreate(viaDb3.id))
        XCTAssertFalse(manager.isPendingCreate(viaClient.id))
        XCTAssertEqual(manager.getLocalMetadata(viaDb3.id)?.pendingCreate, manager.getLocalMetadata(viaClient.id)?.pendingCreate)
        XCTAssertEqual(manager.hasLocalCopy(viaDb3.id), manager.hasLocalCopy(viaClient.id))
        XCTAssertEqual(manager.listPendingCreates().filter { [viaDb3.id, viaClient.id].contains($0) }, [])
        XCTAssertTrue(transport.calls.isEmpty)
        await client.goOnline()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(commits.db3Ids, [])
    }

    func testBothMembersDelegateToOneInternalImplementation() throws {
        let client = try ClientSourceText.code("JsBaoClient.swift")
        let db3 = try ClientSourceText.code("API/Db3API.swift")
        XCTAssertNotNil(client.range(of: #"func cancelPendingCreateLocally\("#, options: .regularExpression))
        XCTAssertNotNil(
            client.range(of: #"public func cancelPendingCreate\([^{]*\{\s*await cancelPendingCreateLocally\("#, options: .regularExpression),
            "the deprecated member delegates"
        )
        let start = try XCTUnwrap(db3.range(of: "public func cancelPendingCreate("), "the db3 member")
        let rest = db3[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    public ")?.lowerBound ?? rest.endIndex)]
        XCTAssertTrue(body.contains("cancelPendingCreateLocally("), "the db3 member delegates")
    }

    // MARK: - Edge case E15

    func testOnACommittedOrUnknownDb3ItSendsNothingAndLeavesItAsItIs() async throws {
        let (client, commits) = try await offlineClient()
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = api(client, transport)
        let landed = try await db3.create(title: "Landed")
        await client.goOnline()
        try await eventually("the commit") { commits.db3Ids == [landed.id] }
        try await eventually("pendingCreate false") { !client.documentManager.isPendingCreate(landed.id) }
        let metadataBefore = client.documentManager.getLocalMetadata(landed.id)
        XCTAssertNotNil(metadataBefore)

        await db3.cancelPendingCreate(landed.id)
        await db3.cancelPendingCreate("01JD5365UNKNWN0000000000XX")

        XCTAssertTrue(transport.calls.isEmpty, "no request, so no DELETE: \(transport.calls.map(\.path))")
        XCTAssertNotNil(client.documentManager.getLocalMetadata(landed.id), "the committed db3 keeps its row on the device")
        XCTAssertNotNil(client.recordLogBinding(landed.id), "and stays bound")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commits.db3Ids, [landed.id], "nothing is created or deleted again")
    }

    // MARK: - 5365-F4: right after a restart

    func testRightAfterARestartItCancelsACreateStoredInAnEarlierSession() async throws {
        let appId = "db3-cancel-create-5365"
        let (path, db3Id) = try await storedPendingCreate(appId)
        let hold = StorageHold()
        let client = JsBaoClient(
            options: Self.options(appId, path: path),
            connectivityMonitor: nil,
            storageBindHoldForTest: { await hold.wait() }
        )
        clients.append(client)
        defer { hold.release() }
        client.registerModels([Self.note])
        let commits = Commits()
        client.documentManager.createRemoteDb3 = { body in
            commits.db3(body["id"]?.stringValue ?? "")
            throw JsBaoError(code: .unavailable, message: "a cancelled create is never committed")
        }
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = api(client, transport)
        try await eventually("storage setup to reach the bind") { hold.reached }

        // Called while storage setup has not restored the stored create yet.
        let cancelling = Task { await db3.cancelPendingCreate(db3Id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        hold.release()
        await cancelling.value

        XCTAssertTrue(transport.calls.isEmpty, "no request: \(transport.calls.map(\.path))")
        XCTAssertFalse(client.documentManager.isPendingCreate(db3Id), "the stored create is cancelled")
        XCTAssertNotEqual(client.documentManager.getLocalMetadata(db3Id)?.pendingCreate, true)
        await client.goOnline()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(commits.db3Ids, [], "no create attempt after reconnecting")
    }
}
