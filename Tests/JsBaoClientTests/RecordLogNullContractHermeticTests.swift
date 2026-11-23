import XCTest
@testable import JsBaoClient

/// #4700 behaviours 5–7, edges 27–28: the db3 null and type contract
/// (`design-docs/db3-null-contract.md`) holds on the Swift store's model API.
/// Every case of `tests/fixtures/db3-null-contract-4694/cases.json`, read by
/// repository path, is answered by `Model.query` through `DynamicModel` and
/// through the cross-document `MultiDocModel`, from the view with the room's
/// statement, its count equal to its rows; the model-free records answer the
/// same. The file's rows are seeded as the room sends them, `stored` taking
/// the place of what a row was written as.
final class RecordLogNullContractHermeticTests: XCTestCase {

    private struct Case {
        let name: String
        let rule: Int
        let filter: DocumentFilter
        let sort: (String, Int)?
        let limit: Int?
        let ordered: Bool
        let expect: [String]
    }

    private struct Contract {
        let model: String
        let rows: [JSONValue]
        let cases: [Case]
    }

    private static func contract() throws -> Contract {
        let text = try ClientSourceText.repoFile("tests/fixtures/db3-null-contract-4694/cases.json")
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let model = try XCTUnwrap(file["model"]?.stringValue)
        let stored = file["stored"]?.objectValue ?? [:]
        let rows = (file["rows"]?.arrayValue ?? []).map { row in
            row["id"]?.stringValue.flatMap { stored[$0] } ?? row
        }
        let cases = try (file["cases"]?.arrayValue ?? []).map { entry -> Case in
            let sort = entry["sort"]?.objectValue?.first.map { ($0.key, Int($0.value.numberValue ?? 1)) }
            return Case(
                name: try XCTUnwrap(entry["name"]?.stringValue),
                rule: Int(try XCTUnwrap(entry["rule"]?.numberValue)),
                filter: entry["filter"]?.objectValue ?? [:],
                sort: sort,
                limit: entry["limit"]?.numberValue.map { Int($0) },
                ordered: entry["ordered"]?.boolValue ?? false,
                expect: (entry["expect"]?.arrayValue ?? []).compactMap(\.stringValue)
            )
        }
        return Contract(model: model, rows: rows, cases: cases)
    }

    private static func schema(_ model: String) -> PrimitiveSchema {
        PrimitiveSchema(name: model, fields: [
            "id": FieldDescriptor(type: .id),
            "s": FieldDescriptor(type: .string),
            "n": FieldDescriptor(type: .number),
            "b": FieldDescriptor(type: .boolean),
            "tags": FieldDescriptor(type: .stringset),
        ])
    }

    private static let document = "db3-contract-4700"

    private var fixture: RecordLogViewFixture!
    private var contract: Contract!

    override func setUp() async throws {
        try await super.setUp()
        contract = try Self.contract()
        fixture = try await RecordLogViewFixture.make("null-contract")
        // The rows reach the store before any model binds, as a catch-up
        // leaves a document a model is then declared on.
        try fixture.seed(Self.document, contract.model, contract.rows)
        try fixture.member(Self.schema(contract.model), Self.document)
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    private var member: DynamicModel {
        get throws { try XCTUnwrap(fixture.shared(Self.schema(contract.model)).member(docId: Self.document)) }
    }

    private var shared: MultiDocModel { fixture.shared(Self.schema(contract.model)) }

    private func ids(_ rows: [[String: JSONValue]]) -> [String] { rows.compactMap { $0["id"]?.stringValue } }

    /// The ids a case answers: in result order when the case is ordered, else sorted.
    private func answered(_ c: Case, _ rows: [[String: JSONValue]]) -> [String] {
        c.ordered ? ids(rows) : ids(rows).sorted()
    }

    private func options(_ c: Case, limit: Int? = nil, cursor: String? = nil, direction: CursorDirection = .forward) -> QueryOptions {
        QueryOptions(sortOrder: c.sort.map { [$0] }, limit: limit, cursor: cursor, direction: direction)
    }

    /// Walk `c` forward by cursor at its page size, then backward from the
    /// last page's `prevCursor`, each backward page in sort order.
    private func walk(_ c: Case, limit: Int, _ page: (QueryOptions) throws -> PagedQueryResult<PrimitiveRow>) throws
        -> (forward: [[String]], backward: [[String]])
    {
        var forward: [PagedQueryResult<PrimitiveRow>] = []
        var cursor: String?
        repeat {
            let next = try page(options(c, limit: limit, cursor: cursor))
            forward.append(next)
            cursor = next.hasMore ? next.nextCursor : nil
        } while cursor != nil && forward.count <= c.expect.count + 1
        var backward: [[String]] = []
        var back = forward.last?.prevCursor
        while let at = back, backward.count <= c.expect.count + 1 {
            let previous = try page(options(c, limit: limit, cursor: at, direction: .backward))
            if previous.data.isEmpty { break }
            backward.append(ids(previous.data.map(\.raw)))
            back = previous.hasMore ? previous.nextCursor : nil
        }
        return (forward.map { ids($0.data.map(\.raw)) }, backward)
    }

    // MARK: - Behaviour 5 (rules 1–9, 11–14) and behaviour 7 (counts)

    func testEveryUnorderedCaseAnswersTheContractOnTheModelAPI() throws {
        let unordered = contract.cases.filter { $0.rule != 10 }
        XCTAssertGreaterThan(unordered.count, 50)
        let records = try fixture.records(Self.document)
        for c in unordered {
            let label = "rule \(c.rule): \(c.name)"
            do {
                XCTAssertEqual(answered(c, try member.query(c.filter)), c.expect, "DynamicModel.query — \(label)")
                XCTAssertEqual(answered(c, try shared.query(c.filter)), c.expect, "MultiDocModel.query — \(label)")
                XCTAssertEqual(try member.count(c.filter), c.expect.count, "DynamicModel.count — \(label)")
                XCTAssertEqual(try shared.count(c.filter), c.expect.count, "MultiDocModel.count — \(label)")
                let page = try records.query(contract.model, c.filter)
                XCTAssertEqual(answered(c, page.data.map(\.raw)), c.expect, "DocumentRecords.query — \(label)")
                XCTAssertEqual(try records.count(contract.model, c.filter), c.expect.count, "DocumentRecords.count — \(label)")
            } catch {
                XCTFail("\(label) threw \(error)")
            }
        }
    }

    /// The plan's named cases, so a regression reads at a glance.
    func testTheStoredJSONTypeDecidesEqualityOnTheModelAPI() throws {
        XCTAssertEqual(ids(try member.query(["n": 5])), ["r04"])
        XCTAssertEqual(ids(try member.query(["n": "5"])), ["r03"])
        XCTAssertEqual(ids(try member.query(["b": true])).sorted(), ["r01", "r04"])
        XCTAssertEqual(ids(try member.query(["n": ["$startsWith": "5"]])).sorted(), ["r03", "r04"])
        XCTAssertEqual(ids(try member.query(["tags": ["$size": 0]])).sorted(), ["r02", "r04"])
    }

    // MARK: - Behaviour 6 (rule 10) and edge 27

    func testEveryOrderedCaseSortsAndWalksBothWaysOnTheModelAPI() throws {
        let ordered = contract.cases.filter { $0.rule == 10 }
        XCTAssertGreaterThanOrEqual(ordered.count, 6)
        for c in ordered {
            let label = "rule 10: \(c.name)"
            do {
                if let limit = c.limit {
                    for (door, page) in [
                        ("DynamicModel", { (o: QueryOptions) in try self.member.queryPaged(c.filter, options: o) }),
                        ("MultiDocModel", { (o: QueryOptions) in try self.shared.queryPaged(c.filter, options: o) }),
                    ] as [(String, (QueryOptions) throws -> PagedQueryResult<PrimitiveRow>)] {
                        let walked = try walk(c, limit: limit, page)
                        XCTAssertEqual(walked.forward.flatMap { $0 }, c.expect, "\(door) forward — \(label)")
                        XCTAssertEqual(walked.forward.count, (c.expect.count + limit - 1) / limit,
                                       "\(door): the last page is the last one read, `hasMore` exact — \(label)")
                        XCTAssertEqual(walked.backward.reversed().flatMap { $0 } + (walked.forward.last ?? []), c.expect,
                                       "\(door) backward — \(label)")
                    }
                } else {
                    XCTAssertEqual(ids(try member.query(c.filter, options: options(c))), c.expect, "DynamicModel — \(label)")
                    XCTAssertEqual(ids(try shared.query(c.filter, options: options(c))), c.expect, "MultiDocModel — \(label)")
                }
                XCTAssertEqual(try member.count(c.filter), c.expect.count, "count — \(label)")
            } catch {
                XCTFail("\(label) threw \(error)")
            }
        }
    }

    // MARK: - Edge 28: set fields on the model API and as stored

    func testADeclaredSetIsAnArrayInCanonicalOrderOnTheModelAPIAndAsStoredWithoutOne() throws {
        try fixture.seed(Self.document, contract.model, [["id": "r10", "s": "f", "tags": ["y", "x"]]])
        let byId = Dictionary(uniqueKeysWithValues: try member.query([:], options: QueryOptions(limit: 100)).map {
            ($0["id"]?.stringValue ?? "", $0)
        })
        XCTAssertEqual(byId["r10"]?["tags"], ["x", "y"], "members in canonical order")
        XCTAssertEqual(byId["r03"]?["tags"], [], "a declared set the row lacks answers []")
        XCTAssertEqual(byId["r01"]?["tags"], ["x", "y"])

        let records = try fixture.records(Self.document)
        let stored = Dictionary(uniqueKeysWithValues: try records.query(contract.model).data.map {
            ($0.raw["id"]?.stringValue ?? "", $0.raw)
        })
        XCTAssertNil(stored["r03"]?["tags"], "the model-free record answers the row as stored")
        XCTAssertEqual(stored["r10"]?["tags"], ["y", "x"])
    }
}
