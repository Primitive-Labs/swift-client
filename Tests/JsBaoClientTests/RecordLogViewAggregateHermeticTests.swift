import XCTest
@testable import JsBaoClient

/// #4700 behaviours 11–12: `Model.aggregate` on a db3 answers from
/// `record_log_view` with the room's statement: a plain field groups by the
/// stored value (null and absent one group), a declared set field is a facet
/// (one row per member), a membership groups by whether the array holds the
/// member, a period buckets an ISO string; count, sum, avg, min and max over
/// the stored values; `sort` and `limit`, the limit in 1 to 10,000; rows whose
/// JSON passes 8 MiB are refused `DB3_PAGE_TOO_LARGE`, never cut. Expected rows
/// are written here, not compared between doors.
final class RecordLogViewAggregateHermeticTests: XCTestCase {

    private static let schema = PrimitiveSchema(name: "Task", fields: [
        "id": FieldDescriptor(type: .id),
        "status": FieldDescriptor(type: .string),
        "points": FieldDescriptor(type: .number),
        "due": FieldDescriptor(type: .string),
        "tags": FieldDescriptor(type: .stringset),
    ])

    private var fixture: RecordLogViewFixture!
    private var member: DynamicModel!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("view-aggregate")
        // `t2` holds its points as the string "5": the stored type stays.
        try fixture.seed("db3-a", "Task", [
            ["id": "t1", "status": "open", "points": 3, "due": "2026-01-15", "tags": ["a", "b"]],
            ["id": "t2", "status": "open", "points": "5", "due": "2026-02-03", "tags": ["b"]],
            ["id": "t3", "status": "done", "points": 2, "due": "2026-04-30", "tags": []],
            ["id": "t4", "status": nil, "points": 1, "due": "2025-12-01"],
            ["id": "t5", "points": 4, "due": "bad", "tags": ["a"]],
        ])
        member = try fixture.member(Self.schema, "db3-a")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    private func groups(_ rows: [[String: JSONValue]], _ key: String) -> [JSONValue?] {
        rows.map { $0["group"]?[key] }
    }

    private func numbers(_ rows: [[String: JSONValue]], _ key: String) -> [Double?] {
        rows.map { $0[key]?.numberValue }
    }

    // MARK: - Behaviour 11

    func testAPlainFieldGroupsByTheStoredValueAndSumsTheStoredNumbers() throws {
        let rows = try member.aggregate(AggregateOptions(
            groupBy: ["status"],
            operations: [AggregateOperation(type: .count), AggregateOperation(type: .sum, field: "points")],
            sort: AggregateSort(field: "status", direction: 1)
        ))
        XCTAssertEqual(groups(rows, "status"), [.null, "done", "open"], "null and absent are one group")
        XCTAssertEqual(numbers(rows, "count"), [2, 1, 2])
        XCTAssertEqual(numbers(rows, "sum_points"), [5, 2, 8], "the stored \"5\" is summed as SQLite reads it")
    }

    func testCountSumAvgMinAndMaxOverTheStoredValues() throws {
        let all = try member.aggregate(AggregateOptions(operations: [
            AggregateOperation(type: .count), AggregateOperation(type: .sum, field: "points"),
            AggregateOperation(type: .avg, field: "points"), AggregateOperation(type: .min, field: "points"),
        ]))
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?["count"]?.numberValue, 5)
        XCTAssertEqual(all.first?["sum_points"]?.numberValue, 15)
        XCTAssertEqual(all.first?["avg_points"]?.numberValue, 3)
        XCTAssertEqual(all.first?["min_points"]?.numberValue, 1)
        XCTAssertEqual(all.first?["group"], [:])
        let numeric = try member.aggregate(AggregateOptions(
            operations: [AggregateOperation(type: .max, field: "points")], filter: ["id": ["$ne": "t2"]]
        ))
        XCTAssertEqual(numeric.first?["max_points"]?.numberValue, 4)
    }

    func testASetFieldIsAFacetCountingARecordOncePerMember() throws {
        let rows = try member.aggregate(AggregateOptions(
            groupBy: ["tags"],
            operations: [AggregateOperation(type: .count), AggregateOperation(type: .sum, field: "points")],
            sort: AggregateSort(field: "tags", direction: 1)
        ))
        XCTAssertEqual(groups(rows, "tags"), ["a", "b"])
        XCTAssertEqual(numbers(rows, "count"), [2, 2])
        XCTAssertEqual(numbers(rows, "sum_points"), [7, 8])
    }

    func testAMembershipGroupsByWhetherTheArrayHoldsTheMember() throws {
        let rows = try member.aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "a")],
            operations: [AggregateOperation(type: .count)],
            sort: AggregateSort(field: "has_tags_a", direction: 1)
        ))
        XCTAssertEqual(groups(rows, "has_tags_a"), ["false", "true"])
        XCTAssertEqual(numbers(rows, "count"), [3, 2])
    }

    func testAPeriodBucketsAnISOStringByMonthQuarterAndYear() throws {
        let expectations: [(DatePeriod, [JSONValue], [Double])] = [
            (.month, [.null, "2025-12", "2026-01", "2026-02", "2026-04"], [1, 1, 1, 1, 1]),
            (.quarter, [.null, "2025-Q4", "2026-Q1", "2026-Q2"], [1, 1, 2, 1]),
            (.year, [.null, "2025", "2026"], [1, 1, 3]),
        ]
        for (period, keys, counts) in expectations {
            let key = "due_\(period.rawValue)"
            let rows = try member.aggregate(AggregateOptions(
                groupBy: [.datePeriod(field: "due", period: period)],
                operations: [AggregateOperation(type: .count)],
                sort: AggregateSort(field: key, direction: 1)
            ))
            XCTAssertEqual(groups(rows, key), keys.map { $0 }, "\(period)")
            XCTAssertEqual(numbers(rows, "count"), counts, "\(period)")
        }
    }

    func testSortAndLimitTakeTheTopGroupsAndALimitOutsideTheRangeIsRefused() throws {
        let top = try member.aggregate(AggregateOptions(
            groupBy: ["status"], operations: [AggregateOperation(type: .sum, field: "points")],
            sort: AggregateSort(field: "sum_points", direction: -1), limit: 2
        ))
        XCTAssertEqual(groups(top, "status"), ["open", .null])
        XCTAssertEqual(numbers(top, "sum_points"), [8, 5])
        for limit in [0, -1, 10_001] {
            XCTAssertThrowsError(try member.aggregate(AggregateOptions(
                groupBy: ["status"], operations: [AggregateOperation(type: .count)], limit: limit
            )), "limit \(limit)") { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "\(error)")
                XCTAssertEqual((error as? JsBaoError)?.message, "Invalid options.limit: must be an integer from 1 to 10000")
            }
        }
        XCTAssertEqual(try member.aggregate(AggregateOptions(
            groupBy: ["status"], operations: [AggregateOperation(type: .count)], limit: 10_000
        )).count, 3)
    }

    // MARK: - Behaviour 12

    func testAnAggregateWhoseRowsPass8MiBIsRefusedNeverCut() throws {
        let member = try XCTUnwrap(self.member)
        let long = String(repeating: "m", count: 1_000)
        try fixture.seed("db3-a", "Task", (0..<9).map { row in
            ["id": .string("big\(row)"), "tags": .array((0..<1_000).map { .string("\(long)-\(row)-\($0)") })]
        })
        XCTAssertThrowsError(try member.aggregate(AggregateOptions(
            groupBy: ["tags"], operations: [AggregateOperation(type: .count)]
        ))) { error in
            let refusal = error as? JsBaoError
            XCTAssertEqual(refusal?.code.rawValue, "DB3_PAGE_TOO_LARGE", "\(error)")
            XCTAssertEqual(refusal?.details?["limit"]?.numberValue, 8 * 1024 * 1024)
            XCTAssertGreaterThan(refusal?.details?["bytes"]?.numberValue ?? 0, 8 * 1024 * 1024)
            XCTAssertTrue(refusal?.message.contains("per db3 response") ?? false, refusal?.message ?? "")
        }
        // Under the budget with sort and a limit: answered.
        let top = try member.aggregate(AggregateOptions(
            groupBy: ["tags"], operations: [AggregateOperation(type: .count)],
            sort: AggregateSort(field: "tags", direction: 1), limit: 10
        ))
        XCTAssertEqual(groups(top, "tags").prefix(2), ["a", "b"])
        XCTAssertEqual(top.count, 10)
    }
}
