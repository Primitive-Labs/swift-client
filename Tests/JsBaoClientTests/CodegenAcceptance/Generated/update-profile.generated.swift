// AUTO-GENERATED FROM workflows/update-profile.toml — DO NOT EDIT.
// Run `primitive workflows codegen --lang swift` to regenerate.
// fingerprint: 5b74d08906bad6d8

import Foundation
import JsBaoClient

public struct UpdateProfileInput: Codable, Equatable, Sendable {
    public var name: String
    public var nickname: String?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        name: String,
        nickname: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.nickname = nickname
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case name
        case nickname
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(nickname, forKey: .nickname)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["name", "nickname"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct UpdateProfileOutput: Codable, Equatable, Sendable {
    public var ok: Bool

    public init(
        ok: Bool
    ) {
        self.ok = ok
    }
}

/// Typed invoker for the `update-profile` workflow. Bind its `UpdateProfileInput` /
/// `UpdateProfileOutput` over the generic `WorkflowsAPI` overloads. Obtain one
/// with `updateProfile(client)`.
public struct UpdateProfileWorkflow: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Start the workflow asynchronously; returns the run handle.
    @discardableResult
    public func start(
        input: UpdateProfileInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        try await client.workflows.start(
            workflowKey: "update-profile",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
    }

    /// Fetch a run's status with a typed `output` bound to `UpdateProfileOutput`.
    public func getStatus(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<UpdateProfileOutput> {
        try await client.workflows.getStatus(
            workflowKey: "update-profile",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Terminate a run; `output` is bound to `UpdateProfileOutput` (a terminated
    /// run can carry partial output).
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<UpdateProfileOutput> {
        try await client.workflows.terminate(
            workflowKey: "update-profile",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Register this workflow's apply handler. Emitted only because
    /// `update-profile` is apply-mode (parity with JS). The context's `output`
    /// is the client's untyped `Any?`.
    public func define(onApply: @escaping WorkflowApplyHandler) {
        client.workflows.define("update-profile", onApply: onApply)
    }

    /// Cron triggers scoped to the `update-profile` workflow. The workflow key is
    /// pinned by the helpers below, so a trigger cannot be redirected.
    public var cronTriggers: CronTriggers {
        CronTriggers(client: client)
    }

    /// Typed cron-trigger management for the `update-profile` workflow.
    public struct CronTriggers: Sendable {
        public let client: JsBaoClient

        public init(client: JsBaoClient) {
            self.client = client
        }

        /// Create a cron trigger that fires this workflow.
        @discardableResult
        public func create(
            triggerKey: String,
            displayName: String,
            cron: String,
            timezone: String? = nil,
            description: String? = nil,
            overlapPolicy: CronOverlapPolicy? = nil,
            rootInput: JSONValue? = nil,
            inputMapping: JSONValue? = nil
        ) async throws -> CronTriggerInfo {
            try await client.cronTriggers.create(
                params: CreateCronTriggerParams(
                    triggerKey: triggerKey,
                    displayName: displayName,
                    cron: cron,
                    workflowKey: "update-profile",
                    timezone: timezone,
                    description: description,
                    overlapPolicy: overlapPolicy,
                    rootInput: rootInput,
                    inputMapping: inputMapping
                )
            )
        }

        /// Update a cron trigger that fires this workflow. Omitted fields stay
        /// unchanged; `description` removes the stored value with `.clear`
        /// and `rootInput` with `.null`.
        @discardableResult
        public func update(
            triggerId: String,
            displayName: String? = nil,
            description: Updatable<String>? = nil,
            cron: String? = nil,
            timezone: String? = nil,
            overlapPolicy: CronOverlapPolicy? = nil,
            rootInput: JSONValue? = nil,
            inputMapping: JSONValue? = nil,
            state: UpdateCronTriggerState? = nil
        ) async throws -> CronTriggerInfo {
            try await client.cronTriggers.update(
                triggerId: triggerId,
                params: UpdateCronTriggerParams(
                    displayName: displayName,
                    description: description,
                    cron: cron,
                    timezone: timezone,
                    workflowKey: "update-profile",
                    overlapPolicy: overlapPolicy,
                    rootInput: rootInput,
                    inputMapping: inputMapping,
                    state: state
                )
            )
        }
    }
}

/// Typed invoker factory for the `update-profile` workflow.
public func updateProfile(_ client: JsBaoClient) -> UpdateProfileWorkflow {
    UpdateProfileWorkflow(client: client)
}
