import XCTest
@testable import JsBaoClient

/// Wire-shape and decode tests for the `listMembers(include:)` parity change
/// (issue #1585 — mirrors the JS client's `include?: "profiles"` option added
/// in #1434). These don't hit the network: a stub `Transport` records the
/// request path and returns a canned envelope, so we can assert the
/// query-param serialization and that `GroupMemberInfo.avatarUrl` decodes.
final class GroupsListMembersIncludeTests: XCTestCase {

    /// An empty page — enough for the tests that only assert the request.
    private func emptyPage() -> RecordingTransport {
        RecordingTransport(json: #"{"items":[]}"#)
    }

    // MARK: - Query-param serialization

    func test_listMembers_includeProfiles_serializesQueryParam() async throws {
        let transport = emptyPage()
        let api = GroupsAPI(transport: transport)
        _ = try await api.listMembers(groupType: "team", groupId: "eng", include: .profiles)
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/groups/team/eng/members?include=profiles")
    }

    func test_listMembers_limitAndInclude_serializesBoth() async throws {
        let transport = emptyPage()
        let api = GroupsAPI(transport: transport)
        _ = try await api.listMembers(
            groupType: "team",
            groupId: "eng",
            options: PaginationOptions(limit: 25),
            include: .profiles
        )
        XCTAssertEqual(transport.lastCall?.path, "/groups/team/eng/members?limit=25&include=profiles")
    }

    func test_listMembers_noInclude_omitsQueryParam() async throws {
        let transport = emptyPage()
        let api = GroupsAPI(transport: transport)
        _ = try await api.listMembers(groupType: "team", groupId: "eng")
        XCTAssertEqual(transport.lastCall?.path, "/groups/team/eng/members")
        XCTAssertFalse(transport.lastCall?.path.contains("include") ?? true)
    }

    // MARK: - avatarUrl decoding

    func test_listMembers_decodesPopulatedAvatarUrl() async throws {
        let transport = RecordingTransport(json: """
        {"items":[{"userId":"u1","addedBy":"owner","userName":"Alice",
                   "userEmail":"a@example.com",
                   "avatarUrl":"https://example.com/a.png"}]}
        """)
        let api = GroupsAPI(transport: transport)
        let result = try await api.listMembers(groupType: "team", groupId: "eng", include: .profiles)
        XCTAssertEqual(result.items.first?.avatarUrl, "https://example.com/a.png")
    }

    func test_listMembers_decodesNullAvatarUrl() async throws {
        let transport = RecordingTransport(json: """
        {"items":[{"userId":"u1","addedBy":"owner","userName":"Bob",
                   "userEmail":"b@example.com","avatarUrl":null}]}
        """)
        let api = GroupsAPI(transport: transport)
        let result = try await api.listMembers(groupType: "team", groupId: "eng", include: .profiles)
        XCTAssertNil(result.items.first?.avatarUrl)
    }

    func test_listMembers_decodesAbsentAvatarUrl() async throws {
        // The default (no-`include`) response omits avatarUrl entirely.
        let transport = RecordingTransport(json: #"{"items":[{"userId":"u1","addedBy":"owner"}]}"#)
        let api = GroupsAPI(transport: transport)
        let result = try await api.listMembers(groupType: "team", groupId: "eng")
        XCTAssertNil(result.items.first?.avatarUrl)
        XCTAssertEqual(result.items.first?.userId, "u1")
    }
}
