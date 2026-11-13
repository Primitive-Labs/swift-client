import XCTest
import YSwift
@testable import JsBaoClient

/// #5136 behaviour 3 (pin): every read of a db3's store answers each row with
/// `id` equal to its key, as it did before the store kept rows without `id`:
/// the store's reads, a page plain and projected, its cursor pages both ways,
/// `count`, the include legs, and the model facade, each compared with rows
/// built here. Ids that need JSON escaping restore as they were written.
final class RecordLogJsonbReadsHermeticTests: XCTestCase {

    private static let author = PrimitiveSchema(name: "Author", fields: [
        "id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string),
    ])
    private static let post = PrimitiveSchema(name: "Post", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "rank": FieldDescriptor(type: .number),
        "authorId": FieldDescriptor(type: .string), "tagIds": FieldDescriptor(type: .stringset),
    ])
    private static let comment = PrimitiveSchema(name: "Comment", fields: [
        "id": FieldDescriptor(type: .id), "postId": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
    ])

    private static let document = "db3-reads"

    /// Ids a JSON text must escape, or carries as more than one byte.
    private static let postIds = ["p\"quoted", "p\\slash", "p\u{1}control", "pé", "p\u{2028}", "plain"]

    private var fixture: RecordLogViewFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("jsonb-reads")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    private var authors: [RecordLogRow] {
        [["id": "a\"1", "name": "Ann"], ["id": "aé2", "name": "Bea"]]
    }

    private var posts: [RecordLogRow] {
        Self.postIds.enumerated().map { i, id in
            [
                "id": .string(id), "title": .string("post \(i)"), "rank": .number(Double(i)),
                "authorId": .string(i % 2 == 0 ? "a\"1" : "aé2"), "tagIds": .array(i % 2 == 0 ? ["a\"1"] : ["a\"1", "aé2"]),
            ]
        }
    }

    private var comments: [RecordLogRow] {
        (0..<12).map { i in
            ["id": .string(String(format: "c\\%02d", i)), "postId": .string(Self.postIds[i % 3]), "body": .string("b\(i)")]
        }
    }

    private func seed() throws -> RecordLogStore {
        try fixture.seed(Self.document, "Author", authors.map(JSONValue.object))
        try fixture.seed(Self.document, "Post", posts.map(JSONValue.object))
        try fixture.seed(Self.document, "Comment", comments.map(JSONValue.object))
        for schema in [Self.author, Self.post, Self.comment] { try fixture.member(schema, Self.document) }
        return try fixture.open(Self.document).store
    }

    private func byId(_ rows: [RecordLogRow]) -> [String: RecordLogRow] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0["id"]?.stringValue ?? "", $0) })
    }

    /// `rows` sorted by id, as SQLite's `BINARY` orders the keys.
    private func sorted(_ rows: [RecordLogRow]) -> [RecordLogRow] {
        rows.sorted { Array(($0["id"]?.stringValue ?? "").utf8).lexicographicallyPrecedes(Array(($1["id"]?.stringValue ?? "").utf8)) }
    }

    /// A row as the model facade answers a page's rows: under its db3 (a
    /// related row is answered as stored).
    private func modelRow(_ row: RecordLogRow) -> RecordLogRow {
        var row = row
        row["_meta_doc_id"] = .string(Self.document)
        return row
    }

    func testTheStoresReadsAnswerEachRowWithItsId() throws {
        let store = try seed()
        let posts = byId(self.posts)
        for (id, row) in posts { XCTAssertEqual(try store.read(model: "Post", id: id), row, id) }
        XCTAssertNil(try store.read(model: "Post", id: "absent"))
        XCTAssertEqual(
            try store.readMany(model: "Post", ids: ["plain", "absent", "p\"quoted", "pé"]),
            [posts["plain"], nil, posts["p\"quoted"], posts["pé"]], "in the order asked, a missing one nil"
        )
        XCTAssertEqual(try store.readRowsAfter(model: "Post", after: nil, limit: 3), Array(sorted(self.posts).prefix(3)))
        XCTAssertEqual(
            try store.readRowsAfter(model: "Post", after: sorted(self.posts)[2]["id"]?.stringValue, limit: 10),
            Array(sorted(self.posts).dropFirst(3))
        )
        XCTAssertEqual(try store.confirmedRows(), authors + self.posts + comments, "in the order they arrived")
    }

    func testAPageItsProjectionsCursorsAndCountAnswerEachRowWithItsId() throws {
        let store = try seed()
        let expected = sorted(posts)
        let page = try store.queryView("Post", options: QueryOptions(sort: ["id": 1]))
        XCTAssertEqual(page.data, expected)
        XCTAssertFalse(page.hasMore)

        let included = try store.queryView("Post", options: QueryOptions(sort: ["id": 1], projection: ["title": 1]))
        XCTAssertEqual(included.data, expected.map { ["id": $0["id"]!, "title": $0["title"]!] }, "inclusion keeps id")
        let excluded = try store.queryView("Post", options: QueryOptions(sort: ["id": 1], projection: ["title": 0, "id": 0]))
        XCTAssertEqual(excluded.data, expected.map { $0.filter { $0.key != "title" } }, "exclusion never drops id")

        // Forward pages of two, then back from the last.
        var forward: [RecordLogRow] = []
        var cursor: String?
        var last: PagedQueryResult<RecordLogRow>?
        repeat {
            let next = try store.queryView("Post", options: QueryOptions(sort: ["rank": -1], limit: 2, cursor: cursor))
            forward += next.data
            last = next
            cursor = next.hasMore ? next.nextCursor : nil
        } while cursor != nil
        XCTAssertEqual(forward, posts.reversed())
        let back = try store.queryView(
            "Post", options: QueryOptions(sort: ["rank": -1], limit: 2, cursor: last?.prevCursor, direction: .backward)
        )
        XCTAssertEqual(back.data, Array(posts.reversed()[2..<4]), "a backward page in sort order")

        XCTAssertEqual(try store.countView("Post"), posts.count)
        XCTAssertEqual(try store.countView("Post", ["id": "p\"quoted"]), 1)
        XCTAssertEqual(try store.queryView("Post", ["id": "p\\slash"]).data, [byId(posts)["p\\slash"]!])
    }

    func testIncludeLegsAnswerEachRowWithItsId() throws {
        _ = try seed()
        let shared = fixture.shared(Self.post)
        let rows = try shared.query(nil, options: QueryOptions(sort: ["id": 1]), include: [
            Include(type: .refersTo, target: fixture.shared(Self.author), sourceField: "authorId", resultKey: "author"),
            Include(type: .refersToMany, target: fixture.shared(Self.author), sourceField: "tagIds", resultKey: "tagged"),
            Include(type: .hasMany, target: fixture.shared(Self.comment), foreignKey: "postId", resultKey: "comments"),
            Include(type: .hasMany, target: fixture.shared(Self.comment), foreignKey: "postId", sort: ["id": -1], limit: 2,
                    resultKey: "latest"),
        ])
        let authors = byId(self.authors)
        XCTAssertEqual(rows.count, posts.count)
        for row in rows {
            let id = try XCTUnwrap(row["id"]?.stringValue)
            let post = try XCTUnwrap(byId(posts)[id])
            // The model API tags each included record with its db3, as it tags the row (#5896).
            let related = try XCTUnwrap(row["_related"]?.objectValue).mapValues(Self.untagged)
            XCTAssertEqual(related["author"], .object(authors[post["authorId"]?.stringValue ?? ""]!), id)
            XCTAssertEqual(
                related["tagged"], .array((post["tagIds"]?.arrayValue ?? []).map { .object(authors[$0.stringValue!]!) }), id
            )
            let mine = sorted(comments.filter { $0["postId"]?.stringValue == id })
            XCTAssertEqual(related["comments"], .array(mine.map(JSONValue.object)), id)
            XCTAssertEqual(related["latest"], .array(mine.reversed().prefix(2).map(JSONValue.object)), id)
        }
    }

    /// `value` without the `_meta_doc_id` the model API tags an included record with.
    private static func untagged(_ value: JSONValue) -> JSONValue {
        if let rows = value.arrayValue { return .array(rows.map(untagged)) }
        guard let row = value.objectValue else { return value }
        return .object(row.filter { $0.key != "_meta_doc_id" })
    }

    func testTheModelFacadeAnswersEachRowWithItsId() throws {
        _ = try seed()
        let shared = fixture.shared(Self.post)
        for row in posts {
            let id = row["id"]?.stringValue ?? ""
            XCTAssertEqual(shared.find(id: id)?.row.filter { $0.key != "_meta_doc_id" }, row, id)
            XCTAssertEqual(shared.member(docId: Self.document)?.find(id: id)?.id, id)
        }
        XCTAssertEqual(try shared.query(nil, options: QueryOptions(sort: ["id": 1])), sorted(posts).map(modelRow))
        var paged: [[String: JSONValue]] = []
        var cursor: String?
        repeat {
            let page = try shared.queryPaged(nil, options: QueryOptions(sort: ["id": 1], limit: 4, cursor: cursor))
            paged += page.data.map(\.raw)
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        XCTAssertEqual(paged, sorted(posts).map(modelRow))
        let member = try XCTUnwrap(shared.member(docId: Self.document))
        XCTAssertEqual(try member.query(["title": "post 1"]), [modelRow(posts[1])])
    }
}
