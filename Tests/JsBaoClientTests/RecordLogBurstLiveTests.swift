import XCTest
@testable import JsBaoClient

/// A burst of 200 record-log saves from one Swift client against a real room
/// (#4484 behavior 14): every entry is acknowledged, the room holds the 200
/// rows, and a second client sees all of them. The wall time is printed; the
/// frames themselves are the hermetic sender tests' subject.
final class RecordLogBurstLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let row = PrimitiveSchema(
        name: "BurstRow",
        fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        live = try RecordLogLiveApp(ctx: ctx, app: try await ctx.createTestApp(name: "swift-record-log-burst"))
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testTwoHundredSavesSettleAndASecondClientSeesThemAll() async throws {
        let writer = try await live.client("writer", models: [Self.row])
        let documentId = try await live.createDocument(writer)
        try await live.open(writer, documentId)
        let rows = try live.member(writer, documentId, "BurstRow")

        let started = Date()
        for index in 0..<200 {
            _ = try rows.create(id: String(format: "row-%03d", index), values: ["label": .string("burst \(index)")])
        }
        let stored = Date().timeIntervalSince(started)
        try await live.settled(writer, documentId, timeout: 60)
        let acknowledged = Date().timeIntervalSince(started)
        print("[4484] Swift burst: 200 saves stored in \(Int(stored * 1000)) ms, all acknowledged after \(Int(acknowledged * 1000)) ms")

        let counted = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/documents/\(documentId)/records/BurstRow/count", body: nil,
            jwt: live.app.ownerJWT
        )
        XCTAssertEqual((counted["count"] as? NSNumber)?.intValue, 200, "the room holds every row")

        let reader = try await live.client("reader", models: [Self.row])
        try await live.open(reader, documentId)
        let seen = try live.member(reader, documentId, "BurstRow")
        try await eventually(timeout: 30, description: "the second client to see all 200") {
            try seen.count() == 200
        }
        XCTAssertEqual(seen.find(id: "row-199")?["label"], .string("burst 199"))
    }
}
