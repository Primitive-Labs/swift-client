import Foundation
@testable import JsBaoClient

/// `op`, failing with `BoundedWaitTimeout` once `seconds` pass. Unlike
/// `within`, the wait does not join `op`: one that never returns (a red run,
/// a release that deadlocked) is left behind rather than holding the test.
func settles(
    within seconds: Double, _ what: String, _ op: @escaping @Sendable () async throws -> Void
) async throws {
    let outcome = Db3Settlement()
    Task {
        do {
            try await op()
            outcome.settle(.success(()))
        } catch {
            outcome.settle(.failure(error))
        }
    }
    Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        outcome.settle(.failure(BoundedWaitTimeout(description: "\(what) did not finish within \(seconds)s")))
    }
    try await outcome.wait()
}
