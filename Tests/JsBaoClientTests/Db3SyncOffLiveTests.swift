import XCTest
@testable import JsBaoClient

/// #4806 behavior 18 and edge case 039 — a db3's sync turned off, against
/// the dev server: the Swift twin of `tests/client/db3-sync-off-gone-4799.test.ts`.
///
/// A live member hears `Db3GoneEvent(reason: .syncOff)` exactly once within
/// ten seconds of the flip; the db3 is gone and refused with `DB3_SYNC_OFF`,
/// its rows stay readable, a new save is refused `WRITE_ACCESS_DENIED`
/// through `Db3WriteRefusedEvent`, and a subscribe while gone throws
/// `.db3SyncOff` with no second gone event. Once the sync is on again a
/// subscribe reaches `live` at the grant's level and a save lands. A member
/// that was offline across the flip hears the same once it reconnects, and
/// its queued write still needs `force` to evict. A revoked grant on a synced
/// db3 still reports `.permission`.
final class Db3SyncOffLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let permissionCache: TimeInterval = 6

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-sync-off-4806")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func setSync(_ db3Id: String, _ sync: Bool) async throws {
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3/\(db3Id)/sync", body: ["sync": sync], jwt: live.app.ownerJWT
        )
    }

    private func save(_ client: JsBaoClient, _ db3: String, _ title: String) throws {
        try client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: db3)
    }

    private func titles(_ client: JsBaoClient) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil).compactMap { $0["title"]?.stringValue }.sorted()
    }

    private func roomTitles(_ db3Id: String) async throws -> [String] {
        try await live.roomRows(db3Id, "Note").values.compactMap { $0["title"] as? String }.sorted()
    }

    private struct Member {
        let id: String
        let userId: String
        let client: JsBaoClient
        let handle: Db3Subscription
    }

    /// A member holding read-write on a db3, subscribed, with `rows` confirmed rows.
    private func memberWith(_ rows: [String]) async throws -> Member {
        let id = try await live.db3Written(0, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        try await ctx.grantPermission(
            appId: live.app.appId, documentId: id, userId: member.userId, permission: "read-write", jwt: live.app.ownerJWT
        )
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        for title in rows {
            try await client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: id, confirm: true)
        }
        return Member(id: id, userId: member.userId, client: client, handle: handle)
    }

    func testALiveMemberHearsTheDb3GoneSyncOffOnceAndSubscribesAgainOnceItIsOn() async throws {
        let m = try await memberWith(["one", "two"])
        let c = m.client
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }

        try await setSync(m.id, false)
        try await eventually(timeout: 10, description: "gone within ten seconds of the flip") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id, reason: .syncOff)])
        XCTAssertEqual(gone.value.first?.code, "DB3_SYNC_OFF")
        try await eventually(description: "the state gone") { m.handle.state.phase == .gone }
        XCTAssertEqual(m.handle.state.permission, .refused)
        XCTAssertEqual(m.handle.state.error?.code, "DB3_SYNC_OFF")
        XCTAssertTrue(m.handle.state.resident)
        XCTAssertEqual(try titles(c), ["one", "two"], "its rows stay readable")

        // A new save is refused, and handed back through Db3WriteRefusedEvent.
        let refusals = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let heardRefused = c.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refusals.mutate { $0.append(event) } }
        XCTAssertThrowsError(try save(c, m.id, "after the flip")) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .writeAccessDenied)
        }
        XCTAssertEqual(refusals.value.map(\.error.code), [.writeAccessDenied])
        heardRefused.cancel()

        // A subscribe while gone throws .db3SyncOff, and no second gone event fires.
        let again = try c.db3.subscribe(m.id, options: Db3SubscribeOptions(readyTimeout: 20))
        let got = await db3Outcome { try await again.ready() }
        XCTAssertEqual(got, "DB3_SYNC_OFF")
        try await delay(1)
        XCTAssertEqual(gone.value.count, 1)
        again.dispose()
        m.handle.dispose()

        // On again: a subscribe reaches live at the grant's level, and a save lands.
        try await setSync(m.id, true)
        let back = try c.db3.subscribe(m.id, options: Db3SubscribeOptions(readyTimeout: 30))
        try await back.ready()
        // The own writer's record.opened lifted the refused mark: the state read now says so.
        try await eventually(description: "live at the grant's level") {
            let state = try await c.db3.state(m.id)
            return state.phase == .live && state.permission == .readWrite
        }
        try await c.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("after sync on")], in: m.id, confirm: true)
        let room = try await roomTitles(m.id)
        XCTAssertEqual(room, ["after sync on", "one", "two"])
        XCTAssertEqual(gone.value.count, 1)
        back.dispose()
    }

    /// Edge case 039, and the reconnect of edge case 038 against the server.
    func testAMemberOfflineAcrossTheFlipHearsItOnReconnectAndItsQueuedWriteNeedsForceToEvict() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }
        c.setNetworkMode(.offline)
        try save(c, m.id, "queued")
        try await setSync(m.id, false)
        c.setNetworkMode(.online)
        try await waitForConnection(client: c, timeout: 15)
        try await eventually(timeout: 15, description: "gone on reconnect") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id, reason: .syncOff)])
        try await eventually(description: "the numbers read") { m.handle.state.pendingWrites == 1 }
        XCTAssertEqual(try titles(c), ["one", "queued"])
        let evicted = await db3Outcome { try await c.db3.evict(m.id) }
        XCTAssertEqual(evicted, "DB3_PENDING_WRITES")
        try await delay(1)
        XCTAssertEqual(gone.value.count, 1)

        // On again: the queued write lands.
        m.handle.dispose()
        try await setSync(m.id, true)
        let back = try c.db3.subscribe(m.id, options: Db3SubscribeOptions(readyTimeout: 30))
        try await back.ready()
        try await live.settled(c, m.id)
        let room = try await roomTitles(m.id)
        XCTAssertEqual(room, ["one", "queued"])
        back.dispose()
    }

    func testARevokedGrantOnASyncedDb3StillReportsPermission() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        defer { heardGone.cancel() }
        _ = try await ctx.appRequest(
            method: "DELETE", appId: live.app.appId, path: "/documents/\(m.id)/permissions/\(m.userId)", body: nil, jwt: live.app.ownerJWT
        )
        try await delay(Self.permissionCache)
        try save(c, m.id, "sent after the revocation")
        try await eventually(timeout: 20, description: "gone") { !gone.value.isEmpty }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id, reason: .permission)])
        XCTAssertEqual(m.handle.state.error?.code, "DB3_ACCESS_REFUSED")
    }
}
