import XCTest
@testable import JsBaoClient

/// #4701 behaviours 12 and 13, edges 39 and 46 — the db3 lifecycle's rules,
/// over its deps (the seam js-bao's `Db3LifecycleDeps` is): nothing of the
/// platform is faked, the world below answers what the client would.
///
/// - 12: the phase (`gone` on a refused store, the session's status while open
///   for a handle, `idle` unsubscribed, `opening` / `reconnecting` by the
///   socket), progress only while loading or catching up, no snapshot emitted
///   twice, and the idle snapshot of an id never seen.
/// - 13: how a handle settles — `available` at once when resident, `ready`'s
///   budget re-armed by progress, `.infinity` and `0`, dispose, re-awaiting,
///   destroy, and `NOT_A_DB3` with nothing opened.
/// - 39: a client on `.memory` storage: the handle rejects
///   `FORMAT2_STORAGE_UNAVAILABLE`, `stored()` is empty.
/// - 46: a change heard while the state is being read is read once more.
final class Db3LifecycleHermeticTests: XCTestCase {

    private static let id = "01JD4701L1FECYC1EXXXXXXXXX"

    /// What the client would answer the lifecycle.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var marks: Db3SyncMarks? = Db3SyncMarks(cursor: 4, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false)
        var stored: RecordLogStoredState? = RecordLogStoredState(cursor: 4, rows: 2, writers: [], replacing: false, lastCatchUpAt: 1_000)
        var socket = true
        var format: Int? = 3
        var storageRefusal: JsBaoError?
        var opens: [String] = []
        var closes: [String] = []
        /// A document door holds the db3 open (`documents.open`).
        var doorOpen = false
        /// What a removal of the store did, in order.
        var steps: [String] = []
        var emitted: [any JsBaoEventPayload] = []
        var reads = 0
        /// Held reads wait here until it opens.
        var readGate: RecordLogReceiptHarness.Gate?

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func states(_ id: String = Db3LifecycleHermeticTests.id) -> [Db3State] {
            with { $0.emitted.compactMap { ($0 as? Db3StateEvent)?.state }.filter { $0.id == id } }
        }

        func events<E: JsBaoEventPayload>(_ type: E.Type) -> [E] { with { $0.emitted.compactMap { $0 as? E } } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { [self] in with { $0.socket } },
                resolveFormat: { [self] _ in with { $0.format } },
                storageRefusal: { [self] _ in with { $0.storageRefusal } },
                open: { [self] id in with { $0.opens.append(id) } },
                close: { [self] id in
                    with {
                        $0.closes.append(id)
                        $0.doorOpen = false
                        $0.steps.append("close")
                    }
                },
                unbind: { [self] _ in with { $0.steps.append("unbind") } },
                isOpen: { [self] _ in with { $0.doorOpen } },
                knownPermission: { _ in .readWrite },
                isBound: { [self] _ in with { $0.marks != nil } },
                syncMarks: { [self] _ in with { $0.marks } },
                storedState: { [self] _ in
                    let gate = with { world -> RecordLogReceiptHarness.Gate? in
                        world.reads += 1
                        return world.readGate
                    }
                    if let gate { await gate.wait() }
                    return with { $0.stored }
                },
                storedIds: { [self] in with { $0.stored == nil ? [] : [Db3LifecycleHermeticTests.id] } },
                purge: { [self] _, _ in
                    with { $0.steps.append("purge") }
                    return Db3PurgeOutcome(purged: true)
                }
            )
        }
    }

    private func make(_ configure: (World) -> Void = { _ in }) -> (Db3Lifecycle, World) {
        let world = World()
        world.with(configure)
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    private func outcome(_ result: Result<Void, Error>?) -> String {
        switch result {
        case nil: return "pending"
        case .success: return "resolved"
        case .failure(let error): return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    // MARK: - Behaviour 12: the state rules

    func testAnUnseenIdAnswersTheIdleSnapshot() async throws {
        let emitted = ThreadSafeBox<Int>(0)
        let lifecycle = Db3Lifecycle(deps: Db3LifecycleDeps(emit: { _ in emitted.mutate { $0 += 1 } }))
        let state = try await lifecycle.state("01JD4701NEVERSEENXXXXXXXXX")
        XCTAssertEqual(state, Db3State(
            id: "01JD4701NEVERSEENXXXXXXXXX", resident: false, subscribed: false, phase: .idle, progress: nil,
            cursor: 0, rows: 0, lastSyncAt: nil, pendingWrites: 0, permission: nil, error: nil
        ))
        XCTAssertEqual(emitted.value, 0, "asking a state emits nothing")
    }

    func testAResidentUnsubscribedDb3IsIdleAndARefusedOneIsGone() async throws {
        let (lifecycle, world) = make()
        var state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.resident)
        XCTAssertEqual(state.rows, 2)
        XCTAssertEqual(state.cursor, 4)
        XCTAssertEqual(state.lastSyncAt, Date(timeIntervalSince1970: 1))
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .refused)
        XCTAssertEqual(state.error?.code, "DB3_ACCESS_REFUSED")
        world.with { $0.marks?.permission = RecordLogPermission.read }
        do {
            let got = try await lifecycle.state(Self.id).permission
            XCTAssertEqual(got, .reader)
        }
    }

    func testTheSessionsStatusWhileOpenThenOpeningAndReconnectingByTheSocket() async throws {
        let (lifecycle, world) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        try await eventually(description: "opening") { handle.state.phase == .opening }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(
            phase: .loading, progress: RecordLogSessionProgress(done: 1, total: 4, unit: .chunks)
        ))
        XCTAssertEqual(handle.state.phase, .loading)
        XCTAssertEqual(handle.state.progress, Db3Progress(done: 1, total: 4, unit: .chunks))
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .idle))
        world.with { $0.socket = false }
        lifecycle.connectionChanged()
        try await eventually(description: "reconnecting") { handle.state.phase == .reconnecting }
        XCTAssertNil(handle.state.progress)
        world.with { $0.socket = true }
        lifecycle.connectionChanged()
        try await eventually(description: "opening again") { handle.state.phase == .opening }
        world.with { $0.marks?.lastCatchUpAt = 2_000; $0.stored?.lastCatchUpAt = 2_000 }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        XCTAssertEqual(handle.state.phase, .live)
        handle.dispose()
        try await eventually(description: "idle after the dispose") { world.states().last?.phase == .idle }
        XCTAssertEqual(world.with { $0.closes }, [Self.id])
        let states = world.states()
        for state in states where state.phase != .loading && state.phase != .catchingUp {
            XCTAssertNil(state.progress, "\(state)")
        }
        for (a, b) in zip(states, states.dropFirst()) { XCTAssertNotEqual(a, b, "a state emitted twice") }
        XCTAssertEqual(states.last?.subscribed, false)
        XCTAssertEqual(world.events(Db3ReadyEvent.self).map(\.id), [Self.id])
    }

    func testANoticeThatChangesNothingEmitsNothing() async throws {
        let (lifecycle, world) = make()
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "the first state") { world.states().count == 1 }
        lifecycle.pendingChanged(Self.id)
        lifecycle.pendingChanged(Self.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(world.states().count, 1)
        world.with { $0.stored?.writers = [.init(writer: "w", clientId: "c", nextSeq: 2, lowestPending: 1, pending: 1)] }
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "the pending write") { world.states().last?.pendingWrites == 1 }
        XCTAssertEqual(world.states().count, 2)
    }

    // MARK: - Behaviour 13: how a handle settles

    func testAvailableAtOnceWhenResidentAndReadyRejectsAtItsBudget() async throws {
        let (lifecycle, _) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 0.2))
        try await eventually(timeout: 1, description: "available") { handle.availableResult != nil }
        XCTAssertEqual(outcome(handle.availableResult), "resolved")
        let started = Date()
        let readyCode = await code { try await handle.ready() }
        XCTAssertEqual(readyCode, "DB3_READY_TIMEOUT")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
        // Settled once: every later await answers the same.
        do {
            let got = await code { try await handle.ready() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        do {
            let got = await code { try await handle.available() }
            XCTAssertEqual(got, "resolved")
        }
        handle.dispose()
    }

    func testProgressReArmsTheBudgetAndAnUnloadedDb3IsNotAvailable() async throws {
        let (lifecycle, world) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        // Steps 0.25 s apart under a 1 s budget: eight steps run twice the
        // budget, so only a re-armed wait is still pending at the end, and each
        // gap leaves 0.75 s of slack. A 0.3 s budget with 0.15 s steps left
        // 0.15 s, which a loaded fleet worker overran (DB3_READY_TIMEOUT).
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 1.0))
        for step in 0..<8 {
            try await Task.sleep(nanoseconds: 250_000_000)
            lifecycle.statusChanged(Self.id, RecordLogSessionStatus(
                phase: .loading, progress: RecordLogSessionProgress(done: step, total: 8, unit: .chunks)
            ))
        }
        XCTAssertEqual(outcome(handle.readyResult), "pending", "each step started the wait again")
        XCTAssertEqual(outcome(handle.availableResult), "pending", "not resident yet")
        world.with { $0.marks?.lastCatchUpAt = 5; $0.stored?.lastCatchUpAt = 5 }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        try await handle.available()
        handle.dispose()
    }

    func testInfinityNeverTimesOutAndZeroTimesOutAtOnceUnlessLive() async throws {
        let (lifecycle, _) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        let forever = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let zero = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 0))
        do {
            let got = await code { try await zero.ready() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(outcome(forever.readyResult), "pending")
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await forever.ready()
        let instant = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 0))
        try await instant.ready()
        lifecycle.unsubscribe(Self.id)
        XCTAssertEqual(outcome(zero.readyResult), "DB3_READY_TIMEOUT")
    }

    func testADisposedHandleRejectsWhileTheOtherResolvesAndDisposeIsIdempotent() async throws {
        let (lifecycle, world) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        let first = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let second = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        first.dispose()
        first.dispose()
        do {
            let got = await code { try await first.ready() }
            XCTAssertEqual(got, "DB3_DISPOSED")
        }
        do {
            let got = await code { try await first.available() }
            XCTAssertEqual(got, "DB3_DISPOSED")
        }
        try await eventually(description: "one open") { world.with { $0.opens }.count == 1 }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await second.ready()
        XCTAssertEqual(world.with { $0.closes }, [], "the second handle keeps it open")
        do {
            let got = await code { try await first.ready() }
            XCTAssertEqual(got, "DB3_DISPOSED")
        }
        second.dispose()
        try await eventually(description: "the close") { world.with { $0.closes } == [Self.id] }
        XCTAssertEqual(world.with { $0.opens }.count, 1)
    }

    func testADestroyedLifecycleRejectsEveryHandleAndRefusesASubscribe() async throws {
        let (lifecycle, _) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        let pending = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        await lifecycle.destroy()
        do {
            let got = await code { try await pending.ready() }
            XCTAssertEqual(got, "DB3_DISPOSED")
        }
        XCTAssertThrowsError(try lifecycle.subscribe(Self.id)) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .db3Disposed)
        }
        XCTAssertThrowsError(try lifecycle.subscribe("")) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .db3Disposed)
        }
        let (fresh, _) = make()
        XCTAssertThrowsError(try fresh.subscribe("")) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
    }

    func testAFormatOneDocumentIsNotADb3AndNothingIsOpened() async throws {
        let (lifecycle, world) = make { $0.marks = nil; $0.stored = nil; $0.format = 1 }
        let handle = try lifecycle.subscribe(Self.id)
        do {
            let got = await code { try await handle.ready() }
            XCTAssertEqual(got, "NOT_A_DB3")
        }
        do {
            let got = await code { try await handle.available() }
            XCTAssertEqual(got, "NOT_A_DB3")
        }
        XCTAssertEqual(world.with { $0.opens }, [])
        let error = try XCTUnwrap(handle.readyResult.flatMap { result -> JsBaoError? in
            if case .failure(let error) = result { return error as? JsBaoError }
            return nil
        })
        XCTAssertEqual(error.details?["documentFormat"], .number(1))
    }

    func testAHandleHearsOnlyItsOwnDb3() async throws {
        let other = "01JD4701OTHERXXXXXXXXXXXXX"
        let (lifecycle, _) = make()
        let mine = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let theirs = try lifecycle.subscribe(other, options: Db3SubscribeOptions(readyTimeout: .infinity))
        let heard = ThreadSafeBox<[String]>([])
        let observation = mine.observe { event in
            if case .state(let state) = event { heard.mutate { $0.append(state.id) } }
        }
        let streamed = Task { () -> [String] in
            var ids: [String] = []
            for await event in mine.stream() {
                if case .ready(let ready) = event { ids.append(ready.id); break }
            }
            return ids
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        lifecycle.statusChanged(other, RecordLogSessionStatus(phase: .live))
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await mine.ready()
        try await theirs.ready()
        do {
            let got = await streamed.value
            XCTAssertEqual(got, [Self.id])
        }
        try await eventually(description: "a state") { !heard.value.isEmpty }
        XCTAssertEqual(Set(heard.value), [Self.id])
        observation.cancel()
        mine.dispose()
        theirs.dispose()
    }

    // MARK: - An eviction ends a door's open (finding 4701-C01)

    func testAnEvictionClosesADoorsOpenBeforeItUnbindsAndPurges() async throws {
        let (lifecycle, world) = make { $0.doorOpen = true }
        lifecycle.openedByDoor(Self.id)
        try await lifecycle.evict(Self.id, options: Db3EvictOptions(force: true))
        XCTAssertEqual(world.with { $0.steps }, ["close", "unbind", "purge"], "the door's open is closed on the socket first")
        XCTAssertFalse(world.with { $0.doorOpen })
        XCTAssertEqual(world.events(Db3EvictedEvent.self).map(\.reason), [.explicit])

        // Not open anywhere: nothing to close.
        let (quiet, untouched) = make()
        try await quiet.evict(Self.id, options: Db3EvictOptions(force: true))
        XCTAssertEqual(untouched.with { $0.steps }, ["unbind", "purge"])
    }

    // MARK: - A refusal remembered by the store (finding 4701-C04)

    func testARefusalTheStoreRemembersIsToldButOnlyTheRoomsAnswerRejectsASubscription() async throws {
        // A new client over a store a refusal marked: the room has since restored access.
        let (lifecycle, world) = make { $0.marks?.permission = RecordLogPermission.refused }
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the remembered refusal told") { world.events(Db3GoneEvent.self).count == 1 }
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(outcome(handle.readyResult), "pending", "the room has not answered this subscription yet")
        // The own writer's record.opened lifted the mark.
        world.with { $0.marks?.permission = nil }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        XCTAssertEqual(handle.state.phase, .live)
        XCTAssertEqual(world.events(Db3GoneEvent.self).count, 1)
        handle.dispose()

        // Still refused: the room's answer rejects the subscription.
        let (refused, refusedWorld) = make { $0.marks?.permission = RecordLogPermission.refused }
        let waiting = try refused.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { refusedWorld.with { $0.opens } == [Self.id] }
        try await eventually(description: "gone told") { refusedWorld.events(Db3GoneEvent.self).count == 1 }
        XCTAssertEqual(outcome(waiting.readyResult), "pending")
        refused.syncFailed(Self.id, "ACCESS_DENIED")
        do {
            let got = await code { try await waiting.ready() }
            XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        }
        XCTAssertEqual(refusedWorld.events(Db3GoneEvent.self).count, 1)
        waiting.dispose()
    }

    func testARefusalHeardFromTheRoomRejectsAPendingSubscriptionInEitherOrder() async throws {
        // The refusal reported before the state read sees the mark.
        let (first, firstWorld) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        let early = try first.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { firstWorld.with { $0.opens } == [Self.id] }
        firstWorld.with { $0.marks?.permission = RecordLogPermission.refused }
        first.syncFailed(Self.id, "ACCESS_DENIED")
        do {
            let got = await code { try await early.ready() }
            XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        }
        XCTAssertEqual(firstWorld.events(Db3GoneEvent.self).count, 1)
        early.dispose()

        // The state read sees the mark before the refusal is reported.
        let (second, secondWorld) = make { $0.marks?.lastCatchUpAt = nil; $0.stored?.lastCatchUpAt = nil }
        let late = try second.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { secondWorld.with { $0.opens } == [Self.id] }
        secondWorld.with { $0.marks?.permission = RecordLogPermission.refused }
        second.pendingChanged(Self.id)
        try await eventually(description: "gone") { secondWorld.events(Db3GoneEvent.self).count == 1 }
        second.syncFailed(Self.id, "ACCESS_DENIED")
        do {
            let got = await code { try await late.ready() }
            XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        }
        late.dispose()
    }

    // MARK: - Edge 46: a change heard mid-read is read once more

    func testAChangeHeardWhileTheStateIsReadIsReadOnceMore() async throws {
        let gate = RecordLogReceiptHarness.Gate()
        let (lifecycle, world) = make { $0.readGate = gate }
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "the read to start") { world.with { $0.reads } == 1 }
        world.with { $0.stored?.rows = 7 }
        lifecycle.pendingChanged(Self.id)
        lifecycle.pendingChanged(Self.id)
        world.with { $0.readGate = nil }
        gate.open()
        try await eventually(description: "the last read") { world.states().last?.rows == 7 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(world.with { $0.reads }, 2, "one read, then one more for what was heard during it")
    }

    // MARK: - Edge 39: storage that cannot hold a db3

    func testAMemoryClientsHandleRejectsTheStorageAndStoresNothing() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-memory-4701",
            token: makeTestJwt(userId: "db3-memory-user"), offline: true, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        let handle = try client.db3.subscribe(Self.id)
        do {
            let got = await code { try await handle.ready() }
            XCTAssertEqual(got, "FORMAT2_STORAGE_UNAVAILABLE")
        }
        do {
            let got = await code { try await handle.available() }
            XCTAssertEqual(got, "FORMAT2_STORAGE_UNAVAILABLE")
        }
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored, [])
        handle.dispose()
        await client.destroy()
    }
}
