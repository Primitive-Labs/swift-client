import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Belt-and-suspenders coverage of cross-doc query behavior that's
/// architecturally covered by the shared-store design but wasn't
/// directly asserted by the main MultiDocModelTests:
///
/// - MongoDB operator surface (`$or`, `$and`, `$in`, `$containsText`,
///   nested combinators) — delegates to `QueryTranslator`, but we
///   want a test per operator against the shared table to catch
///   regressions if the translator or the shared-store plumbing
///   changes.
/// - Cursor pagination round-trip — cursors flow straight into
///   `engine.queryPaged`; we assert forward + backward paging walks
///   every connected doc's records in order, without duplicates or
///   gaps.
final class CrossDocQueryTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "xd_items",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "rank":  FieldDescriptor(type: .number),
            "tag":   FieldDescriptor(type: .string),
        ]
    )

    /// Seven items split across three docs. Ranks are unique; titles
    /// share substrings so `$containsText` has something to find.
    private func seededTrio() throws -> MultiDocModel {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: [
            "title": .string("alpha one"), "rank": .number(1),
            "tag": .string("red"),
        ])
        _ = try a.create(id: "a2", values: [
            "title": .string("alpha two"), "rank": .number(4),
            "tag": .string("red"),
        ])

        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: [
            "title": .string("beta three"), "rank": .number(2),
            "tag": .string("blue"),
        ])
        _ = try b.create(id: "b2", values: [
            "title": .string("alpha four"), "rank": .number(5),
            "tag": .string("blue"),
        ])

        SchemaSync.clearCache()
        let c = multi.connect(docId: "docC", doc: YDocument())
        _ = try c.create(id: "c1", values: [
            "title": .string("gamma five"), "rank": .number(3),
            "tag": .string("green"),
        ])
        _ = try c.create(id: "c2", values: [
            "title": .string("alpha six"), "rank": .number(6),
            "tag": .string("green"),
        ])
        _ = try c.create(id: "c3", values: [
            "title": .string("gamma seven"), "rank": .number(7),
            "tag": .string("red"),
        ])
        return multi
    }

    // MARK: - MongoDB operator coverage

    func testOrOperatorAcrossDocs() throws {
        let multi = try seededTrio()
        let rows = multi.query([
            "$or": [
                ["rank": 1] as [String: Any],
                ["rank": 7] as [String: Any],
            ]
        ])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a1", "c3"])
    }

    func testAndOperatorAcrossDocs() throws {
        let multi = try seededTrio()
        // tag = red AND rank >= 4 → a2 (red,4) and c3 (red,7)
        let rows = multi.query([
            "$and": [
                ["tag": "red"] as [String: Any],
                ["rank": ["$gte": 4]] as [String: Any],
            ]
        ])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a2", "c3"])
    }

    func testInOperatorAcrossDocs() throws {
        let multi = try seededTrio()
        let rows = multi.query(["rank": ["$in": [2, 5, 6]]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["b1", "b2", "c2"])
    }

    func testContainsTextOperatorAcrossDocs() throws {
        let multi = try seededTrio()
        let rows = multi.query(["title": ["$containsText": "alpha"]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a1", "a2", "b2", "c2"],
                       "All four items with 'alpha' in title, spanning docA/docB/docC")
    }

    /// Nested: `(tag = red AND rank <= 4) OR (tag = green AND rank >= 6)`.
    /// Matches a2 (red,4) + c2 (green,6).  a1 excluded because nested
    /// $and wants rank<=4 AND red — a1 fits but wait, rank<=4 AND red:
    /// a1(red,1) yes, a2(red,4) yes. c2 (green,6) yes, c3 (red,7)
    /// fails both branches (not green, not <=4).
    func testNestedCombinatorsAcrossDocs() throws {
        let multi = try seededTrio()
        let rows = multi.query([
            "$or": [
                ["$and": [
                    ["tag": "red"] as [String: Any],
                    ["rank": ["$lte": 4]] as [String: Any],
                ]] as [String: Any],
                ["$and": [
                    ["tag": "green"] as [String: Any],
                    ["rank": ["$gte": 6]] as [String: Any],
                ]] as [String: Any],
            ]
        ])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a1", "a2", "c2"])
    }

    // MARK: - Cursor pagination (queryPaged)

    /// Walk every record in rank-ascending order, 3 per page, via
    /// cursors. Seven records → three pages (3, 3, 1). Each page
    /// must be contiguous with no duplicates or gaps.
    func testCursorPaginationForwardAcrossDocs() throws {
        let multi = try seededTrio()

        // Page 1
        let page1 = try multi.queryPaged(nil, options: QueryOptions(
            sortOrder: [("rank", 1)], limit: 3
        ))
        XCTAssertEqual(page1.data.map { $0["id"] as? String }, ["a1", "b1", "c1"])
        XCTAssertTrue(page1.hasMore)
        XCTAssertNotNil(page1.nextCursor)

        // Page 2
        let page2 = try multi.queryPaged(nil, options: QueryOptions(
            sortOrder: [("rank", 1)], limit: 3, cursor: page1.nextCursor
        ))
        XCTAssertEqual(page2.data.map { $0["id"] as? String }, ["a2", "b2", "c2"])
        XCTAssertTrue(page2.hasMore)

        // Page 3 (tail)
        let page3 = try multi.queryPaged(nil, options: QueryOptions(
            sortOrder: [("rank", 1)], limit: 3, cursor: page2.nextCursor
        ))
        XCTAssertEqual(page3.data.map { $0["id"] as? String }, ["c3"])
        XCTAssertFalse(page3.hasMore)
    }

    /// Backward paging from the middle — the `direction: .backward`
    /// path flips sort directions and applies the cursor's `<`
    /// inequality, mirroring `DynamicModel`'s cursor contract.
    func testCursorPaginationBackwardAcrossDocs() throws {
        let multi = try seededTrio()

        // Forward to page 2, then walk back.
        let page1 = try multi.queryPaged(nil, options: QueryOptions(
            sortOrder: [("rank", 1)], limit: 3
        ))
        let page2 = try multi.queryPaged(nil, options: QueryOptions(
            sortOrder: [("rank", 1)], limit: 3, cursor: page1.nextCursor
        ))

        // Walk back from page 2 → should return page 1's data.
        let back = try multi.queryPaged(nil, options: QueryOptions(
            sortOrder: [("rank", 1)],
            limit: 3,
            cursor: page2.prevCursor,
            direction: .backward
        ))
        XCTAssertEqual(
            Set(back.data.compactMap { $0["id"] as? String }),
            ["a1", "b1", "c1"],
            "Walking back from page 2 returns page 1's records"
        )
    }

    /// Pagination + filter + include chained through the shared
    /// store. Verifies that the include resolver runs per page and
    /// cursors remain stable under a filter.
    func testCursorPaginationWithInclude() throws {
        let multi = try seededTrio()

        // Attach a trivial self-include: each row includes its own
        // record via `refersTo` on `id`. Proves the include resolver
        // participates in the paginated path without interfering
        // with cursor generation.
        let page1 = try multi.queryPaged(
            ["tag": ["$ne": "blue"]],
            options: QueryOptions(sortOrder: [("rank", 1)], limit: 2),
            include: [
                Include(type: .refersTo, target: multi,
                        sourceField: "id", resultKey: "self")
            ]
        )
        // Rank-asc excluding tag=blue: a1(1), c1(3), a2(4), c2(6), c3(7).
        XCTAssertEqual(page1.data.map { $0["id"] as? String }, ["a1", "c1"])
        for row in page1.data {
            let selfRec = (row["_related"] as? [String: Any])?["self"]
                          as? [String: Any]
            XCTAssertEqual(selfRec?["id"] as? String, row["id"] as? String,
                           "Self-include should echo the row")
        }
        XCTAssertTrue(page1.hasMore)

        let page2 = try multi.queryPaged(
            ["tag": ["$ne": "blue"]],
            options: QueryOptions(
                sortOrder: [("rank", 1)], limit: 2, cursor: page1.nextCursor
            ),
            include: [
                Include(type: .refersTo, target: multi,
                        sourceField: "id", resultKey: "self")
            ]
        )
        XCTAssertEqual(page2.data.map { $0["id"] as? String }, ["a2", "c2"])
    }
}
