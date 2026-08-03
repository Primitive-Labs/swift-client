import Foundation

/// Key-value cache with in-memory + persistent storage and deduplication.
///
/// ## Cache values are `JSONValue` (#1993, Phase D1)
///
/// The value domain of this cache is `JSONValue`, not `Any`. That is what
/// makes the in-flight dedup `Task` and the `withTimeout` race carry a
/// `Sendable` payload — the fifteen Swift 6 `Sendable` error sites this file
/// used to hold were all the `Any` flowing through those two places, plus
/// `withTimeout`'s unconstrained generic.
///
/// It is not a new restriction in practice: the persistent tier has always
/// stored a JSON string (`saveToStorage`), so a value that isn't
/// JSON-representable never survived a restart anyway. The public generic
/// `fetchCached<T>` is unchanged — it bridges `T` into `JSONValue` on the way
/// in and materializes it back on the way out (`cacheValue(from:)` /
/// `materialize(_:as:)`), so `[String: Any]`, `String`, and `Codable` models
/// round-trip **within JSON's own value domain**.
///
/// That domain has one edge worth stating, because it is not a JSON-encoding
/// detail an app developer would expect from a Swift API: `JSONValue` has a
/// single numeric case, `.number(Double)` (`Types/JSONValue.swift`), so an
/// integer is exact only to 2^53 — the same bound JavaScript's `number` has.
/// `1234567890123456789` cached and read back is `1234567890123456768`, with
/// nothing thrown. Before Phase D1 the *memory* tier handed a caller its own
/// `Any` back untouched, so an `Int` survived until the process restarted (the
/// persistent tier has always gone through `JSONSerialization`). Cache an
/// integer wider than 2^53 as a `String` — the same advice `JSONValue`'s own
/// header note gives. Its other workaround, an `Int64` field on a `Codable`
/// model, does **not** apply here: a model cached through this type is lowered
/// to `JSONValue` on the way in, so its integer fields cross `Double` too.
/// `testIntegersWiderThanTwoToTheFiftyThreeLoseTheirLowBits` pins the bound.
///
/// ## An actor since #1993, Phase D2
///
/// The lock is gone: `memCache`, `inflightRequests`, `storageProvider` and the
/// user scope are actor-isolated, so the `@unchecked Sendable` opt-out and its
/// hand-written safety argument are replaced by compiler checking. No snapshot
/// holder survives — D2 enumerates none.
///
/// Two consequences worth knowing about:
///
/// * The **dedup decision region** (look up the in-flight task, or create and
///   register one) used to be atomic because it ran inside one `lock.withLock`.
///   Under actor isolation it is atomic because it contains no `await`. That is
///   load-bearing rather than incidental: the `Task` it registers re-enters the
///   cache through `set` and the emitter, so a suspension between the lookup
///   and the registration would let a second caller start a duplicate fetch.
///   The task body therefore lives in `makeFetchTask`, keeping the region
///   itself await-free by construction.
/// * The **emitter is supplied at construction** (`init(emit:)`). The old
///   `setEmitter` was a synchronous mutation of what is now actor state, and
///   `CacheFacade.init` — a synchronous initializer — was its only caller.
///   `JsBaoClient` builds its `KvCache` with the emitter attached instead, so
///   the facade no longer has to reach in after the fact.
public actor KvCache {
    private var memCache: [String: KvCacheRecord] = [:]
    private var inflightRequests: [String: Task<JSONValue, Error>] = [:]
    private var storageProvider: StorageProvider?
    private var userId: String?
    private var isInitialized = false

    /// Emits cache lifecycle events. Mirrors the JS `KvCache`'s `emitter`
    /// (`src/client/kv-cache.ts`): `cacheUpdated` on a successful network
    /// refresh and `cacheUpdateFailed` on a refresh error. Supplied by
    /// `JsBaoClient` at construction; when `nil` the cache is silent (so
    /// callers that construct `KvCache()` keep working).
    ///
    /// A `let` since Phase D2 — the emitter is part of the cache's
    /// construction, not something injected into a running actor.
    ///
    /// **It is invoked from `nonisolated` context, never while the actor is
    /// held** (`emitCacheUpdated` / `emitCacheUpdateFailed`, called from the
    /// fetch task after its isolated step returns). That is deliberate and
    /// load-bearing: `EventEmitter.dispatch` delivers callback subscribers
    /// **synchronously** (`Types/EventEmitter.swift`, and the `subscribe` doc
    /// says so), so this closure runs arbitrary app code. Emitting from an
    /// isolated step would put that app code on the cache's executor, where a
    /// slow `.cacheUpdated` handler serializes every cache operation and a
    /// handler that blocks on a lock held by a task awaiting `KvCache`
    /// deadlocks outright. Before the actor conversion the emit ran in the
    /// fetch `Task` body with no lock held, and `currentEmitter()` took the
    /// lock only long enough to *read* the closure; keeping the call off the
    /// actor preserves exactly that. `nonisolated` because the emitter is
    /// immutable and `Sendable`, so reading it needs no isolation.
    private nonisolated let emit: (@Sendable (any JsBaoEventPayload) -> Void)?

    private static let storeName = "kv"

    /// The persisted shape of a cache entry: the value as a JSON string.
    /// Shared by `loadFromStorage` and `saveToStorage` so the two can't drift.
    struct CacheValue: Codable {
        let json: String
    }

    public init(emit: (@Sendable (any JsBaoEventPayload) -> Void)? = nil) {
        self.emit = emit
    }

    /// Deprecated: the untyped `(JsBaoEvent, Any)` emit closure. Adapted onto
    /// the typed form so existing call sites keep working for one major cycle.
    ///
    /// Written as a second designated initializer rather than a `convenience`
    /// one because an actor has no convenience initializers (a hard error in
    /// the Swift 6 language mode, which Phase F flips this target to).
    @available(*, deprecated, message: "Use init(emit:) with a `(any JsBaoEventPayload) -> Void` closure — the untyped event surface is removed in the next major release.")
    public init(emit: @escaping @Sendable (JsBaoEvent, Any) -> Void) {
        self.emit = adaptUntypedEmit(emit)
    }

    #if DEBUG
    /// Test-only: push a payload through the injected emit closure without
    /// driving a whole network refresh. Used to assert the deprecated untyped
    /// closure is still adapted onto the typed one.
    func emitForTesting(_ payload: any JsBaoEventPayload) {
        emit?(payload)
    }
    #endif

    // MARK: - Setup

    public func setStorageProvider(_ provider: StorageProvider) {
        self.storageProvider = provider
    }

    public func setUserId(_ userId: String?) {
        self.userId = userId
        if userId == nil {
            memCache.removeAll()
            isInitialized = false
        }
    }

    // MARK: - Core Operations

    /// Fetch a value, using cache if available, with deduplication of in-flight
    /// requests.
    ///
    /// A thin generic shim over `fetchCachedValue`: the value is bridged into
    /// the cache's `JSONValue` domain on the way in and materialized back as
    /// `T` on the way out. `T` stays unconstrained, so existing callers using
    /// `[String: Any]`, `String` or `Any` compile and behave as before.
    ///
    /// `fetcher` is `@Sendable` because it always runs inside the dedup
    /// `Task` — that was already true, it just wasn't stated in the type.
    ///
    /// `nonisolated` on purpose: `T` is unconstrained, so letting it cross the
    /// actor boundary would make every `[String: Any]` caller a `Sendable`
    /// violation. Only `JSONValue` crosses; the bridging in and out happens on
    /// the caller's side of the boundary.
    public nonisolated func fetchCached<T>(
        key: String,
        fetcher: @escaping @Sendable () async throws -> T,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        let value = try await fetchCachedValue(
            key: key,
            fetcher: { try Self.cacheValue(from: try await fetcher()) },
            options: options
        )
        return Self.materialize(value, as: T.self)
    }

    /// The typed core of `fetchCached`: the whole cache path — in-memory hit,
    /// persistent-store load, in-flight dedup and the `serverTimeoutMs`
    /// bound — with `JSONValue` as the value type throughout.
    ///
    /// The three critical sections are still three separate uninterrupted
    /// isolated steps with `await`s between them, exactly as before (#1910):
    /// each one used to be a `lock.withLock` hold, and merging them would span
    /// a suspension.
    func fetchCachedValue(
        key: String,
        fetcher: @escaping @Sendable () async throws -> JSONValue,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> JSONValue {
        // Check in-memory cache
        let refreshNetwork = options.refreshNetwork ?? false
        let refreshIfOlderThanMs = options.refreshIfOlderThanMs

        if !refreshNetwork {
            // Region 1: in-memory cache check. Reading `memCache[key]` and
            // evaluating staleness happen with no suspension between them.
            let cached = memCache[key]
            if let cached = cached {
                // Check staleness
                if let maxAge = refreshIfOlderThanMs,
                   let updatedAt = cached.updatedAtMs {
                    let age = Date().timeIntervalSince1970 * 1000 - updatedAt
                    if age < Double(maxAge) {
                        return cached.value
                    }
                } else {
                    return cached.value
                }
            }

            // Region 2: persistent storage load (awaited with nothing held),
            // then a separate isolated step to write the loaded record into
            // memCache.
            if let record = await loadFromStorage(key: key) {
                if let maxAge = refreshIfOlderThanMs,
                   let updatedAt = record.updatedAtMs {
                    let age = Date().timeIntervalSince1970 * 1000 - updatedAt
                    if age < Double(maxAge) {
                        memCache[key] = record
                        return record.value
                    }
                } else {
                    memCache[key] = record
                    return record.value
                }
            }
        }

        // Region 3: in-flight request dedup. The existence check and the
        // new-task registration must be atomic. Under the lock that was one
        // `withLock` hold; under actor isolation it is the absence of `await`
        // between the two — which is why the task's body is built by
        // `makeFetchTask` rather than inline. The task itself may start running
        // on another thread the moment it is created — what it cannot do is
        // reach `inflightRequests`, because the only paths that touch the table
        // (`completeInflightFetch` / `failInflightFetch`) are actor-isolated and
        // this method holds the actor until its next suspension, which comes
        // after `inflightRequests[key] = task`. So the registration always wins
        // the race against its own removal. Awaiting the task happens below,
        // outside the critical region.
        let dedup: (task: Task<JSONValue, Error>, isExisting: Bool)
        if let existing = inflightRequests[key] {
            dedup = (existing, true)
        } else {
            let task = makeFetchTask(key: key, fetcher: fetcher)
            inflightRequests[key] = task
            dedup = (task, false)
        }

        let task = dedup.task
        if dedup.isExisting {
            return try await task.value
        }

        // Honor `serverTimeoutMs`: bound the network fetch. On timeout, fall
        // back to any cached (possibly stale) value; otherwise surface a
        // timeout error instead of hanging (#994). Defaults to 10s to match JS
        // (`Math.max(0, options?.serverTimeoutMs ?? 10000)`); an explicit `0`
        // disables the bound (JS's `Math.max(0, …)` floor → falsy → no timer).
        let timeoutMs = options.serverTimeoutMs ?? 10000
        if timeoutMs > 0 {
            do {
                return try await Self.withTimeout(ms: timeoutMs) {
                    try await task.value
                }
            } catch is CacheTimeoutError {
                if let stale = await self.get(key: key) { return stale }
                throw JsBaoError(
                    code: .listTimeout,
                    message: "Cache fetch exceeded serverTimeoutMs (\(timeoutMs)ms)"
                )
            }
        }

        return try await task.value
    }

    /// Build (but do not register) the task that runs one network fetch for
    /// `key`. Split out of `fetchCachedValue` so the dedup decision region
    /// stays free of `await` — see the comment there.
    ///
    /// The in-flight entry is cleared on both paths. Under the lock that was a
    /// `defer`; a `defer` cannot `await`, so the cleanup moved into the two
    /// isolated completion steps below.
    ///
    /// `nonisolated` on purpose, and load-bearing twice over. An unstructured
    /// `Task` created in actor-isolated context inherits that isolation, so
    /// building this task from an isolated method would (a) make the body wait
    /// on the cache's executor before it could even call `fetcher()` and
    /// (b) put the `emit` calls below back on the actor — the very thing the
    /// `emit` property's note says must not happen. Built from `nonisolated`
    /// context the body runs on the general executor: the isolated steps hop
    /// on and off explicitly, and the emit lands squarely between hops, with
    /// the actor free.
    private nonisolated func makeFetchTask(
        key: String,
        fetcher: @escaping @Sendable () async throws -> JSONValue
    ) -> Task<JSONValue, Error> {
        Task<JSONValue, Error> { [weak self] in
            do {
                let value = try await fetcher()
                await self?.completeInflightFetch(key: key, value: value)
                self?.emitCacheUpdated(key: key, value: value)
                return value
            } catch {
                await self?.failInflightFetch(key: key)
                self?.emitCacheUpdateFailed(key: key, error: error)
                throw error
            }
        }
    }

    /// Store the fetched value, then drop the in-flight entry — in that order,
    /// so a caller arriving mid-store still joins the in-flight task instead of
    /// starting a second fetch.
    ///
    /// The `cacheUpdated` emit deliberately does **not** happen here: it runs
    /// after this step returns, off the actor (see `makeFetchTask` and the
    /// `emit` property). A subscriber cannot observe `inflightRequests`, so
    /// moving the emit past the removal changes nothing it can see.
    private func completeInflightFetch(key: String, value: JSONValue) async {
        await set(key: key, value: value)
        inflightRequests.removeValue(forKey: key)
    }

    /// Drop the in-flight entry after a failed fetch. Dropping it is what keeps
    /// a thrown `fetcher()` from leaving a stale task that makes every later
    /// call for the same key re-throw the original error forever. The
    /// `cacheUpdateFailed` emit runs off the actor, as above.
    private func failInflightFetch(key: String) {
        inflightRequests.removeValue(forKey: key)
    }

    /// Mirror JS `KvCache`: fire `cacheUpdated` after a successful network
    /// refresh (`src/client/kv-cache.ts`). `source` is always "server" — this
    /// only runs on the network path.
    ///
    /// `CacheUpdatedEvent.value` is `Any?`, and what travels in it changed in
    /// Phase D1: it used to be whatever the caller's own fetcher returned, and
    /// is the `JSONSerialization` graph of the cached `JSONValue` now, because
    /// that is all the cache retains. Callers that subscribe to `.cacheUpdated`
    /// and pass their own typed fetcher must read the payload as a JSON graph
    /// (`event.value as? [String: Any]`), not as their model type — a runtime
    /// change with no compile error, so it is called out in `CHANGELOG.md` and
    /// pinned by `testCacheUpdatedCarriesTheJSONGraphNotTheFetcherValue`.
    ///
    /// `nonisolated` so the synchronous subscriber fan-out inside
    /// `EventEmitter.dispatch` never runs on the cache's executor.
    private nonisolated func emitCacheUpdated(key: String, value: JSONValue) {
        emit?(
            CacheUpdatedEvent(
                key: key,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                source: "server",
                value: try? JSONCoding.jsonObject(from: value)
            )
        )
    }

    /// Mirror JS `KvCache`: fire `cacheUpdateFailed` on a refresh error
    /// (`src/client/kv-cache.ts`) before the caller rethrows. `nonisolated` for
    /// the same reason as `emitCacheUpdated`.
    private nonisolated func emitCacheUpdateFailed(key: String, error: Error) {
        emit?(
            CacheUpdateFailedEvent(
                key: key,
                error: (error as? JsBaoError)?.message ?? "\(error)"
            )
        )
    }

    private struct CacheTimeoutError: Error {}

    /// Race an async operation against a timeout, throwing `CacheTimeoutError`
    /// if `ms` elapses first.
    ///
    /// `R: Sendable` because the result crosses the task-group boundary — the
    /// constraint the Swift 6 language mode requires and the only thing that
    /// was ever missing here. The sole caller passes `JSONValue`.
    private static func withTimeout<R: Sendable>(ms: Int, _ op: @escaping @Sendable () async throws -> R) async throws -> R {
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
    func set(key: String, value: JSONValue) async {
        let now = Date()
        let record = KvCacheRecord(
            key: key,
            value: value,
            updatedAt: ISO8601DateFormatter().string(from: now),
            updatedAtMs: now.timeIntervalSince1970 * 1000
        )

        memCache[key] = record

        await saveToStorage(key: key, record: record)
    }

    /// Get a value from cache (memory first, then storage).
    ///
    /// `internal` (not `public`): mirrors JS, which exposes no direct cache
    /// read. Still used internally by `fetchCached` (stale fallback) and the
    /// same-module `CacheFacade`.
    func get(key: String) async -> JSONValue? {
        if let cached = memCache[key] {
            return cached.value
        }

        if let record = await loadFromStorage(key: key) {
            memCache[key] = record
            return record.value
        }

        return nil
    }

    /// Get cache entry info
    public func info(key: String) async -> (updatedAt: String?, ageMs: Double?) {
        let cached = memCache[key]

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
        memCache.removeValue(forKey: key)

        if let provider = storageProvider {
            try? await provider.delete(store: Self.storeName, key: key)
        }
    }

    /// Clear all cache entries
    public func clearAll() async {
        memCache.removeAll()

        if let provider = storageProvider {
            try? await provider.clear(store: Self.storeName)
        }
    }

    // MARK: - Private

    private func loadFromStorage(key: String) async -> KvCacheRecord? {
        guard let provider = storageProvider else { return nil }
        guard let record: StorageRecord<CacheValue> = try? await provider.get(store: Self.storeName, key: key) else {
            return nil
        }
        let value: JSONValue
        if let data = record.value.json.data(using: .utf8),
           let parsed = try? JSONCoding.decodeData(JSONValue.self, from: data) {
            value = parsed
        } else {
            // Entries written before #1993 stored a non-JSON value as its bare
            // `String(describing:)` text (unquoted, so it doesn't parse). Read
            // it back as a string rather than dropping the entry — the same
            // fallback the pre-#1993 reader had.
            value = .string(record.value.json)
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
        let json: String
        if let data = try? JSONCoding.encodeData(record.value),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "null"
        }
        let metadata: [String: String] = [
            "updatedAt": record.updatedAt ?? "",
            "updatedAtMs": record.updatedAtMs.map { String($0) } ?? "",
        ]
        try? await provider.put(store: Self.storeName, key: key, value: CacheValue(json: json), metadata: metadata)
    }
}

// MARK: - Cache Record

struct KvCacheRecord: Sendable {
    let key: String
    let value: JSONValue
    let updatedAt: String?
    let updatedAtMs: Double?
}

// MARK: - Bridging the generic surface onto the JSONValue core

extension KvCache {
    /// Bridge a caller-supplied value into the cache's `JSONValue` domain.
    ///
    /// The conversion itself is `JSONValue.init(jsonAny:subject:)` — shared with
    /// the analytics queue since #1993 Phase D3, which needs exactly the same
    /// `Any` → `JSONValue` lowering at its own untyped entry point. This
    /// wrapper only supplies the cache's wording for the rejection message.
    static func cacheValue(from value: Any) throws -> JSONValue {
        try JSONValue(jsonAny: value, subject: "KvCache values")
    }

    /// Materialize a cached `JSONValue` as the type the caller asked for.
    ///
    /// Mirrors the old `value as? T`: the value is bridged back to the
    /// `JSONSerialization` graph and cast. A `Decodable` `T` that the cast
    /// can't satisfy (a `Codable` model, say) is decoded from the graph
    /// instead, which is more than the old dynamic cast managed.
    /// Returns `nil` when the cached value isn't a `T`.
    ///
    /// **The decode has to be checked, not just attempted.** A `Decodable`
    /// whose stored properties are all optional decodes successfully from
    /// *any* JSON object, so a bare `try?` would turn a shape mismatch — a key
    /// collision, or an entry written under an earlier schema — into an
    /// all-defaults model where the old `value as? T` returned `nil` and the
    /// caller refetched. Silently wrong data is worse than a cache miss, so a
    /// decode from an object is accepted only if it consumed at least one key
    /// that was actually there (`decodeConsumedSourceKeys`). A model that
    /// legitimately holds nothing from the entry is reported as a miss, which
    /// is the conservative direction: the caller refetches.
    static func materialize<T>(_ value: JSONValue?, as _: T.Type) -> T? {
        guard let value = value else { return nil }
        // Hand back the enum ONLY when the caller asked for exactly that type.
        // A bare `value as? T` looks equivalent but is not: it also succeeds
        // for `T == Any` (and for any protocol `JSONValue` happens to conform
        // to), which would hand an `Any`-typed caller the enum where it
        // expects the JSON graph. `UsersAPI.getBasic` is exactly that caller,
        // and it feeds the result straight to `JSONSerialization`.
        if T.self == JSONValue.self, let typed = value as? T { return typed }
        guard let graph = try? JSONCoding.jsonObject(from: value) else { return nil }
        if let direct = graph as? T { return direct }
        if let decodableType = T.self as? any Decodable.Type,
           let decodable = try? decodableType.decodeFromJSONGraph(graph),
           let decoded = decodable as? T,
           decodeConsumedSourceKeys(decoded: decodable, source: graph) {
            return decoded
        }
        return nil
    }

    /// Did decoding `decoded` actually take anything from `source`?
    ///
    /// Only object-shaped entries are checked — an array or a scalar cannot
    /// decode into a mismatched shape without `JSONDecoder` throwing, so there
    /// is nothing to guard there and those decodes are accepted as-is.
    ///
    /// For an object the test is: re-encode the decoded value and require at
    /// least one of its keys to be present in the source graph. An
    /// all-optional model decoded from an unrelated object re-encodes to `{}`
    /// (synthesized `encode(to:)` uses `encodeIfPresent`, so `nil` fields are
    /// omitted), which shares no key and is rejected. A model that really did
    /// read a field re-encodes with that field present, and is accepted.
    private static func decodeConsumedSourceKeys(decoded: Any, source: Any) -> Bool {
        guard let sourceObject = source as? [String: Any] else { return true }
        guard let encodable = decoded as? any Encodable,
              let roundTrip = try? encodable.encodeToJSONGraph(),
              let decodedObject = roundTrip as? [String: Any]
        else {
            // Not re-encodable (a `Decodable`-only type) — there is nothing to
            // compare, so keep the decode rather than manufacture a miss.
            return true
        }
        return decodedObject.keys.contains { sourceObject[$0] != nil }
    }
}

private extension Decodable {
    /// Decode `Self` from a `JSONSerialization` graph. Written as a static
    /// protocol member so it can be called on an opened `any Decodable.Type`.
    static func decodeFromJSONGraph(_ graph: Any) throws -> Self {
        try JSONCoding.decode(Self.self, from: graph)
    }
}

private extension Encodable {
    /// Re-encode `Self` to a `JSONSerialization` graph. A protocol member for
    /// the same reason as `decodeFromJSONGraph`: it has to be callable on an
    /// `any Encodable` existential.
    func encodeToJSONGraph() throws -> Any {
        try JSONCoding.jsonObject(from: self)
    }
}

// MARK: - Cache Facade

/// High-level cache API wrapping KvCache with HTTP-aware caching.
///
/// ## `@unchecked Sendable` safety argument
///
/// The facade has **no mutable state at all**: all three stored properties are
/// `let`, assigned in `init` and never rebound. Two of them are already safe to
/// share (`KvCache` is an actor; `Transport` is `Sendable`); the third,
/// `getNetworkMode`, is a closure the client supplies at construction whose
/// body reads the network mode through `AuthController`'s lock. So there is no
/// field a second thread can observe mid-write, and no lock to reason about —
/// the opt-out exists only because the closure is not typed `@Sendable`
/// (widening it is a public-signature change, so it belongs with the surface
/// work in a later phase, not here).
///
/// It stays a class rather than becoming an actor deliberately: it holds
/// nothing to isolate, and making it one would put an `await` on every
/// `client.cache` call for no safety gain.
public final class CacheFacade: @unchecked Sendable {
    private let kvCache: KvCache
    private let getNetworkMode: () -> NetworkMode
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    ///
    /// There is no `emit` parameter since #1993 Phase D2. The cache's emitter
    /// belongs to `KvCache.init(emit:)` now: `KvCache` is an actor, so a
    /// synchronous initializer cannot reach in and set it afterwards, and a
    /// parameter that quietly dropped the caller's closure would be worse than
    /// no parameter at all. `JsBaoClient` supplies the emitter where the cache
    /// is constructed.
    public init(
        kvCache: KvCache,
        getNetworkMode: @escaping () -> NetworkMode,
        transport: any Transport
    ) {
        self.kvCache = kvCache
        self.getNetworkMode = getNetworkMode
        self.transport = transport
    }

    /// Deprecated: construct with a `Transport` instead. The legacy closure is
    /// wrapped in an adapter so existing call sites keep working for one major
    /// cycle.
    @available(*, deprecated, message: "Use init(kvCache:getNetworkMode:transport:) — the untyped makeRequest closure is removed in the next major release.")
    public convenience init(
        kvCache: KvCache,
        getNetworkMode: @escaping () -> NetworkMode,
        makeRequest: @escaping (String, String, Any?) async throws -> Any
    ) {
        self.init(
            kvCache: kvCache,
            getNetworkMode: getNetworkMode,
            transport: ClosureTransport(makeRequest: makeRequest)
        )
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
        fetcher: @escaping @Sendable () async throws -> T,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> T? {
        let value = try await fetchCachedValue(
            key: key,
            fetcher: { try KvCache.cacheValue(from: try await fetcher()) },
            options: options
        )
        return KvCache.materialize(value, as: T.self)
    }

    /// The typed core of this facade: `waitForLoad` + offline gating over
    /// `KvCache`'s `JSONValue` path. Both the generic `fetchCached` and
    /// `fetchCachedJSON` sit on it, so the policy lives in one place.
    ///
    /// Returns `nil` only for a `.local` read that finds nothing cached — every
    /// other branch either resolves a value or throws.
    private func fetchCachedValue(
        key: String,
        fetcher: @escaping @Sendable () async throws -> JSONValue,
        options: FetchCachedOptions
    ) async throws -> JSONValue? {
        let mode = getNetworkMode()
        let isOffline = mode == .offline
        let waitForLoad = options.waitForLoad ?? .localIfAvailableElseNetwork

        // `.local`: pure cache read, never touches the network.
        if waitForLoad == .local {
            return await kvCache.get(key: key)
        }

        // `.network`: force the network fetch (skip the cache-hit
        // short-circuit). When offline, fall back to cache or throw.
        if waitForLoad == .network {
            if isOffline {
                if let cached = await kvCache.get(key: key) { return cached }
                throw JsBaoError(
                    code: .listUnavailableOffline,
                    message: "Cache fetch unavailable offline (key: \(key))"
                )
            }
            var forced = options
            forced.refreshNetwork = true
            return try await kvCache.fetchCachedValue(key: key, fetcher: fetcher, options: forced)
        }

        // `.localIfAvailableElseNetwork` (default).
        // When offline, serve from cache or throw — never fetch.
        if isOffline {
            if let cached = await kvCache.get(key: key) { return cached }
            throw JsBaoError(
                code: .listUnavailableOffline,
                message: "Cache fetch unavailable offline (key: \(key))"
            )
        }

        // Online/auto: defer to the low-level fetcher, which returns the
        // cached value when present (honoring refreshNetwork /
        // refreshIfOlderThanMs) and otherwise fetches.
        return try await kvCache.fetchCachedValue(key: key, fetcher: fetcher, options: options)
    }

    /// Cache-aware fetch of a JSON document, typed end to end as
    /// `JSONValue` — the caller never handles an `Any` graph.
    ///
    /// Since #1993 this is the cache's native value type all the way down, so
    /// there is no bridging hop: `KvCache` stores `JSONValue` in memory and
    /// the same JSON text on disk that earlier builds wrote, so a cache
    /// written by an earlier build still loads.
    ///
    /// A fetcher that yields `nil` (an empty 2xx body — "no such record") is
    /// cached as JSON `null` and resolves to `nil` here, matching the `NSNull`
    /// sentinel the pre-#1993 implementation stored.
    func fetchCachedJSON(
        key: String,
        fetcher: @escaping @Sendable () async throws -> JSONValue?,
        options: FetchCachedOptions = FetchCachedOptions()
    ) async throws -> JSONValue? {
        let value = try await fetchCachedValue(
            key: key,
            fetcher: { try await fetcher() ?? .null },
            options: options
        )
        guard let value = value, !value.isNull else { return nil }
        return value
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
        // An unknown verb is rejected rather than silently downgraded to
        // `GET`: this is a public entry point taking a `String`, and issuing
        // a different request than the caller asked for is worse than
        // failing.
        guard let verb = HTTPMethod(rawValue: method.uppercased()) else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Unsupported HTTP method \"\(method)\""
            )
        }
        var keyParams = query ?? [:]
        if let body = body, verb.allowsBody {
            keyParams["__body"] = Self.stableBodyKey(body)
        }
        let cacheKey = self.key(keyBase ?? path, params: keyParams.isEmpty ? nil : keyParams)
        let requestPath = Self.appendQuery(to: path, query: query)
        // Route through `fetchCachedJSON` so HTTP requests honor `waitForLoad`
        // and offline gating, not just the low-level cache logic. The response
        // is already a `JSONValue` on the typed transport, which is also the
        // cache's value type — the `T` cast happens once, at the end.
        // An empty 2xx body still yields `nil` (`requestOptional`).
        // GET/HEAD carry no body — the legacy `encodeLegacyBody` path
        // dropped it too, so a `fetchHttp(method: "GET", body:)` still
        // sends a bodyless GET.
        let encodedBody: JSONValue? = verb.allowsBody
            ? try body.map { try JSONCoding.decode(JSONValue.self, from: $0) }
            : nil
        let value = try await self.fetchCachedJSON(key: cacheKey, fetcher: {
            () async throws -> JSONValue? in
            if let encodedBody = encodedBody {
                return try await self.transport.requestOptional(
                    method: verb, path: requestPath, body: encodedBody
                )
            }
            return try await self.transport.requestOptional(
                method: verb, path: requestPath
            )
        }, options: options)
        return KvCache.materialize(value, as: T.self)
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
