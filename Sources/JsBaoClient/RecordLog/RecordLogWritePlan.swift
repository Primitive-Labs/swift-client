import Foundation

// Planning a save on a format-3 document, and the checks an entry passes
// before anything commits: field names the room reserves, values the wire
// cannot carry exactly, and entries larger than the room reads. A port of js-bao's `record-log-client/write.ts`.

/// What a save is planned from.
struct RecordLogSaveInput {
    /// The record's model.
    var model: String
    /// The id the write lands on.
    var recordId: String
    /// The record's view row, or `nil` when the view holds none.
    var existing: RecordLogRow?
    /// The record's whole state as the save resolved it (defaults included),
    /// string sets as arrays of members.
    var dataToSave: [String: JSONValue]
    /// The fields the caller changed on this save.
    var touchedFields: [String]
    /// Per string-set field, the members the caller added and removed.
    var stringSetChanges: [String: (additions: [String], removals: [String])] = [:]
    /// The model's string-set fields.
    var stringSetFieldNames: Set<String> = []
}

/// Fields that never travel: the record's key and the store's own columns.
private func recordLogTravels(_ field: String) -> Bool {
    field != "id" && field != "type" && !field.hasPrefix("_meta_")
}

/// The mutation a save writes. A record the view does not hold is a create
/// carrying the whole state; one it holds is a patch of the fields the caller
/// touched. A touched field with no value is written `null`. String-set members
/// travel as deltas: a create's members are added, a patch's additions and
/// removals are each a member set or cleared.
func planRecordLogSave(_ input: RecordLogSaveInput) -> RecordLogMutation {
    let isNew = input.existing == nil
    var fields: [String: JSONValue] = [:]
    var deltas: [String: [String: Bool]] = [:]
    let scalarKeys = isNew ? Array(input.dataToSave.keys) : input.touchedFields
    for key in scalarKeys where recordLogTravels(key) && !input.stringSetFieldNames.contains(key) {
        fields[key] = input.dataToSave[key] ?? .null
    }
    for field in input.stringSetFieldNames where recordLogTravels(field) {
        var delta: [String: Bool] = [:]
        if isNew {
            for member in input.dataToSave[field]?.arrayValue ?? [] {
                if let text = member.stringValue { delta[text] = true }
            }
        } else {
            guard let change = input.stringSetChanges[field] else { continue }
            for member in change.removals { delta[member] = false }
            for member in change.additions { delta[member] = true }
        }
        if !delta.isEmpty { deltas[field] = delta }
    }
    return RecordLogMutation(
        model: input.model, id: input.recordId, kind: isNew ? .create : .patch,
        fields: fields.isEmpty ? nil : fields,
        stringSetDeltas: deltas.isEmpty ? nil : deltas
    )
}

/// One record's two saves as one mutation, the later planned against the
/// record as the earlier left it: the later save's fields win, a string-set
/// member takes its last change, and a create stays a create carrying
/// everything. A later create or delete stands for both.
func mergeRecordLogMutations(_ earlier: RecordLogMutation, _ later: RecordLogMutation) -> RecordLogMutation {
    if later.kind != .patch || earlier.kind == .delete { return later }
    let kind = earlier.kind
    var fields = earlier.fields ?? [:]
    for (field, value) in later.fields ?? [:] { fields[field] = value }
    var deltas = earlier.stringSetDeltas ?? [:]
    for (field, delta) in later.stringSetDeltas ?? [:] {
        var merged = deltas[field] ?? [:]
        for (member, present) in delta { merged[member] = present }
        // A create adds its members; one removed since was never there.
        if kind == .create { merged = merged.filter { $0.value } }
        deltas[field] = merged.isEmpty ? nil : merged
    }
    return RecordLogMutation(
        model: earlier.model, id: earlier.id, kind: kind,
        fields: fields.isEmpty ? nil : fields,
        stringSetDeltas: deltas.isEmpty ? nil : deltas
    )
}

/// The mutation a delete writes.
func planRecordLogDelete(model: String, recordId: String) -> RecordLogMutation {
    RecordLogMutation(model: model, id: recordId, kind: .delete)
}

/// The path of the first value the wire cannot carry exactly, or `nil`.
private func recordLogBadValue(_ value: JSONValue, _ path: String) -> String? {
    switch value {
    case .number(let number):
        if !number.isFinite { return "\(path) is \(number)" }
        if number == number.rounded(), abs(number) > 9_007_199_254_740_991 {
            return "\(path) (\(number)) is an integer outside ±2^53"
        }
        return nil
    case .array(let items):
        for (index, item) in items.enumerated() {
            if let problem = recordLogBadValue(item, "\(path)[\(index)]") { return problem }
        }
        return nil
    case .object(let object):
        for (key, item) in object.sorted(by: { $0.key < $1.key }) {
            if let problem = recordLogBadValue(item, "\(path).\(key)") { return problem }
        }
        return nil
    default:
        return nil
    }
}

/// Why a field name is the room's own, or `nil` when a record may carry it:
/// `type` is the model's column in queries and a leading `_` is internal;
/// `id` is allowed. The one rule js-bao's `checkReservedFieldName` states.
func recordLogReservedFieldProblem(_ field: String) -> String? {
    if field == "id" { return nil }
    if field == "type" { return "Field 'type' is reserved (maps to internal _type column in queries)" }
    if field.hasPrefix("_") { return "Field '\(field)' is reserved (fields starting with '_' are internal)" }
    return nil
}

/// Bytes of a value's JSON.
func recordLogJSONBytes(_ value: JSONValue) -> Int { RecordLogJSON.bytes(value) }

/// The refusal a client makes before sending, reported as the room's are.
func recordLogLocalRefusal(
    _ error: JsBaoError, documentId: String, mutations: [RecordLogMutation]
) -> DocumentWriteRefusedEvent {
    let writes = RecordLogPendingEntry(
        seq: 0, e: 0, k: 0, m: mutations[0], also: Array(mutations.dropFirst())
    ).refusedWrites
    return DocumentWriteRefusedEvent(
        documentId: documentId, model: mutations[0].model, recordId: mutations[0].id, error: error,
        writes: writes, conflictingRecord: nil
    )
}

/// Refuse an entry the room would not take, before anything commits: a field
/// named `type` or beginning with `_`, or a value that is not finite or an
/// integer outside ±2^53 (`.documentEntryInvalid`), or
/// an entry whose JSON is over 1 MiB (`.documentEntryTooLarge`). The refusal
/// is reported through `report` with the one write it refused, then thrown.
func assertRecordLogEntry(
    documentId: String, mutations: [RecordLogMutation], report: ((DocumentWriteRefusedEvent) -> Void)? = nil
) throws {
    guard let m = mutations.first else { return }
    var error: JsBaoError?
    for mutation in mutations {
        let names = Array((mutation.fields ?? [:]).keys).sorted() + Array((mutation.stringSetDeltas ?? [:]).keys).sorted()
        if let reserved = names.lazy.compactMap(recordLogReservedFieldProblem).first {
            error = JsBaoError(
                code: .documentEntryInvalid,
                message: "Cannot save \(mutation.model) \(mutation.id): \(reserved). Rename the field.",
                details: ["documentId": .string(documentId), "scope": "local"]
            )
            break
        }
        if let problem = recordLogBadValue(.object(mutation.fields ?? [:]), "\(mutation.model).\(mutation.id)") {
            error = JsBaoError(
                code: .documentEntryInvalid,
                message: "Cannot save \(mutation.model) \(mutation.id): \(problem). Store it as a string or a smaller number.",
                details: ["documentId": .string(documentId), "scope": "local"]
            )
            break
        }
    }
    if error == nil {
        // Measured as the room will: the entry with its numbers, which a
        // placeholder of the largest width stands for.
        let widest = JSONValue.number(9_007_199_254_740_991)
        var entry: [String: JSONValue] = ["seq": widest, "e": widest, "k": widest, "m": m.json]
        if mutations.count > 1 { entry["also"] = .array(mutations.dropFirst().map(\.json)) }
        let bytes = recordLogJSONBytes(.object(entry))
        if bytes > RecordLogTransport.entryMaxBytes {
            error = JsBaoError(
                code: .documentEntryTooLarge,
                message: "Cannot save \(m.model) \(m.id): the write is \(bytes) bytes of JSON, over the "
                    + "\(RecordLogTransport.entryMaxBytes)-byte entry limit. Split the record or keep large values outside the document.",
                details: ["documentId": .string(documentId), "scope": "local", "bytes": .number(Double(bytes))]
            )
        }
    }
    guard let error else { return }
    report?(recordLogLocalRefusal(error, documentId: documentId, mutations: mutations))
    throw error
}
