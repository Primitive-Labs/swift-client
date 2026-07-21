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
        timeoutMs: Int? = nil
    ) async throws -> RunSyncResult<CreateCheckoutSessionOutput> {
        try await client.workflows.runSync(
            workflowKey: "create-checkout-session",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            timeoutMs: timeoutMs
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
}

/// Typed invoker factory for the `create-checkout-session` workflow.
public func createCheckoutSession(_ client: JsBaoClient) -> CreateCheckoutSessionWorkflow {
    CreateCheckoutSessionWorkflow(client: client)
}
