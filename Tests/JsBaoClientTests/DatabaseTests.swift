import XCTest
@testable import JsBaoClient

/// Database CRUD and permissions against the live server. (The CEL-context
/// metadata cases this file once ported were removed with the surface, #3991.)
///
/// The timing suite (js-bao-client-database-timing.test.ts) is ported in
/// `DatabaseOperationTimingLiveTests.swift`, not here.
final class DatabaseTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var databaseId: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-databases")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        // Create a database
        let db = try await client.databases.create(params: CreateDatabaseParams(
            title: "Database Test DB",
            databaseType: "test-type"
        ))
        databaseId = db.databaseId
        XCTAssertFalse(databaseId.isEmpty, "Failed to create database")
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    // MARK: - CRUD

    func testCreateAndGetDatabase() async throws {
        let db = try await client.databases.create(params: CreateDatabaseParams(
            title: "CRUD Test DB",
            databaseType: "crud-type"
        ))
        let dbId = db.databaseId
        XCTAssertFalse(dbId.isEmpty)

        let fetched = try await client.databases.get(databaseId: dbId)
        XCTAssertEqual(fetched.title, "CRUD Test DB")
    }

    func testListDatabases() async throws {
        let list = try await client.databases.list()
        XCTAssertGreaterThanOrEqual(list.count, 1)
    }

    /// The `owner` filter narrows the listing to one creator (#2245, parity
    /// with the JS client's `databases.list({ owner })`). The caller here is
    /// the app owner, so this goes through the server's app-wide-authority
    /// branch — the one that reads the creator's own index partition.
    func testListDatabasesFilteredByOwner() async throws {
        let mine = try await client.databases.list(owner: testApp.ownerUserId)
        XCTAssertTrue(mine.contains { $0.databaseId == databaseId })
        XCTAssertTrue(
            mine.allSatisfy { $0.createdBy == testApp.ownerUserId },
            "owner filter returned a database created by someone else"
        )

        // An owner who created nothing is an empty list, not an error. A
        // synthetic id is enough to reach that branch, and keeps the check off
        // the admin user-creation endpoint.
        let strangerId = "01" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
            .prefix(24)
        let theirs = try await client.databases.list(owner: strangerId)
        XCTAssertTrue(theirs.isEmpty)
    }

    func testUpdateDatabase() async throws {
        let result = try await client.databases.update(databaseId: databaseId, params: UpdateDatabaseParams(
            title: "Updated Title"
        ))
        XCTAssertEqual(result.title, "Updated Title")
    }

    func testDeleteDatabase() async throws {
        let db = try await client.databases.create(params: CreateDatabaseParams(
            title: "Delete Me",
            databaseType: "delete-type"
        ))
        let dbId = db.databaseId

        let result = try await client.databases.delete(databaseId: dbId)
        XCTAssertTrue(result.success)
    }

    // MARK: - Permissions

    func testGrantAndRevokePermission() async throws {
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        let grantResult = try await client.databases.addManager(
            databaseId: databaseId,
            params: AddManagerParams(userId: user2.userId)
        )
        XCTAssertEqual(grantResult.userId, user2.userId)
        XCTAssertEqual(grantResult.permission, "manager")

        let permissions = try await client.databases.listPermissions(databaseId: databaseId)
        let user2Perm = permissions.first { $0.userId == user2.userId }
        XCTAssertNotNil(user2Perm)

        let revokeResult = try await client.databases.removeManager(
            databaseId: databaseId,
            userId: user2.userId
        )
        XCTAssertTrue(revokeResult.success)
    }
}
