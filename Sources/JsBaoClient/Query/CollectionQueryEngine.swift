import Foundation
import SQLite3

/// SQLite-backed query engine that mirrors Y.Map collection data for fast queries.
///
/// Each collection gets its own table in an in-memory SQLite database.
/// Records are synced from Y.Map on initial load and kept in sync via
/// explicit calls to `sync()` after mutations.
///
/// This replaces the JS client's IndexedDB/sql.js approach with native SQLite.
public class CollectionQueryEngine {

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init() {
        var db: OpaquePointer?
        // Use in-memory SQLite for query indexing (separate from persistence)
        if sqlite3_open(":memory:", &db) == SQLITE_OK {
            self.db = db
            // Enable WAL for concurrent reads
            execute("PRAGMA journal_mode=WAL")
            execute("PRAGMA synchronous=OFF")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Table Management

    /// Create or update a table for a collection, with columns for each field.
    public func ensureTable(collectionName: String, fields: [(name: String, type: FieldType)]) {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)
        var columns = ["\"id\" TEXT PRIMARY KEY"]

        for field in fields where field.name != "id" {
            let sqlType: String
            switch field.type {
            case .number: sqlType = "REAL"
            case .boolean: sqlType = "INTEGER"
            default: sqlType = "TEXT"
            }
            columns.append("\"\(field.name)\" \(sqlType)")
        }

        let sql = "CREATE TABLE IF NOT EXISTS \"\(tableName)\" (\(columns.joined(separator: ", ")))"
        execute(sql)

        // Create indexes on common query fields
        for field in fields where field.name != "id" {
            execute("CREATE INDEX IF NOT EXISTS \"idx_\(tableName)_\(field.name)\" ON \"\(tableName)\"(\"\(field.name)\")")
        }
    }

    // MARK: - Data Sync

    /// Sync all records from a collection into the SQLite table.
    /// Call this after opening a document or after batch mutations.
    public func syncRecords(collectionName: String, records: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)

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

    /// Insert or update a single record.
    public func upsertRecord(collectionName: String, record: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)
        let columnNames = getColumnNames(tableName)
        guard !columnNames.isEmpty else { return }

        let quotedCols = columnNames.map { "\"\($0)\"" }.joined(separator: ",")
        let placeholders = columnNames.map { _ in "?" }.joined(separator: ",")
        let sql = "INSERT OR REPLACE INTO \"\(tableName)\" (\(quotedCols)) VALUES (\(placeholders))"

        guard let stmt = prepare(sql) else { return }
        for (idx, col) in columnNames.enumerated() {
            bindValue(stmt, index: Int32(idx + 1), value: record[col])
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Delete a record by ID.
    public func deleteRecord(collectionName: String, id: String) {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)
        let sql = "DELETE FROM \"\(tableName)\" WHERE \"id\" = ?"
        guard let stmt = prepare(sql) else { return }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Query

    /// Execute a query with filter and options, returning raw dictionaries.
    public func query(
        collectionName: String,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)
        var sql = "SELECT * FROM \"\(tableName)\""
        var params: [Any] = []

        // WHERE
        if let filter, !filter.isEmpty {
            let (where_, whereParams) = QueryTranslator.translate(filter)
            sql += " WHERE \(where_)"
            params = whereParams
        }

        // ORDER BY
        if let sort = options?.sort, !sort.isEmpty {
            sql += " \(QueryTranslator.buildOrderBy(sort))"
        }

        // LIMIT / OFFSET
        sql += " \(QueryTranslator.buildLimitOffset(limit: options?.limit, offset: options?.offset))"

        return executeQuery(sql, params: params)
    }

    /// Count records matching a filter.
    public func count(collectionName: String, filter: DocumentFilter? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)
        var sql = "SELECT COUNT(*) FROM \"\(tableName)\""
        var params: [Any] = []

        if let filter, !filter.isEmpty {
            let (where_, whereParams) = QueryTranslator.translate(filter)
            sql += " WHERE \(where_)"
            params = whereParams
        }

        let results = executeQuery(sql, params: params)
        return results.first?["COUNT(*)"] as? Int ?? 0
    }

    /// Execute an aggregation query.
    public func aggregate(
        collectionName: String,
        options: AggregateOptions
    ) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        let tableName = sanitizedTableName(collectionName)
        let (sql, params) = QueryTranslator.buildAggregation(tableName: tableName, options: options)
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
        name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }
}
