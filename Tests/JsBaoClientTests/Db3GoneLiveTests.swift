import XCTest
@testable import JsBaoClient

/// #4701 behaviours 24–26 — a revoked grant on a db3, against the dev server,
/// the Swift twin of js-bao's `tests/client/db3-gone-4698.test.ts`:
///
/// - 24: revoked while unsubscribed, the member's next subscribe turns the db3
///   `gone` (`refused`, `DB3_ACCESS_REFUSED`), `Db3GoneEvent` fires once and
///   `ready()` throws; the rows and the queued write stay readable; a new save
///   and a model-free put are refused `WRITE_ACCESS_DENIED` through
///   `Db3WriteRefusedEvent`; `evict` needs force. Restored as reader, the next
///   subscribe opens and the queued write comes back `WRITE_ACCESS_DENIED`.
/// - 25: revoked while live, an entry sent after it turns the handle `gone`;
///   restored read-write, the queued write lands; forced, the eviction goes.
/// - 26: a reconnect's reconciliation and an authoritative metadata sync of
///   each document keep a revoked db3, its rows and its queued write; a
///   revoked format-1 document's metadata is evicted as before.
///
/// The connection serves a document's permission from a cache for up to 5 s,
/// so each contact that must see a grant change waits that out first.
final class Db3GoneLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private static let permissionCache: TimeInterval = 6

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-gone-4701")
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

    private func titles(_ client: JsBaoClient) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil).compactMap { $0["title"]?.stringValue }.sorted()
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

    /// A member holding a db3 subscribed with `rows` confirmed rows.
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

    /// A new save and a model-free put are refused `WRITE_ACCESS_DENIED`, each through `Db3WriteRefusedEvent`.
    private func newWritesRefused(_ c: JsBaoClient, _ id: String) async throws {
        let refusals = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let heard = c.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refusals.mutate { $0.append(event) } }
        defer { heard.cancel() }
        let before = try await c.db3.state(id).pendingWrites
        XCTAssertThrowsError(try save(c, id, "after the revocation")) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .writeAccessDenied)
        }
        XCTAssertThrowsError(try c.documents.records(id).put("Note", ["title": "model-free after"])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .writeAccessDenied)
        }
        XCTAssertEqual(refusals.value.map(\.error.code), [.writeAccessDenied, .writeAccessDenied])
        let after = try await c.db3.state(id).pendingWrites
        XCTAssertEqual(after, before)
    }

    // MARK: - Behaviour 24

    func testARevocationWhileUnsubscribedTurnsTheNextSubscribeGoneKeepingTheRowsThenReaderReopens() async throws {
        let m = try await memberWith(["one", "two"])
        let c = m.client
        m.handle.dispose()
        try await eventually(description: "unsubscribed") { try await !c.db3.state(m.id).subscribed }
        c.setNetworkMode(.offline)
        try save(c, m.id, "queued before")
        try await revoke(m.id, m.userId)
        c.setNetworkMode(.online)
        try await waitForConnection(client: c, timeout: 15)
        try await delay(Self.permissionCache)

        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        let again = try c.db3.subscribe(m.id)
        do {
            let got = await db3Outcome { try await again.ready() }
            XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        }
        try await eventually(description: "the state to be gone") { again.state.phase == .gone }
        try await eventually(description: "the numbers read") { again.state.pendingWrites == 1 }
        XCTAssertEqual(again.state.permission, .refused)
        XCTAssertEqual(again.state.error?.code, "DB3_ACCESS_REFUSED")
        XCTAssertTrue(again.state.resident)
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id)])
        XCTAssertEqual(try titles(c), ["one", "queued before", "two"])
        try await newWritesRefused(c, m.id)
        do {
            let got = await db3Outcome { try await c.db3.evict(m.id) }
            XCTAssertEqual(got, "DB3_PENDING_WRITES")
        }
        XCTAssertEqual(gone.value.count, 1)
        again.dispose()

        // Restored as reader: the next subscribe opens, the queued write comes back refused.
        try await grant(m.id, m.userId, "reader")
        try await delay(Self.permissionCache)
        let refused = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let heardRefused = c.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refused.mutate { $0.append(event) } }
        let restored = try c.db3.subscribe(m.id)
        try await restored.ready()
        try await eventually(timeout: 20, description: "the queued write handed back") {
            refused.value.contains { $0.error.code == .writeAccessDenied }
        }
        try await eventually(timeout: 20, description: "nothing left unsent") { try await c.db3.state(m.id).pendingWrites == 0 }
        let state = try await c.db3.state(m.id)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.permission, .reader)
        let room = try await roomTitles(m.id)
        XCTAssertEqual(room, ["one", "two"])
        heardGone.cancel()
        heardRefused.cancel()
    }

    // MARK: - Behaviour 25

    func testARevocationWhileLiveTurnsTheHandleGoneAndReadWriteLandsTheQueuedWrite() async throws {
        let m = try await memberWith(["one"])
        let c = m.client
        try await revoke(m.id, m.userId)
        try await delay(Self.permissionCache)
        let gone = ThreadSafeBox<[Db3GoneEvent]>([])
        let heardGone = c.eventEmitter.subscribe(Db3GoneEvent.self) { event in gone.mutate { $0.append(event) } }
        try save(c, m.id, "sent after the revocation")
        try await eventually(timeout: 20, description: "the state to be gone") { m.handle.state.phase == .gone }
        try await eventually(description: "the numbers read") { m.handle.state.pendingWrites == 1 }
        XCTAssertEqual(gone.value, [Db3GoneEvent(id: m.id)])
        XCTAssertEqual(m.handle.state.permission, .refused)
        XCTAssertEqual(try titles(c), ["one", "sent after the revocation"])
        try await newWritesRefused(c, m.id)
        do {
            let got = await db3Outcome { try await c.db3.evict(m.id) }
            XCTAssertEqual(got, "DB3_PENDING_WRITES")
        }

        // Restored read-write: the queued write lands.
        try await grant(m.id, m.userId, "read-write")
        try await delay(Self.permissionCache)
        let restored = try c.db3.subscribe(m.id)
        try await restored.ready()
        try await live.settled(c, m.id)
        XCTAssertEqual(restored.state.phase, .live)
        XCTAssertNotEqual(restored.state.permission, .refused)
        let room = try await roomTitles(m.id)
        XCTAssertEqual(room, ["one", "sent after the revocation"])

        // Forced, the eviction goes.
        restored.dispose()
        m.handle.dispose()
        try await c.db3.evict(m.id, options: Db3EvictOptions(force: true))
        let stored = try await c.db3.stored()
        XCTAssertFalse(stored.map(\.id).contains(m.id))
        heardGone.cancel()
    }

    // MARK: - Behaviour 26

    func testAReconnectAndAnAuthoritativeSyncKeepARevokedDb3AndEvictARevokedFormatOneDocument() async throws {
        let m = try await memberWith(["kept"])
        let c = m.client
        let plainId = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        try await grant(plainId, m.userId, "read-write")
        _ = try await c.openDocument(plainId, options: OpenDocumentOptions(waitForLoad: .network))
        _ = await c.closeDocument(plainId)
        m.handle.dispose()
        try await eventually(description: "unsubscribed") { try await !c.db3.state(m.id).subscribed }
        c.setNetworkMode(.offline)
        try save(c, m.id, "queued")
        let evicted = ThreadSafeBox<[Db3EvictedEvent]>([])
        let heard = c.eventEmitter.subscribe(Db3EvictedEvent.self) { event in evicted.mutate { $0.append(event) } }
        try await revoke(m.id, m.userId)
        try await revoke(plainId, m.userId)

        // The reconnect runs its reconciliation; then an explicit authoritative one.
        c.setNetworkMode(.online)
        try await waitForConnection(client: c, timeout: 15)
        try await delay(2)
        var stored = try await c.db3.stored()
        XCTAssertTrue(stored.map(\.id).contains(m.id))
        // Each document asked authoritatively (the server answers both 403 now).
        try await c.syncMetadata(options: SyncMetadataOptions(documentId: plainId, authoritative: true))
        try await c.syncMetadata(options: SyncMetadataOptions(documentId: m.id, authoritative: true))
        XCTAssertNil(c.documentManager.getLocalMetadata(plainId))
        stored = try await c.db3.stored()
        XCTAssertTrue(stored.map(\.id).contains(m.id))
        XCTAssertNotNil(c.documentManager.getLocalMetadata(m.id))
        let pending = try await c.db3.state(m.id).pendingWrites
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(try titles(c), ["kept", "queued"])
        XCTAssertEqual(evicted.value, [])
        heard.cancel()
    }
}
