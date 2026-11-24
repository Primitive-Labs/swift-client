import XCTest
@testable import JsBaoClient

/// #6331 behavior 28 — Swift's `client.db3.deleteWhere` and `patchWhere`
/// against the dev server, the twin of `tests/client/db3-write-where-6331.test.ts`.
///
/// A patch of the records matching a filter, two a page, visits each once by
/// passing `nextCursor` back, though the patch leaves them matching; a delete
/// over the same filter removes them and leaves the others.
final class Db3WriteWhereLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-write-where-6331")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testPatchWherePagesWithTheCursorAndDeleteWhereRemovesTheMatches() async throws {
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/documents",
            body: ["title": "Ledger", "documentFormat": 3], jwt: live.app.ownerJWT
        )
        let id = try XCTUnwrap(created["documentId"] as? String)
        let operations: [[String: Any]] = (0..<5).map { n in
            ["action": "create", "model": "Txn", "id": RecordLogLiveApp.ulid(), "data": ["group": n < 3 ? "a" : "b", "n": n, "seen": 0]]
        }
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(id)/records/batch",
            body: ["operations": operations], jwt: live.app.ownerJWT
        )
        let client = try await live.client("owner", models: [])

        let first = try await client.db3.patchWhere(id, model: "Txn", filter: ["group": "a"], data: ["seen": 1], limit: 2)
        XCTAssertEqual(first.changed, 2)
        XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertNotNil(first.lsn)
        let rest = try await client.db3.patchWhere(id, model: "Txn", filter: ["group": "a"], data: ["seen": 1], limit: 2, cursor: cursor)
        XCTAssertEqual(rest.changed, 1)
        XCTAssertFalse(rest.hasMore)
        XCTAssertNil(rest.nextCursor)
        let patched = try await live.roomRows(id, "Txn").values
        XCTAssertEqual(patched.filter { $0["group"] as? String == "a" }.compactMap { $0["seen"] as? Int }, [1, 1, 1])
        XCTAssertEqual(patched.filter { $0["group"] as? String == "b" }.compactMap { $0["seen"] as? Int }, [0, 0])

        let deleted = try await client.db3.deleteWhere(id, model: "Txn", filter: ["group": "a"])
        XCTAssertEqual(deleted.changed, 3)
        XCTAssertFalse(deleted.hasMore)
        let left = try await live.roomRows(id, "Txn").values.compactMap { $0["group"] as? String }
        XCTAssertEqual(left, ["b", "b"])

        let none = try await client.db3.deleteWhere(id, model: "Txn", filter: ["group": "a"])
        XCTAssertEqual(none.changed, 0)
        XCTAssertNil(none.lsn)
    }
}
