import XCTest
@testable import JsBaoClient

/// #6328 behavior 23 — `client.db3.parallel(_:)` on the wire.
///
/// The requests encode to the envelope `{ requests: [{ db3Id, route, body }] }`,
/// each body exactly what `batch` or `batchRead` sends; the call is one
/// `POST /db3/records/parallel`; and each answer decodes in its place: a
/// `batch` item's writes, a `batch-read` item's results, or the error envelope
/// of an item answered 400 or more, which does not throw.
final class Db3ParallelHermeticTests: XCTestCase {

    private static let a = "01JD6328PAR000000000000AAA"
    private static let b = "01JD6328PAR000000000000BBB"
    private static let c = "01JD6328PAR000000000000CCC"

    private func api(_ json: String, status: Int = 200) -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    private func body(_ call: RecordedRequest?) -> [String: JSONValue]? {
        if case .object(let object)? = call?.jsonBody { return object }
        return nil
    }

    private static let answer = """
    {"results": [
      {"status": 200, "body": {"applied": 1, "added": [{"model": "Note", "id": "r1"}], "updated": [], "deleted": 0, "upserted": [], "requestId": "01JD6328REQ000000000000AAA"}},
      {"status": 200, "body": {"results": [{"index": 0, "model": "Note", "action": "count", "ok": true, "count": 4}], "cost": {"rowsRead": 1, "rowsWritten": 0}}},
      {"status": 404, "body": {"error": "Document not found", "status": 404, "code": "DB3_NOT_FOUND", "details": {"code": "DB3_NOT_FOUND"}}}
    ]}
    """

    func testParallelSendsOneEnvelopeOfEachRoutesBody() async throws {
        let (db3, transport) = api(Self.answer)
        _ = try await db3.parallel([
            .batch(Self.a, [.create(model: "Note", data: ["title": "a"])], options: Db3BatchOptions(atomic: false, requestId: "01JD6328REQ000000000000AAA")),
            .batchRead(Self.b, [.count(model: "Note")]),
            .batchRead(Self.c, [.query(model: "Note", limit: 2)], atomic: false),
        ])
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/records/parallel")
        XCTAssertEqual(body(transport.lastCall), [
            "requests": [
                ["db3Id": .string(Self.a), "route": "batch", "body": [
                    "operations": [["model": "Note", "action": "create", "data": ["title": "a"]]],
                    "atomic": false,
                    "requestId": "01JD6328REQ000000000000AAA",
                ]],
                ["db3Id": .string(Self.b), "route": "batch-read", "body": ["operations": [["model": "Note", "action": "count"]]]],
                ["db3Id": .string(Self.c), "route": "batch-read", "body": [
                    "operations": [["model": "Note", "action": "query", "limit": 2]],
                    "atomic": false,
                ]],
            ],
        ])
    }

    func testParallelDecodesEachAnswerInItsPlaceAndDoesNotThrowForARefusedItem() async throws {
        let (db3, _) = api(Self.answer)
        let response = try await db3.parallel([
            .batch(Self.a, [.create(model: "Note", data: ["title": "a"])]),
            .batchRead(Self.b, [.count(model: "Note")]),
            .batchRead(Self.c, [.count(model: "Note")]),
        ])
        XCTAssertEqual(response.results.map(\.status), [200, 200, 404])
        guard case .batch(let written) = response.results[0].answer else { return XCTFail("\(response.results[0])") }
        XCTAssertEqual(written.applied, 1)
        XCTAssertEqual(written.added.map(\.id), ["r1"])
        XCTAssertEqual(written.requestId, "01JD6328REQ000000000000AAA")
        guard case .batchRead(let read) = response.results[1].answer else { return XCTFail("\(response.results[1])") }
        XCTAssertEqual(read.results.first?.answer, .count(4))
        XCTAssertEqual(read.cost?.rowsRead, 1)
        guard case .refused(let refusal) = response.results[2].answer else { return XCTFail("\(response.results[2])") }
        XCTAssertEqual(refusal.code, "DB3_NOT_FOUND")
        XCTAssertEqual(refusal.status, 404)
        XCTAssertEqual(refusal.error, "Document not found")
    }

    func testParallelThrowsTheEnvelopesRefusal() async throws {
        let (db3, _) = api(#"{"error": "same db3", "status": 400, "code": "DB3_PARALLEL_DUPLICATE_DB3", "details": {"indexes": [0, 1]}}"#, status: 400)
        do {
            _ = try await db3.parallel([.batchRead(Self.a, [.count(model: "Note")]), .batchRead(Self.a, [.count(model: "Note")])])
            XCTFail("parallel should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverCode, "DB3_PARALLEL_DUPLICATE_DB3")
        }
    }
}
