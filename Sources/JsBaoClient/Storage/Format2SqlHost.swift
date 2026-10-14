import Foundation
import SQLite3

/// Direct, serialized SQL access to a storage provider's own database
/// connection (#3436).
///
/// A record-log document's records live in real SQL tables, not in the
/// `kv_store` key-value API the public ``StorageProvider`` protocol exposes —
/// a large document read one JSON blob at a time is not a document. So the
/// record store needs the connection itself. The `Format2` name is kept from
/// the large-document format this host was built for, which is no longer
/// served.
///
/// It needs THAT connection specifically, never a second one on the same file.
/// `JsBaoClient.setupStorage` records why in its own comment: a second handle
/// on one WAL file produced `SQLITE_BUSY` under concurrent auth and data
/// writes. Everything the record-log layer does — the store, the group commit,
/// the file-backed query engine — runs on the provider's single serialized
/// handle.
///
/// The protocol is deliberately NOT part of ``StorageProvider``: a provider
/// that cannot host a record-log document simply does not conform, which is what
/// makes the refusal a type-level fact rather than a runtime capability probe.
/// ``MemoryStorageProvider`` does not conform.
public protocol Format2SqlHost: AnyObject, Sendable {
    /// Run `body` on the provider's serial queue with its connection.
    ///
    /// The handle is valid only for the duration of the call: it belongs to
    /// the provider, which may close it. Every SQL failure throws — none is
    /// discarded, which is the defect `BaoModelQueryEngine` shipped with
    /// (3436-SO-05).
    func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T

    /// The directory the database file lives in, when there is one.
    ///
    /// What a document may keep is a property of the VOLUME it is written
    /// to, and the only thing that knows which volume that is is the
    /// provider. `nil` for a host with no file.
    var databaseDirectory: String? { get }
}

public extension Format2SqlHost {
    /// A host that does not say reads as "no capacity API answered", which is
    /// an unknown quota rather than a refusal.
    var databaseDirectory: String? { nil }
}

/// One SQLite connection, as the record-log layer uses it.
///
/// A protocol rather than the concrete class so a caller can WRAP one — the
/// fault injection the tests need is a decorator over a real connection, which
/// keeps the failure path honest (a real statement really fails) and keeps the
/// library free of a test seam it would otherwise have to carry.
public protocol Format2SqlConnection: AnyObject {
    /// Run a statement for effect. Every failure throws.
    func execute(_ sql: String, _ bindings: [Format2SqlValue]) throws
    /// Run a statement and collect its rows.
    func query(_ sql: String, _ bindings: [Format2SqlValue]) throws -> [Format2SqlRow]
    /// Run DDL, unbound — the statements come from this library, never a caller.
    func executeScript(_ sql: String) throws
    /// Run `body` as one commit, rolling back if it throws. Nesting reuses the
    /// open transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T
    /// Whether a transaction opened through ``transaction(_:)`` is in flight.
    var inTransaction: Bool { get }
    /// The underlying SQLite handle, valid only inside the
    /// ``Format2SqlHost/withConnection(_:)`` call that produced this
    /// connection.
    ///
    /// For the ONE caller that speaks SQLite's C API directly rather than
    /// through the statements above: the file-backed query engine, which
    /// builds its SELECTs column by column and binds its own parameters
    /// (#3436, behavior 13). It gets the same connection so its statements are
    /// serialized with the record store's and join whatever transaction is
    /// open — which is what lets a projected row commit with its merged row.
    ///
    /// A wrapper that cannot supply one answers `nil`, and the engine refuses
    /// rather than opening a second handle on the file.
    var rawHandle: OpaquePointer? { get }
}

extension Format2SqlConnection {
    public func execute(_ sql: String) throws { try execute(sql, []) }
    public func query(_ sql: String) throws -> [Format2SqlRow] { try query(sql, []) }
}

/// The real connection over a raw SQLite handle.
///
/// Wraps the handle so callers bind values rather than interpolating them, and
/// so a failed step is an error rather than a return code nobody read.
public final class SQLiteFormat2Connection: Format2SqlConnection {

    private let db: OpaquePointer
    /// Depth of nested ``transaction(_:)`` calls. SQLite has no nested
    /// transactions, so an inner call reuses the open one — a catch-up fold
    /// calling `applyRemote` inside its own transaction must not commit
    /// halfway through.
    private var transactionDepth = 0

    /// Compiled statements by SQL text, so the same text is compiled once and
    /// run again rather than prepared and finalized on every call — the record
    /// store issues a handful of texts thousands of times.
    ///
    /// Each statement is reset and its bindings cleared as soon as its call
    /// returns, so a cached one never holds a read open or carries a value
    /// into the next call. Texts built per call (an `IN` list of `?` per
    /// member) would grow the cache without end, so it is bounded and the
    /// statement used longest ago goes first.
    private var statements: [StatementKey: CachedStatement] = [:]
    private var uses: UInt64 = 0
    static let statementLimit = 64

    /// A SQL text compared by its bytes. `String` equality is canonical
    /// equivalence — `é` as one scalar equals `e` and a combining accent — but
    /// SQLite reads the bytes, and two such texts can name two tables.
    private struct StatementKey: Hashable {
        let sql: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            var left = lhs.sql
            var right = rhs.sql
            return left.withUTF8 { left in
                right.withUTF8 { right in
                    left.count == right.count
                        && (left.isEmpty || memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0)
                }
            }
        }

        func hash(into hasher: inout Hasher) {
            var sql = sql
            sql.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    /// A class, so marking a use does not hash the SQL text a second time.
    private final class CachedStatement {
        let handle: OpaquePointer
        var lastUse: UInt64

        init(handle: OpaquePointer, lastUse: UInt64) {
            self.handle = handle
            self.lastUse = lastUse
        }
    }

    init(db: OpaquePointer) {
        self.db = db
    }

    /// Whether this wrapper still wraps `handle` — a provider that closed and
    /// reopened has a new one, and the old depth counter with it.
    func owns(_ handle: OpaquePointer) -> Bool { db == handle }

    // MARK: - Statements

    /// Run a statement for effect.
    public func execute(_ sql: String, _ bindings: [Format2SqlValue]) throws {
        let statement = try prepare(sql, bindings)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw failed(sql)
        }
        release(statement)
    }

    /// Run a statement and collect its rows.
    public func query(_ sql: String, _ bindings: [Format2SqlValue]) throws -> [Format2SqlRow] {
        let statement = try prepare(sql, bindings)

        var count: Int32 = 0
        var names: [String?] = []
        var index: Int32 = 0
        var rows: [Format2SqlRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw failed(sql)
            }
            // The names once per call rather than once per row, and after the
            // first step: a cached statement whose table changed under it is
            // recompiled by the step, and its columns with it.
            if rows.isEmpty {
                count = sqlite3_column_count(statement)
                names.reserveCapacity(Int(count))
                index = 0
                while index < count {
                    names.append(sqlite3_column_name(statement, index).map { String(cString: $0) })
                    index += 1
                }
            }
            var columns = [String: Format2SqlValue](minimumCapacity: names.count)
            index = 0
            while index < count {
                if let name = names[Int(index)] { columns[name] = Self.value(of: statement, at: index) }
                index += 1
            }
            rows.append(Format2SqlRow(columns: columns))
        }
        release(statement)
        return rows
    }

    /// Run several statements separated by semicolons — DDL only, so nothing
    /// is bound. Used for the schema, where the statements come from this
    /// library and never from a caller.
    public func executeScript(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        let message = errorPointer.map { String(cString: $0) } ?? lastError()
        if errorPointer != nil { sqlite3_free(errorPointer) }
        guard rc == SQLITE_OK else {
            throw Format2SqlError.executionFailed(sql: sql, message: message)
        }
    }

    // MARK: - Transactions

    /// Run `body` as one commit, rolling back if it throws.
    ///
    /// `BEGIN IMMEDIATE` rather than the deferred default: the fold and the
    /// local-write commit both read before they write, and a deferred
    /// transaction that upgrades to a writer mid-way can lose the lock to
    /// another connection and be asked to retry the whole thing.
    ///
    /// Nesting reuses the open transaction. A catch-up fold is one commit for
    /// a whole overlay — thousands of records — and the per-entry projection
    /// inside it must not commit on its own.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try executeScript("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try executeScript("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            // A failed ROLLBACK is reported as the original error: the caller
            // needs the reason the write failed, not the reason the cleanup
            // after it did.
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    /// Whether a transaction opened through ``transaction(_:)`` is in flight.
    public var inTransaction: Bool { transactionDepth > 0 }

    public var rawHandle: OpaquePointer? { db }

    // MARK: - Private

    /// The compiled statement for `sql` — the cached one, or one compiled now
    /// and cached — with `bindings` bound. Hand it back with `release(_:)`
    /// once its rows are read, or drop it with `failed(_:)`.
    private func prepare(
        _ sql: String, _ bindings: [Format2SqlValue]
    ) throws -> OpaquePointer? {
        uses &+= 1
        let statement: OpaquePointer?
        let key = StatementKey(sql: sql)
        if let cached = statements[key] {
            cached.lastUse = uses
            statement = cached.handle
        } else {
            var compiled: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &compiled, nil) == SQLITE_OK else {
                sqlite3_finalize(compiled)
                throw Format2SqlError.prepareFailed(sql: sql, message: lastError())
            }
            // Text with no statement in it (only a comment) compiles to
            // nothing, which the step reports as misuse, as it always has.
            if let compiled {
                if statements.count >= Self.statementLimit { evictLeastRecentlyUsed() }
                statements[key] = CachedStatement(handle: compiled, lastUse: uses)
            }
            statement = compiled
        }
        var index: Int32 = 1
        for binding in bindings {
            defer { index += 1 }
            switch binding {
            case .null:
                sqlite3_bind_null(statement, index)
            case .text(let text):
                _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                sqlite3_bind_double(statement, index, value)
            }
        }
        return statement
    }

    private static func value(
        of statement: OpaquePointer?, at index: Int32
    ) -> Format2SqlValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        }
    }

    /// Put a statement back for its next call: no longer running, nothing bound.
    private func release(_ statement: OpaquePointer?) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    /// The error a failed step on `sql` throws, read before anything else
    /// touches the handle. The statement is finalized rather than kept: one
    /// that failed for its schema (a table dropped under it) would fail again.
    private func failed(_ sql: String) -> Format2SqlError {
        let error = Format2SqlError.executionFailed(sql: sql, message: lastError())
        if let cached = statements.removeValue(forKey: StatementKey(sql: sql)) { sqlite3_finalize(cached.handle) }
        return error
    }

    private func evictLeastRecentlyUsed() {
        guard let oldest = statements.min(by: { $0.value.lastUse < $1.value.lastUse }) else { return }
        statements.removeValue(forKey: oldest.key)
        sqlite3_finalize(oldest.value.handle)
    }

    /// Finalize every cached statement. The provider calls this before it
    /// closes the handle, so the close is a real one: `sqlite3_close_v2` keeps a
    /// connection with a live statement open as a zombie.
    func finalizeStatements() {
        for statement in statements.values { sqlite3_finalize(statement.handle) }
        statements.removeAll()
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// A bound or returned SQL value.
public enum Format2SqlValue: Equatable, Sendable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)

    public var stringValue: String? {
        switch self {
        case .text(let text): return text
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .null: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let text): return Int(text)
        case .null: return nil
        }
    }

    public var isNull: Bool { self == .null }

    /// Bind a `JSONValue` the way the JS store binds one: a string, a number
    /// or a bool, and null for anything structured. The fold never binds a
    /// structured value — those travel inside the `_data` JSON text.
    public init(json: JSONValue) {
        switch json {
        case .string(let text): self = .text(text)
        case .number(let value):
            self = value == value.rounded() && abs(value) < 9_007_199_254_740_992
                ? .integer(Int64(value))
                : .real(value)
        case .bool(let value): self = .integer(value ? 1 : 0)
        case .null, .object, .array: self = .null
        }
    }
}

/// One returned row.
public struct Format2SqlRow: Sendable {
    public let columns: [String: Format2SqlValue]
    public subscript(column: String) -> Format2SqlValue { columns[column] ?? .null }
}

public enum Format2SqlError: Error, LocalizedError {
    case notInitialized
    case prepareFailed(sql: String, message: String)
    case executionFailed(sql: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "the storage provider's database is not open"
        case .prepareFailed(let sql, let message):
            return "failed to prepare SQL: \(message) — \(sql)"
        case .executionFailed(let sql, let message):
            return "SQL execution failed: \(message) — \(sql)"
        }
    }
}

// MARK: - The provider's conformance

extension SQLiteStorageProvider: Format2SqlHost {

    /// The provider's own connection, on its own serial queue.
    ///
    /// Reusing the serial queue is what makes this safe beside the `kv_store`
    /// API: a record-log write and an auth write cannot be in flight at once, so
    /// there is no second writer to contend with and the `SQLITE_BUSY` that
    /// a second handle produced cannot arise.
    public func withConnection<T>(
        _ body: (any Format2SqlConnection) throws -> T
    ) throws -> T {
        try withRawConnection { db in
            try body(format2ConnectionOnQueue(db))
        }
    }
}
