import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests runtime relationship accessors on `PrimitiveRecord`. The
/// `_meta_*._relationships` map already stores the wire metadata (done
/// in the schema-sync work); these tests wire up the read-side so you
/// can actually traverse a relationship at runtime.
///
/// Design note: Swift doesn't have a global model registry, so the
/// accessors take the target model (and join model, for
/// `hasManyThrough`) as an explicit parameter — callers wire the
/// graph themselves. Matches Swift's general explicit-over-magical
/// aesthetic.
final class RelationshipsRuntimeTests: XCTestCase {

    private var doc: YDocument!
    private var users: DynamicModel!
    private var posts: DynamicModel!
    private var tags: DynamicModel!
    private var postTagLinks: DynamicModel!

    override func setUp() {
        SchemaSync.clearCache()
        doc = YDocument()

        users = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "users_rel",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "name":     FieldDescriptor(type: .string),
            ],
            relationships: [
                "posts": .hasMany(model: "posts_rel", relatedIdField: "userId"),
                "postsByCreatedDesc": .hasMany(
                    model: "posts_rel",
                    relatedIdField: "userId",
                    orderByField: "createdAt",
                    orderDirection: "DESC"
                ),
            ]
        ))
        posts = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "posts_rel",
            fields: [
                "id":        FieldDescriptor(type: .id),
                "userId":    FieldDescriptor(type: .string, indexed: true),
                "title":     FieldDescriptor(type: .string),
                "createdAt": FieldDescriptor(type: .string),
            ],
            relationships: [
                "author": .refersTo(model: "users_rel", relatedIdField: "userId"),
                "tags": .hasManyThrough(
                    model: "tags_rel",
                    joinModel: "post_tag_links_rel",
                    joinModelLocalField: "postId",
                    joinModelRelatedField: "tagId"
                ),
                "tagsByPositionDesc": .hasManyThrough(
                    model: "tags_rel",
                    joinModel: "post_tag_links_rel",
                    joinModelLocalField: "postId",
                    joinModelRelatedField: "tagId",
                    joinModelOrderByField: "position",
                    joinModelOrderDirection: "DESC"
                ),
                "tagsByPositionAsc": .hasManyThrough(
                    model: "tags_rel",
                    joinModel: "post_tag_links_rel",
                    joinModelLocalField: "postId",
                    joinModelRelatedField: "tagId",
                    joinModelOrderByField: "position",
                    joinModelOrderDirection: "ASC"
                ),
                // Orders by a NULLABLE join field — exercises the D7 /
                // Fork B rejection (a NULL order value has no stable
                // cursor position).
                "tagsByWeight": .hasManyThrough(
                    model: "tags_rel",
                    joinModel: "post_tag_links_rel",
                    joinModelLocalField: "postId",
                    joinModelRelatedField: "tagId",
                    joinModelOrderByField: "weight",
                    joinModelOrderDirection: "ASC"
                ),
            ]
        ))
        tags = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "tags_rel",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        ))
        postTagLinks = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "post_tag_links_rel",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "postId":   FieldDescriptor(type: .string, indexed: true),
                "tagId":    FieldDescriptor(type: .string, indexed: true),
                // `position` is REQUIRED (non-null) but non-unique — a
                // valid pagination order field that can still hold tie
                // values across a page boundary. A default (0) lets the
                // many tests that don't care about ordering create links
                // without spelling it out. `weight` is left nullable to
                // drive the D7 rejection test.
                "position": FieldDescriptor(type: .number, required: true, default: .scalar(.number(0))),
                "weight":   FieldDescriptor(type: .number),
            ]
        ))
    }

    // MARK: - refersTo

    func testRefersToResolvesForeignKey() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        _ = try posts.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("hello"),
        ])

        let post = posts.find(id: "p1")!
        let author = try post.refersTo(relationship: "author", target: users)
        XCTAssertEqual(author?.id, "u1")
        XCTAssertEqual(author?["name"], .string("Alice"))
    }

    func testRefersToReturnsNilWhenForeignKeyMissing() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("orphan")])
        let post = posts.find(id: "p1")!
        XCTAssertNil(try post.refersTo(relationship: "author", target: users))
    }

    func testRefersToReturnsNilWhenTargetRecordNotFound() throws {
        _ = try posts.create(id: "p1", values: [
            "userId": .string("nonexistent"), "title": .string("ghost"),
        ])
        let post = posts.find(id: "p1")!
        XCTAssertNil(try post.refersTo(relationship: "author", target: users))
    }

    // MARK: - hasMany

    func testHasManyReturnsRelatedRecords() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        _ = try users.create(id: "u2", values: ["name": .string("Bob")])
        _ = try posts.create(id: "p1", values: ["userId": .string("u1"), "title": .string("a")])
        _ = try posts.create(id: "p2", values: ["userId": .string("u1"), "title": .string("b")])
        _ = try posts.create(id: "p3", values: ["userId": .string("u2"), "title": .string("c")])

        let alice = users.find(id: "u1")!
        let alicePosts = try alice.hasMany(relationship: "posts", target: posts)
        XCTAssertEqual(Set(alicePosts.map(\.id)), ["p1", "p2"])
    }

    func testHasManyReturnsEmptyForNoMatches() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        let alice = users.find(id: "u1")!
        XCTAssertEqual(
            try alice.hasMany(relationship: "posts", target: posts).count,
            0
        )
    }

    /// `orderByField` sorts the result by the named field ascending by
    /// default.
    func testHasManyOrdersByField() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        _ = try posts.create(id: "pA", values: [
            "userId": .string("u1"), "title": .string("A"),
            "createdAt": .string("2026-01-01T00:00:00Z"),
        ])
        _ = try posts.create(id: "pB", values: [
            "userId": .string("u1"), "title": .string("B"),
            "createdAt": .string("2026-03-01T00:00:00Z"),
        ])
        _ = try posts.create(id: "pC", values: [
            "userId": .string("u1"), "title": .string("C"),
            "createdAt": .string("2026-02-01T00:00:00Z"),
        ])

        let alice = users.find(id: "u1")!
        // "postsByCreatedDesc" relationship uses orderByField=createdAt, orderDirection=DESC.
        let ordered = try alice.hasMany(
            relationship: "postsByCreatedDesc",
            target: posts
        )
        XCTAssertEqual(ordered.map(\.id), ["pB", "pC", "pA"])
    }

    // MARK: - Lazy vs batch equivalence (#1115)

    /// The lazy `hasMany` accessor routes through the query engine —
    /// its results (membership AND order) must match what the batch
    /// `Include(type: .hasMany, ...)` path attaches under `_related`.
    /// Default order (no orderByField) is the engine's `id ASC`.
    func testHasManyLazyMatchesBatchInclude_defaultOrder() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        // Create out of id order so insertion order != id order.
        _ = try posts.create(id: "p3", values: ["userId": .string("u1"), "title": .string("c")])
        _ = try posts.create(id: "p1", values: ["userId": .string("u1"), "title": .string("a")])
        _ = try posts.create(id: "p2", values: ["userId": .string("u1"), "title": .string("b")])
        _ = try posts.create(id: "p9", values: ["userId": .string("uX"), "title": .string("other")])

        let lazy = try users.find(id: "u1")!
            .hasMany(relationship: "posts", target: posts)

        let batchRows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [Include(
                type: .hasMany, target: posts!, foreignKey: "userId"
            )]
        )
        let related = batchRows.first?["_related"]?.objectValue?["posts_rel"]?.rowsValue ?? []

        XCTAssertEqual(
            lazy.map(\.id),
            related.compactMap { $0["id"]?.stringValue },
            "lazy hasMany must return the same records in the same order as the batch include path"
        )
        XCTAssertEqual(lazy.map(\.id), ["p1", "p2", "p3"])
    }

    /// Sorted variant: orderByField/orderDirection on the lazy side
    /// must equal `sort:` on the batch include side.
    func testHasManyLazyMatchesBatchInclude_sorted() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        _ = try posts.create(id: "pA", values: [
            "userId": .string("u1"), "title": .string("A"),
            "createdAt": .string("2026-01-01T00:00:00Z"),
        ])
        _ = try posts.create(id: "pB", values: [
            "userId": .string("u1"), "title": .string("B"),
            "createdAt": .string("2026-03-01T00:00:00Z"),
        ])
        _ = try posts.create(id: "pC", values: [
            "userId": .string("u1"), "title": .string("C"),
            "createdAt": .string("2026-02-01T00:00:00Z"),
        ])

        let lazy = try users.find(id: "u1")!
            .hasMany(relationship: "postsByCreatedDesc", target: posts)

        let batchRows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [Include(
                type: .hasMany, target: posts!, foreignKey: "userId",
                sort: ["createdAt": -1]
            )]
        )
        let related = batchRows.first?["_related"]?.objectValue?["posts_rel"]?.rowsValue ?? []

        XCTAssertEqual(
            lazy.map(\.id),
            related.compactMap { $0["id"]?.stringValue }
        )
        XCTAssertEqual(lazy.map(\.id), ["pB", "pC", "pA"])
    }

    /// hasManyThrough returns targets in **target `id ASC`** — matching
    /// js-bao, where the join leg picks which rows/page but the final
    /// `id: { $in: [...] }` query re-sorts the output by target `id ASC`
    /// (relationshipManager.ts → `CursorManager.buildOrderClause`). The
    /// declared join order governs selection, not the output order.
    func testHasManyThroughOrderIsTargetIdAscending() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        _ = try tags.create(id: "t1", values: ["name": .string("red")])
        _ = try tags.create(id: "t2", values: ["name": .string("blue")])
        // Insert join rows out of id order: the buggy join-row-order path
        // would return [t2, t1]; the correct contract is target id ASC.
        _ = try postTagLinks.create(id: "l2", values: [
            "postId": .string("p1"), "tagId": .string("t1"),
        ])
        _ = try postTagLinks.create(id: "l1", values: [
            "postId": .string("p1"), "tagId": .string("t2"),
        ])

        let post = posts.find(id: "p1")!
        let result = try post.hasManyThrough(
            relationship: "tags", joinModel: postTagLinks, target: tags
        )
        XCTAssertEqual(result.map(\.id), ["t1", "t2"],
                       "targets resolve in target id ASC, re-sorted by the $in query")
    }

    /// A DESC `joinModelOrderDirection` selects join rows in DESC of the
    /// declared order field, but the target output is still **target
    /// `id ASC`** — the `$in` re-sort overrides the join leg's direction,
    /// exactly as js-bao does. This locks in that the join direction does
    /// not leak into the final order.
    func testHasManyThroughDescJoinDirectionStillReturnsTargetIdAscending() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        _ = try tags.create(id: "t1", values: ["name": .string("red")])
        _ = try tags.create(id: "t2", values: ["name": .string("blue")])
        // position ASC would order the join leg t1-then-t2; with DESC the
        // join leg is t2-then-t1 — yet the target output stays id ASC.
        _ = try postTagLinks.create(id: "l1", values: [
            "postId": .string("p1"), "tagId": .string("t1"),
            "position": .number(1),
        ])
        _ = try postTagLinks.create(id: "l2", values: [
            "postId": .string("p1"), "tagId": .string("t2"),
            "position": .number(2),
        ])

        let post = posts.find(id: "p1")!
        let result = try post.hasManyThrough(
            relationship: "tagsByPositionDesc", joinModel: postTagLinks, target: tags
        )
        XCTAssertEqual(result.map(\.id), ["t1", "t2"],
                       "DESC join leg selects t2-then-t1, but $in re-sorts to target id ASC")
    }

    // MARK: - hasManyThrough

    func testHasManyThroughResolvesViaJoinModel() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        _ = try tags.create(id: "t1", values: ["name": .string("red")])
        _ = try tags.create(id: "t2", values: ["name": .string("blue")])
        _ = try tags.create(id: "t3", values: ["name": .string("green")])
        _ = try postTagLinks.create(id: "l1", values: [
            "postId": .string("p1"), "tagId": .string("t1"),
        ])
        _ = try postTagLinks.create(id: "l2", values: [
            "postId": .string("p1"), "tagId": .string("t3"),
        ])

        let post = posts.find(id: "p1")!
        let result = try post.hasManyThrough(
            relationship: "tags",
            joinModel: postTagLinks,
            target: tags
        )
        XCTAssertEqual(Set(result.map(\.id)), ["t1", "t3"])
    }

    func testHasManyThroughReturnsEmptyWhenNoJoinRecords() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Lonely")])
        let post = posts.find(id: "p1")!
        let result = try post.hasManyThrough(
            relationship: "tags",
            joinModel: postTagLinks,
            target: tags
        )
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - hasManyThrough pagination (#1230, rerouted #1607)

    /// Paginated dynamic-path `hasManyThrough`. The `tags` relationship
    /// declares no join order, so the paginated overload defaults to
    /// **join-model `id ASC`** and pages the join leg through the shared
    /// composite-cursor engine. Cursors are now OPAQUE `String` tokens
    /// (not raw join-row ids), so the test feeds them back verbatim rather
    /// than asserting their bytes. Seeds six tags/links so `limit: 2`
    /// yields three pages; walks forward, then steps back.
    func testHasManyThroughPaginatesJoinLeg() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        for i in 1...6 {
            _ = try tags.create(id: "t\(i)", values: ["name": .string("n\(i)")])
            _ = try postTagLinks.create(id: "l\(i)", values: [
                "postId": .string("p1"), "tagId": .string("t\(i)"),
            ])
        }
        let post = posts.find(id: "p1")!

        func page(after: String? = nil, before: String? = nil,
                  direction: CursorDirection = .forward) throws -> PagedQueryResult<PrimitiveRecord> {
            try post.hasManyThrough(
                relationship: "tags", joinModel: postTagLinks, target: tags,
                limit: 2, afterCursor: after, beforeCursor: before, direction: direction
            )
        }

        let p1 = try page()
        XCTAssertEqual(p1.data.map(\.id), ["t1", "t2"])
        XCTAssertNotNil(p1.nextCursor)
        XCTAssertNil(p1.prevCursor, "first page has no prevCursor")
        XCTAssertTrue(p1.hasMore)

        let p2 = try page(after: p1.nextCursor)
        XCTAssertEqual(p2.data.map(\.id), ["t3", "t4"])
        XCTAssertNotNil(p2.nextCursor)
        XCTAssertNotNil(p2.prevCursor)
        XCTAssertTrue(p2.hasMore)

        let p3 = try page(after: p2.nextCursor)
        XCTAssertEqual(p3.data.map(\.id), ["t5", "t6"])
        XCTAssertNil(p3.nextCursor, "last page has no nextCursor")
        XCTAssertFalse(p3.hasMore)

        // Backward from page 3's prevCursor returns page 2's rows in
        // DECLARED order. `hasMore` tracks the BACKWARD paging direction
        // (more earlier rows remain) — the over-fetch signal, not
        // "nextCursor is present". Page 2 has page 1 before it → hasMore.
        let back = try page(before: p3.prevCursor, direction: .backward)
        XCTAssertEqual(back.data.map(\.id), ["t3", "t4"],
                       "backward page returns rows in declared (ascending) order")
        XCTAssertTrue(back.hasMore,
                      "backward hasMore tracks earlier rows remaining, not nextCursor")
    }

    /// Straddling-tie regression (#1607, Swift analog of JS scenario8 /
    /// scenario50). A join set whose order-field value repeats ACROSS a
    /// page boundary must page with NO skips and NO duplicates. The old
    /// hand-rolled raw-scalar cursor used the bare order value in a
    /// `$gt`/`$lt` filter, so a tie straddling the boundary was either
    /// skipped (`$gt`) or duplicated (`$lt`). Routing through the
    /// composite `(position, id)` cursor fixes it.
    func testHasManyThroughStraddlingTiePagesWithoutSkipOrDuplicate() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        // positions: l1=1, l2=2, l3=2, l4=3, l5=3, l6=4 — ties at 2 (l2/l3)
        // and 3 (l4/l5) straddle the limit-2 page boundaries.
        let positions = [1, 2, 2, 3, 3, 4]
        for i in 1...6 {
            _ = try tags.create(id: "t\(i)", values: ["name": .string("n\(i)")])
            _ = try postTagLinks.create(id: "l\(i)", values: [
                "postId": .string("p1"), "tagId": .string("t\(i)"),
                "position": .number(Double(positions[i - 1])),
            ])
        }
        let post = posts.find(id: "p1")!

        func page(after: String? = nil) throws -> PagedQueryResult<PrimitiveRecord> {
            try post.hasManyThrough(
                relationship: "tagsByPositionAsc",
                joinModel: postTagLinks, target: tags,
                limit: 2, afterCursor: after
            )
        }

        // Walk every page forward, accumulating ids.
        var seen: [String] = []
        var cursor: String? = nil
        var guardCount = 0
        repeat {
            let p = try page(after: cursor)
            seen.append(contentsOf: p.data.map(\.id))
            cursor = p.hasMore ? p.nextCursor : nil
            guardCount += 1
            XCTAssertLessThan(guardCount, 10, "pagination should terminate")
        } while cursor != nil

        XCTAssertEqual(seen.sorted(), ["t1", "t2", "t3", "t4", "t5", "t6"],
                       "every row visited exactly once despite ties on the boundary")
        XCTAssertEqual(seen.count, Set(seen).count, "no duplicate rows across pages")
    }

    /// A non-positive `limit` returns an empty page without querying
    /// (#1230). The paginated accessor guards it before delegating.
    func testHasManyThroughNonPositiveLimitReturnsEmptyPage() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        for i in 1...3 {
            _ = try tags.create(id: "t\(i)", values: ["name": .string("n\(i)")])
            _ = try postTagLinks.create(id: "l\(i)", values: [
                "postId": .string("p1"), "tagId": .string("t\(i)"),
            ])
        }
        let post = posts.find(id: "p1")!

        for badLimit in [0, -1, -5] {
            let page = try post.hasManyThrough(
                relationship: "tags", joinModel: postTagLinks, target: tags,
                limit: badLimit
            )
            XCTAssertTrue(page.data.isEmpty, "limit=\(badLimit) should yield no rows")
            XCTAssertNil(page.nextCursor)
            XCTAssertNil(page.prevCursor)
            XCTAssertFalse(page.hasMore)
        }
    }

    /// D7 / Fork B (#1607, relaxed): a `hasManyThrough` whose join order
    /// field is nullable/optional is now ACCEPTED (it warns rather than
    /// throwing). The composite `(field, id)` cursor appends the `id`
    /// tiebreaker, so a non-unique/not-`required` order field paginates
    /// deterministically. `weight` is declared without `required: true`;
    /// paging by it must succeed and return the linked tag. (A hard throw
    /// here broke existing valid schemas that order by a non-required field —
    /// see `warnIfOrderFieldNullable`.)
    func testHasManyThroughNullableOrderFieldIsAccepted() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("Post")])
        _ = try tags.create(id: "t1", values: ["name": .string("n1")])
        _ = try postTagLinks.create(id: "l1", values: [
            "postId": .string("p1"), "tagId": .string("t1"),
            "position": .number(1), "weight": .number(1),
        ])
        let post = posts.find(id: "p1")!

        let page = try post.hasManyThrough(
            relationship: "tagsByWeight",
            joinModel: postTagLinks, target: tags, limit: 2
        )
        XCTAssertEqual(
            page.data.map { $0.id }, ["t1"],
            "paging by a nullable order field should succeed and return the linked tag"
        )
    }

    // MARK: - Error cases

    func testUnknownRelationshipThrows() throws {
        _ = try posts.create(id: "p1", values: ["title": .string("t")])
        let post = posts.find(id: "p1")!
        XCTAssertThrowsError(
            try post.refersTo(relationship: "nope", target: users)
        ) { error in
            XCTAssertEqual(
                error as? RelationshipError,
                .relationshipNotFound("nope")
            )
        }
    }

    /// Calling `refersTo` on a hasMany relationship (or vice-versa)
    /// throws with the expected-vs-actual type.
    func testWrongRelationshipTypeThrows() throws {
        _ = try users.create(id: "u1", values: ["name": .string("A")])
        let alice = users.find(id: "u1")!

        // `posts` is declared hasMany on users — invalid target for refersTo.
        XCTAssertThrowsError(
            try alice.refersTo(relationship: "posts", target: posts)
        ) { error in
            XCTAssertEqual(
                error as? RelationshipError,
                .wrongType(name: "posts", expected: "refersTo", got: "hasMany")
            )
        }
    }
}
