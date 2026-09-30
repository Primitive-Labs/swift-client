import Foundation

/// The file-backed query tables a large document's rows are projected into
/// (#3436, behavior 13, decision 3436-SO-05).
///
/// `Model.query()`, `count()` and `aggregate()` run ONE SQL statement against
/// derived tables that mirror the Y.Maps. A large document has no such maps —
/// its records are rows in its own store — so unless they are copied into
/// those tables, a filtered read can only answer without them, which is a
/// silent wrong answer, or refuse.
///
/// Three properties hold it together:
///
/// - **One connection.** The tables live in the storage provider's own
///   database, on the provider's own serial queue. Never a second handle on
///   the same file: `setupStorage`'s comment records the `SQLITE_BUSY` a
///   second handle produced under concurrent auth and data writes.
/// - **One transaction.** A model's rows and its `_query_projection` mark
///   commit together, and every later change commits with the merged row it
///   came from — so `query` and `find` cannot disagree, in either direction,
///   at any point.
/// - **Durable.** The rows and the mark survive a close, which is what keeps
///   reopening a document of this class cheap. A closed document does not
///   answer because the read is SCOPED to the documents that are connected,
///   not because its rows were thrown away; a purge (an eviction, an account
///   wipe) is what takes them.
///
/// Nothing here takes the query engine's own lock. A read takes that lock and
/// then enters the provider's queue; these writes are already on that queue
/// when the fold calls them, and a lock taken in the other order would close
/// a cycle.
public final class Format2QueryProjection: @unchecked Sendable {

    /// The engine the routed reads run on — the same tables, read side.
    public let engine: BaoModelQueryEngine

    private let host: any Format2SqlHost
    private let logger: Logger?

    private let lock = NSLock()
    /// The schema of every model that has been projected, by model name. The
    /// fold needs it to know which fields are stringsets and which column each
    /// value belongs in.
    private var schemas: [String: PrimitiveSchema] = [:]
    private var _projectionsRun = 0

    /// How many times a model's rows have been COPIED IN by this client.
    ///
    /// The mark makes that at most once per `(document, model)` for the life
    /// of the database, which is the property a reopen depends on, so this is
    /// how a test says "the reopen copied nothing" without inferring it from
    /// timing.
    internal var projectionsRun: Int { lock.withLock { _projectionsRun } }

    init(host: any Format2SqlHost, logger: Logger? = nil) {
        self.host = host
        self.logger = logger
        self.engine = BaoModelQueryEngine(host: host, logger: logger)
    }

    // MARK: - Projecting a model

    /// Copy every row `store` holds for `schema` into the query tables, and
    /// mark the model projected — in ONE transaction, so a failure part-way
    /// leaves neither and the next connect does it again.
    ///
    /// A no-op when the mark is already there: the rows are still on disk from
    /// the session that wrote them.
    ///
    /// - Returns: whether the rows were copied now.
    @discardableResult
    func ensureProjected(schema: PrimitiveSchema, store: Format2RecordStore) throws -> Bool {
        lock.withLock { schemas[schema.name] = schema }
        // Widen FIRST. `ensureTable` declares an index per indexed field, and
        // an index on a column the stored table does not have yet fails —
        // leaving the model without the indexes it asked for. After the widen
        // every column the schema names exists, so `ensureTable` can create
        // whatever is missing over it.
        try widenForNewFields(schema)
        engine.ensureTable(
            modelName: schema.name,
            fields: schema.fields.map {
                (name: $0.key, type: $0.value.type.toLegacyFieldType())
            },
            indexedFields: Set(schema.fields.compactMap { name, desc in
                (desc.indexed || desc.unique) ? name : nil
            }),
            withDocIdColumn: true,
            stringsetFields: Set(schema.fields.compactMap { name, desc in
                desc.type == .stringset ? name : nil
            })
        )
        guard try !store.hasQueryProjection(model: schema.name) else { return false }

        try store.transaction {
            var after: String?
            while true {
                let page = try store.readRowsAfter(
                    model: schema.name, after: after, limit: Self.projectionPage
                )
                guard !page.isEmpty else { break }
                for row in page {
                    guard let id = row["id"]?.stringValue else { continue }
                    try write(
                        model: schema.name, documentId: store.documentId,
                        id: id, row: row, store: store
                    )
                }
                after = page.last?["id"]?.stringValue
                if page.count < Self.projectionPage { break }
            }
            // The mark is inside the transaction with the rows. A mark without
            // its rows would make every later query answer short, for good —
            // the next connect would believe the work was done.
            try store.markQueryProjection(model: schema.name)
        }
        lock.withLock { _projectionsRun += 1 }
        logger?.debug(
            "[format2] projected", schema.name, "of", store.documentId,
            "into the query tables"
        )
        return true
    }

    /// Project every model this client has connected on `store`'s document
    /// again, after a reload replaced its rows (#3437, behaviors 21, 22 and 29).
    ///
    /// A rebuild discards the merged view AND the marks, so each of these
    /// calls copies afresh — the early return cannot fire, and what the tables
    /// end up holding is exactly the reloaded view. Reported rather than
    /// thrown for the same reason `ensureProjected`'s caller is: a derived
    /// table must not fail the reload of the document it is derived from, and
    /// what a failure leaves is no mark, so the next connect projects again.
    ///
    /// - Returns: the models that were copied.
    @discardableResult
    func reprojectAll(store: Format2RecordStore) -> [String] {
        var done: [String] = []
        for schema in lock.withLock({ Array(schemas.values) })
            .sorted(by: { $0.name < $1.name }) {
            do {
                if try ensureProjected(schema: schema, store: store) {
                    done.append(schema.name)
                }
            } catch {
                logger?.warn(
                    "[format2] the query projection of", schema.name, "of",
                    store.documentId, "did not commit after a reload:",
                    error.localizedDescription
                )
            }
        }
        return done
    }

    /// Rows are read in id-ordered pages rather than all at once: a document
    /// of this class does not fit in memory, and the walk is bounded by the
    /// page rather than by how far into the model it has read.
    private static let projectionPage = 1_000

    /// Give the table the columns this build's schema has, and re-project
    /// where it gained any.
    ///
    /// These tables are DURABLE, which the in-memory mirror never was: a table
    /// created by yesterday's app version is still here today, and `CREATE
    /// TABLE IF NOT EXISTS` leaves it exactly as it was. A model that gained a
    /// field would then have every projected write fail on a column that does
    /// not exist — and a fold whose write fails is a fold-broken document.
    ///
    /// So the column is added, and every mark for the model is withdrawn: the
    /// old rows hold no value for the new field, and a mark saying otherwise
    /// would make a filtered read on it answer short for every record written
    /// before the upgrade. Each document re-projects when it next connects.
    private func widenForNewFields(_ schema: PrimitiveSchema) throws {
        let table = BaoModelQueryEngine.sanitizeTableName(schema.name)
        let added: [String] = try host.withConnection { connection in
            let existing = Set(
                try connection.query("PRAGMA table_info(\"\(table)\")")
                    .compactMap { $0["name"].stringValue }
            )
            guard !existing.isEmpty else { return [] }
            var added: [String] = []
            for (name, descriptor) in schema.fields.sorted(by: { $0.key < $1.key })
            where name != "id" && descriptor.type != .stringset && !existing.contains(name) {
                try connection.execute(
                    "ALTER TABLE \"\(table)\" ADD COLUMN \"\(name)\" \(Self.columnType(descriptor.type))"
                )
                added.append(name)
            }
            guard !added.isEmpty else { return added }
            try connection.execute(
                "DELETE FROM _query_projection WHERE model = ?", [.text(schema.name)]
            )
            return added
        }
        guard !added.isEmpty else { return }
        logger?.debug(
            "[format2] query table for", schema.name, "gained",
            added.joined(separator: ", "), "— every document re-projects"
        )
    }

    /// The column type `BaoModelQueryEngine.ensureTable` would have declared.
    private static func columnType(_ type: PrimitiveFieldType) -> String {
        switch type.toLegacyFieldType() {
        case .number: return "REAL"
        case .boolean: return "INTEGER"
        default: return "TEXT"
        }
    }

    // MARK: - Keeping them current

    /// One record's projected row, rewritten from the merged view — or
    /// deleted, when the merged view no longer holds it.
    ///
    /// Called from inside the store's own transaction, on the provider's
    /// queue, so this commits with the merged row that caused it.
    func projectRow(model: String, recordId: String, in store: Format2RecordStore) throws {
        guard lock.withLock({ schemas[model] }) != nil else { return }
        guard try store.hasQueryProjection(model: model) else { return }
        let row = try store.read(model: model, recordId: recordId)
        try write(
            model: model, documentId: store.documentId,
            id: recordId, row: row, store: store
        )
    }

    /// Write (or delete) one projected row and its stringset members.
    private func write(
        model: String,
        documentId: String,
        id: String,
        row: [String: JSONValue]?,
        store: Format2RecordStore
    ) throws {
        guard let schema = lock.withLock({ schemas[model] }) else { return }
        let table = BaoModelQueryEngine.sanitizeTableName(model)
        let stringsets = schema.fields.compactMap { name, desc in
            desc.type == .stringset ? name : nil
        }.sorted()

        try host.withConnection { connection in
            for field in stringsets {
                let junction = "\(table)__\(field)"
                try connection.execute(
                    "DELETE FROM \"\(junction)\" WHERE \"_meta_doc_id\" = ? AND \"parent_id\" = ?",
                    [.text(documentId), .text(id)]
                )
            }
            guard let row else {
                try connection.execute(
                    "DELETE FROM \"\(table)\" WHERE \"_meta_doc_id\" = ? AND \"id\" = ?",
                    [.text(documentId), .text(id)]
                )
                return
            }

            var columns = ["_meta_doc_id", "id"]
            var values: [Format2SqlValue] = [.text(documentId), .text(id)]
            for (name, descriptor) in schema.fields.sorted(by: { $0.key < $1.key })
            where name != "id" && descriptor.type != .stringset {
                columns.append(name)
                values.append(Self.column(row[name], as: descriptor.type))
            }
            let quoted = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
            try connection.execute(
                "INSERT OR REPLACE INTO \"\(table)\" (\(quoted)) VALUES (\(placeholders))",
                values
            )

            for field in stringsets {
                let junction = "\(table)__\(field)"
                for member in try store.members(model: model, recordId: id, field: field) {
                    try connection.execute(
                        """
                        INSERT OR IGNORE INTO "\(junction)" \
                        ("_meta_doc_id", "parent_id", "value") VALUES (?, ?, ?)
                        """,
                        [.text(documentId), .text(id), .text(member)]
                    )
                }
            }
        }
    }

    /// What one field's stored JSON binds as, spelled exactly as the
    /// nested-map path spells it (`DynamicModel.sqliteRepresentation`): a
    /// `json` field is its TEXT, everything else its scalar. One column
    /// content for both layouts is what lets one query answer over both.
    static func column(_ value: JSONValue?, as type: PrimitiveFieldType) -> Format2SqlValue {
        guard let value, value != .null else { return .null }
        if type == .json {
            switch value {
            case .object, .array:
                guard let data = try? JSONCoding.encodeData(value),
                      let text = String(data: data, encoding: .utf8)
                else { return .null }
                return .text(text)
            default:
                break
            }
        }
        return Format2SqlValue(json: value)
    }

}
