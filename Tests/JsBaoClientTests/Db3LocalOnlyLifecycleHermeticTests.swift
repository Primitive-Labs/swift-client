import XCTest
@testable import JsBaoClient

/// #5155 behaviours 30 and 31 in the lifecycle's own world (its deps, as the
/// retention suite drives it), and edge case E10.
///
/// - 30: the retention sweep never removes a db3 that lives only on this
///   device, and it counts toward no `maxDocs` cap: a cap of 1 with one
///   synced copy also stored evicts nothing, a 1 ms `ttl` evicts the synced
///   one and keeps it, logged as kept for living only here; the format-1
///   pass's keep verdict keeps it; `evict`, with or without `force`, is
///   refused `.db3LocalOnly`, also for a copy not bound whose row is gone
///   (its stored mark says so).
/// - 31, the held half (pin): `deleteLocalOnly` whose purge another holder
///   refuses throws `.db3Held`, fires no `Db3EvictedEvent`, ends no
///   subscription, and leaves the copy as it was.
/// - E10 (pin): a synced db3's state and stored entry read `localOnly` false.
final class Db3LocalOnlyLifecycleHermeticTests: XCTestCase {

    private static let local = "01JD5155LOCALAAAAAAAAAAAAA"
    private static let synced = "01JD5155SYNCEDBBBBBBBBBBBB"
    private static let scope = "db3-local-only-5155"

    /// What the client would answer the lifecycle: the copies the store holds.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        /// Each stored copy's last catch-up (ms) and whether it lives only here.
        var stored: [String: (lastCatchUpAt: Int64?, localOnly: Bool)] = [:]
        /// The copies whose metadata row says they live only here.
        var rows: Set<String> = []
        var bound: Set<String> = []
        /// Whether a purge removes the copy; `false` is another holder keeping it.
        var purges = true
        var purged: [String] = []
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        var evicted: [String] { with { $0.emitted.compactMap { ($0 as? Db3EvictedEvent)?.id } } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                isLocalOnly: { [self] id in with { $0.rows.contains(id) } },
                knownPermission: { _ in .readWrite },
                isBound: { [self] id in with { $0.bound.contains(id) } },
                syncMarks: { [self] id in
                    with { world in
                        guard world.bound.contains(id), let copy = world.stored[id] else { return nil }
                        return Db3SyncMarks(
                            cursor: 1, permission: nil, lastCatchUpAt: copy.lastCatchUpAt, replacing: false, staged: false,
                            localOnly: copy.localOnly
                        )
                    }
                },
                storedState: { [self] id in
                    with { world in
                        world.stored[id].map { copy in
                            RecordLogStoredState(
                                cursor: 1, rows: 1, writers: [], replacing: false, lastCatchUpAt: copy.lastCatchUpAt,
                                localOnly: copy.localOnly
                            )
                        }
                    }
                },
                storedIds: { [self] in with { Array($0.stored.keys).sorted() } },
                purge: { [self] id, _ in
                    with { world in
                        guard world.purges else { return Db3PurgeOutcome(purged: false) }
                        world.purged.append(id)
                        world.stored[id] = nil
                        world.bound.remove(id)
                        return Db3PurgeOutcome(purged: true)
                    }
                },
                lastUsedAt: { _ in 1 },
                logger: Logger(level: .debug, scope: Db3LocalOnlyLifecycleHermeticTests.scope)
            )
        }
    }

    private var lines: ThreadSafeBox<[String]>!

    override func setUp() {
        super.setUp()
        let lines = ThreadSafeBox<[String]>([])
        self.lines = lines
        Logger.lineForTest = { _, scope, message in
            if scope == Db3LocalOnlyLifecycleHermeticTests.scope { lines.mutate { $0.append(message) } }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        super.tearDown()
    }

    private func make(_ configure: (World) -> Void) -> (Db3Lifecycle, World) {
        let world = World()
        world.with(configure)
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    /// One local-only copy (bound, its row saying so) and one synced copy.
    private func both() -> (Db3Lifecycle, World) {
        make {
            $0.stored = [Self.local: (nil, true), Self.synced: (1, false)]
            $0.rows = [Self.local]
            $0.bound = [Self.local, Self.synced]
        }
    }

    // MARK: - Behaviour 30

    func testACapCountsOnlyTheCopiesThatCanBeFetchedAgain() async throws {
        let (lifecycle, world) = both()
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: 1)
        XCTAssertEqual(world.evicted, [], "one synced copy fits a cap of one: the local-only one counts toward none")
        XCTAssertEqual(world.with { $0.purged }, [])
        XCTAssertTrue(lines.value.contains { $0.contains(Self.local) && $0.contains("lives only on this device") }, "\(lines.value)")
        let sweep = lines.value.filter { $0.hasPrefix("[db3] retention:") }
        XCTAssertEqual(sweep, ["[db3] retention: 2 stored, 1 kept (1 local-only), 0 evicted"])
    }

    func testATtlEvictsTheSyncedCopyAndKeepsTheLocalOnlyOne() async throws {
        let (lifecycle, world) = both()
        try await Task.sleep(nanoseconds: 5_000_000)
        await lifecycle.enforceRetention(ttlMs: 1, maxDocs: nil)
        XCTAssertEqual(world.evicted, [Self.synced])
        XCTAssertNotNil(world.with { $0.stored[Self.local] })
        let wouldRemove = await lifecycle.retentionWouldRemove(Self.local)
        XCTAssertFalse(wouldRemove, "the format-1 pass's verdict keeps it")
        await lifecycle.retentionExpire([Self.local])
        XCTAssertNotNil(world.with { $0.stored[Self.local] })
    }

    func testEvictIsRefusedForceOrNotEvenUnboundWithItsRowGone() async throws {
        let (lifecycle, world) = both()
        for force in [false, true] {
            let error = await db3LocalOnlyThrown { try await lifecycle.evict(Self.local, options: Db3EvictOptions(force: force)) }
            XCTAssertEqual(error?.code, .db3LocalOnly)
            XCTAssertEqual(error?.details?["db3Id"], .string(Self.local))
        }
        // Not bound, its row gone: its stored mark still says so.
        world.with {
            $0.bound = []
            $0.rows = []
        }
        let unbound = await db3LocalOnlyThrown { try await lifecycle.evict(Self.local, options: Db3EvictOptions(force: true)) }
        XCTAssertEqual(unbound?.code, .db3LocalOnly)
        XCTAssertEqual(world.with { $0.purged }, [])
        XCTAssertEqual(world.evicted, [])
    }

    // MARK: - Behaviour 31, the held half (pin)

    func testADeleteAnotherHolderRefusesChangesNothing() async throws {
        let (lifecycle, world) = both()
        world.with { $0.purges = false }
        let sub = try lifecycle.subscribe(Self.local, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await sub.ready()
        let error = await db3LocalOnlyThrown { try await lifecycle.deleteLocalOnly(Self.local) }
        XCTAssertEqual(error?.code, .db3Held)
        XCTAssertEqual(error?.details?["db3Id"], .string(Self.local))
        XCTAssertEqual(world.evicted, [], "no Db3EvictedEvent")
        XCTAssertTrue(lifecycle.isSubscribed(Self.local), "its subscription stays")
        XCTAssertNotNil(world.with { $0.stored[Self.local] }, "the copy stays")
        let stored = try await lifecycle.stored()
        XCTAssertEqual(stored.map(\.id), [Self.local, Self.synced])
        sub.dispose()

        // Once nothing holds it, the delete removes it.
        world.with { $0.purges = true }
        try await lifecycle.deleteLocalOnly(Self.local)
        XCTAssertEqual(world.evicted, [Self.local])
        XCTAssertEqual(world.emitted.compactMap { ($0 as? Db3EvictedEvent)?.reason }, [.explicit])
    }

    // MARK: - E10 (pin)

    func testASyncedDb3ReadsLocalOnlyFalse() async throws {
        let (lifecycle, _) = both()
        let state = try await lifecycle.state(Self.synced)
        XCTAssertFalse(state.localOnly)
        let stored = try await lifecycle.stored()
        XCTAssertEqual(stored.first { $0.id == Self.synced }?.localOnly, false)
        XCTAssertEqual(stored.first { $0.id == Self.local }?.localOnly, true)
        XCTAssertFalse(Db3State(
            id: "x", resident: false, subscribed: false, phase: .idle, progress: nil, cursor: 0, rows: 0, lastSyncAt: nil,
            pendingWrites: 0, permission: nil, error: nil
        ).localOnly)
        XCTAssertFalse(Db3StoredEntry(id: "x", rows: 0, cursor: 0, pendingWrites: 0, lastSyncAt: nil, resident: false).localOnly)
    }
}
