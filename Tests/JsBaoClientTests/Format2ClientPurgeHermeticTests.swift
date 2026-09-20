import XCTest
@testable import JsBaoClient
import YSwift

/// Evicting a large document, and wiping an account, leave nothing of it
/// behind (#3436, behavior 35 and edge E13).
///
/// The purge itself — which tables it drops, which rows it clears, that a
/// sibling document is untouched — is proven over the store elsewhere in this
/// suite. What is asserted here is that the client's two destructive
/// lifecycle paths actually CALL it: `documents.evict` and
/// `logout(wipeLocal: true)`. Before this, both cleared the Yjs snapshot and
/// the KV cache and left every record of the document on disk, which is
/// exactly what criterion 7 forbids.
///
/// Server-free: the client never connects.
final class Format2ClientPurgeHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-purge-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func newDocId() -> String { "f2-purge-\(UUID().uuidString.prefix(8))" }

    /// The one model these documents hold. Registered on the client so the
    /// binding attaches an overlay observer for it — a model nothing has
    /// registered is a model the fold never watches.
    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ]
    )

    private func makeClient(databasePath: String) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-client-purge-test-app",
            token: makeTestJwt(userId: "purge-user"),
            offline: true,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: databasePath),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        return client
    }

    /// Open a large document and leave one unacknowledged write in it.
    @discardableResult
    private func openWithAWrite(
        _ client: JsBaoClient, _ documentId: String
    ) async throws -> Format2DocumentBinding {
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "purge", localOnly: false, documentFormat: 2
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "n1", kind: .create, fields: ["title": .string("kept")]
            ),
            fields: ["title"]
        )
        // The write this helper just made is unacknowledged, which is what
        // makes every case below about an eviction being EXPLICIT rather than
        // incidental. Not a count: an instance that adopted a previous one's
        // ops at the bind owes those as well (#3437, behavior 4).
        let owed = try binding.store.pendingOps()
        XCTAssertFalse(
            owed.isEmpty,
            "precondition: the write is unacknowledged, so an eviction has to be explicit about it"
        )
        XCTAssertEqual(
            owed.last?.recordId, "n1",
            "precondition: the newest owed write is the one this helper made"
        )
        return binding
    }

    /// The host this client's database is reachable through, for reading the
    /// tables directly.
    private func host(_ client: JsBaoClient) async throws -> any Format2SqlHost {
        let stored = await client.offlineStore.getStorageProvider()
        let provider = try XCTUnwrap(stored)
        return try Format2Storage.host(for: provider)
    }

    /// Whether the database still holds anything at all for `documentId`.
    private func tracesRemain(
        _ host: any Format2SqlHost, _ documentId: String
    ) throws -> [String] {
        var traces: [String] = []
        let tables = Format2TableNames(documentId: documentId)
        let present = try host.withConnection { connection in
            Set(
                try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'")
                    .compactMap { $0["name"].stringValue }
            )
        }
        for table in [tables.records, tables.stringSetIndex] where present.contains(table) {
            traces.append("table \(table)")
        }
        for row in try Format2RecordStore.sharedRowCounts(host: host, documentId: documentId)
        where row.count > 0 {
            traces.append("\(row.count) row(s) in \(row.table)")
        }
        return traces
    }

    // MARK: - Behavior 35 — eviction

    func testEvictingALargeDocumentLeavesNothingOfItAndSparesItsSibling() async throws {
        let client = await makeClient(databasePath: newDatabasePath())
        defer { Task { await client.destroy() } }

        let evicted = newDocId()
        let kept = newDocId()
        try await openWithAWrite(client, evicted)
        try await openWithAWrite(client, kept)
        let sqlHost = try await host(client)

        XCTAssertFalse(
            try tracesRemain(sqlHost, evicted).isEmpty,
            "precondition: the document is on disk"
        )

        // `force`, because the write is deliberately unacknowledged: an
        // eviction is an explicit instruction to forget the document, and the
        // pending op goes with it.
        try await client.documents.evict(
            documentId: evicted, options: EvictDocumentOptions(force: true)
        )

        XCTAssertEqual(
            try tracesRemain(sqlHost, evicted), [],
            "an evicted large document may leave no table, no row and no pending op"
        )
        XCTAssertFalse(
            try tracesRemain(sqlHost, kept).isEmpty,
            "and a second document on the same client is not touched by it"
        )
    }

    /// An ordinary close is not an instruction to forget anything.
    func testAnOrdinaryCloseKeepsEverything() async throws {
        let client = await makeClient(databasePath: newDatabasePath())
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await openWithAWrite(client, documentId)
        let sqlHost = try await host(client)

        _ = await client.closeDocument(documentId)

        XCTAssertFalse(
            try tracesRemain(sqlHost, documentId).isEmpty,
            "a close keeps the document's local store — that is what makes the next open cheap"
        )
    }

    // MARK: - Behavior 35 — the account wipe

    func testWipeLocalLeavesNothingForAnyLargeDocumentOpenOrClosed() async throws {
        let client = await makeClient(databasePath: newDatabasePath())
        defer { Task { await client.destroy() } }

        let open = newDocId()
        let closed = newDocId()
        try await openWithAWrite(client, open)
        try await openWithAWrite(client, closed)
        let sqlHost = try await host(client)
        _ = await client.closeDocument(closed)

        try await client.logout(wipeLocal: true)

        XCTAssertEqual(
            try tracesRemain(sqlHost, open), [],
            "a previous account's open large document survived the wipe"
        )
        XCTAssertEqual(
            try tracesRemain(sqlHost, closed), [],
            "a previous account's CLOSED large document survived the wipe — the one the "
            + "in-memory sweep cannot see"
        )
    }

    // MARK: - Edge E13 — a relaunch

    /// A second client instance on the same database is a different client,
    /// and it ADOPTS the previous instance's unacknowledged ops (#3437,
    /// behaviors 4 and 6 — #3436 left them for this child, and this test said
    /// so). A purge removes every client's, not just this one's.
    func testARelaunchAdoptsThePreviousInstancesOpsAndPurgeRemovesThem() async throws {
        let databasePath = newDatabasePath()
        let documentId = newDocId()

        let first = await makeClient(databasePath: databasePath)
        let firstBinding = try await openWithAWrite(first, documentId)
        let firstClientId = firstBinding.store.clientIdentity
        await first.destroy()

        let second = await makeClient(databasePath: databasePath)
        defer { Task { await second.destroy() } }
        let secondBinding = try await openWithAWrite(second, documentId)
        XCTAssertNotEqual(
            secondBinding.store.clientIdentity, firstClientId,
            "a relaunch is a different client; reusing the id would claim sequences the "
            + "server acknowledged for a connection that is gone"
        )

        // The previous instance's write is not lost and not silently treated
        // as this one's either: it was adopted at the bind, re-keyed into this
        // client's sequence space, and it is owed alongside this instance's
        // own write. Before adoption existed it was invisible here — never
        // carried, never replayed, never acknowledged (finding 3437-R02).
        let ops = try secondBinding.store.pendingOps()
        XCTAssertEqual(
            ops.count, 2,
            "the adopted write and this instance's own are both owed; ops: "
            + "\(ops.map { ($0.seq, $0.recordId) })"
        )
        XCTAssertEqual(
            ops.map(\.seq), [1, 2],
            "one contiguous sequence space, the adopted write first"
        )

        let sqlHost = try await host(second)
        try await second.documents.evict(
            documentId: documentId, options: EvictDocumentOptions(force: true)
        )
        XCTAssertEqual(
            try tracesRemain(sqlHost, documentId), [],
            "the purge takes every client's ops for the document, not just this one's"
        )
    }

    // MARK: - Edge E12 — closing and reopening

    /// A close releases the binding: its observers go, and the fold queue is
    /// drained by the cancel before the handle is let go.
    ///
    /// Releasing it is not tidiness. A reopened document gets a NEW `YDocument`
    /// — a large document's Y.Doc IS its epoch overlay — so a binding kept
    /// across the close would leave every later write publishing into the
    /// document that was closed, where nothing reads it and nothing sends it.
    func testClosingReleasesTheBindingAndReopeningAttachesToTheNewDocument() async throws {
        let client = await makeClient(databasePath: newDatabasePath())
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await openWithAWrite(client, documentId)
        let firstOverlay = try XCTUnwrap(client.format2?.binding(documentId)).overlay

        _ = await client.closeDocument(documentId)
        XCTAssertNil(
            client.format2?.binding(documentId),
            "a closed document's binding must go with it"
        )

        let reopened = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        let secondBinding = try XCTUnwrap(client.format2?.binding(documentId))
        XCTAssertTrue(
            secondBinding.overlay.document === reopened,
            "the new binding's overlay has to be the document the reopen produced"
        )
        XCTAssertFalse(
            secondBinding.overlay === firstOverlay,
            "and not the one the close let go of"
        )

        // And the store is still there, which is what a close keeps: the
        // record written before it reads back, and a new write appends to the
        // same durable log rather than starting over.
        let row = try XCTUnwrap(
            try secondBinding.store.read(model: "Note", recordId: "n1")
        )
        XCTAssertEqual(row["title"], .string("kept"))
        XCTAssertEqual(
            try secondBinding.store.pendingOps().map(\.seq), [1],
            "the write the close kept is still owed"
        )
    }

    /// A close DRAINS before it lets go.
    ///
    /// The observer captures the keys an arriving update touched and folds
    /// them on the queue; keys captured and not yet folded are work the
    /// document owes its own merged view. Cancelling the subscriptions without
    /// folding them drops that work for good: the reopen finds the epoch mark
    /// current, runs no catch-up, and the row stays behind the overlay with
    /// nothing scheduled to notice.
    func testAClosePerformsTheFoldItHasAlreadyCapturedBeforeLettingGo() async throws {
        let client = await makeClient(databasePath: newDatabasePath())
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        let binding = try await openWithAWrite(client, documentId)

        // A peer's update lands in the overlay. The observer has captured its
        // keys; nothing has folded them yet.
        let peer = OverlayDocument()
        try peer.applyUpdate(binding.overlay.encodeStateAsUpdate())
        peer.apply(
            OverlayMutation(id: "n2", kind: .create, fields: ["title": .string("peer")]),
            model: "Note"
        )
        // Applied INSIDE the document's operation, and the precondition read
        // there too. A fold scheduled by the capture wants that same lock, so
        // while this thread holds it the queue provably cannot drain — read
        // outside it, the count is a race against the queue, and a queue that
        // won would make this case pass having tested nothing.
        try binding.writePath.withOperation {
            try binding.overlay.applyUpdate(peer.encodeStateAsUpdate())
            XCTAssertGreaterThan(
                binding.observer.pendingKeyCount, 0,
                "precondition: the fold queue has work the close is about to be handed"
            )
        }

        _ = await client.closeDocument(documentId)

        let reopened = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertNotNil(reopened)
        let after = try XCTUnwrap(client.format2?.binding(documentId))
        XCTAssertNotNil(
            try after.store.read(model: "Note", recordId: "n2"),
            "the peer's record never reached the merged view: the close dropped the fold "
            + "it had already captured, and the reopen has no reason to look again"
        )
        XCTAssertEqual(
            after.observer.pendingKeyCount, 0,
            "and the reopen starts with nothing owed — its epoch mark is current, so it "
            + "does not refold the whole overlay"
        )
    }
}
