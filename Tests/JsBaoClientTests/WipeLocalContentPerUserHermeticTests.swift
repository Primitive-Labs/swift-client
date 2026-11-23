import XCTest
@testable import JsBaoClient
import JsBaoSQLite
import YSwift

/// A `wipeLocal` logout removes the signed-out user's document content and
/// no one else's. Every user who signs in on the device shares one Yjs
/// content store (`yjs_docs`, keyed by document id), so the wipe tells the
/// users' content apart by their metadata stores: a document another user's
/// store lists stays, and everything else goes, content no user lists among
/// it. The JS client gets the same split from its per-user database.
///
/// No server: an `OfflineStore` over a temporary `SQLiteStorageProvider`, and
/// a client over a temporary `.sqlite` file with `autoNetwork: false`, against
/// URLs nothing listens on, with a create hook that fails.
final class WipeLocalContentPerUserHermeticTests: XCTestCase {

    private static let appId = "wipe-content-per-user-app"
    private static let userA = "user-a"
    private static let userB = "user-b"

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "wipe-content-per-user-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private static func entry(_ documentId: String, pendingCreate: Bool? = nil) -> LocalMetadataEntry {
        LocalMetadataEntry(documentId: documentId, title: documentId, createdAt: "2026-11-04T00:00:00Z", pendingCreate: pendingCreate)
    }

    // MARK: - Store fixture

    private func makeStore(_ path: String) async throws -> (OfflineStore, SQLiteStorageProvider) {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "probe")
        let store = OfflineStore()
        await store.setStorageProvider(provider)
        return (store, provider)
    }

    private func putContent(_ provider: SQLiteStorageProvider, _ documentIds: String...) async throws {
        for documentId in documentIds {
            try await provider.put(store: YjsSQLitePersistence.store, key: documentId, value: Data([1, 2, 3]), metadata: nil)
        }
    }

    private func content(_ provider: SQLiteStorageProvider) async throws -> Set<String> {
        Set(try await provider.keys(store: YjsSQLitePersistence.store))
    }

    // MARK: - Behavior 1: another user's wipe leaves a user's content

    func testAnotherUsersWipeLeavesTheContentOfADocumentOnlyThisUserStored() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", pendingCreate: true))
        try await store.putMetadata(appId: Self.appId, userId: Self.userB, record: Self.entry("doc-b"))
        try await putContent(provider, "doc-a", "doc-b")

        try await store.clearAllDocumentData(appId: Self.appId, userId: Self.userB)

        let left = try await content(provider)
        XCTAssertEqual(left, ["doc-a"], "B's wipe removes B's content and keeps A's pending create's")
    }

    // MARK: - Behavior 3: a user's own wipe removes everything they stored

    func testAUsersWipeRemovesAllTheirContentAndContentNoUserListsButKeepsAnotherUsers() async throws {
        let path = newDatabasePath()
        let (store, provider) = try await makeStore(path)
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", pendingCreate: true))
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a2"))
        try await store.putMetadata(appId: Self.appId, userId: Self.userB, record: Self.entry("doc-b"))
        // A row an older build wrote to the unscoped store, and content with
        // no metadata row anywhere: neither has an owner to keep it.
        try await provider.put(store: OfflineStore.legacyStoreMetaDocs, key: "doc-old", value: Self.entry("doc-old"), metadata: nil)
        try await putContent(provider, "doc-a", "doc-a2", "doc-b", "doc-old", "doc-orphan")

        try await store.clearAllDocumentData(appId: Self.appId, userId: Self.userA)

        let left = try await content(provider)
        XCTAssertEqual(left, ["doc-b"], "A's wipe removes A's content and unowned content, and keeps B's")
        let rowsA = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userA)
        XCTAssertTrue(rowsA.isEmpty)
    }

    // MARK: - Edge: a document both users stored

    func testADocumentBothUsersStoredKeepsItsContentUntilTheLastOfThemWipes() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-shared"))
        try await store.putMetadata(appId: Self.appId, userId: Self.userB, record: Self.entry("doc-shared"))
        try await putContent(provider, "doc-shared")

        try await store.clearAllDocumentData(appId: Self.appId, userId: Self.userB)
        var left = try await content(provider)
        XCTAssertEqual(left, ["doc-shared"], "A still stores the document, so B's wipe keeps its content")

        try await store.clearAllDocumentData(appId: Self.appId, userId: Self.userA)
        left = try await content(provider)
        XCTAssertEqual(left, [], "no user stores it any more, so A's wipe removes it")
    }

    // MARK: - Edge: a failed ownership read aborts the wipe

    /// Interrupts every statement whose expanded SQL contains `needle`, before
    /// it returns a row, the way a transient read failure would end the scan.
    private final class Interruption {
        let needle: String
        var armed = false
        var interrupted = 0
        init(needle: String) { self.needle = needle }
    }

    private func wipe(
        _ store: OfflineStore, _ provider: SQLiteStorageProvider, userId: String, interrupting needle: String
    ) async throws -> (error: Error?, interrupted: Int) {
        let interruption = Interruption(needle: needle)
        let context = Unmanaged.passRetained(interruption).toOpaque()
        defer { Unmanaged<Interruption>.fromOpaque(context).release() }
        try provider.withRawConnection { db in
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                guard let context, let statement else { return 0 }
                let interruption = Unmanaged<Interruption>.fromOpaque(context).takeUnretainedValue()
                guard let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
                defer { sqlite3_free(expanded) }
                interruption.armed = String(cString: expanded).contains(interruption.needle)
                return 0
            }, context)
            sqlite3_progress_handler(db, 1, { context in
                guard let context else { return 0 }
                let interruption = Unmanaged<Interruption>.fromOpaque(context).takeUnretainedValue()
                guard interruption.armed else { return 0 }
                interruption.interrupted += 1
                return 1
            }, context)
        }
        var failure: Error?
        do {
            try await store.clearAllDocumentData(appId: Self.appId, userId: userId)
        } catch {
            failure = error
        }
        try provider.withRawConnection { db in
            sqlite3_progress_handler(db, 0, nil, nil)
            sqlite3_trace_v2(db, 0, nil, nil)
        }
        return (failure, interruption.interrupted)
    }

    func testAWipeWhoseListingOfTheUsersStoresFailsThrowsAndRemovesNothing() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", pendingCreate: true))
        try await store.putMetadata(appId: Self.appId, userId: Self.userB, record: Self.entry("doc-b"))
        try await putContent(provider, "doc-a", "doc-b")

        let (error, interrupted) = try await wipe(store, provider, userId: Self.userB, interrupting: "SELECT DISTINCT store")

        XCTAssertGreaterThan(interrupted, 0, "precondition: the listing of the metadata stores was interrupted")
        XCTAssertNotNil(error, "a wipe that cannot tell whose content is whose fails")
        let left = try await content(provider)
        XCTAssertEqual(left, ["doc-a", "doc-b"], "an incomplete listing deleted content another user's store lists")
        let rowsB = try await store.loadAllMetadata(appId: Self.appId, userId: Self.userB)
        XCTAssertEqual(rowsB.map(\.documentId), ["doc-b"], "the aborted wipe can run again")
    }

    func testAWipeWhoseReadOfAnotherUsersStoreFailsThrowsAndRemovesNothing() async throws {
        let (store, provider) = try await makeStore(newDatabasePath())
        defer { Task { await provider.close() } }
        try await store.putMetadata(appId: Self.appId, userId: Self.userA, record: Self.entry("doc-a", pendingCreate: true))
        try await store.putMetadata(appId: Self.appId, userId: Self.userB, record: Self.entry("doc-b"))
        try await putContent(provider, "doc-a", "doc-b")
        let storeA = OfflineStore.metadataStore(appId: Self.appId, userId: Self.userA)

        let (error, interrupted) = try await wipe(store, provider, userId: Self.userB, interrupting: "SELECT key FROM kv_store WHERE store = '\(storeA)'")

        XCTAssertGreaterThan(interrupted, 0, "precondition: the read of A's metadata store was interrupted")
        XCTAssertNotNil(error, "a wipe that cannot read another user's store fails")
        let left = try await content(provider)
        XCTAssertEqual(left, ["doc-a", "doc-b"], "an incomplete read of A's store deleted A's pending create's content")
    }

    // MARK: - Behavior 2: the issue's repro, through the client

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

    private func signIn(_ client: JsBaoClient, as userId: String) async {
        client.updateToken(makeTestJwt(userId: userId))
        await client.rebindUserScopedStorage()
        XCTAssertEqual(client.documentManager.userId, userId)
    }

    private let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)

    @available(*, deprecated)
    func testAUserFindsTheContentOfTheirPendingCreateAfterAnotherUsersWipe() async throws {
        let client = JsBaoClient(options: Self.options(path: newDatabasePath(), userId: Self.userA))
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let ready = await client.waitForStorageReady()
        XCTAssertTrue(ready)

        let created = try await client.documents.create(options: CreateDocumentOptions(title: "A's draft"))
        let docA = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        XCTAssertTrue(client.isPendingCreate(docA), "precondition: the create is pending")
        let doc = try await client.openDocument(docA, options: localOpen)
        let map: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in map.updateValue("written offline by A", forKey: "k", transaction: txn) }
        _ = await client.closeDocument(docA)
        try await client.logout()

        await signIn(client, as: Self.userB)
        try await client.logout(wipeLocal: true)

        await signIn(client, as: Self.userA)
        let listed = await client.documents.listPendingCreates()
        XCTAssertEqual(listed.map(\.documentId), [docA])
        let reopened = try await client.openDocument(docA, options: localOpen)
        let readMap: YMap<String> = reopened.getOrCreateMap(named: "notes")
        let value = reopened.transactSync { txn -> String? in readMap.get(key: "k", transaction: txn) }
        XCTAssertEqual(value, "written offline by A", "B's wipe deleted the content of A's pending create")
        await client.destroy()
    }
}
