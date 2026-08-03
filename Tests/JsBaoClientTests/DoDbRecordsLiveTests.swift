import XCTest
@testable import JsBaoClient

/// Live record CRUD through `client.databases.connect(databaseId:)` — the
/// `DoDb` handle converted to the typed transport in #1991 Phase B3
/// (behavior 6). Runs against the local dev server.
///
/// The point of these tests is loss-free round-tripping of *dynamic* user
/// record fields: `DoDb` now carries them as `[String: JSONValue]` instead of
/// an `Any` graph, so string / number / bool / null / array / nested-object
/// fields must come back exactly as they went out.
final class DoDbRecordsLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var db: DoDb!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-dodb")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        let database = try await client.databases.create(params: CreateDatabaseParams(
            title: "DoDb Records",
            databaseType: "test-type"
        ))
        db = client.databases.connect(databaseId: database.databaseId)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testSaveAndQueryRoundTripEveryFieldKind() async throws {
        let id = "rec-\(UUID().uuidString.prefix(8))"
        let record: [String: JSONValue] = [
            "id": .string(id),
            "title": .string("hello world"),
            "done": .bool(false),
            "count": .number(3),
            "note": .null,
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["deep": .object(["deeper": .string("yes")])]),
        ]

        let savedId = try await db.save(modelName: "Task", data: record)
        XCTAssertEqual(savedId, id)

        let found = try await db.find(modelName: "Task", id: id)
        let row = try XCTUnwrap(found)

        XCTAssertEqual(row["title"]?.stringValue, "hello world")
        XCTAssertEqual(row["done"]?.boolValue, false)
        XCTAssertEqual(row["count"]?.numberValue, 3)
        XCTAssertEqual(row["tags"]?.arrayValue?.compactMap { $0.stringValue }, ["a", "b"])
        XCTAssertEqual(row["nested"]?["deep"]?["deeper"]?.stringValue, "yes")
    }

    func testPatchUpdatesOnlyTheProvidedFields() async throws {
        let id = "rec-\(UUID().uuidString.prefix(8))"
        _ = try await db.save(modelName: "Task", data: [
            "id": .string(id),
            "title": .string("first"),
            "done": .bool(false),
        ])

        _ = try await db.patch(modelName: "Task", id: id, data: ["done": .bool(true)])

        let updated = try await db.find(modelName: "Task", id: id)
        let row = try XCTUnwrap(updated)
        XCTAssertEqual(row["done"]?.boolValue, true)
        XCTAssertEqual(row["title"]?.stringValue, "first", "untouched fields survive a patch")
    }

    func testCountQueryAndDeleteDecodeTheirEnvelopes() async throws {
        let prefix = "cnt-\(UUID().uuidString.prefix(8))"
        for index in 0..<3 {
            _ = try await db.save(modelName: "Counted", data: [
                "id": .string("\(prefix)-\(index)"),
                "bucket": .string(prefix),
            ])
        }

        let count = try await db.count(modelName: "Counted", filter: .object([
            "bucket": .string(prefix),
        ]))
        XCTAssertEqual(count, 3)

        let page = try await db.query(modelName: "Counted", filter: .object([
            "bucket": .string(prefix),
        ]))
        XCTAssertEqual(page.data.count, 3)

        let deleted = try await db.delete(modelName: "Counted", id: "\(prefix)-0")
        XCTAssertTrue(deleted)
        let after = try await db.count(modelName: "Counted", filter: .object([
            "bucket": .string(prefix),
        ]))
        XCTAssertEqual(after, 2)
    }

    func testIncrementReturnsThePostIncrementValues() async throws {
        let id = "inc-\(UUID().uuidString.prefix(8))"
        _ = try await db.save(modelName: "Counter", data: [
            "id": .string(id),
            "hits": .number(1),
        ])

        let values = try await db.increment(modelName: "Counter", id: id, fields: ["hits": 2])

        XCTAssertEqual(values["hits"], 3)
    }
}
