import XCTest
@testable import JsBaoClient
import YSwift

/// Logout must empty the shared cross-document store the codegen facade reads
/// (issue #2874).
///
/// Before this fix `logout(wipeLocal: true)` wiped the persisted stores but
/// left the live in-memory state alone: every document stayed open, every
/// `MultiDocModel` member stayed connected, and every update observer stayed
/// attached — so the next user signing in in the same process read the
/// signed-out user's rows through `Model.query()`.
///
/// JS is the reference: `authController.logout` awaits an `onLogoutCleanup`
/// hook on EVERY logout, which closes every open document with
/// `{ evictLocal: false }` before logout completion is signalled. Swift now
/// mirrors that hook. The one deliberate departure is ordering: the close
/// sweep runs BEFORE the `wipeLocal` purge, because Swift's
/// `DocumentManager.evictAllLocalData()` clears `openDocs` and would leave
/// the sweep nothing to iterate.
///
/// Server-free: the client is built with unreachable URLs and never connects.
/// `LogoutNote` + its facade extension are hand-written to match what
/// `SwiftEmitter.crossDocumentFacade(schema:)` emits, the same way
/// `CrossDocumentStaticQueryTests` does.
final class LogoutSharedStoreHermeticTests: XCTestCase {

    struct LogoutNote: PrimitiveModel, Equatable {
        static let modelName = "logout_notes"
        static let primitiveSchema = PrimitiveSchema(
            name: "logout_notes",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string, required: true),
            ]
        )

        var id: String
        var title: String

        init(id: String, title: String) {
            self.id = id; self.title = title
        }

        init?(record: PrimitiveRecord) {
            guard let title = record["title"]?.asString else { return nil }
            self.id = record.id; self.title = title
        }

        init?(row: [String: JSONValue]) {
            guard let id = row["id"]?.stringValue,
                  let title = row["title"]?.stringValue
            else { return nil }
            self.id = id; self.title = title
        }

        func primitiveValues() -> [String: PrimitiveValue] {
            ["title": .string(title)]
        }
    }

    /// Collects `queueOutboundUpdate` calls from whichever thread the write
    /// runs on. A retained `YDocument` whose observer survived the logout
    /// shows up here.
    private final class DocIdSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        func append(_ documentId: String) { lock.withLock { _ids.append(documentId) } }
        var all: [String] { lock.withLock { _ids } }
    }

    /// Counts calls made from a background retry task.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// Records what a logout-completion subscriber sees at delivery time.
    private final class CompletionSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var _openDocs: Int?
        private var _rows: Int?
        func record(openDocs: Int, rows: Int) {
            lock.withLock { _openDocs = openDocs; _rows = rows }
        }
        var openDocs: Int? { lock.withLock { _openDocs } }
        var rows: Int? { lock.withLock { _rows } }
    }

    override func setUp() {
        super.setUp()
        SchemaSync.clearCache()
        JsBaoClient.clearDefault()
    }

    override func tearDown() {
        JsBaoClient.clearDefault()
        super.tearDown()
    }

    /// A client that never reaches a server, configured as the process-wide
    /// default so the codegen facade reads through it.
    private func makeClient(_ appId: String) -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        JsBaoClient.configureDefault(client)
        client.registerModels([LogoutNote.self])
        return client
    }

    /// Two open local-only documents holding three rows between them — the
    /// shape of the issue's repro (a per-user "library" document plus a
    /// second one, read unscoped through the facade).
    private func makeClientWithTwoPopulatedDocuments(
        _ appId: String
    ) async throws -> (client: JsBaoClient, docA: String, docB: String, ydocA: YDocument?) {
        let client = makeClient(appId)
        let (docA, ydocA) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        let (docB, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        try LogoutNote(id: "a1", title: "alpha").save(in: docA)
        try LogoutNote(id: "a2", title: "beta").save(in: docA)
        try LogoutNote(id: "b1", title: "gamma").save(in: docB)
        XCTAssertEqual(try LogoutNote.count(), 3, "precondition: rows span both documents")
        return (client, docA, docB, ydocA)
    }

    /// Give any stray async work time to land before a negative assertion.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Behavior 1: unscoped reads return nothing after the logout

    func testWipeLocalLogoutEmptiesUnscopedFacadeReads() async throws {
        let (client, _, _, _) = try await makeClientWithTwoPopulatedDocuments("logout-store-reads")
        defer { Task { await client.destroy() } }

        try await client.logout(wipeLocal: true)

        XCTAssertEqual(try LogoutNote.count(), 0, "the signed-out user's rows must not survive the logout")
        XCTAssertTrue(try LogoutNote.findAll().isEmpty)
        XCTAssertNil(try LogoutNote.find("a1"))

        // The per-schema store stays registered (JS keeps its model registry
        // across a logout); only its per-document members go away.
        XCTAssertTrue(
            client.inspectableSharedMembers().isEmpty,
            "no document may stay connected to a shared store after logout"
        )
        XCTAssertNotNil(
            client.sharedModel(LogoutNote.modelName),
            "the registered store itself must survive so the next user's opens reconnect to it"
        )
    }

    // MARK: - Behavior 2: every open document is closed

    /// The documents must be *closed*, not merely dropped from the open-doc
    /// map: the `wipeLocal` purge empties that map on its own, so the closed
    /// event is what tells the two apart.
    func testWipeLocalLogoutClosesEveryOpenDocument() async throws {
        let (client, docA, docB, _) = try await makeClientWithTwoPopulatedDocuments("logout-store-closes")
        defer { Task { await client.destroy() } }

        let closed = try await collectEvents(from: client.eventEmitter, event: DocumentClosedEvent.self) {
            try await client.logout(wipeLocal: true)
        }

        XCTAssertEqual(Set(closed.map(\.documentId)), [docA, docB])
        XCTAssertNil(client.getDoc(docA))
        XCTAssertNil(client.getDoc(docB))
        XCTAssertTrue(client.documentManager.openDocumentsSnapshot().isEmpty)
    }

    // MARK: - Behavior 3: a write naming a closed document throws

    func testFacadeWriteAfterLogoutThrowsNotOpen() async throws {
        let (client, docA, _, _) = try await makeClientWithTwoPopulatedDocuments("logout-store-write")
        defer { Task { await client.destroy() } }

        try await client.logout(wipeLocal: true)

        XCTAssertThrowsError(try LogoutNote(id: "a3", title: "delta").save(in: docA)) { error in
            guard let jsBaoError = error as? JsBaoError else {
                return XCTFail("expected a JsBaoError, got \(error)")
            }
            XCTAssertEqual(jsBaoError.code, .notFound)
            XCTAssertTrue(
                jsBaoError.message.contains("is not open"),
                "expected the existing not-open message, got: \(jsBaoError.message)"
            )
        }
    }

    // MARK: - Behavior 4: a retained YDocument is inert after the logout

    /// The issue's second gap: `evictAllLocalData()` closes nothing and
    /// cancels no update observer, so a `YDocument` the app still holds keeps
    /// forwarding its edits to `queueOutboundUpdate`. Run under
    /// `wipeLocal: true` on purpose — it is the assertion that distinguishes
    /// "the sweep closed the documents" from "the wipe merely emptied the
    /// maps", which is exactly what the close-before-wipe ordering buys.
    func testRetainedYDocumentEditAfterWipeLocalLogoutIsInert() async throws {
        let (client, docA, _, ydocA) = try await makeClientWithTwoPopulatedDocuments("logout-store-retained")
        defer { Task { await client.destroy() } }
        let ydoc = try XCTUnwrap(ydocA)

        try await client.logout(wipeLocal: true)

        // Install the sink after the logout: only the post-logout edit is
        // under test.
        let queued = DocIdSink()
        client.onOutboundQueuedForTest = { queued.append($0) }

        let map: YMap<String> = ydoc.getOrCreateMap(named: "content")
        ydoc.transactSync { txn in
            map.updateValue("post-logout", forKey: "key", transaction: txn)
        }
        await settle()

        XCTAssertTrue(
            queued.all.isEmpty,
            "the update observer must be cancelled by the logout; queued: \(queued.all)"
        )
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(docA), 0)
        XCTAssertEqual(try LogoutNote.count(), 0, "a retained document may not resurrect rows")
    }

    // MARK: - Behavior 5: a plain logout cleans up too (JS parity)

    func testPlainLogoutAlsoEmptiesSharedStoreAndClosesDocuments() async throws {
        let (client, docA, docB, ydocA) = try await makeClientWithTwoPopulatedDocuments("logout-store-plain")
        defer { Task { await client.destroy() } }
        let ydoc = try XCTUnwrap(ydocA)

        try await client.logout()

        XCTAssertEqual(try LogoutNote.count(), 0)
        XCTAssertNil(client.getDoc(docA))
        XCTAssertNil(client.getDoc(docB))
        XCTAssertTrue(client.documentManager.openDocumentsSnapshot().isEmpty)

        let queued = DocIdSink()
        client.onOutboundQueuedForTest = { queued.append($0) }
        let map: YMap<String> = ydoc.getOrCreateMap(named: "content")
        ydoc.transactSync { txn in
            map.updateValue("post-logout", forKey: "key", transaction: txn)
        }
        await settle()
        XCTAssertTrue(queued.all.isEmpty, "queued: \(queued.all)")
    }

    // MARK: - Behavior 6: the next user in the same process sees only their rows

    func testNextUserReadsOnlyTheirOwnRowsInTheSameProcess() async throws {
        let (client, _, _, _) = try await makeClientWithTwoPopulatedDocuments("logout-store-next-user")
        defer { Task { await client.destroy() } }

        try await client.logout(wipeLocal: true)

        // The next user, same process: a fresh document, written through the
        // same registered store.
        let (docC, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        try LogoutNote(id: "c1", title: "next user's row").save(in: docC)

        XCTAssertEqual(try LogoutNote.count(), 1)
        XCTAssertEqual(Set(try LogoutNote.findAll().map(\.id)), ["c1"])
    }

    // MARK: - Behavior 7: completion fires only after the cleanup

    func testLogoutCompleteSubscriberObservesEmptyStore() async throws {
        let (client, _, _, _) = try await makeClientWithTwoPopulatedDocuments("logout-store-complete")
        defer { Task { await client.destroy() } }

        let seen = CompletionSnapshot()
        let sub = client.eventEmitter.subscribe(AuthLogoutCompleteEvent.self) { _ in
            seen.record(
                openDocs: client.documentManager.openDocumentsSnapshot().count,
                rows: (try? LogoutNote.count()) ?? -1
            )
        }
        defer { sub.cancel() }

        try await client.logout(wipeLocal: true)

        XCTAssertEqual(seen.openDocs, 0, "completion must fire after every document is closed")
        XCTAssertEqual(seen.rows, 0, "completion must fire after the shared store is emptied")
    }

    // MARK: - Behavior 8: pending-create retry state is dropped

    /// A signed-out user's failed create may not retry under a later
    /// session's transport (JS `resetUserScopedState`). Plain `logout()` —
    /// the reset runs on every logout, not only under `wipeLocal`.
    func testPlainLogoutClearsPendingCreateRetryState() async throws {
        let client = makeClient("logout-store-pending-create")
        defer { Task { await client.destroy() } }

        // A create the server never accepts, retried on a fixed 1s backoff:
        // the retry timer is still armed when the logout runs.
        let commitAttempts = CallCounter()
        client.documentManager.createRemoteDocument = { _ in
            commitAttempts.increment()
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        client.documentManager.isOnlineProvider = { true }
        client.documentManager.commitRetryBackoff = CommitRetryBackoff(
            base: 1, factor: 1, max: 1, jitter: false, maxAttempts: 10
        )

        let (docId, _) = try await client.createDocumentForTest()
        XCTAssertTrue(client.isPendingCreate(docId))
        client.documentManager.scheduleCommitRetry(documentId: docId)
        try await eventually(description: "a commit attempt to fail") {
            commitAttempts.value >= 1
        }

        try await client.logout()
        let attemptsAtLogout = commitAttempts.value

        XCTAssertTrue(
            client.listPendingCreates().isEmpty,
            "the signed-out user's pending create must not survive the logout"
        )
        // Past the armed retry's backoff: a cancelled timer sends nothing.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(
            commitAttempts.value, attemptsAtLogout,
            "no create request may reach the transport after the logout"
        )
    }

    // MARK: - Behavior 9: a document held past `evictAllLocal()` is closed too

    /// `evictAllLocal()` clears the open-document map without closing
    /// anything — its update observer stays attached and its shared-store
    /// membership stays connected (that is exactly what its own comment
    /// warns about). A logout sweep reading the open-document map would skip
    /// those documents and leave the signed-out user's rows readable, so the
    /// sweep reads the retained-document set instead.
    private func assertLogoutClosesDocumentsHeldPastEvictAllLocal(
        appId: String,
        wipeLocal: Bool
    ) async throws {
        let (client, docA, _, ydocA) = try await makeClientWithTwoPopulatedDocuments(appId)
        defer { Task { await client.destroy() } }
        let ydoc = try XCTUnwrap(ydocA)

        await client.evictAllLocal()

        // Precondition — the purge is what makes this case distinct: it took
        // the documents out of the open map while leaving every row of theirs
        // in the shared store.
        XCTAssertTrue(client.documentManager.openDocumentsSnapshot().isEmpty)
        XCTAssertEqual(
            try LogoutNote.count(), 3,
            "precondition: the store the facade reads survives evictAllLocal()"
        )

        if wipeLocal {
            try await client.logout(wipeLocal: true)
        } else {
            try await client.logout()
        }

        XCTAssertEqual(
            try LogoutNote.count(), 0,
            "an evicted-but-held document's rows must not survive the logout"
        )
        XCTAssertTrue(
            client.inspectableSharedMembers().isEmpty,
            "no document may stay connected to a shared store after logout"
        )

        // The observer teardown, not just the store disconnect: an edit on the
        // `YDocument` the app still holds must reach nothing.
        let queued = DocIdSink()
        client.onOutboundQueuedForTest = { queued.append($0) }
        let map: YMap<String> = ydoc.getOrCreateMap(named: "content")
        ydoc.transactSync { txn in
            map.updateValue("post-logout", forKey: "key", transaction: txn)
        }
        await settle()
        XCTAssertTrue(queued.all.isEmpty, "queued: \(queued.all)")
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(docA), 0)
        XCTAssertEqual(try LogoutNote.count(), 0)
    }

    func testPlainLogoutClosesDocumentsHeldPastEvictAllLocal() async throws {
        try await assertLogoutClosesDocumentsHeldPastEvictAllLocal(
            appId: "logout-store-evicted-plain", wipeLocal: false
        )
    }

    func testWipeLocalLogoutClosesDocumentsHeldPastEvictAllLocal() async throws {
        try await assertLogoutClosesDocumentsHeldPastEvictAllLocal(
            appId: "logout-store-evicted-wipe", wipeLocal: true
        )
    }

    // MARK: - Behavior 10: the same user signing back in keeps their creates

    /// The logout drops the in-memory pending-create set while its persisted
    /// records stay on disk (a plain logout wipes nothing). Nothing re-reads
    /// those records for an unchanged user unless the rebind is told to, so
    /// without the reload the same user signing back in — same process, no
    /// relaunch — would leave their offline-created documents silently
    /// uncommitted until the app restarted.
    func testSameUserSignInAfterPlainLogoutRehydratesPendingCreates() async throws {
        let userId = "user-a"
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "logout-store-rehydrate",
            token: makeTestJwt(userId: userId),
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        let storageReady = await client.waitForStorageReady()
        XCTAssertTrue(storageReady)
        XCTAssertEqual(client.documentManager.userId, userId)

        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let (docId, _) = try await client.createDocumentForTest()
        XCTAssertTrue(client.isPendingCreate(docId))

        try await client.logout()
        XCTAssertTrue(
            client.listPendingCreates().isEmpty,
            "the signed-out user's pending create must not survive the logout"
        )

        // The same user signs back in without a relaunch.
        client.updateToken(makeTestJwt(userId: userId))
        await client.rebindUserScopedStorage()

        XCTAssertEqual(
            client.listPendingCreates(), [docId],
            "the persisted pending create must rehydrate for the returning user"
        )
    }

    // MARK: - Edge case: nothing open

    func testLogoutWithNoOpenDocumentsCompletes() async throws {
        let client = makeClient("logout-store-empty")
        defer { Task { await client.destroy() } }

        try await client.logout(wipeLocal: true)

        XCTAssertTrue(client.documentManager.openDocumentsSnapshot().isEmpty)
        XCTAssertEqual(try LogoutNote.count(), 0)
    }

    // MARK: - Edge case: a `retainLocal: false` document is open at logout

    func testLogoutCompletesWithARetainLocalFalseDocumentOpen() async throws {
        let client = makeClient("logout-store-retain-false")
        defer { Task { await client.destroy() } }

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        _ = await client.closeDocument(docId)
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: false, retainLocal: false
        ))
        XCTAssertEqual(client.documentManager.retainLocalSetting(docId), false)

        // The close path's write-confirmation poll is bounded (500 ms) and
        // downgrades to keep-local when unconfirmed; the logout must close
        // the document and return rather than throw or hang.
        let closed = try await collectEvents(from: client.eventEmitter, event: DocumentClosedEvent.self) {
            try await client.logout(wipeLocal: true)
        }

        XCTAssertEqual(closed.map(\.documentId), [docId])
        XCTAssertTrue(client.documentManager.openDocumentsSnapshot().isEmpty)
    }

}

// Mirrors `SwiftEmitter.crossDocumentFacade(schema:)` output — keep in sync
// with the emitter if its template changes.
extension LogoutSharedStoreHermeticTests.LogoutNote {
    static func query(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> [LogoutSharedStoreHermeticTests.LogoutNote] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options)
            .compactMap { LogoutSharedStoreHermeticTests.LogoutNote(row: $0) }
    }

    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    static func findAll() throws -> [LogoutSharedStoreHermeticTests.LogoutNote] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: nil, options: nil)
            .map { row in
                guard let decoded = LogoutSharedStoreHermeticTests.LogoutNote(row: row) else {
                    throw PrimitiveDecodeError(modelName: modelName, row: row)
                }
                return decoded
            }
    }

    static func find(_ id: String) throws -> LogoutSharedStoreHermeticTests.LogoutNote? {
        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {
            return nil
        }
        guard let decoded = LogoutSharedStoreHermeticTests.LogoutNote(row: row) else {
            throw PrimitiveDecodeError(modelName: modelName, row: row)
        }
        return decoded
    }

    @discardableResult
    func save(in documentId: String) throws -> LogoutSharedStoreHermeticTests.LogoutNote {
        try JsBaoClient.requireDefault()
            .codegen.save(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId)
        return self
    }
}
