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

    func testCreateGroupWithoutGroupIdGetsServerAssignedId() async throws {
        // Issue #1353 — `groupId` is optional; the server assigns a ULID.
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let result = try await client.groups.create(params: CreateGroupParams(
            groupType: "team",
            name: "Swift Auto-ID Group"
        ))

        XCTAssertEqual(result.name, "Swift Auto-ID Group")
        // ULID: 26 chars, Crockford base32.
        XCTAssertEqual(result.groupId.count, 26, "Server-assigned groupId should be a ULID")

        // The group is fetchable via the returned ID.
        let fetched = try await client.groups.get(groupType: "team", groupId: result.groupId)
        XCTAssertEqual(fetched.groupId, result.groupId)
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

    // MARK: - Member Pagination

    /// Issue #2075 — paginate a group's members past page 1 against the live
    /// server.
    ///
    /// The server's member cursor is raw JSON (`encodeListCursor` returns
    /// `JSON.stringify(lastEvaluatedKey)`), so it carries `{`, `}`, `"`, `#`
    /// and `[`/`]`. `listMembers` used to interpolate it into the query string
    /// verbatim, and `URLComponents.percentEncodedQuery` traps on those
    /// characters — a process-killing `fatalError`, not a catchable
    /// `HttpError`. #2076 routed the cursor through the shared `URLQuery`
    /// builder; this test is the live regression guard that page 2 actually
    /// loads.
    func testListMembersPaginatesPastFirstPage() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let groupId = "page-group-\(UUID().uuidString.prefix(8))"
        _ = try await client.groups.create(params: CreateGroupParams(
            groupType: "team",
            groupId: groupId,
            name: "Pagination Test Group"
        ))

        // Two members, so a page size of 1 leaves a genuine second page:
        // the app owner plus one freshly created user.
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        _ = try await client.groups.addMember(
            groupType: "team",
            groupId: groupId,
            params: .userId(testApp.ownerUserId)
        )
        _ = try await client.groups.addMember(
            groupType: "team",
            groupId: groupId,
            params: .userId(user2.userId)
        )

        let allMembers = try await client.groups.listMembers(groupType: "team", groupId: groupId)
        XCTAssertEqual(allMembers.items.count, 2, "Group should have two members before paginating")

        let page1 = try await client.groups.listMembers(
            groupType: "team",
            groupId: groupId,
            options: PaginationOptions(limit: 1)
        )
        XCTAssertEqual(page1.items.count, 1, "limit: 1 should return exactly one member")
        XCTAssertTrue(page1.hasMore, "Page 1 of a two-member group should report more pages")

        // Without a cursor the page-2 fetch below would pass vacuously, so
        // require one explicitly.
        let cursor = try XCTUnwrap(
            page1.nextCursor,
            "Page 1 must return a nextCursor — otherwise this test never exercises page 2"
        )
        // The cursor is raw JSON: exactly the shape that made the old
        // unescaped interpolation trap in Foundation.
        XCTAssertTrue(
            cursor.contains("{") && cursor.contains("\""),
            "Expected a raw-JSON cursor carrying query-illegal characters, got: \(cursor)"
        )

        let page2 = try await client.groups.listMembers(
            groupType: "team",
            groupId: groupId,
            options: PaginationOptions(limit: 1, cursor: cursor)
        )
        XCTAssertEqual(page2.items.count, 1, "Page 2 should return the remaining member")

        let firstId = try XCTUnwrap(page1.items.first?.userId)
        let secondId = try XCTUnwrap(page2.items.first?.userId)
        XCTAssertNotEqual(firstId, secondId, "Page 2 must return a different member than page 1")
        XCTAssertEqual(
            Set([firstId, secondId]),
            Set(allMembers.items.map(\.userId)),
            "The two pages together should cover the full member list"
        )
    }
}
