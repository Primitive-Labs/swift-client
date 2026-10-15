import XCTest
@testable import JsBaoClient

/// A Swift client receives bulk loads as chunks, live and on reconnect,
/// against the dev server: the Swift twin of js-bao's
/// `record-log-load-receipt-4311.test.ts`.
///
/// - A connected client declares `accepts: ["load", "segment", "building"]`, is sent
///   `record.load complete` (never `record.released`), reads the manifest and
///   chunks through the grant, pages the remainder, and equals the room within
///   10 s of the frame at 20,000 rows: the patches another client made during
///   the load shown, a refused create absent, a refused patch showing the
///   room's row; a save made while the chunks arrive is confirmed after.
/// - A client that opens while a load applies is told of it and sends no gap
///   re-open; one back from before the load takes the `load` form within 10 s
///   with a 0.5 s handshake timeout, no sync error and no rebuilt socket.
/// - An aborted or failed load opens again and holds exactly the rows applied;
///   a refresh on reconnect removes what no line named and keeps what it must.
/// - The client's artifact read resolves the grant path against the API URL
///   and answers only a 200.
final class RecordLogLoadReceiptLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var extra: [JsBaoClient] = []

    static let fields = ["title", "slug", "n", "body"]
    static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, indexed: true, unique: true), "n": FieldDescriptor(type: .number),
            "body": FieldDescriptor(type: .string),
        ]
    )
    static let tag = PrimitiveSchema(
        name: "Tag", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-load-receipt")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for client in extra { await client.destroy() }
        extra = []
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// A client with its own database and the given handshake budget.
    private func client(_ name: String, handshakeTimeout: TimeInterval) async throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl, wsUrl: TestConfig.wsUrl, appId: live.app.appId, token: live.app.ownerJWT,
            globalAdminAppId: TestConfig.globalAdminAppId, wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn, storageConfig: .sqlite(directory: live.directory + "/\(name)-\(UUID().uuidString.prefix(4)).sqlite"),
            sync: SyncConfig(handshakeTimeout: handshakeTimeout), autoNetwork: true
        ))
        client.registerModels([Self.note, Self.tag])
        extra.append(client)
        _ = await client.waitForStorageReady()
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
        return client
    }

    /// A document with a receiver `x` and a writer `y` open on it.
    private func pair(handshakeTimeout: TimeInterval? = nil) async throws -> (String, JsBaoClient, JsBaoClient, RecordLogLoadDriver) {
        let y = try await live.client("y", models: [Self.note, Self.tag])
        let documentId = try await live.createDocument(y)
        let x: JsBaoClient
        if let handshakeTimeout {
            x = try await client("x", handshakeTimeout: handshakeTimeout)
        } else {
            x = try await live.client("x", models: [Self.note, Self.tag])
        }
        try await live.open(x, documentId)
        try await live.open(y, documentId)
        return (documentId, x, y, RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT))
    }

    private func loaded(_ ids: [String]) -> [(String, [String: JSONValue])] {
        ids.enumerated().map { i, id in (id, ["title": .string("loaded \(id)"), "n": .number(Double(i))]) }
    }

    private func create(_ client: JsBaoClient, _ documentId: String, _ id: String, _ values: [String: PrimitiveValue]) throws {
        _ = try live.member(client, documentId, "Note").create(id: id, values: values)
    }

    private func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - Behavior 21: the client's artifact read

    func testTheArtifactReadResolvesTheGrantPathAgainstTheApiUrlAndAnswersOnlyA200() async throws {
        let (documentId, x, _, load) = try await pair()
        let watch = RecordLogClientWatch(x)
        let session = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: loaded(recordLogIds(20, prefix: "g")))])
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        try await load.until(sessionId) { ($0["state"] as? String) == "complete" }
        let complete = try await eventuallyValue(timeout: 20, description: "record.load complete") {
            watch.received("record.load", phase: "complete").first?.frame
        }
        let path = try XCTUnwrap(complete["download"]?["path"]?.stringValue)
        XCTAssertTrue(path.hasPrefix("/doc-artifact/"), path)
        // The grant is the credential: the read carries no Authorization header, and answers the manifest.
        let manifest = try await x.fetchRecordLogArtifact(path)
        let parsed = try XCTUnwrap(RecordLogJSON.parse(String(decoding: manifest, as: UTF8.self)))
        XCTAssertEqual(parsed["kind"], "ingest")
        XCTAssertEqual(parsed["sessionId"]?.stringValue, sessionId)
        // A path the room granted nothing at is refused with its status, the token never shown.
        do {
            _ = try await x.fetchRecordLogArtifact("/doc-artifact/not-a-grant/manifest")
            XCTFail("a wrong path answered bytes")
        } catch let error as RecordLogArtifactError {
            XCTAssertNotNil(error.status)
            XCTAssertNotEqual(error.status, 200)
            XCTAssertTrue(error.description.contains("/doc-artifact/…"), error.description)
            XCTAssertFalse(error.description.contains("not-a-grant"), error.description)
        }
        try await live.untilEqual(x, documentId, "Note", Self.fields)
    }

    // MARK: - Behavior 23: a connected client receives a 20,000-row load live

    func testAConnectedClientReceivesATwentyThousandRowLoadLiveAndEqualsTheRoom() async throws {
        let (documentId, x, y, load) = try await pair()
        // The opens declared that they take loads and segments.
        let state = try await live.route(documentId, "state")
        let accepts = state["accepts"] as? [String: [String]] ?? [:]
        XCTAssertEqual(accepts.count, 2, "\(state["accepts"] ?? "none")")
        for (_, kinds) in accepts { XCTAssertEqual(kinds, ["load", "segment", "building"]) }

        // Before the load: a holder of the unique key, a record a line will patch, 50 records y patches during it.
        try create(y, documentId, "x-holder", ["title": .string("holds"), "slug": .string("taken")])
        try create(y, documentId, "x-patched", ["title": .string("existing"), "slug": .string("mine")])
        let patched = (0..<50).map { "p" + String(format: "%02d", $0) }
        for id in patched { try create(y, documentId, id, ["title": .string("before")]) }
        try await live.settled(y, documentId)
        try await live.untilEqual(x, documentId, "Note", Self.fields)

        let watch = RecordLogClientWatch(x)
        let notified = LockedBox(0)
        let stop = try live.member(x, documentId, "Note").subscribe { notified.withValue { $0 += 1 } }
        defer { stop() }
        let all = recordLogIds(20_000, prefix: "n")
        // The second chunk is held until x has saved during the receipt.
        let held = watch.holdNext { $0.contains("/Note/1.") }
        try await load.test("set-limits", ["loadTickRows": 2_000, "loadTxnRows": 1_000])
        let session = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: loaded(Array(all[0..<10_000]))),
            RecordLogLoadChunk(model: "Note", index: 1, lines: loaded(Array(all[10_000...]))),
            RecordLogLoadChunk(model: "Note", index: 2, lines: patched.map { ($0, ["title": "loaded", "n": 1]) } + [
                ("x-dup", ["title": "refused create", "slug": "taken"]),
                ("x-patched", ["slug": "taken"]),
            ]),
        ])
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        // y patches its 50 records while the load applies.
        try await load.until(sessionId, timeout: 60) { ["applying", "complete"].contains($0["state"] as? String ?? "") }
        let notes = try live.member(y, documentId, "Note")
        for id in patched { try notes.update(id: id, values: ["title": .string("patched during")]) }
        try await live.settled(y, documentId, timeout: 60)
        let done = try await load.until(sessionId, timeout: 120) { ($0["state"] as? String) == "complete" }
        XCTAssertEqual((done["refusedRows"] as? NSNumber)?.intValue, 2)

        // x is sent the pointer, not the released notice.
        let complete = try await eventuallyValue(timeout: 30, description: "record.load complete") {
            watch.received("record.load", phase: "complete").first
        }
        XCTAssertEqual(complete.frame["sessionId"]?.stringValue, sessionId)
        XCTAssertEqual(complete.frame["chunkCount"], 3)
        XCTAssertEqual(complete.frame["rows"], 20_050)
        XCTAssertEqual(complete.frame["refusedRows"], 2)
        XCTAssertTrue(watch.received("record.released").isEmpty)
        let deliveries = (try await live.route(documentId, "state"))["deliveries"] as? [[String: Any]] ?? []
        let delivered = deliveries.flatMap { $0["frames"] as? [String] ?? [] }
        XCTAssertTrue(delivered.contains("record.load:complete"), "\(delivered.suffix(10))")
        XCTAssertFalse(delivered.contains("record.released"))

        // A save while the chunks arrive: after the first chunk, before the remainder.
        await held.reached.wait()
        let mine = try live.member(x, documentId, "Note")
        let confirmed = Task { try await mine.save(id: "x-mine", values: ["title": .string("saved during the receipt")], confirm: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        held.release.open()

        try await live.untilEqual(x, documentId, "Note", Self.fields, timeout: 30)
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "x's cursor to reach the room's log number") {
            try self.live.marks(x, documentId).cursor >= lsn
        }
        let received = Int(Date().timeIntervalSince(complete.at) * 1000)
        stderr("[4312] a Swift client received a 20,000-row load \(received) ms after its record.load complete frame")
        XCTAssertLessThan(received, 10_000)
        let record = try await confirmed.value
        XCTAssertEqual(record.syncState, .confirmed)
        let room = try await live.roomTable(documentId, "Note")
        XCTAssertEqual(room["x-mine"]?["title"], "saved during the receipt")

        // The corrections.
        let local = try live.localRows(x, documentId, "Note")
        XCTAssertNil(local["x-dup"])
        XCTAssertEqual(local["x-holder"]?["slug"], "taken")
        XCTAssertEqual(local["x-patched"]?["slug"], "mine")
        XCTAssertEqual(local["x-patched"]?["title"], "existing")
        for id in patched { XCTAssertEqual(local[id]?["title"], "patched during", id) }
        XCTAssertEqual(local[all[19_999]]?["title"], .string("loaded \(all[19_999])"))
        // No gap re-open while the load applied; the subscription heard it; every read answered 200.
        XCTAssertEqual(watch.sent("record.open").count, 0)
        XCTAssertEqual(watch.fetched.map(\.status), [200, 200, 200, 200], "\(watch.fetched)")
        XCTAssertGreaterThan(notified.value, 0)
        XCTAssertNil(try live.marks(x, documentId).receipt)
    }

    // MARK: - Behavior 24: a client that opens while a load applies

    func testAClientOpeningWhileALoadAppliesIsToldOfItSendsNoGapReopenAndEndsEqual() async throws {
        let (documentId, _, y, load) = try await pair()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try await load.test("set-clock", ["nowMs": now])
        do {
            try await load.test("set-limits", ["loadTickRows": 500, "loadTxnRows": 500])
            let session = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: loaded(recordLogIds(4_000, prefix: "m")))])
            let sessionId = try XCTUnwrap(session["sessionId"] as? String)
            try await load.test("set-clock", ["nowMs": now + 1_000])
            try await load.test("run-alarm")
            let viewed = try await load.view(sessionId)
            XCTAssertEqual(viewed["state"] as? String, "applying")
            // y writes while the load waits: results the late client holds behind it.
            let notes = try live.member(y, documentId, "Note")
            for i in 0..<3 { _ = try await notes.save(id: "during-\(i)", values: ["title": .string("during \(i)")], confirm: true) }

            let z = try await live.client("z", models: [Self.note, Self.tag])
            let watch = RecordLogClientWatch(z)
            _ = try await z.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: true))
            try await eventually(timeout: 20, description: "z to be told of the load") {
                !watch.received("record.load", phase: "started").isEmpty
            }
            let opensAtStart = watch.sent("record.open").count
            // Past the 2 s gap wait, still applying: no re-open.
            try await Task.sleep(nanoseconds: 2_500_000_000)
            XCTAssertEqual(watch.sent("record.open").count, opensAtStart)
            for n in 2..<40 {
                if (try await load.view(sessionId))["state"] as? String == "complete" { break }
                try await load.test("set-clock", ["nowMs": now + n * 1_000])
                try await load.test("run-alarm")
            }
            try await live.untilEqual(z, documentId, "Note", Self.fields, timeout: 60)
            XCTAssertEqual(watch.sent("record.open").count, opensAtStart, "no open after the first")
        } catch {
            _ = try? await load.test("set-clock", ["nowMs": NSNull()])
            throw error
        }
        try await load.test("set-clock", ["nowMs": NSNull()])
    }

    // MARK: - Behavior 25: a client back from before the load

    func testAClientBackFromBeforeALoadTakesTheLoadFormWithAHalfSecondHandshakeTimeout() async throws {
        let (documentId, x, y, load) = try await pair(handshakeTimeout: 0.5)
        try create(y, documentId, "z-recreated", ["title": .string("old"), "body": .string("a field the room deletes")])
        try await live.settled(y, documentId)
        try await eventually(timeout: 20, description: "x to hold the record") {
            try self.live.member(x, documentId, "Note").find(id: "z-recreated") != nil
        }
        let errors = LockedBox<[DocumentSyncStateChangedEvent]>([])
        let errorTimes = LockedBox<[Date]>([])
        let closes = LockedBox(0)
        let errorSubscription = x.eventEmitter.subscribe(DocumentSyncStateChangedEvent.self) { event in
            if event.state == "error" {
                errors.withValue { $0.append(event) }
                errorTimes.withValue { $0.append(Date()) }
            }
        }
        await x.goOffline()
        // Deleted before the load's reservation, recreated by it without the old field.
        try live.member(y, documentId, "Note").delete(id: "z-recreated")
        try await live.settled(y, documentId)
        let all = recordLogIds(20_000, prefix: "r")
        var chunks = (0..<4).map { i in RecordLogLoadChunk(model: "Note", index: i, lines: loaded(Array(all[(i * 5_000)..<((i + 1) * 5_000)]))) }
        chunks.append(RecordLogLoadChunk(model: "Note", index: 4, lines: [("z-recreated", ["title": "new"])]))
        let session = try await load.load(chunks)
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        try await load.until(sessionId, timeout: 120) { ($0["state"] as? String) == "complete" }

        let watch = RecordLogClientWatch(x)
        let closeSubscription = x.eventEmitter.subscribe(ConnectionCloseEvent.self) { _ in closes.withValue { $0 += 1 } }
        defer {
            errorSubscription.cancel()
            closeSubscription.cancel()
        }
        let started = Date()
        await x.goOnline()
        let opened = try await eventuallyValue(timeout: 30, description: "record.opened") {
            watch.received("record.opened").first?.frame
        }
        XCTAssertEqual(opened["catchUp"]?["mode"], "load")
        XCTAssertEqual(opened["catchUp"]?["load"]?["sessionId"]?.stringValue, sessionId)
        try await live.untilEqual(x, documentId, "Note", Self.fields, timeout: 60)
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "x's cursor to reach the room's log number") {
            try self.live.marks(x, documentId).cursor >= lsn
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        stderr("[4312] a Swift client back from before a 20,000-row load held it \(elapsed) ms after going online")
        XCTAssertLessThan(elapsed, 10_000)
        let recreated = try live.localRows(x, documentId, "Note")["z-recreated"]
        XCTAssertEqual(recreated?["title"], "new")
        XCTAssertEqual(recreated?["body"] ?? .null, .null)
        XCTAssertEqual(errors.value.count, 0, "no sync error; trail: \(watch.received.map { "\($0.frame["type"]?.stringValue ?? "?")@\(Int($0.at.timeIntervalSince(started) * 1000))" }) errors at \(errorTimes.value.map { Int($0.timeIntervalSince(started) * 1000) })")
        XCTAssertEqual(closes.value, 0, "the socket was not rebuilt")
        XCTAssertEqual(watch.received("record.opened").count, 1)
        XCTAssertLessThanOrEqual(watch.sent("record.open").count, 1)
    }

    // MARK: - Behavior 26: an aborted and a failed load

    func testOnAnAbortedOrAFailedLoadTheClientOpensAgainAndHoldsExactlyTheRowsApplied() async throws {
        for stage in ["aborted", "failed"] {
            let (documentId, x, _, load) = try await pair()
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try await load.test("set-clock", ["nowMs": now])
            do {
                try await load.test("set-limits", ["loadTxnRows": 100, "loadTickRows": 300])
                let session = try await load.load([RecordLogLoadChunk(model: "Note", index: 0, lines: loaded(recordLogIds(1_000, prefix: "a")))])
                let sessionId = try XCTUnwrap(session["sessionId"] as? String)
                try await load.test("set-clock", ["nowMs": now + 1_000])
                try await load.test("run-alarm")
                if stage == "aborted" {
                    let aborted = try await load.abort(sessionId)
                    XCTAssertEqual(aborted.status, 200, "\(aborted.json)")
                } else {
                    try await load.test("ingest-fault", ["sessionId": sessionId, "kind": "throw", "times": 10])
                    // A thrown tick is retried after a back-off: each run is two minutes on.
                    for n in 1...10 {
                        if (try await load.view(sessionId))["state"] as? String == "failed" { break }
                        try await load.test("set-clock", ["nowMs": now + n * 120_000])
                        try await load.test("run-alarm")
                    }
                    let viewed = try await load.view(sessionId)
                    XCTAssertEqual(viewed["state"] as? String, "failed")
                }
            } catch {
                _ = try? await load.test("set-clock", ["nowMs": NSNull()])
                throw error
            }
            try await load.test("set-clock", ["nowMs": NSNull()])
            let applied = try await load.count("Note")
            XCTAssertGreaterThan(applied, 0, stage)
            XCTAssertLessThan(applied, 1_000, stage)
            try await live.untilEqual(x, documentId, "Note", Self.fields)
            XCTAssertEqual(try live.localRows(x, documentId, "Note").count, applied, stage)
        }
    }

    // MARK: - Behavior 27: a refresh received on reconnect

    func testARefreshReceivedOnReconnectRemovesWhatNoLineNamedAndKeepsWhatItMust() async throws {
        let (documentId, x, y, load) = try await pair()
        for id in ["a1", "a2", "a3", "a4"] { try create(y, documentId, id, ["title": .string("before")]) }
        _ = try live.member(y, documentId, "Tag").create(id: "t1", values: ["title": .string("another model")])
        try await live.settled(y, documentId)
        try await live.untilEqual(x, documentId, "Note", Self.fields)
        await x.goOffline()
        // x's own create of a covered model, not yet sent.
        try create(x, documentId, "a-mine", ["title": .string("pending create")])
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try await load.test("set-clock", ["nowMs": now])
        do {
            try await load.test("set-limits", ["loadTxnRows": 1, "loadTickRows": 1])
            let session = try await load.load(
                [RecordLogLoadChunk(model: "Note", index: 0, lines: [("a1", ["title": "refreshed"]), ("a2", ["title": "refreshed"])])],
                body: ["mode": "refresh"]
            )
            let sessionId = try XCTUnwrap(session["sessionId"] as? String)
            try await load.test("set-clock", ["nowMs": now + 1_000])
            try await load.test("run-alarm")
            // y creates a covered record while the refresh applies.
            _ = try await live.member(y, documentId, "Note").save(id: "a9", values: ["title": .string("created during")], confirm: true)
            for n in 2..<40 {
                if (try await load.view(sessionId))["state"] as? String == "complete" { break }
                try await load.test("set-clock", ["nowMs": now + n * 1_000])
                try await load.test("run-alarm")
            }
            let viewed = try await load.view(sessionId)
            XCTAssertEqual(viewed["state"] as? String, "complete")
        } catch {
            _ = try? await load.test("set-clock", ["nowMs": NSNull()])
            throw error
        }
        try await load.test("set-clock", ["nowMs": NSNull()])
        let watch = RecordLogClientWatch(x)
        await x.goOnline()
        let opened = try await eventuallyValue(timeout: 30, description: "record.opened") {
            watch.received("record.opened").first?.frame
        }
        XCTAssertEqual(opened["catchUp"]?["mode"], "load")
        try await live.settled(x, documentId)
        try await live.untilEqual(x, documentId, "Note", Self.fields)
        XCTAssertEqual(try live.localRows(x, documentId, "Note").keys.sorted(), ["a-mine", "a1", "a2", "a9"])
        XCTAssertEqual(try live.localRows(x, documentId, "Tag")["t1"]?["title"], "another model")
        let tagDifference = try await live.differs(x, documentId, "Tag", ["title"])
        XCTAssertNil(tagDifference)
    }

    // MARK: - Behavior 29: the fallback, and an interrupted receipt

    /// A document holding a unique key and a record a line will patch; `x` saw
    /// them and went offline; a load then committed with a refused create and a
    /// refused patch in its first chunk.
    private func behindALoad() async throws -> (String, JsBaoClient, RecordLogLoadDriver) {
        let (documentId, x, y, load) = try await pair()
        try create(y, documentId, "x-holder", ["title": .string("holds"), "slug": .string("taken")])
        try create(y, documentId, "x-patched", ["title": .string("existing"), "slug": .string("mine")])
        try await live.settled(y, documentId)
        try await live.untilEqual(x, documentId, "Note", ["title", "slug"])
        await x.goOffline()
        let session = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: recordLogIds(200, prefix: "a").map { ($0, ["title": .string($0)]) } + [
                ("x-dup", ["title": "refused create", "slug": "taken"]), ("x-patched", ["slug": "taken"]),
            ]),
            RecordLogLoadChunk(model: "Note", index: 1, lines: recordLogIds(200, prefix: "y").map { ($0, ["title": .string($0)]) }),
        ])
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        let done = try await load.until(sessionId, timeout: 60) { ($0["state"] as? String) == "complete" }
        XCTAssertEqual((done["refusedRows"] as? NSNumber)?.intValue, 2)
        return (documentId, x, load)
    }

    /// The client equals the room, holds neither refused line's effect, and its receipt is complete.
    private func recovered(_ documentId: String, _ client: JsBaoClient) async throws {
        try await live.untilEqual(client, documentId, "Note", ["title", "slug"], timeout: 60)
        let lsn = try await live.roomLsn(documentId)
        try await eventually(timeout: 20, description: "the cursor to reach the room's log number") {
            try self.live.marks(client, documentId).cursor >= lsn
        }
        let local = try live.localRows(client, documentId, "Note")
        XCTAssertNil(local["x-dup"])
        XCTAssertEqual(local["x-patched"]?["slug"], "mine")
        XCTAssertEqual(local["x-patched"]?["title"], "existing")
        XCTAssertNil(try live.marks(client, documentId).receipt)
    }

    func testWithTheGrantsFailingTwoReceiptsFailAndTheThirdOpenTakesRowsAndEqualsTheRoom() async throws {
        let (documentId, x, load) = try await behindALoad()
        try await load.test("set-limits", ["artifactGrants": false])
        let watch = RecordLogClientWatch(x)
        await x.goOnline()
        try await live.untilEqual(x, documentId, "Note", ["title", "slug"], timeout: 60)
        let answered = watch.received("record.opened").map { $0.frame["catchUp"]?["mode"]?.stringValue ?? "" }
        let opens = watch.sent("record.open").map { $0["accepts"] ?? .null }
        let trail = "opens \(opens); answered \(answered)"
        XCTAssertEqual(Array(answered.prefix(2)), ["load", "load"], trail)
        XCTAssertNotEqual(answered.dropFirst(2).first, "load", trail)
        XCTAssertEqual(opens.dropFirst(2).first, [], trail)
        XCTAssertNil(try live.marks(x, documentId).receipt, "nothing was committed from a chunk")
        XCTAssertNil(try live.localRows(x, documentId, "Note")["x-dup"])
    }

    func testAReceiptInterruptedAfterItsFirstChunkLeavesTheMarkerAndTheNextOpenWalksTheWholeTable() async throws {
        let (documentId, x, load) = try await behindALoad()
        let cursor = try live.marks(x, documentId).cursor
        let watch = RecordLogClientWatch(x)
        let held = watch.holdNext { $0.contains("/Note/1.") }
        await x.goOnline()
        await held.reached.wait()
        await x.goOffline()
        held.release.open()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try live.marks(x, documentId).cursor, cursor)
        XCTAssertEqual(try live.marks(x, documentId).receipt?.kind, .load)
        XCTAssertNotNil(try live.localRows(x, documentId, "Note")["x-dup"], "the committed chunk holds the refused create")
        // The room answers the next open rows: it offers no pointer past a remainder of 0 rows, and with
        // no grant to mint it builds no segment for the reader to wait for (#4556).
        try await load.test("set-limits", ["catchUpPointerRows": 0, "artifactGrants": false])
        await x.goOnline()
        try await recovered(documentId, x)
        XCTAssertTrue(watch.sent("record.catchUp").contains { $0["full"] == true && $0["cursor"] == 0 }, "\(watch.sent("record.catchUp"))")
    }

    func testAnExpiredGrantFailsOnceAndThePointerTheRoomStillOffersThenCompletes() async throws {
        let (documentId, x, load) = try await behindALoad()
        try await load.test("set-limits", ["expiredGrants": 1])
        let watch = RecordLogClientWatch(x)
        await x.goOnline()
        try await recovered(documentId, x)
        XCTAssertEqual(watch.fetched.first?.status, 403, "\(watch.fetched)")
        XCTAssertTrue(watch.fetched.dropFirst().allSatisfy { $0.status == 200 }, "\(watch.fetched)")
    }

    // MARK: - Edge 012: the owner reset mid-receipt

    func testAnotherUserSigningInMidReceiptClosesTheSessionAndNothingOfTheReceiptLandsAfterTheReset() async throws {
        let (documentId, x, _, load) = try await pair()
        let userB = try await ctx.createTestUser(appId: live.app.appId)
        await x.goOffline()
        let session = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: loaded(recordLogIds(200, prefix: "o"))),
            RecordLogLoadChunk(model: "Note", index: 1, lines: loaded(recordLogIds(200, prefix: "p"))),
        ])
        try await load.until(try XCTUnwrap(session["sessionId"] as? String)) { ($0["state"] as? String) == "complete" }
        let watch = RecordLogClientWatch(x)
        let held = watch.holdNext { $0.contains("/Note/1.") }
        await x.goOnline()
        await held.reached.wait()
        XCTAssertNotNil(try live.member(x, documentId, "Note").find(id: "o00001"), "the first chunk landed")
        let storage = await x.offlineStore.getStorageProvider()
        let provider = try XCTUnwrap(storage as? any Format2SqlHost)
        func storedRows() throws -> Int {
            try provider.withConnection { connection in
                try connection.query("SELECT COUNT(*) AS n FROM record_log_rows WHERE doc_id = ?", [.text(documentId)]).first?["n"].intValue ?? -1
            }
        }
        XCTAssertGreaterThan(try storedRows(), 0)
        // Another user signs in: the store is reset, the session closed before it.
        x.updateToken(userB.jwt)
        await x.rebindUserScopedStorage()
        XCTAssertNil(x.recordLogBinding(documentId), "the document's session closed")
        XCTAssertEqual(try storedRows(), 0, "the store was reset")
        // The held chunk answers now: nothing of the receipt touches the store after the reset.
        held.release.open()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try storedRows(), 0)
        XCTAssertTrue(watch.sent("record.catchUp").isEmpty, "the receipt stopped before its remainder")
    }

    // MARK: - Behavior 30: 100,000 rows, live and on reconnect

    func testAHundredThousandRowLoadIsReceivedLiveAndOnReconnectAndBothEqualTheRoom() async throws {
        let (documentId, x, y, load) = try await pair()
        let late = try await live.client("late", models: [Self.note, Self.tag])
        try await live.open(late, documentId)
        try create(y, documentId, "h-holder", ["title": .string("holds"), "slug": .string("taken")])
        // Past every `h` id: the chunks of one model follow each other in id order.
        let patched = (0..<50).map { "zq" + String(format: "%02d", $0) }
        for id in patched { try create(y, documentId, id, ["title": .string("before")]) }
        try await live.settled(y, documentId)
        try await live.untilEqual(late, documentId, "Note", Self.fields)
        await late.goOffline()
        let watch = RecordLogClientWatch(x)
        let all = recordLogIds(100_000, prefix: "h", digits: 6)
        var chunks = (0..<10).map { i in RecordLogLoadChunk(model: "Note", index: i, lines: loaded(Array(all[(i * 10_000)..<((i + 1) * 10_000)]))) }
        // In id order: `zdup` before the `zq` records.
        chunks.append(RecordLogLoadChunk(model: "Note", index: 10, lines: [("zdup", ["title": "refused create", "slug": "taken"])]
            + patched.map { ($0, ["title": "loaded"]) }))
        let session = try await load.load(chunks)
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        try await load.until(sessionId, timeout: 300) { ["applying", "complete"].contains($0["state"] as? String ?? "") }
        let notes = try live.member(y, documentId, "Note")
        for id in patched { try notes.update(id: id, values: ["title": .string("patched during")]) }
        try await live.settled(y, documentId, timeout: 120)
        try await load.until(sessionId, timeout: 600) { ($0["state"] as? String) == "complete" }
        let complete = try await eventuallyValue(timeout: 60, description: "record.load complete") {
            watch.received("record.load", phase: "complete").first
        }
        try await live.untilEqual(x, documentId, "Note", Self.fields, timeout: 300)
        let connectedMs = Int(Date().timeIntervalSince(complete.at) * 1000)
        stderr("[4312] a connected Swift client received a 100,000-row load \(connectedMs) ms after its record.load complete frame")

        let lateWatch = RecordLogClientWatch(late)
        let started = Date()
        await late.goOnline()
        try await live.untilEqual(late, documentId, "Note", Self.fields, timeout: 300)
        let reconnectMs = Int(Date().timeIntervalSince(started) * 1000)
        stderr("[4312] a Swift client back from before a 100,000-row load held it \(reconnectMs) ms after going online")
        XCTAssertEqual(lateWatch.received("record.opened").first?.frame["catchUp"]?["mode"], "load")
        for client in [x, late] {
            let local = try live.localRows(client, documentId, "Note")
            XCTAssertNil(local["zdup"])
            for id in patched { XCTAssertEqual(local[id]?["title"], "patched during", id) }
        }
    }
}
