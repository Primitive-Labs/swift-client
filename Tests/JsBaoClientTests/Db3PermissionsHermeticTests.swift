import XCTest
@testable import JsBaoClient

/// #4943 behavior 1 and edge cases E1, E2, E3 and E9 — `client.db3.permissions(id)`
/// sends what `client.documents` sends, to the db3 mounts.
///
/// Over two recording transports, each of the fourteen calls and its
/// documents twin agree on method, path (`/documents/` → `/db3/`), query and
/// body; ids holding `/` or `?` are encoded once; an empty target throws
/// before any request; `listGroups` filters nothing client-side.
final class Db3PermissionsHermeticTests: XCTestCase {

    private static let entry = #"{"userId":"u1","email":"u1@x.test","permission":"reader","grantedAt":"2026-01-01"}"#
    private static let group = #"{"documentId":"D1","groupType":"team","groupId":"g1","permission":"reader","grantedAt":"t","grantedBy":"o"}"#
    private static let request = #"{"requestId":"r1","documentId":"D1","requesterId":"u2","status":"pending","requestedPermission":"reader","createdAt":"t"}"#

    /// A transport answering each route with a body its call decodes.
    private func transport(systemGroup: Bool = false) -> RecordingTransport {
        RecordingTransport(responder: { call in
            let path = call.path
            let json: String
            if path.contains("/pending-invitations") {
                json = #"{"items":[{"email":"a@x.test","permission":"reader","invitationId":"i1","createdAt":"t","expiresAt":"t"}]}"#
            } else if path.contains("/group-permissions") {
                if call.method == .get {
                    let system = #"{"documentId":"D1","groupType":"_app","groupId":"members","permission":"reader","grantedAt":"t","grantedBy":"o"}"#
                    json = systemGroup ? "[\(Self.group),\(system)]" : "[\(Self.group)]"
                } else if call.method == .post {
                    json = Self.group
                } else {
                    json = #"{"success":true}"#
                }
            } else if path.contains("/link-access") {
                json = #"{"documentId":"D1","linkAccess":"reader"}"#
            } else if path.contains("/access-requests") {
                if call.method == .get {
                    json = "[\(Self.request)]"
                } else if path.hasSuffix("/approve") || path.hasSuffix("/deny") {
                    json = #"{"success":true,"message":"ok","request":\#(Self.request)}"#
                } else {
                    json = #"{"success":true,"message":"ok","request":\#(Self.request)}"#
                }
            } else if path.contains("/permissions") {
                if call.method == .get {
                    json = "[\(Self.entry)]"
                } else if call.method == .put {
                    json = #"{"success":true,"message":"ok"}"#
                } else {
                    json = "{}"
                }
            } else {
                json = "{}"
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
    }

    private func documents(_ transport: RecordingTransport) -> DocumentsAPI {
        DocumentsAPI(transport: transport, blobManager: BlobManager(logger: createLogger(level: .error, scope: "test")))
    }

    private func db3(_ transport: RecordingTransport, _ db3Id: String = "D1") -> Db3PermissionsAPI {
        Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport).permissions(db3Id)
    }

    // MARK: - Behavior 1

    func testEachCallIsTheDocumentsCallOnTheDb3Mount() async throws {
        let ours = transport()
        let theirs = transport()
        let sharing = db3(ours)
        let docs = documents(theirs)

        _ = try await sharing.list()
        _ = try await docs.getPermissions(documentId: "D1")
        _ = try await sharing.set(.user("u1", permission: "reader"))
        _ = try await docs.updatePermissions(documentId: "D1", params: .user("u1", permission: "reader"))
        _ = try await sharing.set(.email("a@x.test", permission: "read-write", sendEmail: false, documentUrl: "https://x.test/d", note: "hi"))
        _ = try await docs.updatePermissions(
            documentId: "D1", params: .email("a@x.test", permission: "read-write", sendEmail: false, documentUrl: "https://x.test/d", note: "hi")
        )
        _ = try await sharing.set(.batch([PermissionAssignment(userId: "u1", permission: "reader"), PermissionAssignment(email: "b@x.test", permission: "reader")]))
        _ = try await docs.updatePermissions(
            documentId: "D1",
            params: .batch([PermissionAssignment(userId: "u1", permission: "reader"), PermissionAssignment(email: "b@x.test", permission: "reader")])
        )
        try await sharing.remove(.userId("u1"))
        try await docs.removePermission(documentId: "D1", .userId("u1"))
        try await sharing.remove(.email("a+b@x.test"))
        try await docs.removePermission(documentId: "D1", .email("a+b@x.test"))
        _ = try await sharing.listPendingInvitations()
        _ = try await docs.listPendingInvitations(documentId: "D1")
        _ = try await sharing.listGroups()
        _ = try await docs.listGroupPermissions(documentId: "D1")
        _ = try await sharing.listGroups(includeSystem: true)
        _ = try await docs.listGroupPermissions(documentId: "D1", includeSystem: true)
        _ = try await sharing.grantGroup(GrantGroupPermissionParams(groupId: "g1", permission: "reader"))
        _ = try await docs.grantGroupPermission(documentId: "D1", params: GrantGroupPermissionParams(groupId: "g1", permission: "reader"))
        _ = try await sharing.revokeGroup("g1")
        _ = try await docs.revokeGroupPermission(documentId: "D1", groupId: "g1")
        _ = try await sharing.getLinkAccess()
        _ = try await docs.getLinkAccess(documentId: "D1")
        try await sharing.setLinkAccess(.readWrite)
        try await docs.setLinkAccess(documentId: "D1", level: .readWrite)
        try await sharing.clearLinkAccess()
        try await docs.clearLinkAccess(documentId: "D1")
        _ = try await sharing.requestAccess(RequestAccessOptions(permission: .reader))
        _ = try await docs.requestAccess(documentId: "D1", options: RequestAccessOptions(permission: .reader))
        _ = try await sharing.listAccessRequests()
        _ = try await docs.listAccessRequests(documentId: "D1")
        _ = try await sharing.approveAccessRequest("r1")
        _ = try await docs.approveAccessRequest(documentId: "D1", requestId: "r1")
        _ = try await sharing.approveAccessRequest("r1", options: ApproveAccessRequestOptions(permission: .readWrite, documentUrl: "https://x.test/d"))
        _ = try await docs.approveAccessRequest(
            documentId: "D1", requestId: "r1", options: ApproveAccessRequestOptions(permission: .readWrite, documentUrl: "https://x.test/d")
        )
        _ = try await sharing.denyAccessRequest("r1")
        _ = try await docs.denyAccessRequest(documentId: "D1", requestId: "r1")
        _ = try await sharing.denyAccessRequest("r1", options: DenyAccessRequestOptions(documentUrl: "https://x.test/d"))
        _ = try await docs.denyAccessRequest(documentId: "D1", requestId: "r1", options: DenyAccessRequestOptions(documentUrl: "https://x.test/d"))

        XCTAssertEqual(ours.calls.count, 20)
        XCTAssertEqual(ours.calls.count, theirs.calls.count)
        for (mine, twin) in zip(ours.calls, theirs.calls) {
            XCTAssertEqual(mine.method, twin.method, mine.path)
            XCTAssertEqual(mine.path, twin.path.replacingOccurrences(of: "/documents/", with: "/db3/"))
            XCTAssertTrue(mine.path.hasPrefix("/db3/D1/"), mine.path)
            XCTAssertEqual(mine.jsonBody, twin.jsonBody, mine.path)
        }
        let paths = ours.calls.map { "\($0.method.rawValue) \($0.path)" }
        XCTAssertEqual(paths, [
            "GET /db3/D1/permissions",
            "PUT /db3/D1/permissions",
            "PUT /db3/D1/permissions",
            "PUT /db3/D1/permissions",
            "DELETE /db3/D1/permissions/u1",
            "DELETE /db3/D1/permissions?email=a%2Bb%40x.test",
            "GET /db3/D1/pending-invitations",
            "GET /db3/D1/group-permissions",
            "GET /db3/D1/group-permissions?includeSystem=true",
            "POST /db3/D1/group-permissions",
            "DELETE /db3/D1/group-permissions/g1",
            "GET /db3/D1/link-access",
            "PUT /db3/D1/link-access",
            "DELETE /db3/D1/link-access",
            "POST /db3/D1/access-requests",
            "GET /db3/D1/access-requests",
            "POST /db3/D1/access-requests/r1/approve",
            "POST /db3/D1/access-requests/r1/approve",
            "POST /db3/D1/access-requests/r1/deny",
            "POST /db3/D1/access-requests/r1/deny",
        ])
        // A nil approve or deny options sends `{}`.
        XCTAssertEqual(ours.calls[16].jsonBody, [:])
        XCTAssertEqual(ours.calls[18].jsonBody, [:])
        XCTAssertEqual(ours.calls[13].jsonBody, nil, "clearLinkAccess sends no body")
        XCTAssertEqual(ours.calls[12].jsonBody, ["level": "read-write"])
    }

    func testEveryIdIsEncodedOnce() async throws {
        let ours = transport()
        let sharing = db3(ours, "D/1?x")
        _ = try await sharing.list()
        try await sharing.remove(.userId("u/1?y"))
        _ = try await sharing.revokeGroup("g/1?z")
        _ = try await sharing.approveAccessRequest("r/1?w")
        _ = try await sharing.denyAccessRequest("r/1?w")
        XCTAssertEqual(ours.calls.map(\.path), [
            "/db3/D%2F1%3Fx/permissions",
            "/db3/D%2F1%3Fx/permissions/u%2F1%3Fy",
            "/db3/D%2F1%3Fx/group-permissions/g%2F1%3Fz",
            "/db3/D%2F1%3Fx/access-requests/r%2F1%3Fw/approve",
            "/db3/D%2F1%3Fx/access-requests/r%2F1%3Fw/deny",
        ])
    }

    // MARK: - E1

    func testAnEmptyTargetThrowsBeforeAnyRequest() async {
        let ours = transport()
        let sharing = db3(ours)
        for target: DocumentPermissionTarget in [.userId(""), .email(""), ""] {
            do {
                try await sharing.remove(target)
                XCTFail("an empty target must throw")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .invalidArgument)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(ours.calls.count, 0)
    }

    // MARK: - E2

    func testListGroupsSendsOnlyWhatItIsAskedAndFiltersNothing() async throws {
        let ours = transport(systemGroup: true)
        let sharing = db3(ours)
        let plain = try await sharing.listGroups()
        let all = try await sharing.listGroups(includeSystem: true)
        XCTAssertEqual(ours.calls.map(\.path), ["/db3/D1/group-permissions", "/db3/D1/group-permissions?includeSystem=true"])
        XCTAssertEqual(plain.map(\.groupType), ["team", "_app"], "the server's answer is passed through")
        XCTAssertEqual(all.map(\.groupType), ["team", "_app"])
    }

    // MARK: - E3

    func testRequestAndApproveSendOnlyTheKeysSet() async throws {
        let ours = transport()
        let sharing = db3(ours)
        _ = try await sharing.requestAccess(RequestAccessOptions(permission: .readWrite, message: "please", sendEmail: false))
        _ = try await sharing.approveAccessRequest("r1", options: ApproveAccessRequestOptions(permission: .reader))
        XCTAssertEqual(ours.calls[0].jsonBody, ["permission": "read-write", "message": "please", "sendEmail": false])
        XCTAssertEqual(ours.calls[1].jsonBody, ["permission": "reader"])
    }

    // MARK: - E9

    func testAStringLiteralTargetIsAUserId() async throws {
        let ours = transport()
        try await db3(ours).remove("u1")
        XCTAssertEqual(ours.lastCall?.method, .delete)
        XCTAssertEqual(ours.lastCall?.path, "/db3/D1/permissions/u1")
    }
}
