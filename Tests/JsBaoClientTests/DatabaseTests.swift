import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-database-metadata.test.ts and js-bao-client-database-timing.test.ts
/// Tests database CRUD and metadata operations.
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
            title: "Metadata Test DB",
            databaseType: "test-type"
        ))
        databaseId = db.databaseId
        XCTAssertFalse(databaseId.isEmpty, "Failed to create database")
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    // MARK: - Metadata

    func testSetMetadataKeys() async throws {
        let result = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "blue",
            "count": 42,
            "active": true,
        ])

        let metadata = result.metadata
        XCTAssertEqual(metadata?["color"]?.stringValue, "blue")
        XCTAssertEqual(metadata?["count"]?.numberValue, 42)
        XCTAssertEqual(metadata?["active"]?.boolValue, true)
    }

    func testMergeWithExistingMetadata() async throws {
        _ = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "blue",
            "count": 42,
        ])

        let result = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "label": "hello",
        ])

        let metadata = result.metadata
        XCTAssertEqual(metadata?["color"]?.stringValue, "blue")
        XCTAssertEqual(metadata?["count"]?.numberValue, 42)
        XCTAssertEqual(metadata?["label"]?.stringValue, "hello")
    }

    func testRemoveKeysSetToNull() async throws {
        _ = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "blue",
            "count": 42,
        ])

        let result = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": .null,
        ])

        let metadata = result.metadata
        XCTAssertNil(metadata?["color"])
        XCTAssertEqual(metadata?["count"]?.numberValue, 42)
    }

    func testReflectMetadataInGet() async throws {
        _ = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "red",
            "count": 7,
        ])

        let db = try await client.databases.get(databaseId: databaseId)
        let metadata = db.metadata
        XCTAssertEqual(metadata?["color"]?.stringValue, "red")
        XCTAssertEqual(metadata?["count"]?.numberValue, 7)
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

        let grantResult = try await client.databases.grantPermission(databaseId: databaseId, params: GrantPermissionParams(
            userId: user2.userId,
            permission: "manager"
        ))
        XCTAssertEqual(grantResult.userId, user2.userId)

        let permissions = try await client.databases.listPermissions(databaseId: databaseId)
        let user2Perm = permissions.first { $0.userId == user2.userId }
        XCTAssertNotNil(user2Perm)

        let revokeResult = try await client.databases.revokePermission(databaseId: databaseId, userId: user2.userId)
        XCTAssertTrue(revokeResult.success)
    }
}
