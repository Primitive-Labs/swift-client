import Foundation

// MARK: - CronTriggersAPI

/// Mirrors the JS `CronTriggersAPI` — schedule workflow runs on a
/// standard 5-field cron expression. Triggers are stored as app-scoped
/// rows; each one binds a Durable Object that owns the next-fire alarm.
///
/// All methods are typed against `api/cronTriggersApi.d.ts`: typed inputs
/// (`CreateCronTriggerParams` / `UpdateCronTriggerParams`) encode to the
/// request body via `JSONCoding.jsonObject`, and responses decode into
/// `CronTriggerInfo` / `CronTriggerListResult` / `CronTriggerDeleteResult` /
/// `CronTriggerTestResult` via `JSONCoding.decode` — which **throws** on a
/// shape mismatch rather than silently coercing a malformed body to an empty
/// `[:]` as the previous `[String: Any]` surface did (#954, #991).
public final class CronTriggersAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// List all cron triggers for the current app. Archived triggers
    /// are excluded. Response envelope: `{ "items": [...] }`.
    public func list() async throws -> CronTriggerListResult {
        let result = try await makeRequest("GET", "/cron-triggers", nil)
        return try JSONCoding.decode(CronTriggerListResult.self, from: result)
    }

    /// Get a cron trigger by id, including runtime state from the
    /// associated Durable Object (`scheduledAlarm` / `scheduledAlarmAt`
    /// populate `result.runtime`).
    public func get(triggerId: String) async throws -> CronTriggerInfo {
        let result = try await makeRequest(
            "GET", "/cron-triggers/\(triggerId)", nil
        )
        return try JSONCoding.decode(CronTriggerInfo.self, from: result)
    }

    /// Create a new cron trigger. The Durable Object is bound and the
    /// first alarm is scheduled as part of this call.
    public func create(params: CreateCronTriggerParams) async throws -> CronTriggerInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/cron-triggers", body)
        return try JSONCoding.decode(CronTriggerInfo.self, from: result)
    }

    /// Update one or more fields. Schedule-relevant changes (`cron`,
    /// `timezone`, `state`) propagate to the Durable Object.
    public func update(
        triggerId: String,
        params: UpdateCronTriggerParams
    ) async throws -> CronTriggerInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest(
            "PUT", "/cron-triggers/\(triggerId)", body
        )
        return try JSONCoding.decode(CronTriggerInfo.self, from: result)
    }

    /// Soft-delete (archive) a cron trigger and cancel its pending alarm.
    public func delete(triggerId: String) async throws -> CronTriggerDeleteResult {
        let result = try await makeRequest(
            "DELETE", "/cron-triggers/\(triggerId)", nil
        )
        return try JSONCoding.decode(CronTriggerDeleteResult.self, from: result)
    }

    /// Pause a trigger. The scheduled alarm is cancelled and no further
    /// runs are started until the trigger is resumed.
    public func pause(triggerId: String) async throws -> CronTriggerInfo {
        let result = try await makeRequest(
            "POST", "/cron-triggers/\(triggerId)/pause", nil
        )
        return try JSONCoding.decode(CronTriggerInfo.self, from: result)
    }

    /// Resume a paused or `error_paused` trigger. Clears `lastError` and
    /// reschedules the next fire.
    public func resume(triggerId: String) async throws -> CronTriggerInfo {
        let result = try await makeRequest(
            "POST", "/cron-triggers/\(triggerId)/resume", nil
        )
        return try JSONCoding.decode(CronTriggerInfo.self, from: result)
    }

    /// Fire the associated workflow immediately without affecting the
    /// schedule. Response: `{ started, runId?, instanceId?, error? }`.
    public func test(triggerId: String) async throws -> CronTriggerTestResult {
        let result = try await makeRequest(
            "POST", "/cron-triggers/\(triggerId)/test", nil
        )
        return try JSONCoding.decode(CronTriggerTestResult.self, from: result)
    }
}
