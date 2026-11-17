import XCTest
@testable import JsBaoClient

/// #5365 behaviour 29a — `client.db3.commitCreate`, the db3 successor of the
/// deprecated `commitOfflineCreate(documentId:onExists:)`, as JS
/// `client.db3.commitCreate` is.
///
/// It commits a db3's pending create now and answers the server's verdict:
/// a refused create is tried again (the refusal is cleared first), and a
/// refusal that holds is answered, not thrown. A db3 with no pending create
/// here (committed already, or unknown) answers `not_pending` with nothing
/// sent. The deprecated member runs the same internal implementation. Called
/// right after a restart, before storage setup has restored a create stored in
/// an earlier session, it waits for it and commits that create (5365-F4).
final class Db3CommitCreateHermeticTests: XCTestCase {

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

    private typealias Answer = @Sendable (JSONValue) throws -> Db3Info

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _posts = 0
        private var _failed = 0
        private var _created: [String] = []
        func post() { lock.withLock { _posts += 1 } }
        func failed() { lock.withLock { _failed += 1 } }
        func created(_ id: String) { lock.withLock { _created.append(id) } }
        var posts: Int { lock.withLock { _posts } }
        var failures: Int { lock.withLock { _failed } }
        var createdIds: [String] { lock.withLock { _created } }
    }

    private static func row(_ body: JSONValue) -> Db3Info {
        Db3Info(
            id: body["id"]?.stringValue ?? "", title: body["title"]?.stringValue ?? "", createdBy: "user-a",
            createdAt: "2026-11-13T00:00:00.000Z", modifiedAt: "2026-11-13T00:00:00.000Z", custodian: "user:user-a",
            sync: true, type: nil, tags: [], metadata: nil, permission: nil, accessSource: nil, grantedAt: nil
        )
    }

    private static let ok: Answer = { body in row(body) }
    private static let taken: Answer = { _ in
        throw HttpError(status: 409, message: "taken", serverCode: "DB3_ID_EXISTS", serverMessage: "A document of this app holds this id")
    }

    /// A client signed in as `user-a`, networking stopped, whose `POST db3`
    /// commit answers `answers` in turn (the last one repeats).
    private func offlineClient(answers: [Answer]) async throws -> (JsBaoClient, Heard, [EventSubscription]) {
        let directory = NSTemporaryDirectory() + "/db3-commit-create-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-commit-create-5365",
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
        let heard = Heard()
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no documents commit for a db3")
        }
        let script = LockedBox(answers)
        client.documentManager.createRemoteDb3 = { body in
            heard.post()
            let answer = script.withValue { queue -> Answer in
                let first = queue[0]
                if queue.count > 1 { queue.removeFirst() }
                return first
            }
            return try answer(body)
        }
        let subscriptions = [
            client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { _ in heard.failed() },
            client.eventEmitter.subscribe(Db3CreatedEvent.self) { heard.created($0.id) },
        ]
        return (client, heard, subscriptions)
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

    func testARefusedCreateIsTriedAgainAndAnswersCreated() async throws {
        let (client, heard, subs) = try await offlineClient(answers: [Self.taken, Self.ok])
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "Refused, then committed")
        await client.goOnline()
        try await eventually("the refusal") { heard.failures == 1 }

        let answer = try await client.db3.commitCreate(info.id)

        XCTAssertEqual(answer, Db3CommitResult(created: true, refused: false, reason: nil))
        XCTAssertEqual(heard.posts, 2, "one POST db3 for the retry")
        XCTAssertFalse(client.documentManager.isPendingCreate(info.id))
        let state = try await client.db3.state(info.id)
        XCTAssertFalse(state.pendingCreate)
    }

    func testARefusalThatHoldsIsAnsweredNotThrown() async throws {
        let (client, heard, subs) = try await offlineClient(answers: [Self.taken])
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "Refused twice")
        await client.goOnline()
        try await eventually("the refusal") { heard.failures == 1 }

        let answer = try await client.db3.commitCreate(info.id)

        XCTAssertFalse(answer.created)
        XCTAssertTrue(answer.refused)
        XCTAssertEqual(answer.reason, "A document of this app holds this id")
        XCTAssertEqual(heard.posts, 2)
        XCTAssertTrue(client.documentManager.isPendingCreate(info.id), "a refused create stays pending")
    }

    func testACommittedOrUnknownDb3AnswersNotPendingWithNothingSent() async throws {
        let (client, heard, subs) = try await offlineClient(answers: [Self.ok])
        defer { subs.forEach { $0.cancel() } }
        let landed = try await client.db3.create(title: "Landed")
        await client.goOnline()
        try await eventually("the commit") { heard.createdIds == [landed.id] }

        let committed = try await client.db3.commitCreate(landed.id)
        let unknown = try await client.db3.commitCreate("01JD5365UNKNWN0000000000XX")

        let notPending = Db3CommitResult(created: false, refused: false, reason: "not_pending")
        XCTAssertEqual(committed, notPending)
        XCTAssertEqual(unknown, notPending)
        XCTAssertEqual(heard.posts, 1, "nothing sent for either")
    }

    @available(*, deprecated, message: "calls the deprecated commitOfflineCreate(documentId:onExists:)")
    func testTheDeprecatedMemberGivesTheSameAnswer() async throws {
        let (client, heard, subs) = try await offlineClient(answers: [Self.taken])
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "Refused")
        await client.goOnline()
        try await eventually("the refusal") { heard.failures == 1 }

        let viaDb3 = try await client.db3.commitCreate(info.id)
        let viaClient = try await client.commitOfflineCreate(documentId: info.id)

        XCTAssertTrue(viaDb3.refused)
        XCTAssertEqual(viaClient["refused"] as? Bool, true)
        XCTAssertEqual(viaClient["reason"] as? String, viaDb3.reason)
        let source = try ClientSourceText.code("JsBaoClient.swift")
        XCTAssertNotNil(source.range(of: #"func commitPendingCreateNow\("#, options: .regularExpression))
    }

    // MARK: - 5365-F4: right after a restart

    func testRightAfterARestartItCommitsACreateStoredInAnEarlierSession() async throws {
        let appId = "db3-commit-create-5365"
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
        let heard = Heard()
        client.documentManager.createRemoteDb3 = { body in
            heard.post()
            return Self.row(body)
        }
        try await eventually("storage setup to reach the bind") { hold.reached }

        // Called while storage setup has not restored the stored create yet.
        let committing = Task { try await client.db3.commitCreate(db3Id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        hold.release()
        let answer = try await committing.value

        XCTAssertNotEqual(answer.reason, "not_pending", "a stored create is pending right after a restart")
        XCTAssertEqual(answer, Db3CommitResult(created: true, refused: false, reason: nil))
        XCTAssertEqual(heard.posts, 1, "one POST db3")
        XCTAssertFalse(client.documentManager.isPendingCreate(db3Id))
    }
}
