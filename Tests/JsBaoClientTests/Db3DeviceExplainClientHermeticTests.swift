import XCTest
@testable import JsBaoClient

/// #5241 behaviors 17 and 18 through `client.db3.records(id)` (Swift),
/// and edge case D: `DocumentRecords.explain(_:_:)` explains a read of the
/// bound copy in the server explain's shape, throws a refusal as `JsBaoError`
/// with its code and `details["reason"]`, and is refused as `query` is when
/// the copy's rows have not loaded here.
final class Db3DeviceExplainClientHermeticTests: XCTestCase {

    private var fixture: RecordLogViewFixture!
    private static let db3 = "01JD5241EXPLA1NCL1ENT0000A"

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("explain-client")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    private func seeded() throws -> DocumentRecords {
        let binding = try fixture.open(Self.db3)
        try fixture.seed(Self.db3, "Note", (0..<60).map { n in
            .object(["id": .string("n\(n)"), "title": .string("note \(n)"), "year": .number(Double(2000 + n % 12))])
        })
        try binding.store.syncIndexes([
            RecordLogIndexEntry(name: "idx_records_note_year", model: "Note", fields: ["year"], unique: false, on: .device),
        ])
        return try fixture.records(Self.db3)
    }

    func testExplainAnswersTheServersShapeForcedAndNot() throws {
        let records = try seeded()
        let plain = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["year": 2003]))
        XCTAssertEqual(plain.indexes, ["idx_records_note_year"])
        XCTAssertEqual(plain.scanned, [])
        XCTAssertEqual(plain.answered, 5)
        XCTAssertEqual(plain.cost, Db3ExplainCost(rowsRead: nil, rowsWritten: nil))
        let forced = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["year": 2003], index: "idx_records_note_year"))
        XCTAssertEqual(forced.index, "idx_records_note_year")
        XCTAssertEqual(forced.indexes, ["idx_records_note_year"])
        let none = try records.explain("Note", Db3ExplainRequest(op: .count, filter: ["year": 2003], index: "none"))
        XCTAssertEqual(none.indexes, [])
        XCTAssertEqual(none.scanned, ["Note"])
        XCTAssertEqual(none.answered, 5)
        XCTAssertEqual(none.answered, try records.count("Note", ["year": 2003]))
    }

    func testARefusalIsAJsBaoErrorWithItsCodeAndReason() throws {
        let records = try seeded()
        do {
            _ = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["title": "note 1"], index: "idx_records_note_year"))
            XCTFail("a field index on other fields is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3IndexCannotServe)
            XCTAssertEqual(error.details?["reason"], "fields")
            XCTAssertEqual(error.details?["index"], "idx_records_note_year")
            XCTAssertEqual(error.details?["model"], "Note")
        }
        do {
            _ = try records.explain("Note", Db3ExplainRequest(op: .query, index: "idx_nope"))
            XCTFail("an unknown name is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3IndexNotFound)
        }
    }

    func testEdgeCaseDExplainIsRefusedAsAQueryIsWhenTheRowsHaveNotLoaded() throws {
        let binding = try fixture.open(Self.db3)
        let records = DocumentRecords(documentId: Self.db3, readable: { throw db3NotResidentError([Self.db3]) }, binding: { binding })
        for read in [{ _ = try records.query("Note") }, { _ = try records.explain("Note", Db3ExplainRequest(op: .query)) }] as [() throws -> Void] {
            do {
                try read()
                XCTFail("refused")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .db3NotResident)
            }
        }
    }
}
