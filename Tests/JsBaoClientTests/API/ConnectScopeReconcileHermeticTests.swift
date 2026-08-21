import XCTest
@testable import JsBaoClient

/// The whole-scope reconciliation that runs at connect (#2852).
///
/// Eviction used to be a side effect of `documents.list()`: only that method
/// reconciled the local cache authoritatively. `me.ownedDocuments` /
/// `me.sharedDocuments` are strict subsets of the cached scope, so they merge
/// only — right for a subset, but it left an app built on the surfaces both
/// clients steer developers to with no eviction path at all, and the `meta`
/// rows and `yjs_docs` snapshots of documents deleted server-side accumulated
/// launch after launch (#2827 saw a 7.1 MB snapshot survive four days).
///
/// So the reconciliation runs on its own schedule instead: once per connect,
/// at most once per staleness window, walking the paged `GET /documents` to the
/// end of the scope — never reading one response as the whole of it.
///
/// Server-free: a `RecordingTransport` answers the walk and a temp SQLite store
/// holds the local rows.
final class ConnectScopeReconcileHermeticTests: XCTestCase {
    private var tempDir: String!
    /// `DocumentManager.emitter` is `weak`; the test holds the strong ref.
    private var emitter: EventEmitter!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-connectscope-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        emitter = EventEmitter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
        emitter = nil
    }

    // MARK: - Fixture

    private struct Fixture {
        let manager: DocumentManager
        let offline: OfflineStore
        let storage: SQLiteStorageProvider
    }

    private func makeFixture() async throws -> Fixture {
        let dbPath = tempDir + "connectscope-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "connectscope")
        let offline = OfflineStore()
        await offline.setStorageProvider(storage)

        let manager = DocumentManager(logger: Logger(level: .warn, scope: "test"))
        manager.offlineStore = offline
        manager.appId = "test-app"
        manager.userId = "test-user"
        manager.emitter = emitter
        try await offline.ensureMetadataDb(appId: "test-app", userId: "test-user")
        return Fixture(manager: manager, offline: offline, storage: storage)
    }

    private func makeAPI(_ fixture: Fixture, transport: RecordingTransport) -> DocumentsAPI {
        DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            ),
            documentManager: fixture.manager
        )
    }

    private func serverDoc(_ id: String, _ title: String) -> [String: Any] {
        ["documentId": id, "title": title, "permission": "owner"]
    }

    /// A server that answers the paged walk from `pages`, keyed by the incoming
    /// `cursor` (`""` for the first page), and fails any unpaged listing — the
    /// reconciliation must never read one of those as the whole scope.
    private static func walkServer(pages: [String: String]) -> RecordingTransport {
        RecordingTransport(responder: { call in
            func json(_ body: String) -> TransportResponse {
                TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
            guard call.path.contains("limit=") else {
                XCTFail("the reconciliation asked an unpaged listing: \(call.path)")
                return json("[]")
            }
            let cursor = Self.cursorParam(of: call.path) ?? ""
            guard let page = pages[cursor] else {
                XCTFail("the walk asked for an unexpected cursor: \(call.path)")
                return json(#"{"items":[],"hasMore":false}"#)
            }
            return json(page)
        })
    }

    private static func cursorParam(of path: String) -> String? {
        URLComponents(string: "https://example.test\(path)")?
            .queryItems?
            .first(where: { $0.name == "cursor" })?
            .value
    }

    private static let liveOnlyPage = """
    {"items":[{"documentId":"doc-live","title":"Still mine","permission":"owner"}],"hasMore":false}
    """

    private func seedYjsRow(_ storage: SQLiteStorageProvider, documentId: String) async throws {
        let persistence = YjsSQLitePersistence(storageProvider: storage, documentId: documentId)
        try await persistence.saveDocument(data: Data([1, 2, 3, 4]))
    }

    private func yjsRow(_ storage: SQLiteStorageProvider, documentId: String) async throws -> Data? {
        let record: StorageRecord<Data>? = try await storage.get(
            store: YjsSQLitePersistence.store, key: documentId
        )
        return record?.value
    }

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DocumentMetadataChangedEvent] = []
        func record(_ event: DocumentMetadataChangedEvent) {
            lock.withLock { events.append(event) }
        }
        var all: [DocumentMetadataChangedEvent] { lock.withLock { events } }
    }

    // MARK: - The reconciliation evicts without any listing call

    func test_connectReconciliationEvictsWhatTheServerNoLongerLists() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-live", "Still mine"),
            serverDoc("doc-deleted", "Deleted server-side"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-deleted")

        let sink = EventSink()
        let sub = emitter.subscribe(DocumentMetadataChangedEvent.self) { sink.record($0) }
        defer { sub.cancel() }

        let transport = Self.walkServer(pages: ["": Self.liveOnlyPage])
        let api = makeAPI(fixture, transport: transport)

        // No `documents.list()` anywhere: this is what an app on
        // `me.ownedDocuments` / `me.sharedDocuments` gets.
        await api.reconcileScopeAtConnect()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-live"),
            "a listed document stays cached"
        )
        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-deleted"),
            "a cached document the walked scope omits must be evicted (#2852)"
        )
        let persisted = try await fixture.offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: "doc-deleted"
        )
        XCTAssertNil(persisted, "the `meta` row must leave the device")
        let snapshot = try await yjsRow(fixture.storage, documentId: "doc-deleted")
        XCTAssertNil(snapshot, "the `yjs_docs` CRDT snapshot must leave the device")

        let deleted = try XCTUnwrap(
            sink.all.first { $0.documentId == "doc-deleted" && $0.action == "deleted" },
            "the app must be notified so open state can be torn down"
        )
        XCTAssertNil(deleted.metadata)
    }

    /// The scope is what the walk read to the end, not what one page said.
    func test_connectReconciliationFollowsTheCursorToTheEndOfTheScope() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the first page"),
            serverDoc("doc-b", "Past the truncation point"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-b")

        let transport = Self.walkServer(pages: [
            "": """
            {"items":[{"documentId":"doc-a","title":"On the first page","permission":"owner"}],\
            "hasMore":true,"nextCursor":"page-2","cursor":"page-2"}
            """,
            "page-2": """
            {"items":[{"documentId":"doc-b","title":"Past the truncation point","permission":"owner"}],\
            "hasMore":false}
            """,
        ])
        let api = makeAPI(fixture, transport: transport)

        await api.reconcileScopeAtConnect()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-b"),
            "a document past the first page is not one the server dropped"
        )
        let keptSnapshot = try await yjsRow(fixture.storage, documentId: "doc-b")
        XCTAssertNotNil(keptSnapshot)
        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "a document absent from the walked scope is evicted"
        )
        XCTAssertEqual(
            transport.calls.count, 2, "the walk pays one request per page, and no more"
        )
    }

    /// Nothing cached, nothing an eviction could remove — so the walk is not
    /// worth a single request.
    func test_connectReconciliationIssuesNoRequestWhenNothingIsCached() async throws {
        let fixture = try await makeFixture()
        let transport = Self.walkServer(pages: ["": Self.liveOnlyPage])
        let api = makeAPI(fixture, transport: transport)

        await api.reconcileScopeAtConnect()

        XCTAssertEqual(transport.calls.count, 0)
    }

    // MARK: - A completed walk that found nothing at all evicts nothing

    /// The one response shape that is well-formed and still means "delete
    /// everything": a completed walk whose union is empty (#2859). The walk
    /// asks `includeRoot=true`, so a correct answer carries at least the
    /// caller's root — zero rows is anomalous, not a user with no documents,
    /// and local data that never synced is not re-downloadable.
    func test_aCompletedWalkThatReturnedZeroDocumentsEvictsNothing() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-cached", "Cached before the walk"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-cached")

        let sink = EventSink()
        let sub = emitter.subscribe(DocumentMetadataChangedEvent.self) { sink.record($0) }
        defer { sub.cancel() }

        let transport = Self.walkServer(pages: ["": #"{"items":[],"hasMore":false}"#])
        let api = makeAPI(fixture, transport: transport)

        await api.reconcileScopeAtConnect()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-cached"),
            "a zero-row page is not the server saying the whole scope is gone"
        )
        let persisted = try await fixture.offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: "doc-cached"
        )
        XCTAssertNotNil(persisted, "the `meta` row stays on the device")
        let snapshot = try await yjsRow(fixture.storage, documentId: "doc-cached")
        XCTAssertNotNil(
            snapshot,
            "and so does the CRDT snapshot, which may hold unsynced offline edits"
        )
        XCTAssertNil(
            sink.all.first { $0.documentId == "doc-cached" && $0.action == "deleted" },
            "and the app must not be told a document it still has was deleted"
        )
    }

    /// Zero rows and an empty scope are different cases. A user whose documents
    /// really were all deleted server-side still has a root, so their walk comes
    /// back with exactly one item — and that page is authoritative about the
    /// rest of the cache.
    func test_aRootOnlyPageStillEvictsEveryOtherCachedDocument() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-root", "Root"),
            serverDoc("doc-deleted", "Deleted server-side"),
        ])

        let transport = Self.walkServer(pages: ["": """
        {"items":[{"documentId":"doc-root","title":"Root","permission":"owner"}],"hasMore":false}
        """])
        let api = makeAPI(fixture, transport: transport)

        await api.reconcileScopeAtConnect()

        XCTAssertNotNil(fixture.manager.getLocalMetadata("doc-root"))
        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-deleted"),
            "a root-only page means the user's documents really are all gone"
        )
    }

    // MARK: - A walk it could not finish evicts nothing

    /// Each of these is a scope the client could not read to the end, so its
    /// silence about a cached document proves nothing. The bare array is the
    /// live defect: the unpaged `GET /documents` is silently truncated at
    /// dynamo-bao's 100-row `defaultQueryLimit`, so a server that ignores
    /// `limit` answers a walk request with a prefix that looks complete.
    func test_connectReconciliationEvictsNothingFromAWalkItCouldNotFinish() async throws {
        let incomplete: [(String, RecordingTransport)] = [
            (
                "a bare array (the server ignored `limit`)",
                RecordingTransport(json: #"[{"documentId":"doc-live","title":"Still mine","permission":"owner"}]"#)
            ),
            (
                "a page that claims more rows with no cursor to ask for them",
                RecordingTransport(json: #"{"items":[{"documentId":"doc-live","title":"Still mine","permission":"owner"}],"hasMore":true}"#)
            ),
            (
                "a body that is not a page of this scope",
                RecordingTransport(json: #"{"error":"nope"}"#)
            ),
            (
                "a failed request",
                RecordingTransport(status: 503, json: #"{"error":"unavailable"}"#)
            ),
            (
                "a cursor that stops advancing",
                RecordingTransport(json: #"{"items":[],"hasMore":true,"nextCursor":"stuck"}"#)
            ),
        ]

        for (label, transport) in incomplete {
            let fixture = try await makeFixture()
            await fixture.manager.handleServerDocuments([
                serverDoc("doc-absent", "Absent from this answer"),
            ])
            let api = makeAPI(fixture, transport: transport)

            await api.reconcileScopeAtConnect()

            XCTAssertNotNil(
                fixture.manager.getLocalMetadata("doc-absent"),
                "\(label) must not evict"
            )
        }
    }

    // MARK: - Its own schedule, not the listing's

    func test_reconciliationRunsAtMostOncePerStalenessWindow() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-live", "Still mine"),
            serverDoc("doc-deleted", "Deleted server-side"),
        ])

        let transport = Self.walkServer(pages: ["": Self.liveOnlyPage])
        let api = makeAPI(fixture, transport: transport)

        await api.reconcileScopeAtConnect()
        let afterFirstConnect = transport.calls.count
        XCTAssertGreaterThan(afterFirstConnect, 0)

        // A reconnect inside the window must not pay for the walk again.
        await api.reconcileScopeAtConnect()
        XCTAssertEqual(transport.calls.count, afterFirstConnect)
    }

    /// The window is spent on one user's scope. Sign a different user in and
    /// their cache — never reconciled against their own scope — must not be
    /// skipped because the previous session walked recently.
    func test_anAccountSwitchReArmsTheReconciliation() async throws {
        let client = makeHermeticClient()
        defer { Task { await client.destroy() } }

        await client.documentManager.handleServerDocuments([
            serverDoc("doc-live", "Still mine"),
        ])
        let transport = Self.walkServer(pages: ["": Self.liveOnlyPage])
        client._documents = makeClientAPI(client, transport: transport)

        await client.documents.reconcileScopeAtConnect()
        let afterUserA = transport.calls.count
        XCTAssertGreaterThan(afterUserA, 0)

        client.authController.applyToken(
            Self.jwt(userId: "user-b"),
            previous: Self.jwt(userId: "user-a"),
            cause: "oauthCallback"
        )
        // The applied-token handler does its work off the caller's thread.
        try await Task.sleep(nanoseconds: 200_000_000)

        await client.documentManager.handleServerDocuments([
            serverDoc("doc-b-deleted", "Deleted while B was away"),
        ])
        await client.documents.reconcileScopeAtConnect()

        XCTAssertGreaterThan(
            transport.calls.count,
            afterUserA,
            "the next user's first connect must walk their own scope (#2852)"
        )
        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-b-deleted"),
            "and evict what that walk did not find"
        )
    }

    /// The union decides who to evict, but evicting them is asynchronous and
    /// runs document by document. A confirmation reaching a document still
    /// waiting its turn is the server saying it is alive, and the decision
    /// taken before that confirmation must not outlive it.
    func test_aConfirmationAfterTheDecisionCancelsThatDocumentsEviction() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-confirmed", "Cached before the walk"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-confirmed")

        let candidates = fixture.manager.evictionCandidateSnapshot(seenIds: [])
        let candidate = try XCTUnwrap(candidates.first { $0.documentId == "doc-confirmed" })

        // The server confirms it after the walk decided to evict it.
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-confirmed", "Renamed by another client"),
        ])

        let evicted = await fixture.manager.evictLocalData(
            documentId: "doc-confirmed", ifUnconfirmedSince: candidate
        )

        XCTAssertFalse(evicted, "a stale decision must report that it evicted nothing")
        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-confirmed"),
            "the row the confirmation wrote must survive"
        )
        let snapshot = try await yjsRow(fixture.storage, documentId: "doc-confirmed")
        XCTAssertNotNil(snapshot, "and so must its CRDT snapshot")
    }

    /// Signing out and back in as somebody else is the ordinary account
    /// switch, and the token-change handler never sees both identities: the
    /// sign-out clears the token without telling it, so the sign-in arrives
    /// with no previous user to compare against. The new user's cache must
    /// still be reconciled rather than skipped on the window the previous
    /// account spent.
    func test_signingOutAndBackInAsAnotherUserReArmsTheReconciliation() async throws {
        let client = makeHermeticClient()
        defer { Task { await client.destroy() } }

        let transport = Self.walkServer(pages: ["": Self.liveOnlyPage])
        client._documents = makeClientAPI(client, transport: transport)

        client.authController.applyToken(
            Self.jwt(userId: "user-a"), previous: nil, cause: "oauthCallback"
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        await client.documentManager.handleServerDocuments([
            serverDoc("doc-live", "Still mine"),
        ])
        await client.documents.reconcileScopeAtConnect()
        let afterUserA = transport.calls.count
        XCTAssertGreaterThan(afterUserA, 0)

        // Sign out, then sign in as somebody else.
        client.authController.applyToken(nil, previous: Self.jwt(userId: "user-a"), cause: "logout")
        client.authController.applyToken(
            Self.jwt(userId: "user-b"), previous: nil, cause: "oauthCallback"
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        await client.documentManager.handleServerDocuments([
            serverDoc("doc-b-deleted", "Deleted while B was away"),
        ])
        await client.documents.reconcileScopeAtConnect()

        XCTAssertGreaterThan(
            transport.calls.count,
            afterUserA,
            "B's first connect must walk their own scope, not inherit A's window (#2852)"
        )
        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-b-deleted"),
            "and evict what that walk did not find"
        )
    }

    /// A walk the account switch overtook belongs to the previous user: its
    /// pages were fetched for that scope, so merging them authoritatively would
    /// write one account's documents into another's cache — and stamping the
    /// window on its way out would skip the new user's own reconciliation.
    func test_aWalkOvertakenByAnAccountSwitchNeitherAppliesNorSchedules() async throws {
        let client = makeHermeticClient()
        defer { Task { await client.destroy() } }

        await client.documentManager.handleServerDocuments([
            serverDoc("doc-a-only", "User A's document"),
        ])

        // The first page hangs until the test releases it; by then a different
        // user has signed in.
        let released = AsyncGate()
        let transport = RecordingTransport(responder: { call in
            func json(_ body: String) -> TransportResponse {
                TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
            if call.path.contains("cursor=") { return json(#"{"items":[],"hasMore":false}"#) }
            if await released.isOpen {
                // B's own walk: their scope has only their live document.
                return json("""
                {"items":[{"documentId":"doc-b-live","title":"B's","permission":"owner"}],\
                "hasMore":false}
                """)
            }
            await released.wait()
            // A's scope, answered long after A stopped being the signed-in user.
            return json("""
            {"items":[{"documentId":"doc-a-only","title":"User A's document","permission":"owner"}],\
            "hasMore":false}
            """)
        })
        client._documents = makeClientAPI(client, transport: transport)

        let walk = Task { await client.documents.reconcileScopeAtConnect() }
        for _ in 0..<100 where transport.calls.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.calls.count, 1, "the walk is in flight")

        client.authController.applyToken(
            Self.jwt(userId: "user-b"),
            previous: Self.jwt(userId: "user-a"),
            cause: "oauthCallback"
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        // B's cache, as their session restored it.
        await client.documentManager.evictAllLocalData()
        await client.documentManager.handleServerDocuments([
            serverDoc("doc-b-live", "B's"),
            serverDoc("doc-b-deleted", "Deleted while B was away"),
        ])

        await released.open()
        await walk.value

        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-a-only"),
            "the previous account's scope must not be merged into this one's cache"
        )

        await client.documents.reconcileScopeAtConnect()
        XCTAssertGreaterThan(
            transport.calls.count, 1, "B's own connect must still walk B's scope"
        )
        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-b-live"))
        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-b-deleted"),
            "and that walk is what evicts for B"
        )
    }

    /// A one-shot gate the scripted transport can wait on.
    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isOpen: Bool { opened }

        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Structurally a JWT, so the client reads a `userId` out of it and can
    /// tell one user's token from another's.
    private static func jwt(userId: String) -> String {
        let payload = #"{"userId":"\#(userId)","sub":"\#(userId)"}"#
        let body = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(body).notverified"
    }

    private func makeHermeticClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            // A dead port: nothing here reaches a server.
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "connect-scope-reconcile-app",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    private func makeClientAPI(
        _ client: JsBaoClient,
        transport: RecordingTransport
    ) -> DocumentsAPI {
        DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            ),
            documentManager: client.documentManager,
            client: client
        )
    }

    // MARK: - The connect handler is what runs it

    func test_theConnectHandlerRunsTheReconciliation() async throws {
        let client = makeHermeticClient()
        defer { Task { await client.destroy() } }

        await client.documentManager.handleServerDocuments([
            serverDoc("doc-live", "Still mine"),
            serverDoc("doc-deleted", "Deleted server-side"),
        ])

        let transport = Self.walkServer(pages: ["": Self.liveOnlyPage])
        client._documents = makeClientAPI(client, transport: transport)

        client.webSocketManagerOnConnected()

        // The connect handler does its work off the caller's thread.
        for _ in 0..<100 {
            if client.documentManager.getLocalMetadata("doc-deleted") == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-deleted"),
            "connecting must reconcile the scope, with no listing call to trigger it (#2852)"
        )
        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-live"))
    }
}
