import XCTest
@testable import JsBaoClient

/// #5136 behaviours 11 and 12, criterion 7's size on the Swift store: the
/// harness's 100,000 rows written through the store's load path take at most
/// 90% of the live pages (`page_count − freelist_count`) of a store holding
/// the same rows written with the previous release's statements in the same
/// order; that previous-release store, opened on this build, converts
/// without growing and reads back every row with its id.
///
/// The bound is asserted on the IMDb rows only (README step 1, or
/// `DB3_STORAGE_TSV`); without them the measurement is recorded as a skip,
/// never a pass. The synthetic rows always run, their figures printed as a
/// diagnostic with no size bound.
final class RecordLogJsonbSizeHermeticTests: XCTestCase {

    private static let model = "Title"
    private static let chunk = 10_000

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider(_ label: String) async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-jsonb-size-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func report(_ line: String) {
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// `rows` through this build's load path: ten chunks of 10,000, then the completion.
    private func loadFresh(_ provider: SQLiteStorageProvider, _ rows: [(id: String, patch: [String: JSONValue])]) throws {
        let store = RecordLogStore(host: provider, documentId: "harness", clientId: "client-1")
        try store.initialize()
        let writer = try store.mintWriter()
        let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "harness").attempt
        for start in stride(from: 0, to: rows.count, by: Self.chunk) {
            let lines = rows[start..<min(start + Self.chunk, rows.count)].map { RecordLogLoadLine(id: $0.id, patch: $0.patch) }
            _ = try store.applyLoadChunk(writer: writer, sessionId: "harness", attempt: attempt, model: Self.model, lines: lines)
        }
        _ = try store.completeLoad(writer: writer, sessionId: "harness", attempt: attempt, mode: .merge, models: [Self.model])
    }

    /// `rows` as the previous release wrote a load, statement for statement:
    /// per chunk in one transaction, each confirmed row as JSON text with
    /// `id`, the chunk's load keys, then the view's rows copied from the
    /// confirmed ones 400 at a time; the keys forgotten at the completion.
    private func loadAsPreviousRelease(_ provider: SQLiteStorageProvider, _ rows: [(id: String, patch: [String: JSONValue])]) throws {
        let store = RecordLogStore(host: provider, documentId: "harness", clientId: "client-1")
        try store.initialize()
        _ = try store.mintWriter()
        try RecordLogPreviousRelease.downgrade(provider)
        let doc = Format2SqlValue.text("harness")
        let model = Format2SqlValue.text(Self.model)
        try provider.withConnection { connection in
            for start in stride(from: 0, to: rows.count, by: Self.chunk) {
                let slice = rows[start..<min(start + Self.chunk, rows.count)]
                try connection.transaction {
                    for (id, patch) in slice {
                        var row = patch
                        row["id"] = .string(id)
                        try connection.execute(
                            """
                            INSERT INTO record_log_rows (doc_id, _type, _id, _data, _gen) VALUES (?, ?, ?, ?, ?)
                              ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data, _gen = excluded._gen
                            """,
                            [doc, model, .text(id), .text(RecordLogJSON.text(.object(row))), .integer(0)]
                        )
                    }
                    for (id, _) in slice {
                        try connection.execute(
                            "INSERT OR IGNORE INTO record_log_load_keys (doc_id, attempt, _type, _id) VALUES (?, 'harness', ?, ?)",
                            [doc, model, .text(id)]
                        )
                    }
                    let ids = slice.map(\.id)
                    for batch in stride(from: 0, to: ids.count, by: 400) {
                        let part = ids[batch..<min(batch + 400, ids.count)]
                        let marks = part.map { _ in "?" }.joined(separator: ", ")
                        let bindings: [Format2SqlValue] = [doc, model] + part.map { .text($0) }
                        try connection.execute("DELETE FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id IN (\(marks))", bindings)
                        try connection.execute(
                            """
                            INSERT INTO record_log_view (doc_id, _type, _id, _data)
                              SELECT doc_id, _type, _id, _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN (\(marks))
                            """,
                            bindings
                        )
                    }
                }
            }
            try connection.execute("DELETE FROM record_log_load_keys WHERE doc_id = ? AND attempt = 'harness'", [doc])
        }
    }

    /// Both stores' live pages, then the previous release's store opened on
    /// this build: it converts without growing and reads back every row.
    private func measure(_ rows: [(id: String, patch: [String: JSONValue])], source: RecordLogHarnessRows.Source) async throws
        -> (fresh: Int, previous: Int)
    {
        let fresh = try await makeProvider("fresh")
        try loadFresh(fresh, rows)
        let freshPages = try RecordLogPreviousRelease.livePages(fresh)
        let previous = try await makeProvider("previous")
        try loadAsPreviousRelease(previous, rows)
        let previousPages = try RecordLogPreviousRelease.livePages(previous)
        report(String(
            format: "[5136] criterion 7 size (%@, %d rows): fresh store %d live pages, previous release %d live pages, ratio %.3f",
            source.rawValue, rows.count, freshPages, previousPages, Double(freshPages) / Double(previousPages)
        ))

        let started = Date()
        let store = RecordLogStore(host: previous, documentId: "harness", clientId: "client-1")
        try store.initialize()
        let seconds = Date().timeIntervalSince(started)
        let convertedPages = try RecordLogPreviousRelease.livePages(previous)
        report(String(
            format: "[5136] criterion 7 conversion (%@, %d rows): %.0f ms, %.0f ms per 100,000 rows; live pages %d before, %d after",
            source.rawValue, rows.count, seconds * 1000, seconds * 1000 * 100_000 / Double(rows.count), previousPages, convertedPages
        ))
        XCTAssertLessThanOrEqual(convertedPages, previousPages, "the converted store does not grow (\(source.rawValue))")
        let kinds = try previous.withConnection {
            try $0.query("SELECT COUNT(*) AS n FROM record_log_view WHERE typeof(_data) <> 'blob' OR json_extract(_data, '$.id') IS NOT NULL")
        }
        XCTAssertEqual(kinds.first?["n"].intValue, 0, "every view row converted (\(source.rawValue))")

        var read: [RecordLogRow] = []
        var after: String?
        repeat {
            let page = try store.readRowsAfter(model: Self.model, after: after, limit: 10_000)
            read += page
            after = page.count == 10_000 ? page.last?["id"]?.stringValue : nil
        } while after != nil
        XCTAssertEqual(read.count, rows.count, "every row read back (\(source.rawValue))")
        var differing = 0
        for (row, (id, patch)) in zip(read, rows) {
            var expected = patch
            expected["id"] = .string(id)
            if !recordLogSameRow(row, expected) { differing += 1 }
        }
        XCTAssertEqual(differing, 0, "every row equals the loaded row with its id (\(source.rawValue))")
        let counts = try previous.withConnection { connection in
            try ["record_log_rows", "record_log_view"].map {
                try connection.query("SELECT COUNT(*) AS n FROM \($0) WHERE doc_id = 'harness'").first?["n"].intValue ?? -1
            }
        }
        XCTAssertEqual(counts, [rows.count, rows.count], "the view counts as the rows do (\(source.rawValue))")
        return (freshPages, previousPages)
    }

    // MARK: - Behaviours 11 and 12 on the IMDb rows

    func testOnTheImdbRowsAFreshStoreTakesAtMost90PercentOfThePreviousReleasesPagesAndOneConvertsWithoutGrowing() async throws {
        guard let tsv = RecordLogHarnessRows.tsv else {
            report("[5136] criterion 7 size: not measured (no IMDb TSV)")
            throw XCTSkip(
                "criterion 7 size: not measured; get the IMDb rows with tests/perf/db3-storage/README.md step 1, or set DB3_STORAGE_TSV"
            )
        }
        let rows = try RecordLogHarnessRows.imdb(tsv)
        XCTAssertEqual(rows.count, 100_000, "the TSV at \(tsv) holds 100,000 rows")
        guard rows.count == 100_000 else { return }
        let (fresh, previous) = try await measure(rows, source: .imdb)
        XCTAssertLessThanOrEqual(Double(fresh), 0.9 * Double(previous), "fresh \(fresh) pages, previous release \(previous)")
    }

    // MARK: - The same procedure on the synthetic rows, a diagnostic

    func testOnTheSyntheticRowsTheSameProcedureRunsAsADiagnostic() async throws {
        _ = try await measure(RecordLogHarnessRows.synthetic(), source: .synthetic)
    }
}
