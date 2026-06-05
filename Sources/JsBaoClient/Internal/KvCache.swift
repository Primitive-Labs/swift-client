import Foundation

/// Key-value cache with in-memory + persistent storage and deduplication.
public final class KvCache: @unchecked Sendable {
    private let lock = NSLock()
    private var memCache: [String: KvCacheRecord] = [:]
    private var inflightRequests: [String: Task<Any?, Error>] = [:]
    private var storageProvider: StorageProvider?
    private var userId: String?
    private var isInitialized = false

    /// Emits cache lifecycle events. Mirrors the JS `KvCache`'s `emitter`
    /// (`src/client/kv-cache.ts`): `cacheUpdated` on a successful network
    /// refresh and `cacheUpdateFailed` on a refresh error. The closure is
    /// injected by `CacheFacade` / `JsBaoClient`; when `nil` the cache is
    /// silent (so existing callers that construct `KvCache()` keep working).
    /// `@Sendable` and stored behind `lock` to preserve the
    /// `@unchecked Sendable` contract.
    private var emit: (@Sendable (JsBaoEvent, Any) -> Void)?

    private static let storeName = "kv"

    public init(emit: (@Sendable (JsBaoEvent, Any) -> Void)? = nil) {
        self.emit = emit
    }

    /// Inject (or replace) the cache-event emitter after construction.
    /// `JsBaoClient` constructs `KvCache()` before its `EventEmitter`
    /// wiring is complete, so the emitter is set here in `setupSubApis`.
    public func setEmitter(_ emit: @escaping @Sendable (JsBaoEvent, Any) -> Void) {
        lock.lock()
        self.emit = emit
        lock.unlock()
    }

    /// Snapshot the emitter under the lock so emission happens off-lock.
    private func currentEmitter() -> (@Sendable (JsBaoEvent, Any) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return emit
    }

    // MARK: - Setup

    public func setStorageProvider(_ provider: StorageProvider) {
        lock.lock()
        self.storageProvider = provider
        lock.unlock()
    }

    public func setUserId(_ userId: String?) {
        lock.lock()
        self.userId = userId
        if userId == nil {
            memCache.removeAll()
            isInitialized = false
        }
        lock.unlock()
    }

    // MARK: - Core Operations

    /// Fetch a value, using cache if available, with deduplication of in-flight requests
    public func fetchCached<T>(
        key: String,
        fetcher: @escaping () async throws -> T,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        // Check in-memory cache
        let refreshNetwork = options.refreshNetwork ?? false
        let refreshIfOlderThanMs = options.refreshIfOlderThanMs

        if !refreshNetwork {
            lock.lock()
            if let cached = memCache[key] {
                lock.unlock()
                // Check staleness
                if let maxAge = refreshIfOlderThanMs,
                   let updatedAt = cached.updatedAtMs {
                    let age = Date().timeIntervalSince1970 * 1000 - updatedAt
                    if age < Double(maxAge) {
                        return cached.value as? T
                    }
                } else {
                    return cached.value as? T
                }
            } else {
                lock.unlock()
            }

            // Check persistent storage
            if let record = await loadFromStorage(key: key) {
                if let maxAge = refreshIfOlderThanMs,
                   let updatedAt = record.updatedAtMs {
                    let age = Date().timeIntervalSince1970 * 1000 - updatedAt
                    if age < Double(maxAge) {
                        lock.lock()
                        memCache[key] = record
                        lock.unlock()
                        return record.value as? T
                    }
                } else {
                    lock.lock()
                    memCache[key] = record
                    lock.unlock()
                    return record.value as? T
                }
            }
        }

        // Deduplicate in-flight requests
        lock.lock()
        if let existing = inflightRequests[key] {
            lock.unlock()
            return try await existing.value as? T
        }

        let task = Task<Any?, Error> { [weak self] in
            // Always remove the inflight entry on completion, regardless of
            // success or failure. Without this `defer`, a thrown error from
            // `fetcher()` would leave a stale entry in the dictionary that
            // makes every subsequent call for the same key re-throw the
            // original error forever.
            defer {
                self?.lock.lock()
                self?.inflightRequests.removeValue(forKey: key)
                self?.lock.unlock()
            }
            do {
                let value = try await fetcher()
                await self?.set(key: key, value: value)
                // Mirror JS `KvCache`: fire `cacheUpdated` after a successful
                // network refresh (`src/client/kv-cache.ts`). `source` is
                // always "server" — this only runs on the network path.
                self?.currentEmitter()?(
                    .cacheUpdated,
                    CacheUpdatedEvent(
                        key: key,
                        updatedAt: ISO8601DateFormatter().string(from: Date()),
                        source: "server",
                        value: value
                    )
                )
                return value
            } catch {
                // Mirror JS `KvCache`: fire `cacheUpdateFailed` on a refresh
                // error (`src/client/kv-cache.ts`) before rethrowing.
                self?.currentEmitter()?(
                    .cacheUpdateFailed,
                    CacheUpdateFailedEvent(
                        key: key,
                        error: (error as? JsBaoError)?.message ?? "\(error)"
                    )
                )
                throw error
            }
        }
        inflightRequests[key] = task
        lock.unlock()

        // Honor `serverTimeoutMs`: bound the network fetch. On timeout, fall
        // back to any cached (possibly stale) value; otherwise surface a
        // timeout error instead of hanging (#994). Defaults to 10s to match JS
        // (`Math.max(0, options?.serverTimeoutMs ?? 10000)`); an explicit `0`
        // disables the bound (JS's `Math.max(0, …)` floor → falsy → no timer).
        let timeoutMs = options.serverTimeoutMs ?? 10000
        if timeoutMs > 0 {
            do {
                return try await Self.withTimeout(ms: timeoutMs) {
                    try await task.value as? T
                }
            } catch is CacheTimeoutError {
                if let stale = await self.get(key: key) as? T { return stale }
                throw JsBaoError(
                    code: .listTimeout,
                    message: "Cache fetch exceeded serverTimeoutMs (\(timeoutMs)ms)"
                )
            }
        }

        return try await task.value as? T
    }

    private struct CacheTimeoutError: Error {}

    /// Race an async operation against a timeout, throwing `CacheTimeoutError`
    /// if `ms` elapses first.
    private static func withTimeout<R>(ms: Int, _ op: @escaping () async throws -> R) async throws -> R {
        try await withThrowingTaskGroup(of: R.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                throw CacheTimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CacheTimeoutError() }
            return first
        }
    }

    /// Set a value in both memory and persistent cache.
    ///
    /// `internal` (not `public`): the JS `KvCache` exposes neither `get` nor
    /// `set` on its public surface (`src/client/kv-cache.ts` only exposes
    /// `fetchCached`/`info`/`clear`/`clearAll`). This stays callable from
    /// `fetchCached` and the same-module `CacheFacade`, but leaves the SDK's
    /// public API.
    func set(key: String, value: Any) async {
        let now = Date()
        let record = KvCacheRecord(
            key: key,
            value: value,
            updatedAt: ISO8601DateFormatter().string(from: now),
            updatedAtMs: now.timeIntervalSince1970 * 1000
        )

        lock.lock()
        memCache[key] = record
        lock.unlock()

        await saveToStorage(key: key, record: record)
    }

    /// Get a value from cache (memory first, then storage).
    ///
    /// `internal` (not `public`): mirrors JS, which exposes no direct cache
    /// read. Still used internally by `fetchCached` (stale fallback) and the
    /// same-module `CacheFacade`.
    func get(key: String) async -> Any? {
        lock.lock()
        if let cached = memCache[key] {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        if let record = await loadFromStorage(key: key) {
            lock.lock()
            memCache[key] = record
            lock.unlock()
            return record.value
        }

        return nil
    }

    /// Get cache entry info
    public func info(key: String) async -> (updatedAt: String?, ageMs: Double?) {
        lock.lock()
        let cached = memCache[key]
        lock.unlock()

        let record: KvCacheRecord?
        if let cached = cached {
            record = cached
        } else {
            record = await loadFromStorage(key: key)
        }
        guard let record = record else { return (nil, nil) }

        let ageMs: Double?
        if let updatedAtMs = record.updatedAtMs {
            ageMs = Date().timeIntervalSince1970 * 1000 - updatedAtMs
        } else {
            ageMs = nil
        }

        return (record.updatedAt, ageMs)
    }

    /// Clear a specific cache entry
    public func clear(key: String) async {
        lock.lock()
        memCache.removeValue(forKey: key)
        lock.unlock()

        if let provider = storageProvider {
            try? await provider.delete(store: Self.storeName, key: key)
        }
    }

    /// Clear all cache entries
    public func clearAll() async {
        lock.lock()
        memCache.removeAll()
        lock.unlock()

        if let provider = storageProvider {
            try? await provider.clear(store: Self.storeName)
        }
    }

    // MARK: - Private

    private func loadFromStorage(key: String) async -> KvCacheRecord? {
        guard let provider = storageProvider else { return nil }
        struct CacheValue: Codable {
            let json: String
        }
        guard let record: StorageRecord<CacheValue> = try? await provider.get(store: Self.storeName, key: key) else {
            return nil
        }
        let value: Any
        if let data = record.value.json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            value = parsed
        } else {
            value = record.value.json
        }
        return KvCacheRecord(
            key: key,
            value: value,
            updatedAt: record.metadata?["updatedAt"],
            updatedAtMs: record.metadata?["updatedAtMs"].flatMap(Double.init)
        )
    }

    private func saveToStorage(key: String, record: KvCacheRecord) async {
        guard let provider = storageProvider else { return }
        struct CacheValue: Codable {
            let json: String
        }
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: record.value),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "\(record.value)"
        }
        let metadata: [String: String] = [
            "updatedAt": record.updatedAt ?? "",
            "updatedAtMs": record.updatedAtMs.map { String($0) } ?? "",
        ]
        try? await provider.put(store: Self.storeName, key: key, value: CacheValue(json: json), metadata: metadata)
    }
}

// MARK: - Cache Record

struct KvCacheRecord {
    let key: String
    let value: Any
    let updatedAt: String?
    let updatedAtMs: Double?
}

// MARK: - Cache Facade

/// High-level cache API wrapping KvCache with HTTP-aware caching
public final class CacheFacade: @unchecked Sendable {
    private let kvCache: KvCache
    private let getNetworkMode: () -> NetworkMode
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(
        kvCache: KvCache,
        getNetworkMode: @escaping () -> NetworkMode,
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        emit: (@Sendable (JsBaoEvent, Any) -> Void)? = nil
    ) {
        self.kvCache = kvCache
        self.getNetworkMode = getNetworkMode
        self.makeRequest = makeRequest
        // Mirror the JS facade: the cache-event emitter is owned at the
        // client level but flows in through the facade (the JS facade is
        // constructed with `emit`). When supplied, forward it onto the
        // underlying `KvCache`, which fires `cacheUpdated`/`cacheUpdateFailed`
        // on the network path. Optional/defaulted so existing callers that
        // omit it keep their current (silent) behavior.
        if let emit = emit {
            kvCache.setEmitter(emit)
        }
    }

    /// Build a deterministic cache key.
    ///
    /// Matches JS `buildCacheKey` (`src/client/kv-cache.ts`) byte-for-byte:
    /// `base` when there are no params, otherwise `base:<stable-sorted JSON>`.
    /// The suffix is the params serialized as JSON with sorted keys (JS uses
    /// a sorting `replacer`; Swift uses `JSONSerialization` with `.sortedKeys`,
    /// as `stableBodyKey` already does at line ~484) so the same params
    /// produce the same key across both clients.
    public func key(_ base: String, params: [String: Any]? = nil) -> String {
        guard let params = params, !params.isEmpty else { return base }
        let serialized: String
        if JSONSerialization.isValidJSONObject(params),
           let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            serialized = s
        } else {
            // Fallback mirrors JS `JSON.stringify` of a non-serializable value
            // collapsing to a stable string; deterministic for a given input.
            serialized = "\(params)"
        }
        return "\(base):\(serialized)"
    }

    /// Fetch with caching, using a custom fetcher.
    ///
    /// This facade layer owns the `waitForLoad` decision and offline gating —
    /// the low-level `KvCache.fetchCached` only runs when a network fetch is
    /// actually warranted. Semantics mirror the JS client (#994):
    ///
    /// - `waitForLoad`:
    ///   - `.local` → return the cached value (if any) WITHOUT hitting the
    ///     network.
    ///   - `.network` → force the network fetch, skipping the cache-hit
    ///     short-circuit (via `refreshNetwork`).
    ///   - `.localIfAvailableElseNetwork` (default) → return cached if present,
    ///     otherwise fetch.
    /// - Offline gating: when `getNetworkMode()` is `.offline`, never attempt
    ///   the network. Return the cached value if present; otherwise throw a
    ///   `.listUnavailableOffline` error.
    ///
    /// The low-level in-flight dedup and `serverTimeoutMs` timeout remain
    /// intact because the actual network path still flows through
    /// `kvCache.fetchCached`.
    public func fetchCached<T>(
        key: String,
        fetcher: @escaping () async throws -> T,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        let mode = getNetworkMode()
        let isOffline = mode == .offline
        let waitForLoad = options.waitForLoad ?? .localIfAvailableElseNetwork

        // `.local`: pure cache read, never touches the network.
        if waitForLoad == .local {
            return await kvCache.get(key: key) as? T
        }

        // `.network`: force the network fetch (skip the cache-hit
        // short-circuit). When offline, fall back to cache or throw.
        if waitForLoad == .network {
            if isOffline {
                if let cached = await kvCache.get(key: key) as? T { return cached }
                throw JsBaoError(
                    code: .listUnavailableOffline,
                    message: "Cache fetch unavailable offline (key: \(key))"
                )
            }
            var forced = options
            forced.refreshNetwork = true
            return try await kvCache.fetchCached(key: key, fetcher: fetcher, options: forced)
        }

        // `.localIfAvailableElseNetwork` (default).
        // When offline, serve from cache or throw — never fetch.
        if isOffline {
            if let cached = await kvCache.get(key: key) as? T { return cached }
            throw JsBaoError(
                code: .listUnavailableOffline,
                message: "Cache fetch unavailable offline (key: \(key))"
            )
        }

        // Online/auto: defer to the low-level fetcher, which returns the
        // cached value when present (honoring refreshNetwork /
        // refreshIfOlderThanMs) and otherwise fetches.
        return try await kvCache.fetchCached(key: key, fetcher: fetcher, options: options)
    }

    /// Fetch HTTP with automatic caching.
    ///
    /// `query` is appended to the request path so it actually reaches the
    /// server (previously it only influenced the cache key, so a filtered
    /// request returned — and cached — the unfiltered response). The cache
    /// key also incorporates the request body for non-GET methods, so two
    /// POSTs to the same path with different bodies don't collide (#994).
    public func fetchHttp<T>(
        method: String = "GET",
        path: String,
        query: [String: Any]? = nil,
        body: Any? = nil,
        keyBase: String? = nil,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        var keyParams = query ?? [:]
        let isBodyless = method.uppercased() == "GET" || method.uppercased() == "HEAD"
        if let body = body, !isBodyless {
            keyParams["__body"] = Self.stableBodyKey(body)
        }
        let cacheKey = self.key(keyBase ?? path, params: keyParams.isEmpty ? nil : keyParams)
        let requestPath = Self.appendQuery(to: path, query: query)
        // Route through the facade `fetchCached` so HTTP requests honor
        // `waitForLoad` and offline gating, not just the low-level cache logic.
        return try await self.fetchCached(key: cacheKey, fetcher: {
            let result = try await self.makeRequest(method, requestPath, body)
            return result as? T
        }, options: options) as? T
    }

    /// Append `query` as a percent-encoded `?k=v&…` string to `path`,
    /// preserving any query string already present.
    private static func appendQuery(to path: String, query: [String: Any]?) -> String {
        guard let query = query, !query.isEmpty else { return path }
        let pairs = query.keys.sorted().map { k -> String in
            let v = "\(query[k] ?? "")"
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return path.contains("?") ? "\(path)&\(pairs)" : "\(path)?\(pairs)"
    }

    /// A deterministic string for a request body, so it can participate in
    /// the cache key. Uses sorted-key JSON when the body is JSON-serializable.
    private static func stableBodyKey(_ body: Any) -> String {
        if JSONSerialization.isValidJSONObject(body),
           let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(body)"
    }

    /// Cache entry info
    public func info(key: String) async -> (updatedAt: String?, ageMs: Double?) {
        await kvCache.info(key: key)
    }

    /// Clear a specific entry
    public func clear(key: String) async {
        await kvCache.clear(key: key)
    }

    /// Clear all entries
    public func clearAll() async {
        await kvCache.clearAll()
    }
}
