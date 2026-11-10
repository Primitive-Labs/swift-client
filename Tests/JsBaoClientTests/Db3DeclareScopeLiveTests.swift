import XCTest
@testable import JsBaoClient

/// #5160 behaviours 14–18 — a Swift client declares into an untyped db3 only
/// the models it uses there, against the dev server: the Swift twin of
/// js-bao's `tests/client/db3-declare-scope-5115.test.ts`.
///
/// - 14: one client, two untyped db3s, M1 saved into X and M2 into Y: X's
///   `record.declare` frames never name M2 and Y's never name M1; registering
///   M3 sends nothing to X; once M3 is saved into Y, X's later opens (a
///   subscribe after a dispose, a reconnect) name only M1; the room's schema
///   for X holds neither M2 nor M3.
/// - 15: a model with a unique field first saved into an open db3 whose open
///   declared nothing is declared before the entry carrying the save; the room
///   lists it, a second client's save of the same value is refused
///   `DOCUMENT_CONSTRAINT_VIOLATED`, and a second save declares nothing more.
/// - 16: a model bound to Y with `setModelDefaultDb3` before the subscribe is
///   declared at Y's open, not X's, and its index is in the room's list and
///   the store's at `ready()`; with X the default db3, X's next open declares
///   every model bound nowhere, and Y only its bound models.
/// - 17: an empty, unbound db3's subscribe sends one declare with no model
///   before `ready()` returns, and the room's schema lists no model.
/// - 18: a new client over the store file of one that saved M1 into X
///   declares M1 at X's first open, before any write, and not M2.
final class Db3DeclareScopeLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-declare-scope-5160")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static func plain(_ name: String) -> PrimitiveSchema {
        PrimitiveSchema(name: name, fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string, indexed: true)])
    }

    /// The frames one client's record-log sessions sent, parsed.
    final class SentFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [JSONValue] = []

        func add(_ text: String) {
            guard let frame = try? JSONCoding.decodeData(JSONValue.self, from: Data(text.utf8)) else { return }
            lock.withLock { _frames.append(frame) }
        }

        var all: [JSONValue] { lock.withLock { _frames } }

        func of(_ db3Id: String, _ type: String? = nil) -> [JSONValue] {
            all.filter { $0["documentId"]?.stringValue == db3Id && (type == nil || $0["type"]?.stringValue == type) }
        }

        /// The model names of each `record.declare` sent for `db3Id`.
        func declared(_ db3Id: String) -> [[String]] {
            of(db3Id, "record.declare").map { ($0["models"]?.objectValue ?? [:]).keys.sorted() }
        }

        func named(_ db3Id: String) -> Set<String> { Set(declared(db3Id).flatMap { $0 }) }
    }

    /// A client over its own store file (or `file`), whose frames are captured from before it connects.
    private func client(_ name: String, models: [PrimitiveSchema], file: String? = nil) async throws -> (JsBaoClient, SentFrames) {
        let sent = SentFrames()
        let client = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT,
            storageConfig: .sqlite(directory: file ?? live.file("\(name)-\(UUID().uuidString.prefix(4))")), autoNetwork: true
        )
        client.recordLogFrameSentForTest = { text in sent.add(text) }
        client.registerModels(models)
        clients.append(client)
        _ = await client.waitForStorageReady()
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
        return (client, sent)
    }

    private func schemaModels(_ db3Id: String) async throws -> Set<String> {
        let answer = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/db3/\(db3Id)/schema", body: nil, jwt: live.app.ownerJWT
        )
        return Set(((answer["schema"] as? [String: Any])?["models"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    private func roomIndexes(_ db3Id: String) async throws -> [RecordLogIndexTuple] {
        let answer = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/db3/\(db3Id)/indexes", body: nil, jwt: live.app.ownerJWT
        )
        return ((answer["indexes"] as? [[String: Any]]) ?? []).map { index in
            RecordLogIndexTuple(
                model: index["model"] as? String ?? "", fields: index["fields"] as? [String] ?? [],
                unique: index["unique"] as? Bool ?? false
            )
        }
    }

    private func save(_ client: JsBaoClient, _ model: PrimitiveSchema, _ db3Id: String, _ values: [String: PrimitiveValue]) async throws -> String {
        let id = RecordLogLiveApp.ulid()
        try await client.codegen.save(model, id: id, values: values, in: db3Id, confirm: true)
        return id
    }

    private func disposed(_ client: JsBaoClient, _ handle: Db3Subscription, _ db3Id: String) async throws {
        handle.dispose()
        try await eventually(timeout: 15, description: "\(db3Id) to be unsubscribed") {
            let state = try await client.db3.state(db3Id)
            return !state.subscribed && state.phase == .idle
        }
    }

    // MARK: - Behaviour 14

    func testEachDb3HearsOnlyItsOwnModelsAndARegistrationElsewhereNeverReachesX() async throws {
        let m1 = Self.plain("rl5160_scope_m1")
        let m2 = Self.plain("rl5160_scope_m2")
        let m3 = Self.plain("rl5160_scope_m3")
        let (c, sent) = try await client("scope", models: [m1, m2])
        let x = try await live.db3Written(0, model: m1.name)
        let y = try await live.db3Written(0, model: m2.name)

        let hx = try c.db3.subscribe(x)
        try await hx.ready()
        _ = try await save(c, m1, x, ["title": .string("in x")])
        let hy = try c.db3.subscribe(y)
        try await hy.ready()
        _ = try await save(c, m2, y, ["title": .string("in y")])
        try await eventually(timeout: 15, description: "X's declaration of M1") { sent.named(x).contains(m1.name) }
        try await eventually(timeout: 15, description: "Y's declaration of M2") { sent.named(y).contains(m2.name) }
        XCTAssertFalse(sent.named(x).contains(m2.name), "\(sent.declared(x))")
        XCTAssertFalse(sent.named(y).contains(m1.name), "\(sent.declared(y))")

        // Registering a model sends nothing to X.
        let before = sent.of(x).count
        c.registerModels([m3])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sent.of(x).count, before, "a registration bound nowhere sends nothing to X")
        _ = try await save(c, m3, y, ["title": .string("in y")])
        try await live.settled(c, y)

        // X opened again: after a dispose, then across a reconnect.
        let declaresBefore = sent.declared(x).count
        try await disposed(c, hx, x)
        let again = try c.db3.subscribe(x)
        try await again.ready()
        try await eventually(timeout: 15, description: "X's declaration on its next open") { sent.declared(x).count > declaresBefore }
        XCTAssertEqual(sent.declared(x).last, [m1.name])
        let opensBefore = sent.of(x, "record.open").count
        let declaresAtReconnect = sent.declared(x).count
        await c.goOffline()
        XCTAssertFalse(c.isConnected)
        await c.goOnline()
        try await waitForConnection(client: c, timeout: 15)
        try await eventually(timeout: 20, description: "X opened again after the reconnect") { sent.of(x, "record.open").count > opensBefore }
        try await eventually(timeout: 20, description: "X's declaration after the reconnect") { sent.declared(x).count > declaresAtReconnect }
        XCTAssertEqual(sent.declared(x).last, [m1.name])

        for leaked in [m2.name, m3.name] { XCTAssertFalse(sent.named(x).contains(leaked), "\(leaked) reached X: \(sent.declared(x))") }
        XCTAssertTrue(sent.named(y).contains(m3.name), "M3's first save into Y declared it there")
        let roomX = try await schemaModels(x)
        XCTAssertTrue(roomX.contains(m1.name), "\(roomX)")
        XCTAssertFalse(roomX.contains(m2.name), "\(roomX)")
        XCTAssertFalse(roomX.contains(m3.name), "\(roomX)")
        again.dispose()
        hy.dispose()
    }

    // MARK: - Behaviour 15

    func testAModelFirstSavedIntoAnOpenDb3IsDeclaredBeforeItsEntryItsConstraintHoldsAndOnlyOnce() async throws {
        let unique = PrimitiveSchema(name: "rl5160_scope_unique", fields: [
            "id": FieldDescriptor(type: .id), "slug": FieldDescriptor(type: .string, unique: true),
        ])
        let (a, sentA) = try await client("a", models: [unique])
        let (b, _) = try await client("b", models: [unique])
        let z = try await live.db3Written(0, model: unique.name)
        let ha = try a.db3.subscribe(z)
        let hb = try b.db3.subscribe(z)
        try await ha.ready()
        try await hb.ready()
        try await eventually(timeout: 15, description: "a's open declaration") { !sentA.declared(z).isEmpty }
        XCTAssertEqual(sentA.declared(z), [[]], "the open declared nothing: the db3 held nothing of a's and nothing is bound")

        await b.goOffline()
        XCTAssertFalse(b.isConnected)
        let winner = try await save(a, unique, z, ["slug": .string("taken")])
        let frames = sentA.of(z)
        let declareAt = try XCTUnwrap(frames.firstIndex {
            $0["type"]?.stringValue == "record.declare" && $0["models"]?[unique.name] != nil
        })
        let entryAt = try XCTUnwrap(frames.firstIndex {
            $0["type"]?.stringValue == "record.entries"
                && ($0["entries"]?.arrayValue ?? []).contains { $0["m"]?["id"]?.stringValue == winner }
        })
        XCTAssertGreaterThan(entryAt, declareAt, "the declaration left before the entry")
        XCTAssertEqual(frames[declareAt]["models"]?[unique.name]?["fields"]?["slug"]?["unique"], true)
        let schema = try await schemaModels(z)
        XCTAssertTrue(schema.contains(unique.name), "\(schema)")

        // The second client saves the same value offline: the room refuses it.
        let refusals = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let listening = b.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refusals.mutate { $0.append(event) } }
        let loser = RecordLogLiveApp.ulid()
        try b.codegen.save(unique, id: loser, values: ["slug": .string("taken")], in: z)
        await b.goOnline()
        try await eventually(timeout: 20, description: "the room's refusal of the second client's save") { !refusals.value.isEmpty }
        listening.cancel()
        XCTAssertEqual(refusals.value.first?.recordId, loser)
        XCTAssertEqual(refusals.value.first?.error.code, .documentConstraintViolated)

        _ = try await save(a, unique, z, ["slug": .string("second")])
        XCTAssertEqual(sentA.of(z, "record.declare").count, 2, "a second save declares nothing more")
        ha.dispose()
        hb.dispose()
    }

    // MARK: - Behaviour 16 (E3)

    func testBoundModelsAreDeclaredWhereBoundAndTheDefaultDb3TakesOnlyTheModelsBoundNowhere() async throws {
        let m1 = Self.plain("rl5160_bind_m1")
        let m2 = Self.plain("rl5160_bind_m2")
        let m4 = Self.plain("rl5160_bind_m4")
        let m5 = Self.plain("rl5160_bind_m5")
        let (c, sent) = try await client("bind", models: [m1, m2, m4])
        let x = try await live.db3Written(0, model: m1.name)
        let y = try await live.db3Written(0, model: m4.name)

        // Bound before the subscribe, on a device that never held Y.
        c.setModelDefaultDb3(m4.name, y)
        var hy = try c.db3.subscribe(y)
        var hx = try c.db3.subscribe(x)
        try await hy.ready()
        let held = try live.binding(c, y).store.indexTuples()
        try await hx.ready()
        XCTAssertTrue(held.contains(RecordLogIndexTuple(model: m4.name, fields: ["title"], unique: false)), "\(held)")
        let room = try await roomIndexes(y)
        XCTAssertTrue(room.contains(RecordLogIndexTuple(model: m4.name, fields: ["title"], unique: false)), "\(room)")
        try await eventually(timeout: 15, description: "both opens' declarations") {
            sent.declared(y).count == 1 && sent.declared(x).count == 1
        }
        XCTAssertEqual(sent.declared(y), [[m4.name]])
        XCTAssertEqual(sent.declared(x), [[]])

        c.registerModels([m5])
        try await Task.sleep(nanoseconds: 500_000_000)
        c.setModelDefaultDb3(m5.name, y)
        try c.setDefaultDb3(x)
        try await disposed(c, hx, x)
        try await disposed(c, hy, y)
        hx = try c.db3.subscribe(x)
        hy = try c.db3.subscribe(y)
        try await hx.ready()
        try await hy.ready()
        try await eventually(timeout: 15, description: "both reopens' declarations") {
            sent.declared(y).count == 2 && sent.declared(x).count == 2
        }
        XCTAssertEqual(sent.declared(x)[1], [m1.name, m2.name], "the default takes every model bound nowhere")
        XCTAssertEqual(sent.declared(y)[1], [m4.name, m5.name], "Y declares only its bound models")
        hx.dispose()
        hy.dispose()
    }

    // MARK: - Behaviour 17

    func testAnEmptyUnboundSubscribeDeclaresNoModelBeforeReady() async throws {
        let m1 = Self.plain("rl5160_empty_m1")
        let (c, sent) = try await client("empty", models: [m1])
        let x = try await live.db3Written(0, model: m1.name)
        let handle = try c.db3.subscribe(x)
        try await settles(within: 20, "ready()") { try await handle.ready() }
        XCTAssertEqual(sent.declared(x), [[]], "exactly one declare, naming no model, before ready() returned")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sent.declared(x), [[]])
        let schema = try await schemaModels(x)
        XCTAssertEqual(schema, [], "the room's schema lists no model")
        handle.dispose()
    }

    // MARK: - Behaviour 18

    func testAfterARelaunchXsFirstOpenDeclaresTheModelsItsCopyHolds() async throws {
        let file = live.file("relaunch-\(UUID().uuidString.prefix(4))")
        let before = Self.plain("rl5160_relaunch_m1")
        let (first, _) = try await client("first", models: [before], file: file)
        let x = try await live.db3Written(0, model: before.name)
        let handle = try first.db3.subscribe(x)
        try await handle.ready()
        _ = try await save(first, before, x, ["title": .string("kept")])
        try await live.settled(first, x)
        try await disposed(first, handle, x)
        clients.removeAll { $0 === first }
        await first.destroy()

        let m1 = Self.plain("rl5160_relaunch_m1")
        let m2 = Self.plain("rl5160_relaunch_m2")
        let (second, sent) = try await client("second", models: [m1, m2], file: file)
        let again = try second.db3.subscribe(x)
        try await again.ready()
        try await eventually(timeout: 15, description: "the relaunched open's declaration") { !sent.declared(x).isEmpty }
        XCTAssertEqual(sent.declared(x).first, [m1.name])
        XCTAssertFalse(sent.named(x).contains(m2.name))
        again.dispose()
    }
}
