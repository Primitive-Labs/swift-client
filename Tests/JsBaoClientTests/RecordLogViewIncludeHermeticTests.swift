import XCTest
import YSwift
@testable import JsBaoClient

/// #4700 behaviour 13, edges 33, 34 and 37: includes on db3 parents are
/// resolved from `record_log_view` by the reader's own statements, never
/// through the public page.
///
/// - Each parent's legs resolve within the parent's own db3.
/// - A `hasMany` leg is never cut by the default page; one that would read
///   more than 1,000 related rows for the page is refused, as is a page whose
///   `_related` takes it past 8 MiB (`DB3_PAGE_TOO_LARGE`).
/// - The include tree is validated whole before any statement runs: a fourth
///   level or an invalid spec is refused `Invalid include: <reason>`.
/// - A format-1 model's include keeps today's resolver: no caps, a silent
///   stop at depth 3.
final class RecordLogViewIncludeHermeticTests: XCTestCase {

    private static let author = PrimitiveSchema(name: "Author", fields: [
        "id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string),
    ])
    private static let tag = PrimitiveSchema(name: "Tag", fields: [
        "id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string),
    ])
    private static let post = PrimitiveSchema(name: "Post", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "authorId": FieldDescriptor(type: .string), "tagIds": FieldDescriptor(type: .stringset),
        "body": FieldDescriptor(type: .string),
    ])
    private static let comment = PrimitiveSchema(name: "Comment", fields: [
        "id": FieldDescriptor(type: .id), "postId": FieldDescriptor(type: .string),
        "authorId": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
    ])
    private static let reply = PrimitiveSchema(name: "Reply", fields: [
        "id": FieldDescriptor(type: .id), "commentId": FieldDescriptor(type: .string),
        "authorId": FieldDescriptor(type: .string),
    ])

    private static let schemas = [author, tag, post, comment, reply]

    private var fixture: RecordLogViewFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("view-include")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    /// Bind every model to each db3 named, as a client declares its models on open.
    private func bind(_ documents: String...) throws {
        for document in documents {
            for schema in Self.schemas { try fixture.member(schema, document) }
        }
    }

    private func shared(_ schema: PrimitiveSchema) -> MultiDocModel { fixture.shared(schema) }

    private func related(_ row: [String: JSONValue], _ key: String) -> JSONValue? { row["_related"]?[key] }

    private func ids(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    private func comments(_ count: Int, post: String, prefix: String = "c") -> [JSONValue] {
        (1...max(count, 1)).prefix(count).map { i in
            ["id": .string(String(format: "\(prefix)%04d", i)), "postId": .string(post), "body": .string("b\(i)")]
        }
    }

    private func assertTooLarge(_ label: String, _ body: () throws -> Any, _ check: (JsBaoError) -> Void = { _ in }) {
        XCTAssertThrowsError(try body(), label) { error in
            guard let refusal = error as? JsBaoError else { return XCTFail("\(label): \(error)") }
            XCTAssertEqual(refusal.code.rawValue, "DB3_PAGE_TOO_LARGE", "\(label): \(refusal)")
            check(refusal)
        }
    }

    private func assertInvalidInclude(_ label: String, _ message: String, _ body: () throws -> Any) {
        XCTAssertThrowsError(try body(), label) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "\(label): \(error)")
            XCTAssertEqual((error as? JsBaoError)?.message, message, label)
        }
    }

    // MARK: - Behaviour 13: the legs come from the parent's own db3, whole

    func testEachLegResolvesWithinTheParentsDb3AndAHasManyLegIsAttachedWhole() throws {
        try fixture.seed("db3-a", "Author", [["id": "a1", "name": "Ann"]])
        try fixture.seed("db3-a", "Tag", [["id": "t1", "label": "one"], ["id": "t2", "label": "two"]])
        try fixture.seed("db3-a", "Post", [["id": "p1", "title": "A", "authorId": "a1", "tagIds": ["t2", "t1", "tX"]]])
        try fixture.seed("db3-a", "Comment", comments(101, post: "p1"))
        try fixture.seed("db3-b", "Author", [["id": "a1", "name": "Bob"]])
        try fixture.seed("db3-b", "Post", [["id": "q1", "title": "B", "authorId": "a1"]])
        try fixture.seed("db3-b", "Comment", [["id": "cb1", "postId": "p1", "body": "from b"]])
        try bind("db3-a", "db3-b")

        let rows = try shared(Self.post).query(nil, options: QueryOptions(sort: ["id": 1]), include: [
            Include(type: .refersTo, target: shared(Self.author), sourceField: "authorId", resultKey: "author"),
            Include(type: .refersToMany, target: shared(Self.tag), sourceField: "tagIds", resultKey: "tags"),
            Include(type: .hasMany, target: shared(Self.comment), foreignKey: "postId", resultKey: "comments"),
            Include(type: .hasMany, target: shared(Self.comment), foreignKey: "postId", sort: ["id": -1], limit: 2,
                    resultKey: "latest"),
        ])
        XCTAssertEqual(rows.map { $0["id"]?.stringValue }, ["p1", "q1"])
        let p1 = rows[0], q1 = rows[1]
        XCTAssertEqual(related(p1, "author")?["name"], "Ann")
        XCTAssertEqual(related(q1, "author")?["name"], "Bob", "a1 in db3-b is db3-b's own author")
        XCTAssertEqual(ids(related(p1, "tags")), ["t1", "t2"], "members in order, a missing one dropped")
        XCTAssertEqual(ids(related(q1, "tags")), [])
        XCTAssertEqual(ids(related(p1, "comments")).count, 101, "a leg is never cut by the default page")
        XCTAssertFalse(ids(related(p1, "comments")).contains("cb1"), "db3-b's comment never reaches db3-a's post")
        XCTAssertEqual(ids(related(q1, "comments")), [])
        XCTAssertEqual(ids(related(p1, "latest")), ["c0101", "c0100"], "a per-parent limit, in the leg's sort")
    }

    func testAHasManyLegPast1000RowsForThePageIsRefusedAnd1000IsAttached() throws {
        try fixture.seed("db3-a", "Post", [["id": "p1", "title": "A"], ["id": "p2", "title": "B"]])
        try fixture.seed("db3-a", "Comment", comments(600, post: "p1") + comments(400, post: "p2", prefix: "d"))
        try bind("db3-a")
        let spec = [Include(type: .hasMany, target: shared(Self.comment), foreignKey: "postId", resultKey: "comments")]
        let rows = try shared(Self.post).query(nil, include: spec)
        XCTAssertEqual(rows.map { ids(related($0, "comments")).count }.reduce(0, +), 1_000, "1,000 exactly is attached")

        try fixture.seed("db3-a", "Comment", [["id": "d9999", "postId": "p2"]])
        assertTooLarge("1,001 rows over the page's two parents", { try self.shared(Self.post).query(nil, include: spec) }) {
            XCTAssertEqual($0.details?["include"], "comments")
            XCTAssertEqual($0.details?["rows"]?.numberValue, 1_001)
            XCTAssertEqual($0.details?["limit"]?.numberValue, 1_000)
        }
    }

    func testAPageWhoseRelatedRowsTakeItPast8MiBIsRefused() throws {
        let mib = String(repeating: "x", count: 1024 * 1024)
        try fixture.seed("db3-a", "Post", [["id": "p1", "title": "A"]])
        try fixture.seed("db3-a", "Comment", (1...9).map { ["id": .string("c\($0)"), "postId": "p1", "body": .string(mib)] })
        try bind("db3-a")
        assertTooLarge("9 MiB of related rows", {
            try self.shared(Self.post).query(nil, include: [
                Include(type: .hasMany, target: self.shared(Self.comment), foreignKey: "postId", resultKey: "comments"),
            ])
        }) {
            XCTAssertEqual($0.details?["limit"]?.numberValue, 8 * 1024 * 1024)
        }
    }

    // MARK: - Edge 34: the budget is measured with `_related`

    func testARecordOverTheBudgetIsAnsweredAloneButNotWithAnInclude() throws {
        try fixture.seed("db3-a", "Post", [["id": "p9", "body": .string(String(repeating: "y", count: 9 * 1024 * 1024))]])
        try bind("db3-a")
        XCTAssertEqual(try shared(Self.post).query(nil).count, 1, "a single larger record is answered alone")
        assertTooLarge("the same page with `_related`", {
            try self.shared(Self.post).query(nil, include: [
                Include(type: .refersTo, target: self.shared(Self.author), sourceField: "authorId", resultKey: "author"),
            ])
        })
    }

    // MARK: - Behaviour 13: the tree is validated before any statement

    func testAFourthLevelAndAnInvalidSpecAreRefusedBeforeAnyStatement() throws {
        try fixture.seed("db3-a", "Author", [["id": "a1", "name": "Ann"]])
        try fixture.seed("db3-a", "Post", [["id": "p1", "title": "A", "authorId": "a1"]])
        try fixture.seed("db3-a", "Comment", [["id": "c1", "postId": "p1", "authorId": "a1"]])
        try fixture.seed("db3-a", "Reply", [["id": "r1", "commentId": "c1", "authorId": "a1"]])
        try bind("db3-a")
        let author = { (include: [Include]?) in
            Include(type: .refersTo, target: self.shared(Self.author), sourceField: "authorId", resultKey: "author", include: include)
        }
        let replies = { (include: [Include]?) in
            Include(type: .hasMany, target: self.shared(Self.reply), foreignKey: "commentId", resultKey: "replies", include: include)
        }
        let comments = { (include: [Include]?) in
            Include(type: .hasMany, target: self.shared(Self.comment), foreignKey: "postId", resultKey: "comments", include: include)
        }
        let posts = shared(Self.post)

        let depth3 = try posts.query(nil, include: [comments([replies([author(nil)])])])
        let reply = related(depth3[0], "comments")?.arrayValue?.first?["_related"]?["replies"]?.arrayValue?.first
        XCTAssertEqual(reply?["_related"]?["author"]?["name"], "Ann", "a depth-3 spec is answered")

        let trace = try fixture.trace(self)
        let fourth = [comments([replies([author([author(nil)])])])]
        for (label, filter) in [("a matching page", nil), ("an empty page", ["title": "none"] as DocumentFilter?)] {
            assertInvalidInclude(label, "Invalid include: include nests deeper than 3 levels") {
                try posts.query(filter, include: fourth)
            }
            assertInvalidInclude("paged, \(label)", "Invalid include: include nests deeper than 3 levels") {
                try posts.queryPaged(filter, include: fourth)
            }
        }
        assertInvalidInclude("a zero limit", "Invalid include: hasMany limit must be a positive integer") {
            try posts.query(["title": "none"], include: [
                Include(type: .hasMany, target: self.shared(Self.comment), foreignKey: "postId", limit: 0),
            ])
        }
        assertInvalidInclude("a source field that is not an identifier", "Invalid include: refersTo: invalid sourceField 'bad field'") {
            try posts.query(nil, include: [Include(type: .refersTo, target: self.shared(Self.author), sourceField: "bad field")])
        }
        assertInvalidInclude("a missing foreign key", "Invalid include: hasMany: 'foreignKey' is required") {
            try posts.query(nil, include: [Include(type: .hasMany, target: self.shared(Self.comment))])
        }
        assertInvalidInclude("a sort direction", "Invalid include: sort directions must be 1 or -1") {
            try posts.query(nil, include: [
                Include(type: .hasMany, target: self.shared(Self.comment), foreignKey: "postId", sort: ["id": 2]),
            ])
        }
        XCTAssertEqual(trace.viewReads, [], "no statement ran: \(trace.viewReads)")
    }

    // MARK: - Edge 33: a target bound to another db3 never answers for this one

    func testATargetBoundToAnotherDb3AttachesNothingOfIt() throws {
        try fixture.seed("db3-a", "Post", [["id": "p1", "title": "A", "authorId": "b-only"]])
        try fixture.seed("db3-b", "Author", [["id": "b-only", "name": "elsewhere"]])
        try fixture.seed("db3-b", "Comment", [["id": "cb1", "postId": "p1"]])
        try bind("db3-a", "db3-b")
        let authorInB = try XCTUnwrap(shared(Self.author).member(docId: "db3-b"))
        let commentsInB = try XCTUnwrap(shared(Self.comment).member(docId: "db3-b"))
        let rows = try shared(Self.post).query(nil, options: QueryOptions(documents: ["db3-a"]), include: [
            Include(type: .refersTo, target: authorInB, sourceField: "authorId", resultKey: "author"),
            Include(type: .hasMany, target: commentsInB, foreignKey: "postId", resultKey: "comments"),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(related(rows[0], "author"), .null)
        XCTAssertEqual(related(rows[0], "comments"), [])
    }

    // MARK: - Edge 37: a leg into a format-1 target is refused; format 1 is unchanged

    func testALegFromADb3IntoAFormat1TargetIsRefused() throws {
        try fixture.seed("db3-a", "Post", [["id": "p1", "title": "A"]])
        try bind("db3-a")
        let plainComments = shared(Self.comment).connect(docId: "plain-1", doc: YDocument())
        _ = try plainComments.create(id: "pc1", values: ["postId": .string("p1")])
        assertInvalidInclude("a format-1 hasMany target", "Invalid include: target is not in the parent's document") {
            try self.shared(Self.post).query(nil, options: QueryOptions(documents: ["db3-a"]), include: [
                Include(type: .hasMany, target: plainComments, foreignKey: "postId", resultKey: "comments"),
            ])
        }
    }

    func testAFormat1IncludeKeepsItsResolverAndStopsSilentlyAtDepth3() throws {
        let doc = YDocument()
        let posts = shared(Self.post).connect(docId: "plain-1", doc: doc)
        let comments = shared(Self.comment).connect(docId: "plain-1", doc: doc)
        let replies = shared(Self.reply).connect(docId: "plain-1", doc: doc)
        let authors = shared(Self.author).connect(docId: "plain-1", doc: doc)
        _ = try authors.create(id: "a1", values: ["name": .string("Ann")])
        _ = try posts.create(id: "p1", values: ["title": .string("A"), "authorId": .string("a1")])
        _ = try comments.create(id: "c1", values: ["postId": .string("p1"), "authorId": .string("a1")])
        _ = try replies.create(id: "r1", values: ["commentId": .string("c1"), "authorId": .string("a1")])
        let author = { (include: [Include]?) in
            Include(type: .refersTo, target: self.shared(Self.author), sourceField: "authorId", resultKey: "author", include: include)
        }
        let rows = try shared(Self.post).query(nil, include: [
            Include(type: .hasMany, target: shared(Self.comment), foreignKey: "postId", resultKey: "comments", include: [
                Include(type: .hasMany, target: shared(Self.reply), foreignKey: "commentId", resultKey: "replies",
                        include: [author([author(nil)])]),
            ]),
        ])
        let reply = related(rows[0], "comments")?.arrayValue?.first?["_related"]?["replies"]?.arrayValue?.first
        let replyAuthor = reply?["_related"]?["author"]
        XCTAssertEqual(replyAuthor?["name"], "Ann", "three levels resolve")
        XCTAssertNil(replyAuthor?["_related"]?["author"], "the fourth level is not resolved, and nothing throws")
    }
}
