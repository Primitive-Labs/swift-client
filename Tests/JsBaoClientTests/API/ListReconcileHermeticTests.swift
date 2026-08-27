import XCTest
@testable import JsBaoClient

/// `documents.list()` reconciles the server listing into the local metadata
/// cache, the way js-bao's `documentsApi.ts` does through
/// `reconcileFromResponse` → `syncMetadata({ scope: "all", authoritative })`.
///
/// Without that reconciliation a document deleted server-side (or one whose
/// access was revoked) keeps its `yjs_docs` snapshot and `meta` row on the
/// device forever — issue #2827 saw a 7.1 MB doc survive four days of
/// launches that synced normally.
///
/// Server-free: a `RecordingTransport` answers the listing and a temp SQLite
/// store holds the local rows.
final class ListReconcileHermeticTests: XCTestCase {
    private var tempDir: String!
    /// `DocumentManager.emitter` is `weak`; the test holds the strong ref.
    private var emitter: EventEmitter!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-listreconcile-\(UUID().uuidString.prefix(8))/"
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
        let dbPath = tempDir + "listreconcile-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "listreconcile")
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

    /// What an unpaged `GET /documents` returns: a bare array (#858).
    private static let liveOnlyListing =
        #"[{"documentId":"doc-live","title":"Still mine","permission":"owner"}]"#

    /// The same listing as the paged endpoint returns it, saying it is the
    /// whole scope.
    private static let liveOnlyPage = """
    {"items":[{"documentId":"doc-live","title":"Still mine","permission":"owner"}],"hasMore":false}
    """

    /// The same listing plus the app root, which the server returns and the
    /// client filters out by default.
    private static let listingWithRoot = """
    [{"documentId":"doc-live","title":"Still mine","permission":"owner"},\
    {"documentId":"root-doc","title":"Root","permission":"read-write","tags":["__ROOT_TAG__"]}]
    """

    private static let pageWithRoot = """
    {"items":[{"documentId":"doc-live","title":"Still mine","permission":"owner"},\
    {"documentId":"root-doc","title":"Root","permission":"read-write","tags":["__ROOT_TAG__"]}],\
    "hasMore":false}
    """

    /// A server that answers the unpaged `GET /documents` with `unpaged` and a
    /// paged request (`limit=…`) from `pages`, keyed by the incoming `cursor`
    /// (`""` for the first page).
    ///
    /// That split is what the deployed server does: the unpaged branch returns
    /// a bare array and throws its `lastEvaluatedKey` away, while any paging
    /// param returns the `{ items, hasMore, nextCursor }` envelope
    /// (`src/app-api/controllers/documents-controller.ts`).
    private static func pagedServer(
        unpaged: String,
        pages: [String: String]
    ) -> RecordingTransport {
        RecordingTransport(responder: { call in
            func json(_ body: String) -> TransportResponse {
                TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
            guard call.path.contains("limit=") else { return json(unpaged) }
            let cursor = Self.cursorParam(of: call.path) ?? ""
            guard let page = pages[cursor] else {
                XCTFail("walk asked for an unexpected cursor: \(call.path)")
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

    /// The unpaged listing a user with more documents than the server's
    /// default query limit gets: a strict prefix of what they own, with
    /// nothing in the body to say so.
    private static let truncatedListing =
        #"[{"documentId":"doc-a","title":"On the truncated first page","permission":"owner"}]"#

    /// The same first page as the paged endpoint returns it — the envelope
    /// that does say more rows remain.
    private static let walkPageOne = """
    {"items":[{"documentId":"doc-a","title":"On the truncated first page","permission":"owner"}],\
    "hasMore":true,"nextCursor":"page-2","cursor":"page-2"}
    """

    private static let walkPageTwo = """
    {"items":[{"documentId":"doc-b","title":"Past the truncation point","permission":"owner"}],\
    "hasMore":false}
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

    // MARK: - Behavior 1: an unpaged listing is authoritative

    func test_unpagedListEvictsTheDocumentTheServerNoLongerLists() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-live", "Still mine"),
            serverDoc("doc-deleted", "Deleted server-side"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-deleted")

        let sink = EventSink()
        let sub = emitter.subscribe(DocumentMetadataChangedEvent.self) { sink.record($0) }
        defer { sub.cancel() }

        let api = makeAPI(fixture, transport: Self.pagedServer(
            unpaged: Self.liveOnlyListing,
            pages: ["": Self.liveOnlyPage]
        ))
        let page = try await api._listImpl()

        XCTAssertEqual(page.items.map { $0.documentId }, ["doc-live"])
        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-live"),
            "a listed document stays cached"
        )
        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-deleted"),
            "a cached document the authoritative listing omits must be evicted (#2827)"
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

    // MARK: - Behavior 2: a paged or filtered listing is upsert-only

    /// A limit, a cursor, a tag filter, `forward`, or the page-returning form
    /// each make the response a subset of the cached scope — its absences
    /// prove nothing, so it may not evict (js-bao's `!isPaged` rule).
    func test_pagedOrFilteredListingNeverEvicts() async throws {
        let fixture = try await makeFixture()
        let api = makeAPI(fixture, transport: RecordingTransport(json: Self.liveOnlyListing))

        let pagedForms: [(String, ListDocumentsOptions?, Bool)] = [
            ("limit", ListDocumentsOptions(limit: 10), false),
            ("cursor", ListDocumentsOptions(cursor: "next-page"), false),
            ("tag", ListDocumentsOptions(tag: "starred"), false),
            ("forward", ListDocumentsOptions(forward: true), false),
            ("listPage", nil, true),
        ]

        for (label, options, returnPage) in pagedForms {
            await fixture.manager.handleServerDocuments([
                serverDoc("doc-absent", "Cached, not on this page"),
            ])
            _ = try await api._listImpl(options: options, returnPage: returnPage)
            XCTAssertNotNil(
                fixture.manager.getLocalMetadata("doc-absent"),
                "a \(label) listing is a subset of the scope and must not evict"
            )
        }
    }

    // MARK: - Behavior 3: the root document the listing filters out is retained

    func test_authoritativeListingRetainsTheRootItFiltersOut() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("root-doc", "Root"),
            serverDoc("doc-deleted", "Deleted server-side"),
        ])

        let api = makeAPI(fixture, transport: Self.pagedServer(
            unpaged: Self.listingWithRoot,
            pages: ["": Self.pageWithRoot]
        ))
        let page = try await api._listImpl()

        XCTAssertFalse(
            page.items.contains { $0.documentId == "root-doc" },
            "the default listing still filters the root out of its result"
        )
        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("root-doc"),
            "the root is filtered from the result, not deleted from the device"
        )
        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-deleted"),
            "retaining the root must not disarm eviction for everything else"
        )
    }

    // MARK: - Behavior 4: a truncated listing is not the whole scope

    /// The unpaged `GET /documents` is silently truncated at dynamo-bao's
    /// `defaultQueryLimit` of 100 rows, and the controller returns a bare array
    /// with no cursor and no `hasMore` — so a truncated response and a complete
    /// one are the same bytes. Reading the caller's own response as the whole
    /// scope therefore deletes real local data for anyone with more than 100
    /// documents.
    ///
    /// Eviction must instead run against a scope the client walked to
    /// exhaustion through the paged envelope, which does carry a cursor.
    func test_truncatedListingDoesNotEvictTheRowsItOmits() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-b", "Past the truncation point"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-b")
        try await seedYjsRow(fixture.storage, documentId: "doc-gone")

        let api = makeAPI(fixture, transport: Self.pagedServer(
            unpaged: Self.truncatedListing,
            pages: ["": Self.walkPageOne, "page-2": Self.walkPageTwo]
        ))
        _ = try await api._listImpl()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-b"),
            "a document the truncated response omitted is not deleted server-side"
        )
        let persisted = try await fixture.offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: "doc-b"
        )
        XCTAssertNotNil(persisted, "its `meta` row must stay on the device")
        let snapshot = try await yjsRow(fixture.storage, documentId: "doc-b")
        XCTAssertNotNil(snapshot, "its `yjs_docs` CRDT snapshot must stay on the device")

        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "a document absent from the walked scope is still evicted (#2827)"
        )
        let evictedSnapshot = try await yjsRow(fixture.storage, documentId: "doc-gone")
        XCTAssertNil(
            evictedSnapshot,
            "the evicted document's CRDT snapshot must leave the device"
        )
    }

    /// A walk that cannot be finished proves nothing about the scope, so it
    /// evicts nothing — the listing the caller got is merged and that is all.
    func test_aWalkThatFailsMidwayEvictsNothing() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-b", "Past the truncation point"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])

        let transport = RecordingTransport(responder: { call in
            let unpaged = TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(Self.truncatedListing.utf8)
            )
            guard call.path.contains("limit=") else { return unpaged }
            return TransportResponse(status: 503, headers: [:], body: Data("{}".utf8))
        })
        let page = try await makeAPI(fixture, transport: transport)._listImpl()

        XCTAssertEqual(page.items.map { $0.documentId }, ["doc-a"], "the caller still gets its listing")
        for documentId in ["doc-b", "doc-gone"] {
            XCTAssertNotNil(
                fixture.manager.getLocalMetadata(documentId),
                "an unfinished walk must not evict \(documentId)"
            )
        }
    }

    /// A server old enough to ignore `limit` answers the walk with the same
    /// bare array — which carries no end-of-scope signal, so it cannot
    /// authorize an eviction either.
    func test_aServerThatIgnoresLimitEvictsNothing() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])

        let api = makeAPI(fixture, transport: RecordingTransport(json: Self.truncatedListing))
        _ = try await api._listImpl()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "a bare array answers `limit` without saying whether it is complete"
        )
    }

    // MARK: - Behavior 5: the walk may only evict what it set out to check

    /// The walk spans several round trips. A document that arrives in the cache
    /// while it runs — a share granted, a `docMetadata` frame, a create landing
    /// — can be genuinely absent from the union because its page had already
    /// gone by, and deleting it would take a document the user still has access
    /// to (plus its CRDT snapshot) off the device.
    ///
    /// So eviction is bounded to the candidates captured before the first
    /// request, still carrying the metadata they had then: a newcomer and a
    /// candidate the server re-confirms mid-walk both survive, while the
    /// document that really is gone is still evicted.
    func test_aDocumentThatArrivesDuringTheWalkIsNotEvicted() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-reconfirmed", "Confirmed again mid-walk"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-arrived")

        let manager = fixture.manager
        let transport = RecordingTransport(responder: { call in
            func json(_ body: String) -> TransportResponse {
                TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
            guard call.path.contains("limit=") else { return json(Self.truncatedListing) }
            guard Self.cursorParam(of: call.path) == "page-2" else { return json(Self.walkPageOne) }
            // Between the two pages: one document enters the cache and one
            // existing candidate is re-confirmed by the server. Neither shows
            // up in the union the walk is assembling.
            await manager.applyDocumentMetadataUpdate(
                documentId: "doc-arrived",
                metadata: ["title": .string("Shared with me mid-walk")]
            )
            await manager.applyDocumentMetadataUpdate(
                documentId: "doc-reconfirmed",
                metadata: ["title": .string("Confirmed again mid-walk")]
            )
            return json(Self.walkPageTwo)
        })
        _ = try await makeAPI(fixture, transport: transport)._listImpl()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-arrived"),
            "a document cached after the walk started was never in its scope question"
        )
        let arrivedSnapshot = try await yjsRow(fixture.storage, documentId: "doc-arrived")
        XCTAssertNotNil(arrivedSnapshot, "and its CRDT snapshot must stay on the device")
        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-reconfirmed"),
            "the server confirmed this one exists while the walk was in flight"
        )
        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "the document that really is absent from the walked scope is still evicted"
        )
    }

    // MARK: - Behavior 6: only a complete, coherent envelope ends the walk

    /// A page that says more rows remain but hands back no cursor leaves the
    /// walk with no way to reach the rest of the scope, so it has not read the
    /// scope — whatever it omitted stays.
    func test_aPageThatSaysMoreRemainWithoutACursorEvictsNothing() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])

        let api = makeAPI(fixture, transport: Self.pagedServer(
            unpaged: Self.truncatedListing,
            pages: ["": """
            {"items":[{"documentId":"doc-a","title":"On the truncated first page",\
            "permission":"owner"}],"hasMore":true}
            """]
        ))
        _ = try await api._listImpl()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "`hasMore` with no cursor is an unfinished walk, not an empty tail"
        )
    }

    /// A body that never mentioned `items` (or the legacy `documents`) decodes
    /// to an empty page. Reading that as "the server lists nothing" would wipe
    /// every cached document and every CRDT snapshot with it.
    func test_aBodyThatListsNoItemsKeyEvictsNothing() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])
        try await seedYjsRow(fixture.storage, documentId: "doc-gone")

        let api = makeAPI(fixture, transport: Self.pagedServer(
            unpaged: Self.truncatedListing,
            pages: ["": #"{"hasMore":false}"#]
        ))
        _ = try await api._listImpl()

        for documentId in ["doc-a", "doc-gone"] {
            XCTAssertNotNil(
                fixture.manager.getLocalMetadata(documentId),
                "a body with no items key says nothing about \(documentId)"
            )
        }
        let goneSnapshot = try await yjsRow(fixture.storage, documentId: "doc-gone")
        XCTAssertNotNil(goneSnapshot, "and no CRDT snapshot may be dropped on the strength of it")
    }

    // MARK: - Behavior 7: the cache must be loaded before its gaps mean anything

    /// `documents.list()` at launch races `setupStorage()`: until the persisted
    /// `meta` rows are back in the index, "which cached documents did this
    /// listing omit?" answers *none* — and the server-deleted row would be
    /// restored from disk moments later, exactly the leak #2827 reports.
    ///
    /// So the reconciliation waits for that load, and a wait that does not
    /// complete merges without evicting rather than evicting blindly.
    func test_aListingBeforeTheLocalMetadataIsLoadedEvictsNothing() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.handleServerDocuments([
            serverDoc("doc-a", "On the truncated first page"),
            serverDoc("doc-gone", "Deleted server-side"),
        ])

        let api = makeAPI(fixture, transport: Self.pagedServer(
            unpaged: Self.truncatedListing,
            pages: ["": Self.walkPageOne, "page-2": Self.walkPageTwo]
        ))
        api.setStorageReadyGate { false }
        _ = try await api._listImpl()

        XCTAssertNotNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "an index that has not finished loading cannot say what the server dropped"
        )

        // Storage settles; the next whole-scope listing reconciles for real.
        api.setStorageReadyGate { true }
        _ = try await api._listImpl()

        XCTAssertNil(
            fixture.manager.getLocalMetadata("doc-gone"),
            "once the local metadata is loaded the walk evicts as it should (#2827)"
        )
    }
}
