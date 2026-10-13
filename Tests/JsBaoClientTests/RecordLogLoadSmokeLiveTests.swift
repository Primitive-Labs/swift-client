import XCTest
@testable import JsBaoClient

/// The vehicle of the Swift receipt suites, before any of them rests on it: a
/// chunk encoded in Swift (`GzipFixture`, CryptoKit sha256) is accepted by a
/// format-3 document's multipart ingest route, the session completes, and the
/// room counts its rows.
final class RecordLogLoadSmokeLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-record-log-load-smoke")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testAChunkEncodedInSwiftIsAcceptedByTheIngestRouteAndTheRoomCountsItsRows() async throws {
        let client = try await live.client("smoke", models: [Self.note])
        let documentId = try await live.createDocument(client)
        let load = RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
        let ids = recordLogIds(250, prefix: "s")
        let committed = try await load.load([
            RecordLogLoadChunk(model: "Note", index: 0, lines: ids.enumerated().map { i, id in
                (id, ["title": .string("smoke \(id)"), "n": .number(Double(i))])
            }),
        ])
        let sessionId = try XCTUnwrap(committed["sessionId"] as? String)
        let done = try await load.until(sessionId) { ($0["state"] as? String) == "complete" }
        XCTAssertEqual((done["state"] as? String), "complete", "\(done)")
        let counted = try await load.count("Note")
        XCTAssertEqual(counted, 250)
        let record = try await load.record("Note", "s00007")
        XCTAssertEqual(record?["title"] as? String, "smoke s00007")
    }
}
