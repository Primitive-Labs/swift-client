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
/// All server-free: `KvCache` with no storage provider (the storage-load
/// region returns nil), so they run without the dev server.
final class KvCacheTests: XCTestCase {

    /// Thread-safe counter for asserting how many times a fetcher ran.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
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

    /// Region 1 (staleness): with `refreshIfOlderThanMs` set so the cached
    /// entry is considered stale, `fetchCached` must fall through to a fresh
    /// fetch instead of returning the cached value. `refreshIfOlderThanMs: 0`
    /// makes any non-negative age stale (age < 0 is never true).
    func testStaleEntryTriggersRefetch() async throws {
        let cache = KvCache()
        let fetcherCalls = AtomicCounter()

        let first: String? = try await cache.fetchCached(key: "stale-key", fetcher: {
            fetcherCalls.increment()
            return "v1"
        })
        XCTAssertEqual(first, "v1")
        XCTAssertEqual(fetcherCalls.value, 1)

        let refreshed: String? = try await cache.fetchCached(
            key: "stale-key",
            fetcher: {
                fetcherCalls.increment()
                return "v2"
            },
            options: FetchCachedOptions(refreshIfOlderThanMs: 0)
        )
        XCTAssertEqual(refreshed, "v2", "a stale entry must refetch rather than serve the cached value")
        XCTAssertEqual(fetcherCalls.value, 2)
    }
}
