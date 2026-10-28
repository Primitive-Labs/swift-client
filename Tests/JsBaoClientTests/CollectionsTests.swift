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

    /// A group is a member of a collection with a role, listed as the
    /// principal `group:<groupId>` (#4737). A session cannot create a group
    /// (#4735), so it is created through the admin API, held by the app owner.
    func testAddGroupMemberAndSeeItInListMembers() async throws {
        let devs = try await ctx.createGroup(app: testApp, name: "Developers").groupId

        let created = try await client.collections.create(params: CreateCollectionParams(name: "group-member-test"))
        let collectionId = created.collectionId

        let added = try await client.collections.addGroupMember(
            collectionId: collectionId, groupId: devs, role: .viewer
        )
        XCTAssertEqual(added.principal, "group:\(devs)")
        XCTAssertEqual(added.groupId, devs)
        XCTAssertEqual(added.role, .viewer)

        let members = try await client.collections.listMembers(collectionId: collectionId)
        let group = try XCTUnwrap(members.first { $0.principal == "group:\(devs)" })
        XCTAssertEqual(group.groupId, devs)
        XCTAssertEqual(group.role, .viewer)
        XCTAssertEqual(members.first { $0.userId == testApp.ownerUserId }?.role, .owner)

        // Cleanup
        let _ = try await client.collections.delete(collectionId: collectionId)
    }

    func testRemoveGroupMember() async throws {
        let revokeDevs = try await ctx.createGroup(app: testApp, name: "Revoke Developers").groupId

        let created = try await client.collections.create(params: CreateCollectionParams(name: "remove-group-test"))
        let collectionId = created.collectionId

        _ = try await client.collections.addGroupMember(
            collectionId: collectionId, groupId: revokeDevs, role: .viewer
        )

        let removeResult = try await client.collections.removeMember(
            collectionId: collectionId, principal: "group:\(revokeDevs)"
        )
        XCTAssertTrue(removeResult.success)

        let members = try await client.collections.listMembers(collectionId: collectionId)
        XCTAssertFalse(members.contains { $0.groupId != nil }, "the group should be gone after removal")

        // Cleanup
        let _ = try await client.collections.delete(collectionId: collectionId)
    }

    func testAddAndRemoveMember() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "member-test"))
        let collectionId = created.collectionId
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        let addResult = try await client.collections.addMember(
            collectionId: collectionId,
            params: .user(user2.userId, role: .viewer)
        )
        // user2 is an existing app user, so the add resolves to a direct membership.
        guard case let .direct(direct) = addResult else {
            return XCTFail("Expected a direct add for an existing user, got: \(addResult)")
        }
        XCTAssertEqual(direct.userId, user2.userId)
        XCTAssertEqual(direct.role, .viewer)

        let removeResult = try await client.collections.removeMember(
            collectionId: collectionId, principal: user2.userId
        )
        XCTAssertTrue(removeResult.success)
    }

    /// Live coverage for `documents.listGroupPermissions(includeSystem:)`
    /// (#2360). Adding a document to a collection materializes the
    /// collection's `_col-reader` / `_col-writer` system group permissions
    /// onto the document. Before the fix Swift never sent
    /// `?includeSystem=true`, so the server had already stripped those rows
    /// and the flag could not return a system group at any input.
    func testListGroupPermissionsIncludeSystemReturnsCollectionGroups() async throws {
        let created = try await client.collections.create(params: CreateCollectionParams(name: "system-groups-test"))
        let collectionId = created.collectionId
        _ = try await client.collections.addDocument(collectionId: collectionId, documentId: documentId)

        let withSystem = try await client.documents.listGroupPermissions(
            documentId: documentId, includeSystem: true
        )
        let systemTypes = withSystem.map { $0.groupType }.filter { $0.hasPrefix("_col-") }
        XCTAssertFalse(
            systemTypes.isEmpty,
            "includeSystem: true must return the collection's _col-* group permissions, got \(withSystem.map { $0.groupType })"
        )

        let withoutSystem = try await client.documents.listGroupPermissions(documentId: documentId)
        XCTAssertTrue(
            withoutSystem.allSatisfy { !$0.groupType.hasPrefix("_") },
            "the default must not return system groups"
        )

        // Cleanup
        _ = try await client.collections.removeDocument(collectionId: collectionId, documentId: documentId)
        _ = try await client.collections.delete(collectionId: collectionId)
    }
}
