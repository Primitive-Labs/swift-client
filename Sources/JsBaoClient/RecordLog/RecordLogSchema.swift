import Foundation

/// The tables the record-log store keeps format-3 documents in, beside the
/// key-value store and the model query tables in the
/// storage provider's one database. Column for column what js-bao's
/// `recordLogClientDDL` writes, so a store reads the same on either client.
/// Every table is keyed by `doc_id`: one store holds every document.
///
/// - `record_log_rows`: the rows the room has confirmed, to the cursor.
/// - `record_log_view`: what reads answer, the confirmed rows with every
///   unjudged entry applied as a guess; rewritten per touched record in the
///   transaction that changes it.
/// - `record_log_state`: per document, the cursor, the epochs, the
///   constraints the room declared, the full replacement in progress, the
///   receipts of a load's or a segment's chunks begun and not completed, and
///   the segment the confirmed rows were last replaced from; and, for a db3
///   that lives only on this device (`local_only` 1, #5155), the index
///   registrations made on it here (`local_indexes`, the room's registry kept
///   on the device).
/// - `record_log_writers`: per document and client, its writer and next
///   sequence number.
/// - `record_log_pending` and `record_log_pending_keys`: the unjudged entries,
///   and the records each one touches.
/// - `record_log_pending_values`: per unjudged entry, the values its mutations
///   write (`upsert` marks the value it upserts on).
/// - `record_log_handled`: per writer and record, the refusals it acted on.
/// - `record_log_epoch_counts`: the entries seen applied per epoch.
/// - `record_log_load_keys`: per receipt attempt, the records a bulk load's
///   chunks named, kept until the attempt applied its last chunk or a full
///   replacement made it right, so a refresh removes the others.
/// - `record_log_indexes`: per document, the room's index list as the store
///   last read it, keyed by `(model, fields, kind)`, from which the view's
///   lookup indexes are built (``RecordLogIndexes``); a member index placed
///   on the device is a row whose `members` names the table its members are
///   kept in (#5156), a text index one whose `text` names its FTS5 table and
///   whose `options` hold its options (#5223).
/// - `record_log_staged_base`: per document and record, the previous
///   completed generation's confirmed row (`_data` NULL when it had none) of
///   each record a staged full replacement has rewritten: the base a view
///   refresh guesses over until the replacement commits.
///
/// `record_log_owner` is this client's alone: the authenticated user the tables
/// belong to (the browser's store is scoped by user through its file's
/// namespace; this provider's file is one per app, so the owner is written down
/// and a sign-in as someone else resets the store). `record_log_meta` is
/// store-wide, as js-bao's: the storage version (``storageVersion``), a store
/// without it being version 1; and, in a store holding a member index, the
/// view's highest rowid when statistics were last gathered
/// (`statistics_rowid`, #5156).
enum RecordLogSchema {
    /// Every table the JS store keeps, in its order.
    static let clientTables = [
        "record_log_rows",
        "record_log_view",
        "record_log_state",
        "record_log_writers",
        "record_log_pending",
        "record_log_pending_keys",
        "record_log_pending_values",
        "record_log_handled",
        "record_log_epoch_counts",
        "record_log_load_keys",
        "record_log_indexes",
        "record_log_staged_base",
        "record_log_index_skips",
    ]

    /// The columns a store created by an earlier version lacks, with the
    /// statement that adds each: `CREATE TABLE IF NOT EXISTS` leaves an
    /// existing table as it was.
    static let addedColumns: [(table: String, column: String, add: String)] = [
        ("record_log_state", "receipt", "ALTER TABLE record_log_state ADD COLUMN receipt TEXT"),
        ("record_log_state", "segment", "ALTER TABLE record_log_state ADD COLUMN segment TEXT"),
        ("record_log_state", "staged", "ALTER TABLE record_log_state ADD COLUMN staged INTEGER"),
    ] + localOnlyColumns + memberIndexColumns + knownHeadColumns + vectorIndexColumns

    /// The columns storage version 4 adds (#5155): the mark of a db3 that
    /// lives only on this device, and the index registrations made on it here.
    static let localOnlyColumns: [(table: String, column: String, add: String)] = [
        ("record_log_state", "local_only", "ALTER TABLE record_log_state ADD COLUMN local_only INTEGER NOT NULL DEFAULT 0"),
        ("record_log_state", "local_indexes", "ALTER TABLE record_log_state ADD COLUMN local_indexes TEXT"),
    ]

    /// The column storage version 5 adds (#5156): the device table a local-only
    /// db3's member index is kept in, NULL for a scalar entry. Kept for a store
    /// from before version 5, whose cache the version-6 step copies with it.
    static let memberIndexColumns: [(table: String, column: String, add: String)] = [
        ("record_log_indexes", "members", "ALTER TABLE record_log_indexes ADD COLUMN members TEXT"),
    ]

    /// The columns storage version 7 adds (#5221): the room's head as this
    /// device last heard it, and when (epoch ms). NULL until a head is heard.
    static let knownHeadColumns: [(table: String, column: String, add: String)] = [
        ("record_log_state", "known_head", "ALTER TABLE record_log_state ADD COLUMN known_head INTEGER"),
        ("record_log_state", "known_head_at", "ALTER TABLE record_log_state ADD COLUMN known_head_at INTEGER"),
    ]

    /// The column storage version 9 adds (#5230, js-bao's
    /// `RECORD_LOG_VECTOR_INDEX_COLUMNS`): the vec1 flat table a vector entry
    /// is kept in on this device, NULL for every other kind.
    static let vectorIndexColumns: [(table: String, column: String, add: String)] = [
        ("record_log_indexes", "vector", "ALTER TABLE record_log_indexes ADD COLUMN vector TEXT"),
    ]

    /// The table naming the user the record-log tables belong to.
    static let ownerTable = "record_log_owner"

    /// The storage version a store is brought to at open: 10 (#5241) adds the
    /// entries each db3's copy skipped, `record_log_index_skips`; 9 (#5230) adds the
    /// vector entry's flat table, `record_log_indexes.vector`; 8 (#5322) adds the
    /// device's index policy, `record_log_index_policy`; 7 (#5221) adds the
    /// room's head as last heard to `record_log_state`; 6 (#5223) keys
    /// `record_log_indexes` by `(doc_id, model, fields, kind)` and adds its
    /// `text` and `options` (``rebuildIndexCache``); 5 (#5156) adds the
    /// member table's name to `record_log_indexes`; 4 (#5155) adds the
    /// local-only mark and registrations to `record_log_state`. Version 3
    /// (#5136) keeps each record's `_data` as JSONB without `id`, which `_id`
    /// holds. Version 2
    /// (#4700) kept it as JSON text with `id`, a db3's rows in its view only
    /// and its indexes from the room's list; version 1 also kept the query
    /// projection (model tables with `_meta_doc_id`, their marks and rule, and
    /// indexes built from declarations). A build that changes the tables
    /// raises it: a store at or above the version runs no DDL at open.
    static let storageVersion = 10

    /// The version from which every row is JSONB without `id`: a store at it
    /// or above has nothing to convert (#5136).
    static let jsonbVersion = 3

    /// The statements that create the tables. Each is idempotent.
    static let ddl: [String] = [
        """
        CREATE TABLE IF NOT EXISTS record_log_rows (
          doc_id TEXT NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          _data TEXT NOT NULL,
          _gen INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (doc_id, _type, _id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_view (
          doc_id TEXT NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          _data TEXT NOT NULL,
          PRIMARY KEY (doc_id, _type, _id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_state (
          doc_id TEXT PRIMARY KEY,
          cursor INTEGER NOT NULL DEFAULT 0,
          open_epoch INTEGER NOT NULL DEFAULT 1,
          grant_epoch INTEGER NOT NULL DEFAULT 2,
          epoch_entries INTEGER NOT NULL DEFAULT 10000,
          constraints TEXT NOT NULL DEFAULT '[]',
          last_catch_up_at INTEGER,
          permission TEXT,
          rows_gen INTEGER NOT NULL DEFAULT 0,
          replacing INTEGER,
          receipt TEXT,
          segment TEXT,
          staged INTEGER,
          local_only INTEGER NOT NULL DEFAULT 0,
          local_indexes TEXT,
          known_head INTEGER,
          known_head_at INTEGER
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_writers (
          doc_id TEXT NOT NULL,
          client_id TEXT NOT NULL,
          writer TEXT NOT NULL,
          next_seq INTEGER NOT NULL DEFAULT 1,
          resumed_at INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (doc_id, client_id)
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS record_log_writers_by_writer ON record_log_writers(doc_id, writer)",
        """
        CREATE TABLE IF NOT EXISTS record_log_pending (
          doc_id TEXT NOT NULL,
          writer TEXT NOT NULL,
          seq INTEGER NOT NULL,
          ord INTEGER NOT NULL,
          e INTEGER NOT NULL,
          entry TEXT NOT NULL,
          ts INTEGER,
          void INTEGER NOT NULL DEFAULT 0,
          acked INTEGER,
          PRIMARY KEY (doc_id, writer, seq)
        )
        """,
        "CREATE INDEX IF NOT EXISTS record_log_pending_acked ON record_log_pending(doc_id, acked) WHERE acked IS NOT NULL",
        // A write numbers its entry after the highest `ord` and counts its
        // epoch's unwithdrawn entries; neither reads the entries.
        "CREATE INDEX IF NOT EXISTS record_log_pending_by_ord ON record_log_pending(doc_id, ord)",
        "CREATE INDEX IF NOT EXISTS record_log_pending_by_epoch ON record_log_pending(doc_id, e) WHERE void = 0",
        """
        CREATE TABLE IF NOT EXISTS record_log_pending_keys (
          doc_id TEXT NOT NULL,
          writer TEXT NOT NULL,
          seq INTEGER NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          resolved INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (doc_id, writer, seq, _type, _id)
        )
        """,
        // The entries touching a record, answered from the index alone: without
        // `writer, seq` in it SQLite reads the keys' primary key by document.
        "DROP INDEX IF EXISTS record_log_pending_keys_by_record",
        "CREATE INDEX IF NOT EXISTS record_log_pending_keys_by_record_entry ON record_log_pending_keys(doc_id, _type, _id, writer, seq)",
        """
        CREATE TABLE IF NOT EXISTS record_log_pending_values (
          doc_id TEXT NOT NULL,
          writer TEXT NOT NULL,
          seq INTEGER NOT NULL,
          _type TEXT NOT NULL,
          field TEXT NOT NULL,
          value,
          upsert INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (doc_id, writer, seq, _type, field, value)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS record_log_pending_values_by_value \
        ON record_log_pending_values(doc_id, _type, field, upsert, value)
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_handled (
          doc_id TEXT NOT NULL,
          writer TEXT NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          from_seq INTEGER NOT NULL,
          until_seq INTEGER NOT NULL,
          PRIMARY KEY (doc_id, writer, _type, _id, from_seq)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_epoch_counts (
          doc_id TEXT NOT NULL,
          epoch INTEGER NOT NULL,
          count INTEGER NOT NULL,
          PRIMARY KEY (doc_id, epoch)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_load_keys (
          doc_id TEXT NOT NULL,
          attempt TEXT NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          PRIMARY KEY (doc_id, attempt, _type, _id)
        )
        """,
        indexCacheDDL,
        """
        CREATE TABLE IF NOT EXISTS record_log_staged_base (
          doc_id TEXT NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          _data TEXT,
          PRIMARY KEY (doc_id, _type, _id)
        )
        """,
        indexPolicyDDL,
        indexSkipsDDL,
        "CREATE TABLE IF NOT EXISTS record_log_owner (user_id TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS record_log_meta (key TEXT PRIMARY KEY, value TEXT)",
    ]

    /// The index cache as storage version 9 keeps it, js-bao's
    /// `RECORD_LOG_INDEXES_DDL`: `kind` is `scalar`, `members`, `text` or
    /// `vector`; `vector` names a vector entry's flat table (#5230).
    static let indexCacheDDL = """
        CREATE TABLE IF NOT EXISTS record_log_indexes (
          doc_id TEXT NOT NULL,
          model TEXT NOT NULL,
          fields TEXT NOT NULL,
          kind TEXT NOT NULL DEFAULT 'scalar',
          is_unique INTEGER NOT NULL DEFAULT 0,
          room_name TEXT,
          members TEXT,
          text TEXT,
          options TEXT,
          vector TEXT,
          PRIMARY KEY (doc_id, model, fields, kind)
        )
        """

    /// The registry entries a db3's copy skipped when it last applied its
    /// room's list (storage version 10, #5241, js-bao's
    /// `RECORD_LOG_INDEX_SKIPS_DDL`): one row per entry, with the placement
    /// the list gave it and why nothing is cached or built for it. Replaced
    /// with the cache, in the same transaction; one of ``clientTables``.
    static let indexSkipsDDL = """
        CREATE TABLE IF NOT EXISTS record_log_index_skips (
          doc_id TEXT NOT NULL,
          room_name TEXT NOT NULL,
          model TEXT NOT NULL,
          fields TEXT NOT NULL,
          kind TEXT NOT NULL,
          "on" TEXT NOT NULL,
          reason TEXT NOT NULL
        )
        """

    /// The device's index policy (storage version 8, #5322, js-bao's
    /// `RECORD_LOG_INDEX_POLICY_DDL`): one row per `(doc_id, model, fields,
    /// kind)` this device declined or accepted, and when. Not one of
    /// ``clientTables``: an evict keeps it, and only `client.db3.delete` clears it.
    static let indexPolicyDDL = """
        CREATE TABLE IF NOT EXISTS record_log_index_policy (
          doc_id TEXT NOT NULL,
          model TEXT NOT NULL,
          fields TEXT NOT NULL,
          kind TEXT NOT NULL,
          verdict TEXT NOT NULL CHECK (verdict IN ('declined', 'accepted')),
          at INTEGER NOT NULL,
          PRIMARY KEY (doc_id, model, fields, kind)
        )
        """

    /// The table ``rebuildIndexCache(_:)`` builds the version-6 cache in before it takes the cache's name.
    static let indexCacheV6 = "record_log_indexes_v6"

    /// Storage version 6 (#5223, js-bao's `rebuildIndexCache`): a cache
    /// without `kind` is copied into a new table of the version-6 shape with
    /// `kind` backfilled (`members` where `members` is set, else `scalar`),
    /// which takes the old table's name. A cache that has `kind`, or no cache
    /// at all, is left alone. Runs in the open's first transaction, after the
    /// columns a store from before version 5 lacks were added.
    static func rebuildIndexCache(_ connection: any Format2SqlConnection) throws {
        let present = Set(try connection.query("SELECT name FROM pragma_table_info('record_log_indexes')", [])
            .compactMap { $0["name"].stringValue })
        if present.isEmpty || present.contains("kind") { return }
        try connection.executeScript("DROP TABLE IF EXISTS \(indexCacheV6)")
        try connection.executeScript(indexCacheDDL.replacingOccurrences(of: "record_log_indexes", with: indexCacheV6))
        try connection.executeScript(
            """
            INSERT INTO \(indexCacheV6) (doc_id, model, fields, kind, is_unique, room_name, members)
              SELECT doc_id, model, fields, CASE WHEN members IS NULL THEN 'scalar' ELSE 'members' END, is_unique, room_name, members
              FROM record_log_indexes
            """
        )
        try connection.executeScript("DROP TABLE record_log_indexes")
        try connection.executeScript("ALTER TABLE \(indexCacheV6) RENAME TO record_log_indexes")
    }

    /// The identifier policy names must pass to be written into SQL as literals.
    static func isValidIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar == "_" || CharacterSet.alphanumerics.contains(scalar))
        }
    }

    /// A string literal for SQL.
    static func quoteLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
