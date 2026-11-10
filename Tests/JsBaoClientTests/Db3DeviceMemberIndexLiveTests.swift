import XCTest
@testable import JsBaoClient

/// #5223 behavior 21 — member indexes on a synced db3 placed on the device,
/// live against the dev server: `kind: .members` placed `.device` on `tags`
/// and `.both` on `labels` register; the device holds both tables, the room
/// only the `both` one; `$contains`, an any-of count, a facet and a
/// membership level answer as before, and the any-of count as the room's
/// HTTP count route; the oracle on a copy of the store file finds no drift.
final class Db3DeviceMemberIndexLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private typealias L = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-device-members-5223")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private struct Reads: Equatable {
        var contains: [String]
        var anyOf: Int
        var facet: Set<String>
        var membership: Set<String>
    }

    private func reads(_ notes: MultiDocModel) throws -> Reads {
        let count = AggregateOperation(type: .count)
        let text = { (rows: [[String: JSONValue]]) in Set(rows.map { RecordLogJSON.text(.object($0)) }) }
        return Reads(
            contains: try notes.query(["tags": ["$contains": "sweet"]], options: QueryOptions(sort: ["title": 1]))
                .compactMap { $0["title"]?.stringValue },
            anyOf: try notes.count(["$or": [["labels": ["$contains": "a"]], ["labels": ["$contains": "c"]]]]),
            facet: text(try notes.aggregate(AggregateOptions(groupBy: ["tags"], operations: [count]))),
            membership: text(try notes.aggregate(AggregateOptions(
                groupBy: [.stringSetMembership(field: "labels", contains: "b")], operations: [count]
            )))
        )
    }

    func testMemberIndexesPlacedOnTheDeviceAndBothBuildOnTheDeviceAndAnswerAsBefore() async throws {
        let (x, id) = try await L.subscribed(live, "x")
        let notes = x.sharedModel(for: L.note)
        let before = try reads(notes)
        XCTAssertEqual(before.contains, ["Pear tart", "Red apple pie"])

        let device = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "tags", kind: .members, on: .device))
        let both = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "labels", kind: .members, on: .both))
        XCTAssertEqual(device.name, "idx_members_note_tags")
        XCTAssertEqual(device.kind, .members)
        XCTAssertEqual(device.on, .device)
        XCTAssertTrue(device.members)
        XCTAssertEqual(both.name, "idx_members_note_labels")
        XCTAssertEqual(both.on, .both)
        XCTAssertTrue(both.members)
        XCTAssertEqual(try L.objects(live, x, id, "table", like: #"idx\_record\_log\_members\_%"#), [
            RecordLogIndexes.memberTableName(documentId: id, model: "Note", field: "labels"),
            RecordLogIndexes.memberTableName(documentId: id, model: "Note", field: "tags"),
        ].sorted())
        XCTAssertEqual(try reads(notes), before)

        let filter = RecordLogJSON.text(["$or": [["labels": ["$contains": "a"]], ["labels": ["$contains": "c"]]]])
        let encoded = filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? filter
        let http = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/documents/\(id)/records/Note/count?filter=\(encoded)", body: nil,
            jwt: live.app.ownerJWT
        )
        XCTAssertEqual((http["count"] as? NSNumber)?.intValue, before.anyOf)
        let storage = try await live.route(id, "storage")
        XCTAssertEqual((storage["memberIndexes"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["idx_members_note_labels"])
        let drift = try await Db3DeviceIndexOracle.driftOnACopy(live.binding(x, id).store)
        XCTAssertEqual(drift, [])
    }
}
