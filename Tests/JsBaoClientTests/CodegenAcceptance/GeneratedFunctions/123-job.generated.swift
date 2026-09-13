// AUTO-GENERATED FROM functions/123-job.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 7058a7879af79597

import Foundation
import JsBaoClient

public typealias _123JobInput = JSONValue

public typealias _123JobOutput = JSONValue

/// Typed invoker for the `123-job` task function. Binds
/// `_123JobInput` / `_123JobOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `_123Job(client)`.
public struct _123JobFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Start the `123-job` task function; returns the run handle.
    @discardableResult
    public func start(
        input: _123JobInput? = nil,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await client.functions.start(
            "123-job",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `_123JobOutput`.
    public func getStatus(runId: String) async throws -> WorkflowStatus<_123JobOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `_123JobOutput`.
    public func waitFor(
        runId: String,
        options: WaitForWorkflowOptions? = nil
    ) async throws -> WaitForResult<_123JobOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: _123JobOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `_123JobOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<_123JobOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "123-job",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `123-job` function.
public func _123Job(_ client: JsBaoClient) -> _123JobFunction {
    _123JobFunction(client: client)
}
