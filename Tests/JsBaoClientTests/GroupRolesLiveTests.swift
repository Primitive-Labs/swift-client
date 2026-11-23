import XCTest
@testable import JsBaoClient

/// The group role table from Swift, against the roles-mode dev server (#4737,
/// project `role-based-groups-collections` phase 3).
///
/// The group's owner is an ordinary app member `G`, never the app owner: the
/// app owner's session holds app authority, which the server admits before it
/// reads the group role, so a refusal from that session would never come. The
/// group is created through the admin API with `custodian: user:<G>`, and
/// every "owner" call below is `G`'s session. `M` and `N` are ordinary members
/// too.
final class GroupRolesLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var owner: TestUser!
    var manager: TestUser!
    var member: TestUser!
    var ownerClient: JsBaoClient!
    var managerClient: JsBaoClient!
    var memberClient: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-group-roles")
        owner = try await ctx.createTestUser(appId: testApp.appId)
        manager = try await ctx.createTestUser(appId: testApp.appId)
        member = try await ctx.createTestUser(appId: testApp.appId)
        ownerClient = createTestClient(appId: testApp.appId, token: owner.jwt)
        managerClient = createTestClient(appId: testApp.appId, token: manager.jwt)
        memberClient = createTestClient(appId: testApp.appId, token: member.jwt)
    }

    override func tearDown() async throws {
        await ownerClient?.destroy()
        await managerClient?.destroy()
        await memberClient?.destroy()
        await ctx.cleanup()
    }

    /// A group held by `G`, created through the admin API.
    private func makeGroup() async throws -> String {
        try await ctx.createGroup(
            app: testApp, name: "Role Group", custodian: "user:\(owner.userId)"
        ).groupId
    }

    /// `G` adds `M` as a manager and `N` as a member.
    private func addManagerAndMember(_ groupId: String) async throws {
        let asManager = try await ownerClient.groups.addMember(
            groupId: groupId, params: .userId(manager.userId, role: .manager)
        )
        guard case let .direct(managerRow) = asManager else { return XCTFail("expected a direct add") }
        XCTAssertEqual(managerRow.role, .manager)
        let asMember = try await ownerClient.groups.addMember(
            groupId: groupId, params: .userId(member.userId, role: .member)
        )
        guard case let .direct(memberRow) = asMember else { return XCTFail("expected a direct add") }
        XCTAssertEqual(memberRow.role, .member)
    }

    private func roles(_ groupId: String, from client: JsBaoClient) async throws -> [String: String?] {
        let page = try await client.groups.listMembers(groupId: groupId)
        return Dictionary(uniqueKeysWithValues: page.items.map { ($0.userId, $0.role) })
    }

    // MARK: - Behavior 10

    func testAdminCreatedGroupIsHeldByItsOrdinaryMemberOwner() async throws {
        let groupId = try await makeGroup()

        let group = try await ownerClient.groups.get(groupId: groupId)
        XCTAssertEqual(group.custodian, "user:\(owner.userId)")
        XCTAssertEqual(group.settings?.memberList, .members)

        let members = try await roles(groupId, from: ownerClient)
        XCTAssertEqual(members[owner.userId], "owner")
    }

    // MARK: - Behavior 11

    func testRolesDecideWhoEditsAndDeletes() async throws {
        let groupId = try await makeGroup()
        try await addManagerAndMember(groupId)

        let demoted = try await ownerClient.groups.setMemberRole(
            groupId: groupId, userId: manager.userId, role: .member
        )
        XCTAssertEqual(demoted.userId, manager.userId)
        XCTAssertEqual(demoted.role, .member)
        let restored = try await ownerClient.groups.setMemberRole(
            groupId: groupId, userId: manager.userId, role: .manager
        )
        XCTAssertEqual(restored.role, .manager)

        let memberEdit = await httpRefusal(try await memberClient.groups.update(
            groupId: groupId, params: UpdateGroupParams(name: "Member Edit")
        ))
        XCTAssertEqual(memberEdit?.status, 403)
        let memberDelete = await httpRefusal(try await memberClient.groups.delete(groupId: groupId))
        XCTAssertEqual(memberDelete?.status, 403)

        let managerEdit = try await managerClient.groups.update(
            groupId: groupId, params: UpdateGroupParams(name: "Manager Edit")
        )
        XCTAssertEqual(managerEdit.name, "Manager Edit")
    }

    // MARK: - Behavior 12

    func testTransferMovesCustodyAndLeavesTheOldOwnerAManager() async throws {
        let groupId = try await makeGroup()
        try await addManagerAndMember(groupId)

        let moved = try await ownerClient.groups.transfer(groupId: groupId, to: "user:\(manager.userId)")
        XCTAssertEqual(moved.custodian, "user:\(manager.userId)")

        let members = try await roles(groupId, from: ownerClient)
        XCTAssertEqual(members[manager.userId], "owner")
        XCTAssertEqual(members[owner.userId], "manager")

        let edited = try await ownerClient.groups.update(
            groupId: groupId, params: UpdateGroupParams(name: "Former Owner Edit")
        )
        XCTAssertEqual(edited.name, "Former Owner Edit")
        let deleted = await httpRefusal(try await ownerClient.groups.delete(groupId: groupId))
        XCTAssertEqual(deleted?.status, 403)
    }

    // MARK: - Behavior 13

    func testMemberListManagersHidesTheRosterFromAMember() async throws {
        let groupId = try await makeGroup()
        try await addManagerAndMember(groupId)

        let hidden = try await ownerClient.groups.update(
            groupId: groupId, params: UpdateGroupParams(settings: ResourceSettings(memberList: .managers))
        )
        XCTAssertEqual(hidden.settings?.memberList, .managers)
        let refused = await httpRefusal(try await memberClient.groups.listMembers(groupId: groupId))
        XCTAssertEqual(refused?.status, 403)
        let managerView = try await roles(groupId, from: managerClient)
        XCTAssertEqual(managerView[member.userId], "member")

        _ = try await ownerClient.groups.update(
            groupId: groupId, params: UpdateGroupParams(settings: ResourceSettings(memberList: .members))
        )
        let memberView = try await roles(groupId, from: memberClient)
        XCTAssertEqual(memberView[owner.userId], "owner")
    }

    // MARK: - Behavior 14

    /// `groups.create` is deprecated with the server refusing every session's
    /// create, so this is a deprecated test method.
    @available(*, deprecated)
    func testOwnerCannotLeaveAndNoSessionCreatesAGroup() async throws {
        let groupId = try await makeGroup()

        let leave = await httpRefusal(try await ownerClient.groups.removeMember(
            groupId: groupId, userId: owner.userId
        ))
        XCTAssertEqual(leave?.status, 403)
        XCTAssertEqual(leave?.serverCode, "OWNER_MUST_TRANSFER")

        let appOwnerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwnerClient.destroy() } }
        for client in [ownerClient!, appOwnerClient] {
            let create = await httpRefusal(try await client.groups.create(params: CreateGroupParams(
                groupType: "group", name: "Session Group"
            )))
            XCTAssertEqual(create?.status, 403)
            XCTAssertEqual(create?.serverCode, "FUNCTION_ROUTE_FUNCTION_ONLY")
        }
    }

    // MARK: - Behavior 15

    /// The typed alias still answers a group stored as type `group`.
    @available(*, deprecated)
    func testTypedAliasStillAnswersTheGroup() async throws {
        let groupId = try await makeGroup()
        let viaAlias = try await ownerClient.groups.get(groupType: "team", groupId: groupId)
        XCTAssertEqual(viaAlias.groupId, groupId)
        XCTAssertEqual(viaAlias.custodian, "user:\(owner.userId)")
    }

    // MARK: - E10

    func testOwnerSessionCannotChangeTheOwnerRow() async throws {
        let groupId = try await makeGroup()
        let refused = await httpRefusal(try await ownerClient.groups.setMemberRole(
            groupId: groupId, userId: owner.userId, role: .member
        ))
        XCTAssertEqual(refused?.status, 403)
        XCTAssertEqual(refused?.serverCode, "OWNER_ROW_PROTECTED")
    }
}
