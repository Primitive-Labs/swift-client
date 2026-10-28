import XCTest
@testable import JsBaoClient

/// #4700 behaviour 21 and edge 32: a store from before the view path, opened
/// after it, is brought to storage version 2 once, in one transaction: every
/// projection table (a `_meta_doc_id` column) and its junctions, the
/// projection marks and rule, and the view indexes the store built from
/// declarations are dropped; `record_log_meta.storage_version` reads 2; every
/// record is kept. A store at version 2 is answered by one version read and one
/// `sqlite_master` probe, and retired again when an older build has recreated
/// the projection layout since (finding 4700-R1).
final class RecordLogStorageVersionHermeticTests: XCTestCase {

    /// The record-log tables as the build before #4700 created them,
    /// statement for statement (`RecordLogSchema.ddl` at 5d6a8a334).
    private static let version1DDL: [String] = [
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
          segment TEXT
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
        CREATE TABLE IF NOT EXISTS record_log_projection (
          doc_id TEXT NOT NULL,
          model TEXT NOT NULL,
          PRIMARY KEY (doc_id, model)
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
        "CREATE TABLE IF NOT EXISTS record_log_owner (user_id TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS record_log_projection_rule (rule INTEGER NOT NULL)",
    ]

    private static let documentId = "rl-version"

    private var directory = ""
    private let lines = LockedBox<[String]>([])

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "/record-log-version-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let lines = lines
        Logger.lineForTest = { _, _, message in
            if message.contains("storage version") { lines.withValue { $0.append(message) } }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func provider() async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func store(_ provider: SQLiteStorageProvider) -> RecordLogStore {
        RecordLogStore(host: provider, documentId: Self.documentId, clientId: "client-1", logger: Logger(level: .info))
    }

    private func rows(_ provider: SQLiteStorageProvider, _ sql: String) throws -> [[String: Format2SqlValue]] {
        try provider.withConnection { try $0.query(sql) }.map(\.columns)
    }

    private func names(_ provider: SQLiteStorageProvider, _ type: String) throws -> Set<String> {
        Set(try rows(provider, "SELECT name FROM sqlite_master WHERE type = '\(type)'").compactMap { $0["name"]?.stringValue })
    }

    private func version(_ provider: SQLiteStorageProvider) throws -> String? {
        try rows(provider, "SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"]?.stringValue
    }

    /// What a store holds of its documents, table by table.
    private func records(_ provider: SQLiteStorageProvider) throws -> [String: [[String: Format2SqlValue]]] {
        var out: [String: [[String: Format2SqlValue]]] = [:]
        for (table, order) in [
            ("record_log_rows", "_id"), ("record_log_view", "_id"), ("record_log_state", "doc_id"),
            ("record_log_pending", "seq"), ("record_log_pending_keys", "seq"), ("record_log_writers", "client_id"),
        ] {
            out[table] = try rows(provider, "SELECT * FROM \(table) ORDER BY \(order)")
        }
        // The `staged` column a store gains at open (#4701) is no record.
        out["record_log_state"] = out["record_log_state"]?.map { $0.filter { $0.key != "staged" } }
        return out
    }

    /// The projection layout an older build keeps beside the view: a model's
    /// table and its set junction (both with `_meta_doc_id`), the marks, the
    /// rule, and the view and rows indexes it built from declarations.
    private func projectionLayout(_ connection: any Format2SqlConnection, rule: Bool = true) throws {
        try connection.executeScript(
            "CREATE TABLE IF NOT EXISTS \"Item\" (\"_meta_doc_id\" TEXT NOT NULL, \"id\" TEXT NOT NULL, \"n\" REAL, PRIMARY KEY (\"_meta_doc_id\", \"id\"))"
        )
        try connection.executeScript(
            "CREATE TABLE IF NOT EXISTS \"Item__tags\" (\"_meta_doc_id\" TEXT NOT NULL, \"parent_id\" TEXT NOT NULL, \"value\" TEXT NOT NULL)"
        )
        try connection.execute("INSERT INTO \"Item\" (\"_meta_doc_id\", \"id\", \"n\") VALUES (?, 'i1', 5)", [.text(Self.documentId)])
        try connection.execute(
            "INSERT INTO \"Item__tags\" (\"_meta_doc_id\", \"parent_id\", \"value\") VALUES (?, 'i1', 'a')", [.text(Self.documentId)]
        )
        try connection.executeScript("CREATE TABLE IF NOT EXISTS record_log_projection (doc_id TEXT NOT NULL, model TEXT NOT NULL, PRIMARY KEY (doc_id, model))")
        try connection.execute("INSERT OR IGNORE INTO record_log_projection (doc_id, model) VALUES (?, 'Item')", [.text(Self.documentId)])
        if rule {
            try connection.executeScript("CREATE TABLE IF NOT EXISTS record_log_projection_rule (rule INTEGER NOT NULL)")
            try connection.execute("DELETE FROM record_log_projection_rule", [])
            try connection.execute("INSERT INTO record_log_projection_rule (rule) VALUES (1)", [])
        }
        try connection.executeScript(
            "CREATE INDEX IF NOT EXISTS idx_record_log_view_f4_item_n ON record_log_view(doc_id, json_extract(_data, '$.n'), _id) WHERE _type = 'Item'"
        )
        try connection.executeScript(
            "CREATE INDEX IF NOT EXISTS idx_record_log_view_u4_item_by_n ON record_log_view(doc_id, json_extract(_data, '$.n'), _id) WHERE _type = 'Item'"
        )
    }

    /// A store as the build before #4700 wrote it: its tables, one record
    /// confirmed and one pending, and the projection layout beside them.
    private func version1Store() async throws -> SQLiteStorageProvider {
        let provider = try await provider()
        try provider.withConnection { connection in
            for statement in Self.version1DDL { try connection.executeScript(statement) }
            let data = #"{"id":"i1","n":5,"tags":["a"]}"#
            for table in ["record_log_rows", "record_log_view"] {
                try connection.execute(
                    "INSERT INTO \(table) (doc_id, _type, _id, _data) VALUES (?, 'Item', 'i1', ?)", [.text(Self.documentId), .text(data)]
                )
            }
            try connection.execute("INSERT INTO record_log_state (doc_id, cursor) VALUES (?, 7)", [.text(Self.documentId)])
            try connection.execute(
                "INSERT INTO record_log_writers (doc_id, client_id, writer, next_seq) VALUES (?, 'client-1', 'W1', 2)",
                [.text(Self.documentId)]
            )
            try connection.execute(
                "INSERT INTO record_log_pending (doc_id, writer, seq, ord, e, entry) VALUES (?, 'W1', 1, 1, 1, '{}')",
                [.text(Self.documentId)]
            )
            try connection.execute(
                "INSERT INTO record_log_pending_keys (doc_id, writer, seq, _type, _id) VALUES (?, 'W1', 1, 'Item', 'i1')",
                [.text(Self.documentId)]
            )
            try connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_record_log_rows_f4_item_n ON record_log_rows(doc_id, json_extract(_data, '$.n'), _id) WHERE _type = 'Item'",
                []
            )
            try projectionLayout(connection)
        }
        return provider
    }

    private func assertRetired(_ provider: SQLiteStorageProvider, file: StaticString = #filePath, line: UInt = #line) throws {
        let tables = try names(provider, "table")
        for gone in ["Item", "Item__tags", "record_log_projection", "record_log_projection_rule"] {
            XCTAssertFalse(tables.contains(gone), "\(gone) is dropped", file: file, line: line)
        }
        let derived = try rows(provider, """
            SELECT m.name AS name FROM sqlite_master m WHERE m.type = 'table'
              AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = '_meta_doc_id')
            """)
        XCTAssertEqual(derived.count, 0, "no table with a _meta_doc_id column: \(derived)", file: file, line: line)
        let declared = try names(provider, "index").filter {
            $0.hasPrefix("idx_record_log_view_f") || $0.hasPrefix("idx_record_log_view_u")
        }
        XCTAssertEqual(declared, [], "the declaration-built view indexes are dropped", file: file, line: line)
        XCTAssertEqual(try version(provider), "2", file: file, line: line)
    }

    // MARK: - Behaviour 21

    func testAStoreFromBeforeTheViewPathIsRetiredOnceKeepingEveryRecord() async throws {
        let provider = try await version1Store()
        let before = try records(provider)
        XCTAssertEqual(before["record_log_view"]?.count, 1)

        try store(provider).initialize()
        try assertRetired(provider)
        XCTAssertEqual(try records(provider), before, "every record is kept")
        XCTAssertEqual(lines.value.count, 1, "one line names the version: \(lines.value)")
        XCTAssertTrue(lines.value.first?.contains("storage version 2") ?? false, lines.value.first ?? "")

        // A second open reads the version and probes for an older build's layout, nothing more.
        lines.value = []
        let trace = try RecordLogStatementTrace.install(on: provider, self)
        try store(provider).initialize()
        let ran = trace.statements.filter { statement in
            !["BEGIN", "COMMIT", "ROLLBACK", "PRAGMA", "SAVEPOINT", "RELEASE"].contains {
                statement.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix($0)
            }
        }
        XCTAssertEqual(ran.count, 2, "one version read and one sqlite_master probe: \(ran)")
        XCTAssertTrue(ran.first?.contains("record_log_meta") ?? false, "\(ran)")
        XCTAssertTrue(ran.last?.contains("sqlite_master") ?? false, "\(ran)")
        XCTAssertEqual(lines.value, [], "nothing to drop, nothing logged")
        XCTAssertEqual(try records(provider), before)
    }

    func testAnOlderBuildsRecreatedLayoutIsRetiredAgainAtVersion2() async throws {
        let provider = try await version1Store()
        try store(provider).initialize()
        let before = try records(provider)
        // An older build opened the store since: it recreated its layout and
        // left the marker as it found it.
        try provider.withConnection { try projectionLayout($0) }
        XCTAssertEqual(try version(provider), "2")
        lines.value = []

        try store(provider).initialize()
        try assertRetired(provider)
        XCTAssertEqual(try records(provider), before, "every record and the marker kept")
        XCTAssertEqual(lines.value.count, 1, "the drop is logged once: \(lines.value)")
    }

    // MARK: - Edge 32

    func testTheMigrationRunsUnderSetOwnerAndAgainWhenItsMarkerIsDeleted() async throws {
        let provider = try await version1Store()
        try RecordLogStore.setOwner(host: provider, userId: "user-a")
        try assertRetired(provider)
        XCTAssertEqual(try RecordLogStore.owner(host: provider), "user-a")

        try provider.withConnection { try $0.execute("DELETE FROM record_log_meta", []) }
        XCTAssertNil(try version(provider))
        try store(provider).initialize()
        try assertRetired(provider)
    }

    // MARK: - Finding 4700-I2: a purge of a store from before the view path

    /// An owner change resets the store before any binding migrated it: the
    /// reset clears every current table, `record_log_indexes` among them, so
    /// the store is brought to the version first.
    func testAnOwnerChangeResetsAStoreFromBeforeTheViewPath() async throws {
        let provider = try await version1Store()
        try provider.withConnection { try $0.execute("INSERT INTO record_log_owner (user_id) VALUES ('user-a')", []) }

        XCTAssertEqual(try RecordLogStore.purgeAll(host: provider), 1, "the one unsent write is dropped")
        try RecordLogStore.setOwner(host: provider, userId: "user-b")
        try assertRetired(provider)
        XCTAssertEqual(try RecordLogStore.owner(host: provider), "user-b")
        XCTAssertEqual(try records(provider).values.map(\.count), [0, 0, 0, 0, 0, 0], "every document's rows are gone")
    }

    /// Purging a document no binding opened since the upgrade.
    func testPurgingAnUnopenedDocumentOfAStoreFromBeforeTheViewPath() async throws {
        let provider = try await version1Store()
        let reply = try store(provider).purge(force: true)
        XCTAssertTrue(reply.purged)
        XCTAssertFalse(reply.nothingStored)
        try assertRetired(provider)
        XCTAssertEqual(try records(provider).values.map(\.count), [0, 0, 0, 0, 0, 0], "the document's rows are gone")
    }

    /// A database that never held a record-log table stays without one.
    func testPurgingAStoreWithNoRecordLogTablesCreatesNone() async throws {
        let provider = try await provider()
        XCTAssertEqual(try RecordLogStore.purgeAll(host: provider), 0)
        XCTAssertTrue(try store(provider).purge(force: true).nothingStored)
        XCTAssertEqual(try names(provider, "table").filter { $0.hasPrefix("record_log_") }, [])
    }

    // MARK: - #4701 edge 50: the staged replacement's column and table, added without a version change

    /// A store a build before #4701 brought to version 2 (no `staged` column,
    /// no `record_log_staged_base`) gains both at the next open, with the
    /// version unchanged and every record kept.
    func testAVersion2StoreFromBeforeTheStagedReplacementGainsItsColumnAndTableAtOpen() async throws {
        let provider = try await version1Store()
        try store(provider).initialize()
        try provider.withConnection { connection in
            if try connection.query("SELECT 1 AS present FROM pragma_table_info('record_log_state') WHERE name = 'staged'").first != nil {
                try connection.executeScript("ALTER TABLE record_log_state DROP COLUMN staged")
            }
            try connection.executeScript("DROP TABLE IF EXISTS record_log_staged_base")
        }
        let before = try records(provider)
        XCTAssertEqual(try version(provider), "2")

        try store(provider).initialize()
        XCTAssertEqual(try version(provider), "2", "no version change")
        XCTAssertTrue(try names(provider, "table").contains("record_log_staged_base"))
        let columns = try rows(provider, "SELECT name FROM pragma_table_info('record_log_state')").compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(columns.last, "staged")
        let after = try records(provider)
        XCTAssertEqual(after.mapValues(\.count), before.mapValues(\.count), "every record kept")
        XCTAssertEqual(after["record_log_view"], before["record_log_view"])
        XCTAssertEqual(after["record_log_pending"], before["record_log_pending"])
        XCTAssertTrue(try rows(provider, "SELECT staged FROM record_log_state").first?["staged"]?.isNull ?? false, "the added column is NULL")
        XCTAssertFalse(try store(provider).storedState().staged)
    }
}
