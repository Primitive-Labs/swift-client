import XCTest
@testable import JsBaoClient

/// #5091 behavior 9 — a db3 already gone for another reason that is then
/// deleted announces `.deleted` once, rule for rule from the JS lifecycle.
///
/// Gone for `.permission` (or `.syncOff`), then the room's `DOCUMENT_DELETED`
/// (`deletedHeard`, the refused mark, `syncFailed`): a second
/// `Db3GoneEvent(reason: .deleted)` (`DB3_DELETED`) fires, every handle hears
/// it, a waiting `ready()` throws `.db3Deleted`, and the state's error names
/// the code. Once announced `.deleted`, nothing more fires; a db3 gone
/// `.clientOutdated` keeps that reason. Swift has no deleting-client
/// coordination, so there is no pending-delete case.
final class Db3DeletedAfterGoneHermeticTests: XCTestCase {
    typealias World = Db3LifecycleHermeticTests.World

    private static let id = "01JD5091DE1ETEDAFTERG0NEXX"

    private func make() -> (Db3Lifecycle, World) {
        let world = World()
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

    private func revoked(_ lifecycle: Db3Lifecycle, _ world: World) {
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
    }

    private func syncOff(_ lifecycle: Db3Lifecycle, _ world: World) {
        lifecycle.syncOffHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DB3_SYNC_OFF")
    }

    /// The room's `DOCUMENT_DELETED` as the client takes it: the reason heard, the store marked, the session's report.
    private func deletedRefusal(_ lifecycle: Db3Lifecycle, _ world: World) {
        lifecycle.deletedHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DOCUMENT_DELETED")
    }

    /// State reads that are no word from the room.
    private func refreshes(_ lifecycle: Db3Lifecycle) async throws {
        lifecycle.pendingChanged(Self.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .idle))
        try await Task.sleep(nanoseconds: 50_000_000)
        lifecycle.pendingChanged(Self.id)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private let deleted = Db3GoneEvent(id: id, reason: .deleted)

    func testAPermissionGoneDb3ThenDeletedAnnouncesDeletedOnce() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let heard = ThreadSafeBox<[Db3GoneEvent]>([])
        let listening = handle.observe { event in
            if case let .gone(gone) = event { heard.mutate { $0.append(gone) } }
        }
        defer { listening.cancel() }
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        revoked(lifecycle, world)
        let first = await code { try await handle.ready() }
        XCTAssertEqual(first, "DB3_ACCESS_REFUSED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .permission)])

        // A subscription made while gone waits for the room's next answer.
        let later = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        deletedRefusal(lifecycle, world)
        let again = await code { try await later.ready() }
        XCTAssertEqual(again, "DB3_DELETED")
        try await eventually(description: "the second gone") { self.gone(world).count == 2 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .permission), deleted])
        XCTAssertEqual(gone(world).last?.code, "DB3_DELETED")
        try await eventually(description: "the handle heard it") { heard.value.count == 2 }
        XCTAssertEqual(heard.value.last, deleted)
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.error?.code, "DB3_DELETED")

        // Nothing more: a later DOCUMENT_DELETED, ACCESS_DENIED, deletedHeard or a state read.
        lifecycle.syncFailed(Self.id, "DOCUMENT_DELETED")
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        lifecycle.deletedHeard(Self.id)
        try await refreshes(lifecycle)
        XCTAssertEqual(gone(world).count, 2)
        handle.dispose()
        later.dispose()
    }

    func testASyncOffGoneDb3ThenDeletedAnnouncesDeletedOnce() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        syncOff(lifecycle, world)
        let first = await code { try await handle.ready() }
        XCTAssertEqual(first, "DB3_SYNC_OFF")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world).first?.reason, .syncOff)
        deletedRefusal(lifecycle, world)
        try await eventually(description: "the second gone") { self.gone(world).count == 2 }
        XCTAssertEqual(gone(world).last, deleted)
        try await refreshes(lifecycle)
        XCTAssertEqual(gone(world).count, 2)
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.error?.code, "DB3_DELETED")
        handle.dispose()
    }

    func testADeletedDb3ThenRefusedFiresNothingMore() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        deletedRefusal(lifecycle, world)
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        try await refreshes(lifecycle)
        XCTAssertEqual(gone(world), [deleted])
        handle.dispose()
    }

    /// 5091-C001: a status heard while the first gone state is still being
    /// delivered (the gone event not yet told) finds the announcement already
    /// decided, so a first deletion is told once, not twice.
    func testAStatusHeardDuringTheFirstGoneDeliveryAnnouncesNothingMore() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let interleaved = ThreadSafeBox(false)
        let listening = handle.observe { event in
            guard case let .state(state) = event, state.phase == .gone else { return }
            var first = false
            interleaved.mutate { done in
                first = !done
                done = true
            }
            if first { lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .idle)) }
        }
        defer { listening.cancel() }
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        deletedRefusal(lifecycle, world)
        try await eventually(description: "gone") { self.gone(world).count >= 1 }
        XCTAssertTrue(interleaved.value)
        try await refreshes(lifecycle)
        XCTAssertEqual(gone(world), [deleted])
        handle.dispose()
    }

    func testAClientOutdatedDb3ThenDeletedFiresNothingMore() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DB3_CLIENT_OUTDATED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        deletedRefusal(lifecycle, world)
        try await refreshes(lifecycle)
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .clientOutdated)])
        handle.dispose()
    }

    func testLiveAgainAndRefusedAgainAnnouncesAfresh() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        revoked(lifecycle, world)
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        deletedRefusal(lifecycle, world)
        try await eventually(description: "the second gone") { self.gone(world).count == 2 }

        // A kept id created anew: live again, the mark lifted.
        world.with { $0.marks?.permission = nil }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await eventually(description: "live again") { handle.state.phase == .live }
        revoked(lifecycle, world)
        try await eventually(description: "gone again") { self.gone(world).count == 3 }
        XCTAssertEqual(gone(world).last?.reason, .permission)
        deletedRefusal(lifecycle, world)
        try await eventually(description: "deleted again") { self.gone(world).count == 4 }
        XCTAssertEqual(gone(world).last, deleted)
        handle.dispose()
    }
}
