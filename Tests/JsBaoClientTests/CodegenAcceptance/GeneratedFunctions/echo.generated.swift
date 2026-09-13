// AUTO-GENERATED FROM functions/echo.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 29b7fe247655a30a

import Foundation
import JsBaoClient

public typealias EchoInput = JSONValue

public typealias EchoOutput = JSONValue

/// Typed invoker for the `echo` request function. Binds
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
}

/// Typed invoker factory for the `echo` function.
public func echo(_ client: JsBaoClient) -> EchoFunction {
    EchoFunction(client: client)
}
