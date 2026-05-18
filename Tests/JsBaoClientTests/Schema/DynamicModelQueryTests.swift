import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests that `DynamicModel` exposes the SQLite-backed query path
/// (`query`, `count`, `aggregate`) using the existing
/// `BaoModelQueryEngine`. Per Work Item 1's plan, the dirty-flag rebuild
/// strategy stays in place — Work Item 2 swaps it for per-record
/// observers.
final class DynamicModelQueryTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "tasks_query",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string),
            "priority": FieldDescriptor(type: .number),
            "done":     FieldDescriptor(type: .boolean),
        ]
    )

    private func seeded() throws -> DynamicModel {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "t1", values: [
            "title": .string("alpha"), "priority": .number(1), "done": .boolean(false),
        ])
        _ = try model.create(id: "t2", values: [
            "title": .string("beta"), "priority": .number(5), "done": .boolean(true),
        ])
        _ = try model.create(id: "t3", values: [
            "title": .string("gamma"), "priority": .number(3), "done": .boolean(true),
        ])
        return model
    }

    func testQueryAll() throws {
        let model = try seeded()
        let rows = model.query()
        XCTAssertEqual(rows.count, 3)
    }

    func testQueryWithFilter() throws {
        let model = try seeded()
        let done = model.query(["done": true])
        XCTAssertEqual(done.count, 2)
        XCTAssertEqual(Set(done.compactMap { $0["title"] as? String }), ["beta", "gamma"])
    }

    func testCountWithFilter() throws {
        let model = try seeded()
        XCTAssertEqual(model.count(["done": true]), 2)
        XCTAssertEqual(model.count(), 3)
    }

    func testAggregateGrouped() throws {
        let model = try seeded()
        let stats = model.aggregate(AggregateOptions(
            groupBy: ["done"],
            operations: [
                AggregateOperation(type: .count),
                AggregateOperation(type: .avg, field: "priority", outputField: "avgPri"),
            ]
        ))
        XCTAssertEqual(stats.count, 2)
    }
}
