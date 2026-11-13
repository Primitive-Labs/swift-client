import XCTest
@testable import JsBaoClient

/// #5888 behaviour 11 — a grant heard while the client's ask of the room is
/// unanswered survives that ask's refusal, the JS client's rule over the
/// Swift lifecycle's deps.
///
/// - 1: a readable level heard before the room's refusal asks the room again
///   at once; until the room answers, no state is `gone`, no gone event
///   fires and a pending `ready()` waits; the room's open clears the grant.
/// - 2: grant, then `deleted`: the refusal turns the db3 `gone` and nothing
///   is asked.
/// - 3: one grant buys two asks, the second about 1 s after the second
///   refusal (the state not `gone` and `ready()` pending meanwhile); a third
///   refusal is final; a sync-off or deleted refusal is never retried.
/// - E8: `deleted` heard while the second ask waits: no ask, and the db3 is
///   `gone` on the standing refusal.
final class Db3GrantBeforeRefusalHermeticTests: XCTestCase {

    private static let id = "01JD5888GRANTBEFOREREFUSAL"

    /// What the client would answer the lifecycle.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var marks: Db3SyncMarks? = Db3SyncMarks(cursor: 4, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false)
        var known: Db3Permission? = .owner
        var opens: [String] = []
        var resyncs: [String] = []
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func states() -> [Db3State] {
            with { $0.emitted.compactMap { ($0 as? Db3StateEvent)?.state }.filter { $0.id == Db3GrantBeforeRefusalHermeticTests.id } }
        }

        func gone() -> [Db3GoneEvent] { with { $0.emitted.compactMap { $0 as? Db3GoneEvent } } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in with { $0.opens.append(id) } },
                resync: { [self] id in with { $0.resyncs.append(id) } },
                isOpen: { _ in false },
                knownPermission: { [self] _ in with { $0.known } },
                isBound: { [self] _ in with { $0.marks != nil } },
                syncMarks: { [self] _ in with { $0.marks } },
                storedState: { _ in RecordLogStoredState(cursor: 4, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) },
                storedIds: { [Db3GrantBeforeRefusalHermeticTests.id] }
            )
        }
    }

    private func make() -> (Db3Lifecycle, World) {
        let world = World()
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    /// Subscribe, open, and make the db3 live for the subscription.
    private func live(_ lifecycle: Db3Lifecycle, _ world: World) async throws -> Db3Subscription {
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        return handle
    }

    /// The session's refusal of its open: idle, the store marked refused, then the lifecycle told.
    private func refuse(_ lifecycle: Db3Lifecycle, _ world: World, _ reason: String = "ACCESS_DENIED") {
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .idle))
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, reason)
    }

    /// The client's ask of the room is unanswered: the session is opening.
    private func asking(_ lifecycle: Db3Lifecycle) {
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .opening))
    }

    /// A `ready()` whose outcome the test reads later: `nil` while it waits.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var current: String? { lock.withLock { value } }
        func set(_ v: String) { lock.withLock { value = v } }
    }

    private func watch(_ handle: Db3Subscription) -> Outcome {
        let outcome = Outcome()
        Task {
            do {
                try await handle.ready()
                outcome.set("resolved")
            } catch {
                outcome.set((error as? JsBaoError)?.code.rawValue ?? "\(error)")
            }
        }
        return outcome
    }

    // MARK: - Behaviour 1

    func testAGrantHeardBeforeTheRefusalAsksAgainAtOnceAndNeverReportsGone() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        asking(lifecycle)
        let pending = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let outcome = watch(pending)
        world.with { $0.known = .reader }
        lifecycle.grantHeard(Self.id, .reader)
        let from = world.states().count

        refuse(lifecycle, world)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id], "asked of the room again at once")
        try await Task.sleep(nanoseconds: 200_000_000)
        let during = Array(world.states().dropFirst(from))
        XCTAssertTrue(during.allSatisfy { $0.phase != .gone && $0.permission == .reader }, "\(during.map { ($0.phase, $0.permission) })")
        let state = try await lifecycle.state(Self.id)
        XCTAssertNotEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .reader)
        XCTAssertTrue(world.gone().isEmpty)
        XCTAssertNil(outcome.current, "a pending ready() still waits")

        // The room's answer to the ask.
        world.with { $0.marks?.permission = RecordLogPermission.read }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await eventually(description: "live as reader") { handle.state.phase == .live && handle.state.permission == .reader }
        try await eventually(description: "the pending ready resolved") { outcome.current == "resolved" }
        XCTAssertTrue(world.gone().isEmpty)

        // The grant was answered: a later refusal is final.
        refuse(lifecycle, world)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(world.with { $0.resyncs }, [Self.id])
        handle.dispose()
        pending.dispose()
    }

    // MARK: - Behaviour 2

    func testARevokeHeardAfterTheGrantWins() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        asking(lifecycle)
        lifecycle.grantHeard(Self.id, .reader)
        lifecycle.accessRevoked(Self.id)
        refuse(lifecycle, world)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(world.with { $0.resyncs }, [])
        XCTAssertEqual(handle.state.error?.code, "DB3_ACCESS_REFUSED")
        XCTAssertEqual(world.gone().count, 1)
        handle.dispose()
    }

    // MARK: - Behaviour 3

    func testOneGrantBuysTwoAsksTheSecondAboutASecondLater() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        asking(lifecycle)
        let pending = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let outcome = watch(pending)
        world.with { $0.known = .reader }
        lifecycle.grantHeard(Self.id, .reader)
        refuse(lifecycle, world)
        XCTAssertEqual(world.with { $0.resyncs }.count, 1)
        asking(lifecycle)
        refuse(lifecycle, world)
        XCTAssertEqual(world.with { $0.resyncs }.count, 1, "the second ask waits")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(world.with { $0.resyncs }.count, 1)
        let waiting = try await lifecycle.state(Self.id)
        XCTAssertNotEqual(waiting.phase, .gone)
        XCTAssertEqual(waiting.permission, .reader)
        XCTAssertTrue(world.gone().isEmpty)
        XCTAssertNil(outcome.current)
        try await eventually(timeout: 2, description: "the second ask") { world.with { $0.resyncs }.count == 2 }
        asking(lifecycle)
        refuse(lifecycle, world)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        try await eventually(description: "the pending ready rejected") { outcome.current == "DB3_ACCESS_REFUSED" }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(world.with { $0.resyncs }.count, 2, "a third refusal is final")
        XCTAssertEqual(world.gone().count, 1)
        handle.dispose()
        pending.dispose()
    }

    func testAGrantHeardDuringTheWaitIsKeptAndTheWaitingAskIsMade() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        asking(lifecycle)
        let pending = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let outcome = watch(pending)
        world.with { $0.known = .reader }
        lifecycle.grantHeard(Self.id, .reader)
        refuse(lifecycle, world)
        asking(lifecycle)
        refuse(lifecycle, world)
        XCTAssertEqual(world.with { $0.resyncs }.count, 1, "the second ask waits")
        // A newer grant while the second ask waits, the store still refused.
        world.with { $0.known = .readWrite }
        lifecycle.grantHeard(Self.id, .readWrite)
        lifecycle.permissionChanged(Self.id, heard: .readWrite)
        XCTAssertEqual(world.with { $0.resyncs }.count, 1, "the waiting ask carries the grant")
        try await eventually(timeout: 2, description: "the waiting ask") { world.with { $0.resyncs }.count == 2 }
        world.with { $0.marks?.permission = nil }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await eventually(description: "live as read-write") { handle.state.phase == .live && handle.state.permission == .readWrite }
        try await eventually(description: "the pending ready resolved") { outcome.current == "resolved" }
        XCTAssertTrue(world.gone().isEmpty)
        handle.dispose()
        pending.dispose()
    }

    func testASyncOffOrDeletedRefusalIsNeverRetried() async throws {
        for reason in ["DB3_SYNC_OFF", "DOCUMENT_DELETED"] {
            let (lifecycle, world) = make()
            let handle = try await live(lifecycle, world)
            asking(lifecycle)
            lifecycle.grantHeard(Self.id, .reader)
            if reason == "DB3_SYNC_OFF" { lifecycle.syncOffHeard(Self.id) } else { lifecycle.deletedHeard(Self.id) }
            refuse(lifecycle, world, reason)
            try await eventually(description: "gone \(reason)") { handle.state.phase == .gone }
            try await Task.sleep(nanoseconds: 1_300_000_000)
            XCTAssertEqual(world.with { $0.resyncs }, [], reason)
            handle.dispose()
        }
    }

    // MARK: - E8

    func testADeletedHeardDuringTheWaitCancelsTheSecondAsk() async throws {
        let (lifecycle, world) = make()
        let handle = try await live(lifecycle, world)
        asking(lifecycle)
        lifecycle.grantHeard(Self.id, .reader)
        refuse(lifecycle, world)
        refuse(lifecycle, world)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(world.gone().isEmpty)
        lifecycle.accessRevoked(Self.id)
        try await eventually(description: "gone") { handle.state.phase == .gone }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(world.with { $0.resyncs }.count, 1)
        XCTAssertEqual(world.gone().count, 1)
        handle.dispose()
    }
}
