import XCTest
@testable import JsBaoClient

/// #4797 behavior 32 — `increment`, `condition` and `ifNotExists` on the Swift
/// model API, live against the room: the twin of js-bao's
/// `js-bao-client-increment-4797` suite.
///
/// - Two Swift clients' offline increments of one field both count, whichever
///   reconnects first; the call answers the new values at once, and with
///   `confirm` the room's even while another increment is pending here.
/// - A record the view does not hold is refused `.db3RecordNotFound` locally;
///   one deleted on the other client is handed back under that code with
///   `current.row == nil`.
/// - Inside `transact`, a save of a field then an increment of it ends at the
///   saved value plus the delta; a create then an increment of a new record
///   lands.
/// - `save(... options: Db3WriteOptions(condition:))` passes and is refused
///   `DB3_CONDITION_NOT_MET` with `current`, an unchanged value included; `ifNotExists` lands on a free id
///   and is refused on a live one; `delete(id:options:)` takes a condition.
final class RecordLogIncrementLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let counter = PrimitiveSchema(
        name: "Counter",
        fields: ["id": FieldDescriptor(type: .id), "n": FieldDescriptor(type: .number), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-increment")
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

    /// Two clients on one db3, both holding `r1` with `n`.
    private func pair(n: Double = 0) async throws -> (String, JsBaoClient, JsBaoClient, DynamicModel, DynamicModel) {
        let x = try await live.client("x", models: [Self.counter])
        let documentId = try await live.createDocument(x)
        let y = try await live.client("y", models: [Self.counter])
        try await live.open(x, documentId)
        try await live.open(y, documentId)
        let countersX = try live.member(x, documentId, "Counter")
        let countersY = try live.member(y, documentId, "Counter")
        _ = try countersX.create(id: "r1", values: ["n": .number(n)])
        try await live.settled(x, documentId)
        try await eventually(timeout: 20, description: "y to hold the record") { countersY.find(id: "r1") != nil }
        return (documentId, x, y, countersX, countersY)
    }

    private func roomN(_ documentId: String, _ id: String = "r1") async throws -> Double? {
        let rows = try await live.roomRows(documentId, "Counter")
        return (rows[id]?["n"] as? NSNumber)?.doubleValue
    }

    func testTwoOfflineIncrementsBothCountWhicheverReconnectsFirst() async throws {
        for xFirst in [true, false] {
            let (documentId, x, y, countersX, countersY) = try await pair()
            await x.goOffline()
            await y.goOffline()
            let answeredX = try await countersX.increment(id: "r1", fields: ["n": 1])
            let answeredY = try await countersY.increment(id: "r1", fields: ["n": 1])
            XCTAssertEqual(answeredX, ["n": 1])
            XCTAssertEqual(answeredY, ["n": 1])
            let (first, second) = xFirst ? (x, y) : (y, x)
            await first.goOnline()
            try await live.settled(first, documentId, timeout: 60)
            await second.goOnline()
            try await live.settled(second, documentId, timeout: 60)
            try await eventually(timeout: 30, description: "both clients at 2") {
                countersX.find(id: "r1")?["n"] == .number(2) && countersY.find(id: "r1")?["n"] == .number(2)
            }
            let roomValue = try await roomN(documentId)
            XCTAssertEqual(roomValue, 2)
            await live.destroy()
            live = try RecordLogLiveApp(ctx: ctx, app: live.app)
        }
    }

    func testConfirmAnswersTheRoomsValuesThoughAnotherIncrementIsPending() async throws {
        let (documentId, _, _, countersX, _) = try await pair(n: 1)
        async let confirmed = countersX.increment(id: "r1", fields: ["n": 1], options: Db3WriteOptions(confirm: true))
        // `async let` may start late: the second increment follows the first.
        try await eventually(timeout: 10, description: "the first increment in the view") { countersX.find(id: "r1")?["n"] == .number(2) }
        let later = try await countersX.increment(id: "r1", fields: ["n": 100])
        XCTAssertEqual(later, ["n": 102])
        let value = try await confirmed
        XCTAssertEqual(value, ["n": 2])
        try await roomReaches(documentId, ["r1": 102])
    }

    func testAMissingRecordIsRefusedLocallyAndADeletedOneIsHandedBack() async throws {
        let (documentId, x, _, countersX, countersY) = try await pair(n: 1)
        do {
            _ = try await countersX.increment(id: "missing", fields: ["n": 1])
            XCTFail("a record the view does not hold is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3RecordNotFound)
        }
        let (heard, subscription) = refusals(x)
        defer { subscription.cancel() }
        await x.goOffline()
        async let refused = countersX.increment(id: "r1", fields: ["n": 1], options: Db3WriteOptions(confirm: true))
        try await Task.sleep(nanoseconds: 200_000_000)
        try await countersY.delete(id: "r1", options: Db3WriteOptions(confirm: true))
        await x.goOnline()
        do {
            _ = try await refused
            XCTFail("the room refuses an increment of a deleted record")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3RecordNotFound)
            XCTAssertEqual(error.details?["current"], .object(["model": "Counter", "id": "r1", "row": .null]))
        }
        try await eventually(timeout: 20, description: "the hand-back event") { !heard.value.isEmpty }
        XCTAssertEqual(heard.value.first?.current, RecordLogCurrentRecord(model: "Counter", id: "r1", row: nil))
        let rows = try await live.roomRows(documentId, "Counter")
        XCTAssertNil(rows["r1"])
    }

    func testInsideTransactASaveThenAnIncrementEndsAtTheSumAndACreatedRecordTakesOne() async throws {
        let (documentId, x, _, countersX, _) = try await pair(n: 0)
        var answered: [String: Double] = [:]
        try countersX.transact {
            try countersX.update(id: "r1", values: ["n": .number(10)])
            answered = try countersX.increment(id: "r1", fields: ["n": 1])
            _ = try countersX.create(id: "r2", values: ["n": .number(5)])
            _ = try countersX.increment(id: "r2", fields: ["n": 2])
        }
        XCTAssertEqual(answered, ["n": 11])
        try await live.settled(x, documentId)
        try await roomReaches(documentId, ["r1": 11, "r2": 7])
    }

    /// Wait until the room's rows hold each `n`.
    private func roomReaches(_ documentId: String, _ expected: [String: Double], timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Double?] = [:]
        while Date() < deadline {
            let rows = try await live.roomRows(documentId, "Counter")
            last = expected.mapValues { _ in nil }
            for id in expected.keys { last[id] = (rows[id]?["n"] as? NSNumber)?.doubleValue }
            if expected.allSatisfy({ last[$0.key] == $0.value }) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("the room did not reach \(expected): \(last)")
    }

    func testTheWriteGuardsOnSaveAndDelete() async throws {
        let (documentId, x, _, countersX, _) = try await pair(n: 1)
        let (heard, subscription) = refusals(x)
        defer { subscription.cancel() }
        _ = try await countersX.save(id: "r1", values: ["n": .number(2)], changedFields: ["n"], options: Db3WriteOptions(condition: ["n": 1]))
        try await live.settled(x, documentId)
        let afterPass = try await roomN(documentId)
        XCTAssertEqual(afterPass, 2)
        do {
            _ = try await countersX.save(
                id: "r1", values: ["n": .number(5)], changedFields: ["n"], options: Db3WriteOptions(condition: ["n": 1], confirm: true)
            )
            XCTFail("a failing condition is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
            XCTAssertEqual(error.details?["current"]?["row"]?["n"], 2)
        }
        try await eventually(timeout: 20, description: "the refusal event") { heard.value.contains { $0.error.code == .db3ConditionNotMet } }
        XCTAssertEqual(heard.value.first { $0.error.code == .db3ConditionNotMet }?.current?.row?["n"], 2)
        // A guarded save of the value already held still goes to the room to
        // be judged (review 4797-C002): it is refused, not skipped as clean.
        do {
            _ = try await countersX.save(
                id: "r1", values: ["n": .number(2)], changedFields: ["n"], options: Db3WriteOptions(condition: ["n": 0], confirm: true)
            )
            XCTFail("an unchanged save with a failing condition is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
            XCTAssertEqual(error.details?["current"]?["row"]?["n"], 2)
        }

        _ = try await countersX.save(id: "fresh", values: ["n": .number(1)], options: Db3WriteOptions(ifNotExists: true, confirm: true))
        do {
            _ = try await countersX.save(id: "fresh", values: ["n": .number(9)], options: Db3WriteOptions(ifNotExists: true, confirm: true))
            XCTFail("ifNotExists on a live record is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
        }
        let freshN = try await roomN(documentId, "fresh")
        XCTAssertEqual(freshN, 1)

        do {
            try await countersX.delete(id: "r1", options: Db3WriteOptions(condition: ["n": 99], confirm: true))
            XCTFail("a failing condition on a delete is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
        }
        try await countersX.delete(id: "r1", options: Db3WriteOptions(condition: ["n": 2], confirm: true))
        let rows = try await live.roomRows(documentId, "Counter")
        XCTAssertNil(rows["r1"])
    }
}
