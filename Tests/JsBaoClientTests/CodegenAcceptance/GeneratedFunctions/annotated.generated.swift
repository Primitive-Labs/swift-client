// AUTO-GENERATED FROM functions/annotated.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 992401acc5c06580

import Foundation
import JsBaoClient

/// A profile update.
///
/// Every field documents its bounds; this comment ends *\/ here.
/// - title: "Profile update"
/// - $comment: "Reviewed with the profiles team."
/// - x-owner: "profiles"
public struct AnnotatedInput: Codable, Equatable, Sendable {
    public enum LocaleValue: String, Codable, CaseIterable, Sendable {
        case en = "en"
        case fr = "fr"
    }

    /// Shown on the badge.
    /// - minLength: 1
    /// - maxLength: 40
    /// - pattern: "^[A-Za-z][A-Za-z .'-]*$"
    /// - examples: ["Ada Lovelace","Grace Hopper"]
    public var name: String
    /// - format: "email"
    /// - deprecated: true
    /// - internal: true
    public var email: String?
    /// - default: "friend"
    /// - deprecated: false
    public var nickname: String?
    /// - minimum: 0
    /// - maximum: 150
    public var age: Int?
    /// The badge language.
    /// - examples: ["en","fr","en","fr","en","fr","en","fr","en","fr","en","fr","en","fr","en","fr"]
    public var locale: LocaleValue?
    /// - minItems: 1
    /// - maxItems: 10
    /// - uniqueItems: true
    /// - items.maxLength: 24
    /// - items.description: "One tag."
    public var tags: [String]?
    /// Where to post the badge, or null.
    /// - properties.city.maxLength: 80
    public var address: JSONValue?
    /// - anyOf/0.minLength: 3
    public var handle: JSONValue?

    public init(
        name: String,
        email: String? = nil,
        nickname: String? = nil,
        age: Int? = nil,
        locale: LocaleValue? = nil,
        tags: [String]? = nil,
        address: JSONValue? = nil,
        handle: JSONValue? = nil
    ) {
        self.name = name
        self.email = email
        self.nickname = nickname
        self.age = age
        self.locale = locale
        self.tags = tags
        self.address = address
        self.handle = handle
    }
}

/// What the update did.
/// - oneOf/0.description: "The profile was saved."
/// - oneOf/1.description: "Nothing changed."
public enum AnnotatedOutput: Codable, Equatable, Sendable {
    case saved(SavedBranch)
    case unchanged(UnchangedBranch)

    public struct SavedBranch: Codable, Equatable, Sendable {
        public enum StatusValue: String, Codable, CaseIterable, Sendable {
            case saved = "saved"
        }

        public var status: StatusValue
        /// The new version.
        /// - minimum: 1
        public var version: Int

        public init(
            status: StatusValue,
            version: Int
        ) {
            self.status = status
            self.version = version
        }
    }

    public struct UnchangedBranch: Codable, Equatable, Sendable {
        public enum StatusValue: String, Codable, CaseIterable, Sendable {
            case unchanged = "unchanged"
        }

        public var status: StatusValue

        public init(
            status: StatusValue
        ) {
            self.status = status
        }
    }

    private enum DiscriminatorKey: String, CodingKey {
        case tag = "status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKey.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "saved":
            self = .saved(try SavedBranch(from: decoder))
        case "unchanged":
            self = .unchanged(try UnchangedBranch(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown status discriminator for AnnotatedOutput"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .saved(let value):
            try value.encode(to: encoder)
        case .unchanged(let value):
            try value.encode(to: encoder)
        }
    }
}

/// Typed invoker for the `annotated` function. Binds
/// `AnnotatedInput` / `AnnotatedOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `annotated(client)`.
public struct AnnotatedFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `annotated` request function and wait for its result.
    public func invoke(
        input: AnnotatedInput,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<AnnotatedOutput> {
        try await client.functions.invoke(
            "annotated",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `annotated` task function; returns the run handle.
    @discardableResult
    public func start(
        input: AnnotatedInput,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await client.functions.start(
            "annotated",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `AnnotatedOutput`.
    public func getStatus(runId: String) async throws -> FunctionRunResult<AnnotatedOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `AnnotatedOutput`.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<AnnotatedOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: AnnotatedOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `AnnotatedOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> FunctionRunResult<AnnotatedOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "annotated",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `annotated` function.
public func annotated(_ client: JsBaoClient) -> AnnotatedFunction {
    AnnotatedFunction(client: client)
}
