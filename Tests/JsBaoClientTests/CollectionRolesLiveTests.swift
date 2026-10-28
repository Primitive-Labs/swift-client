import XCTest
@testable import JsBaoClient

/// The collection role table from Swift, against the roles-mode dev server
/// (#4737, project `role-based-groups-collections` phase 3).
///
/// The collection's owner `C` is an ordinary app member who creates it from
/// their own session, never the app owner: the app owner's session holds app
/// authority, which the server admits before it reads the collection role.
/// `V` (viewer), `E` (editor), `M` (manager) and `G` (only in a group) are
/// ordinary members too. The app owner's session is used once, where app
/// authority is the point: naming another user on `resolveRole`.
final class CollectionRolesLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var owner: TestUser!
    var viewer: TestUser!
    var editor: TestUser!
    var ownerClient: JsBaoClient!
    var viewerClient: JsBaoClient!
    var editorClient: JsBaoClient!
    var extraClients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-collection-roles")
        owner = try await ctx.createTestUser(appId: testApp.appId)
        viewer = try await ctx.createTestUser(appId: testApp.appId)
        editor = try await ctx.createTestUser(appId: testApp.appId)
        ownerClient = createTestClient(appId: testApp.appId, token: owner.jwt)
        viewerClient = createTestClient(appId: testApp.appId, token: viewer.jwt)
        editorClient = createTestClient(appId: testApp.appId, token: editor.jwt)
    }

    override func tearDown() async throws {
        await ownerClient?.destroy()
        await viewerClient?.destroy()
        await editorClient?.destroy()
        for client in extraClients { await client.destroy() }
        await ctx.cleanup()
    }

    private func client(_ token: String) -> JsBaoClient {
        let made = createTestClient(appId: testApp.appId, token: token)
        extraClients.append(made)
        return made
    }

    /// A collection `C` creates, with `V` a viewer and `E` an editor.
    private func makeCollection() async throws -> CollectionInfo {
        let created = try await ownerClient.collections.create(
            params: CreateCollectionParams(name: "roles-\(UUID().uuidString.prefix(8))")
        )
        let asViewer = try await ownerClient.collections.addMember(
            collectionId: created.collectionId, params: .user(viewer.userId, role: .viewer)
        )
        guard case let .direct(viewerRow) = asViewer else {
            XCTFail("expected a direct add")
            return created
        }
        XCTAssertEqual(viewerRow.role, .viewer)
        _ = try await ownerClient.collections.addMember(
            collectionId: created.collectionId, params: .user(editor.userId, role: .editor)
        )
        return created
    }

    private func roles(_ collectionId: String) async throws -> [String: CollectionRole] {
        let members = try await ownerClient.collections.listMembers(collectionId: collectionId)
        return Dictionary(uniqueKeysWithValues: members.map { ($0.principal, $0.role) })
    }

    // MARK: - Behavior 24

    func testOwnerGivesRolesAndTheTableDecidesWhoAdds() async throws {
        let collection = try await makeCollection()
        let id = collection.collectionId
        XCTAssertEqual(collection.custodian, "user:\(owner.userId)")
        let listed = try await ownerClient.collections.list()
        XCTAssertEqual(listed.items.first { $0.collectionId == id }?.role, .owner)

        let members = try await roles(id)
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(members[owner.userId], .owner)
        XCTAssertEqual(members[viewer.userId], .viewer)
        XCTAssertEqual(members[editor.userId], .editor)

        let editorDoc = try await ctx.createDocument(appId: testApp.appId, jwt: editor.jwt, title: "Editor Doc")
        let addedDoc = try await editorClient.collections.addDocument(collectionId: id, documentId: editorDoc)
        XCTAssertEqual(addedDoc.documentId, editorDoc)
        let viewerDoc = try await ctx.createDocument(appId: testApp.appId, jwt: viewer.jwt, title: "Viewer Doc")
        let viewerAdd = await httpRefusal(try await viewerClient.collections.addDocument(
            collectionId: id, documentId: viewerDoc
        ))
        XCTAssertEqual(viewerAdd?.status, 403)

        let invitee = try await ctx.createTestUser(appId: testApp.appId)
        for client in [viewerClient!, editorClient!] {
            let invite = await httpRefusal(try await client.collections.addMember(
                collectionId: id, params: .user(invitee.userId, role: .viewer)
            ))
            XCTAssertEqual(invite?.status, 403)
        }
    }

    // MARK: - Behavior 25

    func testGroupMemberRolesAndResolvedSources() async throws {
        let collection = try await makeCollection()
        let id = collection.collectionId
        let grouped = try await ctx.createTestUser(appId: testApp.appId)
        let groupId = try await ctx.createGroup(
            app: testApp, name: "Crew", custodian: "user:\(owner.userId)",
            initialMembers: [(userId: grouped.userId, role: "member")]
        ).groupId

        let added = try await ownerClient.collections.addGroupMember(
            collectionId: id, groupId: groupId, role: .manager
        )
        XCTAssertEqual(added.principal, "group:\(groupId)")
        XCTAssertEqual(added.role, .manager)

        let viaGroup = try await client(grouped.jwt).collections.resolveRole(collectionId: id)
        XCTAssertEqual(viaGroup, ResolvedCollectionRole(role: .manager, source: .group(groupId: groupId)))
        let direct = try await editorClient.collections.resolveRole(collectionId: id)
        XCTAssertEqual(direct, ResolvedCollectionRole(role: .editor, source: .direct))

        let named = await httpRefusal(try await ownerClient.collections.resolveRole(
            collectionId: id, userId: viewer.userId
        ))
        XCTAssertEqual(named?.status, 403)
        XCTAssertEqual(named?.serverCode, "SUBJECT_USER_FORBIDDEN")
        let byAppOwner = try await client(testApp.ownerJWT).collections.resolveRole(
            collectionId: id, userId: viewer.userId
        )
        XCTAssertEqual(byAppOwner, ResolvedCollectionRole(role: .viewer, source: .direct))

        let lowered = try await ownerClient.collections.setMemberRole(
            collectionId: id, principal: "group:\(groupId)", role: .viewer
        )
        XCTAssertEqual(lowered.role, .viewer)
        let afterLowering = try await roles(id)
        XCTAssertEqual(afterLowering["group:\(groupId)"], .viewer)
        let removed = try await ownerClient.collections.removeMember(
            collectionId: id, principal: "group:\(groupId)"
        )
        XCTAssertTrue(removed.success)
        let afterRemoval = try await roles(id)
        XCTAssertNil(afterRemoval["group:\(groupId)"])
    }

    // MARK: - Behavior 26

    func testOwnerCannotLeaveAndTransferMovesCustody() async throws {
        let collection = try await makeCollection()
        let id = collection.collectionId

        let leave = await httpRefusal(try await ownerClient.collections.removeMember(
            collectionId: id, principal: owner.userId
        ))
        XCTAssertEqual(leave?.status, 403)
        XCTAssertEqual(leave?.serverCode, "OWNER_MUST_TRANSFER")
        let selfRemoved = try await viewerClient.collections.removeMember(collectionId: id, principal: viewer.userId)
        XCTAssertTrue(selfRemoved.success)

        let moved = try await ownerClient.collections.transfer(collectionId: id, to: "user:\(editor.userId)")
        XCTAssertEqual(moved.custodian, "user:\(editor.userId)")
        let members = try await roles(id)
        XCTAssertEqual(members[editor.userId], .owner)
        XCTAssertEqual(members[owner.userId], .manager)
        XCTAssertNil(members[viewer.userId])

        let deleted = await httpRefusal(try await ownerClient.collections.delete(collectionId: id))
        XCTAssertEqual(deleted?.status, 403)
    }

    // MARK: - E8

    func testGroupMemberRefusals() async throws {
        let collection = try await makeCollection()
        let id = collection.collectionId
        let groupId = try await ctx.createGroup(app: testApp, name: "Crew", custodian: "user:\(owner.userId)").groupId

        let asOwner = await httpRefusal(try await ownerClient.collections.addGroupMember(
            collectionId: id, groupId: groupId, role: .owner
        ))
        XCTAssertEqual(asOwner?.status, 400)

        // A collection manager who is not in the group may not add it.
        let manager = try await ctx.createTestUser(appId: testApp.appId)
        _ = try await ownerClient.collections.addMember(collectionId: id, params: .user(manager.userId, role: .manager))
        let outsider = await httpRefusal(try await client(manager.jwt).collections.addGroupMember(
            collectionId: id, groupId: groupId, role: .viewer
        ))
        XCTAssertEqual(outsider?.status, 403)
    }

    // MARK: - E9

    func testTransferRefusals() async throws {
        let collection = try await makeCollection()
        let id = collection.collectionId

        let toApp = await httpRefusal(try await ownerClient.collections.transfer(collectionId: id, to: "app"))
        XCTAssertEqual(toApp?.status, 403)
        XCTAssertEqual(toApp?.serverCode, "CUSTODIAN_NOT_ALLOWED")
        let unchanged = await httpRefusal(try await ownerClient.collections.transfer(
            collectionId: id, to: "user:\(owner.userId)"
        ))
        XCTAssertEqual(unchanged?.status, 400)
        XCTAssertEqual(unchanged?.serverCode, "CUSTODIAN_UNCHANGED")
    }

    // MARK: - E11

    /// `getAccess` and the typed `revokeGroupPermission` are deprecated and
    /// still answer for a group given a role through `addGroupMember`.
    @available(*, deprecated)
    func testDeprecatedAccessCallsStillAnswer() async throws {
        let collection = try await makeCollection()
        let id = collection.collectionId
        let groupId = try await ctx.createGroup(app: testApp, name: "Crew", custodian: "user:\(owner.userId)").groupId
        _ = try await ownerClient.collections.addGroupMember(collectionId: id, groupId: groupId, role: .viewer)

        let access = try await ownerClient.collections.getAccess(collectionId: id)
        let grant = try XCTUnwrap(access.groups.first { $0.groupId == groupId })
        XCTAssertEqual(grant.role, .viewer)
        XCTAssertEqual(grant.permission, "reader")
        XCTAssertEqual(access.members.first { $0.userId == editor.userId }?.role, .editor)

        let revoked = try await ownerClient.collections.revokeGroupPermission(
            collectionId: id, groupType: grant.groupType, groupId: groupId
        )
        XCTAssertTrue(revoked.success)
        let afterRevoke = try await roles(id)
        XCTAssertNil(afterRevoke["group:\(groupId)"])
    }
}
