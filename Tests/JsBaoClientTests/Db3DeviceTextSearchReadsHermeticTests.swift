import XCTest
import YSwift
@testable import JsBaoClient

/// The JS behavior-12 fixture (`db3-store-text-index-5222.test.ts`), ported
/// with the same generator: 1,000 notes with titles and bodies, and the
/// accent, quokka and zebra rows the asserts single out.
enum Db3TextSearchFixture {
    struct Note {
        var id: String
        var title: String
        var body: String
        var kind: String
    }

    static let words = ["apple", "pear", "plum", "river", "stone", "light", "night", "green", "blue", "garden", "running", "runner", "ran"]

    static func notes() -> [Note] {
        var state: UInt32 = 5222
        func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
        func pick() -> String { words[Int(next() * Double(words.count))] }
        var out: [Note] = []
        for n in 1...1000 {
            let titleCount = 1 + Int(next() * 3)
            let title = (0..<titleCount).map { _ in pick() }.joined(separator: " ")
            let bodyCount = 2 + Int(next() * 8)
            let body = (0..<bodyCount).map { _ in pick() }.joined(separator: " ")
            out.append(Note(id: String(format: "n%04d", n), title: title, body: body, kind: n % 3 == 0 ? "a" : "b"))
        }
        out.append(Note(id: "x0001", title: "Café Crème", body: "naïve visit", kind: "a"))
        out.append(Note(id: "x0002", title: "cafe", body: "plain", kind: "a"))
        out.append(Note(id: "x0003", title: "zebra quokka", body: "quokka zebra", kind: "b"))
        out.append(Note(id: "x0004", title: "quokka", body: "nothing here", kind: "b"))
        out.append(Note(id: "x0005", title: "nothing", body: "quokka", kind: "b"))
        return out
    }

    /// The unicode61 tokenizer's reading of the fixture's text: lowercase, diacritics folded, split on non-alphanumerics.
    static func tokens(_ text: String) -> [String] {
        text.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !$0.properties.isDiacritic && $0.properties.generalCategory != .nonspacingMark }
            .map(String.init).joined().lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    static func has(_ text: String, _ word: String, prefix: Bool = false) -> Bool {
        tokens(text).contains { prefix ? $0.hasPrefix(word) : $0 == word }
    }

    static func adjacent(_ text: String, _ a: String, _ b: String) -> Bool {
        let all = tokens(text)
        return all.indices.dropLast().contains { all[$0] == a && all[$0 + 1] == b }
    }
}

/// #5223 behaviors 12, 13, 14 and 9, edge cases E3, E8, E14 — `$search` on
/// the device in the Swift store, as js-bao's view reader answers it: a page
/// joins the text index's matches with `-bm25` as `_score`, best first then
/// id and the db3, cursors and the byte budget as any page; `_score` rides
/// every row through projections and includes; count and an aggregate keep
/// the rows the index matches; `$search` nested in `$and`/`$or`, on a model
/// with no text index here, over two db3s, or on an index this device could
/// not build is refused before any statement, and every other query answers.
final class Db3DeviceTextSearchReadsHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private typealias F = Db3TextIndexFixture
    private typealias N = Db3TextSearchFixture

    private func world(_ label: String = "text-reads", logger: Logger? = nil) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make(label, logger: logger)
        worlds.append(world)
        return world
    }

    /// A synced store holding the fixture through catch-up pages, its text index over title and body.
    private func loaded(_ text: JSONValue? = nil) async throws -> (Db3DeviceIndexWorld, RecordLogStore) {
        let world = try await world()
        let store = try world.store("db3-a")
        let notes = N.notes()
        for start in stride(from: 0, to: notes.count, by: 250) {
            let rows = notes[start..<min(start + 250, notes.count)].map { note in
                RecordLogCatchUpRow(model: "Note", id: note.id, row: [
                    "id": .string(note.id), "title": .string(note.title), "body": .string(note.body), "kind": .string(note.kind),
                ])
            }
            _ = try store.applyCatchUpPage(writer: world.writer("db3-a"), rows: Array(rows), lsn: start + 250)
        }
        try store.syncIndexes([F.textEntry(["title", "body"], text)])
        return (world, store)
    }

    private func search(
        _ store: RecordLogStore, _ search: JSONValue, _ options: QueryOptions = QueryOptions(limit: 10_000), filter: DocumentFilter = [:]
    ) throws -> PagedQueryResult<RecordLogRow> {
        var full = filter
        full["$search"] = search
        return try store.queryView("Note", full, options: options)
    }

    private func ids(_ page: PagedQueryResult<RecordLogRow>) -> [String] { page.data.compactMap { $0["id"]?.stringValue } }

    private func expected(_ match: (N.Note) -> Bool) -> [String] { N.notes().filter(match).map(\.id).sorted() }

    private func thrown(_ body: () throws -> Any) -> JsBaoError? {
        do {
            _ = try body()
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("threw \(error)")
        }
        return nil
    }

    // MARK: - Behavior 13: the fixture's expected sets, count and aggregate

    func testAnswersTheFixturesExpectedSetsAndCountAndAggregateOverTheMatches() async throws {
        let (_, store) = try await loaded()
        let either = { (word: String) in { (r: N.Note) in N.has(r.title, word) || N.has(r.body, word) } }
        XCTAssertEqual(try ids(search(store, "apple")).sorted(), expected(either("apple")))
        XCTAssertEqual(try ids(search(store, ["query": "apple pear"])).sorted(), expected { either("apple")($0) && either("pear")($0) })
        XCTAssertEqual(try ids(search(store, ["query": "plum quokka", "mode": "any"])).sorted(), expected { either("plum")($0) || either("quokka")($0) })
        XCTAssertEqual(try ids(search(store, ["query": "riv", "prefix": true])).sorted(),
                       expected { N.has($0.title, "riv", prefix: true) || N.has($0.body, "riv", prefix: true) })
        XCTAssertEqual(try ids(search(store, ["query": "quokka", "fields": ["title"]])).sorted(), ["x0003", "x0004"])
        XCTAssertEqual(try ids(search(store, "\"green garden\"")).sorted(),
                       expected { N.adjacent($0.title, "green", "garden") || N.adjacent($0.body, "green", "garden") })
        XCTAssertEqual(try ids(search(store, "cafe")).sorted(), ["x0001", "x0002"])
        XCTAssertEqual(try ids(search(store, "naive")).sorted(), ["x0001"])
        let night = expected(either("night"))
        XCTAssertFalse(night.isEmpty)
        XCTAssertEqual(try store.countView("Note", ["$search": "night"]), night.count)
        let kinds = Dictionary(uniqueKeysWithValues: N.notes().map { ($0.id, $0.kind) })
        let trace = try RecordLogStatementTrace.install(on: worlds[0].provider, self)
        let byKind = try RecordLogViewReader(store: store, documents: ["db3-a"]).aggregate(
            "Note", AggregateOptions(groupBy: ["kind"], operations: [AggregateOperation(type: .count)], filter: ["$search": "night"]),
            setFields: []
        )
        XCTAssertEqual(byKind, ["a", "b"].compactMap { kind -> [String: JSONValue]? in
            let count = night.filter { kinds[$0] == kind }.count
            return count > 0 ? ["group": ["kind": .string(kind)], "count": .number(Double(count))] : nil
        })
        let table = F.tableName("db3-a")
        XCTAssertTrue(trace.viewReads.contains { $0.contains("record_log_view.rowid IN (SELECT rowid FROM \"\(table)\" WHERE \"\(table)\" MATCH ?)") },
                      "\(trace.viewReads)")
        trace.clear()
        _ = try store.countView("Note", ["$search": "night"])
        XCTAssertTrue(trace.viewReads.contains { $0.contains("record_log_view.rowid IN (SELECT rowid FROM \"\(table)\" WHERE \"\(table)\" MATCH ?)") },
                      "\(trace.viewReads)")
        // The rest of the filter applies by AND.
        XCTAssertEqual(try ids(search(store, "night", filter: ["kind": "a"])).sorted(), night.filter { kinds[$0] == "a" })
    }

    /// E14: weights change the order in the index's field order; a `fields` restriction ranks by its columns' weights.
    func testWeightsChangeTheOrderInTheIndexsFieldOrder() async throws {
        let (_, title) = try await loaded(["weights": ["title": 10, "body": 1]])
        let (_, body) = try await loaded(["weights": ["title": 1, "body": 10]])
        XCTAssertEqual(try ids(search(title, "quokka")).first, "x0004")
        XCTAssertEqual(try ids(search(body, "quokka")).first, "x0005")
        XCTAssertEqual(try ids(search(title, ["query": "quokka", "fields": ["body"]])), ["x0005", "x0003"])
        // prefix: true on an index with no prefix lengths still answers.
        XCTAssertEqual(try ids(search(title, ["query": "quok", "prefix": true])).sorted(), ["x0003", "x0004", "x0005"])
    }

    /// A weight past Int64 is a valid weight: the page writes it as a double and answers.
    func testAWeightPastInt64RanksWithoutTrapping() async throws {
        let (_, store) = try await loaded(["weights": ["title": 1e20]])
        let page = try search(store, "quokka")
        XCTAssertEqual(ids(page).sorted(), ["x0003", "x0004", "x0005"])
        XCTAssertEqual(ids(page).last, "x0005")
        XCTAssertTrue(page.data.allSatisfy { $0["_score"]?.numberValue != nil })
    }

    func testMatchesRunningByRunUnderPorter() async throws {
        let (_, store) = try await loaded(["tokenizer": "porter"])
        let found = Set(try ids(search(store, "run")))
        XCTAssertFalse(found.isEmpty)
        for note in N.notes() where N.has(note.title, "running") || N.has(note.body, "running") {
            XCTAssertTrue(found.contains(note.id), note.id)
        }
    }

    // MARK: - Behavior 12: the ranked page

    func testAPageJoinsTheIndexWithScoreAsMinusBm25BestFirstThenId() async throws {
        let (world, store) = try await loaded(["weights": ["title": 2]])
        let table = F.tableName("db3-a")
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        let page = try search(store, "stone")
        let reads = trace.viewReads
        XCTAssertEqual(reads.count, 1, "\(reads)")
        let statement = reads.first ?? ""
        XCTAssertTrue(statement.contains(
            "JOIN (SELECT rowid, -bm25(\"\(table)\", 2, 1) AS _score FROM \"\(table)\" WHERE \"\(table)\" MATCH ?) AS _search ON _search.rowid = record_log_view.rowid"
        ), statement)
        XCTAssertTrue(statement.contains("_search._score AS _score"), statement)
        XCTAssertTrue(statement.contains("ORDER BY _search._score DESC, \"_id\" ASC, doc_id ASC"), statement)
        let bm25 = Dictionary(uniqueKeysWithValues: try world.rows(
            "SELECT rowid, -bm25(\"\(table)\", 2, 1) AS score FROM \"\(table)\" WHERE \"\(table)\" MATCH '\"stone\"'"
        ).compactMap { row in row["rowid"].intValue.map { ($0, row["score"]) } })
        let rowids = Dictionary(uniqueKeysWithValues: try world.rows("SELECT _id, rowid FROM record_log_view WHERE doc_id = 'db3-a'")
            .compactMap { row in row["_id"].stringValue.map { ($0, row["rowid"].intValue ?? 0) } })
        XCTAssertGreaterThan(page.data.count, 50)
        for row in page.data {
            guard case .number(let score)? = row["_score"], case .real(let expected)? = rowids[row["id"]?.stringValue ?? ""].flatMap({ bm25[$0] })
            else { return XCTFail("\(row)") }
            XCTAssertEqual(score, expected)
        }
        for (a, b) in zip(page.data, page.data.dropFirst()) {
            let (sa, sb) = (a["_score"]?.numberValue ?? 0, b["_score"]?.numberValue ?? 0)
            XCTAssertTrue(sa > sb || (sa == sb && (a["id"]?.stringValue ?? "") < (b["id"]?.stringValue ?? "")), "\(a) before \(b)")
        }
        let ascending = try search(store, "stone", QueryOptions(sort: ["_score": 1], limit: 10_000)).data
        for (a, b) in zip(ascending, ascending.dropFirst()) {
            XCTAssertLessThanOrEqual(a["_score"]?.numberValue ?? 0, b["_score"]?.numberValue ?? 0)
        }
        let byTitle = try search(store, "stone", QueryOptions(sort: ["title": 1], limit: 10_000)).data
        let titles = byTitle.compactMap { $0["title"]?.stringValue }
        XCTAssertEqual(titles, titles.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
        XCTAssertTrue(byTitle.allSatisfy { $0["_score"]?.numberValue != nil })
        // A query without $search carries no _score.
        XCTAssertTrue(try store.queryView("Note", ["kind": "a"], options: QueryOptions(limit: 5)).data.allSatisfy { $0["_score"] == nil })
    }

    func testCursorsWalkARankedResultForwardAndBackwardAndEqualScoresFallToId() async throws {
        let (world, store) = try await loaded()
        let full = try ids(search(store, "light"))
        XCTAssertGreaterThan(full.count, 30)
        var forward: [[String]] = []
        var page = try search(store, "light", QueryOptions(limit: 7))
        var last = page
        while true {
            forward.append(ids(page))
            last = page
            guard page.hasMore else { break }
            page = try search(store, "light", QueryOptions(limit: 7, cursor: page.nextCursor))
        }
        XCTAssertEqual(forward.flatMap { $0 }, full)
        var backward: [[String]] = [ids(last)]
        var back = try search(store, "light", QueryOptions(limit: 7, cursor: last.prevCursor, direction: .backward))
        while true {
            backward.insert(ids(back), at: 0)
            guard back.hasMore else { break }
            back = try search(store, "light", QueryOptions(limit: 7, cursor: back.nextCursor, direction: .backward))
        }
        XCTAssertEqual(backward.flatMap { $0 }, full)
        // The cursor carries the score, the id and the db3.
        let first = try XCTUnwrap(try search(store, "light", QueryOptions(limit: 7)).nextCursor)
        let payload = try XCTUnwrap(Data(base64Encoded: first))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(decoded["sortFields"] as? [String], ["_score", "id", "_tiebreak:doc_id"])
        XCTAssertNotNil((decoded["values"] as? [String: Any])?["_score"] as? Double)
        // E8: a cursor minted under _score refuses to page a query sorted by a field.
        XCTAssertThrowsError(try search(store, "light", QueryOptions(sort: ["title": 1], limit: 7, cursor: first))) {
            XCTAssertTrue($0 is InvalidCursorError, "\($0)")
        }

        // Equal scores fall to id: a walk at limit 1 over rows that tie is complete and deterministic.
        let ties = try world.store("db3-t")
        try ties.syncIndexes([F.textEntry(["title"])])
        for id in ["t3", "t1", "t2", "t4"] {
            try world.commit("db3-t", [RecordLogMutation(model: "Note", id: id, kind: .create, fields: ["title": "same words"])])
        }
        var walk: [String] = []
        var one = try ties.queryView("Note", ["$search": "same"], options: QueryOptions(limit: 1))
        while true {
            walk += ids(one)
            guard one.hasMore else { break }
            one = try ties.queryView("Note", ["$search": "same"], options: QueryOptions(limit: 1, cursor: one.nextCursor))
        }
        XCTAssertEqual(walk, ["t1", "t2", "t3", "t4"])
    }

    func testTheByteBudgetCutsARankedPage() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try store.syncIndexes([F.textEntry(["title"])])
        let big = String(repeating: "x", count: 3 * 1024 * 1024)
        try world.seed("db3-a", "Note", ["b1", "b2", "b3", "b4"].map { ["id": .string($0), "title": "same", "blob": .string(big)] })
        let cut = try store.queryView("Note", ["$search": "same"], options: QueryOptions(limit: 10))
        XCTAssertLessThan(cut.data.count, 4)
        XCTAssertTrue(cut.hasMore)
        XCTAssertTrue(cut.data.allSatisfy { $0["_score"]?.numberValue != nil })
    }

    func testScoreSurvivesProjectionsAndAnInclude() async throws {
        let (_, store) = try await loaded()
        let projected = try search(store, "plum", QueryOptions(limit: 10_000, projection: ["title": 1])).data
        XCTAssertFalse(projected.isEmpty)
        for row in projected { XCTAssertEqual(row.keys.sorted(), ["_score", "id", "title"]) }
        for row in try search(store, "plum", QueryOptions(limit: 10_000, projection: ["body": 0])).data {
            XCTAssertNil(row["body"])
            XCTAssertNotNil(row["_score"]?.numberValue)
        }

        let fixture = try await RecordLogViewFixture.make("text-include")
        defer { fixture.remove() }
        let schema = PrimitiveSchema(name: "Note", fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "owner": FieldDescriptor(type: .string),
        ])
        let member = try fixture.member(schema, "db3-i")
        try fixture.open("db3-i").store.syncIndexes([F.textEntry(["title"])])
        try fixture.seed("db3-i", "Note", [["id": "o1", "title": "owner"], ["id": "n1", "title": "plum tart", "owner": "o1"]])
        let page = try RecordLogViewReader(store: fixture.open("db3-i").store, documents: ["db3-i"]).page(
            "Note", ["$search": "plum"], options: QueryOptions(projection: ["title": 1]), shape: .stored,
            include: [Include(type: .refersTo, target: member, sourceField: "owner", resultKey: "ownerNote")]
        )
        let found = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(found["id"], "n1")
        XCTAssertEqual(found["title"], "plum tart")
        XCTAssertEqual(found["_related"]?["ownerNote"]?["id"], "o1")
        XCTAssertNotNil(found["_score"]?.numberValue)
    }

    // MARK: - E3: awkward field names

    func testBuildsAndSearchesAnIndexOverRankRowidOrTitleAndTitle() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        let fields = ["rank", "rowid", "OR", "Title", "title"]
        try store.syncIndexes([F.textEntry(fields, ["weights": ["Title": 2, "title": 1]])])
        let table = F.tableName("db3-a")
        XCTAssertEqual(
            try world.rows("SELECT sql FROM sqlite_master WHERE name = ?", [.text(table)]).first?["sql"].stringValue,
            "CREATE VIRTUAL TABLE \"\(table)\" USING fts5(f0, f1, f2, f3, f4, content='', tokenize='unicode61 remove_diacritics 2')"
        )
        try world.commit("db3-a", [
            RecordLogMutation(model: "Note", id: "r", kind: .create, fields: ["rank": "word"]),
            RecordLogMutation(model: "Note", id: "o", kind: .create, fields: ["OR": "word"]),
            RecordLogMutation(model: "Note", id: "u", kind: .create, fields: ["Title": "word"]),
            RecordLogMutation(model: "Note", id: "l", kind: .create, fields: ["title": "word lower"]),
            RecordLogMutation(model: "Note", id: "w", kind: .create, fields: ["rowid": "word"]),
        ])
        XCTAssertEqual(try ids(search(store, ["query": "word", "fields": ["rank"]])), ["r"])
        XCTAssertEqual(try ids(search(store, ["query": "word", "fields": ["OR"]])), ["o"])
        XCTAssertEqual(try ids(search(store, ["query": "word", "fields": ["Title"]])), ["u"])
        XCTAssertEqual(try ids(search(store, ["query": "lower", "fields": ["Title"]])), [])
        XCTAssertEqual(try ids(search(store, ["query": "word", "fields": ["rowid"]])), ["w"])
        // Title weighs 2, title 1: the same word ranks Title's row above title's.
        XCTAssertEqual(try ids(search(store, ["query": "word", "fields": ["Title", "title"]])), ["u", "l"])
        XCTAssertEqual(try ids(search(store, "word")).sorted(), ["l", "o", "r", "u", "w"])
        XCTAssertEqual(try world.drift(), [])

        let other = try world.store("db3-b")
        try other.syncIndexes([F.textEntry(["toString", "valueOf", "hasOwnProperty"])])
        try world.commit("db3-b", [
            RecordLogMutation(model: "Note", id: "s", kind: .create, fields: ["toString": "word"]),
            RecordLogMutation(model: "Note", id: "v", kind: .create, fields: ["valueOf": "word"]),
        ])
        XCTAssertEqual(try ids(other.queryView("Note", ["$search": "word"])).sorted(), ["s", "v"])
        XCTAssertEqual(try ids(other.queryView("Note", ["$search": ["query": "word", "fields": ["valueOf"]]])), ["v"])
        XCTAssertEqual(try world.drift(), [])
    }

    func testRunsHostileSearchesAsPlainWordsAndSplitsOnANul() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try store.syncIndexes([F.textEntry(["title"])])
        try world.commit("db3-a", [
            RecordLogMutation(model: "Note", id: "a", kind: .create, fields: ["title": "near or and not"]),
            RecordLogMutation(model: "Note", id: "b", kind: .create, fields: ["title": "title x a b"]),
            RecordLogMutation(model: "Note", id: "c", kind: .create, fields: ["title": "open phrase"]),
            RecordLogMutation(model: "Note", id: "h", kind: .create, fields: ["title": "hello world"]),
        ])
        for input in ["a\"b", "a*", "NEAR", "OR", "AND", "NOT", "^a", "title:x", "{a}", "(a)", "-a", "a OR b", "\"open phrase", "NEAR(a b)"] {
            XCTAssertNoThrow(try search(store, .string(input)), input)
        }
        XCTAssertEqual(try ids(search(store, "NEAR OR")), ["a"])
        XCTAssertEqual(try ids(search(store, "title:x")), ["b"])
        XCTAssertEqual(try ids(search(store, "\"open phrase")), ["c"])
        for input in ["hello\u{0}world", "\u{0}hello", "hello\u{0}"] { XCTAssertEqual(try ids(search(store, .string(input))), ["h"]) }
        for input in ["", "   ", "...", "\"", "*", "\u{0}"] {
            XCTAssertEqual(thrown { try self.search(store, .string(input)) }?.code, .invalidArgument, input.debugDescription)
        }
    }

    // MARK: - Behavior 13: nested $search is refused on every read

    func testRefusesSearchInsideAndOrOnPageCountAndAggregate() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try store.syncIndexes([F.textEntry(["title"])])
        let top = "$search is allowed only at the top level of a filter: it combines with the rest of the filter by AND"
        for filter: DocumentFilter in [["$or": [["$search": "a"], ["n": 1]]], ["$and": [["$search": "a"]]]] {
            XCTAssertEqual(thrown { try store.queryView("Note", filter) }?.message, top)
            XCTAssertEqual(thrown { try store.countView("Note", filter) }?.message, top)
            XCTAssertEqual(thrown {
                try RecordLogViewReader(store: store, documents: ["db3-a"]).aggregate(
                    "Note", AggregateOptions(groupBy: ["kind"], operations: [AggregateOperation(type: .count)], filter: filter), setFields: []
                )
            }?.message, top)
        }
        XCTAssertEqual(thrown { try self.search(store, ["query": "a", "fields": ["body"]]) }?.message,
                       "$search.fields names body, which the text index does not cover: title")
    }

    // MARK: - Behavior 14: refusals before any statement

    func testRefusesSearchOnAModelWithNoTextIndexHereAndOverTwoDb3sBeforeAnyStatement() async throws {
        let world = try await world()
        let store = try world.store("db3-a")
        try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "a", kind: .create, fields: ["title": "x"])])
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        let refused = try XCTUnwrap(thrown { try store.queryView("Note", ["$search": "x"]) })
        XCTAssertEqual(refused.code, .queryIndexNotOnDevice)
        XCTAssertEqual(refused.code.rawValue, "QUERY_INDEX_NOT_ON_DEVICE")
        XCTAssertEqual(refused.message, "$search on Note needs a text index on this device: register one with kind: \"text\", on: \"device\"")
        XCTAssertEqual(refused.details, ["model": "Note"])
        XCTAssertEqual(thrown { try store.countView("Note", ["$search": "x"]) }?.code, .queryIndexNotOnDevice)
        XCTAssertEqual(trace.viewReads, [], "nothing read the view")
        XCTAssertEqual(try ids(store.queryView("Note", ["title": "x"])), ["a"])

        try store.syncIndexes([F.textEntry(["title"])])
        try world.store("db3-b")
        trace.clear()
        let reader = RecordLogViewReader(store: store, documents: ["db3-a", "db3-b"])
        let two = try XCTUnwrap(thrown { try reader.page("Note", ["$search": "x"], options: nil, shape: .stored) })
        XCTAssertEqual(two.code, .invalidArgument)
        XCTAssertEqual(two.message, "$search reads one db3's text index: give exactly one db3, not 2")
        XCTAssertEqual(thrown { try reader.count("Note", ["$search": "x"]) }?.message, two.message)
        XCTAssertEqual(trace.viewReads, [], "nothing read the view")
    }

    // MARK: - Behavior 9: an entry skipped or not built

    func testSkipsAnEntryNotAnIdentifierAndRefusesSearchOnAnIndexNotBuiltWhileEveryOtherQueryAnswers() async throws {
        let world = try await world(logger: Logger(level: .info))
        let store = try world.store("db3-a")
        try world.commit("db3-a", [RecordLogMutation(model: "Note", id: "a", kind: .create, fields: ["title": "x", "c1": "y"])])
        let skipped = try F.logged { try store.syncIndexes([F.textEntry(["ti-tle"]), F.textEntry(["title"], model: "No-te")]) }
        XCTAssertEqual(skipped.filter { $0.level == .warn }.count, 2, "\(skipped.map(\.message))")
        XCTAssertEqual(try F.textObjects(world), [])
        XCTAssertEqual(try world.rows("SELECT * FROM record_log_indexes").count, 0)
        XCTAssertEqual(thrown { try store.queryView("Note", ["$search": "x"]) }?.code, .queryIndexNotOnDevice)

        // More columns than the build's SQLITE_MAX_COLUMN (2000): FTS5 refuses the table.
        let wide = (0...2000).map { "c\($0)" }
        let lines = try F.logged { try store.syncIndexes([F.textEntry(wide, on: .both)]) }
        let warned = lines.filter { $0.level == .warn }.map(\.message)
        XCTAssertEqual(warned.count, 1, "\(warned)")
        XCTAssertTrue(warned.first?.hasPrefix("[record-log] db3-a: text index idx_text_note on Note is not built: the text index could not be built: ") ?? false,
                      warned.first ?? "")
        XCTAssertTrue(warned.first?.hasSuffix("; $search on it is refused, every other query answers.") ?? false, warned.first ?? "")
        XCTAssertEqual(try F.textObjects(world), [])
        let options = try XCTUnwrap(world.rows("SELECT options FROM record_log_indexes WHERE kind = 'text'").first?["options"].stringValue
            .flatMap(RecordLogJSON.parse))
        let reason = try XCTUnwrap(options["unbuilt"]?.stringValue)
        XCTAssertTrue(reason.hasPrefix("the text index could not be built: "), reason)
        let refused = try XCTUnwrap(thrown { try store.queryView("Note", ["$search": "x"]) })
        XCTAssertEqual(refused.code, .db3IndexPlacementUnsupported)
        XCTAssertEqual(refused.details, ["kind": "text", "on": "both", "engine": "swift-sqlite", "reason": .string(reason)])
        XCTAssertEqual(refused.message, "Note's text index is not built on this device (swift-sqlite): \(reason)")
        XCTAssertEqual(thrown { try store.countView("Note", ["$search": "x"]) }?.code, .db3IndexPlacementUnsupported)
        // Every other query on the model answers.
        XCTAssertEqual(try ids(store.queryView("Note", ["title": "x"])), ["a"])
        XCTAssertEqual(try store.countView("Note", [:]), 1)

        // A later list with a buildable definition builds it and clears the mark.
        XCTAssertEqual(try store.syncIndexes([F.textEntry(["title"], on: .both)]).created, 1)
        XCTAssertNil(try world.rows("SELECT options FROM record_log_indexes WHERE kind = 'text'").first?["options"].stringValue
            .flatMap(RecordLogJSON.parse)?["unbuilt"])
        XCTAssertEqual(try ids(store.queryView("Note", ["$search": "x"])), ["a"])
    }
}
