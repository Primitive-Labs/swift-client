// AUTO-GENERATED FROM functions/echo.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 29b7fe247655a30a

import Foundation
import JsBaoClient

public typealias EchoInput = JSONValue

public typealias EchoOutput = JSONValue

/// Typed invoker for the `echo` any function. Binds
/// `EchoInput` / `EchoOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `echo(client)`.
public struct EchoFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `echo` request function and wait for its result.
    public func invoke(
        input: EchoInput? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<EchoOutput> {
        try await client.functions.invoke(
            "echo",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `echo` task function; returns the run handle.
    @discardableResult
    public func start(
        input: EchoInput? = nil,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await client.functions.start(
            "echo",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `EchoOutput`.
    public func getStatus(runId: String) async throws -> WorkflowStatus<EchoOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `EchoOutput`.
    public func waitFor(
        runId: String,
        options: WaitForWorkflowOptions? = nil
    ) async throws -> WaitForResult<EchoOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: EchoOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `EchoOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<EchoOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "echo",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `echo` function.
public func echo(_ client: JsBaoClient) -> EchoFunction {
    EchoFunction(client: client)
}
