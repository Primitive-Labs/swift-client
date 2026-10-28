import XCTest
@testable import JsBaoClient

/// #4921 behaviors 34, 36 and 38, edge case E14 — `client.db3.create` with
/// networking stopped, and its commit through `POST db3`, with no server.
///
/// A create of the caller's own synced db3 with no custodian mints its id
/// here. With networking stopped it returns at once: the db3 is bound as
/// created here, saves and queries work, and `state.pendingCreate` is true.
/// Back online it commits through the `createRemoteDb3` hook (never the
/// documents hook) with `{ title, id }`; a 201 or 200 settles it once with
/// `Db3CreatedEvent`. `DB3_CREATE_IN_PROGRESS` and a 503 are retried by the
/// backoff; `DB3_ID_EXISTS` leaves it pending with one `Db3CreateFailedEvent`,
/// skipped by the next reconnect, and `commitOfflineCreate(documentId:)`
/// tries again as a backoff round. A commit or an online create answered
/// after another user signed in leaves nothing for that user, and an empty
/// `type` is sent at commit (second opinion 4921-SO-002, -005, -007).
final class Db3OfflineCreateHermeticTests: XCTestCase {

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

    private static let ulidShape = try! NSRegularExpression(pattern: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$")

    private static func isUlid(_ id: String) -> Bool {
        ulidShape.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    /// What the commit hooks were asked: each body sent to `POST db3`, and how many documents commits.
    private final class Commits: @unchecked Sendable {
        private let lock = NSLock()
        private var _db3: [[String: JSONValue]] = []
        private var _documents = 0
        func db3(_ body: JSONValue) { lock.withLock { _db3.append(body.objectValue ?? [:]) } }
        func document() { lock.withLock { _documents += 1 } }
        var db3Bodies: [[String: JSONValue]] { lock.withLock { _db3 } }
        var documents: Int { lock.withLock { _documents } }
    }

    private typealias Answer = @Sendable (JSONValue) throws -> Db3Info

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _created: [Db3CreatedEvent] = []
        private var _failed: [Db3CreateFailedEvent] = []
        func created(_ event: Db3CreatedEvent) { lock.withLock { _created.append(event) } }
        func failed(_ event: Db3CreateFailedEvent) { lock.withLock { _failed.append(event) } }
        var createdEvents: [Db3CreatedEvent] { lock.withLock { _created } }
        var failedEvents: [Db3CreateFailedEvent] { lock.withLock { _failed } }
    }

    /// A client signed in as `user-a`, networking stopped, whose `POST db3`
    /// commit answers `answers` in turn (the last one repeats).
    private func offlineClient(
        answers: [Answer] = []
    ) async throws -> (JsBaoClient, Commits, Heard, [EventSubscription]) {
        let directory = NSTemporaryDirectory() + "/db3-offline-create-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-offline-create-4921",
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
        let script = LockedBox(answers)
        client.documentManager.createRemoteDb3 = { body in
            commits.db3(body)
            let answer = script.withValue { queue -> Answer? in
                guard let first = queue.first else { return nil }
                if queue.count > 1 { queue.removeFirst() }
                return first
            }
            guard let answer else { return Self.row(body) }
            return try answer(body)
        }
        let heard = Heard()
        let subscriptions = [
            client.eventEmitter.subscribe(Db3CreatedEvent.self) { heard.created($0) },
            client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { heard.failed($0) },
        ]
        return (client, commits, heard, subscriptions)
    }

    /// The db3 the server answers for a commit `body`.
    private static func row(_ body: JSONValue) -> Db3Info {
        Db3Info(
            id: body["id"]?.stringValue ?? "", title: body["title"]?.stringValue ?? "", createdBy: "user-a",
            createdAt: "2026-10-28T00:00:00.000Z", modifiedAt: "2026-10-28T00:00:00.000Z", custodian: "user:user-a",
            sync: true, type: nil, tags: [], metadata: nil, permission: nil, accessSource: nil, grantedAt: nil
        )
    }

    private static let taken: Answer = { _ in
        throw HttpError(status: 409, message: "taken", serverCode: "DB3_ID_EXISTS", serverMessage: "A document of this app holds this id")
    }

    // MARK: - Behavior 34

    func testACreateWithNetworkingStoppedIsUsableAtOnceAndPending() async throws {
        let (client, commits, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client).create(title: "Made offline")
        XCTAssertTrue(Self.isUlid(info.id), info.id)
        XCTAssertEqual(info.title, "Made offline")
        XCTAssertEqual(info.custodian, "user:user-a")
        XCTAssertEqual(info.createdBy, "user-a")
        XCTAssertTrue(info.sync)
        XCTAssertNil(info.type)
        XCTAssertEqual(transport.calls.count, 0, "no request with networking stopped")

        let binding = try XCTUnwrap(client.recordLogBinding(info.id))
        XCTAssertTrue(binding.createdLocally)
        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: info.id))
        _ = try notes.save(id: "n1", values: ["title": .string("offline")])
        XCTAssertEqual(try notes.query().compactMap { $0["id"]?.stringValue }, ["n1"])
        let state = try await client.db3.state(info.id)
        XCTAssertTrue(state.pendingCreate)
        XCTAssertTrue(state.resident)
        XCTAssertTrue(client.listPendingCreates().contains(info.id))
        XCTAssertEqual(client.documentManager.getLocalMetadata(info.id)?.db3Create, true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(commits.db3Bodies.isEmpty)
        XCTAssertTrue(heard.createdEvents.isEmpty)
    }

    // MARK: - Behavior 36

    func testReconnectingCommitsThroughPostDb3AndSettlesOnce() async throws {
        for status in [201, 200] {
            let (client, commits, heard, subs) = try await offlineClient()
            defer { subs.forEach { $0.cancel() } }
            let info = try await client.db3.create(title: "Orders \(status)")
            await client.goOnline()
            try await eventually(description: "Db3CreatedEvent (\(status))") { heard.createdEvents.count == 1 }
            XCTAssertEqual(heard.createdEvents.map(\.id), [info.id])
            XCTAssertEqual(commits.db3Bodies.count, 1)
            XCTAssertEqual(commits.db3Bodies.first?["id"]?.stringValue, info.id)
            XCTAssertEqual(commits.db3Bodies.first?["title"]?.stringValue, "Orders \(status)")
            XCTAssertEqual(Set(commits.db3Bodies.first?.keys.map { $0 } ?? []), ["id", "title"])
            XCTAssertEqual(commits.documents, 0)
            XCTAssertFalse(client.documentManager.isPendingCreate(info.id))
            try await eventually(description: "pendingCreate false") { try await !client.db3.state(info.id).pendingCreate }
            let marks = try XCTUnwrap(client.recordLogBinding(info.id)).refreshMarks()
            XCTAssertNotNil(marks.lastCatchUpAt, "the catch-up mark is written")
        }
    }

    func testARetryableFirstAnswerIsRetriedByTheBackoffWithoutAnotherTransition() async throws {
        let inProgress: Answer = { _ in
            throw HttpError(status: 409, message: "busy", serverCode: "DB3_CREATE_IN_PROGRESS")
        }
        let unavailable: Answer = { _ in
            throw HttpError(status: 503, message: "unavailable")
        }
        for first in [inProgress, unavailable] {
            let ok: Answer = { body in Self.row(body) }
            let (client, commits, heard, subs) = try await offlineClient(answers: [first, ok])
            defer { subs.forEach { $0.cancel() } }
            let info = try await client.db3.create(title: "Retried")
            await client.goOnline()
            try await eventually(description: "Db3CreatedEvent after a retry") { heard.createdEvents.count == 1 }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(heard.createdEvents.map(\.id), [info.id])
            XCTAssertEqual(commits.db3Bodies.count, 2)
            XCTAssertTrue(heard.failedEvents.isEmpty)
        }
    }

    func testATakenIdStaysPendingReportsOnceAndRetriesOnlyWhenAsked() async throws {
        let (client, commits, heard, subs) = try await offlineClient(answers: [Self.taken])
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "Taken", type: nil)
        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: info.id))
        _ = try notes.save(id: "n1", values: ["title": .string("kept")])
        await client.goOnline()
        try await eventually(description: "Db3CreateFailedEvent") { heard.failedEvents.count == 1 }
        let failed = try XCTUnwrap(heard.failedEvents.first)
        XCTAssertEqual(failed.code, "DB3_ID_EXISTS")
        XCTAssertEqual(failed.id, info.id)
        XCTAssertEqual(failed.title, "Taken")
        XCTAssertNil(failed.type)
        XCTAssertTrue(client.documentManager.isPendingCreate(info.id))
        XCTAssertEqual(client.documentManager.getLocalMetadata(info.id)?.commitRefused, true)
        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("kept"))
        try await eventually(description: "the refusal in the state") {
            try await client.db3.state(info.id).error?.code == "DB3_ID_EXISTS"
        }

        await client.goOffline()
        await client.goOnline()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(commits.db3Bodies.count, 1, "a reconnect does not repeat a refused commit")
        XCTAssertEqual(heard.failedEvents.count, 1)

        _ = try? await client.commitOfflineCreate(documentId: info.id)
        try await eventually(description: "the explicit retry") { commits.db3Bodies.count == 2 }
        XCTAssertTrue(heard.createdEvents.isEmpty)
    }

    /// 4921-SO-005: an explicit retry after a refusal is a backoff round, so a
    /// transient failure on it is retried without another call or reconnect.
    func testAnExplicitRetryAfterARefusalIsRetriedByTheBackoff() async throws {
        let unavailable: Answer = { _ in throw HttpError(status: 503, message: "unavailable") }
        let ok: Answer = { body in Self.row(body) }
        let (client, commits, heard, subs) = try await offlineClient(answers: [Self.taken, unavailable, ok])
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "Refused then retried")
        await client.goOnline()
        try await eventually(description: "Db3CreateFailedEvent") { heard.failedEvents.count == 1 }

        let answer = try await client.commitOfflineCreate(documentId: info.id)
        XCTAssertEqual(answer["scheduled"] as? Bool, true)
        try await eventually(description: "Db3CreatedEvent after the backoff") { heard.createdEvents.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commits.db3Bodies.count, 3)
        XCTAssertEqual(heard.createdEvents.map(\.id), [info.id])
        XCTAssertEqual(heard.failedEvents.count, 1)
        XCTAssertFalse(client.documentManager.isPendingCreate(info.id))
        XCTAssertNil(client.documentManager.getLocalMetadata(info.id)?.commitRefused)
    }

    /// 4921-SO-007: an empty type is sent at commit as the online create sends it.
    func testAnEmptyTypeIsSentAtCommit() async throws {
        let (client, commits, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        _ = try await client.db3.create(title: "Empty type", type: "")
        await client.goOnline()
        try await eventually(description: "the commit") { commits.db3Bodies.count == 1 }
        XCTAssertEqual(commits.db3Bodies.first?["type"], .string(""))
        _ = heard
    }

    // MARK: - 4921-SO-002

    func testACommitAnsweredAfterAnotherUsersSignInIsNotAdopted() async throws {
        let (client, commits, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "User A's")
        client.documentManager.createRemoteDb3 = { body in
            commits.db3(body)
            client.updateToken(makeTestJwt(userId: "user-b"))
            await client.rebindUserScopedStorage()
            return Self.row(body)
        }
        await client.goOnline()
        try await eventually(description: "the commit") { commits.db3Bodies.count == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(heard.createdEvents.isEmpty, "user-a's db3 is not announced to user-b")
        let row = client.documentManager.getLocalMetadata(info.id)
        XCTAssertNotEqual(row?.pendingCreate, false, "nor settled for user-b")
        XCTAssertNil(row?.createCommittedAt)
        XCTAssertNil(client.recordLogBinding(info.id), "nor bound for user-b")
    }

    func testAnOnlineCreateFailingAfterAnotherUsersSignInKeepsNothing() async throws {
        for switched in [false, true] {
            let (client, _, heard, subs) = try await offlineClient()
            defer { subs.forEach { $0.cancel() } }
            await client.goOnline()
            let transport = RecordingTransport(responder: { _ in
                if switched {
                    client.updateToken(makeTestJwt(userId: "user-b"))
                    await client.rebindUserScopedStorage()
                }
                return TransportResponse(status: 503, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
            })
            let api = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
            if !switched {
                let info = try await api.create(title: "Kept")
                XCTAssertTrue(client.listPendingCreates().contains(info.id))
                continue
            }
            do {
                _ = try await api.create(title: "Not kept")
                XCTFail("the create rejects once another user signed in")
            } catch {}
            XCTAssertEqual(heard.failedEvents.count, 1)
            XCTAssertNotNil(heard.failedEvents.first?.id)
            XCTAssertTrue(client.listPendingCreates().isEmpty)
            if let id = heard.failedEvents.first?.id {
                XCTAssertNil(client.documentManager.getLocalMetadata(id))
            }
        }
    }

    // MARK: - Edge case E14

    func testAnotherUsersSignInNeitherCommitsNorListsThePreviousUsersCreate() async throws {
        let (client, commits, _, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await client.db3.create(title: "User A's")
        client.updateToken(makeTestJwt(userId: "user-b"))
        await client.rebindUserScopedStorage()
        XCTAssertFalse(client.listPendingCreates().contains(info.id))
        await client.goOnline()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(commits.db3Bodies.isEmpty, "nothing committed under user-b's token")
    }

    // MARK: - Behavior 38

    func testTheEventsTheStateAndTheMetadataRowAreAdditive() throws {
        XCTAssertEqual(JsBaoEvent.db3Created.rawValue, "db3:created")
        XCTAssertEqual(JsBaoEvent.db3CreateFailed.rawValue, "db3:create-failed")
        XCTAssertEqual(Db3CreatedEvent.eventKey, .db3Created)
        XCTAssertEqual(Db3CreateFailedEvent.eventKey, .db3CreateFailed)
        let listed = allJsBaoEventPayloadTypes.map { String(describing: $0) }
        XCTAssertTrue(listed.contains("Db3CreatedEvent"))
        XCTAssertTrue(listed.contains("Db3CreateFailedEvent"))

        // The memberwise init as it was still compiles; pendingCreate defaults to false.
        let state = Db3State(
            id: "d", resident: false, subscribed: false, phase: .idle, progress: nil, cursor: 0, rows: 0,
            lastSyncAt: nil, pendingWrites: 0, permission: nil, error: nil
        )
        XCTAssertFalse(state.pendingCreate)

        let stored = #"{"documentId":"d","title":"Old row","pendingCreate":true,"commitError":{"message":"x","at":"2026-01-01T00:00:00Z"}}"#
        let entry = try JSONDecoder().decode(LocalMetadataEntry.self, from: Data(stored.utf8))
        XCTAssertNil(entry.db3Create)
        XCTAssertNil(entry.db3Type)
        XCTAssertNil(entry.commitRefused)
        XCTAssertNil(entry.commitError?.code)
    }
}
