import XCTest
@testable import JsBaoClient

/// #5101 behaviours 6–9 (edges E2, E4) — a re-grant reopens a refused db3 on
/// the Swift client, against the dev server: the twin of js-bao's
/// `tests/client/db3-regrant-reopen-5070.test.ts`.
///
/// - 6: a member's live subscription, revoked and turned `gone`, goes `live`
///   again on the same handle once the owner grants `read-write` again (the
///   level the client had cached), with one `record.open` and no new
///   `Db3GoneEvent`; a confirmed save lands.
/// - 7: re-granted `reader`: `live`/`reader`, a save the moment `live` is
///   observed is refused on the device, the write queued before the
///   revocation is handed back, and a subscription the refusal answered stays
///   rejected.
/// - 8: a refused copy nothing holds open answers the grant's level and its
///   next subscribe resolves `ready()`.
/// - 9: re-granted while offline, the handle is `live` after networking returns.
///
/// The connection serves a document's permission from a cache for up to 5 s,
/// so a contact that must see a revocation waits that out first; a reopen's
/// `record.open` asks the db3's permission afresh.
final class Db3RegrantReopenLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let permissionCache: TimeInterval = 6

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-regrant-5101")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func grant(_ documentId: String, _ userId: String, _ permission: String) async throws {
        try await ctx.grantPermission(
            appId: live.app.appId, documentId: documentId, userId: userId, permission: permission, jwt: live.app.ownerJWT
        )
    }

    private func revoke(_ documentId: String, _ userId: String) async throws {
        _ = try await ctx.appRequest(
            method: "DELETE", appId: live.app.appId, path: "/documents/\(documentId)/permissions/\(userId)", body: nil,
            jwt: live.app.ownerJWT
        )
    }

    private func save(_ client: JsBaoClient, _ db3: String, _ title: String) throws {
        try client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: db3)
    }

    private func roomTitles(_ documentId: String) async throws -> [String] {
        try await live.roomRows(documentId, "Note").values.compactMap { $0["title"] as? String }.sorted()
    }

    private struct Member {
        let id: String
        let userId: String
        let client: JsBaoClient
        let handle: Db3Subscription
    }

    /// A member holding a db3 subscribed `live` with `rows` confirmed rows.
    private func memberWith(_ rows: [String]) async throws -> Member {
        let id = try await live.db3Written(0, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        try await grant(id, member.userId, "read-write")
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        for title in rows {
            try await client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string(title)], in: id, confirm: true)
        }
        return Member(id: id, userId: member.userId, client: client, handle: handle)
    }

    /// Revoke the member, wait out the permission cache, and turn the live
    /// handle `gone` with a save the room refuses (the frozen suite's way).
    private func revokedAndGone(_ m: Member) async throws {
        try await revoke(m.id, m.userId)
        try await delay(Self.permissionCache)
        try save(m.client, m.id, "sent after the revocation")
        try await eventually(timeout: 20, description: "the state to be gone") { m.handle.state.phase == .gone }
        XCTAssertEqual(m.handle.state.permission, .refused)
        XCTAssertEqual(m.handle.state.error?.code, "DB3_ACCESS_REFUSED")
    }

    /// The `record.open` frames sent for `id` from now.
    private func recordOpens(_ client: JsBaoClient, _ id: String) -> ThreadSafeBox<Int> {
        let opens = ThreadSafeBox<Int>(0)
        client.recordLogFrameSentForTest = { text in
            guard let frame = RecordLogJSON.parse(text)?.objectValue, frame["type"]?.stringValue == "record.open",
                  frame["documentId"]?.stringValue == id else { return }
            opens.mutate { $0 += 1 }
        }
        return opens
    }

    // MARK: - Behaviour 6 (E4): the same level again reopens the live handle

    func testAReGrantOfTheCachedLevelReopensTheLiveHandleOnceAndAWriteLands() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        try await revokedAndGone(m)
        let states = ThreadSafeBox<[Db3State]>([])
        let gone = ThreadSafeBox<Int>(0)
        let heardStates = c.eventEmitter.subscribe(Db3StateEvent.self) { event in
            guard event.state.id == m.id else { return }
            states.mutate { $0.append(event.state) }
        }
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in
            if event.id == m.id { gone.mutate { $0 += 1 } }
        }
        let opens = recordOpens(c, m.id)

        try await grant(m.id, m.userId, "read-write")
        try await settles(within: 5, "the handle to go live again") {
            try await eventually(timeout: 5, description: "live again") { m.handle.state.phase == .live }
        }
        XCTAssertEqual(m.handle.state.permission, .readWrite)
        let state = try await c.db3.state(m.id)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.permission, .readWrite)
        XCTAssertNotEqual(try live.binding(c, m.id).refreshMarks().permission, RecordLogPermission.refused)
        XCTAssertEqual(states.value.last?.phase, .live)
        XCTAssertEqual(states.value.last?.permission, .readWrite)
        XCTAssertEqual(gone.value, 0, "the lift emits no gone event")

        try await c.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("after the grant")], in: m.id, confirm: true)
        try await live.settled(c, m.id)
        let room = try await roomTitles(m.id)
        XCTAssertTrue(room.contains("after the grant"), "\(room)")
        XCTAssertEqual(opens.value, 1, "one record.open asked the room again")
        heardStates.cancel()
        heardGone.cancel()
    }

    // MARK: - Behaviour 7: re-granted as reader

    func testAReaderReGrantGoesLiveReadOnlyAtOnceAndHandsBackTheQueuedWrite() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        // A write queued offline before the revocation, sent once the cache knows it.
        c.setNetworkMode(.offline)
        try save(c, m.id, "queued before")
        try await revoke(m.id, m.userId)
        try await delay(Self.permissionCache)
        c.setNetworkMode(.online)
        try await eventually(timeout: 20, description: "the state to be gone") { m.handle.state.phase == .gone }

        // A subscription made while gone: the room's refusal answers it.
        let rejected = try c.db3.subscribe(m.id)
        let first = await db3Outcome { try await rejected.ready() }
        XCTAssertEqual(first, "DB3_ACCESS_REFUSED")

        let refused = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let heardRefused = c.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refused.mutate { $0.append(event) } }
        // The moment `live` is told, a save is refused on the device.
        let atLive = ThreadSafeBox<String?>(nil)
        let heardStates = c.eventEmitter.subscribe(Db3StateEvent.self) { [weak c] event in
            guard let c, event.state.id == m.id, event.state.phase == .live, atLive.value == nil else { return }
            do {
                try c.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("at live")], in: m.id)
                atLive.mutate { $0 = "saved" }
            } catch {
                atLive.mutate { $0 = (error as? JsBaoError)?.code.rawValue ?? "\(error)" }
            }
        }
        let entries = ThreadSafeBox<[String]>([])
        c.recordLogFrameSentForTest = { text in
            if text.contains("\"record.entries\"") { entries.mutate { $0.append(text) } }
        }

        try await grant(m.id, m.userId, "reader")
        try await settles(within: 5, "the handle to go live as reader") {
            try await eventually(timeout: 5, description: "live as reader") { m.handle.state.phase == .live }
        }
        XCTAssertEqual(m.handle.state.permission, .reader)
        // The handle's state is the lifecycle's snapshot, taken before the
        // event is told: the save made inside the event may still be running.
        try await eventually(description: "the save made at live") { atLive.value != nil }
        XCTAssertEqual(atLive.value, JsBaoErrorCode.writeAccessDenied.rawValue, "refused on the device the moment live is told")
        XCTAssertFalse(entries.value.contains { $0.contains("at live") }, "nothing was sent for it")
        try await eventually(timeout: 20, description: "the queued write handed back") {
            refused.value.contains { $0.error.code == .writeAccessDenied }
        }
        let again = await db3Outcome { try await rejected.ready() }
        XCTAssertEqual(again, "DB3_ACCESS_REFUSED", "the subscription the refusal answered stays rejected")

        let later = try c.db3.subscribe(m.id)
        try await settles(within: 5, "a subscribe after the grant") { try await later.ready() }
        XCTAssertEqual(later.state.phase, .live)
        XCTAssertEqual(later.state.permission, .reader)
        let room = try await roomTitles(m.id)
        XCTAssertEqual(room, ["one"])
        heardRefused.cancel()
        heardStates.cancel()
        rejected.dispose()
        later.dispose()
    }

    // MARK: - Behaviour 8: a refused copy nothing holds open

    func testARefusedCopyNothingHoldsOpenAnswersTheGrantAndItsNextSubscribeResolves() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        m.handle.dispose()
        try await eventually(description: "unsubscribed") { try await !c.db3.state(m.id).subscribed }
        try await revoke(m.id, m.userId)
        try await delay(Self.permissionCache)
        let refusedOpen = try c.db3.subscribe(m.id)
        let got = await db3Outcome { try await refusedOpen.ready() }
        XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        try await eventually(description: "refused") { refusedOpen.state.permission == .refused }
        refusedOpen.dispose()
        try await eventually(description: "unsubscribed again") { try await !c.db3.state(m.id).subscribed }

        let gone = ThreadSafeBox<Int>(0)
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in
            if event.id == m.id { gone.mutate { $0 += 1 } }
        }
        try await grant(m.id, m.userId, "read-write")
        try await eventually(timeout: 5, description: "the grant's level") {
            let state = try await c.db3.state(m.id)
            return state.permission == .readWrite && state.phase != .gone
        }
        XCTAssertEqual(gone.value, 0)

        let next = try c.db3.subscribe(m.id)
        try await settles(within: 5, "the next subscribe") { try await next.ready() }
        XCTAssertEqual(next.state.phase, .live)
        XCTAssertEqual(next.state.permission, .readWrite)
        XCTAssertNotEqual(try live.binding(c, m.id).refreshMarks().permission, RecordLogPermission.refused)
        heardGone.cancel()
        next.dispose()
    }

    // MARK: - Behaviour 9 (E2): re-granted while offline

    func testAReGrantHeardOfflineTakesEffectWhenNetworkingReturns() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        try await revokedAndGone(m)
        c.setNetworkMode(.offline)
        try await grant(m.id, m.userId, "read-write")
        try await delay(Self.permissionCache)
        XCTAssertNotEqual(m.handle.state.phase, .live)
        c.setNetworkMode(.online)
        try await settles(within: 10, "live after networking returns") {
            try await eventually(timeout: 10, description: "live") { m.handle.state.phase == .live }
        }
        XCTAssertNotEqual(m.handle.state.permission, .refused)
    }

    // MARK: - #5888 behaviour 13: a transfer to the app, then a reader grant

    func testATransferToTheAppThenAReaderGrantLeavesTheSubscriptionLiveAsReader() async throws {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/documents", body: ["title": "Custodied", "documentFormat": 3], jwt: member.jwt
        )
        let id = try XCTUnwrap(created["documentId"] as? String)
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let handle = try client.db3.subscribe(id)
        try await handle.ready()

        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(id)/transfer", body: ["to": "app"], jwt: live.app.ownerJWT
        )
        try await grant(id, member.userId, "reader")
        try await settles(within: 5, "the handle live as reader") {
            try await eventually(timeout: 5, description: "live as reader") {
                handle.state.phase == .live && handle.state.permission == .reader
            }
        }
        let saved: String? = {
            do {
                try save(client, id, "after the transfer")
                return nil
            } catch {
                return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
            }
        }()
        XCTAssertEqual(saved, JsBaoErrorCode.writeAccessDenied.rawValue, "refused on the device")
    }
}
