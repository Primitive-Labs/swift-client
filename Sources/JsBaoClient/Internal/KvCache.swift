import Foundation

/// Key-value cache with in-memory + persistent storage and deduplication.
public final class KvCache: @unchecked Sendable {
    private let lock = NSLock()
    private var memCache: [String: KvCacheRecord] = [:]
    private var inflightRequests: [String: Task<Any?, Error>] = [:]
    private var storageProvider: StorageProvider?
    private var userId: String?
    private var isInitialized = false

    private static let storeName = "kv"

    public init() {}

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
            let value = try await fetcher()
            await self?.set(key: key, value: value)
            self?.lock.lock()
            self?.inflightRequests.removeValue(forKey: key)
            self?.lock.unlock()
            return value
        }
        inflightRequests[key] = task
        lock.unlock()

        return try await task.value as? T
    }

    /// Set a value in both memory and persistent cache
    public func set(key: String, value: Any) async {
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

    /// Get a value from cache (memory first, then storage)
    public func get(key: String) async -> Any? {
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
        makeRequest: @escaping (String, String, Any?) async throws -> Any
    ) {
        self.kvCache = kvCache
        self.getNetworkMode = getNetworkMode
        self.makeRequest = makeRequest
    }

    /// Build a deterministic cache key
    public func key(_ base: String, params: [String: Any]? = nil) -> String {
        guard let params = params, !params.isEmpty else { return base }
        let sorted = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: "&")
        return "\(base)?\(sorted)"
    }

    /// Fetch with caching, using a custom fetcher
    public func fetchCached<T>(
        key: String,
        fetcher: @escaping () async throws -> T,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        try await kvCache.fetchCached(key: key, fetcher: fetcher, options: options)
    }

    /// Fetch HTTP with automatic caching
    public func fetchHttp<T>(
        method: String = "GET",
        path: String,
        query: [String: Any]? = nil,
        body: Any? = nil,
        keyBase: String? = nil,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        let cacheKey = self.key(keyBase ?? path, params: query)
        return try await kvCache.fetchCached(key: cacheKey, fetcher: {
            let result = try await self.makeRequest(method, path, body)
            return result as? T
        }, options: options) as? T
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
