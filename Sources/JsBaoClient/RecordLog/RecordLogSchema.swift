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
///   the segment the confirmed rows were last replaced from.
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
///   last read it, from which the view's lookup indexes are built
///   (``RecordLogIndexes``).
/// - `record_log_staged_base`: per document and record, the previous
///   completed generation's confirmed row (`_data` NULL when it had none) of
///   each record a staged full replacement has rewritten: the base a view
///   refresh guesses over until the replacement commits.
///
/// `record_log_owner` is this client's alone: the authenticated user the tables
/// belong to (the browser's store is scoped by user through its file's
/// namespace; this provider's file is one per app, so the owner is written down
/// and a sign-in as someone else resets the store). `record_log_meta` is
/// store-wide, as js-bao's: the storage version (``storageVersion``); a store
/// without it is version 1.
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
    ]

    /// The columns a store created by an earlier version lacks, with the
    /// statement that adds each: `CREATE TABLE IF NOT EXISTS` leaves an
    /// existing table as it was.
    static let addedColumns: [(table: String, column: String, add: String)] = [
        ("record_log_state", "receipt", "ALTER TABLE record_log_state ADD COLUMN receipt TEXT"),
        ("record_log_state", "segment", "ALTER TABLE record_log_state ADD COLUMN segment TEXT"),
        ("record_log_state", "staged", "ALTER TABLE record_log_state ADD COLUMN staged INTEGER"),
    ]

    /// The table naming the user the record-log tables belong to.
    static let ownerTable = "record_log_owner"

    /// The storage version a store is brought to at open (#4700): a db3's rows
    /// live in its view only, its indexes come from the room's list. Version 1
    /// kept the query projection (model tables with `_meta_doc_id`, their
    /// marks and rule, and indexes built from declarations). A build that
    /// changes the tables raises it: a store at the version runs no DDL at open.
    static let storageVersion = 2

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
          staged INTEGER
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
        """
        CREATE TABLE IF NOT EXISTS record_log_indexes (
          doc_id TEXT NOT NULL,
          model TEXT NOT NULL,
          fields TEXT NOT NULL,
          is_unique INTEGER NOT NULL DEFAULT 0,
          room_name TEXT,
          PRIMARY KEY (doc_id, model, fields)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS record_log_staged_base (
          doc_id TEXT NOT NULL,
          _type TEXT NOT NULL,
          _id TEXT NOT NULL,
          _data TEXT,
          PRIMARY KEY (doc_id, _type, _id)
        )
        """,
        "CREATE TABLE IF NOT EXISTS record_log_owner (user_id TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS record_log_meta (key TEXT PRIMARY KEY, value TEXT)",
    ]

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
