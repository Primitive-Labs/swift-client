import XCTest
@testable import JsBaoClient
import YSwift

/// Tests for StringSet group-by on the model `aggregate` surface
/// (#954 follow-up): grouping by a stringset field's member values
/// (*facet*) and by whether a set contains a value (*membership*).
///
/// Exercises both engine paths:
///   - `DynamicModel.aggregate` — single doc, scoped via `scopedToDocId`
///     (the path where the doc-scope predicate coexists with JOIN params);
///   - `MultiDocModel.aggregate` — the facade's cross-doc path (no scope,
///     correlates junction rows by `_meta_doc_id`).
final class AggregateStringSetGroupTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "agg_posts",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "score": FieldDescriptor(type: .number),
            "tags":  FieldDescriptor(type: .stringset),
        ]
    )

    private func seededDoc() throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: schema)
        _ = try model.create(id: "d1", values: ["title": .string("d1"), "score": .number(10), "tags": .stringset(["red"])])
        _ = try model.create(id: "d2", values: ["title": .string("d2"), "score": .number(20), "tags": .stringset(["red", "blue"])])
        _ = try model.create(id: "d3", values: ["title": .string("d3"), "score": .number(30), "tags": .stringset(["blue"])])
        _ = try model.create(id: "d4", values: ["title": .string("d4"), "score": .number(40), "tags": .stringset(["green"])])
        _ = try model.create(id: "d5", values: ["title": .string("d5"), "score": .number(50), "tags": .stringset([])])
        return model
    }

    private func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }
    private func dblVal(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    // MARK: - Facet (group by a stringset field's member values)

    func testFacetGroupByTagValue() throws {
        let model = try seededDoc()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["tags"],
            operations: [AggregateOperation(type: .count)]
        ))
        var byTag: [String: Int] = [:]
        for row in rows {
            if let tag = row["tags"] as? String { byTag[tag] = intVal(row["count"]) }
        }
        // red: d1,d2 · blue: d2,d3 · green: d4 · (d5 empty -> excluded)
        XCTAssertEqual(byTag, ["red": 2, "blue": 2, "green": 1])
    }

    func testFacetHonorsFilterOnMainTable() throws {
        let model = try seededDoc()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["tags"],
            operations: [AggregateOperation(type: .count)],
            filter: ["score": ["$gte": 20]]
        ))
        var byTag: [String: Int] = [:]
        for row in rows {
            if let tag = row["tags"] as? String { byTag[tag] = intVal(row["count"]) }
        }
        // score>=20 keeps d2,d3,d4,d5 → red:{d2} blue:{d2,d3} green:{d4}
        XCTAssertEqual(byTag, ["red": 1, "blue": 2, "green": 1])
    }

    // MARK: - Membership (group by whether the set contains a value)

    func testMembershipGroupByTrueFalse() throws {
        let model = try seededDoc()
        let rows = model.aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "red")],
            operations: [AggregateOperation(type: .count)]
        ))
        var byMembership: [String: Int] = [:]
        for row in rows {
            if let key = row["has_tags_red"] as? String { byMembership[key] = intVal(row["count"]) }
        }
        // contains red: d1,d2 (true=2) · rest d3,d4,d5 (false=3)
        XCTAssertEqual(byMembership, ["true": 2, "false": 3])
    }

    func testMembershipWithSumOperation() throws {
        let model = try seededDoc()
        let rows = model.aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "red")],
            operations: [
                AggregateOperation(type: .count),
                AggregateOperation(type: .sum, field: "score"),
            ]
        ))
        var sums: [String: Double] = [:]
        for row in rows {
            if let key = row["has_tags_red"] as? String { sums[key] = dblVal(row["sum_score"]) }
        }
        // true score sum: 10+20=30 · false: 30+40+50=120
        XCTAssertEqual(sums["true"], 30)
        XCTAssertEqual(sums["false"], 120)
    }

    // MARK: - Cross-doc (facade path via MultiDocModel)

    private func seededPair() throws -> MultiDocModel {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: ["title": .string("a1"), "score": .number(10), "tags": .stringset(["red"])])
        _ = try a.create(id: "a2", values: ["title": .string("a2"), "score": .number(20), "tags": .stringset(["red", "blue"])])
        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: ["title": .string("b1"), "score": .number(30), "tags": .stringset(["blue"])])
        return multi
    }

    func testFacetAcrossDocs() throws {
        let multi = try seededPair()
        let rows = multi.aggregate(AggregateOptions(
            groupBy: ["tags"],
            operations: [AggregateOperation(type: .count)]
        ))
        var byTag: [String: Int] = [:]
        for row in rows {
            if let tag = row["tags"] as? String { byTag[tag] = intVal(row["count"]) }
        }
        // red: a1,a2 (2) · blue: a2,b1 (2) — counts must NOT leak across docs
        XCTAssertEqual(byTag, ["red": 2, "blue": 2])
    }

    func testMembershipAcrossDocs() throws {
        let multi = try seededPair()
        let rows = multi.aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "blue")],
            operations: [AggregateOperation(type: .count)]
        ))
        var byMembership: [String: Int] = [:]
        for row in rows {
            if let key = row["has_tags_blue"] as? String { byMembership[key] = intVal(row["count"]) }
        }
        // contains blue: a2,b1 (true=2) · rest a1 (false=1)
        XCTAssertEqual(byMembership, ["true": 2, "false": 1])
    }

    // MARK: - Degraded shapes must NOT crash (recoverable, non-throwing)

    /// A facet field combined with a membership clause: js-bao drops the
    /// facet and runs the regular/membership branch. Must not crash.
    func testFacetMixedWithMembershipDropsFacet() throws {
        let model = try seededDoc()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["tags", .stringSetMembership(field: "tags", contains: "red")],
            operations: [AggregateOperation(type: .count)]
        ))
        // Facet dropped → grouped by membership only.
        var byMembership: [String: Int] = [:]
        for row in rows {
            if let key = row["has_tags_red"] as? String { byMembership[key] = intVal(row["count"]) }
        }
        XCTAssertEqual(byMembership, ["true": 2, "false": 3])
    }

    /// A facet field combined with a regular field: facet dropped, grouped
    /// by the regular field. Must not crash.
    func testFacetMixedWithRegularFieldDropsFacet() throws {
        let model = try seededDoc()
        let rows = model.aggregate(AggregateOptions(
            groupBy: ["tags", "score"],
            operations: [AggregateOperation(type: .count)]
        ))
        // Grouped by score (5 distinct) — facet "tags" dropped, not faceted.
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.compactMap { intVal($0["count"]) }.reduce(0, +), 5)
        XCTAssertNil(rows.first?["tags"], "facet field should be dropped, not in output")
    }

    /// Two or more pure facet fields: unsupported in js-bao (recoverable
    /// 400). Swift is non-throwing → returns no rows, must not crash.
    func testMultipleFacetFieldsReturnEmptyNotCrash() throws {
        SchemaSync.clearCache()
        let twoSetSchema = PrimitiveSchema(
            name: "agg_two_sets",
            fields: [
                "id":     FieldDescriptor(type: .id),
                "tags":   FieldDescriptor(type: .stringset),
                "labels": FieldDescriptor(type: .stringset),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: twoSetSchema)
        _ = try model.create(id: "x1", values: ["tags": .stringset(["a"]), "labels": .stringset(["p"])])
        _ = try model.create(id: "x2", values: ["tags": .stringset(["a", "b"]), "labels": .stringset(["q"])])

        let rows = model.aggregate(AggregateOptions(
            groupBy: ["tags", "labels"],
            operations: [AggregateOperation(type: .count)]
        ))
        XCTAssertEqual(rows.count, 0, "multi-facet is unsupported → empty, not a crash")
    }
}
