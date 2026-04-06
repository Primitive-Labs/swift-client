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
        let db = try await client.databases.create(params: [
            "title": "Metadata Test DB",
            "databaseType": "test-type",
        ])
        databaseId = db["databaseId"] as? String
        XCTAssertNotNil(databaseId, "Failed to create database")
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

        let metadata = result["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["color"] as? String, "blue")
        XCTAssertEqual(metadata?["count"] as? Int, 42)
        XCTAssertEqual(metadata?["active"] as? Bool, true)
    }

    func testMergeWithExistingMetadata() async throws {
        _ = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "blue",
            "count": 42,
        ])

        let result = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "label": "hello",
        ])

        let metadata = result["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["color"] as? String, "blue")
        XCTAssertEqual(metadata?["count"] as? Int, 42)
        XCTAssertEqual(metadata?["label"] as? String, "hello")
    }

    func testRemoveKeysSetToNull() async throws {
        _ = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "blue",
            "count": 42,
        ])

        let result = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": NSNull(),
        ])

        let metadata = result["metadata"] as? [String: Any]
        XCTAssertNil(metadata?["color"])
        XCTAssertEqual(metadata?["count"] as? Int, 42)
    }

    func testReflectMetadataInGet() async throws {
        _ = try await client.databases.updateMetadata(databaseId: databaseId, metadata: [
            "color": "red",
            "count": 7,
        ])

        let db = try await client.databases.get(databaseId: databaseId)
        let metadata = db["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["color"] as? String, "red")
        XCTAssertEqual(metadata?["count"] as? Int, 7)
    }

    // MARK: - CRUD

    func testCreateAndGetDatabase() async throws {
        let db = try await client.databases.create(params: [
            "title": "CRUD Test DB",
            "databaseType": "crud-type",
        ])
        let dbId = db["databaseId"] as? String
        XCTAssertNotNil(dbId)

        let fetched = try await client.databases.get(databaseId: dbId!)
        XCTAssertEqual(fetched["title"] as? String, "CRUD Test DB")
    }

    func testListDatabases() async throws {
        let list = try await client.databases.list()
        XCTAssertGreaterThanOrEqual(list.count, 1)
    }

    func testUpdateDatabase() async throws {
        let result = try await client.databases.update(databaseId: databaseId, params: [
            "title": "Updated Title",
        ])
        XCTAssertEqual(result["title"] as? String, "Updated Title")
    }

    func testDeleteDatabase() async throws {
        let db = try await client.databases.create(params: [
            "title": "Delete Me",
            "databaseType": "delete-type",
        ])
        let dbId = db["databaseId"] as! String

        let result = try await client.databases.delete(databaseId: dbId)
        XCTAssertNotNil(result)
    }

    // MARK: - Permissions

    func testGrantAndRevokePermission() async throws {
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        let grantResult = try await client.databases.grantPermission(databaseId: databaseId, params: [
            "userId": user2.userId,
            "permission": "manager",
        ])
        XCTAssertNotNil(grantResult)

        let permissions = try await client.databases.listPermissions(databaseId: databaseId)
        let user2Perm = permissions.first { ($0["userId"] as? String) == user2.userId }
        XCTAssertNotNil(user2Perm)

        let revokeResult = try await client.databases.revokePermission(databaseId: databaseId, userId: user2.userId)
        XCTAssertNotNil(revokeResult)
    }
}
