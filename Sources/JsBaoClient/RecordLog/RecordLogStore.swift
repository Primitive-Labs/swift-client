import Foundation

// A format-3 document's local store over the storage provider's SQLite
// connection: confirmed rows, the view reads answer from, the unjudged entries
// per writer, the cursor and the epochs, and the projection of the view into
// the model query tables. A port of js-bao's `record-log-client/store.ts`.
//
// Synchronous: every call runs on the provider's serial queue. A save joins
// the connection's group of saves (``RecordLogGroupCommit``); every other
// command is one transaction of its own. A save's pending entry, its view row
// and its query rows commit together or not at all.

/// What a store holds of a document, asked before the document is bound.
struct RecordLogStoredState: Equatable, Sendable {
    /// The cursor: 0 for a document the store never caught up.
    var cursor: Int
    /// How many records the view holds.
    var rows: Int
    /// Every writer with unjudged entries, with its lowest one.
    var writers: [Writer]
    /// A full replacement of the confirmed rows was interrupted.
    var replacing: Bool

    struct Writer: Equatable, Sendable {
        var writer: String
        var clientId: String
        var nextSeq: Int
        var lowestPending: Int
        var pending: Int
    }
}

/// What a binding mirrors, in one read.
struct RecordLogMarks: Equatable, Sendable {
    var cursor: Int
    var open: Int
    var grant: Int
    var entries: Int
    var constraints: [RecordLogConstraint]
    var permission: String?
    var replacing: Bool
    /// The generation of the full replacement in progress, or `nil`.
    var replacement: Int?
    var lastCatchUpAt: Int64?
    /// This client's writer, or `nil` before one is minted.
    var writer: String?
    /// The writer's next sequence number.
    var nextSeq: Int
    /// The `nextSeq` the writer last resumed at after a writer-scoped refusal
    /// (0 when it never did): every number a hand-back removed is below it.
    var resumedAt: Int
    /// The writer's lowest unjudged sequence number.
    var lowestPending: Int?
    /// How many unjudged entries the writer has.
    var pending: Int
    /// The writer's entries the room has not acknowledged, with the records each touches.
    var unacked: [(seq: Int, records: [RecordLogRecordKey])]
    /// The latest receipt of a load's or a segment's chunks begun and not completed, or `nil`.
    var receipt: RecordLogReceipt?
    /// The segment the confirmed rows were last replaced from, or `nil`.
    var segment: RecordLogHeldSegment? = nil

    static func == (a: RecordLogMarks, b: RecordLogMarks) -> Bool {
        a.cursor == b.cursor && a.open == b.open && a.grant == b.grant && a.entries == b.entries
            && a.constraints == b.constraints && a.permission == b.permission && a.replacing == b.replacing
            && a.replacement == b.replacement && a.receipt == b.receipt && a.segment == b.segment
            && a.lastCatchUpAt == b.lastCatchUpAt && a.writer == b.writer && a.nextSeq == b.nextSeq
            && a.resumedAt == b.resumedAt
            && a.lowestPending == b.lowestPending && a.pending == b.pending
            && a.unacked.map(\.seq) == b.unacked.map(\.seq) && a.unacked.map(\.records) == b.unacked.map(\.records)
    }
}

/// One write of a commit: an entry's mutations, `m` first.
struct RecordLogWrite: Sendable {
    var mutations: [RecordLogMutation]
    /// `m` is an upsert on this field.
    var upsertOn: String?
}

/// A record and its view row (`nil` once it shows none).
struct RecordLogRowChange: Equatable, Sendable {
    var model: String
    var id: String
    var row: RecordLogRow?
}

/// What a command that changed view rows answers.
struct RecordLogChangeReply: Sendable {
    var changed: [RecordLogRowChange] = []
    var cursor: Int = 0
    /// A catch-up's page or completion was not applied: the store's cursor is
    /// past the log number it was read at, or another client of the store
    /// began a replacement of its own. The open starts over from the cursor.
    var stale = false
    /// Models whose view rows changed in bulk (a load's or a segment's chunk):
    /// `changed` then names only the records an unjudged entry touches, and a
    /// listener re-reads what it holds of these models.
    var models: [String] = []
    var acknowledged: [RecordLogEntryRef] = []
    var settled: [RecordLogEntryRef] = []
    var handedBack: [RecordLogPendingEntry] = []
    var frames: [RecordLogUpFrame] = []
    /// A compact acknowledgement the store could not derive; the session opens again from the cursor.
    var underivable: RecordLogUnderivableAck?
}

/// The ids a bulk change of one model fell within, first and last included.
struct RecordLogIdRange: Equatable, Sendable {
    var model: String
    var firstId: String
    var lastId: String
}

/// What a chunk of a load or a segment answers.
struct RecordLogChunkReply: Sendable {
    /// Records the chunk put.
    var applied = 0
    /// Records it removed.
    var removed = 0
    /// The records an unjudged entry touches whose view row changed.
    var changed: [RecordLogRowChange] = []
    /// The models whose view rows changed in bulk.
    var models: [String] = []
    /// For a bulk change, the id range each of `models` changed within; a
    /// model with no range here changed anywhere.
    var ranges: [RecordLogIdRange] = []
    var cursor = 0
    /// The receipt attempt is no longer in progress in the store, or another
    /// replacement overtook its generation: nothing changed.
    var stale = false
    /// A held chunk could not be kept: nothing changed, and it is read instead.
    var mismatch = false
}

/// What `commitEntries` answers.
struct RecordLogCommitReply: Sendable {
    /// One entry per write, in order.
    var entries: [RecordLogPendingEntry]
    var changed: [RecordLogRowChange]
    var cursor: Int
}

/// What `purge` answers.
struct RecordLogPurgeReply: Sendable {
    /// Whether the document's local data is gone.
    var purged: Bool
    /// The store held writes the room has not judged, and the purge was not forced.
    var refusedForPending = false
    /// The store held nothing of the document.
    var nothingStored = false
    /// How many unjudged writes it held.
    var pendingOps: Int
    /// The unjudged writes a forced purge dropped, in the order they were written.
    var handedBack: [RecordLogPendingEntry]
}

/// SQL on the one connection, bound per call.
struct RecordLogSql {
    let connection: any Format2SqlConnection

    func exec(_ sql: String, _ bindings: [Format2SqlValue] = []) throws {
        try connection.execute(sql, bindings)
    }

    func rows(_ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try connection.query(sql, bindings)
    }

    func first(_ sql: String, _ bindings: [Format2SqlValue] = []) throws -> Format2SqlRow? {
        try connection.query(sql, bindings).first
    }
}

extension Format2SqlValue {
    /// A written value as `record_log_pending_values` keeps it: a boolean as
    /// 1/0, an object or array as its JSON.
    static func recordLogWritten(_ value: JSONValue) -> Format2SqlValue {
        switch value {
        case .bool(let flag): return .integer(flag ? 1 : 0)
        case .number, .string: return Format2SqlValue(json: value)
        case .null: return .null
        case .object, .array: return .text(RecordLogJSON.text(value))
        }
    }

    /// A value as the JS store binds it into a `json_extract` lookup: a boolean
    /// as 1/0, a number or a string as itself, and anything else as JavaScript's
    /// `String()` of it (which matches no stored value).
    static func recordLogLookup(_ value: JSONValue) -> Format2SqlValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .integer(flag ? 1 : 0)
        case .number, .string: return Format2SqlValue(json: value)
        case .object: return .text("[object Object]")
        case .array(let items):
            return .text(items.map { item -> String in
                switch item {
                case .string(let text): return text
                case .null: return ""
                default: return Format2SqlValue.recordLogLookup(item).stringValue ?? ""
                }
            }.joined(separator: ","))
        }
    }

    /// The same value whatever SQLite stored it as: a whole real as an integer.
    var recordLogNormalized: Format2SqlValue {
        if case .real(let value) = self, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return .integer(Int64(value))
        }
        return self
    }
}

/// An ordered map: entries keep the order they were first put in.
struct RecordLogOrderedMap<Key: Hashable, Value> {
    private(set) var keys: [Key] = []
    private var values: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { values[key] }
        set {
            guard let newValue else {
                if values.removeValue(forKey: key) != nil { keys.removeAll { $0 == key } }
                return
            }
            if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
        }
    }

    func contains(_ key: Key) -> Bool { values[key] != nil }

    var entries: [(key: Key, value: Value)] { keys.map { ($0, values[$0]!) } }
}

/// The client's state for one document, kept in the store's tables.
///
/// Every method runs on the provider's queue inside one of the store's calls,
/// on the connection that call bound (`sql`).
final class SqlRecordLogTables: RecordLogReceiptTables {
    /// How many results held ahead of the cursor make the store say so, once.
    static let heldWarn = 10_000

    private let docId: String
    private let logger: Logger?
    var sql: RecordLogSql!
    /// Results ahead of the cursor; held in memory, refetched by catch-up if lost.
    private var held: [Int: RecordLogResult] = [:]
    /// Whether the held results passed ``heldWarn`` since they last fell below it.
    private var heldWarned = false
    /// Records of entries changed or removed since the last `takeDirty`.
    private var dirty: [RecordLogRecordKey] = []
    /// Inside ``countingEpochs(_:)``, each epoch's unwithdrawn pending entries
    /// once counted, kept as entries are added; `nil` outside it.
    private var epochPending: [Int: Int]?

    init(docId: String, logger: Logger? = nil) {
        self.docId = docId
        self.logger = logger
    }

    private var doc: Format2SqlValue { .text(docId) }

    private func state() throws -> Format2SqlRow? {
        try sql.first("SELECT * FROM record_log_state WHERE doc_id = ?", [doc])
    }

    func ensureState() throws {
        try sql.exec("INSERT OR IGNORE INTO record_log_state (doc_id) VALUES (?)", [doc])
    }

    func cursor() throws -> Int { try state()?["cursor"].intValue ?? 0 }

    func setCursor(_ cursor: Int) throws {
        try ensureState()
        try sql.exec("UPDATE record_log_state SET cursor = ? WHERE doc_id = ?", [.integer(Int64(cursor)), doc])
    }

    func epochs() throws -> RecordLogEpochs {
        let state = try state()
        return RecordLogEpochs(
            open: state?["open_epoch"].intValue ?? RecordLogTransport.firstEpoch,
            grant: state?["grant_epoch"].intValue ?? RecordLogTransport.firstEpoch + 1,
            entries: state?["epoch_entries"].intValue ?? RecordLogTransport.defaultEpochEntries
        )
    }

    func setEpochs(_ epochs: RecordLogEpochs) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET open_epoch = ?, grant_epoch = ?, epoch_entries = ? WHERE doc_id = ?",
            [.integer(Int64(epochs.open)), .integer(Int64(epochs.grant)), .integer(Int64(epochs.entries)), doc]
        )
    }

    func constraints() throws -> [RecordLogConstraint] {
        guard let text = try state()?["constraints"].stringValue else { return [] }
        return RecordLogJSON.parse(text)?.arrayValue?.compactMap { RecordLogConstraint(json: $0) } ?? []
    }

    func setConstraints(_ constraints: [RecordLogConstraint]) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET constraints = ? WHERE doc_id = ?",
            [.text(RecordLogJSON.text(.array(constraints.map(\.json)))), doc]
        )
    }

    func setPermission(_ permission: String?) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET permission = ? WHERE doc_id = ?",
            [permission.map { .text($0) } ?? .null, doc]
        )
    }

    func setLastCatchUpAt(_ at: Int64) throws {
        try ensureState()
        try sql.exec("UPDATE record_log_state SET last_catch_up_at = ? WHERE doc_id = ?", [.integer(at), doc])
    }

    private func generation() throws -> Int {
        let state = try state()
        if let replacing = state?["replacing"], !replacing.isNull { return replacing.intValue ?? 0 }
        return state?["rows_gen"].intValue ?? 0
    }

    func isReplacing() throws -> Bool {
        guard let replacing = try state()?["replacing"] else { return false }
        return !replacing.isNull
    }

    func replacing() throws -> Int? {
        guard let replacing = try state()?["replacing"], !replacing.isNull else { return nil }
        return replacing.intValue
    }

    func receipts() throws -> RecordLogReceiptState? {
        guard let text = try state()?["receipt"].stringValue, !text.isEmpty else { return nil }
        return RecordLogReceiptState(json: RecordLogJSON.parse(text))
    }

    func setReceipts(_ state: RecordLogReceiptState?) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET receipt = ? WHERE doc_id = ?",
            [state.map { .text(RecordLogJSON.text($0.json)) } ?? .null, doc]
        )
    }

    func heldSegment() throws -> RecordLogHeldSegment? {
        guard let text = try state()?["segment"].stringValue, !text.isEmpty else { return nil }
        return RecordLogHeldSegment(json: RecordLogJSON.parse(text))
    }

    func setHeldSegment(_ segment: RecordLogHeldSegment?) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET segment = ? WHERE doc_id = ?",
            [segment.map { .text(RecordLogJSON.text($0.json)) } ?? .null, doc]
        )
    }

    func keepConfirmedRange(model: String, firstId: String, lastId: String, rows: Int) throws -> Bool {
        let state = try state()
        guard let replacing = state?["replacing"], !replacing.isNull, let generation = replacing.intValue else { return false }
        // The confirmed generation's rows only: one an interrupted replacement
        // put carries that replacement's generation. `_id` compares BINARY, the
        // order the room cut the chunk in.
        let predicate = "WHERE doc_id = ? AND _type = ? AND _id >= ? AND _id <= ? AND _gen = ?"
        let bindings: [Format2SqlValue] = [
            doc, .text(model), .text(firstId), .text(lastId), .integer(Int64(state?["rows_gen"].intValue ?? 0)),
        ]
        let count = try sql.first("SELECT COUNT(*) AS n FROM record_log_rows \(predicate)", bindings)?["n"].intValue ?? 0
        guard count == rows else { return false }
        try sql.exec("UPDATE record_log_rows SET _gen = ? \(predicate)", [.integer(Int64(generation))] + bindings)
        return true
    }

    func noteLoadKeys(_ attempt: String, _ keys: [RecordLogRecordKey]) throws {
        for key in keys {
            try sql.exec(
                "INSERT OR IGNORE INTO record_log_load_keys (doc_id, attempt, _type, _id) VALUES (?, ?, ?, ?)",
                [doc, .text(attempt), .text(key.model), .text(key.id)]
            )
        }
    }

    func removeUnnamed(_ attempt: String, models: [String]) throws -> [RecordLogRecordKey] {
        var removed: [RecordLogRecordKey] = []
        let unnamed = """
            FROM record_log_rows r WHERE r.doc_id = ? AND r._type = ? AND NOT EXISTS (
              SELECT 1 FROM record_log_load_keys k
               WHERE k.doc_id = r.doc_id AND k.attempt = ? AND k._type = r._type AND k._id = r._id)
            """
        for model in models {
            let bindings: [Format2SqlValue] = [doc, .text(model), .text(attempt)]
            for row in try sql.rows("SELECT r._id AS _id \(unnamed)", bindings) {
                if let id = row["_id"].stringValue { removed.append(RecordLogRecordKey(model: model, id: id)) }
            }
            try sql.exec(
                "DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN (SELECT r._id \(unnamed))",
                [doc, .text(model)] + bindings
            )
        }
        return removed
    }

    func forgetLoad(_ attempt: String) throws {
        try sql.exec("DELETE FROM record_log_load_keys WHERE doc_id = ? AND attempt = ?", [doc, .text(attempt)])
    }

    func keepLoads(_ attempts: [String]) throws {
        let marks = attempts.map { _ in "?" }.joined(separator: ", ")
        try sql.exec(
            "DELETE FROM record_log_load_keys WHERE doc_id = ?\(attempts.isEmpty ? "" : " AND attempt NOT IN (\(marks))")",
            [doc] + attempts.map { .text($0) }
        )
    }

    func confirmed() throws -> RecordLogRowTable { ConfirmedTable(tables: self) }

    /// The confirmed rows, in the order they arrived: a full replacement puts
    /// its rows in the order it carries them.
    ///
    /// One table serves one rule call, inside which no replacement begins or
    /// ends: whether one is under way, and its generation, are read once.
    private final class ConfirmedTable: RecordLogRowTable {
        let tables: SqlRecordLogTables
        private var writing: (replacing: Bool, generation: Int)?
        init(tables: SqlRecordLogTables) { self.tables = tables }

        private func write() throws -> (replacing: Bool, generation: Int) {
            if let writing { return writing }
            let read = (try tables.isReplacing(), try tables.generation())
            writing = read
            return read
        }

        func row(_ key: RecordLogRecordKey) throws -> RecordLogRow? {
            try tables.confirmedRow(key)
        }

        func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) throws {
            let sql = tables.sql!
            let bindings: [Format2SqlValue] = [tables.doc, .text(key.model), .text(key.id)]
            let (replacing, generation) = try write()
            if replacing {
                try sql.exec("DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?", bindings)
            }
            try sql.exec(
                """
                INSERT INTO record_log_rows (doc_id, _type, _id, _data, _gen) VALUES (?, ?, ?, ?, ?)
                  ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data, _gen = excluded._gen
                """,
                bindings + [.text(RecordLogJSON.text(.object(row))), .integer(Int64(generation))]
            )
        }

        func delete(_ key: RecordLogRecordKey) throws {
            try tables.sql.exec(
                "DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?",
                [tables.doc, .text(key.model), .text(key.id)]
            )
        }

        func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) throws -> String? {
            try RecordLogStore.findHolders(
                tables.sql, table: "record_log_rows", docId: tables.docId, model: model,
                fields: fields, values: values, excluding: excluding, limitToFirst: true
            ).first
        }
    }

    func confirmedRow(_ key: RecordLogRecordKey) throws -> RecordLogRow? {
        try sql.first(
            "SELECT _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?",
            [doc, .text(key.model), .text(key.id)]
        ).map { RecordLogJSON.row($0["_data"].stringValue) }
    }

    func beginReplace() throws {
        try ensureState()
        // Every attempt takes a generation of its own: a row an interrupted
        // attempt put is gone unless this one puts it again.
        try sql.exec(
            "UPDATE record_log_state SET replacing = MAX(rows_gen, COALESCE(replacing, rows_gen)) + 1 WHERE doc_id = ?",
            [doc]
        )
    }

    func completeReplace() throws -> [RecordLogRecordKey] {
        guard let replacing = try state()?["replacing"], !replacing.isNull, let gen = replacing.intValue else {
            return []
        }
        let removed = try sql.rows(
            "SELECT _type, _id FROM record_log_rows WHERE doc_id = ? AND _gen <> ?", [doc, .integer(Int64(gen))]
        ).compactMap { row -> RecordLogRecordKey? in
            guard let model = row["_type"].stringValue, let id = row["_id"].stringValue else { return nil }
            return RecordLogRecordKey(model: model, id: id)
        }
        try sql.exec("DELETE FROM record_log_rows WHERE doc_id = ? AND _gen <> ?", [doc, .integer(Int64(gen))])
        try sql.exec(
            "UPDATE record_log_state SET rows_gen = ?, replacing = NULL WHERE doc_id = ?", [.integer(Int64(gen)), doc]
        )
        return removed
    }

    func buffered(_ l: Int) -> RecordLogResult? { held[l] }

    func buffer(_ item: RecordLogResult) {
        held[item.l] = item
        if held.count > Self.heldWarn && !heldWarned {
            heldWarned = true
            logger?.warn(
                "[record-log] \(docId): \(held.count) results held ahead of the cursor \((try? cursor()) ?? 0) "
                    + "(a load applying, or a result lost); they apply once the store catches up past the gap"
            )
        }
    }

    func dropBufferedThrough(_ l: Int) {
        held = held.filter { $0.key > l }
        if held.count <= Self.heldWarn { heldWarned = false }
    }

    func forgetBuffered() {
        held = [:]
        heldWarned = false
    }

    /// The records of every entry changed or removed since the last call.
    func takeDirty() -> [RecordLogRecordKey] {
        defer { dirty = [] }
        return dirty
    }

    private func markDirty(_ writer: String, _ seq: Int) throws {
        for row in try sql.rows(
            "SELECT _type, _id FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ?",
            [doc, .text(writer), .integer(Int64(seq))]
        ) {
            if let model = row["_type"].stringValue, let id = row["_id"].stringValue {
                dirty.append(RecordLogRecordKey(model: model, id: id))
            }
        }
    }

    func isWriter(_ writer: String) throws -> Bool {
        try sql.first("SELECT 1 AS present FROM record_log_writers WHERE doc_id = ? AND writer = ?", [doc, .text(writer)]) != nil
    }

    func writerState(_ writer: String) throws -> RecordLogWriterState {
        let row = try sql.first(
            "SELECT next_seq, resumed_at FROM record_log_writers WHERE doc_id = ? AND writer = ?", [doc, .text(writer)]
        )
        return RecordLogWriterState(nextSeq: row?["next_seq"].intValue ?? 1, resumedAt: row?["resumed_at"].intValue ?? 0)
    }

    func setWriterState(_ writer: String, _ state: RecordLogWriterState) throws {
        try sql.exec(
            "UPDATE record_log_writers SET next_seq = ?, resumed_at = ? WHERE doc_id = ? AND writer = ?",
            [.integer(Int64(state.nextSeq)), .integer(Int64(state.resumedAt)), doc, .text(writer)]
        )
    }

    func pending(_ writer: String) throws -> [RecordLogPendingEntry] {
        try sql.rows(
            "SELECT entry, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? ORDER BY seq",
            [doc, .text(writer)]
        ).compactMap(Self.pendingEntry(row:))
    }

    func pendingEntry(_ writer: String, _ seq: Int) throws -> RecordLogPendingEntry? {
        try sql.first(
            "SELECT entry, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?",
            [doc, .text(writer), .integer(Int64(seq))]
        ).flatMap(Self.pendingEntry(row:))
    }

    func pendingThrough(_ writer: String, _ seq: Int) throws -> [RecordLogPendingEntry] {
        try sql.rows(
            "SELECT entry, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq <= ? ORDER BY seq",
            [doc, .text(writer), .integer(Int64(seq))]
        ).compactMap(Self.pendingEntry(row:))
    }

    /// A `record_log_pending` row's entry, its acknowledgement with it.
    private static func pendingEntry(row: Format2SqlRow) -> RecordLogPendingEntry? {
        guard var entry = RecordLogPendingEntry(stored: row["entry"].stringValue.flatMap(RecordLogJSON.parse)) else {
            return nil
        }
        entry.acked = row["acked"].intValue
        return entry
    }

    func putPending(_ writer: String, _ entry: RecordLogPendingEntry) throws {
        let w: Format2SqlValue = .text(writer)
        let seq: Format2SqlValue = .integer(Int64(entry.seq))
        let stored = RecordLogJSON.text(entry.storedJSON)
        let acked: Format2SqlValue = entry.acked.map { .integer(Int64($0)) } ?? .null
        let exists = try sql.first(
            "SELECT 1 AS present FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?", [doc, w, seq]
        ) != nil
        if exists {
            if epochPending != nil { epochPending = [:] }
            try markDirty(writer, entry.seq)
            try sql.exec(
                "UPDATE record_log_pending SET entry = ?, void = ?, acked = ?, e = ? WHERE doc_id = ? AND writer = ? AND seq = ?",
                [.text(stored), .integer(entry.isVoid ? 1 : 0), acked, .integer(Int64(entry.e)), doc, w, seq]
            )
            try sql.exec(
                "DELETE FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ? AND resolved = 0",
                [doc, w, seq]
            )
        } else {
            let top = try sql.first("SELECT MAX(ord) AS ord FROM record_log_pending WHERE doc_id = ?", [doc])
            try sql.exec(
                "INSERT INTO record_log_pending (doc_id, writer, seq, ord, e, entry, ts, void, acked) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    doc, w, seq, .integer(Int64((top?["ord"].intValue ?? 0) + 1)), .integer(Int64(entry.e)),
                    .text(stored), entry.ts.map { .integer($0) } ?? .null, .integer(entry.isVoid ? 1 : 0), acked,
                ]
            )
            if !entry.isVoid, let n = epochPending?[entry.e] { epochPending?[entry.e] = n + 1 }
        }
        try putValues(writer, entry)
        for key in entry.keys {
            try sql.exec(
                "INSERT OR IGNORE INTO record_log_pending_keys (doc_id, writer, seq, _type, _id, resolved) VALUES (?, ?, ?, ?, ?, 0)",
                [doc, w, seq, .text(key.model), .text(key.id)]
            )
        }
    }

    /// Keep the values an entry's mutations write, each by model and field, its
    /// upsert's own marked; a string-set change is kept without a value, since
    /// the members it leaves depend on the row.
    private func putValues(_ writer: String, _ entry: RecordLogPendingEntry) throws {
        let w: Format2SqlValue = .text(writer)
        let seq: Format2SqlValue = .integer(Int64(entry.seq))
        try sql.exec("DELETE FROM record_log_pending_values WHERE doc_id = ? AND writer = ? AND seq = ?", [doc, w, seq])
        func put(_ model: String, _ field: String, _ value: Format2SqlValue, _ upsert: Bool) throws {
            try sql.exec(
                """
                INSERT INTO record_log_pending_values (doc_id, writer, seq, _type, field, value, upsert) VALUES (?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT (doc_id, writer, seq, _type, field, value) DO UPDATE SET upsert = MAX(upsert, excluded.upsert)
                """,
                [doc, w, seq, .text(model), .text(field), value, .integer(upsert ? 1 : 0)]
            )
        }
        for (index, mutation) in entry.mutations.enumerated() {
            for (field, value) in (mutation.fields ?? [:]).sorted(by: { $0.key < $1.key }) where value != .null {
                try put(mutation.model, field, .recordLogWritten(value), index == 0 && field == entry.upsertOn)
            }
            for field in (mutation.stringSetDeltas ?? [:]).keys.sorted() {
                try put(mutation.model, field, .null, false)
            }
        }
    }

    func deletePending(_ writer: String, _ seq: Int) throws {
        if epochPending != nil { epochPending = [:] }
        try markDirty(writer, seq)
        let bindings: [Format2SqlValue] = [doc, .text(writer), .integer(Int64(seq))]
        try sql.exec("DELETE FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?", bindings)
        try sql.exec("DELETE FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ?", bindings)
        try sql.exec("DELETE FROM record_log_pending_values WHERE doc_id = ? AND writer = ? AND seq = ?", bindings)
    }

    func acknowledgedThrough(_ l: Int) throws -> [RecordLogEntryRef] {
        try sql.rows(
            "SELECT writer, seq FROM record_log_pending WHERE doc_id = ? AND acked IS NOT NULL AND acked <= ? ORDER BY writer, seq",
            [doc, .integer(Int64(l))]
        ).compactMap { row in
            guard let writer = row["writer"].stringValue, let seq = row["seq"].intValue else { return nil }
            return RecordLogEntryRef(writer: writer, seq: seq)
        }
    }

    func handled(_ writer: String, _ key: RecordLogRecordKey) throws -> [Int: Int] {
        var out: [Int: Int] = [:]
        for row in try sql.rows(
            "SELECT from_seq, until_seq FROM record_log_handled WHERE doc_id = ? AND writer = ? AND _type = ? AND _id = ?",
            [doc, .text(writer), .text(key.model), .text(key.id)]
        ) {
            if let from = row["from_seq"].intValue, let until = row["until_seq"].intValue { out[from] = until }
        }
        return out
    }

    func setHandled(_ writer: String, _ key: RecordLogRecordKey, from: Int, until: Int) throws {
        try sql.exec(
            "INSERT OR REPLACE INTO record_log_handled (doc_id, writer, _type, _id, from_seq, until_seq) VALUES (?, ?, ?, ?, ?, ?)",
            [doc, .text(writer), .text(key.model), .text(key.id), .integer(Int64(from)), .integer(Int64(until))]
        )
    }

    func epochCount(_ e: Int) throws -> Int {
        try sql.first(
            "SELECT count FROM record_log_epoch_counts WHERE doc_id = ? AND epoch = ?", [doc, .integer(Int64(e))]
        )?["count"].intValue ?? 0
    }

    func countEpoch(_ e: Int) throws {
        try sql.exec(
            """
            INSERT INTO record_log_epoch_counts (doc_id, epoch, count) VALUES (?, ?, 1)
              ON CONFLICT (doc_id, epoch) DO UPDATE SET count = count + 1
            """,
            [doc, .integer(Int64(e))]
        )
    }

    func pendingInEpoch(_ e: Int) throws -> Int {
        if let n = epochPending?[e] { return n }
        let n = try sql.first(
            "SELECT COUNT(*) AS n FROM record_log_pending WHERE doc_id = ? AND void = 0 AND e = ?", [doc, .integer(Int64(e))]
        )?["n"].intValue ?? 0
        if epochPending != nil { epochPending?[e] = n }
        return n
    }

    /// Run `body` counting each epoch's pending entries once: a commit's
    /// writes each check the budget, and inside one transaction only they
    /// change the count. Any other change to the pending log counts again.
    func countingEpochs<T>(_ body: () throws -> T) rethrows -> T {
        epochPending = [:]
        defer { epochPending = nil }
        return try body()
    }
}

/// One format-3 document's store, for one client of the database.
///
/// `@unchecked Sendable`: its one mutable member, `tables` (the bound
/// connection and the results held ahead of the cursor), is touched only
/// inside a call on the provider's serial queue (``RecordLogGroupCommitHost/withRecordLogConnection(_:)``
/// or ``Format2SqlHost/withConnection(_:)``), which is the lock.
final class RecordLogStore: @unchecked Sendable {
    let host: any Format2SqlHost
    let documentId: String
    let clientId: String
    private let logger: Logger?
    private let group: RecordLogGroupCommit
    private let tables: SqlRecordLogTables

    /// Where the view's order puts the records only a guess holds, and after them those a guess creates.
    private static let guessHeld = 1 << 50
    private static let guessCreated = 1 << 51

    init(host: any Format2SqlHost, documentId: String, clientId: String, logger: Logger? = nil) {
        self.host = host
        self.logger = logger
        self.documentId = documentId
        self.clientId = clientId
        self.group = (host as? any RecordLogGroupCommitHost)?.recordLogGroupCommit ?? RecordLogGroupCommit()
        self.tables = SqlRecordLogTables(docId: documentId, logger: logger)
    }

    private var doc: Format2SqlValue { .text(documentId) }

    // MARK: - Running on the connection

    /// Run `body` on the connection, joining an open group without closing it.
    private func onConnection<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        let run = { (connection: any Format2SqlConnection) throws -> T in
            let sql = RecordLogSql(connection: connection)
            let outer = self.tables.sql
            self.tables.sql = sql
            defer { self.tables.sql = outer }
            return try body(sql)
        }
        if let groupHost = host as? any RecordLogGroupCommitHost {
            return try groupHost.withRecordLogConnection(run)
        }
        return try host.withConnection(run)
    }

    /// A read: no transaction; it sees what the open group has written.
    private func reading<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.read { try body(sql) } }
    }

    /// A command that is not a save: the open group commits first.
    private func command<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.command(sql.connection) { try body(sql) } }
    }

    /// A save: it joins the connection's group of saves.
    func save<T>(listener: RecordLogGroupCommit.Listener? = nil, _ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.save(sql.connection, listener: listener) { try body(sql) } }
    }

    /// Commit the open group of saves now.
    func flush() throws {
        try onConnection { sql in group.flush(on: sql.connection) }
    }

    // MARK: - Tables and identity

    /// Create the record-log tables. Idempotent; writes no row.
    func initialize() throws {
        try command { sql in
            for statement in RecordLogSchema.ddl { try sql.connection.executeScript(statement) }
            for added in RecordLogSchema.addedColumns {
                let has = try sql.first(
                    "SELECT 1 AS present FROM pragma_table_info(?) WHERE name = ?", [.text(added.table), .text(added.column)]
                ) != nil
                if !has { try sql.connection.executeScript(added.add) }
            }
        }
    }

    private func tablesExist(_ sql: RecordLogSql) throws -> Bool {
        try sql.first(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text("record_log_state")]
        ) != nil
    }

    /// What the store holds of this document, without creating anything.
    func storedState() throws -> RecordLogStoredState {
        try reading { sql in
            guard try tablesExist(sql) else { return RecordLogStoredState(cursor: 0, rows: 0, writers: [], replacing: false) }
            let count = try sql.first("SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = ?", [doc])?["n"].intValue ?? 0
            let writers = try sql.rows(
                """
                SELECT w.writer AS writer, w.client_id AS client_id, w.next_seq AS next_seq,
                       MIN(p.seq) AS lowest, COUNT(p.seq) AS pending
                  FROM record_log_writers w JOIN record_log_pending p ON p.doc_id = w.doc_id AND p.writer = w.writer
                 WHERE w.doc_id = ?
                 GROUP BY w.writer, w.client_id, w.next_seq
                 ORDER BY w.writer
                """,
                [doc]
            ).compactMap { row -> RecordLogStoredState.Writer? in
                guard let writer = row["writer"].stringValue, let clientId = row["client_id"].stringValue else { return nil }
                return RecordLogStoredState.Writer(
                    writer: writer, clientId: clientId, nextSeq: row["next_seq"].intValue ?? 1,
                    lowestPending: row["lowest"].intValue ?? 1, pending: row["pending"].intValue ?? 0
                )
            }
            return RecordLogStoredState(
                cursor: try tables.cursor(), rows: count, writers: writers, replacing: try tables.isReplacing()
            )
        }
    }

    private func writerOf(_ sql: RecordLogSql) throws -> String? {
        try sql.first(
            "SELECT writer FROM record_log_writers WHERE doc_id = ? AND client_id = ?", [doc, .text(clientId)]
        )?["writer"].stringValue
    }

    /// This client's writer, or `nil` before one is minted.
    func writer() throws -> String? {
        try reading { sql in try tablesExist(sql) ? try writerOf(sql) : nil }
    }

    /// This client's writer, minted when it has none: a 26-character ULID.
    func mintWriter() throws -> String {
        try command { sql in
            try tables.ensureState()
            if let known = try writerOf(sql) { return known }
            let writer = ULID.generate()
            try sql.exec(
                "INSERT INTO record_log_writers (doc_id, client_id, writer, next_seq, resumed_at) VALUES (?, ?, ?, 1, 0)",
                [doc, .text(clientId), .text(writer)]
            )
            return writer
        }
    }

    /// Replace a writer the room no longer knows: a new writer id takes the old
    /// one's client, its unacknowledged entries are renumbered from 1 in `seq`
    /// order (their epochs, cursors and order kept), and its void markers and
    /// the refusals it acted on are dropped, since the room never saw the new id.
    func remintWriter(_ old: String) throws -> (writer: String, renumbered: [(from: Int, to: Int)]) {
        try command { sql in
            let fresh = ULID.generate()
            var renumbered: [(from: Int, to: Int)] = []
            let pending = try tables.pending(old)
            for entry in pending where entry.isVoid { try tables.deletePending(old, entry.seq) }
            _ = tables.takeDirty()
            var next = 1
            for entry in pending {
                // An acknowledged entry is the room's already; it settles when the
                // cursor passes its result, under the id it was acknowledged for.
                if entry.isVoid || entry.acked != nil { continue }
                var moved = entry
                moved.seq = next
                moved.acked = nil
                moved.alias = nil
                try sql.exec(
                    "UPDATE record_log_pending SET writer = ?, seq = ?, entry = ?, acked = NULL WHERE doc_id = ? AND writer = ? AND seq = ?",
                    [.text(fresh), .integer(Int64(next)), .text(RecordLogJSON.text(moved.storedJSON)), doc, .text(old), .integer(Int64(entry.seq))]
                )
                for table in ["record_log_pending_keys", "record_log_pending_values"] {
                    try sql.exec(
                        "UPDATE \(table) SET writer = ?, seq = ? WHERE doc_id = ? AND writer = ? AND seq = ?",
                        [.text(fresh), .integer(Int64(next)), doc, .text(old), .integer(Int64(entry.seq))]
                    )
                }
                renumbered.append((entry.seq, next))
                next += 1
            }
            try sql.exec("DELETE FROM record_log_handled WHERE doc_id = ? AND writer = ?", [doc, .text(old)])
            try sql.exec(
                "UPDATE record_log_writers SET writer = ?, next_seq = ?, resumed_at = 0 WHERE doc_id = ? AND writer = ?",
                [.text(fresh), .integer(Int64(next)), doc, .text(old)]
            )
            return (fresh, renumbered)
        }
    }

    /// Remove everything the store keeps of this document: its rows, view,
    /// unjudged entries, writers, epoch counts and projection marks, and its
    /// rows in the query tables `project` names. Refused while it holds
    /// unjudged writes, unless `force`; a forced purge answers what it dropped.
    func purge(force: Bool, project: [RecordLogProjectionSpec] = []) throws -> RecordLogPurgeReply {
        try command { sql in
            guard try tablesExist(sql) else {
                return RecordLogPurgeReply(purged: true, nothingStored: true, pendingOps: 0, handedBack: [])
            }
            let live = try sql.rows(
                "SELECT entry FROM record_log_pending WHERE doc_id = ? AND void = 0 AND acked IS NULL ORDER BY ord", [doc]
            ).compactMap { RecordLogPendingEntry(stored: $0["entry"].stringValue.flatMap(RecordLogJSON.parse)) }
            if !force && !live.isEmpty {
                return RecordLogPurgeReply(purged: false, refusedForPending: true, pendingOps: live.count, handedBack: [])
            }
            let held = try sql.first("SELECT COUNT(*) AS n FROM record_log_state WHERE doc_id = ?", [doc])?["n"].intValue ?? 0
            for spec in project {
                try RecordLogQueryProjection.removeDocument(sql, spec: spec, documentId: documentId)
            }
            for table in RecordLogSchema.clientTables {
                try sql.exec("DELETE FROM \(table) WHERE doc_id = ?", [doc])
            }
            tables.forgetBuffered()
            return RecordLogPurgeReply(
                purged: true, nothingStored: held == 0 && live.isEmpty, pendingOps: live.count, handedBack: live
            )
        }
    }

    /// Everything a binding mirrors, in one read.
    func marks() throws -> RecordLogMarks {
        try reading { sql in try marksOn(sql) }
    }

    private func marksOn(_ sql: RecordLogSql) throws -> RecordLogMarks {
        let epochs = try tables.epochs()
        let state = try sql.first("SELECT * FROM record_log_state WHERE doc_id = ?", [doc])
        let writer = try writerOf(sql)
        let writerState = try writer.map { try tables.writerState($0) }
        let pending = try writer.flatMap { writer in
            try sql.first(
                "SELECT MIN(seq) AS lowest, COUNT(*) AS n FROM record_log_pending WHERE doc_id = ? AND writer = ?",
                [doc, .text(writer)]
            )
        }
        return RecordLogMarks(
            cursor: try tables.cursor(), open: epochs.open, grant: epochs.grant, entries: epochs.entries,
            constraints: try tables.constraints(),
            permission: state?["permission"].stringValue,
            replacing: try tables.isReplacing(),
            replacement: try tables.replacing(),
            lastCatchUpAt: state?["last_catch_up_at"].intValue.map { Int64($0) },
            writer: writer,
            nextSeq: writerState?.nextSeq ?? 1,
            resumedAt: writerState?.resumedAt ?? 0,
            lowestPending: pending?["lowest"].intValue,
            pending: pending?["n"].intValue ?? 0,
            unacked: try writer.map { try unackedOf(sql, $0) } ?? [],
            receipt: try tables.receipts()?.latest,
            segment: try tables.heldSegment()
        )
    }

    /// A writer's unacknowledged, unwithdrawn entries and the records each touches.
    private func unackedOf(_ sql: RecordLogSql, _ writer: String) throws -> [(seq: Int, records: [RecordLogRecordKey])] {
        var bySeq = RecordLogOrderedMap<Int, [RecordLogRecordKey]>()
        for row in try sql.rows(
            """
            SELECT p.seq AS seq, k._type AS _type, k._id AS _id
              FROM record_log_pending p JOIN record_log_pending_keys k
                ON k.doc_id = p.doc_id AND k.writer = p.writer AND k.seq = p.seq
             WHERE p.doc_id = ? AND p.writer = ? AND p.void = 0 AND p.acked IS NULL AND k.resolved = 0
             ORDER BY p.seq
            """,
            [doc, .text(writer)]
        ) {
            guard let seq = row["seq"].intValue, let model = row["_type"].stringValue, let id = row["_id"].stringValue else {
                continue
            }
            bySeq[seq] = (bySeq[seq] ?? []) + [RecordLogRecordKey(model: model, id: id)]
        }
        return bySeq.entries.map { ($0.key, $0.value) }
    }

    /// A writer's unjudged entries, in `seq` order: what a resubmission sends.
    func pendingOf(_ writer: String) throws -> [RecordLogPendingEntry] {
        try reading { _ in try tables.pending(writer) }
    }

    /// The confirmed rows of the document, in the order they arrived.
    func confirmedRows() throws -> [RecordLogRow] {
        try reading { sql in
            try sql.rows("SELECT _data FROM record_log_rows WHERE doc_id = ? ORDER BY rowid", [doc])
                .map { RecordLogJSON.row($0["_data"].stringValue) }
        }
    }

    // MARK: - Reads (the view)

    /// A record's view row, or `nil`.
    func read(model: String, id: String) throws -> RecordLogRow? {
        try reading { sql in try viewRow(sql, RecordLogRecordKey(model: model, id: id)) }
    }

    private func viewRow(_ sql: RecordLogSql, _ key: RecordLogRecordKey) throws -> RecordLogRow? {
        try sql.first(
            "SELECT _data FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id = ?",
            [doc, .text(key.model), .text(key.id)]
        ).map { RecordLogJSON.row($0["_data"].stringValue) }
    }

    /// Several records' view rows, in the order asked for; a missing one is `nil`.
    func readMany(model: String, ids: [String]) throws -> [RecordLogRow?] {
        guard !ids.isEmpty else { return [] }
        return try reading { sql in
            var found: [String: RecordLogRow] = [:]
            let unique = Array(Set(ids))
            for start in stride(from: 0, to: unique.count, by: 500) {
                let slice = Array(unique[start..<min(start + 500, unique.count)])
                let placeholders = slice.map { _ in "?" }.joined(separator: ", ")
                for row in try sql.rows(
                    "SELECT _id, _data FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id IN (\(placeholders))",
                    [doc, .text(model)] + slice.map { .text($0) }
                ) {
                    if let id = row["_id"].stringValue { found[id] = RecordLogJSON.row(row["_data"].stringValue) }
                }
            }
            return ids.map { found[$0] }
        }
    }

    /// One page of a model's view rows in id order, after `after`.
    func readRowsAfter(model: String, after: String?, limit: Int) throws -> [RecordLogRow] {
        try reading { sql in
            let rows: [Format2SqlRow]
            if let after {
                rows = try sql.rows(
                    "SELECT _data FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id > ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .text(after), .integer(Int64(limit))]
                )
            } else {
                rows = try sql.rows(
                    "SELECT _data FROM record_log_view WHERE doc_id = ? AND _type = ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .integer(Int64(limit))]
                )
            }
            return rows.map { RecordLogJSON.row($0["_data"].stringValue) }
        }
    }

    /// One page of a model's record ids in id order, after `after`.
    func recordIdsAfter(model: String, after: String?, limit: Int) throws -> [String] {
        try reading { sql in
            let rows: [Format2SqlRow]
            if let after {
                rows = try sql.rows(
                    "SELECT _id FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id > ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .text(after), .integer(Int64(limit))]
                )
            } else {
                rows = try sql.rows(
                    "SELECT _id FROM record_log_view WHERE doc_id = ? AND _type = ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .integer(Int64(limit))]
                )
            }
            return rows.compactMap { $0["_id"].stringValue }
        }
    }

    /// The id of the first live record of `model` in the view whose `fields` hold `values`.
    func findIdByFields(model: String, fields: [String], values: [JSONValue]) throws -> String? {
        try reading { sql in
            try Self.findHolders(
                sql, table: "record_log_view", docId: documentId, model: model, fields: fields,
                values: values, excluding: [], limitToFirst: true
            ).first
        }
    }

    /// The live records of `model` in `table` (by id) whose `fields` hold
    /// `values`, not one of `excluding`.
    static func findHolders(
        _ sql: RecordLogSql, table: String, docId: String, model: String, fields: [String],
        values: [JSONValue], excluding: [String], limitToFirst: Bool
    ) throws -> [String] {
        guard !fields.isEmpty, !values.contains(.null) else { return [] }
        let literal = RecordLogSchema.isValidIdentifier(model) && fields.allSatisfy(RecordLogSchema.isValidIdentifier)
        var bindings: [Format2SqlValue] = [.text(docId)]
        var predicates: [String]
        if literal {
            predicates = ["_type = \(RecordLogSchema.quoteLiteral(model))"]
            for (field, value) in zip(fields, values) {
                predicates.append("json_extract(_data, '$.\(field)') IS ?")
                bindings.append(.recordLogLookup(value))
            }
        } else {
            predicates = ["_type = ?"]
            bindings.append(.text(model))
            for (field, value) in zip(fields, values) {
                predicates.append("json_extract(_data, '$.' || ?) IS ?")
                bindings.append(.text(field))
                bindings.append(.recordLogLookup(value))
            }
        }
        var query = "SELECT _id FROM \(table) WHERE doc_id = ? AND \(predicates.joined(separator: " AND ")) ORDER BY _id"
        if limitToFirst {
            query += " LIMIT ?"
            bindings.append(.integer(Int64(Set(excluding).count + 1)))
        }
        return try sql.rows(query, bindings).compactMap { $0["_id"].stringValue }.filter { !excluding.contains($0) }
    }

    /// Build the view's lookup indexes for one model: one per scalar `indexed`
    /// or `unique` field and one per compound constraint, each partial on the
    /// model; and on the confirmed rows one per such field and single-field
    /// constraint, where an upsert's guess looks for the records holding its
    /// value. A string-set field, or a name that is not an identifier, is
    /// skipped. Never throws.
    @discardableResult
    func ensureFieldIndexes(
        model: String, fields: [String], constraints: [(name: String, fields: [String])], stringSetFields: [String] = []
    ) -> Int {
        guard RecordLogSchema.isValidIdentifier(model) else { return 0 }
        let sets = Set(stringSetFields)
        let usable = { (field: String) in !sets.contains(field) && RecordLogSchema.isValidIdentifier(field) }
        var wanted = RecordLogOrderedMap<String, (table: String, columns: String)>()
        let byField = { (field: String) in "doc_id, json_extract(_data, '$.\(field)'), _id" }
        for field in fields where usable(field) {
            wanted[RecordLogSchema.fieldIndexName(kind: .field, model: model, name: field)] = ("record_log_view", byField(field))
            wanted[RecordLogSchema.fieldIndexName(kind: .field, model: model, name: field, table: .rows)] = ("record_log_rows", byField(field))
        }
        for constraint in constraints {
            guard !constraint.fields.isEmpty, RecordLogSchema.isValidIdentifier(constraint.name),
                  constraint.fields.allSatisfy(usable)
            else { continue }
            wanted[RecordLogSchema.fieldIndexName(kind: .constraint, model: model, name: constraint.name)] = (
                "record_log_view",
                (["doc_id"] + constraint.fields.map { "json_extract(_data, '$.\($0)')" } + ["_id"]).joined(separator: ", ")
            )
            if constraint.fields.count == 1 {
                wanted[RecordLogSchema.fieldIndexName(kind: .field, model: model, name: constraint.fields[0], table: .rows)] = (
                    "record_log_rows", byField(constraint.fields[0])
                )
            }
        }
        var created = 0
        for (name, spec) in wanted.entries {
            do {
                try command { sql in
                    let existed = try sql.first(
                        "SELECT 1 AS present FROM sqlite_master WHERE type = 'index' AND name = ?", [.text(name)]
                    ) != nil
                    if existed { return }
                    try sql.connection.executeScript(
                        "CREATE INDEX IF NOT EXISTS \(name) ON \(spec.table)(\(spec.columns)) WHERE _type = '\(model)'"
                    )
                    created += 1
                }
            } catch {
                logger?.warn("[record-log] Could not create lookup index", name, "; lookups on it scan:", error.localizedDescription)
            }
        }
        return created
    }

    // MARK: - The view

    /// Rewrite the view rows of `keys` and of every record an unjudged entry
    /// touching them also touches: the confirmed row, then every such
    /// unwithdrawn entry's guess in the order they were written. Answers the
    /// records whose view row changed.
    ///
    /// An upsert's guess lands on whichever record holds its value first in
    /// the view's order, so it depends on every record that holds its value or
    /// is written it. A refresh takes in each unjudged upsert whose value a
    /// refreshed record's confirmed or view row holds or a refreshed entry
    /// writes, and with it every record holding that value and every entry
    /// writing it; a guess that resolves outside the records refreshed starts
    /// the refresh again with that record in it.
    private func refreshView(_ sql: RecordLogSql, _ keys: [RecordLogRecordKey]) throws -> [RecordLogRecordKey] {
        guard !keys.isEmpty else { return [] }
        var seeds = keys
        while true {
            var closure = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
            var entries = RecordLogOrderedMap<RecordLogEntryRef, Bool>()
            var probed = Set<ProbeKey>()
            var queue: [RecordLogEntryRef] = []

            func queueRows(_ rows: [Format2SqlRow]) {
                for row in rows {
                    if let writer = row["writer"].stringValue, let seq = row["seq"].intValue {
                        queue.append(RecordLogEntryRef(writer: writer, seq: seq))
                    }
                }
            }
            // The unjudged upserts of `model` on `field` whose value is `value`
            // (as kept); every one on `field` when the value is not known.
            func probe(_ model: String, _ field: String, _ value: Format2SqlValue) throws {
                guard probed.insert(ProbeKey(kind: "upsert", model: model, field: field, value: value)).inserted else { return }
                if value.isNull {
                    queueRows(try sql.rows(
                        "SELECT writer, seq FROM record_log_pending_values WHERE doc_id = ? AND _type = ? AND field = ? AND upsert = 1",
                        [doc, .text(model), .text(field)]
                    ))
                } else {
                    queueRows(try sql.rows(
                        "SELECT writer, seq FROM record_log_pending_values WHERE doc_id = ? AND _type = ? AND field = ? AND upsert = 1 AND value = ?",
                        [doc, .text(model), .text(field), value]
                    ))
                }
            }
            // Every record that may hold `value` in `field` when an upsert on it
            // is guessed: one whose confirmed or view row holds it, and one an
            // unjudged entry writes it (or a string-set change) to.
            func holders(_ model: String, _ field: String, _ value: Format2SqlValue) throws {
                guard probed.insert(ProbeKey(kind: "held", model: model, field: field, value: value)).inserted else { return }
                let json = Self.jsonOf(value)
                for table in ["record_log_rows", "record_log_view"] {
                    for id in try Self.findHolders(
                        sql, table: table, docId: documentId, model: model, fields: [field], values: [json],
                        excluding: [], limitToFirst: false
                    ) {
                        try add(RecordLogRecordKey(model: model, id: id))
                    }
                }
                queueRows(try sql.rows(
                    """
                    SELECT writer, seq FROM record_log_pending_values
                     WHERE doc_id = ? AND _type = ? AND field = ? AND upsert IN (0, 1) AND (value = ? OR value IS NULL)
                    """,
                    [doc, .text(model), .text(field), value]
                ))
            }
            func add(_ key: RecordLogRecordKey) throws {
                guard !closure.contains(key) else { return }
                closure[key] = true
                queueRows(try sql.rows(
                    "SELECT writer, seq FROM record_log_pending_keys WHERE doc_id = ? AND _type = ? AND _id = ?",
                    [doc, .text(key.model), .text(key.id)]
                ))
                for row in [try tables.confirmedRow(key), try viewRow(sql, key)] {
                    for (field, value) in (row ?? [:]).sorted(by: { $0.key < $1.key }) where value != .null {
                        try probe(key.model, field, Format2SqlValue.recordLogWritten(value).recordLogNormalized)
                    }
                }
            }

            for key in seeds { try add(key) }
            while let ref = queue.popLast() {
                guard !entries.contains(ref) else { continue }
                entries[ref] = true
                for written in try sql.rows(
                    "SELECT _type, field, value, upsert FROM record_log_pending_values WHERE doc_id = ? AND writer = ? AND seq = ?",
                    [doc, .text(ref.writer), .integer(Int64(ref.seq))]
                ) {
                    guard let model = written["_type"].stringValue, let field = written["field"].stringValue else { continue }
                    let value = written["value"].recordLogNormalized
                    try probe(model, field, value)
                    if written["upsert"].intValue == 1 && !value.isNull { try holders(model, field, value) }
                }
                for other in try sql.rows(
                    "SELECT _type, _id FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ?",
                    [doc, .text(ref.writer), .integer(Int64(ref.seq))]
                ) {
                    if let model = other["_type"].stringValue, let id = other["_id"].stringValue {
                        try add(RecordLogRecordKey(model: model, id: id))
                    }
                }
            }

            let working = try guessView(sql, closure: closure.keys, entries: entries.keys)
            let outside = working.resolved.filter { !closure.contains($0) }
            if outside.isEmpty { return try writeView(sql, working.rows) }
            seeds.append(contentsOf: outside)
        }
    }

    /// What a probe was asked for, so each is asked once per refresh.
    private struct ProbeKey: Hashable {
        var kind: String
        var model: String
        var field: String
        var value: String

        init(kind: String, model: String, field: String, value: Format2SqlValue) {
            self.kind = kind
            self.model = model
            self.field = field
            switch value {
            case .null: self.value = "n"
            case .text(let text): self.value = "t" + text
            case .integer(let number): self.value = "i\(number)"
            case .real(let number): self.value = "r\(number)"
            }
        }
    }

    private static func jsonOf(_ value: Format2SqlValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .text(let text): return .string(text)
        case .integer(let number): return .number(Double(number))
        case .real(let number): return .number(number)
        }
    }

    /// A record's place in the view's order: its confirmed row's, or, for a
    /// record only a guess holds, after every confirmed row in the order its
    /// entries were written.
    private func viewOrder(_ sql: RecordLogSql, _ key: RecordLogRecordKey) throws -> Int {
        if let row = try sql.first(
            "SELECT rowid AS at FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?",
            [doc, .text(key.model), .text(key.id)]
        ), let at = row["at"].intValue {
            return at
        }
        let pending = try sql.first(
            """
            SELECT MIN(p.ord) AS ord FROM record_log_pending p JOIN record_log_pending_keys k
                ON k.doc_id = p.doc_id AND k.writer = p.writer AND k.seq = p.seq
             WHERE p.doc_id = ? AND k._type = ? AND k._id = ?
            """,
            [doc, .text(key.model), .text(key.id)]
        )
        return Self.guessHeld + (pending?["ord"].intValue ?? 0)
    }

    /// The table a refresh guesses over: the closure's confirmed rows, and view
    /// rows of anything else a guess reaches.
    private final class WorkingTable: RecordLogRowTable {
        let store: RecordLogStore
        let sql: RecordLogSql
        var rows = RecordLogOrderedMap<RecordLogRecordKey, RecordLogRow?>()
        var placed: [RecordLogRecordKey: Int] = [:]
        var appended = 0

        init(store: RecordLogStore, sql: RecordLogSql) {
            self.store = store
            self.sql = sql
        }

        func place(_ key: RecordLogRecordKey) throws -> Int {
            if let at = placed[key] { return at }
            let at = try store.viewOrder(sql, key)
            placed[key] = at
            return at
        }

        func row(_ key: RecordLogRecordKey) throws -> RecordLogRow? {
            if let held = rows[key] { return held }
            let read = try store.viewRow(sql, key)
            rows[key] = .some(read)
            return read
        }

        func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) throws {
            if try self.row(key) == nil {
                placed[key] = RecordLogStore.guessCreated + appended
                appended += 1
            }
            rows[key] = .some(row)
        }

        func delete(_ key: RecordLogRecordKey) throws {
            rows[key] = .some(nil)
        }

        func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) throws -> String? {
            var found: [RecordLogRecordKey] = []
            for (key, row) in rows.entries {
                guard let row, key.model == model, !excluding.contains(key.id) else { continue }
                if recordLogHolds(row, fields: fields, values: values) { found.append(key) }
            }
            let skip = excluding + rows.keys.filter { $0.model == model }.map(\.id)
            for id in try RecordLogStore.findHolders(
                sql, table: "record_log_view", docId: store.documentId, model: model, fields: fields,
                values: values, excluding: skip, limitToFirst: false
            ) {
                found.append(RecordLogRecordKey(model: model, id: id))
            }
            guard var first = found.first else { return nil }
            for key in found.dropFirst() where try place(key) < place(first) { first = key }
            return first.id
        }
    }

    /// The rows of `closure` as the confirmed rows with `entries`' guesses
    /// applied in the order they were written, and every record a guess
    /// resolved to (recorded against its entry, so a later refresh of either
    /// reaches the other).
    private func guessView(
        _ sql: RecordLogSql, closure: [RecordLogRecordKey], entries: [RecordLogEntryRef]
    ) throws -> (rows: RecordLogOrderedMap<RecordLogRecordKey, RecordLogRow?>, resolved: [RecordLogRecordKey]) {
        let table = WorkingTable(store: self, sql: sql)
        for key in closure { table.rows[key] = .some(try tables.confirmedRow(key)) }

        var ordered: [(ref: RecordLogEntryRef, ord: Int, entry: RecordLogPendingEntry)] = []
        for ref in entries {
            guard let row = try sql.first(
                "SELECT ord, entry, void FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?",
                [doc, .text(ref.writer), .integer(Int64(ref.seq))]
            ), row["void"].intValue != 1,
                let entry = RecordLogPendingEntry(stored: row["entry"].stringValue.flatMap(RecordLogJSON.parse))
            else { continue }
            ordered.append((ref, row["ord"].intValue ?? 0, entry))
        }
        ordered.sort { $0.ord < $1.ord }

        var resolved = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for (ref, _, entry) in ordered {
            for key in try recordLogApplyGuess(table, entry) {
                resolved[key] = true
                // An upsert resolved to a record its entry does not name: kept, so
                // the next refresh of either reaches the other.
                try sql.exec(
                    "INSERT OR IGNORE INTO record_log_pending_keys (doc_id, writer, seq, _type, _id, resolved) VALUES (?, ?, ?, ?, ?, 1)",
                    [doc, .text(ref.writer), .integer(Int64(ref.seq)), .text(key.model), .text(key.id)]
                )
            }
        }
        return (table.rows, resolved.keys)
    }

    /// Write the working rows into the view; answers the records whose view row changed.
    private func writeView(
        _ sql: RecordLogSql, _ working: RecordLogOrderedMap<RecordLogRecordKey, RecordLogRow?>
    ) throws -> [RecordLogRecordKey] {
        var changed: [RecordLogRecordKey] = []
        for (key, row) in working.entries {
            let before = try viewRow(sql, key)
            if before == row { continue }
            if let row {
                try sql.exec(
                    """
                    INSERT INTO record_log_view (doc_id, _type, _id, _data) VALUES (?, ?, ?, ?)
                      ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data
                    """,
                    [doc, .text(key.model), .text(key.id), .text(RecordLogJSON.text(.object(row)))]
                )
            } else {
                try sql.exec(
                    "DELETE FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id = ?",
                    [doc, .text(key.model), .text(key.id)]
                )
            }
            changed.append(key)
        }
        return changed
    }

    /// Refresh, project and describe the view rows a command touched, with any already refreshed.
    private func settleView(
        _ sql: RecordLogSql, _ touched: [RecordLogRecordKey], _ project: [RecordLogProjectionSpec],
        refreshed: [RecordLogRecordKey] = []
    ) throws -> [RecordLogRowChange] {
        var unique = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for key in touched + tables.takeDirty() { unique[key] = true }
        var changed = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for key in refreshed + (try refreshView(sql, unique.keys)) { changed[key] = true }
        let keys = changed.keys
        for spec in project {
            for key in keys where key.model == spec.model {
                try RecordLogQueryProjection.projectRow(
                    sql, spec: spec, documentId: documentId, id: key.id, row: try viewRow(sql, key)
                )
            }
        }
        // A model with no spec here (not registered yet in this process) had
        // view rows change that its query tables did not take: they no longer
        // hold its view, and its registration rebuilds them.
        let projected = Set(project.map(\.model))
        for model in Set(keys.map(\.model)).subtracting(projected) {
            try sql.exec("DELETE FROM record_log_projection WHERE doc_id = ? AND model = ?", [doc, .text(model)])
        }
        return try keys.map { RecordLogRowChange(model: $0.model, id: $0.id, row: try viewRow(sql, $0)) }
    }

    private func rules(_ writer: String) -> RecordLogRules {
        RecordLogRules(tables: tables, writer: writer)
    }

    // MARK: - Writes

    /// Commit local writes, one entry each, as one save in the connection's
    /// group: the budget check, the pending entry, the guess on the view and
    /// the projection. `listener` hears the group's outcome after it commits:
    /// `nil`, or — when the group's `COMMIT` failed and everything in it was
    /// rolled back, these entries included — a `JsBaoError(.unavailable)`
    /// naming the document, with `details.reason` `"commit-failed"`.
    ///
    /// - Throws: `JsBaoError(.documentEpochBudget)` when both epochs this client
    ///   may write into are full; nothing of the save lands.
    func commitEntries(
        writer: String, writes: [RecordLogWrite], project: [RecordLogProjectionSpec] = [],
        ts: Int64? = nil, listener: RecordLogGroupCommit.Listener? = nil
    ) throws -> RecordLogCommitReply {
        let documentId = documentId
        let heard: RecordLogGroupCommit.Listener? = listener.map { listener in
            { error in
                listener(error.map { error in
                    JsBaoError(
                        code: .unavailable,
                        message: "Saves to the format-3 document \(documentId) could not be committed and were "
                            + "rolled back: \(error.localizedDescription)",
                        details: ["documentId": .string(documentId), "reason": "commit-failed",
                                  "error": .string(error.localizedDescription)]
                    )
                })
            }
        }
        return try save(listener: heard) { sql in
            try tables.countingEpochs {
                let rules = rules(writer)
                var entries: [RecordLogPendingEntry] = []
                var refreshed: [RecordLogRecordKey] = []
                for write in writes {
                    guard let m = write.mutations.first else { continue }
                    try rules.budgetCheck(documentId: documentId)
                    let entry = try rules.write(
                        m, also: Array(write.mutations.dropFirst()), upsertOn: write.upsertOn,
                        ts: ts ?? Int64(Date().timeIntervalSince1970 * 1000)
                    )
                    // Each write lands on the view before the next is applied over it.
                    refreshed.append(contentsOf: try refreshView(sql, entry.keys + tables.takeDirty()))
                    entries.append(entry)
                }
                let changed = try settleView(sql, [], project, refreshed: refreshed)
                return RecordLogCommitReply(entries: entries, changed: changed, cursor: try tables.cursor())
            }
        }
    }

    /// Apply what the room relayed, item by item.
    func receive(writer: String, items: [RecordLogResultItem], project: [RecordLogProjectionSpec] = []) throws -> RecordLogChangeReply {
        try command { sql in
            let rules = rules(writer)
            var reply = RecordLogChangeReply()
            var touched: [RecordLogRecordKey] = []
            for item in items {
                let out = try rules.receive(item)
                touched.append(contentsOf: out.touched)
                reply.acknowledged.append(contentsOf: out.acknowledged)
                reply.settled.append(contentsOf: out.settled)
                if reply.underivable == nil { reply.underivable = out.underivable }
            }
            reply.changed = try settleView(sql, touched, project)
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    /// Act on a refusal: hand back what it reaches and answer the frames that move the room past it.
    func refused(writer: String, refusal: RecordLogRefusal, project: [RecordLogProjectionSpec] = []) throws -> RecordLogChangeReply {
        try command { sql in
            let out = try rules(writer).refused(refusal)
            var reply = RecordLogChangeReply()
            reply.handedBack = out.handedBack
            reply.frames = out.frames
            reply.changed = try settleView(sql, out.touched, project)
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    /// The room has moved past a withdrawn entry's number.
    func settled(writer: String, seq: Int) throws {
        try command { _ in try rules(writer).settled(seq) }
    }

    /// Begin a catch-up; a full one replaces the confirmed rows as its pages arrive.
    func beginCatchUp(writer: String, full: Bool) throws {
        _ = try beginFencedCatchUp(writer: writer, full: full)
    }

    /// Begin a catch-up as ``beginCatchUp(writer:full:)`` does, answering a full
    /// one's generation: every later command of it carries it, and another
    /// client of the store beginning a replacement makes it stale.
    func beginFencedCatchUp(writer: String, full: Bool) throws -> Int? {
        try command { _ in try rules(writer).beginFencedCatchUp(full: full) }
    }

    /// Begin a segment's full replacement: its generation, and the segment the
    /// store's rows were last replaced from, read in the same transaction (a
    /// mirror's may be older). The receipt tries to keep only those chunks.
    func beginSegmentReplacement(writer: String) throws -> (generation: Int?, held: RecordLogHeldSegment?) {
        try command { _ in
            let generation = try rules(writer).beginFencedCatchUp(full: true)
            return (generation, try tables.heldSegment())
        }
    }

    /// Whether `generation` is not the replacement the store is in.
    private func staleGeneration(_ generation: Int?) throws -> Bool {
        guard let generation else { return false }
        return try tables.replacing() != generation
    }

    /// Apply one page of a catch-up, read by the room at log number `lsn`. One
    /// older than the cursor, or under a replacement generation another began
    /// after, is answered `stale` and changes nothing.
    func applyCatchUpPage(
        writer: String, rows: [RecordLogCatchUpRow], gone: [RecordLogRecordKey] = [], lsn: Int? = nil,
        generation: Int? = nil, project: [RecordLogProjectionSpec] = []
    ) throws -> RecordLogChangeReply {
        try command { sql in
            let cursor = try tables.cursor()
            if let lsn, cursor > lsn { return RecordLogChangeReply(cursor: cursor, stale: true) }
            if try staleGeneration(generation) { return RecordLogChangeReply(cursor: cursor, stale: true) }
            let touched = try rules(writer).applyCatchUpPage(RecordLogCatchUpInput(rows: rows, gone: gone))
            return RecordLogChangeReply(changed: try settleView(sql, touched, project), cursor: try tables.cursor())
        }
    }

    /// Complete a catch-up at the room's log number, seeing the highest epoch
    /// its rows carry. One below the cursor, or a replacement's under a
    /// generation another began after, is answered `stale`: the cursor never
    /// moves back, and a full replacement removes nothing. A completion that
    /// ends receipt attempt `receipt` ends it in the store, and a full
    /// replacement every attempt whose last change came before it began.
    func completeCatchUp(
        writer: String, lsn: Int, high: Int? = nil, full: Bool = false, generation: Int? = nil,
        receipt: String? = nil, segment: RecordLogHeldSegment? = nil, at: Int64? = nil, project: [RecordLogProjectionSpec] = []
    ) throws -> RecordLogChangeReply {
        try command { sql in
            let cursor = try tables.cursor()
            if cursor > lsn { return RecordLogChangeReply(cursor: cursor, stale: true) }
            if try staleGeneration(generation) { return RecordLogChangeReply(cursor: cursor, stale: true) }
            let out = try rules(writer).completeCatchUp(
                lsn: lsn, high: high, full: full, generation: generation, receipt: receipt, segment: segment
            )
            try tables.setLastCatchUpAt(at ?? Int64(Date().timeIntervalSince1970 * 1000))
            var reply = RecordLogChangeReply()
            reply.acknowledged = out.acknowledged
            reply.settled = out.settled
            reply.underivable = out.underivable
            reply.changed = try settleView(sql, out.touched, project)
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    // MARK: - Receipts of chunks

    /// A receipt of a load's or a segment's chunks begins: it is kept from now
    /// until its completion, or a full replacement begun after its last
    /// change, ends it, so a store reopened after an interrupted receipt knows
    /// its rows may hold what the room does not. Answers the cursor and the
    /// attempt's id, which each of its commands carries.
    func beginReceipt(writer: String, kind: RecordLogReceiptKind, id: String) throws -> (cursor: Int, attempt: String) {
        try command { _ in
            let attempt = try rules(writer).beginReceipt(RecordLogReceipt(kind: kind, id: id))
            return (try tables.cursor(), attempt)
        }
    }

    /// The answer to a chunk command of a receipt attempt the store no longer has in progress: nothing changed.
    private func staleReceipt(_ writer: String, _ attempt: String?) throws -> RecordLogChunkReply? {
        guard let attempt, try !rules(writer).receiptInProgress(attempt) else { return nil }
        return RecordLogChunkReply(cursor: try tables.cursor(), stale: true)
    }

    /// Apply one chunk of bulk load `sessionId` as receipt `attempt`, in one
    /// transaction: its lines merged into the confirmed rows by key, the view
    /// rows of the chunk's records, and their query rows. The reply names the
    /// model, and in `changed` only the records an unjudged entry touches. An
    /// attempt the store no longer has in progress (a full replacement or its
    /// own completion ended it) is answered `stale` and changes nothing.
    func applyLoadChunk(
        writer: String, sessionId: String, attempt: String, model: String, lines: [RecordLogLoadLine],
        project: [RecordLogProjectionSpec] = []
    ) throws -> RecordLogChunkReply {
        try command { sql in
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let touched = try rules(writer).applyLoadLines(attempt: attempt, model: model, lines: lines)
            // A delete is touched only when it removed a record.
            let touchedIds = Set(touched.map(\.id))
            let removed = lines.filter { $0.patch["_deleted"] == .bool(true) && touchedIds.contains($0.id) }.count
            var reply = RecordLogChunkReply()
            reply.applied = touched.count - removed
            reply.removed = removed
            reply.changed = try settleBulk(sql, touched, project)
            reply.models = [model]
            if let first = lines.first, let last = lines.last {
                reply.ranges = [RecordLogIdRange(model: model, firstId: first.id, lastId: last.id)]
            }
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    /// Receipt `attempt` applied every chunk of bulk load `sessionId`. A
    /// refresh removes the confirmed rows of `models` no line the attempt
    /// applied named, from the view and the query tables too (an unjudged
    /// entry's guess stays); a merge removes nothing. `stale` as
    /// ``applyLoadChunk(writer:sessionId:attempt:model:lines:project:)``.
    func completeLoad(
        writer: String, sessionId: String, attempt: String, mode: RecordLogLoadMode, models: [String],
        project: [RecordLogProjectionSpec] = []
    ) throws -> RecordLogChunkReply {
        try command { sql in
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let touched = try rules(writer).completeLoad(attempt: attempt, mode: mode, models: models)
            var reply = RecordLogChunkReply()
            reply.removed = touched.count
            reply.changed = try settleBulk(sql, touched, project)
            reply.models = Self.modelsOf(touched)
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    /// Put one row chunk of a segment under the replacement `generation`, its
    /// view and query rows with it. Under a generation another replacement
    /// superseded, or as an attempt no longer in progress, it is answered
    /// `stale` and changes nothing.
    func applySegmentChunk(
        writer: String, generation: Int, attempt: String? = nil, rows: [RecordLogCatchUpRow],
        project: [RecordLogProjectionSpec] = []
    ) throws -> RecordLogChunkReply {
        try command { sql in
            let cursor = try tables.cursor()
            if try staleGeneration(generation) { return RecordLogChunkReply(cursor: cursor, stale: true) }
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let touched = try rules(writer).applySegmentRows(generation: generation, attempt: attempt, rows: rows)
            var reply = RecordLogChunkReply()
            reply.applied = touched.count
            reply.changed = try settleBulk(sql, touched, project)
            reply.models = Self.modelsOf(touched)
            if let first = rows.first, let last = rows.last, rows.allSatisfy({ $0.model == first.model }) {
                reply.ranges = [RecordLogIdRange(model: first.model, firstId: first.id, lastId: last.id)]
            }
            reply.cursor = cursor
            return reply
        }
    }

    /// Keep one chunk of segment `segmentId` from the confirmed rows instead of
    /// reading it, in one transaction, as
    /// ``RecordLogRules/keepSegmentChunk(generation:attempt:object:sha256:model:firstId:lastId:rows:)``
    /// decides: the reply's `applied` is the rows kept, or it answers
    /// `mismatch` and nothing changed. `stale` as
    /// ``applySegmentChunk(writer:generation:attempt:rows:project:)``, and for
    /// an attempt no longer in progress. The view and query rows are already
    /// the kept rows'.
    func keepSegmentChunk(
        writer: String, generation: Int, attempt: String, segmentId: String, object: String, sha256: String, model: String,
        firstId: String, lastId: String, rows: Int
    ) throws -> RecordLogChunkReply {
        try command { _ in
            let cursor = try tables.cursor()
            if try staleGeneration(generation) { return RecordLogChunkReply(cursor: cursor, stale: true) }
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let out = try rules(writer).keepSegmentChunk(
                generation: generation, attempt: attempt, object: object, sha256: sha256, model: model,
                firstId: firstId, lastId: lastId, rows: rows
            )
            var reply = RecordLogChunkReply()
            reply.cursor = cursor
            switch out {
            case .mismatch:
                reply.mismatch = true
            case .kept(let kept, let ranges):
                reply.applied = kept
                reply.ranges = ranges
            }
            return reply
        }
    }

    /// Apply a segment's corrections under the replacement `generation`;
    /// `stale` as ``applySegmentChunk(writer:generation:attempt:rows:project:)``.
    func applySegmentCorrections(
        writer: String, generation: Int, attempt: String? = nil, lines: [RecordLogCorrection],
        project: [RecordLogProjectionSpec] = []
    ) throws -> RecordLogChunkReply {
        try command { sql in
            let cursor = try tables.cursor()
            if try staleGeneration(generation) { return RecordLogChunkReply(cursor: cursor, stale: true) }
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let touched = try rules(writer).applySegmentCorrections(generation: generation, attempt: attempt, lines: lines)
            let hit = Set(touched)
            let removed = lines.filter { $0.row == nil && hit.contains(RecordLogRecordKey(model: $0.model, id: $0.id)) }.count
            var reply = RecordLogChunkReply()
            reply.applied = touched.count - removed
            reply.removed = removed
            reply.changed = try settleBulk(sql, touched, project)
            reply.models = Self.modelsOf(touched)
            reply.cursor = cursor
            return reply
        }
    }

    /// The distinct models of `keys`, in first-seen order.
    private static func modelsOf(_ keys: [RecordLogRecordKey]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { seen.insert($0.model).inserted ? $0.model : nil }
    }

    /// The view and query rows of records a chunk changed, written set-based:
    /// a record no unjudged entry touches and no unjudged upsert's value lands
    /// on shows its confirmed row, copied in batches; the rest are refreshed one
    /// closure at a time as any other change is. Answers the records the
    /// refresh changed.
    private func settleBulk(
        _ sql: RecordLogSql, _ keys: [RecordLogRecordKey], _ project: [RecordLogProjectionSpec]
    ) throws -> [RecordLogRowChange] {
        var models: [String] = []
        var byModel: [String: [String]] = [:]
        for key in keys {
            if byModel[key.model] == nil { models.append(key.model) }
            byModel[key.model, default: []].append(key.id)
        }
        var refresh = tables.takeDirty()
        let batch = 400
        for model in models {
            let ids = byModel[model] ?? []
            var guessed = RecordLogOrderedMap<String, Bool>()
            for start in stride(from: 0, to: ids.count, by: batch) {
                let slice = Array(ids[start..<min(start + batch, ids.count)])
                let marks = slice.map { _ in "?" }.joined(separator: ", ")
                for row in try sql.rows(
                    "SELECT DISTINCT _id FROM record_log_pending_keys WHERE doc_id = ? AND _type = ? AND _id IN (\(marks))",
                    [doc, .text(model)] + slice.map { .text($0) }
                ) {
                    if let id = row["_id"].stringValue { guessed[id] = true }
                }
            }
            // An unjudged upsert lands on the first record holding its value: a
            // record of the chunk that now holds one is refreshed with it.
            let chunkIds = Set(ids)
            for upsert in try sql.rows(
                """
                SELECT DISTINCT field, value FROM record_log_pending_values
                 WHERE doc_id = ? AND _type = ? AND upsert = 1 AND value IS NOT NULL
                """,
                [doc, .text(model)]
            ) {
                guard let field = upsert["field"].stringValue else { continue }
                for id in try Self.findHolders(
                    sql, table: "record_log_rows", docId: documentId, model: model, fields: [field],
                    values: [Self.jsonOf(upsert["value"].recordLogNormalized)], excluding: [], limitToFirst: false
                ) where chunkIds.contains(id) {
                    guessed[id] = true
                }
            }
            let plain = ids.filter { !guessed.contains($0) }
            for start in stride(from: 0, to: plain.count, by: batch) {
                let slice = Array(plain[start..<min(start + batch, plain.count)])
                let marks = slice.map { _ in "?" }.joined(separator: ", ")
                let bindings: [Format2SqlValue] = [doc, .text(model)] + slice.map { .text($0) }
                try sql.exec("DELETE FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id IN (\(marks))", bindings)
                try sql.exec(
                    """
                    INSERT INTO record_log_view (doc_id, _type, _id, _data)
                      SELECT doc_id, _type, _id, _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN (\(marks))
                    """,
                    bindings
                )
            }
            refresh.append(contentsOf: guessed.keys.map { RecordLogRecordKey(model: model, id: $0) })
            if let spec = project.first(where: { $0.model == model }) {
                for id in plain {
                    try RecordLogQueryProjection.projectRow(
                        sql, spec: spec, documentId: documentId, id: id,
                        row: try viewRow(sql, RecordLogRecordKey(model: model, id: id))
                    )
                }
            } else if !plain.isEmpty {
                // Not registered here: its query tables no longer hold its view,
                // and its registration rebuilds them.
                try sql.exec("DELETE FROM record_log_projection WHERE doc_id = ? AND model = ?", [doc, .text(model)])
            }
        }
        return try settleView(sql, refresh, project)
    }

    /// Record what the room said about epochs and constraints, and the permission the client holds.
    @discardableResult
    func setState(
        writer: String, notice: (current: Int, next: Int?, entries: Int?)? = nil,
        constraints: [RecordLogConstraint]? = nil, permission: String?? = nil
    ) throws -> RecordLogMarks {
        try command { sql in
            if let notice { try rules(writer).notice(current: notice.current, next: notice.next, entries: notice.entries) }
            if let constraints { try tables.setConstraints(constraints) }
            if let permission { try tables.setPermission(permission) }
            return try marksOn(sql)
        }
    }

    /// The client's copy of its open epoch is full: it moves to the next epoch
    /// the room has opened, the move a write's budget check makes on its own.
    @discardableResult
    func spill(writer: String) throws -> RecordLogMarks {
        try command { sql in
            try rules(writer).spill()
            return try marksOn(sql)
        }
    }

    /// The room said the epochs moved without a write: the client has seen `e`.
    func sawEpoch(writer: String, _ e: Int) throws {
        try command { _ in try rules(writer).sawEpoch(e) }
    }

    // MARK: - The query projection

    /// Project the named records' view rows into one model's query tables.
    func projectRows(ids: [String], spec: RecordLogProjectionSpec) throws {
        try command { sql in
            for id in ids {
                try RecordLogQueryProjection.projectRow(
                    sql, spec: spec, documentId: documentId, id: id,
                    row: try viewRow(sql, RecordLogRecordKey(model: spec.model, id: id))
                )
            }
        }
    }

    /// Project every view row of one model and mark the model projected, in one
    /// transaction; a no-op when the mark is already there.
    @discardableResult
    func projectModel(spec: RecordLogProjectionSpec) throws -> Bool {
        try command { sql in
            if try sql.first(
                "SELECT 1 AS present FROM record_log_projection WHERE doc_id = ? AND model = ?", [doc, .text(spec.model)]
            ) != nil {
                return false
            }
            try RecordLogQueryProjection.removeDocument(sql, spec: spec, documentId: documentId)
            for row in try sql.rows(
                "SELECT _id, _data FROM record_log_view WHERE doc_id = ? AND _type = ? ORDER BY _id", [doc, .text(spec.model)]
            ) {
                guard let id = row["_id"].stringValue else { continue }
                try RecordLogQueryProjection.projectRow(
                    sql, spec: spec, documentId: documentId, id: id, row: RecordLogJSON.row(row["_data"].stringValue)
                )
            }
            try sql.exec("INSERT OR IGNORE INTO record_log_projection (doc_id, model) VALUES (?, ?)", [doc, .text(spec.model)])
            return true
        }
    }

    /// Whether one model's query tables hold this document's view.
    func isProjected(model: String) throws -> Bool {
        try reading { sql in
            guard try tablesExist(sql) else { return false }
            return try sql.first(
                "SELECT 1 AS present FROM record_log_projection WHERE doc_id = ? AND model = ?", [doc, .text(model)]
            ) != nil
        }
    }

    /// Forget that a model's query tables hold this document's view (one model, or all).
    func forgetProjection(model: String? = nil) throws {
        try command { sql in
            if let model {
                try sql.exec("DELETE FROM record_log_projection WHERE doc_id = ? AND model = ?", [doc, .text(model)])
            } else {
                try sql.exec("DELETE FROM record_log_projection WHERE doc_id = ?", [doc])
            }
        }
    }

    // MARK: - The owner

    /// Whether the database holds the record-log tables at all — read only,
    /// so a client that never bound a format-3 document writes nothing.
    static func hasTables(host: any Format2SqlHost) throws -> Bool {
        try RecordLogStore(host: host, documentId: "", clientId: "").reading { sql in try sql.first(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text("record_log_state")]
        ) != nil }
    }

    /// The user the record-log tables belong to, or `nil` when none is written.
    static func owner(host: any Format2SqlHost) throws -> String? {
        try RecordLogStore(host: host, documentId: "", clientId: "").reading { sql in
            guard try sql.first(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(RecordLogSchema.ownerTable)]
            ) != nil else { return nil }
            return try sql.first("SELECT user_id FROM record_log_owner LIMIT 1")?["user_id"].stringValue
        }
    }

    /// Write down the user the record-log tables belong to.
    static func setOwner(host: any Format2SqlHost, userId: String) throws {
        let store = RecordLogStore(host: host, documentId: "", clientId: "")
        try store.initialize()
        try store.command { sql in
            try sql.exec("DELETE FROM record_log_owner")
            try sql.exec("INSERT INTO record_log_owner (user_id) VALUES (?)", [.text(userId)])
        }
    }

    /// Remove every document's rows from every record-log table, and the
    /// projected rows of the models `project` names: the store reset of a
    /// principal change. Answers how many unjudged entries were dropped.
    @discardableResult
    static func purgeAll(host: any Format2SqlHost, project: [RecordLogProjectionSpec] = []) throws -> Int {
        let store = RecordLogStore(host: host, documentId: "", clientId: "")
        return try store.command { sql in
            guard try store.tablesExist(sql) else { return 0 }
            let dropped = try sql.first(
                "SELECT COUNT(*) AS n FROM record_log_pending WHERE void = 0 AND acked IS NULL"
            )?["n"].intValue ?? 0
            let documents = try sql.rows("SELECT DISTINCT doc_id FROM record_log_view").compactMap { $0["doc_id"].stringValue }
            for spec in project {
                for documentId in documents {
                    try RecordLogQueryProjection.removeDocument(sql, spec: spec, documentId: documentId)
                }
            }
            for table in RecordLogSchema.clientTables { try sql.exec("DELETE FROM \(table)") }
            return dropped
        }
    }
}
