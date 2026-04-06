import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-collections.test.ts
final class CollectionsTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var documentId: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-collections")
        documentId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Collection Doc")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testCreateCollection() async throws {
        let result = try await client.collections.create(params: [
            "name": "test-collection",
            "description": "A test collection",
        ])
        XCTAssertNotNil(result["collectionId"])
        XCTAssertEqual(result["name"] as? String, "test-collection")
    }

    func testListCollections() async throws {
        let _ = try await client.collections.create(params: ["name": "list-test"])
        let result = try await client.collections.list()
        XCTAssertNotNil(result["items"])
    }

    func testGetCollection() async throws {
        let created = try await client.collections.create(params: ["name": "get-test"])
        let collectionId = created["collectionId"] as! String
        let result = try await client.collections.get(collectionId: collectionId)
        XCTAssertEqual(result["collectionId"] as? String, collectionId)
    }

    func testUpdateCollection() async throws {
        let created = try await client.collections.create(params: ["name": "update-test"])
        let collectionId = created["collectionId"] as! String
        let result = try await client.collections.update(collectionId: collectionId, params: ["name": "updated-name"])
        XCTAssertEqual(result["name"] as? String, "updated-name")
    }

    func testAddDocumentToCollection() async throws {
        let created = try await client.collections.create(params: ["name": "doc-test"])
        let collectionId = created["collectionId"] as! String
        let result = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)
        XCTAssertNotNil(result["collectionId"])
        XCTAssertNotNil(result["documentId"])
    }

    func testListDocumentsInCollection() async throws {
        let created = try await client.collections.create(params: ["name": "list-docs-test"])
        let collectionId = created["collectionId"] as! String
        let _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)
        let result = try await client.collections.listDocuments(collectionId: collectionId)
        let items = result["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 1)
    }

    func testRemoveDocumentFromCollection() async throws {
        let created = try await client.collections.create(params: ["name": "remove-doc-test"])
        let collectionId = created["collectionId"] as! String
        let _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)
        let result = try await client.collections.removeDocument(collectionId: collectionId, documentId: documentId)
        XCTAssertEqual(result["success"] as? Bool, true)
    }

    func testDeleteCollection() async throws {
        let created = try await client.collections.create(params: ["name": "delete-test"])
        let collectionId = created["collectionId"] as! String
        let result = try await client.collections.delete(collectionId: collectionId)
        XCTAssertEqual(result["success"] as? Bool, true)
    }

    // MARK: - Missing from JS parity

    func testListCollectionsForDocument() async throws {
        let created = try await client.collections.create(params: ["name": "for-doc-test"])
        let collectionId = created["collectionId"] as! String
        let _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)

        let result = try await client.collections.listCollectionsForDocument(documentId: documentId)
        let items = result["items"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(items.count, 1, "Should list at least one collection for the document")
        let collIds = items.compactMap { $0["collectionId"] as? String }
        XCTAssertTrue(collIds.contains(collectionId))

        // Cleanup
        let _ = try await client.collections.removeDocument(collectionId: collectionId, documentId: documentId)
        let _ = try await client.collections.delete(collectionId: collectionId)
    }

    func testGrantGroupPermissionAndSeeInAccess() async throws {
        // Create a group via HTTP
        _ = try await client.makeRequest("POST", "/groups", [
            "groupType": "team",
            "groupId": "devs",
            "name": "Developers",
        ])

        let created = try await client.collections.create(params: ["name": "group-perm-test"])
        let collectionId = created["collectionId"] as! String

        let grantResult = try await client.collections.grantGroupPermission(
            collectionId: collectionId,
            params: ["groupType": "team", "groupId": "devs", "permission": "reader"]
        )
        XCTAssertEqual(grantResult["groupType"] as? String, "team")
        XCTAssertEqual(grantResult["groupId"] as? String, "devs")
        XCTAssertEqual(grantResult["permission"] as? String, "reader")

        let access = try await client.collections.getAccess(collectionId: collectionId)
        let groups = access["groups"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["groupType"] as? String, "team")

        // Cleanup
        let _ = try await client.collections.delete(collectionId: collectionId)
    }

    func testRevokeGroupPermission() async throws {
        // Create a group via HTTP (may already exist from previous test, ignore error)
        _ = try? await client.makeRequest("POST", "/groups", [
            "groupType": "team",
            "groupId": "revoke-devs",
            "name": "Revoke Developers",
        ])

        let created = try await client.collections.create(params: ["name": "revoke-perm-test"])
        let collectionId = created["collectionId"] as! String

        // Grant permission
        let _ = try await client.collections.grantGroupPermission(
            collectionId: collectionId,
            params: ["groupType": "team", "groupId": "revoke-devs", "permission": "reader"]
        )

        // Revoke permission
        let revokeResult = try await client.collections.revokeGroupPermission(
            collectionId: collectionId,
            groupType: "team",
            groupId: "revoke-devs"
        )
        XCTAssertEqual(revokeResult["success"] as? Bool, true)

        // Verify access is empty
        let access = try await client.collections.getAccess(collectionId: collectionId)
        let groups = access["groups"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 0, "Groups should be empty after revoke")

        // Cleanup
        let _ = try await client.collections.delete(collectionId: collectionId)
    }

    func testAddAndRemoveMember() async throws {
        let created = try await client.collections.create(params: ["name": "member-test"])
        let collectionId = created["collectionId"] as! String
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        let addResult = try await client.collections.addMember(collectionId: collectionId, params: [
            "userId": user2.userId,
            "permission": "reader",
        ])
        XCTAssertNotNil(addResult)

        let removeResult = try await client.collections.removeMember(collectionId: collectionId, userId: user2.userId)
        XCTAssertEqual(removeResult["success"] as? Bool, true)
    }
}
