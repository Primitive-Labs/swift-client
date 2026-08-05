import XCTest
@testable import JsBaoClient

/// Live coverage for `databases.executeOperation(timing:)` (issue #2359).
///
/// Port of the JS client's `tests/client/js-bao-client-database-timing.test.ts`.
/// The wire-shape half — that `timing` leaves as the `X-Timing` header and not
/// as a body field — is pinned without a server in
/// `API/DatabasesExecuteOperationTimingTests.swift`; this file proves the end
/// the user actually cares about: the server sees the flag and answers with a
/// `_timing` block.
final class DatabaseOperationTimingLiveTests: XCTestCase {
    /// The op-edit gate (#666) needs a schema on the type config before
    /// registered ops can be created.
    static let schema = """
    [models.Task.fields]
    id = { type = "string" }
    title = { type = "string" }
    """

    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var databaseId: String!
    let databaseType = "swiftTimingDB"

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-db-timing")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        // Type config FIRST (with schema) — an implicit auto-create on
        // `POST /databases` would materialize a schemaless type and the op gate
        // would refuse the seed ops with 422.
        _ = try await client.requestJSON(
            method: .post,
            path: "/databases/types",
            body: [
                "databaseType": .string(databaseType),
                "schema": .string(Self.schema),
            ] as [String: JSONValue]
        )

        let db = try await client.databases.create(params: CreateDatabaseParams(
            title: "Swift Timing DB",
            databaseType: databaseType
        ))
        databaseId = db.databaseId

        let seedQuery: [String: JSONValue] = [
            "name": "seed_query",
            "type": "query",
            "modelName": "$params.modelName",
            "access": "true",
            "definition": ["filter": "$params.filter"],
            "params": [
                "modelName": ["type": "string", "required": true],
                "filter": ["type": "object", "required": true],
            ],
        ]
        _ = try await client.requestJSON(
            method: .post,
            path: "/databases/types/\(databaseType)/operations",
            body: seedQuery
        )
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private func runQuery(timing: Bool?) async throws -> JSONValue {
        try await client.databases.executeOperation(
            databaseId: databaseId,
            name: "seed_query",
            options: ExecuteOperationOptions(
                params: .object([
                    "modelName": .string("Task"),
                    "filter": .object([:]),
                ]),
                timing: timing
            )
        )
    }

    func testTimingTrueReturnsTimingBlock() async throws {
        let result = try await runQuery(timing: true)

        let timing = try XCTUnwrap(
            result["_timing"]?.objectValue,
            "expected a _timing block when timing: true was requested"
        )
        XCTAssertNotNil(timing["totalMs"]?.numberValue)
        XCTAssertNotNil(timing["doInvocation"]?.numberValue)
    }

    func testTimingOmittedReturnsNoTimingBlock() async throws {
        let result = try await runQuery(timing: nil)
        XCTAssertNil(result["_timing"])
    }

    func testTimingFalseReturnsNoTimingBlock() async throws {
        let result = try await runQuery(timing: false)
        XCTAssertNil(result["_timing"])
    }

    /// The timing block is purely additive — asking for it must not change the
    /// operation's own result. Compare the two responses with `_timing`
    /// stripped rather than naming a result key, so the assertion holds for
    /// whatever shape the query op returns.
    func testTimingPreservesOperationResult() async throws {
        let timedResult = try await runQuery(timing: true)
        let untimedResult = try await runQuery(timing: nil)
        let withTiming = try XCTUnwrap(timedResult.objectValue)
        let withoutTiming = try XCTUnwrap(untimedResult.objectValue)

        XCTAssertNotNil(withTiming["_timing"])
        XCTAssertFalse(withoutTiming.isEmpty, "expected a non-empty query result")
        XCTAssertEqual(withTiming.filter { $0.key != "_timing" }, withoutTiming)
    }
}
