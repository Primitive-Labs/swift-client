// AUTO-GENERATED FROM workflows/process-payment.toml — DO NOT EDIT.
// Run `primitive workflows codegen --lang swift` to regenerate.
// fingerprint: 58bc395ce882cc92

import Foundation
import JsBaoClient

public struct ProcessPaymentInput: Codable, Equatable, Sendable {
    public var amount: Double

    public init(
        amount: Double
    ) {
        self.amount = amount
    }
}

public enum ProcessPaymentOutput: Codable, Equatable, Sendable {
    case card(CardBranch)
    case bank(BankBranch)

    public struct CardBranch: Codable, Equatable, Sendable {
        public enum KindValue: String, Codable, CaseIterable, Sendable {
            case card = "card"
        }

        public var kind: KindValue
        public var last4: String

        public init(
            kind: KindValue,
            last4: String
        ) {
            self.kind = kind
            self.last4 = last4
        }
    }

    public struct BankBranch: Codable, Equatable, Sendable {
        public enum KindValue: String, Codable, CaseIterable, Sendable {
            case bank = "bank"
        }

        public var kind: KindValue
        public var accountId: String

        public init(
            kind: KindValue,
            accountId: String
        ) {
            self.kind = kind
            self.accountId = accountId
        }
    }

    private enum DiscriminatorKey: String, CodingKey {
        case tag = "kind"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKey.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "card":
            self = .card(try CardBranch(from: decoder))
        case "bank":
            self = .bank(try BankBranch(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown kind discriminator for ProcessPaymentOutput"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .card(let value):
            try value.encode(to: encoder)
        case .bank(let value):
            try value.encode(to: encoder)
        }
    }
}

/// Typed invoker for the `process-payment` workflow. Bind its `ProcessPaymentInput` /
/// `ProcessPaymentOutput` over the generic `WorkflowsAPI` overloads. Obtain one
/// with `processPayment(client)`.
public struct ProcessPaymentWorkflow: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Run the workflow synchronously and wait for its terminal status.
    /// Emitted only because `process-payment` is `syncCallable` (parity with JS).
    public func runSync(
        input: ProcessPaymentInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> RunSyncResult<ProcessPaymentOutput> {
        try await client.workflows.runSync(
            workflowKey: "process-payment",
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
        input: ProcessPaymentInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        try await client.workflows.start(
            workflowKey: "process-payment",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
    }

    /// Fetch a run's status with a typed `output` bound to `ProcessPaymentOutput`.
    public func getStatus(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<ProcessPaymentOutput> {
        try await client.workflows.getStatus(
            workflowKey: "process-payment",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }
}

/// Typed invoker factory for the `process-payment` workflow.
public func processPayment(_ client: JsBaoClient) -> ProcessPaymentWorkflow {
    ProcessPaymentWorkflow(client: client)
}
