import XCTest
@testable import JsBaoClient

/// #4889 behavior 19 — `client.db3.ingests` drives a bulk load over the
/// `db3/:db3Id/*` mounts against the dev server.
///
/// A load built with `buildChunks` completes and its rows read back through
/// `db3/:db3Id/records`; a format-1 document is refused `HttpError` 409
/// `NOT_A_DB3`.
final class Db3IngestsLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-ingests-4889")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func db3() async throws -> String {
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3", body: ["title": "Loaded"], jwt: live.app.ownerJWT
        )
        return try XCTUnwrap(created["id"] as? String)
    }

    func testALoadOverTheDb3MountsCompletesAndItsRowsReadBack() async throws {
        let client = try await live.client("db3-ingests", models: [Self.note])
        let db3Id = try await db3()
        let rows = (0..<40).map { DocumentIngestRow(model: "Note", id: String(format: "note-%03d", $0), patch: ["title": .string("Note \($0)")]) }
        let chunks = try client.db3.ingests.buildChunks(rows: rows, options: DocumentIngestBuildOptions(cutRows: 15))
        XCTAssertEqual(chunks.count, 3)
        let session = try await client.db3.ingests.create(db3Id: db3Id)
        XCTAssertEqual(session.state, "uploading")
        for chunk in chunks {
            let stored = try await client.db3.ingests.uploadChunk(db3Id: db3Id, sessionId: session.sessionId, chunk: chunk)
            XCTAssertTrue(stored.ok)
        }
        _ = try await client.db3.ingests.commit(db3Id: db3Id, sessionId: session.sessionId)
        var loaded = try await client.db3.ingests.get(db3Id: db3Id, sessionId: session.sessionId)
        let deadline = Date().addingTimeInterval(120)
        while !["complete", "failed", "aborted"].contains(loaded.state), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            loaded = try await client.db3.ingests.get(db3Id: db3Id, sessionId: session.sessionId)
        }
        XCTAssertEqual(loaded.state, "complete", "\(String(describing: loaded.failure))")
        XCTAssertEqual(loaded.refusedRows, 0)
        let listed = try await client.db3.ingests.list(db3Id: db3Id, limit: 5)
        XCTAssertTrue(listed.items.contains { $0.sessionId == session.sessionId })

        let read = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/db3/\(db3Id)/records/Note?limit=100", body: nil, jwt: live.app.ownerJWT
        )
        let items = try XCTUnwrap(read["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, rows.map(\.id))

        let second = try await client.db3.ingests.create(db3Id: db3Id)
        let aborted = try await client.db3.ingests.abort(db3Id: db3Id, sessionId: second.sessionId)
        XCTAssertEqual(aborted.state, "aborted")
    }

    func testAFormatOneDocumentIsRefusedNotADb3() async throws {
        let client = try await live.client("db3-ingests", models: [Self.note])
        let classic = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/documents", body: ["title": "classic"], jwt: live.app.ownerJWT
        )
        let formatOne = try XCTUnwrap(classic["documentId"] as? String)
        do {
            _ = try await client.db3.ingests.create(db3Id: formatOne)
            XCTFail("a format-1 document was not refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.serverCode, "NOT_A_DB3")
        }
    }
}
