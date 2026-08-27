import Foundation

// MARK: - CronTriggers: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/cronTriggersApi.d.ts`) field-for-field so the two surfaces line up.
// Timestamps stay as ISO-8601 `String`s — exactly what JS exposes. Opaque
// workflow inputs (`rootInput` / `inputMapping` params, typed `any` on JS)
// are `JSONValue` (see JSONValue.swift).

// MARK: Enums

/// Whether an object is in service. Mirrors JS `ObjectStatus` — one
/// server-owned field with one writer pair (`disable` / `enable`), shared by
/// every type that has it. `archived` is a delete tombstone and only appears
/// on the types whose delete flow writes one.
///
/// It replaces `CronTriggerState`, which mixed availability (`paused`) with
/// lifecycle (`error_paused`, `archived`) and was settable through `update`.
/// A trigger the platform took out of service after a failed fire is
/// `.inactive` with `lastError` set; `enable` clears both.
public enum ObjectStatus: String, Codable, Sendable {
    case active
    case inactive
    case archived
}

/// What happens when a cron tick arrives while a prior run is still active.
public enum CronOverlapPolicy: String, Codable, Sendable {
    case skip
    case allow
}

// MARK: Info

/// A single cron trigger row, including optional runtime state from the
/// associated Durable Object. Mirrors JS `CronTriggerInfo`.
public struct CronTriggerInfo: Decodable, Sendable, Equatable {
    /// Durable-Object-sourced runtime state. Present on `get` (which reads
    /// through to the DO); absent on list rows. Mirrors JS
    /// `CronTriggerInfo.runtime`.
    public struct Runtime: Decodable, Sendable, Equatable {
        public let scheduledAlarm: Double?
        public let scheduledAlarmAt: String?
    }

    public let triggerId: String
    public let triggerKey: String
    public let displayName: String
    public let description: String?
    public let cron: String
    public let timezone: String
    public let workflowKey: String
    public let overlapPolicy: CronOverlapPolicy
    public let rootInput: String?
    public let inputMapping: String?
    public let status: ObjectStatus
    public let lastError: String?
    public let lastTriggeredAt: String?
    public let lastTriggeredRunId: String?
    public let nextFireAt: String?
    public let skippedCount: Double
    public let firedCount: Double
    public let createdBy: String
    public let createdAt: String
    public let modifiedAt: String
    public let runtime: Runtime?
}

/// Envelope returned by `list`: `{ "items": [...] }`. Mirrors JS
/// `CronTriggerListResult`.
public struct CronTriggerListResult: Decodable, Sendable, Equatable {
    public let items: [CronTriggerInfo]
}

// MARK: Create / update inputs

/// Parameters for `create`. Mirrors JS `CreateCronTriggerParams`.
public struct CreateCronTriggerParams: Encodable, Sendable {
    /// Unique per-app identifier (alphanumerics, hyphens, underscores).
    public var triggerKey: String
    /// Display name shown in UIs.
    public var displayName: String
    /// Standard 5-field cron expression.
    public var cron: String
    /// Workflow key to invoke when the cron fires.
    public var workflowKey: String
    /// IANA timezone (e.g. "America/New_York"). Defaults to "UTC".
    public var timezone: String?
    /// Optional human-readable description.
    public var description: String?
    /// What happens when a tick arrives while a prior run is active.
    /// Default: `.skip`.
    public var overlapPolicy: CronOverlapPolicy?
    /// Root input passed to the workflow on each fire.
    public var rootInput: JSONValue?
    /// Additional mapped inputs; supports `{{now}}` template substitution.
    public var inputMapping: JSONValue?

    public init(
        triggerKey: String,
        displayName: String,
        cron: String,
        workflowKey: String,
        timezone: String? = nil,
        description: String? = nil,
        overlapPolicy: CronOverlapPolicy? = nil,
        rootInput: JSONValue? = nil,
        inputMapping: JSONValue? = nil
    ) {
        self.triggerKey = triggerKey
        self.displayName = displayName
        self.cron = cron
        self.workflowKey = workflowKey
        self.timezone = timezone
        self.description = description
        self.overlapPolicy = overlapPolicy
        self.rootInput = rootInput
        self.inputMapping = inputMapping
    }
}

/// Parameters for `update`. Mirrors JS `UpdateCronTriggerParams`: every
/// field is optional with replace semantics — omit a property to leave it
/// unchanged. `description` is clearable (JS `string | null`); pass
/// `.clear` to null it out, `.value(x)` to set it.
public struct UpdateCronTriggerParams: Encodable, Sendable {
    public var displayName: String?
    /// `.value("...")` to set, `.clear` to remove, omit to leave as-is.
    public var description: Updatable<String>?
    public var cron: String?
    public var timezone: String?
    public var workflowKey: String?
    public var overlapPolicy: CronOverlapPolicy?
    public var rootInput: JSONValue?
    public var inputMapping: JSONValue?

    public init(
        displayName: String? = nil,
        description: Updatable<String>? = nil,
        cron: String? = nil,
        timezone: String? = nil,
        workflowKey: String? = nil,
        overlapPolicy: CronOverlapPolicy? = nil,
        rootInput: JSONValue? = nil,
        inputMapping: JSONValue? = nil
    ) {
        self.displayName = displayName
        self.description = description
        self.cron = cron
        self.timezone = timezone
        self.workflowKey = workflowKey
        self.overlapPolicy = overlapPolicy
        self.rootInput = rootInput
        self.inputMapping = inputMapping
    }
}

// MARK: Result wrappers

/// Result of `delete`: `{ archived }`. Mirrors JS `Promise<{ archived: boolean }>`.
public struct CronTriggerDeleteResult: Decodable, Sendable, Equatable {
    public let archived: Bool
}

/// Result of `test`: `{ started, runId?, instanceId?, error? }`. Mirrors JS
/// `Promise<{ started: boolean; runId?: string; instanceId?: string; error?: string }>`.
public struct CronTriggerTestResult: Decodable, Sendable, Equatable {
    public let started: Bool
    public let runId: String?
    public let instanceId: String?
    public let error: String?
}
