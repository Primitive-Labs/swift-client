import XCTest
@testable import JsBaoClient

/// #5223 behavior 20 — `$search` on the device answers the same in Swift as
/// in js-bao, live against the dev server: on two db3s, one with a
/// `unicode61` and one with a `porter` text index over `title` and `body`
/// (`title` weighing 3), registered before the JS client opens, the Swift
/// client (the bundled SQLite) and a model-free JS client in a Node child
/// (better-sqlite3) answer the same ids in the same order and the same
/// `_score` (to 1e-9) for a string, `all`, `any`, `prefix`, `fields`, a
/// phrase and every hostile input; a ranked cursor either mints pages the
/// other's query.
final class Db3TextSearchParityLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var children: [ModelFreeJSChild] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-text-parity-5223")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for child in children { child.stop() }
        children = []
        await live?.destroy()
        await ctx?.cleanup()
    }

    static let rows: [(String, String)] = [
        ("Red apple pie", "a sweet apple dessert"), ("Green apple", "tart and crisp"), ("Apple apple apple", "nothing else"),
        ("Pear tart", "pears and apples baked"), ("Running notes", "notes about runners"), ("Open phrase here", "near or and not"),
        ("title x a b", "apple runner"), ("Apple tart", "apple tarts with pears"), ("Plum and pear", "running late"),
        ("Café crème", "naïve apple"), ("Apples", "baked apple apple"), ("Apple runner", "runs every morning"),
    ]

    static let searches: [JSONValue] = [
        "apple", ["query": "apple tart"], ["query": "pear runners", "mode": "any"], ["query": "app", "prefix": true],
        ["query": "apple", "fields": ["title"]], "\"apple pie\"", "cafe", "run",
        "a\"b", "a*", "NEAR", "OR", "AND", "NOT", "^a", "title:x", "{a}", "(a)", "-a", "a OR b", "NEAR(a b)", "\"open phrase",
    ]

    /// A db3 with the rows and a device text index of `tokenizer`, registered over HTTP before any client opens it.
    private func db3(_ tokenizer: String) async throws -> String {
        let id = try await live.db3Written(0, model: "Note")
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(id)/indexes",
            body: ["model": "Note", "fields": ["title", "body"], "kind": "text", "on": "device",
                   "text": ["tokenizer": tokenizer, "weights": ["title": 3]]],
            jwt: live.app.ownerJWT
        )
        for (n, row) in Self.rows.enumerated() {
            _ = try await ctx.appRequest(
                method: "POST", appId: live.app.appId, path: "/documents/\(id)/records/Note",
                body: ["id": String(format: "p%02d", n), "data": ["title": row.0, "body": row.1]], jwt: live.app.ownerJWT
            )
        }
        return id
    }

    private func child(_ documentId: String) async throws -> ModelFreeJSChild {
        let child = try ModelFreeJSChild(app: live.app, documentId: documentId)
        children.append(child)
        try await child.ready()
        return child
    }

    private func ranked(_ rows: [JSONValue]) -> [(id: String, score: Double)] {
        rows.map { ($0["id"]?.stringValue ?? "", $0["_score"]?.numberValue ?? .nan) }
    }

    func testSwiftAndJSAnswerTheSameIdsOrderAndScoreAndPageEachOthersRankedCursors() async throws {
        let x = try await live.client("x", models: [])
        for tokenizer in ["unicode61", "porter"] {
            let id = try await db3(tokenizer)
            try await live.open(x, id)
            let js = try await child(id)
            let records = x.db3.records(id)
            try await eventually(timeout: 30, description: "both clients to hold the rows and the index") {
                let swift = try records.query("Note", ["$search": "apple"], options: QueryOptions(limit: 50)).data.count
                let fromJS = try await js.send(["op": "query", "model": "Note", "filter": ["$search": "apple"], "options": ["limit": 50]])
                return swift >= 8 && swift == (fromJS["data"]?.arrayValue?.count ?? -1)
            }
            for search in Self.searches {
                let swift = ranked(try records.query("Note", ["$search": search], options: QueryOptions(limit: 50)).data.map { .object($0.raw) })
                let fromJS = ranked(try await js.send([
                    "op": "query", "model": "Note", "filter": ["$search": search], "options": ["limit": 50],
                ])["data"]?.arrayValue ?? [])
                let label = "\(tokenizer) \(RecordLogJSON.text(search))"
                XCTAssertEqual(swift.map(\.id), fromJS.map(\.id), label)
                for (a, b) in zip(swift, fromJS) { XCTAssertEqual(a.score, b.score, accuracy: 1e-9, "\(label) \(a.id)") }
                XCTAssertTrue(swift.allSatisfy { $0.score.isFinite }, label)
            }

            // A ranked cursor one client mints pages the other's query.
            let full = try records.query("Note", ["$search": "apple"], options: QueryOptions(limit: 50)).data.compactMap { $0["id"]?.stringValue }
            XCTAssertGreaterThan(full.count, 4)
            let swiftFirst = try records.query("Note", ["$search": "apple"], options: QueryOptions(limit: 2))
            let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(swiftFirst.nextCursor))
                .flatMap { try? JSONCoding.decodeData(JSONValue.self, from: $0) })
            XCTAssertEqual(payload["sortFields"], ["_score", "id", "_tiebreak:doc_id"])
            let jsNext = try await js.send([
                "op": "query", "model": "Note", "filter": ["$search": "apple"],
                "options": ["limit": 2, "uniqueStartKey": .string(try XCTUnwrap(swiftFirst.nextCursor))],
            ])
            XCTAssertEqual(jsNext["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, Array(full[2..<4]), "a Swift cursor pages the JS query")
            let jsFirst = try await js.send(["op": "query", "model": "Note", "filter": ["$search": "apple"], "options": ["limit": 2]])
            let jsCursor = try XCTUnwrap(jsFirst["nextCursor"]?.stringValue)
            let swiftNext = try records.query("Note", ["$search": "apple"], options: QueryOptions(limit: 2, cursor: jsCursor))
            XCTAssertEqual(swiftNext.data.compactMap { $0["id"]?.stringValue }, Array(full[2..<4]), "a JS cursor pages the Swift query")
        }
    }
}
