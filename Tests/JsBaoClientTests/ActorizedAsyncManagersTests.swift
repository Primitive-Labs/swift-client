import XCTest
@testable import JsBaoClient

/// Phase D2 of the concurrency-modernization epic (#1993): `OfflineStore` and
/// `KvCache` become `actor`s ("straight actors" — the Fork 1 Option C
/// twin-and-deprecate policy lands with `AnalyticsQueue` in D3), their new
/// isolation boundaries are typed in the same commit, and `KvCache.setEmitter`
/// is eliminated by supplying the emitter at construction.
///
/// The checks fall into two kinds:
///
/// * **Structural** (source text) — that the types really are actors and really
///   carry no lock, and that the two invariants the conversion could silently
///   break are still argued in the code: no `await` inside the dedup decision
///   region, and no synchronous provider lookup inside `persistDocumentToLocal`.
///   These are source-text checks because "is an actor" and "suspends here" are
///   not observable from a passing functional test.
/// * **Behavioral** — the round-trips and the coalescing that must survive the
///   conversion, plus the typed analytics boundary end to end.
///
/// All server-free.
final class ActorizedAsyncManagersTests: XCTestCase {

    /// Thread-safe counter for asserting how many times a fetcher ran.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// Thread-safe holder for one event payload observed through an injected
    /// emitter. `Any?` because `CacheUpdatedEvent.value` is `Any?` — the whole
    /// point of the test that uses it is what concrete thing arrives there.
    private final class PayloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Any?
        func set(_ value: Any?) { lock.withLock { _value = value } }
        var value: Any? { lock.withLock { _value } }
    }

    /// Thread-safe collector for events observed through an injected emitter.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func append(_ name: String) { lock.withLock { _events.append(name) } }
        var events: [String] { lock.withLock { _events } }
    }

    // MARK: - Behavior 2 — the actor declarations, and no surviving locks

    /// Both converted types are actors, declared as such. This is the phase's
    /// headline and cannot be observed any other way from a test — an actor and
    /// a lock-guarded class behave identically from the outside.
    func testOfflineStoreAndKvCacheAreDeclaredAsActors() throws {
        XCTAssertTrue(
            try Self.clientSource("Internal/OfflineStore.swift").contains("public actor OfflineStore"),
            "OfflineStore must be an actor"
        )
        XCTAssertTrue(
            try Self.clientSource("Internal/KvCache.swift").contains("public actor KvCache"),
            "KvCache must be an actor"
        )
    }

    /// The conversion has to *replace* the lock, not sit beside it. Behavior 2
    /// allows a converted type to keep an explicitly enumerated, safety-argued
    /// snapshot holder; D2 needs none, so the budget for both files is zero.
    func testConvertedActorsDeclareNoLocks() throws {
        for file in ["Internal/OfflineStore.swift", "Internal/KvCache.swift"] {
            let source = try Self.code(file)
            XCTAssertFalse(
                source.contains("NSLock()"),
                "\(file) declares an NSLock — D2 enumerates no surviving snapshot holders"
            )
        }
        // The converted types stop opting out of Sendable checking. `CacheFacade`
        // shares KvCache.swift and stays a class, so this is asserted on the two
        // declarations rather than on the files.
        for declaration in ["class OfflineStore", "class KvCache"] {
            XCTAssertFalse(
                try Self.code("Internal/OfflineStore.swift").contains(declaration)
                    || Self.code("Internal/KvCache.swift").contains(declaration),
                "\(declaration) must be an actor, not a lock-guarded @unchecked Sendable class"
            )
        }
    }

    /// The two files this phase gives a new isolation boundary are named in the
    /// gate's zero list. Actorizing a type *creates* `Sendable` requirements at
    /// every new boundary, so "the budget was already 0" is not the same claim
    /// as "these two files are held at 0" — naming them is what stops a later
    /// phase from re-introducing an `Any` here unnoticed.
    func testV6GateHoldsThePhaseD2FilesAtZero() throws {
        var root = URL(fileURLWithPath: #filePath)
        // .../Tests/JsBaoClientTests/<this file> → the package root.
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let runner = try String(contentsOf: root.appendingPathComponent("run-tests.sh"), encoding: .utf8)

        for file in ["Internal/OfflineStore.swift", "Internal/AnalyticsQueue.swift"] {
            XCTAssertTrue(runner.contains("\"\(file)\""),
                          "run-tests.sh must hold \(file) at zero .v6 Sendable sites")
        }
    }

    /// The dedup decision region (look up the in-flight task, or create and
    /// register one) must stay a single uninterrupted isolated step. Under the
    /// old `lock.withLock` that was structural; under actor isolation an `await`
    /// anywhere between the lookup and the registration would let a second
    /// caller in and start a duplicate fetch. The `Task` body is built by a
    /// separate method precisely so this region has no `await` in it at all.
    func testDedupDecisionRegionContainsNoSuspensionPoint() throws {
        // Sliced on code anchors, from comment-free source, so the region under
        // test is the statements themselves and not the prose explaining them.
        let source = try Self.code("Internal/KvCache.swift")
        let region = try Self.slice(
            source,
            from: "let dedup: (task: Task<JSONValue, Error>, isExisting: Bool)",
            to: "let task = dedup.task"
        )
        XCTAssertFalse(
            region.contains("await"),
            "the dedup check-and-register region must not suspend:\n\(region)"
        )
        XCTAssertTrue(
            region.contains("inflightRequests[key] = task"),
            "the region under test must be the one that registers the in-flight task"
        )
    }

    /// `DocumentManager.persistDocumentToLocal` used to resolve the storage
    /// provider from a synchronous immediately-invoked closure. `OfflineStore`'s
    /// provider accessor is isolated now, so that closure cannot exist — the
    /// lookup is inlined into the async function.
    func testPersistDocumentToLocalHasNoSynchronousProviderLookup() throws {
        let source = try Self.code("Internal/DocumentManager.swift")
        let lookups = source.components(separatedBy: "offlineStore.getStorageProvider()").count - 1
        let awaited = source.components(separatedBy: "await offlineStore.getStorageProvider()").count - 1
        XCTAssertGreaterThan(lookups, 0, "the lookups this test guards must still exist")
        XCTAssertEqual(awaited, lookups,
                       "every storage-provider lookup must go through the actor with `await`")
        XCTAssertFalse(
            source.contains("let persistence: YjsSQLitePersistence? = {"),
            "the synchronous immediately-invoked closure cannot await — it must become async"
        )
    }

    // MARK: - KvCache: the emitter now arrives at construction

    /// `setEmitter` is gone. Keeping it would mean a synchronous mutation of
    /// actor state, which is the thing the conversion exists to remove.
    func testKvCacheHasNoSetEmitter() throws {
        let source = try Self.code("Internal/KvCache.swift")
        XCTAssertFalse(source.contains("func setEmitter"),
                       "KvCache.setEmitter is eliminated in favour of init(emit:)")
        XCTAssertFalse(source.contains("kvCache.setEmitter"),
                       "CacheFacade.init must not wire the emitter after construction")
    }

    /// The construction-ordering fix: `JsBaoClient` builds its `KvCache` with
    /// the emitter already attached, instead of building it bare and injecting
    /// the closure later from `setupSubApis`.
    func testJsBaoClientConstructsKvCacheWithItsEmitter() throws {
        let source = try Self.code("JsBaoClient.swift")
        XCTAssertTrue(source.contains("KvCache(emit:"),
                      "the client must construct KvCache with its emitter")
        XCTAssertFalse(source.contains("setEmitter"),
                       "no post-construction emitter wiring remains")
    }

    /// End to end: an emitter supplied to `init` still fires `cacheUpdated`
    /// after a successful network refresh, and `cacheUpdateFailed` when the
    /// fetcher throws — the two events `CacheFacade` used to wire in.
    func testEmitterSuppliedAtConstructionReceivesBothCacheEvents() async throws {
        let log = EventLog()
        let cache = KvCache(emit: { payload in log.append(type(of: payload).eventKey.rawValue) })

        let value: String? = try await cache.fetchCached(key: "emit-ok", fetcher: { "v" })
        XCTAssertEqual(value, "v")

        do {
            let _: String? = try await cache.fetchCached(key: "emit-fail", fetcher: {
                throw JsBaoError(code: .unavailable, message: "boom")
            })
            XCTFail("the fetcher's error must propagate")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        }

        XCTAssertEqual(
            log.events,
            [JsBaoEvent.cacheUpdated.rawValue, JsBaoEvent.cacheUpdateFailed.rawValue]
        )
    }

    /// The dedup invariant, exercised rather than read: 50 concurrent callers
    /// for one key still collapse onto a single fetcher run under actor
    /// isolation, and every one of them gets the same value.
    func testConcurrentFetchesDedupeUnderActorIsolation() async throws {
        let cache = KvCache()
        let fetcherCalls = AtomicCounter()

        let results = try await withThrowingTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<50 {
                group.addTask {
                    try await cache.fetchCached(key: "actor-dedup", fetcher: {
                        fetcherCalls.increment()
                        try await Task.sleep(nanoseconds: 200_000_000)
                        return "shared"
                    })
                }
            }
            var collected: [String?] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(fetcherCalls.value, 1,
                       "actor isolation must not turn the dedup region into an interleaving point")
        XCTAssertEqual(results.count, 50)
        XCTAssertTrue(results.allSatisfy { $0 == "shared" })
    }

    /// A failed fetch must still clear its in-flight entry, otherwise every
    /// later call for the same key replays the original error forever. The
    /// cleanup moved out of a `defer` (which cannot `await`) into explicit
    /// isolated completion steps, so it is worth re-checking here.
    func testFailedFetchClearsItsInflightEntry() async throws {
        let cache = KvCache()

        do {
            let _: String? = try await cache.fetchCached(key: "retry", fetcher: {
                throw JsBaoError(code: .unavailable, message: "first attempt fails")
            })
            XCTFail("the first fetch must throw")
        } catch {}

        let second: String? = try await cache.fetchCached(key: "retry", fetcher: { "recovered" })
        XCTAssertEqual(second, "recovered",
                       "a failed fetch must not poison the key with a stale in-flight task")
    }

    // MARK: - KvCache: the emit stays off the actor (review of PR #2266)

    /// `EventEmitter` delivers callback subscribers **synchronously**, so the
    /// emit closure runs arbitrary app code. Running it from an isolated step
    /// would put that code on the cache's executor: a slow `.cacheUpdated`
    /// handler would serialize every cache operation, and a handler that waits
    /// on work which itself needs the cache would deadlock outright.
    ///
    /// Exercised rather than read: the handler blocks until a *concurrent*
    /// `cache.get` — a genuinely isolated call — has completed. If the emit
    /// held the actor, that call could not finish and the wait would time out.
    func testCacheUpdatedEmitDoesNotOccupyTheCacheActor() async throws {
        let reentrantCallFinished = DispatchSemaphore(value: 0)
        let emitEntered = DispatchSemaphore(value: 0)
        let sawReentrantCall = AtomicCounter()

        let cache = KvCache(emit: { payload in
            guard payload is CacheUpdatedEvent else { return }
            emitEntered.signal()
            // Deliberately blocking: this is the app handler whose cost must
            // not land on the cache actor.
            if reentrantCallFinished.wait(timeout: .now() + 5) == .success {
                sawReentrantCall.increment()
            }
        })

        // Seed a second key so the concurrent read has something to return.
        await cache.set(key: "other", value: .string("seeded"))

        let emitNeverFired = AtomicCounter()
        let reader = Task { () -> JSONValue? in
            // Only start once the handler is actually blocking. Bounded: if the
            // emit stops firing — the regression this test guards — an untimed
            // wait would hang the suite instead of failing with a message.
            guard await emitEntered.waitAsync(timeout: .now() + 5) == .success else {
                emitNeverFired.increment()
                return nil
            }
            let value = await cache.get(key: "other")
            reentrantCallFinished.signal()
            return value
        }

        let fetched: String? = try await cache.fetchCached(key: "emit-offactor", fetcher: { "v" })
        XCTAssertEqual(fetched, "v")

        let readWhileHandlerBlocked = await reader.value
        XCTAssertEqual(emitNeverFired.value, 0,
                       "the .cacheUpdated emit never fired — the handler was never entered")
        XCTAssertEqual(readWhileHandlerBlocked, .string("seeded"),
                       "an isolated cache call must complete while a .cacheUpdated handler is running")
        XCTAssertEqual(sawReentrantCall.value, 1,
                       "the emit must run with the actor free — it blocked the cache instead")
    }

    /// The structural half of the check above: the isolated completion steps
    /// must not contain the emit at all. A behavioral test can only observe the
    /// deadlock once the ordering is wrong in a way that reproduces; this
    /// pins where the call may live.
    func testIsolatedCompletionStepsDoNotEmit() throws {
        let source = try Self.code("Internal/KvCache.swift")
        // The two isolated completion steps sit between the fetch task and the
        // nonisolated emit helpers, so one anchored slice covers both.
        let region = try Self.slice(
            source,
            from: "private func completeInflightFetch(",
            to: "private nonisolated func emitCacheUpdated("
        )
        XCTAssertTrue(region.contains("private func failInflightFetch("),
                      "the slice must cover both isolated completion steps")
        XCTAssertFalse(
            region.contains("emit?("),
            "the isolated completion steps must not emit — that runs off the actor:\n\(region)"
        )
        XCTAssertTrue(
            source.contains("private nonisolated func emitCacheUpdated(")
                && source.contains("private nonisolated func emitCacheUpdateFailed("),
            "both emit helpers must be nonisolated"
        )
        XCTAssertTrue(
            source.contains("private nonisolated func makeFetchTask("),
            "the fetch task must be built from nonisolated context, or its body inherits actor isolation"
        )
    }

    /// `CacheUpdatedEvent.value` is `Any?`, and what travels in it changed with
    /// the `JSONValue` conversion: it used to be the caller's own fetcher
    /// result, and is the JSON graph now. That is a runtime-only change (no
    /// compile error for `event.value as? MyModel`), so it is disclosed in the
    /// CHANGELOG and pinned here.
    func testCacheUpdatedCarriesTheJSONGraphNotTheFetcherValue() async throws {
        struct Profile: Codable, Equatable { let name: String }

        let received = PayloadBox()
        let cache = KvCache(emit: { payload in
            if let updated = payload as? CacheUpdatedEvent { received.set(updated.value) }
        })

        let fetched: Profile? = try await cache.fetchCached(
            key: "graph-payload",
            fetcher: { Profile(name: "ada") }
        )
        XCTAssertEqual(fetched, Profile(name: "ada"), "the caller still gets its own type back")

        let payload = received.value
        XCTAssertNil(payload as? Profile,
                     "documented: the event payload is no longer the fetcher's own value")
        XCTAssertEqual((payload as? [String: Any])?["name"] as? String, "ada",
                       "the event payload is the JSON graph of the cached value")
    }

    // MARK: - OfflineStore: the isolated provider and the typed analytics boundary

    /// The provider accessors are isolated now; the round-trip through them
    /// still works, which is what every metadata/grant/JWT method depends on.
    func testOfflineStoreProviderAccessorsAreIsolatedAndRoundTrip() async throws {
        let provider = MemoryStorageProvider()
        let store = OfflineStore()
        await store.setStorageProvider(provider)

        let read = await store.getStorageProvider()
        XCTAssertTrue(read === provider)

        try await store.ensureMetadataDb(appId: "app", userId: "user")
        try await store.putMetadata(
            appId: "app", userId: "user",
            record: LocalMetadataEntry(documentId: "doc-1", title: "T")
        )
        let loaded = try await store.getMetadata(appId: "app", userId: "user", documentId: "doc-1")
        XCTAssertEqual(loaded?.title, "T")
    }

    /// The analytics queue's payload crosses a brand-new isolation boundary, so
    /// it is typed as `JSONValue` rather than `Any` — the plan's explicit
    /// requirement for this method. The round-trip preserves every JSON shape.
    func testAnalyticsQueueBoundaryIsTypedAndRoundTrips() async throws {
        let provider = MemoryStorageProvider()
        let store = OfflineStore()
        await store.setStorageProvider(provider)

        let events: [[String: JSONValue]] = [
            ["event": .string("doc_open"), "count": .number(2), "ok": .bool(true)],
            ["event": .string("doc_edit"), "tags": .array([.string("a")]), "meta": .object(["k": .null])],
        ]
        try await store.persistAnalyticsQueue(appId: "app", userId: "user", events: events)
        let restored = try await store.loadAnalyticsQueue(appId: "app", userId: "user")

        XCTAssertEqual(restored, events)
    }

    /// The signature really is the typed one — an `Any` payload crossing this
    /// boundary is what the phase set out to remove.
    func testPersistAnalyticsQueueDeclaresTheTypedPayload() throws {
        let source = try Self.code("Internal/OfflineStore.swift")
        XCTAssertTrue(
            source.contains("events: [[String: JSONValue]]"),
            "persistAnalyticsQueue's payload must attach to JSONValue, never Any"
        )
        XCTAssertFalse(
            source.contains("[[String: Any]]"),
            "no untyped analytics payload may cross the new actor boundary"
        )
    }

    /// A buffered event has to survive a persist/restore cycle end to end.
    /// This is the regression that would bite users: events buffered offline
    /// and lost on relaunch.
    ///
    /// The assertion is on the **restored queue's buffer**, not on the store —
    /// asserting the store only proves the persist direction, and would still
    /// pass if the restore dropped every row on the way back.
    func testAnalyticsQueuePersistAndRestoreSurviveTheTypedBoundary() async throws {
        let provider = MemoryStorageProvider()
        let store = OfflineStore()
        await store.setStorageProvider(provider)

        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "d2-test"),
            appId: "app",
            offlineStore: store,
            getUserId: { "user" }
        )
        await queue.logEvent([
            "event": .string("session_start"), "count": .number(3), "ok": .bool(true),
        ])
        await queue.persistBuffer()

        let restoredQueue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "d2-test"),
            appId: "app",
            offlineStore: store,
            getUserId: { "user" }
        )
        await restoredQueue.restoreBuffer()

        let restored = await restoredQueue.bufferedEvents
        XCTAssertEqual(restored.count, 1, "the restored buffer must hold the persisted event")
        XCTAssertEqual(restored.first?["event"], .string("session_start"))
        XCTAssertEqual(restored.first?["count"], .number(3))
        XCTAssertEqual(restored.first?["ok"], .bool(true))
        XCTAssertNotNil(restored.first?["timestamp"]?.stringValue,
                        "the queue's own defaulting must survive the round trip")

        // And the store really is where it came from.
        let persisted = try await store.loadAnalyticsQueue(appId: "app", userId: "user")
        XCTAssertEqual(persisted, restored)
    }

    /// `ensureMetadataDb` reads its decision from isolated state, awaits the
    /// provider's `initialize`, then writes back — the same three steps the
    /// lock version had, so the second call for the same namespace is still a
    /// no-op rather than a second `initialize`.
    func testEnsureMetadataDbInitializesOncePerNamespace() async throws {
        let provider = CountingStorageProvider()
        let store = OfflineStore()
        await store.setStorageProvider(provider)

        try await store.ensureMetadataDb(appId: "app", userId: "user")
        try await store.ensureMetadataDb(appId: "app", userId: "user")
        XCTAssertEqual(provider.initializeCount, 1)

        try await store.ensureMetadataDb(appId: "app", userId: "other")
        XCTAssertEqual(provider.initializeCount, 2, "a new namespace re-initializes")
    }

    // MARK: - Helpers

    // The implementations live in `Helpers/ClientSourceText.swift` — every
    // phase of the concurrency epic needs the same four, so there is one copy
    // (consolidated in Phase D4). These are the local names the tests above use.

    private static func code(_ relativePath: String) throws -> String {
        try ClientSourceText.code(relativePath)
    }

    private static func clientSource(_ relativePath: String) throws -> String {
        try ClientSourceText.clientSource(relativePath)
    }

    private static func slice(_ source: String, from: String, to: String) throws -> String {
        try ClientSourceText.slice(source, from: from, to: to)
    }
}

/// Counts `initialize` calls so the namespace guard can be observed.
private final class CountingStorageProvider: StorageProvider, @unchecked Sendable {
    private let inner = MemoryStorageProvider()
    private let lock = NSLock()
    private var _initializeCount = 0
    var initializeCount: Int { lock.withLock { _initializeCount } }

    func initialize(namespace: String) async throws {
        lock.withLock { _initializeCount += 1 }
        try await inner.initialize(namespace: namespace)
    }
    func close() async { await inner.close() }
    func isReady() -> Bool { inner.isReady() }
    func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
        try await inner.get(store: store, key: key)
    }
    func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
        try await inner.put(store: store, key: key, value: value, metadata: metadata)
    }
    func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
        try await inner.putBatch(store: store, records: records)
    }
    func delete(store: String, key: String) async throws {
        try await inner.delete(store: store, key: key)
    }
    func clear(store: String) async throws { try await inner.clear(store: store) }
    func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
        try await inner.iterate(store: store, callback: callback)
    }
    func keys(store: String) async throws -> [String] { try await inner.keys(store: store) }
    func has(store: String, key: String) async throws -> Bool {
        try await inner.has(store: store, key: key)
    }
}
