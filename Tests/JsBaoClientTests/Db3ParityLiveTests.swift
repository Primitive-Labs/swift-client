import XCTest
@testable import JsBaoClient

/// #4701 behaviours 34–36 and 51 — the db3 parity suite on Swift, over the
/// shared case files the JS suites read, against the dev server:
///
/// - 51: the loader refuses a case file holding a `"TBD"` placeholder, naming
///   the case; the committed files load.
/// - 34: every case of `tests/fixtures/db3-null-contract-4694/cases.json`
///   answers its ids on the room's `db3/:id/records/:model` and `count`, on
///   `DynamicModel` and `MultiDocModel` of a subscribed typed client, and on
///   the model-free `documents.records(id)`; a limited case is walked forward
///   by cursor and backward from the last page's `prevCursor` on every door.
/// - 35: the aggregate and count cases of `tests/fixtures/db3-parity-4701/aggregate.json`
///   answer alike on the room and `MultiDocModel.aggregate` / `count`, and the
///   recorded rows where a case has them.
/// - 36: the include cases of `tests/fixtures/db3-parity-4701/include.json`
///   answer alike on the room's `query?include=` and the typed
///   `query(include:)`, and the recorded checks hold.
///
/// Each fixture is written by a Swift model-free client with explicit ids and
/// settled; the typed legs subscribe a second client, which loads the db3 from
/// the room. Rows compare as canonical JSON: the room's `type` and the
/// client's `_meta*` keys dropped, and (for the include fixture) an empty
/// `tagIds`, absent on the room and `[]` on the client.
final class Db3ParityLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-parity-4701")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    // MARK: - The shared files

    struct ParityFileError: Error, CustomStringConvertible {
        let file: String
        let problems: [String]
        var description: String { "the db3 parity file \(file) is refused: \(problems.joined(separator: "; "))" }
    }

    /// Every place under `value` holding the placeholder `"TBD"`.
    static func placeholders(_ value: JSONValue, _ at: String) -> [String] {
        switch value {
        case .string("TBD"): return [at]
        case .array(let items): return items.enumerated().flatMap { placeholders($0.element, "\(at)[\($0.offset)]") }
        case .object(let fields): return fields.keys.sorted().flatMap { placeholders(fields[$0]!, "\(at).\($0)") }
        default: return []
        }
    }

    /// A parity file's JSON, refused when a case holds a placeholder.
    static func parse(_ text: String, file: String) throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        var problems: [String] = []
        for entry in value["cases"]?.arrayValue ?? [] {
            let name = entry["name"]?.stringValue ?? "?"
            for at in placeholders(entry, "") {
                problems.append("case \"\(name)\" holds the placeholder \"TBD\" at \(at.dropFirst())")
            }
        }
        guard problems.isEmpty else { throw ParityFileError(file: file, problems: problems) }
        return value
    }

    static func load(_ name: String) throws -> JSONValue {
        let path = "tests/fixtures/db3-parity-4701/\(name).json"
        return try parse(try ClientSourceText.repoFile(path), file: path)
    }

    /// What `path` answers from `value`: a number picks an element, a name a
    /// field, `"*"` maps the rest over a list, a missing step answers null.
    static func at(_ value: JSONValue, _ path: ArraySlice<JSONValue>) -> JSONValue {
        guard let step = path.first else { return value }
        let rest = path.dropFirst()
        if step.stringValue == "*" { return value.arrayValue.map { .array($0.map { at($0, rest) }) } ?? .null }
        if let index = step.numberValue.map({ Int($0) }) {
            guard let items = value.arrayValue, index < items.count else { return .null }
            return at(items[index], rest)
        }
        guard let key = step.stringValue, let next = value.objectValue?[key] else { return .null }
        return at(next, rest)
    }

    func testTheLoaderRefusesAPlaceholderNamingTheCaseAndTheCommittedFilesLoad() throws {
        let file = #"{"cases": [{"name": "ok", "options": {}}, {"name": "sorted", "expected": "TBD"}]}"#
        XCTAssertThrowsError(try Self.parse(file, file: "inline")) { error in
            XCTAssertEqual((error as? ParityFileError)?.problems, ["case \"sorted\" holds the placeholder \"TBD\" at expected"])
        }
        let aggregate = try Self.load("aggregate")
        XCTAssertEqual(aggregate["cases"]?.arrayValue?.count, 17)
        let include = try Self.load("include")
        XCTAssertEqual(include["cases"]?.arrayValue?.count, 7)
    }

    // MARK: - Shared machinery

    /// A route of the app API, answered as JSON.
    private func room(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        let url = try XCTUnwrap(URL(string: "\(TestConfig.httpUrl)/app/\(live.app.appId)/api\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(live.app.ownerJWT)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        if let body { request.httpBody = Data(RecordLogJSON.text(body).utf8) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestSetupError("\(method) \(path) answered \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func query(_ pairs: [String: JSONValue?]) -> String {
        var components = URLComponents()
        components.queryItems = pairs.keys.sorted().compactMap { key in
            guard let value = pairs[key] ?? nil else { return nil }
            if case .string(let text) = value { return URLQueryItem(name: key, value: text) }
            if case .number(let number) = value { return URLQueryItem(name: key, value: String(Int(number))) }
            return URLQueryItem(name: key, value: RecordLogJSON.text(value))
        }
        let text = components.percentEncodedQuery ?? ""
        return text.isEmpty ? "" : "?" + text.replacingOccurrences(of: "+", with: "%2B")
    }

    private static func recordValue(_ value: JSONValue) -> DocumentRecordValue {
        switch value {
        case .string(let text): return .string(text)
        case .number(let number): return .number(number)
        case .bool(let flag): return .bool(flag)
        case .array(let items): return .stringSet(items.compactMap(\.stringValue))
        default: return .null
        }
    }

    private static func schema(_ name: String, _ fields: [String: JSONValue]) -> PrimitiveSchema {
        var out: [String: FieldDescriptor] = ["id": FieldDescriptor(type: .id)]
        for (field, type) in fields where field != "id" {
            switch type.stringValue {
            case "number": out[field] = FieldDescriptor(type: .number)
            case "boolean": out[field] = FieldDescriptor(type: .boolean)
            case "stringset": out[field] = FieldDescriptor(type: .stringset)
            default: out[field] = FieldDescriptor(type: .string)
            }
        }
        return PrimitiveSchema(name: name, fields: out)
    }

    /// A db3 holding `rows` (model → records), written by a model-free client with explicit ids and settled.
    private func written(_ rows: [(String, [JSONValue])]) async throws -> (String, JsBaoClient) {
        let writer = try await live.client("writer", models: [])
        let id = try await live.createDocument(writer)
        let handle = try writer.db3.subscribe(id)
        try await handle.ready()
        let records = writer.documents.records(id)
        for (model, list) in rows {
            for row in list {
                var data: [String: DocumentRecordValue] = [:]
                for (field, value) in row.objectValue ?? [:] { data[field] = Self.recordValue(value) }
                try records.put(model, data)
            }
        }
        try await live.settled(writer, id)
        return (id, writer)
    }

    /// A second client with `schemas`, subscribed to `id` and live.
    private func typed(_ id: String, _ schemas: [PrimitiveSchema]) async throws -> JsBaoClient {
        let client = try await live.client("typed", models: schemas)
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        return client
    }

    /// A record as every door answers it: its own fields, `id` and `_related`,
    /// without the room's `type` and the client's `_meta*` keys; `dropEmpty`
    /// names set fields whose empty value counts as absent.
    private static func canonical(_ value: JSONValue, dropEmpty: Set<String> = []) -> JSONValue {
        switch value {
        case .array(let items): return .array(items.map { canonical($0, dropEmpty: dropEmpty) })
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, item) in fields where key != "type" && !key.hasPrefix("_meta") {
                if dropEmpty.contains(key), item.arrayValue?.isEmpty == true { continue }
                out[key] = key == "_related" ? .object((item.objectValue ?? [:]).mapValues { canonical($0, dropEmpty: dropEmpty) })
                    : canonical(item, dropEmpty: dropEmpty)
            }
            return .object(out)
        default: return value
        }
    }

    private static func sortedText(_ rows: [JSONValue]) -> [String] { rows.map { RecordLogJSON.text($0) }.sorted() }

    // MARK: - Behaviour 34: the null contract on every Swift door

    func testTheNullContractAnswersAlikeOnTheRoomAndEverySwiftDoor() async throws {
        let file = try JSONDecoder().decode(
            JSONValue.self, from: Data(try ClientSourceText.repoFile("tests/fixtures/db3-null-contract-4694/cases.json").utf8)
        )
        let model = try XCTUnwrap(file["model"]?.stringValue)
        let rows = try XCTUnwrap(file["rows"]?.arrayValue)
        let (id, writer) = try await written([(model, rows)])
        let schema = Self.schema(model, ["s": "string", "n": "number", "b": "boolean", "tags": "stringset"])
        let client = try await typed(id, [schema])
        let member = try XCTUnwrap(client.sharedModel(for: schema).member(docId: id))
        let shared = client.sharedModel(for: schema)
        let records = writer.documents.records(id)
        let base = "/db3/\(id)/records/\(model)"

        // The precheck: the model-free client holds the room's rows.
        let roomRows = try await room("GET", base + Self.query(["limit": .number(100)]))["items"]?.arrayValue ?? []
        let clientRows = try records.query(model, nil, options: QueryOptions(limit: 100)).data.map { JSONValue.object($0.raw) }
        XCTAssertEqual(Self.sortedText(roomRows.map { Self.canonical($0) }), Self.sortedText(clientRows.map { Self.canonical($0) }))

        let ids = { (rows: [JSONValue]) in rows.compactMap { $0["id"]?.stringValue } }
        for entry in file["cases"]?.arrayValue ?? [] {
            let name = entry["name"]?.stringValue ?? "?"
            let rule = Int(entry["rule"]?.numberValue ?? 0)
            let label = "rule \(rule): \(name)"
            let filter = entry["filter"]?.objectValue ?? [:]
            let expect = (entry["expect"]?.arrayValue ?? []).compactMap(\.stringValue)
            let ordered = entry["ordered"]?.boolValue ?? false
            let sortPair = entry["sort"]?.objectValue?.first.map { ($0.key, Int($0.value.numberValue ?? 1)) }
            let limit = entry["limit"]?.numberValue.map { Int($0) }
            let shape = { (got: [String]) in ordered ? got : got.sorted() }
            let filterJSON = JSONValue.object(filter)
            let sortJSON = sortPair.map { JSONValue.object([$0.0: .number(Double($0.1))]) }
            do {
                // Counts on every door.
                let roomCount = try await room("GET", base + "/count" + Self.query(["filter": filterJSON]))["count"]?.numberValue
                XCTAssertEqual(roomCount.map { Int($0) }, expect.count, "room count — \(label)")
                XCTAssertEqual(try member.count(filter), expect.count, "DynamicModel.count — \(label)")
                XCTAssertEqual(try shared.count(filter, options: QueryOptions(db3: [id])), expect.count, "MultiDocModel.count — \(label)")
                XCTAssertEqual(try records.count(model, filter), expect.count, "DocumentRecords.count — \(label)")

                guard let limit else {
                    let options = QueryOptions(sortOrder: sortPair.map { [$0] }, limit: 100)
                    let roomIds = ids(try await room("GET", base + Self.query(["filter": filterJSON, "sort": sortJSON, "limit": .number(100)]))["items"]?.arrayValue ?? [])
                    XCTAssertEqual(shape(roomIds), expect, "room — \(label)")
                    XCTAssertEqual(shape(ids(try member.query(filter, options: options).map { .object($0) })), expect, "DynamicModel — \(label)")
                    XCTAssertEqual(shape(ids(try shared.query(filter, options: QueryOptions(sortOrder: sortPair.map { [$0] }, limit: 100, db3: [id])).map { .object($0) })), expect, "MultiDocModel — \(label)")
                    XCTAssertEqual(shape(ids(try records.query(model, filter, options: options).data.map { .object($0.raw) })), expect, "DocumentRecords — \(label)")
                    continue
                }

                // A limited case: walked forward by cursor, then backward from the last page's prevCursor.
                let roomPage = { (cursor: String?) async throws -> (ids: [String], next: String?, prev: String?, more: Bool) in
                    let page = try await self.room("GET", base + Self.query([
                        "filter": filterJSON, "sort": sortJSON, "limit": .number(Double(limit)), "cursor": cursor.map { .string($0) },
                    ]))
                    return (ids(page["items"]?.arrayValue ?? []), page["nextCursor"]?.stringValue, page["prevCursor"]?.stringValue,
                            page["hasMore"]?.boolValue ?? false)
                }
                var forward: [[String]] = []
                var lastPrev: String?
                var cursor: String?
                repeat {
                    let page = try await roomPage(cursor)
                    if page.ids.isEmpty { break }
                    forward.append(page.ids)
                    lastPrev = page.prev
                    cursor = page.more ? page.next : nil
                } while cursor != nil && forward.count <= expect.count + 1
                XCTAssertEqual(forward.flatMap { $0 }, expect, "room forward — \(label)")
                var backward: [[String]] = []
                var back = lastPrev
                while let at = back, backward.count <= expect.count + 1 {
                    let page = try await roomPage(at)
                    if page.ids.isEmpty { break }
                    backward.append(page.ids)
                    // A backward page answers in sort order; its nextCursor steps further back.
                    back = page.more ? page.next : nil
                }
                XCTAssertEqual(backward.reversed().flatMap { $0 } + (forward.last ?? []), expect, "room backward — \(label)")

                for (door, page) in [
                    ("DynamicModel", { (o: QueryOptions) in try member.queryPaged(filter, options: o) }),
                    ("MultiDocModel", { (o: QueryOptions) in
                        var scoped = o
                        scoped.db3 = [id]
                        return try shared.queryPaged(filter, options: scoped)
                    }),
                    ("DocumentRecords", { (o: QueryOptions) in try records.query(model, filter, options: o) }),
                ] as [(String, (QueryOptions) throws -> PagedQueryResult<PrimitiveRow>)] {
                    var pages: [PagedQueryResult<PrimitiveRow>] = []
                    var next: String?
                    repeat {
                        let got = try page(QueryOptions(sortOrder: sortPair.map { [$0] }, limit: limit, cursor: next))
                        pages.append(got)
                        next = got.hasMore ? got.nextCursor : nil
                    } while next != nil && pages.count <= expect.count + 1
                    let walked = pages.map { ids($0.data.map { .object($0.raw) }) }
                    XCTAssertEqual(walked.flatMap { $0 }, expect, "\(door) forward — \(label)")
                    XCTAssertEqual(walked.count, (expect.count + limit - 1) / limit, "\(door): page sizes exact — \(label)")
                    var backwardPages: [[String]] = []
                    var prev = pages.last?.prevCursor
                    while let at = prev, backwardPages.count <= expect.count + 1 {
                        let got = try page(QueryOptions(sortOrder: sortPair.map { [$0] }, limit: limit, cursor: at, direction: .backward))
                        if got.data.isEmpty { break }
                        backwardPages.append(ids(got.data.map { .object($0.raw) }))
                        prev = got.hasMore ? got.nextCursor : nil
                    }
                    XCTAssertEqual(backwardPages.reversed().flatMap { $0 } + (walked.last ?? []), expect, "\(door) backward — \(label)")
                }
            } catch {
                XCTFail("\(label) threw \(error)")
            }
        }
    }

    // MARK: - Behaviour 35: aggregates and counts

    private static func aggregateOptions(_ options: JSONValue, db3: String) throws -> AggregateOptions {
        let groupBy: [AggregateGroupBy] = try (options["groupBy"]?.arrayValue ?? []).map { level in
            if let field = level.stringValue { return .field(field) }
            let field = try XCTUnwrap(level["field"]?.stringValue)
            if let contains = level["contains"]?.stringValue { return .stringSetMembership(field: field, contains: contains) }
            let period = try XCTUnwrap(level["period"]?.stringValue.flatMap(DatePeriod.init(rawValue:)))
            return .datePeriod(field: field, period: period)
        }
        let operations: [AggregateOperation] = try (options["operations"]?.arrayValue ?? []).map { op in
            AggregateOperation(
                type: try XCTUnwrap(op["type"]?.stringValue.flatMap(AggregateOperation.OperationType.init(rawValue:))),
                field: op["field"]?.stringValue
            )
        }
        let sort = options["sort"].flatMap { sort in
            sort["field"]?.stringValue.map { AggregateSort(field: $0, direction: Int(sort["direction"]?.numberValue ?? 1)) }
        }
        return AggregateOptions(
            groupBy: groupBy, operations: operations, filter: options["filter"]?.objectValue, sort: sort,
            limit: options["limit"]?.numberValue.map { Int($0) }, db3: [db3]
        )
    }

    func testTheAggregateAndCountCasesAnswerAlikeOnTheRoomAndTheSwiftModelApi() async throws {
        let parity = try Self.load("aggregate")
        let model = try XCTUnwrap(parity["model"]?.stringValue)
        let (id, _) = try await written([(model, parity["rows"]?.arrayValue ?? [])])
        let schema = Self.schema(model, parity["fields"]?.objectValue ?? [:])
        let client = try await typed(id, [schema])
        let shared = client.sharedModel(for: schema)
        let base = "/db3/\(id)/records/\(model)"

        for entry in parity["cases"]?.arrayValue ?? [] {
            let name = entry["name"]?.stringValue ?? "?"
            let options = try XCTUnwrap(entry["options"])
            let ordered = entry["ordered"]?.boolValue ?? false
            let compare = { (rows: [JSONValue]) in ordered ? rows.map { RecordLogJSON.text($0) } : Self.sortedText(rows) }
            do {
                let roomRows = try await room("POST", base + "/aggregate", body: .object(["options": options]))["result"]?.arrayValue ?? []
                if let expected = entry["expected"]?.arrayValue {
                    XCTAssertEqual(compare(roomRows), compare(expected), "room's recorded rows — \(name)")
                }
                let swiftRows = try shared.aggregate(Self.aggregateOptions(options, db3: id)).map { JSONValue.object($0) }
                XCTAssertEqual(compare(swiftRows), compare(roomRows), "MultiDocModel.aggregate — \(name)")
            } catch {
                XCTFail("\(name) threw \(error)")
            }
        }
        for filter in parity["counts"]?.arrayValue ?? [] {
            let roomCount = try await room("GET", base + "/count" + Self.query(["filter": filter]))["count"]?.numberValue
            XCTAssertEqual(
                try shared.count(filter.objectValue ?? [:], options: QueryOptions(db3: [id])), roomCount.map { Int($0) },
                RecordLogJSON.text(filter)
            )
        }
    }

    // MARK: - Behaviour 36: includes

    private func include(_ spec: JSONValue, _ client: JsBaoClient, _ schemas: [String: PrimitiveSchema]) throws -> Include {
        let model = try XCTUnwrap(spec["model"]?.stringValue)
        let target = client.sharedModel(for: try XCTUnwrap(schemas[model], model))
        let sort = spec["sort"]?.objectValue?.mapValues { Int($0.numberValue ?? 1) }
        let projection = spec["projection"]?.objectValue?.mapValues { Int($0.numberValue ?? 1) }
        return Include(
            type: try XCTUnwrap(spec["type"]?.stringValue.flatMap(IncludeKind.init(rawValue:))), target: target,
            sourceField: spec["sourceField"]?.stringValue, foreignKey: spec["foreignKey"]?.stringValue,
            filter: spec["filter"]?.objectValue, sort: sort, limit: spec["limit"]?.numberValue.map { Int($0) },
            projection: projection, resultKey: spec["as"]?.stringValue,
            include: try spec["include"]?.arrayValue?.map { try include($0, client, schemas) }
        )
    }

    func testTheIncludeCasesAnswerAlikeOnTheRoomAndTheSwiftModelApi() async throws {
        let parity = try Self.load("include")
        let models = parity["models"]?.objectValue ?? [:]
        let rows = parity["rows"]?.objectValue ?? [:]
        var schemas: [String: PrimitiveSchema] = [:]
        var fixture: [(String, [JSONValue])] = []
        for key in ["supplier", "product", "customer", "order", "line", "tag"] {
            let entry = try XCTUnwrap(models[key], key)
            let name = try XCTUnwrap(entry["name"]?.stringValue)
            schemas[name] = Self.schema(name, entry["fields"]?.objectValue ?? [:])
            fixture.append((name, rows[key]?.arrayValue ?? []))
        }
        let (id, _) = try await written(fixture)
        let client = try await typed(id, Array(schemas.values))

        for entry in parity["cases"]?.arrayValue ?? [] {
            let name = entry["name"]?.stringValue ?? "?"
            do {
                let model = try XCTUnwrap(entry["model"].flatMap { models[$0.stringValue ?? ""] }?["name"]?.stringValue)
                let specs = entry["include"] ?? .array([])
                let roomRows = try await room("GET", "/db3/\(id)/records/\(model)" + Self.query(["include": specs]))["items"]?.arrayValue ?? []
                let room = Self.canonical(.array(roomRows), dropEmpty: ["tagIds"])
                for check in entry["expected"]?.arrayValue ?? [] {
                    let path = check["path"]?.arrayValue ?? []
                    XCTAssertEqual(Self.at(room, path[...]), check["equals"] ?? .null, "\(name): \(RecordLogJSON.text(.array(path)))")
                }
                let includes = try (specs.arrayValue ?? []).map { try include($0, client, schemas) }
                let swiftRows = try client.sharedModel(for: try XCTUnwrap(schemas[model]))
                    .query(nil, options: QueryOptions(limit: 100, db3: [id]), include: includes)
                let swift = Self.canonical(.array(swiftRows.map { .object($0) }), dropEmpty: ["tagIds"])
                XCTAssertEqual(RecordLogJSON.text(swift), RecordLogJSON.text(room), "typed query(include:) — \(name)")
            } catch {
                XCTFail("\(name) threw \(error)")
            }
        }
    }
}
