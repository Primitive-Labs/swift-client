import XCTest
@testable import JsBaoClient

/// #5101 behaviours 14–18 and 20 (edges E6, E7) — a registered index reaches
/// this device, against the dev server: the Swift twin of js-bao's
/// `tests/client/db3-indexes-device-5070.test.ts`.
///
/// - 14: `register` and `drop` on a subscribed db3 return with the store's
///   view indexes changed; on a disposed copy, or a db3 never bound here, they
///   read nothing, and the next subscribe's `ready()` holds the index.
/// - 15: over three reloads of one file, each after the owner registered an
///   index, the store holds the room's list the moment `ready()` returns.
/// - 16: offline, the open's read fails and is not retried; back online it is
///   read and `ready()` returns with the room's list.
/// - 17: evicted and subscribed again at once, `ready()` returns with the
///   room's list.
/// - 18: a `drop` refused `DB3_INDEX_IN_USE`, and a `register` refused
///   offline, read no list.
/// - 20: a first subscribe whose models declare an indexed field returns from
///   `ready()` with the index the room created for that declaration.
///
/// "Uses the index" is the store's view-index tuples: Swift has no dev-mode
/// scan warning.
final class Db3IndexesDeviceLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
        "views": FieldDescriptor(type: .number), "f1": FieldDescriptor(type: .string), "f2": FieldDescriptor(type: .string),
        "f3": FieldDescriptor(type: .string),
    ])

    /// The same model with `title` declared indexed.
    private static let declaredNote = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string, indexed: true),
        "body": FieldDescriptor(type: .string), "views": FieldDescriptor(type: .number),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-indexes-device-5101")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func tuples(_ indexes: [Db3Index]) -> [RecordLogIndexTuple] {
        indexes.map { RecordLogIndexTuple(model: $0.model, fields: $0.fields, unique: $0.unique) }
            .sorted { ($0.model, $0.fields.joined(separator: "\u{1}")) < ($1.model, $1.fields.joined(separator: "\u{1}")) }
    }

    private func store(_ c: JsBaoClient, _ id: String) throws -> [RecordLogIndexTuple] {
        try live.binding(c, id).store.indexTuples()
    }

    private func reads(_ c: JsBaoClient, _ id: String) -> ThreadSafeBox<Int> {
        let count = ThreadSafeBox<Int>(0)
        c.db3IndexReadForTest = { documentId in if documentId == id { count.mutate { $0 += 1 } } }
        return count
    }

    /// The owner registers an index over HTTP, as another device would.
    private func registerOverHttp(_ id: String, _ field: String) async throws {
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(id)/indexes", body: ["model": "Note", "field": field],
            jwt: live.app.ownerJWT
        )
    }

    private func roomList(_ id: String) async throws -> [RecordLogIndexTuple] {
        let answer = try await ctx.appRequest(method: "GET", appId: live.app.appId, path: "/db3/\(id)/indexes", body: nil, jwt: live.app.ownerJWT)
        let indexes = answer["indexes"] as? [[String: Any]] ?? []
        return indexes.map {
            RecordLogIndexTuple(model: $0["model"] as? String ?? "", fields: $0["fields"] as? [String] ?? [], unique: $0["unique"] as? Bool ?? false)
        }.sorted { ($0.model, $0.fields.joined(separator: "\u{1}")) < ($1.model, $1.fields.joined(separator: "\u{1}")) }
    }

    // MARK: - Behaviour 14

    func testRegisterAndDropOnASubscribedDb3ChangeTheStoreBeforeTheyReturn() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        try await x.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("one"), "views": .number(3)], in: id, confirm: true)

        let views = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "views"))
        XCTAssertTrue(try store(x, id).contains(RecordLogIndexTuple(model: "Note", fields: ["views"], unique: false)),
                      "applied before register returned")
        let found = try x.sharedModel(for: Self.note).query(["views": .number(3)])
        XCTAssertEqual(found.compactMap { $0["title"]?.stringValue }, ["one"])
        try await x.db3.indexes.drop(id, name: views.name)
        XCTAssertFalse(try store(x, id).contains { $0.fields == ["views"] }, "dropped before drop returned")

        // Disposed: the copy is not open here, so nothing is read.
        handle.dispose()
        try await eventually(description: "unsubscribed") { try await !x.db3.state(id).subscribed }
        let count = reads(x, id)
        _ = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "body"))
        XCTAssertEqual(count.value, 0, "a copy not held open reads no list")
        XCTAssertFalse(try store(x, id).contains { $0.fields == ["body"] })
        let again = try x.db3.subscribe(id)
        try await again.ready()
        XCTAssertTrue(try store(x, id).contains(RecordLogIndexTuple(model: "Note", fields: ["body"], unique: false)),
                      "the next subscribe's ready() holds it")
        again.dispose()

        // A db3 this client never bound reads nothing; the room has the index.
        let other = try await live.db3Written(0, model: "Note")
        let otherReads = reads(x, other)
        _ = try await x.db3.indexes.register(other, Db3IndexRegistration(model: "Note", field: "views"))
        XCTAssertEqual(otherReads.value, 0)
        let otherList = try await roomList(other)
        XCTAssertTrue(otherList.contains { $0.fields == ["views"] })
    }

    // MARK: - Behaviour 15

    func testOverThreeReloadsTheStoreHoldsTheRoomsListTheMomentReadyReturns() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let file = live.file("reloads")
        let first = try await live.client("first", models: [Self.note], file: file)
        let opened = try first.db3.subscribe(id)
        try await opened.ready()
        opened.dispose()
        await first.destroy()

        for field in ["f1", "f2", "f3"] {
            try await registerOverHttp(id, field)
            let c = try await live.client("reload-\(field)", models: [Self.note], file: file)
            let handle = try c.db3.subscribe(id)
            try await handle.ready()
            let held = try store(c, id)
            let room = try await roomList(id)
            XCTAssertEqual(held, room, "after registering \(field)")
            handle.dispose()
            await c.destroy()
        }
    }

    // MARK: - Behaviour 16

    func testOfflineTheReadFailsOnceAndOnlineReadyReturnsWithTheRoomsList() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let file = live.file("offline")
        let first = try await live.client("first", models: [Self.note], file: file)
        let opened = try first.db3.subscribe(id)
        try await opened.ready()
        opened.dispose()
        await first.destroy()
        try await registerOverHttp(id, "views")

        let c = try await live.client("offline", models: [Self.note], file: file)
        let count = reads(c, id)
        c.setNetworkMode(.offline)
        let handle = try c.db3.subscribe(id)
        let ready = Task { try await handle.ready() }
        try await handle.available()
        try await eventually(timeout: 10, description: "the open's read failed") { count.value == 1 && c.db3IndexRefresher.owed(id) }
        try await delay(3)
        XCTAssertEqual(count.value, 1, "no read is retried offline")
        XCTAssertFalse(try store(c, id).contains { $0.fields == ["views"] })

        c.setNetworkMode(.online)
        try await settles(within: 20, "ready() online") { try await ready.value }
        XCTAssertGreaterThan(count.value, 1)
        let held = try store(c, id)
        let room = try await roomList(id)
        XCTAssertEqual(held, room)
        handle.dispose()
    }

    // MARK: - Behaviour 17 (E7)

    func testEvictedAndSubscribedAgainAtOnceReadyReturnsWithTheRoomsList() async throws {
        let id = try await live.db3Written(0, model: "Note")
        try await registerOverHttp(id, "views")
        let c = try await live.client("evict", models: [Self.note])
        let first = try c.db3.subscribe(id)
        try await first.available()
        try await c.db3.evict(id, options: Db3EvictOptions(force: true))
        let again = try c.db3.subscribe(id)
        try await settles(within: 20, "ready() after the eviction") { try await again.ready() }
        let held = try store(c, id)
        let room = try await roomList(id)
        XCTAssertEqual(held, room)
        again.dispose()
    }

    // MARK: - Behaviour 18 (E6)

    func testARefusedDropAndARefusedRegisterReadNoList() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let c = try await live.client("refused", models: [Self.declaredNote])
        let handle = try c.db3.subscribe(id)
        try await handle.ready()
        let listed = try await c.db3.indexes.list(id)
        let declared = try XCTUnwrap(listed.first { $0.fields == ["title"] })
        let count = reads(c, id)
        do {
            try await c.db3.indexes.drop(id, name: declared.name)
            XCTFail("a declared index is in use")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "DB3_INDEX_IN_USE")
        }
        c.setNetworkMode(.offline)
        do {
            _ = try await c.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "views"))
            XCTFail("offline, the route is not reached")
        } catch {}
        c.setNetworkMode(.online)
        try await delay(0.5)
        XCTAssertEqual(count.value, 0, "a refused register or drop reads no list")
        handle.dispose()
    }

    // MARK: - Behaviour 20: the declaration's index is in the store at ready()

    func testAFirstSubscribeReturnsFromReadyWithTheIndexItsDeclarationCreated() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let before = try await roomList(id)
        XCTAssertFalse(before.contains { $0.fields == ["title"] }, "no index yet")
        let c = try await live.client("declares", models: [Self.declaredNote])
        let frames = ThreadSafeBox<[String]>([])
        c.recordLogFrameSentForTest = { text in
            if text.contains("\"record.declare\"") { frames.mutate { $0.append(text) } }
        }
        let handle = try c.db3.subscribe(id)
        try await settles(within: 20, "ready()") { try await handle.ready() }
        let declaredBeforeReady = frames.value.count
        let held = try store(c, id)
        let room = try await roomList(id)
        XCTAssertTrue(held.contains(RecordLogIndexTuple(model: "Note", fields: ["title"], unique: false)), "\(held)")
        XCTAssertEqual(held, room)
        XCTAssertGreaterThan(declaredBeforeReady, 0, "the declaration left before ready() returned")
        handle.dispose()
    }
}
