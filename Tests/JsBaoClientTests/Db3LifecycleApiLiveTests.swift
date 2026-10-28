import XCTest
@testable import JsBaoClient

/// #4806 behaviors 12 to 15 and edge case 034 — `client.db3`'s lifecycle
/// calls against the dev server.
///
/// - 12: `create(title:type:)` answers the typed db3 held by its creator and
///   is resident at once: `stored()` lists it, a declared model saves and
///   queries before any subscribe, and the first subscribe sends that write
///   to the room. A sync-off create (app owner) is not resident and a
///   subscribe turns it gone `.syncOff`; a member's sync-off create is 403.
/// - 13: `get` reports the grant; `delete`; `listMine`; `transfer` answers
///   the bare row; a format-1 document is `NOT_A_DB3`.
/// - 14: `getOrCreateWithAlias` creates once, then answers the reference; a
///   differing type is 409 `DB3_TYPE_MISMATCH`.
/// - 15: the sync, type, app-access and custody calls answer their routes.
final class Db3LifecycleApiLiveTests: XCTestCase {

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
        let app = try await ctx.createTestApp(name: "swift-db3-lifecycle-4806")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Push a db3 type of the Note schema, and answer its name.
    private func pushType() async throws -> String {
        let name = "swift-notes-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(name)", body: ["schema": Self.schema], jwt: live.app.ownerJWT
        )
        return name
    }

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

    // MARK: - Behavior 12

    func testACreatedDb3IsResidentAtOnceAndItsFirstSubscribeSendsTheWritesMadeBefore() async throws {
        let type = try await pushType()
        let owner = try await live.client("owner", models: [Self.note])
        let info = try await owner.db3.create(title: "Orders", type: type)
        XCTAssertEqual(info.type, type)
        XCTAssertTrue(info.sync)
        XCTAssertEqual(info.custodian, "user:\(live.app.ownerUserId)")
        XCTAssertEqual(info.title, "Orders")

        let stored = try await owner.db3.stored()
        XCTAssertTrue(stored.contains { $0.id == info.id && $0.resident })
        let state = try await owner.db3.state(info.id)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.subscribed)
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("before subscribing")], in: info.id)
        XCTAssertEqual(try titles(owner, info.id), ["before subscribing"])

        let handle = try owner.db3.subscribe(info.id)
        try await handle.ready()
        try await live.settled(owner, info.id)
        let room = try await live.roomRows(info.id, "Note").values.compactMap { $0["title"] as? String }
        XCTAssertEqual(room, ["before subscribing"])
        // The owner's second client reads it from the room.
        let second = try await live.client("owner-second", models: [Self.note])
        let secondHandle = try second.db3.subscribe(info.id)
        try await secondHandle.ready()
        XCTAssertEqual(try titles(second, info.id), ["before subscribing"])
        handle.dispose()
        secondHandle.dispose()
    }

    func testASyncOffCreateIsNotResidentAndASubscribeTurnsItGoneSyncOff() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let info = try await owner.db3.create(title: "Server only", sync: false)
        XCTAssertFalse(info.sync)
        let state = try await owner.db3.state(info.id)
        XCTAssertFalse(state.resident)
        let storedNow = try await owner.db3.stored()
        XCTAssertFalse(storedNow.map(\.id).contains(info.id))

        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heard = owner.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heard.cancel() }
        let handle = try owner.db3.subscribe(info.id, options: Db3SubscribeOptions(readyTimeout: 20))
        let got = await db3Outcome { try await handle.ready() }
        XCTAssertEqual(got, "DB3_SYNC_OFF")
        try await eventually(timeout: 10, description: "gone") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: info.id, reason: .syncOff)])
        handle.dispose()
    }

    func testAMembersSyncOffCreateIsRefusedAndCreatesNothing() async throws {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let before = try await client.db3.listMine().items.count
        let refused = await status { _ = try await client.db3.create(title: "Mine", sync: false) }
        XCTAssertEqual(refused.0, 403)
        let after = try await client.db3.listMine().items.count
        XCTAssertEqual(after, before)
        let storedNow = try await client.db3.stored()
        XCTAssertEqual(storedNow, [])
    }

    /// Edge case 034.
    func testACreateNamingNoTypeOfTheAppIsRefused() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let before = try await owner.db3.listMine().items.count
        let refused = await status { _ = try await owner.db3.create(title: "Typed", type: "no-such-type-\(UUID().uuidString.prefix(6))") }
        XCTAssertEqual(refused.0, 404)
        XCTAssertEqual(refused.1, "DB3_TYPE_NOT_FOUND")
        let after = try await owner.db3.listMine().items.count
        XCTAssertEqual(after, before)
    }

    // MARK: - Behavior 13

    func testGetDeleteListMineTransferAndNotADb3() async throws {
        // A member holds a db3: `get` answers their own grant. (An app owner
        // or admin reads every db3 through the app's authority, with no grant.)
        let holderUser = try await ctx.createTestUser(appId: live.app.appId)
        let holder = try await live.client("holder", models: [Self.note], token: holderUser.jwt)
        let held = try await holder.db3.create(title: "Held", tags: ["kept"])
        let read = try await holder.db3.get(held.id)
        XCTAssertEqual(read.id, held.id)
        XCTAssertEqual(read.custodian, "user:\(holderUser.userId)")
        XCTAssertEqual(read.permission, .owner)
        XCTAssertEqual(read.accessSource, .owner)
        XCTAssertEqual(read.tags, ["kept"])

        // A member reached through a group.
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let group = try await ctx.createGroup(app: live.app, name: "readers", initialMembers: [(userId: member.userId, role: "member")])
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(held.id)/group-permissions",
            body: ["groupId": group.groupId, "permission": "reader"], jwt: live.app.ownerJWT
        )
        let memberClient = try await live.client("member", models: [Self.note], token: member.jwt)
        let viaGroup = try await memberClient.db3.get(held.id)
        XCTAssertEqual(viaGroup.accessSource, .group)
        XCTAssertEqual(viaGroup.permission, .reader)

        // listMine lists what the caller holds and nothing another user holds.
        let owner = try await live.client("owner", models: [Self.note])
        let theirs = try await owner.db3.create(title: "Theirs")
        let mine = try await holder.db3.listMine(options: PaginationOptions(limit: 100))
        XCTAssertEqual(mine.items.map(\.id), [held.id])
        XCTAssertTrue(mine.items.allSatisfy { $0.tags == [] })
        XCTAssertEqual(mine.items.first?.permission, .owner)

        // transfer answers the bare row.
        let moved = try await owner.db3.transfer(theirs.id, to: "app")
        XCTAssertEqual(moved.id, theirs.id)
        XCTAssertEqual(moved.custodian, "app")
        XCTAssertEqual(moved.tags, [])
        XCTAssertNil(moved.permission)

        // delete, then the next get is a 404.
        let deleted = try await holder.db3.delete(held.id)
        XCTAssertTrue(deleted.success)
        let afterDelete = await status { _ = try await holder.db3.get(held.id) }
        XCTAssertEqual(afterDelete.0, 404)

        // A format-1 document is not a db3.
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let notADb3 = await status { _ = try await owner.db3.get(plain) }
        XCTAssertEqual(notADb3.0, 409)
        XCTAssertEqual(notADb3.1, "NOT_A_DB3")
    }

    // MARK: - Behavior 14

    func testGetOrCreateWithAliasCreatesOnceThenAnswersTheReference() async throws {
        let type = try await pushType()
        let owner = try await live.client("owner", models: [Self.note])
        let alias = AliasRef(scope: .user, aliasKey: "home-\(UUID().uuidString.prefix(6).lowercased())", userId: live.app.ownerUserId)
        let first = try await owner.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Home", type: type))
        XCTAssertTrue(first.created)
        let created = try XCTUnwrap(first.db3)
        XCTAssertEqual(created.type, type)
        XCTAssertEqual(first.alias?.aliasKey, alias.aliasKey)
        let state = try await owner.db3.state(first.id)
        XCTAssertTrue(state.resident, "resident before any subscribe")
        let storedBefore = try await owner.db3.stored().count

        let second = try await owner.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Home", type: type))
        XCTAssertFalse(second.created)
        XCTAssertNil(second.db3)
        XCTAssertEqual(second.id, first.id)
        let storedAfter = try await owner.db3.stored().count
        XCTAssertEqual(storedAfter, storedBefore)

        let other = try await pushType()
        let mismatch = await status {
            _ = try await owner.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Home", type: other))
        }
        XCTAssertEqual(mismatch.0, 409)
        XCTAssertEqual(mismatch.1, "DB3_TYPE_MISMATCH")
    }

    // MARK: - Behavior 15

    func testTheSyncTypeAppAccessAndCustodyCallsAnswerTheirRoutes() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3 = try await owner.db3.create(title: "Managed")

        let off = try await owner.db3.setSync(db3.id, sync: false)
        XCTAssertEqual(off, Db3SyncChange(id: db3.id, sync: false, changed: true))
        let synced = try await owner.db3.getSync(db3.id)
        XCTAssertEqual(synced, Db3SyncState(id: db3.id, sync: false))
        _ = try await owner.db3.setSync(db3.id, sync: true)

        let type = try await pushType()
        let attached = try await owner.db3.setType(db3.id, type: type)
        XCTAssertEqual(attached.type, type)
        XCTAssertEqual(attached.outcome, "committed")
        let typed = try await owner.db3.getType(db3.id)
        XCTAssertEqual(typed.type, type)
        XCTAssertNotNil(typed.installed)
        XCTAssertEqual(typed.installed?.revision, attached.revision)

        // App access lets a member with no row read it, and its removal takes that back.
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let memberClient = try await live.client("member", models: [Self.note], token: member.jwt)
        let granted = try await owner.db3.setAppAccess(db3.id, level: .readWrite)
        XCTAssertEqual(granted, Db3AppAccessChange(id: db3.id, level: .readWrite, changed: true))
        let access = try await owner.db3.getAppAccess(db3.id)
        XCTAssertEqual(access, Db3AppAccess(id: db3.id, level: .readWrite))
        let viaApp = try await memberClient.db3.get(db3.id)
        XCTAssertEqual(viaApp.id, db3.id)
        let revoked = try await owner.db3.setAppAccess(db3.id, level: nil)
        XCTAssertEqual(revoked, Db3AppAccessChange(id: db3.id, level: nil, changed: true))
        let refused = await status { _ = try await memberClient.db3.get(db3.id) }
        XCTAssertEqual(refused.0, 403)

        // The owner row goes and comes back while the custodian stays.
        let removed = try await owner.db3.setOwnerRow(db3.id, present: false)
        XCTAssertFalse(removed.ownerRow)
        XCTAssertTrue(removed.changed)
        XCTAssertEqual(removed.custodian, "user:\(live.app.ownerUserId)")
        let restored = try await owner.db3.setOwnerRow(db3.id, present: true)
        XCTAssertTrue(restored.ownerRow)

        let moved = try await owner.db3.transfer(db3.id, to: "app")
        XCTAssertEqual(moved.custodian, "app")
        XCTAssertEqual(moved.id, db3.id)
    }
}
