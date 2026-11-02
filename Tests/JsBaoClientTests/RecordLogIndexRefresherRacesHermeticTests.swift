import XCTest
@testable import JsBaoClient

/// #5101 review findings C001–C003 — the index refresher's bookkeeping
/// under answers that race, over a world whose reads and store writes the
/// test answers one by one.
///
/// - C001: a read is accepted and its application registered in one step,
///   so `settled` is never true while an accepted list is not in the store,
///   and two answers that land together never leave a stale application
///   that keeps `ready()` waiting.
/// - C002: a store write that passed the check before a rebind is not
///   written over the list of the new binding.
/// - C003: a refresh answered by a later list fails when that list could not
///   be written to the store.
final class RecordLogIndexRefresherRacesHermeticTests: XCTestCase {

    private static let id = "01JD5101REFRESHRACESXXXXXX"

    private static func entry(_ field: String) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: "idx_\(field)", model: "Note", fields: [field], unique: false)
    }

    private struct WriteFailed: Error {}

    /// A store write the test holds before its guard, or fails.
    private struct Step {
        var gate: RecordLogReceiptHarness.Gate?
        var error: Error?
    }

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        var reads: [RecordLogIndexRefresherHermeticTests.Read] = []
        var applied: [[RecordLogIndexEntry]] = []
        var steps: [Int: Step] = [:]
        var writes = 0
        var outcomes: [RecordLogIndexOutcome] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func read(_ n: Int) -> RecordLogIndexRefresherHermeticTests.Read { with { $0.reads[n] } }
        var readCount: Int { with { $0.reads.count } }

        func deps() -> RecordLogIndexRefresherDeps {
            RecordLogIndexRefresherDeps(
                read: { [self] id in
                    let read = RecordLogIndexRefresherHermeticTests.Read(id)
                    with { $0.reads.append(read) }
                    return try await read.wait()
                },
                apply: { [self] _, entries, whileLatest in
                    let step = with { world -> Step? in
                        defer { world.writes += 1 }
                        return world.steps[world.writes]
                    }
                    if let gate = step?.gate { await gate.wait() }
                    if let error = step?.error { throw error }
                    _ = try whileLatest { with { $0.applied.append(entries) } }
                },
                settled: { [self] _, outcome in with { $0.outcomes.append(outcome) } },
                setTimer: { delay, fire in RecordLogIndexRefresherHermeticTests.Timer(delay, fire) }
            )
        }
    }

    private func make(_ configure: (World) -> Void = { _ in }) -> (RecordLogIndexRefresher, World) {
        let world = World()
        world.with(configure)
        return (RecordLogIndexRefresher(deps: world.deps()), world)
    }

    private func refreshing(_ refresher: RecordLogIndexRefresher) -> Task<String, Never> {
        Task {
            do {
                try await refresher.refresh(Self.id)
                return "resolved"
            } catch {
                return error is WriteFailed ? "write failed" : "\(error)"
            }
        }
    }

    // MARK: - C001

    func testSettledIsNeverTrueBeforeAnAcceptedListIsInTheStore() async throws {
        for round in 0..<100 {
            let (refresher, world) = make()
            refresher.opening(Self.id)
            refresher.opened(Self.id)
            try await eventually(interval: 0.001, description: "round \(round): the read") { world.readCount == 1 }
            let answered = Task.detached { world.read(0).answer(.success([Self.entry("title")])) }
            var early = false
            let deadline = Date().addingTimeInterval(5)
            while !refresher.settled(Self.id), Date() < deadline {}
            XCTAssertTrue(refresher.settled(Self.id), "round \(round): the list applied")
            if world.with({ $0.applied.isEmpty }) { early = true }
            await answered.value
            XCTAssertFalse(early, "round \(round): settled while the accepted list was not in the store")
            if early { return }
        }
    }

    func testAnswersLandingTogetherLeaveNoApplicationBehind() async throws {
        for round in 0..<100 {
            let (refresher, world) = make()
            // Read n is the n-th issued: the second refresh starts once the first read is out.
            let first = refreshing(refresher)
            try await eventually(interval: 0.001, description: "round \(round): the first read") { world.readCount == 1 }
            let second = refreshing(refresher)
            try await eventually(interval: 0.001, description: "round \(round): the second read") { world.readCount == 2 }
            let lists = [[Self.entry("title")], [Self.entry("slug")]]
            await withTaskGroup(of: Void.self) { group in
                for n in [1, 0] {
                    group.addTask { world.read(n).answer(.success(lists[n])) }
                }
            }
            let answers = [await first.value, await second.value]
            XCTAssertEqual(answers, ["resolved", "resolved"], "round \(round)")
            XCTAssertTrue(refresher.settled(Self.id), "round \(round): an application was left registered")
            XCTAssertEqual(world.with { $0.applied.last }, [Self.entry("slug")], "round \(round): the later read's list is in the store")
            if !refresher.settled(Self.id) { return }
        }
    }

    // MARK: - C002

    func testAWriteCheckedBeforeARebindIsNotWrittenOverTheNewBinding() async throws {
        let gate = RecordLogReceiptHarness.Gate()
        let (refresher, world) = make { $0.steps[0] = Step(gate: gate) }
        let old = refreshing(refresher)
        try await eventually(description: "the old binding's read") { world.readCount == 1 }
        world.read(0).answer(.success([Self.entry("title")]))
        try await eventually(description: "the old list's write held") { world.with { $0.writes } == 1 }
        refresher.rebind(Self.id)
        let new = refreshing(refresher)
        try await eventually(description: "the new binding's read") { world.readCount == 2 }
        world.read(1).answer(.success([Self.entry("slug")]))
        let got = await new.value
        XCTAssertEqual(got, "resolved")
        XCTAssertEqual(world.with { $0.applied }, [[Self.entry("slug")]])
        gate.open()
        _ = await old.value
        XCTAssertEqual(world.with { $0.applied }, [[Self.entry("slug")]], "the earlier binding's list is not written")
        XCTAssertTrue(refresher.settled(Self.id))
        XCTAssertEqual(world.with { $0.outcomes }, [.applied], "only the new binding's list reports applied")
    }

    // MARK: - C003

    func testARefreshAnsweredByALaterListFailsWhenThatListIsNotWritten() async throws {
        let gate = RecordLogReceiptHarness.Gate()
        let (refresher, world) = make { $0.steps[0] = Step(gate: gate, error: WriteFailed()) }
        let earlier = refreshing(refresher)
        try await eventually(description: "the first read") { world.readCount == 1 }
        let later = refreshing(refresher)
        try await eventually(description: "the second read") { world.readCount == 2 }
        world.read(1).answer(.success([Self.entry("slug")]))
        try await eventually(description: "the later list's write held") { world.with { $0.writes } == 1 }
        // The earlier read is answered late: it waits for the later list's write.
        world.read(0).answer(.success([Self.entry("title")]))
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let answers = [await earlier.value, await later.value]
        XCTAssertEqual(answers, ["write failed", "write failed"], "neither list reached the store")
        XCTAssertEqual(world.with { $0.applied }, [])
        XCTAssertTrue(refresher.owed(Self.id), "the list is owed")
        XCTAssertFalse(refresher.settled(Self.id))
    }
}
