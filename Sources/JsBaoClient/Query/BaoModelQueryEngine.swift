import Foundation
import SQLite3

/// SQLite-backed query engine that mirrors Y.Map model data for fast queries.
///
/// Each model gets its own table in an in-memory SQLite database.
/// Records are synced from Y.Map on initial load and kept in sync via
/// explicit calls to `sync()` after mutations.
///
/// This replaces the JS client's IndexedDB/sql.js approach with native SQLite.
public class BaoModelQueryEngine {

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Test-only counter: incremented on every successful single-row
    /// write (`upsertRecord` / `deleteRecord`). Tests assert that a
    /// single field-level mutation produces at most one row write —
    /// the core performance win over the old bulk-rebuild path.
    ///
    /// Stringset junction-row writes are also counted here. A mutation
    /// on a K-member stringset field therefore adds up to K rows to
    /// this counter (one per member, plus one for the main-row upsert).
    internal private(set) var rowWriteCount: Int = 0

    /// Every junction table registered so far, keyed by its SQLite
    /// name. If two distinct `(model, field)` pairs would produce the
    /// same junction name, we fail-fast instead of silently sharing
    /// the table. See `Primitive-Labs/js-bao#14` for the collision
    /// classes this guards against.
    private var registeredJunctions: [String: (model: String, field: String)] = [:]

    /// Per-model set of scalar string-typed field names, captured at
    /// `ensureTable` time. Used by `QueryTranslator` to gate substring
    /// operators ($startsWith / $endsWith / $containsText): if the
    /// target field isn't a string or stringset, the translator emits
    /// `0` instead of letting SQLite coerce a numeric/boolean column
    /// to text and silently match digits. Matches js-bao's
    /// `DocumentQueryTranslator.ts:309` field-type gate (which throws).
    private var stringFieldsByModel: [String: Set<String>] = [:]

    public init() {
        var db: OpaquePointer?
        // Use in-memory SQLite for query indexing (separate from persistence)
        if sqlite3_open(":memory:", &db) == SQLITE_OK {
            self.db = db
            // Enable WAL for concurrent reads.
            execute("PRAGMA journal_mode=WAL")
            // NORMAL is a good balance: skips fsync on every commit (fast)
            // but still syncs at WAL checkpoints (durable enough). OFF
            // disables fsync entirely and risks file-level corruption on
            // a crash, which is rarely a worthwhile trade for user data.
            execute("PRAGMA synchronous=NORMAL")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Table Management

    /// Create or update a table for a model, with columns for each field.
    ///
    /// - Parameters:
    ///   - modelName: logical model name (used as table name).
    ///   - fields: every field, used to declare columns.
    ///   - indexedFields: if non-nil, only these fields get a
    ///     `CREATE INDEX`. If nil, every non-id column is indexed —
    ///     legacy behavior used by `BaoModel<T>`. `DynamicModel`
    ///     passes the set derived from `indexed: true` / `unique: true`.
    ///   - withDocIdColumn: when `true`, adds a `_meta_doc_id TEXT`
    ///     column with a compound `(_meta_doc_id, id)` primary key and
    ///     an index on `_meta_doc_id`. Lets one engine instance host
    ///     records from multiple YDocuments (matches js-bao's shared
    ///     `dbInstance` design). Default is `false` for backward
    ///     compatibility with legacy `BaoModel<T>` callers.
    public func ensureTable(
        modelName: String,
        fields: [(name: String, type: FieldType)],
        indexedFields: Set<String>? = nil,
        withDocIdColumn: Bool = false,
        stringsetFields: Set<String> = []
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Capture scalar string fields for substring-op type gating
        // (see `stringFieldsByModel` doc comment). Done up-front so
        // every subsequent query/queryPaged/count/aggregate call can
        // consult the same record without re-walking the field list.
        stringFieldsByModel[modelName] = Set(
            fields.compactMap { $0.type == .string ? $0.name : nil }
        )

        let tableName = sanitizedTableName(modelName)
        var columns: [String]
        if withDocIdColumn {
            // Compound PK lets the same record id exist in multiple
            // docs without conflict.
            columns = [
                "\"_meta_doc_id\" TEXT NOT NULL",
                "\"id\" TEXT NOT NULL",
            ]
        } else {
            columns = ["\"id\" TEXT PRIMARY KEY"]
        }

        // Stringset fields don't get a column on the main table —
        // their data lives in a per-field junction table (see below).
        for field in fields where field.name != "id" && !stringsetFields.contains(field.name) {
            let sqlType: String
            switch field.type {
            case .number: sqlType = "REAL"
            case .boolean: sqlType = "INTEGER"
            default: sqlType = "TEXT"
            }
            columns.append("\"\(field.name)\" \(sqlType)")
        }

        if withDocIdColumn {
            columns.append("PRIMARY KEY (\"_meta_doc_id\", \"id\")")
        }

        let sql = "CREATE TABLE IF NOT EXISTS \"\(tableName)\" (\(columns.joined(separator: ", ")))"
        execute(sql)

        if withDocIdColumn {
            execute("CREATE INDEX IF NOT EXISTS \"idx_\(tableName)__meta_doc_id\" ON \"\(tableName)\"(\"_meta_doc_id\")")
        }
        for field in fields where field.name != "id" && !stringsetFields.contains(field.name) {
            if let allowed = indexedFields, !allowed.contains(field.name) {
                continue
            }
            execute("CREATE INDEX IF NOT EXISTS \"idx_\(tableName)_\(field.name)\" ON \"\(tableName)\"(\"\(field.name)\")")
        }

        // Junction tables for stringset fields. Double-underscore
        // delimiter (diverging from js-bao's single underscore) so
        // `(users, posts_tags)` and `(users_posts, tags)` don't
        // collapse to the same junction name. Collision detection
        // below catches the remaining edge cases.
        for field in fields where stringsetFields.contains(field.name) {
            ensureJunctionTable(
                modelName: modelName,
                fieldName: field.name,
                withDocIdColumn: withDocIdColumn
            )
        }
    }

    /// Create the per-field junction table that stores a stringset's
    /// members. Matches js-bao's layout (one row per member, exact-
    /// match `value` column) with our double-underscore name
    /// separator.
    ///
    /// Single-doc: PK `(parent_id, value)`.
    /// Multi-doc (sharedEngine): PK `(_meta_doc_id, parent_id, value)`
    /// — same compound PK shape as the main table, so disconnects
    /// can sweep by `_meta_doc_id` alone.
    private func ensureJunctionTable(
        modelName: String,
        fieldName: String,
        withDocIdColumn: Bool
    ) {
        let junctionName = junctionTableName(
            modelName: modelName, fieldName: fieldName
        )
        // Collision check — if another (model, field) pair already
        // claimed this name, fail-fast. Same table for two different
        // stringset fields would silently interleave their members.
        if let existing = registeredJunctions[junctionName],
           existing.model != modelName || existing.field != fieldName {
            preconditionFailure("""
            Junction-table name collision on '\(junctionName)'.
            First registered by model='\(existing.model)' field='\(existing.field)'.
            Now requested by model='\(modelName)' field='\(fieldName)'.
            Rename one of the fields so the composed name is unique.
            """)
        }
        registeredJunctions[junctionName] = (model: modelName, field: fieldName)

        var columns: [String] = []
        if withDocIdColumn {
            columns.append("\"_meta_doc_id\" TEXT NOT NULL")
        }
        columns.append("\"parent_id\" TEXT NOT NULL")
        columns.append("\"value\" TEXT NOT NULL")
        let pk = withDocIdColumn
            ? "PRIMARY KEY (\"_meta_doc_id\", \"parent_id\", \"value\")"
            : "PRIMARY KEY (\"parent_id\", \"value\")"
        columns.append(pk)

        execute("CREATE TABLE IF NOT EXISTS \"\(junctionName)\" (\(columns.joined(separator: ", ")))")
    }

    /// Composed junction-table name.  Double underscore separator to
    /// reduce ambiguity vs js-bao's single underscore.
    internal func junctionTableName(modelName: String, fieldName: String) -> String {
        "\(sanitizedTableName(modelName))__\(fieldName)"
    }

    /// Test-only helper for schema/index introspection.
    public func rawQuery(_ sql: String, params: [Any] = []) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return executeQuery(sql, params: params)
    }

    // MARK: - Data Sync

    /// Sync all records from a model into the SQLite table.
    /// Call this after opening a document or after batch mutations.
    public func syncRecords(modelName: String, records: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(modelName)

        // Clear existing data
        execute("DELETE FROM \"\(tableName)\"")

        guard !records.isEmpty else { return }

        // Get column names from the table
        let columnNames = getColumnNames(tableName)
        guard !columnNames.isEmpty else { return }

        let placeholders = columnNames.map { _ in "?" }.joined(separator: ",")
        let quotedCols = columnNames.map { "\"\($0)\"" }.joined(separator: ",")
        let sql = "INSERT OR REPLACE INTO \"\(tableName)\" (\(quotedCols)) VALUES (\(placeholders))"

        guard let stmt = prepare(sql) else { return }

        for record in records {
            sqlite3_reset(stmt)
            for (idx, col) in columnNames.enumerated() {
                bindValue(stmt, index: Int32(idx + 1), value: record[col])
            }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Insert or update a single record. Called per-record from
    /// `DynamicModel` when the Y.Map changes — replaces the previous
    /// bulk `syncRecords` rebuild.
    ///
    /// - Parameters:
    ///   - record: scalar field values. Stringset fields MUST NOT
    ///     appear here — pass them via `stringsets` instead. The
    ///     main table no longer has stringset columns, so an
    ///     accidental stringset in `record` is ignored.
    ///   - stringsets: per-field member lists. Each field's junction
    ///     table is rewritten wholesale: existing rows for
    ///     `(parent_id, [_meta_doc_id])` are deleted, then new rows
    ///     are inserted. Omit a field to leave its junction
    ///     untouched; pass an empty array to clear it.
    public func upsertRecord(
        modelName: String,
        record: [String: Any],
        stringsets: [String: [String]] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(modelName)
        let columnNames = getColumnNames(tableName)
        if !columnNames.isEmpty {
            let quotedCols = columnNames.map { "\"\($0)\"" }.joined(separator: ",")
            let placeholders = columnNames.map { _ in "?" }.joined(separator: ",")
            let sql = "INSERT OR REPLACE INTO \"\(tableName)\" (\(quotedCols)) VALUES (\(placeholders))"

            if let stmt = prepare(sql) {
                for (idx, col) in columnNames.enumerated() {
                    bindValue(stmt, index: Int32(idx + 1), value: record[col])
                }
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                rowWriteCount += 1
            }
        }

        // Junction-table writes. Replace-all semantics per parent:
        // we clear the parent's existing members before inserting the
        // new ones. Scoped by `_meta_doc_id` when the main row carries
        // one — otherwise scoped only by `parent_id`.
        let parentId = record["id"] as? String ?? ""
        let docId = record["_meta_doc_id"] as? String
        for (fieldName, members) in stringsets {
            writeJunction(
                modelName: modelName,
                fieldName: fieldName,
                parentId: parentId,
                docId: docId,
                members: members
            )
        }
    }

    /// Replace the junction rows for one `(parent, field)` pair.
    /// Caller holds `lock`.
    private func writeJunction(
        modelName: String,
        fieldName: String,
        parentId: String,
        docId: String?,
        members: [String]
    ) {
        let junction = junctionTableName(
            modelName: modelName, fieldName: fieldName
        )

        // Clear old members first so the "replace" semantic holds
        // even when `members.isEmpty`.
        var deleteSQL = "DELETE FROM \"\(junction)\" WHERE \"parent_id\" = ?"
        if docId != nil {
            deleteSQL += " AND \"_meta_doc_id\" = ?"
        }
        if let stmt = prepare(deleteSQL) {
            sqlite3_bind_text(stmt, 1, (parentId as NSString).utf8String, -1, nil)
            if let docId {
                sqlite3_bind_text(stmt, 2, (docId as NSString).utf8String, -1, nil)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        guard !members.isEmpty else { return }

        let colList: String
        let placeholders: String
        if docId != nil {
            colList = "\"_meta_doc_id\", \"parent_id\", \"value\""
            placeholders = "?, ?, ?"
        } else {
            colList = "\"parent_id\", \"value\""
            placeholders = "?, ?"
        }
        let insertSQL = "INSERT OR IGNORE INTO \"\(junction)\" (\(colList)) VALUES (\(placeholders))"
        guard let stmt = prepare(insertSQL) else { return }
        for member in members {
            sqlite3_reset(stmt)
            var idx: Int32 = 1
            if let docId {
                sqlite3_bind_text(stmt, idx, (docId as NSString).utf8String, -1, nil)
                idx += 1
            }
            sqlite3_bind_text(stmt, idx, (parentId as NSString).utf8String, -1, nil)
            idx += 1
            sqlite3_bind_text(stmt, idx, (member as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            rowWriteCount += 1
        }
        sqlite3_finalize(stmt)
    }

    /// Delete a record by ID. When `scopedToDocId` is supplied, only
    /// the row with that `(_meta_doc_id, id)` pair is removed —
    /// required when a shared engine hosts records from multiple docs.
    public func deleteRecord(
        modelName: String,
        id: String,
        scopedToDocId: String? = nil,
        stringsetFields: Set<String> = []
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Junction rows first so a partially-failed delete doesn't
        // leave stringset orphans pointing at a gone parent row.
        for field in stringsetFields {
            writeJunction(
                modelName: modelName, fieldName: field,
                parentId: id, docId: scopedToDocId,
                members: [] // empty → pure DELETE, no INSERT
            )
        }

        let tableName = sanitizedTableName(modelName)
        var sql = "DELETE FROM \"\(tableName)\" WHERE \"id\" = ?"
        if scopedToDocId != nil {
            sql += " AND \"_meta_doc_id\" = ?"
        }
        guard let stmt = prepare(sql) else { return }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        if let docId = scopedToDocId {
            sqlite3_bind_text(stmt, 2, (docId as NSString).utf8String, -1, nil)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        rowWriteCount += 1
    }

    /// Sweep every junction row belonging to one docId across the
    /// stringset fields it owns. Used by `MultiDocModel.disconnect`
    /// to wipe a doc's contribution from the shared store in one
    /// pass. `value` column isn't indexed independently of PK, so we
    /// rely on the leading `_meta_doc_id` column of the compound PK.
    /// Build the SELECT column list for the main-table query. When
    /// `projection` is nil, expand to `*` minus stringset columns
    /// (which don't exist on the main table but just so we're explicit
    /// about what's selected). When include-mode, we list the
    /// projected columns plus `id` + `_meta_doc_id`. When exclude-
    /// mode, we list every existing column except the projected-out
    /// ones (but always keep `id` + `_meta_doc_id`).
    ///
    /// Stringset fields are NEVER in the SELECT list (they have no
    /// main-table column); `populateStringsets` fills them in post-
    /// query based on the same projection.
    ///
    /// **Lock contract**: caller holds `lock`. This helper reads
    /// table schema via `getColumnNames` which itself does not take
    /// the lock (the lock guards `db`, and we're operating on read
    /// queries through `executeQuery` inside `getColumnNames` which
    /// runs under the caller's lock already).
    private func buildSelectColumnList(
        tableName: String,
        projection: [String: Int]?,
        stringsetFields: Set<String>
    ) -> String {
        guard let projection, !projection.isEmpty else { return "*" }
        // Validate: no mixed include + exclude (matches js-bao
        // which also rejects mixed projections).
        let values = Set(projection.values)
        precondition(values.count <= 1 || !(values.contains(0) && values.contains(1)),
                     "Projection cannot mix include (1) and exclude (0) values")

        // Column names actually present on the table. Caller already
        // holds `lock` (the deadlock we had earlier was from a second
        // `lock.lock()` here).
        let tableCols = Set(getColumnNames(tableName))

        let isIncludeMode = values.contains(1)
        var selected: Set<String> = []

        if isIncludeMode {
            // Start with the requested fields, keep only those that
            // are real main-table columns (stringsets aren't on the
            // main table). Then always add id + _meta_doc_id.
            for (field, flag) in projection where flag == 1 {
                if tableCols.contains(field) { selected.insert(field) }
            }
            selected.insert("id")
            if tableCols.contains("_meta_doc_id") {
                selected.insert("_meta_doc_id")
            }
        } else {
            // Exclude-mode: start with every table column, drop the
            // projected-out names. id + _meta_doc_id never dropped.
            selected = tableCols
            for (field, flag) in projection where flag == 0 {
                if field != "id" && field != "_meta_doc_id" {
                    selected.remove(field)
                }
            }
        }
        _ = stringsetFields // stringsets don't appear in SELECT either way

        // Deterministic column order for readable SQL.
        return selected.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
    }

    /// After a main-table SELECT, fill each row's stringset fields
    /// with `[String]` arrays loaded from the junction tables. Batched
    /// one query per stringset field — N×K → K queries for N rows and
    /// K fields. Caller must NOT hold `lock` (this takes it per-field).
    ///
    /// When `projection` is provided we skip fields that the caller
    /// asked us not to return (exclude-mode) or didn't ask for
    /// (include-mode).
    private func populateStringsets(
        rows: inout [[String: Any]],
        modelName: String,
        stringsetFields: Set<String>,
        projection: [String: Int]? = nil
    ) {
        let effectiveFields = projectedStringsetFields(
            stringsetFields: stringsetFields, projection: projection
        )
        // Original signature ignored projection — keep the rest of
        // the body operating on `effectiveFields`.
        return populateStringsetsFiltered(
            rows: &rows, modelName: modelName,
            stringsetFields: effectiveFields
        )
    }

    /// Apply the projection to the set of stringset fields that
    /// should be populated. Include-mode: keep only the ones listed.
    /// Exclude-mode: drop the ones listed. `nil` projection keeps
    /// everything.
    private func projectedStringsetFields(
        stringsetFields: Set<String>,
        projection: [String: Int]?
    ) -> Set<String> {
        guard let projection, !projection.isEmpty else { return stringsetFields }
        let values = Set(projection.values)
        let isIncludeMode = values.contains(1)
        if isIncludeMode {
            let included = Set(projection.filter { $0.value == 1 }.map { $0.key })
            return stringsetFields.intersection(included)
        } else {
            let excluded = Set(projection.filter { $0.value == 0 }.map { $0.key })
            return stringsetFields.subtracting(excluded)
        }
    }

    private func populateStringsetsFiltered(
        rows: inout [[String: Any]],
        modelName: String,
        stringsetFields: Set<String>
    ) {
        guard !rows.isEmpty, !stringsetFields.isEmpty else {
            // Still populate every absent stringset field with [] so
            // callers get a deterministic shape.
            for i in rows.indices {
                for field in stringsetFields where rows[i][field] == nil {
                    rows[i][field] = [String]()
                }
            }
            return
        }
        for field in stringsetFields {
            populateOneStringsetField(
                rows: &rows, modelName: modelName, fieldName: field
            )
        }
    }

    /// One junction query → group-by parent → attach to rows.
    /// When the engine has a `_meta_doc_id` column, the group key is
    /// `(doc_id, parent_id)` since the same parent id can repeat
    /// across docs.
    private func populateOneStringsetField(
        rows: inout [[String: Any]],
        modelName: String,
        fieldName: String
    ) {
        let junction = junctionTableName(modelName: modelName, fieldName: fieldName)
        // Collect (docId, parentId) keys from the rows.
        struct Key: Hashable { let doc: String; let parent: String }
        var keys: Set<Key> = []
        for row in rows {
            guard let parent = row["id"] as? String else { continue }
            let doc = row["_meta_doc_id"] as? String ?? ""
            keys.insert(Key(doc: doc, parent: parent))
        }
        guard !keys.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // Check junction schema for `_meta_doc_id` column — if absent,
        // we're in single-doc mode and query by parent_id alone.
        let junctionCols = Set(getColumnNames(junction))
        let hasDocId = junctionCols.contains("_meta_doc_id")

        // Build one SELECT per batch. Chunk IN-list if very large to
        // avoid blowing SQLite's parameter limit (~999). Typical
        // client query pages are small; this matters only for big
        // bulk reads.
        let parentIds = Array(Set(keys.map { $0.parent }))
        let chunkSize = 500
        var grouped: [Key: [String]] = [:]

        for chunkStart in stride(from: 0, to: parentIds.count, by: chunkSize) {
            let chunk = Array(parentIds[chunkStart..<min(chunkStart + chunkSize, parentIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let selectList = hasDocId ? "\"_meta_doc_id\", \"parent_id\", \"value\"" : "\"parent_id\", \"value\""
            let sql = "SELECT \(selectList) FROM \"\(junction)\" WHERE \"parent_id\" IN (\(placeholders))"
            let resultRows = executeQuery(sql, params: chunk)
            for r in resultRows {
                let doc = r["_meta_doc_id"] as? String ?? ""
                guard let p = r["parent_id"] as? String,
                      let v = r["value"] as? String else { continue }
                grouped[Key(doc: doc, parent: p), default: []].append(v)
            }
        }

        for i in rows.indices {
            let parent = rows[i]["id"] as? String ?? ""
            let doc = rows[i]["_meta_doc_id"] as? String ?? ""
            rows[i][fieldName] = grouped[Key(doc: doc, parent: parent)] ?? []
        }
    }

    public func deleteAllStringsetRows(
        modelName: String,
        scopedToDocId: String,
        stringsetFields: Set<String>
    ) {
        lock.lock()
        defer { lock.unlock() }
        for field in stringsetFields {
            let junction = junctionTableName(
                modelName: modelName, fieldName: field
            )
            let sql = "DELETE FROM \"\(junction)\" WHERE \"_meta_doc_id\" = ?"
            if let stmt = prepare(sql) {
                sqlite3_bind_text(stmt, 1, (scopedToDocId as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Query

    /// Execute a query with filter and options, returning raw dictionaries.
    /// `scopedToDocId` (when non-nil) restricts the query to rows
    /// whose `_meta_doc_id` matches — used by per-doc DynamicModel
    /// instances on a shared engine.
    public func query(
        modelName: String,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        scopedToDocId: String? = nil,
        stringsetFields: Set<String> = []
    ) -> [[String: Any]] {
        // Take the lock only for the base SELECT so the post-query
        // stringset population (which re-enters the engine via
        // junction sub-queries) doesn't deadlock against a non-
        // reentrant NSLock.
        let tableName = sanitizedTableName(modelName)
        var rows: [[String: Any]] = {
            lock.lock()
            defer { lock.unlock() }
            do {
                let (sql, params) = try buildSelectSQL(
                    tableName: tableName,
                    modelName: modelName,
                    filter: filter,
                    options: options,
                    scopedToDocId: scopedToDocId,
                    stringsetFields: stringsetFields
                )
                return executeQuery(sql, params: params)
            } catch {
                // Non-throwing public API — typically only the cursor
                // decoder throws here, and a malformed cursor is a
                // caller bug. Log and return no rows rather than
                // crashing the host app via `try!`. Callers that need
                // error visibility should use `queryPaged`.
                NSLog("[BaoModelQueryEngine] query failed for '\(modelName)': \(error)")
                return []
            }
        }()
        populateStringsets(
            rows: &rows, modelName: modelName,
            stringsetFields: stringsetFields,
            projection: options?.projection
        )
        return rows
    }

    /// Paginated variant of `query`. Returns a `PaginatedResult` with
    /// next/prev cursors for forward/backward navigation. Mirrors
    /// js-bao's `BaseModel.query` Promise<PaginatedResult>.
    public func queryPaged(
        modelName: String,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        scopedToDocId: String? = nil,
        stringsetFields: Set<String> = []
    ) throws -> PagedQueryResult<[String: Any]> {
        let tableName = sanitizedTableName(modelName)
        let resolved = resolveSort(options: options)
        // Pull `limit + 1` rows to detect whether more rows exist past
        // this page; the extra row is trimmed before returning.
        let limit = options?.limit
        let queryOptionsWithOverLimit = QueryOptions(
            sort: options?.sort,
            sortOrder: options?.sortOrder,
            limit: limit.map { $0 + 1 },
            offset: options?.offset,
            cursor: options?.cursor,
            direction: options?.direction ?? .forward,
            documents: options?.documents,
            projection: options?.projection
        )
        // Scope the lock to just the base SELECT. Stringset population
        // reacquires the lock (see `query()`).
        var rows: [[String: Any]] = try {
            lock.lock()
            defer { lock.unlock() }
            let (sql, params) = try buildSelectSQL(
                tableName: tableName,
                modelName: modelName,
                filter: filter,
                options: queryOptionsWithOverLimit,
                scopedToDocId: scopedToDocId,
                stringsetFields: stringsetFields
            )
            return executeQuery(sql, params: params)
        }()
        populateStringsets(
            rows: &rows, modelName: modelName,
            stringsetFields: stringsetFields,
            projection: options?.projection
        )
        let hasMore: Bool = {
            guard let limit else { return false }
            if rows.count > limit {
                rows.removeLast(rows.count - limit)
                return true
            }
            return false
        }()
        let isFirstPage = options?.cursor == nil
        let (next, prev) = try CursorManager.generateResultCursors(
            rows: rows,
            sortFields: resolved.fields,
            direction: options?.direction ?? .forward,
            hasMore: hasMore,
            isFirstPage: isFirstPage
        )
        return PagedQueryResult(
            data: rows,
            nextCursor: next,
            prevCursor: prev,
            hasMore: hasMore
        )
    }

    // MARK: - SELECT SQL builder (shared by query + queryPaged)

    private struct ResolvedSort {
        let fields: [String]
        let directions: [Int] // 1 asc, -1 desc
    }

    /// Resolve the effective sort order. Precedence:
    ///   1. `sortOrder` (explicit ordered pairs) — takes priority.
    ///   2. `sort` dict — keys sorted lexicographically for
    ///      determinism across cursor generations.
    ///   3. Default: `id ASC`.
    ///
    /// Then ALWAYS appends `id ASC` if id isn't already in the sort —
    /// matches js-bao's `extractSortFields` / `buildOrderClause`
    /// (CursorManager.ts:184-197, 222-225). Ensures stable
    /// pagination on ties when sorting by a non-unique field.
    private func resolveSort(options: QueryOptions?) -> ResolvedSort {
        var fields: [String]
        var dirs: [Int]

        if let ordered = options?.sortOrder, !ordered.isEmpty {
            fields = ordered.map { $0.0 }
            dirs = ordered.map { $0.1 == -1 ? -1 : 1 }
        } else if let sort = options?.sort, !sort.isEmpty {
            fields = sort.keys.sorted()
            dirs = fields.map { sort[$0] == -1 ? -1 : 1 }
        } else {
            fields = []
            dirs = []
        }

        // Append `id ASC` as an implicit tiebreaker if not already in
        // the sort — makes pagination stable on non-unique sort keys.
        if !fields.contains("id") {
            fields.append("id")
            dirs.append(1)
        }

        return ResolvedSort(fields: fields, directions: dirs)
    }

    private func buildSelectSQL(
        tableName: String,
        modelName: String,
        filter: DocumentFilter?,
        options: QueryOptions?,
        scopedToDocId: String? = nil,
        stringsetFields: Set<String> = []
    ) throws -> (String, [Any]) {
        // Projection: build an explicit column list when the caller
        // specified one. Stringset fields don't live on the main
        // table — include-mode skips them here (they're populated
        // post-query by `populateStringsets`). The existing columns
        // path below looks at table schema to fold in id and
        // _meta_doc_id even when the caller doesn't list them.
        let selectList = buildSelectColumnList(
            tableName: tableName,
            projection: options?.projection,
            stringsetFields: stringsetFields
        )
        var sql = "SELECT \(selectList) FROM \"\(tableName)\""
        var params: [Any] = []
        var whereParts: [String] = []

        if let docId = scopedToDocId {
            whereParts.append("\"_meta_doc_id\" = ?")
            params.append(docId)
        }

        // `options.documents` — multi-doc scoping shortcut. Mirrors
        // js-bao's `WHERE _meta_doc_id IN (...)` pattern; an empty
        // list deliberately matches nothing (`1 = 0`).
        if let docs = options?.documents {
            if docs.isEmpty {
                whereParts.append("1 = 0")
            } else {
                let placeholders = docs.map { _ in "?" }.joined(separator: ", ")
                whereParts.append("\"_meta_doc_id\" IN (\(placeholders))")
                params.append(contentsOf: docs)
            }
        }

        if let filter, !filter.isEmpty {
            let (where_, whereParams) = QueryTranslator.translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFieldsByModel[modelName],
                tableName: tableName
            )
            whereParts.append("(\(where_))")
            params.append(contentsOf: whereParams)
        }

        let resolved = resolveSort(options: options)

        // Cursor pagination — lexicographic multi-field WHERE.
        if let cursorText = options?.cursor {
            let cursor = try CursorManager.decodeCursor(cursorText)
            let (cursorSQL, cursorParams) =
                try CursorManager.buildPaginationConditions(
                    cursor: cursor,
                    currentSortFields: resolved.fields,
                    sortDirections: resolved.directions,
                    direction: options?.direction ?? .forward,
                    fieldFormatter: { "\"\($0)\"" }
                )
            whereParts.append(cursorSQL)
            params.append(contentsOf: cursorParams)
        }

        if !whereParts.isEmpty {
            sql += " WHERE \(whereParts.joined(separator: " AND "))"
        }

        // ORDER BY. Backward direction reverses each sort field's
        // direction so the cursor's "<" inequality returns rows in
        // the right order — matches js-bao's walk-back semantics.
        let backward = (options?.direction ?? .forward) == .backward
        let orderParts: [String] = zip(
            resolved.fields, resolved.directions
        ).map { field, dir in
            let effective = backward ? -dir : dir
            return "\"\(field)\" \(effective == 1 ? "ASC" : "DESC")"
        }
        sql += " ORDER BY \(orderParts.joined(separator: ", "))"

        sql += " \(QueryTranslator.buildLimitOffset(limit: options?.limit, offset: options?.offset))"
        return (sql, params)
    }

    /// Count records matching a filter. `scopedToDocId` restricts to
    /// rows whose `_meta_doc_id` matches.
    public func count(
        modelName: String,
        filter: DocumentFilter? = nil,
        scopedToDocId: String? = nil,
        stringsetFields: Set<String> = [],
        documents: [String]? = nil
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(modelName)
        var sql = "SELECT COUNT(*) FROM \"\(tableName)\""
        var params: [Any] = []
        var whereParts: [String] = []

        if let docId = scopedToDocId {
            whereParts.append("\"_meta_doc_id\" = ?")
            params.append(docId)
        }
        if let docs = documents {
            if docs.isEmpty {
                whereParts.append("1 = 0")
            } else {
                let placeholders = docs.map { _ in "?" }.joined(separator: ", ")
                whereParts.append("\"_meta_doc_id\" IN (\(placeholders))")
                params.append(contentsOf: docs)
            }
        }
        if let filter, !filter.isEmpty {
            let (where_, whereParams) = QueryTranslator.translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFieldsByModel[modelName],
                tableName: tableName
            )
            whereParts.append("(\(where_))")
            params.append(contentsOf: whereParams)
        }
        if !whereParts.isEmpty {
            sql += " WHERE \(whereParts.joined(separator: " AND "))"
        }

        let results = executeQuery(sql, params: params)
        return results.first?["COUNT(*)"] as? Int ?? 0
    }

    /// Execute an aggregation query. `scopedToDocId` restricts the
    /// underlying SELECT to rows from the named doc; omit to run
    /// across every doc that's written into this engine — that's
    /// how cross-doc aggregate works on a shared store.
    public func aggregate(
        modelName: String,
        options: AggregateOptions,
        scopedToDocId: String? = nil,
        stringsetFields: Set<String> = []
    ) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(modelName)
        var (sql, params) = QueryTranslator.buildAggregation(
            tableName: tableName, options: options,
            stringsetFields: stringsetFields,
            stringFields: stringFieldsByModel[modelName]
        )
        // `buildAggregation` already threads `tableName` through
        // `translate` internally.
        if let docId = scopedToDocId {
            // Inject the docId predicate into the existing WHERE
            // (or add one). buildAggregation produces SQL like
            // `SELECT ... FROM "x" [WHERE ...] [GROUP BY ...] [ORDER BY ...] [LIMIT ...]`.
            // The first ` WHERE ` is always the outer one (any nested
            // WHERE inside e.g. stringset EXISTS subqueries appears
            // later in the string); splice into just that occurrence
            // so we don't touch the subquery. If there's no outer
            // WHERE, insert one before the first of GROUP BY /
            // ORDER BY / LIMIT.
            if let whereRange = sql.range(of: " WHERE ") {
                sql.replaceSubrange(
                    whereRange,
                    with: " WHERE \"_meta_doc_id\" = ? AND "
                )
            } else {
                let tailStart = [" GROUP BY ", " ORDER BY ", " LIMIT "]
                    .compactMap { sql.range(of: $0)?.lowerBound }
                    .min()
                if let tailStart {
                    let head = sql[..<tailStart]
                    let tail = sql[tailStart...]
                    sql = String(head) + " WHERE \"_meta_doc_id\" = ?"
                        + String(tail)
                } else {
                    sql += " WHERE \"_meta_doc_id\" = ?"
                }
            }
            params.insert(docId, at: 0)
        }
        return executeQuery(sql, params: params)
    }

    // MARK: - Raw SQL Helpers

    private func execute(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return nil
        }
        return stmt
    }

    private func executeQuery(_ sql: String, params: [Any]) -> [[String: Any]] {
        guard let stmt = prepare(sql) else { return [] }

        for (idx, param) in params.enumerated() {
            bindValue(stmt, index: Int32(idx + 1), value: param)
        }

        var results: [[String: Any]] = []
        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let type = sqlite3_column_type(stmt, i)

                switch type {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let cStr = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: cStr)
                    }
                case SQLITE_NULL:
                    break // omit nulls
                default:
                    if let cStr = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: cStr)
                    }
                }
            }
            results.append(row)
        }

        sqlite3_finalize(stmt)
        return results
    }

    private func bindValue(_ stmt: OpaquePointer, index: Int32, value: Any?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }

        switch value {
        case let v as Int:
            sqlite3_bind_int64(stmt, index, Int64(v))
        case let v as Int64:
            sqlite3_bind_int64(stmt, index, v)
        case let v as Double:
            sqlite3_bind_double(stmt, index, v)
        case let v as Float:
            sqlite3_bind_double(stmt, index, Double(v))
        case let v as Bool:
            sqlite3_bind_int(stmt, index, v ? 1 : 0)
        case let v as String:
            sqlite3_bind_text(stmt, index, (v as NSString).utf8String, -1, nil)
        case is NSNull:
            sqlite3_bind_null(stmt, index)
        default:
            let str = "\(value)"
            sqlite3_bind_text(stmt, index, (str as NSString).utf8String, -1, nil)
        }
    }

    private func getColumnNames(_ tableName: String) -> [String] {
        var names: [String] = []
        let sql = "PRAGMA table_info(\"\(tableName)\")"
        guard let stmt = prepare(sql) else { return names }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                names.append(String(cString: cStr))
            }
        }
        sqlite3_finalize(stmt)
        return names
    }

    private func sanitizedTableName(_ name: String) -> String {
        Self.sanitizeTableName(name)
    }

    /// Public sanitizer mirroring `sanitizedTableName` so callers like
    /// `DynamicModel.inspectionTableName` can resolve the actual SQLite
    /// table name without re-implementing the substitution rules.
    public static func sanitizeTableName(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }
}
