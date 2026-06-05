import XCTest
@testable import JsBaoClient
import YSwift

final class GroupsTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-groups")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Create Group

    func testCreateGroup() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let groupId = "test-group-\(UUID().uuidString.prefix(8))"
        let result = try await client.groups.create(params: CreateGroupParams(
            groupType: "team",
            groupId: groupId,
            name: "Swift Test Group"
        ))

        XCTAssertEqual(result.groupId, groupId, "Created group should echo back its id")
        XCTAssertEqual(result.name, "Swift Test Group")
    }

    // MARK: - Add/Remove Member

    func testAddRemoveMember() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Create a group
        let groupId = "member-group-\(UUID().uuidString.prefix(8))"
        let _ = try await client.groups.create(params: CreateGroupParams(
            groupType: "team",
            groupId: groupId,
            name: "Member Test Group"
        ))

        // Create a second user to add
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        // Add member
        let addResult = try await client.groups.addMember(
            groupType: "team",
            groupId: groupId,
            params: .userId(user2.userId)
        )
        XCTAssertFalse(addResult.status.isEmpty, "Expected a status from addMember")

        // List members to verify
        let membersResult = try await client.groups.listMembers(groupType: "team", groupId: groupId)
        let hasMember = membersResult.items.contains { member in
            member.userId == user2.userId
        }
        XCTAssertTrue(hasMember, "Added user should appear in member list")

        // Remove member
        let removeResult = try await client.groups.removeMember(
            groupType: "team",
            groupId: groupId,
            userId: user2.userId
        )
        XCTAssertTrue(removeResult.success, "Expected success from removeMember")
    }
}
