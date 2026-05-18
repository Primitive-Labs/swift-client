import XCTest
@testable import JsBaoClient
import YSwift

/// Per-member substring operators on stringset fields:
/// `$startsWith`, `$endsWith`, `$containsText`.
///
/// Matches js-bao browser.js:703-769. On a stringset field, these ops
/// match if ANY individual member satisfies the substring predicate —
/// via `EXISTS (SELECT 1 FROM {junction} WHERE value LIKE ?)`. On
/// non-stringset string fields they continue to match the column
/// directly (existing behavior).
///
/// This closes gap (D) identified in the browser-vs-Swift audit.
final class StringSetSubstringOpsTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "sub_items",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "tags":  FieldDescriptor(type: .stringset),
            "name":  FieldDescriptor(type: .string),
        ]
    )

    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "p1", values: [
            "name": .string("first"),
            "tags": .stringset(["draft-001", "approved"]),
        ])
        _ = try model.create(id: "p2", values: [
            "name": .string("second"),
            "tags": .stringset(["draft-002", "reviewed"]),
        ])
        _ = try model.create(id: "p3", values: [
            "name": .string("third"),
            "tags": .stringset(["published-A", "approved"]),
        ])
        _ = try model.create(id: "p4", values: [
            "name": .string("fourth"),
            "tags": .stringset([]),
        ])
        return model
    }

    // MARK: - $startsWith on stringset

    func testStartsWithMatchesAnyMemberPrefix() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$startsWith": "draft-"]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["p1", "p2"])
    }

    func testStartsWithDoesNotMatchIfNoMemberStartsWithPrefix() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$startsWith": "archived-"]])
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - $endsWith on stringset

    func testEndsWithMatchesAnyMemberSuffix() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$endsWith": "-A"]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["p3"])
    }

    // MARK: - $containsText on stringset

    func testContainsTextMatchesSubstringWithinAnyMember() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$containsText": "rove"]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["p1", "p3"],
                       "'rove' is a substring of 'approved' — both p1 and p3 carry 'approved'")
    }

    /// Substring operators must match within a single member, never
    /// across member boundaries. The junction-per-member storage makes
    /// this automatic.
    func testContainsTextDoesNotMatchAcrossMemberBoundaries() throws {
        let model = try seeded()
        // "001approved" would be a boundary-crossing match under a
        // naive CSV storage (members "draft-001" + "approved"). With
        // junction rows it cannot match.
        let rows = model.query(["tags": ["$containsText": "001approved"]])
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Empty stringset / missing field

    func testStartsWithOnEmptyStringsetNoMatch() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$startsWith": "anything"]])
        let ids = rows.compactMap { $0["id"] as? String }
        XCTAssertFalse(ids.contains("p4"))
    }

    // MARK: - Non-stringset field unchanged

    /// On a regular string column these operators still match the
    /// column value directly — no junction lookup.
    func testSubstringOpsOnStringFieldStillMatchColumn() throws {
        let model = try seeded()
        let rows = model.query(["name": ["$startsWith": "fir"]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["p1"])
    }

    // MARK: - Cross-doc via MultiDocModel

    func testStartsWithWorksAcrossDocsViaMultiDocModel() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: [
            "name": .string("A"), "tags": .stringset(["draft-A", "live"]),
        ])

        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: [
            "name": .string("B"), "tags": .stringset(["draft-B", "archived"]),
        ])

        let rows = multi.query(["tags": ["$startsWith": "draft-"]])
        XCTAssertEqual(
            Set(rows.compactMap { $0["id"] as? String }),
            ["a1", "b1"]
        )
    }
}
