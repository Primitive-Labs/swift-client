import XCTest
@testable import JsBaoClient
import YSwift
import JsBaoSQLite

/// The client's format-3 front door without a server: the storage refusal,
/// how frames are classified, the existing format-mismatch arm, and the store
/// reset when another user signs in (intent decision 18). Clients run over a
/// temporary `.sqlite` directory with `autoNetwork: false`; creates are
/// intercepted so nothing is posted.
final class RecordLogClientHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/rl-client-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(user: String?, storage: StorageConfig) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "record-log-client-test-app",
            token: user.map { makeTestJwt(userId: $0) },
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: storage,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return client
    }

    private func createFormatThree(_ client: JsBaoClient) async throws -> String {
        let created = try await client.createDocument(options: CreateDocumentOptions(documentFormat: 3))
        return try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
    }

    private func openLocally(_ client: JsBaoClient, _ documentId: String) async throws {
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
    }

    /// One integer a statement answers, read straight off the file.
    private func count(_ path: String, _ sql: String) throws -> Int {
        try probe(path, sql).flatMap { Int($0) } ?? -1
    }

    /// The user the record-log tables belong to, read straight off the file.
    private func owner(_ path: String) throws -> String? {
        try probe(path, "SELECT user_id FROM record_log_owner LIMIT 1")
    }

    /// How long the test's own connection waits for the client's connection to
    /// release its lock. The client writes on its own schedule (a flush, the
    /// analytics buffer), and without a busy timeout a statement that lands
    /// during one of those writes fails at once with "database is locked".
    private static let busyTimeoutMs: Int32 = 5_000

    /// Run one statement on the file through a connection of the test's own.
    private func execute(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_busy_timeout(db, Self.busyTimeoutMs) == SQLITE_OK,
              sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        else { throw JsBaoError(code: .unavailable, message: String(cString: sqlite3_errmsg(db))) }
    }

    private func probe(_ path: String, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw JsBaoError(code: .unavailable, message: "cannot open \(path)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, Self.busyTimeoutMs)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw JsBaoError(code: .unavailable, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    // MARK: - Edge 45

    func testAFormatThreeDocumentOnMemoryStorageIsRefusedBeforeAnyFrame() async throws {
        let client = await makeClient(user: "user-a", storage: .memory)
        defer { Task { await client.destroy() } }
        let documentId = try await createFormatThree(client)
        do {
            try await openLocally(client, documentId)
            XCTFail("a format-3 document cannot live in memory storage")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2StorageUnavailable)
            XCTAssertEqual(error.details?["reason"], "not-persistent")
        }
        XCTAssertFalse(client.isRecordLogDocument(documentId))
    }

    // MARK: - Edge 46 and the frame router

    func testRecordFramesAreRoutedButAFormatMismatchStillTearsTheDocumentDown() async throws {
        XCTAssertTrue(JsBaoClient.isRecordLogFrame(type: "record.opened", messageType: nil, code: nil))
        XCTAssertTrue(JsBaoClient.isRecordLogFrame(type: "error", messageType: "record.open", code: "WRITER_ID_TAKEN"))
        XCTAssertFalse(JsBaoClient.isRecordLogFrame(type: "error", messageType: "record.open", code: "DOCUMENT_FORMAT_MISMATCH"))
        XCTAssertFalse(JsBaoClient.isRecordLogFrame(type: "error", messageType: "syncStep1", code: "X"))
        XCTAssertFalse(JsBaoClient.isRecordLogFrame(type: "syncComplete", messageType: nil, code: nil))

        let client = await makeClient(user: "user-a", storage: .sqlite(directory: newDatabasePath()))
        defer { Task { await client.destroy() } }
        let created = try await client.createDocument(options: CreateDocumentOptions())
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await openLocally(client, documentId)
        await client.handleWebSocketMessage(RecordLogJSON.text([
            "type": "error", "code": "DOCUMENT_FORMAT_MISMATCH", "documentId": .string(documentId),
            "messageType": "syncStep1", "message": "format 3", "detail": ["declared": 1, "actual": 3],
        ]))
        XCTAssertTrue(client.isFormatRefused(documentId), "the existing arm tore the document down")
        XCTAssertEqual(client.formatRefusal(documentId)?.code, .documentFormatMismatch)
    }

    // MARK: - Edge 52 and the hermetic half of edge 51: the principal

    func testTheStoreIsKeptForTheSameUserAndResetWithoutAnEventForAnother() async throws {
        let path = newDatabasePath()
        let client = await makeClient(user: "user-a", storage: .sqlite(directory: path))
        defer { Task { await client.destroy() } }
        let refusals = LockedBox(0)
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { _ in refusals.withValue { $0 += 1 } }
        defer { subscription.cancel() }

        let documentId = try await createFormatThree(client)
        try await openLocally(client, documentId)
        XCTAssertTrue(client.isRecordLogDocument(documentId))
        let writerA = try XCTUnwrap(client.recordLogBinding(documentId)?.writer)
        _ = try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId)).create(id: "n1", values: ["title": .string("by a")])
        try client.recordLogBinding(documentId)?.store.flush()
        XCTAssertEqual(try owner(path), "user-a", "the owner is written at the first bind under a known user")

        // A logout without wipeLocal and a sign-in as the same user keep everything.
        try await client.logout()
        XCTAssertFalse(client.isRecordLogDocument(documentId), "the logout closed the document")
        client.updateToken(makeTestJwt(userId: "user-a"))
        await client.rebindUserScopedStorage()
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 1, "the same user keeps the unsent write")
        try await openLocally(client, documentId)
        XCTAssertEqual(try client.recordLogBinding(documentId)?.store.pendingOf(writerA).count, 1)
        XCTAssertNotNil(try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId)).find(id: "n1"))

        // Another user: the store is reset, with no refusal event for user A's writes.
        try await client.logout()
        client.updateToken(makeTestJwt(userId: "user-b"))
        await client.rebindUserScopedStorage()
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 0)
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_view"), 0)
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_writers"), 0)
        XCTAssertEqual(try owner(path), "user-b")
        XCTAssertEqual(refusals.value, 0, "user A's writes are theirs; nothing is handed to user B")
    }

    /// 4309-C2-08: a reset that cannot complete (here a trigger refuses the
    /// reset's deletes, while every other write still succeeds) leaves nothing
    /// of user A's store bindable for user B; once it can complete, the next
    /// bind resets it first.
    func testAResetThatCannotCompleteLeavesTheStoreUnbindableUntilItDoes() async throws {
        let path = newDatabasePath()
        let client = await makeClient(user: "user-a", storage: .sqlite(directory: path))
        defer { Task { await client.destroy() } }
        let documentId = try await createFormatThree(client)
        try await openLocally(client, documentId)
        _ = try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId)).create(id: "n1", values: ["title": .string("by a")])
        try client.recordLogBinding(documentId)?.store.flush()
        try await client.logout()
        client.updateToken(makeTestJwt(userId: "user-b"))

        try execute(path, """
            CREATE TRIGGER refuse_reset BEFORE DELETE ON record_log_pending
            BEGIN SELECT RAISE(ABORT, 'the reset cannot complete'); END
            """)
        await client.rebindUserScopedStorage()
        XCTAssertEqual(try owner(path), "user-a", "the reset could not run")
        do {
            _ = try await client.bindRecordLogDocument(documentId)
            XCTFail("user A's store must not be bound for user B")
        } catch {}
        XCTAssertNil(client.recordLogBinding(documentId))
        XCTAssertFalse(client.isRecordLogDocument(documentId))
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 1, "nothing of it was sent or removed")

        try execute(path, "DROP TRIGGER refuse_reset")
        let binding = try await client.bindRecordLogDocument(documentId)
        XCTAssertEqual(try owner(path), "user-b", "the bind reset the store first")
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 0, "user A's write is gone")
        XCTAssertNil(try binding.store.read(model: "Note", id: "n1"))
    }

    func testABindWhileSignedOutComparesNothingAndARelaunchAsAnotherUserResets() async throws {
        let path = newDatabasePath()
        var documentId = ""
        do {
            let a = await makeClient(user: "user-a", storage: .sqlite(directory: path))
            documentId = try await createFormatThree(a)
            try await openLocally(a, documentId)
            _ = try XCTUnwrap(a.sharedModel("Note")?.member(docId: documentId)).create(id: "n1", values: ["title": .string("a")])
            try a.recordLogBinding(documentId)?.store.flush()
            await a.destroy()
        }
        // An offline relaunch before the token is back: nothing compared, nothing reset.
        do {
            let signedOut = await makeClient(user: nil, storage: .sqlite(directory: path))
            XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 1)
            XCTAssertEqual(try owner(path), "user-a")
            await signedOut.destroy()
        }
        // The same user relaunching keeps it.
        do {
            let same = await makeClient(user: "user-a", storage: .sqlite(directory: path))
            XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 1)
            await same.destroy()
        }
        // Another user relaunching over the same directory resets it.
        let other = await makeClient(user: "user-b", storage: .sqlite(directory: path))
        defer { Task { await other.destroy() } }
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 0)
        XCTAssertEqual(try owner(path), "user-b")
    }
    // MARK: - Behavior 31: a wiping logout

    func testAWipingLogoutPurgesTheStoreAndHandsUnsentWritesBackOnce() async throws {
        let path = newDatabasePath()
        let client = await makeClient(user: "user-a", storage: .sqlite(directory: path))
        defer { Task { await client.destroy() } }
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in
            refusals.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }
        let documentId = try await createFormatThree(client)
        try await openLocally(client, documentId)
        _ = try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId)).create(id: "n1", values: ["title": .string("unsent")])
        try client.recordLogBinding(documentId)?.store.flush()

        try await client.logout(wipeLocal: true)
        XCTAssertEqual(refusals.value.count, 1, "one event for the unsent write")
        XCTAssertEqual(refusals.value.first?.error.code, .documentStorePurged)
        XCTAssertEqual(refusals.value.first?.writes?.map(\.recordId), ["n1"])
        for table in RecordLogSchema.clientTables {
            XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM \(table) WHERE doc_id = '\(documentId)'"), 0, table)
        }
    }

    // MARK: - Behavior 29: an offline open with no format

    func testAnOpenWithNoKnownFormatProceedsAndBindsOnceTheRowNamesThree() async throws {
        let client = await makeClient(user: "user-a", storage: .sqlite(directory: newDatabasePath()))
        defer { Task { await client.destroy() } }
        let created = try await client.createDocument(options: CreateDocumentOptions())
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        XCTAssertNil(client.documentManager.documentFormat(documentId))
        try await openLocally(client, documentId)
        XCTAssertFalse(client.isRecordLogDocument(documentId), "offline with no format, the open proceeds as before")

        client.documentManager.noteDocumentFormat(documentId, 3)
        _ = await client.closeDocument(documentId)
        try await openLocally(client, documentId)
        XCTAssertTrue(client.isRecordLogDocument(documentId), "bound once the row names format 3")
    }

    // MARK: - A sync that lands before the open binds

    /// The sync a create's commit schedules can reach the handshake while the
    /// open is between opening the Y.Doc and binding the store. The row names
    /// format 3, so the handshake is the session's `record.open` once the open
    /// binds — never a `syncStep1`, which the room refuses by tearing the
    /// document down. (A db3 created here is bound at its create since #4701,
    /// so the row here is one whose format was learned after it was written.)
    func testADocumentWhoseRowNamesThreeDoesNotHandshakeUntilItIsBound() async throws {
        let client = await makeClient(user: "user-a", storage: .sqlite(directory: newDatabasePath()))
        defer { Task { await client.destroy() } }
        let created = try await client.createDocument(options: CreateDocumentOptions())
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        client.documentManager.noteDocumentFormat(documentId, 3)
        client.documentManager.handlePendingCreateCommitted(documentId)
        XCTAssertEqual(client.documentManager.documentFormat(documentId), 3)
        XCTAssertFalse(client.isRecordLogDocument(documentId))

        let early = await client.resolveRecordLogBeforeHandshake(documentId)
        XCTAssertFalse(early, "no Yjs handshake for a format-3 document the open has not bound yet")

        try await openLocally(client, documentId)
        XCTAssertTrue(client.isRecordLogDocument(documentId))
        let bound = await client.resolveRecordLogBeforeHandshake(documentId)
        XCTAssertTrue(bound, "once bound, its session handshakes")
    }

    // MARK: - #4701 edge 49: releasing a db3's session under a transaction on another thread

    /// What a door close of a db3 does to its store (#4701 C2): the session is
    /// released, the open group of saves commits, and the binding stays, so a
    /// transaction another thread holds commits its entry after the release.
    func testReleasingTheSessionFlushesTheGroupAndKeepsTheBindingForAPendingTransaction() async throws {
        let path = newDatabasePath()
        let client = await makeClient(user: "user-a", storage: .sqlite(directory: path))
        defer { Task { await client.destroy() } }
        let documentId = try await createFormatThree(client)
        try await openLocally(client, documentId)
        let member = try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId))
        _ = try member.create(id: "n0", values: ["title": .string("before the release")])

        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let outcome = LockedBox<Result<Void, Error>?>(nil)
        let thread = Thread {
            outcome.value = Result {
                try member.transact {
                    _ = try member.create(id: "t1", values: ["title": .string("held by the transaction")])
                    started.signal()
                    proceed.wait()
                }
            }
        }
        thread.start()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { started.wait(); done.resume() }
        }

        await client.releaseRecordLogSession(documentId)
        XCTAssertEqual(try count(path, "SELECT COUNT(*) AS n FROM record_log_pending"), 1, "the open group committed")
        proceed.signal()
        let deadline = Date().addingTimeInterval(5)
        while outcome.value == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertNoThrow(try XCTUnwrap(outcome.value).get(), "the transaction's commit lands after the release")
        let binding = try XCTUnwrap(client.recordLogBinding(documentId), "the binding stays")
        XCTAssertFalse(binding.isClosed)
        try binding.store.flush()
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.m.id), ["n0", "t1"])
        XCTAssertNotNil(member.find(id: "t1"))
    }
}
