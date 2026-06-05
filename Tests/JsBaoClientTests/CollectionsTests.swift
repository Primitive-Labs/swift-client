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
        let result = try await client.collections.create(params: CreateCollectionParams(
            name: "test-collection",
            description: "A test collection"
        ))
        XCTAssertFalse(result.collectionId.isEmpty)
        XCTAssertEqual(result.name, "test-collection")
    }

    func testListCollections() async throws {
        let _ = try await client.collections.create(params: CreateCollectionParams(name: "list-test"))
        let result = try await client.collections.list()
        XCTAssertFalse(result.items.isEmpty)
    }

    func testGetCollection() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "get-test"))
        let collectionId = created.collectionId
        let result = try await client.collections.get(collectionId: collectionId)
        XCTAssertEqual(result.collectionId, collectionId)
    }

    func testUpdateCollection() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "update-test"))
        let collectionId = created.collectionId
        let result = try await client.collections.update(collectionId: collectionId, params: UpdateCollectionParams(name: "updated-name"))
        XCTAssertEqual(result.name, "updated-name")
    }

    func testAddDocumentToCollection() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "doc-test"))
        let collectionId = created.collectionId
        let result = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)
        XCTAssertEqual(result.collectionId, collectionId)
        XCTAssertEqual(result.documentId, documentId)
    }

    func testListDocumentsInCollection() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "list-docs-test"))
        let collectionId = created.collectionId
        let _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)
        let result = try await client.collections.listDocuments(collectionId: collectionId)
        XCTAssertEqual(result.items.count, 1)
    }

    func testRemoveDocumentFromCollection() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "remove-doc-test"))
        let collectionId = created.collectionId
        let _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)
        let result = try await client.collections.removeDocument(collectionId: collectionId, documentId: documentId)
        XCTAssertTrue(result.success)
    }

    func testDeleteCollection() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "delete-test"))
        let collectionId = created.collectionId
        let result = try await client.collections.delete(collectionId: collectionId)
        XCTAssertTrue(result.success)
    }

    // MARK: - Missing from JS parity

    func testListCollectionsForDocument() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "for-doc-test"))
        let collectionId = created.collectionId
        let _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)

        let result = try await client.collections.listCollectionsForDocument(documentId: documentId)
        let items = result.items
        XCTAssertGreaterThanOrEqual(items.count, 1, "Should list at least one collection for the document")
        let collIds = items.map { $0.collectionId }
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

        let created = try await client.collections.create(params: CreateCollectionParams(name: "group-perm-test"))
        let collectionId = created.collectionId

        let grantResult = try await client.collections.grantGroupPermission(
            collectionId: collectionId,
            params: GrantCollectionGroupPermissionParams(groupType: "team", groupId: "devs", permission: "reader")
        )
        XCTAssertEqual(grantResult.groupType, "team")
        XCTAssertEqual(grantResult.groupId, "devs")
        XCTAssertEqual(grantResult.permission, "reader")

        let access = try await client.collections.getAccess(collectionId: collectionId)
        let groups = access.groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.groupType, "team")

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

        let created = try await client.collections.create(params: CreateCollectionParams(name: "revoke-perm-test"))
        let collectionId = created.collectionId

        // Grant permission
        let _ = try await client.collections.grantGroupPermission(
            collectionId: collectionId,
            params: GrantCollectionGroupPermissionParams(groupType: "team", groupId: "revoke-devs", permission: "reader")
        )

        // Revoke permission
        let revokeResult = try await client.collections.revokeGroupPermission(
            collectionId: collectionId,
            groupType: "team",
            groupId: "revoke-devs"
        )
        XCTAssertTrue(revokeResult.success)

        // Verify access is empty
        let access = try await client.collections.getAccess(collectionId: collectionId)
        let groups = access.groups
        XCTAssertEqual(groups.count, 0, "Groups should be empty after revoke")

        // Cleanup
        let _ = try await client.collections.delete(collectionId: collectionId)
    }

    func testAddAndRemoveMember() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "member-test"))
        let collectionId = created.collectionId
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        let addResult = try await client.collections.addMember(
            collectionId: collectionId,
            params: .user(user2.userId, permission: .reader)
        )
        // user2 is an existing app user, so the add resolves to a direct membership.
        guard case let .direct(direct) = addResult else {
            return XCTFail("Expected a direct add for an existing user, got: \(addResult)")
        }
        XCTAssertEqual(direct.userId, user2.userId)

        let removeResult = try await client.collections.removeMember(collectionId: collectionId, userId: user2.userId)
        XCTAssertTrue(removeResult.success)
    }
}
