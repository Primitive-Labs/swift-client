import Foundation
import XCTest
@testable import JsBaoClient

/// Wire-parity tests for #2076: the sub-APIs build request paths and query
/// strings by routing every value through `URLEncoding` / `URLQuery` instead of
/// hand-escaping with `.urlQueryAllowed` / `.urlPathAllowed`.
///
/// Each sub-API takes an injected `Transport`, so we capture the exact path
/// each method hands to it without a live server. The stub returns an empty
/// JSON object and the call is wrapped in `try?` — the path is recorded before
/// the method decodes, so a decode failure does not hide the assertion.
///
/// Two guarantees are pinned:
///  * safe values (slugs, ULIDs, alphanumeric cursors) stay byte-identical, so
///    the change is a no-op for every input that works today;
///  * reserved characters that the old charsets let through (`+ @ /` space …)
///    are now percent-encoded, matching the JS client's `URLSearchParams`.
final class URLConstructionParityTests: XCTestCase {

    /// Records the path the sub-API asks the transport for and replies with an
    /// empty JSON object. Callers use `try?` so a decode mismatch on the empty
    /// body doesn't mask the captured path.
    private final class PathRecorder: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var lastPath: String?

        var path: String? { lock.withLock { lastPath } }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            lock.withLock { lastPath = path }
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
    }

    // MARK: - UsersAPI.lookup — the live wrong-user bug

    /// A plus-addressed email must reach the wire percent-encoded. The old
    /// `.urlQueryAllowed` left `+` and `@` literal, so `?email=a+b@x.com`
    /// decoded to `a b@x.com` server-side and resolved the wrong user.
    func test_usersLookup_plusAddressedEmail_isEncoded() async throws {
        let recorder = PathRecorder()
        let users = UsersAPI(transport: recorder)
        _ = try? await users.lookup(email: "a+b@x.com")
        XCTAssertEqual(recorder.path, "/users/lookup?email=a%2Bb%40x.com")
    }

    /// An ordinary email now encodes `@` to `%40` (JS `URLSearchParams` parity);
    /// the server decodes it back to the same address.
    func test_usersLookup_ordinaryEmail_matchesEncodeURIComponent() async throws {
        let recorder = PathRecorder()
        let users = UsersAPI(transport: recorder)
        _ = try? await users.lookup(email: "user@example.com")
        XCTAssertEqual(recorder.path, "/users/lookup?email=user%40example.com")
    }

    // MARK: - GroupsAPI.list — byte-identical + boolean convention preserved

    /// A slug type filter and the `includeSystem=true`-only-when-true boolean
    /// convention are preserved byte-for-byte.
    func test_groupsList_slugAndBoolean_areByteIdentical() async throws {
        let recorder = PathRecorder()
        let groups = GroupsAPI(transport: recorder)
        _ = try? await groups.list(options: ListGroupsOptions(
            type: "editors", limit: 25, cursor: "abc123", includeSystem: true
        ))
        XCTAssertEqual(recorder.path, "/groups?type=editors&limit=25&cursor=abc123&includeSystem=true")
    }

    /// `includeSystem` defaulting to nil/false appends nothing (unchanged).
    func test_groupsList_includeSystemFalse_isOmitted() async throws {
        let recorder = PathRecorder()
        let groups = GroupsAPI(transport: recorder)
        _ = try? await groups.list(options: ListGroupsOptions(type: "editors"))
        XCTAssertEqual(recorder.path, "/groups?type=editors")
    }

    // MARK: - GroupsAPI.listMembers — #2075 (cursor was not escaped at all)

    /// The cursor is now percent-encoded. Before the fix `listMembers`
    /// interpolated it raw (`cursor=\(cursor)`), so a cursor containing a `+`
    /// or space produced a malformed query on page 2.
    func test_groupsListMembers_cursor_isEncoded() async throws {
        let recorder = PathRecorder()
        let groups = GroupsAPI(transport: recorder)
        _ = try? await groups.listMembers(
            groupType: "editors",
            groupId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            options: PaginationOptions(limit: 50, cursor: "a+b c")
        )
        XCTAssertEqual(
            recorder.path,
            "/groups/editors/01ARZ3NDEKTSV4RRFFQ69G5FAV/members?limit=50&cursor=a%2Bb%20c"
        )
    }

    /// A plain cursor stays byte-identical.
    func test_groupsListMembers_plainCursor_isByteIdentical() async throws {
        let recorder = PathRecorder()
        let groups = GroupsAPI(transport: recorder)
        _ = try? await groups.listMembers(
            groupType: "editors",
            groupId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            options: PaginationOptions(cursor: "eyJrIjoxfQ")
        )
        XCTAssertEqual(
            recorder.path,
            "/groups/editors/01ARZ3NDEKTSV4RRFFQ69G5FAV/members?cursor=eyJrIjoxfQ"
        )
    }

    // MARK: - GroupsAPI.removeMemberByEmail — plus email in the query

    func test_groupsRemoveMemberByEmail_plusEmail_isEncoded() async throws {
        let recorder = PathRecorder()
        let groups = GroupsAPI(transport: recorder)
        _ = try? await groups.removeMemberByEmail(
            groupType: "editors", groupId: "01ARZ3NDEKTSV4RRFFQ69G5FAV", email: "a+b@x.com"
        )
        XCTAssertEqual(
            recorder.path,
            "/groups/editors/01ARZ3NDEKTSV4RRFFQ69G5FAV/members?email=a%2Bb%40x.com"
        )
    }

    // MARK: - GroupsAPI path segment — `/` in a value is now escaped

    /// A value containing `/` is now escaped to `%2F` (the old `.urlPathAllowed`
    /// left it literal, letting a value split into extra path segments).
    func test_groupsDelete_slashInValue_isEscaped() async throws {
        let recorder = PathRecorder()
        let groups = GroupsAPI(transport: recorder)
        _ = try? await groups.delete(groupType: "a/b", groupId: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertEqual(recorder.path, "/groups/a%2Fb/01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }

    // MARK: - CollectionsAPI.list — shared queryString helper

    func test_collectionsList_cursor_isEncoded() async throws {
        let recorder = PathRecorder()
        let collections = CollectionsAPI(transport: recorder)
        _ = try? await collections.list(options: PaginationOptions(limit: 10, cursor: "a+b"))
        XCTAssertEqual(recorder.path, "/collections?limit=10&cursor=a%2Bb")
    }

    // MARK: - InvitationsAPI.listDeferredGrants — email filter

    func test_invitationsListDeferredGrants_email_isEncoded() async throws {
        let recorder = PathRecorder()
        let invitations = InvitationsAPI(transport: recorder)
        _ = try? await invitations.listDeferredGrants(email: "a+b@x.com")
        XCTAssertEqual(recorder.path, "/deferred-grants?email=a%2Bb%40x.com")
    }

    // MARK: - RuleSetsAPI.list — resourceType filter

    func test_ruleSetsList_resourceType_isEncoded() async throws {
        let recorder = PathRecorder()
        let ruleSets = RuleSetsAPI(transport: recorder)
        _ = try? await ruleSets.list(options: ListRuleSetsOptions(resourceType: "a b/c"))
        XCTAssertEqual(recorder.path, "/rule-sets?resourceType=a%20b%2Fc")
    }

    /// A plain resourceType slug stays byte-identical.
    func test_ruleSetsList_slug_isByteIdentical() async throws {
        let recorder = PathRecorder()
        let ruleSets = RuleSetsAPI(transport: recorder)
        _ = try? await ruleSets.list(options: ListRuleSetsOptions(resourceType: "document"))
        XCTAssertEqual(recorder.path, "/rule-sets?resourceType=document")
    }

    // MARK: - JsBaoClient.openDocumentByAlias — path segment

    /// A `/` in the alias is escaped so it can't split into extra path
    /// segments; the old `.urlPathAllowed` charset left it literal.
    func test_aliasResolvePath_slashInAlias_isEscaped() {
        XCTAssertEqual(
            JsBaoClient.aliasResolvePath(alias: "team/docs"),
            "/document-aliases/team%2Fdocs/resolve"
        )
    }

    /// A plain alias slug stays byte-identical.
    func test_aliasResolvePath_slug_isByteIdentical() {
        XCTAssertEqual(
            JsBaoClient.aliasResolvePath(alias: "my-doc"),
            "/document-aliases/my-doc/resolve"
        )
    }

    // MARK: - JsBaoClient.syncMetadata — query

    /// No options → bare `/documents`, no trailing `?`.
    func test_syncMetadataPath_noOptions_isBare() {
        XCTAssertEqual(
            JsBaoClient.syncMetadataPath(documentId: nil, payloadType: nil),
            "/documents"
        )
    }

    /// `payloadType` was previously appended unescaped; both values now route
    /// through `URLQuery`. Order preserved (documentId, payloadType).
    func test_syncMetadataPath_bothValues_areEncoded() {
        XCTAssertEqual(
            JsBaoClient.syncMetadataPath(documentId: "a+b", payloadType: "full/ids"),
            "/documents?documentId=a%2Bb&payloadType=full%2Fids"
        )
    }

    /// Plain values stay byte-identical.
    func test_syncMetadataPath_plainValues_areByteIdentical() {
        XCTAssertEqual(
            JsBaoClient.syncMetadataPath(documentId: "01ARZ3NDEKTSV4RRFFQ69G5FAV", payloadType: "full"),
            "/documents?documentId=01ARZ3NDEKTSV4RRFFQ69G5FAV&payloadType=full"
        )
    }
}
