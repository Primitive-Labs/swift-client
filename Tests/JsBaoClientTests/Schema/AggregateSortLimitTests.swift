import XCTest
@testable import JsBaoClient
import YSwift

/// Aggregation supports `sort` + `limit` to express top-N rollups in
/// one SQL query — matches js-bao browser.js:4522 (aggregation
/// options documented with sort+limit, SQL builder at ~line 4740).
///
/// This closes gap (B) from the browser-vs-Swift audit. Without these
/// options callers had to sort & slice the aggregate result in Swift
/// memory; with them the SQL does it in one pass.
final class AggregateSortLimitTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "agg_events",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "kind":  FieldDescriptor(type: .string, indexed: true),
            "score": FieldDescriptor(type: .number),
        ]
    )

    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        // 3 records for 'login', 2 for 'signup', 1 for 'purchase'.
        let seed: [(id: String, kind: String, score: Double)] = [
            ("l1", "login", 5), ("l2", "login", 3), ("l3", "login", 7),
            ("s1", "signup", 10), ("s2", "signup", 4),
            ("p1", "purchase", 12),
        ]
        for rec in seed {
            _ = try model.create(id: rec.id, values: [
                "kind":  .string(rec.kind),
                "score": .number(rec.score),
            ])
        }
        return model
    }

    // MARK: - sort by aggregate output (COUNT DESC is the top-N case)

    func testSortByCountDescendingOrdersGroups() throws {
        let model = try seeded()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            sort: AggregateSort(field: "n", direction: -1)
        ))
        XCTAssertEqual(
            rows.compactMap { $0["kind"] as? String },
            ["login", "signup", "purchase"],
            "Ordered by count DESC"
        )
    }

    func testSortByCountAscending() throws {
        let model = try seeded()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            sort: AggregateSort(field: "n", direction: 1)
        ))
        XCTAssertEqual(
            rows.compactMap { $0["kind"] as? String },
            ["purchase", "signup", "login"]
        )
    }

    // MARK: - sort by a group-by field directly

    func testSortByGroupFieldOrders() throws {
        let model = try seeded()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            sort: AggregateSort(field: "kind", direction: 1)
        ))
        XCTAssertEqual(
            rows.compactMap { $0["kind"] as? String },
            ["login", "purchase", "signup"]
        )
    }

    // MARK: - limit

    func testLimitCapsResults() throws {
        let model = try seeded()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            sort: AggregateSort(field: "n", direction: -1),
            limit: 1
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["kind"] as? String, "login")
    }

    /// Top-2 by sum of score — combines sort by a numeric aggregate
    /// + limit. Exercises the primary use case.
    func testSortBySumAndLimit() throws {
        let model = try seeded()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .sum, field: "score", outputField: "total")],
            sort: AggregateSort(field: "total", direction: -1),
            limit: 2
        ))
        XCTAssertEqual(rows.count, 2)
        // login sum = 15, signup sum = 14, purchase sum = 12
        XCTAssertEqual(rows[0]["kind"] as? String, "login")
        XCTAssertEqual(rows[1]["kind"] as? String, "signup")
    }

    // MARK: - sort + limit + filter

    func testSortAndLimitComposeWithFilter() throws {
        let model = try seeded()
        // Only consider scores >= 5. Remaining: login l1(5), l3(7), signup s1(10), purchase p1(12).
        // Grouped: login=2, signup=1, purchase=1. Top-2 by count DESC:
        // login first; signup and purchase tie — id-implicit tie-break
        // isn't part of the aggregate contract; we just check the
        // top-1 is login.
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            filter: ["score": ["$gte": 5]],
            sort: AggregateSort(field: "n", direction: -1),
            limit: 1
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["kind"] as? String, "login")
        XCTAssertEqual(rows[0]["n"] as? Int, 2)
    }

    // MARK: - cross-doc via MultiDocModel

    /// Per-doc scoped aggregate with `sort` + `limit` but no
    /// `groupBy` / no filter. The naive implementation appended
    /// `WHERE _meta_doc_id = ?` after the existing `ORDER BY ... LIMIT`
    /// clauses, producing invalid SQL and silently returning `[]`.
    /// The scope predicate must go before ORDER BY / LIMIT.
    func testScopedAggregateWithSortAndLimitNoGroupBy() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: ["kind": .string("login"), "score": .number(5)])
        _ = try a.create(id: "a2", values: ["kind": .string("login"), "score": .number(3)])

        // COUNT(*) across the (scoped) doc, with sort + limit. Without
        // groupBy this is a single-row aggregate — sort/limit are
        // degenerate but the SQL must still be valid.
        let rows = a.aggregate(AggregateOptions(
            operations: [AggregateOperation(type: .count, outputField: "n")],
            sort: AggregateSort(field: "n", direction: -1),
            limit: 1
        ))
        XCTAssertEqual(rows.count, 1,
                       "Scoped aggregate with ORDER BY/LIMIT must execute")
        XCTAssertEqual(rows[0]["n"] as? Int, 2,
                       "Must count only this doc's 2 records")
    }

    /// Per-doc scoped aggregate with a stringset `$contains` filter.
    /// The stringset predicate translates to `EXISTS (SELECT 1 FROM
    /// junction WHERE ...)`, so the SQL has a nested WHERE inside a
    /// subquery. The scope predicate must be spliced only into the
    /// *outer* WHERE — a naive whole-string replace would also rewrite
    /// the nested WHERE and add unpaired `?` placeholders.
    func testScopedAggregateWithStringsetFilter() throws {
        SchemaSync.clearCache()
        let taggedSchema = PrimitiveSchema(
            name: "agg_tagged",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "kind":  FieldDescriptor(type: .string, indexed: true),
                "tags":  FieldDescriptor(type: .stringset),
            ]
        )
        let multi = MultiDocModel(schema: taggedSchema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: [
            "kind": .string("login"), "tags": .stringset(["red", "urgent"]),
        ])
        _ = try a.create(id: "a2", values: [
            "kind": .string("login"), "tags": .stringset(["red"]),
        ])
        _ = try a.create(id: "a3", values: [
            "kind": .string("signup"), "tags": .stringset(["blue"]),
        ])

        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: [
            "kind": .string("login"), "tags": .stringset(["red"]),
        ])

        // Count docA's records tagged "red", grouped by kind. docB's
        // matching record must be excluded by the scope predicate.
        let rows = a.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            filter: ["tags": ["$contains": "red"]],
            sort: AggregateSort(field: "n", direction: -1)
        ))
        XCTAssertEqual(rows.count, 1,
                       "Only 'login' in docA has records tagged 'red'")
        XCTAssertEqual(rows[0]["kind"] as? String, "login")
        XCTAssertEqual(rows[0]["n"] as? Int, 2,
                       "Must count only docA's 2 red-tagged login records")
    }

    /// Aggregation sort + limit honors the whole shared store.
    func testCrossDocTopNByCount() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: ["kind": .string("login"), "score": .number(1)])
        _ = try a.create(id: "a2", values: ["kind": .string("login"), "score": .number(1)])
        _ = try a.create(id: "a3", values: ["kind": .string("signup"), "score": .number(1)])

        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: ["kind": .string("login"), "score": .number(1)])

        let rows = multi.aggregate(AggregateOptions(
            groupBy: ["kind"],
            operations: [AggregateOperation(type: .count, outputField: "n")],
            sort: AggregateSort(field: "n", direction: -1),
            limit: 1
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["kind"] as? String, "login")
        XCTAssertEqual(rows[0]["n"] as? Int, 3, "3 login records across both docs")
    }
}
