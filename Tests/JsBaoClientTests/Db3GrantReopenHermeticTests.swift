import XCTest
@testable import JsBaoClient

/// #5101 behaviours 1–4 (edges E1, E3, E5) — a grant heard for a refused db3,
/// the JS client's #5070 rules over the Swift lifecycle's deps.
///
/// - 1: a db3 that was live for a subscription, then refused, is asked of the
///   room again once on a readable grant; its state answers the grant's level
///   while the room's answer is awaited, and goes live with no `Db3GoneEvent`
///   on the lift. Two grants back to back ask once (E1).
/// - 2: a subscription the refusal answered before the db3 was ever live for
///   it asks nothing; the state answers `idle` and the level, and a new
///   subscribe asks the room.
/// - 3: a db3 gone as deleted, sync-off or outdated, a grant with no level, a
///   db3 not bound here: nothing is asked (E3). A db3 a document door holds
///   open is asked.
/// - 4: the reopen refused again: gone again, a waiting subscription rejected,
///   and the next grant may ask again (E5).
final class Db3GrantReopenHermeticTests: XCTestCase {

    private static let id = "01JD5101GRANTRE0PENXXXXXXX"

    /// What the client would answer the lifecycle.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var marks: Db3SyncMarks? = Db3SyncMarks(cursor: 4, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false)
        var known: Db3Permission? = .readWrite
        var opens: [String] = []
        var resyncs: [String] = []
        var doorOpen = false
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func states() -> [Db3State] {
            with { $0.emitted.compactMap { ($0 as? Db3StateEvent)?.state }.filter { $0.id == Db3GrantReopenHermeticTests.id } }
        }

        func gone() -> [Db3GoneEvent] { with { $0.emitted.compactMap { $0 as? Db3GoneEvent } } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in with { $0.opens.append(id) } },
                resync: { [self] id in with { $0.resyncs.append(id) } },
                isOpen: { [self] _ in with { $0.doorOpen } },
                knownPermission: { [self] _ in with { $0.known } },
                isBound: { [self] _ in with { $0.marks != nil } },
                syncMarks: { [self] _ in with { $0.marks } },
                storedState: { _ in RecordLogStoredState(cursor: 4, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) },
                storedIds: { [Db3GrantReopenHermeticTests.id] }
            )
        }
    }

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

    /// Subscribe, open, and make the db3 live for the subscription.
    private func live(_ lifecycle: Db3Lifecycle, _ world: World) async throws -> Db3Subscription {
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        return handle
    }

    /// The room refuses the open session: the store is marked refused and the session goes idle.
    private func refuse(_ lifecycle: Db3Lifecycle, _ world: World, _ reason: String = "ACCESS_DENIED") {
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .idle))
        lifecycle.syncFailed(Self.id, reason)
    }

    // MARK: - Behaviour 1 (E1): a live subscription reopens once

    func testAGrantReopensALiveSubscriptionOnceAndTheLiftEmitsNoGone() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        refuse(lifecycle, world)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        XCTAssertEqual(handle.state.permission, .refused)
        XCTAssertEqual(world.gone().count, 1)

        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id], "asked of the room again at once")
        let granted = try await lifecycle.state(Self.id)
        XCTAssertNotEqual(granted.phase, .gone, "a grant was heard: the room's refusal no longer stands")
        XCTAssertEqual(granted.permission, .readWrite)
        XCTAssertEqual(world.with { $0.marks?.permission }, RecordLogPermission.refused, "the mark is the room's to lift")

        // E1: a second grant while the reopen runs asks nothing more.
        lifecycle.permissionChanged(Self.id, heard: .reader)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id])

        // The room's `record.opened` lifts the mark; the session goes live.
        world.with { $0.marks?.permission = nil }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await eventually(description: "live again") { handle.state.phase == .live }
        XCTAssertEqual(handle.state.permission, .readWrite)
        let phases = world.states().map(\.phase)
        let goneAt = try XCTUnwrap(phases.firstIndex(of: .gone))
        XCTAssertTrue(phases[goneAt...].contains(.live), "gone, then live: \(phases)")
        XCTAssertEqual(world.gone().count, 1, "the lift emits no gone event")
        XCTAssertEqual(world.with { $0.opens }, [Self.id], "the same open: no new subscribe")

        // Live cleared the grant and the reopen: a later refusal is reopened by a new grant.
        refuse(lifecycle, world)
        try await eventually(description: "gone again") { handle.state.phase == .gone }
        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id, Self.id])
        handle.dispose()
    }

    // MARK: - Behaviour 2: a subscription the refusal answered does not reopen

    func testASubscriptionTheRefusalAnsweredAsksNothingAndANewSubscribeAsksTheRoom() async throws {
        let (lifecycle, world) = make()
        let rejected = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        refuse(lifecycle, world)
        let first = await code { try await rejected.ready() }
        XCTAssertEqual(first, "DB3_ACCESS_REFUSED")
        try await eventually(description: "gone") { rejected.state.phase == .gone }

        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(world.with { $0.resyncs }, [], "a subscription the refusal answered asks nothing")
        let granted = try await lifecycle.state(Self.id)
        XCTAssertEqual(granted.phase, .idle)
        XCTAssertEqual(granted.permission, .readWrite)
        XCTAssertTrue(world.gone().count == 1)

        // A new subscribe asks the room (the db3 is open here, its session idle).
        let later = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "asked again") { world.with { $0.resyncs } == [Self.id] }
        world.with { $0.marks?.permission = nil }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        let readied = await code { try await later.ready() }
        XCTAssertEqual(readied, "resolved")
        let again = await code { try await rejected.ready() }
        XCTAssertEqual(again, "DB3_ACCESS_REFUSED", "the rejected subscription stays rejected")
        rejected.dispose()
        later.dispose()
    }

    // MARK: - Behaviour 3 (E3): what a grant does not reopen

    func testAGrantOnADeletedSyncOffOrOutdatedCopyReopensNothing() async throws {
        for (reason, gone) in [("DOCUMENT_DELETED", "DB3_DELETED"), ("DB3_SYNC_OFF", "DB3_SYNC_OFF")] {
            let (lifecycle, world) = make()
            let handle = try await live(lifecycle, world)
            if reason == "DOCUMENT_DELETED" { lifecycle.deletedHeard(Self.id) } else { lifecycle.syncOffHeard(Self.id) }
            refuse(lifecycle, world, reason)
            try await eventually(description: "gone \(reason)") { handle.state.phase == .gone }
            lifecycle.permissionChanged(Self.id, heard: .readWrite)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(world.with { $0.resyncs }, [], reason)
            let state = try await lifecycle.state(Self.id)
            XCTAssertEqual(state.phase, .gone, reason)
            XCTAssertEqual(state.error?.code, gone, reason)
            handle.dispose()
        }
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        lifecycle.syncFailed(Self.id, "DB3_CLIENT_OUTDATED")
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        try await eventually(description: "gone outdated") { handle.state.phase == .gone }
        lifecycle.permissionChanged(Self.id, heard: .owner)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(world.with { $0.resyncs }, [])
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.error?.code, "DB3_CLIENT_OUTDATED")
        handle.dispose()
    }

    func testAGrantWithNoLevelOrARefusedLevelOrOnAnUnboundDb3AsksNothing() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        refuse(lifecycle, world)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        lifecycle.permissionChanged(Self.id)
        lifecycle.permissionChanged(Self.id, heard: nil)
        lifecycle.permissionChanged(Self.id, heard: .refused)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(world.with { $0.resyncs }, [], "only a heard readable level reopens")
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .refused)
        handle.dispose()

        let (unbound, nothing) = make { $0.marks = nil }
        unbound.permissionChanged(Self.id, heard: .readWrite)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(nothing.with { $0.resyncs }, [], "a db3 not bound here")
    }

    func testADoorHeldRefusedDb3IsAskedAgain() async throws {
        let (lifecycle, world) = make {
            $0.doorOpen = true
            $0.marks?.permission = RecordLogPermission.refused
        }
        lifecycle.openedByDoor(Self.id)
        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id])
        let state = try await lifecycle.state(Self.id)
        XCTAssertNotEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .readWrite)
    }

    // MARK: - Behaviour 4 (E5): the reopen refused again

    func testAReopenRefusedAgainIsGoneAgainAndTheNextGrantAsksAgain() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        refuse(lifecycle, world)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id])
        try await eventually(description: "no longer gone") { handle.state.phase != .gone }
        // A subscription made while the room is asked waits for its answer.
        let waiting = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))

        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        let got = await code { try await waiting.ready() }
        XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        try await eventually(description: "gone again") { handle.state.phase == .gone }
        XCTAssertEqual(world.gone().count, 2)
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.permission, .refused)

        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id, Self.id], "the next grant asks again")
        handle.dispose()
        waiting.dispose()
    }
}
