import XCTest
@testable import JsBaoClient

/// #5044 — why a subscription ended, against the dev server. Each db3's
/// `ready()` is held pending (its record frames dropped by `Db3FrameGate`), so
/// the door ends it:
///
/// - 9: a `logout()` and a user switch (`updateToken` of another user, then
///   `rebindUserScopedStorage()`) reject every handle `DB3_DISPOSED` with
///   `details["reason"] == "identity-changed"` and the db3's id.
/// - 16: `dispose()` → `disposed`; `client.destroy()` → `destroyed`, and a
///   subscribe on the destroyed client throws `destroyed`;
///   `client.closeDocument(id)` → `closed`; a forced `client.db3.evict(id)` →
///   `evicted`.
final class Db3DisposedReasonLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-reasons-5044")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// A subscription of `id` on `client` whose `ready()` stays pending: the
    /// db3's record frames never reach its session.
    private func held(_ client: JsBaoClient, _ id: String, gate: Db3FrameGate) throws -> Db3Subscription {
        gate.drop(Db3FrameGate.of(id))
        return try client.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
    }

    private func rejection(_ subscription: Db3Subscription) async -> JsBaoError? {
        do {
            try await subscription.ready()
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    private func assertDisposed(
        _ error: JsBaoError?, _ reason: String, _ id: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(error?.code, .db3Disposed, file: file, line: line)
        XCTAssertEqual(error?.details?["reason"]?.stringValue, reason, file: file, line: line)
        XCTAssertEqual(error?.details?["db3Id"]?.stringValue, id, file: file, line: line)
    }

    // MARK: - Behaviour 9

    func testALogoutEndsEverySubscriptionWithIdentityChanged() async throws {
        let id = try await live.db3Written(1, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("logout"))
        let gate = Db3FrameGate(x)
        let first = try held(x, id, gate: gate)
        let second = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 15, description: "the db3 bound by its open") { x.isRecordLogDocument(id) }

        try await x.logout()
        assertDisposed(await rejection(first), "identity-changed", id)
        assertDisposed(await rejection(second), "identity-changed", id)
    }

    func testAUserSwitchEndsEverySubscriptionWithIdentityChanged() async throws {
        let id = try await live.db3Written(1, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("switch"))
        let gate = Db3FrameGate(x)
        let first = try held(x, id, gate: gate)
        let second = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 15, description: "the db3 bound by its open") { x.isRecordLogDocument(id) }

        let member = try await ctx.createTestUser(appId: live.app.appId)
        x.updateToken(member.jwt)
        await x.rebindUserScopedStorage()
        assertDisposed(await rejection(first), "identity-changed", id)
        assertDisposed(await rejection(second), "identity-changed", id)
    }

    // MARK: - Behaviour 16

    func testEachDoorSaysWhyTheSubscriptionEnded() async throws {
        let id = try await live.db3Written(1, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("doors"))
        let gate = Db3FrameGate(x)

        // dispose()
        let disposed = try held(x, id, gate: gate)
        try await eventually(timeout: 15, description: "the db3 bound by its open") { x.isRecordLogDocument(id) }
        disposed.dispose()
        assertDisposed(await rejection(disposed), "disposed", id)

        // A document door's close
        let closed = try held(x, id, gate: gate)
        try await eventually(timeout: 15, description: "the db3 open again") { x.documentManager.isOpen(id) }
        await x.closeDocument(id)
        assertDisposed(await rejection(closed), "closed", id)

        // The local copy removed
        let evicted = try held(x, id, gate: gate)
        try await eventually(timeout: 15, description: "the db3 open again") { x.documentManager.isOpen(id) }
        try await x.db3.evict(id, options: Db3EvictOptions(force: true))
        assertDisposed(await rejection(evicted), "evicted", id)

        // The client destroyed, and a subscribe after it
        let y = try await live.client("y", models: [Self.note], file: live.file("destroyed"))
        let destroyed = try held(y, id, gate: Db3FrameGate(y))
        try await eventually(timeout: 15, description: "the db3 bound by its open") { y.isRecordLogDocument(id) }
        await y.destroy()
        assertDisposed(await rejection(destroyed), "destroyed", id)
        XCTAssertThrowsError(try y.db3.subscribe(id)) { thrown in
            self.assertDisposed(thrown as? JsBaoError, "destroyed", id)
        }
    }
}
