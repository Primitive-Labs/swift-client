// AUTO-GENERATED FROM workflows/tick.toml — DO NOT EDIT.
// Run `primitive workflows codegen --lang swift` to regenerate.
// fingerprint: 905ee7e0297479f7

import Foundation
import JsBaoClient

public typealias TickInput = String

public struct TickOutput: Codable, Equatable, Sendable {
    public var ticked: Bool

    public init(
        ticked: Bool
    ) {
        self.ticked = ticked
    }
}

/// Typed invoker for the `tick` workflow. Bind its `TickInput` /
/// `TickOutput` over the generic `WorkflowsAPI` overloads. Obtain one
/// with `tick(client)`.
public struct TickWorkflow: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Start the workflow asynchronously; returns the run handle.
    @discardableResult
    public func start(
        input: TickInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        try await client.workflows.start(
            workflowKey: "tick",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
    }

    /// Fetch a run's status with a typed `output` bound to `TickOutput`.
    public func getStatus(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<TickOutput> {
        try await client.workflows.getStatus(
            workflowKey: "tick",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Terminate a run; `output` is bound to `TickOutput` (a terminated
    /// run can carry partial output).
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<TickOutput> {
        try await client.workflows.terminate(
            workflowKey: "tick",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Register this workflow's apply handler. Emitted only because
    /// `tick` is apply-mode (parity with JS). The context's `output`
    /// is the client's untyped `Any?`.
    public func define(onApply: @escaping WorkflowApplyHandler) {
        client.workflows.define("tick", onApply: onApply)
    }

    /// Cron triggers scoped to the `tick` workflow. The workflow key is
    /// pinned by the helpers below, so a trigger cannot be redirected.
    public var cronTriggers: CronTriggers {
        CronTriggers(client: client)
    }

    /// Typed cron-trigger management for the `tick` workflow.
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
            rootInput: TickInput? = nil,
            inputMapping: JSONValue? = nil
        ) async throws -> CronTriggerInfo {
            try await client.cronTriggers.create(
                params: CreateCronTriggerParams(
                    triggerKey: triggerKey,
                    displayName: displayName,
                    cron: cron,
                    workflowKey: "tick",
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
            rootInput: Updatable<TickInput>? = nil,
            inputMapping: JSONValue? = nil,
            state: UpdateCronTriggerState? = nil
        ) async throws -> CronTriggerInfo {
            let rootInputValue: JSONValue? = try rootInput.map {
                (change: Updatable<TickInput>) throws -> JSONValue in
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
                    workflowKey: "tick",
                    overlapPolicy: overlapPolicy,
                    rootInput: rootInputValue,
                    inputMapping: inputMapping,
                    state: state
                )
            )
        }
    }
}

/// Typed invoker factory for the `tick` workflow.
public func tick(_ client: JsBaoClient) -> TickWorkflow {
    TickWorkflow(client: client)
}
