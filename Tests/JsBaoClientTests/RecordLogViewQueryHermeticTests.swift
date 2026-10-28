import XCTest
@testable import JsBaoClient

/// A query on any field of a format-3 document, answered from the store's
/// `record_log_view` by the statement the room runs for the same filter.
///
/// - Behaviour 2: `QueryTranslator`'s view mode reads every field with
///   `json_extract` over `_data` (`id` as `_id`, `type` as `_type`), binds a
///   boolean as 1/0 and an integral number as an integer, compares the stored
///   JSON type, and refuses a name that is not an identifier; its column mode
///   is what it always was.
/// - Behaviour 3: membership (`$contains`, `$all`, `$size`) reads the array
///   the record holds with `json_each`; a substring operator on a field
///   holding an array matches its members; membership on a field that holds
///   no array matches nothing.
///
/// The Swift twin of js-bao's `record-log-client-view-query-4623.test.ts`.
final class RecordLogViewTranslatorHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-view-translator-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        try RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a").initialize()
        return provider
    }

    /// View rows written as a catch-up leaves them: `_data` is the row's JSON.
    private func seed(_ provider: SQLiteStorageProvider, _ rows: [(doc: String, model: String, row: JSONValue)]) throws {
        try provider.withConnection { connection in
            for (doc, model, row) in rows {
                try connection.execute(
                    "INSERT INTO record_log_view (doc_id, _type, _id, _data) VALUES (?, ?, ?, ?)",
                    [.text(doc), .text(model), .text(row["id"]?.stringValue ?? ""), .text(RecordLogJSON.text(row))]
                )
            }
        }
    }

    /// The ids of `Memo` in `doc-1` the translated filter matches, in id order.
    private func ids(_ provider: SQLiteStorageProvider, _ filter: DocumentFilter, model: String = "Memo") throws -> [String] {
        let (clause, params) = try QueryTranslator.translateView(filter)
        return try provider.withConnection { connection in
            try connection.query(
                "SELECT _id FROM record_log_view WHERE doc_id = ? AND _type = ? AND (\(clause)) ORDER BY _id",
                [.text("doc-1"), .text(model)] + params.map(Format2SqlValue.init(bindable:))
            )
        }.compactMap { $0["_id"].stringValue }
    }

    private func memos(_ provider: SQLiteStorageProvider) throws {
        try seed(provider, [
            ("doc-1", "Memo", ["id": "m1", "title": "Alpha", "n": 1, "done": true, "tags": ["a", "b"]]),
            ("doc-1", "Memo", ["id": "m2", "title": "beta", "n": 5, "done": false, "tags": ["b"]]),
            ("doc-1", "Memo", ["id": "m3", "title": "gamma", "n": "5", "tags": []]),
            ("doc-1", "Memo", ["id": "m4", "n": 9, "tags": ["a", "c"], "note": nil]),
            ("doc-1", "Note", ["id": "n1", "title": "Alpha", "n": 1]),
            ("doc-2", "Memo", ["id": "x1", "title": "Alpha", "n": 1]),
        ])
    }

    func testViewModeAnswersTheFilterGrammarOverTheStoredJSON() async throws {
        let provider = try await makeProvider()
        try memos(provider)
        XCTAssertEqual(try ids(provider, [:]), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(try ids(provider, ["title": "Alpha"]), ["m1"])
        XCTAssertEqual(try ids(provider, ["n": ["$eq": 1]]), ["m1"])
        XCTAssertEqual(try ids(provider, ["title": ["$ne": "Alpha"]]), ["m2", "m3", "m4"], "$ne includes a missing field")
        // SQLite orders any text above any number: the stored "5" is past 1.
        XCTAssertEqual(try ids(provider, ["n": ["$gt": 1]]), ["m2", "m3", "m4"])
        XCTAssertEqual(try ids(provider, ["n": ["$gte": 5, "$lt": 9]]), ["m2"])
        XCTAssertEqual(try ids(provider, ["n": ["$lte": 1]]), ["m1"])
        XCTAssertEqual(try ids(provider, ["n": ["$in": [1, 9]]]), ["m1", "m4"])
        XCTAssertEqual(try ids(provider, ["n": [1, 9]]), ["m1", "m4"], "an array is $in, as js-bao reads it")
        XCTAssertEqual(try ids(provider, ["n": ["$nin": [1, 9]]]), ["m2", "m3"])
        XCTAssertEqual(try ids(provider, ["title": ["$exists": false]]), ["m4"])
        XCTAssertEqual(try ids(provider, ["note": ["$exists": true]]), ["m4"], "a stored null exists, as in js-bao")
        XCTAssertEqual(try ids(provider, ["title": ["$startsWith": "al"]]), ["m1"])
        XCTAssertEqual(try ids(provider, ["title": ["$endsWith": "TA"]]), ["m2"])
        XCTAssertEqual(try ids(provider, ["title": ["$containsText": "amm"]]), ["m3"])
        XCTAssertEqual(try ids(provider, ["$and": [["n": ["$gte": 1]], ["tags": ["$contains": "b"]]]]), ["m1", "m2"])
        XCTAssertEqual(try ids(provider, ["$or": [["title": "beta"], ["n": 9]]]), ["m2", "m4"])
        XCTAssertEqual(try ids(provider, ["done": true]), ["m1"], "a boolean matches a stored boolean")
        XCTAssertEqual(try ids(provider, ["done": false]), ["m2"])
        XCTAssertEqual(try ids(provider, ["note": nil]), ["m1", "m2", "m3", "m4"], "null is IS NULL: missing or stored null")
        XCTAssertEqual(try ids(provider, ["id": "m2"]), ["m2"])
        XCTAssertEqual(try ids(provider, ["id": ["$in": ["m1", "m3"]]]), ["m1", "m3"])
        XCTAssertEqual(try ids(provider, ["type": "Memo", "n": 1]), ["m1"])
        XCTAssertEqual(try ids(provider, ["title": "Alpha"], model: "Note"), ["n1"])
    }

    /// Edge: an empty `$in` matches nothing, a `null` in `$nin` excludes a
    /// missing field, and `$exists: false` matches only a field the record
    /// lacks — `json_type` names a stored null, as js-bao's translator reads it.
    func testEmptyInNullInNinAndExistsFalseAsJsBaoAnswersThem() async throws {
        let provider = try await makeProvider()
        try memos(provider)
        XCTAssertEqual(try ids(provider, ["n": ["$in": []]]), [])
        XCTAssertEqual(try ids(provider, ["title": ["$nin": [nil]]]), ["m1", "m2", "m3"])
        XCTAssertEqual(try ids(provider, ["title": ["$nin": [nil, "beta"]]]), ["m1", "m3"])
        XCTAssertEqual(try ids(provider, ["note": ["$nin": [nil]]]), [], "a stored null is excluded with the missing")
        XCTAssertEqual(try ids(provider, ["note": ["$exists": false]]), ["m1", "m2", "m3"])
        XCTAssertEqual(try ids(provider, ["title": ["$exists": false]]), ["m4"])
    }

    func testViewModeComparesTheStoredJSONType() async throws {
        let provider = try await makeProvider()
        try memos(provider)
        XCTAssertEqual(try ids(provider, ["n": 5]), ["m2"], "5 does not match a stored \"5\"")
        XCTAssertEqual(try ids(provider, ["n": "5"]), ["m3"])
        XCTAssertEqual(try ids(provider, ["n": 5.0]), ["m2"])
        XCTAssertEqual(try ids(provider, ["Title": "Alpha"]), [], "field names compare exactly")
    }

    func testViewModeStatementsAndBindings() throws {
        let (equal, equalParams) = try QueryTranslator.translateView(["n": 5])
        XCTAssertEqual(equal, "json_extract(_data, '$.n') = ?")
        XCTAssertEqual(equalParams.first as? Int64, 5, "an integral number binds as an integer")
        let (_, realParams) = try QueryTranslator.translateView(["n": 1.5])
        XCTAssertEqual(realParams.first as? Double, 1.5)
        let (_, flagParams) = try QueryTranslator.translateView(["done": true])
        XCTAssertEqual(flagParams.first as? Int, 1, "a boolean binds as 1/0")
        let (missing, missingParams) = try QueryTranslator.translateView(["gone": nil])
        XCTAssertEqual(missing, "json_extract(_data, '$.gone') IS NULL")
        XCTAssertTrue(missingParams.isEmpty)
        let (byId, _) = try QueryTranslator.translateView(["id": "m1", "type": "Memo"])
        XCTAssertTrue(byId.contains("\"_id\" = ?"), byId)
        XCTAssertTrue(byId.contains("\"_type\" = ?"), byId)
        let (ne, _) = try QueryTranslator.translateView(["title": ["$ne": "a"]])
        XCTAssertEqual(ne, "(json_extract(_data, '$.title') IS NULL OR json_extract(_data, '$.title') != ?)")
    }

    func testViewModeRefusesANameThatIsNotAnIdentifier() throws {
        for filter: DocumentFilter in [
            ["bad field": 1],
            ["x') OR 1=1 --": 1],
            ["n": ["$gt": 1], "$or": [["a b": ["$exists": true]]]],
            ["tags": ["$contains": "a"], "é": 1],
        ] {
            XCTAssertThrowsError(try QueryTranslator.translateView(filter), "\(filter)") { error in
                let error = error as? JsBaoError
                XCTAssertEqual(error?.code, .invalidArgument)
                XCTAssertTrue(error?.message.contains("query field: Identifier") ?? false, error?.message ?? "")
            }
        }
        XCTAssertThrowsError(try QueryTranslator.translateView(["n": ["$regex": "x"]])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "an unknown operator is refused, not dropped")
        }
    }

    func testColumnModeIsUnchanged() throws {
        let (gt, gtParams) = try QueryTranslator.translate(["n": ["$gt": 1]])
        XCTAssertEqual(gt, "\"n\" > ?")
        XCTAssertEqual(gtParams.first as? Int64, 1)
        let (exists, _) = try QueryTranslator.translate(["n": ["$exists": false]])
        XCTAssertEqual(exists, "\"n\" IS NULL")
        let (member, _) = try QueryTranslator.translate(
            ["tags": ["$contains": "a"]], stringsetFields: ["tags"], tableName: "Memo"
        )
        XCTAssertTrue(member.contains("\"Memo__tags\""), member)
    }

    // MARK: - Behaviour 3: membership

    func testMembershipReadsTheStoredArray() async throws {
        let provider = try await makeProvider()
        try memos(provider)
        XCTAssertEqual(try ids(provider, ["tags": ["$contains": "a"]]), ["m1", "m4"])
        XCTAssertEqual(try ids(provider, ["tags": ["$all": ["a", "b"]]]), ["m1"])
        XCTAssertEqual(try ids(provider, ["tags": ["$all": []]]), [], "an empty $all matches nothing")
        XCTAssertEqual(try ids(provider, ["tags": ["$size": 0]]), ["m3"])
        XCTAssertEqual(try ids(provider, ["tags": ["$size": ["$gte": 2]]]), ["m1", "m4"])
        XCTAssertEqual(try ids(provider, ["tags": ["$containsText": "C"]]), ["m4"], "a substring operator matches a member")
        XCTAssertEqual(try ids(provider, ["tags": ["$startsWith": "b"]]), ["m1", "m2"])

        let (contains, params) = try QueryTranslator.translateView(["tags": ["$contains": "a"]])
        XCTAssertEqual(
            contains,
            "(json_type(record_log_view._data, '$.tags') = 'array' AND EXISTS (SELECT 1 FROM "
                + "json_each(record_log_view._data, '$.tags') AS _set WHERE _set.value = ?))"
        )
        XCTAssertEqual(params.first as? String, "a")
    }

    func testMembershipOnAFieldHoldingNoArrayMatchesNothing() async throws {
        let provider = try await makeProvider()
        try seed(provider, [
            ("doc-1", "Memo", ["id": "s", "tags": "a", "n": 1]),
            ("doc-1", "Memo", ["id": "t", "tags": ["a"], "n": 2]),
        ])
        XCTAssertEqual(try ids(provider, ["tags": ["$contains": "a"]]), ["t"])
        XCTAssertEqual(try ids(provider, ["tags": ["$all": ["a"]]]), ["t"])
        XCTAssertEqual(try ids(provider, ["missing": ["$size": 0]]), [])
        XCTAssertEqual(try ids(provider, ["n": ["$contains": "1"]]), [])
        XCTAssertEqual(try ids(provider, ["tags": ["$startsWith": "a"]]), ["s", "t"], "a scalar matches on itself")
    }
}

/// The store's `queryView` and `countView` (behaviours 4 and 5): one page of a
/// model's view rows in this document by the view-mode filter, sorted with
/// `id` breaking ties, paged by cursor both ways, and counted alike; no index
/// is built because a query named a field.
final class RecordLogViewQueryHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-view-query-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func opened(_ provider: SQLiteStorageProvider, documentId: String = "doc-1") throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-a")
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private func create(_ store: RecordLogStore, _ writer: String, _ model: String, _ id: String,
                        _ fields: [String: JSONValue], tags: [String]? = nil) throws {
        let deltas = tags.map { ["tags": Dictionary(uniqueKeysWithValues: $0.map { ($0, true) })] }
        _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [
            RecordLogMutation(model: model, id: id, kind: .create, fields: fields, stringSetDeltas: deltas),
        ])])
    }

    private func ids(_ page: PagedQueryResult<RecordLogRow>) -> [String] {
        page.data.compactMap { $0["id"]?.stringValue }
    }

    private func indexesOnView(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection { connection in
            try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'record_log_view' ORDER BY name"
            )
        }.compactMap { $0["name"].stringValue }
    }

    /// Seven `Memo` records with `rank` = (i * 3) % 7 and `done` on the even ones.
    private func ranked(_ store: RecordLogStore, _ writer: String) throws {
        for i in 0..<7 {
            try create(store, writer, "Memo", "m\(i)", ["rank": .number(Double((i * 3) % 7)), "done": .bool(i % 2 == 0)])
        }
    }

    func testAnswersTheFilterOverGuessesAndCaughtUpRowsOfTheOneDocument() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let (other, otherWriter) = try opened(provider, documentId: "doc-2")
        try create(store, writer, "Memo", "m1", ["title": "Alpha", "n": 1, "done": true], tags: ["a", "b"])
        try create(store, writer, "Memo", "m2", ["title": "beta", "n": 5], tags: ["b"])
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Memo", id: "m3", row: ["id": "m3", "title": "gamma", "n": "5", "tags": []]),
            RecordLogCatchUpRow(model: "Memo", id: "m4", row: ["id": "m4", "n": 9, "tags": ["a", "c"], "note": nil]),
            RecordLogCatchUpRow(model: "Note", id: "n1", row: ["id": "n1", "title": "Alpha", "n": 1]),
        ], lsn: 0)
        try create(other, otherWriter, "Memo", "x1", ["title": "Alpha", "n": 1])

        XCTAssertEqual(ids(try store.queryView("Memo")), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(ids(try store.queryView("Memo", ["title": "Alpha"])), ["m1"])
        XCTAssertEqual(ids(try store.queryView("Memo", ["n": 5])), ["m2"])
        XCTAssertEqual(ids(try store.queryView("Memo", ["tags": ["$contains": "a"]])), ["m1", "m4"])
        XCTAssertEqual(ids(try store.queryView("Memo", ["done": true])), ["m1"])
        XCTAssertEqual(try store.countView("Memo", ["tags": ["$contains": "a"]]), 2)
        XCTAssertEqual(try store.countView("Memo"), 4)
        XCTAssertEqual(try other.countView("Memo"), 1)
        XCTAssertEqual(try store.queryView("Memo", ["n": 9]).data, [["id": "m4", "n": 9, "tags": ["a", "c"], "note": nil]])
        XCTAssertEqual(ids(try store.queryView("Memo", ["nobody": "x"])), [])
        XCTAssertEqual(try store.countView("Memo", ["nobody": ["$gt": 1]]), 0)
    }

    func testSortsOnAFieldAndOnIdAndPagesBothWays() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try ranked(store, writer)

        XCTAssertEqual(ids(try store.queryView("Memo", options: QueryOptions(sort: ["rank": 1]))),
                       ["m0", "m5", "m3", "m1", "m6", "m4", "m2"])
        XCTAssertEqual(ids(try store.queryView("Memo", options: QueryOptions(sort: ["id": -1]))),
                       ["m6", "m5", "m4", "m3", "m2", "m1", "m0"])

        let byRank = { (cursor: String?, direction: CursorDirection) in
            try store.queryView("Memo", options: QueryOptions(sortOrder: [("rank", -1)], limit: 3, cursor: cursor, direction: direction))
        }
        let first = try byRank(nil, .forward)
        XCTAssertEqual(ids(first), ["m2", "m4", "m6"])
        XCTAssertTrue(first.hasMore)
        XCTAssertNil(first.prevCursor)
        let second = try byRank(first.nextCursor, .forward)
        XCTAssertEqual(ids(second), ["m1", "m3", "m5"])
        XCTAssertTrue(second.hasMore)
        let third = try byRank(second.nextCursor, .forward)
        XCTAssertEqual(ids(third), ["m0"])
        XCTAssertFalse(third.hasMore)
        XCTAssertNil(third.nextCursor)
        let back = try byRank(second.prevCursor, .backward)
        XCTAssertEqual(ids(back), ["m2", "m4", "m6"], "a backward page answers in sort order")
        XCTAssertFalse(back.hasMore)

        let exact = try store.queryView("Memo", options: QueryOptions(limit: 7))
        XCTAssertEqual(exact.data.count, 7)
        XCTAssertFalse(exact.hasMore, "exactly `limit` rows left: no further page")
        XCTAssertEqual(ids(try store.queryView("Memo", ["done": true])), ["m0", "m2", "m4", "m6"])
        XCTAssertEqual(try store.countView("Memo", ["done": false]), 3)
    }

    /// A non-positive `limit` is refused, as the room refuses it: the db3
    /// Limits decision moved this pin (#4700, finding 4700-R4); it answered
    /// every row before.
    func testANonPositiveLimitIsRefusedAndAnEmptyModelAnswersAnEmptyPage() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try ranked(store, writer)
        for limit in [0, -1] {
            XCTAssertThrowsError(try store.queryView("Memo", options: QueryOptions(limit: limit)), "limit \(limit)") { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "\(error)")
                XCTAssertEqual((error as? JsBaoError)?.message, "Invalid options.limit: must be an integer from 1 to 10000")
            }
        }
        let all = try store.queryView("Memo")
        XCTAssertEqual(all.data.count, 7)
        XCTAssertFalse(all.hasMore)
        let empty = try store.queryView("Nothing", options: QueryOptions(limit: 2))
        XCTAssertEqual(empty.data.count, 0)
        XCTAssertFalse(empty.hasMore)
        XCTAssertNil(empty.nextCursor)
        XCTAssertNil(empty.prevCursor)
        XCTAssertEqual(try store.countView("Nothing"), 0)
    }

    /// Paging by a string-set field walks every record once, both ways: a
    /// cursor carries the set as the row holds it, its members by their bytes,
    /// and binds it as the JSON text `json_extract` yields (C4624-003).
    func testPagesByAStringSetFieldBothWays() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        let sets: [(String, [String]?)] = [
            ("m0", nil), ("m1", ["a"]), ("m2", ["b"]), ("m3", ["a", "b"]), ("m4", ["\u{E9}"]), ("m5", ["e\u{301}"]),
            ("m6", ["x/y"]), ("m7", ["e\u{301}", "\u{E9}"]), ("m8", []),
        ]
        for (id, tags) in sets {
            if let tags {
                _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [
                    RecordLogMutation(
                        model: "Memo", id: id, kind: .create, fields: ["n": 1], stringSetDeltas: tags.isEmpty ? ["tags": [:]] : nil
                    ),
                ] + tags.map { member in
                    RecordLogMutation(model: "Memo", id: id, kind: .patch, stringSetDeltas: ["tags": [member: true]])
                })])
            } else {
                try create(store, writer, "Memo", id, ["n": 1])
            }
        }
        XCTAssertEqual(try store.read(model: "Memo", id: "m7")?["tags"]?.arrayValue?.count, 2, "both spellings held")

        for direction in [1, -1] {
            let sort = QueryOptions(sortOrder: [("tags", direction)])
            let all = ids(try store.queryView("Memo", options: sort))
            XCTAssertEqual(all.count, sets.count)
            var pages: [PagedQueryResult<RecordLogRow>] = []
            var cursor: String?
            repeat {
                let page = try store.queryView(
                    "Memo", options: QueryOptions(sortOrder: [("tags", direction)], limit: 2, cursor: cursor)
                )
                pages.append(page)
                cursor = page.nextCursor
            } while cursor != nil && pages.count <= sets.count
            XCTAssertEqual(pages.flatMap(ids), all, "forward, sort \(direction): every record once, in order")
            for at in 1..<pages.count {
                let back = try store.queryView(
                    "Memo",
                    options: QueryOptions(sortOrder: [("tags", direction)], limit: 2, cursor: pages[at].prevCursor, direction: .backward)
                )
                XCTAssertEqual(ids(back), ids(pages[at - 1]), "backward from page \(at), sort \(direction)")
            }
        }

        // Each cursor carries its row's array, member for member by bytes.
        let bytes = { (value: JSONValue?) in value?.arrayValue?.compactMap(\.stringValue).map { Array($0.utf8) } }
        var cursorAt: String?
        var checked: [String] = []
        repeat {
            let step = try store.queryView("Memo", options: QueryOptions(sortOrder: [("tags", 1)], limit: 1, cursor: cursorAt))
            let row = try XCTUnwrap(step.data.first)
            if let next = step.nextCursor {
                let carried = Data(base64Encoded: next).flatMap { try? JSONCoding.decodeData(JSONValue.self, from: $0) }
                XCTAssertEqual(bytes(carried?.objectValue?["values"]?.objectValue?["tags"]), bytes(row["tags"]))
                checked.append(row["id"]?.stringValue ?? "")
            }
            cursorAt = step.nextCursor
        } while cursorAt != nil && checked.count <= sets.count
        XCTAssertTrue(checked.contains("m7"), "the row holding both spellings minted a cursor: \(checked)")
        XCTAssertEqual(checked.count, sets.count - 1)
    }

    /// Paging by `type`, alone or before another field, walks every record
    /// once, both ways: a cursor carries the `_type` column the page sorts
    /// by, which the record's JSON does not hold, and a row read back is
    /// unchanged (C4624-004).
    func testPagesByTheTypeColumnBothWays() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try ranked(store, writer)
        let unpaged = try store.queryView("Memo", options: QueryOptions(sortOrder: [("type", 1)]))
        XCTAssertNil(unpaged.data.first?["type"], "a row read back carries no `type`")

        for sort in [[("type", 1)], [("type", -1)], [("type", 1), ("rank", -1)], [("type", -1), ("rank", 1)]] {
            let all = ids(try store.queryView("Memo", options: QueryOptions(sortOrder: sort)))
            XCTAssertEqual(all.count, 7)
            var pages: [PagedQueryResult<RecordLogRow>] = []
            var cursor: String?
            repeat {
                let page = try store.queryView("Memo", options: QueryOptions(sortOrder: sort, limit: 3, cursor: cursor))
                pages.append(page)
                cursor = page.nextCursor
            } while cursor != nil && pages.count <= 7
            XCTAssertEqual(pages.flatMap(ids), all, "forward, sort \(sort): every record once, in order")
            XCTAssertEqual(pages.count, 3, "sort \(sort)")
            for at in 1..<pages.count {
                let back = try store.queryView(
                    "Memo", options: QueryOptions(sortOrder: sort, limit: 3, cursor: pages[at].prevCursor, direction: .backward)
                )
                XCTAssertEqual(ids(back), ids(pages[at - 1]), "backward from page \(at), sort \(sort)")
            }
        }
    }

    func testACursorOfAnotherSortIsRefused() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try ranked(store, writer)
        let first = try store.queryView("Memo", options: QueryOptions(sortOrder: [("rank", -1)], limit: 3))
        XCTAssertThrowsError(
            try store.queryView("Memo", options: QueryOptions(sortOrder: [("done", 1)], limit: 3, cursor: first.nextCursor))
        ) { error in
            XCTAssertTrue(error is InvalidCursorError, "\(error)")
        }
    }

    func testProjectionKeepsOrDropsRowKeysAndAlwaysKeepsId() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try create(store, writer, "Memo", "m1", ["title": "a", "n": 1, "done": true])
        XCTAssertEqual(try store.queryView("Memo", options: QueryOptions(projection: ["title": 1])).data, [["id": "m1", "title": "a"]])
        XCTAssertEqual(try store.queryView("Memo", options: QueryOptions(projection: ["done": 0, "id": 0])).data,
                       [["id": "m1", "title": "a", "n": 1]])
        // A sort on a field the projection omits still pages.
        try create(store, writer, "Memo", "m2", ["title": "b", "n": 2])
        let first = try store.queryView("Memo", options: QueryOptions(sortOrder: [("n", -1)], limit: 1, projection: ["title": 1]))
        XCTAssertEqual(first.data, [["id": "m2", "title": "b"]])
        let next = try store.queryView(
            "Memo", options: QueryOptions(sortOrder: [("n", -1)], limit: 1, cursor: first.nextCursor, projection: ["title": 1])
        )
        XCTAssertEqual(next.data, [["id": "m1", "title": "a"]])
        XCTAssertThrowsError(try store.queryView("Memo", options: QueryOptions(projection: ["title": 1, "n": 0]))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
    }

    func testTheDocumentsScopeNamesThisDocumentOrAnswersNothing() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try create(store, writer, "Memo", "m1", ["n": 1])
        XCTAssertEqual(ids(try store.queryView("Memo", options: QueryOptions(documents: ["doc-1"]))), ["m1"])
        XCTAssertEqual(ids(try store.queryView("Memo", options: QueryOptions(documents: ["doc-2", "doc-1"]))), ["m1"])
        XCTAssertEqual(ids(try store.queryView("Memo", options: QueryOptions(documents: ["doc-2"]))), [])
        XCTAssertEqual(ids(try store.queryView("Memo", options: QueryOptions(documents: []))), [])
        XCTAssertEqual(try store.countView("Memo", documents: ["doc-2"]), 0)
        XCTAssertEqual(try store.countView("Memo", documents: ["doc-1"]), 1)
    }

    func testRefusesANameThatIsNotAnIdentifierAndBuildsNoIndex() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        try create(store, writer, "Memo", "m1", ["n": 1])
        for call in [
            { _ = try store.queryView("not a model") },
            { _ = try store.countView("not a model") },
            { _ = try store.queryView("Memo", ["bad field": 1]) },
            { _ = try store.queryView("Memo", options: QueryOptions(sort: ["a b": 1])) },
        ] as [() throws -> Void] {
            XCTAssertThrowsError(try call()) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "\(error)")
                XCTAssertTrue((error as? JsBaoError)?.message.contains("Identifier") ?? false, "\(error)")
            }
        }
        let before = try indexesOnView(provider)
        _ = try store.queryView("Memo", ["n": 1, "title": ["$startsWith": "a"]], options: QueryOptions(sort: ["n": -1]))
        _ = try store.countView("Memo", ["tags": ["$contains": "a"]])
        XCTAssertEqual(try indexesOnView(provider), before)
    }

    /// Behaviour 5: an undeclared set a cold store loaded from a segment chunk.
    func testASegmentChunksUndeclaredSetAnswersMembership() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try opened(provider)
        _ = try store.beginReceipt(writer: writer, kind: .segment, id: "S1")
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applySegmentChunk(writer: writer, generation: generation, rows: [
            RecordLogCatchUpRow(model: "Memo", id: "n1", row: ["id": "n1", "title": "a memo", "tags": ["b", "a"]]),
            RecordLogCatchUpRow(model: "Memo", id: "n2", row: ["id": "n2", "title": "another", "tags": ["c"]]),
        ])
        XCTAssertEqual(ids(try store.queryView("Memo", ["tags": ["$contains": "a"]])), ["n1"])
        XCTAssertEqual(try store.countView("Memo", ["tags": ["$contains": "a"]]), 1)
    }
}
