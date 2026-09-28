import Foundation

/// The client-side record store of a large document (#3436).
///
/// A format-2 document's authoritative content is a persisted SQLite `records`
/// table, and this is the client's copy of it — the "merged view" — folded
/// from the base snapshot plus every epoch overlay since. A port of
/// `packages/js-bao/src/models/format2RecordStore.ts`, with the same table
/// shapes, the same statements and the same semantics, because a database
/// written by either client has to read on the other.
///
/// **No migrations.** The JS store carries a column-by-column upgrade path for
/// databases written by earlier builds. Swift has never shipped a format-2
/// table, so there is no earlier build and no database to migrate: the DDL
/// creates the current shape and that is the only shape that exists. Adding
/// the migrations anyway would be code no test could reach.
///
/// Every method is synchronous and runs inside the host's serial queue; the
/// store never holds the connection, it borrows it per call.
public final class Format2RecordStore: @unchecked Sendable {

    private let host: Format2SqlHost
    private let docId: String
    private let clientId: String
    private let tables: Format2TableNames
    private let statements: OverlayFold.Statements

    /// Memoized hydration scope. `nil` scope means "the whole document",
    /// which is also the un-loaded state, so the loaded FLAG is separate.
    private let scopeLock = NSLock()
    private var scope: [String]?
    private var scopeLoaded = false

    /// The offline window's two numbers, in memory (#3437, behavior 2).
    ///
    /// Every local write is checked against them, and the write path is the
    /// intent's declared hot path — so the check reads this pair rather than
    /// the `_epoch` row. They change only when a frame arrives, which is where
    /// the mirror is refreshed from; it is seeded by ``initialize()``, so a
    /// write never pays a lazy first read either.
    ///
    /// Per store INSTANCE, which is per open document per client. A second
    /// instance over the same file (documented as one process per database)
    /// keeps its own, refreshed by its own frames: the window is about the
    /// contact THIS client had with the server.
    private let windowLock = NSLock()
    private var mirroredLastSyncAt: Int?
    private var mirroredWindowDays = Format2OfflineWindow.defaultOfflineWindowDays

    public init(host: Format2SqlHost, documentId: String, clientId: String) {
        self.host = host
        self.docId = documentId
        self.clientId = clientId
        self.tables = Format2TableNames(documentId: documentId)
        self.statements = OverlayFold.Statements(tables: tables)
    }

    /// Where a merged row that just changed is ALSO written: the file-backed
    /// query tables a filtered read answers from (#3436, behavior 13).
    ///
    /// `nil` until a model of this document has been projected, which is what
    /// leaves the fold's cost unchanged for a document nothing queries. Set on
    /// the binding, before any fold can run.
    private let projectionLock = NSLock()
    private var _projection: Format2QueryProjection?
    public var projection: Format2QueryProjection? {
        get { projectionLock.withLock { _projection } }
        set { projectionLock.withLock { _projection = newValue } }
    }

    public var documentId: String { docId }
    public var clientIdentity: String { clientId }
    public var tableNames: Format2TableNames { tables }

    // MARK: - Schema

    /// The DDL, statement for statement as `format2ClientDDL` writes it.
    ///
    /// The per-document tables are scoped by the hex-encoded document id so a
    /// client database can hold several documents at once and the merged view
    /// of one is never readable as another's. The shared tables are keyed by
    /// `doc_id` for the same reason.
    public static func clientDDL(documentId: String) -> [String] {
        let tables = Format2TableNames(documentId: documentId)
        let records = tables.records
        let members = tables.stringSetIndex
        return [
            """
            CREATE TABLE IF NOT EXISTS \(records) (
              _id TEXT NOT NULL,
              _type TEXT NOT NULL,
              _data TEXT NOT NULL,
              PRIMARY KEY (_type, _id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS \(members) (
              _record_id TEXT NOT NULL,
              _type TEXT NOT NULL,
              field TEXT NOT NULL,
              value TEXT NOT NULL,
              UNIQUE(_type, field, _record_id, value)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_\(records)_type ON \(records)(_type)",
            """
            CREATE INDEX IF NOT EXISTS idx_\(members)_tfv \
            ON \(members)(_type, field, value)
            """,
            // `_record_id` DIRECTLY after `_type` (#3688). The fold's
            // per-record member delete — every `_replace`, every tombstone —
            // and the coverage delete both key on that pair; the retired
            // `(_type, field, _record_id)` shape left the planner narrowing on
            // `_type` alone, a walk of the model's whole member table per
            // record. The old name is dropped in `initialize()`, not here, so
            // this list stays creation-only and the object-name pin still
            // parses it.
            """
            CREATE INDEX IF NOT EXISTS idx_\(members)_trf \
            ON \(members)(_type, _record_id, field)
            """,
            """
            CREATE TABLE IF NOT EXISTS _epoch (
              doc_id TEXT PRIMARY KEY,
              epoch INTEGER NOT NULL DEFAULT 0,
              acked_seq INTEGER NOT NULL DEFAULT 0,
              last_sync_at INTEGER,
              window_days INTEGER,
              clock_offset INTEGER,
              hydrated_models TEXT,
              folded_state TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS _pending_ops (
              doc_id TEXT NOT NULL,
              client_id TEXT NOT NULL,
              seq INTEGER NOT NULL,
              model TEXT NOT NULL,
              record_id TEXT NOT NULL,
              op TEXT NOT NULL,
              fields TEXT NOT NULL,
              base_epoch INTEGER NOT NULL,
              ts INTEGER NOT NULL,
              mutation TEXT,
              prior_overlay TEXT,
              from_client_id TEXT,
              from_seq INTEGER,
              PRIMARY KEY (doc_id, client_id, seq)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS _client_acks (
              doc_id TEXT NOT NULL,
              client_id TEXT NOT NULL,
              acked_seq INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (doc_id, client_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS _snapshot_load (
              doc_id TEXT NOT NULL,
              build_id TEXT NOT NULL,
              ordinal INTEGER NOT NULL,
              PRIMARY KEY (doc_id, build_id, ordinal)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS _snapshot_base (
              doc_id TEXT PRIMARY KEY,
              build_id TEXT NOT NULL,
              epoch INTEGER NOT NULL,
              complete INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS _discontinuities (
              doc_id TEXT NOT NULL,
              epoch INTEGER NOT NULL,
              PRIMARY KEY (doc_id, epoch)
            )
            """,
            // The judgement an epoch move owes but has not run (#3437,
            // finding 3437-SO-03). Written in the SAME transaction as the
            // epoch mark, so a restart cannot find the mark moved and the debt
            // forgotten — which is the window in which an outdated write
            // would be restored by the key rule alone and published with
            // recency never asked. One note per document: a second deferral
            // before the first is judged widens the same note.
            """
            CREATE TABLE IF NOT EXISTS _deferred_replay (
              doc_id TEXT PRIMARY KEY,
              through_seq INTEGER NOT NULL,
              from_epoch INTEGER NOT NULL,
              to_epoch INTEGER NOT NULL,
              kind TEXT NOT NULL
            )
            """,
            // Swift-only: which models have been projected into the
            // file-backed query tables, so a reopen projects nothing. The
            // parity dump excludes it by name.
            """
            CREATE TABLE IF NOT EXISTS _query_projection (
              doc_id TEXT NOT NULL,
              model TEXT NOT NULL,
              PRIMARY KEY (doc_id, model)
            )
            """,
        ]
    }

    /// Create the schema and seed this document's epoch row. Idempotent.
    public func initialize() throws {
        try withConnection { connection in
            for statement in Self.clientDDL(documentId: docId) {
                try connection.executeScript(statement)
            }
            // #3688 — the member index `_record_id` moved forward in. Created
            // under a NEW name above (an `IF NOT EXISTS` under the old one is a
            // silent no-op on a database that already has it), so the old one
            // is dropped here. Per document, so another document's index is
            // never touched, and a no-op on a database that never had it.
            try connection.executeScript(
                "DROP INDEX IF EXISTS idx_\(tables.stringSetIndex)_tfr"
            )
            // #3782 — a database written before the folded-state mark existed
            // has `_epoch` without it, and `CREATE TABLE IF NOT EXISTS` leaves
            // such a table as it found it. NULL is what that database knows
            // about its folds: nothing, so its next bind catches up whole and
            // stamps. Guarded, so it runs once per file (#3688's precedent for
            // a post-DDL step in this method).
            let epochColumns = try connection.query("PRAGMA table_info(_epoch)", [])
                .compactMap { $0["name"].stringValue }
            if !epochColumns.isEmpty, !epochColumns.contains("folded_state") {
                try connection.executeScript("ALTER TABLE _epoch ADD COLUMN folded_state TEXT")
            }
            try connection.execute(
                "INSERT OR IGNORE INTO _epoch (doc_id, epoch, acked_seq) VALUES (?, 0, 0)",
                [.text(docId)]
            )
            // Seed the window mirror from the row this document already has,
            // so the first local write reads memory rather than SQL.
            let row = try connection.query(
                "SELECT last_sync_at, window_days FROM _epoch WHERE doc_id = ?",
                [.text(docId)]
            ).first
            windowLock.withLock {
                mirroredLastSyncAt = row?["last_sync_at"].intValue
                mirroredWindowDays = Format2OfflineWindow.configuredOfflineWindowDays(
                    row?["window_days"].intValue
                )
            }
        }
    }

    // MARK: - Hydration scope

    /// Record which models this device holds; `nil` is "the whole document".
    ///
    /// Durable, because a restart reconnects and starts folding the epoch
    /// overlay again — without the scope that fold would quietly repopulate a
    /// skipped model with the handful of records the epoch touched.
    public func setHydrationScope(_ models: [String]?) throws {
        let encoded: Format2SqlValue
        if let models {
            let data = try JSONEncoder().encode(models)
            encoded = .text(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            encoded = .null
        }
        let changed = try hydrationScope() != models
        try withConnection { connection in
            try connection.transaction {
                // #3782 — the folded state names the models it vouches for; a
                // scope that changes which models this device holds changes
                // what a fold of the overlay writes, so nothing is known.
                if changed { try clearFoldedState() }
                try connection.execute(
                    "UPDATE _epoch SET hydrated_models = ? WHERE doc_id = ?",
                    [encoded, .text(docId)]
                )
            }
        }
        scopeLock.withLock {
            scope = models
            scopeLoaded = true
        }
    }

    /// The models this device holds, or `nil` when it holds the document.
    ///
    /// Throws when the row cannot be read, and caches only what a successful
    /// read returned. A suppressed failure here reads as "this device holds
    /// the whole document", which is the one answer that authorizes reads and
    /// folds of every model — and caching it would keep that answer for the
    /// life of the store.
    public func hydrationScope() throws -> [String]? {
        if let cached = scopeLock.withLock({ scopeLoaded ? scope : nil }) { return cached }
        if scopeLock.withLock({ scopeLoaded }) { return nil }

        let raw = try withConnection { connection in
            try connection.query(
                "SELECT hydrated_models FROM _epoch WHERE doc_id = ?", [.text(docId)]
            ).first?["hydrated_models"].stringValue
        }
        var parsed: [String]?
        if let text = raw, let data = text.data(using: .utf8) {
            parsed = try JSONDecoder().decode([String].self, from: data)
        }
        scopeLock.withLock {
            scope = parsed
            scopeLoaded = true
        }
        return parsed
    }

    /// Whether this device holds `model` at all.
    public func isHydrated(_ model: String) throws -> Bool {
        guard let scope = try hydrationScope() else { return true }
        return scope.contains(model)
    }

    /// Refuse a model this device does not hold, rather than answering partly.
    ///
    /// A capped load leaves a model out because the device has no room. The
    /// records it holds of that model afterwards — whatever a later overlay
    /// happened to touch — are not the model, they are a handful of recently
    /// changed rows, and answering a query from them is wrong in the way that
    /// is hardest to notice.
    private func assertHydrated(_ model: String) throws {
        guard !(try isHydrated(model)) else { return }
        throw JsBaoError(
            code: .format2ModelNotHydrated,
            message: "Model \(model) is not available on this device.",
            details: [
                "model": .string(model),
                "hydrated": .array((try hydrationScope() ?? []).map(JSONValue.string)),
            ]
        )
    }

    // MARK: - Reads (the merged view)

    public func read(model: String, recordId: String) throws -> [String: JSONValue]? {
        try assertHydrated(model)
        return try withConnection { connection in
            let rows = try connection.query(
                "SELECT _data FROM \(tables.records) WHERE _type = ? AND _id = ?",
                [.text(model), .text(recordId)]
            )
            guard let data = rows.first?["_data"].stringValue else { return nil }
            return Self.decodeRow(data, id: recordId)
        }
    }

    /// Several records of one model in ONE statement, in the order asked for.
    /// A missing record is `nil` in its slot rather than absent, so the caller
    /// can pair results with ids positionally.
    public func readMany(
        model: String, recordIds: [String]
    ) throws -> [[String: JSONValue]?] {
        try assertHydrated(model)
        guard !recordIds.isEmpty else { return [] }
        let unique = Array(Set(recordIds))
        let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
        let found = try withConnection { connection -> [String: [String: JSONValue]] in
            let rows = try connection.query(
                """
                SELECT _id, _data FROM \(tables.records) \
                WHERE _type = ? AND _id IN (\(placeholders))
                """,
                [.text(model)] + unique.map { Format2SqlValue.text($0) }
            )
            var out: [String: [String: JSONValue]] = [:]
            for row in rows {
                guard let id = row["_id"].stringValue,
                      let data = row["_data"].stringValue else { continue }
                out[id] = Self.decodeRow(data, id: id)
            }
            return out
        }
        return recordIds.map { found[$0] }
    }

    public func readAll(model: String) throws -> [[String: JSONValue]] {
        try assertHydrated(model)
        return try withConnection { connection in
            try connection.query(
                "SELECT _id, _data FROM \(tables.records) WHERE _type = ? ORDER BY _id",
                [.text(model)]
            ).compactMap { row in
                guard let id = row["_id"].stringValue,
                      let data = row["_data"].stringValue else { return nil }
                return Self.decodeRow(data, id: id)
            }
        }
    }

    /// One PAGE of a model's rows, in id order, after `after`.
    ///
    /// A keyset walk rather than an offset: `findAll` on a 2 GB document has
    /// to be bounded by what is resident, not by how far in it has read.
    public func readRowsAfter(
        model: String, after: String?, limit: Int
    ) throws -> [[String: JSONValue]] {
        try assertHydrated(model)
        return try withConnection { connection in
            let rows: [Format2SqlRow]
            if let after {
                rows = try connection.query(
                    """
                    SELECT _id, _data FROM \(tables.records) \
                    WHERE _type = ? AND _id > ? ORDER BY _id LIMIT ?
                    """,
                    [.text(model), .text(after), .integer(Int64(limit))]
                )
            } else {
                rows = try connection.query(
                    """
                    SELECT _id, _data FROM \(tables.records) \
                    WHERE _type = ? ORDER BY _id LIMIT ?
                    """,
                    [.text(model), .integer(Int64(limit))]
                )
            }
            return rows.compactMap { row in
                guard let id = row["_id"].stringValue,
                      let data = row["_data"].stringValue else { return nil }
                return Self.decodeRow(data, id: id)
            }
        }
    }

    public func recordIds(model: String) throws -> [String] {
        try assertHydrated(model)
        return try withConnection { connection in
            try connection.query(
                "SELECT _id FROM \(tables.records) WHERE _type = ? ORDER BY _id",
                [.text(model)]
            ).compactMap { $0["_id"].stringValue }
        }
    }

    public func recordIdsAfter(
        model: String, after: String?, limit: Int
    ) throws -> [String] {
        try assertHydrated(model)
        return try withConnection { connection in
            let rows: [Format2SqlRow]
            if let after {
                rows = try connection.query(
                    """
                    SELECT _id FROM \(tables.records) \
                    WHERE _type = ? AND _id > ? ORDER BY _id LIMIT ?
                    """,
                    [.text(model), .text(after), .integer(Int64(limit))]
                )
            } else {
                rows = try connection.query(
                    "SELECT _id FROM \(tables.records) WHERE _type = ? ORDER BY _id LIMIT ?",
                    [.text(model), .integer(Int64(limit))]
                )
            }
            return rows.compactMap { $0["_id"].stringValue }
        }
    }

    /// The id of the first record whose fields all match — the merged-view
    /// answer to `upsertOn` resolution and to a unique-constraint check. A
    /// base-only holder is found here and nowhere in the epoch doc, which is
    /// the whole point.
    public func findIdByFields(
        model: String, fields: [String], values: [JSONValue]
    ) throws -> String? {
        try assertHydrated(model)
        guard !fields.isEmpty else { return nil }
        let predicates = fields
            .map { _ in "json_extract(_data, '$.' || ?) IS ?" }
            .joined(separator: " AND ")
        var bindings: [Format2SqlValue] = [.text(model)]
        for (index, field) in fields.enumerated() {
            bindings.append(.text(field))
            bindings.append(Format2SqlValue(json: values[index]))
        }
        return try withConnection { connection in
            try connection.query(
                """
                SELECT _id FROM \(tables.records) \
                WHERE _type = ? AND \(predicates) ORDER BY _id LIMIT 1
                """,
                bindings
            ).first?["_id"].stringValue
        }
    }

    /// The members of one record's stringset field, in rowid order.
    public func members(model: String, recordId: String, field: String) throws -> [String] {
        try withConnection { connection in
            try connection.query(
                statements.selectMembers, [.text(model), .text(recordId), .text(field)]
            ).compactMap { $0["value"].stringValue }
        }
    }

    // MARK: - The fold

    /// Fold one record's overlay entry into the merged view.
    ///
    /// A model this device does not hold is SKIPPED, not refused: an arriving
    /// update is not a caller asking a question, and refusing it would break
    /// the document rather than bound it.
    public func applyRemote(model: String, entry: OverlayRecordEntry) throws {
        guard try isHydrated(model) else { return }
        try withConnection { connection in
            // One transaction, so the merged row and its projected row land
            // together even when this is a single record's fold rather than a
            // whole batch. Nesting inside a batch's transaction is free.
            try connection.transaction {
                try OverlayFold.project(
                    connection, model: model, entry: entry, statements: statements
                )
                try projection?.projectRow(model: model, recordId: entry.id, in: self)
            }
        }
    }

    /// Run `body` as ONE commit. A catch-up fold of a whole overlay is a
    /// single transaction rather than one per record — the difference between
    /// one commit and thousands.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withConnection { connection in
            try connection.transaction(body)
        }
    }

    // MARK: - Local writes

    /// Commit a LOCAL write: the merged row and the pending op land together
    /// or neither does. The returned sequence is what an `update.ack` prunes
    /// against.
    ///
    /// The mutation is stored, not just the field names it touched, because
    /// the merged row cannot reproduce it: materializing a row loses the
    /// difference between a patch and a `_replace` create, turns an explicit
    /// null unset into an absent key, and drops stringset member tombstones.
    /// Those shapes survive only in the overlay — and the overlay's own
    /// persistence is a Yjs update flushed asynchronously AFTER this commit,
    /// so a crash in between would otherwise leave a pending op whose write
    /// nothing could reconstruct.
    @discardableResult
    public func commitLocalWrite(
        model: String,
        mutation: OverlayMutation,
        pending: PendingOpInput
    ) throws -> Int {
        try assertHydrated(model)
        let seq = try pending.seq ?? nextSeq()
        let entry = OverlayKeys.group(OverlayKeys.encode(mutation))[ByteKey(mutation.id)]
            ?? OverlayRecordEntry(id: mutation.id)

        let fieldsJSON = try Self.encodeJSON(pending.fields.map(JSONValue.string))
        let mutationJSON = try Self.encodeJSON(mutation.storedJSON)
        let priorJSON: Format2SqlValue = try pending.priorOverlay.map {
            .text(try Self.encodeJSON(JSONValue.object($0)))
        } ?? .null

        try withConnection { connection in
            try connection.transaction {
                try OverlayFold.project(
                    connection, model: model, entry: entry, statements: statements
                )
                try projection?.projectRow(model: model, recordId: entry.id, in: self)
                // INSERT OR REPLACE: a write in flight when a document is
                // rebound can be replayed with the sequence its sender
                // pinned, so the same command may execute twice. The row
                // projection is already idempotent (an overlay entry is
                // state); this makes the log entry so too.
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO _pending_ops
                      (doc_id, client_id, seq, model, record_id, op, fields, base_epoch, ts,
                       mutation, prior_overlay)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(docId), .text(clientId), .integer(Int64(seq)),
                        .text(pending.model), .text(pending.recordId),
                        .text(pending.op.rawValue), .text(fieldsJSON),
                        .integer(Int64(pending.baseEpoch)), .integer(Int64(pending.ts)),
                        .text(mutationJSON), priorJSON,
                    ]
                )
            }
        }
        return seq
    }

    // MARK: - Pending ops and durable acknowledgement

    /// The next local sequence: one past the highest ever issued BY THIS
    /// CLIENT. The ack is a floor as well as the pending rows, because a prune
    /// removes the rows and `MAX(seq)` alone would then re-issue sequences the
    /// server already has.
    public func nextSeq() throws -> Int {
        try withConnection { connection in
            let highest = try connection.query(
                """
                SELECT COALESCE(MAX(seq), 0) AS v FROM _pending_ops \
                WHERE doc_id = ? AND client_id = ?
                """,
                [.text(docId), .text(clientId)]
            ).first?["v"].intValue ?? 0
            let acked = try connection.query(
                "SELECT acked_seq AS v FROM _client_acks WHERE doc_id = ? AND client_id = ?",
                [.text(docId), .text(clientId)]
            ).first?["v"].intValue ?? 0
            return max(highest, acked) + 1
        }
    }

    /// The highest sequence this client has committed locally — what an
    /// outbound update frame claims, and what an `update.ack` has to reach
    /// before the document has nothing unsynced left.
    public func highestLocalSeq() throws -> Int { try nextSeq() - 1 }

    public func pendingOps() throws -> [PendingOp] {
        try withConnection { connection in
            try connection.query(
                """
                SELECT client_id, seq, model, record_id, op, fields, base_epoch, ts, \
                mutation, prior_overlay \
                FROM _pending_ops WHERE doc_id = ? AND client_id = ? ORDER BY seq
                """,
                [.text(docId), .text(clientId)]
            ).compactMap(PendingOp.init(row:))
        }
    }

    /// Prune at or below the server's contiguous-sequence high-water mark.
    /// A lower (out-of-order or replayed) ack never lowers the mark and never
    /// resurrects a pruned op.
    public func prunePendingOps(maxContiguousSeq: Int) throws {
        guard try maxContiguousSeq > ackedSeq() else { return }
        try withConnection { connection in
            try connection.transaction {
                try connection.execute(
                    "DELETE FROM _pending_ops WHERE doc_id = ? AND client_id = ? AND seq <= ?",
                    [.text(docId), .text(clientId), .integer(Int64(maxContiguousSeq))]
                )
                try connection.execute(
                    """
                    INSERT INTO _client_acks (doc_id, client_id, acked_seq) VALUES (?, ?, ?)
                    ON CONFLICT (doc_id, client_id) DO UPDATE SET acked_seq = excluded.acked_seq
                    """,
                    [.text(docId), .text(clientId), .integer(Int64(maxContiguousSeq))]
                )
            }
        }
    }

    /// Take over every pending row another client id left behind (#3437,
    /// behavior 4).
    ///
    /// Swift mints its client id per `JsBaoClient` instance and never persists
    /// it, so after a relaunch the previous instance's unacknowledged writes
    /// are rows this client cannot see — `pendingOps()` filters by id. Without
    /// adoption they are never carried, never replayed and never acknowledged
    /// (finding 3437-R02).
    ///
    /// Every foreign client is treated as GONE. That is Node's rule and the
    /// right one here: one process per database file, so a row under another
    /// id belongs to a session that has ended. (Two `JsBaoClient` instances in
    /// one process over one file is edge E6 — the second adopts the first's
    /// ops, documented rather than prevented.)
    ///
    /// Re-keyed with FRESH sequences above this client's own, in
    /// `(client_id, seq)` order, recording where each came from. Nothing else
    /// moves: the old client's `_client_acks` row is a fact about a session
    /// that is gone, and rewriting it would tell this client the server had
    /// acknowledged sequences it has never sent.
    @discardableResult
    public func adoptOrphanedPendingOps() throws -> [AdoptedOp] {
        try withConnection { connection in
            let foreign = try connection.query(
                """
                SELECT client_id, seq, model, record_id, op, fields, base_epoch, ts, \
                mutation, prior_overlay \
                FROM _pending_ops WHERE doc_id = ? AND client_id <> ? \
                ORDER BY client_id, seq
                """,
                [.text(docId), .text(clientId)]
            )
            // One query for a client with nothing to adopt, which is the
            // ordinary case on every open after the first.
            guard !foreign.isEmpty else { return [] }

            var next = try nextSeqLocked(connection)
            var adopted: [AdoptedOp] = []
            try connection.transaction {
                for row in foreign {
                    guard let op = PendingOp(row: row),
                          let fromClientId = row["client_id"].stringValue
                    else { continue }
                    let seq = next
                    next += 1
                    try connection.execute(
                        """
                        INSERT OR REPLACE INTO _pending_ops
                          (doc_id, client_id, seq, model, record_id, op, fields,
                           base_epoch, ts, mutation, prior_overlay,
                           from_client_id, from_seq)
                        SELECT ?, ?, ?, model, record_id, op, fields, base_epoch, ts,
                               mutation, prior_overlay, ?, seq
                        FROM _pending_ops
                        WHERE doc_id = ? AND client_id = ? AND seq = ?
                        """,
                        [
                            .text(docId), .text(clientId), .integer(Int64(seq)),
                            .text(fromClientId), .text(docId), .text(fromClientId),
                            .integer(Int64(op.seq)),
                        ]
                    )
                    try connection.execute(
                        """
                        DELETE FROM _pending_ops \
                        WHERE doc_id = ? AND client_id = ? AND seq = ?
                        """,
                        [.text(docId), .text(fromClientId), .integer(Int64(op.seq))]
                    )
                    adopted.append(AdoptedOp(
                        op: PendingOp(
                            seq: seq, model: op.model, recordId: op.recordId,
                            op: op.op, fields: op.fields, baseEpoch: op.baseEpoch,
                            ts: op.ts, mutation: op.mutation,
                            priorOverlay: op.priorOverlay
                        ),
                        fromClientId: fromClientId,
                        fromSeq: op.seq
                    ))
                }
            }
            return adopted
        }
    }

    /// ``nextSeq()`` on a connection the caller already holds.
    private func nextSeqLocked(_ connection: any Format2SqlConnection) throws -> Int {
        let highest = try connection.query(
            """
            SELECT COALESCE(MAX(seq), 0) AS v FROM _pending_ops \
            WHERE doc_id = ? AND client_id = ?
            """,
            [.text(docId), .text(clientId)]
        ).first?["v"].intValue ?? 0
        let acked = try connection.query(
            "SELECT acked_seq AS v FROM _client_acks WHERE doc_id = ? AND client_id = ?",
            [.text(docId), .text(clientId)]
        ).first?["v"].intValue ?? 0
        return max(highest, acked) + 1
    }

    /// Forget these sequences: the judgement dropped them (#3437, behavior 20).
    public func forgetPendingOps(_ sequences: [Int]) throws {
        guard !sequences.isEmpty else { return }
        try withConnection { connection in
            try connection.transaction {
                for seq in sequences {
                    try connection.execute(
                        """
                        DELETE FROM _pending_ops \
                        WHERE doc_id = ? AND client_id = ? AND seq = ?
                        """,
                        [.text(docId), .text(clientId), .integer(Int64(seq))]
                    )
                }
            }
        }
    }

    /// Rewrite a pending op to the part of it that survived a judgement
    /// (#3437, behavior 20). The durable row has to agree with what was
    /// stated, or a later restore would put the dropped half back.
    public func narrowPendingOps(
        _ narrowed: [(seq: Int, fields: [String], mutation: OverlayMutation)]
    ) throws {
        guard !narrowed.isEmpty else { return }
        try withConnection { connection in
            try connection.transaction {
                for entry in narrowed {
                    try connection.execute(
                        """
                        UPDATE _pending_ops SET fields = ?, mutation = ? \
                        WHERE doc_id = ? AND client_id = ? AND seq = ?
                        """,
                        [
                            .text(try Self.encodeJSON(
                                entry.fields.map(JSONValue.string)
                            )),
                            .text(try Self.encodeJSON(entry.mutation.storedJSON)),
                            .text(docId), .text(clientId), .integer(Int64(entry.seq)),
                        ]
                    )
                }
            }
        }
    }

    public func ackedSeq() throws -> Int {
        try withConnection { connection in
            try connection.query(
                "SELECT acked_seq AS v FROM _client_acks WHERE doc_id = ? AND client_id = ?",
                [.text(docId), .text(clientId)]
            ).first?["v"].intValue ?? 0
        }
    }

    // MARK: - Epoch and sync bookkeeping

    /// The epoch this client's merged view is folded up to.
    ///
    /// Throws rather than answering zero when the row cannot be read: zero is
    /// "this device is cold", which the handshake acts on and a pending op
    /// records as the epoch it was written against. A failed read is not a
    /// cold device.
    public func epoch() throws -> Int {
        try withConnection { connection in
            try connection.query(
                "SELECT epoch AS v FROM _epoch WHERE doc_id = ?", [.text(docId)]
            ).first?["v"].intValue ?? 0
        }
    }

    public func setEpoch(_ epoch: Int) throws {
        try withConnection { connection in
            try connection.transaction {
                // #3782 — another epoch is another Y.Doc, with client ids of
                // its own; a vector measured against the old one says nothing
                // about the new one.
                if try self.epoch() != epoch { try clearFoldedState() }
                try connection.execute(
                    "UPDATE _epoch SET epoch = ? WHERE doc_id = ?",
                    [.integer(Int64(epoch)), .text(docId)]
                )
            }
        }
    }

    // MARK: - What the store last folded (#3782)

    /// The overlay state the merged view was last folded from, or `nil` when
    /// nothing is known — a database written before this, or one whose rows
    /// were just replaced from another source.
    ///
    /// What it vouches for: for every model in `models`, every overlay item of
    /// that model's map below `vector` has been folded into the records AND
    /// projected into the query tables (the fold projects in the same
    /// transaction on this client).
    public func foldedState() throws -> FoldedState? {
        try withConnection { connection in
            FoldedState.decode(
                try connection.query(
                    "SELECT folded_state FROM _epoch WHERE doc_id = ?", [.text(docId)]
                ).first?["folded_state"].stringValue
            )
        }
    }

    /// Record that a fold certified `state`. Called INSIDE the transaction of
    /// the fold it vouches for.
    ///
    /// Merged per client by MAX with the models unioned, but only while the
    /// overlay that folded, at `docState`, is at or ahead of the stored vector
    /// on every client (the guard the JS client applies). A store that knows
    /// nothing is stamped only by a fold of whole model maps (`whole`): an
    /// incremental fold wrote its own keys and says nothing about the rest.
    ///
    /// - Returns: whether the state was written.
    @discardableResult
    public func noteFoldedState(
        _ state: FoldedState, docState: [String: Int], whole: Bool
    ) throws -> Bool {
        try withConnection { connection in
            let held = try foldedState()
            if held == nil && !whole { return false }
            if let held, !FoldedState.isAtOrAhead(docState, of: held.vector) { return false }
            let merged = held.map { $0.merged(with: state) } ?? state
            try connection.execute(
                "UPDATE _epoch SET folded_state = ? WHERE doc_id = ?",
                [.text(merged.encoded()), .text(docId)]
            )
            return true
        }
    }

    /// Write `state` as it is, dropping whatever was stored. For a fold that
    /// knows exactly which models it certifies through its vector, when the
    /// max-merge would carry a model it did not fold forward (finding
    /// 3782-C04). Called inside the fold's transaction.
    func replaceFoldedState(_ state: FoldedState) throws {
        try withConnection { connection in
            try connection.execute(
                "UPDATE _epoch SET folded_state = ? WHERE doc_id = ?",
                [.text(state.encoded()), .text(docId)]
            )
        }
    }

    /// Nothing is known about what the merged view was folded from.
    public func clearFoldedState() throws {
        try withConnection { connection in
            try connection.execute(
                "UPDATE _epoch SET folded_state = NULL WHERE doc_id = ?", [.text(docId)]
            )
        }
    }

    public func lastSyncAt() throws -> Int? {
        try withConnection { connection in
            try connection.query(
                "SELECT last_sync_at FROM _epoch WHERE doc_id = ?", [.text(docId)]
            ).first?["last_sync_at"].intValue
        }
    }

    /// Record that this client was in touch with the server, and (when the
    /// server said so) the window it is held to. Persisted together because
    /// the session that enforces the window is the one that cannot ask for it:
    /// a client that starts offline reads both back out of its own database.
    public func noteSync(at: Int, windowDays: Int? = nil) throws {
        windowLock.withLock {
            mirroredLastSyncAt = at
            if let windowDays {
                mirroredWindowDays =
                    Format2OfflineWindow.configuredOfflineWindowDays(windowDays)
            }
        }
        try withConnection { connection in
            if let windowDays {
                try connection.execute(
                    "UPDATE _epoch SET last_sync_at = ?, window_days = ? WHERE doc_id = ?",
                    [
                        .integer(Int64(at)),
                        .integer(Int64(Self.configuredWindowDays(windowDays))),
                        .text(docId),
                    ]
                )
            } else {
                try connection.execute(
                    "UPDATE _epoch SET last_sync_at = ? WHERE doc_id = ?",
                    [.integer(Int64(at)), .text(docId)]
                )
            }
        }
    }

    /// Record the window WITHOUT claiming a sync.
    ///
    /// The handshake carries the window whatever else it says, including to a
    /// client that is behind by whole epochs and cannot act on the rest of the
    /// frame. Taking the number is right there; moving the mark it is measured
    /// FROM is not — a frame is proof of contact, not proof that this client's
    /// merged view is the room's state.
    public func noteOfflineWindow(_ windowDays: Int?) throws {
        guard let windowDays else { return }
        windowLock.withLock {
            mirroredWindowDays =
                Format2OfflineWindow.configuredOfflineWindowDays(windowDays)
        }
        try withConnection { connection in
            try connection.execute(
                "UPDATE _epoch SET window_days = ? WHERE doc_id = ?",
                [.integer(Int64(Self.configuredWindowDays(windowDays))), .text(docId)]
            )
        }
    }

    public func offlineWindowDays() throws -> Int {
        let stored = try withConnection { connection in
            try connection.query(
                "SELECT window_days FROM _epoch WHERE doc_id = ?", [.text(docId)]
            ).first?["window_days"].intValue
        }
        return Self.configuredWindowDays(stored ?? Self.defaultOfflineWindowDays)
    }

    /// Where this document stands relative to its window, read from the
    /// in-memory mirror (#3437, behavior 2).
    ///
    /// No SQL: this runs once per local write, on the declared hot path, and
    /// the numbers it needs move only when a frame arrives.
    public func offlineWindowStatus(now: Int) -> OfflineWindowStatus {
        let (mark, days) = windowLock.withLock {
            (mirroredLastSyncAt, mirroredWindowDays)
        }
        return Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: mark, windowDays: days, now: now
        )
    }

    /// How far this client's clock is behind the server's, in milliseconds.
    /// Zero until one has been measured — which is why ``clockOffsetKnown()``
    /// exists separately: a measured zero and never having measured are the
    /// same number and very different facts.
    public func clockOffset() throws -> Int {
        try storedClockOffset() ?? 0
    }

    public func clockOffsetKnown() throws -> Bool {
        try storedClockOffset() != nil
    }

    private func storedClockOffset() throws -> Int? {
        try withConnection { connection in
            try connection.query(
                "SELECT clock_offset FROM _epoch WHERE doc_id = ?", [.text(docId)]
            ).first?["clock_offset"].intValue
        }
    }

    public func noteClockOffset(_ offsetMs: Int) throws {
        try withConnection { connection in
            try connection.execute(
                "UPDATE _epoch SET clock_offset = ? WHERE doc_id = ?",
                [.integer(Int64(offsetMs)), .text(docId)]
            )
        }
    }

    /// Now, on the server's clock as far as this client can tell.
    public func correctedNow(
        _ now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) throws -> Int {
        now + (try clockOffset())
    }

    // MARK: - Snapshot load marks

    /// Begin loading a base: record which build and epoch this device is
    /// installing, incomplete until every chunk lands.
    ///
    /// The same call drops the load marks of every OTHER build, which are
    /// progress on a load nothing will ever finish — and which, left behind,
    /// are marks a later build could collide with on an ordinal and skip a
    /// chunk for.
    public func beginBase(buildId: String, epoch: Int) throws {
        try withConnection { connection in
            try connection.transaction {
                try connection.execute(
                    """
                    INSERT INTO _snapshot_base (doc_id, build_id, epoch, complete)
                    VALUES (?, ?, ?, 0)
                    ON CONFLICT (doc_id) DO UPDATE SET
                      build_id = excluded.build_id, epoch = excluded.epoch, complete = 0
                    """,
                    [.text(docId), .text(buildId), .integer(Int64(epoch))]
                )
                try connection.execute(
                    "DELETE FROM _snapshot_load WHERE doc_id = ? AND build_id <> ?",
                    [.text(docId), .text(buildId)]
                )
            }
        }
    }

    /// The base this device holds, and whether its load finished.
    public func baseState() throws -> (buildId: String, epoch: Int, complete: Bool)? {
        try withConnection { connection in
            guard let row = try connection.query(
                "SELECT build_id, epoch, complete FROM _snapshot_base WHERE doc_id = ?",
                [.text(docId)]
            ).first, let buildId = row["build_id"].stringValue else { return nil }
            return (buildId, row["epoch"].intValue ?? 0, (row["complete"].intValue ?? 0) != 0)
        }
    }

    public func completeBase(buildId: String) throws {
        try withConnection { connection in
            try connection.execute(
                "UPDATE _snapshot_base SET complete = 1 WHERE doc_id = ? AND build_id = ?",
                [.text(docId), .text(buildId)]
            )
        }
    }

    /// Where this store's database file lives, for the storage probe
    /// (#3437, behavior 33). `nil` for a host with no file.
    public var databaseDirectory: String? { host.databaseDirectory }

    /// Ordinals of the chunks already committed for a build, so a resumed load
    /// does not re-fetch them.
    public func completedChunks(buildId: String) throws -> [Int] {
        try withConnection { connection in
            try connection.query(
                """
                SELECT ordinal FROM _snapshot_load \
                WHERE doc_id = ? AND build_id = ? ORDER BY ordinal
                """,
                [.text(docId), .text(buildId)]
            ).compactMap { $0["ordinal"].intValue }
        }
    }

    public func chunkIsComplete(buildId: String, ordinal: Int) throws -> Bool {
        try withConnection { connection in
            try !connection.query(
                """
                SELECT 1 FROM _snapshot_load \
                WHERE doc_id = ? AND build_id = ? AND ordinal = ? LIMIT 1
                """,
                [.text(docId), .text(buildId), .integer(Int64(ordinal))]
            ).isEmpty
        }
    }

    /// Apply one snapshot chunk: its rows AND the mark that says it landed, in
    /// ONE commit (#3436, behavior 24).
    ///
    /// The atomicity belongs to the store rather than to each caller, because
    /// it is the whole of what makes a load resumable: a mark that could
    /// outlive its rows would make a resume skip records that are not there.
    ///
    /// A chunk whose mark is already written is SKIPPED inside the
    /// transaction (edge E9). A snapshot row REPLACES what the merged view
    /// holds, and by the time a second attempt reaches one an overlay fold may
    /// have changed it — re-applying would put the base's older value back
    /// over the current one, with nothing to notice. The check is inside the
    /// transaction because the mark and the rows it vouches for are only ever
    /// consistent there.
    ///
    /// - Returns: how many entries were actually projected, which is `0` both
    ///   for an already-marked chunk and for a model this device is not
    ///   holding.
    @discardableResult
    public func applyChunk(
        model: String,
        entries: [OverlayRecordEntry],
        buildId: String,
        ordinal: Int
    ) throws -> Int {
        try withConnection { connection in
            try connection.transaction {
                if try chunkIsComplete(buildId: buildId, ordinal: ordinal) { return 0 }
                // #3782 — base rows replace what the overlay fold wrote; the
                // load's closing catch-up stamps the store again.
                try clearFoldedState()
                var applied = 0
                if try isHydrated(model) {
                    for entry in entries {
                        try OverlayFold.project(
                            connection, model: model, entry: entry, statements: statements
                        )
                        try projection?.projectRow(
                            model: model, recordId: entry.id, in: self
                        )
                        applied += 1
                    }
                }
                try markChunkComplete(buildId: buildId, ordinal: ordinal)
                return applied
            }
        }
    }

    public func markChunkComplete(buildId: String, ordinal: Int) throws {
        try withConnection { connection in
            try connection.execute(
                """
                INSERT OR IGNORE INTO _snapshot_load (doc_id, build_id, ordinal) \
                VALUES (?, ?, ?)
                """,
                [.text(docId), .text(buildId), .integer(Int64(ordinal))]
            )
        }
    }

    /// Record that the chain has a break at `epoch` — a bulk load replaced the
    /// document's rows, so the epochs either side of it do not sum.
    public func noteDiscontinuity(epoch: Int) throws {
        try withConnection { connection in
            try connection.execute(
                "INSERT OR IGNORE INTO _discontinuities (doc_id, epoch) VALUES (?, ?)",
                [.text(docId), .integer(Int64(epoch))]
            )
        }
    }

    public func discontinuityEpochs() throws -> [Int] {
        try withConnection { connection in
            try connection.query(
                "SELECT epoch FROM _discontinuities WHERE doc_id = ? ORDER BY epoch",
                [.text(docId)]
            ).compactMap { $0["epoch"].intValue }
        }
    }

    /// Forget the discontinuities at or below `epoch`: a rebuild past them has
    /// converged, so they are no longer boundaries anything is waiting on.
    public func clearDiscontinuities(through epoch: Int) throws {
        try withConnection { connection in
            try connection.execute(
                "DELETE FROM _discontinuities WHERE doc_id = ? AND epoch <= ?",
                [.text(docId), .integer(Int64(epoch))]
            )
        }
    }

    // MARK: - The judgement a move owes

    /// Record that a judgement is owed on the sequences at or below
    /// `throughSeq` (#3437, finding 3437-SO-03).
    ///
    /// Written in the SAME transaction as the epoch mark by the move that
    /// deferred its carry. Without it a restart in that window would find the
    /// mark moved and the debt forgotten: the bind would restore those writes
    /// by the key rule alone and the flush would publish them, with recency
    /// never consulted — which is exactly the outdated write the replay exists
    /// to drop.
    ///
    /// One note per document. A second deferral before the first is judged
    /// widens the same note rather than queueing beside it: the judgement is
    /// "everything at or below this sequence, read against the chain from here
    /// to there", and two of those over overlapping spans is one.
    public func noteDeferredReplay(
        throughSeq: Int, fromEpoch: Int, toEpoch: Int, kind: DeferredReplayKind
    ) throws {
        try withConnection { connection in
            try connection.execute(
                """
                INSERT INTO _deferred_replay
                  (doc_id, through_seq, from_epoch, to_epoch, kind)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (doc_id) DO UPDATE SET
                  through_seq = MAX(through_seq, excluded.through_seq),
                  from_epoch = MIN(from_epoch, excluded.from_epoch),
                  to_epoch = MAX(to_epoch, excluded.to_epoch),
                  kind = excluded.kind
                """,
                [
                    .text(docId), .integer(Int64(throughSeq)),
                    .integer(Int64(fromEpoch)), .integer(Int64(toEpoch)),
                    .text(kind.rawValue),
                ]
            )
        }
    }

    public func deferredReplay() throws -> DeferredReplayNote? {
        try withConnection { connection in
            try connection.query(
                """
                SELECT through_seq, from_epoch, to_epoch, kind \
                FROM _deferred_replay WHERE doc_id = ?
                """,
                [.text(docId)]
            ).first.flatMap(DeferredReplayNote.init(row:))
        }
    }

    /// Run several of this store's commands in ONE SQLite transaction.
    ///
    /// What an epoch move needs: the epoch mark, the sync mark and — when the
    /// carry was deferred — the judgement note describe one event, and a
    /// restart that found the mark moved and the note missing would restore an
    /// owed write with recency never consulted (#3437, finding 3437-SO-03).
    /// The connection is re-entrant, so the commands inside can be the
    /// ordinary ones rather than transaction-aware copies of them.
    public func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try withConnection { connection in
            try connection.transaction { try body() }
        }
    }

    public func clearDeferredReplay() throws {
        try withConnection { connection in
            try connection.execute(
                "DELETE FROM _deferred_replay WHERE doc_id = ?", [.text(docId)]
            )
        }
    }

    /// Throw away a merged view that cannot be repaired, keeping the writes
    /// this client still owes the server.
    ///
    /// The rows go, the members go, and the load marks go with them — a mark
    /// that outlived its rows would make the next load skip records that are
    /// not there. So does the base row: which build these rows came from is no
    /// longer a fact about this client.
    ///
    /// What stays is `_pending_ops` and `_client_acks` — the writes the server
    /// has not acknowledged are still owed however broken the view is — and
    /// `_discontinuities`, because a bulk load this client crossed is still
    /// owed too, and forgetting it here would have the client reload from a
    /// base and then never converge past it.
    ///
    /// The hydration scope stays too: which models this device can hold is a
    /// fact about the DEVICE, and the base that replaces this view has to be
    /// planned against the same cap (#3437, behavior 34).
    ///
    /// And the derived query tables go with the records (finding 3437-SO-05).
    /// They are a second view onto the same document, `Format2QueryProjection`
    /// returns early on an existing mark, and a load writes only the ids the
    /// new base carries — so a record the replacement base does not hold would
    /// stay visible to `query`, `count`, `aggregate` and the stringset index
    /// after `find(id:)` reports it gone. The marks go with the rows, which is
    /// what makes the next connect project again instead of returning early.
    public func discardMergedView() throws {
        try withConnection { connection in
            let present = try Self.existingTables(connection)
            let derived = try Self.queryTables(connection, present: present)
            try connection.transaction {
                try connection.execute("DELETE FROM \(tables.records)", [])
                try connection.execute("DELETE FROM \(tables.stringSetIndex)", [])
                try connection.execute(
                    "DELETE FROM _snapshot_load WHERE doc_id = ?", [.text(docId)]
                )
                try connection.execute(
                    "DELETE FROM _snapshot_base WHERE doc_id = ?", [.text(docId)]
                )
                // Every derived table is swept, including the stringset
                // junctions: one this document was never projected into holds
                // no row tagged with it, so the delete is a no-op there.
                for table in derived {
                    try connection.execute(
                        "DELETE FROM \"\(table)\" WHERE \"_meta_doc_id\" = ?",
                        [.text(docId)]
                    )
                }
                try connection.execute(
                    "DELETE FROM _query_projection WHERE doc_id = ?", [.text(docId)]
                )
                // #3782 — nothing is folded any more.
                try clearFoldedState()
            }
        }
    }

    // MARK: - Query projection marks

    /// Record that a model's rows have been projected into the query tables,
    /// so a close-and-reopen projects nothing.
    public func markQueryProjection(model: String) throws {
        try withConnection { connection in
            try connection.execute(
                "INSERT OR IGNORE INTO _query_projection (doc_id, model) VALUES (?, ?)",
                [.text(docId), .text(model)]
            )
        }
    }

    public func hasQueryProjection(model: String) throws -> Bool {
        try withConnection { connection in
            try !connection.query(
                "SELECT 1 FROM _query_projection WHERE doc_id = ? AND model = ? LIMIT 1",
                [.text(docId), .text(model)]
            ).isEmpty
        }
    }

    public func withdrawQueryProjection(model: String) throws {
        try withConnection { connection in
            try connection.execute(
                "DELETE FROM _query_projection WHERE doc_id = ? AND model = ?",
                [.text(docId), .text(model)]
            )
        }
    }

    // MARK: - Purge

    /// The shared tables a document has rows in, so one list decides what a
    /// purge has to reach and what a test has to check.
    static let sharedTables = [
        "_epoch", "_pending_ops", "_client_acks", "_snapshot_load",
        "_snapshot_base", "_discontinuities", "_query_projection",
    ]

    /// Drop everything belonging to one document.
    ///
    /// Reaches a document that is CLOSED and absent from memory, because that
    /// is what the callers need: `evictDocument` runs for a document nothing
    /// is holding, and `logout(wipeLocal:)` for a whole account. The
    /// per-document tables are DROPPED rather than emptied — they are named
    /// after the document and nothing will ever read them again.
    ///
    /// Unacknowledged pending ops go too. An ordinary close keeps them (they
    /// are writes the server still owes an ack for); an eviction and an
    /// account wipe are both explicit instructions to forget the document, and
    /// leaving a previous account's writes on disk is what criterion 7 is
    /// about.
    public static func purge(host: any Format2SqlHost, documentId: String) throws {
        let tables = Format2TableNames(documentId: documentId)
        try host.withConnection { connection in
            let present = try existingTables(connection)
            // A client that has never opened a large document has none of these
            // tables, and every eviction it ever runs comes through here. Say
            // so once rather than reading the shape of every table it does have.
            guard present.contains("_epoch") else { return }
            let derived = try queryTables(connection, present: present)
            try connection.transaction {
                for table in [tables.records, tables.stringSetIndex] where present.contains(table) {
                    try connection.executeScript("DROP TABLE IF EXISTS \(table)")
                }
                // The derived query tables are shared by every document in the
                // database, so the document's ROWS go rather than the table.
                // Every one of them is swept — a table this document was never
                // projected into holds no row tagged with it, so the delete is
                // a no-op there, and one whose mark was withdrawn by a schema
                // widening is reached anyway.
                for table in derived {
                    try connection.execute(
                        "DELETE FROM \"\(table)\" WHERE \"_meta_doc_id\" = ?",
                        [.text(documentId)]
                    )
                }
                for table in sharedTables where present.contains(table) {
                    try connection.execute(
                        "DELETE FROM \(table) WHERE doc_id = ?", [.text(documentId)]
                    )
                }
            }
        }
    }

    /// The same, for every document in the database — `logout(wipeLocal:)`.
    ///
    /// The document ids come from the tables themselves rather than from
    /// anything in memory, so a document this client never opened in this
    /// session is still reached.
    public static func purgeAll(host: any Format2SqlHost) throws {
        try host.withConnection { connection in
            let present = try existingTables(connection)
            let perDocument = try connection.query(
                """
                SELECT name FROM sqlite_master WHERE type = 'table' \
                AND (name LIKE 'records_f2_%' OR name LIKE 'stringset_index_f2_%')
                """
            ).compactMap { $0["name"].stringValue }
            let derived = try queryTables(connection, present: present)
            try connection.transaction {
                for table in perDocument {
                    try connection.executeScript("DROP TABLE IF EXISTS \(table)")
                }
                for table in derived {
                    try connection.executeScript("DELETE FROM \"\(table)\"")
                }
                for table in sharedTables where present.contains(table) {
                    try connection.execute("DELETE FROM \(table)")
                }
            }
        }
    }

    /// Rows each shared table still holds for a document. The purge's own
    /// check, and an operator's.
    public static func sharedRowCounts(
        host: any Format2SqlHost, documentId: String
    ) throws -> [(table: String, count: Int)] {
        try host.withConnection { connection in
            let present = try existingTables(connection)
            return try sharedTables.filter(present.contains).map { table in
                let count = try connection.query(
                    "SELECT COUNT(*) AS v FROM \(table) WHERE doc_id = ?", [.text(documentId)]
                ).first?["v"].intValue ?? 0
                return (table: table, count: count)
            }
        }
    }

    /// Every derived query table this database holds.
    ///
    /// Found by SHAPE — the `_meta_doc_id` column the projection gives each
    /// model table and each stringset junction — and NOT from the
    /// `_query_projection` marks. The marks say which models are projected and
    /// UP TO DATE, which is a different question and not a durable inventory:
    /// widening a table for a schema that gained a field withdraws every mark
    /// for that model while the rows stay, and a purge that took the marks for
    /// an inventory would walk past those rows and leave them on disk. For
    /// `logout(wipeLocal:)` that is a previous account's records surviving an
    /// account wipe, which is what criterion 7 is about.
    ///
    /// Nothing else in this database carries that column: the per-document
    /// record and member tables, the shared format-2 tables and the provider's
    /// own key-value store are all named here or shaped differently.
    private static func queryTables(
        _ connection: any Format2SqlConnection, present: Set<String>
    ) throws -> [String] {
        var out: [String] = []
        for table in present.sorted() where !table.hasPrefix("sqlite_") {
            guard !sharedTables.contains(table),
                  !table.hasPrefix("records_f2_"),
                  !table.hasPrefix("stringset_index_f2_")
            else { continue }
            let columns = try connection.query("PRAGMA table_info(\"\(table)\")")
                .compactMap { $0["name"].stringValue }
            if columns.contains("_meta_doc_id") { out.append(table) }
        }
        return out
    }

    /// Which tables this database actually has.
    ///
    /// A purge runs on every client, including one that has never opened a
    /// large document and has no format-2 table at all — and on every document
    /// an eviction sweeps, most of which are format 1. Asking first is what
    /// makes both a no-op instead of an error.
    private static func existingTables(
        _ connection: any Format2SqlConnection
    ) throws -> Set<String> {
        Set(
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'")
                .compactMap { $0["name"].stringValue }
        )
    }

    // MARK: - Test and diagnostic dumps

    /// Every schema object this database holds, by name, excluding SQLite's
    /// own. Used by the parity check and by an operator reading a support
    /// bundle.
    public func schemaObjects() throws -> [String: String] {
        try withConnection { connection in
            var out: [String: String] = [:]
            for row in try connection.query(
                "SELECT name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
            ) {
                guard let name = row["name"].stringValue,
                      let sql = row["sql"].stringValue else { continue }
                out[name] = sql
            }
            return out
        }
    }

    public struct RecordRow: Equatable, Sendable {
        public let type: String
        public let id: String
        public let data: String
    }

    public func dumpRecords() throws -> [RecordRow] {
        try withConnection { connection in
            try connection.query(
                "SELECT _type, _id, _data FROM \(tables.records) ORDER BY _type, _id"
            ).compactMap { row in
                guard let type = row["_type"].stringValue,
                      let id = row["_id"].stringValue,
                      let data = row["_data"].stringValue else { return nil }
                return RecordRow(type: type, id: id, data: data)
            }
        }
    }

    public struct MemberRow: Equatable, Sendable {
        public let type: String
        public let recordId: String
        public let field: String
        public let value: String
    }

    public func dumpMembers() throws -> [MemberRow] {
        try withConnection { connection in
            try connection.query(
                """
                SELECT _type, _record_id, field, value FROM \(tables.stringSetIndex) \
                ORDER BY _type, _record_id, field, rowid
                """
            ).compactMap { row in
                guard let type = row["_type"].stringValue,
                      let recordId = row["_record_id"].stringValue,
                      let field = row["field"].stringValue,
                      let value = row["value"].stringValue else { return nil }
                return MemberRow(type: type, recordId: recordId, field: field, value: value)
            }
        }
    }

    public func dumpClientAcks() throws -> [(clientId: String, ackedSeq: Int)] {
        try withConnection { connection in
            try connection.query(
                """
                SELECT client_id, acked_seq FROM _client_acks \
                WHERE doc_id = ? ORDER BY client_id
                """,
                [.text(docId)]
            ).compactMap { row in
                guard let id = row["client_id"].stringValue else { return nil }
                return (clientId: id, ackedSeq: row["acked_seq"].intValue ?? 0)
            }
        }
    }

    // MARK: - Private

    private func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T {
        try host.withConnection(body)
    }

    /// Decode a stored `_data` blob back into a record, with `id` restored.
    private static func decodeRow(_ data: String, id: String) -> [String: JSONValue] {
        guard let bytes = data.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: bytes)
        else { return ["id": .string(id)] }
        var row = decoded
        row["id"] = .string(id)
        return row
    }

    private static func encodeJSON(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Format2SqlError.executionFailed(
                sql: "<json encoding>", message: "value is not UTF-8"
            )
        }
        return text
    }

    private static func encodeJSON(_ value: [JSONValue]) throws -> String {
        try encodeJSON(JSONValue.array(value))
    }

    /// The deployment's offline write window, as the server last reported it.
    ///
    /// js-bao's numbers, not this client's own: 7 days, clamped to 1–14, the
    /// same range overlay retention prunes archives by — which is what an
    /// offline write is replayed across, so a client whose window outran
    /// retention would go on accepting writes the server cannot place
    /// (#3437, finding 3437-R01).
    static let defaultOfflineWindowDays = Format2OfflineWindow.defaultOfflineWindowDays
    private static func configuredWindowDays(_ value: Int) -> Int {
        Format2OfflineWindow.configuredOfflineWindowDays(value)
    }
}

/// A write this client has committed locally and the server has not
/// acknowledged.
public struct PendingOp: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case create, patch, delete
    }

    public let seq: Int
    public let model: String
    public let recordId: String
    public let op: Kind
    /// Field names the op touched.
    public let fields: [String]
    /// Epoch the op was written against, for recency-aware replay.
    public let baseEpoch: Int
    /// Server-offset-corrected wall clock at write time.
    public let ts: Int
    /// The overlay mutation this op wrote, so the write can be reproduced from
    /// the durable log alone.
    public let mutation: OverlayMutation?
    /// What the overlay held for each key this op wrote, just BEFORE the
    /// write. A key the overlay did not hold is absent, so `[:]` is a complete
    /// answer; `nil` is "not recorded".
    public let priorOverlay: [String: JSONValue]?

    public init(
        seq: Int,
        model: String,
        recordId: String,
        op: Kind,
        fields: [String],
        baseEpoch: Int,
        ts: Int,
        mutation: OverlayMutation?,
        priorOverlay: [String: JSONValue]?
    ) {
        self.seq = seq
        self.model = model
        self.recordId = recordId
        self.op = op
        self.fields = fields
        self.baseEpoch = baseEpoch
        self.ts = ts
        self.mutation = mutation
        self.priorOverlay = priorOverlay
    }

    init?(row: Format2SqlRow) {
        guard let model = row["model"].stringValue,
              let recordId = row["record_id"].stringValue,
              let op = row["op"].stringValue.flatMap(Kind.init(rawValue:))
        else { return nil }
        self.seq = row["seq"].intValue ?? 0
        self.model = model
        self.recordId = recordId
        self.op = op
        self.fields = row["fields"].stringValue
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        self.baseEpoch = row["base_epoch"].intValue ?? 0
        self.ts = row["ts"].intValue ?? 0
        self.mutation = row["mutation"].stringValue.flatMap(OverlayMutation.init(storedJSON:))
        self.priorOverlay = row["prior_overlay"].stringValue
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
    }
}

/// A pending op this client took over from an instance that is gone
/// (#3437, behavior 4).
public struct AdoptedOp: Equatable, Sendable {
    /// The op under ITS NEW sequence, which is what every later claim,
    /// judgement and ack names it by.
    public let op: PendingOp
    /// The instance it came from, and the sequence it had there. Kept because
    /// an adoption is not a write: the pair is what makes a re-run of the same
    /// adoption recognisable and what an operator reads in the log.
    public let fromClientId: String
    public let fromSeq: Int

    public var seq: Int { op.seq }
    public var model: String { op.model }
    public var recordId: String { op.recordId }
}

/// Why a judgement is owed (#3437, behaviors 20 and 28).
public enum DeferredReplayKind: String, Equatable, Sendable {
    /// A returning client's move, judged against the sealed chain it applied.
    case ordinary
    /// A bulk load's discontinuity, judged by PRESENCE once the replacement
    /// base is in.
    case discontinuity
}

/// The judgement an epoch move owes but has not run.
public struct DeferredReplayNote: Equatable, Sendable {
    /// Every sequence at or below this is held off the overlay until the
    /// judgement has said which of them still stand.
    public let throughSeq: Int
    /// The span of the chain the judgement reads: the epoch the writes were
    /// made against, and the one they were moved onto.
    public let fromEpoch: Int
    public let toEpoch: Int
    public let kind: DeferredReplayKind

    public init(throughSeq: Int, fromEpoch: Int, toEpoch: Int, kind: DeferredReplayKind) {
        self.throughSeq = throughSeq
        self.fromEpoch = fromEpoch
        self.toEpoch = toEpoch
        self.kind = kind
    }

    init?(row: Format2SqlRow) {
        guard let kind = row["kind"].stringValue.flatMap(DeferredReplayKind.init(rawValue:))
        else { return nil }
        self.throughSeq = row["through_seq"].intValue ?? 0
        self.fromEpoch = row["from_epoch"].intValue ?? 0
        self.toEpoch = row["to_epoch"].intValue ?? 0
        self.kind = kind
    }
}

/// What a caller supplies for the pending-op half of a local write.
public struct PendingOpInput: Sendable {
    public let model: String
    public let recordId: String
    public let op: PendingOp.Kind
    public let fields: [String]
    public let baseEpoch: Int
    public let ts: Int
    /// Pin the sequence rather than taking the next one — a replayed write
    /// keeps the sequence its sender claimed.
    public let seq: Int?
    public let priorOverlay: [String: JSONValue]?

    public init(
        model: String,
        recordId: String,
        op: PendingOp.Kind,
        fields: [String],
        baseEpoch: Int,
        ts: Int,
        seq: Int? = nil,
        priorOverlay: [String: JSONValue]? = nil
    ) {
        self.model = model
        self.recordId = recordId
        self.op = op
        self.fields = fields
        self.baseEpoch = baseEpoch
        self.ts = ts
        self.seq = seq
        self.priorOverlay = priorOverlay
    }
}

extension OverlayMutation {
    /// The mutation as the JSON the pending-op log stores — the same shape
    /// `largeDocuments.ts` writes, so a log row is readable on either client.
    var storedJSON: JSONValue {
        var out: [String: JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue)]
        if !fields.isEmpty { out["fields"] = .object(fields) }
        if !stringSetDeltas.isEmpty {
            out["stringSetDeltas"] = .object(stringSetDeltas.mapValues { members in
                JSONValue.object(members.mapValues { JSONValue.bool($0) })
            })
        }
        return .object(out)
    }

    /// Rebuild a mutation from a stored log row.
    init?(storedJSON text: String) {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let kind = object["kind"]?.stringValue.flatMap(Kind.init(rawValue:))
        else { return nil }
        self.init(
            id: id,
            kind: kind,
            fields: object["fields"]?.objectValue ?? [:],
            stringSetDeltas: (object["stringSetDeltas"]?.objectValue ?? [:])
                .compactMapValues { members in
                    members.objectValue?.compactMapValues { $0.boolValue }
                }
        )
    }
}
