import XCTest
@testable import JsBaoClient

/// #5363 behavior 18 — `revokePendingInvitation` against the dev server, the
/// Swift twin of the JS client's suite.
///
/// The app's owner shares a db3 and a group by email; the db3's and the
/// group's revokes answer the typed result and empty their lists, and a
/// member who neither made the grant nor manages the group is refused 403.
final class PendingInvitationRevokeLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-pending-invitation-revoke-5363")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func email(_ label: String) -> String {
        "swift-revoke-5363-\(label)-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    }

    /// The `HttpError` `body` throws; a failure when it throws nothing or something else.
    private func httpError(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> HttpError? {
        do {
            try await body()
            XCTFail("nothing was thrown", file: file, line: line)
        } catch let error as HttpError {
            return error
        } catch {
            XCTFail("threw \(error), not an HttpError", file: file, line: line)
        }
        return nil
    }

    func testTheDb3RevokeEmptiesItsListAndRefusesANonGrantor() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let created = try await owner.db3.create(title: "Shared")
        _ = try await owner.db3.get(created.id)
        let invitee = email("db3")
        try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3/\(created.id)/permissions",
            body: ["email": invitee, "permission": "reader"], jwt: live.app.ownerJWT
        )
        let pending = try await owner.db3.permissions(created.id).listPendingInvitations()
        let entry = try XCTUnwrap(pending.first { $0.email == invitee })

        let member = try await ctx.createTestUser(appId: live.app.appId)
        let theirs = try await live.client("member", models: [Self.note], token: member.jwt)
        let refused = await httpError { _ = try await theirs.db3.permissions(created.id).revokePendingInvitation(entry.invitationId) }
        XCTAssertEqual(refused?.status, 403)

        let revoked = try await owner.db3.permissions(created.id).revokePendingInvitation(entry.invitationId)
        XCTAssertEqual(revoked, PendingInvitationRevokeResult(
            success: true, status: "pending_cancelled", invitationId: entry.invitationId, email: invitee, deferredCount: 1
        ))
        let after = try await owner.db3.permissions(created.id).listPendingInvitations()
        XCTAssertTrue(after.filter { $0.email == invitee }.isEmpty)
    }

    func testTheGroupRevokeEmptiesItsListAndRefusesAPlainMember() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let plain = try await ctx.createTestUser(appId: live.app.appId)
        let group = try await ctx.createGroup(app: live.app, name: "Revoke 5363", initialMembers: [(userId: plain.userId, role: "member")])
        let invitee = email("group")
        try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/groups/\(group.groupId)/members",
            body: ["email": invitee], jwt: live.app.ownerJWT
        )
        let pending = try await owner.groups.listPendingInvitations(groupId: group.groupId)
        let entry = try XCTUnwrap(pending.first { $0.email == invitee })

        let theirs = try await live.client("plain", models: [Self.note], token: plain.jwt)
        let refused = await httpError { _ = try await theirs.groups.revokePendingInvitation(groupId: group.groupId, invitationId: entry.invitationId) }
        XCTAssertEqual(refused?.status, 403)

        let revoked = try await owner.groups.revokePendingInvitation(groupId: group.groupId, invitationId: entry.invitationId)
        XCTAssertEqual(revoked.status, "pending_cancelled")
        XCTAssertEqual(revoked.invitationId, entry.invitationId)
        XCTAssertEqual(revoked.deferredCount, 1)
        let after = try await owner.groups.listPendingInvitations(groupId: group.groupId)
        XCTAssertTrue(after.filter { $0.email == invitee }.isEmpty)
    }
}
