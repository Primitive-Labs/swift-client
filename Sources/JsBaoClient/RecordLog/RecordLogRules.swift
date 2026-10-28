import Foundation

// The record-log client's rules: what a writer does with its own entries and
// with what the room sends down. It keeps plain rows and a cursor, applies
// results in log-number order, withdraws what a refusal reaches, and writes
// into the highest epoch it has seen. A port of js-bao's
// `record-log-client/client.ts`, rule for rule.
//
// The rules run over a `RecordLogTables` port, so the same code keeps its state
// in the SQLite store or in memory (for the golden-trace replay). Every method
// is synchronous; the store runs each call inside one transaction.

/// The epochs a client has open, and the rotation size it budgets against.
struct RecordLogEpochs: Equatable, Sendable {
    /// The epoch it writes into; never below the highest it has seen.
    var open: Int
    /// The highest epoch the room has told it is open; it cannot write past this.
    var grant: Int
    /// The rotation size: how many entries fill a client's copy of an epoch.
    var entries: Int
}

/// A writer's next sequence number and where it last resumed.
struct RecordLogWriterState: Equatable, Sendable {
    var nextSeq: Int
    var resumedAt: Int
}

/// One writer's entry, named.
struct RecordLogEntryRef: Hashable, Sendable {
    var writer: String
    var seq: Int
}

/// Where a client's state is kept: one document's shared tables, and per writer its entries.
protocol RecordLogTables: AnyObject {
    /// The highest log number below which every result has been applied.
    func cursor() throws -> Int
    func setCursor(_ cursor: Int) throws
    func epochs() throws -> RecordLogEpochs
    func setEpochs(_ epochs: RecordLogEpochs) throws
    func constraints() throws -> [RecordLogConstraint]
    func setConstraints(_ constraints: [RecordLogConstraint]) throws
    /// The confirmed rows.
    func confirmed() throws -> RecordLogRowTable
    /// Every confirmed row is replaced by what follows (a full catch-up).
    func beginReplace() throws
    /// The replacement is complete: rows it did not put are gone. Answers the records removed.
    func completeReplace() throws -> [RecordLogRecordKey]
    /// A result held ahead of the cursor.
    func buffered(_ l: Int) -> RecordLogResult?
    func buffer(_ item: RecordLogResult)
    /// Drop held results at or below `l`.
    func dropBufferedThrough(_ l: Int)
    /// Whether `writer` is one of this store's writers.
    func isWriter(_ writer: String) throws -> Bool
    func writerState(_ writer: String) throws -> RecordLogWriterState
    func setWriterState(_ writer: String, _ state: RecordLogWriterState) throws
    /// A writer's unjudged entries, in `seq` order.
    func pending(_ writer: String) throws -> [RecordLogPendingEntry]
    /// One of a writer's unjudged entries, or `nil`.
    func pendingEntry(_ writer: String, _ seq: Int) throws -> RecordLogPendingEntry?
    /// A writer's unjudged entries at or below `seq`, in `seq` order.
    func pendingThrough(_ writer: String, _ seq: Int) throws -> [RecordLogPendingEntry]
    /// Insert or replace a writer's entry.
    func putPending(_ writer: String, _ entry: RecordLogPendingEntry) throws
    func deletePending(_ writer: String, _ seq: Int) throws
    /// Every acknowledged entry whose result is at or below `l`, in `seq` order per writer.
    func acknowledgedThrough(_ l: Int) throws -> [RecordLogEntryRef]
    /// Per first refused number on a record, the number the writer resumed at.
    func handled(_ writer: String, _ key: RecordLogRecordKey) throws -> [Int: Int]
    func setHandled(_ writer: String, _ key: RecordLogRecordKey, from: Int, until: Int) throws
    /// How many entries of epoch `e` this client has seen applied.
    func epochCount(_ e: Int) throws -> Int
    func countEpoch(_ e: Int) throws
    /// How many unjudged, unwithdrawn entries of epoch `e` the store holds, every writer's.
    func pendingInEpoch(_ e: Int) throws -> Int
}

extension RecordLogTables {
    /// Answered from ``pending(_:)``, reading every entry of the writer.
    func pendingEntry(_ writer: String, _ seq: Int) throws -> RecordLogPendingEntry? {
        try pending(writer).first(where: { $0.seq == seq })
    }

    /// Answered from ``pending(_:)``.
    func pendingThrough(_ writer: String, _ seq: Int) throws -> [RecordLogPendingEntry] {
        try pending(writer).filter { $0.seq <= seq }
    }
}

/// Tables that receive loads and segments: they keep the replacement's
/// generation, the receipts in progress and the records each load named. The
/// rules of a load or a segment need them; tables without them cannot.
protocol RecordLogReceiptTables: RecordLogTables {
    /// The generation of the full replacement in progress, or `nil`.
    func replacing() throws -> Int?
    /// The receipts of chunks begun and not completed, or `nil` when none is
    /// and no replacement counts against them.
    func receipts() throws -> RecordLogReceiptState?
    /// Store the receipts in progress (`nil`: none).
    func setReceipts(_ state: RecordLogReceiptState?) throws
    /// Remember that receipt `attempt` of a load named these records.
    func noteLoadKeys(_ attempt: String, _ keys: [RecordLogRecordKey]) throws
    /// Remove every confirmed row of `models` receipt `attempt` did not name; answers them.
    func removeUnnamed(_ attempt: String, models: [String]) throws -> [RecordLogRecordKey]
    /// Forget the records receipt `attempt` named.
    func forgetLoad(_ attempt: String) throws
    /// Forget the records every receipt but `attempts` named.
    func keepLoads(_ attempts: [String]) throws
    /// The segment the confirmed rows were last replaced from, or `nil`.
    func heldSegment() throws -> RecordLogHeldSegment?
    /// Record the segment a full replacement's completion replaced the rows from (`nil`: none).
    func setHeldSegment(_ segment: RecordLogHeldSegment?) throws
    /// Under the full replacement in progress, keep the confirmed rows of
    /// `model` with ids in `[firstId, lastId]` (rows of no other replacement)
    /// when there are exactly `rows` of them, as though it had put them.
    /// Answers whether it did; when not, nothing changed.
    func keepConfirmedRange(model: String, firstId: String, lastId: String, rows: Int) throws -> Bool
}

/// What a refusal did.
struct RecordLogRefusalOutcome: Sendable {
    /// Records whose view may have moved.
    var touched: [RecordLogRecordKey] = []
    /// The entries handed back to the app, in `seq` order.
    var handedBack: [RecordLogPendingEntry] = []
    /// The frames to send so the room moves past the withdrawn entries.
    var frames: [RecordLogUpFrame] = []
}

/// A compact acknowledgement the client could not derive: no unwithdrawn
/// pending entry of `writer` has its `seq`. It waits at `l`, and the session
/// opens the document again from the cursor so the catch-up carries the row.
struct RecordLogUnderivableAck: Equatable, Sendable {
    /// The acknowledged entry's log number.
    var l: Int
    /// The writer it names.
    var writer: String
    /// The sequence number it names.
    var seq: Int
}

/// What a received item did.
struct RecordLogReceiveOutcome: Sendable {
    /// Records whose view may have moved.
    var touched: [RecordLogRecordKey] = []
    /// The writer entries this item acknowledged: what a `confirm` waits for.
    var acknowledged: [RecordLogEntryRef] = []
    /// Writer entries that left the pending log.
    var settled: [RecordLogEntryRef] = []
    /// Those entries with the confirmed rows of their records as each settled,
    /// right after the result that settled it applied.
    var settlements: [RecordLogEntryRef: RecordLogSettlement] = [:]
    /// A compact acknowledgement at the cursor that could not be derived, which holds every later result back.
    var underivable: RecordLogUnderivableAck?
}

/// A catch-up's content: changed rows, or the whole table.
struct RecordLogCatchUpInput: Sendable {
    /// The rows replace the whole table.
    var full: Bool = false
    var rows: [RecordLogCatchUpRow] = []
    /// Records gone since the cursor.
    var gone: [RecordLogRecordKey] = []
}

/// The rules one writer of one document runs, over its tables.
final class RecordLogRules {
    let tables: RecordLogTables
    let writer: String

    init(tables: RecordLogTables, writer: String) {
        self.tables = tables
        self.writer = writer
    }

    /// The writer's next sequence number.
    func nextSeq() throws -> Int { try tables.writerState(writer).nextSeq }

    /// The writer's unjudged entries.
    func pending() throws -> [RecordLogPendingEntry] { try tables.pending(writer) }

    /// Write an entry: the next `seq`, the open epoch, the cursor. It joins the
    /// pending log; the store applies it to the view as a guess.
    func write(
        _ m: RecordLogMutation, also: [RecordLogMutation] = [], upsertOn: String? = nil, ts: Int64? = nil
    ) throws -> RecordLogPendingEntry {
        let state = try tables.writerState(writer)
        let entry = RecordLogPendingEntry(
            seq: state.nextSeq, e: try tables.epochs().open, k: try tables.cursor(), m: m,
            also: also.isEmpty ? nil : also, upsertOn: upsertOn, ts: ts
        )
        try tables.setWriterState(writer, RecordLogWriterState(nextSeq: state.nextSeq + 1, resumedAt: state.resumedAt))
        try tables.putPending(writer, entry)
        return entry
    }

    /// Whether another entry may be written: when the client's copy of its open
    /// epoch is full it moves to the next one the room has opened; when that is
    /// full too the write is refused `DOCUMENT_EPOCH_BUDGET`.
    ///
    /// - Returns: `true` when the open epoch moved.
    @discardableResult
    func budgetCheck(documentId: String) throws -> Bool {
        let epochs = try tables.epochs()
        func full(_ e: Int) throws -> Bool {
            try tables.epochCount(e) + tables.pendingInEpoch(e) >= epochs.entries
        }
        if try !full(epochs.open) { return false }
        if epochs.open < epochs.grant, try !full(epochs.open + 1) {
            try spill()
            return true
        }
        throw JsBaoError(
            code: .documentEpochBudget,
            message: "This client's copies of epochs \(epochs.open) and \(epochs.open + 1) are full "
                + "(\(epochs.entries) entries each); connect so the room can rotate before writing more.",
            details: ["documentId": .string(documentId), "scope": "local"]
        )
    }

    /// The client's copy of its open epoch is full: it moves to the next one the room has opened.
    func spill() throws {
        var epochs = try tables.epochs()
        guard epochs.open < epochs.grant else { return }
        epochs.open += 1
        try tables.setEpochs(epochs)
    }

    /// The room says which epoch is current; the one after it is open too.
    func notice(current: Int, next: Int? = nil, entries: Int? = nil) throws {
        let epochs = try tables.epochs()
        try tables.setEpochs(RecordLogEpochs(
            open: max(epochs.open, current),
            grant: max(epochs.grant, next ?? current + 1),
            entries: entries ?? epochs.entries
        ))
    }

    /// The client has seen epoch `e`: it never writes below it again.
    func sawEpoch(_ e: Int) throws {
        var epochs = try tables.epochs()
        if e <= epochs.open && e <= epochs.grant { return }
        epochs.open = max(epochs.open, e)
        epochs.grant = max(epochs.grant, e)
        try tables.setEpochs(epochs)
    }

    /// The room has moved past a withdrawn entry's sequence number.
    func settled(_ seq: Int) throws {
        if let entry = try tables.pendingEntry(writer, seq), entry.isVoid {
            try tables.deletePending(writer, seq)
        }
    }

    /// Something the room relayed. A result is applied to the confirmed rows in
    /// log-number order (one ahead of the cursor waits; one at or below it was
    /// applied already). Independently of that, a result naming a writer of this
    /// store acknowledges that writer's entry at once; the entry leaves the
    /// pending log, and its guess the view, once its result's row is applied.
    /// `void` and `duplicate` items settle the entry they name.
    ///
    /// A compact acknowledgement (no `changes`) is applied, in its turn, by its
    /// pending entry's mutations as plain row operations, the rule by which the
    /// room vouched for it. With no unwithdrawn pending entry for its `seq` it
    /// stays buffered, the cursor stops below it, and the outcome names it
    /// (`underivable`).
    func receive(_ item: RecordLogResultItem) throws -> RecordLogReceiveOutcome {
        var out = RecordLogReceiveOutcome()
        switch item {
        case .void(let seq):
            if let entry = try tables.pendingEntry(writer, seq) {
                try tables.deletePending(writer, seq)
                try settle(&out, writer: writer, entry)
                if !entry.isVoid { out.touched.append(contentsOf: entry.keys) }
            }
            return out
        case .duplicate(let seq):
            // Accepted before: the row comes from catch-up.
            let entry = try tables.pendingEntry(writer, seq)
            out.acknowledged.append(RecordLogEntryRef(writer: writer, seq: seq))
            if let entry {
                try tables.deletePending(writer, seq)
                try settle(&out, writer: writer, entry)
                if !entry.isVoid { out.touched.append(contentsOf: entry.keys) }
            }
            return out
        case .result(let result):
            if let w = result.w, let seq = result.seq, try tables.isWriter(w) {
                out.acknowledged.append(RecordLogEntryRef(writer: w, seq: seq))
                if var entry = try tables.pendingEntry(w, seq),
                   !entry.isVoid, entry.acked == nil {
                    entry.acked = result.l
                    if let alias = result.alias { entry.alias = alias }
                    try tables.putPending(w, entry)
                }
            }
            let confirmed = try tables.confirmed()
            if result.l > (try tables.cursor()) {
                tables.buffer(result)
                while let next = tables.buffered(try tables.cursor() + 1) {
                    if let changes = next.changes {
                        for change in changes {
                            try recordLogApplyChange(confirmed, change)
                            out.touched.append(RecordLogRecordKey(model: change.model, id: change.id))
                        }
                    } else if try !applyOwnEntry(confirmed, next, &out) {
                        out.underivable = RecordLogUnderivableAck(l: next.l, writer: next.w ?? "", seq: next.seq ?? 0)
                        break
                    }
                    try tables.setCursor(next.l)
                    tables.dropBufferedThrough(next.l)
                    try tables.countEpoch(next.e)
                    if let w = next.w, let seq = next.seq, try tables.isWriter(w) {
                        try confirmEntry(writer: w, seq: seq, alias: next.alias, &out)
                    }
                    try sawEpoch(next.e)
                }
            }
            try settleAcknowledged(&out)
            return out
        }
    }

    /// A compact acknowledgement's changes, derived: the mutations of the
    /// pending entry it names applied in order to the confirmed rows as plain
    /// row operations. Answers `false`, changing nothing, when no unwithdrawn
    /// pending entry of a writer of this store has its `seq`.
    private func applyOwnEntry(
        _ confirmed: RecordLogRowTable, _ item: RecordLogResult, _ out: inout RecordLogReceiveOutcome
    ) throws -> Bool {
        guard let w = item.w, let seq = item.seq, try tables.isWriter(w),
              let entry = try tables.pendingEntry(w, seq), !entry.isVoid
        else { return false }
        for mutation in entry.mutations {
            if let row = recordLogPlainRowAfter(try confirmed.row(mutation.key), mutation) {
                try confirmed.set(mutation.key, row)
            } else if mutation.kind == .delete {
                try confirmed.delete(mutation.key)
            }
            out.touched.append(mutation.key)
        }
        return true
    }

    /// Acknowledged entries whose result's row the cursor has passed leave the
    /// pending log: their row was applied, here or by another writer of this
    /// store, before the acknowledgement arrived.
    private func settleAcknowledged(_ out: inout RecordLogReceiveOutcome) throws {
        for ref in try tables.acknowledgedThrough(try tables.cursor()) {
            guard let entry = try tables.pendingEntry(ref.writer, ref.seq) else { continue }
            try tables.deletePending(ref.writer, ref.seq)
            try settle(&out, writer: ref.writer, entry)
            out.touched.append(contentsOf: entry.keys)
            if let alias = entry.alias { try renamePending(writer: ref.writer, alias: alias, &out.touched) }
        }
    }

    /// An entry left the pending log: it is settled, with the confirmed rows
    /// of the records it touched (an upsert's holder included) as they are
    /// now, right after the result that settled it applied.
    private func settle(_ out: inout RecordLogReceiveOutcome, writer: String, _ entry: RecordLogPendingEntry) throws {
        let ref = RecordLogEntryRef(writer: writer, seq: entry.seq)
        out.settled.append(ref)
        var keys = entry.isVoid ? [] : entry.keys
        if !entry.isVoid, let alias = entry.alias { keys.append(RecordLogRecordKey(model: alias.model, id: alias.to)) }
        var seen = Set<RecordLogRecordKey>()
        let confirmed = try tables.confirmed()
        var rows: [RecordLogCurrentRecord] = []
        for key in keys where seen.insert(key).inserted {
            rows.append(RecordLogCurrentRecord(model: key.model, id: key.id, row: try confirmed.row(key)))
        }
        out.settlements[ref] = RecordLogSettlement(rows: rows)
    }

    /// What the room made of an accepted entry of a writer of this store: it and
    /// every earlier entry of that writer leave the pending log (the room judged
    /// them first), and an upsert that resolved elsewhere renames what the
    /// writer wrote since.
    private func confirmEntry(
        writer: String, seq: Int, alias: RecordLogAlias?, _ out: inout RecordLogReceiveOutcome
    ) throws {
        for entry in try tables.pendingThrough(writer, seq) {
            try tables.deletePending(writer, entry.seq)
            var settled = entry
            if entry.seq == seq, let alias { settled.alias = alias }
            try settle(&out, writer: writer, settled)
            if !entry.isVoid { out.touched.append(contentsOf: entry.keys) }
        }
        if let alias { try renamePending(writer: writer, alias: alias, &out.touched) }
    }

    /// An upsert of this writer's resolved to an existing record: what it wrote since belongs there.
    private func renamePending(writer: String, alias: RecordLogAlias, _ touched: inout [RecordLogRecordKey]) throws {
        func renamed(_ m: RecordLogMutation) -> RecordLogMutation {
            guard m.model == alias.model, m.id == alias.from else { return m }
            var moved = m
            moved.id = alias.to
            return moved
        }
        touched.append(RecordLogRecordKey(model: alias.model, id: alias.from))
        touched.append(RecordLogRecordKey(model: alias.model, id: alias.to))
        for entry in try tables.pending(writer) {
            var next = entry
            next.m = renamed(entry.m)
            next.also = entry.also?.map(renamed)
            if next != entry { try tables.putPending(writer, next) }
        }
    }

    /// A refusal, as far as its scope reaches. The room refused everything in
    /// that scope from `from` until this writer resumes, so that run is handed
    /// back; entries below `from` were accepted and stay pending until the room
    /// returns them.
    ///
    /// - `entry`: that entry alone.
    /// - `record`: every later entry on a refused record from that record's
    ///   first refused number, and a withdrawn entry's other records from its
    ///   own number. Withdrawn entries stay in line as void markers. Each record
    ///   is resumed once per first refused number.
    /// - `writer`: every entry from `from`, unless the refusal is older than the
    ///   writer's last resume (then only what it covered before that resume).
    func refused(_ refusal: RecordLogRefusal) throws -> RecordLogRefusalOutcome {
        var result = RecordLogRefusalOutcome()
        func handBack(_ gone: (RecordLogPendingEntry) -> Bool) throws {
            for entry in try tables.pending(writer) where gone(entry) {
                result.handedBack.append(entry)
                try tables.deletePending(writer, entry.seq)
                if !entry.isVoid { result.touched.append(contentsOf: entry.keys) }
            }
        }
        if refusal.scope == .entry {
            try handBack { $0.seq == refusal.seq }
            return result
        }
        let state = try tables.writerState(writer)
        if refusal.scope == .record {
            var froms: [(key: RecordLogRecordKey, from: Int)] = []
            var fromIndex: [RecordLogRecordKey: Int] = [:]
            func addFrom(_ key: RecordLogRecordKey, _ from: Int) {
                if let at = fromIndex[key] {
                    froms[at].from = from
                } else {
                    fromIndex[key] = froms.count
                    froms.append((key, from))
                }
            }
            for record in refusal.records { addFrom(record.key, record.from) }
            var withdrawn: [RecordLogPendingEntry] = []
            for entry in try tables.pending(writer) where !entry.isVoid {
                let keys = entry.keys
                var hit = false
                for key in keys {
                    guard let at = fromIndex[key], entry.seq >= froms[at].from else { continue }
                    let until = try tables.handled(writer, key)[froms[at].from]
                    if until == nil || entry.seq < until! { hit = true; break }
                }
                guard hit else { continue }
                withdrawn.append(entry)
                for key in keys where fromIndex[key] == nil { addFrom(key, entry.seq) }
            }
            for var entry in withdrawn {
                result.handedBack.append(entry)
                result.touched.append(contentsOf: entry.keys)
                entry.isVoid = true
                try tables.putPending(writer, entry)
            }
            var records: [RecordLogRefusedRecord] = []
            for (key, from) in froms {
                if try tables.handled(writer, key)[from] != nil { continue }
                try tables.setHandled(writer, key, from: from, until: state.nextSeq)
                records.append(RecordLogRefusedRecord(model: key.model, id: key.id, from: from))
            }
            if !records.isEmpty { result.frames.append(.resume(nextSeq: state.nextSeq, records: records)) }
            return result
        }
        let stale = refusal.from < state.resumedAt
        try handBack { $0.seq >= refusal.from && (!stale || $0.seq < state.resumedAt) }
        if stale { return result }
        try tables.setWriterState(writer, RecordLogWriterState(nextSeq: state.nextSeq, resumedAt: state.nextSeq))
        result.frames.append(.resume(nextSeq: state.nextSeq, records: nil))
        return result
    }

    /// Begin a catch-up: a full one replaces the table, so every row it does not
    /// carry is gone once it completes.
    func beginCatchUp(full: Bool) throws {
        _ = try beginFencedCatchUp(full: full)
    }

    /// Begin a catch-up as ``beginCatchUp(full:)`` does, answering a full one's
    /// replacement generation (`nil` for one that is not full, or for tables
    /// that keep none). Receipts whose last change precedes it are made right
    /// when it completes.
    func beginFencedCatchUp(full: Bool) throws -> Int? {
        guard full else { return nil }
        try tables.beginReplace()
        guard let receiving = tables as? RecordLogReceiptTables else { return nil }
        var state = try receiving.receipts() ?? RecordLogReceiptState()
        state.since = state.n
        try receiving.setReceipts(state)
        return try receiving.replacing()
    }

    /// Apply one part of a catch-up: its rows, and the records gone since the cursor.
    func applyCatchUpPage(_ page: RecordLogCatchUpInput, generation: Int? = nil) throws -> [RecordLogRecordKey] {
        try assertGeneration(generation)
        let confirmed = try tables.confirmed()
        var touched: [RecordLogRecordKey] = []
        for row in page.rows {
            let key = RecordLogRecordKey(model: row.model, id: row.id)
            try confirmed.set(key, row.row)
            touched.append(key)
        }
        for key in page.gone {
            try confirmed.delete(key)
            touched.append(key)
        }
        return touched
    }

    /// Complete a catch-up: the cursor is the room's log number, results held at
    /// or below it are dropped (the rows hold them), held results past it
    /// apply, and the client writes at or above the highest epoch any row it now
    /// holds was written in.
    ///
    /// - Parameters:
    ///   - generation: The replacement's generation, checked before anything is removed.
    ///   - receipt: The receipt attempt it completes: that attempt's changes are the room's now.
    ///   - segment: For a segment's replacement, the segment and its chunks: the store holds them from now.
    func completeCatchUp(
        lsn: Int, high: Int?, full: Bool, generation: Int? = nil, receipt: String? = nil, segment: RecordLogHeldSegment? = nil
    ) throws -> RecordLogReceiveOutcome {
        try assertGeneration(generation)
        var out = RecordLogReceiveOutcome()
        if full {
            out.touched.append(contentsOf: try tables.completeReplace())
            // The marker describes the rows of the generation that completed:
            // any other replacement's leaves none.
            try (tables as? RecordLogReceiptTables)?.setHeldSegment(segment)
        }
        // A completed receipt leaves its own changes the room's, and a full
        // replacement every change made before it began; a receipt that changed
        // rows after stays in progress.
        try settleReceipts(full: full, own: receipt)
        try tables.setCursor(lsn)
        tables.dropBufferedThrough(lsn)
        if let high { try sawEpoch(high) }
        if let next = tables.buffered(lsn + 1) {
            // Results that arrived while the pages were read apply now.
            let replay = try receive(.result(next))
            out.touched.append(contentsOf: replay.touched)
            out.acknowledged.append(contentsOf: replay.acknowledged)
            out.settled.append(contentsOf: replay.settled)
            out.settlements.merge(replay.settlements) { _, new in new }
            if let underivable = replay.underivable { out.underivable = underivable }
        }
        try settleAcknowledged(&out)
        return out
    }

    // MARK: - Receipts of chunks

    private func receiptTables() throws -> RecordLogReceiptTables {
        guard let receiving = tables as? RecordLogReceiptTables else {
            throw JsBaoError(
                code: .unavailable,
                message: "[record-log] These tables cannot receive a load or a segment: they keep no receipt state."
            )
        }
        return receiving
    }

    /// Drop the receipt attempts a completion made right: `own`, with every
    /// earlier attempt of the same load or segment whose last change came
    /// before own's (its remainder corrects the same lines), and on a full
    /// replacement every one whose last change came before it began. The
    /// records a dropped attempt's load named are forgotten with it.
    private func settleReceipts(full: Bool, own: String?) throws {
        guard let receiving = tables as? RecordLogReceiptTables, let state = try receiving.receipts() else { return }
        let since = full ? state.since : nil
        let mine = own.flatMap { own in state.attempts.first { $0.attempt == own } }
        func ended(_ a: RecordLogReceiptAttempt) -> Bool {
            if a.attempt == own { return true }
            if let mine, a.kind == mine.kind, a.id == mine.id, a.last <= mine.last { return true }
            if let since, a.last <= since { return true }
            return false
        }
        let attempts = state.attempts.filter { !ended($0) }
        let nextSince = full ? nil : state.since
        if attempts.count == state.attempts.count && nextSince == state.since { return }
        try receiving.setReceipts(
            !attempts.isEmpty || nextSince != nil ? RecordLogReceiptState(n: state.n, since: nextSince, attempts: attempts) : nil
        )
        if attempts.count < state.attempts.count { try receiving.keepLoads(attempts.map(\.attempt)) }
    }

    /// Whether receipt `attempt` is still in progress in the store.
    func receiptInProgress(_ attempt: String) throws -> Bool {
        guard let receiving = tables as? RecordLogReceiptTables else { return false }
        return try receiving.receipts()?.attempts.contains { $0.attempt == attempt } == true
    }

    /// Count a change of receipt `attempt`. One no longer in progress is
    /// refused: whatever made its earlier changes right came before this one.
    private func touchReceipt(_ attempt: String) throws {
        let receiving = try receiptTables()
        guard var state = try receiving.receipts(),
              let at = state.attempts.firstIndex(where: { $0.attempt == attempt })
        else { throw RecordLogStaleReceiptError(attempt: attempt) }
        state.n += 1
        state.attempts[at].last = state.n
        try receiving.setReceipts(state)
    }

    /// A command under `generation` while the store replaces under another is stale.
    private func assertGeneration(_ generation: Int?) throws {
        guard let generation else { return }
        let current = try (tables as? RecordLogReceiptTables)?.replacing()
        if current != generation { throw RecordLogStaleReplacementError(generation: generation, current: current) }
    }

    /// A receipt of chunks begins: from its first committed chunk the confirmed
    /// rows may hold what the room does not, until its own completion or a full
    /// replacement begun after its last change makes them right. Answers the
    /// attempt's id, which each of its commands carries.
    func beginReceipt(_ receipt: RecordLogReceipt) throws -> String {
        let receiving = try receiptTables()
        var state = try receiving.receipts() ?? RecordLogReceiptState()
        state.n += 1
        let attempt = "\(state.n).\(Self.attemptSuffix())"
        state.attempts.append(RecordLogReceiptAttempt(kind: receipt.kind, id: receipt.id, attempt: attempt, last: state.n))
        try receiving.setReceipts(state)
        return attempt
    }

    /// Eight base-36 characters, as the JS attempt ids carry.
    private static func attemptSuffix() -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<8).map { _ in digits[Int.random(in: 0..<digits.count)] })
    }

    /// The latest receipt begun and not completed, or `nil` when none is.
    func incompleteReceipt() throws -> RecordLogReceipt? {
        try (tables as? RecordLogReceiptTables)?.receipts()?.latest
    }

    /// Apply one chunk's lines of a load to the confirmed rows, by key, as
    /// receipt `attempt`: `_deleted: true` removes the record (an absent one is
    /// left alone); otherwise the line's fields are set over the row it has,
    /// `null` kept as a present null, the line's own `id` field ignored, a
    /// nested value or a string set's array taken whole. Each key is remembered
    /// for a refresh. An attempt no longer in progress is refused with
    /// ``RecordLogStaleReceiptError`` before anything changes.
    ///
    /// - Returns: The records whose confirmed row changed.
    func applyLoadLines(attempt: String, model: String, lines: [RecordLogLoadLine]) throws -> [RecordLogRecordKey] {
        let receiving = try receiptTables()
        try touchReceipt(attempt)
        let confirmed = try tables.confirmed()
        var touched: [RecordLogRecordKey] = []
        for line in lines {
            let key = RecordLogRecordKey(model: model, id: line.id)
            let existing = try confirmed.row(key)
            if line.patch["_deleted"] == .bool(true) {
                guard existing != nil else { continue }
                try confirmed.delete(key)
                touched.append(key)
                continue
            }
            var row = existing ?? [:]
            for (field, value) in line.patch where field != "id" { row[field] = value }
            row["id"] = .string(line.id)
            try confirmed.set(key, row)
            touched.append(key)
        }
        try receiving.noteLoadKeys(attempt, lines.map { RecordLogRecordKey(model: model, id: $0.id) })
        return touched
    }

    /// Receipt `attempt` applied every chunk of its load. A refresh removes
    /// every confirmed row of `models` no line the attempt applied named (the
    /// remainder then restores what another writer created meanwhile); a merge
    /// removes nothing. The attempt's keys are forgotten either way; one no
    /// longer in progress is refused as ``applyLoadLines(attempt:model:lines:)`` refuses it.
    func completeLoad(attempt: String, mode: RecordLogLoadMode, models: [String]) throws -> [RecordLogRecordKey] {
        let receiving = try receiptTables()
        try touchReceipt(attempt)
        let touched = mode == .refresh ? try receiving.removeUnnamed(attempt, models: models) : []
        try receiving.forgetLoad(attempt)
        return touched
    }

    /// Put a segment's rows under the replacement `generation`, as receipt `attempt` when it names one.
    func applySegmentRows(generation: Int, attempt: String?, rows: [RecordLogCatchUpRow]) throws -> [RecordLogRecordKey] {
        try assertGeneration(generation)
        if let attempt { try touchReceipt(attempt) }
        let confirmed = try tables.confirmed()
        var touched: [RecordLogRecordKey] = []
        for item in rows {
            let key = RecordLogRecordKey(model: item.model, id: item.id)
            var row = item.row
            row["id"] = .string(item.id)
            try confirmed.set(key, row)
            touched.append(key)
        }
        return touched
    }

    /// Keep one chunk of a segment from the rows the store holds instead of
    /// reading it, under the replacement `generation` as receipt `attempt`. The
    /// rows are kept only when the held segment's marker lists the same object
    /// with the same digest, row count and range, no other receipt attempt is
    /// in progress, and the confirmed rows of that range number exactly `rows`;
    /// otherwise nothing changes and it answers ``RecordLogKeepOutcome/mismatch``,
    /// and the chunk is read. A kept row the room changed after the new segment
    /// began is corrected by its corrections or the pages after them.
    ///
    /// - Throws: ``RecordLogStaleReplacementError`` under a superseded
    ///   generation; ``RecordLogStaleReceiptError`` for an attempt no longer in progress.
    func keepSegmentChunk(
        generation: Int, attempt: String, object: String, sha256: String, model: String, firstId: String, lastId: String,
        rows: Int
    ) throws -> RecordLogKeepOutcome {
        try assertGeneration(generation)
        let receiving = try receiptTables()
        guard let state = try receiving.receipts(), state.attempts.contains(where: { $0.attempt == attempt }) else {
            throw RecordLogStaleReceiptError(attempt: attempt)
        }
        let entry = try receiving.heldSegment()?.chunks.first { $0.object == object }
        let same = entry.map {
            $0.model == model && $0.sha256 == sha256 && $0.rows == rows && $0.firstId == firstId && $0.lastId == lastId
        } ?? false
        // Another attempt's committed chunks may hold rows the room does not.
        let alone = state.attempts.allSatisfy { $0.attempt == attempt }
        guard same, alone, try receiving.keepConfirmedRange(model: model, firstId: firstId, lastId: lastId, rows: rows) else {
            return .mismatch
        }
        try touchReceipt(attempt)
        return .kept(rows: rows, ranges: [RecordLogIdRange(model: model, firstId: firstId, lastId: lastId)])
    }

    /// Apply a segment's corrections under the replacement `generation`: a row
    /// replaces the record's, a `nil` deletes it (one the chunks did not carry
    /// changes nothing).
    func applySegmentCorrections(generation: Int, attempt: String?, lines: [RecordLogCorrection]) throws -> [RecordLogRecordKey] {
        try assertGeneration(generation)
        if let attempt { try touchReceipt(attempt) }
        let confirmed = try tables.confirmed()
        var touched: [RecordLogRecordKey] = []
        for line in lines {
            let key = RecordLogRecordKey(model: line.model, id: line.id)
            if var row = line.row {
                row["id"] = .string(line.id)
                try confirmed.set(key, row)
            } else {
                guard try confirmed.row(key) != nil else { continue }
                try confirmed.delete(key)
            }
            touched.append(key)
        }
        return touched
    }

    /// A whole catch-up in one call: begin, one page, complete.
    func catchUp(
        _ input: RecordLogCatchUpInput, lsn: Int, high: Int?,
        notice: (current: Int, next: Int?, entries: Int?)? = nil,
        constraints: [RecordLogConstraint]? = nil
    ) throws -> RecordLogReceiveOutcome {
        try beginCatchUp(full: input.full)
        let page = try applyCatchUpPage(input)
        var out = try completeCatchUp(lsn: lsn, high: high, full: input.full)
        out.touched.append(contentsOf: page)
        if let notice { try self.notice(current: notice.current, next: notice.next, entries: notice.entries) }
        if let constraints { try tables.setConstraints(constraints) }
        return out
    }
}

/// A client's state in memory: what a replay of the golden traces drives.
final class RecordLogMemoryTables: RecordLogReceiptTables {
    private var cursorValue: Int
    private var epochValue: RecordLogEpochs
    private var constraintList: [RecordLogConstraint] = []
    private(set) var rows = RecordLogMapRowTable()
    /// The records a full replacement has put, in the order it put them.
    private var replaced: [RecordLogRecordKey]?
    private var replacingSet = Set<RecordLogRecordKey>()
    /// The records interrupted replacements put since the last completion: not of the confirmed generation.
    private var interruptedSet = Set<RecordLogRecordKey>()
    /// Counts the replacements begun; the one in progress is the latest.
    private var generationValue = 0
    private var receiptValue: RecordLogReceiptState?
    private var heldValue: RecordLogHeldSegment?
    /// Per receipt attempt, the records its load's chunks named.
    private var loadKeys: [String: Set<RecordLogRecordKey>] = [:]
    private var held: [Int: RecordLogResult] = [:]
    private var writerOrder: [String] = []
    private var writers: [String: Writer] = [:]
    private var counts: [Int: Int] = [:]

    private struct Writer {
        var nextSeq = 1
        var resumedAt = 0
        var pending: [RecordLogPendingEntry] = []
        var handled: [RecordLogRecordKey: [Int: Int]] = [:]
    }

    init(
        rows: [(RecordLogRecordKey, RecordLogRow)] = [], cursor: Int = 0,
        open: Int = RecordLogTransport.firstEpoch, grant: Int = RecordLogTransport.firstEpoch + 1,
        entries: Int = RecordLogTransport.defaultEpochEntries, writers: [String] = []
    ) {
        self.cursorValue = cursor
        self.epochValue = RecordLogEpochs(open: open, grant: grant, entries: entries)
        self.rows = RecordLogMapRowTable(rows)
        for writer in writers { _ = writerOf(writer) }
    }

    private func writerOf(_ writer: String) -> Writer {
        if let found = writers[writer] { return found }
        writers[writer] = Writer()
        writerOrder.append(writer)
        return writers[writer]!
    }

    private func update(_ writer: String, _ body: (inout Writer) -> Void) {
        var w = writerOf(writer)
        body(&w)
        writers[writer] = w
    }

    func cursor() -> Int { cursorValue }
    func setCursor(_ cursor: Int) { cursorValue = cursor }
    func epochs() -> RecordLogEpochs { epochValue }
    func setEpochs(_ epochs: RecordLogEpochs) { epochValue = epochs }
    func constraints() -> [RecordLogConstraint] { constraintList }
    func setConstraints(_ constraints: [RecordLogConstraint]) { constraintList = constraints }

    func confirmed() -> RecordLogRowTable {
        guard replaced != nil else { return rows }
        return ReplacingTable(owner: self)
    }

    /// The confirmed rows while a full replacement is under way: a row put is
    /// remembered, in order, as one the replacement keeps.
    private final class ReplacingTable: RecordLogRowTable {
        let owner: RecordLogMemoryTables
        init(owner: RecordLogMemoryTables) { self.owner = owner }
        func row(_ key: RecordLogRecordKey) -> RecordLogRow? { owner.rows.row(key) }
        func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) {
            if owner.replacingSet.insert(key).inserted { owner.replaced?.append(key) }
            owner.rows.set(key, row)
        }
        func delete(_ key: RecordLogRecordKey) { owner.rows.delete(key) }
        func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) -> String? {
            owner.rows.holder(model: model, fields: fields, values: values, excluding: excluding)
        }
    }

    func beginReplace() {
        // A row an interrupted attempt put stays unconfirmed, as its generation does in the store.
        interruptedSet.formUnion(replacingSet)
        replaced = []
        replacingSet = []
        generationValue += 1
    }

    func replacing() -> Int? { replaced == nil ? nil : generationValue }

    func receipts() -> RecordLogReceiptState? { receiptValue }
    func setReceipts(_ state: RecordLogReceiptState?) { receiptValue = state }

    func noteLoadKeys(_ attempt: String, _ keys: [RecordLogRecordKey]) {
        loadKeys[attempt, default: []].formUnion(keys)
    }

    func removeUnnamed(_ attempt: String, models: [String]) -> [RecordLogRecordKey] {
        let named = loadKeys[attempt] ?? []
        let covered = Set(models)
        let removed = rows.order.filter { covered.contains($0.model) && !named.contains($0) }
        for key in removed { rows.delete(key) }
        return removed
    }

    func forgetLoad(_ attempt: String) { loadKeys[attempt] = nil }

    func heldSegment() -> RecordLogHeldSegment? { heldValue }
    func setHeldSegment(_ segment: RecordLogHeldSegment?) { heldValue = segment }

    func keepConfirmedRange(model: String, firstId: String, lastId: String, rows: Int) -> Bool {
        guard replaced != nil else { return false }
        let within = self.rows.order.filter { key in
            key.model == model && !replacingSet.contains(key) && !interruptedSet.contains(key)
                && RecordLogChunkReader.compareIds(key.id, firstId) >= 0 && RecordLogChunkReader.compareIds(key.id, lastId) <= 0
        }
        guard within.count == rows else { return false }
        // Kept in the chunk's order, as reading it would have put them.
        for key in within.sorted(by: { RecordLogChunkReader.compareIds($0.id, $1.id) < 0 }) {
            replacingSet.insert(key)
            replaced?.append(key)
        }
        return true
    }

    func keepLoads(_ attempts: [String]) {
        let kept = Set(attempts)
        loadKeys = loadKeys.filter { kept.contains($0.key) }
    }

    /// The receipt attempts whose load keys are kept: a check that none outlives its receipt.
    var loadKeyAttempts: [String] { loadKeys.keys.sorted() }

    func completeReplace() -> [RecordLogRecordKey] {
        let kept = replaced ?? []
        let keptSet = replacingSet
        replaced = nil
        replacingSet = []
        interruptedSet = []
        // The room's table, in the room's order: the rows the replacement put.
        let next = RecordLogMapRowTable()
        for key in kept { if let row = rows.row(key) { next.set(key, row) } }
        let removed = rows.order.filter { !keptSet.contains($0) }
        rows = next
        return removed
    }

    func buffered(_ l: Int) -> RecordLogResult? { held[l] }
    func buffer(_ item: RecordLogResult) { held[item.l] = item }
    func dropBufferedThrough(_ l: Int) { held = held.filter { $0.key > l } }

    func isWriter(_ writer: String) -> Bool { writers[writer] != nil }

    func writerState(_ writer: String) -> RecordLogWriterState {
        let w = writerOf(writer)
        return RecordLogWriterState(nextSeq: w.nextSeq, resumedAt: w.resumedAt)
    }

    func setWriterState(_ writer: String, _ state: RecordLogWriterState) {
        update(writer) {
            $0.nextSeq = state.nextSeq
            $0.resumedAt = state.resumedAt
        }
    }

    func pending(_ writer: String) -> [RecordLogPendingEntry] { writers[writer]?.pending ?? [] }

    func putPending(_ writer: String, _ entry: RecordLogPendingEntry) {
        update(writer) { w in
            if let at = w.pending.firstIndex(where: { $0.seq == entry.seq }) {
                w.pending[at] = entry
            } else {
                w.pending.append(entry)
                w.pending.sort { $0.seq < $1.seq }
            }
        }
    }

    func deletePending(_ writer: String, _ seq: Int) {
        guard writers[writer] != nil else { return }
        update(writer) { $0.pending.removeAll { $0.seq == seq } }
    }

    func acknowledgedThrough(_ l: Int) -> [RecordLogEntryRef] {
        var out: [RecordLogEntryRef] = []
        for writer in writerOrder {
            for entry in writers[writer]?.pending ?? [] {
                if let acked = entry.acked, acked <= l { out.append(RecordLogEntryRef(writer: writer, seq: entry.seq)) }
            }
        }
        return out
    }

    /// The table the app reads: confirmed rows with every unwithdrawn pending
    /// entry of the store applied as a guess, in `seq` order per writer.
    func view() throws -> RecordLogMapRowTable {
        let table = rows.clone()
        for writer in writerOrder {
            for entry in writers[writer]?.pending ?? [] where !entry.isVoid {
                try recordLogApplyGuess(table, entry)
            }
        }
        return table
    }

    func handled(_ writer: String, _ key: RecordLogRecordKey) -> [Int: Int] {
        writers[writer]?.handled[key] ?? [:]
    }

    func setHandled(_ writer: String, _ key: RecordLogRecordKey, from: Int, until: Int) {
        update(writer) { $0.handled[key, default: [:]][from] = until }
    }

    func epochCount(_ e: Int) -> Int { counts[e] ?? 0 }
    func countEpoch(_ e: Int) { counts[e, default: 0] += 1 }

    func pendingInEpoch(_ e: Int) -> Int {
        writers.values.reduce(0) { total, w in
            total + w.pending.filter { !$0.isVoid && $0.e == e }.count
        }
    }
}
