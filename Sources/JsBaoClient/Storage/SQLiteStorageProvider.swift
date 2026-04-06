import Foundation
import SQLite3

/// SQLite-backed implementation of ``StorageProvider``.
///
/// Uses the raw SQLite3 C API available on all Apple platforms.
/// Thread safety is achieved via an internal serial `DispatchQueue`
/// that serializes all database access.
public final class SQLiteStorageProvider: StorageProvider, @unchecked Sendable {

    // MARK: - Private state

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.jsbao.sqlite-storage", qos: .userInitiated)
    private let databasePath: String?
    private var _isReady = false

    // MARK: - Init

    /// Create a provider that stores its database at `path`.
    /// - Parameter path: Full file path for the SQLite database.
    ///   Pass `nil` to use an in-memory database (useful for tests).
    public init(path: String? = nil) {
        self.databasePath = path
    }

    // MARK: - StorageProvider

    public func initialize(namespace: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let resolvedPath: String
                    if let databasePath {
                        resolvedPath = databasePath
                    } else {
                        let dir = Self.defaultDirectory(namespace: namespace)
                        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        resolvedPath = (dir as NSString).appendingPathComponent("jsbao_storage.sqlite")
                    }

                    var dbPointer: OpaquePointer?
                    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                    let rc = sqlite3_open_v2(resolvedPath, &dbPointer, flags, nil)
                    guard rc == SQLITE_OK, let dbPointer else {
                        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                        throw SQLiteStorageError.openFailed(message: msg)
                    }
                    self.db = dbPointer

                    // Enable WAL mode for better concurrent read performance.
                    try self.exec("PRAGMA journal_mode=WAL")

                    try self.exec("""
                        CREATE TABLE IF NOT EXISTS kv_store (
                            store TEXT NOT NULL,
                            key TEXT NOT NULL,
                            value TEXT,
                            metadata TEXT,
                            updated_at TEXT,
                            PRIMARY KEY (store, key)
                        )
                        """)

                    self._isReady = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let db {
                    sqlite3_close_v2(db)
                    self.db = nil
                }
                self._isReady = false
                continuation.resume()
            }
        }
    }

    public func isReady() -> Bool {
        queue.sync { _isReady }
    }

    public func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
        try await onQueue {
            try self.ensureReady()

            let sql = "SELECT value, metadata, updated_at FROM kv_store WHERE store = ? AND key = ?"
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, key, -1, Self.SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return try self.recordFromRow(stmt: stmt!, key: key)
        }
    }

    public func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
        try await onQueue {
            try self.ensureReady()

            let valueJSON = try self.encode(value)
            let metaJSON = try self.encodeMetadata(metadata)
            let now = Self.iso8601Now()

            let sql = """
                INSERT INTO kv_store (store, key, value, metadata, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(store, key) DO UPDATE SET value = excluded.value, metadata = excluded.metadata, updated_at = excluded.updated_at
                """
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, key, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, valueJSON, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, metaJSON, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, now, -1, Self.SQLITE_TRANSIENT)

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw SQLiteStorageError.executionFailed(message: self.lastError())
            }
        }
    }

    public func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
        try await onQueue {
            try self.ensureReady()

            try self.exec("BEGIN TRANSACTION")
            do {
                let sql = """
                    INSERT INTO kv_store (store, key, value, metadata, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(store, key) DO UPDATE SET value = excluded.value, metadata = excluded.metadata, updated_at = excluded.updated_at
                    """
                var stmt: OpaquePointer?
                try self.prepare(sql, statement: &stmt)
                defer { sqlite3_finalize(stmt) }

                let now = Self.iso8601Now()

                for record in records {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)

                    let valueJSON = try self.encode(record.value)
                    let metaJSON = try self.encodeMetadata(record.metadata)

                    sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, record.key, -1, Self.SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, valueJSON, -1, Self.SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, metaJSON, -1, Self.SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 5, now, -1, Self.SQLITE_TRANSIENT)

                    let rc = sqlite3_step(stmt)
                    guard rc == SQLITE_DONE else {
                        throw SQLiteStorageError.executionFailed(message: self.lastError())
                    }
                }

                try self.exec("COMMIT")
            } catch {
                try? self.exec("ROLLBACK")
                throw error
            }
        }
    }

    public func delete(store: String, key: String) async throws {
        try await onQueue {
            try self.ensureReady()

            let sql = "DELETE FROM kv_store WHERE store = ? AND key = ?"
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, key, -1, Self.SQLITE_TRANSIENT)

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw SQLiteStorageError.executionFailed(message: self.lastError())
            }
        }
    }

    public func clear(store: String) async throws {
        try await onQueue {
            try self.ensureReady()

            let sql = "DELETE FROM kv_store WHERE store = ?"
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw SQLiteStorageError.executionFailed(message: self.lastError())
            }
        }
    }

    public func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
        try await onQueue {
            try self.ensureReady()

            let sql = "SELECT key, value, metadata, updated_at FROM kv_store WHERE store = ? ORDER BY rowid ASC"
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
                let key = String(cString: keyPtr)
                let record: StorageRecord<T> = try self.recordFromRow(stmt: stmt!, key: key, valueColumn: 1, metadataColumn: 2, updatedAtColumn: 3)
                try callback(record)
            }
        }
    }

    public func keys(store: String) async throws -> [String] {
        try await onQueue {
            try self.ensureReady()

            let sql = "SELECT key FROM kv_store WHERE store = ? ORDER BY rowid ASC"
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)

            var result: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    result.append(String(cString: ptr))
                }
            }
            return result
        }
    }

    public func has(store: String, key: String) async throws -> Bool {
        try await onQueue {
            try self.ensureReady()

            let sql = "SELECT 1 FROM kv_store WHERE store = ? AND key = ? LIMIT 1"
            var stmt: OpaquePointer?
            try self.prepare(sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, store, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, key, -1, Self.SQLITE_TRANSIENT)

            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: - Private helpers

    /// The SQLite SQLITE_TRANSIENT destructor constant, telling SQLite to copy bound values immediately.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func ensureReady() throws {
        guard _isReady, db != nil else {
            throw SQLiteStorageError.notInitialized
        }
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteStorageError.executionFailed(message: lastError())
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteStorageError.prepareFailed(message: lastError())
        }
    }

    private func lastError() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func encode<T: Codable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let str = String(data: data, encoding: .utf8) else {
            throw SQLiteStorageError.encodingFailed
        }
        return str
    }

    private func encodeMetadata(_ metadata: [String: String]?) throws -> String? {
        guard let metadata else { return nil }
        let data = try JSONEncoder().encode(metadata)
        return String(data: data, encoding: .utf8)
    }

    private func decodeMetadata(_ json: String?) -> [String: String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Build a ``StorageRecord`` from the current row of a statement.
    /// Default column indices match the `get` query (value=0, metadata=1, updated_at=2).
    private func recordFromRow<T: Codable>(
        stmt: OpaquePointer,
        key: String,
        valueColumn: Int32 = 0,
        metadataColumn: Int32 = 1,
        updatedAtColumn: Int32 = 2
    ) throws -> StorageRecord<T> {
        guard let valuePtr = sqlite3_column_text(stmt, valueColumn) else {
            throw SQLiteStorageError.decodingFailed
        }
        let valueJSON = String(cString: valuePtr)
        guard let valueData = valueJSON.data(using: .utf8) else {
            throw SQLiteStorageError.decodingFailed
        }
        let value = try JSONDecoder().decode(T.self, from: valueData)

        let metaStr: String? = sqlite3_column_text(stmt, metadataColumn).map { String(cString: $0) }
        let metadata = decodeMetadata(metaStr)

        let updatedAt: String? = sqlite3_column_text(stmt, updatedAtColumn).map { String(cString: $0) }

        return StorageRecord(key: key, value: value, metadata: metadata, updatedAt: updatedAt)
    }

    /// Execute a throwing closure on the serial queue, bridging back to async/await.
    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func defaultDirectory(namespace: String) -> String {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
        #endif
        return (base as NSString).appendingPathComponent("JsBaoClient/\(namespace)")
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - Errors

public enum SQLiteStorageError: Error, LocalizedError {
    case notInitialized
    case openFailed(message: String)
    case prepareFailed(message: String)
    case executionFailed(message: String)
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SQLiteStorageProvider has not been initialized"
        case .openFailed(let message):
            return "Failed to open SQLite database: \(message)"
        case .prepareFailed(let message):
            return "Failed to prepare SQL statement: \(message)"
        case .executionFailed(let message):
            return "SQL execution failed: \(message)"
        case .encodingFailed:
            return "Failed to encode value to JSON"
        case .decodingFailed:
            return "Failed to decode value from JSON"
        }
    }
}
