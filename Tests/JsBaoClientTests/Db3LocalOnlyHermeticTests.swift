import XCTest
@testable import JsBaoClient

/// #5155 behaviours 20 to 26 and 33, edge case E2's Swift half — a db3 that
/// lives only on this device, through the Swift client, with no server.
///
/// `client.db3.create(title:localOnly: true)` answers at once under an id
/// minted here, with nothing sent and neither create hook asked; what only
/// the server can hold (a type, sync off, a custodian) is refused before
/// anything is created. Saves, patches, deletes, increments and transactions
/// are judged and confirmed on the device, the binding holding nothing
/// pending and the sender never handed an entry; a confirmation is released
/// only once the group transaction committed. Unique keys, upserts, guards
/// and increments are judged with the room's codes; rows events and model
/// callbacks fire; a subscription is live at once with no open. The document
/// doors keep refusing format 3 with `localOnly`.
final class Db3LocalOnlyHermeticTests: XCTestCase {

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true), "status": FieldDescriptor(type: .string),
            "views": FieldDescriptor(type: .number), "owner": FieldDescriptor(type: .string), "day": FieldDescriptor(type: .number),
        ],
        constraints: ["owner_day": ConstraintDescriptor(name: "owner_day", fields: ["owner", "day"])]
    )

    private static let ulidShape = try! NSRegularExpression(pattern: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$")

    /// What the create hooks were asked, and the db3 events heard.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _remote = 0
        private var _created: [String] = []
        private var _failed = 0
        private var _refused: [Db3WriteRefusedEvent] = []
        private var _rows: [Db3RowsEvent] = []
        private var _ready: [String] = []
        func remote() { lock.withLock { _remote += 1 } }
        func created(_ id: String) { lock.withLock { _created.append(id) } }
        func failed() { lock.withLock { _failed += 1 } }
        func refused(_ event: Db3WriteRefusedEvent) { lock.withLock { _refused.append(event) } }
        func rows(_ event: Db3RowsEvent) { lock.withLock { _rows.append(event) } }
        func ready(_ id: String) { lock.withLock { _ready.append(id) } }
        var remoteCreates: Int { lock.withLock { _remote } }
        var createdIds: [String] { lock.withLock { _created } }
        var failedCount: Int { lock.withLock { _failed } }
        var refusals: [Db3WriteRefusedEvent] { lock.withLock { _refused } }
        var rowsEvents: [Db3RowsEvent] { lock.withLock { _rows } }
        var readyIds: [String] { lock.withLock { _ready } }
    }

    /// A client signed in as `userId`, networking stopped, whose create hooks
    /// count what they are asked, over `directory`'s store (a new one by
    /// default) or in memory.
    func offlineClient(
        userId: String = "user-a", directory: String? = nil, memory: Bool = false
    ) async throws -> (JsBaoClient, Heard, [EventSubscription]) {
        let directory = directory ?? {
            let made = NSTemporaryDirectory() + "/db3-local-only-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
            directories.append(made)
            return made
        }()
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-local-only-5155",
            token: makeTestJwt(userId: userId),
            logLevel: .none,
            storageConfig: memory ? .memory : .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels([Self.note])
        let heard = Heard()
        client.documentManager.createRemoteDocument = { _ in
            heard.remote()
            throw JsBaoError(code: .unavailable, message: "no documents commit for a local-only db3")
        }
        client.documentManager.createRemoteDb3 = { _ in
            heard.remote()
            throw JsBaoError(code: .unavailable, message: "no db3 commit for a local-only db3")
        }
        let subscriptions = [
            client.eventEmitter.subscribe(Db3CreatedEvent.self) { heard.created($0.id) },
            client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { _ in heard.failed() },
            client.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { heard.refused($0) },
            client.eventEmitter.subscribe(Db3RowsEvent.self) { heard.rows($0) },
            client.eventEmitter.subscribe(Db3ReadyEvent.self) { heard.ready($0.id) },
        ]
        return (client, heard, subscriptions)
    }

    /// A local-only db3 of `client`'s, created through a `Db3API` over `transport`.
    func createLocalOnly(_ client: JsBaoClient, transport: RecordingTransport, title: String = "Mine") async throws -> Db3Info {
        try await Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
            .create(title: title, tags: ["t"], metadata: ["k": "v"], localOnly: true)
    }

    func notes(_ client: JsBaoClient, _ db3Id: String) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: db3Id))
    }

    func eventually(_ description: String, timeout: TimeInterval = 3, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    func thrown(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> JsBaoError? {
        do {
            try await body()
            XCTFail("nothing was thrown", file: file, line: line)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("threw \(error), not a JsBaoError", file: file, line: line)
            return nil
        }
    }

    // MARK: - Behaviour 20

    func testACreateAnswersAtOnceUnderAnIdMintedHereWithNothingSent() async throws {
        let (client, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await createLocalOnly(client, transport: transport)

        XCTAssertTrue(Self.ulidShape.firstMatch(in: info.id, range: NSRange(info.id.startIndex..., in: info.id)) != nil, info.id)
        XCTAssertTrue(info.localOnly)
        XCTAssertFalse(info.sync)
        XCTAssertNil(info.type)
        XCTAssertEqual(info.custodian, "user:user-a")
        XCTAssertEqual(info.createdBy, "user-a")
        XCTAssertEqual(info.title, "Mine")
        XCTAssertEqual(info.tags, ["t"])
        XCTAssertEqual(info.metadata, ["k": "v"])
        try await eventually("Db3CreatedEvent") { heard.createdIds == [info.id] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(heard.createdIds, [info.id], "Db3CreatedEvent fires once")
        XCTAssertEqual(heard.remoteCreates, 0, "neither create hook is asked")
        XCTAssertEqual(transport.calls.count, 0, "no request")

        // Nothing pending: it never commits.
        XCTAssertFalse(client.documentManager.isPendingCreate(info.id))
        XCTAssertFalse(client.listPendingCreates().contains(info.id))
        let commit = try await client.documents.commitOfflineCreate(documentId: info.id)
        XCTAssertFalse(commit.created)
        XCTAssertEqual(commit.reason, "not_pending")
        XCTAssertEqual(heard.remoteCreates, 0)

        let meta = try XCTUnwrap(client.documentManager.getLocalMetadata(info.id))
        XCTAssertEqual(meta.localOnly, true)
        XCTAssertEqual(meta.documentFormat, 3)
        XCTAssertEqual(meta.db3Create, true)
        XCTAssertNotEqual(meta.pendingCreate, true)
        XCTAssertEqual(meta.lastKnownPermission, "owner")

        let state = try await client.db3.state(info.id)
        XCTAssertTrue(state.localOnly)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.pendingCreate)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.pendingWrites, 0)
        XCTAssertNil(state.lastSyncAt)
        XCTAssertEqual(state.permission, .owner)
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored.map(\.id), [info.id])
        XCTAssertEqual(stored.first?.localOnly, true)
    }

    // MARK: - Behaviour 21

    func testWhatOnlyTheServerCanHoldIsRefusedBeforeAnythingIsCreated() async throws {
        let (client, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let transport = RecordingTransport(status: 500, json: "{}")
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let rows = client.documentManager.getMetadataIndex().count
        for attempt in [
            { try await db3.create(title: "Typed", type: "orders", localOnly: true) },
            { try await db3.create(title: "Off", sync: false, localOnly: true) },
            { try await db3.create(title: "App's", custodian: "app", localOnly: true) },
        ] as [() async throws -> Db3Info] {
            let error = await thrown { _ = try await attempt() }
            XCTAssertEqual(error?.code, .localOnlyUnsupportedOption)
        }
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, rows, "no metadata row")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored, [])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(heard.failedCount, 0, "no Db3CreateFailedEvent")
        XCTAssertEqual(heard.createdIds, [])
        XCTAssertEqual(transport.calls.count, 0)
    }

    // MARK: - Edge case E2, the Swift half

    func testAClientThatCannotKeepADb3RefusesTheCreateAndKeepsNothing() async throws {
        let (client, heard, subs) = try await offlineClient(memory: true)
        defer { subs.forEach { $0.cancel() } }
        let transport = RecordingTransport(status: 500, json: "{}")
        let rows = client.documentManager.getMetadataIndex().count
        let error = await thrown { _ = try await self.createLocalOnly(client, transport: transport) }
        XCTAssertEqual(error?.code, .format2StorageUnavailable)
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, rows, "no metadata row")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored, [])
        XCTAssertEqual(heard.createdIds, [])
        XCTAssertEqual(transport.calls.count, 0)
    }

    // MARK: - Behaviour 22

    func testWritesAreConfirmedInTheirCommitInTheStoreAndTheBinding() async throws {
        let (client, _, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        let notes = try notes(client, info.id)
        let binding = try XCTUnwrap(client.recordLogBinding(info.id))
        let handed = LockedBox(0)
        binding.onCommitted { entries in handed.withValue { $0 += entries.count } }

        var cursor = 0
        func confirmedEach(_ step: String, entries: Int = 1) async throws {
            cursor += entries
            let state = try await client.db3.state(info.id)
            XCTAssertEqual(state.pendingWrites, 0, step)
            XCTAssertEqual(state.cursor, cursor, step)
            XCTAssertEqual(binding.marks.pending, 0, step)
            XCTAssertEqual(binding.unacknowledgedSeqs, [Int](), "\(step): the binding holds nothing unacknowledged")
            XCTAssertEqual(binding.unsettledSeqs, [Int](), "\(step): nor anything unsettled")
            XCTAssertEqual(try binding.store.storedState().writers, [], step)
        }
        let saved = try notes.save(id: "n1", values: ["title": .string("one"), "slug": .string("a"), "views": .number(1)])
        XCTAssertEqual(saved.syncState, .confirmed, "confirmed as soon as the save returns")
        try await confirmedEach("save")
        try notes.update(id: "n1", values: ["title": .string("uno")])
        try await confirmedEach("patch")
        _ = try await notes.increment(id: "n1", fields: ["views": 2], options: Db3WriteOptions())
        try await confirmedEach("increment")
        try notes.transact {
            _ = try notes.save(id: "n2", values: ["slug": .string("b"), "views": .number(5)])
            _ = try notes.save(id: "n3", values: ["slug": .string("c"), "views": .number(7)])
        }
        try await confirmedEach("a two-record transaction")
        notes.delete(id: "n3")
        try await confirmedEach("delete")

        XCTAssertEqual(try notes.query().compactMap { $0["id"]?.stringValue }.sorted(), ["n1", "n2"])
        XCTAssertEqual(try notes.count(["views": ["$gte": .number(3)]]), 2)
        let totals = try notes.aggregate(AggregateOptions(operations: [AggregateOperation(type: .sum, field: "views")]))
        XCTAssertEqual(totals.first?["sum_views"]?.numberValue, 8)

        // `confirm: true` resolves with no subscription held.
        _ = try await notes.save(id: "n4", values: ["slug": .string("d")], confirm: true)
        try await confirmedEach("a confirmed save")
        let unsubscribed = try await client.db3.state(info.id)
        XCTAssertFalse(unsubscribed.subscribed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(handed.value, 0, "the sender is never handed an entry")
    }

    func testAConfirmationIsReleasedOnlyOnceItsGroupCommitted() async throws {
        let (client, _, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        let notes = try notes(client, info.id)
        let binding = try XCTUnwrap(client.recordLogBinding(info.id))
        let storage = await client.offlineStore.getStorageProvider()
        let provider = try XCTUnwrap(storage as? SQLiteStorageProvider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        try provider.withConnection { connection in
            try connection.executeScript("PRAGMA foreign_keys=ON")
            try connection.executeScript("CREATE TABLE IF NOT EXISTS commit_parent (id TEXT PRIMARY KEY)")
            try connection.executeScript(
                "CREATE TABLE IF NOT EXISTS commit_child (pid TEXT REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED)"
            )
        }
        // A statement in the open group that only its COMMIT finds wrong.
        try binding.store.save { sql in try sql.exec("INSERT INTO commit_child (pid) VALUES ('missing')") }
        let error = await thrown { _ = try await notes.save(id: "n1", values: ["slug": .string("a")], confirm: true) }
        XCTAssertEqual(error?.code, .unavailable)
        XCTAssertEqual(error?.details?["reason"], "commit-failed")
        XCTAssertNil(notes.find(id: "n1"), "nothing landed")
        XCTAssertEqual(binding.unacknowledgedSeqs, [Int]())
        let failed = try await client.db3.state(info.id)
        XCTAssertEqual(failed.cursor, 0)

        // The next save commits and confirms.
        _ = try await notes.save(id: "n1", values: ["slug": .string("a")], confirm: true)
        XCTAssertEqual(notes.find(id: "n1")?.id, "n1")
        let committed = try await client.db3.state(info.id)
        XCTAssertEqual(committed.cursor, 1)
    }

    // MARK: - Behaviour 23

    func testAUniqueKeyIsJudgedOnTheDeviceAndAnUpsertLandsOnItsHolder() async throws {
        let (client, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        let notes = try notes(client, info.id)
        _ = try notes.save(id: "n1", values: ["slug": .string("a"), "title": .string("first")])

        let error = await thrown { _ = try notes.save(id: "n2", values: ["slug": .string("a")]) }
        XCTAssertEqual(error?.code, .documentConstraintViolated)
        XCTAssertEqual(error?.details?["conflicting"], .object(["model": "Note", "id": "n1"]))
        try await eventually("Db3WriteRefusedEvent") { !heard.refusals.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(heard.refusals.count, 1)
        XCTAssertEqual(heard.refusals.first?.error.code, .documentConstraintViolated)
        XCTAssertEqual(heard.refusals.first?.error.details?["scope"], "local")
        XCTAssertEqual(heard.refusals.first?.conflictingRecord, RecordLogRecordKey(model: "Note", id: "n1"))
        XCTAssertNil(notes.find(id: "n2"), "nothing landed")
        let afterRefusal = try await client.db3.state(info.id)
        XCTAssertEqual(afterRefusal.cursor, 1)

        // A compound key two records of one transaction take: refused as a whole.
        let both = await thrown {
            try notes.transact {
                _ = try notes.save(id: "n3", values: ["owner": .string("u"), "day": .number(1)])
                _ = try notes.save(id: "n4", values: ["owner": .string("u"), "day": .number(1)])
            }
        }
        XCTAssertEqual(both?.code, .documentConstraintViolated)
        XCTAssertNil(notes.find(id: "n3"))

        // An upsert lands on the record holding its value.
        _ = try notes.upsert(["slug": .string("a"), "title": .string("second")], on: "slug")
        let holders = try notes.query(["slug": "a"])
        XCTAssertEqual(holders.compactMap { $0["id"]?.stringValue }, ["n1"])
        XCTAssertEqual(holders.first?["title"], "second")
    }

    // MARK: - Behaviour 24

    func testGuardsAndIncrementsAreJudgedOnTheDevice() async throws {
        let (client, _, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        let notes = try notes(client, info.id)
        _ = try notes.save(id: "n1", values: ["slug": .string("a"), "status": .string("open"), "views": .number(1)])

        let exists = await thrown {
            _ = try await notes.save(id: "n1", values: ["slug": .string("a")], options: Db3WriteOptions(ifNotExists: true))
        }
        XCTAssertEqual(exists?.code, .db3ConditionNotMet)
        XCTAssertEqual(exists?.details?["current"]?["id"], "n1")
        XCTAssertEqual(exists?.details?["current"]?["row"]?["status"], "open")

        let unmet = await thrown {
            _ = try await notes.save(
                id: "n1", values: ["status": .string("closed")], options: Db3WriteOptions(condition: ["status": "draft"])
            )
        }
        XCTAssertEqual(unmet?.code, .db3ConditionNotMet)
        XCTAssertEqual(unmet?.details?["current"]?["model"], "Note")
        XCTAssertEqual(notes.find(id: "n1")?["status"], .string("open"))

        // A condition the record meets applies at once, visible to a query.
        _ = try await notes.save(id: "n1", values: ["status": .string("closed")], options: Db3WriteOptions(condition: ["status": "open"]))
        XCTAssertEqual(try notes.query(["status": "closed"]).count, 1)

        // A guarded increment with confirm answers the settled row.
        let views = try await notes.increment(
            id: "n1", fields: ["views": 2], options: Db3WriteOptions(condition: ["status": "closed"], confirm: true)
        )
        XCTAssertEqual(views, ["views": 3])

        let missing = await thrown { _ = try await notes.increment(id: "ghost", fields: ["views": 1], options: Db3WriteOptions()) }
        XCTAssertEqual(missing?.code, .db3RecordNotFound)
    }

    // MARK: - Behaviour 25

    func testEachWriteIsHeardAsLocalRowsAndByTheModelsListeners() async throws {
        let (client, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        let notes = try notes(client, info.id)
        let callbacks = LockedBox(0)
        let unsubscribe = notes.subscribe { callbacks.withValue { $0 += 1 } }
        defer { unsubscribe() }

        _ = try notes.save(id: "n1", values: ["slug": .string("a")])
        try notes.update(id: "n1", values: ["title": .string("t")])
        notes.delete(id: "n1")
        try await eventually("three rows events") { heard.rowsEvents.filter { $0.id == info.id }.count >= 3 }
        let events = heard.rowsEvents.filter { $0.id == info.id }
        XCTAssertTrue(events.allSatisfy { $0.origin == .local }, "\(events.map(\.origin))")
        XCTAssertEqual(events.last?.changes.first?.id, "n1")
        XCTAssertNil(events.last?.changes.first?.row, "the delete's change has no row")
        try await eventually("the model's callbacks") { callbacks.value >= 3 }
    }

    // MARK: - Behaviour 26

    func testASubscriptionIsLiveAtOnceWithNoOpen() async throws {
        let (client, heard, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let info = try await createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))

        let sub = try client.db3.subscribe(info.id)
        try await sub.available()
        try await sub.ready()
        try await eventually("live") { sub.state.phase == .live }
        let live = try await client.db3.state(info.id)
        XCTAssertEqual(live.phase, .live)
        XCTAssertTrue(heard.readyIds.contains(info.id), "Db3ReadyEvent fired")
        let immediate = try client.db3.subscribe(info.id, options: Db3SubscribeOptions(readyTimeout: 0))
        try await immediate.ready()
        XCTAssertFalse(client.documentManager.isOpen(info.id), "nothing was opened")

        sub.dispose()
        immediate.dispose()
        try await eventually("idle") { try await client.db3.state(info.id).phase == .idle }
        let refreshed = try await client.db3.refresh(info.id)
        XCTAssertTrue(refreshed.localOnly)
        XCTAssertEqual(refreshed.phase, .idle)
        XCTAssertFalse(client.documentManager.isOpen(info.id))
    }

    // MARK: - Behaviour 33 (pin)

    func testTheDocumentDoorsStillRefuseFormat3WithLocalOnly() async throws {
        let (client, _, subs) = try await offlineClient()
        defer { subs.forEach { $0.cancel() } }
        let rows = client.documentManager.getMetadataIndex().count
        let viaDocuments = await thrown {
            _ = try await client.documents.create(options: CreateDocumentOptions(title: "Doc", localOnly: true, documentFormat: 3))
        }
        XCTAssertEqual(viaDocuments?.code, .localOnlyUnsupportedOption)
        let viaClient = await thrown {
            _ = try await client.createDocument(options: CreateDocumentOptions(title: "Doc", localOnly: true, documentFormat: 3))
        }
        XCTAssertEqual(viaClient?.code, .localOnlyUnsupportedOption)
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, rows)
        XCTAssertEqual(client.listPendingCreates(), [])
    }
}
