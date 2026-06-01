import Foundation

// MARK: - CronTriggersAPI

/// Mirrors the JS `CronTriggersAPI` — schedule workflow runs on a
/// standard 5-field cron expression. Triggers are stored as app-scoped
/// rows; each one binds a Durable Object that owns the next-fire alarm.
public final class CronTriggersAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// List all cron triggers for the current app. Archived triggers
    /// are excluded. Response shape: `{ "items": [...] }`.
    public func list() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/cron-triggers", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Get a cron trigger by id, including runtime state from the
    /// associated Durable Object (`scheduledAlarm` / `scheduledAlarmAt`
    /// fields populate `result["runtime"]`).
    public func get(triggerId: String) async throws -> [String: Any] {
        let result = try await makeRequest(
            "GET", "/cron-triggers/\(triggerId)", nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Create a new cron trigger. The Durable Object is bound and the
    /// first alarm is scheduled as part of this call.
    ///
    /// - Parameter params: Expected keys:
    ///   - `triggerKey` (String, required): per-app identifier.
    ///   - `displayName` (String, required)
    ///   - `cron` (String, required): 5-field cron expression.
    ///   - `workflowKey` (String, required): workflow to invoke on fire.
    ///   - `timezone` (String, optional): IANA name; defaults to `"UTC"`.
    ///   - `description` (String, optional)
    ///   - `overlapPolicy` (String, optional): `"skip"` (default) or
    ///     `"allow"` for what to do if a prior run is still active.
    ///   - `rootInput` (Any, optional): root workflow input.
    ///   - `inputMapping` (Any, optional): supports `{{now}}` template.
    public func create(params: [String: Any]) async throws -> [String: Any] {
        let result = try await makeRequest("POST", "/cron-triggers", params)
        return result as? [String: Any] ?? [:]
    }

    /// Update one or more fields. Schedule-relevant changes (`cron`,
    /// `timezone`, `state`) propagate to the Durable Object.
    ///
    /// - Parameter params: Any subset of `displayName`, `description`,
    ///   `cron`, `timezone`, `workflowKey`, `overlapPolicy`, `rootInput`,
    ///   `inputMapping`, `state` (`"active" | "paused" | "archived"`).
    public func update(
        triggerId: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await makeRequest(
            "PUT", "/cron-triggers/\(triggerId)", params
        )
        return result as? [String: Any] ?? [:]
    }

    /// Soft-delete (archive) a cron trigger and cancel its pending alarm.
    public func delete(triggerId: String) async throws -> [String: Any] {
        let result = try await makeRequest(
            "DELETE", "/cron-triggers/\(triggerId)", nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Pause a trigger. The scheduled alarm is cancelled and no further
    /// runs are started until the trigger is resumed.
    public func pause(triggerId: String) async throws -> [String: Any] {
        let result = try await makeRequest(
            "POST", "/cron-triggers/\(triggerId)/pause", nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Resume a paused or error_paused trigger. Clears `lastError` and
    /// reschedules the next fire.
    public func resume(triggerId: String) async throws -> [String: Any] {
        let result = try await makeRequest(
            "POST", "/cron-triggers/\(triggerId)/resume", nil
        )
        return result as? [String: Any] ?? [:]
    }

    /// Fire the associated workflow immediately without affecting the
    /// schedule. Response shape:
    /// `{ "started": Bool, "runId"?: String, "instanceId"?: String, "error"?: String }`.
    public func test(triggerId: String) async throws -> [String: Any] {
        let result = try await makeRequest(
            "POST", "/cron-triggers/\(triggerId)/test", nil
        )
        return result as? [String: Any] ?? [:]
    }
}
