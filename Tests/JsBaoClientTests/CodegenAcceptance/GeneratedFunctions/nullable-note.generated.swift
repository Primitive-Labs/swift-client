// AUTO-GENERATED FROM functions/nullable-note.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 7f9bb5c3aa94c7f4

import Foundation
import JsBaoClient

public typealias NullableNoteInput = String?

public struct NullableNoteOutput: Codable, Equatable, Sendable {
    public var seen: String

    public init(
        seen: String
    ) {
        self.seen = seen
    }
}

/// Typed invoker for the `nullable-note` function. Binds
/// `NullableNoteInput` / `NullableNoteOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `nullableNote(client)`.
public struct NullableNoteFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `nullable-note` request function and wait for its result.
    public func invoke(
        input: NullableNoteInput,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<NullableNoteOutput> {
        // `NullableNoteInput` is Optional, so `nil` is the JSON `null` the
        // declared schema allows — not "no input". Delegating `nil` would omit
        // `rootInput`, which the server defaults to `{}`; `JSONValue.null`
        // travels as the null through the same path a scalar root uses.
        if let input {
            return try await client.functions.invoke(
                "nullable-note",
                input: input,
                contextDocId: contextDocId,
                meta: meta,
                timeout: timeout
            )
        }
        return try await client.functions.invoke(
            "nullable-note",
            input: JSONValue.null,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `nullable-note` task function; returns the run handle.
    @discardableResult
    public func start(
        input: NullableNoteInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        // `NullableNoteInput` is Optional, so `nil` is the JSON `null` the
        // declared schema allows — not "no input". Delegating `nil` would omit
        // `rootInput`, which the server defaults to `{}`; `JSONValue.null`
        // travels as the null through the same path a scalar root uses.
        if let input {
            return try await client.functions.start(
                "nullable-note",
                input: input,
                runKey: runKey,
                contextDocId: contextDocId,
                meta: meta
            )
        }
        return try await client.functions.start(
            "nullable-note",
            input: JSONValue.null,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `NullableNoteOutput`.
    public func getStatus(runId: String) async throws -> FunctionRunResult<NullableNoteOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `NullableNoteOutput`.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<NullableNoteOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: NullableNoteOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `NullableNoteOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> FunctionRunResult<NullableNoteOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "nullable-note",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `nullable-note` function.
public func nullableNote(_ client: JsBaoClient) -> NullableNoteFunction {
    NullableNoteFunction(client: client)
}
