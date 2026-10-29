import XCTest
@testable import JsBaoClient

/// A whole-scope `syncMetadata` lists what js-bao lists (#4830): the server
/// removed the legacy `GET /documents` union list, so the scope is
/// `GET /me/owned-documents` plus `GET /me/shared-documents`, each walked to
/// exhaustion, concatenated and deduplicated by id, and merged
/// authoritatively — a cached document neither list returns is evicted.
///
/// JS is the reference (`syncMetadata` in `src/client/JsBaoClient.ts`).
///
/// Server-free (`*HermeticTests`): a `LoopbackAPIServer` answers the client's
/// real HTTP requests, so the path under test is the shipped one.
final class SyncMetadataWholeScopeHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var servers: [LoopbackAPIServer] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for server in servers { server.stop() }
        servers = []
    }

    // MARK: - Fixture

    private func makeClient(
        token: String = "test-token",
        _ responder: @escaping @Sendable (LoopbackAPIServer.Request) -> LoopbackAPIServer.Response
    ) throws -> (JsBaoClient, LoopbackAPIServer) {
        let server = try LoopbackAPIServer(responder: responder)
        let baseUrl = try server.start()
        servers.append(server)

        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl,
            // Nothing in these tests needs a socket.
            wsUrl: "ws://127.0.0.1:1",
            appId: "sync-metadata-whole-scope-app",
            token: token,
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        return (client, server)
    }

    /// A server whose two lists answer from `owned` and `shared`, each a list
    /// of pages keyed by the cursor that asks for them (`nil` for the first).
    /// Everything else is a 404.
    private func makeClient(
        token: String = "test-token",
        owned: [String?: String],
        shared: [String?: String],
        onRequest: @escaping @Sendable (LoopbackAPIServer.Request) -> Void = { _ in }
    ) throws -> (JsBaoClient, LoopbackAPIServer) {
        try makeClient(token: token) { request in
            onRequest(request)
            let pages: [String?: String]
            switch request.apiPathOnly {
            case "/me/owned-documents": pages = owned
            case "/me/shared-documents": pages = shared
            default: return .status(404, "unscripted path \(request.apiPathOnly)")
            }
            let cursor = Self.query(request, "cursor")
            guard let page = pages[cursor] else {
                return .status(400, "unscripted cursor \(cursor ?? "<none>")")
            }
            return .json(page)
        }
    }

    private static func query(_ request: LoopbackAPIServer.Request, _ name: String) -> String? {
        URLComponents(string: request.apiPath)?.queryItems?.first { $0.name == name }?.value
    }

    private static func row(_ id: String, _ title: String, _ permission: String = "owner") -> String {
        #"{"documentId":"\#(id)","title":"\#(title)","permission":"\#(permission)"}"#
    }

    /// One page of the `{ items, hasMore, nextCursor }` envelope both lists answer.
    private static func page(_ rows: [String], next: String? = nil) -> String {
        let cursor = next.map { #","nextCursor":"\#($0)""# } ?? ""
        return #"{"items":[\#(rows.joined(separator: ","))],"hasMore":\#(next != nil)\#(cursor)}"#
    }

    private static let emptyPage = page([])

    private func seedLocal(_ client: JsBaoClient, _ id: String, _ title: String) async {
        await client.documentManager.handleServerDocuments([
            ["documentId": id, "title": title, "permission": "read-write"]
        ])
    }

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DocumentMetadataChangedEvent] = []
        func record(_ event: DocumentMetadataChangedEvent) {
            lock.withLock { events.append(event) }
        }
        var all: [DocumentMetadataChangedEvent] { lock.withLock { events } }
        func deleted(_ documentId: String) -> DocumentMetadataChangedEvent? {
            all.first { $0.documentId == documentId && $0.action == "deleted" }
        }
        func updates(_ documentId: String) -> Int {
            all.filter { $0.documentId == documentId && $0.action == "updated" }.count
        }
    }

    private func sink(_ client: JsBaoClient) -> (EventSink, EventSubscription) {
        let sink = EventSink()
        let subscription = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) {
            sink.record($0)
        }
        return (sink, subscription)
    }

    /// Lets a scripted response reach the client that is waiting for it.
    private final class ClientBox: @unchecked Sendable {
        private let lock = NSLock()
        private var client: JsBaoClient?
        func hold(_ client: JsBaoClient) { lock.withLock { self.client = client } }

        /// What a `docMetadata` frame confirming the document ends in: a
        /// metadata write, which stamps the row as freshly confirmed.
        func confirm(_ documentId: String, title: String) {
            guard let client = lock.withLock({ self.client }),
                  var entry = client.documentManager.getLocalMetadata(documentId)
            else { return }
            entry.title = title
            client.documentManager.setMetadata(documentId, entry: entry)
        }
    }

    // MARK: - Behaviours

    func test_wholeScopeSync_listsOwnedAndSharedAndEvictsWhatNeitherReturns() async throws {
        let (client, server) = try makeClient(
            owned: [nil: Self.page([Self.row("doc-owned", "Mine")])],
            shared: [nil: Self.page([Self.row("doc-shared", "Theirs", "reader")])]
        )
        await seedLocal(client, "doc-stale", "Deleted while offline")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata()

        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-owned")?.title, "Mine")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-shared")?.title, "Theirs")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-shared")?.permission, "reader")
        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-stale"),
            "a cached document neither list returns must be evicted"
        )
        XCTAssertNotNil(events.deleted("doc-stale"))
        let listed = server.requests.map(\.apiPathOnly)
        XCTAssertTrue(listed.contains("/me/owned-documents"), "saw \(listed)")
        XCTAssertTrue(listed.contains("/me/shared-documents"), "saw \(listed)")
        XCTAssertFalse(listed.contains("/documents"), "the legacy union list is gone; saw \(listed)")
    }

    func test_wholeScopeSync_walksEachListToExhaustion() async throws {
        let (client, server) = try makeClient(
            owned: [
                nil: Self.page([Self.row("doc-owned-1", "Owned one")], next: "owned-2"),
                "owned-2": Self.page([Self.row("doc-owned-2", "Owned two")]),
            ],
            shared: [
                nil: Self.page([Self.row("doc-shared-1", "Shared one", "reader")], next: "shared-2"),
                "shared-2": Self.page([Self.row("doc-shared-2", "Shared two", "reader")]),
            ]
        )
        await seedLocal(client, "doc-owned-2", "On the owned list's second page")
        await seedLocal(client, "doc-shared-2", "On the shared list's second page")
        await seedLocal(client, "doc-stale", "Deleted while offline")

        try await client.syncMetadata()

        for id in ["doc-owned-1", "doc-owned-2", "doc-shared-1", "doc-shared-2"] {
            XCTAssertNotNil(client.documentManager.getLocalMetadata(id), "\(id) was listed")
        }
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-owned-2")?.title, "Owned two")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-shared-2")?.title, "Shared two")
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-stale"))
        let cursors = server.requests.map { "\($0.apiPathOnly) \(Self.query($0, "cursor") ?? "-")" }
        XCTAssertEqual(cursors, [
            "/me/owned-documents -",
            "/me/owned-documents owned-2",
            "/me/shared-documents -",
            "/me/shared-documents shared-2",
        ])
    }

    /// Exhaustion has no page budget: a scope of more than 100 pages (over
    /// 10,000 owned documents at the server's page size) is still walked to
    /// its end, merged, and evicts what it does not mention.
    func test_wholeScopeSync_walksPastAHundredPages() async throws {
        let pageCount = 150
        var owned: [String?: String] = [:]
        for index in 1...pageCount {
            let next = index < pageCount ? "owned-\(index + 1)" : nil
            owned[index == 1 ? nil : "owned-\(index)"] =
                Self.page([Self.row("doc-owned-\(index)", "Owned \(index)")], next: next)
        }
        let (client, server) = try makeClient(owned: owned, shared: [nil: Self.emptyPage])
        await seedLocal(client, "doc-owned-\(pageCount)", "On the last owned page")
        await seedLocal(client, "doc-stale", "Deleted while offline")

        try await client.syncMetadata()

        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-owned-1"))
        XCTAssertEqual(
            client.documentManager.getLocalMetadata("doc-owned-\(pageCount)")?.title,
            "Owned \(pageCount)"
        )
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-stale"))
        XCTAssertEqual(
            server.requests.filter { $0.apiPathOnly == "/me/owned-documents" }.count,
            pageCount
        )
    }

    func test_wholeScopeSync_deduplicatesADocumentBothListsReturn() async throws {
        let (client, _) = try makeClient(
            owned: [nil: Self.page([Self.row("doc-both", "Owned copy", "owner")])],
            shared: [nil: Self.page([Self.row("doc-both", "Shared copy", "reader")])]
        )
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata()

        XCTAssertEqual(events.updates("doc-both"), 1, "one document, one row")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-both")?.title, "Owned copy")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-both")?.permission, "owner")
    }

    func test_wholeScopeIdsSync_asksTheOwnedListForIdsAndVerifiesBeforeEvicting() async throws {
        let (client, server) = try makeClient { request in
            switch request.apiPathOnly {
            case "/me/owned-documents": return .json(Self.page([#"{"documentId":"doc-listed"}"#]))
            case "/me/shared-documents": return .json(Self.emptyPage)
            case "/documents/doc-gone": return .status(404, "Not Found")
            case "/documents/doc-live": return .json(Self.row("doc-live", "Still mine"))
            default: return .status(404, "unscripted path \(request.apiPathOnly)")
            }
        }
        await seedLocal(client, "doc-listed", "Listed")
        await seedLocal(client, "doc-gone", "Gone from the server")
        await seedLocal(client, "doc-live", "Missing from the id list only")

        try await client.syncMetadata(options: SyncMetadataOptions(payloadType: "ids"))

        let owned = try XCTUnwrap(server.requests.first { $0.apiPathOnly == "/me/owned-documents" })
        XCTAssertEqual(Self.query(owned, "fields"), "ids")
        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-listed"))
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-gone"))
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-live")?.title, "Still mine")
    }

    // MARK: - Edge cases

    /// The owned list leaves the app root out unless asked for it, so the
    /// root's absence from the scope is not news.
    func test_wholeScopeSync_keepsTheRootDocument() async throws {
        let (client, _) = try makeClient(
            token: makeTestJwt(userId: "user-root", rootDocId: "doc-root"),
            owned: [nil: Self.emptyPage],
            shared: [nil: Self.emptyPage]
        )
        await seedLocal(client, "doc-root", "App root")
        await seedLocal(client, "doc-stale", "Deleted while offline")

        try await client.syncMetadata()

        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-root"))
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-stale"))
    }

    /// A walk that saw only the owned half would read every shared document
    /// as evictable, so a failed half fails the sync and evicts nothing.
    func test_wholeScopeSync_aFailedListThrowsAndChangesNothing() async throws {
        let (client, _) = try makeClient { request in
            switch request.apiPathOnly {
            case "/me/owned-documents": return .json(Self.page([Self.row("doc-new", "New")]))
            case "/me/shared-documents": return .status(500, "Internal Server Error")
            default: return .status(404, "unscripted path \(request.apiPathOnly)")
            }
        }
        await seedLocal(client, "doc-shared", "Shared with me")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        do {
            try await client.syncMetadata()
            XCTFail("a failed list must fail the sync")
        } catch {
            XCTAssertTrue(String(describing: error).contains("500"), "expected the 500, got \(error)")
        }

        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-shared"))
        XCTAssertNil(events.deleted("doc-shared"))
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-new"))
    }

    /// Anything short of reaching the end of both lists — a page that says
    /// more rows remain but gives no cursor, a cursor that does not advance or
    /// cycles back to one already followed, a page that is not the envelope —
    /// authorizes no eviction and merges nothing.
    func test_wholeScopeSync_anUnfinishedWalkChangesNothing() async throws {
        let unfinished: [(String, [String?: String])] = [
            ("more rows, no cursor", [nil: #"{"items":[\#(Self.row("doc-new", "New"))],"hasMore":true}"#]),
            ("cursor stuck", [
                nil: Self.page([Self.row("doc-new", "New")], next: "same"),
                "same": Self.page([], next: "same"),
            ]),
            ("cursor cycles", [
                nil: Self.page([Self.row("doc-new", "New")], next: "a"),
                "a": Self.page([], next: "b"),
                "b": Self.page([], next: "a"),
            ]),
            ("not the envelope", [nil: "[\(Self.row("doc-new", "New"))]"]),
            ("no items", [nil: #"{"documents":[]}"#]),
        ]
        for (label, shared) in unfinished {
            let (client, server) = try makeClient(
                owned: [nil: Self.page([Self.row("doc-owned", "Mine")])],
                shared: shared
            )
            await seedLocal(client, "doc-kept", "Cached")

            try await client.syncMetadata()

            XCTAssertTrue(
                server.requests.contains { $0.apiPathOnly == "/me/shared-documents" },
                "\(label): the walk must reach the shared list"
            )
            XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-kept"), label)
            XCTAssertNil(client.documentManager.getLocalMetadata("doc-new"), label)
            XCTAssertNil(client.documentManager.getLocalMetadata("doc-owned"), label)
        }
    }

    /// The walk spans several round trips. A cached document the server
    /// confirms while it runs can be absent from a page that had already gone
    /// by, so its absence from the walk does not evict it.
    func test_wholeScopeSync_keepsADocumentConfirmedWhileTheWalkRuns() async throws {
        let box = ClientBox()
        let (client, _) = try makeClient(
            owned: [nil: Self.page([Self.row("doc-owned", "Mine")])],
            shared: [nil: Self.emptyPage],
            onRequest: { request in
                guard request.apiPathOnly == "/me/shared-documents" else { return }
                box.confirm("doc-confirmed", title: "Confirmed mid-walk")
            }
        )
        box.hold(client)
        await seedLocal(client, "doc-confirmed", "Cached before the walk")
        await seedLocal(client, "doc-stale", "Deleted while offline")

        try await client.syncMetadata()

        XCTAssertEqual(
            client.documentManager.getLocalMetadata("doc-confirmed")?.title,
            "Confirmed mid-walk"
        )
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-stale"))
    }

    func test_wholeScopeSync_isMergeOnlyWhenAuthoritativeIsFalse() async throws {
        let (client, _) = try makeClient(
            owned: [nil: Self.page([Self.row("doc-owned", "Mine")])],
            shared: [nil: Self.emptyPage]
        )
        await seedLocal(client, "doc-unlisted", "Not in either list")

        try await client.syncMetadata(options: SyncMetadataOptions(authoritative: false))

        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-owned")?.title, "Mine")
        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-unlisted"))
    }
}
