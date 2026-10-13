import XCTest
@testable import JsBaoClient
import YSwift

/// The record-log criteria a Swift client must meet against a real room
/// (intent criteria 3, 4 and 5), and the developer additions with real
/// acknowledgements: the Swift twins of js-bao's offline-window, budget,
/// constraints, upsert and confirm suites. The room's `rotate`, `checkpoint`
/// and `set-limits` test routes stand in for days passing.
final class RecordLogCriteriaLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let sheet = PrimitiveSchema(
        name: "Sheet",
        fields: ["id": FieldDescriptor(type: .id), "f": FieldDescriptor(type: .string), "g": FieldDescriptor(type: .string)]
    )
    private static let tag = PrimitiveSchema(
        name: "Tag",
        fields: [
            "id": FieldDescriptor(type: .id), "slug": FieldDescriptor(type: .string, indexed: true, unique: true),
            "title": FieldDescriptor(type: .string),
        ]
    )
    private static let entry = PrimitiveSchema(
        name: "Entry",
        fields: [
            "id": FieldDescriptor(type: .id), "slug": FieldDescriptor(type: .string, indexed: true, unique: true),
            "a": FieldDescriptor(type: .string), "b": FieldDescriptor(type: .string), "c": FieldDescriptor(type: .string),
        ]
    )
    private static let row = PrimitiveSchema(
        name: "Row",
        fields: ["id": FieldDescriptor(type: .id), "n": FieldDescriptor(type: .number), "body": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-criteria")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func refusals(_ client: JsBaoClient) -> (LockedBox<[DocumentWriteRefusedEvent]>, EventSubscription) {
        let heard = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in
            heard.withValue { $0.append(event) }
        }
        return (heard, subscription)
    }

    private func pair(_ schema: PrimitiveSchema) async throws -> (String, JsBaoClient, JsBaoClient) {
        let x = try await live.client("x", models: [schema])
        let documentId = try await live.createDocument(x)
        let y = try await live.client("y", models: [schema])
        try await live.open(x, documentId)
        try await live.open(y, documentId)
        return (documentId, x, y)
    }

    // MARK: - Behavior 22 (criterion 3): inside the window

    func testInsideTheWindowEveryOfflineWriteAppliesExceptAFieldALaterEpochWrote() async throws {
        let (documentId, x, y) = try await pair(Self.sheet)
        let sheetsX = try live.member(x, documentId, "Sheet")
        let sheetsY = try live.member(y, documentId, "Sheet")
        _ = try sheetsX.create(id: "shared", values: ["f": .string("orig"), "g": .string("orig")])
        _ = try sheetsX.create(id: "doomed", values: ["f": .string("to delete")])
        try await live.settled(x, documentId)
        try await eventually(timeout: 20, description: "y to hold both records") { sheetsY.find(id: "doomed") != nil }

        await x.goOffline()
        _ = try sheetsX.create(id: "made", values: ["f": .string("made offline")])
        try sheetsX.update(id: "made", values: ["f": .string("patched offline")])
        try sheetsX.update(id: "shared", values: ["f": .string("x wrote f"), "g": .string("x wrote g")])
        sheetsX.delete(id: "doomed")
        XCTAssertEqual(try live.binding(x, documentId).marks.open, 1)

        // Meanwhile the room rotates and the other client writes `g` in the new epoch.
        _ = try await live.route(documentId, "rotate")
        try await eventually(timeout: 20, description: "y to hear the rotation") {
            (try? live.binding(y, documentId).refreshMarks().open) ?? 0 >= 2
        }
        try sheetsY.update(id: "shared", values: ["g": .string("y wrote g later")])
        try await live.settled(y, documentId)

        await x.goOnline()
        try await live.settled(x, documentId, timeout: 60)
        let expected = { (record: PrimitiveRecord?) -> Bool in
            record?["f"] == .string("x wrote f") && record?["g"] == .string("y wrote g later")
        }
        try await eventually(timeout: 30, description: "both clients to hold the shared record") {
            expected(sheetsX.find(id: "shared")) && expected(sheetsY.find(id: "shared"))
        }
        for sheets in [sheetsX, sheetsY] {
            XCTAssertEqual(sheets.find(id: "made")?["f"], .string("patched offline"))
            XCTAssertNil(sheets.find(id: "doomed"))
        }
        let rows = try await live.roomRows(documentId, "Sheet")
        XCTAssertEqual(rows["shared"]?["f"] as? String, "x wrote f")
        XCTAssertEqual(rows["shared"]?["g"] as? String, "y wrote g later")
        XCTAssertEqual(rows["made"]?["f"] as? String, "patched offline")
        XCTAssertNil(rows["doomed"])
    }

    // MARK: - Behavior 23 (criterion 3): below a floor

    func testReturningBelowTheCursorFloorHandsEveryUnsentWriteBackAtOnce() async throws {
        try await returningBelowAFloor(.cursor)
    }

    func testReturningBelowTheEpochFloorHandsEveryUnsentWriteBackAtOnce() async throws {
        try await returningBelowAFloor(.epoch)
    }

    private enum Floor { case cursor, epoch }

    private func returningBelowAFloor(_ floor: Floor) async throws {
        let (documentId, x, y) = try await pair(Self.sheet)
        let sheetsX = try live.member(x, documentId, "Sheet")
        let sheetsY = try live.member(y, documentId, "Sheet")
        _ = try sheetsX.create(id: "kept", values: ["f": .string("confirmed")])
        try await live.settled(x, documentId)

        await x.goOffline()
        let (heard, subscription) = refusals(x)
        defer { subscription.cancel() }
        _ = try sheetsX.create(id: "made", values: ["f": .string("made away"), "g": .string("too")])
        try sheetsX.update(id: "kept", values: ["f": .string("patched away")])
        XCTAssertEqual(try live.pending(x, documentId).count, 2)

        for index in 0..<3 { _ = try sheetsY.create(id: "y\(index)", values: ["f": .string("y \(index)")]) }
        try await live.settled(y, documentId)
        let room = try await live.route(documentId, "state")
        let lsn = room["lsn"] as? Int ?? 0
        switch floor {
        case .cursor:
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 0, "cursorFloor": lsn, "keepWriters": true])
        case .epoch:
            _ = try await live.route(documentId, "rotate")
            _ = try await live.route(documentId, "rotate")
            _ = try await live.route(documentId, "checkpoint", ["epochFloor": 1, "cursorFloor": 0, "keepWriters": true])
        }

        await x.goOnline()
        try await eventually(timeout: 60, description: "the hand-back") { !heard.value.isEmpty }
        try await live.settled(x, documentId, timeout: 60)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(heard.value.count, 1, "exactly one event")
        let event = try XCTUnwrap(heard.value.first)
        XCTAssertEqual(event.error.code, floor == .cursor ? .documentOfflineWindowExpired : .documentEpochFrozen)
        XCTAssertEqual(event.writes?.map(\.recordId), ["made", "kept"], "every unsent write, in order")
        XCTAssertEqual(event.writes?.map(\.kind), [.create, .patch])
        XCTAssertEqual(event.writes?.map { $0.fields?["f"] }, [.string("made away"), .string("patched away")])

        XCTAssertNil(sheetsX.find(id: "made"), "reverted here")
        XCTAssertEqual(sheetsX.find(id: "kept")?["f"], .string("confirmed"))
        let rows = try await live.roomRows(documentId, "Sheet")
        XCTAssertNil(rows["made"], "nothing applied there")
        XCTAssertEqual(rows["kept"]?["f"] as? String, "confirmed")
        XCTAssertEqual(try sheetsX.count(), rows.count)
        let roomNow = try await live.route(documentId, "state")
        XCTAssertEqual(try live.binding(x, documentId).refreshMarks().cursor, roomNow["lsn"] as? Int, "caught up to the room")

        _ = try sheetsX.create(id: "after", values: ["f": .string("after the refusal")])
        try await live.settled(x, documentId)
        try await eventually(timeout: 20, description: "the next write to land") {
            (try await live.roomRows(documentId, "Sheet"))["after"] != nil
        }
    }

    // MARK: - Behavior 24 (criterion 3): the epoch budget

    func testTheBudgetSpillsThenRefusesLocallyAndARotationLetsWritesContinue() async throws {
        let first = try await live.client("first", models: [Self.row])
        let documentId = try await live.createDocument(first)
        _ = try await live.route(documentId, "set-limits", ["epochEntries": 3, "epochMinSeconds": 3_600])
        try await live.open(first, documentId)
        let marks = try live.binding(first, documentId).refreshMarks()
        XCTAssertEqual([marks.entries, marks.open, marks.grant], [3, 1, 2])

        await first.goOffline()
        let (heard, subscription) = refusals(first)
        defer { subscription.cancel() }
        let rows = try live.member(first, documentId, "Row")
        for n in 1...6 { _ = try rows.create(id: "r\(n)", values: ["n": .number(Double(n))]) }
        XCTAssertEqual(try live.pending(first, documentId).map(\.e), [1, 1, 1, 2, 2, 2], "the fourth spilled to the next epoch")
        XCTAssertThrowsError(try rows.create(id: "r7", values: ["n": .number(7)])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .documentEpochBudget)
        }
        XCTAssertEqual(heard.value.count, 1)
        XCTAssertEqual(heard.value.first?.error.code, .documentEpochBudget)
        XCTAssertEqual(heard.value.first?.writes?.map(\.recordId), ["r7"], "the one write")
        XCTAssertNil(rows.find(id: "r7"))
        XCTAssertEqual(try rows.count(), 6, "everything already written is kept")

        await first.goOnline()
        try await live.settled(first, documentId, timeout: 60)
        try await eventually(timeout: 30, description: "the six to land") { (try await live.roomRows(documentId, "Row")).count == 6 }
        _ = try await live.route(documentId, "rotate")
        _ = try await live.route(documentId, "rotate")
        try await eventually(timeout: 20, description: "the rotation heard") {
            ((try? live.binding(first, documentId).refreshMarks().grant) ?? 0) >= 4
        }
        _ = try rows.create(id: "r7", values: ["n": .number(7)])
        try await live.settled(first, documentId)
        try await eventually(timeout: 20, description: "the write after the rotation to land") {
            (try await live.roomRows(documentId, "Row")).count == 7
        }
    }

    // MARK: - Behavior 25 (criterion 4): constraints

    func testAKeyTheViewHoldsIsRefusedAtTheSaveAndNothingIsSent() async throws {
        let client = try await live.client("one", models: [Self.tag])
        let documentId = try await live.createDocument(client)
        try await live.open(client, documentId)
        let tags = try live.member(client, documentId, "Tag")
        _ = try tags.create(id: "t1", values: ["slug": .string("taken"), "title": .string("first")])
        try await live.settled(client, documentId)
        let before = try live.binding(client, documentId).refreshMarks().nextSeq
        XCTAssertThrowsError(try tags.create(id: "t2", values: ["slug": .string("taken"), "title": .string("second")])) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError, "\(error)")
        }
        XCTAssertEqual(try live.binding(client, documentId).refreshMarks().nextSeq, before)
        XCTAssertEqual(try live.pending(client, documentId), [])
        let rowCount = try await live.roomRows(documentId, "Tag").count
        XCTAssertEqual(rowCount, 1)
    }

    func testTheRoomsRefusalWithdrawsTheClosureAndReachesTheAppOnce() async throws {
        let winnerClient = try await live.client("winner", models: [Self.tag])
        let documentId = try await live.createDocument(winnerClient)
        let loserClient = try await live.client("loser", models: [Self.tag])
        try await live.open(winnerClient, documentId)
        try await live.open(loserClient, documentId)
        let winnerTags = try live.member(winnerClient, documentId, "Tag")
        let tags = try live.member(loserClient, documentId, "Tag")

        _ = try tags.create(id: "other", values: ["slug": .string("other"), "title": .string("confirmed")])
        try await live.settled(loserClient, documentId)
        _ = try tags.create(id: "outside", values: ["slug": .string("outside"), "title": .string("kept")])
        try await live.settled(loserClient, documentId)

        await loserClient.goOffline()
        _ = try winnerTags.create(id: "winner", values: ["slug": .string("shared"), "title": .string("winner")])
        try await live.settled(winnerClient, documentId)
        let (heard, subscription) = refusals(loserClient)
        defer { subscription.cancel() }

        _ = try tags.create(id: "loser", values: ["slug": .string("shared"), "title": .string("loser")])
        try tags.update(id: "loser", values: ["title": .string("loser, patched")])
        try tags.transact {
            try tags.update(id: "loser", values: ["title": .string("loser, in a transaction")])
            try tags.update(id: "other", values: ["title": .string("changed with the loser")])
        }
        _ = try tags.create(id: "unrelated", values: ["slug": .string("unrelated"), "title": .string("outside the closure")])
        XCTAssertEqual(tags.find(id: "loser")?["title"], .string("loser, in a transaction"))
        XCTAssertEqual(tags.find(id: "other")?["title"], .string("changed with the loser"))
        XCTAssertTrue(heard.value.isEmpty)

        await loserClient.goOnline()
        try await eventually(timeout: 60, description: "the refusal to reach the app") { !heard.value.isEmpty }
        try await live.settled(loserClient, documentId, timeout: 60)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(heard.value.count, 1)
        let event = try XCTUnwrap(heard.value.first)
        XCTAssertEqual(event.error.code, .documentConstraintViolated)
        XCTAssertEqual(event.documentId, documentId)
        XCTAssertEqual(event.model, "Tag")
        XCTAssertEqual(event.recordId, "loser")
        XCTAssertEqual(event.conflictingRecord, RecordLogRecordKey(model: "Tag", id: "winner"))
        let writes = try XCTUnwrap(event.writes)
        XCTAssertEqual(writes.map(\.recordId), ["loser", "loser", "loser", "other"])
        XCTAssertEqual(writes.map(\.kind), [.create, .patch, .patch, .patch])
        XCTAssertEqual(writes.map { $0.fields?["title"] }, [
            .string("loser"), .string("loser, patched"), .string("loser, in a transaction"), .string("changed with the loser"),
        ])
        XCTAssertEqual(writes[2].seq, writes[3].seq, "the transaction's two writes were one entry")
        XCTAssertEqual(Set(writes.map(\.seq)).count, 3)

        XCTAssertNil(tags.find(id: "loser"), "the refused record is gone")
        XCTAssertEqual(tags.find(id: "other")?["title"], .string("confirmed"), "the closure's other record is back to its confirmed row")
        XCTAssertEqual(tags.find(id: "unrelated")?["title"], .string("outside the closure"))
        XCTAssertEqual(tags.find(id: "outside")?["title"], .string("kept"))
        let rows = try await live.roomRows(documentId, "Tag")
        XCTAssertNil(rows["loser"])
        XCTAssertEqual(rows["other"]?["title"] as? String, "confirmed")
        XCTAssertEqual(rows["winner"]?["title"] as? String, "winner")

        try tags.update(id: "other", values: ["title": .string("saved after the refusal")])
        try await live.settled(loserClient, documentId)
        try await eventually(timeout: 20, description: "the next save to land") {
            (try await live.roomRows(documentId, "Tag"))["other"]?["title"] as? String == "saved after the refusal"
        }
    }

    // MARK: - Behavior 26 (criterion 5): upserts converge

    func testTwoClientsUpsertingOneKeyApartEndWithOneRecordHoldingBoth() async throws {
        let (documentId, x, y) = try await pair(Self.entry)
        let entriesX = try live.member(x, documentId, "Entry")
        let entriesY = try live.member(y, documentId, "Entry")
        await x.goOffline()
        await y.goOffline()
        let fromY = try entriesY.upsert(["slug": .string("k"), "b": .string("from y")], on: "slug", id: "fromY")
        let fromX = try entriesX.upsert(["slug": .string("k"), "a": .string("from x")], on: "slug", id: "fromX")
        try entriesX.update(id: "fromX", values: ["c": .string("x, later")])
        XCTAssertTrue(fromY.wasCreated)
        XCTAssertTrue(fromX.wasCreated)

        await y.goOnline()
        try await live.settled(y, documentId, timeout: 60)
        await x.goOnline()
        try await live.settled(x, documentId, timeout: 60)
        let whole = { (record: PrimitiveRecord?) -> Bool in
            record?["a"] == .string("from x") && record?["b"] == .string("from y") && record?["c"] == .string("x, later")
        }
        try await eventually(timeout: 30, description: "both clients to hold one merged record") {
            whole(entriesY.find(id: "fromY")) && whole(entriesX.find(id: "fromY"))
        }
        for entries in [entriesX, entriesY] {
            XCTAssertEqual(try entries.query(["slug": "k"]).compactMap { $0["id"]?.stringValue }, ["fromY"])
        }
        XCTAssertNil(entriesX.find(id: "fromX"), "no record under the loser's id")
        XCTAssertEqual(fromX.record["a"], .string("from x"), "the loser's handle reads through the alias")
        XCTAssertEqual(fromX.record["b"], .string("from y"))
        let rows = try await live.roomRows(documentId, "Entry")
        XCTAssertEqual(Array(rows.keys), ["fromY"])
        XCTAssertEqual(rows["fromY"]?["a"] as? String, "from x")
        XCTAssertEqual(rows["fromY"]?["b"] as? String, "from y")
        XCTAssertEqual(rows["fromY"]?["c"] as? String, "x, later")
    }

    // MARK: - Behavior 17 with the room: released

    func testASubscriberTheRoomReleasesOnAFailedDeliveryCatchesUpWithoutReconnecting() async throws {
        let (documentId, x, y) = try await pair(Self.sheet)
        let writer = try live.binding(x, documentId).writer
        var connectionId: String?
        try await eventually(timeout: 20, description: "the room to hold x's subscription") {
            let state = try await live.route(documentId, "state")
            let subscribers = state["subscribers"] as? [[String: Any]] ?? []
            connectionId = subscribers.first { $0["writer"] as? String == writer }?["connectionId"] as? String
            return connectionId != nil
        }
        _ = try await live.route(documentId, "fail-delivery", ["connectionId": try XCTUnwrap(connectionId)])
        let sheetsY = try live.member(y, documentId, "Sheet")
        _ = try sheetsY.create(id: "lost", values: ["f": .string("lost")])
        _ = try sheetsY.create(id: "after", values: ["f": .string("after")])
        try await live.settled(y, documentId)
        let state = try await live.route(documentId, "state")
        XCTAssertGreaterThanOrEqual((state["counters"] as? [String: Any])?["deliveriesFailed"] as? Int ?? 0, 1)
        let sheetsX = try live.member(x, documentId, "Sheet")
        try await eventually(timeout: 20, description: "x to hold both records written after its delivery failed") {
            sheetsX.find(id: "lost")?["f"] == .string("lost") && sheetsX.find(id: "after")?["f"] == .string("after")
        }
        try await eventually(timeout: 20, description: "x's cursor to reach the room's") {
            let room = try await live.route(documentId, "state")
            return try live.binding(x, documentId).refreshMarks().cursor == room["lsn"] as? Int
        }
    }

    // MARK: - Networking turned off and on with the socket left open

    func testEntriesQueuedWhileNetworkingWasOffLeaveWhenItIsOnAgain() async throws {
        let client = try await live.client("toggle", models: [Self.row])
        let documentId = try await live.createDocument(client)
        try await live.open(client, documentId)
        let rows = try live.member(client, documentId, "Row")
        client.setNetworkMode(.offline)
        _ = try rows.create(id: "q1", values: ["n": .number(1)])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try live.pending(client, documentId).count, 1, "nothing leaves while networking is off")
        client.setNetworkMode(.online)
        try await live.settled(client, documentId)
        try await eventually(timeout: 20, description: "the queued entry to land") {
            (try await live.roomRows(documentId, "Row"))["q1"] != nil
        }
    }

    // MARK: - Behaviors 27 and 28 with the room, edge 48, and the HTTP 410 of behavior 32

    func testConfirmWaitsForTheRoomAndSyncStateFollowsAndALargeEntryTravelsAlone() async throws {
        let client = try await live.client("confirm", models: [Self.row])
        let documentId = try await live.createDocument(client)
        try await live.open(client, documentId)
        let rows = try live.member(client, documentId, "Row")

        let record = try await rows.save(id: "c1", values: ["n": .number(1)], confirm: true)
        XCTAssertEqual(record.syncState, RecordSyncState.confirmed, "resolved only after the room acknowledged")
        XCTAssertTrue(try live.pending(client, documentId).allSatisfy { $0.seq != record.recordLogSeq || $0.acked != nil })

        await client.goOffline()
        let quick = try await rows.save(id: "c2", values: ["n": .number(2)], confirm: false)
        XCTAssertEqual(quick.syncState, RecordSyncState.pending)
        await client.goOnline()
        try await eventually(timeout: 30, description: "the pending save to confirm") { quick.syncState == RecordSyncState.confirmed }

        // Edge 48: an entry larger than the frame target travels alone and is acknowledged.
        let big = String(repeating: "x", count: 100 * 1024)
        let large = try await rows.save(id: "big", values: ["body": .string(big)], confirm: true)
        XCTAssertEqual(large.syncState, RecordSyncState.confirmed)
        let roomRow = try await live.roomRows(documentId, "Row")["big"]
        XCTAssertEqual((roomRow?["body"] as? String)?.count, big.count)

        // Behavior 32: a route the room does not serve for a format-3 document answers 410.
        // (`/snapshots` serves format 3 since #4310; the state export still does not.)
        let token = live.app.ownerJWT
        let http = HttpClient(config: HttpClientConfig(
            apiUrl: TestConfig.httpUrl, appId: live.app.appId,
            getToken: { token }, getConnectionId: { nil },
            getGlobalAdminAppId: { TestConfig.globalAdminAppId }, logger: Logger(level: .none),
            refreshAccessToken: { .invalid }
        ))
        do {
            let _: JSONValue? = try await http.requestOptional(method: .get, path: "/documents/\(documentId)/export/state")
            XCTFail("the state export does not serve a format-3 document")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 410)
            XCTAssertEqual(error.serverCode, "DOCUMENT_FORMAT_UNSUPPORTED")
        }
    }
}
