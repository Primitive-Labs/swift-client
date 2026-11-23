import XCTest
@testable import JsBaoClient

/// #5223 behavior 11 and edge cases E4, E13 — `$search`'s grammar, the
/// Swift port of js-bao's `query/textSearch.ts`, pinned to it by the JS
/// suite's own fixtures (`db3-text-search-match-5222.test.ts`): the MATCH
/// text is quoted words and phrases only, byte for byte as js-bao emits it;
/// every hostile input runs on the bundled FTS5 as plain words; a NUL splits
/// words; refusals carry js-bao's messages.
final class Db3TextSearchGrammarHermeticTests: XCTestCase {

    private static let fields = ["title", "body"]

    private func match(_ search: JSONValue, _ fields: [String] = fields) throws -> String {
        try RecordLogTextSearch.match(try RecordLogTextSearch.parse(search), indexFields: fields)
    }

    /// A contentless FTS5 table over `columns` aliases holding `rows` by rowid, on the bundled SQLite.
    private func ftsTable(_ columns: Int, _ rows: [[JSONValue]]) async throws -> (String) throws -> [Int] {
        let provider = SQLiteStorageProvider(path: nil)
        try await provider.initialize(namespace: "grammar-\(UUID().uuidString)")
        let names = (0..<columns).map { "f\($0)" }
        try provider.withConnection { connection in
            try connection.executeScript(
                "CREATE VIRTUAL TABLE t USING fts5(\(names.joined(separator: ", ")), content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2')"
            )
            for row in rows {
                try connection.execute(
                    "INSERT INTO t (rowid, \(names.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: columns + 1).joined(separator: ", ")))",
                    row.map { value in
                        switch value {
                        case .number(let n): return .integer(Int64(n))
                        case .string(let s): return .text(s)
                        default: return .null
                        }
                    }
                )
            }
        }
        return { text in
            try provider.withConnection { try $0.query("SELECT rowid FROM t WHERE t MATCH ? ORDER BY rowid", [.text(text)]) }
                .compactMap { $0["rowid"].intValue }
        }
    }

    func testParsesAStringAsAQueryAndTheObjectsOptionsWithTheirDefaults() throws {
        let plain = try RecordLogTextSearch.parse("hello world")
        XCTAssertEqual(plain.terms, [.init(text: "hello", phrase: false), .init(text: "world", phrase: false)])
        XCTAssertEqual(plain.mode, .all)
        XCTAssertFalse(plain.prefix)
        XCTAssertNil(plain.fields)
        let object = try RecordLogTextSearch.parse(["query": "a \"b c\"", "mode": "any", "prefix": true, "fields": ["title"]])
        XCTAssertEqual(object.terms, [.init(text: "a", phrase: false), .init(text: "b c", phrase: true)])
        XCTAssertEqual(object.mode, .any)
        XCTAssertTrue(object.prefix)
        XCTAssertEqual(object.fields, ["title"])
        XCTAssertEqual(try RecordLogTextSearch.parse(["query": "a", "fields": ["title", "body", "title"]]).fields, ["title", "body"])
    }

    private static let hostile: [(String, String)] = [
        ("a\"b", "\"a\"\"b\""),
        ("a*", "\"a*\""),
        ("NEAR", "\"NEAR\""),
        ("OR", "\"OR\""),
        ("AND", "\"AND\""),
        ("NOT", "\"NOT\""),
        ("^a", "\"^a\""),
        ("title:x", "\"title:x\""),
        ("{a}", "\"{a}\""),
        ("(a)", "\"(a)\""),
        ("-a", "\"-a\""),
        ("a OR b", "\"a\" AND \"OR\" AND \"b\""),
        ("NEAR(a b)", "\"NEAR(a\" AND \"b)\""),
        ("\"open phrase", "\"open phrase\""),
        ("one \"two three\" four", "\"one\" AND \"two three\" AND \"four\""),
        ("x \"\" y", "\"x\" AND \"y\""),
    ]

    func testEmitsEveryHostileInputAsJsBaoDoes() throws {
        for (input, text) in Self.hostile {
            XCTAssertEqual(try match(.string(input)), text, input)
        }
    }

    func testRunsEveryHostileMatchTextOnTheBundledFTS5MatchingPlainWordsOnly() async throws {
        let search = try await ftsTable(2, [
            [1, "near or and not", nil], [2, "a b", "title x"], [3, "open phrase here", nil],
            [4, "phrase open", nil], [5, "one two three four", nil], [6, "one three two four", nil],
        ])
        for (input, _) in Self.hostile { XCTAssertNoThrow(try search(try match(.string(input))), input) }
        XCTAssertEqual(try search(try match("NEAR")), [1])
        XCTAssertEqual(try search(try match("OR")), [1])
        XCTAssertEqual(try search(try match("NOT AND")), [1])
        XCTAssertEqual(try search(try match("title:x")), [2])
        XCTAssertEqual(try search(try match("a OR b")), [])
        XCTAssertEqual(try search(try match("{a}")), [2])
        XCTAssertEqual(try search(try match("-a")), [2])
        XCTAssertEqual(try search(try match("a\"b")), [2])
        XCTAssertEqual(try search(try match("\"open phrase")), [3])
        XCTAssertEqual(try search(try match("one \"two three\" four")), [5])
        XCTAssertEqual(try search(try match("x y", Self.fields)), [])
        XCTAssertEqual(try search(try match(["query": "x y", "mode": "any"])), [2])
    }

    /// E4: a NUL splits words, so none reaches FTS5 inside a quoted string; a NUL alone is refused.
    func testSplitsWordsOnANul() async throws {
        let search = try await ftsTable(1, [[1, "hello world"], [2, "hello"]])
        XCTAssertEqual(try match("hello\u{0}world"), "\"hello\" AND \"world\"")
        XCTAssertEqual(try match("\u{0}hello"), "\"hello\"")
        XCTAssertEqual(try match("hello\u{0}"), "\"hello\"")
        XCTAssertEqual(try match("\"hello\u{0}world\""), "\"hello world\"")
        for input in ["hello\u{0}world", "\u{0}hello", "hello\u{0}", "\"hello\u{0}world\""] {
            XCTAssertNoThrow(try search(try match(.string(input))), input.debugDescription)
        }
        XCTAssertEqual(try search(try match("hello\u{0}world")), [1])
        XCTAssertEqual(refusal("\u{0}")?.message, "$search needs at least one word to find")
    }

    func testSuffixesEachWordAndPhraseUnderPrefixAndJoinsByOrUnderAny() async throws {
        XCTAssertEqual(try match(["query": "ph \"open ph\"", "prefix": true]), "\"ph\"* AND \"open ph\"*")
        XCTAssertEqual(try match(["query": "a b", "mode": "any"]), "\"a\" OR \"b\"")
        let search = try await ftsTable(1, [[1, "phrase open"], [2, "open phrase"], [3, "philosophy"]])
        XCTAssertEqual(try search(try match(["query": "ph \"open ph\"", "prefix": true])), [2])
        XCTAssertEqual(try search(try match(["query": "ph", "prefix": true])), [1, 2, 3])
    }

    func testRestrictsToFieldsThroughTheIndexsAliasesWhateverTheFieldNames() async throws {
        XCTAssertEqual(try match(["query": "a b", "fields": ["body"]]), "{\"f1\"} : (\"a\" AND \"b\")")
        let fields = ["rank", "rowid", "OR", "Title", "title"]
        XCTAssertEqual(try match(["query": "w", "fields": ["OR", "rank"]], fields), "{\"f2\" \"f0\"} : (\"w\")")
        XCTAssertEqual(try match(["query": "w", "fields": ["Title"]], fields), "{\"f3\"} : (\"w\")")
        let search = try await ftsTable(5, [
            [1, "w", nil, nil, nil, nil], [2, nil, nil, "w", nil, nil], [3, nil, nil, nil, nil, "w"], [4, nil, nil, nil, "w", nil],
        ])
        XCTAssertEqual(try search(try match(["query": "w", "fields": ["rank"]], fields)), [1])
        XCTAssertEqual(try search(try match(["query": "w", "fields": ["OR"]], fields)), [2])
        XCTAssertEqual(try search(try match(["query": "w", "fields": ["Title"]], fields)), [4])
        XCTAssertEqual(try search(try match(["query": "w", "fields": ["title"]], fields)), [3])
        XCTAssertEqual(try search(try match(["query": "w"], fields)), [1, 2, 3, 4])
    }

    private func refusal(_ search: JSONValue, fields: [String] = fields, file: StaticString = #filePath, line: UInt = #line) -> JsBaoError? {
        do {
            _ = try match(search, fields)
            XCTFail("\(search) was not refused", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument, file: file, line: line)
            return error
        } catch {
            XCTFail("threw \(error)", file: file, line: line)
        }
        return nil
    }

    func testRefusesEachInvalidSearchWithJsBaosMessage() {
        let noWord = "$search needs at least one word to find"
        let refused: [(JSONValue, String)] = [
            ("", noWord), ("   ", noWord), ("...", noWord), ("\"", noWord), ("\"\"\"", noWord), ("*", noWord),
            (["query": ""], noWord),
            (42, "$search must be a string or { query, mode?, prefix?, fields? }"),
            (.null, "$search must be a string or { query, mode?, prefix?, fields? }"),
            (["a"], "$search must be a string or { query, mode?, prefix?, fields? }"),
            (["query": 1], "$search.query must be a string"),
            (["mode": "any"], "$search.query must be a string"),
            (["query": "a", "mode": "some"], "$search.mode must be \"all\" or \"any\""),
            (["query": "a", "prefix": "yes"], "$search.prefix must be true or false"),
            (["query": "a", "fields": "title"], "$search.fields must be a non-empty array of field names"),
            (["query": "a", "fields": []], "$search.fields must be a non-empty array of field names"),
            (["query": "a", "fields": [1]], "$search.fields must be a non-empty array of field names"),
            (["query": "a", "near": 2], "$search.near is not a search option: give query, mode, prefix or fields"),
        ]
        for (search, message) in refused {
            XCTAssertEqual(refusal(search)?.message, message, "\(search)")
        }
    }

    /// E13: a `fields` entry the index does not cover is refused, naming it and the index's fields.
    func testRefusesFieldsOutsideTheIndexNamingThem() {
        XCTAssertEqual(refusal(["query": "a", "fields": ["tags"]])?.message,
                       "$search.fields names tags, which the text index does not cover: title, body")
    }
}
