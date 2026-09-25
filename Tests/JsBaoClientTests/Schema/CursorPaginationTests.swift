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
///  - `queryPaged` returns `PagedQueryResult<PrimitiveRow>` with
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
        XCTAssertEqual(page.data.map { $0["id"]?.stringValue }, ["p1", "p2"])
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
            collected += page.data.compactMap { $0["id"]?.stringValue }
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
        var collected: [String] = lastPage.data.compactMap { $0["id"]?.stringValue }
        var cursorBack = lastPage.prevCursor
        while let c = cursorBack {
            let page = try model.queryPaged(
                nil,
                options: QueryOptions(
                    sort: ["id": 1], limit: 2,
                    cursor: c, direction: .backward
                )
            )
            // Backward pages now return rows in DECLARED (id-ASC) order
            // (#1607 D8 — the engine reverses the trimmed page before
            // returning). Prepend the page as-is so the accumulated list
            // stays ASC. (Before the fix, backward pages came back id-DESC
            // and this test reversed each page to compensate.)
            collected = page.data.compactMap { $0["id"]?.stringValue } + collected
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
        XCTAssertEqual(page1.data.map { $0["id"]?.stringValue }, ["p2", "p5"])

        let page2 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: order, limit: 2,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"]?.stringValue }, ["p4", "p1"])

        let page3 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: order, limit: 2,
                cursor: page2.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page3.data.map { $0["id"]?.stringValue }, ["p3"])
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
        XCTAssertEqual(page1.data.map { $0["id"]?.stringValue }, ["p1", "p3", "p4"])

        let page2 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: order, limit: 3,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"]?.stringValue }, ["p2", "p5"])
    }

    // MARK: - With filter

    func testCursorPagingWithFilter() throws {
        let model = try seeded()
        // Filter category=="a": p1, p2, p4. Order by id ASC.
        let page1 = try model.queryPaged(
            ["category": "a"],
            options: QueryOptions(sort: ["id": 1], limit: 2)
        )
        XCTAssertEqual(page1.data.map { $0["id"]?.stringValue }, ["p1", "p2"])

        let page2 = try model.queryPaged(
            ["category": "a"],
            options: QueryOptions(
                sort: ["id": 1], limit: 2,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"]?.stringValue }, ["p4"])
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
        XCTAssertEqual(page.data.map { $0["id"]?.stringValue }, ["p1", "p2", "p3"])
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
        XCTAssertEqual(page1.data.map { $0["id"]?.stringValue }, ["p2", "p5"])

        let page2 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 2,
                cursor: page1.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page2.data.map { $0["id"]?.stringValue }, ["p4", "p1"])

        let page3 = try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 2,
                cursor: page2.nextCursor, direction: .forward
            )
        )
        XCTAssertEqual(page3.data.map { $0["id"]?.stringValue }, ["p3"])
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

    // MARK: - #3228 NULL-aware pagination

    /// Nine items, four of which never write `rank`. The per-model table
    /// stores an absent field as a NULL column and `executeQuery` omits NULL
    /// columns from the row dictionaries entirely, so the boundary row arrives
    /// at `cursorFromRow` with no `rank` key — which used to throw
    /// `InvalidCursorError("Row missing sort field 'rank'")`.
    ///
    /// Swift's model API has no way to store an explicit null (`PrimitiveValue`
    /// has no null case), and it needs none: absent and null are one value at
    /// the SQL layer on every engine, which is exactly why the cursor encoding
    /// does not distinguish them.
    private func seededWithNulls() throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: schema)
        let rows: [(String, Double?)] = [
            ("q1", 1), ("q2", 2), ("q3", 3), ("q4", nil), ("q5", nil),
            ("q6", 2), ("q7", nil), ("q8", 10), ("q9", nil),
        ]
        for (id, rank) in rows {
            var values: [String: PrimitiveValue] = ["category": .string("a")]
            if let rank { values["rank"] = .number(rank) }
            _ = try model.create(id: id, values: values)
        }
        return model
    }

    /// Nulls order before every real value ascending, after every real value
    /// descending — SQLite's native ORDER BY placement, and the contract JS
    /// implements for the same seeded set.
    private let nullsAscOrder = [
        "q4", "q5", "q7", "q9", "q1", "q2", "q6", "q3", "q8",
    ]
    private let nullsDescOrder = [
        "q8", "q3", "q2", "q6", "q1", "q4", "q5", "q7", "q9",
    ]

    /// Page forward through every page, asserting the server never advertises
    /// more rows without the means to fetch them.
    private func pageForward(
        _ model: DynamicModel,
        sortDirection: Int,
        limit: Int = 3,
        projection: [String: Int]? = nil
    ) throws -> [String] {
        var collected: [String] = []
        var cursor: String? = nil
        for page in 0..<15 {
            let result = try model.queryPaged(
                nil,
                options: QueryOptions(
                    sort: ["rank": sortDirection],
                    limit: limit,
                    cursor: cursor,
                    direction: .forward,
                    projection: projection
                )
            )
            collected += result.data.compactMap { $0["id"]?.stringValue }
            if !result.hasMore { return collected }
            XCTAssertNotNil(
                result.nextCursor,
                "page \(page) advertised hasMore with no nextCursor"
            )
            cursor = result.nextCursor
        }
        XCTFail("paging did not terminate within 15 pages")
        return collected
    }

    /// Behavior 11 — forward, ascending: nulls first, every row exactly once.
    func testNullSortAscendingPagesEveryRowOnce() throws {
        let model = try seededWithNulls()
        XCTAssertEqual(try pageForward(model, sortDirection: 1), nullsAscOrder)
    }

    /// Behavior 11 — forward, descending: the null tail is still reached. The
    /// old clause emitted `rank < ?`, which is UNKNOWN for a NULL column, so
    /// the four null rows were unreachable from any non-null cursor.
    func testNullSortDescendingReachesTheNullTail() throws {
        let model = try seededWithNulls()
        XCTAssertEqual(try pageForward(model, sortDirection: -1), nullsDescOrder)
    }

    /// Behavior 11 — backward paging over the mixed set, both sort directions,
    /// visits every earlier row exactly once.
    func testNullSortBackwardPagingVisitsEveryRowOnce() throws {
        for (sortDirection, order) in [(1, nullsAscOrder), (-1, nullsDescOrder)] {
            let model = try seededWithNulls()

            // Walk forward to the final page, then back from its prevCursor.
            var lastPage = try model.queryPaged(
                nil,
                options: QueryOptions(sort: ["rank": sortDirection], limit: 3)
            )
            while let next = lastPage.nextCursor, lastPage.hasMore {
                lastPage = try model.queryPaged(
                    nil,
                    options: QueryOptions(
                        sort: ["rank": sortDirection], limit: 3,
                        cursor: next, direction: .forward
                    )
                )
            }

            var collected = lastPage.data.compactMap { $0["id"]?.stringValue }
            var cursorBack = lastPage.prevCursor
            var guardCount = 0
            while let c = cursorBack, guardCount < 15 {
                guardCount += 1
                let page = try model.queryPaged(
                    nil,
                    options: QueryOptions(
                        sort: ["rank": sortDirection], limit: 3,
                        cursor: c, direction: .backward
                    )
                )
                // D8: backward pages come back in declared order.
                collected = page.data.compactMap { $0["id"]?.stringValue }
                    + collected
                cursorBack = page.hasMore ? page.nextCursor : nil
            }

            XCTAssertEqual(
                collected, order,
                "backward paging with sort direction \(sortDirection)"
            )
        }
    }

    /// Behavior 11 — a cursor minted from a row with no `rank` value at all
    /// succeeds and carries the field as null (an omitted `values` key on this
    /// side, since `PrimitiveValue` has no null case).
    func testCursorFromRowMissingSortFieldEncodesNull() throws {
        let model = try seededWithNulls()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["rank": 1], limit: 2)
        )
        XCTAssertEqual(page.data.map { $0["id"]?.stringValue }, ["q4", "q5"])
        let cursor = try CursorManager.decodeCursor(page.nextCursor!)
        XCTAssertEqual(cursor.sortFields, ["rank", "id"])
        XCTAssertNil(cursor.values["rank"], "an absent sort value is null")
        XCTAssertEqual(cursor.values["id"], .string("q5"))
    }

    /// Behavior 13 — a select-column projection that omits the sort field
    /// still pages exactly-once, and the returned rows are unchanged: neither
    /// the projected-out field nor the internal alias appears.
    func testProjectedQueryOmittingSortFieldPagesExactlyOnce() throws {
        let model = try seededWithNulls()
        let collected = try pageForward(
            model, sortDirection: 1, projection: ["category": 1]
        )
        XCTAssertEqual(collected, nullsAscOrder)

        let page = try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 3, projection: ["category": 1]
            )
        )
        for row in page.data {
            XCTAssertNil(row["rank"], "the projection omitted rank")
            for key in row.raw.keys {
                // The reserved prefix, pinned as a literal on both sides. It
                // starts with `_` (reserved on the write path) AND contains a
                // `:`, which no field name may contain, so it can be the name
                // of neither a projected column nor a stored field. The JS half
                // pins the same string.
                XCTAssertFalse(
                    key.hasPrefix("_cursor:"),
                    "internal alias \(key) leaked into a returned row"
                )
            }
        }
        XCTAssertEqual(CursorManager.sortValueAliasPrefix, "_cursor:")
        XCTAssertEqual(CursorManager.sortValueAlias("rank"), "_cursor:rank")
    }

    /// A schema field named after the OLD alias shape (`_cursor_` + a field
    /// name) is ordinary data: its value must never be read as the sort value
    /// of `rank`, and it must survive into the rows the caller sees. Minting
    /// reads only the fields the SELECT actually aliased, so a row key is never
    /// judged by its shape.
    func testAliasLookalikeColumnIsTreatedAsOrdinaryData() throws {
        SchemaSync.clearCache()
        let lookalikeSchema = PrimitiveSchema(
            name: "pgn_alias_items",
            fields: [
                "id":               FieldDescriptor(type: .id),
                "rank":             FieldDescriptor(type: .number),
                "_cursor_rank":     FieldDescriptor(type: .number),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: lookalikeSchema)
        for (id, rank) in [("a1", 1.0), ("a2", 2.0), ("a3", 3.0)] {
            _ = try model.create(id: id, values: [
                "rank": .number(rank), "_cursor_rank": .number(50),
            ])
        }

        let page = try model.queryPaged(
            nil,
            options: QueryOptions(sort: ["rank": 1], limit: 2)
        )
        XCTAssertEqual(page.data.map { $0["id"]?.stringValue }, ["a1", "a2"])
        XCTAssertEqual(page.data[0]["_cursor_rank"]?.numberValue, 50)
        let cursor = try CursorManager.decodeCursor(page.nextCursor!)
        XCTAssertEqual(
            cursor.values["rank"], .number(2),
            "the look-alike column's 50 must not become the sort value"
        )

        // And the walk still completes.
        var collected = page.data.compactMap { $0["id"]?.stringValue }
        var next = page.hasMore ? page.nextCursor : nil
        var guardCount = 0
        while let c = next, guardCount < 5 {
            guardCount += 1
            let more = try model.queryPaged(
                nil,
                options: QueryOptions(
                    sort: ["rank": 1], limit: 2,
                    cursor: c, direction: .forward
                )
            )
            collected += more.data.compactMap { $0["id"]?.stringValue }
            next = more.hasMore ? more.nextCursor : nil
        }
        XCTAssertEqual(collected, ["a1", "a2", "a3"])
    }

    /// Behavior 13 — and the cursor carries the projected-out field's REAL
    /// value, not a false null. Without this, the next page's `IS NOT NULL`
    /// predicate would replay the page just returned.
    func testProjectedCursorCarriesTheRealSortValue() throws {
        let model = try seededWithNulls()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(
                sort: ["rank": 1], limit: 6, projection: ["category": 1]
            )
        )
        XCTAssertEqual(
            page.data.map { $0["id"]?.stringValue },
            Array(nullsAscOrder.prefix(6)).map { Optional($0) }
        )
        let cursor = try CursorManager.decodeCursor(page.nextCursor!)
        XCTAssertEqual(cursor.values["rank"], .number(2))
        XCTAssertEqual(cursor.values["id"], .string("q2"))
    }

    // MARK: - #3228 cross-runtime payload parity (behavior 15)

    /// The exact token JS mints for a boundary row that never wrote
    /// `priority`, sorting `{priority: 1}`:
    ///
    ///   {"values":{"priority":null,"id":"r4"},
    ///    "sortFields":["priority","id"],"direction":1}
    ///
    /// Pinned as a literal on the JS side by
    /// `tests/unit/workflows/cursor-pagination-null-aware.test.ts`.
    private let jsMintedNullCursor =
        "eyJ2YWx1ZXMiOnsicHJpb3JpdHkiOm51bGwsImlkIjoicjQifSwic29ydEZpZWxkcyI6"
        + "WyJwcmlvcml0eSIsImlkIl0sImRpcmVjdGlvbiI6MX0="

    /// A JS-minted null-carrying cursor decodes here with the field treated as
    /// null — NOT as the empty string `jsonToPrimitive` used to fall back to,
    /// which would have compared `rank = ''` and matched nothing.
    func testJsMintedNullCursorDecodesAsNull() throws {
        let decoded = try CursorManager.decodeCursor(jsMintedNullCursor)
        XCTAssertEqual(decoded.sortFields, ["priority", "id"])
        XCTAssertEqual(decoded.direction, 1)
        XCTAssertEqual(decoded.values["id"], .string("r4"))
        XCTAssertNil(decoded.values["priority"])
        XCTAssertNotEqual(decoded.values["priority"], .string(""))
    }

    /// And Swift emits the same shape JS emits: an explicit `null` for every
    /// sort field whose value is null, keyed off `sortFields` so the payload
    /// never silently loses a key.
    func testSwiftEncodesNullSortValueAsExplicitJsonNull() throws {
        let encoded = try CursorManager.encodeCursor(CursorData(
            values: ["id": .string("r4")],
            sortFields: ["priority", "id"],
            direction: 1
        ))
        let json = String(
            data: Data(base64Encoded: encoded)!, encoding: .utf8
        )!
        XCTAssertTrue(
            json.contains("\"priority\":null"),
            "expected an explicit JSON null for priority, got \(json)"
        )
        XCTAssertTrue(json.contains("\"id\":\"r4\""))

        // Round-trips back to the same nullability.
        let decoded = try CursorManager.decodeCursor(encoded)
        XCTAssertNil(decoded.values["priority"])
        XCTAssertEqual(decoded.values["id"], .string("r4"))
    }

    /// The `.null → .string("")` fallback no longer applies inside cursor
    /// values; the `.object` fallback is unchanged.
    func testObjectFallbackUnchangedForCursorValues() throws {
        let objectCursor = try CursorManager.encodeCursor(CursorData(
            values: ["rank": .string("")],
            sortFields: ["rank"],
            direction: 1
        ))
        // An empty string is a real value and stays one.
        let decoded = try CursorManager.decodeCursor(objectCursor)
        XCTAssertEqual(decoded.values["rank"], .string(""))

        // A JSON object in a cursor value still degrades to the empty string
        // rather than being read as null.
        let raw = #"{"values":{"rank":{"a":1}},"sortFields":["rank"],"direction":1}"#
        let token = Data(raw.utf8).base64EncodedString()
        XCTAssertEqual(
            try CursorManager.decodeCursor(token).values["rank"], .string("")
        )
    }

    // MARK: - #3228 NULL-aware WHERE emission (behavior 11, SQL level)

    /// The four rules, and the `id` exemption that keeps the default sort's
    /// SQL byte-identical.
    func testPaginationConditionsAreNullAware() throws {
        let fields = ["rank", "id"]
        func build(
            _ values: [String: PrimitiveValue],
            _ fieldDir: Int,
            _ direction: CursorDirection
        ) throws -> (sql: String, params: [Any]) {
            try CursorManager.buildPaginationConditions(
                cursor: CursorData(
                    values: values, sortFields: fields,
                    direction: direction.jsBaoValue
                ),
                currentSortFields: fields,
                sortDirections: [fieldDir, 1],
                direction: direction
            )
        }

        // Unchanged for a non-null ascending forward cursor.
        XCTAssertEqual(
            try build(["rank": .number(3), "id": .string("q3")], 1, .forward).sql,
            "((rank > ?) OR (rank = ? AND id > ?))"
        )
        // `>` on null → IS NOT NULL; the equality level becomes IS NULL.
        XCTAssertEqual(
            try build(["id": .string("q7")], 1, .forward).sql,
            "((rank IS NOT NULL) OR (rank IS NULL AND id > ?))"
        )
        // `<` on a real value widens to pick up the null tail.
        XCTAssertEqual(
            try build(["rank": .number(3), "id": .string("q3")], -1, .forward).sql,
            "((rank < ? OR rank IS NULL) OR (rank = ? AND id > ?))"
        )
        // `<` on null matches nothing; the deeper level carries the walk.
        XCTAssertEqual(
            try build(["id": .string("q7")], -1, .forward).sql,
            "((rank IS NULL AND id > ?))"
        )
        // A null level binds no parameter.
        XCTAssertEqual(
            try build(["id": .string("q7")], 1, .forward).params.count, 1
        )
        // `id` is never given IS NULL handling.
        let idOnly = try CursorManager.buildPaginationConditions(
            cursor: CursorData(
                values: ["id": .string("q3")], sortFields: ["id"], direction: 1
            ),
            currentSortFields: ["id"],
            sortDirections: [-1],
            direction: .forward
        )
        XCTAssertEqual(idOnly.sql, "((id < ?))")
        XCTAssertFalse(idOnly.sql.contains("IS NULL"))
    }
}
