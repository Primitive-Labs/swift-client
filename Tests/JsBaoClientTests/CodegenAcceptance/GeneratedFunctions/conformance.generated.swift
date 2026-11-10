// AUTO-GENERATED FROM functions/conformance.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 9b952406e819f68d

import Foundation
import JsBaoClient

public struct ConformanceInput: Codable, Equatable, Sendable {
    public enum LevelValue: String, Codable, CaseIterable, Sendable {
        case low = "low"
        case high = "high"
    }
    public enum ModeValue: String, Codable, CaseIterable, Sendable {
        case fast = "fast"
        case safe = "safe"
    }

    public var level: LevelValue
    public var mode: ModeValue?
    public var note: String?
    public var legacy: JSONValue?

    public init(
        level: LevelValue,
        mode: ModeValue? = nil,
        note: String? = nil,
        legacy: JSONValue? = nil
    ) {
        self.level = level
        self.mode = mode
        self.note = note
        self.legacy = legacy
    }

    public enum CodingKeys: String, CodingKey {
        case level
        case mode
        case note
        case legacy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.level = try container.decode(LevelValue.self, forKey: .level)
        self.mode = try container.decodeIfPresent(ModeValue.self, forKey: .mode)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.legacy = try container.decodeIfPresent(JSONValue.self, forKey: .legacy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(legacy, forKey: .legacy)
    }
}

public struct ConformanceOutput: Codable, Equatable, Sendable {
    public var ok: Bool

    public init(
        ok: Bool
    ) {
        self.ok = ok
    }
}

/// Typed invoker for the `conformance` function. Binds
/// `ConformanceInput` / `ConformanceOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `conformance(client)`.
public struct ConformanceFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `conformance` request function and wait for its result.
    public func invoke(
        input: ConformanceInput,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<ConformanceOutput> {
        try await client.functions.invoke(
            "conformance",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `conformance` task function; returns the run handle.
    @discardableResult
    public func start(
        input: ConformanceInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await client.functions.start(
            "conformance",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `ConformanceOutput`.
    public func getStatus(runId: String) async throws -> FunctionRunResult<ConformanceOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `ConformanceOutput`.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<ConformanceOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: ConformanceOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `ConformanceOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> FunctionRunResult<ConformanceOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "conformance",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `conformance` function.
public func conformance(_ client: JsBaoClient) -> ConformanceFunction {
    ConformanceFunction(client: client)
}
