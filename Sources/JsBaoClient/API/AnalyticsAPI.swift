import Foundation

// MARK: - AnalyticsAPI

/// `client.analytics` namespace. Mirrors js-bao's `AnalyticsClient`
/// interface (`logEvent` / `logSnapshot` / `flush` / `setPlanOverride` /
/// `setAppVersionOverride`). All calls fan out to the shared
/// `AnalyticsQueue` the client owns; this type holds no buffer of its own.
///
/// ## Every member is async and carries the Async suffix
///
/// `AnalyticsQueue` is an `actor` (#1993, Phase D3), so each member does its
/// work on the caller's task. Two awaited calls are ordered, and an event
/// logged before a flush is in that flush's batch.
///
/// `flushAsync()` awaits the send attempt and its failure handling: it returns
/// once the batch has been handed to the socket or, when the send throws, once
/// the events have been re-buffered and persisted. With no connection it
/// returns at once without sending, and the events stay buffered for the next
/// flush. A normal return means the attempt finished, not that the batch was
/// transmitted.
///
/// The suffix is how the members arrived: Phase D3 added them as twins beside
/// synchronous originals, which #2367 removed. The twins took a distinct name
/// rather than being `async` overloads of the same name on purpose: Swift
/// prefers an `async` overload in an asynchronous context, so a same-name twin
/// would have turned every existing un-`await`ed call inside an `async`
/// function into a compile error during the migration. The names stay as
/// shipped; renaming now would be a second source break for no behavior change.
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
