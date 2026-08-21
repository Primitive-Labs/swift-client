// AUTO-GENERATED FROM workflows/create-checkout-session.toml — DO NOT EDIT.
// Run `primitive workflows codegen --lang swift` to regenerate.
// fingerprint: 34b8fd59b830c807

import Foundation
import JsBaoClient

public struct CreateCheckoutSessionInput: Codable, Equatable, Sendable {
    public enum ModeValue: String, Codable, CaseIterable, Sendable {
        case payment = "payment"
        case subscription = "subscription"
    }

    public var priceId: String
    public var quantity: Int?
    public var mode: ModeValue?

    public init(
        priceId: String,
        quantity: Int? = nil,
        mode: ModeValue? = nil
    ) {
        self.priceId = priceId
        self.quantity = quantity
        self.mode = mode
    }
}

public struct CreateCheckoutSessionOutput: Codable, Equatable, Sendable {
    public var checkoutUrl: String
    public var expiresAt: String?

    public init(
        checkoutUrl: String,
        expiresAt: String? = nil
    ) {
        self.checkoutUrl = checkoutUrl
        self.expiresAt = expiresAt
    }
}

/// Typed invoker for the `create-checkout-session` workflow. Bind its `CreateCheckoutSessionInput` /
/// `CreateCheckoutSessionOutput` over the generic `WorkflowsAPI` overloads. Obtain one
/// with `createCheckoutSession(client)`.
public struct CreateCheckoutSessionWorkflow: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Run the workflow synchronously and wait for its terminal status.
    /// Emitted only because `create-checkout-session` is `syncCallable` (parity with JS).
    public func runSync(
        input: CreateCheckoutSessionInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> RunSyncResult<CreateCheckoutSessionOutput> {
        try await client.workflows.runSync(
            workflowKey: "create-checkout-session",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the workflow asynchronously; returns the run handle.
    @discardableResult
    public func start(
        input: CreateCheckoutSessionInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        try await client.workflows.start(
            workflowKey: "create-checkout-session",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
    }

    /// Fetch a run's status with a typed `output` bound to `CreateCheckoutSessionOutput`.
    public func getStatus(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<CreateCheckoutSessionOutput> {
        try await client.workflows.getStatus(
            workflowKey: "create-checkout-session",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Terminate a run; `output` is bound to `CreateCheckoutSessionOutput` (a terminated
    /// run can carry partial output).
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<CreateCheckoutSessionOutput> {
        try await client.workflows.terminate(
            workflowKey: "create-checkout-session",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Register this workflow's apply handler. Emitted only because
    /// `create-checkout-session` is apply-mode (parity with JS). The context's `output`
    /// is the client's untyped `Any?`.
    public func define(onApply: @escaping WorkflowApplyHandler) {
        client.workflows.define("create-checkout-session", onApply: onApply)
    }

    /// Cron triggers scoped to the `create-checkout-session` workflow. The workflow key is
    /// pinned by the helpers below, so a trigger cannot be redirected.
    public var cronTriggers: CronTriggers {
        CronTriggers(client: client)
    }

    /// Typed cron-trigger management for the `create-checkout-session` workflow.
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
                    workflowKey: "create-checkout-session",
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
                    workflowKey: "create-checkout-session",
                    overlapPolicy: overlapPolicy,
                    rootInput: rootInput,
                    inputMapping: inputMapping,
                    state: state
                )
            )
        }
    }
}

/// Typed invoker factory for the `create-checkout-session` workflow.
public func createCheckoutSession(_ client: JsBaoClient) -> CreateCheckoutSessionWorkflow {
    CreateCheckoutSessionWorkflow(client: client)
}
