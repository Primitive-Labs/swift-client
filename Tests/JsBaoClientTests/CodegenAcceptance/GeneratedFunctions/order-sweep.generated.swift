// AUTO-GENERATED FROM functions/order-sweep.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 6c79c4c4a51de013

import Foundation
import JsBaoClient

public struct OrderSweepInput: Codable, Equatable, Sendable {
    public var olderThanDays: Int?

    public init(
        olderThanDays: Int? = nil
    ) {
        self.olderThanDays = olderThanDays
    }
}

public struct OrderSweepOutput: Codable, Equatable, Sendable {
    public var swept: Double

    public init(
        swept: Double
    ) {
        self.swept = swept
    }
}

/// Typed invoker for the `order-sweep` function. Binds
/// `OrderSweepInput` / `OrderSweepOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `orderSweep(client)`.
public struct OrderSweepFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `order-sweep` request function and wait for its result.
    public func invoke(
        input: OrderSweepInput? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<OrderSweepOutput> {
        try await client.functions.invoke(
            "order-sweep",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `order-sweep` task function; returns the run handle.
    @discardableResult
    public func start(
        input: OrderSweepInput? = nil,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await client.functions.start(
            "order-sweep",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `OrderSweepOutput`.
    public func getStatus(runId: String) async throws -> FunctionRunResult<OrderSweepOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `OrderSweepOutput`.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<OrderSweepOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: OrderSweepOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `OrderSweepOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> FunctionRunResult<OrderSweepOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "order-sweep",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `order-sweep` function.
public func orderSweep(_ client: JsBaoClient) -> OrderSweepFunction {
    OrderSweepFunction(client: client)
}
