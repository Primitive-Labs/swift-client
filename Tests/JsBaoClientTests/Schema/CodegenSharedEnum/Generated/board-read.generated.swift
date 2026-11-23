// AUTO-GENERATED FROM functions/board-read.toml — DO NOT EDIT.
// Run `primitive functions codegen --lang swift` to regenerate.
// fingerprint: 54ff8c3b523ed00d

import Foundation
import JsBaoClient

public struct BoardReadInput: Codable, Equatable, Sendable {
    /// - projection: declared — db3 board.posts as declared (closed, storage keys stripped)
    public var draft: PostsDeclared?
    public var want: Phase?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        draft: PostsDeclared? = nil,
        want: Phase? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.draft = draft
        self.want = want
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case draft
        case want
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.draft = try container.decodeIfPresent(PostsDeclared.self, forKey: .draft)
        self.want = try container.decodeIfPresent(Phase.self, forKey: .want)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(draft, forKey: .draft)
        try container.encodeIfPresent(want, forKey: .want)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["draft", "want"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct BoardReadOutput: Codable, Equatable, Sendable {
    public struct Strict: Codable, Equatable, Sendable {
        public var id: String?
        public var title: String?
        public var status: Phase
        /// Extra keys the schema does not model, preserved round-trip.
        public var extra: [String: JSONValue]

        public init(
            id: String? = nil,
            title: String? = nil,
            status: Phase,
            extra: [String: JSONValue] = [:]
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.extra = extra
        }

        public enum CodingKeys: String, CodingKey {
            case id
            case title
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeIfPresent(String.self, forKey: .id)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.status = try container.decode(Phase.self, forKey: .status)
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            var collected: [String: JSONValue] = [:]
            for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
                collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
            }
            self.extra = collected
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(status, forKey: .status)
            var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in extra where !Self.knownKeys.contains(key) {
                try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        }

        private static let knownKeys: Set<String> = ["id", "title", "status"]

        private struct DynamicCodingKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// - projection: row — db3 board.posts as a stored row (id, the declared fields, the type's stamps; open)
    public var post: PostsRow
    /// - projection: row — db3 board.posts as a stored row (id, the declared fields, the type's stamps; open)
    public var strict: Strict?
    /// Extra keys the schema does not model, preserved round-trip.
    public var extra: [String: JSONValue]

    public init(
        post: PostsRow,
        strict: Strict? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.post = post
        self.strict = strict
        self.extra = extra
    }

    public enum CodingKeys: String, CodingKey {
        case post
        case strict
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.post = try container.decode(PostsRow.self, forKey: .post)
        self.strict = try container.decodeIfPresent(Strict.self, forKey: .strict)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        var collected: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            collected[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        self.extra = collected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(post, forKey: .post)
        try container.encodeIfPresent(strict, forKey: .strict)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let knownKeys: Set<String> = ["post", "strict"]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Typed invoker for the `board-read` function. Binds
/// `BoardReadInput` / `BoardReadOutput` over the generic
/// `FunctionsAPI` overloads. Obtain one with `boardRead(client)`.
public struct BoardReadFunction: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Invoke the `board-read` request function and wait for its result.
    public func invoke(
        input: BoardReadInput? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<BoardReadOutput> {
        try await client.functions.invoke(
            "board-read",
            input: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Start the `board-read` task function; returns the run handle.
    @discardableResult
    public func start(
        input: BoardReadInput? = nil,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await client.functions.start(
            "board-read",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// A run's status, with `output` bound to `BoardReadOutput`.
    public func getStatus(runId: String) async throws -> FunctionRunResult<BoardReadOutput> {
        try await client.functions.getStatus(runId: runId)
    }

    /// Wait for a run to settle; `output` is bound to `BoardReadOutput`.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<BoardReadOutput> {
        try await client.functions.waitFor(
            runId: runId,
            as: BoardReadOutput.self,
            options: options
        )
    }

    /// Terminate a run; `output` is bound to `BoardReadOutput` (a terminated
    /// run can carry partial output). The function key is pinned.
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> FunctionRunResult<BoardReadOutput> {
        try await client.functions.terminate(
            FunctionRunRef(
                functionKey: "board-read",
                runKey: runKey,
                contextDocId: contextDocId
            )
        )
    }
}

/// Typed invoker factory for the `board-read` function.
public func boardRead(_ client: JsBaoClient) -> BoardReadFunction {
    BoardReadFunction(client: client)
}
