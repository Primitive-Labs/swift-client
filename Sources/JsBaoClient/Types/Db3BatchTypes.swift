import Foundation

// MARK: - Batch operations

/// One read of a db3 batch, as `client.db3.batchRead` takes it: a `query`
/// with what a records query takes, a `count` with its filter, or an
/// `aggregate` with the aggregate options. Each is answered at its place in
/// the request.
///
/// ```swift
/// let reads: [Db3BatchReadOperation] = [
///     .query(model: "Project", sort: ["updatedAt": -1], limit: 20),
///     .count(model: "Task", filter: ["done": false]),
/// ]
/// ```
public enum Db3BatchReadOperation: Encodable, Sendable, Equatable {
    /// A page of `model`'s records: `filter`, `sort` (each field `1` or `-1`), `limit` (100 when
    /// omitted, at most 10,000), a page's `cursor`, and related records to `include`.
    case query(
        model: String,
        filter: [String: JSONValue]? = nil,
        sort: [String: Int]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        include: [JSONValue]? = nil
    )
    /// How many of `model`'s records match `filter` (all of them when omitted).
    case count(model: String, filter: [String: JSONValue]? = nil)
    /// Aggregate rows over `model`'s records: `options` holds `operations`, and optionally
    /// `groupBy`, `filter`, `sort` and `limit`.
    case aggregate(model: String, options: [String: JSONValue])

    /// The op as the route takes it.
    var wire: [String: JSONValue] {
        switch self {
        case let .query(model, filter, sort, limit, cursor, include):
            var op: [String: JSONValue] = ["model": .string(model), "action": "query"]
            if let filter { op["filter"] = .object(filter) }
            if let sort { op["sort"] = .object(sort.mapValues { .number(Double($0)) }) }
            if let limit { op["limit"] = .number(Double(limit)) }
            if let cursor { op["cursor"] = .string(cursor) }
            if let include { op["include"] = .array(include) }
            return op
        case let .count(model, filter):
            var op: [String: JSONValue] = ["model": .string(model), "action": "count"]
            if let filter { op["filter"] = .object(filter) }
            return op
        case let .aggregate(model, options):
            return ["model": .string(model), "action": "aggregate", "options": .object(options)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(wire).encode(to: encoder)
    }
}

/// One operation of `client.db3.batch`: a write, applied with the others in
/// one transaction and in order, or a read (`.query`, `.count`,
/// `.aggregate`) answered against the writes before it. Any write may carry
/// `condition`, a guard in the query filter grammar on the record it
/// addresses, and `requestId`, a ULID naming it so a retry is not applied
/// twice.
///
/// ```swift
/// let result = try await client.db3.batch(db3Id, [
///     .create(model: "Visit", data: ["at": .number(Date().timeIntervalSince1970)]),
///     .count(model: "Visit"),
/// ])
/// ```
public enum Db3BatchOperation: Encodable, Sendable, Equatable {
    /// Create a record; the db3 mints its id when `id` is omitted.
    case create(model: String, data: [String: JSONValue], id: String? = nil, condition: [String: JSONValue]? = nil, requestId: String? = nil)
    /// Merge `data` into an existing record.
    case patch(model: String, id: String, data: [String: JSONValue], condition: [String: JSONValue]? = nil, requestId: String? = nil)
    /// Delete a record.
    case delete(model: String, id: String, condition: [String: JSONValue]? = nil, requestId: String? = nil)
    /// Merge `data` into the record holding the unique `constraint`'s key, or create it.
    case upsert(model: String, constraint: String, data: [String: JSONValue], id: String? = nil, condition: [String: JSONValue]? = nil, requestId: String? = nil)
    /// Add each of `fields` to the record's number field, a missing one counting as 0.
    case increment(model: String, id: String, fields: [String: Double], condition: [String: JSONValue]? = nil, requestId: String? = nil)
    /// A read, answered in the result's `reads`.
    case read(Db3BatchReadOperation)

    /// A page of `model`'s records, read against the writes before it.
    public static func query(
        model: String,
        filter: [String: JSONValue]? = nil,
        sort: [String: Int]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        include: [JSONValue]? = nil
    ) -> Db3BatchOperation {
        .read(.query(model: model, filter: filter, sort: sort, limit: limit, cursor: cursor, include: include))
    }

    /// How many of `model`'s records match `filter`, counted against the writes before it.
    public static func count(model: String, filter: [String: JSONValue]? = nil) -> Db3BatchOperation {
        .read(.count(model: model, filter: filter))
    }

    /// Aggregate rows over `model`'s records, against the writes before it.
    public static func aggregate(model: String, options: [String: JSONValue]) -> Db3BatchOperation {
        .read(.aggregate(model: model, options: options))
    }

    /// A write's own keys beside its guard and request id.
    private static func write(
        _ model: String, _ action: String, _ fields: [String: JSONValue], condition: [String: JSONValue]?, requestId: String?
    ) -> [String: JSONValue] {
        var op = fields
        op["model"] = .string(model)
        op["action"] = .string(action)
        if let condition { op["condition"] = .object(condition) }
        if let requestId { op["requestId"] = .string(requestId) }
        return op
    }

    /// The op as the route takes it.
    var wire: [String: JSONValue] {
        switch self {
        case let .create(model, data, id, condition, requestId):
            var fields: [String: JSONValue] = ["data": .object(data)]
            if let id { fields["id"] = .string(id) }
            return Self.write(model, "create", fields, condition: condition, requestId: requestId)
        case let .patch(model, id, data, condition, requestId):
            return Self.write(model, "patch", ["id": .string(id), "data": .object(data)], condition: condition, requestId: requestId)
        case let .delete(model, id, condition, requestId):
            return Self.write(model, "delete", ["id": .string(id)], condition: condition, requestId: requestId)
        case let .upsert(model, constraint, data, id, condition, requestId):
            var fields: [String: JSONValue] = ["constraint": .string(constraint), "data": .object(data)]
            if let id { fields["id"] = .string(id) }
            return Self.write(model, "upsert", fields, condition: condition, requestId: requestId)
        case let .increment(model, id, fields, condition, requestId):
            return Self.write(
                model, "increment", ["id": .string(id), "fields": .object(fields.mapValues { .number($0) })],
                condition: condition, requestId: requestId
            )
        case let .read(read):
            return read.wire
        }
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(wire).encode(to: encoder)
    }
}

/// How `client.db3.batch` applies its operations.
public struct Db3BatchOptions: Sendable, Equatable {
    /// `false` applies each operation on its own: the writes that pass commit, `results` names each
    /// refused write and a refused read is `.refused`. All or nothing when omitted.
    public var atomic: Bool?
    /// A ULID naming the whole request: a retry carrying it is answered with the first answer's
    /// writes, and its reads are answered again.
    public var requestId: String?

    public init(atomic: Bool? = nil, requestId: String? = nil) {
        self.atomic = atomic
        self.requestId = requestId
    }
}

// MARK: - Batch answers

/// What the server read and wrote to answer a db3 call, in rows; `nil` where it keeps no counter.
public struct Db3Cost: Decodable, Sendable, Equatable {
    /// Rows the call read.
    public let rowsRead: Int?
    /// Rows the call wrote; 0 for a read.
    public let rowsWritten: Int?
}

/// One read's answer in a db3 batch.
public enum Db3BatchReadAnswer: Sendable, Equatable {
    /// A page of records, whether more follow, and the cursors for the next and the previous page.
    case query(items: [[String: JSONValue]], hasMore: Bool, nextCursor: String?, prevCursor: String?)
    /// How many records matched.
    case count(Int)
    /// The aggregate's rows, each `{ group, ...values }`.
    case aggregate([JSONValue])
    /// With `atomic: false`: why the read was refused, such as `DB3_PAGE_TOO_LARGE`.
    case refused(code: String, status: Int, error: String)
}

/// One read's result in a db3 batch, at its `index` in the request.
public struct Db3BatchReadResult: Decodable, Sendable, Equatable {
    /// The read's place in the request's operations, from 0.
    public let index: Int
    /// The model it read.
    public let model: String
    /// `query`, `count` or `aggregate`.
    public let action: String
    /// Its answer, or its refusal.
    public let answer: Db3BatchReadAnswer

    private enum CodingKeys: String, CodingKey {
        case index, model, action, ok, items, hasMore, nextCursor, prevCursor, count, result, code, status, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        model = try c.decode(String.self, forKey: .model)
        action = try c.decode(String.self, forKey: .action)
        guard try c.decode(Bool.self, forKey: .ok) else {
            answer = .refused(
                code: try c.decodeIfPresent(String.self, forKey: .code) ?? "",
                status: try c.decodeIfPresent(Int.self, forKey: .status) ?? 0,
                error: try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            )
            return
        }
        switch action {
        case "query":
            answer = .query(
                items: try c.decode([[String: JSONValue]].self, forKey: .items),
                hasMore: try c.decode(Bool.self, forKey: .hasMore),
                nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor),
                prevCursor: try c.decodeIfPresent(String.self, forKey: .prevCursor)
            )
        case "count":
            answer = .count(try c.decode(Int.self, forKey: .count))
        case "aggregate":
            answer = .aggregate(try c.decode([JSONValue].self, forKey: .result))
        default:
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "unknown read action \(action)")
        }
    }
}

/// What `client.db3.batchRead` answers: one result per read, in order, and what reading them cost.
public struct Db3BatchReadResponse: Decodable, Sendable, Equatable {
    /// One result per read, in order.
    public let results: [Db3BatchReadResult]
    /// The rows the server read to answer them.
    public let cost: Db3Cost?
}

/// A record a db3 batch created or changed, with what its hook rules wrote.
public struct Db3BatchRecord: Decodable, Sendable, Equatable {
    public let model: String
    public let id: String
    /// Every field the db3's hook rules wrote into the record, with its value; `nil` when none.
    public let appliedFields: [String: JSONValue]?
}

/// One upsert's outcome in a db3 batch: the record it resolved, whether it created it, and what
/// its hook rules wrote.
public struct Db3BatchUpserted: Decodable, Sendable, Equatable {
    public let index: Int
    public let model: String
    public let id: String
    public let created: Bool
    /// Every field the db3's hook rules wrote into the record, with its value; `nil` when none.
    public let appliedFields: [String: JSONValue]?
}

/// One increment's outcome in a db3 batch: the record and each field's value after it.
public struct Db3BatchIncremented: Decodable, Sendable, Equatable {
    public let index: Int
    public let model: String
    public let id: String
    /// Each incremented field's value once the increment applied.
    public let values: [String: Double]
}

/// One write's result in a db3 batch run with `atomic: false`.
public struct Db3BatchOperationResult: Decodable, Sendable, Equatable {
    /// The write's place in the request's operations, from 0.
    public let index: Int
    public let model: String
    public let id: String?
    /// Whether it applied.
    public let ok: Bool
    /// What it did when it applied: `added`, `updated`, `upserted`, `deleted` or `incremented`.
    public let kind: String?
    /// An applied increment's fields, each with its value after it.
    public let values: [String: Double]?
    /// Every field the db3's hook rules wrote into an applied write's record, with its value; `nil`
    /// when none.
    public let appliedFields: [String: JSONValue]?
    /// Why it was refused, such as `DB3_CONDITION_NOT_MET`.
    public let code: String?
    public let status: Int?
    public let error: String?
}

/// What `client.db3.batch` answers.
public struct Db3BatchResult: Decodable, Sendable, Equatable {
    /// How many write operations applied.
    public let applied: Int
    /// The records created.
    public let added: [Db3BatchRecord]
    /// The records changed.
    public let updated: [Db3BatchRecord]
    /// How many records were deleted.
    public let deleted: Int
    /// One entry per upsert, in input order.
    public let upserted: [Db3BatchUpserted]?
    /// One entry per increment, in input order, with each field's value after it; `nil` when the
    /// batch carried none.
    public let incremented: [Db3BatchIncremented]?
    /// `false` when the batch ran with `atomic: false`.
    public let atomic: Bool?
    /// With `atomic: false`: one result per write, in order.
    public let results: [Db3BatchOperationResult]?
    /// One result per read, in order, each answered against the writes before it; `nil` when the
    /// batch carried none.
    public let reads: [Db3BatchReadResult]?
    /// The batch's own request id, echoed.
    public let requestId: String?
    /// The rows the batch read and wrote.
    public let cost: Db3Cost?
}
