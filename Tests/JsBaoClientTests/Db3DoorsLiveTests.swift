import XCTest
@testable import JsBaoClient

/// #4701 behaviours 30, 31 and edge 41 — the document doors on a db3, against
/// the dev server, the Swift twin of js-bao's
/// `tests/client/db3-deprecated-open-4698.test.ts`:
///
/// - 30: `documents.open` and `openDocument` open a db3 as before and log one
///   `deprecated on a db3` warning per client and door naming
///   `client.db3.subscribe`; `documents.close` / `closeDocument` warn once per
///   client and door naming `client.db3.unsubscribe`, dispose this client's
///   handles and keep the store bound, so the db3 still answers after the
///   close; a format-1 document warns nothing; `documents.delete`'s own close
///   warns nothing; a second client warns again.
/// - 31: a close owed a purge (evicted while open, or opened not to be
///   retained) unbinds the db3 so the purge removes it; `documents.evict`
///   without force refuses a db3 holding an unsent write.
/// - 41: a subscription made while a door holds the db3 open leaves it open
///   and subscribed for the door when it is disposed.
/// - Finding 4701-C01: `client.db3.evict` of a db3 only a door holds open
///   closes it on the socket before the purge: the room counts no subscriber
///   and no model member keeps the closed binding.
final class Db3DoorsLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var lines: ThreadSafeBox<[String]>!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-doors-4701")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
        let lines = ThreadSafeBox<[String]>([])
        self.lines = lines
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("deprecated on a db3") { lines.mutate { $0.append(message) } }
        }
    }

    override func tearDown() async throws {
        Logger.lineForTest = nil
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func opens() -> [String] { lines.value.filter { $0.contains("client.db3.subscribe") } }
    private func closes() -> [String] { lines.value.filter { $0.contains("client.db3.unsubscribe") } }

    private func titles(_ client: JsBaoClient, _ options: QueryOptions? = nil) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil, options: options).compactMap { $0["title"]?.stringValue }.sorted()
    }

    // MARK: - Behaviour 30

    func testTheDoorsOpenAndCloseADb3AsBeforeWarningOncePerClientAndDoorAndKeepItQueryable() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let formatOne = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let x = try await live.client("x", models: [Self.note])

        _ = try await x.documents.open(id, options: OpenDocumentOptions(waitForLoad: .network))
        XCTAssertEqual(opens().count, 1, "\(lines.value)")
        try await x.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("while open")], in: id, confirm: true)
        XCTAssertEqual(try titles(x, QueryOptions(documents: [id])), ["while open"])

        // Closed through documents.close: warned, the handle disposed, the store bound.
        let sub = try x.db3.subscribe(id)
        try await sub.ready()
        _ = await x.documents.close(id)
        XCTAssertEqual(closes().count, 1, "\(lines.value)")
        do {
            let got = await db3Outcome { try await sub.ready() }
            XCTAssertEqual(got, "resolved", "a settled ready stays resolved")
        }
        try await eventually(description: "the handle disposed by the close") { !sub.state.subscribed }
        XCTAssertTrue(x.isRecordLogDocument(id))
        XCTAssertEqual(try titles(x, QueryOptions(db3: [id])), ["while open"])
        XCTAssertEqual(try x.documents.records(id).query("Note").data.count, 1)

        // The same doors again: no further line. The other doors: one more each.
        _ = try await x.documents.open(id, options: OpenDocumentOptions(waitForLoad: .network))
        _ = await x.documents.close(id)
        XCTAssertEqual(opens().count, 1)
        XCTAssertEqual(closes().count, 1)
        _ = try await x.openDocument(id, options: OpenDocumentOptions(waitForLoad: .network))
        XCTAssertEqual(opens().count, 2)
        _ = await x.closeDocument(id)
        XCTAssertEqual(closes().count, 2)
        XCTAssertTrue(lines.value.allSatisfy { $0.contains(id) }, "\(lines.value)")

        // A format-1 document warns nothing.
        let before = lines.value.count
        _ = try await x.documents.open(formatOne, options: OpenDocumentOptions(waitForLoad: .network))
        _ = await x.documents.close(formatOne)
        XCTAssertEqual(lines.value.count, before)

        // A second client warns again.
        let y = try await live.client("y", models: [Self.note])
        _ = try await y.documents.open(id, options: OpenDocumentOptions(waitForLoad: .network))
        XCTAssertEqual(opens().count, 3)
    }

    func testADeleteOfAnOpenDb3LogsNoCloseWarning() async throws {
        let x = try await live.client("x", models: [Self.note])
        let id = try await live.createDocument(x)
        _ = try await x.documents.open(id, options: OpenDocumentOptions(waitForLoad: .network))
        try await x.documents.delete(documentId: id, options: DeleteDocumentOptions(forceCloseIfOpen: true))
        XCTAssertEqual(closes(), [])
        XCTAssertFalse(x.documentManager.isOpen(id))
    }

    // MARK: - Behaviour 31

    func testACloseOwedAPurgeUnbindsTheDb3AndAnUnforcedEvictKeepsUnsentWrites() async throws {
        let x = try await live.client("x", models: [Self.note])

        // Evicted while open: the purge is owed at the close.
        let evicted = try await live.db3Written(0, model: "Note")
        _ = try await x.documents.open(evicted, options: OpenDocumentOptions(waitForLoad: .network))
        try await x.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("evicted while open")], in: evicted, confirm: true)
        try await live.settled(x, evicted)
        try await x.documents.evict(documentId: evicted)
        _ = await x.documents.close(evicted)
        XCTAssertFalse(x.isRecordLogDocument(evicted))
        var stored = try await x.db3.stored()
        XCTAssertFalse(stored.map(\.id).contains(evicted))

        // Opened not to be kept after its close: the close evicts.
        let transient = try await live.db3Written(0, model: "Note")
        _ = try await x.documents.open(transient, options: OpenDocumentOptions(waitForLoad: .network, retainLocal: false))
        try await x.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("not retained")], in: transient, confirm: true)
        try await live.settled(x, transient)
        _ = await x.documents.close(transient)
        XCTAssertFalse(x.isRecordLogDocument(transient))
        stored = try await x.db3.stored()
        XCTAssertFalse(stored.map(\.id).contains(transient))

        // An unsent write: documents.evict without force refuses the db3.
        let dirty = try await live.db3Written(0, model: "Note")
        try await live.residentOn(x, dirty)
        x.setNetworkMode(.offline)
        try x.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("unsent")], in: dirty)
        do {
            try await x.documents.evict(documentId: dirty)
            XCTFail("an unforced evict of a db3 with an unsent write is refused")
        } catch {
            XCTAssertNotNil(error as? JsBaoError, "\(error)")
        }
        let kept = try await x.db3.state(dirty)
        XCTAssertTrue(kept.resident)
        XCTAssertEqual(kept.pendingWrites, 1)
    }

    // MARK: - Edge 41

    func testASubscriptionDisposedWhileADoorHoldsTheDb3LeavesItOpenAndSubscribed() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let y = try await live.client("y", models: [Self.note])
        _ = try await x.documents.open(id, options: OpenDocumentOptions(waitForLoad: .network))
        let held = try y.db3.subscribe(id)
        try await held.ready()
        try await live.subscribersBecome(id, 2)

        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        handle.dispose()
        _ = try await x.db3.refresh(id)
        try await delay(0.5)
        XCTAssertTrue(x.documentManager.isOpen(id))
        let count = try await live.subscribers(id)
        XCTAssertEqual(count, 2)

        // x's open still hears the room.
        try await y.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("from y")], in: id, confirm: true)
        try await eventually(timeout: 15, description: "y's write to reach x's open") {
            try self.titles(x, QueryOptions(db3: [id])).contains("from y")
        }
    }

    // MARK: - Finding 4701-C01

    func testAnEvictionOfADb3OnlyADoorHoldsClosesItOnTheSocket() async throws {
        let id = try await live.db3Written(1, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        _ = try await x.documents.open(id, options: OpenDocumentOptions(waitForLoad: .network))
        try await live.subscribersBecome(id, 1)
        XCTAssertNotNil(x.sharedModel(for: Self.note).member(docId: id))

        try await x.db3.evict(id, options: Db3EvictOptions(force: true))
        try await live.subscribersBecome(id, 0)
        XCTAssertFalse(x.documentManager.isOpen(id))
        XCTAssertFalse(x.isRecordLogDocument(id))
        XCTAssertNil(x.sharedModel(for: Self.note).member(docId: id), "no member keeps the closed binding")
        let stored = try await x.db3.stored()
        XCTAssertFalse(stored.map(\.id).contains(id))
    }
}
