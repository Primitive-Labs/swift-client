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
        let rows = try model.query()
        XCTAssertEqual(rows.count, 3)
    }

    func testQueryWithFilter() throws {
        let model = try seeded()
        let done = try model.query(["done": true])
        XCTAssertEqual(done.count, 2)
        XCTAssertEqual(Set(done.compactMap { $0["title"]?.stringValue }), ["beta", "gamma"])
    }

    func testCountWithFilter() throws {
        let model = try seeded()
        XCTAssertEqual(try model.count(["done": true]), 2)
        XCTAssertEqual(try model.count(), 3)
    }

    /// A numeric filter operand has to bind as INTEGER when it is integral.
    /// Only `number` fields get a REAL column; `string`/`date`/`id`/`json`
    /// fields are TEXT, and SQLite converts the bound operand with the
    /// column's TEXT affinity — `5` becomes `'5'` but `5.0` becomes `'5.0'`,
    /// so binding every number as `Double` would stop matching a stored `"5"`.
    func testIntegralNumericOperandMatchesStringColumn() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let codes = PrimitiveSchema(
            name: "codes_query",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "code": FieldDescriptor(type: .string),
            ]
        )
        let model = DynamicModel(doc: doc, schema: codes)
        _ = try model.create(id: "c1", values: ["code": .string("5")])
        _ = try model.create(id: "c2", values: ["code": .string("7")])

        XCTAssertEqual(try model.query(["code": 5]).count, 1)
        XCTAssertEqual(try model.query(["code": ["$in": [5, 9]]]).count, 1)
        XCTAssertEqual(try model.query(["code": ["$ne": 5]]).count, 1)
        // A non-integral operand keeps binding as REAL — `'5.5'` is what a
        // TEXT column would have to hold for it to match.
        XCTAssertEqual(try model.query(["code": 5.5]).count, 0)
    }

    /// The integral-binding rule must not disturb a real REAL column: SQLite
    /// compares INTEGER and REAL numerically, so `5` still matches `5.0`.
    func testIntegralNumericOperandStillMatchesNumberColumn() throws {
        let model = try seeded()
        XCTAssertEqual(try model.query(["priority": 5]).count, 1)
        XCTAssertEqual(try model.query(["priority": ["$gte": 3]]).count, 2)
    }

    func testAggregateGrouped() throws {
        let model = try seeded()
        let stats = try model.aggregate(AggregateOptions(
            groupBy: ["done"],
            operations: [
                AggregateOperation(type: .count),
                AggregateOperation(type: .avg, field: "priority", outputField: "avgPri"),
            ]
        ))
        XCTAssertEqual(stats.count, 2)
    }
}
