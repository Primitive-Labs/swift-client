import XCTest
@testable import JsBaoClient

/// #4806 behavior 16 and edge case 038 — a db3 whose sync turned off is gone
/// for that reason, rule for rule from the JS lifecycle (#4799).
///
/// The room refuses every record frame of a sync-off db3 `DB3_SYNC_OFF`; the
/// session marks the store refused and reports the code. The lifecycle keeps
/// the reason: the db3 turns gone once with `Db3GoneEvent(reason: .syncOff,
/// code: "DB3_SYNC_OFF")`, its state's error names the code, and a waiting
/// or later `ready()` throws `.db3SyncOff`. A revoked grant still reports
/// `.permission`, and a room that needs a newer client keeps precedence.
final class Db3SyncOffLifecycleHermeticTests: XCTestCase {
    typealias World = Db3LifecycleHermeticTests.World

    private static let id = "01JD4806SYNC0FFXXXXXXXXXXX"

    private func make(_ configure: (World) -> Void = { _ in }) -> (Db3Lifecycle, World) {
        let world = World()
        world.with(configure)
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    private func gone(_ world: World) -> [Db3GoneEvent] { world.events(Db3GoneEvent.self) }

    func testASyncOffRefusalTurnsTheDb3GoneOnceForThatReason() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        // The session marks the store refused and reports the room's code.
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DB3_SYNC_OFF")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_SYNC_OFF")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .syncOff)])
        XCTAssertEqual(gone(world).first?.code, "DB3_SYNC_OFF")
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .refused)
        XCTAssertEqual(state.error?.code, "DB3_SYNC_OFF")
        XCTAssertTrue(state.resident, "its rows stay readable")
        XCTAssertEqual(handle.state.error?.code, "DB3_SYNC_OFF")
        XCTAssertTrue(world.events(Db3ErrorEvent.self).isEmpty, "a sync-off refusal is not a retried error")

        // A subscribe while gone is answered by the room's next refusal: it
        // throws `.db3SyncOff`, and no second gone event fires.
        let later = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        lifecycle.syncFailed(Self.id, "DB3_SYNC_OFF")
        let again = await code { try await later.ready() }
        XCTAssertEqual(again, "DB3_SYNC_OFF")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gone(world).count, 1)
        handle.dispose()
        later.dispose()
    }

    func testSyncOffHeardBeforeTheMarkGivesTheSameReason() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        // The client hears the frame first; a state read sees the mark before the session reports it.
        lifecycle.syncOffHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .syncOff)])
        lifecycle.syncFailed(Self.id, "DB3_SYNC_OFF")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_SYNC_OFF")
        XCTAssertEqual(gone(world).count, 1)
        handle.dispose()
    }

    func testARevokedGrantStillReportsPermission() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .permission)])
        let refusedState = try await lifecycle.state(Self.id)
        XCTAssertEqual(refusedState.error?.code, "DB3_ACCESS_REFUSED")
        handle.dispose()
    }

    func testAnAccessRefusalAfterSyncOffReportsPermission() async throws {
        // Heard as sync-off, then refused for access before the db3 turned gone: the room's last word wins.
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.syncOffHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world).first?.reason, .permission)
        handle.dispose()
    }

    func testAClientOutdatedRoomKeepsPrecedence() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.syncOffHeard(Self.id)
        lifecycle.syncFailed(Self.id, "DB3_CLIENT_OUTDATED")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_CLIENT_OUTDATED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .clientOutdated)])
        let outdatedState = try await lifecycle.state(Self.id)
        XCTAssertEqual(outdatedState.error?.code, "DB3_CLIENT_OUTDATED")
        handle.dispose()
    }

    /// Edge case 038: subscribed and offline when the sync went off.
    func testAReconnectRefusedSyncOffTurnsTheDb3GoneOnce() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        world.with { $0.socket = false }
        lifecycle.connectionChanged()
        try await eventually(description: "reconnecting") { handle.state.phase == .reconnecting }
        // Back online: the reopen is refused because the sync is off now.
        world.with { $0.socket = true }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .idle))
        lifecycle.connectionChanged()
        lifecycle.syncOffHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DB3_SYNC_OFF")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .syncOff)])
        lifecycle.connectionChanged()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gone(world).count, 1)
        XCTAssertEqual(handle.state.error?.code, "DB3_SYNC_OFF")
        handle.dispose()
    }

    func testOnceTheSyncIsOnAgainTheDb3IsLiveAndAFreshRefusalIsAskedAnew() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DB3_SYNC_OFF")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        handle.dispose()
        // The last subscription's close is done before the db3 is asked for again.
        try await eventually(description: "the close") { world.with { $0.closes } == [Self.id] }
        // On again: the own writer's record.opened lifted the mark, and the db3 is live.
        world.with { $0.marks?.permission = nil }
        let back = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the reopen") { world.with { $0.opens } == [Self.id, Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await back.ready()
        // A state read started before the session said live may land after `ready()`; the last word is live.
        try await eventually(description: "live") { back.state.phase == .live }
        XCTAssertNil(back.state.error)
        // A later revoke is a permission refusal, not the sync-off reason kept from before.
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "gone again") { self.gone(world).count == 2 }
        XCTAssertEqual(gone(world).last?.reason, .permission)
        back.dispose()
    }
}
