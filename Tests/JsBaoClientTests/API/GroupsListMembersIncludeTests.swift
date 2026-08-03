import XCTest
@testable import JsBaoClient

/// Wire-shape and decode tests for the `listMembers(include:)` parity change
/// (issue #1585 — mirrors the JS client's `include?: "profiles"` option added
/// in #1434). These don't hit the network: a stub `makeRequest` closure
/// records the request path and returns a canned envelope, so we can assert
/// the query-param serialization and that `GroupMemberInfo.avatarUrl` decodes.
final class GroupsListMembersIncludeTests: XCTestCase {

    /// Records the most recent request and returns a canned response.
    final class CallRecorder: @unchecked Sendable {
        var method: String?
        var path: String?
        var response: Any = ["items": [Any]()]

        func make(_ method: String, _ path: String, _ data: Any?) async throws -> Any {
            self.method = method
            self.path = path
            return response
        }
    }

    // MARK: - Query-param serialization

    func test_listMembers_includeProfiles_serializesQueryParam() async throws {
        let r = CallRecorder()
        let api = GroupsAPI(makeRequest: r.make)
        _ = try await api.listMembers(groupType: "team", groupId: "eng", include: .profiles)
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/groups/team/eng/members?include=profiles")
    }

    func test_listMembers_limitAndInclude_serializesBoth() async throws {
        let r = CallRecorder()
        let api = GroupsAPI(makeRequest: r.make)
        _ = try await api.listMembers(
            groupType: "team",
            groupId: "eng",
            options: PaginationOptions(limit: 25),
            include: .profiles
        )
        XCTAssertEqual(r.path, "/groups/team/eng/members?limit=25&include=profiles")
    }

    func test_listMembers_noInclude_omitsQueryParam() async throws {
        let r = CallRecorder()
        let api = GroupsAPI(makeRequest: r.make)
        _ = try await api.listMembers(groupType: "team", groupId: "eng")
        XCTAssertEqual(r.path, "/groups/team/eng/members")
        XCTAssertFalse(r.path?.contains("include") ?? true)
    }

    // MARK: - avatarUrl decoding

    func test_listMembers_decodesPopulatedAvatarUrl() async throws {
        let r = CallRecorder()
        r.response = ["items": [[
            "userId": "u1", "addedBy": "owner",
            "userName": "Alice", "userEmail": "a@example.com",
            "avatarUrl": "https://example.com/a.png",
        ]]]
        let api = GroupsAPI(makeRequest: r.make)
        let result = try await api.listMembers(groupType: "team", groupId: "eng", include: .profiles)
        XCTAssertEqual(result.items.first?.avatarUrl, "https://example.com/a.png")
    }

    func test_listMembers_decodesNullAvatarUrl() async throws {
        let r = CallRecorder()
        r.response = ["items": [[
            "userId": "u1", "addedBy": "owner",
            "userName": "Bob", "userEmail": "b@example.com",
            "avatarUrl": NSNull(),
        ]]]
        let api = GroupsAPI(makeRequest: r.make)
        let result = try await api.listMembers(groupType: "team", groupId: "eng", include: .profiles)
        XCTAssertNil(result.items.first?.avatarUrl)
    }

    func test_listMembers_decodesAbsentAvatarUrl() async throws {
        // The default (no-`include`) response omits avatarUrl entirely.
        let r = CallRecorder()
        r.response = ["items": [[
            "userId": "u1", "addedBy": "owner",
        ]]]
        let api = GroupsAPI(makeRequest: r.make)
        let result = try await api.listMembers(groupType: "team", groupId: "eng")
        XCTAssertNil(result.items.first?.avatarUrl)
        XCTAssertEqual(result.items.first?.userId, "u1")
    }
}
