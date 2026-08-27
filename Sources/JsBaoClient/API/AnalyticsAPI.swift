import Foundation

// MARK: - AnalyticsAPI

/// `client.analytics` namespace. Mirrors js-bao's `AnalyticsClient`
/// interface (`logEvent` / `logSnapshot` / `flush` / `setPlanOverride` /
/// `setAppVersionOverride`). All calls fan out to the shared
/// `AnalyticsQueue` the client owns; this type holds no buffer of its own.
///
/// ## The synchronous members are deprecated (#1993, Phase D3)
///
/// `AnalyticsQueue` is an `actor` now, so its work is `async`. Every member
/// below therefore comes in two shapes:
///
/// * the original **synchronous** one, kept for the deprecation window. It
///   hands the work to an unstructured `Task` and returns immediately, so two
///   consecutive calls are not ordered against each other and a `flush()` may
///   run before an event logged just before it has been buffered. That event is
///   not lost — it goes out with the next batch — but it is not in *this* one.
/// * the **`Async` twin**, which does the work on the caller's task. Two
///   awaited calls are ordered, and `flushAsync()` returns only once the batch
///   has reached the socket.
///
/// The twins carry a distinct name rather than being `async` overloads of the
/// same name on purpose: Swift prefers an `async` overload in an asynchronous
/// context, so a same-name twin turns every existing un-`await`ed call in an
/// `async` function into a compile error — exactly the source break the
/// deprecation window exists to avoid.
public final class AnalyticsAPI: Sendable {
    private let queue: AnalyticsQueue
    /// Resolves the current user id (ULID) for `logSnapshot`. Returns
    /// nil when there is no authenticated user.
    private let resolveUserUlid: @Sendable () -> String?

    public init(
        queue: AnalyticsQueue,
        resolveUserUlid: @escaping @Sendable () -> String?
    ) {
        self.queue = queue
        self.resolveUserUlid = resolveUserUlid
    }

    // MARK: - logEvent

    /// Log a typed analytics event, returning once it is buffered. The queue
    /// fills in `user_ulid`, `timestamp`, and any plan / app-version overrides.
    public func logEventAsync(_ event: AnalyticsEventInput) async {
        await queue.logEvent(event)
    }

    // MARK: - logSnapshot

    /// Log a point-in-time state snapshot for the current user, returning once
    /// it is buffered. No-ops when there is no authenticated user.
    public func logSnapshotAsync(context: JSONValue? = nil) async {
        guard let event = snapshotEvent(context: context) else { return }
        await queue.logEvent(event)
    }

    private func snapshotEvent(context: JSONValue?) -> AnalyticsEventInput? {
        guard let userUlid = resolveUserUlid() else { return nil }
        return AnalyticsEventInput(
            action: "_snapshot",
            feature: "_state",
            user_ulid: userUlid,
            context_json: context
        )
    }

    // MARK: - flush

    /// Flush pending analytics events, returning once the batch has reached
    /// the socket (or, on a send failure, once it has been re-buffered and
    /// persisted).
    public func flushAsync() async {
        await queue.flushAndWait()
    }

    // MARK: - Overrides

    /// Override the plan field on all subsequent analytics events, returning
    /// once the override is in effect.
    public func setPlanOverrideAsync(_ plan: String?) async {
        await queue.setPlanOverride(plan)
    }

    /// Override the app-version field on all subsequent analytics events,
    /// returning once the override is in effect.
    public func setAppVersionOverrideAsync(_ version: String?) async {
        await queue.setAppVersionOverride(version)
    }
}
