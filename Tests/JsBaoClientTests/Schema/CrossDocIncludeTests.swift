import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests that `Include` resolves related records across multiple
/// YDocuments when the target is a `MultiDocModel`.
///
/// Mirrors js-bao's shared-DB design (cloudflare-do.js `_resolveIncludes`):
/// one SQLite table per model spanning every connected doc, with
/// `_meta_doc_id` as a column. An `IN (?, ?, ...)` batch lookup on the
/// target table therefore resolves FKs regardless of which doc owns
/// the parent or the target — no fan-out, no per-doc iteration.
///
/// Scope here: the resolver takes an `IncludeTarget` (not a concrete
/// `DynamicModel`), and both `DynamicModel` and `MultiDocModel`
/// conform. Parent rows may come from either kind of model as well.
final class CrossDocIncludeTests: XCTestCase {

    private let userSchema = PrimitiveSchema(
        name: "xd_users",
        fields: [
            "id":   FieldDescriptor(type: .id),
            "name": FieldDescriptor(type: .string),
        ]
    )

    private let postSchema = PrimitiveSchema(
        name: "xd_posts",
        fields: [
            "id":     FieldDescriptor(type: .id),
            "userId": FieldDescriptor(type: .string, indexed: true),
            "title":  FieldDescriptor(type: .string),
            "tagIds": FieldDescriptor(type: .stringset),
        ]
    )

    private let tagSchema = PrimitiveSchema(
        name: "xd_tags",
        fields: [
            "id":   FieldDescriptor(type: .id),
            "name": FieldDescriptor(type: .string),
        ]
    )

    /// Users split across two docs, posts in a third doc pointing at
    /// users that live in either. Proves the `refersTo` include
    /// resolves regardless of which doc owns the target.
    func testRefersToIncludeResolvesAcrossDocs() throws {
        SchemaSync.clearCache()
        let users = MultiDocModel(schema: userSchema)
        let posts = MultiDocModel(schema: postSchema)

        let usersA = users.connect(docId: "usersDocA", doc: YDocument())
        _ = try usersA.create(id: "u1", values: ["name": .string("Alice")])

        SchemaSync.clearCache()
        let usersB = users.connect(docId: "usersDocB", doc: YDocument())
        _ = try usersB.create(id: "u2", values: ["name": .string("Bob")])

        SchemaSync.clearCache()
        let postsA = posts.connect(docId: "postsDocA", doc: YDocument())
        _ = try postsA.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("alice-post"),
        ])
        _ = try postsA.create(id: "p2", values: [
            "userId": .string("u2"), "title": .string("bob-post"),
        ])

        let rows = try posts.query(
            nil,
            options: QueryOptions(sort: ["id": 1]),
            include: [
                Include(type: .refersTo, target: users,
                        sourceField: "userId", resultKey: "author")
            ]
        )
        XCTAssertEqual(rows.count, 2)

        let aliceAuthor = ((rows[0]["_related"] as? [String: Any])?["author"]
                           as? [String: Any])
        XCTAssertEqual(aliceAuthor?["id"] as? String, "u1")
        XCTAssertEqual(aliceAuthor?["name"] as? String, "Alice")

        let bobAuthor = ((rows[1]["_related"] as? [String: Any])?["author"]
                         as? [String: Any])
        XCTAssertEqual(bobAuthor?["id"] as? String, "u2")
        XCTAssertEqual(bobAuthor?["name"] as? String, "Bob",
                       "Author record lives in a different doc — must still resolve")
    }

    /// A `DynamicModel` can be used as the PARENT while the include
    /// target is a `MultiDocModel`. Mixed-mode resolution.
    func testIncludeTargetCanBeMultiDocWhenParentIsSingleDoc() throws {
        SchemaSync.clearCache()
        let users = MultiDocModel(schema: userSchema)

        let usersA = users.connect(docId: "usersDocA", doc: YDocument())
        _ = try usersA.create(id: "u1", values: ["name": .string("Alice")])
        SchemaSync.clearCache()
        let usersB = users.connect(docId: "usersDocB", doc: YDocument())
        _ = try usersB.create(id: "u2", values: ["name": .string("Bob")])

        SchemaSync.clearCache()
        let postsDoc = YDocument()
        let posts = DynamicModel(doc: postsDoc, schema: postSchema)
        _ = try posts.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("one"),
        ])
        _ = try posts.create(id: "p2", values: [
            "userId": .string("u2"), "title": .string("two"),
        ])

        let rows = try posts.query(nil, options: QueryOptions(sort: ["id": 1]), include: [
            Include(type: .refersTo, target: users,
                    sourceField: "userId", resultKey: "author")
        ])
        let names = rows.compactMap {
            (($0["_related"] as? [String: Any])?["author"] as? [String: Any])?["name"]
                as? String
        }
        XCTAssertEqual(names, ["Alice", "Bob"])
    }

    /// `hasMany`: users in one doc, posts authored by them in a
    /// different doc. Include returns the post list per user.
    func testHasManyIncludeResolvesAcrossDocs() throws {
        SchemaSync.clearCache()
        let users = MultiDocModel(schema: userSchema)
        let posts = MultiDocModel(schema: postSchema)

        let usersA = users.connect(docId: "usersDocA", doc: YDocument())
        _ = try usersA.create(id: "u1", values: ["name": .string("Alice")])
        _ = try usersA.create(id: "u2", values: ["name": .string("Bob")])

        SchemaSync.clearCache()
        let postsB = posts.connect(docId: "postsDocB", doc: YDocument())
        _ = try postsB.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("one"),
        ])
        _ = try postsB.create(id: "p2", values: [
            "userId": .string("u1"), "title": .string("two"),
        ])
        _ = try postsB.create(id: "p3", values: [
            "userId": .string("u2"), "title": .string("three"),
        ])

        let rows = try users.query(nil, options: QueryOptions(sort: ["id": 1]), include: [
            Include(type: .hasMany, target: posts,
                    foreignKey: "userId", resultKey: "posts")
        ])
        XCTAssertEqual(rows.count, 2)

        let alicePosts = (rows[0]["_related"] as? [String: Any])?["posts"]
                         as? [[String: Any]] ?? []
        XCTAssertEqual(alicePosts.count, 2)
        XCTAssertEqual(
            Set(alicePosts.compactMap { $0["id"] as? String }),
            ["p1", "p2"]
        )

        let bobPosts = (rows[1]["_related"] as? [String: Any])?["posts"]
                       as? [[String: Any]] ?? []
        XCTAssertEqual(bobPosts.map { $0["id"] as? String }, ["p3"])
    }

    /// `refersToMany` (stringset of FKs): a post's `tagIds` stringset
    /// references tags that live in another doc. Include returns the
    /// full tag records.
    func testRefersToManyResolvesAcrossDocs() throws {
        SchemaSync.clearCache()
        let tags = MultiDocModel(schema: tagSchema)
        let posts = MultiDocModel(schema: postSchema)

        let tagsA = tags.connect(docId: "tagsDocA", doc: YDocument())
        _ = try tagsA.create(id: "t1", values: ["name": .string("red")])
        SchemaSync.clearCache()
        let tagsB = tags.connect(docId: "tagsDocB", doc: YDocument())
        _ = try tagsB.create(id: "t2", values: ["name": .string("blue")])

        SchemaSync.clearCache()
        let postsC = posts.connect(docId: "postsDocC", doc: YDocument())
        _ = try postsC.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("one"),
            "tagIds": .stringset(["t1", "t2"]),
        ])

        let rows = try posts.query(
            ["id": "p1"], options: nil, include: [
                Include(type: .refersToMany, target: tags,
                        sourceField: "tagIds", resultKey: "tags")
            ]
        )
        let tagRows = (rows[0]["_related"] as? [String: Any])?["tags"]
                      as? [[String: Any]] ?? []
        XCTAssertEqual(
            Set(tagRows.compactMap { $0["id"] as? String }),
            ["t1", "t2"],
            "Both tags resolved even though they live in separate docs"
        )
    }
}
