import Foundation

// Plain rows: a client's guess at its own unacknowledged entries, and the
// room's changes applied to the rows it has confirmed. No stamps and no
// rules; the room's result replaces the guess once the entry is judged. A port
// of js-bao's `record-log-client/guess.ts` and `record-log/resolve.ts`.

/// A table of plain rows a guess or a change is applied to.
protocol RecordLogRowTable: AnyObject {
    /// The row of a live record, or `nil`.
    func row(_ key: RecordLogRecordKey) throws -> RecordLogRow?
    /// Put a record's row.
    func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) throws
    /// Remove a record's row.
    func delete(_ key: RecordLogRecordKey) throws
    /// The id of a live record of `model` whose `fields` hold `values`, or
    /// `nil`; a `null` value never matches.
    func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) throws -> String?
}

/// The mutations an entry stands for against a table.
///
/// Only an upsert differs from what the entry carries: when a live record of
/// `m`'s model other than `m.id` holds `m.fields[upsertOn]`, `m` becomes a patch
/// of that record and the alias is named. `also` is applied as written.
func recordLogResolveEntry(
    _ table: RecordLogRowTable, _ entry: RecordLogPendingEntry
) throws -> (mutations: [RecordLogMutation], alias: RecordLogAlias?) {
    guard let field = entry.upsertOn else { return (entry.mutations, nil) }
    let m = entry.m
    guard let value = m.fields?[field], value != .null,
          let to = try table.holder(model: m.model, fields: [field], values: [value], excluding: [m.id])
    else { return (entry.mutations, nil) }
    var patch = m
    patch.id = to
    patch.kind = .patch
    return ([patch] + (entry.also ?? []), RecordLogAlias(model: m.model, from: m.id, to: to))
}

/// Apply an entry as a client guesses it: a create is the whole record, a patch
/// sets what it names on a record the table holds, a delete removes, an upsert
/// goes to the record the table shows holding its value. A field written
/// `null` stays, holding `null`.
///
/// - Returns: the records the guess touched, an upsert's resolution included.
@discardableResult
func recordLogApplyGuess(_ table: RecordLogRowTable, _ entry: RecordLogPendingEntry) throws -> [RecordLogRecordKey] {
    var touched: [RecordLogRecordKey] = []
    for mutation in try recordLogResolveEntry(table, entry).mutations {
        let key = mutation.key
        touched.append(key)
        if mutation.kind == .delete {
            try table.delete(key)
            continue
        }
        let prior: RecordLogRow? = mutation.kind == .create ? ["id": .string(mutation.id)] : try table.row(key)
        guard var row = prior else { continue }
        for (field, value) in mutation.fields ?? [:] { row[field] = value }
        for (field, deltas) in mutation.stringSetDeltas ?? [:] {
            var members = row[field]?.arrayValue?.compactMap(\.stringValue) ?? []
            for (member, present) in deltas {
                if present {
                    members.append(member)
                } else {
                    members.removeAll { recordLogSameText($0, member) }
                }
            }
            row[field] = .array(recordLogCanonicalStringSet(members).map { .string($0) })
        }
        try table.set(key, row)
    }
    return touched
}

/// Apply one record's change from a result to a table of confirmed rows.
func recordLogApplyChange(_ table: RecordLogRowTable, _ change: RecordLogChange) throws {
    let key = RecordLogRecordKey(model: change.model, id: change.id)
    if change.gone { return try table.delete(key) }
    if let row = change.row { return try table.set(key, row) }
    var row = try table.row(key) ?? ["id": .string(change.id)]
    for (field, value) in change.set ?? [:] { row[field] = value }
    for field in change.unset ?? [] { row.removeValue(forKey: field) }
    try table.set(key, row)
}

/// Whether a row's `fields` hold `values`: every one present, not `null`, and equal.
func recordLogHolds(_ row: RecordLogRow, fields: [String], values: [JSONValue]) -> Bool {
    for (field, value) in zip(fields, values) {
        guard let held = row[field], held != .null, held == value else { return false }
    }
    return true
}

/// Plain rows in insertion order: a record put again keeps its place, a deleted
/// one put again goes last. An upsert's holder is the first live record in
/// that order holding the value.
final class RecordLogMapRowTable: RecordLogRowTable {
    private(set) var order: [RecordLogRecordKey] = []
    private var rows: [RecordLogRecordKey: RecordLogRow] = [:]

    init() {}

    init(_ entries: [(RecordLogRecordKey, RecordLogRow)]) {
        for (key, row) in entries { put(key, row) }
    }

    /// The rows, in table order.
    var orderedRows: [(key: RecordLogRecordKey, row: RecordLogRow)] {
        order.compactMap { key in rows[key].map { (key, $0) } }
    }

    func contains(_ key: RecordLogRecordKey) -> Bool { rows[key] != nil }

    func row(_ key: RecordLogRecordKey) -> RecordLogRow? { rows[key] }

    func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) { put(key, row) }

    func delete(_ key: RecordLogRecordKey) {
        guard rows.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) -> String? {
        if values.contains(.null) { return nil }
        for key in order where key.model == model && !excluding.contains(key.id) {
            if let row = rows[key], recordLogHolds(row, fields: fields, values: values) { return key.id }
        }
        return nil
    }

    /// An independent copy.
    func clone() -> RecordLogMapRowTable {
        let copy = RecordLogMapRowTable()
        copy.order = order
        copy.rows = rows
        return copy
    }

    private func put(_ key: RecordLogRecordKey, _ row: RecordLogRow) {
        if rows.updateValue(row, forKey: key) == nil { order.append(key) }
    }
}
