import XCTest
@testable import JsBaoClient

/// #6270 — a generated model's typed reads, through the committed
/// `CodegenAcceptance/Generated/TaskRecord.swift` and `CrashTestRecord.swift`.
///
/// Each field token builds the `DocumentFilter` the hand-written form builds;
/// the typed `query`, `queryPaged`, `queryOne` and `count` answer what the
/// `DocumentFilter` overloads answer for the equivalent filter and sort; a
/// typed aggregate's rows answer each requested key with the value its raw
/// row holds; and a typed sort beside an `options` that sorts already is
/// refused before anything is read.
///
/// The store is a local-only document (`createDocumentForTest`), as in
/// `CodegenUpsertNamesHermeticTests`, so the class is marked deprecated with it.
@available(*, deprecated)
final class TypedModelQueryHermeticTests: XCTestCase {

    private let f = TaskRecord.fields

    // MARK: - Filters as values

    func testEachTokenOperatorBuildsTheHandWrittenFilter() {
        let cases: [(ModelFilter<TaskRecord>, DocumentFilter)] = [
            (f.title.eq("a"), ["title": "a"]),
            (f.title.isNull(), ["title": .null]),
            (f.title.ne("a"), ["title": ["$ne": "a"]]),
            (f.title.in(["a", "b"]), ["title": ["$in": ["a", "b"]]]),
            (f.title.notIn(["a"]), ["title": ["$nin": ["a"]]]),
            (f.title.exists(), ["title": ["$exists": true]]),
            (f.title.exists(false), ["title": ["$exists": false]]),
            (f.title.gt("a"), ["title": ["$gt": "a"]]),
            (f.title.startsWith("Q3"), ["title": ["$startsWith": "Q3"]]),
            (f.title.endsWith("x"), ["title": ["$endsWith": "x"]]),
            (f.title.containsText("rent"), ["title": ["$containsText": "rent"]]),
            (f.priority.eq(2), ["priority": 2]),
            (f.priority.gte(2), ["priority": ["$gte": 2]]),
            (f.priority.lt(2.5), ["priority": ["$lt": 2.5]]),
            (f.priority.lte(3), ["priority": ["$lte": 3]]),
            (f.priority.in([1, 2]), ["priority": ["$in": [1, 2]]]),
            (f.createdAt.gte("2026-01-01"), ["createdAt": ["$gte": "2026-01-01"]]),
            (f.id.in(["t1"]), ["id": ["$in": ["t1"]]]),
            (f.tags.contains("red"), ["tags": ["$contains": "red"]]),
            (f.tags.all(["red", "blue"]), ["tags": ["$all": ["red", "blue"]]]),
            (f.tags.size(2), ["tags": ["$size": 2]]),
            (f.tags.size(.gt(1)), ["tags": ["$size": ["$gt": 1]]]),
            (f.tags.size(.gte(1), .lt(3)), ["tags": ["$size": ["$gte": 1, "$lt": 3]]]),
            (f.tags.size(.eq(0)), ["tags": ["$size": ["$eq": 0]]]),
            (f.tags.size(.ne(2), .lte(4)), ["tags": ["$size": ["$ne": 2, "$lte": 4]]]),
            (f.tags.size(.gt(1), .gt(2)), ["tags": ["$size": ["$gt": 2]]]),
            (f.tags.isNull(), ["tags": .null]),
            (f.tags.exists(), ["tags": ["$exists": true]]),
            (f.tags.startsWith("re"), ["tags": ["$startsWith": "re"]]),
            (.and([f.title.eq("a"), f.priority.gt(1)]), ["$and": [["title": "a"], ["priority": ["$gt": 1]]]]),
            (.or([f.title.eq("a"), .and([f.priority.gt(1), f.tags.contains("x")])]),
             ["$or": [["title": "a"], ["$and": [["priority": ["$gt": 1]], ["tags": ["$contains": "x"]]]]]]),
            (.and([]), ["$and": []]),
            (.or([]), ["$or": []]),
            (ModelFilter(unchecked: ["$search": "rent"]), ["$search": "rent"]),
        ]
        for (index, (typed, handWritten)) in cases.enumerated() {
            XCTAssertEqual(typed.documentFilter, handWritten, "case \(index)")
        }
        let crash = CrashTestRecord.fields
        let crashCases: [(ModelFilter<CrashTestRecord>, DocumentFilter)] = [
            (crash.active.eq(true), ["active": true]),
            (crash.active.ne(false), ["active": ["$ne": false]]),
            (crash.active.in([true]), ["active": ["$in": [true]]]),
            (crash.default.eq("x"), ["default": "x"]),
            (crash.where.notIn(["y"]), ["where": ["$nin": ["y"]]]),
        ]
        for (index, (typed, handWritten)) in crashCases.enumerated() {
            XCTAssertEqual(typed.documentFilter, handWritten, "crash case \(index)")
        }
    }

    // MARK: - Reads against a store

    private func seeded() async throws -> JsBaoClient {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        SchemaSync.clearCache()
        client.registerModels([TaskRecord.self, CrashTestRecord.self])
        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        let tasks: [(String, String, Double, Set<String>, String)] = [
            ("t1", "rent", 3, ["home", "red"], "2026-01-05"),
            ("t2", "food", 1, ["red"], "2026-01-20"),
            ("t3", "rent", 2, [], "2026-02-01"),
            ("t4", "fuel", 5, ["car"], "2026-02-14"),
            ("t5", "food", 4, ["home"], "2026-03-01"),
        ]
        for (id, title, priority, tags, createdAt) in tasks {
            try TaskRecord(id: id, title: title, priority: priority, tags: tags, createdAt: createdAt).save(in: doc)
        }
        try CrashTestRecord(id: "c1", requiredTags: ["a"], email: "a@x", score: 1, active: true).save(in: doc)
        try CrashTestRecord(id: "c2", requiredTags: ["a"], email: "b@x", score: 2, active: false).save(in: doc)
        try CrashTestRecord(id: "c3", requiredTags: ["a"], email: "c@x", score: 4, active: true).save(in: doc)
        return client
    }

    override func tearDown() {
        JsBaoClient.clearDefault()
        super.tearDown()
    }

    func testTypedReadsAnswerWhatTheDocumentFilterReadsAnswer() async throws {
        _ = try await seeded()
        let typed = f.priority.gte(2)
        let open: DocumentFilter = ["priority": ["$gte": 2]]

        let ids = try TaskRecord.query(where: typed, sort: [.asc(f.title), .desc(f.priority)]).map(\.id)
        XCTAssertEqual(ids, ["t5", "t4", "t1", "t3"])
        XCTAssertEqual(ids, try TaskRecord.query(open, options: QueryOptions(sortOrder: [("title", 1), ("priority", -1)])).map(\.id))
        XCTAssertEqual(try TaskRecord.query(where: nil, sort: [.desc(f.priority)]).map(\.id), ["t4", "t5", "t1", "t3", "t2"])
        XCTAssertEqual(try TaskRecord.query(where: typed, include: []).map(\.id).sorted(),
                       try TaskRecord.query(open, include: []).map(\.id).sorted())

        let page = try TaskRecord.queryPaged(where: typed, sort: [.asc(f.priority)], options: QueryOptions(limit: 2))
        let openPage = try TaskRecord.queryPaged(open, options: QueryOptions(sortOrder: [("priority", 1)], limit: 2))
        XCTAssertEqual(page.data.map(\.id), ["t3", "t1"])
        XCTAssertEqual(page.data.map(\.id), openPage.data.map(\.id))
        XCTAssertEqual(page.hasMore, openPage.hasMore)
        let next = try TaskRecord.queryPaged(where: typed, sort: [.asc(f.priority)], options: QueryOptions(limit: 2, cursor: page.nextCursor))
        XCTAssertEqual(next.data.map(\.id), ["t5", "t4"])

        XCTAssertEqual(try TaskRecord.queryOne(where: f.tags.contains("car"))?.id, "t4")
        XCTAssertEqual(try TaskRecord.queryOne(where: f.title.eq("food"), sort: [.desc(f.priority)])?.id, "t5")
        XCTAssertEqual(try TaskRecord.queryOne(where: f.title.eq("food"), sort: [.desc(f.priority)])?.id,
                       try TaskRecord.queryOne(["title": "food"], options: QueryOptions(sortOrder: [("priority", -1)]))?.id)
        XCTAssertNil(try TaskRecord.queryOne(where: f.title.eq("none")))

        XCTAssertEqual(try TaskRecord.count(where: typed), 4)
        XCTAssertEqual(try TaskRecord.count(where: typed), try TaskRecord.count(open))
        XCTAssertEqual(try TaskRecord.count(where: nil), 5)
        let either = ModelFilter<TaskRecord>.or([f.tags.contains("car"), .and([f.title.eq("rent"), f.priority.lt(3)])])
        XCTAssertEqual(try TaskRecord.query(where: either, sort: [.asc(f.id)]).map(\.id), ["t3", "t4"])
        XCTAssertEqual(try CrashTestRecord.count(where: CrashTestRecord.fields.active.eq(true)), 2)
        XCTAssertEqual(try CrashTestRecord.count(where: CrashTestRecord.fields.active.eq(true)), try CrashTestRecord.count(["active": true]))
    }

    func testTypedAggregateRowsAnswerTheRawRowsValues() async throws {
        _ = try await seeded()
        let title = f.title.group, month = f.createdAt.period(.month), red = f.tags.has("red")
        let n = TaskRecord.aggregateCount(), total = f.priority.sum(), mean = f.priority.avg()
        let low = f.priority.min(), high = f.priority.max(), latest = f.createdAt.max()
        let rows = try TaskRecord.aggregate(groupBy: [title, month, red], operations: [n, total, mean, low, high, latest])
        let raw = try TaskRecord.aggregate(AggregateOptions(
            groupBy: ["title", .datePeriod(field: "createdAt", period: .month), .stringSetMembership(field: "tags", contains: "red")],
            operations: [AggregateOperation(type: .count), AggregateOperation(type: .sum, field: "priority"),
                         AggregateOperation(type: .avg, field: "priority"), AggregateOperation(type: .min, field: "priority"),
                         AggregateOperation(type: .max, field: "priority"), AggregateOperation(type: .max, field: "createdAt")]
        ))
        XCTAssertEqual(rows.map(\.raw), raw)
        XCTAssertEqual(rows.count, 5)
        for row in rows {
            let group = try XCTUnwrap(row.raw["group"]?.objectValue)
            XCTAssertEqual(row[title], group["title"]?.stringValue)
            XCTAssertEqual(row[month], group["createdAt_month"]?.stringValue)
            XCTAssertEqual(row[red].map { $0 ? "true" : "false" }, group["has_tags_red"]?.stringValue)
            XCTAssertEqual(row[n].map(Double.init), row.raw["count"]?.numberValue)
            XCTAssertEqual(row[total], row.raw["sum_priority"]?.numberValue)
            XCTAssertEqual(row[mean], row.raw["avg_priority"]?.numberValue)
            XCTAssertEqual(row[low], row.raw["min_priority"]?.numberValue)
            XCTAssertEqual(row[high], row.raw["max_priority"]?.numberValue)
            XCTAssertEqual(row[latest], row.raw["max_createdAt"]?.stringValue)
        }
        let rentJanuary = try XCTUnwrap(rows.first { $0[title] == "rent" && $0[month] == "2026-01" })
        XCTAssertEqual(rentJanuary[red], true)
        XCTAssertEqual(rentJanuary[n], 1)
        XCTAssertEqual(rentJanuary[total], 3)
        XCTAssertEqual(rentJanuary[latest], "2026-01-05")

        // A stringset facet: one row per member, its value the member string.
        let tag = f.tags.group
        let facets = try TaskRecord.aggregate(groupBy: [tag], operations: [n], where: f.priority.gte(2))
        XCTAssertEqual(facets.map(\.raw), try TaskRecord.aggregate(AggregateOptions(
            groupBy: ["tags"], operations: [AggregateOperation(type: .count)], filter: ["priority": ["$gte": 2]])))
        var byMember: [String: Int] = [:]
        for row in facets { if let member = row[tag] { byMember[member] = row[n] } }
        XCTAssertEqual(byMember, ["home": 2, "red": 1, "car": 1])

        // `min`/`max` of the id answer its stored strings.
        let firstId = f.id.min(), lastId = f.id.max()
        let ids = try TaskRecord.aggregate(groupBy: [title], operations: [firstId, lastId])
        XCTAssertEqual(ids.map(\.raw), try TaskRecord.aggregate(AggregateOptions(
            groupBy: ["title"], operations: [AggregateOperation(type: .min, field: "id"), AggregateOperation(type: .max, field: "id")])))
        var spans: [String: [String]] = [:]
        for row in ids { if let name = row[title], let lo = row[firstId], let hi = row[lastId] { spans[name] = [lo, hi] } }
        XCTAssertEqual(spans, ["rent": ["t1", "t3"], "food": ["t2", "t5"], "fuel": ["t4", "t4"]])

        // A boolean level answers a `Bool`.
        let active = CrashTestRecord.fields.active.group, score = CrashTestRecord.fields.score.sum()
        let crash = try CrashTestRecord.aggregate(groupBy: [active], operations: [score])
        var scores: [Bool: Double] = [:]
        for row in crash { if let flag = row[active] { scores[flag] = row[score] } }
        XCTAssertEqual(scores, [true: 5, false: 2])
    }

    func testACustomOutputFieldAndAnUnrequestedKey() async throws {
        _ = try await seeded()
        let total = f.priority.sum(as: "total"), n = TaskRecord.aggregateCount(as: "n")
        let rows = try TaskRecord.aggregate(groupBy: [], operations: [total, n])
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.raw["total"], 15)
        XCTAssertEqual(row[total], 15)
        XCTAssertEqual(row[n], 5)
        XCTAssertEqual(row.raw["group"], .object([:]))
        // Keys the request did not name answer nil.
        XCTAssertNil(row[f.title.group])
        XCTAssertNil(row[f.priority.sum()])
        XCTAssertNil(row[TaskRecord.aggregateCount()])
    }

    func testATypedSortBesideAnOptionsSortIsRefusedBeforeAnythingIsRead() throws {
        // No default client: a read would stop at `requireDefault()`.
        JsBaoClient.clearDefault()
        let sorts: [QueryOptions] = [QueryOptions(sort: ["title": 1]), QueryOptions(sortOrder: [("title", 1)])]
        for options in sorts {
            XCTAssertThrowsError(try TaskRecord.query(where: nil, sort: [.asc(f.priority)], options: options)) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
            }
            XCTAssertThrowsError(try TaskRecord.queryPaged(where: nil, sort: [.asc(f.priority)], options: options)) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
            }
            XCTAssertThrowsError(try TaskRecord.queryOne(where: nil, sort: [.desc(f.priority)], options: options, include: [])) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
            }
        }
    }
}
