import XCTest
@testable import JsBaoClient

/// #4943 behaviors 2 to 8 and edge cases E10 and E11 — `client.db3.permissions(id)`
/// against the dev server.
///
/// - 2: user grants, email invitations and removals, each answer the
///   documents twin's.
/// - 3: group grants, `includeSystem` and the app row.
/// - 4: link access, and E11: a member with no grant is refused.
/// - 5: access requests, approved and denied.
/// - 6: a sync-off db3 refuses every grant-adding call, and E10.
/// - 7: every call on a format-1 document is `NOT_A_DB3`.
/// - 8: removing your own grant keeps the local copy and refuses the next subscribe.
final class Db3PermissionsLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private static let schema = """
    [models.Note]
    [models.Note.fields.id]
    type = "id"
    [models.Note.fields.title]
    type = "string"
    """

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-permissions-4943")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func pushType() async throws -> String {
        let name = "swift-share-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(name)", body: ["schema": Self.schema], jwt: live.app.ownerJWT
        )
        return name
    }

    /// A refusal as `(status, serverCode)`; `(nil, nil)` when the call answered.
    private func status(_ body: () async throws -> Void) async -> (Int?, String?) {
        do {
            try await body()
            return (nil, nil)
        } catch let error as HttpError {
            return (error.status, error.serverCode)
        } catch {
            return (-1, "\(error)")
        }
    }

    private func titles(_ client: JsBaoClient, _ db3Id: String) throws -> [String] {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: db3Id)).query().compactMap { $0["title"]?.stringValue }.sorted()
    }

    /// A typed db3 the app owner holds, with one Note the room has.
    private func ownedDb3(_ owner: JsBaoClient) async throws -> String {
        let type = try await pushType()
        let info = try await owner.db3.create(title: "Shared", type: type)
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("hello")], in: info.id)
        let handle = try owner.db3.subscribe(info.id)
        try await handle.ready()
        try await live.settled(owner, info.id)
        handle.dispose()
        return info.id
    }

    // MARK: - Behavior 2

    func testUserGrantsInvitationsAndRemovalsAnswerAsTheDocumentsTwin() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await ownedDb3(owner)
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        let sharing = owner.db3.permissions(db3Id)

        let granted = try await sharing.set(.user(bob.userId, permission: "reader"))
        XCTAssertTrue(granted.success)
        let listed = try await sharing.list()
        XCTAssertEqual(listed.first { $0.userId == bob.userId }?.permission, .reader)
        let twinListed = try await owner.documents.getPermissions(documentId: db3Id)
        XCTAssertEqual(listed, twinListed, "the documents twin answers the same rows")

        let bobClient = try await live.client("bob", models: [Self.note], token: bob.jwt)
        let bobHandle = try bobClient.db3.subscribe(db3Id)
        try await bobHandle.ready()
        XCTAssertEqual(try titles(bobClient, db3Id), ["hello"])
        bobHandle.dispose()

        // A reader may not share.
        let refused = await status { _ = try await bobClient.db3.permissions(db3Id).set(.user(live.app.ownerUserId, permission: "reader")) }
        XCTAssertEqual(refused.0, 403)

        _ = try await sharing.set(.user(bob.userId, permission: "read-write"))
        let updated = try await sharing.list()
        XCTAssertEqual(updated.first { $0.userId == bob.userId }?.permission, .readWrite)

        let invited = "swift-invitee-\(UUID().uuidString.prefix(6).lowercased())@test.local"
        _ = try await sharing.set(.email(invited, permission: "reader", sendEmail: false))
        let pending = try await sharing.listPendingInvitations()
        XCTAssertEqual(pending.map(\.email), [invited])
        let twinPending = try await owner.documents.listPendingInvitations(documentId: db3Id)
        XCTAssertEqual(twinPending.map(\.invitationId), pending.map(\.invitationId))
        try await sharing.remove(.email(invited))
        let afterCancel = try await sharing.listPendingInvitations()
        XCTAssertEqual(afterCancel.count, 0)

        try await sharing.remove(.userId(bob.userId))
        let afterRemove = try await sharing.list()
        XCTAssertFalse(afterRemove.contains { $0.userId == bob.userId })
        let gone = await status { _ = try await bobClient.db3.get(db3Id) }
        XCTAssertEqual(gone.0, 403)
    }

    // MARK: - Behavior 3

    func testGroupGrantsAndTheAppRow() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await ownedDb3(owner)
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let group = try await ctx.createGroup(app: live.app, name: "readers", initialMembers: [(userId: member.userId, role: "member")])
        let sharing = owner.db3.permissions(db3Id)
        let memberClient = try await live.client("member", models: [Self.note], token: member.jwt)

        let refusedBefore = await status { _ = try await memberClient.db3.get(db3Id) }
        XCTAssertEqual(refusedBefore.0, 403)

        let entry = try await sharing.grantGroup(GrantGroupPermissionParams(groupId: group.groupId, permission: "reader"))
        XCTAssertEqual(entry.groupId, group.groupId)
        XCTAssertEqual(entry.permission, "reader")
        XCTAssertEqual(entry.documentId, db3Id)
        let again = try await sharing.grantGroup(GrantGroupPermissionParams(groupId: group.groupId, permission: "read-write"))
        XCTAssertEqual(again.permission, "read-write")
        let groups = try await sharing.listGroups()
        XCTAssertEqual(groups.map(\.groupId), [group.groupId])
        XCTAssertEqual(groups.first?.permission, "read-write")

        let viaGroup = try await memberClient.db3.get(db3Id)
        XCTAssertEqual(viaGroup.accessSource, .group)
        let memberHandle = try memberClient.db3.subscribe(db3Id)
        try await memberHandle.ready()
        XCTAssertEqual(try titles(memberClient, db3Id), ["hello"])
        memberHandle.dispose()

        let revoked = try await sharing.revokeGroup(group.groupId)
        XCTAssertTrue(revoked.success)
        let refusedAfter = await status { _ = try await memberClient.db3.get(db3Id) }
        XCTAssertEqual(refusedAfter.0, 403)
        let none = try await sharing.listGroups()
        XCTAssertEqual(none.count, 0)

        _ = try await owner.db3.setAppAccess(db3Id, level: .reader)
        let plain = try await sharing.listGroups()
        XCTAssertFalse(plain.contains { $0.groupType.hasPrefix("_") }, "the default omits the app row: \(plain)")
        let all = try await sharing.listGroups(includeSystem: true)
        XCTAssertTrue(all.contains { $0.groupType == "_app" }, "includeSystem lists the app row: \(all)")
        let twinAll = try await owner.documents.listGroupPermissions(documentId: db3Id, includeSystem: true)
        XCTAssertEqual(all, twinAll)
    }

    // MARK: - Behavior 4 and E11

    func testLinkAccessSetReadOverwrittenAndCleared() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await ownedDb3(owner)
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let memberClient = try await live.client("member", models: [Self.note], token: member.jwt)
        let sharing = owner.db3.permissions(db3Id)

        // E11: a member with no grant may not read the db3's sharing.
        let listRefused = await status { _ = try await memberClient.db3.permissions(db3Id).list() }
        XCTAssertEqual(listRefused.0, 403)
        XCTAssertEqual(listRefused.1, "DOC_ACCESS_DENIED")
        let linkRefused = await status { _ = try await memberClient.db3.permissions(db3Id).getLinkAccess() }
        XCTAssertEqual(linkRefused.0, 403)
        XCTAssertEqual(linkRefused.1, "DOC_ACCESS_DENIED")

        let set = try await sharing.setLinkAccess(.reader)
        XCTAssertEqual(set.documentId, db3Id)
        XCTAssertEqual(set.linkAccess, .reader)
        XCTAssertEqual(set.linkAccessUpdatedBy, live.app.ownerUserId)
        let viaLink = try await memberClient.db3.get(db3Id)
        XCTAssertEqual(viaLink.accessSource, .link)
        XCTAssertEqual(viaLink.permission, .reader)

        let overwritten = try await sharing.setLinkAccess(.readWrite)
        XCTAssertEqual(overwritten.linkAccess, .readWrite)
        let read = try await sharing.getLinkAccess()
        XCTAssertEqual(read.linkAccess, .readWrite)
        let twinRead = try await owner.documents.getLinkAccess(documentId: db3Id)
        XCTAssertEqual(read, twinRead)

        let cleared = try await sharing.clearLinkAccess()
        XCTAssertNil(cleared.linkAccess)
        let refused = await status { _ = try await memberClient.db3.get(db3Id) }
        XCTAssertEqual(refused.0, 403)
    }

    // MARK: - Behavior 5

    func testAccessRequestsApprovedAndDenied() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await ownedDb3(owner)
        let carol = try await ctx.createTestUser(appId: live.app.appId)
        let dave = try await ctx.createTestUser(appId: live.app.appId)
        let carolClient = try await live.client("carol", models: [Self.note], token: carol.jwt)
        let daveClient = try await live.client("dave", models: [Self.note], token: dave.jwt)
        let sharing = owner.db3.permissions(db3Id)

        let asked = try await carolClient.db3.permissions(db3Id).requestAccess(
            RequestAccessOptions(permission: .reader, message: "may I?", sendEmail: false)
        )
        XCTAssertTrue(asked.success)
        XCTAssertEqual(asked.request.documentId, db3Id)
        XCTAssertEqual(asked.request.requesterId, carol.userId)
        XCTAssertEqual(asked.request.status, "pending")
        let requests = try await sharing.listAccessRequests()
        XCTAssertTrue(requests.contains { $0.requestId == asked.request.requestId })

        let approved = try await sharing.approveAccessRequest(asked.request.requestId)
        XCTAssertTrue(approved.success)
        XCTAssertEqual(approved.request.status, "approved")
        let members = try await sharing.list()
        XCTAssertEqual(members.first { $0.userId == carol.userId }?.permission, .reader)
        let carolRead = try await carolClient.db3.get(db3Id)
        XCTAssertEqual(carolRead.permission, .reader)
        let twice = await status { _ = try await sharing.approveAccessRequest(asked.request.requestId) }
        XCTAssertEqual(twice.0, 409)

        let daveAsked = try await daveClient.db3.permissions(db3Id).requestAccess(RequestAccessOptions(permission: .readWrite, sendEmail: false))
        let denied = try await sharing.denyAccessRequest(daveAsked.request.requestId)
        XCTAssertTrue(denied.success)
        XCTAssertEqual(denied.request.status, "denied")
        let daveRefused = await status { _ = try await daveClient.db3.get(db3Id) }
        XCTAssertEqual(daveRefused.0, 403)
    }

    // MARK: - Behavior 6 and E10

    func testASyncOffDb3RefusesEveryGrantAddingCall() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await ownedDb3(owner)
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        let carol = try await ctx.createTestUser(appId: live.app.appId)
        let group = try await ctx.createGroup(app: live.app, name: "team", initialMembers: [(userId: carol.userId, role: "member")])
        let carolClient = try await live.client("carol", models: [Self.note], token: carol.jwt)
        let sharing = owner.db3.permissions(db3Id)
        _ = try await sharing.set(.user(bob.userId, permission: "reader"))
        let asked = try await carolClient.db3.permissions(db3Id).requestAccess(RequestAccessOptions(permission: .reader, sendEmail: false))

        _ = try await owner.db3.setSync(db3Id, sync: false)
        let code = "DB3_SYNC_OFF_NO_SHARING"
        let set = await status { _ = try await sharing.set(.user(carol.userId, permission: "reader")) }
        XCTAssertEqual(set.0, 409)
        XCTAssertEqual(set.1, code)
        let grant = await status { _ = try await sharing.grantGroup(GrantGroupPermissionParams(groupId: group.groupId, permission: "reader")) }
        XCTAssertEqual(grant.0, 409)
        XCTAssertEqual(grant.1, code)
        let link = await status { _ = try await sharing.setLinkAccess(.reader) }
        XCTAssertEqual(link.0, 409)
        XCTAssertEqual(link.1, code)
        let approve = await status { _ = try await sharing.approveAccessRequest(asked.request.requestId) }
        XCTAssertEqual(approve.0, 409)
        XCTAssertEqual(approve.1, code)

        // Reads and removals answer.
        let listed = try await sharing.list()
        XCTAssertTrue(listed.contains { $0.userId == bob.userId }, "the suspended grant is listed: \(listed)")
        let linkState = try await sharing.getLinkAccess()
        XCTAssertNil(linkState.linkAccess)
        let pending = try await sharing.listPendingInvitations()
        XCTAssertEqual(pending.count, 0)
        try await sharing.remove(.userId(bob.userId))
        let afterRemove = try await sharing.list()
        XCTAssertFalse(afterRemove.contains { $0.userId == bob.userId })

        _ = try await owner.db3.setSync(db3Id, sync: true)
        _ = try await sharing.set(.user(carol.userId, permission: "reader"))
        let landed = try await sharing.list()
        XCTAssertEqual(landed.first { $0.userId == carol.userId }?.permission, .reader)
    }

    // MARK: - Behavior 7

    func testEveryCallOnAFormat1DocumentIsNotADb3() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let sharing = owner.db3.permissions(plain)
        let calls: [(String, () async throws -> Void)] = [
            ("list", { _ = try await sharing.list() }),
            ("set", { _ = try await sharing.set(.user(self.live.app.ownerUserId, permission: "reader")) }),
            ("remove user", { try await sharing.remove(.userId("someone")) }),
            ("remove email", { try await sharing.remove(.email("someone@test.local")) }),
            ("listPendingInvitations", { _ = try await sharing.listPendingInvitations() }),
            ("listGroups", { _ = try await sharing.listGroups() }),
            ("grantGroup", { _ = try await sharing.grantGroup(GrantGroupPermissionParams(groupId: "g", permission: "reader")) }),
            ("revokeGroup", { _ = try await sharing.revokeGroup("g") }),
            ("getLinkAccess", { _ = try await sharing.getLinkAccess() }),
            ("setLinkAccess", { _ = try await sharing.setLinkAccess(.reader) }),
            ("clearLinkAccess", { _ = try await sharing.clearLinkAccess() }),
            ("requestAccess", { _ = try await sharing.requestAccess(RequestAccessOptions(permission: .reader, sendEmail: false)) }),
            ("listAccessRequests", { _ = try await sharing.listAccessRequests() }),
            ("approveAccessRequest", { _ = try await sharing.approveAccessRequest("r1") }),
            ("denyAccessRequest", { _ = try await sharing.denyAccessRequest("r1") }),
        ]
        for (name, call) in calls {
            let refused = await status(call)
            XCTAssertEqual(refused.0, 409, name)
            XCTAssertEqual(refused.1, "NOT_A_DB3", name)
        }
    }

    // MARK: - Behavior 8

    func testRemovingYourOwnGrantKeepsTheCopyAndRefusesTheNextSubscribe() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await ownedDb3(owner)
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "reader"))
        let bobClient = try await live.client("bob", models: [Self.note], token: bob.jwt)
        try await live.residentOn(bobClient, db3Id)
        XCTAssertEqual(try titles(bobClient, db3Id), ["hello"])

        let metadata = ThreadSafeBox<[DocumentMetadataChangedEvent]>([])
        let heardMetadata = bobClient.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) { event in
            metadata.mutate { $0.append(event) }
        }
        defer { heardMetadata.cancel() }
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = bobClient.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }

        try await bobClient.db3.permissions(db3Id).remove(.userId(bob.userId))
        let state = try await bobClient.db3.state(db3Id)
        XCTAssertTrue(state.resident, "the local copy stays")
        XCTAssertEqual(try titles(bobClient, db3Id), ["hello"], "and readable")
        XCTAssertFalse(metadata.value.contains { $0.documentId == db3Id }, "no metadata change is emitted: \(metadata.value)")

        let handle = try bobClient.db3.subscribe(db3Id, options: Db3SubscribeOptions(readyTimeout: 20))
        let outcome = await db3Outcome { try await handle.ready() }
        XCTAssertEqual(outcome, "DB3_ACCESS_REFUSED")
        try await eventually(timeout: 10, description: "gone") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value.first, Db3GoneEvent(id: db3Id, reason: .permission))
        handle.dispose()
    }
}
