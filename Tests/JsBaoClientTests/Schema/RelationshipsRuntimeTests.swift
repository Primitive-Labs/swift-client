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
                "id":     FieldDescriptor(type: .id),
                "postId": FieldDescriptor(type: .string, indexed: true),
                "tagId":  FieldDescriptor(type: .string, indexed: true),
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
