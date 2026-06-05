import Foundation

// MARK: - AnalyticsAPI

/// `client.analytics` namespace. Mirrors js-bao's `AnalyticsClient`
/// interface (`logEvent` / `logSnapshot` / `flush` / `setPlanOverride` /
/// `setAppVersionOverride`). All calls fan out to the shared
/// `AnalyticsQueue` the client owns; this struct holds no buffer of its
/// own and is a thin, injected-closure facade matching the other
/// `*API` types (see `MeAPI` / `SessionAPI`).
public final class AnalyticsAPI: @unchecked Sendable {
    private let logEventClosure: (AnalyticsEventInput) -> Void
    private let flushClosure: () -> Void
    private let setPlanOverrideClosure: (String?) -> Void
    private let setAppVersionOverrideClosure: (String?) -> Void
    /// Resolves the current user id (ULID) for `logSnapshot`. Returns
    /// nil when there is no authenticated user.
    private let resolveUserUlid: () -> String?

    public init(
        logEvent: @escaping (AnalyticsEventInput) -> Void,
        flush: @escaping () -> Void,
        setPlanOverride: @escaping (String?) -> Void,
        setAppVersionOverride: @escaping (String?) -> Void,
        resolveUserUlid: @escaping () -> String?
    ) {
        self.logEventClosure = logEvent
        self.flushClosure = flush
        self.setPlanOverrideClosure = setPlanOverride
        self.setAppVersionOverrideClosure = setAppVersionOverride
        self.resolveUserUlid = resolveUserUlid
    }

    /// Log a typed analytics event. The queue fills in `user_ulid`,
    /// `timestamp`, and any plan / app-version overrides.
    public func logEvent(_ event: AnalyticsEventInput) {
        logEventClosure(event)
    }

    /// Log a point-in-time state snapshot for the current user. No-ops
    /// when there is no authenticated user (mirrors js-bao's
    /// `analytics.logSnapshot`, which bails when `resolveAnalyticsUserUlid`
    /// returns null). Emits `action: "_snapshot"`, `feature: "_state"`.
    public func logSnapshot(context: JSONValue? = nil) {
        guard let userUlid = resolveUserUlid() else { return }
        logEventClosure(
            AnalyticsEventInput(
                action: "_snapshot",
                feature: "_state",
                user_ulid: userUlid,
                context_json: context
            )
        )
    }

    /// Flush pending analytics events immediately.
    public func flush() {
        flushClosure()
    }

    /// Override the plan field on all subsequent analytics events.
    public func setPlanOverride(_ plan: String?) {
        setPlanOverrideClosure(plan)
    }

    /// Override the app-version field on all subsequent analytics events.
    public func setAppVersionOverride(_ version: String?) {
        setAppVersionOverrideClosure(version)
    }
}
