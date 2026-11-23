import XCTest
@testable import JsBaoClient

/// #5101 behaviours 12 and 13 (edges E9, E13) — `ready()` waits for the
/// open's index list: the lifecycle's `indexesSettled` dep, the JS client's
/// #5070 rule.
///
/// - 12: live with the list not applied, `available()` resolves and `ready()`
///   waits; `indexesChanged` once it is applied settles `ready()` and tells
///   `Db3ReadyEvent` once; a subscription attached to a db3 already live
///   waits the same way. (A world without the dep settles on `live`: the
///   frozen lifecycle worlds.)
/// - 13: a list that never applies rejects `DB3_READY_TIMEOUT` after the
///   subscription's `readyTimeout`, attached before `live` or after it; a
///   dispose ends the wait.
final class Db3IndexBarrierHermeticTests: XCTestCase {

    private static let id = "01JD5101BARR1ERXXXXXXXXXXX"

    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var settled = false
        var opens: [String] = []
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func readies() -> Int { with { $0.emitted.filter { $0 is Db3ReadyEvent }.count } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in with { $0.opens.append(id) } },
                knownPermission: { _ in .readWrite },
                isBound: { _ in true },
                syncMarks: { _ in Db3SyncMarks(cursor: 4, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false) },
                storedState: { _ in RecordLogStoredState(cursor: 4, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) },
                storedIds: { [Db3IndexBarrierHermeticTests.id] },
                indexesSettled: { [self] _ in with { $0.settled } }
            )
        }
    }

    private func make() -> (Db3Lifecycle, World) {
        let world = World()
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    private func outcome(_ result: Result<Void, Error>?) -> String {
        switch result {
        case nil: return "pending"
        case .success: return "resolved"
        case .failure(let error): return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    // MARK: - Behaviour 12

    func testReadyWaitsForTheIndexListAndAvailableDoesNot() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.available()
        try await eventually(description: "live") { handle.state.phase == .live }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(outcome(handle.readyResult), "pending", "the open's list is not applied")
        XCTAssertEqual(world.readies(), 0)

        world.with { $0.settled = true }
        lifecycle.indexesChanged(Self.id)
        try await handle.ready()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.readies(), 1)

        // Attached to a db3 already live: the same wait.
        world.with { $0.settled = false }
        let attached = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(outcome(attached.readyResult), "pending")
        world.with { $0.settled = true }
        lifecycle.indexesChanged(Self.id)
        try await attached.ready()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.readies(), 2, "one ready event per subscription")
        handle.dispose()
        attached.dispose()
    }

    // MARK: - Behaviour 13 (E9)

    func testAListThatNeverAppliesTimesOutBeforeAndAfterLiveAndADisposeEndsTheWait() async throws {
        let (lifecycle, world) = make()
        let before = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 0.4))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await eventually(description: "live") { before.state.phase == .live }
        let after = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 0.4))
        let disposed = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 0.4))
        disposed.dispose()
        try await eventually(timeout: 5, description: "both timed out") {
            before.readyResult != nil && after.readyResult != nil
        }
        XCTAssertEqual(outcome(before.readyResult), "DB3_READY_TIMEOUT", "attached before live")
        XCTAssertEqual(outcome(after.readyResult), "DB3_READY_TIMEOUT", "attached to a db3 already live")
        XCTAssertEqual(outcome(disposed.readyResult), "DB3_DISPOSED")
        XCTAssertEqual(world.readies(), 0)
        before.dispose()
        after.dispose()
    }
}
