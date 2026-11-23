import XCTest
@testable import JsBaoClient

/// Local document metadata belongs to one app and one user (#4829). The
/// client keeps one SQLite file per app, so the rows live in the store
/// `meta:<appId>:<userId>`: a user who signs in on a shared device never
/// lists, retries or commits another user's pending creates, and finds their
/// own again when they sign back in. Rows an older build wrote to the
/// unscoped `meta` store carry no owner, so no one loads them; a `wipeLocal`
/// logout clears them.
///
/// No server: an `OfflineStore` over a temporary `SQLiteStorageProvider`, and
/// clients over a temporary `.sqlite` file with `autoNetwork: false`, against
/// URLs nothing listens on, with a create hook that records and fails.
final class LocalMetadataPerUserHermeticTests: XCTestCase {

    private static let appId = "local-meta-per-user-app"
    private static let userA = "user-a"
    private static let userB = "user-b"

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "local-meta-per-user-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private static func metaStore(_ userId: String) -> String { "meta:\(appId):\(userId)" }

    private static func entry(_ documentId: String, title: String, pendingCreate: Bool? = nil) -> LocalMetadataEntry {
        LocalMetadataEntry(documentId: documentId, title: title, createdAt: "2026-11-04T00:00:00Z", pendingCreate: pendingCreate)
    }

    // MARK: - Store fixture

    private func makeStore(_ path: String) async throws -> (OfflineStore, SQLiteStorageProvider) {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "probe")
        let store = OfflineStore()
        await store.setStorageProvider(provider)
        return (store, provider)
    }

    private func keys(_ provider: SQLiteStorageProvider, _ store: String) async throws -> Set<String> {
        Set(try await provider.keys(store: store))
    }

    /// Rows as a build before #4829 wrote them: the unscoped `meta` store,
    /// keyed by document id alone.
    private func seedLegacyRows(_ path: String, _ entries: [LocalMetadataEntry]) async throws {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "legacy")
        for entry in entries {
            try await provider.put(store: "meta", key: entry.documentId, value: entry, metadata: nil)
        }
        await provider.close()
    }

    private func legacyKeysAfterClose(_ path: String) async throws -> Set<String> {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "probe")
        defer { Task { await provider.close() } }
        return try await keys(provider, "meta")
    }

    // MARK: - Client fixture

    /// Every create request the client makes, by document id. Each fails,
    /// so a create stays pending.
    private final class CreateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        var ids: [String] { lock.withLock { _ids } }
        func record(_ id: String) { lock.withLock { _ids.append(id) } }
        func count(_ id: String) -> Int { ids.filter { $0 == id }.count }
    }

    private static func options(path: String, userId: String) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            token: makeTestJwt(userId: userId),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            autoNetwork: false
        )
    }

    private static func failCreates(_ client: JsBaoClient, into recorder: CreateRecorder) {
        client.documentManager.createRemoteDocument = { body in
            if let id = body["documentId"] as? String { recorder.record(id) }
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
    }

    private func makeClient(path: String, userId: String, recorder: CreateRecorder) async -> JsBaoClient {
        let client = JsBaoClient(options: Self.options(path: path, userId: userId))
        Self.failCreates(client, into: recorder)
        let ready = await client.waitForStorageReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(client.documentManager.userId, userId)
        return client
    }

    @available(*, deprecated)
    private func create(_ client: JsBaoClient, title: String) async throws -> String {
        let result = try await client.documents.create(options: CreateDocumentOptions(title: title))
        let id = try XCTUnwrap(result.metadata?["documentId"]?.stringValue)
        XCTAssertTrue(client.isPendingCreate(id), "precondition: the create is pending")
        return id
    }

    private func signIn(_ client: JsBaoClient, as userId: String) async {
        client.updateToken(makeTestJwt(userId: userId))
        await client.rebindUserScopedStorage()
        XCTAssertEqual(client.documentManager.userId, userId)
    }

    /// Holds storage setup after the provider is attached and before the user
    /// is bound, and says when setup has got there.
    private final class BindHold: @unchecked Sendable {
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

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 5, _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            if Date() > deadline { throw JsBaoError(code: .unavailable, message: "timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Give a stray retry time to land before a negative assertion.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Behavior 1: a row is read back by its own user only

    func testARowWrittenForOneUserIsReadOnlyByThatUserFromTheirOwnStore() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", title: "A's"))

        let forB = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userB)
        XCTAssertTrue(forB.isEmpty, "B loaded \(forB.map(\.documentId))")
        let gotForB = try await store.getMetadata(appId: Self.appId, userId: Self.userB, documentId: "doc-a")
        XCTAssertNil(gotForB)
        let readForB = try await store.readMetadata(appId: Self.appId, userId: Self.userB, documentId: "doc-a")
        XCTAssertNil(readForB.entry)
        XCTAssertTrue(readForB.readable, "B's store was read; it holds no row")

        let forA = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userA)
        XCTAssertEqual(forA.map(\.documentId), ["doc-a"])
        let gotForA = try await store.getMetadata(appId: Self.appId, userId: Self.userA, documentId: "doc-a")
        XCTAssertEqual(gotForA?.title, "A's")
        let readForA = try await store.readMetadata(appId: Self.appId, userId: Self.userA, documentId: "doc-a")
        XCTAssertEqual(readForA.entry?.title, "A's")

        let keysA = try await keys(provider, Self.metaStore(Self.userA))
        XCTAssertEqual(keysA, ["doc-a"])
        let keysB = try await keys(provider, Self.metaStore(Self.userB))
        XCTAssertEqual(keysB, [])
        let legacy = try await keys(provider, "meta")
        XCTAssertEqual(legacy, [], "nothing is written to the unscoped store")
    }

    // MARK: - Edge: a fresh install

    func testAFreshFileHasNothingInEitherStoreAndAFirstWriteGoesToTheUsersStore() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.ensureMetadataDb(appId: Self.appId, userId: Self.userA)
        let loaded = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userA)
        XCTAssertTrue(loaded.isEmpty)
        var legacy = try await keys(provider, "meta")
        var own = try await keys(provider, Self.metaStore(Self.userA))
        XCTAssertEqual(legacy, [])
        XCTAssertEqual(own, [])

        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", title: "first"))
        legacy = try await keys(provider, "meta")
        own = try await keys(provider, Self.metaStore(Self.userA))
        XCTAssertEqual(legacy, [])
        XCTAssertEqual(own, ["doc-a"])
    }

    // MARK: - Behavior 2: two users' rows for one document

    func testTwoUsersRowsForTheSameDocumentChangeIndependently() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(
            appId: Self.appId, userId: Self.userA, record: Self.entry("doc-1", title: "A title", pendingCreate: true)
        )
        try await store.putMetadata(
            appId: Self.appId, userId: Self.userB, record: Self.entry("doc-1", title: "B title", pendingCreate: true)
        )

        try await store.putMetadataBatch(
            appId: Self.appId, userId: Self.userB, records: [Self.entry("doc-1", title: "B renamed", pendingCreate: false)]
        )
        var rowA = try await store.getMetadata(appId: Self.appId, userId: Self.userA, documentId: "doc-1")
        let rowB = try await store.getMetadata(appId: Self.appId, userId: Self.userB, documentId: "doc-1")
        XCTAssertEqual(rowB?.title, "B renamed")
        XCTAssertEqual(rowA?.title, "A title")
        XCTAssertEqual(rowA?.pendingCreate, true)

        try await store.deleteMetadata(appId: Self.appId, userId: Self.userB, documentId: "doc-1")
        let deletedB = try await store.getMetadata(appId: Self.appId, userId: Self.userB, documentId: "doc-1")
        XCTAssertNil(deletedB)
        rowA = try await store.getMetadata(appId: Self.appId, userId: Self.userA, documentId: "doc-1")
        XCTAssertEqual(rowA?.title, "A title")
        XCTAssertEqual(rowA?.pendingCreate, true)
    }

    // MARK: - Behavior 3: one user's wipe

    func testClearingOneUsersDocumentDataLeavesAnotherUsersRows() async throws {
        let path = newDatabasePath()
        try await seedLegacyRows(path, [Self.entry("doc-old", title: "old")])
        let (store, provider) = try await makeStore(path)
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", title: "A's"))
        try await store.putMetadata(appId: Self.appId, userId: Self.userB, record: Self.entry("doc-b", title: "B's"))
        try await provider.put(store: YjsSQLitePersistence.store, key: "doc-b", value: Data([1, 2, 3]), metadata: nil)

        try await store.clearAllDocumentData(appId: Self.appId, userId: Self.userB)

        let keysB = try await keys(provider, Self.metaStore(Self.userB))
        let legacy = try await keys(provider, "meta")
        let content = try await keys(provider, YjsSQLitePersistence.store)
        XCTAssertEqual(keysB, [])
        XCTAssertEqual(legacy, [], "the unscoped legacy store is cleared by a wipe")
        XCTAssertEqual(content, [])
        let forA = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userA)
        XCTAssertEqual(forA.map(\.documentId), ["doc-a"], "another user's rows survive the wipe")
        XCTAssertEqual(forA.first?.title, "A's")
    }

    // MARK: - Behavior 4: pre-upgrade rows are quarantined

    func testRowsInTheUnscopedLegacyStoreAreNeverLoaded() async throws {
        let path = newDatabasePath()
        try await seedLegacyRows(path, [
            Self.entry("doc-old", title: "old", pendingCreate: true),
            Self.entry("doc-shared", title: "legacy"),
        ])
        let (store, provider) = try await makeStore(path)
        defer { Task { await provider.close() } }
        // A creates a document whose id collides with a legacy row.
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-shared", title: "A's own"))

        let forA = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userA)
        XCTAssertEqual(forA.map(\.documentId), ["doc-shared"])
        XCTAssertEqual(forA.first?.title, "A's own")
        let forB = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userB)
        XCTAssertTrue(forB.isEmpty, "B loaded \(forB.map(\.documentId))")
        let oldForA = try await store.getMetadata(appId: Self.appId, userId: Self.userA, documentId: "doc-old")
        let oldForB = try await store.getMetadata(appId: Self.appId, userId: Self.userB, documentId: "doc-old")
        XCTAssertNil(oldForA)
        XCTAssertNil(oldForB)

        let legacy = try await keys(provider, "meta")
        XCTAssertEqual(legacy, ["doc-old", "doc-shared"], "quarantined rows stay on disk")
    }

    @available(*, deprecated)
    func testAClientBootingOverPreUpgradeRowsListsNoneAndAWipeClearsThem() async throws {
        let path = newDatabasePath()
        try await seedLegacyRows(path, [Self.entry("doc-old", title: "old", pendingCreate: true)])
        let recorder = CreateRecorder()
        let client = await makeClient(path: path, userId: Self.userA, recorder: recorder)

        let listed = await client.documents.listPendingCreates()
        XCTAssertTrue(listed.isEmpty, "listed \(listed.map(\.documentId))")
        let row = await client.documents.getLocalMetadata(documentId: "doc-old")
        XCTAssertNil(row)
        XCTAssertFalse(client.documents.isPendingCreate(documentId: "doc-old"))
        await settle()
        XCTAssertEqual(recorder.count("doc-old"), 0, "a quarantined pending create is never committed")

        try await client.logout(wipeLocal: true)
        await client.destroy()
        let legacy = try await legacyKeysAfterClose(path)
        XCTAssertEqual(legacy, [], "a wipeLocal logout clears the legacy store")
    }

    // MARK: - Behaviors 5 and 6: the issue's repro

    @available(*, deprecated)
    func testAnotherUsersPendingCreateIsNotListedRetriedOrCommittedAfterTheyLogOut() async throws {
        let recorder = CreateRecorder()
        let client = await makeClient(path: newDatabasePath(), userId: Self.userA, recorder: recorder)
        let docA = try await create(client, title: "A's draft")
        try await client.logout()

        await signIn(client, as: Self.userB)
        let requestsBefore = recorder.count(docA)

        let listed = await client.documents.listPendingCreates()
        XCTAssertTrue(listed.isEmpty, "B lists \(listed.map(\.documentId))")
        let pending = await client.documents.getPendingCreate(documentId: docA)
        XCTAssertNil(pending)
        XCTAssertFalse(client.documents.isPendingCreate(documentId: docA))
        let row = await client.documents.getLocalMetadata(documentId: docA)
        XCTAssertNil(row)

        do {
            _ = try await client.documents.commitOfflineCreate(documentId: docA)
            XCTFail("B committed A's pending create")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument, error.message)
        }
        await settle()
        XCTAssertEqual(recorder.count(docA), requestsBefore, "no create request for A's document under B")
        await client.destroy()
    }

    // MARK: - Behavior 7: the user signs back in

    @available(*, deprecated)
    func testAUserWhoSignsBackInFindsTheirOwnPendingCreateOnly() async throws {
        let recorder = CreateRecorder()
        let client = await makeClient(path: newDatabasePath(), userId: Self.userA, recorder: recorder)
        let docA = try await create(client, title: "A's draft")
        try await client.logout()

        await signIn(client, as: Self.userB)
        let docB = try await create(client, title: "B's draft")
        try await client.logout()

        await signIn(client, as: Self.userA)
        let listed = await client.documents.listPendingCreates()
        XCTAssertEqual(listed.map(\.documentId), [docA], "B's \(docB) must not be listed for A")
        XCTAssertEqual(listed.first?.title, "A's draft")
        await client.destroy()
    }

    // MARK: - Behavior 8: a relaunch

    @available(*, deprecated)
    func testAfterARelaunchEachUserLoadsOnlyTheirOwnRows() async throws {
        let path = newDatabasePath()
        let recorder = CreateRecorder()
        let first = await makeClient(path: path, userId: Self.userA, recorder: recorder)
        let docA = try await create(first, title: "A's draft")
        await first.destroy()

        let asB = await makeClient(path: path, userId: Self.userB, recorder: recorder)
        let listedForB = await asB.documents.listPendingCreates()
        XCTAssertTrue(listedForB.isEmpty, "B lists \(listedForB.map(\.documentId))")
        let rowForB = await asB.documents.getLocalMetadata(documentId: docA)
        XCTAssertNil(rowForB)
        await asB.destroy()

        let asA = await makeClient(path: path, userId: Self.userA, recorder: recorder)
        let listedForA = await asA.documents.listPendingCreates()
        XCTAssertEqual(listedForA.map(\.documentId), [docA])
        XCTAssertEqual(listedForA.first?.title, "A's draft")
        await asA.destroy()
    }

    // MARK: - Edges: no signed-in user

    func testAMetadataWriteOrReadWithNoUserTouchesNoStore() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", title: "A's"))

        let wrote = try await store.putMetadataReporting(
            appId: Self.appId, userId: "", record: Self.entry("doc-x", title: "no owner", pendingCreate: true)
        )
        XCTAssertFalse(wrote, "a row with no owner is not persisted")
        try await store.putMetadataBatch(appId: Self.appId, userId: "", records: [Self.entry("doc-y", title: "no owner")])
        try await store.deleteMetadata(appId: Self.appId, userId: "", documentId: "doc-a")
        let unowned = try await keys(provider, Self.metaStore(""))
        let legacy = try await keys(provider, "meta")
        let own = try await keys(provider, Self.metaStore(Self.userA))
        XCTAssertEqual(unowned, [])
        XCTAssertEqual(legacy, [])
        XCTAssertEqual(own, ["doc-a"])

        let loaded = try await store.loadAllMetadata(appId: Self.appId, userId: "")
        XCTAssertTrue(loaded.isEmpty)
        let read = try await store.readMetadata(appId: Self.appId, userId: "", documentId: "doc-a")
        XCTAssertNil(read.entry)
        XCTAssertFalse(read.readable, "with no user the store cannot answer: local-only stays unknown")
    }

    // MARK: - Behavior 10: a create before the user binds

    @available(*, deprecated)
    func testACreateBeforeTheUserBindsPersistsUnderTheUserTheClientBinds() async throws {
        let path = newDatabasePath()
        let recorder = CreateRecorder()
        let hold = BindHold()
        let client = JsBaoClient(
            options: Self.options(path: path, userId: Self.userA),
            connectivityMonitor: nil,
            storageBindHoldForTest: { await hold.wait() }
        )
        defer { hold.release() }
        Self.failCreates(client, into: recorder)
        try await waitUntil("the provider to attach") { hold.reached }
        XCTAssertEqual(client.documentManager.userId, "", "precondition: no user bound yet")

        let docId = try await create(client, title: "early")
        XCTAssertEqual(client.documentManager.getLocalMetadata(docId)?.title, "early")
        let attached = await client.offlineStore.getStorageProvider()
        let provider = try XCTUnwrap(attached)
        try await provider.initialize(namespace: "probe")
        let unowned = try await provider.keys(store: Self.metaStore(""))
        let ownEarly = try await provider.keys(store: Self.metaStore(Self.userA))
        XCTAssertEqual(unowned, [], "nothing is persisted without an owner")
        XCTAssertEqual(ownEarly, [], "not yet: the user is not bound")

        hold.release()
        let ready = await client.waitForStorageReady()
        XCTAssertTrue(ready)
        try await waitUntil("the row to reach A's store") {
            try await provider.keys(store: Self.metaStore(Self.userA)).contains(docId)
        }
        let listed = await client.documents.listPendingCreates()
        XCTAssertEqual(listed.map(\.documentId), [docId])
        await client.destroy()

        let asA = await makeClient(path: path, userId: Self.userA, recorder: recorder)
        let listedForA = await asA.documents.listPendingCreates()
        XCTAssertEqual(listedForA.map(\.documentId), [docId])
        XCTAssertEqual(listedForA.first?.title, "early")
        await asA.destroy()

        let asB = await makeClient(path: path, userId: Self.userB, recorder: recorder)
        let listedForB = await asB.documents.listPendingCreates()
        XCTAssertTrue(listedForB.isEmpty, "B lists \(listedForB.map(\.documentId))")
        await asB.destroy()
    }
}
