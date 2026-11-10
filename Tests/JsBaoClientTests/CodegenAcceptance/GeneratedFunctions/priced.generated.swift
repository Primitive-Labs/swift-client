// AUTO-GENERATED FROM functions/priced.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 02c24ad3381b4aa6

import Foundation
import JsBaoClient

public struct PricedInputValue: Codable, Equatable, Sendable {
    public enum ModeValue: String, Codable, CaseIterable, Sendable {
        case quote = "quote"
    }

    public var price: Money
    public var discount: Money?
    public var mode: ModeValue
    public var contact: JSONValue?
    public var note: String?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        price: Money,
        discount: Money? = nil,
        mode: ModeValue,
        contact: JSONValue? = nil,
        note: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.price = price
        self.discount = discount
        self.mode = mode
        self.contact = contact
        self.note = note
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case price
        case discount
        case mode
        case contact
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.price = try container.decode(Money.self, forKey: .price)
        self.discount = try container.decodeIfPresent(Money.self, forKey: .discount)
        self.mode = try container.decode(ModeValue.self, forKey: .mode)
        self.contact = try container.decodeIfPresent(JSONValue.self, forKey: .contact)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(price, forKey: .price)
        try container.encodeIfPresent(discount, forKey: .discount)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(contact, forKey: .contact)
        try container.encodeIfPresent(note, forKey: .note)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["price", "discount", "mode", "contact", "note"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public typealias PricedInput = PricedInputValue?

public struct PricedOutput: Codable, Equatable, Sendable {
    /// - projection: row — db3 workspace.tasks as a stored row (id, the declared fields, the type's stamps; open)
    public var row: TasksRow
    public var status: Status?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        row: TasksRow,
        status: Status? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.row = row
        self.status = status
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case row
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.row = try container.decode(TasksRow.self, forKey: .row)
        self.status = try container.decodeIfPresent(Status.self, forKey: .status)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(row, forKey: .row)
        try container.encodeIfPresent(status, forKey: .status)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["row", "status"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Typed invoker for the `priced` function. Binds
/// `PricedInput` / `PricedOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `priced(client)`.
public struct PricedFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `priced` request function and wait for its result.
    public func invoke(
        input: PricedInput,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<PricedOutput> {
        // `PricedInput` is Optional, so `nil` is the JSON `null` the
        // declared schema allows — not "no input". Delegating `nil` would omit
        // `rootInput`, which the server defaults to `{}`; `JSONValue.null`
        // travels as the null through the same path a scalar root uses.
        if let input {
            return try await client.functions.invoke(
                "priced",
                input: input,
                contextDocId: contextDocId,
                meta: meta,
                timeout: timeout
            )
        }
        return try await client.functions.invoke(
            "priced",
            input: JSONValue.null,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `priced` task function; returns the run handle.
    @discardableResult
    public func start(
        input: PricedInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        // `PricedInput` is Optional, so `nil` is the JSON `null` the
        // declared schema allows — not "no input". Delegating `nil` would omit
        // `rootInput`, which the server defaults to `{}`; `JSONValue.null`
        // travels as the null through the same path a scalar root uses.
        if let input {
            return try await client.functions.start(
                "priced",
                input: input,
                runKey: runKey,
                contextDocId: contextDocId,
                meta: meta
            )
        }
        return try await client.functions.start(
            "priced",
            input: JSONValue.null,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `PricedOutput`.
    public func getStatus(runId: String) async throws -> FunctionRunResult<PricedOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `PricedOutput`.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<PricedOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: PricedOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `PricedOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> FunctionRunResult<PricedOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "priced",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `priced` function.
public func priced(_ client: JsBaoClient) -> PricedFunction {
    PricedFunction(client: client)
}
