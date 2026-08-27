import Foundation

extension TimeInterval {
    /// This interval as the whole milliseconds the wire format,
    /// `withTimeout(ms:)` and the client's own millisecond thresholds speak.
    ///
    /// The `*Ms: Int` → `TimeInterval` migration (#2367) turned this
    /// conversion into a repo-wide idiom at every wire boundary, so it has one
    /// home rather than nine copies. The JSON keys did not change — only the
    /// Swift parameters did.
    ///
    /// Negatives clamp to `0`, matching js-bao's `Math.max(0, …)` floor on the
    /// same options. That is not cosmetic: `withTimeout(ms:)` converts to
    /// `UInt64`, so a negative would trap.
    ///
    /// The top end is clamped too, and for the same reason. `Int(_:)` traps on
    /// a non-finite or out-of-range `Double`, and the `Int` parameters this
    /// migration replaced could not express those values — `.infinity` or
    /// `1e30` as a lock TTL or workflow timeout would have terminated the
    /// process. `.nan` floors to `0` (`Swift.max(0, .nan)` is `0`, since every
    /// comparison against NaN is false); anything above the ceiling, including
    /// `.infinity`, saturates to ``maxWholeMilliseconds``.
    ///
    /// Named `wholeMilliseconds`, not `milliseconds`: `TimeInterval` is a
    /// `typealias` for `Double`, so a bare `milliseconds` would offer itself on
    /// every `Double` in the module — byte counts and elapsed-time scalars
    /// included — and read as if any of them were a duration. It is not
    /// `wireMilliseconds` either, because three of the nine callers
    /// (`analyticsAutoEvents.minResume` / `.syncErrorsMinInterval`,
    /// `FetchCachedOptions.refreshIfOlderThan`) compare the result locally
    /// rather than sending it.
    var wholeMilliseconds: Int {
        let seconds = Swift.max(0, self)
        guard seconds.isFinite else { return Self.maxWholeMilliseconds }
        let ms = (seconds * 1000).rounded()
        guard ms < Double(Self.maxWholeMilliseconds) else {
            return Self.maxWholeMilliseconds
        }
        return Int(ms)
    }

    /// The ceiling ``wholeMilliseconds`` saturates to: about 292 years, so it
    /// is unreachable as a real duration and any caller hitting it meant
    /// "never time out".
    ///
    /// It is `Int.max / 1_000_000` rather than `Int.max` because
    /// `withTimeout(ms:)` multiplies by 1_000_000 to reach nanoseconds —
    /// saturating at `Int.max` would just move the trap into that
    /// multiplication.
    static var maxWholeMilliseconds: Int { Int.max / 1_000_000 }
}

/// Thrown by `withTimeout(ms:_:)` when the operation didn't finish in time.
/// Callers map it to whatever typed `JsBaoError` their surface promises —
/// `KvCache` to `.listTimeout` after a stale-value fallback, `MeAPI` to
/// `.listTimeout` directly.
struct AsyncTimeoutError: Error {}

/// Race an async operation against a timeout, throwing `AsyncTimeoutError`
/// if `ms` elapses first.
///
/// `R: Sendable` because the result crosses the task-group boundary — the
/// constraint the Swift 6 language mode requires.
///
/// Shared by every `serverTimeoutMs` implementation in the client so the
/// bound means the same thing everywhere (#2360); the timeout *policy* on
/// expiry stays with each caller.
func withTimeout<R: Sendable>(
    ms: Int,
    _ op: @escaping @Sendable () async throws -> R
) async throws -> R {
    try await withThrowingTaskGroup(of: R.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            throw AsyncTimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw AsyncTimeoutError() }
        return first
    }
}
