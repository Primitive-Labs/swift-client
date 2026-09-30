import Foundation

/// One author waiting in a session's queue, with their batch in order (§D5).
/// The queue is the one platform-shaped JSON column of a session row.
public struct PrimitiveQueueEntry: Sendable, Equatable, Hashable {
    public var userId: String
    public var messageIds: [String]

    public init(userId: String, messageIds: [String]) {
        self.userId = userId
        self.messageIds = messageIds
    }

    /// Read from one queue entry; `nil` without a string `userId` and an
    /// array `messageIds`. Non-string message ids are dropped.
    public init?(json: JSONValue) {
        guard let userId = json["userId"]?.stringValue,
              let messageIds = json["messageIds"]?.stringArrayValue
        else { return nil }
        self.init(userId: userId, messageIds: messageIds)
    }

    public var jsonValue: JSONValue {
        ["userId": .string(userId), "messageIds": .array(messageIds.map { .string($0) })]
    }
}

/// The read rules the generated platform session models share (#3802) — the
/// Swift half of `src/client/agents/sessionModelRuntime.ts`.
///
/// `AgentSessionModels.generated.swift` calls through here so each rule is
/// written once:
///
/// - A stringset reads as its string members. An empty one is `nil`, as an
///   absent one is: the store's query path hands back every declared
///   stringset as an array, so the two cannot be told apart there.
/// - Numbers must be finite; nothing is coerced from a string. Booleans read
///   through `rowBoolValue` (`0` is false, any other number true), as the JS
///   client reads them.
/// - A JSON column's text is parsed whole; absent text, or text that is not
///   JSON, is no value (`nil`). An `any` value is kept whole — `.null`
///   included, which is distinct from a missing column. An object column
///   keeps every key. Valid JSON of the wrong top-level type is `nil`, or the
///   empty collection where the column says so.
enum AgentSessionJSON {

    static func members(_ value: JSONValue?) -> Set<String>? {
        guard let members = value?.stringArrayValue, !members.isEmpty else { return nil }
        return Set(members)
    }

    static func number(_ value: JSONValue?) -> Double? {
        guard let number = value?.numberValue, number.isFinite else { return nil }
        return number
    }

    /// The value a JSON column's text holds; `nil` when the column is absent
    /// or its text is not JSON. The text `null` is `.null`.
    static func parse(_ column: JSONValue?) -> JSONValue? {
        guard let text = column?.stringValue else { return nil }
        return try? JSONCoding.decoder.decode(JSONValue.self, from: Data(text.utf8))
    }

    /// An object column: every key of the stored object.
    static func object(_ column: JSONValue?, emptyOnWrongType: Bool) -> [String: JSONValue]? {
        guard let value = parse(column) else { return nil }
        return value.objectValue ?? (emptyOnWrongType ? [:] : nil)
    }

    /// The queue column: its well-formed entries, in order.
    static func queue(_ column: JSONValue?, emptyOnWrongType: Bool) -> [PrimitiveQueueEntry]? {
        guard let value = parse(column) else { return nil }
        guard let items = value.arrayValue else { return emptyOnWrongType ? [] : nil }
        return items.compactMap(PrimitiveQueueEntry.init(json:))
    }

    /// The canonical text of a JSON column: compact, keys sorted.
    static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A stored record read back as the row `init?(row:)` takes.
    static func row(from record: PrimitiveRecord) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(record.id)]
        for (field, value) in record.snapshot() {
            switch value {
            case let .string(s), let .id(s), let .date(s): row[field] = .string(s)
            case let .number(n): row[field] = .number(n)
            case let .boolean(b): row[field] = .bool(b)
            case let .json(data): row[field] = .string(String(decoding: data, as: UTF8.self))
            case let .stringset(set): row[field] = .array(set.sorted().map { .string($0) })
            }
        }
        return row
    }
}
