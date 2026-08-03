import XCTest
@testable import JsBaoClient

/// Path-encoding tests for `client.groups` (#2042).
///
/// `HttpClient.buildURLRequest` assembles the request path from segments the
/// caller supplies, so every free-text path parameter must be pre-encoded with
/// `.urlPathAllowed` (the convention used across every sub-API). These tests
/// pin that the older `GroupsAPI` methods percent-encode `groupType` /
/// `groupId` / `userId` before interpolating them into the path, so a
/// URL-reserved character in one of those values can't produce a malformed
/// path. `GroupsAPI` takes an injected `makeRequest` closure, which lets us
/// capture the path each method builds without a live server.
final class GroupsAPIPathEncodingTests: XCTestCase {

    /// Builds a `GroupsAPI` whose `makeRequest` records the path it is handed
    /// and returns a canned `{ success: true }` body (enough to decode
    /// `SuccessResult`).
    private func makeGroups(record: @escaping (String) -> Void) -> GroupsAPI {
        GroupsAPI { _, path, _ in
            record(path)
            return ["success": true]
        }
    }

    // A group type carrying URL-reserved characters (space and `#`). These are
    // not in `.urlPathAllowed`, so a correct implementation escapes them to
    // `%20` and `%23`.
    private let reservedType = "team space#1"
    private let reservedTypeEncoded = "team%20space%231"

    func test_delete_percentEncodesGroupTypeAndId() async throws {
        var captured: String?
        let groups = makeGroups { captured = $0 }
        _ = try await groups.delete(groupType: reservedType, groupId: "b#2")
        XCTAssertEqual(captured, "/groups/\(reservedTypeEncoded)/b%232")
    }

    func test_removeMember_percentEncodesUserIdSegment() async throws {
        var captured: String?
        let groups = makeGroups { captured = $0 }
        _ = try await groups.removeMember(
            groupType: "org", groupId: "01ARZ3NDEKTSV4RRFFQ69G5FAV", userId: "user id#7"
        )
        XCTAssertEqual(
            captured,
            "/groups/org/01ARZ3NDEKTSV4RRFFQ69G5FAV/members/user%20id%237"
        )
    }

    func test_slugAndUlid_passThroughUnchanged() async throws {
        // The common case: a slug type + ULID id carry no reserved characters,
        // so encoding is a no-op and the path is byte-for-byte the raw form.
        var captured: String?
        let groups = makeGroups { captured = $0 }
        _ = try await groups.delete(
            groupType: "editors", groupId: "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        )
        XCTAssertEqual(captured, "/groups/editors/01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }
}
