import Foundation

// MARK: - LocksAPI

/// Sub-API for the named lock service (`client.locks.*`). Mirrors the JS
/// client's `LocksAPI` (`src/client/api/locksApi.ts`, issue #1518)
/// method-for-method.
///
/// A caller acquires a lease on an app-scoped, caller-chosen key, does its
/// exclusive work, then releases. `ttl` is mandatory, so a crashed holder
/// never wedges the key — the lease expires and the next acquirer takes over.
/// It is a `TimeInterval` in **seconds** (renamed from `ttlMs: Int` in #2367);
/// the request body still carries a `ttlMs` JSON key.
/// Blocking `acquire` is a client-side poll loop over the one-shot server
/// endpoint.
///
/// Swift has no async `defer`, so release on both the success and the failure
/// path — and `await` it, so the key is actually free when you return:
///
/// ```swift
/// guard let handle = try await client.locks.tryAcquire(key: "import:daily", ttl: 60) else {
///     return  // someone else is already importing
/// }
/// do {
///     try await runImport()
/// } catch {
///     _ = try? await client.locks.release(handle)
///     throw error
/// }
/// _ = try? await client.locks.release(handle)
/// ```
///
/// Semantics are fixed by the server:
/// - The lease is mandatory and capped server-side at 24h.
/// - `handleId` is opaque and required by `release` / `renew`; it is what
///   proves holder identity to the lock service. The Swift client does not
///   surface a fencing token yet — see #2005 for the parity follow-up.
/// - Fairness is racy — waiters are not queued, so a blocking `acquire` may
///   lose to a later arrival.
/// - Re-acquiring a key you already hold is contention, **not** re-entrancy:
///   the server answers `acquired: false` and you must `renew` instead.
public final class LocksAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Poll cadence used when the server offers no `retryAfterMs`. Mirrors the
    /// JS client's `DEFAULT_RETRY_AFTER_MS`.
    static let defaultRetryAfterMs = 250

    /// Cap on the backoff derived from a 429's `retryAfter`. The acquire
    /// rate-limit window is an hour, so a fully-exhausted bucket can report a
    /// very large `retryAfter`; clamp it so a blocking `acquire` keeps polling
    /// at a sane cadence (and re-checks its own `timeoutMs`) instead of
    /// sleeping for minutes at a time. Mirrors JS `MAX_RATE_LIMIT_BACKOFF_MS`.
    static let maxRateLimitBackoffMs = 30_000

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Acquire

    /// One non-blocking attempt at the server endpoint. Returns the raw
    /// response so both `tryAcquire` and the blocking `acquire` loop can read
    /// the contention detail.
    private func acquireOnce(key: String, ttlMs: Int) async throws -> LockAcquireResponse {
        try await transport.request(
            method: .post,
            path: "/locks/acquire",
            body: LockAcquireRequest(key: key, ttlMs: ttlMs)
        )
    }

    /// Single non-blocking attempt. Returns the handle on success, or `nil`
    /// when the key is currently held by a live lease (including one held by
    /// the calling user).
    ///
    /// Unlike the blocking `acquire`, a rate-limit 429 is **not** swallowed
    /// here — it surfaces to the caller as an `HttpError`.
    public func tryAcquire(key: String, ttl: TimeInterval) async throws -> LockHandle? {
        let res = try await acquireOnce(key: key, ttlMs: ttl.wholeMilliseconds)
        return res.acquired ? res.handle : nil
    }

    /// Block until the lock is acquired or `timeout` elapses.
    ///
    /// Polls the acquire endpoint with jittered backoff (honoring the server's
    /// `retryAfterMs`), then throws `JsBaoError(code: .lockTimeout)` if it never
    /// wins the key within the window. The thrown error's `details` carry the
    /// contended `key` and the timeout that elapsed — the same payload as
    /// the JS client's `LockTimeoutError`.
    ///
    /// - Parameters:
    ///   - key: The caller-chosen lock key.
    ///   - ttl: Lease duration once acquired (capped server-side at 24h).
    ///   - timeout: How long to wait for the lock before throwing. Saturates
    ///     at ``TimeInterval/maxWholeMilliseconds`` (~292 years), so
    ///     `.infinity` means "wait indefinitely" rather than trapping.
    public func acquire(key: String, ttl: TimeInterval, timeout: TimeInterval) async throws -> LockHandle {
        let ttlMs = ttl.wholeMilliseconds
        let timeoutMs = timeout.wholeMilliseconds
        let deadline = Self.deadline(timeoutMs: timeoutMs)
        while true {
            var base = Self.defaultRetryAfterMs
            do {
                let res = try await acquireOnce(key: key, ttlMs: ttlMs)
                if res.acquired, let handle = res.handle { return handle }
                if let retryAfterMs = res.retryAfterMs, retryAfterMs > 0 {
                    base = retryAfterMs
                }
            } catch {
                // The server rate-limits every acquire attempt and deliberately
                // counts each blocking poll, so a sustained wait on a contended
                // key can trip its own 429. Treat that as "not acquired yet":
                // back off (honoring the server's retry hint) and keep polling
                // until `timeoutMs`, then throw `.lockTimeout` as normal. Only
                // 429 is swallowed — every other error (auth, network, 5xx)
                // still propagates.
                guard let backoff = Self.rateLimitBackoffMs(error) else { throw error }
                base = backoff
            }

            let now = Date()
            if now >= deadline { throw Self.timeoutError(key: key, timeoutMs: timeoutMs) }

            let jitter = Int.random(in: 0..<max(1, base / 2))
            let remainingMs = Int((deadline.timeIntervalSince(now) * 1000).rounded())
            let wait = min(base + jitter, remainingMs)
            if wait <= 0 { throw Self.timeoutError(key: key, timeoutMs: timeoutMs) }
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
        }
    }

    // MARK: - Release / renew

    /// Release a held lock. The handle carries its own key.
    ///
    /// Losing the lock is not an error: a handle that no longer holds the key
    /// comes back as `released == false` with a `reason`.
    @discardableResult
    public func release(_ handle: LockHandle) async throws -> LockReleaseResult {
        try await transport.request(
            method: .post,
            path: "/locks/release",
            body: LockReleaseRequest(
                key: handle.key,
                handle: LockHandleRef(handleId: handle.handleId)
            )
        )
    }

    /// Extend a held lease. Returns `renewed == false` (reason `"lease_lost"`)
    /// if the handle no longer holds the key.
    @discardableResult
    public func renew(_ handle: LockHandle, ttl: TimeInterval) async throws -> LockRenewResult {
        try await transport.request(
            method: .post,
            path: "/locks/renew",
            body: LockRenewRequest(
                key: handle.key,
                handle: LockHandleRef(handleId: handle.handleId),
                ttlMs: ttl.wholeMilliseconds
            )
        )
    }

    // MARK: - Inspection

    /// Current holder of a key, or `held == false` when free or lease-expired.
    ///
    /// The key rides in the request body (not the path) because caller-chosen
    /// keys may contain `:` and `/`.
    public func status(key: String) async throws -> LockStatus {
        try await transport.request(
            method: .post,
            path: "/locks/status",
            body: LockStatusRequest(key: key)
        )
    }

    /// List all currently-held locks in the app. Requires an app admin token.
    public func list() async throws -> LockListResult {
        try await transport.request(method: .get, path: "/locks")
    }

    // MARK: - Helpers

    /// The instant a blocking `acquire` gives up, derived from the **clamped**
    /// millisecond bound rather than the raw `TimeInterval` the caller passed.
    ///
    /// This is what keeps the poll loop's remaining-time arithmetic safe.
    /// `Date().addingTimeInterval(timeout)` with `timeout: .infinity` yields a
    /// deadline whose `timeIntervalSince(now)` is also infinite, and the loop
    /// converts that remainder with `Int(_:)` — which traps on a non-finite or
    /// out-of-range `Double`. `timeoutMs` has already been through
    /// ``TimeInterval/wholeMilliseconds``, so it is finite and bounded by
    /// ``TimeInterval/maxWholeMilliseconds``; a deadline built from it is
    /// finite by construction and the remainder always fits in an `Int`.
    ///
    /// Before #2367 the parameter was `timeoutMs: Int` and could not express
    /// an infinite wait, so the trap surface arrived with the `TimeInterval`
    /// migration.
    static func deadline(timeoutMs: Int, from now: Date = Date()) -> Date {
        now.addingTimeInterval(Double(timeoutMs) / 1000)
    }

    /// The `.lockTimeout` error a blocking `acquire` raises at its deadline.
    /// Mirrors the JS client's `LockTimeoutError` message and `details`.
    static func timeoutError(key: String, timeoutMs: Int) -> JsBaoError {
        JsBaoError(
            code: .lockTimeout,
            message: "Timed out after \(timeoutMs)ms waiting to acquire lock \"\(key)\"",
            details: ["key": .string(key), "timeoutMs": .number(Double(timeoutMs))]
        )
    }

    /// If `error` is the 429 the server raises when a blocking `acquire`'s own
    /// polling trips the per-user acquire rate limit, return the suggested
    /// backoff in ms; otherwise `nil` so the caller rethrows.
    ///
    /// `HttpClient` surfaces non-2xx responses as `HttpError`, so the status is
    /// read directly and the server's `retryAfter` (seconds) is taken from the
    /// JSON body when present, falling back to the default poll cadence.
    static func rateLimitBackoffMs(_ error: Error) -> Int? {
        guard let http = error as? HttpError, http.status == 429 else { return nil }
        if let seconds = retryAfterSeconds(fromBody: http.body), seconds > 0 {
            return min(Int((seconds * 1000).rounded()), maxRateLimitBackoffMs)
        }
        return defaultRetryAfterMs
    }

    /// The rate-limit error body, typed so the parse stays on `Codable` rather
    /// than an untyped JSON graph. The server nests `retryAfter` (seconds)
    /// under `details`; a top-level copy is accepted too.
    private struct RateLimitBody: Decodable {
        struct Details: Decodable { let retryAfter: Double? }
        let details: Details?
        let retryAfter: Double?
    }

    /// Pull `details.retryAfter` (or a top-level `retryAfter`), in seconds, out
    /// of a rate-limit error body.
    private static func retryAfterSeconds(fromBody body: String?) -> Double? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONCoding.decoder.decode(RateLimitBody.self, from: data)
        else { return nil }
        guard let seconds = parsed.details?.retryAfter ?? parsed.retryAfter else { return nil }
        return seconds.isFinite ? seconds : nil
    }
}
