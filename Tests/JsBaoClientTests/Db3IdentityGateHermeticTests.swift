import XCTest
@testable import JsBaoClient

/// #5044 — the client's identity gate (`Db3IdentityRelease`) with the
/// lifecycle's opens waiting at it, as the client wires them:
///
/// - an open the outgoing user started (a subscribe made while a sign-out's
///   cleanup runs ahead of `forgetStates()`) is retired at the gate once the
///   user changes, so the release, whose close would queue behind it, settles;
/// - the new user's open, made after the release, waits at the gate and goes
///   ahead when the change ends;
/// - a waiter is checked and registered in one hold: an outgoing one arriving
///   after the change is refused, and a further change retires every waiter.
final class Db3IdentityGateHermeticTests: XCTestCase {

    private static let id = "01JD5044GATEXXXXXXXXXXXXXX"

    private struct Unexpected: Error {}

    /// What the client would answer; its open waits at a real identity gate
    /// with the identity the lifecycle started the open under.
    final class World: @unchecked Sendable {
        let gate = Db3IdentityRelease()
        weak var lifecycle: Db3Lifecycle?
        private let lock = NSLock()
        private var marks: [String: Db3SyncMarks] = [:]
        private var opened: Set<String> = []
        private var _steps: [String] = []
        private var emitted: [any JsBaoEventPayload] = []

        var steps: [String] { lock.withLock { _steps } }
        var errorEvents: [Db3ErrorEvent] { lock.withLock { emitted.compactMap { $0 as? Db3ErrorEvent } } }
        func isOpened(_ id: String) -> Bool { lock.withLock { opened.contains(id) } }

        func bind(_ id: String) {
            lock.withLock { marks[id] = Db3SyncMarks(cursor: 2, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false) }
        }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in lock.withLock { emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in
                    try await gate.wait(openedUnder: lifecycle?.openIdentity(id))
                    bind(id)
                    lock.withLock {
                        _steps.append("open")
                        opened.insert(id)
                    }
                },
                close: { [self] id in
                    lock.withLock {
                        _steps.append("close")
                        _ = opened.remove(id)
                    }
                },
                unbind: { [self] id in lock.withLock { marks[id] = nil } },
                isOpen: { [self] id in lock.withLock { opened.contains(id) } },
                isBound: { [self] id in lock.withLock { marks[id] != nil } },
                syncMarks: { [self] id in lock.withLock { marks[id] } },
                storedState: { [self] id in
                    lock.withLock { marks[id] == nil ? nil : RecordLogStoredState(cursor: 2, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) }
                },
                unbindAll: { [self] in lock.withLock { marks = [:] } }
            )
        }
    }

    private func world() -> (Db3Lifecycle, World) {
        let world = World()
        world.bind(Self.id)
        let lifecycle = Db3Lifecycle(deps: world.deps())
        world.lifecycle = lifecycle
        return (lifecycle, world)
    }

    private func subscribe(_ lifecycle: Db3Lifecycle) throws -> Db3Subscription {
        try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
    }

    private func reason(_ subscription: Db3Subscription) async -> String? {
        do {
            try await subscription.ready()
            return nil
        } catch {
            return (error as? JsBaoError)?.details?["reason"]?.stringValue ?? "\(error)"
        }
    }

    private func retired(_ task: Task<Void, Error>, _ what: String) async throws {
        try await settles(within: 5, what) {
            do {
                try await task.value
            } catch is CancellationError {
                return
            }
            throw Unexpected()
        }
    }

    // MARK: - The lifecycle at the gate

    func testAnOpenTheOutgoingUserStartedIsRetiredAtTheGateAndTheReleaseSettles() async throws {
        let (lifecycle, world) = world()
        // A sign-out began and its cleanup is suspended before `forgetStates()`.
        let change = world.gate.begin(releasing: [Self.id])
        let a = try subscribe(lifecycle)
        try await eventually(description: "A's open at the gate") { world.gate.waiting == 1 }

        world.gate.retire(below: lifecycle.forgetStates())
        try await settles(within: 5, "releaseAll") { await lifecycle.releaseAll(unbind: true) }
        let aReason = await reason(a)
        XCTAssertEqual(aReason, "identity-changed")
        world.gate.end(change)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(world.steps, [], "nothing opened for the outgoing user, and nothing closed")
        XCTAssertTrue(world.errorEvents.isEmpty, "a retired open is no error: \(world.errorEvents)")
        let state = try await lifecycle.state(Self.id)
        XCTAssertNil(state.error)
        try await settles(within: 5, "destroy") { await lifecycle.destroy() }
    }

    func testTheNewUsersOpenWaitsAtTheGateAndGoesAheadWhenTheChangeEnds() async throws {
        let (lifecycle, world) = world()
        let a = try subscribe(lifecycle)
        try await eventually(description: "A's open") { world.isOpened(Self.id) }

        let change = world.gate.begin(releasing: [Self.id])
        world.gate.retire(below: lifecycle.forgetStates())
        try await settles(within: 5, "releaseAll") { await lifecycle.releaseAll(unbind: true) }
        let aReason = await reason(a)
        XCTAssertEqual(aReason, "identity-changed")

        let b = try subscribe(lifecycle)
        try await eventually(description: "B's open at the gate") { world.gate.waiting == 1 }
        XCTAssertNil(b.availableResult, "B's open waits for the change")

        world.gate.end(change)
        try await settles(within: 5, "B's available()") { try await b.available() }
        XCTAssertEqual(world.steps, ["open", "close", "open"])
        b.dispose()
        try await settles(within: 5, "destroy") { await lifecycle.destroy() }
    }

    // MARK: - The gate

    func testAWaiterTheOutgoingUserStartedIsRetiredAndTheNewOnesGoAhead() async throws {
        let gate = Db3IdentityRelease()
        let change = gate.begin(releasing: [])
        let outgoing = Task { try await gate.wait(openedUnder: 0) }
        let incoming = Task { try await gate.wait(openedUnder: 1) }
        let bind = Task { try await gate.wait() }
        try await eventually(description: "three waiters") { gate.waiting == 3 }

        gate.retire(below: 1)
        try await retired(outgoing, "the outgoing waiter")
        XCTAssertEqual(gate.waiting, 2)

        gate.end(change)
        try await settles(within: 5, "the new user's waiter") { try await incoming.value }
        try await settles(within: 5, "the bind's waiter") { try await bind.value }
    }

    func testAnOutgoingWaiterArrivingAfterTheUserChangedIsRefused() async throws {
        let gate = Db3IdentityRelease()
        let change = gate.begin(releasing: [])
        gate.retire(below: 1)
        try await retired(Task { try await gate.wait(openedUnder: 0) }, "the late outgoing waiter")
        XCTAssertEqual(gate.waiting, 0)
        gate.end(change)
    }

    func testAFurtherChangeRetiresEveryWaiter() async throws {
        let gate = Db3IdentityRelease()
        let first = gate.begin(releasing: [])
        let waiter = Task { try await gate.wait(openedUnder: 0) }
        try await eventually(description: "the waiter") { gate.waiting == 1 }

        let second = gate.begin(releasing: [])
        try await retired(waiter, "the waiter of the first change")
        gate.end(first)
        gate.end(second)
        try await settles(within: 5, "a wait with no change in progress") { try await gate.wait(openedUnder: 0) }
    }
}
