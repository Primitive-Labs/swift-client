import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests the batch `include` pre-fetch API — a port of js-bao's
/// `IncludeResolver` (see `/tmp/js-bao-ref-uniq/IncludeResolver.ts`).
///
/// Contract:
///  - `DynamicModel.query(filter, options: {include: [...]})` runs the
///    base query, then for each include spec collects FK values from
///    the parents, does ONE batched lookup on the target, and attaches
///    results under `row["_related"][resultKey]`.
///  - Three relationship types: `refersTo`, `refersToMany` (StringSet
///    of FKs), `hasMany` (target's FK points back).
///  - Nested includes allowed up to depth 3.
///  - Optional filter / sort / limit on the related records.
///  - Result key defaults to `target.modelName`; overridable via `as:`.
///
/// The load-bearing property is **batch**: N parent records + an
/// include = ONE target lookup, not N.
final class IncludeResolverTests: XCTestCase {

    private var doc: YDocument!
    private var users: DynamicModel!
    private var posts: DynamicModel!
    private var tags: DynamicModel!

    override func setUp() {
        SchemaSync.clearCache()
        doc = YDocument()

        users = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "inc_users",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        ))
        posts = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "inc_posts",
            fields: [
                "id":     FieldDescriptor(type: .id),
                "userId": FieldDescriptor(type: .string, indexed: true),
                "title":  FieldDescriptor(type: .string),
                "tagIds": FieldDescriptor(type: .stringset),
                "score":  FieldDescriptor(type: .number),
            ]
        ))
        tags = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "inc_tags",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        ))
    }

    private func seed() throws {
        _ = try users.create(id: "u1", values: ["name": .string("Alice")])
        _ = try users.create(id: "u2", values: ["name": .string("Bob")])
        _ = try tags.create(id: "t1", values: ["name": .string("red")])
        _ = try tags.create(id: "t2", values: ["name": .string("blue")])
        _ = try tags.create(id: "t3", values: ["name": .string("green")])
        _ = try posts.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("one"),
            "tagIds": .stringset(["t1", "t2"]), "score": .number(10),
        ])
        _ = try posts.create(id: "p2", values: [
            "userId": .string("u1"), "title": .string("two"),
            "tagIds": .stringset(["t2"]), "score": .number(20),
        ])
        _ = try posts.create(id: "p3", values: [
            "userId": .string("u2"), "title": .string("three"),
            "tagIds": .stringset(["t3"]), "score": .number(30),
        ])
    }

    // MARK: - refersTo

    /// Each post has its `author` (refersTo user) pre-loaded under
    /// `row["_related"]["author"]`.
    func testRefersToInclude() throws {
        try seed()
        let rows = try posts.query(nil, options: QueryOptions(sort: ["id": 1]), include: [
            Include(type: .refersTo, target: users,
                    sourceField: "userId", resultKey: "author")
        ])
        XCTAssertEqual(rows.count, 3)
        let firstAuthor = ((rows[0]["_related"] as? [String: Any])?["author"]
            as? [String: Any])
        XCTAssertEqual(firstAuthor?["id"] as? String, "u1")
        XCTAssertEqual(firstAuthor?["name"] as? String, "Alice")
    }

    /// A post with a missing FK gets `_related.author = nil`.
    func testRefersToMissingFkReturnsNil() throws {
        try seed()
        _ = try posts.create(id: "p_orphan", values: ["title": .string("orphan")])
        let rows = try posts.query(
            ["id": "p_orphan"],
            options: nil,
            include: [
                Include(type: .refersTo, target: users,
                        sourceField: "userId", resultKey: "author")
            ]
        )
        let related = rows[0]["_related"] as? [String: Any]
        XCTAssertNotNil(related, "_related container must exist")
        XCTAssertTrue(related?["author"] is NSNull || related?["author"] == nil,
                      "Missing FK → nil author")
    }

    /// Two parents sharing an FK hit ONE target record but attach it
    /// to both parents. Proves batch dedup.
    func testRefersToDedupesSharedForeignKey() throws {
        try seed()
        let rows = try posts.query(
            ["userId": "u1"],
            options: QueryOptions(sort: ["id": 1]),
            include: [
                Include(type: .refersTo, target: users,
                        sourceField: "userId", resultKey: "author")
            ]
        )
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let author = ((row["_related"] as? [String: Any])?["author"]
                as? [String: Any])
            XCTAssertEqual(author?["id"] as? String, "u1",
                           "Both posts share the same author record")
        }
    }

    // MARK: - refersToMany (StringSet of FKs → array of records)

    func testRefersToManyInclude() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"],
            options: nil,
            include: [
                Include(type: .refersToMany, target: tags,
                        sourceField: "tagIds", resultKey: "tags")
            ]
        )
        let related = rows[0]["_related"] as? [String: Any]
        let tagRecords = related?["tags"] as? [[String: Any]] ?? []
        let tagIds = Set(tagRecords.compactMap { $0["id"] as? String })
        XCTAssertEqual(tagIds, ["t1", "t2"])
    }

    /// `refersToMany` with a filter narrows the resolved records.
    /// p1 has stringset [t1, t2]; filtering the target by
    /// `name = "red"` should return only t1 even though the parent
    /// references both.
    func testRefersToManyWithFilter() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"], options: nil, include: [
                Include(
                    type: .refersToMany, target: tags,
                    sourceField: "tagIds",
                    filter: ["name": "red"],
                    resultKey: "tags"
                )
            ]
        )
        let related = (rows[0]["_related"] as? [String: Any])?["tags"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(related.compactMap { $0["id"] as? String }, ["t1"])
    }

    /// `refersToMany` with sort orders the resolved records.
    /// p1's members are {t1=red, t2=blue}; sort by `name ASC` must
    /// put blue before red.
    func testRefersToManyWithSort() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"], options: nil, include: [
                Include(
                    type: .refersToMany, target: tags,
                    sourceField: "tagIds",
                    sort: ["name": 1],
                    resultKey: "tags"
                )
            ]
        )
        let related = (rows[0]["_related"] as? [String: Any])?["tags"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(
            related.compactMap { $0["name"] as? String },
            ["blue", "red"],
            "Sort ASC on name should emit blue before red"
        )
    }

    /// `refersToMany` with a per-parent limit caps the number of
    /// resolved records. p1 references 2 tags; limit 1 returns 1.
    func testRefersToManyWithLimit() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"], options: nil, include: [
                Include(
                    type: .refersToMany, target: tags,
                    sourceField: "tagIds",
                    sort: ["name": 1], // deterministic for assertion
                    limit: 1,
                    resultKey: "tags"
                )
            ]
        )
        let related = (rows[0]["_related"] as? [String: Any])?["tags"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual(related[0]["name"] as? String, "blue",
                       "Sorted ASC then limited to 1 → blue")
    }

    /// Batch dedup — two parents sharing an FK in their stringset
    /// should resolve that tag once, not twice. p1 and p2 both
    /// include t2; the returned objects for that tag should be
    /// materially the same record.
    func testRefersToManyDedupesSharedMemberAcrossParents() throws {
        try seed()
        let rows = try posts.query(
            ["userId": "u1"], options: QueryOptions(sort: ["id": 1]),
            include: [
                Include(
                    type: .refersToMany, target: tags,
                    sourceField: "tagIds", resultKey: "tags"
                )
            ]
        )
        XCTAssertEqual(rows.count, 2)
        let t2FromP1 = (rows[0]["_related"] as? [String: Any])?["tags"]
            as? [[String: Any]]
        let t2FromP2 = (rows[1]["_related"] as? [String: Any])?["tags"]
            as? [[String: Any]]
        let p1T2 = t2FromP1?.first(where: { $0["id"] as? String == "t2" })
        let p2T2 = t2FromP2?.first(where: { $0["id"] as? String == "t2" })
        XCTAssertNotNil(p1T2)
        XCTAssertNotNil(p2T2)
        XCTAssertEqual(p1T2?["name"] as? String, p2T2?["name"] as? String,
                       "Same record via shared member must look identical on both parents")
    }

    /// A post with an empty StringSet gets `_related.tags = []`.
    func testRefersToManyEmptySet() throws {
        try seed()
        _ = try posts.create(id: "p_notags", values: [
            "userId": .string("u1"), "title": .string("no-tags"),
            "tagIds": .stringset([]),
        ])
        let rows = try posts.query(
            ["id": "p_notags"],
            options: nil,
            include: [
                Include(type: .refersToMany, target: tags,
                        sourceField: "tagIds", resultKey: "tags")
            ]
        )
        let tagRecords = (rows[0]["_related"] as? [String: Any])?["tags"]
            as? [[String: Any]]
        XCTAssertEqual(tagRecords?.count, 0)
    }

    // MARK: - hasMany

    /// Each user gets their posts pre-loaded under `_related.posts`.
    func testHasManyInclude() throws {
        try seed()
        let rows = try users.query(nil, options: QueryOptions(sort: ["id": 1]), include: [
            Include(type: .hasMany, target: posts,
                    foreignKey: "userId", resultKey: "posts")
        ])
        let u1 = rows.first(where: { $0["id"] as? String == "u1" })
        let u1Posts = ((u1?["_related"]) as? [String: Any])?["posts"]
            as? [[String: Any]]
        XCTAssertEqual(Set(u1Posts?.compactMap { $0["id"] as? String } ?? []),
                       ["p1", "p2"])
        let u2 = rows.first(where: { $0["id"] as? String == "u2" })
        let u2Posts = ((u2?["_related"]) as? [String: Any])?["posts"]
            as? [[String: Any]]
        XCTAssertEqual(Set(u2Posts?.compactMap { $0["id"] as? String } ?? []),
                       ["p3"])
    }

    /// `hasMany` with a filter narrows the included records. Alice has
    /// posts p1 (score 10) and p2 (score 20); with `score > 15`, only
    /// p2 comes back.
    func testHasManyIncludeWithFilter() throws {
        try seed()
        let rows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [
                Include(
                    type: .hasMany, target: posts,
                    foreignKey: "userId",
                    filter: ["score": ["$gt": 15]],
                    resultKey: "posts"
                )
            ]
        )
        let uPosts = (rows[0]["_related"] as? [String: Any])?["posts"]
            as? [[String: Any]]
        XCTAssertEqual(uPosts?.compactMap { $0["id"] as? String }, ["p2"])
    }

    /// `hasMany` with sort orders the included records.
    func testHasManyIncludeWithSort() throws {
        try seed()
        let rows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [
                Include(
                    type: .hasMany, target: posts,
                    foreignKey: "userId",
                    sort: ["score": -1],
                    resultKey: "posts"
                )
            ]
        )
        let uPosts = (rows[0]["_related"] as? [String: Any])?["posts"]
            as? [[String: Any]]
        XCTAssertEqual(uPosts?.compactMap { $0["id"] as? String }, ["p2", "p1"],
                       "Sort by score DESC → p2 (20) before p1 (10)")
    }

    /// Per-parent `limit`. u1 has 2 posts; with limit 1 we get just 1
    /// (the first by id, since no sort is specified).
    func testHasManyIncludeWithLimit() throws {
        try seed()
        let rows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [
                Include(
                    type: .hasMany, target: posts,
                    foreignKey: "userId",
                    sort: ["id": 1],
                    limit: 1,
                    resultKey: "posts"
                )
            ]
        )
        let uPosts = (rows[0]["_related"] as? [String: Any])?["posts"]
            as? [[String: Any]]
        XCTAssertEqual(uPosts?.count, 1)
        XCTAssertEqual(uPosts?.first?["id"] as? String, "p1")
    }

    /// Include-mode projection that omits the foreign key must not
    /// cause related records to be dropped. The resolver needs the FK
    /// internally to group by parent; it force-selects it and then
    /// strips it from the emitted rows.
    func testHasManyIncludeWithProjectionOmittingForeignKey() throws {
        try seed()
        let rows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [
                Include(
                    type: .hasMany, target: posts,
                    foreignKey: "userId",
                    projection: ["title": 1],
                    resultKey: "posts"
                )
            ]
        )
        let uPosts = (rows[0]["_related"] as? [String: Any])?["posts"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(Set(uPosts.compactMap { $0["id"] as? String }),
                       ["p1", "p2"],
                       "Related posts must not be dropped when projection omits FK")
        for p in uPosts {
            XCTAssertNotNil(p["title"])
            XCTAssertNil(p["userId"],
                         "FK must be stripped when projection excluded it")
            XCTAssertNil(p["score"])
        }
    }

    /// Exclude-mode projection that names the foreign key must also
    /// not drop related records.
    func testHasManyIncludeWithExcludeProjectionOfForeignKey() throws {
        try seed()
        let rows = try users.query(
            ["id": "u1"],
            options: nil,
            include: [
                Include(
                    type: .hasMany, target: posts,
                    foreignKey: "userId",
                    projection: ["userId": 0],
                    resultKey: "posts"
                )
            ]
        )
        let uPosts = (rows[0]["_related"] as? [String: Any])?["posts"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(Set(uPosts.compactMap { $0["id"] as? String }),
                       ["p1", "p2"])
        for p in uPosts {
            XCTAssertNil(p["userId"])
            XCTAssertNotNil(p["title"])
        }
    }

    // MARK: - Nested includes

    /// A post has an `author` (refersTo), and the user has many
    /// `posts` (hasMany back). Nesting the hasMany under the refersTo
    /// exercises depth > 1.
    func testNestedInclude() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"],
            options: nil,
            include: [
                Include(
                    type: .refersTo, target: users,
                    sourceField: "userId", resultKey: "author",
                    include: [
                        Include(type: .hasMany, target: posts,
                                foreignKey: "userId", resultKey: "allPosts")
                    ]
                )
            ]
        )
        let author = (rows[0]["_related"] as? [String: Any])?["author"]
            as? [String: Any]
        let authorsPosts = (author?["_related"] as? [String: Any])?["allPosts"]
            as? [[String: Any]]
        XCTAssertEqual(Set(authorsPosts?.compactMap { $0["id"] as? String } ?? []),
                       ["p1", "p2"])
    }

    /// Depth limit: nesting beyond 3 levels is silently truncated
    /// (matches js-bao's `if (depth >= 3) return`).
    func testDepthLimitStopsAtThree() throws {
        try seed()
        // 4 levels deep via self-referential hasMany.
        let rows = try posts.query(
            ["id": "p1"],
            options: nil,
            include: [
                Include(type: .refersTo, target: users,
                        sourceField: "userId", resultKey: "author",
                include: [
                    Include(type: .hasMany, target: posts,
                            foreignKey: "userId", resultKey: "posts",
                    include: [
                        Include(type: .refersTo, target: users,
                                sourceField: "userId", resultKey: "author",
                        include: [
                            Include(type: .hasMany, target: posts,
                                    foreignKey: "userId", resultKey: "posts")
                        ])
                    ])
                ])
            ]
        )
        // Inspect the 4th level — should be absent (depth cut off).
        let author = (rows[0]["_related"] as? [String: Any])?["author"]
            as? [String: Any]
        let lvl2posts = (author?["_related"] as? [String: Any])?["posts"]
            as? [[String: Any]]
        let lvl3author = (lvl2posts?.first?["_related"]
            as? [String: Any])?["author"] as? [String: Any]
        // Level 3 author exists. Level 4 posts should NOT (cut off).
        XCTAssertNotNil(lvl3author)
        XCTAssertNil(lvl3author?["_related"])
    }

    // MARK: - Multiple includes on one query

    func testMultipleIncludesOnOneQuery() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"],
            options: nil,
            include: [
                Include(type: .refersTo, target: users,
                        sourceField: "userId", resultKey: "author"),
                Include(type: .refersToMany, target: tags,
                        sourceField: "tagIds", resultKey: "tags"),
            ]
        )
        let related = rows[0]["_related"] as? [String: Any]
        let author = related?["author"] as? [String: Any]
        let tagRecs = related?["tags"] as? [[String: Any]]
        XCTAssertEqual(author?["id"] as? String, "u1")
        XCTAssertEqual(tagRecs?.count, 2)
    }

    // MARK: - Result-key alias

    /// `as:` nil defaults to `target.modelName`.
    func testResultKeyDefaultsToModelName() throws {
        try seed()
        let rows = try posts.query(
            ["id": "p1"],
            options: nil,
            include: [
                Include(type: .refersTo, target: users,
                        sourceField: "userId")  // no `as:`
            ]
        )
        let related = rows[0]["_related"] as? [String: Any]
        XCTAssertNotNil(related?["inc_users"],
                        "Default result key should be target's modelName")
    }

    // MARK: - Per-record refersToMany accessor

    /// Companion to the batch API: the per-record accessor for
    /// refersToMany on `PrimitiveRecord`.
    func testRecordRefersToManyAccessor() throws {
        try seed()
        // Seed a relationship in the schema — accessor needs it.
        SchemaSync.clearCache()
        let doc2 = YDocument()
        let tags2 = DynamicModel(doc: doc2, schema: PrimitiveSchema(
            name: "tags2",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        ))
        let posts2 = DynamicModel(doc: doc2, schema: PrimitiveSchema(
            name: "posts2",
            fields: [
                "id":     FieldDescriptor(type: .id),
                "tagIds": FieldDescriptor(type: .stringset),
            ],
            relationships: [
                "tags": RelationshipDescriptor(properties: [
                    "type": "refersToMany",
                    "model": "tags2",
                    "sourceField": "tagIds",
                ])
            ]
        ))

        _ = try tags2.create(id: "ta", values: ["name": .string("A")])
        _ = try tags2.create(id: "tb", values: ["name": .string("B")])
        _ = try posts2.create(id: "pp", values: [
            "tagIds": .stringset(["ta", "tb"]),
        ])
        let post = posts2.find(id: "pp")!
        let results = try post.refersToMany(relationship: "tags", target: tags2)
        XCTAssertEqual(Set(results.map(\.id)), ["ta", "tb"])
    }
}
