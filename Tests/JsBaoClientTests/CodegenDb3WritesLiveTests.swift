import XCTest
@testable import JsBaoClient

/// #4942 behaviors 1–5, edge cases E1, E2 and E6 — a generated model's db3
/// writes, live against the room.
///
/// Every write goes through the generated `TaskRecord` facade, which calls
/// `client.codegen` on the default client (`JsBaoClient.configureDefault`):
///
/// - `save(in:options:)` with a condition lands when it holds and, under
///   `confirm`, is refused `.db3ConditionNotMet` with the room's row when it
///   does not; `ifNotExists` is pending and out of the view offline, lands on
///   a free id once acknowledged (an explicit and a minted id), and is refused
///   on a live one.
/// - `TaskRecord.increment` made offline on two clients counts twice, in
///   either reconnect order; with `confirm` it answers the room's values, and
///   of a record deleted on the other client it is refused
///   `.db3RecordNotFound` with `current.row == nil`.
/// - `delete(in:options:)` with a failing condition keeps the record; with a
///   passing one the record is gone.
final class CodegenDb3WritesLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-codegen-db3-writes")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// One client on a fresh db3 holding `t1`, configured as the default client.
    private func single(priority: Double = 1) async throws -> (String, JsBaoClient) {
        let x = try await live.client("x", models: [TaskRecord.primitiveSchema])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        JsBaoClient.configureDefault(x)
        try TaskRecord(id: "t1", title: "Task", priority: priority).save(in: documentId)
        try await live.settled(x, documentId)
        return (documentId, x)
    }

    /// Two clients on one db3, both holding `t1`; `x` is the default client.
    private func pair(priority: Double = 0) async throws -> (String, JsBaoClient, JsBaoClient) {
        let (documentId, x) = try await single(priority: priority)
        let y = try await live.client("y", models: [TaskRecord.primitiveSchema])
        try await live.open(y, documentId)
        let membersY = try live.member(y, documentId, "tasks")
        try await eventually(timeout: 20, description: "y to hold the record") { membersY.find(id: "t1") != nil }
        return (documentId, x, y)
    }

    private func roomRow(_ documentId: String, _ id: String = "t1") async throws -> [String: Any]? {
        try await live.roomRows(documentId, "tasks")[id]
    }

    private func roomPriority(_ documentId: String, _ id: String = "t1") async throws -> Double? {
        (try await roomRow(documentId, id)?["priority"] as? NSNumber)?.doubleValue
    }

    /// `t1`'s priority in `client`'s view.
    private func viewPriority(_ client: JsBaoClient, _ documentId: String) throws -> PrimitiveValue? {
        try live.member(client, documentId, "tasks").find(id: "t1")?["priority"]
    }

    // MARK: - Behavior 1, edge case E1

    func testASaveWithAConditionLandsWhenItHoldsAndIsRefusedWithTheRoomsRowWhenNot() async throws {
        let (documentId, x) = try await single(priority: 1)
        var task = try XCTUnwrap(TaskRecord.find("t1"))
        task.priority = 2
        _ = try await task.save(in: documentId, options: Db3WriteOptions(condition: ["priority": 1]))
        try await live.settled(x, documentId)
        let afterPass = try await roomPriority(documentId)
        XCTAssertEqual(afterPass, 2)

        // Under confirm the answer carries the accepted values.
        task = try XCTUnwrap(TaskRecord.find("t1"))
        task.priority = 3
        let confirmed = try await task.save(in: documentId, options: Db3WriteOptions(condition: ["priority": 2], confirm: true))
        XCTAssertEqual(confirmed.priority, 3)
        XCTAssertTrue(confirmed._changedFields.isEmpty)

        task.priority = 9
        do {
            _ = try await task.save(in: documentId, options: Db3WriteOptions(condition: ["priority": 1], confirm: true))
            XCTFail("a failing condition is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
            XCTAssertEqual(error.details?["current"]?["row"]?["priority"], 3)
        }
        try await live.settled(x, documentId)
        let afterRefusal = try await roomPriority(documentId)
        XCTAssertEqual(afterRefusal, 3)
        XCTAssertEqual(try TaskRecord.find("t1")?.priority, 3)

        // The facade call itself, as the generated model makes it.
        _ = try await x.codegen.save(
            TaskRecord.primitiveSchema, id: "t1", values: ["priority": .number(4)], in: documentId,
            changedFields: ["priority"], options: Db3WriteOptions(condition: ["priority": 3], confirm: true)
        )
        let afterFacade = try await roomPriority(documentId)
        XCTAssertEqual(afterFacade, 4)
    }

    // MARK: - Behavior 2, edge case E6

    func testTwoOfflineIncrementsBothCountWhicheverReconnectsFirst() async throws {
        for xFirst in [true, false] {
            let (documentId, x, y) = try await pair()
            await x.goOffline()
            await y.goOffline()
            JsBaoClient.configureDefault(x)
            let answeredX = try await TaskRecord.increment(id: "t1", fields: ["priority": 1], in: documentId)
            JsBaoClient.configureDefault(y)
            let answeredY = try await TaskRecord.increment(id: "t1", fields: ["priority": 1], in: documentId)
            XCTAssertEqual(answeredX, ["priority": 1])
            XCTAssertEqual(answeredY, ["priority": 1])
            // Each write went to the default client of its call.
            XCTAssertEqual(try live.pending(x, documentId).count, 1)
            XCTAssertEqual(try live.pending(y, documentId).count, 1)
            let (first, second) = xFirst ? (x, y) : (y, x)
            await first.goOnline()
            try await live.settled(first, documentId, timeout: 60)
            await second.goOnline()
            try await live.settled(second, documentId, timeout: 60)
            try await eventually(timeout: 30, description: "both clients at 2") {
                try self.viewPriority(x, documentId) == .number(2) && self.viewPriority(y, documentId) == .number(2)
            }
            let roomValue = try await roomPriority(documentId)
            XCTAssertEqual(roomValue, 2)
            JsBaoClient.clearDefault()
            await live.destroy()
            live = try RecordLogLiveApp(ctx: ctx, app: live.app)
        }
    }

    // MARK: - Behavior 3

    func testAConfirmedIncrementAnswersTheRoomAndADeletedRecordIsHandedBack() async throws {
        let (documentId, x, y) = try await pair(priority: 1)
        let confirmed = try await TaskRecord.increment(
            id: "t1", fields: ["priority": 1], in: documentId, options: Db3WriteOptions(confirm: true)
        )
        XCTAssertEqual(confirmed, ["priority": 2])
        let membersY = try live.member(y, documentId, "tasks")
        try await eventually(timeout: 20, description: "y to see the increment") { membersY.find(id: "t1")?["priority"] == .number(2) }

        await x.goOffline()
        async let refused = TaskRecord.increment(id: "t1", fields: ["priority": 1], in: documentId, options: Db3WriteOptions(confirm: true))
        try await Task.sleep(nanoseconds: 200_000_000)
        try await membersY.delete(id: "t1", options: Db3WriteOptions(confirm: true))
        await x.goOnline()
        do {
            _ = try await refused
            XCTFail("the room refuses an increment of a deleted record")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3RecordNotFound)
            XCTAssertEqual(error.details?["current"], .object(["model": "tasks", "id": "t1", "row": .null]))
        }
        let row = try await roomRow(documentId)
        XCTAssertNil(row)
    }

    // MARK: - Behavior 4

    func testADeleteWithAConditionKeepsTheRecordWhenItFailsAndDeletesWhenItHolds() async throws {
        let (documentId, x) = try await single(priority: 1)
        let task = try XCTUnwrap(TaskRecord.find("t1"))
        do {
            try await task.delete(in: documentId, options: Db3WriteOptions(condition: ["priority": 7], confirm: true))
            XCTFail("a failing condition is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
        }
        try await live.settled(x, documentId)
        let kept = try await roomRow(documentId)
        XCTAssertNotNil(kept)
        XCTAssertNotNil(try TaskRecord.find("t1"))

        try await task.delete(in: documentId, options: Db3WriteOptions(condition: ["priority": 1]))
        try await live.settled(x, documentId)
        let gone = try await roomRow(documentId)
        XCTAssertNil(gone)
        XCTAssertNil(try TaskRecord.find("t1"))
    }

    // MARK: - Behavior 5, edge case E2

    func testAnIfNotExistsSaveIsHeldOfflineLandsOnAFreeIdAndIsRefusedOnALiveOne() async throws {
        let (documentId, x) = try await single(priority: 1)
        await x.goOffline()
        let minted = TaskRecord(title: "Minted")
        _ = try await TaskRecord(id: "standup", title: "Standup").save(in: documentId, options: Db3WriteOptions(ifNotExists: true))
        _ = try await minted.save(in: documentId, options: Db3WriteOptions(ifNotExists: true))
        XCTAssertEqual(try live.pending(x, documentId).count, 2)
        XCTAssertNil(try TaskRecord.find("standup"))
        XCTAssertNil(try TaskRecord.find(minted.id))

        await x.goOnline()
        try await live.settled(x, documentId, timeout: 60)
        for id in ["standup", minted.id] {
            let row = try await roomRow(documentId, id)
            XCTAssertNotNil(row, id)
            try await eventually(timeout: 20, description: "\(id) in the view") { try TaskRecord.find(id) != nil }
        }
        XCTAssertEqual(try TaskRecord.find(minted.id)?.title, "Minted")

        do {
            _ = try await TaskRecord(id: "t1", title: "Taken", priority: 9)
                .save(in: documentId, options: Db3WriteOptions(ifNotExists: true, confirm: true))
            XCTFail("ifNotExists on a live record is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ConditionNotMet)
        }
        let holder = try await roomRow(documentId)
        XCTAssertEqual(holder?["title"] as? String, "Task")
        XCTAssertEqual((holder?["priority"] as? NSNumber)?.doubleValue, 1)
    }
}
