// AUTO-GENERATED FROM workflows/send-digest.toml — DO NOT EDIT.
// Run `primitive workflows codegen --lang swift` to regenerate.
// fingerprint: 314f5fef8e366329

import Foundation
import JsBaoClient

public typealias SendDigestInput = JSONValue

public struct SendDigestOutput: Codable, Equatable, Sendable {
    public var sent: Int

    public init(
        sent: Int
    ) {
        self.sent = sent
    }
}

/// Typed invoker for the `send-digest` workflow. Bind its `SendDigestInput` /
/// `SendDigestOutput` over the generic `WorkflowsAPI` overloads. Obtain one
/// with `sendDigest(client)`.
public struct SendDigestWorkflow: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Start the workflow asynchronously; returns the run handle.
    @discardableResult
    public func start(
        input: SendDigestInput? = nil,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        try await client.workflows.start(
            workflowKey: "send-digest",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
    }

    /// Fetch a run's status with a typed `output` bound to `SendDigestOutput`.
    public func getStatus(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<SendDigestOutput> {
        try await client.workflows.getStatus(
            workflowKey: "send-digest",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Terminate a run; `output` is bound to `SendDigestOutput` (a terminated
    /// run can carry partial output).
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<SendDigestOutput> {
        try await client.workflows.terminate(
            workflowKey: "send-digest",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Cron triggers scoped to the `send-digest` workflow. The workflow key is
    /// pinned by the helpers below, so a trigger cannot be redirected.
    public var cronTriggers: CronTriggers {
        CronTriggers(client: client)
    }

    /// Typed cron-trigger management for the `send-digest` workflow.
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
            rootInput: SendDigestInput? = nil,
            inputMapping: JSONValue? = nil
        ) async throws -> CronTriggerInfo {
            try await client.cronTriggers.create(
                params: CreateCronTriggerParams(
                    triggerKey: triggerKey,
                    displayName: displayName,
                    cron: cron,
                    workflowKey: "send-digest",
                    timezone: timezone,
                    description: description,
                    overlapPolicy: overlapPolicy,
                    rootInput: try rootInput.map { try JSONValue(encoding: $0) },
                    inputMapping: inputMapping
                )
            )
        }

        /// Update a cron trigger that fires this workflow. Omitted fields stay
        /// unchanged; `description` and `rootInput` both remove the stored
        /// value with `.clear`.
        @discardableResult
        public func update(
            triggerId: String,
            displayName: String? = nil,
            description: Updatable<String>? = nil,
            cron: String? = nil,
            timezone: String? = nil,
            overlapPolicy: CronOverlapPolicy? = nil,
            rootInput: Updatable<SendDigestInput>? = nil,
            inputMapping: JSONValue? = nil
        ) async throws -> CronTriggerInfo {
            let rootInputValue: JSONValue? = try rootInput.map {
                (change: Updatable<SendDigestInput>) throws -> JSONValue in
                switch change {
                case .clear: return .null
                case let .value(input): return try JSONValue(encoding: input)
                }
            }
            return try await client.cronTriggers.update(
                triggerId: triggerId,
                params: UpdateCronTriggerParams(
                    displayName: displayName,
                    description: description,
                    cron: cron,
                    timezone: timezone,
                    workflowKey: "send-digest",
                    overlapPolicy: overlapPolicy,
                    rootInput: rootInputValue,
                    inputMapping: inputMapping
                )
            )
        }
    }
}

/// Typed invoker factory for the `send-digest` workflow.
public func sendDigest(_ client: JsBaoClient) -> SendDigestWorkflow {
    SendDigestWorkflow(client: client)
}
