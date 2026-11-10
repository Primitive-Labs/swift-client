import XCTest
@testable import JsBaoClient

/// #5309 behavior 5 — after creates, patches and deletes, `$search` answers
/// alike wherever it answers, live against the dev server: on a db3 with a
/// text index placed `both` over `title` and `body` (`title` weighing 3),
/// for each tokenizer, the Swift device (the bundled SQLite), a model-free
/// JS device in a Node child (better-sqlite3) and the server answer the same
/// ids in the same order with `_score` equal to 1e-9, after the Swift
/// device's writes, after the JS device's, for #5224's deletion fixture, and
/// on a Swift device that subscribes after the writes. Each comparison waits
/// first until both devices hold the server's rows (``converged(_:js:id:)``):
/// a writer's settlement does not wait for the other device's rows.
final class Db3TextSearchWriteParityLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var children: [ModelFreeJSChild] = []
    private typealias L = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-text-write-parity-5309")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for child in children { child.stop() }
        children = []
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static let searches = Db3TextSearchParityLiveTests.searches + ["x", "filler"]
    private static let filler = Array(repeating: "filler", count: 100).joined(separator: " ")

    /// A route of the app API, answered as JSON.
    private func server(_ path: String, _ pairs: [String: JSONValue]) async throws -> JSONValue {
        var components = URLComponents()
        components.queryItems = pairs.keys.sorted().map { key in
            if case .number(let number)? = pairs[key] { return URLQueryItem(name: key, value: String(Int(number))) }
            return URLQueryItem(name: key, value: RecordLogJSON.text(pairs[key] ?? .null))
        }
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let url = try XCTUnwrap(URL(string: "\(TestConfig.httpUrl)/app/\(live.app.appId)/api\(path)?\(query)"))
        var request = URLRequest(url: url)
        request.setValue("Bearer \(live.app.ownerJWT)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestSetupError("GET \(path) answered \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The rows of `Note` each side holds, by id, as `title` and `body`.
    private static func keyed(_ rows: [JSONValue]) -> [String: String] {
        Dictionary(rows.map { row in
            (row["id"]?.stringValue ?? "", RecordLogJSON.text([row["title"] ?? .null, row["body"] ?? .null]))
        }, uniquingKeysWith: { a, _ in a })
    }

    private func serverRows(_ id: String, _ filter: JSONValue? = nil) async throws -> [JSONValue] {
        var pairs: [String: JSONValue] = ["limit": 1_000]
        if let filter { pairs["filter"] = filter }
        return try await server("/db3/\(id)/records/Note", pairs)["items"]?.arrayValue ?? []
    }

    private func swiftRows(_ client: JsBaoClient, _ id: String, _ filter: DocumentFilter = [:]) throws -> [JSONValue] {
        try client.db3.records(id).query("Note", filter, options: QueryOptions(limit: 1_000)).data.map { .object($0.raw) }
    }

    private func jsRows(_ js: ModelFreeJSChild, _ filter: JSONValue = [:]) async throws -> [JSONValue] {
        try await js.send(["op": "query", "model": "Note", "filter": filter, "options": ["limit": 1_000]])["data"]?.arrayValue ?? []
    }

    /// Wait (30 s) until every Swift device in `swift` and the JS device hold
    /// the server's unfiltered `Note` rows: the same ids, each with the same
    /// `title` and `body`. A timeout names the device and a row that differs,
    /// so it reads as replication, not ranking.
    private func converged(
        _ swift: [(name: String, client: JsBaoClient)], js: ModelFreeJSChild, id: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        var last = "never compared"
        while Date() < deadline {
            let truth = Self.keyed(try await serverRows(id))
            var sides = try swift.map { ($0.name, Self.keyed(try swiftRows($0.client, id))) }
            sides.append(("the JS device", Self.keyed(try await jsRows(js))))
            let differing = sides.compactMap { name, rows -> String? in
                guard rows != truth else { return nil }
                let key = Set(rows.keys).union(truth.keys).sorted().first { rows[$0] != truth[$0] } ?? "?"
                return "\(name) holds \(key) as \(rows[key] ?? "nothing"), the server \(truth[key] ?? "nothing")"
            }
            if differing.isEmpty { return }
            last = differing.joined(separator: "; ")
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("replication, not ranking: the devices did not converge on the server's rows in 30 s: \(last)", file: file, line: line)
        throw TestSetupError("the devices did not converge: \(last)")
    }

    private static func ranked(_ rows: [JSONValue]) -> [(id: String, score: Double)] {
        rows.map { ($0["id"]?.stringValue ?? "", $0["_score"]?.numberValue ?? .nan) }
    }

    /// Every search of the set answered alike by each Swift device, the JS device and the server.
    private func expectParity(
        _ swift: [(name: String, client: JsBaoClient)], js: ModelFreeJSChild, id: String, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for search in Self.searches {
            let onServer = Self.ranked(try await serverRows(id, ["$search": search]))
            var sides = try swift.map { ($0.name, Self.ranked(try swiftRows($0.client, id, ["$search": search]))) }
            sides.append(("the JS device", Self.ranked(try await jsRows(js, ["$search": search]))))
            for (name, answer) in sides {
                let what = "\(label): \(name) vs the server, \(RecordLogJSON.text(search))"
                XCTAssertEqual(answer.map(\.id), onServer.map(\.id), what, file: file, line: line)
                for (a, b) in zip(answer, onServer) { XCTAssertEqual(a.score, b.score, accuracy: 1e-9, "\(what) \(a.id)", file: file, line: line) }
            }
        }
    }

    func testSwiftJSAndTheServerRankAlikeAfterCreatesPatchesAndDeletes() async throws {
        for tokenizer in ["unicode61", "porter"] {
            let id = try await live.db3Written(0, model: "Note")
            _ = try await ctx.appRequest(
                method: "POST", appId: live.app.appId, path: "/db3/\(id)/indexes",
                body: ["model": "Note", "fields": ["title", "body"], "kind": "text", "on": "both",
                       "text": ["tokenizer": tokenizer, "weights": ["title": 3]]],
                jwt: live.app.ownerJWT
            )
            let x = try await live.client("x-\(tokenizer)", models: [])
            try await live.open(x, id)
            let records = x.db3.records(id)

            // The Swift device creates the rows, patches one and deletes one.
            for (n, row) in Db3TextSearchParityLiveTests.rows.enumerated() {
                try await records.put("Note", ["id": .string(String(format: "p%02d", n)), "title": .string(row.0), "body": .string(row.1)], confirm: true)
            }
            try await records.patch("Note", id: "p00", ["body": .string("a sweet apple apple dessert")], confirm: true)
            try await records.delete("Note", id: "p05", confirm: true)
            try await live.settled(x, id)
            let js = try ModelFreeJSChild(app: live.app, documentId: id)
            children.append(js)
            try await js.ready()
            let swift = [(name: "the Swift device", client: x)]
            try await converged(swift, js: js, id: id)
            XCTAssertGreaterThanOrEqual(try swiftRows(x, id, ["$search": "apple"]).count, 6)
            try await expectParity(swift, js: js, id: id, "\(tokenizer), after the Swift writes")

            // The JS device creates one, patches others and deletes one.
            try await js.send(["op": "put", "model": "Note", "data": ["id": "j00", "title": "Apple from node", "body": "pear runner"]])
            try await js.send(["op": "patch", "model": "Note", "id": "p01", "data": ["title": "Green apple apple"]])
            try await js.send(["op": "patch", "model": "Note", "id": "p08", "data": ["body": "running early"]])
            try await js.send(["op": "delete", "model": "Note", "id": "p02"])
            try await js.send(["op": "settle"])
            try await converged(swift, js: js, id: id)
            try await expectParity(swift, js: js, id: id, "\(tokenizer), after the JS writes")

            // #5224's deletion fixture, its third row deleted.
            for (n, title) in ["apple", "apple apple x x x x x x x x", Self.filler].enumerated() {
                try await records.put("Note", ["id": .string("d\(n)"), "title": .string(title)], confirm: true)
            }
            try await records.delete("Note", id: "d2", confirm: true)
            try await live.settled(x, id)
            try await converged(swift, js: js, id: id)
            let filler = try await serverRows(id, ["$search": "filler"])
            XCTAssertEqual(filler.count, 0, "the deleted third row matches nothing")
            let apple = try await serverRows(id, ["$search": "apple"]).compactMap { $0["id"]?.stringValue }
            XCTAssertLessThan(try XCTUnwrap(apple.firstIndex(of: "d0")), try XCTUnwrap(apple.firstIndex(of: "d1")))
            try await expectParity(swift, js: js, id: id, "\(tokenizer), the deletion fixture")

            // A Swift device that subscribes after the writes builds its table fresh and answers the same.
            let y = try await live.client("y-\(tokenizer)", models: [])
            try await live.open(y, id)
            let table = RecordLogIndexes.textTableName(documentId: id, model: "Note")
            try await eventually(timeout: 30, description: "the fresh device's text table") {
                try L.objects(self.live, y, id, "table", like: table) == [table]
                    && L.objects(self.live, y, id, "trigger", like: "\(table)__%").count == 3
            }
            let both = swift + [(name: "the fresh Swift device", client: y)]
            try await converged(both, js: js, id: id)
            try await expectParity(both, js: js, id: id, "\(tokenizer), on a device that subscribed after the writes")
            let drift = try await Db3DeviceIndexOracle.driftOnACopy(live.binding(x, id).store)
            XCTAssertEqual(drift, [], tokenizer)
        }
    }
}
