import XCTest
@testable import JsBaoClient

/// #5101 behaviours 10 and 11 (edges E8, E13, E14) — a db3's index-list
/// reads on the Swift client, the port of js-bao's `Db3IndexRefresher`
/// (#5070), over a world whose reads and timers the test answers.
///
/// - 10: reads apply in the order they were accepted per binding, a read of
///   an earlier binding applies nothing, a read resolves once its list or a
///   later one is in the store; a failed read is owed and asked again on a
///   backoff (1 s doubling to 10 s) while bound and the socket is up, not
///   while it is down; an owed list is read again at `socketOpened` (the
///   socket's open and the return of networking); a final 4xx is not retried
///   on the backoff, a 408 and a 429 are.
/// - 11: `settled` is false while a list is on its way or the open's
///   declaration is awaited; the declaration timer never ends a wait whose
///   declaration is still expected; a store turned read-only releases it; a
///   reopen reads the list again; `openFailed` and `destroy`.
final class RecordLogIndexRefresherHermeticTests: XCTestCase {

    private static let id = "01JD5101REFRESHERXXXXXXXXX"

    private static func entry(_ field: String) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: "idx_\(field)", model: "Note", fields: [field], unique: false)
    }

    /// A read the test answers.
    final class Read: @unchecked Sendable {
        let documentId: String
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[RecordLogIndexEntry], Error>?
        private var answer: Result<[RecordLogIndexEntry], Error>?

        init(_ documentId: String) { self.documentId = documentId }

        func wait() async throws -> [RecordLogIndexEntry] {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<[RecordLogIndexEntry], Error>? in
                    if let answer { return answer }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }

        func answer(_ result: Result<[RecordLogIndexEntry], Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<[RecordLogIndexEntry], Error>? in
                answer = result
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }

    /// A timer the test fires.
    final class Timer: RecordLogIndexTimer, @unchecked Sendable {
        let delay: TimeInterval
        let fire: @Sendable () -> Void
        private let lock = NSLock()
        private var _cancelled = false
        private var _fired = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        var live: Bool { lock.withLock { !_cancelled && !_fired } }

        init(_ delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.fire = fire
        }

        func cancel() { lock.withLock { _cancelled = true } }

        func run() {
            guard lock.withLock({ () -> Bool in
                guard !_cancelled, !_fired else { return false }
                _fired = true
                return true
            }) else { return }
            fire()
        }
    }

    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var reads: [Read] = []
        var applied: [[RecordLogIndexEntry]] = []
        var applyGate: RecordLogReceiptHarness.Gate?
        var timers: [Timer] = []
        var outcomes: [RecordLogIndexOutcome] = []
        var bound = true
        var socket = true
        var declares = true

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func read(_ n: Int) -> Read { with { $0.reads[n] } }
        var readCount: Int { with { $0.reads.count } }
        /// The delays of the timers still to fire.
        var pending: [TimeInterval] { with { $0.timers.filter(\.live).map(\.delay) } }
        func timer(_ delay: TimeInterval) -> Timer? { with { $0.timers.last { $0.live && $0.delay == delay } } }

        func deps() -> RecordLogIndexRefresherDeps {
            RecordLogIndexRefresherDeps(
                read: { [self] id in
                    let read = Read(id)
                    with { $0.reads.append(read) }
                    return try await read.wait()
                },
                apply: { [self] _, entries, whileLatest in
                    if let gate = with({ $0.applyGate }) { await gate.wait() }
                    _ = try whileLatest { with { $0.applied.append(entries) } }
                },
                bound: { [self] _ in with { $0.bound } },
                socketUp: { [self] in with { $0.socket } },
                declares: { [self] _ in with { $0.declares } },
                settled: { [self] _, outcome in with { $0.outcomes.append(outcome) } },
                setTimer: { [self] delay, fire in
                    let timer = Timer(delay, fire)
                    with { $0.timers.append(timer) }
                    return timer
                }
            )
        }
    }

    private func make(_ configure: (World) -> Void = { _ in }) -> (RecordLogIndexRefresher, World) {
        let world = World()
        world.with(configure)
        return (RecordLogIndexRefresher(deps: world.deps()), world)
    }

    private func failure(_ status: Int) -> HttpError { HttpError(status: status, message: "HTTP \(status)") }

    /// Start a refresh in a task; answers its outcome once it settles.
    private func refreshing(_ refresher: RecordLogIndexRefresher) -> Task<String, Never> {
        Task {
            do {
                try await refresher.refresh(Self.id)
                return "resolved"
            } catch {
                return (error as? HttpError).map { "\($0.status)" } ?? "\(error)"
            }
        }
    }

    // MARK: - Behaviour 10: order, binding, owed and retried

    func testReadsApplyInTheOrderAcceptedAndALateEarlierReadIsDropped() async throws {
        let (refresher, world) = make()
        let first = refreshing(refresher)
        try await eventually(description: "the first read") { world.readCount == 1 }
        let second = refreshing(refresher)
        try await eventually(description: "the second read") { world.readCount == 2 }
        world.read(1).answer(.success([Self.entry("slug")]))
        try await eventually(description: "the later list applied") { world.with { $0.applied.count } == 1 }
        world.read(0).answer(.success([Self.entry("title")]))
        let answers = [await first.value, await second.value]
        XCTAssertEqual(answers, ["resolved", "resolved"], "each read resolves once a list at least as recent is in the store")
        XCTAssertEqual(world.with { $0.applied }, [[Self.entry("slug")]], "the earlier read answered late is dropped")
        XCTAssertTrue(refresher.settled(Self.id))
    }

    func testARebindDropsEveryReadInFlight() async throws {
        let (refresher, world) = make()
        let ok = refreshing(refresher)
        let bad = refreshing(refresher)
        try await eventually(description: "the reads") { world.readCount == 2 }
        refresher.rebind(Self.id)
        world.read(0).answer(.success([Self.entry("title")]))
        world.read(1).answer(.failure(failure(500)))
        _ = await ok.value
        _ = await bad.value
        XCTAssertEqual(world.with { $0.applied }, [], "a read of the earlier binding applies nothing")
        XCTAssertFalse(refresher.owed(Self.id), "nor is it owed")
        XCTAssertEqual(world.pending, [], "nor retried")
        XCTAssertTrue(refresher.settled(Self.id), "nothing was read for the new binding")
    }

    func testAFailedReadIsOwedAndRetriedOnABackoffWhileBoundAndUp() async throws {
        let (refresher, world) = make()
        let first = refreshing(refresher)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.failure(failure(500)))
        let got = await first.value
        XCTAssertEqual(got, "500", "the refresh throws the failure")
        XCTAssertTrue(refresher.owed(Self.id))
        XCTAssertFalse(refresher.settled(Self.id))
        var delays: [TimeInterval] = []
        for n in 1...6 {
            try await eventually(description: "retry \(n)") { !world.pending.isEmpty }
            delays.append(contentsOf: world.pending)
            world.with { $0.timers.first(where: \.live) }?.run()
            try await eventually(description: "read \(n + 1)") { world.readCount == n + 1 }
            world.read(n).answer(.failure(failure(503)))
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 10, 10])
        // The seventh retry is answered: the list is applied and no longer owed.
        try await eventually(description: "retry 7") { !world.pending.isEmpty }
        world.with { $0.timers.first(where: \.live) }?.run()
        try await eventually(description: "read 8") { world.readCount == 8 }
        world.read(7).answer(.success([Self.entry("title")]))
        // `settled` answers true as the application ends, just before it is told.
        try await eventually(description: "applied") { world.with { $0.outcomes }.last == .applied }
        XCTAssertTrue(refresher.settled(Self.id))
        XCTAssertFalse(refresher.owed(Self.id))
        XCTAssertEqual(world.pending, [])
    }

    func testAFailureWithTheSocketDownSchedulesNoRetryAndIsReadAgainAtTheSocketsOpen() async throws {
        let (refresher, world) = make { $0.socket = false }
        let first = refreshing(refresher)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.failure(failure(500)))
        _ = await first.value
        XCTAssertEqual(world.pending, [], "no retry while the socket is down")
        XCTAssertEqual(world.with { $0.outcomes }, [.failed])
        XCTAssertTrue(refresher.owed(Self.id))

        // The socket's open, or networking allowed again (the same routine): read again at once.
        world.with { $0.socket = true }
        refresher.socketOpened()
        try await eventually(description: "read again") { world.readCount == 2 }
        refresher.socketOpened()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.readCount, 2, "a list being read is not asked for twice")
        world.read(1).answer(.success([Self.entry("title")]))
        try await eventually(description: "applied") { refresher.settled(Self.id) }
        refresher.socketOpened()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.readCount, 2, "a list not owed is not read again")
    }

    func testAFinalRefusalIsNotRetriedOnTheBackoffButATimeoutAndARateLimitAre() async throws {
        let (refresher, world) = make()
        let forbidden = refreshing(refresher)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.failure(failure(403)))
        _ = await forbidden.value
        XCTAssertEqual(world.pending, [], "a 403 is the server's final answer")
        XCTAssertTrue(refresher.owed(Self.id))
        XCTAssertEqual(world.with { $0.outcomes }, [.failed])
        refresher.socketOpened()
        try await eventually(description: "read at the socket's open") { world.readCount == 2 }

        for (n, status) in [(1, 429), (2, 408)] {
            world.read(n).answer(.failure(failure(status)))
            try await eventually(description: "\(status) retried") { !world.pending.isEmpty }
            world.with { $0.timers.first(where: \.live) }?.run()
            try await eventually(description: "read after \(status)") { world.readCount == n + 2 }
        }
        world.read(3).answer(.success([]))
        try await eventually(description: "applied") { refresher.settled(Self.id) }
    }

    // MARK: - Behaviour 11: what `ready()` waits for

    func testSettledWaitsForAReadInFlightOrBeingApplied() async throws {
        let gate = RecordLogReceiptHarness.Gate()
        let (refresher, world) = make { $0.applyGate = gate }
        XCTAssertTrue(refresher.settled(Self.id), "a db3 never read expects nothing")
        refresher.opening(Self.id)
        XCTAssertFalse(refresher.settled(Self.id), "its list is on its way from the bind")
        refresher.opened(Self.id)
        try await eventually(description: "the read") { world.readCount == 1 }
        XCTAssertFalse(refresher.settled(Self.id), "outstanding")
        world.read(0).answer(.success([Self.entry("title")]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(refresher.settled(Self.id), "being applied")
        gate.open()
        try await eventually(description: "applied") { world.with { $0.outcomes } == [.applied] }
        XCTAssertTrue(refresher.settled(Self.id))
    }

    func testTheDeclarationTimerNeverEndsAWaitWhoseDeclarationIsStillExpected() async throws {
        let (refresher, world) = make()
        refresher.opening(Self.id)
        refresher.opened(Self.id)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.success([]))
        try await eventually(description: "the open's list") { world.with { $0.applied.count } == 1 }
        refresher.statusChanged(Self.id, .live)
        XCTAssertFalse(refresher.settled(Self.id), "the open's declaration is awaited")
        let timer = try XCTUnwrap(world.timer(RecordLogIndexRefresher.listTimeout))
        let outcomes = world.with { $0.outcomes.count }
        timer.run()
        XCTAssertFalse(refresher.settled(Self.id), "the 10 s timer passes and the wait stands")
        XCTAssertEqual(world.with { $0.outcomes.count }, outcomes, "nothing reported applied")

        // The acknowledgment reads the list again and settles it.
        refresher.declared(Self.id)
        try await eventually(description: "the re-read") { world.readCount == 2 }
        XCTAssertFalse(refresher.settled(Self.id))
        world.read(1).answer(.success([Self.entry("title")]))
        try await eventually(description: "settled") { world.with { $0.outcomes.count } == outcomes + 1 }
        XCTAssertEqual(world.with { $0.outcomes }.last, .applied)
        XCTAssertTrue(refresher.settled(Self.id))
    }

    func testAnOpenThatDeclaresNothingAwaitsNoAcknowledgment() async throws {
        let (refresher, world) = make { $0.declares = false }
        refresher.opening(Self.id)
        refresher.opened(Self.id)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.success([]))
        try await eventually(description: "applied") { refresher.settled(Self.id) }
        refresher.statusChanged(Self.id, .live)
        XCTAssertTrue(refresher.settled(Self.id), "typed or read-only: no acknowledgment comes")
        XCTAssertEqual(world.pending, [])
    }

    func testAStoreTurnedReadOnlyReleasesTheWait() async throws {
        // Released by the next `settled` query.
        do {
            let (refresher, world) = make()
            refresher.opening(Self.id)
            refresher.opened(Self.id)
            try await eventually(description: "the read") { world.readCount == 1 }
            world.read(0).answer(.success([]))
            try await eventually(description: "the open's list") { world.with { $0.applied.count } == 1 }
            refresher.statusChanged(Self.id, .live)
            XCTAssertFalse(refresher.settled(Self.id))
            world.with { $0.declares = false }
            XCTAssertTrue(refresher.settled(Self.id), "a reader's declaration is refused, never acknowledged")
        }
        // Released by the timer, which reports it applied.
        do {
            let (refresher, world) = make()
            refresher.opening(Self.id)
            refresher.opened(Self.id)
            try await eventually(description: "the read") { world.readCount == 1 }
            world.read(0).answer(.success([]))
            try await eventually(description: "the open's list") { world.with { $0.applied.count } == 1 }
            refresher.statusChanged(Self.id, .live)
            let before = world.with { $0.outcomes.count }
            world.with { $0.declares = false }
            try XCTUnwrap(world.timer(RecordLogIndexRefresher.listTimeout)).run()
            XCTAssertEqual(world.with { $0.outcomes.count }, before + 1)
            XCTAssertEqual(world.with { $0.outcomes }.last, .applied)
        }
    }

    func testAReopenAfterLiveReadsTheListAgain() async throws {
        let (refresher, world) = make { $0.declares = false }
        refresher.opening(Self.id)
        refresher.opened(Self.id)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.success([]))
        try await eventually(description: "applied") { refresher.settled(Self.id) }
        refresher.statusChanged(Self.id, .live)
        refresher.statusChanged(Self.id, .live)
        XCTAssertEqual(world.readCount, 1, "live again with no reopen reads nothing")
        refresher.statusChanged(Self.id, .idle)
        refresher.statusChanged(Self.id, .opening)
        refresher.statusChanged(Self.id, .live)
        XCTAssertFalse(refresher.settled(Self.id), "the reopen's live reads the list at once")
        try await eventually(description: "the reopen's read") { world.readCount == 2 }
        world.read(1).answer(.success([Self.entry("title")]))
        try await eventually(description: "applied") { refresher.settled(Self.id) }
    }

    func testAFailedOpenReportsFailedAndDestroyEndsEveryTimer() async throws {
        let (refresher, world) = make()
        refresher.opening(Self.id)
        refresher.openFailed(Self.id)
        XCTAssertEqual(world.with { $0.outcomes }, [.failed])
        XCTAssertTrue(refresher.settled(Self.id), "nothing is on its way")

        refresher.opening(Self.id)
        refresher.opened(Self.id)
        try await eventually(description: "the read") { world.readCount == 1 }
        world.read(0).answer(.failure(failure(500)))
        try await eventually(description: "a retry") { world.pending == [1] }
        refresher.statusChanged(Self.id, .live)
        XCTAssertEqual(Set(world.pending), [1, RecordLogIndexRefresher.listTimeout])
        refresher.destroy()
        XCTAssertEqual(world.pending, [], "every retry and wait ends")
        XCTAssertTrue(world.with { $0.timers }.allSatisfy(\.cancelled))
    }
}
