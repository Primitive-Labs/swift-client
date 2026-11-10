import XCTest
@testable import JsBaoClient

/// #5085 — a db3 copy's last use is the later of its last open and the end of
/// its last subscription, against the dev server. Each case holds copy A
/// subscribed from first, opens and disposes copy B after it, ends A's
/// subscription last, and applies `maxDocs: 1`: A, whose subscription ended
/// last, is kept and B is evicted. The stamp is `lastOpenedAt`, written with
/// second precision, so the uses are spaced more than a second apart.
///
/// - 8 (intent repro B): A's subscription ends by its dispose.
/// - E3: it ends by a logout, and by another user's sign-in; the stamp is in
///   the outgoing user's store when they sign in again. (Another user's
///   sign-in resets the record-log store, so that case checks the stamp
///   alone: no copy is left to rank.)
/// - E4: it ends by the client's destruction; a relaunch over the same file
///   ranks by it.
/// - E9: a dispose followed in the same turn by a logout still stamps it.
final class Db3LastUseLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-last-use-5085")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// The copy's last use, as its metadata row says.
    private func lastUse(_ client: JsBaoClient, _ id: String) -> Date? {
        client.documentManager.getMetadataIndex()[id]?.lastOpenedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// A subscribed until live, then B opened and disposed more than a second later.
    private func holdAThenUseB(_ client: JsBaoClient, _ a: String, _ b: String) async throws -> Db3Subscription {
        let handle = try client.db3.subscribe(a)
        try await handle.ready()
        try await delay(1.1)
        try await live.residentOn(client, b)
        try await delay(1.1)
        return handle
    }

    /// A's last use, as its row says, is later than B's.
    private func usedAAfterB(_ client: JsBaoClient, _ a: String, _ b: String) throws {
        let usedA = try XCTUnwrap(lastUse(client, a), "A's row is dated")
        let usedB = try XCTUnwrap(lastUse(client, b), "B's row is dated")
        XCTAssertGreaterThan(usedA, usedB, "A's subscription ended after B's")
    }

    /// A's last use is later than B's, and `maxDocs: 1` evicts B and keeps A.
    private func keepsAOverB(_ client: JsBaoClient, _ a: String, _ b: String) async throws {
        try usedAAfterB(client, a, b)
        let evicted = ThreadSafeBox<[Db3EvictedEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3EvictedEvent.self) { event in evicted.mutate { $0.append(event) } }
        defer { heard.cancel() }
        try client.db3.setRetentionPolicy(RetentionPolicy(maxDocs: 1))
        try await eventually(timeout: 15, description: "the retention eviction") { evicted.value.contains { $0.id == b } }
        try await delay(0.5)
        XCTAssertEqual(evicted.value.filter { [a, b].contains($0.id) }, [Db3EvictedEvent(id: b, reason: .retention)])
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored.map(\.id), [a])
    }

    /// The owner signs in again on the same client.
    private func signBackIn(_ client: JsBaoClient) async {
        client.updateToken(live.app.ownerJWT)
        await client.rebindUserScopedStorage()
    }

    // MARK: - Behaviour 8 (intent repro B)

    func testTheCopyHeldLongestAndDisposedLastIsKept() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let handle = try await holdAThenUseB(x, a, b)
        handle.dispose()
        try await eventually(description: "A to be unsubscribed") { try await x.db3.state(a).subscribed == false }
        try await live.subscribersBecome(a, 0)
        try await keepsAOverB(x, a, b)
    }

    // MARK: - E3

    func testALogoutEndsTheSubscriptionInTheOutgoingUsersStore() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("logout"))
        _ = try await holdAThenUseB(x, a, b)
        try await x.logout()
        await signBackIn(x)
        try await keepsAOverB(x, a, b)
    }

    func testAnotherUsersSignInEndsTheSubscriptionInTheOutgoingUsersStore() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let x = try await live.client("x", models: [Self.note], file: live.file("switch"))
        _ = try await holdAThenUseB(x, a, b)
        x.updateToken(member.jwt)
        await x.rebindUserScopedStorage()
        await signBackIn(x)
        // The owner's rows kept the stamp; the record-log store was reset for
        // the member, so no copy is left here to rank.
        try usedAAfterB(x, a, b)
        let stored = try await x.db3.stored()
        XCTAssertEqual(stored, [])
    }

    // MARK: - E4

    func testTheClientsDestructionEndsTheSubscriptionAndARelaunchRanksByIt() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let file = live.file("relaunch")
        let x = try await live.client("x", models: [Self.note], file: file)
        _ = try await holdAThenUseB(x, a, b)
        await x.destroy()
        let x2 = try await live.client("x2", models: [Self.note], file: file)
        try await eventually(description: "the stored db3s to be bound") { x2.isRecordLogDocument(a) && x2.isRecordLogDocument(b) }
        try await keepsAOverB(x2, a, b)
    }

    // MARK: - E9

    func testADisposeFollowedByALogoutInTheSameTurnEndsTheSubscription() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("dispose-logout"))
        let handle = try await holdAThenUseB(x, a, b)
        handle.dispose()
        try await x.logout()
        await signBackIn(x)
        try await keepsAOverB(x, a, b)
    }
}
