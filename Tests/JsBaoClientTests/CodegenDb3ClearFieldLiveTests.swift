import XCTest
@testable import JsBaoClient

/// #5021 behavior 22 — a generated model's `date` field set to `nil` and
/// saved stores null in the room, live.
///
/// The room's row shows the field null (or absent) while the other fields
/// stay, and a second client opening the db3 afterwards reads it as nil.
final class CodegenDb3ClearFieldLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let date = "2026-10-29T00:00:00.000Z"

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-codegen-db3-clear-5021")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testANilDateIsStoredNullInTheRoomAndReadNilByAnotherClient() async throws {
        let x = try await live.client("x", models: [TaskRecord.primitiveSchema])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        JsBaoClient.configureDefault(x)
        var task = try TaskRecord(id: "t1", title: "Close me", priority: 2, createdAt: Self.date).save(in: documentId)
        try await live.settled(x, documentId)
        let stored = try await live.roomRows(documentId, "tasks")["t1"]
        XCTAssertEqual(stored?["createdAt"] as? String, Self.date)

        task.createdAt = nil
        _ = try task.save(in: documentId)
        try await live.settled(x, documentId)
        let rows = try await live.roomRows(documentId, "tasks")
        let row = try XCTUnwrap(rows["t1"])
        XCTAssertTrue(row["createdAt"] == nil || row["createdAt"] is NSNull, "createdAt is null in the room: \(row)")
        XCTAssertEqual(row["title"] as? String, "Close me")
        XCTAssertEqual((row["priority"] as? NSNumber)?.doubleValue, 2)

        let y = try await live.client("y", models: [TaskRecord.primitiveSchema])
        try await live.open(y, documentId)
        let members = try live.member(y, documentId, "tasks")
        try await eventually(timeout: 20, description: "y to hold the record") { members.find(id: "t1") != nil }
        let seen = try XCTUnwrap(members.find(id: "t1"))
        XCTAssertNil(seen["createdAt"])
        XCTAssertEqual(seen["title"], .string("Close me"))
    }
}
