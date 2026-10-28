import XCTest
@testable import JsBaoClient

/// #4701 — the db3s a device holds, against the dev server:
///
/// - 20: every db3 the store holds for the user is bound at start-up: a new
///   client over the same file reads it resident without subscribing,
///   `stored()` lists it, an unscoped query answers its rows, and a model
///   registered after the binding reads them too; a format-1-only client
///   creates no record-log table.
/// - 27: `evict` is refused `DB3_PENDING_WRITES` while unsent writes exist;
///   forced, the handle hears `evicted`, `Db3EvictedEvent` and
///   `DOCUMENT_STORE_PURGED` fire, the store goes, and the next subscribe is a
///   cold load under a new writer; a never-stored id resolves quietly.
/// - 28: the retention policy's TTL evicts a db3 with nothing unsent and keeps
///   one holding an unsent write and one subscribed.
/// - 29: `stored()` lists the user's db3s with their numbers, a pending create
///   made offline included and an evicted one not.
/// - Edges 42, 43: the quiet calls; a forced eviction while subscribed closes
///   the db3 on the socket before it purges.
/// - 33: a logout, wiped or not, ends every handle and unbinds every db3, so
///   nothing of the signed-out user's db3s answers, while the file keeps them
///   for the same user's next sign-in; a start-up binding a logout raced is
///   discarded; a sign-in as another user unbinds the previous user's db3s.
final class Db3EvictStoredLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-stored-4701")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient, _ options: QueryOptions? = nil) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil, options: options).compactMap { $0["title"]?.stringValue }.sorted()
    }

    // MARK: - Behaviour 20

    func testEveryStoredDb3IsBoundAtStartUp() async throws {
        let id = try await live.db3Written(3, model: "Note")
        let file = live.file("start-up")
        let x = try await live.client("x", models: [Self.note], file: file)
        try await live.residentOn(x, id)
        await x.destroy()

        let x2 = try await live.client("x2", models: [Self.note], file: file)
        XCTAssertTrue(x2.isRecordLogDocument(id), "bound when storage is ready, before any subscribe")
        XCTAssertFalse(x2.documentManager.isOpen(id))
        let state = try await x2.db3.state(id)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.subscribed)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.rows, 3)
        let stored = try await x2.db3.stored()
        XCTAssertEqual(stored.map(\.id), [id])
        XCTAssertEqual(stored.first?.rows, 3)
        XCTAssertEqual(stored.first?.resident, true)
        XCTAssertEqual(try titles(x2), ["row 1", "row 2", "row 3"])
        XCTAssertEqual(try x2.documents.records(id).count("Note"), 3)
        await x2.destroy()

        // A model registered after the binding reads its rows too.
        let x3 = try await live.client("x3", models: [], file: file)
        XCTAssertTrue(x3.isRecordLogDocument(id))
        x3.registerModels([Self.note])
        XCTAssertEqual(try titles(x3), ["row 1", "row 2", "row 3"])
        XCTAssertEqual(try titles(x3, QueryOptions(db3: [id])), ["row 1", "row 2", "row 3"])

        // A client that only ever holds format-1 documents creates no record-log table.
        let plain = try await live.client("plain", models: [Self.note])
        let created = try await plain.createDocument(options: CreateDocumentOptions(title: "format 1"))
        let formatOne = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await plain.openDocument(formatOne, options: OpenDocumentOptions(waitForLoad: .local))
        try plain.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("one")], in: formatOne)
        _ = await plain.closeDocument(formatOne)
        let host = await plain.db3Host()
        XCTAssertFalse(try RecordLogStore.hasTables(host: XCTUnwrap(host)))
        let none = try await plain.db3.stored()
        XCTAssertEqual(none, [])
    }

    private func save(_ client: JsBaoClient, _ db3: String, _ title: String) throws {
        try client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: db3)
    }

    // MARK: - Behaviour 27 and edge 42

    func testEvictIsRefusedWithUnsentWritesThenForcedAndTheNextSubscribeStartsAfresh() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        try await x.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("confirmed")], in: id, confirm: true)
        let firstWriter = try live.binding(x, id).writer
        x.setNetworkMode(.offline)
        try save(x, id, "unsent")

        do {
            let got = await db3Outcome { try await x.db3.evict(id) }
            XCTAssertEqual(got, "DB3_PENDING_WRITES")
        }
        var state = try await x.db3.state(id)
        XCTAssertTrue(state.resident)
        XCTAssertEqual(state.rows, 2)
        XCTAssertEqual(state.pendingWrites, 1)

        let evicted = ThreadSafeBox<[Db3EvictedEvent]>([])
        let refusals = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let byHandle = ThreadSafeBox<[Db3EvictedEvent]>([])
        let a = x.eventEmitter.subscribe(Db3EvictedEvent.self) { event in evicted.mutate { $0.append(event) } }
        let b = x.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refusals.mutate { $0.append(event) } }
        let c = handle.observe { event in
            if case .evicted(let e) = event { byHandle.mutate { $0.append(e) } }
        }
        try await x.db3.evict(id, options: Db3EvictOptions(force: true))
        XCTAssertEqual(byHandle.value, [Db3EvictedEvent(id: id, reason: .explicit)])
        XCTAssertEqual(evicted.value, [Db3EvictedEvent(id: id, reason: .explicit)])
        XCTAssertEqual(refusals.value.map(\.error.code), [.documentStorePurged])
        do {
            let got = await db3Outcome { try await handle.ready() }
            XCTAssertEqual(got, "resolved", "a ready that settled stays settled")
        }
        let stored = try await x.db3.stored()
        XCTAssertFalse(stored.map(\.id).contains(id))
        state = try await x.db3.state(id)
        XCTAssertFalse(state.resident)
        XCTAssertEqual(state.rows, 0)
        XCTAssertEqual(state.pendingWrites, 0)
        XCTAssertFalse(state.subscribed)
        XCTAssertFalse(x.isRecordLogDocument(id))

        x.setNetworkMode(.online)
        try await waitForConnection(client: x, timeout: 15)
        let watch = RecordLogClientWatch(x)
        let again = try x.db3.subscribe(id)
        try await again.ready()
        let open = try XCTUnwrap(watch.sent("record.open").first { $0["documentId"]?.stringValue == id })
        XCTAssertEqual(open["cursor"]?.wholeNumber, 0)
        XCTAssertNotEqual(try live.binding(x, id).writer, firstWriter)
        XCTAssertEqual(try titles(x, QueryOptions(db3: [id])), ["confirmed"])

        // Edge 42: never stored, no handle, never seen: nothing sent, nothing emitted.
        let before = evicted.value.count
        let unseen = RecordLogLiveApp.ulid()
        try await x.db3.evict(unseen)
        x.db3.unsubscribe(unseen)
        let idle = try await x.db3.state(unseen)
        XCTAssertEqual(idle.phase, .idle)
        try await delay(0.3)
        XCTAssertEqual(evicted.value.count, before)
        XCTAssertTrue(watch.sent.filter { $0["documentId"]?.stringValue == unseen }.isEmpty)
        a.cancel()
        b.cancel()
        c.cancel()
    }

    // MARK: - Edge 43

    func testAForcedEvictionWhileSubscribedClosesTheDb3OnTheSocketFirst() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        try await live.subscribersBecome(id, 1)
        let openAtPurge = ThreadSafeBox<[Bool]>([])
        let heard = x.eventEmitter.subscribe(Db3EvictedEvent.self) { _ in
            openAtPurge.mutate { $0.append(x.documentManager.isOpen(id)) }
        }
        try await x.db3.evict(id, options: Db3EvictOptions(force: true))
        XCTAssertEqual(openAtPurge.value, [false], "closed on the socket before the store went")
        try await live.subscribersBecome(id, 0)
        XCTAssertFalse(handle.state.subscribed)
        heard.cancel()
    }

    // MARK: - Behaviour 28

    func testTheRetentionTtlEvictsACleanDb3AndKeepsOneWithUnsentWritesAndOneSubscribed() async throws {
        let clean = try await live.db3Written(1, model: "Note")
        let dirty = try await live.db3Written(1, model: "Note")
        let held = try await live.db3Written(1, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        try await live.residentOn(x, clean)
        try await live.residentOn(x, dirty)
        let holding = try x.db3.subscribe(held)
        try await holding.ready()
        x.setNetworkMode(.offline)
        try save(x, dirty, "unsent")
        let evicted = ThreadSafeBox<[Db3EvictedEvent]>([])
        let heard = x.eventEmitter.subscribe(Db3EvictedEvent.self) { event in evicted.mutate { $0.append(event) } }
        try await delay(0.05)
        x.db3.setRetentionPolicy(RetentionPolicy(ttl: 0.01))
        try await eventually(timeout: 15, description: "the retention eviction") { evicted.value.contains { $0.id == clean } }
        try await delay(0.5)
        XCTAssertEqual(
            evicted.value.filter { [clean, dirty, held].contains($0.id) }, [Db3EvictedEvent(id: clean, reason: .retention)]
        )
        let gone = try await x.db3.state(clean)
        XCTAssertFalse(gone.resident)
        let kept = try await x.db3.state(dirty)
        XCTAssertTrue(kept.resident)
        XCTAssertEqual(kept.pendingWrites, 1)
        let subscribed = try await x.db3.state(held)
        XCTAssertTrue(subscribed.resident)
        XCTAssertTrue(subscribed.subscribed)
        heard.cancel()
    }

    // MARK: - Behaviour 29

    func testStoredListsTheUsersDb3sAPendingCreateIncludedAndAnEvictedOneNot() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let e = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        try await live.residentOn(x, a)
        try await live.residentOn(x, b)
        try await live.residentOn(x, e)
        try save(x, a, "in a")
        try await x.db3.evict(e, options: Db3EvictOptions(force: true))
        x.setNetworkMode(.offline)
        let created = try await x.createDocument(options: CreateDocumentOptions(title: "made here", documentFormat: 3))
        let local = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try save(x, local, "local one")
        let stored = try await x.db3.stored()
        XCTAssertEqual(stored.map(\.id), [a, b, local].sorted())
        let first = try XCTUnwrap(stored.first { $0.id == a })
        XCTAssertEqual(first.rows, 1)
        XCTAssertGreaterThanOrEqual(first.cursor, 0)
        XCTAssertEqual(first.pendingWrites, 1)
        XCTAssertNotNil(first.lastSyncAt)
        XCTAssertTrue(first.resident)
        let made = try XCTUnwrap(stored.first { $0.id == local })
        XCTAssertEqual(made.rows, 1)
        XCTAssertEqual(made.pendingWrites, 1)
        XCTAssertNil(made.lastSyncAt)
        XCTAssertTrue(made.resident)
    }

    // MARK: - Behaviour 33

    private func viewRows(_ client: JsBaoClient, _ id: String) async throws -> Int {
        let found = await client.db3Host()
        let host = try XCTUnwrap(found)
        return try host.withConnection {
            try $0.query("SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = ?", [.text(id)]).first?["n"].intValue ?? -1
        }
    }

    private func code(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    func testALogoutUnbindsEveryDb3AndTheSameUsersSignInBindsThemAgain() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let never = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("identity"))
        try await live.residentOn(x, id)
        let gate = Db3FrameGate(x)
        gate.drop(Db3FrameGate.of(never))
        let pending = try x.db3.subscribe(never, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 15, description: "the never-loaded db3 bound") { x.isRecordLogDocument(never) }

        try await x.logout()
        do {
            let got = await db3Outcome { try await pending.ready() }
            XCTAssertEqual(got, "DB3_DISPOSED")
        }
        XCTAssertEqual(try titles(x), [])
        XCTAssertEqual(code { _ = try x.sharedModel(for: Self.note).query(nil, options: QueryOptions(db3: [id])) }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { _ = try x.documents.records(id).query("Note") }, "NOT_FOUND")
        XCTAssertEqual(code { try self.save(x, id, "after the logout") }, "NOT_FOUND")
        XCTAssertFalse(x.isRecordLogDocument(id))
        XCTAssertFalse(x.isRecordLogDocument(never))
        let none = try await x.db3.stored()
        XCTAssertEqual(none, [])
        let kept = try await viewRows(x, id)
        XCTAssertEqual(kept, 2, "the file keeps the rows for the same user's next sign-in")

        // The same user signs in again: bound again, resident.
        x.updateToken(live.app.ownerJWT)
        await x.rebindUserScopedStorage()
        XCTAssertTrue(x.isRecordLogDocument(id))
        let back = try await x.db3.state(id)
        XCTAssertTrue(back.resident)
        XCTAssertEqual(try titles(x), ["row 1", "row 2"])

        // A start-up binding a logout raced is discarded.
        try await x.logout()
        let reached = RecordLogReceiptHarness.Gate()
        let release = RecordLogReceiptHarness.Gate()
        x.db3BindHoldForTest = { _ in
            reached.open()
            await release.wait()
        }
        let ownerJWT = live.app.ownerJWT
        let signIn = Task {
            x.updateToken(ownerJWT)
            await x.rebindUserScopedStorage()
        }
        await reached.wait()
        try await x.logout()
        release.open()
        await signIn.value
        x.db3BindHoldForTest = nil
        try await delay(0.3)
        XCTAssertFalse(x.isRecordLogDocument(id), "the binding finished after the logout and was discarded")
        XCTAssertEqual(try titles(x), [])

        // A wiping logout removes the rows as well.
        x.updateToken(live.app.ownerJWT)
        await x.rebindUserScopedStorage()
        XCTAssertTrue(x.isRecordLogDocument(id))
        try await x.logout(wipeLocal: true)
        XCTAssertFalse(x.isRecordLogDocument(id))
        let wiped = try await viewRows(x, id)
        XCTAssertEqual(wiped, 0)
    }

    func testASignInAsAnotherUserUnbindsThePreviousUsersDb3s() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("switch"))
        try await live.residentOn(x, id)
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let member = try await ctx.createTestUser(appId: live.app.appId)
        x.updateToken(member.jwt)
        await x.rebindUserScopedStorage()
        XCTAssertFalse(x.isRecordLogDocument(id))
        XCTAssertFalse(handle.state.subscribed)
        XCTAssertEqual(try titles(x), [])
        let stored = try await x.db3.stored()
        XCTAssertEqual(stored, [])
        let found = await x.db3Host()
        let host = try XCTUnwrap(found)
        XCTAssertEqual(try RecordLogStore.owner(host: host), member.userId)
    }
}
