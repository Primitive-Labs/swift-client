import Foundation

// The vocabulary of the record-log client (a `documentFormat: 3` document):
// what a client keeps of its unacknowledged entries, what the room sends down,
// and what an app is handed back when a write is refused. A port of js-bao's
// `record-log-client/types.ts` and the parts of `record-log/types.ts` the
// client reads; every wire shape is the JS one, field for field.

/// A record of a format-3 document: its model and its id.
public struct RecordLogRecordKey: Hashable, Sendable, CustomStringConvertible {
    /// The record's model.
    public let model: String
    /// The record's id.
    public let id: String

    public init(model: String, id: String) {
        self.model = model
        self.id = id
    }

    public var description: String { "\(model)/\(id)" }

    var json: JSONValue { .object(["model": .string(model), "id": .string(id)]) }

    init?(json: JSONValue?) {
        guard let model = json?["model"]?.stringValue, let id = json?["id"]?.stringValue else { return nil }
        self.init(model: model, id: id)
    }
}

/// What a write did to a record, as a refusal hands it back.
public enum RecordLogWriteKind: String, Sendable, Equatable {
    case create
    case patch
    case delete
    /// Added each of its `fields`, a number, to the record's field.
    case increment
}

/// A record a refusal names with the room's row of it: the record a failed
/// `condition` was judged against, or the one an increment named
/// (`row == nil` when the record has no live row).
public struct RecordLogCurrentRecord: Sendable, Equatable {
    /// The record's model.
    public let model: String
    /// The record's id.
    public let id: String
    /// The room's live row of the record, or `nil`.
    public let row: [String: JSONValue]?

    public init(model: String, id: String, row: [String: JSONValue]?) {
        self.model = model
        self.id = id
        self.row = row
    }

    /// The record as the JS client's `current` spells it: `{ model, id, row }`, `row` `null` for none.
    public var json: JSONValue {
        .object(["model": .string(model), "id": .string(id), "row": row.map { .object($0) } ?? .null])
    }

    init?(json: JSONValue?) {
        guard let model = json?["model"]?.stringValue, let id = json?["id"]?.stringValue else { return nil }
        self.init(model: model, id: id, row: json?["row"]?.objectValue)
    }
}

/// What a write of this client left in the confirmed rows when the room
/// settled it: each record it touched and the room's row of it then (`nil`
/// when the record shows none), before any later result and without the
/// guesses of other pending writes.
public struct RecordLogSettlement: Sendable, Equatable {
    /// One per record the write touched.
    public let rows: [RecordLogCurrentRecord]

    public init(rows: [RecordLogCurrentRecord]) {
        self.rows = rows
    }
}

/// One write the room (or this client, before sending) handed back, with its
/// values: what an app needs to redo it or tell the user what was lost.
public struct RecordLogRefusedWrite: Sendable, Equatable {
    /// The record's model.
    public let model: String
    /// The record's id.
    public let recordId: String
    /// What the write did to the record.
    public let kind: RecordLogWriteKind
    /// The field values the write set; a cleared field is `.null`.
    public let fields: [String: JSONValue]?
    /// Per string-set field, the members the write added (`true`) or removed (`false`).
    public let stringSetDeltas: [String: [String: Bool]]?
    /// The writer's sequence number of the entry that carried it; 0 for a
    /// write refused before it was sent.
    public let seq: Int

    public init(
        model: String, recordId: String, kind: RecordLogWriteKind,
        fields: [String: JSONValue]?, stringSetDeltas: [String: [String: Bool]]?, seq: Int
    ) {
        self.model = model
        self.recordId = recordId
        self.kind = kind
        self.fields = fields
        self.stringSetDeltas = stringSetDeltas
        self.seq = seq
    }
}

/// Whether a record's last write from this client has reached the room.
public enum RecordSyncState: String, Sendable, Equatable {
    /// An entry of this client touching the record is not acknowledged yet.
    case pending
    /// The room has acknowledged everything this client wrote to the record.
    case confirmed
    /// The save that produced this handle was handed back.
    case refused
}

/// A record's row as the app reads it: `id` and every field; a field written
/// `null` is a present `.null`; a string set is an array of its members in
/// code-point order.
typealias RecordLogRow = [String: JSONValue]

/// The constants a format-3 client works with, the JS client's numbers.
enum RecordLogTransport {
    /// The document format this store serves.
    static let documentFormat = 3
    /// The epoch every document starts in.
    static let firstEpoch = 1
    /// The rotation size a client assumes before its first handshake.
    static let defaultEpochEntries = 10_000
    /// The largest entry a client sends, in bytes of its JSON.
    static let entryMaxBytes = 1024 * 1024
    /// The size a batch of entries aims at; a larger entry travels alone.
    static let frameTargetBytes = 64 * 1024
    /// How many `record.entries` frames of one writer are unanswered at a
    /// time. Entries written meanwhile queue, and leave together once the
    /// frame's last entry is answered.
    static let framesInFlight = 1
    /// How long an unanswered `record.entries` frame holds back the next.
    /// After it, what is queued leaves; the frame's entries are still sent
    /// again when the room reports them missing.
    static let frameWaitMs = 2_000
    /// How long the sender gathers the entries of one batch.
    static let tickMs = 5
    /// How long a group of saves stays open before it commits.
    static let groupCommitMs = 5
    /// The most entries the room takes in one `record.entries` frame.
    static let upBatchMax = 200
    /// The most entries one `record.entries` frame of this client carries.
    /// Fewer than the room takes, so another writer's save is not held long
    /// behind one request of a burst.
    static let frameEntriesMax = 64
    /// How long an orphan writer's drain waits for the room's answers.
    static let drainWaitMs = 15_000
    /// How long a result ahead of the cursor may wait for the gap to fill.
    static let resultGapMs = 2_000
}

// MARK: - Mutations and entries

/// One record write.
///
/// `fields` absent from the mutation leave the record's values alone; a field
/// given `.null` is set to `null`. A create replaces what its writer had seen of
/// the record; a patch sets what it names; a delete removes the record; an
/// increment adds each of its `fields` (a number) to the record's field, a
/// missing or non-numeric one counting as 0. `condition` (the query filter
/// grammar) and `ifNotExists` (a create only) are guards the room judges and
/// never stores.
struct RecordLogMutation: Equatable, Sendable {
    var model: String
    var id: String
    var kind: RecordLogWriteKind
    var fields: [String: JSONValue]?
    var stringSetDeltas: [String: [String: Bool]]?
    /// The record must be live and match this filter when the room applies the write.
    var condition: JSONValue?
    /// On a create: applied only when the record has no live row.
    var ifNotExists: Bool = false

    init(
        model: String, id: String, kind: RecordLogWriteKind,
        fields: [String: JSONValue]? = nil, stringSetDeltas: [String: [String: Bool]]? = nil,
        condition: JSONValue? = nil, ifNotExists: Bool = false
    ) {
        self.model = model
        self.id = id
        self.kind = kind
        self.fields = fields
        self.stringSetDeltas = stringSetDeltas
        self.condition = condition
        self.ifNotExists = ifNotExists
    }

    var key: RecordLogRecordKey { RecordLogRecordKey(model: model, id: id) }

    /// Whether the room judges a guard of this mutation: a `condition` or `ifNotExists`.
    var carriesGuard: Bool { condition != nil || ifNotExists }

    /// The mutation with its guards dropped.
    var withoutGuards: RecordLogMutation {
        var plain = self
        plain.condition = nil
        plain.ifNotExists = false
        return plain
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(model), "id": .string(id), "kind": .string(kind.rawValue),
        ]
        if let fields { object["fields"] = .object(fields) }
        if let stringSetDeltas {
            object["stringSetDeltas"] = .object(stringSetDeltas.mapValues { members in
                .object(members.mapValues { .bool($0) })
            })
        }
        if let condition { object["condition"] = condition }
        if ifNotExists { object["ifNotExists"] = .bool(true) }
        return .object(object)
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue,
              let model = object["model"]?.stringValue,
              let id = object["id"]?.stringValue,
              let kind = object["kind"]?.stringValue.flatMap(RecordLogWriteKind.init(rawValue:))
        else { return nil }
        self.model = model
        self.id = id
        self.kind = kind
        self.fields = object["fields"]?.objectValue
        if let deltas = object["stringSetDeltas"]?.objectValue {
            var out: [String: [String: Bool]] = [:]
            for (field, members) in deltas {
                var delta: [String: Bool] = [:]
                for (member, present) in members.objectValue ?? [:] {
                    if let present = present.boolValue { delta[member] = present }
                }
                out[field] = delta
            }
            self.stringSetDeltas = out
        } else {
            self.stringSetDeltas = nil
        }
        self.condition = object["condition"]
        self.ifNotExists = object["ifNotExists"]?.boolValue == true
    }
}

/// An upsert's resolution: the id a writer used, and the existing record the
/// room applied the write to.
struct RecordLogAlias: Equatable, Sendable {
    var model: String
    var from: String
    var to: String

    var json: JSONValue {
        .object(["model": .string(model), "from": .string(from), "to": .string(to)])
    }

    init(model: String, from: String, to: String) {
        self.model = model
        self.from = from
        self.to = to
    }

    init?(json: JSONValue?) {
        guard let model = json?["model"]?.stringValue,
              let from = json?["from"]?.stringValue,
              let to = json?["to"]?.stringValue
        else { return nil }
        self.init(model: model, from: from, to: to)
    }
}

/// One entry as its writer keeps it until the room has judged it.
///
/// `seq`, `e` and `k` are fixed when it is written. A void entry is a withdrawn
/// one, still sent (empty) so the room can move past its number.
struct RecordLogPendingEntry: Equatable, Sendable {
    /// The writer's sequence number.
    var seq: Int
    /// The epoch it was written in.
    var e: Int
    /// The last log number the writer had applied when it wrote the entry.
    var k: Int
    /// Its first mutation.
    var m: RecordLogMutation
    /// More mutations, applied and refused together with `m`.
    var also: [RecordLogMutation]?
    /// `m` is a create that becomes a patch of the live record holding this field's value.
    var upsertOn: String?
    /// Withdrawn after a refusal; sent empty.
    var isVoid: Bool = false
    /// When it was written, in milliseconds.
    var ts: Int64?
    /// The log number of its result, once the room acknowledged it.
    var acked: Int?
    /// The upsert's resolution its acknowledgement named, applied when it settles.
    var alias: RecordLogAlias?

    /// `m`, then `also`.
    var mutations: [RecordLogMutation] { [m] + (also ?? []) }

    /// The distinct records the entry's mutations name, in order of first mention.
    var keys: [RecordLogRecordKey] {
        var seen = Set<RecordLogRecordKey>()
        var out: [RecordLogRecordKey] = []
        for mutation in mutations where seen.insert(mutation.key).inserted {
            out.append(mutation.key)
        }
        return out
    }

    /// The entry as the store keeps it: everything but `acked`, which has a column of its own.
    var storedJSON: JSONValue {
        var object: [String: JSONValue] = [
            "seq": .number(Double(seq)), "e": .number(Double(e)), "k": .number(Double(k)), "m": m.json,
        ]
        if let also { object["also"] = .array(also.map(\.json)) }
        if let upsertOn { object["upsertOn"] = .string(upsertOn) }
        if isVoid { object["void"] = .bool(true) }
        if let ts { object["ts"] = .number(Double(ts)) }
        if let alias { object["alias"] = alias.json }
        return .object(object)
    }

    init(
        seq: Int, e: Int, k: Int, m: RecordLogMutation, also: [RecordLogMutation]? = nil,
        upsertOn: String? = nil, isVoid: Bool = false, ts: Int64? = nil,
        acked: Int? = nil, alias: RecordLogAlias? = nil
    ) {
        self.seq = seq
        self.e = e
        self.k = k
        self.m = m
        self.also = also
        self.upsertOn = upsertOn
        self.isVoid = isVoid
        self.ts = ts
        self.acked = acked
        self.alias = alias
    }

    init?(stored json: JSONValue?) {
        guard let object = json?.objectValue,
              let seq = object["seq"]?.wholeNumber, let e = object["e"]?.wholeNumber,
              let k = object["k"]?.wholeNumber, let m = RecordLogMutation(json: object["m"])
        else { return nil }
        self.init(
            seq: seq, e: e, k: k, m: m,
            also: object["also"]?.arrayValue?.compactMap { RecordLogMutation(json: $0) },
            upsertOn: object["upsertOn"]?.stringValue,
            isVoid: object["void"]?.boolValue == true,
            ts: object["ts"]?.numberValue.map { Int64($0) },
            acked: object["acked"]?.wholeNumber,
            alias: RecordLogAlias(json: object["alias"])
        )
    }

    /// The entry as `record.entries` carries it: no writer, and a void one empty.
    var wire: RecordLogWireEntry {
        isVoid
            ? RecordLogWireEntry(seq: seq, e: e, k: k, isVoid: true)
            : RecordLogWireEntry(seq: seq, e: e, k: k, m: m, also: also, upsertOn: upsertOn)
    }

    /// The writes the entry carried, one per mutation, for a hand-back.
    var refusedWrites: [RecordLogRefusedWrite] {
        mutations.map { mutation in
            RecordLogRefusedWrite(
                model: mutation.model, recordId: mutation.id, kind: mutation.kind,
                fields: mutation.fields, stringSetDeltas: mutation.stringSetDeltas, seq: seq
            )
        }
    }
}

/// One entry as `record.entries` carries it: no writer on it.
struct RecordLogWireEntry: Equatable, Sendable {
    var seq: Int
    var e: Int
    var k: Int
    var m: RecordLogMutation?
    var also: [RecordLogMutation]?
    var upsertOn: String?
    var isVoid: Bool = false

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "seq": .number(Double(seq)), "e": .number(Double(e)), "k": .number(Double(k)),
        ]
        if let m { object["m"] = m.json }
        if let also { object["also"] = .array(also.map(\.json)) }
        if let upsertOn { object["upsertOn"] = .string(upsertOn) }
        if isVoid { object["void"] = .bool(true) }
        return .object(object)
    }
}

// MARK: - What the room sends

/// What one entry changed in one record, as a client with plain rows applies it.
struct RecordLogChange: Equatable, Sendable {
    var model: String
    var id: String
    /// The record is gone.
    var gone: Bool = false
    /// The record appeared: its whole row.
    var row: RecordLogRow?
    /// Fields whose value changed.
    var set: RecordLogRow?
    /// Fields that left the row.
    var unset: [String]?

    init(
        model: String, id: String, gone: Bool = false, row: RecordLogRow? = nil,
        set: RecordLogRow? = nil, unset: [String]? = nil
    ) {
        self.model = model
        self.id = id
        self.gone = gone
        self.row = row
        self.set = set
        self.unset = unset
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue,
              let model = object["model"]?.stringValue,
              let id = object["id"]?.stringValue
        else { return nil }
        self.init(
            model: model, id: id,
            gone: object["gone"]?.boolValue == true,
            row: object["row"]?.objectValue,
            set: object["set"]?.objectValue,
            unset: object["unset"]?.arrayValue?.compactMap(\.stringValue)
        )
    }
}

/// An accepted entry as the room relays it: its log number, epoch and changes.
struct RecordLogResult: Equatable, Sendable {
    /// The entry's log number.
    var l: Int
    /// The entry's epoch.
    var e: Int
    /// What it changed. `nil` only in a compact acknowledgement: the writer's
    /// own item for an entry the room applied as written, whose changes the
    /// client derives from its pending entry. `[]` means nothing visible changed.
    var changes: [RecordLogChange]?
    /// The upsert's resolution, when there was one.
    var alias: RecordLogAlias?
    /// The writer, on the acknowledging connection only.
    var w: String?
    /// The writer's sequence number, on the acknowledging connection only.
    var seq: Int?
}

/// One item of a `record.results` frame.
enum RecordLogResultItem: Equatable, Sendable {
    /// An accepted entry.
    case result(RecordLogResult)
    /// The room moved past a void entry of this writer.
    case void(seq: Int)
    /// The room had accepted this entry of this writer before; its row comes from catch-up.
    case duplicate(seq: Int)

    init?(json: JSONValue?) {
        guard let object = json?.objectValue else { return nil }
        if object["void"]?.boolValue == true, let seq = object["seq"]?.wholeNumber {
            self = .void(seq: seq)
            return
        }
        if object["duplicate"]?.boolValue == true, let seq = object["seq"]?.wholeNumber {
            self = .duplicate(seq: seq)
            return
        }
        guard let l = object["l"]?.wholeNumber, let e = object["e"]?.wholeNumber else { return nil }
        self = .result(RecordLogResult(
            l: l, e: e,
            changes: object["changes"]?.arrayValue.map { $0.compactMap { RecordLogChange(json: $0) } },
            alias: RecordLogAlias(json: object["alias"]),
            w: object["w"]?.stringValue,
            seq: object["seq"]?.wholeNumber
        ))
    }
}

/// How far a refusal reaches.
enum RecordLogRefusalScope: String, Sendable, Equatable {
    case writer
    case record
    case entry
}

/// A record a refusal names, with the first refused number on it.
struct RecordLogRefusedRecord: Equatable, Sendable {
    var model: String
    var id: String
    var from: Int

    var key: RecordLogRecordKey { RecordLogRecordKey(model: model, id: id) }

    var json: JSONValue {
        .object(["model": .string(model), "id": .string(id), "from": .number(Double(from))])
    }
}

/// A `record.refused` frame's content.
struct RecordLogRefusal: Equatable, Sendable {
    /// The refused entry's sequence number.
    var seq: Int
    /// Why it was refused.
    var code: String
    /// How far the refusal reaches.
    var scope: RecordLogRefusalScope
    /// The first refused number.
    var from: Int
    /// Each record the entry touched, with the first refused number on it.
    var records: [RecordLogRefusedRecord]
    /// The record already holding the key, for a constraint refusal.
    var conflicting: RecordLogRecordKey?
    /// The constraint's name, for a constraint refusal.
    var constraint: String?
    /// What the room said.
    var message: String?
    /// For `DB3_CONDITION_NOT_MET`, the record whose guard failed and the
    /// room's row of it; for `DB3_RECORD_NOT_FOUND`, the record an increment
    /// named (`row == nil`).
    var current: RecordLogCurrentRecord?
    /// For `DB3_TRIGGER_REFUSED`, the code of the db3 trigger that refused the write.
    var reason: String?

    init(
        seq: Int, code: String, scope: RecordLogRefusalScope, from: Int,
        records: [RecordLogRefusedRecord] = [], conflicting: RecordLogRecordKey? = nil,
        constraint: String? = nil, message: String? = nil, current: RecordLogCurrentRecord? = nil,
        reason: String? = nil
    ) {
        self.seq = seq
        self.code = code
        self.scope = scope
        self.from = from
        self.records = records
        self.conflicting = conflicting
        self.constraint = constraint
        self.message = message
        self.current = current
        self.reason = reason
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue,
              let seq = object["seq"]?.wholeNumber,
              let scope = object["scope"]?.stringValue.flatMap(RecordLogRefusalScope.init(rawValue:))
        else { return nil }
        self.init(
            seq: seq,
            code: object["code"]?.stringValue ?? "",
            scope: scope,
            from: object["from"]?.wholeNumber ?? seq,
            records: (object["records"]?.arrayValue ?? []).compactMap { record in
                guard let model = record["model"]?.stringValue, let id = record["id"]?.stringValue,
                      let from = record["from"]?.wholeNumber
                else { return nil }
                return RecordLogRefusedRecord(model: model, id: id, from: from)
            },
            conflicting: RecordLogRecordKey(json: object["conflicting"]),
            constraint: object["constraint"]?.stringValue,
            message: object["message"]?.stringValue,
            current: RecordLogCurrentRecord(json: object["current"]),
            reason: object["reason"]?.stringValue
        )
    }
}

/// A frame a client sends to the room.
enum RecordLogUpFrame: Equatable, Sendable {
    /// Entries, in `seq` order.
    case entries([RecordLogWireEntry])
    /// The writer resumes at `nextSeq`; `records` names refused records with their first refused number.
    case resume(nextSeq: Int, records: [RecordLogRefusedRecord]?)
    /// The models' declarations.
    case declare(models: [String: JSONValue])

    var json: JSONValue {
        switch self {
        case .entries(let entries):
            return .object(["type": "record.entries", "entries": .array(entries.map(\.json))])
        case .resume(let nextSeq, let records):
            var object: [String: JSONValue] = ["type": "record.resume", "nextSeq": .number(Double(nextSeq))]
            if let records { object["records"] = .array(records.map(\.json)) }
            return .object(object)
        case .declare(let models):
            return .object(["type": "record.declare", "models": .object(models)])
        }
    }
}

/// A live row a catch-up carries.
struct RecordLogCatchUpRow: Equatable, Sendable {
    var model: String
    var id: String
    var row: RecordLogRow
}

/// Fields of one model that no two live records may hold the same values of.
struct RecordLogConstraint: Equatable, Sendable {
    var model: String
    var name: String
    var fields: [String]

    var json: JSONValue {
        .object(["model": .string(model), "name": .string(name), "fields": .array(fields.map { .string($0) })])
    }

    init(model: String, name: String, fields: [String]) {
        self.model = model
        self.name = name
        self.fields = fields
    }

    init?(json: JSONValue?) {
        guard let model = json?["model"]?.stringValue, let name = json?["name"]?.stringValue else { return nil }
        self.init(model: model, name: name, fields: json?["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

/// The codes a format-3 write is handed back with.
enum RecordLogHandBackCode {
    static let all: Set<String> = [
        "DOCUMENT_CONSTRAINT_VIOLATED", "DOCUMENT_EPOCH_FROZEN", "DOCUMENT_OFFLINE_WINDOW_EXPIRED",
        "DOCUMENT_EPOCH_NOT_OPEN", "DOCUMENT_STORE_PURGED", "DOCUMENT_EPOCH_BUDGET",
        "DOCUMENT_ENTRY_TOO_LARGE", "DOCUMENT_ENTRY_INVALID", "WRITE_ACCESS_DENIED",
        "DB3_CONDITION_NOT_MET", "DB3_RECORD_NOT_FOUND", "DB3_TRIGGER_REFUSED", "DB3_MODEL_NOT_DECLARED",
    ]
}

/// The wire version this client declares on `record.open`: 2 since the
/// `increment` entry kind. A room past it refuses the open `DB3_CLIENT_OUTDATED`.
let recordLogWireVersion = 2

// MARK: - JSON

/// JSON text in and out of the store and the wire.
///
/// Keys are written sorted, so the same value always writes the same text.
/// Numbers are `JSONValue`'s doubles, which is what the JS client's are.
enum RecordLogJSON {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The value as JSON text; `null` for a value JSON cannot carry (a non-finite number).
    static func text(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    /// The text parsed, or `nil` when it is not JSON. Every stored entry and
    /// row is read through here, so it throws nothing (`JSONValue(jsonText:)`).
    static func parse(_ text: String) -> JSONValue? {
        JSONValue(jsonText: text)
    }

    /// A row parsed from the store; an empty row when the text is not an object.
    static func row(_ text: String?) -> RecordLogRow {
        text.flatMap(parse)?.objectValue ?? [:]
    }

    /// Bytes of the value's JSON text.
    static func bytes(_ value: JSONValue) -> Int {
        text(value).utf8.count
    }
}

extension JSONValue {
    /// The value as an `Int`, when it is a whole number.
    var wholeNumber: Int? {
        guard case .number(let value) = self, value.isFinite, value == value.rounded(),
              abs(value) <= 9_007_199_254_740_992
        else { return nil }
        return Int(value)
    }
}

/// String-set members in canonical order: by Unicode code point (UTF-8 byte
/// order, which is SQLite's `BINARY` collation), each distinct member once.
func recordLogCanonicalStringSet<S: Sequence>(_ values: S) -> [String] where S.Element == String {
    var seen = Set<[UInt8]>()
    var unique: [(bytes: [UInt8], value: String)] = []
    for value in values {
        let bytes = Array(value.utf8)
        if seen.insert(bytes).inserted { unique.append((bytes, value)) }
    }
    return unique.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }.map(\.value)
}

/// Whether two strings are the same bytes, which is how JS compares them.
func recordLogSameText(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// Whether two values are the same JSON, strings compared by their bytes:
/// `JSONValue`'s `==` compares strings canonically, so a set holding U+00E9
/// equals one holding U+0065 U+0301 by it, and the JS client and the room
/// keep them apart.
func recordLogSameJSON(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)): return recordLogSameText(x, y)
    case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(recordLogSameJSON)
    case (.object(let x), .object(let y)):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { recordLogSameJSON(value, $0) } ?? false }
    default: return a == b
    }
}

/// Whether two rows (or their absence) are the same, as ``recordLogSameJSON(_:_:)`` compares.
func recordLogSameRow(_ a: RecordLogRow?, _ b: RecordLogRow?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let x?, let y?): return recordLogSameJSON(.object(x), .object(y))
    default: return false
    }
}
