import XCTest
@testable import JsBaoClient

/// #5085 — the db3 half of the Swift retention policy, `Db3Lifecycle.enforceRetention`,
/// over its deps (the #4701 lifecycle world): which copies it ranks and in what
/// order, which it keeps and counts, the one line it writes, and the keep
/// verdict the format-1 pass asks of a db3 row. Every removal against a real
/// store is proven live in `Db3RetentionStoredLiveTests`.
///
/// - 6: last use is `lastUsedAt`, else the store's `lastCatchUpAt`, else
///   oldest; a subscribed, door-held, pending or unjudged copy is kept, counts
///   toward `maxDocs`, and the walk goes on to the next; one
///   `[db3] retention: …` line per sweep.
/// - E5: `ttl` evicts a copy whose last use is old and keeps a subscribed one.
/// - E6: `maxDocs: nil` is no cap; `maxDocs: 0` keeps no unheld copy.
/// - 4 (SO-001): `retentionWouldRemove` answers the keep verdict and removes nothing.
/// - 5085-C002: `retentionExpire`, ahead of the format-1 pass's `ttl`, removes
///   what that pass's door removed before: a stored copy it may remove is
///   evicted, a row with no copy is forgotten with no event, a kept one stays.
final class Db3RetentionSweepHermeticTests: XCTestCase {

    private static let a = "01JD5085SWEEPAAAAAAAAAAAAA"
    private static let b = "01JD5085SWEEPBBBBBBBBBBBBB"
    private static let c = "01JD5085SWEEPCCCCCCCCCCCCC"
    private static let d = "01JD5085SWEEPDDDDDDDDDDDDD"
    private static let e = "01JD5085SWEEPEEEEEEEEEEEEE"
    private static let scope = "db3-sweep-5085"

    /// What the client would answer the lifecycle: the copies the store holds.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        /// Each stored copy's `lastCatchUpAt` (ms) and unjudged writes.
        var stored: [String: (lastCatchUpAt: Int64?, pending: Int)] = [:]
        /// Each copy's metadata row's last use (ms).
        var lastUsed: [String: Int64] = [:]
        var doorOpen: Set<String> = []
        var pendingCreates: Set<String> = []
        var purged: [String] = []
        var forgotten: [String] = []
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        var evicted: [String] { with { $0.emitted.compactMap { ($0 as? Db3EvictedEvent)?.id } } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                isOpen: { [self] id in with { $0.doorOpen.contains(id) } },
                pendingCreates: { [self] in with { Array($0.pendingCreates) } },
                isPendingCreate: { [self] id in with { $0.pendingCreates.contains(id) } },
                knownPermission: { _ in .readWrite },
                forget: { [self] id in with { $0.forgotten.append(id) } },
                isBound: { [self] id in with { $0.stored[id] != nil } },
                syncMarks: { [self] id in
                    with { $0.stored[id] == nil ? nil : Db3SyncMarks(cursor: 1, permission: nil, lastCatchUpAt: 1, replacing: false, staged: false) }
                },
                storedState: { [self] id in
                    with { world in
                        world.stored[id].map { copy in
                            RecordLogStoredState(
                                cursor: 1, rows: 1,
                                writers: copy.pending > 0
                                    ? [RecordLogStoredState.Writer(writer: "w", clientId: "c", nextSeq: copy.pending + 1, lowestPending: 1, pending: copy.pending)]
                                    : [],
                                replacing: false, lastCatchUpAt: copy.lastCatchUpAt
                            )
                        }
                    }
                },
                storedIds: { [self] in with { Array($0.stored.keys) } },
                purge: { [self] id, _ in
                    with {
                        $0.purged.append(id)
                        $0.stored[id] = nil
                    }
                    return Db3PurgeOutcome(purged: true)
                },
                lastUsedAt: { [self] id in with { $0.lastUsed[id] } },
                logger: Logger(level: .debug, scope: Db3RetentionSweepHermeticTests.scope)
            )
        }
    }

    private var lines: ThreadSafeBox<[String]>!

    override func setUp() {
        super.setUp()
        let lines = ThreadSafeBox<[String]>([])
        self.lines = lines
        Logger.lineForTest = { _, scope, message in
            if scope == Db3RetentionSweepHermeticTests.scope { lines.mutate { $0.append(message) } }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        super.tearDown()
    }

    private var sweepLines: [String] { lines.value.filter { $0.hasPrefix("[db3] retention:") } }

    private func make(_ configure: (World) -> Void) -> (Db3Lifecycle, World) {
        let world = World()
        world.with(configure)
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    /// Subscribe and wait until the lifecycle opened it.
    private func subscribed(_ lifecycle: Db3Lifecycle, _ id: String) async throws -> Db3Subscription {
        let handle = try lifecycle.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 5, description: "\(id) subscribed") { lifecycle.isSubscribed(id) }
        try await delay(0.05)
        return handle
    }

    // MARK: - Behaviour 6

    func testRanksByLastUseThenByLastCatchUpThenOldest() async throws {
        let (lifecycle, world) = make {
            $0.stored = [Self.a: (2_000, 0), Self.b: (500, 0), Self.c: (nil, 0)]
            $0.lastUsed = [Self.a: 3_000]
        }
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: 2)
        XCTAssertEqual(world.evicted, [Self.c], "a copy nothing dates is the oldest")
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: 1)
        XCTAssertEqual(world.evicted, [Self.c, Self.b], "B's catch-up is older than A's last use")
        XCTAssertEqual(world.with { Array($0.stored.keys) }, [Self.a])
        XCTAssertEqual(sweepLines, ["[db3] retention: 3 stored, 0 kept, 1 evicted", "[db3] retention: 2 stored, 0 kept, 1 evicted"])
    }

    func testAKeptCopyCountsAndTheWalkGoesOnToTheNextRemovable() async throws {
        let (lifecycle, world) = make {
            $0.stored = [Self.a: (1_000, 0), Self.b: (2_000, 0), Self.c: (3_000, 0), Self.d: (4_000, 3), Self.e: (5_000, 0)]
            $0.lastUsed = [Self.a: 1_000, Self.b: 2_000, Self.c: 3_000, Self.d: 4_000, Self.e: 5_000]
            $0.doorOpen = [Self.b]
            $0.pendingCreates = [Self.c]
        }
        let held = try await subscribed(lifecycle, Self.a)
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: 4)
        XCTAssertEqual(world.evicted, [Self.e], "A, B, C and D are kept and count; E goes")
        XCTAssertEqual(world.with { Set($0.stored.keys) }, [Self.a, Self.b, Self.c, Self.d])
        XCTAssertTrue(held.state.subscribed)
        XCTAssertEqual(
            sweepLines,
            ["[db3] retention: 5 stored, 4 kept (1 subscribed, 1 open, 1 pending create, 1 unjudged writes), 1 evicted"]
        )
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: 2)
        XCTAssertEqual(world.evicted, [Self.e], "only kept copies are left")
        XCTAssertEqual(sweepLines.last, "[db3] retention: 4 stored, 4 kept (1 subscribed, 1 open, 1 pending create, 1 unjudged writes), 0 evicted; 4 remain, above maxDocs 2")
        held.dispose()
    }

    // MARK: - E5

    func testTtlEvictsACopyWhoseLastUseIsOldAndKeepsASubscribedOne() async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let (lifecycle, world) = make {
            $0.stored = [Self.a: (now - 60_000, 0), Self.b: (now - 60_000, 0), Self.c: (now, 0)]
            $0.lastUsed = [Self.a: now - 60_000, Self.b: now - 60_000, Self.c: now]
        }
        let held = try await subscribed(lifecycle, Self.b)
        await lifecycle.enforceRetention(ttlMs: 30_000, maxDocs: nil)
        XCTAssertEqual(world.evicted, [Self.a])
        XCTAssertEqual(world.with { Set($0.stored.keys) }, [Self.b, Self.c])
        held.dispose()
    }

    // MARK: - E6

    func testMaxDocsNilIsNoCapAndZeroKeepsNoUnheldCopy() async throws {
        let (lifecycle, world) = make {
            $0.stored = [Self.a: (1_000, 0), Self.b: (2_000, 0), Self.c: (3_000, 0)]
        }
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: nil)
        XCTAssertEqual(world.evicted, [])
        XCTAssertEqual(sweepLines, [], "a policy with no cap and no TTL sweeps nothing")
        let held = try await subscribed(lifecycle, Self.c)
        await lifecycle.enforceRetention(ttlMs: nil, maxDocs: 0)
        XCTAssertEqual(world.evicted, [Self.a, Self.b])
        XCTAssertEqual(world.with { Array($0.stored.keys) }, [Self.c])
        held.dispose()
    }

    // MARK: - The keep verdict (SO-001)

    func testTheVerdictKeepsWhatTheSweepKeepsAndRemovesNothing() async throws {
        let (lifecycle, world) = make {
            $0.stored = [Self.a: (1_000, 0), Self.b: (2_000, 0), Self.c: (3_000, 0), Self.d: (4_000, 2), Self.e: (5_000, 0)]
            $0.doorOpen = [Self.b]
            $0.pendingCreates = [Self.c]
        }
        let held = try await subscribed(lifecycle, Self.a)
        var verdicts: [Bool] = []
        for id in [Self.a, Self.b, Self.c, Self.d, Self.e] { verdicts.append(await lifecycle.retentionWouldRemove(id)) }
        XCTAssertEqual(verdicts, [false, false, false, false, true])
        XCTAssertEqual(world.with { $0.purged }, [], "the verdict removes nothing")
        XCTAssertEqual(world.evicted, [])
        held.dispose()
    }

    // MARK: - The format-1 pass's TTL (5085-C002)

    func testExpireRemovesWhatTheFormatOnePassDoorRemovedAndKeepsWhatItKept() async throws {
        let (lifecycle, world) = make {
            $0.stored = [Self.a: (1_000, 0), Self.b: (2_000, 0), Self.c: (3_000, 2)]
        }
        let held = try await subscribed(lifecycle, Self.b)
        // D has a row and no copy here.
        await lifecycle.retentionExpire([Self.a, Self.b, Self.c, Self.d])
        XCTAssertEqual(world.evicted, [Self.a], "one event, for the stored copy it may remove")
        XCTAssertEqual(world.with { $0.purged }, [Self.a])
        XCTAssertEqual(world.with { $0.forgotten }, [Self.a, Self.d], "the row with no copy is forgotten, as before")
        XCTAssertEqual(world.with { Set($0.stored.keys) }, [Self.b, Self.c], "the subscribed copy and the unjudged one stay")
        XCTAssertEqual(sweepLines, [], "not a sweep: no retention line")
        held.dispose()
    }
}
