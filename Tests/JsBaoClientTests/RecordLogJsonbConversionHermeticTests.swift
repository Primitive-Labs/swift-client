import XCTest
@testable import JsBaoClient

/// #5136 behaviours 5 and 6: a store from the previous release (storage
/// version 2: `_data` JSON text with `id`) opens on this build and converts
/// one document per transaction, in `doc_id` order, each row's own encoding
/// its marker (text is still to convert), and writes the version last. No row
/// is added, lost or duplicated in any table; every lookup index stays; a
/// staged base's NULL row stays NULL; the live pages do not grow, whatever
/// the number of documents (finding 5136-R2). A conversion interrupted after
/// one document's transaction resumes at the next open from the next
/// document. A key holding U+0000 keeps its whole `id` (finding 5136-R1).
final class RecordLogJsonbConversionHermeticTests: XCTestCase {

    private static let dataTables = ["record_log_rows", "record_log_view", "record_log_staged_base"]

    private var directories: [String] = []
    private let lines = LockedBox<[String]>([])

    override func setUp() {
        super.setUp()
        let lines = lines
        Logger.lineForTest = { _, _, message in
            if message.contains("storage version") { lines.withValue { $0.append(message) } }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-jsonb-conversion-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func store(_ host: any Format2SqlHost, _ documentId: String) -> RecordLogStore {
        RecordLogStore(host: host, documentId: documentId, clientId: "client-1", logger: Logger(level: .info))
    }

    private func opened(_ provider: SQLiteStorageProvider, _ documentId: String) throws -> (RecordLogStore, String) {
        let store = store(provider, documentId)
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private func row(_ model: String, _ id: String, _ fields: RecordLogRow) -> RecordLogCatchUpRow {
        var row = fields
        row["id"] = .string(id)
        return RecordLogCatchUpRow(model: model, id: id, row: row)
    }

    private func commit(_ store: RecordLogStore, _ writer: String, _ m: RecordLogMutation) throws {
        _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [m])])
        try store.flush()
    }

    /// A store as the previous release left it, three documents:
    /// - `doc-a`: `Note` and `Tag` rows confirmed, the room's index list (a
    ///   lookup index on the view and a unique one on the rows), unjudged
    ///   entries whose view rows differ from the confirmed ones, and a staged
    ///   replacement in progress whose base holds a row and a NULL;
    /// - `doc-b`: rows of one model, one holding nothing but its id;
    /// - `doc-c`: a state row and no rows.
    private func planted() async throws -> SQLiteStorageProvider {
        let provider = try await makeProvider()
        let (a, writer) = try opened(provider, "doc-a")
        try a.syncIndexes([
            RecordLogIndexEntry(name: "by_n", model: "Note", fields: ["n"], unique: false),
            RecordLogIndexEntry(name: "by_slug", model: "Note", fields: ["slug"], unique: true),
        ])
        let first = try XCTUnwrap(try a.beginFencedCatchUp(writer: writer, full: true))
        let notes = (1...6).map { i in
            row("Note", "n\(i)", ["title": .string("note \(i)"), "n": .number(Double(i)), "slug": .string("s\(i)"), "tags": ["x", "é"]])
        }
        _ = try a.applyCatchUpPage(
            writer: writer, rows: notes + [row("Tag", "t1", ["label": "one"]), row("Tag", "t2", ["label": "two \u{2028}"])],
            lsn: 5, generation: first
        )
        _ = try a.completeCatchUp(writer: writer, lsn: 5, full: true, generation: first, at: 1_000)
        try commit(a, writer, RecordLogMutation(model: "Note", id: "n2", kind: .patch, fields: ["title": "mine"]))
        try commit(a, writer, RecordLogMutation(model: "Note", id: "n7", kind: .create, fields: ["title": "guessed", "n": 7]))
        let second = try XCTUnwrap(try a.beginFencedCatchUp(writer: writer, full: true))
        _ = try a.applyCatchUpPage(
            writer: writer, rows: [row("Note", "n1", ["title": "replaced", "n": 1]), row("Note", "n8", ["title": "new"])],
            lsn: 9, generation: second
        )

        let (b, other) = try opened(provider, "doc-b")
        try b.beginCatchUp(writer: other, full: false)
        _ = try b.applyCatchUpPage(writer: other, rows: [row("Note", "b1", ["title": "b"]), row("Note", "b-solo", [:])], lsn: 3)
        _ = try b.completeCatchUp(writer: other, lsn: 3, at: 2_000)

        _ = try opened(provider, "doc-c")
        try RecordLogPreviousRelease.downgrade(provider)
        return provider
    }

    /// Every record-log table's rows in `rowid` order, `_data` read as its row
    /// with `id` (whatever its encoding).
    private func records(_ provider: SQLiteStorageProvider) throws -> [String: [[String: Format2SqlValue]]] {
        var out: [String: [[String: Format2SqlValue]]] = [:]
        try provider.withConnection { connection in
            for table in RecordLogSchema.clientTables {
                let data = Self.dataTables.contains(table)
                out[table] = try connection.query(
                    "SELECT *\(data ? ", json(_data) AS _json" : "") FROM \(table) ORDER BY rowid"
                ).map { row in
                    var columns = row.columns
                    if data {
                        columns["_data"] = columns["_json"]?.isNull == false
                            ? .text(RecordLogJSON.text(.object(RecordLogJSON.row(columns["_json"]?.stringValue, id: columns["_id"]?.stringValue))))
                            : .null
                        columns["_json"] = nil
                    }
                    return columns
                }
            }
        }
        return out
    }

    private func scalar(_ provider: SQLiteStorageProvider, _ sql: String) throws -> Format2SqlValue {
        try provider.withConnection { try $0.query(sql) }.first?.columns.values.first ?? .null
    }

    private func version(_ provider: SQLiteStorageProvider) throws -> String? {
        try scalar(provider, "SELECT value FROM record_log_meta WHERE key = 'storage_version'").stringValue
    }

    /// Stored rows of `documentId` (every document when `nil`) not yet JSONB without `id`.
    private func unconverted(_ provider: SQLiteStorageProvider, _ documentId: String? = nil) throws -> Int {
        var count = 0
        for table in Self.dataTables {
            count += try scalar(provider, """
                SELECT COUNT(*) FROM \(table) WHERE _data IS NOT NULL\(documentId.map { " AND doc_id = '\($0)'" } ?? "")
                   AND (typeof(_data) <> 'blob' OR json_extract(_data, '$.id') IS NOT NULL)
                """).intValue ?? -1
        }
        return count
    }

    private func storedRows(_ provider: SQLiteStorageProvider) throws -> Int {
        try Self.dataTables.reduce(0) { $0 + (try scalar(provider, "SELECT COUNT(*) FROM \($1) WHERE _data IS NOT NULL").intValue ?? 0) }
    }

    /// The traced statements, cut into transactions (`BEGIN` … `COMMIT`), PRAGMAs left out.
    private func transactions(_ trace: RecordLogStatementTrace) -> (blocks: [[String]], outside: [String]) {
        var blocks: [[String]] = []
        var outside: [String] = []
        var open: [String]?
        for statement in trace.statements.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            let upper = statement.uppercased()
            if upper.hasPrefix("PRAGMA") { continue }
            if upper.hasPrefix("BEGIN") { open = []; continue }
            if upper.hasPrefix("COMMIT") || upper.hasPrefix("ROLLBACK") {
                blocks.append(open ?? [])
                open = nil
                continue
            }
            if open != nil { open?.append(statement) } else { outside.append(statement) }
        }
        return (blocks, outside)
    }

    private static let conversion = [
        "UPDATE record_log_rows SET _data = jsonb(",
        "UPDATE record_log_view SET _data = jsonb(",
        "UPDATE record_log_staged_base SET _data = jsonb(",
    ]

    private func isConversion(_ block: [String]) -> Bool {
        block.count == Self.conversion.count && zip(block, Self.conversion).allSatisfy { $0.hasPrefix($1) }
    }

    // MARK: - Behaviour 5

    func testAVersion2StoreConvertsOneDocumentPerTransactionKeepingEveryRow() async throws {
        let provider = try await planted()
        XCTAssertEqual(try version(provider), "2")
        XCTAssertEqual(try unconverted(provider), try storedRows(provider), "every stored row is text with id")
        let stored = try storedRows(provider)
        let before = try records(provider)
        let indexes = try provider.withConnection { try $0.query("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name") }
            .map(\.columns)
        let viewIndex = try XCTUnwrap(indexes.compactMap { $0["name"]?.stringValue }.first { $0.hasPrefix("idx_record_log_view_") })
        XCTAssertTrue(indexes.contains { ($0["name"]?.stringValue ?? "").hasPrefix("idx_record_log_rows_") }, "a lookup index on the rows")
        let pagesBefore = try RecordLogPreviousRelease.livePages(provider)
        XCTAssertTrue(try scalar(provider, "SELECT COUNT(*) FROM record_log_staged_base WHERE _data IS NULL").intValue == 1)

        let trace = try RecordLogStatementTrace.install(on: provider, self)
        try store(provider, "doc-b").initialize()

        // The DDL, one transaction per document holding rows (doc-a, doc-b), then the version.
        let (blocks, outside) = transactions(trace)
        XCTAssertEqual(outside, [], "every statement runs in a transaction")
        XCTAssertEqual(blocks.count, 4, "\(blocks)")
        XCTAssertFalse(blocks.joined().contains { $0.hasPrefix("UPDATE record_log_state") }, "no state row is written")
        XCTAssertTrue(blocks.first?.contains { $0.hasPrefix("CREATE TABLE IF NOT EXISTS record_log_rows") } ?? false)
        XCTAssertFalse(blocks.first?.contains { $0.contains("jsonb(") } ?? true, "no row is converted with the DDL")
        for block in blocks.dropFirst().dropLast() { XCTAssertTrue(isConversion(block), "one document's transaction: \(block)") }
        XCTAssertTrue(blocks.last?.contains { $0.contains("INSERT INTO record_log_meta") } ?? false, "\(blocks.last ?? [])")
        XCTAssertFalse(blocks.last?.contains { $0.contains("jsonb(") } ?? true)

        XCTAssertEqual(try version(provider), "4")
        XCTAssertEqual(try unconverted(provider), 0, "every stored row is JSONB without id")
        XCTAssertEqual(try records(provider), before, "every table keeps its rows, keys and values")
        XCTAssertEqual(try scalar(provider, "SELECT COUNT(*) FROM record_log_staged_base WHERE _data IS NULL").intValue, 1, "the NULL base stays NULL")
        XCTAssertEqual(
            try provider.withConnection { try $0.query("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name") }.map(\.columns),
            indexes, "every index kept"
        )
        let plan = try provider.withConnection {
            try $0.query("EXPLAIN QUERY PLAN SELECT _id FROM record_log_view WHERE doc_id = 'doc-a' AND _type = 'Note' AND json_extract(_data, '$.n') = 3")
        }.compactMap { $0["detail"].stringValue }.joined(separator: "; ")
        XCTAssertTrue(plan.contains(viewIndex), "an indexed equality still reads \(viewIndex): \(plan)")
        XCTAssertLessThanOrEqual(try RecordLogPreviousRelease.livePages(provider), pagesBefore, "the store does not grow")
        XCTAssertEqual(lines.value.count, 1, "\(lines.value)")
        XCTAssertTrue(lines.value.first?.contains("storage version 4") ?? false, lines.value.first ?? "")
        XCTAssertTrue(lines.value.first?.contains("2 document(s), \(stored) row(s) re-encoded as JSONB without id") ?? false, lines.value.first ?? "")
        XCTAssertFalse(lines.value.first?.contains("resumed") ?? true)

        // Reads answer as before; a converted document reads, writes and completes its replacement.
        let (a, writer) = try opened(provider, "doc-a")
        XCTAssertEqual(try a.read(model: "Note", id: "n2")?["title"], "mine", "the guess over n2")
        XCTAssertEqual(try a.read(model: "Tag", id: "t2"), ["id": "t2", "label": "two \u{2028}"])
        try commit(a, writer, RecordLogMutation(model: "Note", id: "n8", kind: .patch, fields: ["title": "patched"]))
        XCTAssertNil(try a.read(model: "Note", id: "n8"), "the NULL base reads as no row")
        try commit(a, writer, RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["n": 10]))
        XCTAssertEqual(try a.read(model: "Note", id: "n1")?["title"], "note 1", "the base row reads as it was")
        XCTAssertEqual(try a.queryView("Note", ["n": 3]).data.compactMap { $0["id"]?.stringValue }, ["n3"])
        let generation = try XCTUnwrap(try a.marks().replacement)
        _ = try a.completeCatchUp(writer: writer, lsn: 9, full: true, generation: generation, at: 3_000)
        XCTAssertEqual(try a.read(model: "Note", id: "n1"), ["id": "n1", "title": "replaced", "n": 10])
        XCTAssertEqual(try a.read(model: "Note", id: "n8"), ["id": "n8", "title": "patched"])
        let b = store(provider, "doc-b")
        XCTAssertEqual(try b.read(model: "Note", id: "b-solo"), ["id": "b-solo"])
        XCTAssertEqual(
            try scalar(provider, "SELECT json(_data) FROM record_log_view WHERE doc_id = 'doc-b' AND _id = 'b-solo'").stringValue, "{}",
            "a row holding only its id is stored empty"
        )
        XCTAssertEqual(try scalar(provider, "SELECT COUNT(*) FROM record_log_rows WHERE doc_id = 'doc-c'").intValue, 0)
    }

    // MARK: - Behaviour 6

    func testAnInterruptedConversionResumesAtTheNextDocumentWithNoRowLostOrDuplicated() async throws {
        let provider = try await planted()
        let before = try records(provider)
        let faulting = RecordLogFaultingHost(provider, failing: "UPDATE record_log_rows SET _data = jsonb(", at: 2)
        XCTAssertThrowsError(try store(faulting, "doc-a").initialize()) { error in
            XCTAssertTrue(error is RecordLogFaultingHost.Injected, "\(error)")
        }
        XCTAssertEqual(try version(provider), "2", "the version is written last")
        XCTAssertEqual(try unconverted(provider, "doc-a"), 0, "the first document's transaction committed")
        XCTAssertGreaterThan(try unconverted(provider, "doc-b"), 0, "the second's rolled back")
        XCTAssertEqual(try records(provider), before)

        lines.value = []
        let trace = try RecordLogStatementTrace.install(on: provider, self)
        try store(provider, "doc-a").initialize()
        let (blocks, _) = transactions(trace)
        XCTAssertEqual(blocks.filter(isConversion).count, 1, "doc-b only (doc-c holds no row): \(blocks)")
        XCTAssertEqual(trace.statements.filter { $0.contains("UPDATE record_log_rows SET _data = jsonb(") }.count, 1)
        XCTAssertEqual(try version(provider), "4")
        XCTAssertEqual(try unconverted(provider), 0)
        XCTAssertEqual(try records(provider), before, "no row lost or duplicated")
        XCTAssertEqual(lines.value.count, 1, "\(lines.value)")
        XCTAssertTrue(lines.value.first?.contains("1 document(s)") ?? false, lines.value.first ?? "")
        XCTAssertTrue(lines.value.first?.contains("resumed; 1 already converted") ?? false, lines.value.first ?? "")

        trace.clear()
        try store(provider, "doc-c").initialize()
        let fast = trace.statements.filter { !["BEGIN", "COMMIT", "ROLLBACK", "PRAGMA"].contains(where: $0.uppercased().hasPrefix) }
        XCTAssertEqual(fast.count, 2, "the fast path: \(fast)")
    }

    // MARK: - Edge: the calls that bring a store to the version first

    func testSetOwnerPurgeAndPurgeAllConvertAVersion2StoreFirst() async throws {
        let owned = try await planted()
        try RecordLogStore.setOwner(host: owned, userId: "user-a")
        XCTAssertEqual(try version(owned), "4")
        XCTAssertEqual(try unconverted(owned), 0)

        let purged = try await planted()
        XCTAssertTrue(try store(purged, "doc-c").purge(force: true).purged)
        XCTAssertEqual(try version(purged), "4")
        XCTAssertEqual(try unconverted(purged), 0)

        let reset = try await planted()
        let trace = try RecordLogStatementTrace.install(on: reset, self)
        XCTAssertEqual(try RecordLogStore.purgeAll(host: reset), 2, "doc-a's two unsent writes")
        XCTAssertEqual(try version(reset), "4")
        let statements = trace.statements
        let converted = statements.indices.filter { statements[$0].hasPrefix(Self.conversion[0]) }
        let cleared = try XCTUnwrap(statements.firstIndex { $0.hasPrefix("DELETE FROM record_log_rows") })
        XCTAssertEqual(converted.count, 2, "each document holding rows converted")
        XCTAssertTrue(converted.allSatisfy { $0 < cleared }, "before the reset clears the tables")
    }

    // MARK: - Finding 5136-R2: many documents

    /// Stores of `documents` documents, one holding a confirmed row and the
    /// rest a state row each as the previous release inserted it
    /// (`doc_id` only), converted from packed pages (the planted file copied
    /// by `VACUUM INTO`). Over counts a state-table page apart, one leaves
    /// that table's last page all but full, where a byte more per state row
    /// (a per-document marker written there) takes a page more.
    func testAStoreOfManyDocumentsDoesNotGrowAtConversion() async throws {
        for documents in stride(from: 1_000, to: 1_150, by: 25) {
            lines.value = []
            let planted = try await makeProvider()
            let (a, writer) = try opened(planted, "doc-0000")
            try a.beginCatchUp(writer: writer, full: false)
            _ = try a.applyCatchUpPage(writer: writer, rows: [row("Note", "n1", ["title": "one"])], lsn: 1)
            _ = try a.completeCatchUp(writer: writer, lsn: 1, at: 1_000)
            try RecordLogPreviousRelease.downgrade(planted)
            let packed = try XCTUnwrap(directories.last) + "/packed.sqlite"
            try planted.withConnection { connection in
                try connection.execute(
                    """
                    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                    INSERT INTO record_log_state (doc_id) SELECT printf('doc-%04d', i) FROM n
                    """,
                    [.integer(Int64(documents - 1))]
                )
                try connection.executeScript("VACUUM INTO '\(packed)'")
            }
            await planted.close()
            let provider = SQLiteStorageProvider(path: packed)
            try await provider.initialize(namespace: "test")
            XCTAssertEqual(try scalar(provider, "SELECT COUNT(*) FROM record_log_state").intValue, documents)
            let pagesBefore = try RecordLogPreviousRelease.livePages(provider)
            let before = try records(provider)

            try store(provider, "doc-0001").initialize()
            XCTAssertEqual(try version(provider), "4")
            XCTAssertEqual(try unconverted(provider), 0)
            XCTAssertEqual(try records(provider), before, "\(documents) documents")
            XCTAssertLessThanOrEqual(
                try RecordLogPreviousRelease.livePages(provider), pagesBefore, "\(documents) documents: the store does not grow"
            )
            XCTAssertTrue(lines.value.first?.contains("1 document(s), 2 row(s) re-encoded") ?? false, lines.value.first ?? "")
            await provider.close()
        }
    }

    // MARK: - Finding 5136-R1: a key holding U+0000

    func testAKeyHoldingANulKeepsItsWholeIdThroughWritesReadsAndConversion() async throws {
        let id = "prefix\u{0}suffix"
        let provider = try await makeProvider()
        let (a, writer) = try opened(provider, "doc-a")
        try a.beginCatchUp(writer: writer, full: false)
        _ = try a.applyCatchUpPage(
            writer: writer, rows: [row("Note", id, ["title": "nul"]), row("Note", "plain", ["title": "plain"])], lsn: 1
        )
        _ = try a.completeCatchUp(writer: writer, lsn: 1, at: 1_000)
        try commit(a, writer, RecordLogMutation(model: "Note", id: id, kind: .patch, fields: ["title": "patched"]))

        func assertWhole(_ store: RecordLogStore, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let ids = Set([id, "plain"])
            XCTAssertEqual(Set(try store.queryView("Note").data.compactMap { $0["id"]?.stringValue }), ids, label, file: file, line: line)
            XCTAssertEqual(Set(try store.confirmedRows().compactMap { $0["id"]?.stringValue }), ids, label, file: file, line: line)
            XCTAssertEqual(
                Set(try store.readRowsAfter(model: "Note", after: nil, limit: 10).compactMap { $0["id"]?.stringValue }), ids,
                label, file: file, line: line
            )
            XCTAssertEqual(try store.read(model: "Note", id: id)?["id"], .string(id), label, file: file, line: line)
        }
        try assertWhole(a, "written as JSONB")
        // Stored JSONB, the whole id kept in it; every other row without id.
        XCTAssertEqual(
            try scalar(provider, "SELECT COUNT(*) FROM record_log_view WHERE typeof(_data) = 'blob' AND json_extract(_data, '$.id') IS NOT NULL")
                .intValue, 1
        )
        XCTAssertEqual(try scalar(provider, "SELECT COUNT(*) FROM record_log_rows WHERE json_extract(_data, '$.id') IS NOT NULL").intValue, 1)

        try RecordLogPreviousRelease.downgrade(provider)
        try store(provider, "doc-a").initialize()
        XCTAssertEqual(try version(provider), "4")
        XCTAssertEqual(try scalar(provider, "SELECT COUNT(*) FROM record_log_view WHERE typeof(_data) <> 'blob'").intValue, 0)
        XCTAssertEqual(
            try scalar(provider, "SELECT COUNT(*) FROM record_log_view WHERE json_extract(_data, '$.id') IS NOT NULL").intValue, 1,
            "the conversion keeps the id the key cannot restore, and only that one"
        )
        try assertWhole(store(provider, "doc-a"), "converted")
    }
}
