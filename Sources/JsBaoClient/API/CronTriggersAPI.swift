import Foundation

// MARK: - CronTriggersAPI

/// Mirrors the JS `CronTriggersAPI` — schedule workflow runs on a
/// standard 5-field cron expression. Triggers are stored as app-scoped
/// rows; each one binds a Durable Object that owns the next-fire alarm.
///
/// All methods are typed against `api/cronTriggersApi.d.ts`: typed inputs
/// (`CreateCronTriggerParams` / `UpdateCronTriggerParams`) are encoded as the
/// request body by the transport, and responses decode into
/// `CronTriggerInfo` / `CronTriggerListResult` / `CronTriggerDeleteResult` /
/// `CronTriggerTestResult` — which **throws** on a shape mismatch rather than
/// silently coercing a malformed body to an empty `[:]` as the previous
/// untyped surface did (#954, #991).
public final class CronTriggersAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// List all cron triggers for the current app. Archived triggers
    /// are excluded. Response envelope: `{ "items": [...] }`.
    public func list() async throws -> CronTriggerListResult {
        try await transport.request(method: .get, path: "/cron-triggers")
    }

    /// Get a cron trigger by id, including runtime state from the
    /// associated Durable Object (`scheduledAlarm` / `scheduledAlarmAt`
    /// populate `result.runtime`).
    public func get(triggerId: String) async throws -> CronTriggerInfo {
        try await transport.request(method: .get, path: "/cron-triggers/\(triggerId)")
    }

    /// Create a new cron trigger. The Durable Object is bound and the
    /// first alarm is scheduled as part of this call.
    public func create(params: CreateCronTriggerParams) async throws -> CronTriggerInfo {
        try await transport.request(method: .post, path: "/cron-triggers", body: params)
    }

    /// Update one or more fields. Schedule-relevant changes (`cron`,
    /// `timezone`) propagate to the Durable Object. Availability is not
    /// settable here — use `disable` / `enable`.
    public func update(
        triggerId: String,
        params: UpdateCronTriggerParams
    ) async throws -> CronTriggerInfo {
        try await transport.request(
            method: .put,
            path: "/cron-triggers/\(triggerId)",
            body: params
        )
    }

    /// Soft-delete (archive) a cron trigger and cancel its pending alarm.
    public func delete(triggerId: String) async throws -> CronTriggerDeleteResult {
        try await transport.request(method: .delete, path: "/cron-triggers/\(triggerId)")
    }

    /// Take a trigger out of service. The scheduled alarm is cancelled and no
    /// further runs start until `enable`.
    public func disable(triggerId: String) async throws -> CronTriggerInfo {
        try await transport.request(method: .post, path: "/cron-triggers/\(triggerId)/disable")
    }

    /// Put a trigger back in service. Clears `lastError` and reschedules the
    /// next fire. Refuses an archived trigger — that is a delete, not a pause.
    public func enable(triggerId: String) async throws -> CronTriggerInfo {
        try await transport.request(method: .post, path: "/cron-triggers/\(triggerId)/enable")
    }

    /// Fire the associated workflow immediately without affecting the
    /// schedule. Response: `{ started, runId?, instanceId?, error? }`.
    public func test(triggerId: String) async throws -> CronTriggerTestResult {
        try await transport.request(method: .post, path: "/cron-triggers/\(triggerId)/test")
    }
}
