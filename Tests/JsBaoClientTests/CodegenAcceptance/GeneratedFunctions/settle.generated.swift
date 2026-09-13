// AUTO-GENERATED FROM functions/settle.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: d2786dab0b79592e

import Foundation
import JsBaoClient

public struct SettleInput: Codable, Equatable, Sendable {
    public var id: String

    public init(
        id: String
    ) {
        self.id = id
    }
}

public enum SettleOutput: Codable, Equatable, Sendable {
    case settled(SettledBranch)
    case pending(PendingBranch)

    public struct SettledBranch: Codable, Equatable, Sendable {
        public enum KindValue: String, Codable, CaseIterable, Sendable {
            case settled = "settled"
        }

        public var kind: KindValue
        public var note: String?

        public init(
            kind: KindValue,
            note: String? = nil
        ) {
            self.kind = kind
            self.note = note
        }

        public enum CodingKeys: String, CodingKey {
            case kind
            case note
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try container.decode(KindValue.self, forKey: .kind)
            self.note = try container.decodeIfPresent(String.self, forKey: .note)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(note, forKey: .note)
        }
    }

    public struct PendingBranch: Codable, Equatable, Sendable {
        public enum KindValue: String, Codable, CaseIterable, Sendable {
            case pending = "pending"
        }

        public var kind: KindValue
        public var details: [String: JSONValue]

        public init(
            kind: KindValue,
            details: [String: JSONValue]
        ) {
            self.kind = kind
            self.details = details
        }
    }

    private enum DiscriminatorKey: String, CodingKey {
        case tag = "kind"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKey.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "settled":
            self = .settled(try SettledBranch(from: decoder))
        case "pending":
            self = .pending(try PendingBranch(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown kind discriminator for SettleOutput"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .settled(let value):
            try value.encode(to: encoder)
        case .pending(let value):
            try value.encode(to: encoder)
        }
    }
}

/// Typed invoker for the `settle` request function. Binds
/// `SettleInput` / `SettleOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `settle(client)`.
public struct SettleFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `settle` request function and wait for its result.
    public func invoke(
        input: SettleInput,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<SettleOutput> {
        try await client.functions.invoke(
            "settle",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }
}

/// Typed invoker factory for the `settle` function.
public func settle(_ client: JsBaoClient) -> SettleFunction {
    SettleFunction(client: client)
}
