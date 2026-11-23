import XCTest
import YSwift
@testable import JsBaoClient

/// The model API's db3 scope and residency rules on the paths beside the
/// filtered read:
///
/// - Finding 4701-C02: an explicitly empty `db3` scope answers nothing on the
///   in-memory mirror too (as `documents: []` does), for query, paging,
///   includes, count and aggregate, while a format-1 document is connected.
/// - Finding 4701-C03: a bound db3 whose rows have not loaded here (not
///   resident) answers no unique-key lookup and no cross-document upsert
///   search, as it answers no query.
final class Db3ScopeResidencyHermeticTests: XCTestCase {

    private static let schema = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id),
        "title": FieldDescriptor(type: .string),
        "slug": FieldDescriptor(type: .string, unique: true),
        "rank": FieldDescriptor(type: .number),
    ])

    private var fixture: RecordLogViewFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("db3-scope-residency")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    private func ids(_ rows: [[String: JSONValue]]) -> [String] { rows.compactMap { $0["id"]?.stringValue } }

    // MARK: - 4701-C02

    func testAnEmptyDb3ScopeAnswersNothingFromTheFormatOneMirror() throws {
        let shared = fixture.shared(Self.schema)
        let plain = shared.connect(docId: "plain-1", doc: YDocument())
        _ = try plain.create(id: "p1", values: ["title": .string("plain"), "rank": .number(9)])
        XCTAssertEqual(ids(try shared.query(nil, options: nil)), ["p1"], "the format-1 row is there unscoped")

        let empty = QueryOptions(db3: [])
        XCTAssertEqual(ids(try shared.query(nil, options: empty)), [])
        XCTAssertEqual(ids(try shared.query(nil, options: empty, include: [])), [])
        XCTAssertEqual(ids(try shared.queryPaged(nil, options: empty).data.map(\.raw)), [])
        XCTAssertEqual(ids(try shared.queryPaged(nil, options: empty, include: []).data.map(\.raw)), [])
        XCTAssertEqual(try shared.count(nil, options: empty), 0)

        let operations = [AggregateOperation(type: .count)]
        let unscoped = try shared.aggregate(AggregateOptions(operations: operations))
        let byDocuments = try shared.aggregate(AggregateOptions(operations: operations, documents: []))
        XCTAssertNotEqual(unscoped, byDocuments, "the empty documents scope narrows the aggregate")
        XCTAssertEqual(try shared.aggregate(AggregateOptions(operations: operations, db3: [])), byDocuments)
    }

    // MARK: - 4701-C03

    func testANonResidentDb3AnswersNoUniqueLookupAndNoUpsertSearch() throws {
        let constraint = try XCTUnwrap(Self.schema.resolvedUniqueConstraints.first?.name)
        try fixture.seed("db3-partial", "Note", [["id": "r1", "title": "partial", "slug": "one"]])
        let partial = try fixture.open("db3-partial")
        // Bound, its load not completed here: not resident.
        partial.createdLocally = false
        XCTAssertFalse(partial.isResident)
        try fixture.member(Self.schema, "db3-partial")
        try fixture.member(Self.schema, "db3-whole")
        let shared = fixture.shared(Self.schema)

        XCTAssertNil(try shared.findByUnique(constraint: constraint, values: [.string("one")]))
        XCTAssertEqual(ids(try shared.query(nil, options: nil)), [], "the query leaves it out as well")

        let upsert = try shared.upsertByUnique(
            constraint: constraint, data: ["slug": .string("one"), "title": .string("whole")],
            id: "w1", targetDocId: "db3-whole"
        )
        XCTAssertTrue(upsert.wasCreated, "the partial db3's row was not found")
        XCTAssertEqual(upsert.record.id, "w1")

        // Resident, it answers again.
        partial.createdLocally = true
        let found = try XCTUnwrap(shared.findByUnique(constraint: constraint, values: [.string("one")]))
        XCTAssertEqual(found.docId, "db3-partial")
    }
}
