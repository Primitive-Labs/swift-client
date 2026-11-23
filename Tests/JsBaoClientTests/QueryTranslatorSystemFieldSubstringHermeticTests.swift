import XCTest
@testable import JsBaoClient

/// #5136 behaviour 16 (finding F1), and behaviour 9's filters over mixed
/// encodings: `$startsWith`, `$endsWith` and `$containsText` on `id` or
/// `type` in the view mode match the record's key or model column with one
/// `LIKE`, over JSONB rows without `id` and over text rows an older build
/// wrote with it, so they answer what a filter over the keys answers. The
/// pattern's checks (a string value, trimmed, empty as no condition,
/// escaped, at most 1,024 characters) and every other field's statement are
/// unchanged. The Swift twin of #5134's F2 fix in js-bao's translator.
final class QueryTranslatorSystemFieldSubstringHermeticTests: XCTestCase {

    /// Record keys a pattern's `%`, `_` and `\` must match literally.
    private static let memoIds = ["M-2", "a\\b", "m%4", "m-1", "m_3", "mx3", "zz-m"]

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    /// A store whose view holds `Memo` and `Note` rows the store wrote, one
    /// `Memo` row as an older build wrote it (text with `id`) and one as
    /// JSONB without `id` planted directly.
    private func store() async throws -> (SQLiteStorageProvider, RecordLogStore) {
        let directory = NSTemporaryDirectory() + "/record-log-system-substring-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-1")
        try store.initialize()
        let writer = try store.mintWriter()
        var rows = Self.memoIds.enumerated().map { i, id in
            RecordLogCatchUpRow(model: "Memo", id: id, row: [
                "id": .string(id), "title": .string("memo \(i)"), "tags": i % 2 == 0 ? ["red", "blue"] : ["green"],
            ])
        }
        rows.append(RecordLogCatchUpRow(model: "Note", id: "m-note", row: ["id": "m-note", "title": "a note"]))
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: rows, lsn: 1)
        _ = try store.completeCatchUp(writer: writer, lsn: 1)
        try provider.withConnection { connection in
            try connection.execute(
                "INSERT INTO record_log_view (doc_id, _type, _id, _data) VALUES ('doc-1', 'Memo', 'm-text', ?)",
                [.text(#"{"id":"m-text","tags":["red"],"title":"older build"}"#)]
            )
            try connection.execute(
                "INSERT INTO record_log_view (doc_id, _type, _id, _data) VALUES ('doc-1', 'Memo', 'm-blob', jsonb(?))",
                [.text(#"{"tags":[],"title":"planted"}"#)]
            )
        }
        return (provider, store)
    }

    private static var allMemoIds: [String] { memoIds + ["m-blob", "m-text"] }

    /// The `Memo` ids `filter` answers, through a page and through `count`.
    private func ids(_ store: RecordLogStore, _ filter: DocumentFilter, model: String = "Memo") throws -> [String] {
        let page = try store.queryView(model, filter, options: QueryOptions(sort: ["id": 1], limit: 100))
        let found = page.data.map { $0["id"]?.stringValue ?? "<no id>" }
        XCTAssertEqual(try store.countView(model, filter), found.count, "count answers as the page: \(filter)")
        return found.sorted()
    }

    /// What a filter over the keys answers: SQLite's `LIKE` folds ASCII case only.
    private func keys(_ match: (String) -> Bool) -> [String] {
        Self.allMemoIds.filter { match($0.lowercased()) }.sorted()
    }

    func testSubstringFiltersOnIdMatchTheKeyOfJsonbRowsAndOfTextRows() async throws {
        let (_, store) = try await store()
        XCTAssertEqual(try ids(store, ["id": ["$startsWith": "m-"]]), keys { $0.hasPrefix("m-") })
        XCTAssertEqual(try ids(store, ["id": ["$startsWith": "m-"]]), ["M-2", "m-1", "m-blob", "m-text"])
        XCTAssertEqual(try ids(store, ["id": ["$endsWith": "-1"]]), keys { $0.hasSuffix("-1") })
        XCTAssertEqual(try ids(store, ["id": ["$endsWith": "XT"]]), ["m-text"], "case is folded")
        XCTAssertEqual(try ids(store, ["id": ["$containsText": "-"]]), keys { $0.contains("-") })
        XCTAssertEqual(try ids(store, ["id": ["$containsText": "blob"]]), ["m-blob"], "a JSONB row without id matches on its key")
        XCTAssertEqual(try ids(store, ["id": ["$containsText": "text"]]), ["m-text"], "a text row with id matches on its key")
        for row in try store.queryView("Memo", ["id": ["$startsWith": "m-"]]).data {
            XCTAssertNotNil(row["id"]?.stringValue, "each row answers its id")
        }
    }

    func testAPatternsWildcardsAndEscapeMatchTheLiteralCharacterInTheKey() async throws {
        let (_, store) = try await store()
        XCTAssertEqual(try ids(store, ["id": ["$startsWith": "m_"]]), ["m_3"], "`_` is not a wildcard")
        XCTAssertEqual(try ids(store, ["id": ["$containsText": "%"]]), ["m%4"], "`%` is not a wildcard")
        XCTAssertEqual(try ids(store, ["id": ["$containsText": "\\"]]), ["a\\b"], "`\\` is matched, not an escape")
        XCTAssertEqual(try ids(store, ["id": ["$startsWith": "  m%  "]]), ["m%4"], "trimmed")
    }

    func testSubstringFiltersOnTypeMatchTheModel() async throws {
        let (_, store) = try await store()
        XCTAssertEqual(try ids(store, ["type": ["$startsWith": "me"]]), Self.allMemoIds.sorted())
        XCTAssertEqual(try ids(store, ["type": ["$endsWith": "MO"]]), Self.allMemoIds.sorted())
        XCTAssertEqual(try ids(store, ["type": ["$containsText": "note"]]), [])
        XCTAssertEqual(try ids(store, ["type": ["$containsText": "ot"]], model: "Note"), ["m-note"])
    }

    func testTheStatementMatchesTheColumnWithOneLikeAndOtherFieldsKeepTheirs() throws {
        for (field, column) in [("id", "\"_id\""), ("type", "\"_type\"")] {
            for (op, pattern) in [("$startsWith", "ab%"), ("$endsWith", "%ab"), ("$containsText", "%ab%")] {
                let (clause, params) = try QueryTranslator.translateView([field: [op: "ab"]])
                XCTAssertEqual(clause, "\(column) LIKE ? ESCAPE '\\' COLLATE NOCASE", "\(field) \(op)")
                XCTAssertFalse(clause.contains("json_type("), clause)
                XCTAssertEqual(params.compactMap { $0 as? String }, [pattern], "\(field) \(op)")
            }
        }
        let (title, params) = try QueryTranslator.translateView(["title": ["$startsWith": "ab"]])
        XCTAssertEqual(
            title,
            "((json_type(record_log_view._data, '$.title') <> 'array' AND json_extract(_data, '$.title') LIKE ? ESCAPE '\\' COLLATE NOCASE) "
                + "OR (json_type(record_log_view._data, '$.title') = 'array' AND EXISTS (SELECT 1 FROM json_each(record_log_view._data, '$.title') "
                + "AS _set WHERE _set.value LIKE ? ESCAPE '\\' COLLATE NOCASE)))",
            "a field of the record's JSON keeps today's statement"
        )
        XCTAssertEqual(params.compactMap { $0 as? String }, ["ab%", "ab%"])
    }

    func testAnIdFilterBesideASetFilterKeepsBothWings() async throws {
        let (_, store) = try await store()
        let either: DocumentFilter = ["$or": [["id": ["$endsWith": "-1"]], ["tags": ["$containsText": "gree"]]]]
        let (clause, _) = try QueryTranslator.translateView(either)
        XCTAssertTrue(clause.contains("\"_id\" LIKE ? ESCAPE '\\' COLLATE NOCASE"), clause)
        XCTAssertTrue(clause.contains("json_each(record_log_view._data, '$.tags')"), clause)
        XCTAssertEqual(try ids(store, either), ["a\\b", "m-1", "mx3"])
        let both: DocumentFilter = ["$and": [["id": ["$startsWith": "m"]], ["tags": ["$contains": "red"]]]]
        XCTAssertEqual(try ids(store, both), ["M-2", "m%4", "m-text", "m_3"])
    }

    func testThePatternsRefusalsAndNoOpAreUnchanged() async throws {
        let (_, store) = try await store()
        XCTAssertEqual(try ids(store, ["id": ["$startsWith": "   "]]), Self.allMemoIds.sorted(), "whitespace only adds no condition")
        XCTAssertEqual(try QueryTranslator.translateView(["type": ["$endsWith": " "]]).0, "1=1")
        XCTAssertThrowsError(try QueryTranslator.translateView(["id": ["$startsWith": .string(String(repeating: "a", count: 1_025))]])) {
            XCTAssertEqual(($0 as? JsBaoError)?.code, .invalidArgument, "\($0)")
        }
        XCTAssertNoThrow(try QueryTranslator.translateView(["id": ["$startsWith": .string(String(repeating: "a", count: 1_024))]]))
        XCTAssertThrowsError(try QueryTranslator.translateView(["type": ["$containsText": 5]])) {
            XCTAssertEqual(($0 as? JsBaoError)?.code, .invalidArgument, "\($0)")
        }
        XCTAssertThrowsError(try QueryTranslator.translateView(["id": ["$startsWith": "a", "$endsWith": "b"]])) {
            XCTAssertEqual(($0 as? JsBaoError)?.code, .invalidArgument, "\($0)")
        }
        // The column mode's gate on a field that is not a string is its own, as it was.
        XCTAssertThrowsError(try QueryTranslator.translate(["id": ["$startsWith": "a"]], stringFields: ["title"])) {
            XCTAssertEqual(($0 as? JsBaoError)?.code, .invalidArgument, "\($0)")
        }
        XCTAssertEqual(
            try QueryTranslator.translate(["title": ["$startsWith": "a"]], stringFields: ["title"]).0,
            "\"title\" LIKE ? ESCAPE '\\' COLLATE NOCASE"
        )
    }
}
