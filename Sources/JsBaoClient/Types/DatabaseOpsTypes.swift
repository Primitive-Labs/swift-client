import Foundation

// MARK: - Database typed-ops result envelopes (#1547, Phase 4)
//
// The published SDK counterparts of the TS `databases codegen` generic result
// shapes (`QueryResult`, `MutationResult`, `CountResult`, …). They mirror the
// runtime result shapes the database-operations controller returns. The
// CLI-generated `<type>.generated.swift` files reference THESE (via each op's
// `<Op>Result` typealias) instead of copying them per file — a Swift package
// compiles every generated file into one module, so a per-file copy would
// collide. Named with a `DB…` prefix to avoid clashing with the existing
// `PagedQueryResult` / `DoDbQueryResult` document types.

/// A page of records returned by a `query` op. `T` is the record type (a
/// generated record struct) or the open `JSONValue` when the op's projection
/// narrows the rows (Swift has no `Pick`/`Partial` analog).
public struct DBQueryResult<T: Codable & Sendable>: Codable, Sendable {
    public var data: [T]
    public var hasMore: Bool?
    public var nextCursor: String?

    public init(data: [T], hasMore: Bool? = nil, nextCursor: String? = nil) {
        self.data = data
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

extension DBQueryResult: Equatable where T: Equatable {}

/// One step's result inside a `mutation` op's uniform response (#1458). `op` is
/// the step kind (`save|patch|delete|increment|addToSet|removeFromSet`); `id`
/// the record id; `values` an `increment` step's post-increment counters;
/// `error` a per-step failure string.
public struct DBMutationStepResult: Codable, Sendable, Equatable {
    public var op: String
    public var success: Bool
    public var id: String
    public var values: [String: Double]?
    public var error: String?

    public init(
        op: String,
        success: Bool,
        id: String,
        values: [String: Double]? = nil,
        error: String? = nil
    ) {
        self.op = op
        self.success = success
        self.id = id
        self.values = values
        self.error = error
    }
}

/// Every `mutation` op returns a uniform `{ results: [...] }` in
/// definition-step order (#1458).
public struct DBMutationResult: Codable, Sendable, Equatable {
    public var results: [DBMutationStepResult]

    public init(results: [DBMutationStepResult]) {
        self.results = results
    }
}

/// A `count` op returns a single count.
public struct DBCountResult: Codable, Sendable, Equatable {
    public var count: Int

    public init(count: Int) {
        self.count = count
    }
}

/// An `aggregate` op returns a single result object.
public struct DBAggregateResult: Codable, Sendable, Equatable {
    public var result: [String: JSONValue]

    public init(result: [String: JSONValue]) {
        self.result = result
    }
}

/// An `applyToQuery` op returns match/affect/fail counts.
public struct DBApplyToQueryResult: Codable, Sendable, Equatable {
    public var matched: Int
    public var affected: Int
    public var failed: Int
    public var sample: [JSONValue]?

    public init(matched: Int, affected: Int, failed: Int, sample: [JSONValue]? = nil) {
        self.matched = matched
        self.affected = affected
        self.failed = failed
        self.sample = sample
    }
}

/// A `pipeline` op returns per-step results keyed by step name.
public struct DBPipelineResult: Codable, Sendable, Equatable {
    public var steps: [String: JSONValue]

    public init(steps: [String: JSONValue]) {
        self.steps = steps
    }
}
