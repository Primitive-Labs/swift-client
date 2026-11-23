import XCTest
@testable import JsBaoClient

/// #5044 — the lifecycle's identity release (`releaseAll`), over its deps:
///
/// - 7: every open of the previous user is retired at once and closed on the
///   socket exactly once, whether or not a subscription was made since; a
///   subscribe made during the release opens after that close on the same
///   chain, `releaseAll` returns without waiting for that open, a state read
///   while the close runs answers `resident: false`, and the unbind follows
///   the closes.
/// - 8: a reconcile queued before the release opens nothing ahead of its close,
///   nor does one that runs after the user changed but before the release began.
/// - 18: a second release begun while the new user's open waits at the
///   client's identity gate retires that open quietly (no error event, no
///   error kept, no close of an open that never happened); both releases
///   return and `destroy()` settles.
final class Db3IdentityReleaseHermeticTests: XCTestCase {

    private static let id = "01JD5044RE1EASEXXXXXXXXXXX"

    /// What the client would answer. Closes and opens can be held; a held open
    /// can be retired with `CancellationError`, as the client's identity gate
    /// retires one when a further release begins.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [String: Db3SyncMarks] = [:]
        private var opened: Set<String> = []
        private var _steps: [String] = []
        private var emitted: [any JsBaoEventPayload] = []
        private var closeHeld = false
        private var closeWaiters: [CheckedContinuation<Void, Never>] = []
        private var openHeld = false
        private var openWaiters: [CheckedContinuation<Void, Error>] = []

        static let residentMarks = Db3SyncMarks(cursor: 2, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false)

        var steps: [String] { lock.withLock { _steps } }
        var errorEvents: [Db3ErrorEvent] { lock.withLock { emitted.compactMap { $0 as? Db3ErrorEvent } } }
        func isBoundAndResident(_ id: String) -> Bool { lock.withLock { marks[id]?.resident ?? false } }
        func isOpened(_ id: String) -> Bool { lock.withLock { opened.contains(id) } }

        func bind(_ id: String) { lock.withLock { marks[id] = Self.residentMarks } }

        func holdCloses() { lock.withLock { closeHeld = true } }
        func releaseCloses() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                closeHeld = false
                defer { closeWaiters = [] }
                return closeWaiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func holdOpens() { lock.withLock { openHeld = true } }
        func releaseOpens() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                openHeld = false
                defer { openWaiters = [] }
                return openWaiters
            }
            for waiter in waiters { waiter.resume() }
        }

        /// A further release began: every open waiting at the gate is retired.
        func retireWaitingOpens() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { openWaiters = [] }
                return openWaiters
            }
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in lock.withLock { emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in
                    let held = lock.withLock { () -> Bool in
                        _steps.append("open")
                        return openHeld
                    }
                    if held {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            let parked = lock.withLock { () -> Bool in
                                guard openHeld else { return false }
                                openWaiters.append(continuation)
                                return true
                            }
                            if !parked { continuation.resume() }
                        }
                    }
                    lock.withLock {
                        opened.insert(id)
                        marks[id] = Self.residentMarks
                    }
                },
                close: { [self] id in
                    let held = lock.withLock { () -> Bool in
                        _steps.append("close")
                        return closeHeld
                    }
                    if held {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            let parked = lock.withLock { () -> Bool in
                                guard closeHeld else { return false }
                                closeWaiters.append(continuation)
                                return true
                            }
                            if !parked { continuation.resume() }
                        }
                    }
                    lock.withLock { _ = opened.remove(id) }
                },
                unbind: { [self] id in lock.withLock { marks[id] = nil } },
                isOpen: { [self] id in lock.withLock { opened.contains(id) } },
                isBound: { [self] id in lock.withLock { marks[id] != nil } },
                syncMarks: { [self] id in lock.withLock { marks[id] } },
                storedState: { [self] id in
                    lock.withLock { marks[id] == nil ? nil : RecordLogStoredState(cursor: 2, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) }
                },
                unbindAll: { [self] in
                    lock.withLock {
                        _steps.append("unbindAll")
                        marks = [:]
                    }
                }
            )
        }
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

    /// A lifecycle whose db3 is open for A's subscription.
    private func openForA() async throws -> (Db3Lifecycle, World, Db3Subscription) {
        let world = World()
        world.bind(Self.id)
        let lifecycle = Db3Lifecycle(deps: world.deps())
        let a = try subscribe(lifecycle)
        try await eventually(description: "A's open") { world.isOpened(Self.id) }
        return (lifecycle, world, a)
    }

    // MARK: - Behaviour 7

    func testTheOutgoingOpenIsClosedOnceAndTheNewSubscribeOpensAfterIt() async throws {
        let (lifecycle, world, a) = try await openForA()
        world.holdCloses()
        lifecycle.forgetStates()
        let release = Task { await lifecycle.releaseAll(unbind: true) }
        try await eventually(description: "the outgoing close") { world.steps.contains("close") }
        let aReason = await reason(a)
        XCTAssertEqual(aReason, "identity-changed")

        // The previous user's binding is still there, and answers no state as resident.
        XCTAssertTrue(world.isBoundAndResident(Self.id))
        let during = try await lifecycle.state(Self.id)
        XCTAssertFalse(during.resident, "a binding being released is not resident")

        world.holdOpens()
        let b = try subscribe(lifecycle)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(b.availableResult, "B never reads the outgoing binding")

        world.releaseCloses()
        try await settles(within: 5, "releaseAll") { await release.value }
        try await eventually(description: "B's open") { world.steps.filter { $0 == "open" }.count == 2 }
        XCTAssertNil(b.availableResult, "releaseAll returned while B's open is still held")

        let steps = world.steps
        XCTAssertEqual(steps.filter { $0 == "close" }.count, 1, "closed exactly once: \(steps)")
        let close = try XCTUnwrap(steps.firstIndex(of: "close"))
        XCTAssertLessThan(close, try XCTUnwrap(steps.lastIndex(of: "open")), "B's open follows the close: \(steps)")
        XCTAssertLessThan(close, try XCTUnwrap(steps.firstIndex(of: "unbindAll")), "the unbind follows the close: \(steps)")

        world.releaseOpens()
        try await settles(within: 5, "B's available()") { try await b.available() }
        let after = try await lifecycle.state(Self.id)
        XCTAssertTrue(after.resident)
        b.dispose()
    }

    // MARK: - Behaviour 8

    func testAReconcileQueuedBeforeTheReleaseOpensNothingAheadOfItsClose() async throws {
        let (lifecycle, world, a) = try await openForA()
        // In one turn: A disposes, the user changes, B subscribes.
        a.dispose()
        lifecycle.forgetStates()
        let release = Task { await lifecycle.releaseAll(unbind: false) }
        let b = try subscribe(lifecycle)
        try await settles(within: 5, "releaseAll") { await release.value }
        try await eventually(description: "B's open") { world.steps.filter { $0 == "open" }.count == 2 }
        XCTAssertEqual(world.steps, ["open", "close", "open"])
        try await settles(within: 5, "B's available()") { try await b.available() }
        b.dispose()
    }

    func testASubscribeMadeBeforeTheReleaseBeginsOpensOnlyAfterIt() async throws {
        let (lifecycle, world, a) = try await openForA()
        a.dispose()
        try await eventually(description: "A's close") { world.steps == ["open", "close"] }
        // The user changed and B subscribed, but the release has not begun:
        // B's reconcile runs in that gap, as it may on another thread.
        lifecycle.forgetStates()
        let b = try subscribe(lifecycle)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(world.steps, ["open", "close"], "nothing opens before the release")

        try await settles(within: 5, "releaseAll") { await lifecycle.releaseAll(unbind: false) }
        try await eventually(description: "B's open") { world.steps.count >= 3 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.steps, ["open", "close", "open"])
        try await settles(within: 5, "B's available()") { try await b.available() }
        b.dispose()
    }

    // MARK: - Behaviour 18

    func testASecondReleaseRetiresTheOpenWaitingAtTheGateQuietly() async throws {
        let (lifecycle, world, _) = try await openForA()
        world.holdCloses()
        world.holdOpens()
        lifecycle.forgetStates()
        let first = Task { await lifecycle.releaseAll(unbind: true) }
        try await eventually(description: "the outgoing close") { world.steps.contains("close") }
        let b = try subscribe(lifecycle)
        world.releaseCloses()
        try await settles(within: 5, "the first release") { await first.value }
        try await eventually(description: "B's open at the gate") { world.steps.filter { $0 == "open" }.count == 2 }

        // A sign-out while B's open waits: the gate retires it.
        world.retireWaitingOpens()
        lifecycle.forgetStates()
        try await settles(within: 5, "the second release") { await lifecycle.releaseAll(unbind: true) }
        let bReason = await reason(b)
        XCTAssertEqual(bReason, "identity-changed")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(world.steps.filter { $0 == "close" }.count, 1, "an open that never happened is not closed: \(world.steps)")
        XCTAssertTrue(world.errorEvents.isEmpty, "a retired open is no error: \(world.errorEvents)")
        let state = try await lifecycle.state(Self.id)
        XCTAssertNil(state.error)
        try await settles(within: 5, "destroy") { await lifecycle.destroy() }
    }
}
