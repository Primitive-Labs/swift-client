import XCTest
@testable import JsBaoClient

/// The intent's assumption 3 on the Swift store (behaviour 1): a file-backed
/// store holds 100,000 rows of one 10-field model, and an equality query on a
/// field with no index, answered from `record_log_view` by `queryView` (the
/// statement a model-free query ships with: `json_extract` over the model's
/// view rows, an unindexed scan, then each match parsed), completes within
/// 100 ms warm (median of 5 after one warm-up) and cold (a fresh provider and
/// store's first query, median of 3). Nothing on the view names the field,
/// before or after. The Swift twin of `record-log-query-cost-4623.test.ts`.
///
/// #4700 behaviour 24 (criterion 4 on macOS) adds the indexed cell: once the
/// store synced a list naming `(Note, [n])`, the same query answers within
/// 50 ms warm and cold, on the bundled SQLite, through the index.
final class RecordLogViewQueryCostHermeticTests: XCTestCase {

    private static let rows = 100_000
    private static let boundMs = 100.0
    private static let indexedBoundMs = 50.0
    private var directory = ""

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "/record-log-view-cost-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private var path: String { directory + "/store.sqlite" }

    private func open() async throws -> (SQLiteStorageProvider, RecordLogStore) {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "test")
        let store = RecordLogStore(host: provider, documentId: "cost-4624", clientId: "probe")
        try store.initialize()
        return (provider, store)
    }

    private func ms(_ work: () throws -> Void) rethrows -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private func indexesNamingN(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection { connection in
            try connection.query("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'record_log_view'")
        }.filter { ($0["sql"].stringValue ?? "").contains("'$.n'") }.compactMap { $0["name"].stringValue }
    }

    /// 100,000 rows of one 10-field `Note`, `n` holding 0 to 999, written as a catch-up leaves them.
    private func seed() async throws {
        do {
            let (provider, _) = try await open()
            try provider.withConnection { connection in
                try connection.execute("BEGIN", [])
                for i in 0..<Self.rows {
                    let id = "01J" + String(repeating: "0", count: 23 - String(i).count) + String(i)
                    let row: JSONValue = [
                        "id": .string(id), "title": .string("title \(i)"), "slug": .string("slug-\(i)"),
                        "body": .string(String(repeating: "x", count: 40)), "a": .number(Double(i) * 1.5),
                        "b": .number(Double(i % 7)), "c": .number(Double(i) / 3), "done": .bool(i % 2 == 0),
                        "kind": .string("k\(i % 5)"), "owner": .string("owner-\(i % 50)"), "n": .number(Double(i % 1000)),
                    ]
                    let data = RecordLogJSON.text(row)
                    for table in ["record_log_rows", "record_log_view"] {
                        try connection.execute(
                            "INSERT INTO \(table) (doc_id, _type, _id, _data) VALUES (?, ?, ?, ?)",
                            [.text("cost-4624"), .text("Note"), .text(id), .text(data)]
                        )
                    }
                }
                try connection.execute("COMMIT", [])
            }
            XCTAssertEqual(try indexesNamingN(provider), [])
        }
    }

    func testAnEqualityQueryOnAnUnindexedFieldAnswersWithin100MsWarmAndCold() async throws {
        try await seed()
        let (provider, store) = try await open()
        XCTAssertEqual(try store.queryView("Note", ["n": 500]).data.count, Self.rows / 1000)
        var warm: [Double] = []
        for i in 0..<5 {
            warm.append(try ms { _ = try store.queryView("Note", ["n": .number(Double(501 + i))]) })
        }
        var cold: [Double] = []
        for i in 0..<3 {
            let (_, fresh) = try await open()
            var answered = 0
            cold.append(try ms { answered = try fresh.queryView("Note", ["n": .number(Double(600 + i))]).data.count })
            XCTAssertEqual(answered, Self.rows / 1000)
        }
        let report = "[4624] assumption 3, \(Self.rows) rows, Swift store, ms (bound \(Int(Self.boundMs))): "
            + "warm \(String(format: "%.1f", median(warm))) \(warm.map { String(format: "%.1f", $0) }), "
            + "cold \(String(format: "%.1f", median(cold))) \(cold.map { String(format: "%.1f", $0) })"
        print(report)
        XCTAssertLessThanOrEqual(median(warm), Self.boundMs, report)
        XCTAssertLessThanOrEqual(median(cold), Self.boundMs, report)
        XCTAssertEqual(try indexesNamingN(provider), [], "no store builds an index because a query asked for a field")
    }

    func testAnEqualityQueryOnAnIndexedFieldAnswersWithin50MsWarmAndCold() async throws {
        try await seed()
        let (provider, store) = try await open()
        let built = try ms {
            _ = try store.syncIndexes([RecordLogIndexEntry(name: "idx_records_Note_n", model: "Note", fields: ["n"], unique: false)])
        }
        XCTAssertEqual(try indexesNamingN(provider), ["idx_record_log_view_4_note_1_n"])
        XCTAssertEqual(try store.indexTuples(), [RecordLogIndexTuple(model: "Note", fields: ["n"], unique: false)])

        // The statement the reader runs uses the index.
        let trace = try RecordLogStatementTrace.install(on: provider, self)
        XCTAssertEqual(try store.queryView("Note", ["n": 500]).data.count, Self.rows / 1000, "the warm-up")
        let statement = try XCTUnwrap(trace.viewReads.last)
        let plan = try provider.withConnection { connection in
            try connection.query("EXPLAIN QUERY PLAN " + statement, [.text("Note"), .integer(500), .text("cost-4624")])
        }.compactMap { $0["detail"].stringValue }
        XCTAssertTrue(plan.contains { $0.contains("idx_record_log_view_4_note_1_n") }, "the plan: \(plan)")

        var warm: [Double] = []
        for i in 0..<5 {
            warm.append(try ms { _ = try store.queryView("Note", ["n": .number(Double(501 + i))]) })
        }
        var cold: [Double] = []
        for i in 0..<3 {
            let (_, fresh) = try await open()
            var answered = 0
            cold.append(try ms { answered = try fresh.queryView("Note", ["n": .number(Double(600 + i))]).data.count })
            XCTAssertEqual(answered, Self.rows / 1000)
        }
        let report = "[4700] criterion 4, \(Self.rows) rows, Swift store, indexed, ms (bound \(Int(Self.indexedBoundMs))): "
            + "build \(String(format: "%.1f", built)), "
            + "warm \(String(format: "%.1f", median(warm))) \(warm.map { String(format: "%.1f", $0) }), "
            + "cold \(String(format: "%.1f", median(cold))) \(cold.map { String(format: "%.1f", $0) })"
        print(report)
        XCTAssertLessThanOrEqual(median(warm), Self.indexedBoundMs, report)
        XCTAssertLessThanOrEqual(median(cold), Self.indexedBoundMs, report)
    }
}
