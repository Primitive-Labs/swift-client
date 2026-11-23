import XCTest
@testable import JsBaoClient

/// #6331 behavior 27 — `client.db3.deleteWhere` and `patchWhere` on the wire.
///
/// Each sends its route's method, path and body (`filter`, `data` on a patch,
/// and `limit`, `cursor` and `requestId` only when given) and decodes the
/// answer as ``Db3WriteWhereResult``: a cut page's `cutBy` and `nextCursor`,
/// and a page that matched nothing with a null `lsn`.
final class Db3WriteWhereHermeticTests: XCTestCase {

    private static let id = "01JD6331WHR000000000000AAA"

    private func api(_ json: String, status: Int = 200) -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    private func body(_ call: RecordedRequest?) -> [String: JSONValue]? {
        if case .object(let object)? = call?.jsonBody { return object }
        return nil
    }

    func testDeleteWhereSendsTheFilterAndPagingAndDecodesACutPage() async throws {
        let (db3, transport) = api("""
        {"ok": true, "changed": 2, "hasMore": true, "nextCursor": "c1", "cutBy": "entryBytes", "lsn": 41,
         "requestId": "01JD6331REQ000000000000AAA", "cost": {"rowsRead": 3, "rowsWritten": 2}}
        """)
        let result = try await db3.deleteWhere(
            Self.id, model: "Txn", filter: ["accountId": "a1"], limit: 500, cursor: "c0", requestId: "01JD6331REQ000000000000AAA"
        )
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)/records/Txn/delete-where")
        XCTAssertEqual(body(transport.lastCall), [
            "filter": ["accountId": "a1"],
            "limit": 500,
            "cursor": "c0",
            "requestId": "01JD6331REQ000000000000AAA",
        ])
        XCTAssertEqual(result.changed, 2)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.nextCursor, "c1")
        XCTAssertEqual(result.cutBy, "entryBytes")
        XCTAssertEqual(result.lsn, 41)
        XCTAssertEqual(result.requestId, "01JD6331REQ000000000000AAA")
        XCTAssertEqual(result.cost?.rowsWritten, 2)
    }

    func testDeleteWhereWithOnlyAFilterSendsNoPagingAndDecodesANullLsn() async throws {
        let (db3, transport) = api("""
        {"ok": true, "changed": 0, "hasMore": false, "lsn": null}
        """)
        let result = try await db3.deleteWhere(Self.id, model: "Txn", filter: [:])
        XCTAssertEqual(body(transport.lastCall), ["filter": [:]])
        XCTAssertEqual(result.changed, 0)
        XCTAssertFalse(result.hasMore)
        XCTAssertNil(result.nextCursor)
        XCTAssertNil(result.cutBy)
        XCTAssertNil(result.lsn)
        XCTAssertNil(result.cost)
    }

    func testPatchWhereSendsTheFilterAndData() async throws {
        let (db3, transport) = api("""
        {"ok": true, "changed": 3, "hasMore": false, "lsn": 42}
        """)
        let result = try await db3.patchWhere(Self.id, model: "Txn", filter: ["accountId": "a1"], data: ["reviewed": true], limit: 3)
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)/records/Txn/patch-where")
        XCTAssertEqual(body(transport.lastCall), [
            "filter": ["accountId": "a1"],
            "data": ["reviewed": true],
            "limit": 3,
        ])
        XCTAssertEqual(result.changed, 3)
        XCTAssertEqual(result.lsn, 42)
    }

    func testARefusalThrowsTheRoutesError() async throws {
        let (db3, _) = api("""
        {"error": "limit must be an integer from 1 to 1000", "code": "INVALID_ARGUMENT"}
        """, status: 400)
        do {
            _ = try await db3.deleteWhere(Self.id, model: "Txn", filter: [:], limit: 1001)
            XCTFail("expected the refusal")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
        }
    }
}
