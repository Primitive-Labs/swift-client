import XCTest
@testable import JsBaoClient

/// #5136 (db3 storage, C1 on Swift): the store keeps each record's `_data` in
/// `record_log_rows`, `record_log_view` and `record_log_staged_base` as SQLite
/// JSONB without `id`, which the record's key (`_id`) already holds, and hands
/// every row back with `id` restored.
///
/// - Behaviour 1 (pin, the vehicle): the vendored SQLite round-trips JSONB
///   byte for byte.
/// - Behaviour 2: every write stores JSONB without `id`; a staged base row
///   for a record that had none stays NULL.
/// - Behaviour 9: a row an older build wrote (JSON text with `id`) reads
///   beside the JSONB rows, is re-encoded on its next write, and a lookup on
///   `id` finds a record through `_id` in either encoding.
/// - Behaviour 10 (pin): a page's byte budget counts each row as its JSON
///   text with `id`.
final class RecordLogJsonbStorageHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-jsonb-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(_ provider: SQLiteStorageProvider, _ documentId: String = "doc-1") throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1")
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private func rows(_ provider: SQLiteStorageProvider, _ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try provider.withConnection { try $0.query(sql, bindings) }
    }

    private func note(_ id: String, _ fields: RecordLogRow) -> RecordLogCatchUpRow {
        var row = fields
        row["id"] = .string(id)
        return RecordLogCatchUpRow(model: "Note", id: id, row: row)
    }

    private func mutation(
        _ id: String, _ kind: RecordLogWriteKind, _ fields: [String: JSONValue]? = nil, tags: [String: Bool]? = nil
    ) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: kind, fields: fields, stringSetDeltas: tags.map { ["tags": $0] })
    }

    private func commit(_ store: RecordLogStore, _ writer: String, _ m: RecordLogMutation, upsertOn: String? = nil) throws {
        _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [m], upsertOn: upsertOn)])
        try store.flush()
    }

    /// `row` as the store keeps it: its JSON text without `id`.
    private func textWithoutId(_ row: RecordLogRow) -> String {
        var row = row
        row["id"] = nil
        return RecordLogJSON.text(.object(row))
    }

    /// Every `_data` of `table` is JSONB without `id` whose JSON is `expected`'s
    /// row without `id`, record by record; a NULL staged row is listed as `nil`.
    private func assertStoredAsJsonb(
        _ provider: SQLiteStorageProvider, _ table: String, _ expected: [String: RecordLogRow?], _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let stored = try rows(provider, """
            SELECT _id, typeof(_data) AS kind, json_type(_data) AS shape, json_extract(_data, '$.id') AS id_inside,
                   json(_data) AS text
              FROM \(table) WHERE doc_id = 'doc-1' ORDER BY _id
            """)
        XCTAssertEqual(stored.compactMap { $0["_id"].stringValue }, expected.keys.sorted(), "\(label): \(table)'s records", file: file, line: line)
        for found in stored {
            let id = found["_id"].stringValue ?? ""
            guard let row = expected[id] else { continue }
            guard let row else {
                XCTAssertEqual(found["kind"].stringValue, "null", "\(label): \(table) \(id) stays NULL", file: file, line: line)
                continue
            }
            XCTAssertEqual(found["kind"].stringValue, "blob", "\(label): \(table) \(id) is JSONB", file: file, line: line)
            XCTAssertEqual(found["shape"].stringValue, "object", "\(label): \(table) \(id)", file: file, line: line)
            XCTAssertTrue(found["id_inside"].isNull, "\(label): \(table) \(id) holds no id", file: file, line: line)
            XCTAssertTrue(
                (found["text"].stringValue ?? "").utf8.elementsEqual(textWithoutId(row).utf8),
                "\(label): \(table) \(id): \(found["text"].stringValue ?? "nil") is not \(textWithoutId(row))", file: file, line: line
            )
        }
    }

    /// The view as reads answer it, and the confirmed rows, by id.
    private func viewRows(_ store: RecordLogStore, _ ids: [String]) throws -> [String: RecordLogRow?] {
        var out: [String: RecordLogRow?] = [:]
        for id in ids { if let row = try store.read(model: "Note", id: id) { out[id] = .some(row) } }
        return out
    }

    private func confirmed(_ store: RecordLogStore) throws -> [String: RecordLogRow?] {
        var out: [String: RecordLogRow?] = [:]
        for row in try store.confirmedRows() { if let id = row["id"]?.stringValue { out[id] = .some(row) } }
        return out
    }

    private func assertEveryTableJsonb(
        _ provider: SQLiteStorageProvider, _ store: RecordLogStore, _ label: String,
        staged: [String: RecordLogRow?] = [:], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let known = try rows(provider, "SELECT _id FROM record_log_view WHERE doc_id = 'doc-1'").compactMap { $0["_id"].stringValue }
        try assertStoredAsJsonb(provider, "record_log_rows", try confirmed(store), label, file: file, line: line)
        try assertStoredAsJsonb(provider, "record_log_view", try viewRows(store, known), label, file: file, line: line)
        try assertStoredAsJsonb(provider, "record_log_staged_base", staged, label, file: file, line: line)
    }

    // MARK: - Behaviour 1 (pin): the vehicle

    func testTheBundledSQLiteRoundTripsJsonbByteForByte() async throws {
        let provider = try await makeProvider()
        let spellings = [
            #"{"a":1.0}"#, #"{"a":1E5}"#, #"{"a":-0}"#, #"{"a":9007199254740993}"#, #"{"a":"é"}"#, #"{"a":"\/"}"#,
            #"{"a":"\u0001\n\t\u001f"}"#, "{\"a\":\"\u{2028}\"}", #"{"z":1,"a":2,"m":[3,{"y":null,"b":true}]}"#,
        ]
        for text in spellings {
            let back = try XCTUnwrap(try rows(provider, "SELECT json(jsonb(?)) AS text, typeof(jsonb(?)) AS kind", [.text(text), .text(text)]).first)
            XCTAssertEqual(back["kind"].stringValue, "blob", text)
            XCTAssertTrue((back["text"].stringValue ?? "").utf8.elementsEqual(text.utf8), "\(back["text"].stringValue ?? "nil") is not \(text)")
        }
        // A row as the store writes it, `id` dropped, reads back as the row's text without `id`.
        let row: RecordLogRow = [
            "id": "r\"1\\é", "title": "é \u{2028} \u{1}", "n": 1.5, "big": 9_007_199_254_740_991, "tags": ["b", "a"],
            "nested": ["k": nil, "list": [1, "two"]], "flag": false,
        ]
        let text = RecordLogJSON.text(.object(row))
        let back = try rows(provider, "SELECT json(jsonb(json_remove(?, '$.id'))) AS text", [.text(text)]).first?["text"].stringValue
        XCTAssertTrue((back ?? "").utf8.elementsEqual(textWithoutId(row).utf8), "\(back ?? "nil") is not \(textWithoutId(row))")
    }

    // MARK: - Behaviour 2: every write stores JSONB without id

    func testEveryWriteStoresJsonbWithoutId() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)

        // A segment's chunk and its corrections, received as a first load.
        let attempt = try store.beginReceipt(writer: writer, kind: .segment, id: "G1").attempt
        let first = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applySegmentChunk(
            writer: writer, generation: first, attempt: attempt,
            rows: [note("s1", ["title": "segment one", "n": 1]), note("s2", ["title": "segment two"])]
        )
        try assertEveryTableJsonb(provider, store, "a segment chunk")
        _ = try store.applySegmentCorrections(writer: writer, generation: first, attempt: attempt, lines: [
            RecordLogCorrection(model: "Note", id: "s2", row: note("s2", ["title": "corrected", "slug": "s-2"]).row),
            RecordLogCorrection(model: "Note", id: "s3", row: note("s3", ["title": "added later"]).row),
        ])
        _ = try store.completeCatchUp(writer: writer, lsn: 5, full: true, generation: first, receipt: attempt, at: 1_000)
        try assertEveryTableJsonb(provider, store, "a corrections chunk")
        XCTAssertEqual(try store.read(model: "Note", id: "s2"), ["id": "s2", "title": "corrected", "slug": "s-2"])

        // A catch-up page.
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(
            writer: writer, rows: [note("a", ["title": "a1", "slug": "s-a"]), note("b", ["title": "b1", "slug": "s-b"])], lsn: 6
        )
        _ = try store.completeCatchUp(writer: writer, lsn: 6)
        try assertEveryTableJsonb(provider, store, "a catch-up page")

        // A load chunk, its view rows copied in a batch.
        let load = try store.beginReceipt(writer: writer, kind: .load, id: "L1").attempt
        _ = try store.applyLoadChunk(writer: writer, sessionId: "L1", attempt: load, model: "Note", lines: [
            RecordLogLoadLine(id: "l1", patch: ["title": "loaded", "n": 2.5]),
            RecordLogLoadLine(id: "l2", patch: ["title": "loaded too", "tags": ["x", "y"]]),
        ])
        _ = try store.completeLoad(writer: writer, sessionId: "L1", attempt: load, mode: .merge, models: ["Note"])
        try assertEveryTableJsonb(provider, store, "a load chunk")

        // Local commits: a create, a patch, a set change and an upsert's guess.
        try commit(store, writer, mutation("c", .create, ["title": "mine", "tags": ["p"]]))
        try commit(store, writer, mutation("a", .patch, ["title": "patched", "n": nil]))
        try commit(store, writer, mutation("c", .patch, tags: ["q": true, "p": false]))
        try commit(store, writer, mutation("u-new", .create, ["slug": "s-b", "title": "upserted"]), upsertOn: "slug")
        XCTAssertEqual(try store.read(model: "Note", id: "b")?["title"], "upserted", "the upsert's guess lands on b")
        XCTAssertEqual(try store.read(model: "Note", id: "c")?["tags"], ["q"])
        try assertEveryTableJsonb(provider, store, "local commits")

        // A staged replacement keeps the previous rows as they are stored, and none for a record that had none.
        let before = try confirmed(store)
        let second = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertTrue(try store.storedState().staged)
        _ = try store.applyCatchUpPage(
            writer: writer, rows: [note("a", ["title": "a2"]), note("fresh", ["title": "new in the replacement"])],
            lsn: 9, generation: second
        )
        try commit(store, writer, mutation("a", .patch, ["n": 7]))
        XCTAssertEqual(try store.read(model: "Note", id: "a")?["title"], "patched", "the guess reads the staged base")
        try assertEveryTableJsonb(provider, store, "a staged replacement", staged: ["a": before["a"] ?? nil, "fresh": .none])
        let held = try rows(provider, "SELECT _data IS NULL AS absent FROM record_log_staged_base WHERE doc_id = 'doc-1' AND _id = 'fresh'")
        XCTAssertEqual(held.first?["absent"].intValue, 1, "a record that had no row has a NULL base")
        _ = try store.completeCatchUp(writer: writer, lsn: 9, full: true, generation: second, at: 2_000)
        try assertEveryTableJsonb(provider, store, "the replacement's completion")
        XCTAssertEqual(try store.read(model: "Note", id: "a"), ["id": "a", "title": "patched", "n": 7])
    }

    // MARK: - Behaviour 9: mixed encodings

    /// A row as an older build wrote it: JSON text with `id`, in both tables.
    private func plantText(_ provider: SQLiteStorageProvider, _ row: RecordLogRow) throws {
        let id = row["id"]?.stringValue ?? ""
        try provider.withConnection { connection in
            for table in ["record_log_rows", "record_log_view"] {
                try connection.execute(
                    "INSERT INTO \(table) (doc_id, _type, _id, _data) VALUES ('doc-1', 'Note', ?, ?)",
                    [.text(id), .text(RecordLogJSON.text(.object(row)))]
                )
            }
        }
    }

    private func kind(_ provider: SQLiteStorageProvider, _ table: String, _ id: String) throws -> String? {
        try rows(provider, "SELECT typeof(_data) AS kind FROM \(table) WHERE doc_id = 'doc-1' AND _id = ?", [.text(id)])
            .first?["kind"].stringValue
    }

    func testARowAnOlderBuildWroteReadsBesideJsonbRowsAndIsReencodedOnItsNextWrite() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            note("a", ["title": "jsonb", "slug": "s-a", "my-field": "x"]), note("b", ["title": "jsonb too", "slug": "s-b"]),
        ], lsn: 3)
        _ = try store.completeCatchUp(writer: writer, lsn: 3)
        let old: RecordLogRow = ["id": "old", "title": "older build", "slug": "s-old", "my-field": "y"]
        try plantText(provider, old)
        XCTAssertEqual(try kind(provider, "record_log_view", "old"), "text")
        XCTAssertEqual(try kind(provider, "record_log_view", "a"), "blob")

        XCTAssertEqual(try store.read(model: "Note", id: "old"), old)
        XCTAssertEqual(try store.readMany(model: "Note", ids: ["old", "a", "gone"]), [
            old, ["id": "a", "title": "jsonb", "slug": "s-a", "my-field": "x"], nil,
        ])
        let page = try store.queryView("Note", options: QueryOptions(sort: ["id": 1]))
        XCTAssertEqual(page.data.map { $0["id"]?.stringValue }, ["a", "b", "old"])
        XCTAssertEqual(page.data.last, old)

        // A lookup on `id` reads the key, whatever the row holds.
        XCTAssertEqual(try store.findIdByFields(model: "Note", fields: ["id"], values: ["old"]), "old")
        XCTAssertEqual(try store.findIdByFields(model: "Note", fields: ["id"], values: ["a"]), "a")
        XCTAssertEqual(try store.findIdByFields(model: "Note", fields: ["id", "slug"], values: ["b", "s-b"]), "b")
        XCTAssertNil(try store.findIdByFields(model: "Note", fields: ["id", "slug"], values: ["b", "s-a"]))
        XCTAssertEqual(try store.findIdByFields(model: "Note", fields: ["my-field", "id"], values: ["x", "a"]), "a", "the bound branch")
        XCTAssertEqual(try store.findIdByFields(model: "Note", fields: ["my-field", "id"], values: ["y", "old"]), "old")
        // An upsert's holder lookup on the confirmed rows.
        let holders = try store.readView { sql in
            (
                try RecordLogStore.findHolders(
                    sql, table: "record_log_rows", docId: "doc-1", model: "Note", fields: ["id"], values: ["a"],
                    excluding: [], limitToFirst: true
                ),
                try RecordLogStore.findHolders(
                    sql, table: "record_log_rows", docId: "doc-1", model: "Note", fields: ["slug", "id"], values: ["s-old", "old"],
                    excluding: [], limitToFirst: false
                ),
                try RecordLogStore.findHolders(
                    sql, table: "record_log_rows", docId: "doc-1", model: "Note", fields: ["id"], values: ["a"],
                    excluding: ["a"], limitToFirst: true
                )
            )
        }
        XCTAssertEqual(holders.0, ["a"])
        XCTAssertEqual(holders.1, ["old"])
        XCTAssertEqual(holders.2, [])

        // The next write re-encodes the older row.
        try commit(store, writer, mutation("old", .patch, ["title": "patched"]))
        XCTAssertEqual(try kind(provider, "record_log_view", "old"), "blob")
        XCTAssertEqual(try kind(provider, "record_log_rows", "old"), "text", "the confirmed row is the room's to change")
        XCTAssertEqual(try store.read(model: "Note", id: "old"), ["id": "old", "title": "patched", "slug": "s-old", "my-field": "y"])
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: [note("old", ["title": "patched", "slug": "s-old", "my-field": "y"])], lsn: 4)
        XCTAssertEqual(try kind(provider, "record_log_rows", "old"), "blob")
        XCTAssertEqual(
            try rows(provider, "SELECT json_extract(_data, '$.id') IS NULL AS gone FROM record_log_view WHERE _id = 'old'").first?["gone"].intValue, 1
        )
    }

    /// Edge: a view row an older build wrote as text, in the rollback window,
    /// differs from its JSONB rewrite by its bytes, so the staged
    /// replacement that rewrites it names it changed, once, with its row.
    func testAStagedReplacementNamesATextRowItRewroteAsJsonbOnceWithItsRow() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        let first = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applyCatchUpPage(
            writer: writer, rows: [note("a", ["title": "a1"]), note("b", ["title": "b1"])], lsn: 5, generation: first
        )
        _ = try store.completeCatchUp(writer: writer, lsn: 5, full: true, generation: first, at: 1_000)
        try provider.withConnection { connection in
            for table in ["record_log_rows", "record_log_view"] {
                try connection.execute(
                    "UPDATE \(table) SET _data = ? WHERE doc_id = 'doc-1' AND _id = 'a'", [.text(#"{"id":"a","title":"a1"}"#)]
                )
            }
        }
        XCTAssertEqual(try kind(provider, "record_log_view", "a"), "text")

        let second = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applyCatchUpPage(
            writer: writer, rows: [note("a", ["title": "a1"]), note("b", ["title": "b1"])], lsn: 9, generation: second
        )
        let done = try store.completeCatchUp(writer: writer, lsn: 9, full: true, generation: second, at: 2_000)
        XCTAssertEqual(done.changed, [RecordLogRowChange(model: "Note", id: "a", row: ["id": "a", "title": "a1"])])
        XCTAssertEqual(try kind(provider, "record_log_view", "a"), "blob")
        XCTAssertEqual(try store.read(model: "Note", id: "a"), ["id": "a", "title": "a1"])
    }

    // MARK: - Behaviour 10 (pin): the page byte budget

    /// `rows` of `model` confirmed by one catch-up page.
    private func caughtUp(_ store: RecordLogStore, _ writer: String, _ rows: [RecordLogRow], model: String) throws {
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: rows.map {
            RecordLogCatchUpRow(model: model, id: $0["id"]?.stringValue ?? "", row: $0)
        }, lsn: 1)
        _ = try store.completeCatchUp(writer: writer, lsn: 1)
    }

    func testAPageCountsEachRowAsItsJsonWithIdAndCutsWhereThatSumPasses8MiB() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        let limit = Db3Limits.responseMaxBytes
        // Seven large rows whose ids need escaping, then one sized so that the
        // page passes the limit only when its `id` is counted.
        let ids = ["b1\"q", "b2\\q", "b3é", "b4\u{1}", "b5\u{2028}", "b6", "b7"]
        var big: [RecordLogRow] = ids.map { ["id": .string($0), "body": .string(String(repeating: "x", count: 1_100_000)), "n": 1] }
        let used = big.reduce(0) { $0 + RecordLogJSON.bytes(.object($1)) }
        var crossing: RecordLogRow = ["id": "b8", "body": ""]
        let base = RecordLogJSON.bytes(.object(crossing))
        crossing["body"] = .string(String(repeating: "y", count: limit - used - base + 1))
        XCTAssertEqual(used + RecordLogJSON.bytes(.object(crossing)), limit + 1)
        var withoutId = crossing
        withoutId["id"] = nil
        XCTAssertLessThanOrEqual(used + RecordLogJSON.bytes(.object(withoutId)), limit, "without its id the row would fit")
        big.append(crossing)
        big.append(["id": "b9", "body": "small"])
        try caughtUp(store, writer, big, model: "Note")

        let page = try store.queryView("Note", options: QueryOptions(sort: ["id": 1]))
        XCTAssertEqual(page.data.map { $0["id"]?.stringValue }, ids, "the page ends before the row that passes 8 MiB")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.data, Array(big.prefix(7)), "each row with its id")
        let projected = try store.queryView("Note", options: QueryOptions(sort: ["id": 1], projection: ["absent": 0]))
        XCTAssertEqual(projected.data.map { $0["id"]?.stringValue }, ids, "the same cut as a projection that drops nothing")
        XCTAssertTrue(projected.hasMore)
        let next = try store.queryView("Note", options: QueryOptions(sort: ["id": 1], cursor: page.nextCursor))
        XCTAssertEqual(next.data.map { $0["id"]?.stringValue }, ["b8", "b9"])

        // A row that holds nothing but its id is stored as `{}` and counts as `{"id":…}`: it fits exactly.
        var exact: [RecordLogRow] = big.prefix(7).map { row in
            var row = row
            row["id"] = .string("a" + (row["id"]?.stringValue ?? ""))
            return row
        }
        let filled = exact.reduce(0) { $0 + RecordLogJSON.bytes(.object($1)) }
        let solo = "c" + String(repeating: "z", count: limit - filled - RecordLogJSON.bytes(.object(["id": "c"])))
        XCTAssertEqual(filled + RecordLogJSON.bytes(.object(["id": .string(solo)])), limit)
        exact.append(["id": .string(solo)])
        exact.append(["id": "d"])
        try caughtUp(store, writer, exact, model: "Solo")
        let fitted = try store.queryView("Solo", options: QueryOptions(sort: ["id": 1]))
        XCTAssertEqual(fitted.data.count, 8, "the id-only row ends the page at exactly 8 MiB")
        XCTAssertEqual(fitted.data.last, ["id": .string(solo)])
        XCTAssertTrue(fitted.hasMore)
        XCTAssertEqual(
            try rows(provider, "SELECT json(_data) AS text FROM record_log_view WHERE _type = 'Solo' AND _id = 'd'").first?["text"].stringValue,
            "{}"
        )
        XCTAssertEqual(try store.read(model: "Solo", id: "d"), ["id": "d"])
    }
}
