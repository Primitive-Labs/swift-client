import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Full-parity cursor pagination tests — mirrors js-bao's
/// `CursorManager` + `buildPaginationConditions` semantics (see
/// `/tmp/js-bao-ref-uniq/CursorManager.ts`).
///
/// Contract:
///  - Cursor is an opaque base64-encoded JSON payload with
///    `{ values, sortFields, direction }`.
///  - `queryPaged` returns `PagedQueryResult<[String: Any]>` with
///    `data`, `nextCursor`, `prevCursor`, `hasMore`.
///  - Multi-field sort paginates lexicographically: for a sort of
///    `[a ASC, id ASC]`, the WHERE becomes
///    `(a > ?) OR (a = ? AND id > ?)` so ties on `a` are broken by id.
///  - Direction (`.forward` / `.backward`) is independent of per-field
///    sort direction. Forward ASC uses `>`; forward DESC uses `<`;
///    backward flips both.
///  - A cursor whose encoded `sortFields` don't match the query's
///    current sort throws `InvalidCursorError`.
final class CursorPaginationTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "pgn_items",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "category": FieldDescriptor(type: .string, indexed: true),
            "rank":     FieldDescriptor(type: .number),
        ]
    )

    /// 5 items with ids p1–p5, varied category + rank so we can sort
    /// by multiple columns.
    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: schema)
        _ = try model.create(id: "p1", values: [
            "category": .string("a"), "rank": .number(3),
        ])
        _ = try model.create(id: "p2", values: [
            "category": .string("a"), "rank": .number(1),
        ])
        _ = try model.create(id: "p3", values: [
            "category": .string("b"), "rank": .number(3),
        ])
        _ = try model.create(id: "p4", values: [
            "category": .string("a"), "rank": .number(2),
        ])
        _ = try model.create(id: "p5", values: [
            "category": .string("b"), "rank": .number(1),
        ])
        return model
    }

    // MARK: - Cursor codec round-trip

    /// Round-trip: encode a cursor, decode it back, assert structural
    /// equality. Guards against our JSON/base64 layer regressing.
    func testCursorEncodeDecodeRoundTrip() throws {
        let data = CursorData(
            values: ["id": .string("p3")],
            sortFields: ["id"],
            direction: 1
        )
        let encoded = try CursorManager.encodeCursor(data)
        let decoded = try CursorManager.decodeCursor(encoded)
        XCTAssertEqual(decoded.sortFields, ["id"])
        XCTAssertEqual(decoded.direction, 1)
        XCTAssertEqual(decoded.values["id"], .string("p3"))
    }

    /// Malformed input throws, doesn't crash.
    func testCursorDecodeMalformedThrows() {
        XCTAssertThrowsError(try CursorManager.decodeCursor("not-base64"))
        XCTAssertThrowsError(try CursorManager.decodeCursor("bm90anNvbg=="))
    }

    // MARK: - Paginated result shape

    /// First page returns `hasMore`, `nextCursor` set, `prevCursor` nil.
    func testFirstPageHasNextCursorButNoPrev() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["id": 1], limit: 2)
        )
        XCTAssertEqual(page.data.map { $0["id"] as? String }, ["p1", "p2"])
        XCTAssertTrue(page.hasMore)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertNil(page.prevCursor,
                     "First page has no prev cursor")
    }

    /// Last page has `hasMore == false` and `nextCursor == nil`.
    func testLastPageNoNextCursor() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["id": 1], limit: 10)
        )
        XCTAssertEqual(page.data.count, 5)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - Forward paging (single-field id ASC)

    func testForwardPagingAcrossAllPages() throws {
        let model = try seeded()
        var collected: [String] = []
        var cursor: String? = nil
        for _ in 0..<10 { // upper bound so a bug can't loop forever
            let page = try model.queryPaged(
                nil,
                options: QueryOptions(
                    sort: ["id": 1], limit: 2,
                    cursor: cursor, direction: .forward
                )
            )
            collected += page.data.compactMap { $0["id"] as? String }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        XCTAssertEqual(collected, ["p1", "p2", "p3", "p4", "p5"])
    }

    // MARK: - Backward paging

    func testBackwardPagingFromEnd() throws {
        let model = try seeded()

        // Forward to the last page.
        var lastPage = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["id": 1], limit: 2)
        )
        var cursor = lastPage.nextCursor
        while let c = cursor {
            lastPage = try model.queryPaged(
                nil,
                options: QueryOptions(
                    sort: ["id": 1], limit: 2,
                    cursor: c, direction: .forward
                )
            )
            cursor = lastPage.nextCursor
        }

        // lastPage is the final forward page. Seed `collected` with
        // its rows, then walk BACKWARD from its prevCursor. In
        // backward mode `nextCursor` advances further back; `prevCursor`
        // would rewind toward where we came from (not what we want).
        var collected: [String] = lastPage.data.compactMap { $0["id"] as? String }
        var cursorBack = lastPage.prevCursor
        while let c = cursorBack {
            let page = try model.queryPaged(
                nil,
                options: QueryOptions(
                    sort: ["id": 1], limit: 2,
                    cursor: c, direction: .backward
                )
            )
            // Backward page rows are returned id-DESC; reverse before
            // prepending so the final list stays ASC.
            collected = page.data.compactMap { $0["id"] as? String }.reversed() + collected
            cursorBack = page.nextCursor
        }

        XCTAssertEqual(collected, ["p1", "p2", "p3", "p4", "p5"])
    }

    // MARK: - Multi-field stable pagination (the load-bearing parity test)

    /// With sort `[rank ASC, id ASC]`, p2 and p5 both have rank 1;
    /// cursor must break ties by id. After page 1 ends on p2, next page
    /// must start at p5 (not skip or duplicate).
    func testMultiFieldLexicographicPagination() throws {
        let model = try seeded()
        // Sort: rank ASC, id ASC. Full order: p2(rank1,idp2), p5(rank1,idp5),
        // p4(rank2,idp4), p1(rank3,idp1), p3(rank3,idp3).
        // Use `sortOrder` (ordered pairs) — Swift dict literals don't
        // preserve insertion order, so multi-field sorts need the
        // explicit ordered form.
        let order: [(String, Int)] = [("rank", 1), ("id", 1)]
        let page1 = try model.queryPaged(
            nil,
            options: QueryOptions(sortOrder: order, limit: 2)
        )
        XCTAssertEqual(page1.data.map { $0["id"] as? String }, ["p2", "p5"])

        let page2 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: order, limit: 2,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"] as? String }, ["p4", "p1"])

        let page3 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: order, limit: 2,
                cursor: page2.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page3.data.map { $0["id"] as? String }, ["p3"])
        XCTAssertFalse(page3.hasMore)
    }

    /// Mixed sort direction: `[rank DESC, id ASC]`. p1+p3 tie on rank=3;
    /// must break by id (p1 first).
    func testMixedSortDirections() throws {
        let model = try seeded()
        let order: [(String, Int)] = [("rank", -1), ("id", 1)]
        // Full order: p1(rank3,p1), p3(rank3,p3), p4(rank2), p2(rank1,p2), p5(rank1,p5).
        let page1 = try model.queryPaged(
            nil,
            options: QueryOptions(sortOrder: order, limit: 3)
        )
        XCTAssertEqual(page1.data.map { $0["id"] as? String }, ["p1", "p3", "p4"])

        let page2 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: order, limit: 3,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"] as? String }, ["p2", "p5"])
    }

    // MARK: - With filter

    func testCursorPagingWithFilter() throws {
        let model = try seeded()
        // Filter category=="a": p1, p2, p4. Order by id ASC.
        let page1 = try model.queryPaged(
            ["category": "a"],
            options: QueryOptions(sort: ["id": 1], limit: 2)
        )
        XCTAssertEqual(page1.data.map { $0["id"] as? String }, ["p1", "p2"])

        let page2 = try model.queryPaged(
            ["category": "a"],
            options: QueryOptions(
                sort: ["id": 1], limit: 2,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"] as? String }, ["p4"])
        XCTAssertFalse(page2.hasMore)
    }

    // MARK: - Sort-mismatch validation

    /// A cursor that encodes one set of sort fields can't be used with
    /// a query that sorts differently — throws `InvalidCursorError`
    /// rather than silently paginating through stale data.
    func testCursorFromDifferentSortThrows() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["id": 1], limit: 1)
        )
        XCTAssertThrowsError(try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 2,
                cursor: page.nextCursor, direction: .forward
            )
        )) { error in
            XCTAssertTrue(error is InvalidCursorError,
                          "Sort-field mismatch must throw, got \(error)")
        }
    }

    // MARK: - Default sort

    /// When no sort is specified, the implicit sort is `id ASC` —
    /// matches js-bao's DocumentQueryTranslator default.
    func testDefaultSortIsIdAscending() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(limit: 3)
        )
        XCTAssertEqual(page.data.map { $0["id"] as? String }, ["p1", "p2", "p3"])
    }

    // MARK: - Implicit id tiebreaker

    /// js-bao auto-appends `id ASC` to the sort whenever the caller's
    /// sort doesn't already include id (CursorManager.ts:184-197,
    /// 222-225). Without this, sorting by a non-unique field gives
    /// non-deterministic page boundaries on ties.
    ///
    /// Seeded data has p2+p5 tied on rank=1 and p1+p3 tied on rank=3.
    /// With only `sort: [rank: 1]`, js-bao paginates stably because
    /// the effective ORDER BY is `rank ASC, id ASC`. Swift must match.
    func testSingleFieldSortAutoAppendsIdTiebreaker() throws {
        let model = try seeded()
        // Sort only by rank. Ties (p2+p5, p1+p3) must be broken by id.
        // Full stable order: p2, p5, p4, p1, p3.
        let page1 = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["rank": 1], limit: 2)
        )
        XCTAssertEqual(page1.data.map { $0["id"] as? String }, ["p2", "p5"])

        let page2 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 2,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"] as? String }, ["p4", "p1"])

        let page3 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 2,
                cursor: page2.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page3.data.map { $0["id"] as? String }, ["p3"])
    }

    /// The cursor generated from a single-field sort includes `id` in
    /// its `sortFields` (because the engine auto-appends it).
    func testCursorIncludesImplicitIdInSortFields() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["rank": 1], limit: 1)
        )
        let cursor = try CursorManager.decodeCursor(page.nextCursor!)
        XCTAssertEqual(cursor.sortFields, ["rank", "id"],
                       "Cursor must carry id as tiebreaker")
        XCTAssertNotNil(cursor.values["id"])
    }

    /// When the caller already includes `id` explicitly, don't
    /// duplicate it.
    func testExplicitIdInSortIsntDuplicated() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: [("rank", 1), ("id", 1)], limit: 1
            )
        )
        let cursor = try CursorManager.decodeCursor(page.nextCursor!)
        XCTAssertEqual(cursor.sortFields, ["rank", "id"])
    }
}
