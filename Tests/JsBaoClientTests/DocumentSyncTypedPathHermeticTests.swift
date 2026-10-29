import XCTest
@testable import JsBaoClient

/// The document calls that used to read the server's answer as an untyped
/// `Any` graph — metadata sync and the offline-create commit — read it
/// through the typed `Transport` helpers on `HttpClient` (#4005).
///
/// These pin what an app can see: the rows a listing upserts and evicts, the
/// body the create sends, and how a 409 or an empty answer is handled. They
/// pass against the untyped path too, apart from the one accepted change: a
/// 2xx whose body is not JSON is now an error rather than silence.
///
/// Server-free (`*HermeticTests`): a `LoopbackAPIServer` answers the client's
/// real HTTP requests, so the path under test is the shipped one.
final class DocumentSyncTypedPathHermeticTests: XCTestCase {
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
        _ responder: @escaping @Sendable (LoopbackAPIServer.Request) -> LoopbackAPIServer.Response
    ) throws -> (JsBaoClient, LoopbackAPIServer) {
        let server = try LoopbackAPIServer(responder: responder)
        let baseUrl = try server.start()
        servers.append(server)

        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl,
            // Nothing in these tests needs a socket.
            wsUrl: "ws://127.0.0.1:1",
            appId: "document-sync-typed-path-app",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        return (client, server)
    }

    /// A server whose whole document scope is `listing`: the owned list
    /// answers it as one `{ items, hasMore }` page and the shared list is
    /// empty. Everything else is a 404.
    private func makeClient(listing: String) throws -> (JsBaoClient, LoopbackAPIServer) {
        try makeClient { request in
            switch request.apiPathOnly {
            case "/me/owned-documents": return .json(#"{"items":\#(listing),"hasMore":false}"#)
            case "/me/shared-documents": return .json(#"{"items":[],"hasMore":false}"#)
            default: return .status(404)
            }
        }
    }

    private func seedLocal(
        _ client: JsBaoClient,
        _ id: String,
        _ title: String,
        thumbnailBlobId: String? = nil
    ) async {
        var row: [String: Any] = ["documentId": id, "title": title, "permission": "read-write"]
        if let thumbnailBlobId { row["thumbnailBlobId"] = thumbnailBlobId }
        await client.documentManager.handleServerDocuments([row])
    }

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DocumentMetadataChangedEvent] = []
        func record(_ event: DocumentMetadataChangedEvent) {
            lock.withLock { events.append(event) }
        }
        func deleted(_ documentId: String) -> DocumentMetadataChangedEvent? {
            lock.withLock { events }.first { $0.documentId == documentId && $0.action == "deleted" }
        }
    }

    private func sink(_ client: JsBaoClient) -> (EventSink, EventSubscription) {
        let sink = EventSink()
        let subscription = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) {
            sink.record($0)
        }
        return (sink, subscription)
    }

    // MARK: - Metadata sync

    func test_wholeScopeListing_upsertsListedRowsAndEvictsTheUnlistedOne() async throws {
        let (client, server) = try makeClient(listing: """
            [{"documentId":"doc-a","title":"Alpha","permission":"read-write"},
             {"documentId":"doc-b","title":"Beta","permission":"reader"}]
            """)
        await seedLocal(client, "doc-stale", "Deleted while offline")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata()

        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-a")?.title, "Alpha")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-b")?.title, "Beta")
        XCTAssertNil(client.documentManager.getLocalMetadata("doc-stale"))
        XCTAssertNotNil(events.deleted("doc-stale"))
        XCTAssertTrue(
            server.paths.contains { $0.hasPrefix("/me/owned-documents") },
            "the listing must come from GET /me/owned-documents; saw \(server.paths)"
        )
    }

    func test_listingThatIsAnObject_isIgnored() async throws {
        let (client, _) = try makeClient { request in
            request.apiPathOnly.hasPrefix("/me/") ? .json(#"{"documents":[]}"#) : .status(404)
        }
        await seedLocal(client, "doc-kept", "Kept")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata()

        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-kept"))
        XCTAssertNil(events.deleted("doc-kept"))
    }

    func test_listingWithANonObjectElement_isIgnoredAsAWhole() async throws {
        let (client, _) = try makeClient(
            listing: #"[{"documentId":"doc-new","title":"New","permission":"read-write"}, 1]"#
        )
        await seedLocal(client, "doc-kept", "Kept")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata()

        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-new"),
            "a listing with a non-object element must not upsert any of its rows"
        )
        XCTAssertNotNil(client.documentManager.getLocalMetadata("doc-kept"))
        XCTAssertNil(events.deleted("doc-kept"))
    }

    func test_nullThumbnailInAListing_clearsTheCachedThumbnail() async throws {
        let (client, _) = try makeClient(
            listing: #"[{"documentId":"doc-a","title":"Alpha","permission":"read-write","thumbnailBlobId":null}]"#
        )
        await seedLocal(client, "doc-a", "Alpha", thumbnailBlobId: "blob-old")
        XCTAssertEqual(client.documentManager.getLocalMetadata("doc-a")?.thumbnailBlobId, "blob-old")

        try await client.syncMetadata()

        XCTAssertNil(
            client.documentManager.getLocalMetadata("doc-a")?.thumbnailBlobId,
            "a thumbnailBlobId sent as null clears the cached one"
        )
    }

    func test_singleDocumentSync_withABodyThatIsNotJson_throwsAndKeepsTheRow() async throws {
        let docId = "doc-malformed"
        let (client, _) = try makeClient { _ in .json("{not json") }
        await seedLocal(client, docId, "Still here")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        do {
            try await client.syncMetadata(options: SyncMetadataOptions(documentId: docId))
            XCTFail("a 2xx whose body is not JSON must fail the sync")
        } catch {
            XCTAssertTrue(error is HttpError, "expected HttpError, got \(error)")
        }

        XCTAssertNotNil(client.documentManager.getLocalMetadata(docId))
        XCTAssertNil(events.deleted(docId))
    }

    // MARK: - Offline-create commit

    func test_commitOfflineCreate_postsTheBodyAndClearsThePendingFlag() async throws {
        let docId = "doc-created"
        let (client, server) = try makeClient { request in
            guard request.method == "POST", request.apiPathOnly == "/documents" else {
                return .status(404)
            }
            return .json(#"{"documentId":"doc-created"}"#)
        }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "Fresh", localOnly: false, tags: ["t1"]
        )
        XCTAssertTrue(client.documentManager.isPendingCreate(docId))

        let result = try await client.documentManager.commitOfflineCreate(documentId: docId)

        XCTAssertEqual(result["created"] as? Bool, true)
        XCTAssertFalse(client.documentManager.isPendingCreate(docId))
        let posts = server.requests.filter { $0.method == "POST" && $0.apiPathOnly == "/documents" }
        XCTAssertEqual(posts.count, 1)
        let body = try XCTUnwrap(posts.first?.jsonBody)
        XCTAssertEqual(body["documentId"] as? String, docId)
        XCTAssertEqual(body["title"] as? String, "Fresh")
        XCTAssertEqual(body["tags"] as? [String], ["t1"])
    }

    func test_commitOfflineCreate_on409WithLink_linksAndClearsThePendingFlag() async throws {
        let docId = "doc-exists"
        let (client, _) = try makeClient { _ in .status(409, "exists") }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "Twin", localOnly: false
        )

        let result = try await client.documentManager.commitOfflineCreate(
            documentId: docId, onExists: "link"
        )

        XCTAssertEqual(result["linked"] as? Bool, true)
        XCTAssertFalse(client.documentManager.isPendingCreate(docId))
    }

    func test_commitOfflineCreate_withAnEmptyBody_stillSucceeds() async throws {
        let docId = "doc-empty-answer"
        let (client, _) = try makeClient { _ in .json("") }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "Quiet", localOnly: false
        )

        let result = try await client.documentManager.commitOfflineCreate(documentId: docId)

        XCTAssertEqual(result["created"] as? Bool, true)
        XCTAssertFalse(client.documentManager.isPendingCreate(docId))
    }
}
