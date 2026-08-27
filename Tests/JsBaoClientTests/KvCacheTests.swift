import XCTest
@testable import JsBaoClient

/// Targeted tests for `KvCache.fetchCached` after the
/// `NSLock.lock()/unlock()` → scoped `withLock` conversion (issue #1910).
///
/// `fetchCached` is the non-mechanical hand-conversion site: it has three
/// separate critical sections (an in-memory cache read, a storage-load
/// write-back, and an in-flight-request dedup) that are intentionally NOT
/// atomic across the `await`s between them. The conversion must keep them as
/// separate `withLock` blocks — never merged into one spanning a suspension.
/// These tests pin the observable behavior of each region.
///
/// All server-free: the region-1 and region-3 tests use a `KvCache` with no
/// storage provider (so the storage-load region returns nil); the region-2
/// tests use a `MemoryStorageProvider`. None of them need the dev server.
final class KvCacheTests: XCTestCase {

    /// Thread-safe counter for asserting how many times a fetcher ran.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        /// Increment and read atomically, for a fetcher that must label its
        /// own response with the call number it is answering.
        func incrementAndGet() -> Int { lock.withLock { _value += 1; return _value } }
        var value: Int { lock.withLock { _value } }
    }

    /// Build the app-relaunch shape for the region-2 (persistent storage) tests:
    /// `key` is on disk with a real `updatedAtMs`, and the returned cache's
    /// `memCache` is empty, so a read has to go through `loadFromStorage`.
    ///
    /// Two caches over one provider is what makes that true — priming and
    /// reading through the same instance would leave the record in `memCache`
    /// and every read would stop in region 1. `loadFromStorage` is not
    /// user-scoped, so the second cache finds the first one's record directly.
    ///
    /// This is the cold-start path, and the most likely real-world trigger of
    /// #2364: after a relaunch `memCache` is empty and the persisted `me.get()`
    /// entry is past the shared 5-minute TTL.
    private func makeDiskBackedCache(
        key: String,
        value: JSONValue,
        emit: (@Sendable (any JsBaoEventPayload) -> Void)? = nil
    ) async throws -> KvCache {
        let provider = MemoryStorageProvider()
        try await provider.initialize(namespace: "kv-cache-region-2-tests")

        let priming = KvCache()
        await priming.setStorageProvider(provider)
        await priming.set(key: key, value: value)

        let coldStart = KvCache(emit: emit)
        await coldStart.setStorageProvider(provider)
        return coldStart
    }

    /// Region 3 (in-flight dedup): N concurrent `fetchCached` calls for the
    /// same key while the fetch is in flight must share a single fetcher
    /// invocation and all observe the same value. The check-and-register of
    /// the in-flight task must be atomic under one lock hold — if it weren't,
    /// concurrent callers would each start their own fetch.
    func testConcurrentFetchesDedupeToSingleFetcher() async throws {
        let cache = KvCache()
        let fetcherCalls = AtomicCounter()
        let callerCount = 50

        let results = try await withThrowingTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<callerCount {
                group.addTask {
                    try await cache.fetchCached(key: "dedup-key", fetcher: {
                        fetcherCalls.increment()
                        // Hold the request in flight long enough for every
                        // caller to reach the dedup region.
                        try await Task.sleep(nanoseconds: 200_000_000)
                        return "the-value"
                    })
                }
            }
            var collected: [String?] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(fetcherCalls.value, 1, "concurrent callers must dedupe to exactly one fetcher invocation")
        XCTAssertEqual(results.count, callerCount)
        XCTAssertTrue(results.allSatisfy { $0 == "the-value" }, "all callers observe the shared result")
    }

    /// Region 1 (in-memory cache hit): once a value is cached, a subsequent
    /// `fetchCached` with default options returns it WITHOUT invoking the
    /// fetcher again.
    func testCacheHitShortCircuitsFetcher() async throws {
        let cache = KvCache()

        let first: String? = try await cache.fetchCached(key: "hit-key", fetcher: { "v1" })
        XCTAssertEqual(first, "v1")

        let second: String? = try await cache.fetchCached(key: "hit-key", fetcher: {
            XCTFail("fetcher must not run on a fresh cache hit")
            return "v2"
        })
        XCTAssertEqual(second, "v1", "cache hit returns the stored value")
    }

    /// Region 1 (staleness): with `refreshIfOlderThan` set so the cached
    /// entry is due for a refresh, `fetchCached` returns the **cached** value
    /// immediately and refreshes behind it — it never awaits the network on a
    /// cache hit (#2364). That is what JS does
    /// (`src/client/kv-cache.ts`: `fetchNetwork().catch(() => {})` then
    /// `return localVal`). `refreshIfOlderThan: 0` makes any age due
    /// (`age >= 0` is always true).
    ///
    /// Swift used to fall through to an awaited fetch here, so every expiry of
    /// the shared 5-minute `me.get()` TTL blocked the caller on a round trip.
    func testStaleEntryServesCachedValueAndRefreshesInBackground() async throws {
        let fetcherCalls = AtomicCounter()
        // Synchronize on the cache *write*, not on the fetcher returning:
        // `makeFetchTask` emits `cacheUpdated` only after `completeInflightFetch`
        // has stored the value, so an expectation fulfilled inside the fetcher
        // can resume this test before `v2` is in the cache (review finding on
        // #2364). Two writes happen — the priming fetch and the background
        // refresh — so the emit closure routes them to separate expectations.
        let writes = AtomicCounter()
        let primingCommitted = expectation(description: "priming write committed")
        let refreshCommitted = expectation(description: "background refresh committed to the cache")
        let cache = KvCache(emit: { payload in
            guard payload is CacheUpdatedEvent else { return }
            if writes.incrementAndGet() == 1 {
                primingCommitted.fulfill()
            } else {
                refreshCommitted.fulfill()
            }
        })

        let first: String? = try await cache.fetchCached(key: "stale-key", fetcher: {
            fetcherCalls.increment()
            return "v1"
        })
        XCTAssertEqual(first, "v1")
        XCTAssertEqual(fetcherCalls.value, 1)
        await fulfillment(of: [primingCommitted], timeout: 5)

        let served: String? = try await cache.fetchCached(
            key: "stale-key",
            fetcher: {
                fetcherCalls.increment()
                // Long enough that an awaited fetch could not have returned by
                // the time the assertion below runs.
                try await Task.sleep(nanoseconds: 100_000_000)
                return "v2"
            },
            options: FetchCachedOptions(refreshIfOlderThan: 0)
        )
        XCTAssertEqual(served, "v1", "a due entry serves the cached value rather than waiting on the network")

        await fulfillment(of: [refreshCommitted], timeout: 5)
        XCTAssertEqual(fetcherCalls.value, 2, "the refresh still ran — in the background")

        // The refresh's value landed in the cache, so the next read sees it.
        let afterRefresh: String? = try await cache.fetchCached(key: "stale-key", fetcher: {
            XCTFail("the refreshed entry is fresh — no fetch expected")
            return "v3"
        })
        XCTAssertEqual(afterRefresh, "v2", "the background refresh updated the cached entry")
    }

    /// `refreshNetwork` is the other trigger JS folds into the same
    /// `shouldRefresh` flag: it forces the refresh regardless of age, and the
    /// caller still gets the cached value straight away. It does **not** mean
    /// "bypass the cache and wait" — that is `waitForLoad: .network`.
    func testRefreshNetworkServesCachedValueAndRefreshesInBackground() async throws {
        // Same write-ordering synchronization as the stale-entry test above.
        let writes = AtomicCounter()
        let primingCommitted = expectation(description: "priming write committed")
        let refreshCommitted = expectation(description: "background refresh committed to the cache")
        let cache = KvCache(emit: { payload in
            guard payload is CacheUpdatedEvent else { return }
            if writes.incrementAndGet() == 1 {
                primingCommitted.fulfill()
            } else {
                refreshCommitted.fulfill()
            }
        })

        let first: String? = try await cache.fetchCached(key: "refresh-key", fetcher: { "v1" })
        XCTAssertEqual(first, "v1")
        await fulfillment(of: [primingCommitted], timeout: 5)

        let served: String? = try await cache.fetchCached(
            key: "refresh-key",
            fetcher: {
                try await Task.sleep(nanoseconds: 100_000_000)
                return "v2"
            },
            options: FetchCachedOptions(refreshNetwork: true)
        )
        XCTAssertEqual(served, "v1", "refreshNetwork refreshes behind the cached value, it does not block on it")

        await fulfillment(of: [refreshCommitted], timeout: 5)

        let afterRefresh: String? = try await cache.fetchCached(key: "refresh-key", fetcher: {
            XCTFail("the refreshed entry is fresh — no fetch expected")
            return "v3"
        })
        XCTAssertEqual(afterRefresh, "v2")
    }

    /// The background refresh shares the in-flight dedup table with the awaited
    /// path, so a burst of due reads starts exactly one refresh.
    func testConcurrentDueReadsStartASingleBackgroundRefresh() async throws {
        let cache = KvCache()
        let fetcherCalls = AtomicCounter()
        // The refresh runs in an unstructured task, so the task group finishing
        // only proves the 25 callers returned — the fetcher may not have started
        // yet, and `fetcherCalls.value` could still be 0 (review finding on
        // #2364). Wait on the fetcher itself. `expectation(description:)`
        // asserts on over-fulfillment, so a *second* refresh starting fails the
        // test too — which is the dedup property under test.
        let refreshStarted = expectation(description: "the background refresh's fetcher started")

        _ = try await cache.fetchCached(key: "burst-key", fetcher: { "v1" }) as String?

        let served = try await withThrowingTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<25 {
                group.addTask {
                    try await cache.fetchCached(
                        key: "burst-key",
                        fetcher: {
                            fetcherCalls.increment()
                            refreshStarted.fulfill()
                            try await Task.sleep(nanoseconds: 200_000_000)
                            return "v2"
                        },
                        options: FetchCachedOptions(refreshIfOlderThan: 0)
                    )
                }
            }
            var collected: [String?] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        XCTAssertTrue(served.allSatisfy { $0 == "v1" }, "every caller got the cached value with no wait")
        await fulfillment(of: [refreshStarted], timeout: 5)
        XCTAssertEqual(fetcherCalls.value, 1, "the due reads deduped onto one background refresh")
    }

    /// A cached JSON `null` is the "no such record" sentinel
    /// (`CacheFacade.fetchCachedJSON`), so a record holding it has nothing to
    /// serve. A **due** entry must therefore await the fetch — the behavior
    /// both Swift and JS already had on these two triggers — rather than hand
    /// back `nil` and refresh behind it. JS excludes null/undefined from
    /// `localVal` (`src/client/kv-cache.ts`) for the same reason.
    ///
    /// The last assertion pins the deliberately-unchanged half: a `null` that
    /// is not due still short-circuits as a cache hit. That negative-caching
    /// difference from JS predates #2364 and is out of its scope.
    func testDueCachedNullAwaitsTheNetworkRatherThanServingNil() async throws {
        let cache = KvCache()

        // Prime the entry with "no such record".
        let primed = try await cache.fetchCachedValue(key: "null-key", fetcher: { .null })
        XCTAssertTrue(primed.isNull)

        // Age-based trigger: the entry is due, and there is nothing to serve.
        let byAge = try await cache.fetchCachedValue(
            key: "null-key",
            fetcher: { .string("from-server") },
            options: FetchCachedOptions(refreshIfOlderThan: 0)
        )
        XCTAssertEqual(
            byAge, .string("from-server"),
            "a due null entry has nothing to serve, so it must await the fetch"
        )

        // `refreshNetwork` trigger, on a fresh null entry.
        let nulled = try await cache.fetchCachedValue(key: "other-null-key", fetcher: { .null })
        XCTAssertTrue(nulled.isNull)
        let byRefreshNetwork = try await cache.fetchCachedValue(
            key: "other-null-key",
            fetcher: { .string("from-server") },
            options: FetchCachedOptions(refreshNetwork: true)
        )
        XCTAssertEqual(
            byRefreshNetwork, .string("from-server"),
            "refreshNetwork on a cached null must await the fetch, not resolve nil"
        )

        // Unchanged: a null entry that is NOT due is still a hit.
        let stillNull = try await cache.fetchCachedValue(key: "fresh-null-key", fetcher: { .null })
        XCTAssertTrue(stillNull.isNull)
        let freshHit = try await cache.fetchCachedValue(
            key: "fresh-null-key",
            fetcher: {
                XCTFail("a fresh null entry still short-circuits — no fetch expected")
                return .string("unused")
            }
        )
        XCTAssertTrue(freshHit.isNull, "negative caching on the fresh-hit path is unchanged")
    }

    /// Region 2 (persistent storage load), age trigger: a due entry that is
    /// only on **disk** serves its cached value immediately and refreshes
    /// behind it, exactly as region 1 does for an in-memory one.
    ///
    /// This is the cold-start path — see `makeDiskBackedCache` — so it is where
    /// #2364's stall was most likely to be hit in a real app.
    func testDiskBackedDueEntryServesCachedValueAndRefreshesInBackground() async throws {
        let refreshCommitted = expectation(description: "background refresh committed to the cache")
        let cache = try await makeDiskBackedCache(
            key: "cold-start-key",
            value: .string("from-disk"),
            emit: { payload in
                guard payload is CacheUpdatedEvent else { return }
                refreshCommitted.fulfill()
            }
        )
        let fetcherCalls = AtomicCounter()

        let served: String? = try await cache.fetchCached(
            key: "cold-start-key",
            fetcher: {
                fetcherCalls.increment()
                // Long enough that an awaited fetch could not have returned by
                // the time the assertion below runs.
                try await Task.sleep(nanoseconds: 100_000_000)
                return "from-server"
            },
            options: FetchCachedOptions(refreshIfOlderThan: 0)
        )
        XCTAssertEqual(
            served, "from-disk",
            "a due entry loaded from storage serves the cached value rather than waiting on the network"
        )

        await fulfillment(of: [refreshCommitted], timeout: 5)
        XCTAssertEqual(fetcherCalls.value, 1, "the refresh still ran — in the background")

        // The refresh's value landed in the cache, so the next read sees it.
        let afterRefresh: String? = try await cache.fetchCached(key: "cold-start-key", fetcher: {
            XCTFail("the refreshed entry is fresh — no fetch expected")
            return "unused"
        })
        XCTAssertEqual(afterRefresh, "from-server", "the background refresh updated the cached entry")
    }

    /// Region 2, `refreshNetwork` trigger. This is a genuinely new path, not a
    /// mirror of region 1: before #2364 the outer guard was `if !refreshNetwork`,
    /// so a `refreshNetwork` call that missed `memCache` skipped the storage
    /// read entirely and awaited the network. It now loads from disk, memoizes,
    /// and hands back the **disk** value with the refresh behind it.
    func testDiskBackedRefreshNetworkServesCachedValueAndRefreshesInBackground() async throws {
        let refreshCommitted = expectation(description: "background refresh committed to the cache")
        let cache = try await makeDiskBackedCache(
            key: "cold-start-refresh-key",
            value: .string("from-disk"),
            emit: { payload in
                guard payload is CacheUpdatedEvent else { return }
                refreshCommitted.fulfill()
            }
        )
        let fetcherCalls = AtomicCounter()

        let served: String? = try await cache.fetchCached(
            key: "cold-start-refresh-key",
            fetcher: {
                fetcherCalls.increment()
                try await Task.sleep(nanoseconds: 100_000_000)
                return "from-server"
            },
            options: FetchCachedOptions(refreshNetwork: true)
        )
        XCTAssertEqual(
            served, "from-disk",
            "refreshNetwork reaches the storage load and refreshes behind the disk value, it does not block on the network"
        )

        await fulfillment(of: [refreshCommitted], timeout: 5)
        XCTAssertEqual(fetcherCalls.value, 1)

        let afterRefresh: String? = try await cache.fetchCached(key: "cold-start-refresh-key", fetcher: {
            XCTFail("the refreshed entry is fresh — no fetch expected")
            return "unused"
        })
        XCTAssertEqual(afterRefresh, "from-server")
    }

    /// Region 2's `null` rule: a cached JSON `null` loaded from storage is the
    /// "no such record" sentinel, so a due entry has nothing to serve and must
    /// await the fetch — the same rule region 1 applies, on both triggers.
    func testDiskBackedDueCachedNullAwaitsTheNetwork() async throws {
        let byAgeCache = try await makeDiskBackedCache(key: "cold-null-key", value: .null)
        let byAge = try await byAgeCache.fetchCachedValue(
            key: "cold-null-key",
            fetcher: { .string("from-server") },
            options: FetchCachedOptions(refreshIfOlderThan: 0)
        )
        XCTAssertEqual(
            byAge, .string("from-server"),
            "a due null entry loaded from storage has nothing to serve, so it must await the fetch"
        )

        let byRefreshNetworkCache = try await makeDiskBackedCache(key: "other-cold-null-key", value: .null)
        let byRefreshNetwork = try await byRefreshNetworkCache.fetchCachedValue(
            key: "other-cold-null-key",
            fetcher: { .string("from-server") },
            options: FetchCachedOptions(refreshNetwork: true)
        )
        XCTAssertEqual(
            byRefreshNetwork, .string("from-server"),
            "refreshNetwork on a null loaded from storage must await the fetch, not resolve nil"
        )
    }

    /// A background refresh that throws must not surface to the caller — it
    /// already has its value. JS swallows it with `.catch(() => {})`; the
    /// failure is still observable through the `cacheUpdateFailed` event.
    func testBackgroundRefreshFailureIsNotThrownToTheCaller() async throws {
        let failures = AtomicCounter()
        let failureEmitted = expectation(description: "cacheUpdateFailed emitted")
        let cache = KvCache(emit: { payload in
            if payload is CacheUpdateFailedEvent {
                failures.increment()
                failureEmitted.fulfill()
            }
        })

        _ = try await cache.fetchCached(key: "failing-key", fetcher: { "v1" }) as String?

        struct RefreshFailure: Error {}
        let served: String? = try await cache.fetchCached(
            key: "failing-key",
            fetcher: { throw RefreshFailure() },
            options: FetchCachedOptions(refreshIfOlderThan: 0)
        )
        XCTAssertEqual(served, "v1", "the cached value is returned even though the refresh fails")

        await fulfillment(of: [failureEmitted], timeout: 5)
        XCTAssertEqual(failures.value, 1)

        // The failed refresh left the good entry in place and cleared the
        // in-flight slot, so a later read still serves it.
        let afterFailure: String? = try await cache.fetchCached(key: "failing-key", fetcher: { "v2" })
        XCTAssertEqual(afterFailure, "v1")
    }

    /// The background path is only for cache *hits*. A miss — even one asking
    /// for age-based refresh — still awaits the network, because there is no
    /// value to serve.
    func testCacheMissStillAwaitsTheNetwork() async throws {
        let cache = KvCache()

        let value: String? = try await cache.fetchCached(
            key: "miss-key",
            fetcher: {
                try await Task.sleep(nanoseconds: 50_000_000)
                return "fresh"
            },
            options: FetchCachedOptions(refreshIfOlderThan: 0)
        )
        XCTAssertEqual(value, "fresh", "a miss has nothing to serve, so it waits for the fetch")
    }

    /// `waitForLoad: .network` keeps its meaning: skip the cache and wait for
    /// the server. `CacheFacade` used to express that by setting
    /// `refreshNetwork`, which now means the opposite — so the facade routes it
    /// through the internal `awaitNetwork` flag instead.
    ///
    /// The discriminating assertion is the **returned value**, not the call
    /// count. The server answers with an incrementing counter behind a 150ms
    /// delay, so "served the cached value and refreshed behind it" and "waited
    /// for the server" are distinguishable: only the awaited path can hand back
    /// the fresh `n`. A call-count-only assertion passes either way, because a
    /// background refresh reaches the transport too.
    func testWaitForLoadNetworkStillAwaitsFreshServerData() async throws {
        let serverHits = AtomicCounter()
        let transport = RecordingTransport(responder: { _ in
            let n = serverHits.incrementAndGet()
            // Slow enough that a background refresh cannot have landed by the
            // time the assertions below run.
            try await Task.sleep(nanoseconds: 150_000_000)
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"n": \#(n)}"#.utf8)
            )
        })
        let facade = CacheFacade(
            kvCache: KvCache(),
            getNetworkMode: { .auto },
            transport: transport
        )

        let primed: [String: Any]? = try await facade.fetchHttp(path: "/thing")
        XCTAssertEqual((primed?["n"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(transport.calls.count, 1)

        // A default read is served from the cache…
        let cached: [String: Any]? = try await facade.fetchHttp(path: "/thing")
        XCTAssertEqual((cached?["n"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(transport.calls.count, 1, "the cache hit short-circuits")

        // …but `.network` goes to the wire and waits for the answer, so what it
        // returns is the server's fresh value — not the cached `n: 1` that a
        // background refresh would have handed back.
        let forced: [String: Any]? = try await facade.fetchHttp(
            path: "/thing",
            options: FetchCachedOptions(waitForLoad: .network)
        )
        XCTAssertEqual(
            (forced?["n"] as? NSNumber)?.intValue, 2,
            "waitForLoad: .network must await the server and return the fresh value"
        )
        XCTAssertEqual(transport.calls.count, 2, "waitForLoad: .network must reach the server")
    }
}
