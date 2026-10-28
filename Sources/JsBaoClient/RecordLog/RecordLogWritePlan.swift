import Foundation

// Planning a save on a format-3 document, and the checks an entry passes
// before anything commits: field names the room reserves, the value and name
// rules (`RecordLogValues`), values the wire cannot carry exactly, and entries
// larger than the room reads. A port of js-bao's `record-log-client/write.ts`.

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
    /// The write's guards: `ifNotExists` plans a create of the whole state
    /// whatever the view holds; `condition` rides the mutation.
    var guards: RecordLogWriteGuards = RecordLogWriteGuards()
}

/// The guards a db3 write may carry, judged by the room alone: the write is
/// applied only when they hold, and refused `DB3_CONDITION_NOT_MET` otherwise.
struct RecordLogWriteGuards: Equatable, Sendable {
    /// The record must be live and match this filter (the query filter grammar).
    var condition: JSONValue?
    /// The write is a create that lands only when no live record has its id.
    var ifNotExists: Bool = false
}

/// Fields that never travel: the record's key and the store's own columns.
private func recordLogTravels(_ field: String) -> Bool {
    field != "id" && field != "type" && !field.hasPrefix("_meta_")
}

/// The members of `value` when it is an array of strings (a string set by
/// its shape), else `nil`.
private func recordLogStringArray(_ value: JSONValue?) -> [String]? {
    guard case .array(let items)? = value else { return nil }
    let members = items.compactMap(\.stringValue)
    return members.count == items.count ? members : nil
}

/// The mutation a save writes. A record the view does not hold is a create
/// carrying the whole state; one it holds is a patch of the fields the caller
/// touched. A touched field with no value is written `null`. String-set members
/// travel as deltas: a create's members are added, a patch's additions and
/// removals are each a member set or cleared. An array of strings in any other
/// field is a string set by its shape: a create adds its members, a patch
/// replaces the record's members with them (removals of the members the view
/// holds that it dropped, compared by their bytes, additions of its own), and
/// a patch's null on one is removals of every member the view holds. A set
/// field the caller touched travels even with no net change, as an empty
/// change, so an explicitly empty set reaches the room; an empty set the
/// caller never touched does not travel. Any other array stays in `fields`,
/// where `assertRecordLogEntry` refuses it. js-bao's `planRecordLogSave`.
func planRecordLogSave(_ input: RecordLogSaveInput) -> RecordLogMutation {
    let isNew = input.existing == nil || input.guards.ifNotExists
    var fields: [String: JSONValue] = [:]
    var deltas: [String: [String: Bool]] = [:]
    var scalarKeys: [String] = []
    for key in isNew ? Array(input.dataToSave.keys) : input.touchedFields where !scalarKeys.contains(key) {
        scalarKeys.append(key)
    }
    for key in scalarKeys where recordLogTravels(key) && !input.stringSetFieldNames.contains(key) {
        let value = input.dataToSave[key]
        if let members = recordLogStringArray(value) {
            var delta: [String: Bool] = [:]
            if !isNew, let held = input.existing?[key]?.arrayValue {
                for member in held.compactMap(\.stringValue) where !members.contains(where: { recordLogSameText($0, member) }) {
                    delta[member] = false
                }
            }
            for member in members { delta[member] = true }
            deltas[key] = delta
            continue
        }
        if !isNew, value == nil || value == .null, let held = recordLogStringArray(input.existing?[key]) {
            deltas[key] = Dictionary(held.map { ($0, false) }, uniquingKeysWith: { first, _ in first })
            continue
        }
        fields[key] = value ?? .null
    }
    for field in input.stringSetFieldNames where recordLogTravels(field) {
        let change = input.stringSetChanges[field]
        var delta: [String: Bool] = [:]
        if isNew {
            guard let value = input.dataToSave[field], value != .null else { continue }
            guard let members = recordLogStringArray(value) else {
                fields[field] = value
                continue
            }
            if change == nil && members.isEmpty { continue }
            for member in members { delta[member] = true }
        } else {
            guard let change else { continue }
            for member in change.removals { delta[member] = false }
            for member in change.additions { delta[member] = true }
        }
        deltas[field] = delta
    }
    return RecordLogMutation(
        model: input.model, id: input.recordId, kind: isNew ? .create : .patch,
        fields: fields.isEmpty ? nil : fields,
        stringSetDeltas: deltas.isEmpty ? nil : deltas,
        condition: input.guards.condition, ifNotExists: input.guards.ifNotExists
    )
}

/// Both conditions, conjoined with the grammar's own `$and`; either alone; or none.
private func recordLogConjoined(_ earlier: JSONValue?, _ later: JSONValue?) -> JSONValue? {
    guard let earlier else { return later }
    guard let later else { return earlier }
    return .object(["$and": .array([earlier, later])])
}

/// One record's two saves as one mutation, the later planned against the
/// record as the earlier left it: the later save's fields win, a string-set
/// member takes its last change, and a create stays a create carrying
/// everything. A set field the later save named stays named even when its
/// merged change is empty, so an explicitly empty set reaches the room. A
/// field the later save sends as a value or as a set change is sent only that
/// way, never in both. A later create or delete stands for both. Every
/// condition is kept, two conjoined (`{ $and: [earlier, later] }`);
/// `ifNotExists` is kept while the merged mutation is a create.
func mergeRecordLogMutations(_ earlier: RecordLogMutation, _ later: RecordLogMutation) -> RecordLogMutation {
    let condition = recordLogConjoined(earlier.condition, later.condition)
    func guarded(_ m: RecordLogMutation) -> RecordLogMutation {
        var out = m
        out.condition = condition
        out.ifNotExists = m.kind == .create && (earlier.ifNotExists || later.ifNotExists)
        return out
    }
    if later.kind != .patch || earlier.kind == .delete { return guarded(later) }
    let kind = earlier.kind
    var fields = earlier.fields ?? [:]
    for (field, value) in later.fields ?? [:] { fields[field] = value }
    var deltas = (earlier.stringSetDeltas ?? [:]).filter { later.fields?[$0.key] == nil }
    for (field, delta) in later.stringSetDeltas ?? [:] {
        fields[field] = nil
        var merged = deltas[field] ?? [:]
        for (member, present) in delta { merged[member] = present }
        // A create adds its members; one removed since was never there.
        if kind == .create { merged = merged.filter { $0.value } }
        deltas[field] = merged
    }
    return guarded(RecordLogMutation(
        model: earlier.model, id: earlier.id, kind: kind,
        fields: fields.isEmpty ? nil : fields,
        stringSetDeltas: deltas.isEmpty ? nil : deltas
    ))
}

/// What a transaction holds of one record: its absolute write (a create,
/// patch or delete, the record's saves merged) and the increment of the
/// fields that write does not assign, sent right after it in the record's
/// entry (js-bao's `RecordLogHeldWrites`).
struct RecordLogHeldWrites: Equatable, Sendable {
    /// The record's saves and delete, merged into one mutation.
    var mutation: RecordLogMutation?
    /// The deltas of fields `mutation` does not assign, summed.
    var increment: RecordLogMutation?

    init(mutation: RecordLogMutation? = nil, increment: RecordLogMutation? = nil) {
        self.mutation = mutation
        self.increment = increment
    }

    /// What the record's entry carries: the absolute write, then the increment.
    var mutations: [RecordLogMutation] { [mutation, increment].compactMap { $0 } }
}

/// Fold one more write of a record into what a transaction holds of it,
/// field by field, so an increment beside a write of other fields stays an
/// increment and is never sent as a reset of the counter. An increment's
/// delta of a field the held write assigns (any field of a create) is added
/// into that value; every other delta is added to the held increment. A later
/// save or patch merges into the held write and takes a field it names over
/// from the increment as absolute; a later create or delete stands for the
/// record and drops the increment. Conditions are kept: conjoined where the
/// write they guard lands, a dropped increment's on what stands for it.
/// js-bao's `foldRecordLogIncrement`.
func foldRecordLogIncrement(_ held: RecordLogHeldWrites, _ next: RecordLogMutation) -> RecordLogHeldWrites {
    if next.kind != .increment {
        var mutation = held.mutation.map { mergeRecordLogMutations($0, next) } ?? next
        let named = Set((next.fields ?? [:]).keys).union((next.stringSetDeltas ?? [:]).keys)
        if next.kind == .patch, var increment = held.increment {
            let left = (increment.fields ?? [:]).filter { !named.contains($0.key) }
            if !left.isEmpty {
                increment.fields = left
                return RecordLogHeldWrites(mutation: mutation, increment: increment)
            }
        }
        if let dropped = held.increment?.condition {
            mutation.condition = recordLogConjoined(mutation.condition, dropped)
        }
        return RecordLogHeldWrites(mutation: mutation)
    }
    let absolute = held.mutation.flatMap { $0.kind == .delete ? nil : $0 }
    var intoAbsolute: [String: JSONValue] = [:]
    var deltas = held.increment?.fields ?? [:]
    var accumulated = false
    for (field, delta) in next.fields ?? [:] {
        if let absolute, absolute.kind == .create || absolute.fields?[field] != nil {
            intoAbsolute[field] = .number(recordLogNumeric(absolute.fields?[field]) + recordLogNumeric(delta))
        } else {
            deltas[field] = .number(recordLogNumeric(deltas[field]) + recordLogNumeric(delta))
            accumulated = true
        }
    }
    var mutation = held.mutation
    if var updated = absolute, !intoAbsolute.isEmpty {
        updated.fields = (updated.fields ?? [:]).merging(intoAbsolute) { _, new in new }
        if !accumulated { updated.condition = recordLogConjoined(absolute?.condition, next.condition) }
        mutation = updated
    }
    if !accumulated && held.increment == nil { return RecordLogHeldWrites(mutation: mutation) }
    var increment = held.increment ?? next.withoutGuards
    increment.fields = deltas
    increment.condition = recordLogConjoined(held.increment?.condition, accumulated ? next.condition : nil)
    return RecordLogHeldWrites(mutation: mutation, increment: increment)
}

/// The mutation an increment writes: each of `fields` added to the record's
/// field, a missing or non-numeric one counting as 0; two increments of one
/// field both count whatever order they reach the room in. js-bao's
/// `planRecordLogIncrement`.
func planRecordLogIncrement(
    model: String, recordId: String, fields: [String: JSONValue], condition: JSONValue? = nil
) -> RecordLogMutation {
    RecordLogMutation(model: model, id: recordId, kind: .increment, fields: fields, condition: condition)
}

/// What a model-free write does: `put` creates (replacing a record the id
/// names), `patch` changes the fields named, `delete` removes the record.
enum RecordLogRecordWriteKind: Sendable {
    case put, patch, delete

    /// The kind its mutation has.
    var mutationKind: RecordLogWriteKind {
        switch self {
        case .put: return .create
        case .patch: return .patch
        case .delete: return .delete
        }
    }
}

/// Refuse a model-free write the room would refuse by its names, before
/// anything is planned: an id that is empty, a model name that is not an
/// identifier, or a key of `data` that `recordLogReservedFieldProblem`
/// reserves or that is not an identifier, each `.documentEntryInvalid` in the
/// room's words. The `id` key is the one key not judged: the planner ignores
/// it. The refusal is reported through `report` with the one write it
/// refused, then thrown. js-bao's `assertRecordLogRecordInput`.
func assertRecordLogRecordInput(
    documentId: String, model: String, id: String, kind: RecordLogRecordWriteKind,
    data: [String: DocumentRecordValue], report: ((DocumentWriteRefusedEvent) -> Void)? = nil
) throws {
    var message: String?
    if id.isEmpty {
        message = "Cannot save \(model): a record id is a non-empty string."
    } else if let problem = RecordLogValues.identifierProblem(.model, model) {
        message = "Cannot save \(model) \(id): \(problem)."
    } else {
        for key in data.keys.sorted() where key != "id" {
            if let problem = recordLogReservedFieldProblem(key) ?? RecordLogValues.identifierProblem(.field, key) {
                message = "Cannot save \(model) \(id): \(problem). Rename the field."
                break
            }
        }
    }
    guard let message else { return }
    let error = JsBaoError(
        code: .documentEntryInvalid, message: message, details: ["documentId": .string(documentId), "scope": "local"]
    )
    report?(recordLogLocalRefusal(
        error, documentId: documentId, mutations: [RecordLogMutation(model: model, id: id, kind: kind.mutationKind)]
    ))
    throw error
}

/// A model-free write, as the planner takes it.
struct RecordLogRecordWriteInput {
    /// The record's model.
    var model: String
    /// The record the write lands on.
    var id: String
    /// `put` creates (replacing a record the id names); `patch` changes the fields named.
    var kind: RecordLogRecordWriteKind
    /// The record's view row, or `nil` when the view holds none.
    var existing: RecordLogRow?
    /// The fields to write; an `id` key is ignored.
    var data: [String: DocumentRecordValue]
}

/// One field's member changes, each member once by its UTF-8 bytes (a later
/// change of the same bytes wins).
struct RecordLogMemberChanges {
    private var entries: [(member: String, present: Bool)] = []
    private var index: [[UInt8]: Int] = [:]

    mutating func set(_ member: String, _ present: Bool) {
        let bytes = Array(member.utf8)
        if let at = index[bytes] {
            entries[at].present = present
        } else {
            index[bytes] = entries.count
            entries.append((member, present))
        }
    }

    /// The changes as member maps no two of whose members Swift's `String`
    /// equality merges (it compares canonically, so U+00E9 and U+0065 U+0301
    /// are one key): the members of each canonically equal group go one per
    /// map, removals before additions and each in byte order. One map when no
    /// two members are canonically equal; one empty map for no change.
    func rounds() -> [[String: Bool]] {
        var groups: [[(member: String, present: Bool)]] = []
        var groupOf: [String: Int] = [:]
        for entry in entries {
            if let at = groupOf[entry.member] {
                groups[at].append(entry)
            } else {
                groupOf[entry.member] = groups.count
                groups.append([entry])
            }
        }
        let ordered = groups.map { group in
            group.sorted { a, b in
                a.present != b.present ? !a.present : Array(a.member.utf8).lexicographicallyPrecedes(Array(b.member.utf8))
            }
        }
        let count = max(1, ordered.map(\.count).max() ?? 0)
        return (0..<count).map { round in
            var map: [String: Bool] = [:]
            for group in ordered where round < group.count { map[group[round].member] = group[round].present }
            return map
        }
    }
}

/// The mutations a model-free write commits, planned against the record's
/// view row, in order, as one entry (`m` then `also`). A `put` is a create entry carrying
/// every field of `data` (the room's create rule replaces a record the id
/// names); a `patch` is a patch of the fields named, even of a record the view
/// does not hold. A string set is a put's additions, and a patch's
/// replacement of the record's members (removals of the held members it does
/// not name, by their bytes, and additions of its own); a patch's `null` on a
/// field the view holds as an array removes every member. A set change
/// removes every member the view holds (`clear`), then the ones named
/// (`remove`), then adds (`add`; a put takes only these); a change of nothing
/// travels as an empty change. The `id` key of `data` is ignored.
///
/// One mutation, as js-bao's `planRecordLogRecordWrite` plans it, unless a
/// field's changes name two members Swift's `String` equality merges (the two
/// spellings of "é"): those go in further patches of the record, one spelling
/// each (``RecordLogMemberChanges/rounds()``), which the entry's `also`
/// carries, so the record ends as one write would leave it and the room
/// accepts or refuses them together.
func planRecordLogRecordWrites(_ input: RecordLogRecordWriteInput) -> [RecordLogMutation] {
    let isPut = input.kind == .put
    let held = { (key: String) -> [String] in
        isPut ? [] : (recordLogStringArray(input.existing?[key]) ?? [])
    }
    var fields: [String: JSONValue] = [:]
    var changes: [String: RecordLogMemberChanges] = [:]
    for (key, value) in input.data where key != "id" {
        var change = RecordLogMemberChanges()
        switch value {
        case .string, .number, .bool:
            fields[key] = value.json
            continue
        case .null:
            guard !isPut, recordLogStringArray(input.existing?[key]) != nil else {
                fields[key] = .null
                continue
            }
            for member in held(key) { change.set(member, false) }
        case .stringSet(let members):
            for member in held(key) where !members.contains(where: { recordLogSameText($0, member) }) {
                change.set(member, false)
            }
            for member in members { change.set(member, true) }
        case .setChange(let add, let remove, let clear):
            if !isPut {
                if clear { for member in held(key) { change.set(member, false) } }
                for member in remove { change.set(member, false) }
            }
            for member in add { change.set(member, true) }
        }
        changes[key] = change
    }
    let rounds = changes.mapValues { $0.rounds() }
    let count = max(1, rounds.values.map(\.count).max() ?? 1)
    return (0..<count).map { round in
        let deltas = rounds.compactMapValues { round < $0.count ? $0[round] : nil }
        return RecordLogMutation(
            model: input.model, id: input.id, kind: round == 0 && isPut ? .create : .patch,
            fields: round == 0 && !fields.isEmpty ? fields : nil,
            stringSetDeltas: deltas.isEmpty ? nil : deltas
        )
    }
}

/// The one mutation a model-free write commits when no field's changes name
/// two spellings of a member: ``planRecordLogRecordWrites(_:)``'s first.
func planRecordLogRecordWrite(_ input: RecordLogRecordWriteInput) -> RecordLogMutation {
    planRecordLogRecordWrites(input)[0]
}

/// The mutation a delete writes.
func planRecordLogDelete(model: String, recordId: String) -> RecordLogMutation {
    RecordLogMutation(model: model, id: recordId, kind: .delete)
}

/// The mutation a delete writes, carrying `condition` when one is given.
func planRecordLogDelete(model: String, recordId: String, condition: JSONValue?) -> RecordLogMutation {
    RecordLogMutation(model: model, id: recordId, kind: .delete, condition: condition)
}

/// Why `condition` cannot guard a write, in the room's words, or `nil`: it
/// must be an object the query translator accepts (js-bao's `conditionProblem`).
func recordLogConditionProblem(_ condition: JSONValue) -> String? {
    guard let filter = condition.objectValue else {
        return "condition must be an object (the query filter grammar, e.g. { status: \"open\" })"
    }
    do {
        _ = try QueryTranslator.translateView(filter)
        return nil
    } catch {
        return "condition: \((error as? JsBaoError)?.message ?? error.localizedDescription)"
    }
}

/// Why a mutation's guards are malformed, in the room's words, or `nil`.
private func recordLogGuardProblem(_ m: RecordLogMutation, _ at: Int) -> String? {
    let place = at == 0 ? "m" : "also[\(at - 1)]"
    if let condition = m.condition, let problem = recordLogConditionProblem(condition) { return "\(place).\(problem)" }
    if m.ifNotExists, m.kind != .create { return "\(place).ifNotExists guards a create; \(place) is a \(m.kind.rawValue)" }
    return nil
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

/// Why a field name is reserved, or `nil` when a record may carry it:
/// `type` is the model's column in queries, a leading `_` is internal, and a
/// name in `ReservedFieldNames` breaks a generated model on the JavaScript or
/// the Swift client; `id` is allowed. The one rule js-bao's
/// `checkReservedFieldName` states, with the same sentence.
func recordLogReservedFieldProblem(_ field: String) -> String? {
    if field == "id" { return nil }
    if field == "type" { return "Field 'type' is reserved (maps to internal _type column in queries)" }
    if field.hasPrefix("_") { return "Field '\(field)' is reserved (fields starting with '_' are internal)" }
    if let reason = ReservedFieldNames.reasons[field] { return "Field '\(field)' is reserved (\(reason))" }
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
/// `recordLogReservedFieldProblem` reserves (`type`, a leading `_`, or a name
/// that breaks a generated model on either client), a model or field name
/// that is not an identifier, a value no record-log field holds (an object,
/// an array in `fields`: a string set travels as deltas), or a value that is
/// not finite or an integer outside ±2^53 (`.documentEntryInvalid`), or
/// an entry whose JSON is over 1 MiB (`.documentEntryTooLarge`). The refusal
/// is reported through `report` with the one write it refused, then thrown.
func assertRecordLogEntry(
    documentId: String, mutations: [RecordLogMutation], upsertOn: String? = nil,
    report: ((DocumentWriteRefusedEvent) -> Void)? = nil
) throws {
    guard let m = mutations.first else { return }
    var error: JsBaoError?
    func invalid(_ mutation: RecordLogMutation, _ problem: String) -> JsBaoError {
        JsBaoError(
            code: .documentEntryInvalid, message: "Cannot save \(mutation.model) \(mutation.id): \(problem).",
            details: ["documentId": .string(documentId), "scope": "local"]
        )
    }
    if upsertOn != nil {
        if m.kind == .increment {
            error = invalid(m, "upsertOn cannot ride an entry whose m is an increment: an increment names its record")
        } else if m.ifNotExists {
            error = invalid(m, "m.ifNotExists cannot ride an entry with upsertOn: an upsert lands on the record holding the key")
        }
    }
    // An increment of a field an absolute mutation of the same entry assigns
    // would not be ordered after it: a transaction folds it into the value.
    var assigned: [RecordLogRecordKey: (at: Int, fields: Set<String>)] = [:]
    for (at, mutation) in mutations.enumerated() where error == nil {
        if mutation.kind != .increment {
            if mutation.kind != .delete { assigned[mutation.key] = (at, Set((mutation.fields ?? [:]).keys)) }
            continue
        }
        guard let absolute = assigned[mutation.key],
              let field = (mutation.fields ?? [:]).keys.sorted().first(where: { absolute.fields.contains($0) })
        else { continue }
        let place = { (i: Int) in i == 0 ? "m" : "also[\(i - 1)]" }
        error = invalid(mutation, "\(place(at)) increments \(field), which \(place(absolute.at)) of the same entry assigns")
    }
    for (at, mutation) in mutations.enumerated() where error == nil {
        let names = Array((mutation.fields ?? [:]).keys).sorted() + Array((mutation.stringSetDeltas ?? [:]).keys).sorted()
        if let reserved = names.lazy.compactMap(recordLogReservedFieldProblem).first {
            error = JsBaoError(
                code: .documentEntryInvalid,
                message: "Cannot save \(mutation.model) \(mutation.id): \(reserved). Rename the field.",
                details: ["documentId": .string(documentId), "scope": "local"]
            )
            break
        }
        if let rule = RecordLogValues.ruleProblem(mutation) {
            error = JsBaoError(
                code: .documentEntryInvalid,
                message: "Cannot save \(mutation.model) \(mutation.id): \(rule).",
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
        if let problem = recordLogGuardProblem(mutation, at) {
            error = invalid(mutation, problem)
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
