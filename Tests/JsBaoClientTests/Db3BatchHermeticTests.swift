import XCTest
@testable import JsBaoClient

/// #5243 behavior 24 — `client.db3.batch` and `batchRead` on the wire.
///
/// Each operation encodes to the route's op (a write's `model`, `action`, its
/// fields; a read's `query`, `count` or `aggregate` with its options), both
/// calls send their route's method, path and body, and the answers decode:
/// a batch's writes with its `reads`, each read result at its index as a
/// page, a count, aggregate rows, or `.refused(code:status:error:)`.
final class Db3BatchHermeticTests: XCTestCase {

    private static let id = "01JD5243BAT000000000000AAA"

    private func api(_ json: String, status: Int = 200) -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    private func body(_ call: RecordedRequest?) -> [String: JSONValue]? {
        if case .object(let object)? = call?.jsonBody { return object }
        return nil
    }

    private static let batchAnswer = """
    {"applied": 2, "added": [{"model": "Note", "id": "r1", "appliedFields": {"ownerId": "u-1"}}], "updated": [], "deleted": 1,
     "upserted": [], "incremented": [{"index": 7, "model": "Note", "id": "r1", "values": {"n": 3, "score": 1.5}}],
     "requestId": "01JD5243REQ000000000000AAA",
     "reads": [
       {"index": 1, "model": "Note", "action": "query", "ok": true, "items": [{"id": "r1", "title": "a"}], "hasMore": true, "nextCursor": "c1", "prevCursor": "c0"},
       {"index": 3, "model": "Note", "action": "count", "ok": true, "count": 4},
       {"index": 4, "model": "Tag", "action": "aggregate", "ok": true, "result": [{"group": {}, "count": 2}]},
       {"index": 5, "model": "Note", "action": "query", "ok": false, "code": "DB3_PAGE_TOO_LARGE", "status": 400, "error": "too large"}
     ],
     "cost": {"rowsRead": 12, "rowsWritten": 3}}
    """

    func testBatchSendsEachOperationAsTheRouteTakesIt() async throws {
        let (db3, transport) = api(Self.batchAnswer)
        _ = try await db3.batch(Self.id, [
            .create(model: "Note", data: ["title": "a"]),
            .query(model: "Note", filter: ["title": "a"], sort: ["n": -1], limit: 5, cursor: "c0"),
            .patch(model: "Note", id: "r1", data: ["title": "b"], condition: ["title": "a"]),
            .count(model: "Note"),
            .aggregate(model: "Tag", options: ["operations": [["type": "count"]]]),
            .delete(model: "Note", id: "r2"),
            .upsert(model: "Note", constraint: "Note_slug_unique", data: ["slug": "s"]),
            .increment(model: "Note", id: "r1", fields: ["n": 1], requestId: "01JD5243OPR000000000000AAA"),
        ], options: Db3BatchOptions(atomic: false, requestId: "01JD5243REQ000000000000AAA"))
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)/records/batch")
        XCTAssertEqual(body(transport.lastCall), [
            "operations": [
                ["model": "Note", "action": "create", "data": ["title": "a"]],
                ["model": "Note", "action": "query", "filter": ["title": "a"], "sort": ["n": -1], "limit": 5, "cursor": "c0"],
                ["model": "Note", "action": "patch", "id": "r1", "data": ["title": "b"], "condition": ["title": "a"]],
                ["model": "Note", "action": "count"],
                ["model": "Tag", "action": "aggregate", "options": ["operations": [["type": "count"]]]],
                ["model": "Note", "action": "delete", "id": "r2"],
                ["model": "Note", "action": "upsert", "constraint": "Note_slug_unique", "data": ["slug": "s"]],
                ["model": "Note", "action": "increment", "id": "r1", "fields": ["n": 1], "requestId": "01JD5243OPR000000000000AAA"],
            ],
            "atomic": false,
            "requestId": "01JD5243REQ000000000000AAA",
        ])
    }

    func testBatchDecodesTheWritesAndEachReadAtItsIndex() async throws {
        let (db3, _) = api(Self.batchAnswer)
        let result = try await db3.batch(Self.id, [.create(model: "Note", data: ["title": "a"]), .count(model: "Note")])
        XCTAssertEqual(result.applied, 2)
        XCTAssertEqual(result.added.map(\.id), ["r1"])
        XCTAssertEqual(result.added.first?.appliedFields?["ownerId"], "u-1")
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(result.requestId, "01JD5243REQ000000000000AAA")
        XCTAssertEqual(result.cost?.rowsRead, 12)
        let reads = try XCTUnwrap(result.reads)
        XCTAssertEqual(reads.map(\.index), [1, 3, 4, 5])
        XCTAssertEqual(reads.map(\.model), ["Note", "Note", "Tag", "Note"])
        guard case .query(let items, let hasMore, let nextCursor, let prevCursor) = reads[0].answer else { return XCTFail("\(reads[0])") }
        XCTAssertEqual(items, [["id": "r1", "title": "a"]])
        XCTAssertTrue(hasMore)
        XCTAssertEqual(nextCursor, "c1")
        XCTAssertEqual(prevCursor, "c0")
        XCTAssertEqual(result.incremented, [Db3BatchIncremented(index: 7, model: "Note", id: "r1", values: ["n": 3, "score": 1.5])])
        XCTAssertEqual(reads[1].answer, .count(4))
        XCTAssertEqual(reads[2].answer, .aggregate([["group": [:], "count": 2]]))
        XCTAssertEqual(reads[3].answer, .refused(code: "DB3_PAGE_TOO_LARGE", status: 400, error: "too large"))
    }

    func testBatchReadSendsTheReadsAndDecodesTheResultsWithTheCost() async throws {
        let (db3, transport) = api("""
        {"results": [
          {"index": 0, "model": "Note", "action": "query", "ok": true, "items": [], "hasMore": false},
          {"index": 1, "model": "Note", "action": "count", "ok": true, "count": 0},
          {"index": 2, "model": "Note", "action": "query", "ok": false, "code": "QUERY_INDEX_NOT_ON_SERVER", "status": 400, "error": "no index"}
        ], "cost": {"rowsRead": 2, "rowsWritten": 0}}
        """)
        let answer = try await db3.batchRead(Self.id, [
            .query(model: "Note", include: [["model": "Tag", "type": "hasMany", "foreignKey": "noteId"]]),
            .count(model: "Note", filter: ["done": false]),
            .query(model: "Note"),
        ], atomic: false)
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)/records/batch-read")
        XCTAssertEqual(body(transport.lastCall), [
            "operations": [
                ["model": "Note", "action": "query", "include": [["model": "Tag", "type": "hasMany", "foreignKey": "noteId"]]],
                ["model": "Note", "action": "count", "filter": ["done": false]],
                ["model": "Note", "action": "query"],
            ],
            "atomic": false,
        ])
        XCTAssertEqual(answer.results.map(\.index), [0, 1, 2])
        XCTAssertEqual(answer.results[0].answer, .query(items: [], hasMore: false, nextCursor: nil, prevCursor: nil))
        XCTAssertEqual(answer.results[1].answer, .count(0))
        XCTAssertEqual(answer.results[2].answer, .refused(code: "QUERY_INDEX_NOT_ON_SERVER", status: 400, error: "no index"))
        XCTAssertEqual(answer.cost?.rowsRead, 2)

        // Without `atomic`, the body carries none.
        _ = try await db3.batchRead(Self.id, [.count(model: "Note")])
        XCTAssertEqual(body(transport.lastCall), ["operations": [["model": "Note", "action": "count"]]])
    }

    func testBatchReadThrowsTheRoutesRefusal() async throws {
        let (db3, _) = api(#"{"error": "too many", "code": "BATCH_TOO_LARGE"}"#, status: 400)
        do {
            _ = try await db3.batchRead(Self.id, [.count(model: "Note")])
            XCTFail("batchRead should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverCode, "BATCH_TOO_LARGE")
        }
    }

    func testAPartialBatchDecodesEachIncrementsValues() async throws {
        let (db3, _) = api("""
        {"applied": 1, "added": [], "updated": [], "deleted": 0, "atomic": false,
         "incremented": [{"index": 0, "model": "Note", "id": "r1", "values": {"views": 11}}],
         "results": [
           {"index": 0, "model": "Note", "id": "r1", "ok": true, "kind": "incremented", "values": {"views": 11}},
           {"index": 1, "model": "Note", "id": "r2", "ok": false, "code": "DB3_CONDITION_NOT_MET", "status": 409, "error": "no"}
         ]}
        """)
        let result = try await db3.batch(Self.id, [
            .increment(model: "Note", id: "r1", fields: ["views": 1]),
            .increment(model: "Note", id: "r2", fields: ["views": 1]),
        ], options: Db3BatchOptions(atomic: false))
        XCTAssertEqual(result.incremented?.first?.values, ["views": 11])
        let results = try XCTUnwrap(result.results)
        XCTAssertEqual(results[0].kind, "incremented")
        XCTAssertEqual(results[0].values, ["views": 11])
        XCTAssertNil(results[1].values)
        XCTAssertEqual(results[1].code, "DB3_CONDITION_NOT_MET")
    }

    func testAHookedUpsertDecodesWhatTheHookRulesWrote() async throws {
        let (db3, _) = api("""
        {"applied": 1, "added": [], "updated": [], "deleted": 0, "atomic": false,
         "upserted": [{"index": 0, "model": "Note", "id": "r1", "created": true, "appliedFields": {"ownerId": "u-1", "createdAt": 1700000000000}}],
         "results": [
           {"index": 0, "model": "Note", "id": "r1", "ok": true, "kind": "upserted", "created": true, "appliedFields": {"ownerId": "u-1", "createdAt": 1700000000000}}
         ]}
        """)
        let result = try await db3.batch(Self.id, [
            .upsert(model: "Note", constraint: "Note_slug_unique", data: ["slug": "s"]),
        ], options: Db3BatchOptions(atomic: false))
        let upserted = try XCTUnwrap(result.upserted?.first)
        XCTAssertTrue(upserted.created)
        XCTAssertEqual(upserted.appliedFields?["ownerId"], "u-1")
        XCTAssertEqual(upserted.appliedFields?["createdAt"], 1700000000000)
        let applied = try XCTUnwrap(result.results?.first)
        XCTAssertEqual(applied.kind, "upserted")
        XCTAssertEqual(applied.appliedFields?["ownerId"], "u-1")
    }
}
