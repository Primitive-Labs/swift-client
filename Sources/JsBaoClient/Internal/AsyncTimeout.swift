import Foundation

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
