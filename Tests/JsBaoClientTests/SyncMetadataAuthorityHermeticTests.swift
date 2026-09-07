import XCTest
@testable import JsBaoClient

/// Swift mirrors of `tests/client/js-bao-client-sync-metadata-authority.test.ts`
/// (#3079): which `syncMetadata` calls may evict a cached document.
///
/// JS is the reference. A single-document sync is authoritative for its own
/// row by default — it is the one call an app makes to ask "is this document
/// still mine?", and a revoked or deleted document has to leave the device
/// when the answer is no. An ids-only payload does not skip eviction, it
/// defers it: the row goes only once the server confirms it is gone (404 /
/// 403), never on the strength of an id list.
///
/// Server-free (`*HermeticTests`): a `LoopbackAPIServer` answers the client's
/// real HTTP requests from a per-test script, so the whole path under test —
/// `syncMetadata` → `HttpClient` → `DocumentManager` — is the shipped one.
final class SyncMetadataAuthorityHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var servers: [LoopbackAPIServer] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for server in servers { server.stop() }
        servers = []
    }

    // MARK: - Fixture

    /// A real client whose API requests `responder` answers.
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
            appId: "sync-metadata-authority-app",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        return (client, server)
    }

    /// A server that answers `GET /documents/<id>` from `documents` (a status
    /// for the ones it no longer has) and any whole-scope listing with
    /// `listing`.
    private func makeClient(
        listing: String = "[]",
        documents: [String: LoopbackAPIServer.Response]
    ) throws -> (JsBaoClient, LoopbackAPIServer) {
        try makeClient { request in
            let path = request.apiPathOnly
            if path.hasPrefix("/documents/") {
                let id = String(path.dropFirst("/documents/".count))
                return documents[id] ?? .status(404, "unscripted document \(id)")
            }
            if path == "/documents" { return .json(listing) }
            return .status(404, "unscripted path \(path)")
        }
    }

    private func serverDoc(_ id: String, _ title: String) -> String {
        #"{"documentId":"\#(id)","title":"\#(title)","permission":"read-write"}"#
    }

    /// Put a document in the local cache the way a server listing would.
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
    }

    /// Lets a scripted response reach the client that is waiting for it, so a
    /// test can land a server confirmation while the request is in flight.
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

        /// The confirmation an `availability` frame carrying a metadata blob
        /// delivers, through the handler the frame actually calls.
        func confirmByAvailabilityFrame(_ documentId: String, title: String) {
            guard let client = lock.withLock({ self.client }) else { return }
            client.documentManager.applyServerMetadata(
                documentId,
                metadata: ["title": .string(title)],
                action: "updated",
                changedFields: ["title"]
            )
        }

        /// The confirmation a `pendingCreateCommitted` frame delivers, through
        /// the handler the frame actually calls: the server has accepted the
        /// create, so the document exists server-side from here on.
        func confirmPendingCreate(_ documentId: String) {
            guard let client = lock.withLock({ self.client }) else { return }
            client.documentManager.handlePendingCreateCommitted(documentId)
        }
    }

    /// Records `documentMetadataChanged` for the life of the returned
    /// subscription, which the caller keeps alive.
    private func sink(_ client: JsBaoClient) -> (EventSink, EventSubscription) {
        let sink = EventSink()
        let subscription = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) {
            sink.record($0)
        }
        return (sink, subscription)
    }

    // MARK: - A single-document sync is authoritative for its own row

    func test_singleDocumentSync_evictsTheDocumentTheServerHasDeleted() async throws {
        let goneId = "doc-gone"
        let keptId = "doc-kept"
        let (client, _) = try makeClient(documents: [goneId: .status(404, "Not Found")])
        await seedLocal(client, goneId, "Deleted by a peer")
        await seedLocal(client, keptId, "Still mine")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: goneId))

        XCTAssertNil(
            client.documentManager.getLocalMetadata(goneId),
            "a document the server no longer has must leave the local index"
        )
        let deleted = try XCTUnwrap(
            events.deleted(goneId),
            "an evicted document must emit a deleted metadata event"
        )
        XCTAssertNil(deleted.metadata)
        XCTAssertNotNil(
            client.documentManager.getLocalMetadata(keptId),
            "a single-document answer says nothing about the other documents"
        )
    }

    func test_singleDocumentSync_evictsTheDocumentWhoseAccessWasRevoked() async throws {
        let revokedId = "doc-revoked"
        let (client, _) = try makeClient(documents: [revokedId: .status(403, "Forbidden")])
        await seedLocal(client, revokedId, "Access revoked while offline")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: revokedId))

        XCTAssertNil(client.documentManager.getLocalMetadata(revokedId))
        XCTAssertNotNil(events.deleted(revokedId))
    }

    func test_singleDocumentSync_keepsAndRefreshesTheRowTheServerStillHas() async throws {
        let liveId = "doc-live"
        let (client, _) = try makeClient(
            documents: [liveId: .json(serverDoc(liveId, "Renamed on the server"))]
        )
        await seedLocal(client, liveId, "Old title")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: liveId))

        XCTAssertEqual(
            client.documentManager.getLocalMetadata(liveId)?.title,
            "Renamed on the server"
        )
        XCTAssertNil(events.deleted(liveId))
    }

    func test_singleDocumentSync_isMergeOnlyWhenAuthoritativeIsFalse() async throws {
        let docId = "doc-merge-only"
        let (client, _) = try makeClient(documents: [docId: .status(404, "Not Found")])
        await seedLocal(client, docId, "Merge only")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(
            options: SyncMetadataOptions(documentId: docId, authoritative: false)
        )

        XCTAssertNotNil(
            client.documentManager.getLocalMetadata(docId),
            "authoritative: false is merge-only in either scope"
        )
        XCTAssertNil(events.deleted(docId))
    }

    /// An ids payload defers eviction rather than disabling it: the target is
    /// verified against the server, and only a 404 / 403 removes it.
    func test_singleDocumentSync_withIdsPayloadVerifiesBeforeEvicting() async throws {
        let goneId = "doc-ids-gone"
        let (client, server) = try makeClient(documents: [goneId: .status(404, "Not Found")])
        await seedLocal(client, goneId, "Named by an id list")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(
            options: SyncMetadataOptions(documentId: goneId, payloadType: "ids")
        )

        XCTAssertTrue(
            server.paths.contains { $0.hasPrefix("/documents/\(goneId)") },
            "the client must ask the server before deleting; saw \(server.paths)"
        )
        XCTAssertNil(client.documentManager.getLocalMetadata(goneId))
        XCTAssertNotNil(events.deleted(goneId))
    }

    /// The eviction is decided before the request goes out and applied when it
    /// comes back. A confirmation landing in that window — a `docMetadata`
    /// frame, another listing — is newer news than the denial, so the scoped
    /// sync abandons its eviction rather than deleting the row that
    /// confirmation just wrote (the rule `evictLocalData(ifUnconfirmedSince:)`
    /// enforces for the ids branch, #2827).
    func test_singleDocumentSync_abandonsTheEvictionWhenAConfirmationLandsInFlight() async throws {
        let docId = "doc-confirmed-in-flight"
        let box = ClientBox()
        let (client, _) = try makeClient { request in
            guard request.apiPathOnly == "/documents/\(docId)" else {
                return .status(404, "unscripted path \(request.apiPathOnly)")
            }
            // The confirmation reaches the client while this GET is in flight:
            // answered before the denial below is delivered, so the client
            // applies the denial to a row the server has since vouched for.
            box.confirm(docId, title: "Renamed by another client")
            return .status(404, "Not Found")
        }
        box.hold(client)
        await seedLocal(client, docId, "Cached before the sync")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: docId))

        XCTAssertEqual(
            client.documentManager.getLocalMetadata(docId)?.title,
            "Renamed by another client",
            "a stale denial must not delete the row a confirmation wrote after it was sent"
        )
        XCTAssertNil(
            events.deleted(docId),
            "and must not announce a deletion that did not happen"
        )
    }

    /// The same rule through the handler an `availability` frame's metadata
    /// blob actually lands in. A confirmation only counts as one if it stamps
    /// the row, so every path the server confirms a document through has to —
    /// JS notes the touch for any server-sourced metadata apply
    /// (`documentManager.ts:1550`, #2852).
    func test_singleDocumentSync_abandonsTheEvictionWhenAnAvailabilityFrameConfirmsInFlight() async throws {
        let docId = "doc-availability-in-flight"
        let box = ClientBox()
        let (client, _) = try makeClient { request in
            guard request.apiPathOnly == "/documents/\(docId)" else {
                return .status(404, "unscripted path \(request.apiPathOnly)")
            }
            box.confirmByAvailabilityFrame(docId, title: "Confirmed by an availability frame")
            return .status(404, "Not Found")
        }
        box.hold(client)
        await seedLocal(client, docId, "Cached before the sync")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: docId))

        XCTAssertEqual(
            client.documentManager.getLocalMetadata(docId)?.title,
            "Confirmed by an availability frame",
            "a frame that says the server has this document is a confirmation like any other"
        )
        XCTAssertNil(events.deleted(docId))
    }

    /// A pending create the server accepts while the scoped GET is in flight.
    /// The commit is what makes the document evictable at all — it clears the
    /// exemption that protected it when the request went out — so it has to
    /// stamp the row too, or the 404 that was true before the commit deletes
    /// the document the commit just confirmed.
    func test_singleDocumentSync_abandonsTheEvictionWhenAPendingCreateCommitsInFlight() async throws {
        let docId = "doc-committed-in-flight"
        let box = ClientBox()
        let (client, _) = try makeClient { request in
            guard request.apiPathOnly == "/documents/\(docId)" else {
                return .status(404, "unscripted path \(request.apiPathOnly)")
            }
            box.confirmPendingCreate(docId)
            return .status(404, "Not Found")
        }
        box.hold(client)
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "Created offline", localOnly: false
        )
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: docId))

        XCTAssertNotNil(
            client.documentManager.getLocalMetadata(docId),
            "the commit is newer news than the 404 that was sent before it"
        )
        XCTAssertNil(events.deleted(docId))
    }

    // MARK: - Edge cases

    /// The server has never heard of a pending create or a local-only
    /// document, so a 404 for one proves nothing.
    func test_singleDocumentSync_neverEvictsAPendingCreateOrLocalOnlyDocument() async throws {
        let pendingId = "doc-pending"
        let localOnlyId = "doc-local-only"
        let (client, _) = try makeClient(documents: [
            pendingId: .status(404, "Not Found"),
            localOnlyId: .status(404, "Not Found"),
        ])
        _ = try await client.documentManager.createLocalDocument(
            documentId: pendingId, title: "Pending create", localOnly: false
        )
        _ = try await client.documentManager.createLocalDocument(
            documentId: localOnlyId, title: "Local only", localOnly: true
        )

        try await client.syncMetadata(options: SyncMetadataOptions(documentId: pendingId))
        try await client.syncMetadata(options: SyncMetadataOptions(documentId: localOnlyId))

        XCTAssertNotNil(client.documentManager.getLocalMetadata(pendingId))
        XCTAssertNotNil(client.documentManager.getLocalMetadata(localOnlyId))
    }

    /// Only "the server says this document is not yours" evicts. A server
    /// error is a failed sync: it throws and the cache is untouched.
    func test_singleDocumentSync_propagatesAServerErrorAndEvictsNothing() async throws {
        let docId = "doc-server-error"
        let (client, _) = try makeClient(documents: [docId: .status(500, "Internal Server Error")])
        await seedLocal(client, docId, "Still mine")

        do {
            try await client.syncMetadata(options: SyncMetadataOptions(documentId: docId))
            XCTFail("a 500 must surface to the caller")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("500"),
                "expected the server's 500, got \(error)"
            )
        }

        XCTAssertNotNil(client.documentManager.getLocalMetadata(docId))
    }

    // MARK: - A whole-scope ids listing verifies before evicting

    func test_wholeScopeIdsSync_evictsOnlyAfterTheServerConfirmsTheRowIsGone() async throws {
        let listedId = "doc-listed"
        let goneId = "doc-unlisted-gone"
        let (client, server) = try makeClient(
            listing: #"[{"documentId":"\#(listedId)"}]"#,
            documents: [goneId: .status(404, "Not Found")]
        )
        await seedLocal(client, listedId, "Listed by the server")
        await seedLocal(client, goneId, "Not in the id list")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(payloadType: "ids"))

        XCTAssertTrue(
            server.paths.contains { $0.hasPrefix("/documents/\(goneId)") },
            "the id list alone may not delete a row; saw \(server.paths)"
        )
        XCTAssertNil(client.documentManager.getLocalMetadata(goneId))
        XCTAssertNotNil(events.deleted(goneId))
        XCTAssertNotNil(client.documentManager.getLocalMetadata(listedId))
    }

    func test_wholeScopeIdsSync_keepsARowMissingFromTheListThatTheServerStillHas() async throws {
        let listedId = "doc-listed"
        let unlistedId = "doc-unlisted-live"
        let (client, _) = try makeClient(
            listing: #"[{"documentId":"\#(listedId)"}]"#,
            documents: [unlistedId: .json(serverDoc(unlistedId, "Still mine"))]
        )
        await seedLocal(client, listedId, "Listed by the server")
        await seedLocal(client, unlistedId, "Absent from a truncated id list")
        let (events, subscription) = sink(client)
        defer { subscription.cancel() }

        try await client.syncMetadata(options: SyncMetadataOptions(payloadType: "ids"))

        XCTAssertNotNil(client.documentManager.getLocalMetadata(unlistedId))
        XCTAssertNil(events.deleted(unlistedId))
    }

    func test_wholeScopeIdsSync_verifiesNothingWhenNotAuthoritative() async throws {
        let goneId = "doc-unlisted-gone"
        let (client, server) = try makeClient(
            listing: "[]",
            documents: [goneId: .status(404, "Not Found")]
        )
        await seedLocal(client, goneId, "Not in the id list")

        try await client.syncMetadata(
            options: SyncMetadataOptions(payloadType: "ids", authoritative: false)
        )

        XCTAssertFalse(
            server.paths.contains { $0.hasPrefix("/documents/\(goneId)") },
            "a merge-only sync has no reason to verify anything"
        )
        XCTAssertNotNil(client.documentManager.getLocalMetadata(goneId))
    }
}
