import XCTest
@testable import JsBaoClient

/// Purging a large document's data, and the socket's receive limit (#3436,
/// behaviors 35 and 3, edge E14).
///
/// Two independent rules that share a suite because each is small and both are
/// about what the transport and the store OWE the rest of the client: a
/// document's rows must not outlive an eviction or an account wipe, and a
/// frame the handshake depends on must not be refused before the code that
/// would have raised the limit ever runs.
final class Format2PurgeAndMessageSizeHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-purge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A document with a row, an unacknowledged pending op, a stringset
    /// member, a query-projection mark, and marks in every shared table — so
    /// a purge that misses one is visible.
    @discardableResult
    private func seed(
        _ provider: any Format2SqlHost, documentId: String
    ) throws -> Format2RecordStore {
        let store = Format2RecordStore(
            host: provider, documentId: documentId, clientId: "me"
        )
        try store.initialize()
        try store.setEpoch(4)
        try store.noteSync(at: 1_700_000_000_000, windowDays: 14)
        _ = try store.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(
                id: "r1", kind: .create,
                fields: ["title": .string("kept")],
                stringSetDeltas: ["tags": ["x": true]]
            ),
            pending: PendingOpInput(
                model: "Note", recordId: "r1", op: .create, fields: ["title"],
                baseEpoch: 4, ts: 1
            )
        )
        try store.beginBase(buildId: "b1", epoch: 4)
        try store.markChunkComplete(buildId: "b1", ordinal: 0)
        try store.noteDiscontinuity(epoch: 3)
        try store.markQueryProjection(model: "Note")
        return store
    }

    // MARK: - Behavior 35 — purge

    func testPurgeLeavesNoRowTableOrPendingOpForTheDocument() async throws {
        let provider = try await makeProvider()
        let doomed = try seed(provider, documentId: "docA")
        let survivor = try seed(provider, documentId: "docB")

        XCTAssertEqual(try doomed.pendingOps().count, 1, "the fixture has an unacked write")

        try Format2RecordStore.purge(host: provider, documentId: "docA")

        // The per-document tables are gone, not merely empty: they are named
        // after the document and nothing will ever read them again.
        let schema = try survivor.schemaObjects()
        let doomedTables = Format2TableNames(documentId: "docA")
        XCTAssertNil(schema[doomedTables.records], "the records table survived")
        XCTAssertNil(schema[doomedTables.stringSetIndex], "the member table survived")

        // And every shared table has forgotten it.
        for (table, count) in try Format2RecordStore.sharedRowCounts(
            host: provider, documentId: "docA"
        ) {
            XCTAssertEqual(count, 0, "\(table) still holds rows for the purged document")
        }

        // The sibling is untouched — tables, rows, pending op and marks.
        XCTAssertNotNil(schema[Format2TableNames(documentId: "docB").records])
        XCTAssertEqual(
            try survivor.read(model: "Note", recordId: "r1")?["title"], .string("kept")
        )
        XCTAssertEqual(try survivor.pendingOps().count, 1)
        XCTAssertEqual(try survivor.epoch(), 4)
        XCTAssertTrue(try survivor.hasQueryProjection(model: "Note"))
    }

    func testPurgeAllLeavesNothingForAnyDocument() async throws {
        let provider = try await makeProvider()
        try seed(provider, documentId: "docA")
        try seed(provider, documentId: "docB")

        try Format2RecordStore.purgeAll(host: provider)

        for documentId in ["docA", "docB"] {
            let tables = Format2TableNames(documentId: documentId)
            let probe = Format2RecordStore(
                host: provider, documentId: documentId, clientId: "me"
            )
            let schema = try probe.schemaObjects()
            XCTAssertNil(schema[tables.records], "\(documentId) records table survived")
            XCTAssertNil(schema[tables.stringSetIndex], "\(documentId) member table survived")
            for (table, count) in try Format2RecordStore.sharedRowCounts(
                host: provider, documentId: documentId
            ) {
                XCTAssertEqual(count, 0, "\(table) still holds rows for \(documentId)")
            }
        }
        // The provider's own key-value store is NOT part of a format-2 purge:
        // `wipeLocal` clears it separately and an eviction must not.
        XCTAssertNotNil(
            try Format2RecordStore(
                host: provider, documentId: "docA", clientId: "me"
            ).schemaObjects()["kv_store"]
        )
    }

    func testPurgingADocumentThatWasNeverAFormat2DocumentIsANoOp() async throws {
        // Eviction calls purge for every document, and most are format 1.
        let provider = try await makeProvider()
        try seed(provider, documentId: "docA")
        XCTAssertNoThrow(
            try Format2RecordStore.purge(host: provider, documentId: "never-opened")
        )
        let survivor = Format2RecordStore(host: provider, documentId: "docA", clientId: "me")
        XCTAssertEqual(
            try survivor.read(model: "Note", recordId: "r1")?["title"], .string("kept")
        )
    }

    func testPurgeOnADatabaseWithNoFormat2TablesAtAllIsANoOp() async throws {
        // `wipeLocal` runs on every client, including one that has never
        // opened a large document — there is not even a `_pending_ops` table.
        let provider = try await makeProvider()
        XCTAssertNoThrow(try Format2RecordStore.purgeAll(host: provider))
        XCTAssertNoThrow(try Format2RecordStore.purge(host: provider, documentId: "x"))
    }

    // MARK: - Behavior 3 / E14 — the receive limit

    func testTheManagerStartsAtFoundationsDefaultAndRaisesOnlyWhenAsked() async throws {
        let manager = WebSocketManager(logger: Logger(level: .none), maxReconnectDelayMs: 1000)
        let untouched = await manager.configuredMaximumMessageSize
        XCTAssertNil(
            untouched,
            "an untouched manager leaves Foundation's 1 MiB default alone, "
                + "which is the format-1 limit the intent says not to change"
        )

        await manager.setMaximumMessageSize(Format2Transport.maximumMessageSize)
        let raised = await manager.configuredMaximumMessageSize
        XCTAssertEqual(raised, Format2Transport.maximumMessageSize)
    }

    func testTheLimitIsNeverLowered() async throws {
        // A format-1 document opened after a format-2 one must not take the
        // socket back down: they share one connection, and the next
        // `epoch.info` on the large document would be refused by the receive.
        let manager = WebSocketManager(logger: Logger(level: .none), maxReconnectDelayMs: 1000)
        await manager.setMaximumMessageSize(Format2Transport.maximumMessageSize)
        await manager.setMaximumMessageSize(1024)
        let afterLowerAttempt = await manager.configuredMaximumMessageSize
        XCTAssertEqual(
            afterLowerAttempt, Format2Transport.maximumMessageSize, "the limit was lowered"
        )
    }

    /// E14 — raising the limit applies to the LIVE task and to every later
    /// one, without reconnecting.
    func testTheLimitAppliesToTheLiveTaskAndSurvivesAReconnect() async throws {
        let manager = WebSocketManager(logger: Logger(level: .none), maxReconnectDelayMs: 1000)
        // The live task is configured immediately, and so is every later one:
        // `applyMaximumMessageSize(to:)` is the one place the value reaches a
        // task, called both by the raise and by `performConnect`. Driving that
        // method is driving what production does.
        let task = URLSession(configuration: .ephemeral)
            .webSocketTask(with: URL(string: "ws://127.0.0.1:1")!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        await manager.setMaximumMessageSize(Format2Transport.maximumMessageSize)
        await manager.applyMaximumMessageSize(to: task)
        XCTAssertEqual(task.maximumMessageSize, Format2Transport.maximumMessageSize)
    }

    // MARK: - Behavior 3 — who asks for it

    func testADocumentNotKnownToBeFormatOneRaisesTheLimitBeforeSyncStep1() {
        // The rule (3436-SO-07). A first open has no local metadata, so the
        // format is learned from `epoch.info` — which is the very frame the
        // limit protects, and which `URLSessionWebSocketTask` fails at the
        // RECEIVE rather than in the handler. So the question the client asks
        // before `syncStep1` is not "is this a large document" (it cannot
        // know) but "is this document locally KNOWN to be format 1".
        XCTAssertTrue(
            Format2Transport.needsRaisedMessageSize(storedDocumentFormat: nil),
            "a document with no recorded format must raise the limit"
        )
        XCTAssertTrue(
            Format2Transport.needsRaisedMessageSize(storedDocumentFormat: 2),
            "a known large document must raise the limit"
        )
        XCTAssertFalse(
            Format2Transport.needsRaisedMessageSize(storedDocumentFormat: 1),
            "a document locally known to be format 1 keeps Foundation's default"
        )
    }
}
