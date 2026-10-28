import XCTest
@testable import JsBaoClient

/// #4701 behaviours 17–19 and 21–23, edge 44 — a db3's residency on this
/// device against the dev server, the Swift twin of js-bao's
/// `tests/client/db3-residency-4698.test.ts`:
///
/// - 17: a resident, unsubscribed db3 answers the model API and
///   `documents.records` from its store and queues writes; the room delivers
///   nothing to it while unsubscribed; the next subscribe opens from the stored
///   cursor, and the queued writes land as an offline write's through the open
///   door do.
/// - 18: a bound db3 whose cold load was interrupted is not resident: left out
///   of an unscoped read, refused `DB3_NOT_RESIDENT` when named by
///   `QueryOptions(db3:)`, saved into, or read model-free, while a model-free
///   put is queued; a new client over the same file reads it the same, and
///   its subscribe resumes it.
/// - 19: `available()` tells an empty db3 that synced, a populated one and one
///   created here offline from one never loaded.
/// - 21: `Db3RowsEvent` by origin and with a bulk load's models;
///   `Db3WriteRefusedEvent` beside `DocumentWriteRefusedEvent`.
/// - 22: a resident db3 under a full replacement reads its previous rows while
///   loading, and the replacement's once live.
/// - 23: subscribing offline; the save destination and the default-document
///   setters on a resident, unsubscribed db3; the scope conflict.
/// - 44: a db3 whose format nothing local knows, subscribed offline.
final class Db3ResidencyLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, indexed: true, unique: true),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-residency-4701")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    @discardableResult
    private func save(_ client: JsBaoClient, _ db3: String, _ title: String, slug: String? = nil) throws -> String {
        let id = RecordLogLiveApp.ulid()
        var values: [String: PrimitiveValue] = ["title": .string(title)]
        if let slug { values["slug"] = .string(slug) }
        try client.codegen.save(Self.note, id: id, values: values, in: db3)
        return id
    }

    @discardableResult
    private func confirmed(_ client: JsBaoClient, _ db3: String, _ title: String, id: String? = nil) async throws -> String {
        let id = id ?? RecordLogLiveApp.ulid()
        try await client.codegen.save(Self.note, id: id, values: ["title": .string(title)], in: db3, confirm: true)
        return id
    }

    private func titles(_ client: JsBaoClient, _ options: QueryOptions? = nil) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil, options: options).compactMap { $0["title"]?.stringValue }.sorted()
    }

    private func code(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    // MARK: - Behaviour 17

    func testAResidentUnsubscribedDb3AnswersQueuesAndCatchesUpFromItsCursor() async throws {
        let x = try await live.client("x", models: [Self.note])
        let y = try await live.client("y", models: [Self.note])
        let w = try await live.client("w", models: [Self.note])
        let id = try await live.createDocument(x)
        let legacy = try await live.createDocument(w)

        let subscribed = try x.db3.subscribe(id)
        try await subscribed.ready()
        let keep = try await confirmed(x, id, "kept")
        let gone = try await confirmed(x, id, "deleted offline")
        subscribed.dispose()
        try await live.subscribersBecome(id, 0)

        // Another client's write is not delivered while x is unsubscribed.
        let watch = RecordLogClientWatch(x)
        let other = try y.db3.subscribe(id)
        try await other.ready()
        try await confirmed(y, id, "from y")
        try await delay(1)
        XCTAssertTrue(watch.received("record.results").filter { $0.frame["documentId"]?.stringValue == id }.isEmpty)
        XCTAssertEqual(try titles(x), ["deleted offline", "kept"])

        // Offline writes queue; reads answer from the store.
        let cursor = try live.marks(x, id).cursor
        x.setNetworkMode(.offline)
        let notified = ThreadSafeBox(0)
        let stop = x.codegen.subscribe(Self.note) { notified.mutate { $0 += 1 } }
        try save(x, id, "queued offline")
        try x.codegen.delete(Self.note, id: gone, in: id)
        stop()
        XCTAssertGreaterThan(notified.value, 0)
        let pending = try await x.db3.state(id).pendingWrites
        XCTAssertEqual(pending, 2)
        XCTAssertEqual(try titles(x), ["kept", "queued offline"])
        XCTAssertEqual(try titles(x, QueryOptions(db3: [id])), ["kept", "queued offline"])
        XCTAssertEqual(try x.sharedModel(for: Self.note).count(nil, options: QueryOptions(db3: [id])), 2)
        XCTAssertEqual(x.sharedModel(for: Self.note).find(id: keep)?.row["title"]?.stringValue, "kept")
        let page = try x.documents.records(id).query("Note")
        XCTAssertEqual(page.data.compactMap { $0.raw["title"]?.stringValue }.sorted(), ["kept", "queued offline"])

        // The next subscribe opens from the stored cursor; nothing is replaced whole.
        x.setNetworkMode(.online)
        try await waitForConnection(client: x, timeout: 15)
        let again = try x.db3.subscribe(id)
        try await again.ready()
        try await live.settled(x, id)
        let open = try XCTUnwrap(watch.sent("record.open").first { $0["documentId"]?.stringValue == id })
        XCTAssertEqual(open["cursor"]?.wholeNumber, cursor)
        let opened = try XCTUnwrap(watch.received("record.opened").map(\.frame).last { $0["documentId"]?.stringValue == id })
        XCTAssertNotEqual(opened["catchUp"]?["mode"]?.stringValue, "full")
        XCTAssertNotEqual(opened["catchUp"]?["full"], .bool(true))
        XCTAssertEqual(try titles(x, QueryOptions(db3: [id])), ["from y", "kept", "queued offline"])

        // The same writes through the open door, offline then online, land the same rows.
        try await live.open(w, legacy)
        try await confirmed(w, legacy, "kept")
        let legacyGone = try await confirmed(w, legacy, "deleted offline")
        w.setNetworkMode(.offline)
        try save(w, legacy, "queued offline")
        try w.codegen.delete(Self.note, id: legacyGone, in: legacy)
        w.setNetworkMode(.online)
        try await live.settled(w, legacy)
        let rowsOf = { (doc: String) async throws -> [String] in
            try await self.live.roomRows(doc, "Note").values.compactMap { $0["title"] as? String }.filter { $0 != "from y" }.sorted()
        }
        let viaDb3 = try await rowsOf(id)
        let viaDoor = try await rowsOf(legacy)
        XCTAssertEqual(viaDb3, viaDoor)
        XCTAssertEqual(viaDb3, ["kept", "queued offline"])
    }

    // MARK: - Behaviour 18

    func testABoundDb3WhoseColdLoadWasInterruptedIsNotResidentAndRefusedWhenNamed() async throws {
        let big = try await live.db3Written(2_000, model: "Note", pageRows: 100)
        let file = live.file("interrupted")
        let x = try await live.client("x", models: [Self.note], file: file)
        let small = try await live.createDocument(x)
        try await live.residentOn(x, small)
        try save(x, small, "in the resident one")
        let gate = Db3FrameGate(x)
        let pages = ThreadSafeBox(0)
        gate.drop { frame in
            guard frame["documentId"]?.stringValue == big, frame["type"]?.stringValue == "record.catchUpPage" else { return false }
            var count = 0
            pages.mutate { $0 += 1; count = $0 }
            return count > 2
        }
        let handle = try x.db3.subscribe(big, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 30, description: "the cold load to start") { pages.value > 2 }
        handle.dispose()
        let state = try await x.db3.state(big)
        XCTAssertFalse(state.resident)
        XCTAssertTrue(x.isRecordLogDocument(big), "bound, not resident")

        XCTAssertEqual(try titles(x), ["in the resident one"], "an unscoped read leaves it out")
        do {
            _ = try x.sharedModel(for: Self.note).query(nil, options: QueryOptions(db3: [big]))
            XCTFail("a db3 scope naming it is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3NotResident)
            XCTAssertEqual(error.details?["documents"], .array([.string(big)]))
        }
        XCTAssertEqual(code { try self.save(x, big, "into it") }, "DB3_NOT_RESIDENT")
        let records = x.documents.records(big)
        XCTAssertEqual(code { _ = try records.get("Note", id: "p000001") }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { _ = try records.query("Note") }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { _ = try records.count("Note") }, "DB3_NOT_RESIDENT")
        try records.put("Note", ["id": .string(RecordLogLiveApp.ulid()), "title": "queued model-free"])
        let queued = try await x.db3.state(big).pendingWrites
        XCTAssertEqual(queued, 1, "a model-free write is queued, as in JS")

        gate.drop(Db3FrameGate.of(big))
        let waiting = try x.db3.subscribe(big, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await delay(0.5)
        XCTAssertNil(waiting.availableResult, "available waits for the load")
        waiting.dispose()

        // A new client over the same file reads it the same, and resumes it.
        await x.destroy()
        let x2 = try await live.client("x2", models: [Self.note], file: file)
        let reopened = try await x2.db3.state(big)
        XCTAssertFalse(reopened.resident)
        XCTAssertTrue(reopened.subscribed == false)
        let again = x2.documents.records(big)
        XCTAssertEqual(code { _ = try again.get("Note", id: "p000001") }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { _ = try again.query("Note") }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { _ = try again.count("Note") }, "DB3_NOT_RESIDENT")
        let resumed = try x2.db3.subscribe(big)
        try await resumed.available()
        try await resumed.ready()
        let after = try await x2.db3.state(big)
        XCTAssertTrue(after.resident)
        // x's queued put drains as an orphan writer's entry of the new client.
        try await eventually(timeout: 20, description: "the queued put to land") { try again.count("Note") == 2_001 }
        XCTAssertNotNil(try again.get("Note", id: "p000001"))
        XCTAssertEqual(try titles(x2, QueryOptions(limit: 10_000, db3: [big])).count, 2_001)
    }

    // MARK: - Behaviour 19

    func testAvailableTellsAnEmptyDb3FromOneNotLoaded() async throws {
        // Created by another client: a db3 created here is resident at once.
        let neverLoaded = try await live.db3Written(0, model: "Note")
        let empty = try await live.db3Written(0, model: "Note")
        let populated = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let gate = Db3FrameGate(x)

        let stopNever = gate.drop(Db3FrameGate.of(neverLoaded))
        let waiting = try x.db3.subscribe(neverLoaded, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await delay(1)
        XCTAssertNil(waiting.availableResult)
        let unloaded = try await x.db3.state(neverLoaded)
        XCTAssertFalse(unloaded.resident)
        let records = x.documents.records(neverLoaded)
        XCTAssertEqual(code { _ = try records.query("Note") }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { _ = try records.count("Note") }, "DB3_NOT_RESIDENT")
        stopNever()
        waiting.dispose()

        try await live.residentOn(x, empty)
        let synced = try await x.db3.state(empty)
        XCTAssertTrue(synced.resident)
        XCTAssertEqual(synced.rows, 0)
        XCTAssertNotNil(synced.lastSyncAt)
        try await live.residentOn(x, populated)
        try save(x, populated, "one")
        _ = try await x.db3.refresh(populated)
        for id in [empty, populated] {
            let stop = gate.drop(Db3FrameGate.of(id))
            let handle = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
            try await delay(0.2)
            do {
                let got = await db3Outcome { try await handle.available() }
                XCTAssertEqual(got, "resolved")
            }
            let answered = try x.documents.records(id).query("Note").data.compactMap { $0.raw["title"]?.stringValue }
            XCTAssertEqual(answered, id == empty ? [] : ["one"])
            stop()
            handle.dispose()
        }

        // Created here while offline: resident at once, its rows pending, never synced.
        x.setNetworkMode(.offline)
        let created = try await x.createDocument(options: CreateDocumentOptions(title: "made offline", documentFormat: 3))
        let local = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        let first = try save(x, local, "first")
        try save(x, local, "second")
        let made = try await x.db3.state(local)
        XCTAssertTrue(made.resident)
        XCTAssertEqual(made.pendingWrites, 2)
        XCTAssertNil(made.lastSyncAt)
        let handle = try x.db3.subscribe(local, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await delay(0.2)
        do {
            let got = await db3Outcome { try await handle.available() }
            XCTAssertEqual(got, "resolved")
        }
        XCTAssertEqual(try x.documents.records(local).get("Note", id: first)?.raw["title"]?.stringValue, "first")
        handle.dispose()
    }

    // MARK: - Behaviour 21

    func testRowsEventsByOriginAndTheRefusalUnderBothNames() async throws {
        let x = try await live.client("x", models: [Self.note])
        let y = try await live.client("y", models: [Self.note])
        let id = try await live.createDocument(x)
        let rows = ThreadSafeBox<[Db3RowsEvent]>([])
        let heard = x.eventEmitter.subscribe(Db3RowsEvent.self) { event in rows.mutate { $0.append(event) } }
        let hx = try x.db3.subscribe(id)
        let hy = try y.db3.subscribe(id)
        try await hx.ready()
        try await hy.ready()
        let mine = try save(x, id, "mine")
        try await eventually(description: "a local Db3RowsEvent") {
            rows.value.contains { $0.id == id && $0.origin == .local && $0.changes.contains { $0.id == mine } }
        }
        let theirs = try await confirmed(y, id, "theirs")
        try await eventually(timeout: 15, description: "a remote Db3RowsEvent") {
            rows.value.contains { $0.id == id && $0.origin == .remote && $0.changes.contains { $0.id == theirs } }
        }
        XCTAssertEqual(rows.value.first { $0.changes.contains { $0.id == theirs } }?.changes.first { $0.id == theirs }?.row?["title"], .string("theirs"))
        heard.cancel()

        // A bulk change: a cold load received as chunks names its models.
        let big = try await live.db3Written(7_000, model: "Note")
        let z = try await live.client("z", models: [Self.note])
        let bulk = ThreadSafeBox<[Db3RowsEvent]>([])
        let bulkHeard = z.eventEmitter.subscribe(Db3RowsEvent.self) { event in bulk.mutate { $0.append(event) } }
        let hz = try z.db3.subscribe(big)
        try await hz.ready()
        XCTAssertTrue(bulk.value.contains { $0.id == big && ($0.models ?? []).contains("Note") }, "\(bulk.value.map(\.models))")
        bulkHeard.cancel()

        // A constraint refusal: the same fields under both names.
        hx.dispose()
        try await eventually(description: "x unsubscribed") { try await !x.db3.state(id).subscribed }
        try await y.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("holds"), "slug": .string("dup")], in: id, confirm: true)
        x.setNetworkMode(.offline)
        let document = ThreadSafeBox<[DocumentWriteRefusedEvent]>([])
        let db3 = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let a = x.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in document.mutate { $0.append(event) } }
        let b = x.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in db3.mutate { $0.append(event) } }
        let loser = try save(x, id, "loses", slug: "dup")
        x.setNetworkMode(.online)
        try await waitForConnection(client: x, timeout: 15)
        let back = try x.db3.subscribe(id)
        try await back.ready()
        try await eventually(timeout: 15, description: "the refusal under both names") {
            document.value.count == 1 && db3.value.count == 1
        }
        let one = try XCTUnwrap(document.value.first)
        let two = try XCTUnwrap(db3.value.first)
        XCTAssertEqual(two.documentId, one.documentId)
        XCTAssertEqual(two.model, one.model)
        XCTAssertEqual(two.recordId, one.recordId)
        XCTAssertEqual(two.recordId, loser)
        XCTAssertEqual(two.error.code, one.error.code)
        XCTAssertEqual(two.error.code, .documentConstraintViolated)
        a.cancel()
        b.cancel()
    }

    // MARK: - Behaviour 22

    func testAResidentDb3ReadsItsPreviousRowsDuringAFullReplacement() async throws {
        let x = try await live.client("x", models: [Self.note])
        let y = try await live.client("y", models: [Self.note])
        let id = try await live.createDocument(y)
        let hy = try y.db3.subscribe(id)
        try await hy.ready()
        let changed = try await confirmed(y, id, "before")
        let removed = try await confirmed(y, id, "removed later")
        for i in 0..<6 { try await confirmed(y, id, "filler \(i)") }
        try await live.residentOn(x, id)
        let previous = try titles(x, QueryOptions(db3: [id]))
        XCTAssertTrue(previous.contains("before"))

        // While x is away the room changes and compacts past x's cursor.
        try await confirmed(y, id, "after", id: changed)
        try y.codegen.delete(Self.note, id: removed, in: id)
        try await confirmed(y, id, "added")
        try await live.settled(y, id)
        let lsn = try await live.roomLsn(id)
        _ = try await live.route(id, "checkpoint", ["epochFloor": 0, "cursorFloor": lsn, "keepWriters": true])
        _ = try await live.route(id, "set-limits", ["catchUpInlineRows": 2, "catchUpPageRows": 2])

        x.recordLogFrameGateForTest = { frame in
            if frame["documentId"]?.stringValue == id, frame["type"]?.stringValue == "record.catchUpPage" {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            return true
        }
        let handle = try x.db3.subscribe(id)
        try await eventually(timeout: 20, description: "the replacement to be loading") { handle.state.phase == .loading }
        XCTAssertTrue(handle.state.resident)
        XCTAssertEqual(try titles(x, QueryOptions(db3: [id])), previous)
        try await handle.ready()
        let now = try titles(x, QueryOptions(db3: [id]))
        XCTAssertTrue(now.contains("after"))
        XCTAssertTrue(now.contains("added"))
        XCTAssertFalse(now.contains("removed later"))
        XCTAssertFalse(now.contains("before"))
    }

    // MARK: - Behaviour 23

    func testSubscribingOfflineAndTheSaveDestination() async throws {
        let x = try await live.client("x", models: [Self.note])
        let id = try await live.createDocument(x)
        let never = try await live.db3Written(0, model: "Note")
        try await live.residentOn(x, id)
        try save(x, id, "here")
        x.setNetworkMode(.offline)
        let handle = try x.db3.subscribe(id)
        try await handle.available()
        try await eventually(description: "reconnecting while offline") { handle.state.phase == .reconnecting }
        XCTAssertEqual(try titles(x, QueryOptions(db3: [id])), ["here"])
        let unloaded = try x.db3.subscribe(never, options: Db3SubscribeOptions(readyTimeout: 1.5))
        do {
            let got = await db3Outcome { try await unloaded.ready() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        do {
            let got = await db3Outcome { try await unloaded.available() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        unloaded.dispose()
        x.setNetworkMode(.online)
        try await handle.ready()
        XCTAssertEqual(handle.state.phase, .live)
        try await live.settled(x, id)
        handle.dispose()
        try await eventually(description: "unsubscribed") { try await !x.db3.state(id).subscribed }

        // The save destination: a resident, unsubscribed db3 takes a save, which queues.
        x.setNetworkMode(.offline)
        let saved = try save(x, id, "by destination")
        let queued = try await x.db3.state(id)
        XCTAssertEqual(queued.pendingWrites, 1)
        XCTAssertEqual(x.sharedModel(for: Self.note).find(id: saved)?.row["title"]?.stringValue, "by destination")
        try x.setDefaultDb3(id)
        XCTAssertEqual(x.getDocumentModelMapping(modelName: "Note"), id)
        x.clearDefaultDocumentId()
        try x.setDefaultDocumentId(id)
        XCTAssertEqual(x.getDocumentModelMapping(modelName: "Note"), id)
        let created = try await x.createDocument(options: CreateDocumentOptions(title: "format 1"))
        let formatOne = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        XCTAssertEqual(code { try x.setDefaultDocumentId(formatOne) }, "NOT_FOUND")
        XCTAssertEqual(code { try self.save(x, RecordLogLiveApp.ulid(), "nowhere") }, "NOT_FOUND")
        XCTAssertEqual(
            code { _ = try x.sharedModel(for: Self.note).query(nil, options: QueryOptions(documents: [id], db3: [never])) },
            "INVALID_ARGUMENT"
        )
        XCTAssertEqual(
            try titles(x, QueryOptions(documents: [id], db3: [id])), ["by destination", "here"], "the same ids in both are one scope"
        )

        // A bound db3 whose load never completed is not a destination.
        x.setNetworkMode(.online)
        try await waitForConnection(client: x, timeout: 15)
        let gate = Db3FrameGate(x)
        gate.drop(Db3FrameGate.of(never))
        let stalled = try x.db3.subscribe(never, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 15, description: "the never-loaded db3 to be bound") { x.isRecordLogDocument(never) }
        stalled.dispose()
        XCTAssertEqual(code { try self.save(x, never, "not yet") }, "DB3_NOT_RESIDENT")
        XCTAssertEqual(code { try x.setDefaultDb3(never) }, "DB3_NOT_RESIDENT")
    }

    // MARK: - Edge 44

    func testADb3WhoseFormatNothingLocalKnowsWaitsForItOffline() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let id = try await live.createDocument(owner)
        let x = try await live.client("x", models: [Self.note])
        x.setNetworkMode(.offline)
        let first = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 1.5))
        do {
            let got = await db3Outcome { try await first.ready() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        XCTAssertNil(x.documentManager.documentFormat(id))
        let second = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        x.setNetworkMode(.online)
        try await second.ready()
        XCTAssertEqual(second.state.phase, .live)
        XCTAssertTrue(x.isRecordLogDocument(id))
    }
}
