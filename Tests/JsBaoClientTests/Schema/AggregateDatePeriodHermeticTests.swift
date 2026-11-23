import XCTest
@testable import JsBaoClient
import YSwift

/// A local `aggregate` groups a `date` field by calendar month, quarter or
/// year (`.datePeriod(field:period:)`), answering the rows js-bao's model
/// statics answer for the same stored strings.
///
/// A period level takes the key `<field>_<period>` in a row's `group` and
/// holds `YYYY-MM`, `YYYY-Qn` or `YYYY`, read from the stored text (no
/// time-zone conversion). A missing value, or text that does not begin
/// `YYYY-MM`, is the `null` bucket, and its key is present as `.null`.
///
/// The fixture and expected tables are the ones
/// `tests/unit/workflows/aggregate-date-period-4266.test.ts` asserts for js-bao:
///
/// | id  | categoryId | date                     | amount |
/// |-----|------------|--------------------------|--------|
/// | r1  | food       | 2025-11-03               | -40    |
/// | r2  | food       | 2025-11-28               | -10    |
/// | r3  | food       | 2025-12-15               | -25    |
/// | r4  | salary     | 2025-12-31               | 3000   |
/// | r5  | food       | 2026-01-02T08:15:00.000Z | -30    |
/// | r6  | salary     | 2026-01-31               | 3000   |
/// | r7  | food       | 2026-03-09               | -12    |
/// | r8  | food       | 2026-04-01               | -5     |
/// | r9  | food       | (missing)                | -1     |
/// | r10 | food       | "not a date"             | -2     |
/// | r11 | food       | 2026-10-31               | -7     |
/// | r12 | food       | 2026-11-01               | -9     |
final class AggregateDatePeriodHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "agg_period_ledger",
        fields: [
            "id":         FieldDescriptor(type: .id),
            "categoryId": FieldDescriptor(type: .string),
            "amount":     FieldDescriptor(type: .number),
            "date":       FieldDescriptor(type: .date),
            "when":       FieldDescriptor(type: .string),
            "rank":       FieldDescriptor(type: .number),
            "date_month": FieldDescriptor(type: .string),
            "tags":       FieldDescriptor(type: .stringset),
        ]
    )

    private static let fixture: [(id: String, categoryId: String, date: String?, amount: Double)] = [
        ("r1", "food", "2025-11-03", -40),
        ("r2", "food", "2025-11-28", -10),
        ("r3", "food", "2025-12-15", -25),
        ("r4", "salary", "2025-12-31", 3000),
        ("r5", "food", "2026-01-02T08:15:00.000Z", -30),
        ("r6", "salary", "2026-01-31", 3000),
        ("r7", "food", "2026-03-09", -12),
        ("r8", "food", "2026-04-01", -5),
        ("r9", "food", nil, -1),
        ("r10", "food", "not a date", -2),
        ("r11", "food", "2026-10-31", -7),
        ("r12", "food", "2026-11-01", -9),
    ]

    private static func values(_ row: (id: String, categoryId: String, date: String?, amount: Double))
        -> [String: PrimitiveValue]
    {
        var values: [String: PrimitiveValue] = [
            "categoryId": .string(row.categoryId), "amount": .number(row.amount), "rank": .number(1),
        ]
        if let date = row.date {
            values["date"] = .date(date)
            values["when"] = .string(date)
        }
        return values
    }

    private static let range: DocumentFilter = ["date": ["$gte": "2025-11-01", "$lte": "2026-10-31"]]
    private static let sumAndCount = [
        AggregateOperation(type: .sum, field: "amount"), AggregateOperation(type: .count),
    ]

    private static func options(
        _ groupBy: [AggregateGroupBy], filter: DocumentFilter? = range,
        sort: AggregateSort? = nil, limit: Int? = nil, documents: [String]? = nil
    ) -> AggregateOptions {
        AggregateOptions(
            groupBy: groupBy, operations: sumAndCount, filter: filter,
            sort: sort, limit: limit, documents: documents
        )
    }

    private static func row(
        _ categoryId: String, _ key: String, _ bucket: JSONValue, _ sum: Double, _ count: Double
    ) -> [String: JSONValue] {
        ["group": ["categoryId": .string(categoryId), key: bucket],
         "sum_amount": .number(sum), "count": .number(count)]
    }

    private static let monthRows = [
        row("food", "date_month", "2025-11", -50, 2),
        row("food", "date_month", "2025-12", -25, 1),
        row("salary", "date_month", "2025-12", 3000, 1),
        row("food", "date_month", "2026-01", -30, 1),
        row("salary", "date_month", "2026-01", 3000, 1),
        row("food", "date_month", "2026-03", -12, 1),
        row("food", "date_month", "2026-04", -5, 1),
        row("food", "date_month", "2026-10", -7, 1),
    ]

    private static let quarterRows = [
        row("food", "date_quarter", "2025-Q4", -75, 3),
        row("salary", "date_quarter", "2025-Q4", 3000, 1),
        row("food", "date_quarter", "2026-Q1", -42, 2),
        row("salary", "date_quarter", "2026-Q1", 3000, 1),
        row("food", "date_quarter", "2026-Q2", -5, 1),
        row("food", "date_quarter", "2026-Q4", -7, 1),
    ]

    private static let yearRows = [
        row("food", "date_year", "2025", -75, 3),
        row("salary", "date_year", "2025", 3000, 1),
        row("food", "date_year", "2026", -54, 4),
        row("salary", "date_year", "2026", 3000, 1),
    ]

    /// The unfiltered month rows of `food`: the in-range ones, then
    /// `2026-11` and the `null` bucket (a missing date and "not a date").
    private static let foodMonthsUnfiltered: [[String: JSONValue]] = [
        ["group": ["date_month": "2025-11"], "sum_amount": -50, "count": 2],
        ["group": ["date_month": "2025-12"], "sum_amount": -25, "count": 1],
        ["group": ["date_month": "2026-01"], "sum_amount": -30, "count": 1],
        ["group": ["date_month": "2026-03"], "sum_amount": -12, "count": 1],
        ["group": ["date_month": "2026-04"], "sum_amount": -5, "count": 1],
        ["group": ["date_month": "2026-10"], "sum_amount": -7, "count": 1],
        ["group": ["date_month": "2026-11"], "sum_amount": -9, "count": 1],
        ["group": ["date_month": .null], "sum_amount": -3, "count": 2],
    ]

    /// Rows in a stable order: by every group value, `null` last.
    private func sorted(_ rows: [[String: JSONValue]]) -> [[String: JSONValue]] {
        func key(_ row: [String: JSONValue]) -> String {
            let group = row["group"]?.objectValue ?? [:]
            return group.keys.sorted().map { "\($0)=\(group[$0]?.stringValue ?? "~null")" }
                .joined(separator: "|")
        }
        return rows.sorted { key($0) < key($1) }
    }

    private func assertRows(
        _ actual: [[String: JSONValue]], _ expected: [[String: JSONValue]],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(sorted(actual), sorted(expected), file: file, line: line)
    }

    // MARK: - Fixtures

    private func singleDocument() throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: Self.schema)
        for row in Self.fixture { _ = try model.create(id: row.id, values: Self.values(row)) }
        return model
    }

    /// The fixture split over two ordinary documents: r1–r6 in A, r7–r12 in B.
    private func twoDocuments() throws -> (MultiDocModel, [String]) {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: Self.schema)
        let a = multi.connect(docId: "docA", doc: YDocument())
        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        for (index, row) in Self.fixture.enumerated() {
            _ = try (index < 6 ? a : b).create(id: row.id, values: Self.values(row))
        }
        return (multi, ["docA", "docB"])
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/rl-aggperiod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// The fixture split over two record-log (format-3) documents in one
    /// store, as above.
    private func twoRecordLogDocuments() async throws -> (MultiDocModel, [String]) {
        let provider = try await makeProvider()
        let shared = MultiDocModel(schema: Self.schema)
        var ids: [String] = []
        for suffix in ["a", "b"] {
            let documentId = "aggperiod-\(suffix)-\(UUID().uuidString.prefix(8))"
            let binding = try RecordLogDocumentBinding(
                host: provider, documentId: documentId, clientId: "client-1",
                logger: Logger(level: .none)
            )
            try shared.connect(docId: documentId, doc: YDocument()).bindRecordLog(binding)
            ids.append(documentId)
        }
        for (index, row) in Self.fixture.enumerated() {
            _ = try XCTUnwrap(shared.member(docId: ids[index < 6 ? 0 : 1]))
                .create(id: row.id, values: Self.values(row))
        }
        return (shared, ids)
    }

    private let month = AggregateGroupBy.datePeriod(field: "date", period: .month)

    // MARK: - One document

    func testMonthQuarterAndYearRowsOnOneDocument() throws {
        let model = try singleDocument()
        assertRows(try model.aggregate(Self.options(["categoryId", month])), Self.monthRows)
        assertRows(
            try model.aggregate(Self.options(["categoryId", .datePeriod(field: "date", period: .quarter)])),
            Self.quarterRows
        )
        assertRows(
            try model.aggregate(Self.options(["categoryId", .datePeriod(field: "date", period: .year)])),
            Self.yearRows
        )
    }

    func testTheNullBucketCarriesItsKeyAsNull() throws {
        let rows = try singleDocument().aggregate(Self.options([month], filter: ["categoryId": "food"]))
        assertRows(rows, Self.foodMonthsUnfiltered)
        let nullRow = try XCTUnwrap(rows.first { $0["group"]?["date_month"] == .null })
        XCTAssertTrue(nullRow["group"]?.objectValue?.keys.contains("date_month") ?? false)
        XCTAssertEqual(nullRow["sum_amount"], -3)
        XCTAssertEqual(nullRow["count"], 2)
    }

    func testSortingByThePeriodKeyIsChronological() throws {
        let model = try singleDocument()
        let ascending = try model.aggregate(Self.options(
            ["categoryId", month], sort: AggregateSort(field: "date_month", direction: 1)
        ))
        let months: [JSONValue?] = ["2025-11", "2025-12", "2025-12", "2026-01", "2026-01", "2026-03", "2026-04", "2026-10"]
        XCTAssertEqual(ascending.map { $0["group"]?["date_month"] }, months)
        let latest = try model.aggregate(Self.options(
            ["categoryId", month], sort: AggregateSort(field: "date_month", direction: -1), limit: 3
        ))
        XCTAssertEqual(latest, [
            Self.row("food", "date_month", "2026-10", -7, 1),
            Self.row("food", "date_month", "2026-04", -5, 1),
            Self.row("food", "date_month", "2026-03", -12, 1),
        ])
    }

    /// A date field `sum` grouped by month is keyed `sum_month`, the key of
    /// `sum` over the number field `month` too; the sort names the operation,
    /// as in js-bao.
    func testSortingByAKeyThatIsBothAPeriodAndAnOperationUsesTheOperation() throws {
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "agg_period_clashing",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "sum":   FieldDescriptor(type: .date),
                "month": FieldDescriptor(type: .number),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: schema)
        _ = try model.create(id: "s1", values: ["sum": .date("2026-01-10"), "month": .number(100)])
        _ = try model.create(id: "s2", values: ["sum": .date("2026-02-10"), "month": .number(1)])
        let rows = try model.aggregate(AggregateOptions(
            groupBy: [.datePeriod(field: "sum", period: .month)],
            operations: [AggregateOperation(type: .sum, field: "month")],
            sort: AggregateSort(field: "sum_month", direction: 1), limit: 1
        ))
        XCTAssertEqual(rows, [["group": ["sum_month": "2026-02"], "sum_month": 1]])
    }

    // MARK: - Several documents

    func testMonthAndQuarterRowsAcrossTwoDocuments() throws {
        let (multi, ids) = try twoDocuments()
        assertRows(try multi.aggregate(Self.options(["categoryId", month])), Self.monthRows)
        assertRows(
            try multi.aggregate(Self.options(["categoryId", .datePeriod(field: "date", period: .quarter)])),
            Self.quarterRows
        )
        assertRows(
            try multi.aggregate(Self.options(["categoryId", .datePeriod(field: "date", period: .year)])),
            Self.yearRows
        )
        assertRows(
            try multi.aggregate(Self.options([month], filter: ["categoryId": "food"], documents: ids)),
            Self.foodMonthsUnfiltered
        )
    }

    func testMonthRowsAcrossTwoRecordLogDocuments() async throws {
        let (shared, ids) = try await twoRecordLogDocuments()
        assertRows(try shared.aggregate(Self.options(["categoryId", month])), Self.monthRows)
        let rows = try shared.aggregate(Self.options([month], filter: ["categoryId": "food"]))
        assertRows(rows, Self.foodMonthsUnfiltered)
        XCTAssertTrue(
            rows.contains { $0["group"]?.objectValue?["date_month"] == .null },
            "the null bucket's key is present as .null on a record-log document too"
        )
        XCTAssertEqual(try shared.aggregate(Self.options([month], documents: [])).count, 0)
        assertRows(
            try shared.aggregate(Self.options(["categoryId", month], documents: [ids[1]])),
            [
                Self.row("food", "date_month", "2026-03", -12, 1),
                Self.row("food", "date_month", "2026-04", -5, 1),
                Self.row("food", "date_month", "2026-10", -7, 1),
            ]
        )
    }

    // MARK: - Field types and keys

    func testAStringFieldIsAccepted() throws {
        let rows = try singleDocument().aggregate(
            Self.options(["categoryId", .datePeriod(field: "when", period: .month)])
        )
        assertRows(rows, Self.monthRows.map { row in
            var group = row["group"]?.objectValue ?? [:]
            group["when_month"] = group.removeValue(forKey: "date_month")
            var renamed = row
            renamed["group"] = .object(group)
            return renamed
        })
    }

    func testANumberStringSetOrUnknownFieldIsRefused() throws {
        let model = try singleDocument()
        let (multi, _) = try twoDocuments()
        for (field, message) in [
            ("rank", "Field 'rank' is not a date or string field but used in period groupBy"),
            ("tags", "Field 'tags' is not a date or string field but used in period groupBy"),
            ("nope", "Unknown field 'nope' in period groupBy"),
        ] {
            let options = Self.options([.datePeriod(field: field, period: .month)])
            for aggregate in [model.aggregate, multi.aggregate] {
                XCTAssertThrowsError(try aggregate(options)) { error in
                    XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
                    XCTAssertEqual((error as? JsBaoError)?.message, message)
                }
            }
        }
    }

    /// The collision rule in force for every level kind: two levels sharing a
    /// key are refused (`Ambiguous aggregation group keys`), never suffixed.
    func testTwoLevelsSharingAPeriodKeyAreRefused() throws {
        let model = try singleDocument()
        for groupBy: [AggregateGroupBy] in [["date_month", month], [month, month]] {
            XCTAssertThrowsError(try model.aggregate(Self.options(groupBy))) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
                XCTAssertEqual(
                    (error as? JsBaoError)?.message,
                    "Ambiguous aggregation group keys: 'date_month' names more than one groupBy level"
                )
            }
        }
        let both = try model.aggregate(Self.options(
            [month, .datePeriod(field: "date", period: .year)], filter: ["categoryId": "salary"]
        ))
        assertRows(both, [
            ["group": ["date_month": "2025-12", "date_year": "2025"], "sum_amount": 3000, "count": 1],
            ["group": ["date_month": "2026-01", "date_year": "2026"], "sum_amount": 3000, "count": 1],
        ])
    }

    /// The bucket expression is js-bao's, character for character.
    func testTheBucketExpressionMatchesJsBao() {
        let column = "\"t\".\"date\""
        let guardText = "CASE WHEN \(column) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]*' THEN"
        XCTAssertEqual(
            QueryTranslator.periodBucketSQL(column: column, period: .month),
            "\(guardText) substr(\(column), 1, 7) ELSE NULL END"
        )
        XCTAssertEqual(
            QueryTranslator.periodBucketSQL(column: column, period: .quarter),
            "\(guardText) substr(\(column), 1, 4) || '-Q' || ((CAST(substr(\(column), 6, 2) AS INTEGER) + 2) / 3) ELSE NULL END"
        )
        XCTAssertEqual(
            QueryTranslator.periodBucketSQL(column: column, period: .year),
            "\(guardText) substr(\(column), 1, 4) ELSE NULL END"
        )
    }

    /// An ordinary `query` is untouched: a record without a date has no
    /// `date` key in its row.
    func testAnOrdinaryQueryStillOmitsAMissingDate() throws {
        let rows = try singleDocument().query(["id": "r9"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0]["date"])
    }
}
