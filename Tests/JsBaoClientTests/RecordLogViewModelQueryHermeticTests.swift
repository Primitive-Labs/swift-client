import XCTest
import YSwift
@testable import JsBaoClient

/// #4700 behaviours 8–10, edges 29–30: the model API reads a db3 from
/// `record_log_view` with the room's statement and the db3 limits.
///
/// - Several db3s on one provider answer one statement, ordered by the sort,
///   then `_id`, then `doc_id`; a scope mixing a format-1 member is refused.
/// - A page answers 100 records when no `limit` is sent, refuses a `limit`
///   outside 1 to 10,000, and ends before the record whose JSON would take it
///   past 8 MiB (a single larger record is answered alone).
/// - The cursor carries the document under `_tiebreak:doc_id`, a key no
///   record field can take.
/// - A name that is not an identifier is refused before any statement.
final class RecordLogViewModelQueryHermeticTests: XCTestCase {

    private static let schema = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id),
        "title": FieldDescriptor(type: .string),
        "rank": FieldDescriptor(type: .number),
        "body": FieldDescriptor(type: .string),
    ])

    private static let limitMessage = "Invalid options.limit: must be an integer from 1 to 10000"

    private var fixture: RecordLogViewFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("view-model-query")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    private func ids(_ rows: [[String: JSONValue]]) -> [String] { rows.compactMap { $0["id"]?.stringValue } }
    private func ids(_ page: PagedQueryResult<PrimitiveRow>) -> [String] { ids(page.data.map(\.raw)) }

    private func cursorPayload(_ cursor: String?) -> JSONValue? {
        cursor.flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONCoding.decodeData(JSONValue.self, from: $0) }
    }

    private func assertRefusedLimit(_ label: String, _ body: () throws -> Any) {
        XCTAssertThrowsError(try body(), label) { error in
            let refusal = error as? JsBaoError
            XCTAssertEqual(refusal?.code, .invalidArgument, "\(label): \(error)")
            XCTAssertEqual(refusal?.message, Self.limitMessage, label)
        }
    }

    // MARK: - Behaviour 8: several db3s in one statement

    func testTwoDb3sAnswerOneStatementOrderedBySortThenIdThenDocument() throws {
        try fixture.seed("db3-a", "Note", [
            ["id": "n1", "title": "a1", "rank": 2], ["id": "n2", "title": "a2", "rank": 1],
            ["id": "same", "title": "a-same", "rank": 1],
        ])
        try fixture.seed("db3-b", "Note", [
            ["id": "m1", "title": "b1", "rank": 3], ["id": "same", "title": "b-same", "rank": 1],
        ])
        try fixture.member(Self.schema, "db3-a")
        try fixture.member(Self.schema, "db3-b")
        let shared = fixture.shared(Self.schema)
        let trace = try fixture.trace(self)

        let rows = try shared.query(nil, options: QueryOptions(sortOrder: [("rank", 1)]))
        XCTAssertEqual(ids(rows), ["n2", "same", "same", "n1", "m1"])
        XCTAssertEqual(rows.map { $0["_meta_doc_id"]?.stringValue }, ["db3-a", "db3-a", "db3-b", "db3-a", "db3-b"],
                       "each row answered with its own document")
        XCTAssertEqual(rows.map { $0["title"]?.stringValue }, ["a2", "a-same", "b-same", "a1", "b1"])
        XCTAssertEqual(trace.viewReads.count, 1, "one statement: \(trace.statements)")
        XCTAssertTrue(trace.viewReads.first?.contains("doc_id IN") ?? false, "\(trace.viewReads)")

        // Paged, the walk crosses the two documents' equal ids once each.
        var walked: [String] = []
        var cursor: String?
        repeat {
            let page = try shared.queryPaged(nil, options: QueryOptions(sortOrder: [("rank", 1)], limit: 2, cursor: cursor))
            walked += page.data.map { "\($0.raw["_meta_doc_id"]?.stringValue ?? "")/\($0.raw["id"]?.stringValue ?? "")" }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil && walked.count <= 5
        XCTAssertEqual(walked, ["db3-a/n2", "db3-a/same", "db3-b/same", "db3-a/n1", "db3-b/m1"])

        trace.clear()
        XCTAssertEqual(try shared.count(["rank": 1]), 3)
        let groups = try shared.aggregate(AggregateOptions(groupBy: ["rank"], operations: [AggregateOperation(type: .count)]))
        XCTAssertEqual(groups.map { $0["count"]?.numberValue }, [3, 1, 1])
        XCTAssertEqual(trace.viewReads.count, 2, "one statement each: \(trace.statements)")

        let scoped = try shared.query(nil, options: QueryOptions(sortOrder: [("rank", 1)], documents: ["db3-b"]))
        XCTAssertEqual(ids(scoped), ["same", "m1"])
    }

    func testAFormat1MemberBesideADb3IsRefusedAndAFormat1ScopeRunsOnTheMirror() throws {
        try fixture.seed("db3-a", "Note", [["id": "n1", "title": "a1", "rank": 1]])
        try fixture.member(Self.schema, "db3-a")
        let shared = fixture.shared(Self.schema)
        let plain = shared.connect(docId: "plain-1", doc: YDocument())
        _ = try plain.create(id: "p1", values: ["title": .string("plain"), "rank": .number(9)])

        XCTAssertThrowsError(try shared.query(nil)) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .format2QueryScope, "\(error)")
        }
        XCTAssertThrowsError(try shared.count(nil)) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .format2QueryScope, "\(error)")
        }
        XCTAssertEqual(ids(try shared.query(nil, options: QueryOptions(documents: ["plain-1"]))), ["p1"])
        XCTAssertEqual(ids(try shared.query(nil, options: QueryOptions(documents: ["db3-a"]))), ["n1"])
    }

    // MARK: - Behaviour 9: the default page and the limit's range

    func testAPageAnswers100RecordsByDefaultAndRefusesALimitOutsideOneTo10000() throws {
        try fixture.seed("db3-a", "Note", (0..<101).map { i in
            ["id": .string(String(format: "n%03d", i)), "title": .string("t\(i)"), "rank": .number(Double(i))]
        })
        let member = try fixture.member(Self.schema, "db3-a")
        let shared = fixture.shared(Self.schema)
        let records = try fixture.records("db3-a")

        XCTAssertEqual(try member.query(nil).count, 100, "Model.query")
        let paged = try member.queryPaged(nil)
        XCTAssertEqual(paged.data.count, 100, "Model.queryPaged")
        XCTAssertTrue(paged.hasMore)
        XCTAssertNotNil(paged.nextCursor)
        XCTAssertEqual(try shared.query(nil).count, 100, "MultiDocModel.query")
        let sharedPage = try shared.queryPaged(nil)
        XCTAssertEqual(sharedPage.data.count, 100)
        XCTAssertTrue(sharedPage.hasMore)
        let free = try records.query("Note")
        XCTAssertEqual(free.data.count, 100, "DocumentRecords.query")
        XCTAssertTrue(free.hasMore)
        XCTAssertEqual(ids(try records.query("Note", options: QueryOptions(cursor: free.nextCursor))), ["n100"])

        for limit in [0, -1, 10_001] {
            assertRefusedLimit("Model.query limit \(limit)") { try member.query(nil, options: QueryOptions(limit: limit)) }
            assertRefusedLimit("Model.queryPaged limit \(limit)") { try member.queryPaged(nil, options: QueryOptions(limit: limit)) }
            assertRefusedLimit("MultiDocModel.query limit \(limit)") { try shared.query(nil, options: QueryOptions(limit: limit)) }
            assertRefusedLimit("DocumentRecords.query limit \(limit)") {
                try records.query("Note", options: QueryOptions(limit: limit))
            }
        }
        let all = try member.queryPaged(nil, options: QueryOptions(limit: 10_000))
        XCTAssertEqual(all.data.count, 101)
        XCTAssertFalse(all.hasMore)
        XCTAssertEqual(try member.count(nil), 101, "a count consumes every row")
    }

    // MARK: - Behaviour 10: the byte budget ends a page

    func testAPageEndsBeforeTheRecordThatTakesItPast8MiBAndALargerRecordIsAnsweredAlone() throws {
        let mib = 1024 * 1024
        let body = { (bytes: Int) in JSONValue.string(String(repeating: "x", count: bytes)) }
        try fixture.seed("db3-a", "Note", [
            ["id": "a0", "body": body(9 * mib)],
            ["id": "b1", "body": body(3 * mib)], ["id": "b2", "body": body(3 * mib)], ["id": "b3", "body": body(3 * mib)],
            ["id": "c4", "title": "small"],
        ])
        let member = try fixture.member(Self.schema, "db3-a")
        let records = try fixture.records("db3-a")

        for (door, page) in [
            ("Model.queryPaged", { (cursor: String?) in try member.queryPaged(nil, options: QueryOptions(cursor: cursor)) }),
            ("DocumentRecords.query", { (cursor: String?) in
                let free = try records.query("Note", options: QueryOptions(cursor: cursor))
                return PagedQueryResult(data: free.data, nextCursor: free.nextCursor, prevCursor: free.prevCursor, hasMore: free.hasMore)
            }),
        ] as [(String, (String?) throws -> PagedQueryResult<PrimitiveRow>)] {
            var pages: [[String]] = []
            var cursor: String?
            repeat {
                let next = try page(cursor)
                pages.append(ids(next))
                cursor = next.hasMore ? next.nextCursor : nil
            } while cursor != nil && pages.count < 6
            XCTAssertEqual(pages, [["a0"], ["b1", "b2"], ["b3", "c4"]],
                           "\(door): a 9 MiB record alone, then two 3 MiB records a page")
        }
    }

    // MARK: - Edge 28 and behaviour 6: a set field's cursor holds the stored value

    /// The model API answers an absent or null set as `[]` and a set in
    /// canonical order, but the statement sorts the stored value: a cursor
    /// minted from the answered row would page past every remaining record
    /// (finding 4700-I1). It carries what the view stores, as js-bao's does.
    func testACursorOnASetFieldCarriesTheStoredValueNotTheAnsweredOne() throws {
        let schema = PrimitiveSchema(name: "Tagged", fields: [
            "id": FieldDescriptor(type: .id),
            "tags": FieldDescriptor(type: .stringset),
        ])
        try fixture.seed("db3-a", "Tagged", [
            ["id": "t1"], ["id": "t2", "tags": nil], ["id": "t3", "tags": ["x"]],
            ["id": "t4", "tags": ["b", "a"]], ["id": "t5", "tags": ["c"]],
        ])
        let member = try fixture.member(schema, "db3-a")
        let records = try fixture.records("db3-a")
        let sorted = { (cursor: String?, direction: CursorDirection) in
            QueryOptions(sortOrder: [("tags", 1)], limit: 1, cursor: cursor, direction: direction)
        }
        // Nulls first, then the stored JSON text: `["b","a"]` < `["c"]` < `["x"]`.
        let expected = ["t1", "t2", "t4", "t5", "t3"]

        var forward: [PagedQueryResult<PrimitiveRow>] = []
        var cursor: String?
        repeat {
            let page = try member.queryPaged(nil, options: sorted(cursor, .forward))
            forward.append(page)
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil && forward.count <= expected.count
        XCTAssertEqual(forward.flatMap { ids($0) }, expected, "the forward walk answers every record once")
        XCTAssertEqual(forward.first?.data.first?.raw["tags"], .array([]), "an absent set is answered []")

        var backward: [String] = []
        var back = forward.last?.prevCursor
        while let at = back, backward.count <= expected.count {
            let page = try member.queryPaged(nil, options: sorted(at, .backward))
            if page.data.isEmpty { break }
            backward = ids(page) + backward
            back = page.hasMore ? page.nextCursor : nil
        }
        XCTAssertEqual(backward, Array(expected.dropLast()), "the backward walk answers every earlier record once")

        // The typed and model-free readers mint the same cursor at each boundary.
        var free: String?
        var typed: String?
        for _ in expected.dropLast() {
            let typedPage = try member.queryPaged(nil, options: sorted(typed, .forward))
            let freePage = try records.query("Tagged", options: sorted(free, .forward))
            XCTAssertEqual(cursorPayload(typedPage.nextCursor), cursorPayload(freePage.nextCursor), "at \(ids(typedPage))")
            typed = typedPage.nextCursor
            free = freePage.nextCursor
        }
    }

    // MARK: - Edge 29: a field named doc_id still gets the document tie-break

    func testASortOnAFieldNamedDocIdKeepsTheDocumentTieBreak() throws {
        try fixture.seed("db3-a", "Memo", [
            ["id": "m1", "doc_id": "z"], ["id": "m2", "doc_id": "a"], ["id": "m3", "doc_id": "a"], ["id": "m4"],
        ])
        let records = try fixture.records("db3-a")
        let first = try records.query("Memo", options: QueryOptions(sortOrder: [("doc_id", 1)], limit: 1))
        let payload = cursorPayload(first.nextCursor)
        XCTAssertEqual(payload?["sortFields"], ["doc_id", "id", "_tiebreak:doc_id"])
        XCTAssertEqual(payload?["values"]?["_tiebreak:doc_id"], "db3-a")
        var walked = ids(first.data.map(\.raw))
        var cursor = first.nextCursor
        while let at = cursor, walked.count <= 4 {
            let page = try records.query("Memo", options: QueryOptions(sortOrder: [("doc_id", 1)], limit: 1, cursor: at))
            walked += ids(page.data.map(\.raw))
            cursor = page.hasMore ? page.nextCursor : nil
        }
        XCTAssertEqual(walked, ["m4", "m2", "m3", "m1"])
    }

    // MARK: - Edge 30: a name that is not an identifier

    func testANameThatIsNotAnIdentifierIsRefusedBeforeAnyStatement() throws {
        try fixture.seed("db3-a", "Note", [["id": "n1", "title": "a1", "rank": 1]])
        let member = try fixture.member(Self.schema, "db3-a")
        let shared = fixture.shared(Self.schema)
        let trace = try fixture.trace(self)
        func refused(_ label: String, _ body: () throws -> Any) {
            XCTAssertThrowsError(try body(), label) { error in
                let refusal = error as? JsBaoError
                XCTAssertEqual(refusal?.code, .invalidArgument, "\(label): \(error)")
                XCTAssertTrue(refusal?.message.contains("Identifier \"bad field\" must match") ?? false, "\(label): \(error)")
            }
        }
        refused("query") { try member.query(["bad field": 1]) }
        refused("shared query") { try shared.query(["bad field": 1]) }
        refused("count") { try member.count(["bad field": 1]) }
        refused("sort") { try member.query(nil, options: QueryOptions(sortOrder: [("bad field", 1)])) }
        refused("aggregate") { try member.aggregate(AggregateOptions(groupBy: ["bad field"], operations: [AggregateOperation(type: .count)])) }
        refused("aggregate operation") {
            try member.aggregate(AggregateOptions(operations: [AggregateOperation(type: .sum, field: "bad field")]))
        }
        XCTAssertEqual(trace.viewReads, [], "nothing read the view")
    }
}
