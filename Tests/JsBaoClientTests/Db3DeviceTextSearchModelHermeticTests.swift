import XCTest
import YSwift
@testable import JsBaoClient

/// #5223 behavior 18 — `_score` rides the model API and the model-free
/// records: `DynamicModel.query` and `queryPaged` rows (`PrimitiveRow.raw`)
/// hold it as a number on a `$search`, the shared model's first row is the
/// best match, a save through the model of a record read from a search
/// commits no `_score`, and `client.db3.records(id).query` rows carry
/// it while `count` counts the matches.
final class Db3DeviceTextSearchModelHermeticTests: XCTestCase {

    private static let schema = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
    ])

    private var fixture: RecordLogViewFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("text-model")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    func testScoreRidesTheModelAPIAndTheRecordsAndIsNeverSaved() throws {
        let notes = try fixture.member(Self.schema, "db3-m")
        let binding = try fixture.open("db3-m")
        try binding.store.syncIndexes([Db3TextIndexFixture.textEntry(["title", "body"], ["weights": ["title": 3]])])
        try fixture.seed("db3-m", "Note", [
            ["id": "a", "title": "Apple apple apple", "body": "red"], ["id": "b", "title": "Pie", "body": "apple"],
            ["id": "c", "title": "Pear", "body": "green"], ["id": "d", "title": "Apple", "body": "tart"],
        ])

        let rows = try notes.query(["$search": "apple"])
        XCTAssertEqual(rows.compactMap { $0["id"]?.stringValue }.first, "a")
        XCTAssertEqual(Set(rows.compactMap { $0["id"]?.stringValue }), ["a", "b", "d"])
        let scores = rows.compactMap { $0["_score"]?.numberValue }
        XCTAssertEqual(scores.count, 3)
        XCTAssertEqual(scores, scores.sorted(by: >))
        let paged = try notes.queryPaged(["$search": "apple"], options: QueryOptions(limit: 2))
        XCTAssertEqual(paged.data.count, 2)
        XCTAssertTrue(paged.data.allSatisfy { $0.raw["_score"]?.numberValue != nil })
        XCTAssertNotNil(paged.nextCursor)
        XCTAssertEqual(try notes.count(["$search": "apple"]), 3)
        XCTAssertEqual(try fixture.shared(Self.schema).query(["$search": "apple"]).first?["id"], "a")

        // A save of a record read from a search commits its fields, never `_score`.
        try notes.update(id: "a", values: ["body": .string("crisp")])
        let pending = try binding.store.pendingOf(binding.writer)
        XCTAssertFalse(pending.isEmpty)
        XCTAssertFalse(pending.contains { RecordLogJSON.text($0.storedJSON).contains("_score") })
        XCTAssertNil(try binding.store.read(model: "Note", id: "a")?["_score"])
        XCTAssertEqual(try binding.store.read(model: "Note", id: "a")?["body"], "crisp")

        let records = try fixture.records("db3-m")
        let found = try records.query("Note", ["$search": "apple"])
        XCTAssertEqual(found.data.first?["id"], "a")
        XCTAssertTrue(found.data.allSatisfy { $0["_score"]?.numberValue != nil })
        XCTAssertEqual(try records.count("Note", ["$search": "apple"]), 3)
        XCTAssertTrue(try records.query("Note", ["title": "Pear"]).data.allSatisfy { $0["_score"] == nil })
    }
}
