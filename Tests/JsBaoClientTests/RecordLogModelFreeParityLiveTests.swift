import XCTest
@testable import JsBaoClient

/// A model-free Swift client and a model-free JS client (a Node child,
/// ``ModelFreeJSChild``) on one format-3 document of a live app: each sees the
/// other's writes to a model nobody declared, and the two agree on every
/// record (intent criterion 1, Swift part).
final class RecordLogModelFreeParityLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var children: [ModelFreeJSChild] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-model-free-parity")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for child in children { child.stop() }
        children = []
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func child(_ documentId: String) async throws -> ModelFreeJSChild {
        let child = try ModelFreeJSChild(app: live.app, documentId: documentId)
        children.append(child)
        try await child.ready()
        return child
    }

    /// Rows as canonical JSON (keys sorted), compared as UTF-8 bytes.
    private func canonical(_ rows: [JSONValue]) -> [UInt8] {
        Array(RecordLogJSON.text(.array(rows.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") })).utf8)
    }

    /// Behaviour 20: each client writes, replaces and adds to the other's set;
    /// both read the same rows as the room holds, and a cursor one mints pages
    /// the other's query.
    func testASwiftAndAJSModelFreeClientAgreeOnEveryRecord() async throws {
        let swift = try await live.client("swift", models: [])
        let documentId = try await live.createDocument(swift)
        try await live.open(swift, documentId)
        let js = try await child(documentId)
        let records = swift.documents.records(documentId)

        let pre = "\u{E9}", decomposed = "e\u{301}"
        let fromJS = try await js.send([
            "op": "put", "model": "Memo",
            "data": ["id": "j1", "s": "js", "n": 1.5, "b": true, "z": nil, "tags": [.string(pre), .string(decomposed), "j"]],
        ])
        XCTAssertEqual(fromJS["tags"]?.arrayValue?.count, 3, "the JS client keeps both spellings")
        try records.put("Memo", ["id": "s1", "s": "swift", "n": 2, "b": false, "z": nil, "tags": ["s", "w"]])
        try await js.send(["op": "settle"])
        try await live.settled(swift, documentId)

        // Each replaces the other's set, then adds to it.
        try await eventually(timeout: 30, description: "Swift to hold the JS record") { try records.get("Memo", id: "j1") != nil }
        try records.patch("Memo", id: "j1", ["tags": ["j", "r"]])
        try records.patch("Memo", id: "j1", ["tags": .setChange(add: ["fromSwift"])])
        try await eventually(timeout: 30, description: "the JS child to hold the Swift record") {
            try await js.send(["op": "get", "model": "Memo", "id": "s1"]) != .null
        }
        try await js.send(["op": "patch", "model": "Memo", "id": "s1", "data": ["tags": [.string(decomposed), "w"]]])
        try await js.send(["op": "patch", "model": "Memo", "id": "s1", "data": ["tags": ["$add": [.string(pre)]]]])
        try await js.send(["op": "settle"])
        try await live.settled(swift, documentId)

        let room = try await live.roomRows(documentId, "Memo")
        var roomRows: [JSONValue] = []
        for (_, row) in room {
            var row = row
            row.removeValue(forKey: "type")
            roomRows.append(try JSONCoding.decodeData(JSONValue.self, from: JSONSerialization.data(withJSONObject: row)))
        }
        XCTAssertEqual(roomRows.count, 2)
        let s1Tags = roomRows.first { $0["id"] == "s1" }?["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(s1Tags.map { Array($0.utf8) }, [decomposed, "w", pre].map { Array($0.utf8) },
                       "the JS writes against the Swift record: both spellings, two members, in byte order")
        XCTAssertEqual(roomRows.first { $0["id"] == "j1" }?["tags"], ["fromSwift", "j", "r"])

        try await eventually(timeout: 30, description: "both clients to read the room's rows") {
            let swiftRows = try records.query("Memo", nil, options: QueryOptions(sort: ["id": 1])).data.map { JSONValue.object($0.raw) }
            let jsRows = try await js.send(["op": "query", "model": "Memo", "options": ["sort": ["id": 1]]])["data"]?.arrayValue ?? []
            return self.canonical(swiftRows) == self.canonical(roomRows) && self.canonical(jsRows) == self.canonical(roomRows)
        }

        // A cursor one client minted pages the other's query.
        let swiftFirst = try records.query("Memo", nil, options: QueryOptions(sort: ["id": 1], limit: 1))
        XCTAssertEqual(swiftFirst.data.map { $0["id"] }, ["j1"])
        // Both clients order a db3 by the sort, then `_id`, then the document,
        // and carry the document under the JS client's tie-break key (#4700).
        let swiftPayload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(swiftFirst.nextCursor))
            .flatMap { try? JSONCoding.decodeData(JSONValue.self, from: $0) })
        XCTAssertEqual(swiftPayload["sortFields"], ["id", "_tiebreak:doc_id"])
        XCTAssertEqual(swiftPayload["values"]?["_tiebreak:doc_id"], .string(documentId))
        let jsNext = try await js.send([
            "op": "query", "model": "Memo",
            "options": ["sort": ["id": 1], "limit": 1, "uniqueStartKey": .string(try XCTUnwrap(swiftFirst.nextCursor))],
        ])
        XCTAssertEqual(jsNext["data"]?.arrayValue?.map { $0["id"] }, ["s1"])
        let jsFirst = try await js.send(["op": "query", "model": "Memo", "options": ["sort": ["id": 1], "limit": 1]])
        let jsCursor = try XCTUnwrap(jsFirst["nextCursor"]?.stringValue)
        let swiftNext = try records.query("Memo", nil, options: QueryOptions(sort: ["id": 1], limit: 1, cursor: jsCursor))
        XCTAssertEqual(swiftNext.data.map { $0["id"] }, ["s1"], "a JS cursor pages the Swift query")
    }

    /// Edge: a child that cannot start fails with its stderr, well before the
    /// wait's timeout, and a child that started is killed when the test ends.
    func testAChildThatCannotStartFailsWithItsStderrAndAStartedOneIsKilled() async throws {
        let swift = try await live.client("swift", models: [])
        let documentId = try await live.createDocument(swift)
        let broken = try ModelFreeJSChild(app: live.app, documentId: documentId, requestText: "not json")
        children.append(broken)
        let started = Date()
        do {
            try await broken.ready(timeout: 60)
            XCTFail("a child handed a request it cannot parse must not answer ready")
        } catch let error as TestSetupError {
            XCTAssertTrue(error.message.contains("the JS child exited"), error.message)
            XCTAssertTrue(error.message.contains("JSON"), "the failure carries the child's stderr: \(error.message)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 55, "a child that cannot start fails, never a hang")

        try await live.open(swift, documentId)
        let js = try await child(documentId)
        XCTAssertTrue(js.isRunning)
        js.stop()
        XCTAssertFalse(js.isRunning, "stop, as tearDown calls it, kills the child")
    }

    /// The vehicle: a record the JS child puts reaches the Swift client's view.
    func testAJSChildsPutReachesTheSwiftClient() async throws {
        let swift = try await live.client("swift", models: [])
        let documentId = try await live.createDocument(swift)
        try await live.open(swift, documentId)
        let js = try await child(documentId)

        let put = try await js.send(["op": "put", "model": "Memo", "data": ["id": "j1", "title": "from js", "tags": ["a"]]])
        XCTAssertEqual(put["title"], "from js")
        try await js.send(["op": "settle"])
        let binding = try live.binding(swift, documentId)
        let row = try await eventuallyValue(timeout: 30, description: "the JS child's record to reach Swift") {
            try binding.store.read(model: "Memo", id: "j1")
        }
        XCTAssertEqual(row["title"], "from js")
        XCTAssertEqual(row["tags"], ["a"])
    }
}
