// AUTO-GENERATED FROM functions/greet.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 5e3c1f51e9ddb182

import Foundation
import JsBaoClient

public struct GreetInput: Codable, Equatable, Sendable {
    public var name: String

    public init(
        name: String
    ) {
        self.name = name
    }
}

public struct GreetOutput: Codable, Equatable, Sendable {
    public var greeting: String

    public init(
        greeting: String
    ) {
        self.greeting = greeting
    }
}

/// Typed invoker for the `greet` request function. Binds
/// `GreetInput` / `GreetOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `greet(client)`.
public struct GreetFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `greet` request function and wait for its result.
    public func invoke(
        input: GreetInput,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<GreetOutput> {
        try await client.functions.invoke(
            "greet",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }
}

/// Typed invoker factory for the `greet` function.
public func greet(_ client: JsBaoClient) -> GreetFunction {
    GreetFunction(client: client)
}
