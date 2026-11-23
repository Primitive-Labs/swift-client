import Foundation
import YSwift
import Yniffi

/// A single record living inside a model's top-level Y.Map. Identity is
/// the inner Y.Map — the same Y.Map you can attach a per-record observer
/// to (Work Item 2). Subscript reads/writes go straight through the CRDT.
///
/// The record holds a reference to its parent `DynamicModel` so writes
/// are scoped to the same transaction dispatch policy (sync or
/// client-integrated) the model was set up with.
///
/// ## `Sendable` — plain and checked (Phase C)
///
/// No `@unchecked` here, and none is needed: every stored property is `let`
/// and `Sendable` (`String`s, `Int?`s, and `DynamicModel`, which is
/// `@unchecked Sendable` behind its documented lock invariants). The compiler
/// verifies this conformance, so the type carries no safety-argument debt of
/// its own — that debt is `DynamicModel`'s, stated once there.
///
/// It stays a **live handle**, not a value snapshot: a subscript read goes
/// through the model to the CRDT and so reflects concurrent writes, and the
/// subscript setter writes through. Sending a `PrimitiveRecord` across
/// an isolation boundary sends the handle; the data it reads through stays
/// serialized by the model's locks.
public final class PrimitiveRecord: Sendable {
    public let modelName: String
    public let id: String

    // Strong ref: the record must remain usable even if the caller
    // drops its handle to the DynamicModel immediately after `create`.
    internal let model: DynamicModel

    /// On a record-log (format-3) document, the writer's sequence number of
    /// the entry the save that returned this handle committed; `nil` for any
    /// other handle (a lookup, another format, a save inside `transact`).
    public let recordLogSeq: Int?

    /// The save that returned this handle, as its document's binding names it:
    /// `recordLogSeq` is minted again after a group of saves failed to commit,
    /// and a later save under the same number is not this one.
    internal let recordLogTicket: Int?

    internal init(modelName: String, id: String, model: DynamicModel, recordLogSeq: Int? = nil) {
        self.modelName = modelName
        self.id = id
        self.model = model
        self.recordLogSeq = recordLogSeq
        self.recordLogTicket = recordLogSeq.flatMap { model.recordLog?.binding.ticket(of: $0) }
    }

    /// Whether this record's writes from this client have reached the room,
    /// on a record-log (format-3) document: `pending` while an entry of this
    /// client touching the record is unacknowledged, `refused` when the save
    /// that produced this handle was handed back, `confirmed` otherwise. `nil`
    /// on any other document. The model's listeners hear a record move to
    /// `confirmed`.
    public var syncState: RecordSyncState? {
        model.recordLog?.binding.syncState(model: modelName, id: id, lastSeq: recordLogSeq, ticket: recordLogTicket)
    }

    // MARK: - Subscript

    public subscript(field: String) -> PrimitiveValue? {
        get { model.readField(recordId: id, field: field) }
        set {
            // Route through the throwing update path so unique
            // constraints are enforced. A violation leaves the record
            // untouched; callers that need the error surface should
            // use `DynamicModel.update(id:values:)` directly.
            if let v = newValue {
                model.assignFieldFromRecord(recordId: id, field: field, value: v)
            } else {
                model.clearField(recordId: id, field: field)
            }
        }
    }

    // MARK: - Escape hatch for unknown fields

    /// Raw JSON string as the Yrs FFI hands it back. Use for fields the
    /// schema doesn't know about; otherwise prefer the subscript.
    public func rawValue(for field: String) -> String? {
        model.readRaw(recordId: id, field: field)
    }

    /// Every field name currently present on the underlying Y.Map — includes
    /// fields Swift's schema doesn't know about. Used by callers doing
    /// schema-evolution work; matches `Object.keys(record)` in js-bao.
    public func fieldNames() -> Set<String> {
        return model.fieldNames(recordId: id)
    }

    /// Whether the stored record holds `field`, a stored `null` included.
    ///
    /// `false` means the record was never written with the field, so a read
    /// fills the field's `default`, as js-bao's getter does; a cleared field
    /// (stored `null`) answers `true`. Answered on a db3 (record-log)
    /// document, where clearing a field stores `null`; `nil` on a Y.Map
    /// document, where clearing a field removes it, so a missing field there
    /// may be a cleared one.
    ///
    /// ```swift
    /// let points = record.holds("points") == false ? 3 : record["points"]?.asNumber
    /// ```
    public func holds(_ field: String) -> Bool? {
        model.holds(recordId: id, field: field)
    }

    /// Whether the record a query row answers holds `field`, a stored `null`
    /// included, as ``holds(_:)`` answers for a record.
    ///
    /// A row from a db3 (record-log) document carries a cleared field as
    /// `null` and leaves out a field never written, so a row lacking `field`
    /// answers `false` when the row's document (`_meta_doc_id`) is one a
    /// client in this process opened as a db3. The answer depends on the row
    /// alone, not on which client is the default or whether the document is
    /// still open, so a row kept and read later reads the same. Any other row
    /// lacking it answers `nil`: a Y.Map document's rows leave out a cleared
    /// field too. A row read with a projection leaves out the fields it did
    /// not ask for, so build a model from a whole row.
    ///
    /// A row carries every string set field, as `[]` when the set has no
    /// members; a db3 row lists the ones its record does not hold under
    /// `_meta_unheld`, so those answer `false` too.
    ///
    /// ```swift
    /// let points = PrimitiveRecord.holds("points", in: row) == false ? 3 : row["points"]?.numberValue
    /// ```
    public static func holds(_ field: String, in row: [String: JSONValue]) -> Bool? {
        // A field the row's db3 clears reads as unset: neither held nor never written, so no default fills it (#6021).
        if case .array(let cleared)? = row[clearedFieldsKey], cleared.contains(.string(field)) { return nil }
        if case .array(let unheld)? = row[unheldFieldsKey], unheld.contains(.string(field)) { return false }
        if row[field] != nil { return true }
        guard let document = row["_meta_doc_id"]?.stringValue,
              RecordLogDocumentIds.contains(document)
        else { return nil }
        return false
    }

    /// Whether the db3's held revision clears `field`: the record reads it
    /// as unset, whatever its local copy holds. `false` for a field the
    /// revision keeps, and on a Y.Map document, where a record that lacks a
    /// field merely lacks it.
    ///
    /// A generated model answers `nil` from `init?(record:)` for a
    /// non-optional field its db3 clears.
    public func isCleared(_ field: String) -> Bool {
        model.isCleared(recordId: id, field: field)
    }

    /// Whether the db3's held revision clears `field` on the record a query
    /// row answers, as ``isCleared(_:)`` answers for a record. A row from a
    /// Y.Map document, or one that merely lacks the field, answers `false`.
    public static func isCleared(_ field: String, in row: [String: JSONValue]) -> Bool {
        if case .array(let cleared)? = row[clearedFieldsKey], cleared.contains(.string(field)) { return true }
        return false
    }

    /// The stored value of `field` when it is of the kind a field of `type`
    /// takes; `nil` when the record lacks it, holds `null`, or holds a value
    /// of another kind.
    ///
    /// The value is judged as stored, before any read converts it, as a
    /// typed db3 judges a write: a string for `string` and `id`, a finite
    /// number for `number`, a boolean for `boolean`, and for `date` an
    /// ISO-8601 date on a real calendar day or an epoch number (answered as
    /// its ISO string). On a Y.Map document a stored `0` or `1` in a boolean
    /// field is a boolean. A generated model reads a field with a literal
    /// `default` this way and answers the default where this is `nil`:
    ///
    /// ```swift
    /// let points = record.fittingValue("points", as: .number)?.asNumber ?? 3
    /// ```
    public func fittingValue(_ field: String, as type: PrimitiveFieldType) -> PrimitiveValue? {
        model.fittingValue(recordId: id, field: field, type: type)
    }

    /// The value of `field` in a query row when it is of the kind a field
    /// of `type` takes, as ``fittingValue(_:as:)`` answers for a record. A
    /// row from a db3 carries each value as stored; any other row may hold a
    /// boolean as SQLite's `0` or `1`, which is a boolean.
    ///
    /// Where the row's value is not the stored one (a Y.Map document's
    /// query row holds a stored `5` in a boolean field as `true`, and leaves
    /// out an epoch number in a date field), the row lists the stored value
    /// under ``storedKindsKey`` and that value is judged, so a row reads as
    /// its record does.
    public static func fittingValue(_ field: String, as type: PrimitiveFieldType, in row: [String: JSONValue]) -> PrimitiveValue? {
        let db3 = row["_meta_doc_id"]?.stringValue.map(RecordLogDocumentIds.contains) ?? false
        if case .object(let stored)? = row[storedKindsKey], let value = stored[field] {
            return fitting(value, as: type, numericBooleans: !db3)
        }
        guard let value = row[field] else { return nil }
        return fitting(value, as: type, numericBooleans: !db3)
    }

    /// The key under which a row lists, by field, a stored value the row
    /// itself does not carry as stored: a number in a boolean field other
    /// than `0` or `1`, and a number in a date field. Only a row that has
    /// such a value carries the key.
    static let storedKindsKey = "_meta_stored"

    /// Whether a row must list the stored `value` of a field of `type`
    /// under ``storedKindsKey``: the row's own value of it would be judged
    /// differently (a Y.Map read converts any number in a boolean field to a
    /// boolean, and reads a number in a date field as missing).
    static func listsStoredKind(_ value: JSONValue, as type: PrimitiveFieldType) -> Bool {
        switch (type, value) {
        case let (.boolean, .number(n)): return n != 0 && n != 1
        case (.date, .number): return true
        default: return false
        }
    }

    /// The fields of `fields` whose stored value a row must list (see
    /// ``listsStoredKind(_:as:)``), read through `raw`, the stored JSON text
    /// of a field; `nil` when there are none.
    static func storedKinds(
        of fields: [String: FieldDescriptor], raw: (String) -> String?
    ) -> [String: JSONValue]? {
        var out: [String: JSONValue] = [:]
        for (name, desc) in fields where desc.type == .boolean || desc.type == .date {
            guard let text = raw(name), let value = JSONValue(jsonText: text),
                  listsStoredKind(value, as: desc.type) else { continue }
            out[name] = value
        }
        return out.isEmpty ? nil : out
    }

    /// `value` as the `PrimitiveValue` a field of `type` reads, when it is
    /// of the kind that field takes (``fittingValue(_:as:)``); `nil`
    /// otherwise. `numericBooleans` takes a `0` or `1` as a boolean, as a
    /// Y.Map document's reads do.
    public static func fitting(_ value: JSONValue, as type: PrimitiveFieldType, numericBooleans: Bool) -> PrimitiveValue? {
        switch (type, value) {
        case let (.string, .string(s)): return .string(s)
        case let (.id, .string(s)): return .id(s)
        case let (.number, .number(n)) where n.isFinite: return .number(n)
        case let (.boolean, .bool(b)): return .boolean(b)
        case let (.boolean, .number(n)) where numericBooleans && (n == 0 || n == 1): return .boolean(n == 1)
        case let (.date, .string(s)) where StoredDate.fits(s): return .date(s)
        case let (.date, .number(n)): return StoredDate.iso(epochMilliseconds: n).map(PrimitiveValue.date)
        default: return nil
        }
    }

    /// The key under which a db3 row lists the string set fields its record
    /// does not hold. A row carries each such field as `[]`, as it carries a
    /// set with no members, so ``holds(_:in:)`` reads presence from the list.
    static let unheldFieldsKey = "_meta_unheld"

    /// The key under which a db3 row lists the fields its db3's held revision
    /// clears (#6021): the row leaves them out, and ``holds(_:in:)`` answers
    /// `nil` for them, so a model fills no default there.
    static let clearedFieldsKey = "_meta_cleared"

    /// Record in `row` that its db3 clears `fields`; nothing when there are none.
    static func markCleared(_ fields: some Collection<String>, in row: inout [String: JSONValue]) {
        guard !fields.isEmpty else { return }
        row[clearedFieldsKey] = .array(fields.sorted().map { .string($0) })
    }

    /// Record in `row` that its record does not hold the string set fields
    /// `fields`; nothing when there are none, so a row whose record holds
    /// every set keeps the keys it carried.
    static func markUnheld(_ fields: some Collection<String>, in row: inout [String: JSONValue]) {
        guard !fields.isEmpty else { return }
        row[unheldFieldsKey] = .array(fields.sorted().map { .string($0) })
    }

    // MARK: - Stored dates

    /// What a typed db3's `date` field takes on write, as the room judges it:
    /// an ISO-8601 calendar date, optionally followed by a `T`- or
    /// space-separated time and a `Z` or `±HH:MM` offset, that names a real
    /// calendar day and time (`24:00`, with zero seconds, is the next day's
    /// midnight, as `Date.parse` reads it); or an epoch number a JavaScript
    /// `Date` can represent.
    enum StoredDate {
        /// The JavaScript `Date` range, in milliseconds either side of the epoch.
        static let maxEpochMilliseconds = 8.64e15

        private static let pattern = try! NSRegularExpression(
            pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(?:Z|[+-](\d{2}):?(\d{2}))?)?$"#
        )

        // Immutable once built and documented thread-safe, so shared.
        nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter
        }()

        static func fits(_ text: String) -> Bool {
            guard let result = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return false }
            func digits(_ index: Int) -> Substring? {
                Range(result.range(at: index), in: text).map { text[$0] }
            }
            func part(_ index: Int) -> Int? { digits(index).flatMap { Int($0) } }
            guard let year = part(1), let month = part(2), let day = part(3), (1...12).contains(month), day >= 1 else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first), days.contains(day)
            else { return false }
            let minute = part(5) ?? 0, second = part(6) ?? 0
            if let hour = part(4) {
                if hour > 24 { return false }
                // `24:00` is the end of the day only with nothing after it.
                if hour == 24, minute != 0 || second != 0 || digits(7)?.contains(where: { $0 != "0" }) == true { return false }
            }
            if minute > 59 || second > 59 { return false }
            if let offsetHour = part(8), offsetHour > 23 { return false }
            if let offsetMinute = part(9), offsetMinute > 59 { return false }
            return true
        }

        /// The ISO string an epoch number names, as JavaScript's
        /// `toISOString` writes it; `nil` past the `Date` range.
        static func iso(epochMilliseconds n: Double) -> String? {
            guard n.isFinite, abs(n) <= maxEpochMilliseconds else { return nil }
            return formatter.string(from: Date(timeIntervalSince1970: n / 1000))
        }
    }

    // MARK: - Snapshot

    /// Snapshot every known field into a dictionary of `PrimitiveValue`.
    /// Unknown fields are omitted; use `rawValue(for:)` for those.
    public func snapshot() -> [String: PrimitiveValue] {
        return model.snapshot(recordId: id)
    }
}

extension KeyedDecodingContainer {
    /// The value under `key` when it is of the kind a field of `type` takes,
    /// judged as ``PrimitiveRecord/fittingValue(_:as:)`` judges a stored
    /// value; `nil` when the key is missing, holds `null`, or holds a value of
    /// another kind. Never throws, so a generated model's `init(from:)` reads
    /// a field with a literal `default` as that default instead of failing.
    public func fittingValue(forKey key: Key, as type: PrimitiveFieldType) -> PrimitiveValue? {
        guard let value = (try? decodeIfPresent(JSONValue.self, forKey: key)) ?? nil else { return nil }
        return PrimitiveRecord.fitting(value, as: type, numericBooleans: false)
    }
}
